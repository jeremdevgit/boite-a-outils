// SPDX-License-Identifier: GPL-3.0-or-later — Copyright (C) 2026 jeremdevgit — voir LICENSE
//! Langue des quelques textes affichés par Windows lui-même (messages de démarrage, titre et
//! dossier de l'installateur, raccourcis, Paramètres › Applications) : celle de Windows au
//! lancement, puis celle choisie dans l'interface. Anglais si la langue n'est pas proposée.
use std::sync::atomic::{AtomicUsize, Ordering};

const CODES: [&str; 8] = ["fr", "en", "es", "de", "it", "pt", "zh", "ja"];
static LANGUE: AtomicUsize = AtomicUsize::new(1);

/// Langue d'affichage de Windows.
pub fn depuis_windows() {
    let id = unsafe { windows_sys::Win32::Globalization::GetUserDefaultUILanguage() } & 0x3ff;
    let code = match id {
        0x0c => "fr",
        0x0a => "es",
        0x07 => "de",
        0x10 => "it",
        0x16 => "pt",
        0x04 => "zh",
        0x11 => "ja",
        _ => "en",
    };
    definir(code);
}

/// Change la langue ; renvoie vrai si elle a changé.
pub fn definir(code: &str) -> bool {
    match CODES.iter().position(|c| *c == code) {
        Some(i) => LANGUE.swap(i, Ordering::Relaxed) != i,
        None => false,
    }
}

