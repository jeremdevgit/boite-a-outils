// SPDX-License-Identifier: GPL-3.0-or-later — Copyright (C) 2026 jeremdevgit — voir LICENSE
//! Barre des tâches transparente, floutée ou colorée (façon TranslucentTB).
//!
//! Un petit processus sans fenêtre (`BoiteAOutils.exe --barre`) applique
//! l'effet à la barre avec SetWindowCompositionAttribute, depuis son propre
//! processus : rien n'est injecté dans l'Explorateur. Windows remet l'aspect
//! d'origine à chaque redessin de la barre, d'où une réapplication régulière.
//! Réglages dans barre.json ; « normal » arrête le processus.

use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use windows_sys::Win32::Foundation::{BOOL, HWND, LPARAM};
use windows_sys::Win32::UI::WindowsAndMessaging::*;

#[derive(Serialize, Deserialize, Clone, PartialEq)]
#[serde(default)]
pub struct Config {
    /// normal, clear (transparente), blur (floutée), acrylic (verre dépoli), color (teinte)
    pub mode: String,
    /// teinte #RRGGBBAA pour « color » et « acrylic »
    pub color: String,
    /// aspect quand une fenêtre est agrandie (vide = le même)
    pub maximized: String,
}

impl Default for Config {
    fn default() -> Self {
        Config { mode: "normal".into(), color: "#00000040".into(), maximized: String::new() }
    }
}

/// Fichier de réglages : passé en argument au processus `--barre` (il ne
/// connaît pas forcément le même dossier de données), sinon dossier de l'application.
fn path() -> PathBuf {
    let args: Vec<String> = std::env::args().collect();
    if let Some(i) = args.iter().position(|a| a == "--barre") {
        if let Some(p) = args.get(i + 1).filter(|p| p.ends_with("barre.json")) {
            return PathBuf::from(p);
        }
    }
    crate::win::data_dir().join("barre.json")
}

pub fn load() -> Config {
    std::fs::read(path()).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default()
}

pub fn save(c: &Config) {
    let _ = std::fs::write(path(), serde_json::to_vec_pretty(c).unwrap_or_default());
}

#[repr(C)]
struct AccentPolicy {
    state: u32,
    flags: u32,
    color: u32,
    animation: u32,
}

#[repr(C)]
struct CompositionData {
    attribute: u32,
    data: *mut AccentPolicy,
    size: usize,
}

type SetWca = unsafe extern "system" fn(HWND, *mut CompositionData) -> BOOL;

fn set_wca() -> Option<SetWca> {
    use windows_sys::Win32::System::LibraryLoader::{GetModuleHandleW, GetProcAddress};
    unsafe {
        let user32 = crate::win::w("user32.dll");
        let h = GetModuleHandleW(user32.as_ptr());
        GetProcAddress(h, b"SetWindowCompositionAttribute\0".as_ptr()).map(|f| std::mem::transmute::<_, SetWca>(f))
    }
}

/// #RRGGBBAA → ABGR attendu par Windows.
fn abgr(hex: &str) -> u32 {
    let h = hex.trim_start_matches('#');
    let v = u32::from_str_radix(h, 16).unwrap_or(0);
    let (r, g, b, a) = if h.len() == 8 { (v >> 24, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF) } else { (v >> 16, (v >> 8) & 0xFF, v & 0xFF, 0xFF) };
    (a << 24) | (b << 16) | (g << 8) | r
}

fn taskbars() -> Vec<HWND> {
    unsafe extern "system" fn cb(h: HWND, l: LPARAM) -> BOOL {
        let mut cls = [0u16; 64];
        let n = GetClassNameW(h, cls.as_mut_ptr(), 64) as usize;
        let c = String::from_utf16_lossy(&cls[..n]);
        if c == "Shell_TrayWnd" || c == "Shell_SecondaryTrayWnd" {
            (*(l as *mut Vec<HWND>)).push(h);
        }
        1
    }
    let mut v: Vec<HWND> = Vec::new();
    unsafe { EnumWindows(Some(cb), &mut v as *mut _ as LPARAM) };
    v
}

/// Une fenêtre visible est-elle agrandie sur l'écran de cette barre ?
fn maximized_on(bar: HWND) -> bool {
    struct Ctx {
        mon: isize,
        found: bool,
    }
    unsafe extern "system" fn cb(h: HWND, l: LPARAM) -> BOOL {
        let ctx = &mut *(l as *mut Ctx);
        if IsWindowVisible(h) != 0 && IsZoomed(h) != 0 && IsIconic(h) == 0 {
            let style = GetWindowLongW(h, GWL_EXSTYLE) as u32;
            if style & WS_EX_TOOLWINDOW == 0
                && windows_sys::Win32::Graphics::Gdi::MonitorFromWindow(h, windows_sys::Win32::Graphics::Gdi::MONITOR_DEFAULTTONEAREST) as isize == ctx.mon
            {
                // fenêtres masquées par le bureau virtuel (« cloaked ») ignorées
                let mut cloaked = 0u32;
                windows_sys::Win32::Graphics::Dwm::DwmGetWindowAttribute(h, windows_sys::Win32::Graphics::Dwm::DWMWA_CLOAKED as u32, &mut cloaked as *mut u32 as _, 4);
                if cloaked == 0 {
                    ctx.found = true;
                    return 0;
                }
            }
        }
        1
    }
    let mon = unsafe { windows_sys::Win32::Graphics::Gdi::MonitorFromWindow(bar, windows_sys::Win32::Graphics::Gdi::MONITOR_DEFAULTTONEAREST) } as isize;
    let mut ctx = Ctx { mon, found: false };
    unsafe { EnumWindows(Some(cb), &mut ctx as *mut _ as LPARAM) };
    ctx.found
}

