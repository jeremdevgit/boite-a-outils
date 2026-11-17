<p align="center"><img src="captures/icone-windows.png" width="112" alt=""> <img src="captures/icone-macos.png" width="112" alt=""></p>

<h1 align="center">Boîte à outils</h1>

<p align="center"><b>Den Computer pflegen, ohne etwas kaputt zu machen: Bereinigung, Autostart, Hardware, Sensoren, Dateisuche – alles rückgängig machbar.</b></p>

<p align="center"><img src="https://img.shields.io/badge/%F0%9F%9B%A0%EF%B8%8F%20System%20%26%20hardware-Windows%20%C2%B7%20macOS-2f6fde?style=flat-square" alt="System & Hardware"> <a href="https://github.com/jeremdevgit/boite-a-outils/releases"><img src="https://img.shields.io/github/v/release/jeremdevgit/boite-a-outils?include_prereleases&style=flat-square&label=version" alt="version"></a> <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL--3.0--or--later-555?style=flat-square" alt="GPL-3.0-or-later"></a> <a href="https://github.com/jeremdevgit/boite-a-outils/actions/workflows/windows.yml"><img src="https://github.com/jeremdevgit/boite-a-outils/actions/workflows/windows.yml/badge.svg" alt="CI"></a></p>

<p align="center"><a href="README.md">English</a> · <a href="README.fr.md">Français</a> · <a href="README.es.md">Español</a> · <b>Deutsch</b> · <a href="README.it.md">Italiano</a> · <a href="README.pt.md">Português</a> · <a href="README.zh.md">简体中文</a> · <a href="README.ja.md">日本語</a></p>

<p align="center"><a href="https://github.com/jeremdevgit/boite-a-outils/releases/latest"><b>⬇ Herunterladen</b></a></p>

![Boîte à outils unter Windows](captures/en/windows-accueil.png)

Boîte à outils erklärt jede Einstellung in einfachen Worten, ändert nichts ohne deine Zustimmung und protokolliert jede Änderung in einem **Verlauf**, der sich mit einem Klick rückgängig machen lässt. Dieses Repository enthält zwei native Apps: eine für **Windows 10/11** ([`windows/`](windows/), Rust + WebView2) und eine für **macOS 14+** ([`macos/`](macos/), Swift + SwiftUI).

## Auf einen Blick

| | |
|---|---|
| **Kategorie** | 🛠️ System & Hardware |
| **Plattformen** | Windows · macOS |
| **Oberfläche** | 8 Sprachen (EN, FR, ES, DE, IT, PT, ZH, JA) |
| **Preis** | Kostenlos, quelloffen, ohne Werbung und Telemetrie |
| **Status** | Stabil |
| **Lizenz** | [GPL-3.0-or-later](LICENSE) |

## Was sie kann

| Bereich | Windows | macOS |
|---|---|---|
| **Autostart & Prozesse** | Programme, geplante Aufgaben, einzeln erklärte Dienste, defekte Einträge | Anmeldeobjekte, Launch Agents, Prozesse |
| **Bereinigung** | Caches von Windows, Browsern, Apps und Spielen; nur Unbedenkliches ist vorausgewählt | Systembereinigung, Browser-Datenschutz, Entwicklungsprojekte |
| **Speicherplatz** | Große Dateien, Duplikate, alte Versionen, vergessene Installer, Reste | Große Dateien, Duplikate, vollständiges Deinstallieren, verwaiste Reste |
| **Dateisuche** | Lokaler Index nach Name oder Pfad, Platzhalter, Größen- und Datumsfilter | Ebenso, im Finder-Stil |
| **Hardware** | CPU, RAM, GPU, SMART-Status, Bildschirme, USB-Kabel, Treiber, Sensoren, Stabilitätstests | Sensoren, Laufwerke, Bildschirme, Akku, USB-C-Kabel und -Anschlüsse |
| **Einstellungen** | Dokumentierte, umkehrbare Optimierungen (Spiele, Energie, Explorer, Datenschutz, Werbung) | Versteckte Einstellungen, Schalter, Fenster, Zwischenablage, Netzwerk |
| **Reparatur** | Wiederherstellungspunkte, SFC/DISM, Sysinternals, wichtige Apps per winget | Wartung, Updates, Sicherheit |

<p><img src="captures/en/windows-nettoyage.png" alt="Bereinigung" width="49%"> <img src="captures/en/windows-recherche.png" alt="Dateisuche" width="49%"></p>
<p><img src="captures/en/macos-capteurs.png" alt="Sensoren unter macOS" width="49%"> <img src="captures/en/macos-interrupteurs-sombre.png" alt="Schalter, dunkler Modus" width="49%"></p>

