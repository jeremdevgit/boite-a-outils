<p align="center"><img src="captures/icone-windows.png" width="112" alt=""> <img src="captures/icone-macos.png" width="112" alt=""></p>

<h1 align="center">Boîte à outils</h1>

<p align="center"><b>Cuida tu ordenador sin romper nada: limpieza, arranque, hardware, sensores, búsqueda de archivos; todo se puede deshacer.</b></p>

<p align="center"><img src="https://img.shields.io/badge/%F0%9F%9B%A0%EF%B8%8F%20System%20%26%20hardware-Windows%20%C2%B7%20macOS-2f6fde?style=flat-square" alt="Sistema y hardware"> <a href="https://github.com/jeremdevgit/boite-a-outils/releases"><img src="https://img.shields.io/github/v/release/jeremdevgit/boite-a-outils?include_prereleases&style=flat-square&label=version" alt="version"></a> <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL--3.0--or--later-555?style=flat-square" alt="GPL-3.0-or-later"></a> <a href="https://github.com/jeremdevgit/boite-a-outils/actions/workflows/windows.yml"><img src="https://github.com/jeremdevgit/boite-a-outils/actions/workflows/windows.yml/badge.svg" alt="CI"></a></p>

<p align="center"><a href="README.md">English</a> · <a href="README.fr.md">Français</a> · <b>Español</b> · <a href="README.de.md">Deutsch</a> · <a href="README.it.md">Italiano</a> · <a href="README.pt.md">Português</a> · <a href="README.zh.md">简体中文</a> · <a href="README.ja.md">日本語</a></p>

<p align="center"><a href="https://github.com/jeremdevgit/boite-a-outils/releases/latest"><b>⬇ Descargar</b></a></p>

![Boîte à outils en Windows](captures/en/windows-accueil.png)

Boîte à outils explica cada ajuste con palabras sencillas, no cambia nada sin tu permiso y anota cada cambio en un **Historial** que se deshace con un clic. En este repositorio hay dos aplicaciones nativas: una para **Windows 10/11** ([`windows/`](windows/), Rust + WebView2) y otra para **macOS 14+** ([`macos/`](macos/), Swift + SwiftUI).

## De un vistazo

| | |
|---|---|
| **Categoría** | 🛠️ Sistema y hardware |
| **Plataformas** | Windows · macOS |
| **Interfaz** | 8 idiomas (EN, FR, ES, DE, IT, PT, ZH, JA) |
| **Precio** | Gratis, de código abierto, sin anuncios ni telemetría |
| **Estado** | Estable |
| **Licencia** | [GPL-3.0-or-later](LICENSE) |

## Qué hace

| Área | Windows | macOS |
|---|---|---|
| **Arranque y procesos** | Programas, tareas programadas, servicios explicados uno a uno, entradas rotas | Elementos de inicio, agentes, procesos |
| **Limpieza** | Cachés de Windows, navegadores, apps y juegos; solo se marca lo seguro | Limpieza del sistema, privacidad del navegador, proyectos de desarrollo |
| **Espacio en disco** | Archivos grandes, duplicados, versiones antiguas, instaladores olvidados, restos | Archivos grandes, duplicados, desinstalador completo, restos huérfanos |
| **Búsqueda de archivos** | Índice local por nombre o ruta, comodines, filtros de tamaño y fecha | Igual, al estilo Finder |
| **Hardware** | CPU, RAM, GPU, salud SMART, pantallas, cables USB, controladores, sensores, pruebas de estabilidad | Sensores, discos, pantallas, batería, cables y puertos USB-C |
| **Ajustes** | Ajustes documentados y reversibles (juegos, energía, Explorador, privacidad, anuncios) | Ajustes ocultos, interruptores, ventanas, portapapeles, red |
| **Reparación** | Puntos de restauración, SFC/DISM, Sysinternals, apps esenciales con winget | Mantenimiento, actualizaciones, seguridad |

<p><img src="captures/en/windows-nettoyage.png" alt="Limpieza" width="49%"> <img src="captures/en/windows-recherche.png" alt="Búsqueda de archivos" width="49%"></p>
<p><img src="captures/en/macos-capteurs.png" alt="Sensores en macOS" width="49%"> <img src="captures/en/macos-interrupteurs-sombre.png" alt="Interruptores, modo oscuro" width="49%"></p>

