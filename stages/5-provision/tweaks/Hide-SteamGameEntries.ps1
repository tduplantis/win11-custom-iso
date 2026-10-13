<#
.SYNOPSIS
    Keeps Steam games out of Installed apps and off the desktop.

.DESCRIPTION
    Steam registers every installed game as its own entry under the Uninstall
    registry key and can drop a steam:// shortcut on the desktop. Steam has no
    setting to turn the registry entries off, and they are written by a SYSTEM
    service, so they cannot be blocked without breaking other installers.
    Instead this script cleans up after Steam:

      - marks each "Steam App <id>" uninstall entry as a system component,
        which hides it from Settings > Installed apps and Programs and
        Features (the entry is still there, so Steam is unaffected)
      - deletes .url shortcuts that point at steam://rungameid/ from every
        user's desktop and the public desktop

    Games remain installed and are launched, updated and removed from Steam.

    -Register installs a scheduled task (SYSTEM, at logon and every 15
    minutes) that repeats the cleanup. Requires elevation.

.EXAMPLE
    .\Hide-SteamGameEntries.ps1             # clean up once
    .\Hide-SteamGameEntries.ps1 -Register   # clean up now and keep it clean
    .\Hide-SteamGameEntries.ps1 -Unregister # remove the task and unhide entries
#>
[CmdletBinding()]
param(
    [switch]$Register,
    [switch]$Unregister
)

$ErrorActionPreference = 'Stop'
$taskName = 'Hide Steam game entries'
$installDir = Join-Path $env:ProgramData 'Win11CustomIso'
$uninstallRoots = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
                  'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'

function Get-SteamEntries {
    Get-ChildItem $uninstallRoots -ErrorAction SilentlyContinue | Where-Object PSChildName -like 'Steam App *'
}

function Get-DesktopFolders {
    [Environment]::GetFolderPath('CommonDesktopDirectory')
    $profiles = Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' |
        Where-Object PSChildName -like 'S-1-5-21-*'
    foreach ($p in $profiles) {
        $profileDir = (Get-ItemProperty $p.PSPath).ProfileImagePath
        Join-Path $profileDir 'Desktop'
        # A redirected desktop (e.g. OneDrive) is only visible while the user's hive is loaded
        $shell = Get-Item "Registry::HKEY_USERS\$($p.PSChildName)\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" -ErrorAction SilentlyContinue
        if ($shell) {
            $raw = $shell.GetValue('Desktop', $null, 'DoNotExpandEnvironmentNames')
            if ($raw) { $raw -replace '%USERPROFILE%', $profileDir.Replace('$', '$$') }
        }
    }
}

if ($Unregister) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Get-SteamEntries | ForEach-Object { Remove-ItemProperty $_.PSPath -Name SystemComponent -ErrorAction SilentlyContinue }
    Remove-Item (Join-Path $installDir (Split-Path $PSCommandPath -Leaf)) -ErrorAction SilentlyContinue
    return
}

Get-SteamEntries | ForEach-Object { Set-ItemProperty $_.PSPath -Name SystemComponent -Value 1 -Type DWord }

Get-DesktopFolders | Sort-Object -Unique | Where-Object { Test-Path $_ -ErrorAction SilentlyContinue } | ForEach-Object {
    Get-ChildItem $_ -Filter *.url -File -ErrorAction SilentlyContinue |
        Where-Object { Select-String -Path $_.FullName -Pattern '^URL=steam://rungameid/' -Quiet } |
        Remove-Item -Force
}

if ($Register) {
    New-Item -ItemType Directory -Force $installDir | Out-Null
    $script = Join-Path $installDir (Split-Path $PSCommandPath -Leaf)
    if ($PSCommandPath -ne $script) { Copy-Item $PSCommandPath $script -Force }

    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`""
    $triggers = (New-ScheduledTaskTrigger -AtLogOn),
                (New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 15))
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $triggers -Principal $principal -Force | Out-Null
}