Die Dateisuche erstellt einen lokalen Index des gewählten Ordners oder Laufwerks (der erste Durchlauf kann einige Minuten dauern), zeigt bis zu 500 Treffer und sendet niemals Pfade oder Inhalte ins Internet. Die macOS-Module sind in [`macos/README.md`](macos/README.md) beschrieben (auf Französisch).

## Installation

**Windows** – lade `BoiteAOutils-Setup.exe` aus der [neuesten Version](https://github.com/jeremdevgit/boite-a-outils/releases/latest) herunter und starte es. Eine installierte Version wird erkannt und automatisch ersetzt; Verlauf, Sicherungen und Einstellungen bleiben erhalten. Stille Installation: `BoiteAOutils-Setup.exe /S`. Die Datei ist nicht mit einem kostenpflichtigen Zertifikat signiert: Wenn SmartScreen erscheint, wähle **Weitere Informationen › Trotzdem ausführen**. Prüfen mit `Get-FileHash` und `SHA256SUMS-windows.txt`.

**macOS** – das `.pkg` (empfohlen) schließt und ersetzt die vorherige Version; das `.dmg` wird per Drag & Drop installiert. Die App ist nicht notarisiert: beim ersten Mal **Rechtsklick › Öffnen**. Danach *Festplattenvollzugriff* gewähren (die Seite **Berechtigungen** führt dich). Prüfen: `shasum -a 256 -c SHA256SUMS-macos.txt --ignore-missing`.

## Sicherheit und Datenschutz

- **Keine Telemetrie, kein Konto, keine Werbung.** Alles wird auf dem Computer analysiert.
- **Nichts ändert sich ohne Bestätigung.** Gelöschtes landet nach Möglichkeit im Papierkorb; unter Windows wird vor der ersten Änderung ein Wiederherstellungspunkt angeboten.
- Installiert in einem Ordner, den nur Administratoren ändern können; System-DLLs nur aus System32; externe Links werden mit deinen Rechten geöffnet, nie als Administrator.
- Online-Dienste nur auf Anfrage: Microsoft-Update-Katalog, live.sysinternals.com, winget, Herstellerseiten, VirusTotal (Hash einer Datei, macOS), api.ipify.org und Apples `networkQuality` (macOS).

## Selbst bauen

```powershell
# Windows — Rust stable + Visual Studio Build Tools (C++)
cd windows
cargo build --release
.\tools\release.ps1          # verteilter Installer + Prüfungen
```

```sh
# macOS 14+ — Xcode oder Command Line Tools
cd macos
./build.sh                   # Universal-App (Apple Silicon + Intel)
./make_installer.sh          # .pkg, .dmg und Prüfsummen
./Tests/run_tests.sh
```

Veröffentlichte Versionen werden mit GitHub Actions gebaut ([`windows.yml`](.github/workflows/windows.yml)).

## Lizenz

GNU GPL v3 oder später – siehe [LICENSE](LICENSE). Drittkomponenten in [`licences-tiers/`](licences-tiers/): [PawnIO](https://github.com/namazso/PawnIO.Modules)-Module (LGPL-2.1, Sensoren unter Windows) und USB-Power-Delivery-/SMC-Code nach WhatCable (MIT, macOS).

---

Eine Sicherheitslücke gefunden? Bitte privat melden (siehe [SECURITY.md](SECURITY.md)), nicht in einem öffentlichen Issue.

## Weitere freie Software von jeremdevgit

Alle kostenlos, quelloffen und werbefrei.

**🛠️ System & Hardware** — [rJb](https://github.com/jeremdevgit/rjb) · [LJ Hub](https://github.com/jeremdevgit/lj-hub) · [Decklight](https://github.com/jeremdevgit/decklight)

**📒 Produktivität & Daten** — [Carnet de notes](https://github.com/jeremdevgit/carnet-rust) · [JMeca](https://github.com/jeremdevgit/jmeca) · [Suite Libre](https://jeremdevgit.github.io/suite-libre/)

**🎮 Musik & Spiele** — [Pomme](https://github.com/jeremdevgit/pomme) · [Ludothèque](https://github.com/jeremdevgit/ludotheque) · [AutoDex](https://github.com/jeremdevgit/autodex) · [Batailles de France](https://github.com/jeremdevgit/batailles-de-france)