/// Texte dans la langue choisie (le français sert de clé).
pub fn tr(fr: &'static str) -> &'static str {
    let i = LANGUE.load(Ordering::Relaxed);
    if i == 0 {
        return fr;
    }
    TEXTES.iter().find(|t| t[0] == fr).map_or(fr, |t| t[i])
}

#[rustfmt::skip]
const TEXTES: &[[&str; 8]] = &[
    ["La Boîte à outils a rencontré un problème et doit se fermer.", "Boîte à outils ran into a problem and has to close.", "Boîte à outils ha encontrado un problema y debe cerrarse.", "Boîte à outils hat ein Problem festgestellt und muss beendet werden.", "Boîte à outils ha riscontrato un problema e deve chiudersi.", "O Boîte à outils encontrou um problema e precisa fechar.", "Boîte à outils 遇到问题，需要关闭。", "Boîte à outils で問題が発生したため、終了します。"],
    ["La Boîte à outils a besoin de « Microsoft Edge WebView2 », un composant gratuit de Windows, absent de ce PC.\n\nLe télécharger et l'installer maintenant depuis le site de Microsoft ? Une connexion Internet est nécessaire, et cela peut prendre quelques minutes sans rien afficher.",
     "Boîte à outils needs “Microsoft Edge WebView2”, a free Windows component that is missing on this PC.\n\nDownload and install it now from Microsoft's website? An Internet connection is required, and it may take a few minutes without showing anything.",
     "Boîte à outils necesita «Microsoft Edge WebView2», un componente gratuito de Windows que falta en este PC.\n\n¿Descargarlo e instalarlo ahora desde el sitio de Microsoft? Se necesita conexión a Internet y puede tardar unos minutos sin mostrar nada.",
     "Boîte à outils benötigt „Microsoft Edge WebView2“, eine kostenlose Windows-Komponente, die auf diesem PC fehlt.\n\nJetzt von der Microsoft-Website herunterladen und installieren? Eine Internetverbindung ist nötig, und es kann einige Minuten dauern, ohne dass etwas angezeigt wird.",
     "Boîte à outils ha bisogno di «Microsoft Edge WebView2», un componente gratuito di Windows assente su questo PC.\n\nScaricarlo e installarlo ora dal sito di Microsoft? Serve una connessione a Internet e potrebbero volerci alcuni minuti senza che venga mostrato nulla.",
     "O Boîte à outils precisa do “Microsoft Edge WebView2”, um componente gratuito do Windows que não está neste PC.\n\nBaixar e instalar agora pelo site da Microsoft? É preciso ter conexão com a Internet, e pode levar alguns minutos sem mostrar nada.",
     "Boîte à outils 需要“Microsoft Edge WebView2”，这是一个免费的 Windows 组件，此电脑上缺少它。\n\n现在从 Microsoft 网站下载并安装吗？需要连接互联网，可能需要几分钟且不显示任何内容。",
     "Boîte à outils には、この PC にない無料の Windows コンポーネント「Microsoft Edge WebView2」が必要です。\n\n今すぐ Microsoft の Web サイトからダウンロードしてインストールしますか？インターネット接続が必要で、何も表示されないまま数分かかることがあります。"],
    ["installation non terminée", "installation not finished", "instalación no terminada", "Installation nicht abgeschlossen", "installazione non completata", "instalação não concluída", "安装未完成", "インストールが完了していません"],
    ["WebView2 n'a pas pu être installé :", "WebView2 could not be installed:", "No se pudo instalar WebView2:", "WebView2 konnte nicht installiert werden:", "Impossibile installare WebView2:", "Não foi possível instalar o WebView2:", "无法安装 WebView2：", "WebView2 をインストールできませんでした："],
    ["La page de téléchargement de Microsoft va s'ouvrir : installez le « Bootstrapper » ou le « Standalone Installer », puis relancez la Boîte à outils.", "Microsoft's download page will open: install the “Bootstrapper” or the “Standalone Installer”, then restart Boîte à outils.", "Se abrirá la página de descarga de Microsoft: instala el «Bootstrapper» o el «Standalone Installer» y vuelve a abrir Boîte à outils.", "Die Downloadseite von Microsoft wird geöffnet: Installieren Sie den „Bootstrapper“ oder den „Standalone Installer“ und starten Sie Boîte à outils neu.", "Si aprirà la pagina di download di Microsoft: installa il «Bootstrapper» o lo «Standalone Installer», poi riavvia Boîte à outils.", "A página de download da Microsoft vai abrir: instale o “Bootstrapper” ou o “Standalone Installer” e abra o Boîte à outils de novo.", "将打开 Microsoft 下载页面：请安装“Bootstrapper”或“Standalone Installer”，然后重新启动 Boîte à outils。", "Microsoft のダウンロード ページが開きます。「Bootstrapper」または「Standalone Installer」をインストールしてから、Boîte à outils を起動し直してください。"],
    ["L'interface n'a pas pu démarrer :", "The interface could not start:", "La interfaz no pudo iniciarse:", "Die Oberfläche konnte nicht starten:", "Impossibile avviare l'interfaccia:", "A interface não pôde iniciar:", "界面无法启动：", "インターフェイスを起動できませんでした："],
    ["Réparez « Microsoft Edge WebView2 Runtime » depuis Paramètres > Applications, ou réinstallez-le depuis la page qui va s'ouvrir, puis relancez la Boîte à outils.", "Repair “Microsoft Edge WebView2 Runtime” from Settings > Apps, or reinstall it from the page that will open, then restart Boîte à outils.", "Repara «Microsoft Edge WebView2 Runtime» desde Configuración > Aplicaciones, o reinstálalo desde la página que se abrirá, y vuelve a abrir Boîte à outils.", "Reparieren Sie „Microsoft Edge WebView2 Runtime“ unter Einstellungen > Apps oder installieren Sie es über die sich öffnende Seite neu und starten Sie Boîte à outils neu.", "Ripara «Microsoft Edge WebView2 Runtime» da Impostazioni > App, oppure reinstallalo dalla pagina che si aprirà, poi riavvia Boîte à outils.", "Repare o “Microsoft Edge WebView2 Runtime” em Configurações > Aplicativos, ou reinstale pela página que vai abrir, e abra o Boîte à outils de novo.", "请在“设置 > 应用”中修复“Microsoft Edge WebView2 Runtime”，或从将打开的页面重新安装，然后重新启动 Boîte à outils。", "[設定] > [アプリ] で「Microsoft Edge WebView2 Runtime」を修復するか、開くページから再インストールしてから、Boîte à outils を起動し直してください。"],
    ["L'installation de la Boîte à outils demande les droits administrateur : elle s'installe pour tout le PC, dans un dossier protégé.", "Installing Boîte à outils requires administrator rights: it installs for the whole PC, in a protected folder.", "La instalación de Boîte à outils requiere permisos de administrador: se instala para todo el PC, en una carpeta protegida.", "Die Installation von Boîte à outils erfordert Administratorrechte: Sie erfolgt für den ganzen PC in einem geschützten Ordner.", "L'installazione di Boîte à outils richiede i diritti di amministratore: si installa per tutto il PC, in una cartella protetta.", "A instalação do Boîte à outils exige permissões de administrador: ele é instalado para todo o PC, em uma pasta protegida.", "安装 Boîte à outils 需要管理员权限：它会为整台电脑安装到受保护的文件夹中。", "Boîte à outils のインストールには管理者権限が必要です。PC 全体を対象に、保護されたフォルダーにインストールされます。"],
    ["Relancez l'installateur et acceptez l'invite de Windows.", "Run the installer again and accept the Windows prompt.", "Vuelve a ejecutar el instalador y acepta el aviso de Windows.", "Starten Sie das Installationsprogramm erneut und bestätigen Sie die Windows-Abfrage.", "Riavvia il programma di installazione e accetta la richiesta di Windows.", "Execute o instalador de novo e aceite o aviso do Windows.", "请重新运行安装程序并接受 Windows 提示。", "インストーラーをもう一度実行し、Windows の確認を許可してください。"],
    ["Installer la Boîte à outils", "Install Boîte à outils", "Instalar Boîte à outils", "Boîte à outils installieren", "Installa Boîte à outils", "Instalar o Boîte à outils", "安装 Boîte à outils", "Boîte à outils をインストール"],
    ["Boîte à outils — désinstaller ou réparer", "Boîte à outils — uninstall or repair", "Boîte à outils: desinstalar o reparar", "Boîte à outils – deinstallieren oder reparieren", "Boîte à outils — disinstalla o ripara", "Boîte à outils — desinstalar ou reparar", "Boîte à outils — 卸载或修复", "Boîte à outils — アンインストールまたは修復"],
    ["Dossier d'installation de la Boîte à outils", "Boîte à outils installation folder", "Carpeta de instalación de Boîte à outils", "Installationsordner von Boîte à outils", "Cartella di installazione di Boîte à outils", "Pasta de instalação do Boîte à outils", "Boîte à outils 安装文件夹", "Boîte à outils のインストール先フォルダー"],
    ["Démarrage, services, nettoyage et entretien de Windows", "Windows startup, services, cleanup and maintenance", "Inicio, servicios, limpieza y mantenimiento de Windows", "Autostart, Dienste, Bereinigung und Wartung von Windows", "Avvio, servizi, pulizia e manutenzione di Windows", "Inicialização, serviços, limpeza e manutenção do Windows", "Windows 启动项、服务、清理与维护", "Windows のスタートアップ、サービス、クリーンアップ、メンテナンス"],
    ["Démarrage, services, nettoyage et entretien de Windows, sans rien casser", "Windows startup, services, cleanup and maintenance, without breaking anything", "Inicio, servicios, limpieza y mantenimiento de Windows, sin romper nada", "Autostart, Dienste, Bereinigung und Wartung von Windows, ohne etwas kaputt zu machen", "Avvio, servizi, pulizia e manutenzione di Windows, senza rompere nulla", "Inicialização, serviços, limpeza e manutenção do Windows, sem quebrar nada", "Windows 启动项、服务、清理与维护，绝不搞坏系统", "何も壊さずに、Windows のスタートアップ、サービス、クリーンアップ、メンテナンス"],
];
