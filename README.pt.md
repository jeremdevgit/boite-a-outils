<p align="center"><img src="captures/icone-windows.png" width="112" alt=""> <img src="captures/icone-macos.png" width="112" alt=""></p>

<h1 align="center">Boîte à outils</h1>

<p align="center"><b>Cuide do seu computador sem estragar nada: limpeza, arranque, hardware, sensores, pesquisa de ficheiros — tudo pode ser desfeito.</b></p>

<p align="center"><img src="https://img.shields.io/badge/%F0%9F%9B%A0%EF%B8%8F%20System%20%26%20hardware-Windows%20%C2%B7%20macOS-2f6fde?style=flat-square" alt="Sistema e hardware"> <a href="https://github.com/jeremdevgit/boite-a-outils/releases"><img src="https://img.shields.io/github/v/release/jeremdevgit/boite-a-outils?include_prereleases&style=flat-square&label=version" alt="version"></a> <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL--3.0--or--later-555?style=flat-square" alt="GPL-3.0-or-later"></a> <a href="https://github.com/jeremdevgit/boite-a-outils/actions/workflows/windows.yml"><img src="https://github.com/jeremdevgit/boite-a-outils/actions/workflows/windows.yml/badge.svg" alt="CI"></a></p>

<p align="center"><a href="README.md">English</a> · <a href="README.fr.md">Français</a> · <a href="README.es.md">Español</a> · <a href="README.de.md">Deutsch</a> · <a href="README.it.md">Italiano</a> · <b>Português</b> · <a href="README.zh.md">简体中文</a> · <a href="README.ja.md">日本語</a></p>

<p align="center"><a href="https://github.com/jeremdevgit/boite-a-outils/releases/latest"><b>⬇ Transferir</b></a></p>

![Boîte à outils no Windows](captures/en/windows-accueil.png)

A Boîte à outils explica cada definição em palavras simples, não altera nada sem o seu consentimento e regista cada alteração num **Histórico** que se desfaz com um clique. Este repositório reúne duas aplicações nativas: uma para **Windows 10/11** ([`windows/`](windows/), Rust + WebView2) e outra para **macOS 14+** ([`macos/`](macos/), Swift + SwiftUI).

## Em resumo

| | |
|---|---|
| **Categoria** | 🛠️ Sistema e hardware |
| **Plataformas** | Windows · macOS |
| **Interface** | 8 idiomas (EN, FR, ES, DE, IT, PT, ZH, JA) |
| **Preço** | Gratuito, de código aberto, sem anúncios nem telemetria |
| **Estado** | Estável |
| **Licença** | [GPL-3.0-or-later](LICENSE) |

## O que faz

| Área | Windows | macOS |
|---|---|---|
| **Arranque e processos** | Programas, tarefas agendadas, serviços explicados um a um, entradas avariadas | Itens de início de sessão, agentes, processos |
| **Limpeza** | Caches do Windows, navegadores, apps e jogos; só o que é seguro vem marcado | Limpeza do sistema, privacidade dos navegadores, projetos de desenvolvimento |
| **Espaço em disco** | Ficheiros grandes, duplicados, versões antigas, instaladores esquecidos, restos | Ficheiros grandes, duplicados, desinstalação completa, restos órfãos |
| **Pesquisa de ficheiros** | Índice local por nome ou caminho, curingas, filtros de tamanho e data | O mesmo, ao estilo do Finder |
| **Hardware** | CPU, RAM, GPU, saúde SMART, ecrãs, cabos USB, controladores, sensores, testes de estabilidade | Sensores, discos, ecrãs, bateria, cabos e portas USB-C |
| **Definições** | Ajustes documentados e reversíveis (jogos, energia, Explorador, privacidade, anúncios) | Definições ocultas, interruptores, janelas, área de transferência, rede |
| **Reparação** | Pontos de restauro, SFC/DISM, Sysinternals, apps essenciais via winget | Manutenção, atualizações, segurança |

