# Win11 Custom ISO

A staged pipeline that turns any Windows 11 PC into a repeatable, unattended
rebuild: inventory the machine, pick what to keep, build a trimmed and fully
patched ISO from official Microsoft media, and have apps install themselves on
first boot.

Each stage is a standalone script that reads the previous stage's output from
`profiles\<name>\`. Profiles describe a real machine and are git-ignored.

| Stage | Purpose | Status |
|-------|---------|--------|
| 1 Discover  | Read-only inventory of the current PC | ready |
| 2 Curate    | Turn the inventory into a keep/drop manifest | ready |
| 3 Build     | Official ISO + updates + drivers + conservative debloat | planned |
| 4 Unattend  | Generate `autounattend.xml` (no secrets) | planned |
| 5 Provision | First-boot app install and settings | tweaks only |
| 6 Maintain  | Keep apps patched; rebuild the ISO monthly | planned |
| 7 Validate  | Test-install each ISO in a Hyper-V VM | planned |

## Stage 1

```powershell
.\stages\1-discover\Invoke-Discovery.ps1
```

Changes nothing on the system. Run elevated to also capture TPM state and
enabled optional features. Output: `profiles\<COMPUTERNAME>\inventory.json`
and `winget-export.json`.

## Stage 2

```powershell
.\stages\2-curate\New-Manifest.ps1
```

Writes `profiles\<COMPUTERNAME>\manifest.json`, the one file you edit. Apps
matched to a winget package are marked `install`; everything else found on the
PC is marked `review` for you to decide. Runtimes, inbox components, drivers
and games are skipped. Disks other than the system disk are listed under
`disks.preserve`, and setup always stops at the disk picker rather than
choosing a disk itself.

## Tweaks

Optional behaviours switched on per profile under `tweaks` in the manifest.

| Tweak | What it does |
|-------|--------------|
| `hideSteamGameEntries` | Hides Steam's per-game entries from Installed apps and removes Steam game shortcuts from the desktop, via [Hide-SteamGameEntries.ps1](stages/5-provision/tweaks/Hide-SteamGameEntries.ps1) |

## Principles

- Official Microsoft media only; you supply the ISO.
- Nothing is removed that Windows Update, Defender, Secure Boot, TPM or VBS
  depend on, so cumulative updates and game anti-cheat keep working.
- No passwords, product keys or tokens are ever written to the repo or the ISO.