fn apply(f: SetWca, bar: HWND, mode: &str, color: &str) {
    let (state, col) = match mode {
        "clear" => (2, 0u32),             // dégradé transparent, teinte invisible
        "color" => (2, abgr(color)),      // teinte choisie
        "blur" => (3, 0),                 // flou
        "acrylic" => (4, abgr(color)),    // verre dépoli teinté
        _ => (0, 0),                      // aspect de Windows
    };
    let mut accent = AccentPolicy { state, flags: 2, color: col, animation: 0 };
    let mut data = CompositionData { attribute: 19, data: &mut accent, size: std::mem::size_of::<AccentPolicy>() };
    unsafe { f(bar, &mut data) };
}

/// Boucle du processus `--barre` : s'arrête quand le mode repasse à « normal »
/// ou quand une autre instance tourne déjà.
pub fn agent() {
    use windows_sys::Win32::System::Threading::CreateMutexW;
    let name = crate::win::w("Local\\BoiteAOutils.Barre");
    unsafe {
        CreateMutexW(std::ptr::null(), 1, name.as_ptr());
        if windows_sys::Win32::Foundation::GetLastError() == 183 {
            return; // ERROR_ALREADY_EXISTS
        }
    }
    let Some(f) = set_wca() else { return };
    let mut cfg = load();
    let mut stamp = std::fs::metadata(path()).and_then(|m| m.modified()).ok();
    let mut tick = 0u32;
    loop {
        tick += 1;
        if tick % 10 == 0 {
            let s = std::fs::metadata(path()).and_then(|m| m.modified()).ok();
            if s != stamp {
                stamp = s;
                cfg = load();
            }
        }
        let bars = taskbars();
        if cfg.mode == "normal" {
            for b in bars {
                apply(f, b, "normal", "");
                // la barre reprend son aspect au prochain redessin
                unsafe { SendMessageW(b, WM_THEMECHANGED, 0, 0) };
            }
            return;
        }
        for b in bars {
            let mode = if !cfg.maximized.is_empty() && maximized_on(b) { cfg.maximized.as_str() } else { cfg.mode.as_str() };
            apply(f, b, mode, &cfg.color);
        }
        std::thread::sleep(std::time::Duration::from_millis(100));
    }
}

const RUN_KEY: &str = "Software\\Microsoft\\Windows\\CurrentVersion\\Run";
const RUN_NAME: &str = "BoiteAOutils-Barre";

/// Enregistre les réglages, démarre ou arrête le processus et l'inscrit au démarrage.
pub fn set(c: &Config) -> Result<(), String> {
    save(c);
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    register(&exe, c.mode != "normal");
    Ok(())
}

/// Installation : la barre déjà réglée passe sur l'exécutable installé
/// (l'ancien a pu être lancé depuis Téléchargements). Vrai si elle est active.
pub fn reattach(exe: &std::path::Path) -> bool {
    let on = load().mode != "normal";
    if on {
        register(exe, true);
    }
    on
}

fn register(exe: &std::path::Path, on: bool) {
    let cfg = path();
    let cmd = format!("\"{}\" --barre \"{}\"", exe.display(), cfg.display());
    use windows_sys::Win32::System::Registry::*;
    unsafe {
        let mut key: HKEY = std::ptr::null_mut();
        let k = crate::win::w(RUN_KEY);
        if RegOpenKeyExW(HKEY_CURRENT_USER, k.as_ptr(), 0, KEY_SET_VALUE, &mut key) == 0 {
            let n = crate::win::w(RUN_NAME);
            if on {
                let v = crate::win::w(&cmd);
                RegSetValueExW(key, n.as_ptr(), 0, REG_SZ, v.as_ptr() as _, (v.len() * 2) as u32);
            } else {
                RegDeleteValueW(key, n.as_ptr());
            }
            RegCloseKey(key);
        }
    }
    if on {
        // le processus déjà lancé relit barre.json ; sinon on le démarre, sans droits administrateur
        crate::win::open_as_user_args(&exe.to_string_lossy(), &format!("--barre \"{}\"", cfg.display()));
    }
}

/// Le processus tourne-t-il ?
pub fn running() -> bool {
    use windows_sys::Win32::System::Threading::{OpenMutexW, SYNCHRONIZATION_SYNCHRONIZE};
    let name = crate::win::w("Local\\BoiteAOutils.Barre");
    let h = unsafe { OpenMutexW(SYNCHRONIZATION_SYNCHRONIZE, 0, name.as_ptr()) };
    if h.is_null() {
        return false;
    }
    unsafe { windows_sys::Win32::Foundation::CloseHandle(h) };
    true
}