<p><img src="captures/en/windows-nettoyage.png" alt="Limpeza" width="49%"> <img src="captures/en/windows-recherche.png" alt="Pesquisa de ficheiros" width="49%"></p>
<p><img src="captures/en/macos-capteurs.png" alt="Sensores no macOS" width="49%"> <img src="captures/en/macos-interrupteurs-sombre.png" alt="Interruptores, modo escuro" width="49%"></p>

A pesquisa cria um índice local da pasta ou unidade escolhida (a primeira análise pode demorar alguns minutos), mostra até 500 resultados e nunca envia caminhos nem conteúdos para a Internet. Os módulos do macOS estão descritos em [`macos/README.md`](macos/README.md) (em francês).

## Instalar

**Windows** — transfira `BoiteAOutils-Setup.exe` da [versão mais recente](https://github.com/jeremdevgit/boite-a-outils/releases/latest) e execute-o. Uma versão já instalada é detetada e substituída automaticamente; histórico, cópias de segurança e definições mantêm-se. Instalação silenciosa: `BoiteAOutils-Setup.exe /S`. O executável não está assinado com um certificado pago: se o SmartScreen aparecer, escolha **Mais informações › Executar mesmo assim**. Verifique com `Get-FileHash` e `SHA256SUMS-windows.txt`.

**macOS** — o `.pkg` (recomendado) fecha e substitui a versão anterior; o `.dmg` instala-se arrastando. A app não está notarizada: na primeira vez, **clique direito › Abrir**. Depois conceda o *Acesso total ao disco* (a página **Permissões** guia-o). Verificação: `shasum -a 256 -c SHA256SUMS-macos.txt --ignore-missing`.

## Segurança e privacidade

- **Sem telemetria, sem conta, sem anúncios.** Tudo é analisado no computador.
- **Nada muda sem confirmação.** O que apagar vai para a Reciclagem / Lixo sempre que possível; no Windows é proposto um ponto de restauro antes da primeira alteração.
- Instalada numa pasta que só os administradores podem alterar; DLL do sistema carregadas apenas de System32; ligações externas abertas com os seus direitos, nunca como administrador.
- Serviços online só quando pede: catálogo do Microsoft Update, live.sysinternals.com, winget, sites dos fabricantes, VirusTotal (hash de um ficheiro, macOS), api.ipify.org e `networkQuality` da Apple (macOS).

## Compilar

```powershell
# Windows — Rust estável + Visual Studio Build Tools (C++)
cd windows
cargo build --release
.\tools\release.ps1          # instalador distribuído + verificações
```

```sh
# macOS 14+ — Xcode ou Command Line Tools
cd macos
./build.sh                   # app universal (Apple Silicon + Intel)
./make_installer.sh          # .pkg, .dmg e somas de verificação
./Tests/run_tests.sh
```

As versões publicadas são compiladas pelo GitHub Actions ([`windows.yml`](.github/workflows/windows.yml)).

## Licença

GNU GPL v3 ou posterior — ver [LICENSE](LICENSE). Componentes de terceiros em [`licences-tiers/`](licences-tiers/): módulos [PawnIO](https://github.com/namazso/PawnIO.Modules) (LGPL-2.1, sensores no Windows) e código USB Power Delivery / SMC adaptado do WhatCable (MIT, macOS).

---

Encontrou uma vulnerabilidade? Comunique-a em privado (consulte [SECURITY.md](SECURITY.md)) e não num issue público.

## Mais software livre de jeremdevgit

Todos gratuitos, de código aberto e sem anúncios.

**🛠️ Sistema e hardware** — [rJb](https://github.com/jeremdevgit/rjb) · [LJ Hub](https://github.com/jeremdevgit/lj-hub) · [Decklight](https://github.com/jeremdevgit/decklight)

**📒 Produtividade e dados** — [Carnet de notes](https://github.com/jeremdevgit/carnet-rust) · [JMeca](https://github.com/jeremdevgit/jmeca) · [Suite Libre](https://jeremdevgit.github.io/suite-libre/)

**🎮 Música e jogos** — [Pomme](https://github.com/jeremdevgit/pomme) · [Ludothèque](https://github.com/jeremdevgit/ludotheque) · [AutoDex](https://github.com/jeremdevgit/autodex) · [Batailles de France](https://github.com/jeremdevgit/batailles-de-france)
