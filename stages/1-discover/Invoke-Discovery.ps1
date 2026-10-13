<#
.SYNOPSIS
    Stage 1 - read-only inventory of the current PC.

.DESCRIPTION
    Collects what later stages need to rebuild this machine: OS and hardware
    summary, installed apps, third-party drivers, optional features, startup
    items, services and scheduled tasks. Nothing on the system is changed.

    Output goes to profiles\<ProfileName>\, which is git-ignored. No product
    keys, serial numbers, user names or passwords are recorded.

    Runs without elevation; a few sections (TPM, optional features) are only
    filled in when run as Administrator and are listed under 'skipped' otherwise.

.EXAMPLE
    .\Invoke-Discovery.ps1
    .\Invoke-Discovery.ps1 -ProfileName gaming-rig
#>
[CmdletBinding()]
param(
    [string]$ProfileName = $env:COMPUTERNAME,
    [string]$OutputRoot
)

$ErrorActionPreference = 'Stop'
# Not a param default: $PSScriptRoot is empty there under Windows PowerShell 5.1 -File
if (-not $OutputRoot) { $OutputRoot = Join-Path $PSScriptRoot '..\..\profiles' }
$skipped = New-Object System.Collections.Generic.List[string]

function Invoke-Section {
    param([string]$Name, [scriptblock]$Script)
    Write-Host "  $Name..."
    try { & $Script }
    catch {
        $skipped.Add("${Name}: $($_.Exception.Message)")
        $null
    }
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

$outDir = Join-Path $OutputRoot $ProfileName
New-Item -ItemType Directory -Force $outDir | Out-Null
$outDir = (Resolve-Path $outDir).Path

Write-Host "Inventorying this PC (read-only) -> $outDir"

$os = Invoke-Section 'Operating system' {
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $w = Get-CimInstance Win32_OperatingSystem
    [ordered]@{
        caption        = $w.Caption
        edition        = $cv.EditionID
        displayVersion = $cv.DisplayVersion
        build          = "$($cv.CurrentBuild).$($cv.UBR)"
        architecture   = $w.OSArchitecture
        locale         = (Get-Culture).Name
        uiLanguage     = (Get-UICulture).Name
        keyboard       = (Get-WinUserLanguageList | ForEach-Object { $_.InputMethodTips }) -join ';'
        timeZone       = (Get-TimeZone).Id
    }
}

$activation = Invoke-Section 'Activation channel' {
    Get-CimInstance SoftwareLicensingProduct -Filter "PartialProductKey IS NOT NULL AND ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f'" |
        ForEach-Object { [ordered]@{ name = $_.Name; channel = $_.Description; licenseStatus = $_.LicenseStatus } }
}

$hardware = Invoke-Section 'Hardware' {
    $cs = Get-CimInstance Win32_ComputerSystem
    $bb = Get-CimInstance Win32_BaseBoard
    $systemDisks = @(Get-Disk | Where-Object { $_.IsBoot -or $_.IsSystem } | ForEach-Object { "$($_.Number)" })
    [ordered]@{
        manufacturer = $cs.Manufacturer
        model        = $cs.Model
        baseboard    = "$($bb.Manufacturer) $($bb.Product)"
        cpu          = @(Get-CimInstance Win32_Processor | ForEach-Object { $_.Name.Trim() })
        ramGB        = [math]::Round($cs.TotalPhysicalMemory / 1GB)
        gpu          = @(Get-CimInstance Win32_VideoController | ForEach-Object {
                [ordered]@{ name = $_.Name; driverVersion = $_.DriverVersion } })
        disks        = @(Get-PhysicalDisk | ForEach-Object {
                [ordered]@{ model = $_.FriendlyName; media = "$($_.MediaType)"; bus = "$($_.BusType)"; sizeGB = [math]::Round($_.Size / 1GB); isSystem = ($systemDisks -contains "$($_.DeviceId)") } })
        secureBoot   = [bool](Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State' -ErrorAction SilentlyContinue).UEFISecureBootEnabled
    }
}

$tpm = Invoke-Section 'TPM' {
    if (-not $isAdmin) { throw 'requires elevation' }
    $t = Get-Tpm
    [ordered]@{ present = $t.TpmPresent; ready = $t.TpmReady }
}

$win32Apps = Invoke-Section 'Installed programs' {
    $keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    Get-ItemProperty $keys -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -and -not $_.SystemComponent -and -not $_.ParentKeyName } |
        Sort-Object DisplayName -Unique |
        ForEach-Object { [ordered]@{ name = $_.DisplayName; version = $_.DisplayVersion; publisher = $_.Publisher; key = $_.PSChildName } }
}

$storeApps = Invoke-Section 'Store apps' {
    Get-AppxPackage | Where-Object { -not $_.IsFramework -and $_.SignatureKind -ne 'System' } |
        Sort-Object Name |
        ForEach-Object { [ordered]@{ name = $_.Name; version = "$($_.Version)"; signature = "$($_.SignatureKind)" } }
}

$wingetFile = Join-Path $outDir 'winget-export.json'
$null = Invoke-Section 'winget export' {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { throw 'winget not found' }
    winget export -o $wingetFile -s winget --disable-interactivity | Out-Null
    if (-not (Test-Path $wingetFile)) { throw "winget export failed (exit $LASTEXITCODE)" }
}

$drivers = Invoke-Section 'Third-party drivers' {
    Get-CimInstance Win32_PnPSignedDriver |
        Where-Object { $_.DriverProviderName -and $_.DriverProviderName -ne 'Microsoft' -and $_.InfName -like 'oem*.inf' } |
        Sort-Object DeviceClass, DeviceName |
        ForEach-Object { [ordered]@{ class = $_.DeviceClass; device = $_.DeviceName; provider = $_.DriverProviderName; version = $_.DriverVersion; inf = $_.InfName } }
}

$features = Invoke-Section 'Optional features' {
    if (-not $isAdmin) { throw 'requires elevation' }
    @(Get-WindowsOptionalFeature -Online | Where-Object State -eq 'Enabled' | ForEach-Object FeatureName | Sort-Object)
}

$startup = Invoke-Section 'Startup items' {
    Get-CimInstance Win32_StartupCommand |
        ForEach-Object { [ordered]@{ name = $_.Name; command = $_.Command; location = $_.Location } }
}

$services = Invoke-Section 'Third-party services' {
    Get-CimInstance Win32_Service |
        Where-Object { $_.PathName -and $_.PathName -notmatch '\\Windows\\' } |
        Sort-Object Name |
        ForEach-Object { [ordered]@{ name = $_.Name; displayName = $_.DisplayName; startMode = $_.StartMode; state = $_.State } }
}

$tasks = Invoke-Section 'Third-party scheduled tasks' {
    Get-ScheduledTask | Where-Object { $_.TaskPath -notlike '\Microsoft\*' } |
        Sort-Object TaskPath, TaskName |
        ForEach-Object { [ordered]@{ path = $_.TaskPath; name = $_.TaskName; state = "$($_.State)" } }
}

$inventory = [ordered]@{
    schema           = 1
    profile          = $ProfileName
    collected        = (Get-Date).ToString('yyyy-MM-dd')
    elevated         = $isAdmin
    os               = $os
    activation       = @($activation)
    hardware         = $hardware
    tpm              = $tpm
    programs         = @($win32Apps)
    storeApps        = @($storeApps)
    drivers          = @($drivers)
    optionalFeatures = $features
    startup          = @($startup)
    services         = @($services)
    scheduledTasks   = @($tasks)
    skipped          = @($skipped)
}

$inventoryFile = Join-Path $outDir 'inventory.json'
$inventory | ConvertTo-Json -Depth 6 | Out-File $inventoryFile -Encoding utf8

Write-Host ''
Write-Host "Programs: $(@($win32Apps).Count)  Store apps: $(@($storeApps).Count)  Drivers: $(@($drivers).Count)  Services: $(@($services).Count)  Tasks: $(@($tasks).Count)"
if ($skipped.Count) {
    Write-Host 'Skipped:'
    $skipped | ForEach-Object { Write-Host "  $_" }
}
Write-Host "Wrote $inventoryFile"
