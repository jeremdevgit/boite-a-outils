<p align="center"><img src="captures/icone-windows.png" width="112" alt=""> <img src="captures/icone-macos.png" width="112" alt=""></p>

<h1 align="center">Boîte à outils</h1>

<p align="center"><b>Look after your computer without breaking anything: cleanup, startup, hardware, sensors, file search — every change can be undone.</b></p>

<p align="center"><img src="https://img.shields.io/badge/%F0%9F%9B%A0%EF%B8%8F%20System%20%26%20hardware-Windows%20%C2%B7%20macOS-2f6fde?style=flat-square" alt="System & hardware"> <a href="https://github.com/jeremdevgit/boite-a-outils/releases"><img src="https://img.shields.io/github/v/release/jeremdevgit/boite-a-outils?include_prereleases&style=flat-square&label=version" alt="version"></a> <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL--3.0--or--later-555?style=flat-square" alt="GPL-3.0-or-later"></a> <a href="https://github.com/jeremdevgit/boite-a-outils/actions/workflows/windows.yml"><img src="https://github.com/jeremdevgit/boite-a-outils/actions/workflows/windows.yml/badge.svg" alt="CI"></a></p>

<p align="center"><b>English</b> · <a href="README.fr.md">Français</a> · <a href="README.es.md">Español</a> · <a href="README.de.md">Deutsch</a> · <a href="README.it.md">Italiano</a> · <a href="README.pt.md">Português</a> · <a href="README.zh.md">简体中文</a> · <a href="README.ja.md">日本語</a></p>

<p align="center"><a href="https://github.com/jeremdevgit/boite-a-outils/releases/latest"><b>⬇ Download</b></a></p>

![Boîte à outils on Windows](captures/en/windows-accueil.png)

Boîte à outils explains every setting in plain words, changes nothing without your consent and logs every change in a **History** you can undo in one click. Two native apps live in this repository: one for **Windows 10/11** ([`windows/`](windows/), Rust + WebView2) and one for **macOS 14+** ([`macos/`](macos/), Swift + SwiftUI).

## At a glance

| | |
|---|---|
| **Category** | 🛠️ System & hardware |
| **Platforms** | Windows · macOS |
| **Interface** | 8 languages (EN, FR, ES, DE, IT, PT, ZH, JA) |
| **Price** | Free, open source, no ads, no telemetry |
| **Status** | Stable |
| **License** | [GPL-3.0-or-later](LICENSE) |

## What it does

| Area | Windows | macOS |
|---|---|---|
| **Startup & processes** | Programs, scheduled tasks, services explained one by one, broken entries | Login items, launch agents, processes |
| **Cleanup** | Windows, browser, app and game caches; safe items ticked by default | System cleanup, browser privacy, development projects |
| **Disk space** | Large files, duplicates, old app versions, forgotten installers, leftovers | Large files, duplicates, complete uninstaller, orphaned leftovers |
| **File search** | Local index by name or path, wildcards, size/date filters | Same, in Finder style |
| **Hardware** | CPU, RAM, GPU, SMART health, displays, USB cables, drivers, sensors, stability tests | Sensors, drives, displays, battery, USB-C cables and ports |
| **Settings** | Documented, reversible tweaks (games, power, Explorer, privacy, ads) | Hidden settings, switches, window tiling, clipboard, network |
| **Repair** | Restore points, SFC/DISM, Sysinternals, essential apps via winget | Maintenance, updates, security checks |

<p><img src="captures/en/windows-nettoyage.png" alt="Cleanup" width="49%"> <img src="captures/en/windows-recherche.png" alt="File search" width="49%"></p>
<p><img src="captures/en/macos-capteurs.png" alt="Sensors on macOS" width="49%"> <img src="captures/en/macos-interrupteurs-sombre.png" alt="Switches, dark mode" width="49%"></p>

File search builds a local index of the folder or drive you choose (the first scan can take a few minutes), shows up to 500 matches and never sends paths or contents online. The macOS modules are detailed in [`macos/README.md`](macos/README.md) (in French).

## Install

**Windows** — download `BoiteAOutils-Setup.exe` from the [latest release](https://github.com/jeremdevgit/boite-a-outils/releases/latest) and run it. An installed version is detected and replaced automatically; history, backups and settings are kept. Silent install: `BoiteAOutils-Setup.exe /S`. The executable is not signed with a paid certificate: if SmartScreen appears, choose **More info › Run anyway**. Check it with `Get-FileHash` against `SHA256SUMS-windows.txt`.

**macOS** — the `.pkg` (recommended) closes and replaces the previous version; the `.dmg` is a classic drag-and-drop. The app is not notarized: the first time, **right-click › Open**. Then grant *Full Disk Access* (the **Permissions** page guides you). Check with `shasum -a 256 -c SHA256SUMS-macos.txt --ignore-missing`.

## Safety and privacy

- **No telemetry, no account, no ads.** Everything is analyzed on the computer.
- **Nothing changes without confirmation.** Deletions go to the Recycle Bin / Trash when possible; a restore point is offered before the first change on Windows.
- Installed in a folder only administrators can modify; system DLLs loaded only from System32; external links opened with your rights, never as administrator.
- Online services are contacted only when you ask: Microsoft Update catalog, live.sysinternals.com, winget, manufacturers' sites, VirusTotal (a file hash, macOS), api.ipify.org and Apple's `networkQuality` (macOS).

## Build from source

```powershell
# Windows — Rust stable + Visual Studio Build Tools (C++)
cd windows
cargo build --release
.\tools\release.ps1          # distributed installer + checks
```

```sh
# macOS 14+ — Xcode or Command Line Tools
cd macos
./build.sh                   # universal app (Apple Silicon + Intel)
./make_installer.sh          # .pkg, .dmg and checksums
./Tests/run_tests.sh
```

Releases are built by GitHub Actions ([`windows.yml`](.github/workflows/windows.yml)).

## License

GNU GPL v3 or later — see [LICENSE](LICENSE). Third-party components in [`licences-tiers/`](licences-tiers/): [PawnIO](https://github.com/namazso/PawnIO.Modules) modules (LGPL-2.1, Windows sensors) and USB Power Delivery / SMC code adapted from WhatCable (MIT, macOS).

---

Found a vulnerability? Please report it privately (see [SECURITY.md](SECURITY.md)) rather than in a public issue.

## More free software by jeremdevgit

All free, open source and ad-free.

**🛠️ System & hardware** — [rJb](https://github.com/jeremdevgit/rjb) · [LJ Hub](https://github.com/jeremdevgit/lj-hub) · [Decklight](https://github.com/jeremdevgit/decklight)

**📒 Productivity & data** — [Carnet de notes](https://github.com/jeremdevgit/carnet-rust) · [JMeca](https://github.com/jeremdevgit/jmeca) · [Suite Libre](https://jeremdevgit.github.io/suite-libre/)

**🎮 Music & games** — [Pomme](https://github.com/jeremdevgit/pomme) · [Ludothèque](https://github.com/jeremdevgit/ludotheque) · [AutoDex](https://github.com/jeremdevgit/autodex) · [Batailles de France](https://github.com/jeremdevgit/batailles-de-france)
