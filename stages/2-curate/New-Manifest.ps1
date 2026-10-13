<#
.SYNOPSIS
    Stage 2 - turn a Stage 1 inventory into an editable rebuild manifest.

.DESCRIPTION
    Reads profiles\<ProfileName>\inventory.json and winget-export.json and
    writes manifest.json next to them. The manifest is the single file later
    stages read, and the one you edit by hand:

      install - installed on first boot (winget id required)
      review  - found on this PC but not matched to a winget package; change
                to install (and add an id or installer) or to skip
      skip    - deliberately left out: runtimes that arrive as dependencies,
                inbox Windows components, drivers and games

    Games are never reinstalled; launchers are, and are pointed back at the
    libraries on the preserved disks.

    Matching installed programs to winget ids is a name heuristic, so check
    the 'review' entries rather than trusting them to be complete.

.EXAMPLE
    .\New-Manifest.ps1
    .\New-Manifest.ps1 -ProfileName gaming-rig -WindowsChannel Insider -Force
#>
[CmdletBinding()]
param(
    [string]$ProfileName = $env:COMPUTERNAME,
    [string]$ProfileRoot,
    [ValidateSet('Release', 'Insider')]
    [string]$WindowsChannel = 'Release',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
if (-not $ProfileRoot) { $ProfileRoot = Join-Path $PSScriptRoot '..\..\profiles' }

$dir = [IO.Path]::GetFullPath((Join-Path $ProfileRoot $ProfileName))
$inventoryFile = Join-Path $dir 'inventory.json'
$wingetFile = Join-Path $dir 'winget-export.json'
$manifestFile = Join-Path $dir 'manifest.json'

if (-not (Test-Path $inventoryFile)) { throw "No inventory at $inventoryFile - run Stage 1 first." }
if ((Test-Path $manifestFile) -and -not $Force) {
    throw "$manifestFile already exists and may contain your edits. Use -Force to regenerate it."
}

$inventory = Get-Content $inventoryFile -Raw | ConvertFrom-Json
$wingetIds = @()
if (Test-Path $wingetFile) {
    $wingetIds = @((Get-Content $wingetFile -Raw | ConvertFrom-Json).Sources.Packages.PackageIdentifier | Sort-Object -Unique)
}

# winget ids that should not be installed explicitly
$runtimeIds = '^(Microsoft\.(VCRedist|DotNet|VCLibs|UI\.Xaml|WindowsAppRuntime|DirectX|AppInstaller|XNARedist|GameInput)|CreativeTechnology\.OpenAL|Nvidia\.PhysX|EpicGames\.EpicOnlineServices)'
$inboxIds = '^Microsoft\.(Edge|OneDrive|WindowsTerminal|WindowsPCHealthCheck|WindowsInstallationAssistant)$'

# installed-program names that are not apps to carry over
$runtimeNames = 'Visual C\+\+|Desktop Runtime|ASP\.NET Core|Redistributable|^OpenAL$|Epic Online Services|Rockstar Games SDK|Microsoft GameInput'
$inboxNames = '^Microsoft (Edge|OneDrive)|Application Compatibility|Installation Assistant|PC Health Check'
$driverNames = '^(NVIDIA|AMD|Realtek|Intel\(R\)) '

function Get-Normalized([string]$Text) { ($Text -replace '[^A-Za-z0-9]', '').ToLower() }

$apps = New-Object System.Collections.Generic.List[object]
$matchKeys = New-Object System.Collections.Generic.List[string]

foreach ($id in $wingetIds) {
    if ($id -match $runtimeIds) { $category = 'runtime'; $action = 'skip' }
    elseif ($id -match $inboxIds) { $category = 'inbox'; $action = 'skip' }
    else { $category = 'app'; $action = 'install' }

    $apps.Add([ordered]@{ name = $id; id = $id; source = 'winget'; category = $category; action = $action })

    # "Publisher.Product.Edition" -> try both "publisherproductedition" and "productedition"
    $matchKeys.Add((Get-Normalized $id))
    $tail = Get-Normalized (($id -split '\.', 2)[1])
    if ($tail.Length -ge 4) { $matchKeys.Add($tail) }
}

$games = New-Object System.Collections.Generic.List[object]
foreach ($program in $inventory.programs) {
    $name = $program.name
    if ($program.key -like 'Steam App *') {
        $games.Add([ordered]@{ name = $name; launcher = 'Steam' })
        continue
    }
    if ($name -match $runtimeNames -or $name -match $inboxNames -or $name -match $driverNames) { continue }

    $normalized = Get-Normalized $name
    if ($matchKeys | Where-Object { $normalized.Contains($_) }) { continue }

    $apps.Add([ordered]@{ name = $name; id = $null; source = 'manual'; category = 'app'; action = 'review' })
}

$storeApps = @($inventory.storeApps |
        Where-Object { $_.signature -eq 'Store' -and $_.name -notmatch '^(Microsoft|MicrosoftWindows|MicrosoftCorporationII|Clipchamp|MSTeams|aimgr)' } |
        ForEach-Object { [ordered]@{ name = $_.name; id = $null; source = 'msstore'; category = 'app'; action = 'review' } })

$manifest = [ordered]@{
    schema  = 1
    profile = $ProfileName
    windows = [ordered]@{
        channel = $WindowsChannel.ToLower()
        version = $inventory.os.displayVersion
        edition = $inventory.os.edition
        locale  = $inventory.os.locale
    }
    disks   = [ordered]@{
        # Setup always stops at the disk picker; it never chooses or wipes a disk on its own.
        install  = 'prompt'
        preserve = @($inventory.hardware.disks | Where-Object { -not $_.isSystem } |
                ForEach-Object { [ordered]@{ model = $_.model; sizeGB = $_.sizeGB } })
    }
    tweaks  = [ordered]@{
        hideSteamGameEntries = $true
    }
    apps    = @($apps | Sort-Object { $_.action }, { $_.name }) + $storeApps
    games   = @($games | Sort-Object { $_.name })
}

$manifest | ConvertTo-Json -Depth 5 | Out-File $manifestFile -Encoding utf8

$counts = $manifest.apps | Group-Object { $_.action } | ForEach-Object { "$($_.Name): $($_.Count)" }
Write-Host "Apps -> $($counts -join '  ')   Games (not reinstalled): $($games.Count)"
Write-Host "Preserved disks: $(($manifest.disks.preserve | ForEach-Object { $_.model }) -join ', ')"
Write-Host "Wrote $manifestFile - edit the 'review' entries before Stage 3."
