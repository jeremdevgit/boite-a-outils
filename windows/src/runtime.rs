// SPDX-License-Identifier: GPL-3.0-or-later — Copyright (C) 2026 jeremdevgit — voir LICENSE
//! Prérequis au lancement : moteur WebView2 présent (proposé au téléchargement
//! sinon) et message lisible si le démarrage échoue, au lieu d'une fermeture muette.

use crate::win::w;
use windows_sys::Win32::System::Registry::*;
use windows_sys::Win32::UI::WindowsAndMessaging::*;

const TITLE: &str = "Boîte à outils";
const CLIENT: &str = "Microsoft\\EdgeUpdate\\Clients\\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}";
const DOWNLOAD_PAGE: &str = "https://developer.microsoft.com/microsoft-edge/webview2/";

pub fn message(text: &str, flags: u32) -> i32 {
    let (t, c) = (w(text), w(TITLE));
    unsafe { MessageBoxW(std::ptr::null_mut(), t.as_ptr(), c.as_ptr(), flags) }
}

/// Un échec de démarrage sur le fil principal s'affiche ; les commandes de
/// l'interface ont leur propre fil et renvoient déjà leur erreur à l'écran.
pub fn install_panic_message() {
    std::panic::set_hook(Box::new(|info| {
        if std::thread::current().name() != Some("main") {
            return;
        }
        let what = info.payload().downcast_ref::<&str>().map(|s| s.to_string()).or_else(|| info.payload().downcast_ref::<String>().cloned()).unwrap_or_default();
        message(&format!("La Boîte à outils a rencontré un problème et doit se fermer.\n\n{what}"), MB_OK | MB_ICONERROR);
    }));
}

/// Détection documentée par Microsoft : version inscrite dans le registre,
/// pour tout le PC (64 bits, 32 bits) ou pour l'utilisateur.
fn version_in(root: HKEY, key: &str) -> bool {
    let (k, n) = (w(key), w("pv"));
    let mut buf = [0u16; 64];
    let mut size = std::mem::size_of_val(&buf) as u32;
    let r = unsafe { RegGetValueW(root, k.as_ptr(), n.as_ptr(), RRF_RT_REG_SZ, std::ptr::null_mut(), buf.as_mut_ptr() as _, &mut size) };
    if r != 0 {
        return false;
    }
    let len = buf.iter().position(|c| *c == 0).unwrap_or(0);
    let v = String::from_utf16_lossy(&buf[..len]);
    !v.is_empty() && v != "0.0.0.0"
}

pub fn webview2_installed() -> bool {
    #[cfg(feature = "test-hooks")]
    if std::env::var_os("BAO_FAKE_NO_WV2").is_some() {
        return false;
    }
    version_in(HKEY_LOCAL_MACHINE, &format!("SOFTWARE\\WOW6432Node\\{CLIENT}")) || version_in(HKEY_LOCAL_MACHINE, &format!("SOFTWARE\\{CLIENT}")) || version_in(HKEY_CURRENT_USER, &format!("Software\\{CLIENT}"))
}

/// Vrai si l'interface peut s'ouvrir. Sinon propose d'installer le composant
/// officiel de Microsoft et explique quoi faire si cela échoue.
pub fn ensure_webview2() -> bool {
    if webview2_installed() {
        return true;
    }
    let ask = "La Boîte à outils a besoin de « Microsoft Edge WebView2 », un composant gratuit de Windows, absent de ce PC.\n\nLe télécharger et l'installer maintenant depuis le site de Microsoft ? Une connexion Internet est nécessaire, et cela peut prendre quelques minutes sans rien afficher.";
    if message(ask, MB_YESNO | MB_ICONQUESTION) != IDYES {
        return false;
    }
    let result = crate::ps::run("webview2", &serde_json::Value::Null);
    if webview2_installed() {
        return true;
    }
    let why = result.err().unwrap_or_else(|| "installation non terminée".into());
    message(&format!("WebView2 n'a pas pu être installé :\n{why}\n\nLa page de téléchargement de Microsoft va s'ouvrir : installez le « Bootstrapper » ou le « Standalone Installer », puis relancez la Boîte à outils."), MB_OK | MB_ICONWARNING);
    crate::win::shell_open(DOWNLOAD_PAGE);
    false
}

/// Le moteur est inscrit mais refuse de démarrer (installation abîmée, dossier
/// de données bloqué, antivirus) : explication et pistes, pas de fermeture muette.
pub fn webview_failed(error: &dyn std::fmt::Display) {
    message(&format!("L'interface n'a pas pu démarrer :\n{error}\n\nRéparez « Microsoft Edge WebView2 Runtime » depuis Paramètres > Applications, ou réinstallez-le depuis la page qui va s'ouvrir, puis relancez la Boîte à outils."), MB_OK | MB_ICONERROR);
    crate::win::shell_open(DOWNLOAD_PAGE);
}