La búsqueda crea un índice local de la carpeta o unidad elegida (el primer análisis puede tardar unos minutos), muestra hasta 500 resultados y nunca envía rutas ni contenidos a Internet. Los módulos de macOS se detallan en [`macos/README.md`](macos/README.md) (en francés).

## Instalar

**Windows**: descarga `BoiteAOutils-Setup.exe` de la [última versión](https://github.com/jeremdevgit/boite-a-outils/releases/latest) y ejecútalo. Una versión ya instalada se detecta y se reemplaza automáticamente; se conservan historial, copias y ajustes. Instalación silenciosa: `BoiteAOutils-Setup.exe /S`. El ejecutable no está firmado con un certificado de pago: si aparece SmartScreen, elige **Más información › Ejecutar de todas formas**. Compruébalo con `Get-FileHash` y `SHA256SUMS-windows.txt`.

**macOS**: el `.pkg` (recomendado) cierra y reemplaza la versión anterior; el `.dmg` se instala arrastrando. La app no está notarizada: la primera vez, **clic derecho › Abrir**. Después concede el *Acceso total al disco* (la página **Permisos** te guía). Comprobación: `shasum -a 256 -c SHA256SUMS-macos.txt --ignore-missing`.

## Seguridad y privacidad

- **Sin telemetría, sin cuenta, sin anuncios.** Todo se analiza en el ordenador.
- **Nada cambia sin confirmación.** Lo eliminado va a la Papelera cuando es posible; en Windows se ofrece un punto de restauración antes del primer cambio.
- Instalada en una carpeta que solo pueden modificar los administradores; DLL del sistema cargadas solo desde System32; enlaces externos abiertos con tus permisos, nunca como administrador.
- Servicios en línea solo cuando lo pides: catálogo de Microsoft Update, live.sysinternals.com, winget, webs de fabricantes, VirusTotal (hash de un archivo, macOS), api.ipify.org y `networkQuality` de Apple (macOS).

## Compilar

```powershell
# Windows — Rust estable + Visual Studio Build Tools (C++)
cd windows
cargo build --release
.\tools\release.ps1          # instalador distribuido + comprobaciones
```

```sh
# macOS 14+ — Xcode o Command Line Tools
cd macos
./build.sh                   # app universal (Apple Silicon + Intel)
./make_installer.sh          # .pkg, .dmg y sumas de control
./Tests/run_tests.sh
```

Las versiones publicadas se compilan con GitHub Actions ([`windows.yml`](.github/workflows/windows.yml)).

## Licencia

GNU GPL v3 o posterior — ver [LICENSE](LICENSE). Componentes de terceros en [`licences-tiers/`](licences-tiers/): módulos [PawnIO](https://github.com/namazso/PawnIO.Modules) (LGPL-2.1, sensores en Windows) y código USB Power Delivery / SMC adaptado de WhatCable (MIT, macOS).

---

¿Has encontrado una vulnerabilidad? Infórmala en privado (consulta [SECURITY.md](SECURITY.md)) y no en una incidencia pública.

## Más software libre de jeremdevgit

Todos gratuitos, de código abierto y sin anuncios.

**🛠️ Sistema y hardware** — [rJb](https://github.com/jeremdevgit/rjb) · [LJ Hub](https://github.com/jeremdevgit/lj-hub) · [Decklight](https://github.com/jeremdevgit/decklight)

**📒 Productividad y datos** — [Carnet de notes](https://github.com/jeremdevgit/carnet-rust) · [JMeca](https://github.com/jeremdevgit/jmeca) · [Suite Libre](https://jeremdevgit.github.io/suite-libre/)

**🎮 Música y juegos** — [Pomme](https://github.com/jeremdevgit/pomme) · [Ludothèque](https://github.com/jeremdevgit/ludotheque) · [AutoDex](https://github.com/jeremdevgit/autodex) · [Batailles de France](https://github.com/jeremdevgit/batailles-de-france)
