#![windows_subsystem = "windows"]
// SPDX-License-Identifier: GPL-3.0-or-later — Copyright (C) 2026 jeremdevgit — voir LICENSE
//! Boîte à outils : démarrage, services, processus, nettoyage, fichiers lourds
//! et fantômes, optimisations et outils de réparation de Windows.
//!
//! Une vue WebView2 affiche l'interface (fichiers intégrés à l'exécutable,
//! servis à http://bao.localhost/). Le code natif analyse les fichiers et les
//! caches ; les réglages de Windows passent par des scripts PowerShell intégrés.
//! Chaque modification est inscrite dans l'historique avec de quoi l'annuler.

mod backup;
mod backup_paths;
mod clean;
mod display;
mod usb;
mod winget;
mod hwinfo;
mod pawnio;
mod sensors;
mod stress;
mod benchmark_file;
mod taskbar;
mod files;
mod search;
mod disktree;
mod install;
mod install_security;
mod user_context;
mod journal;
mod langue;
mod setup;
mod shell;
mod live;
mod procs;
mod runtime;
mod ps;
mod sysint;
mod win;

use serde_json::{json, Value};
use std::borrow::Cow;
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use tao::event::{Event, WindowEvent};
use tao::event_loop::{ControlFlow, EventLoopBuilder, EventLoopProxy};
use tao::platform::windows::WindowExtWindows;
use tao::window::WindowBuilder;
use wry::{MemoryUsageLevel, WebViewBuilder, WebViewBuilderExtWindows, WebViewExtWindows};

const APP_URL: &str = "http://bao.localhost/";

enum UserEvent {
    Ipc(String),
    ToUi(Value),
    Quit,
}

static PROXY: OnceLock<Mutex<EventLoopProxy<UserEvent>>> = OnceLock::new();
static CANCEL: OnceLock<Mutex<HashMap<u64, Arc<AtomicBool>>>> = OnceLock::new();

fn post(e: UserEvent) {
    if let Some(p) = PROXY.get() {
        let _ = p.lock().unwrap().send_event(e);
    }
}

fn to_ui(v: Value) {
    post(UserEvent::ToUi(v));
}

fn testing() -> bool {
    cfg!(feature = "test-hooks") && std::env::var_os("BAO_TEST").is_some()
}

/// Journal de test réservé au dossier de données privé, sans chemin temporaire partagé.
#[cfg(feature = "test-hooks")]
fn test_log(msg: &str) {
    use std::io::Write;
    let Ok(dir) = win::operation_data_dir() else {
        return;
    };
    let safe_msg: String = msg.chars().flat_map(char::escape_default).collect();
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(dir.join("bao_test.log"))
    {
        let _ = writeln!(f, "{safe_msg}");
    }
}

#[cfg(not(feature = "test-hooks"))]
fn test_log(_: &str) {}

/// Fichiers de l'interface, intégrés à l'exécutable.
fn asset(path: &str) -> Option<(&'static [u8], &'static str)> {
    Some(match path.trim_start_matches('/') {
        "" | "index.html" => (include_bytes!("../ui/index.html"), "text/html; charset=utf-8"),
        "style.css" => (include_bytes!("../ui/style.css"), "text/css; charset=utf-8"),
        "app.js" => (include_bytes!("../ui/app.js"), "text/javascript; charset=utf-8"),
        "kb.js" => (include_bytes!("../ui/kb.js"), "text/javascript; charset=utf-8"),
        "hw.js" => (include_bytes!("../ui/hw.js"), "text/javascript; charset=utf-8"),
        "pro.js" => (include_bytes!("../ui/pro.js"), "text/javascript; charset=utf-8"),
        "disk.js" => (include_bytes!("../ui/disk.js"), "text/javascript; charset=utf-8"),
        "langue.js" => (include_bytes!("../ui/langue.js"), "text/javascript; charset=utf-8"),
        "textes-chargeur.js" => (include_bytes!("../ui/textes-chargeur.js"), "text/javascript; charset=utf-8"),
        // traductions : seule celle de la langue choisie est chargée
        "textes/en.js" => (include_bytes!("../ui/textes/en.js"), "text/javascript; charset=utf-8"),
        "textes/es.js" => (include_bytes!("../ui/textes/es.js"), "text/javascript; charset=utf-8"),
        "textes/de.js" => (include_bytes!("../ui/textes/de.js"), "text/javascript; charset=utf-8"),
        "textes/it.js" => (include_bytes!("../ui/textes/it.js"), "text/javascript; charset=utf-8"),
        "textes/pt.js" => (include_bytes!("../ui/textes/pt.js"), "text/javascript; charset=utf-8"),
        "textes/zh.js" => (include_bytes!("../ui/textes/zh.js"), "text/javascript; charset=utf-8"),
        "textes/ja.js" => (include_bytes!("../ui/textes/ja.js"), "text/javascript; charset=utf-8"),
        "icon.png" => return None,
        _ => return None,
    })
}

fn icon_png() -> Vec<u8> {
    // PNG non compressé (zlib « stored ») de l'icône 64 px
    let size = 64u32;
    let rgba = icon::render_icon(size);
    let mut raw = Vec::new();
    for y in 0..size as usize {
        raw.push(0u8);
        raw.extend_from_slice(&rgba[y * size as usize * 4..(y + 1) * size as usize * 4]);
    }
    let mut z = vec![0x78, 0x01];
    for (i, c) in raw.chunks(65535).enumerate() {
        let last = (i + 1) * 65535 >= raw.len();
        z.push(last as u8);
        z.extend_from_slice(&(c.len() as u16).to_le_bytes());
        z.extend_from_slice(&(!(c.len() as u16)).to_le_bytes());
        z.extend_from_slice(c);
    }
    let (mut a, mut b) = (1u32, 0u32);
    for &x in &raw {
        a = (a + x as u32) % 65521;
        b = (b + a) % 65521;
    }
    z.extend_from_slice(&((b << 16) | a).to_be_bytes());
    fn crc(data: &[u8]) -> u32 {
        let mut c = 0xffff_ffffu32;
        for &x in data {
            c ^= x as u32;
            for _ in 0..8 {
                c = if c & 1 != 0 { 0xedb8_8320 ^ (c >> 1) } else { c >> 1 };
            }
        }
        !c
    }
    let mut png = vec![0x89, b'P', b'N', b'G', 0x0d, 0x0a, 0x1a, 0x0a];
    let mut chunk = |kind: &[u8], data: &[u8]| {
        png.extend_from_slice(&(data.len() as u32).to_be_bytes());
        let mut c = kind.to_vec();
        c.extend_from_slice(data);
        png.extend_from_slice(&c);
        png.extend_from_slice(&crc(&c).to_be_bytes());
    };
    let mut ihdr = Vec::new();
    ihdr.extend_from_slice(&size.to_be_bytes());
    ihdr.extend_from_slice(&size.to_be_bytes());
    ihdr.extend_from_slice(&[8, 6, 0, 0, 0]);
    chunk(b"IHDR", &ihdr);
    chunk(b"IDAT", &z);
    chunk(b"IEND", &[]);
    png
}

mod icon {
    include!("icon.rs");
}

fn window_icon() -> Option<tao::window::Icon> {
    tao::window::Icon::from_rgba(icon::render_icon(32), 32, 32).ok()
}

fn dark_title_bar(hwnd: isize) {
    use windows_sys::Win32::Graphics::Dwm::DwmSetWindowAttribute;
    let on: i32 = 1;
    unsafe {
        // DWMWA_USE_IMMERSIVE_DARK_MODE
        DwmSetWindowAttribute(hwnd as _, 20, &on as *const i32 as _, 4);
    }
}

fn main() {
    langue::depuis_windows();
    runtime::install_panic_message();
    let args: Vec<String> = std::env::args().collect();
    // barre des tâches transparente : petit processus sans fenêtre ni droits administrateur
    if args.iter().any(|a| a == "--barre") {
        taskbar::agent();
        return;
    }
    // installateur (BoiteAOutils-Setup.exe) et maintenance (uninstall.exe) : même exécutable
    let has = |f: &str| args.iter().any(|a| a == f);
    let stem = std::env::current_exe().ok().and_then(|e| e.file_stem().map(|s| s.to_string_lossy().to_lowercase())).unwrap_or_default();
    if has("--uninstall") {
        if setup::ensure_admin(&args) {
            std::process::exit(install::quiet_uninstall(has("--all")));
        }
        return;
    }
    if has("--maintenance") || stem == "uninstall" {
        return setup::run(setup::Mode::Maintenance, &args);
    }
    if has("--setup") || stem.contains("setup") || stem.contains("install") {
        return setup::run(setup::Mode::Setup, &args);
    }
    // administrateur nécessaire pour les services, tâches et dossiers système :
    // relance avec l'invite UAC ; refus → mode limité (lecture et nettoyage personnel)
    if !win::is_elevated() && !testing() && !args.iter().any(|a| a == "--eleve" || a == "--limite") && win::relaunch_elevated() {
        return;
    }

    if !runtime::ensure_webview2() {
        return;
    }

    let event_loop = EventLoopBuilder::<UserEvent>::with_user_event().build();
    let proxy = event_loop.create_proxy();
    let _ = PROXY.set(Mutex::new(proxy.clone()));
    let _ = CANCEL.set(Mutex::new(HashMap::new()));

    let window = WindowBuilder::new()
        .with_title("Boîte à outils")
        .with_inner_size(tao::dpi::LogicalSize::new(1280.0, 820.0))
        .with_min_inner_size(tao::dpi::LogicalSize::new(380.0, 420.0))
        .with_window_icon(window_icon())
        .with_visible(false)
        .build(&event_loop)
        .expect("fenêtre");
    dark_title_bar(window.hwnd() as isize);

    let webview_dir = match win::operation_data_dir() {
        Ok(dir) => dir.join("WebView2-App"),
        Err(e) => {
            runtime::webview_failed(&e);
            return;
        }
    };
    let mut ctx = wry::WebContext::new(Some(webview_dir));
    let ipc_proxy = proxy.clone();
    let png = icon_png();
    let webview = WebViewBuilder::new_with_web_context(&mut ctx)
        .with_background_color((14, 16, 24, 255))
        .with_devtools(cfg!(debug_assertions))
        .with_additional_browser_args("--disable-features=msWebOOUI,msPdfOOUI,msSmartScreenProtection,Translate,msEdgeTranslate,AutofillServerCommunication,OptimizationHints,msEdgeShoppingAssistant")
        .with_custom_protocol("bao".into(), move |_id, req| {
            let path = req.uri().path().to_string();
            let resp = wry::http::Response::builder().header("Cache-Control", "no-store");
            if path == "/icon.png" {
                return resp.header("Content-Type", "image/png").body(Cow::Owned(png.clone())).unwrap();
            }
            match asset(&path) {
                Some((body, mime)) => resp.header("Content-Type", mime).body(Cow::Borrowed(body)).unwrap(),
                None => resp.status(404).body(Cow::Borrowed(&b""[..])).unwrap(),
            }
        })
        // l'interface ne quitte jamais ses propres pages
        .with_navigation_handler(|url| url.starts_with(APP_URL))
        .with_new_window_req_handler(|uri, _| {
            if uri.starts_with("https://") {
                win::shell_open(&uri);
            }
            wry::NewWindowResponse::Deny
        })
        .with_ipc_handler(move |m| {
            if m.uri().to_string().starts_with(APP_URL) {
                let _ = ipc_proxy.send_event(UserEvent::Ipc(m.body().clone()));
            }
        })
        .with_url(format!("{APP_URL}index.html"))
        .build(&window);
    let webview = match webview {
        Ok(w) => w,
        Err(e) => return runtime::webview_failed(&e),
    };

    let mut shown = false;
    let mut minimized = false;
    event_loop.run(move |event, _, flow| {
        *flow = ControlFlow::Wait;
        match event {
            Event::UserEvent(UserEvent::Ipc(msg)) => {
                let Ok(v) = serde_json::from_str::<Value>(&msg) else { return };
                if v["cmd"] == "ready" && !shown {
                    shown = true;
                    #[cfg(feature = "test-hooks")]
                    if let Some(geo) = std::env::var("BAO_SHOW_AT").ok().filter(|_| testing()) {
                        let n: Vec<f64> = geo.split(',').filter_map(|x| x.parse().ok()).collect();
                        if n.len() == 4 {
                            window.set_outer_position(tao::dpi::PhysicalPosition::new(n[0], n[1]));
                            window.set_inner_size(tao::dpi::PhysicalSize::new(n[2], n[3]));
                        }
                    }
                    window.set_visible(true);
                }
                if v["cmd"] == "ready" {
                    // langue choisie dans l'interface, pour les messages de Windows
                    langue::definir(v["lang"].as_str().unwrap_or(""));
                    return;
                }
                if v["cmd"] == "log" {
                    if testing() {
                        test_log(v["msg"].as_str().unwrap_or(""));
                    }
                    return;
                }
                if v["cmd"] == "elevate" {
                    if win::relaunch_elevated() {
                        *flow = ControlFlow::Exit;
                    }
                    return;
                }
                dispatch(v);
            }
            Event::UserEvent(UserEvent::ToUi(v)) => {
                let _ = webview.evaluate_script(&format!("window.bao&&bao.recv({v})"));
            }
            // fenêtre réduite : plus aucun rendu ni minuterie, mémoire rendue au système
            Event::WindowEvent { event: WindowEvent::Resized(size), .. } => {
                let hidden = size.width == 0 || size.height == 0;
                if hidden != minimized {
                    minimized = hidden;
                    let _ = webview.set_visible(!hidden);
                    let _ = webview.set_memory_usage_level(if hidden { MemoryUsageLevel::Low } else { MemoryUsageLevel::Normal });
                }
            }
            Event::UserEvent(UserEvent::Quit) | Event::WindowEvent { event: WindowEvent::CloseRequested, .. } => {
                for c in CANCEL.get().unwrap().lock().unwrap().values() {
                    c.store(true, Ordering::Relaxed);
                }
                *flow = ControlFlow::Exit;
            }
            _ => {}
        }
    });
}

/// Une demande de l'interface : exécutée sur son propre fil, réponse
/// { type: 'reply', id, ok, data | error } et progression { type: 'progress', id, data }.
fn dispatch(v: Value) {
    let id = v["id"].as_u64().unwrap_or(0);
    let cmd = v["cmd"].as_str().unwrap_or("").to_string();
    let args = v["args"].clone();
    if cmd == "cancel" {
        if let Some(c) = CANCEL.get().unwrap().lock().unwrap().get(&args["job"].as_u64().unwrap_or(0)) {
            c.store(true, Ordering::Relaxed);
        }
        return;
    }
    let cancel = Arc::new(AtomicBool::new(false));
    CANCEL.get().unwrap().lock().unwrap().insert(id, cancel.clone());
    std::thread::spawn(move || {
        let progress = move |d: Value| to_ui(json!({ "type": "progress", "id": id, "data": d }));
        let r = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| run(&cmd, &args, &cancel, &progress)))
            .unwrap_or_else(|_| Err("erreur interne".into()));
        CANCEL.get().unwrap().lock().unwrap().remove(&id);
        if testing() {
            test_log(&format!("cmd {cmd} → {}", if r.is_ok() { "ok" } else { "erreur" }));
        }
        match r {
            Ok(data) => to_ui(json!({ "type": "reply", "id": id, "ok": true, "data": data })),
            Err(e) => to_ui(json!({ "type": "reply", "id": id, "ok": false, "error": e })),
        }
    });
}

fn paths(v: &Value) -> Vec<PathBuf> {
    v.as_array().map(|a| a.iter().filter_map(|p| p.as_str()).map(PathBuf::from).collect()).unwrap_or_default()
}

/// Dossiers personnels analysés pour les doublons et les dossiers vides.
fn user_folders() -> Vec<PathBuf> {
    use windows::Win32::UI::Shell::*;
    // emplacements réels : ces dossiers peuvent être déplacés (OneDrive, autre lecteur)
    [FOLDERID_Desktop, FOLDERID_Documents, FOLDERID_Downloads, FOLDERID_Pictures, FOLDERID_Videos, FOLDERID_Music].iter().filter_map(shell::known_folder).filter(|p| p.exists()).collect()
}

/// Outils de réparation autorisés (aucune commande arbitraire depuis l'interface).
fn tool_line(name: &str, drive: &str) -> Option<(&'static str, Vec<String>)> {
    let d = drive.chars().next().filter(|c| c.is_ascii_alphabetic()).map(|c| format!("{}:", c.to_ascii_uppercase())).unwrap_or_else(win::system_drive);
    Some(match name {
        "sfc" => ("sfc.exe", vec!["/scannow".into()]),
        "dism_check" => ("dism.exe", vec!["/Online".into(), "/Cleanup-Image".into(), "/ScanHealth".into()]),
        "dism_restore" => ("dism.exe", vec!["/Online".into(), "/Cleanup-Image".into(), "/RestoreHealth".into()]),
        "dism_analyze" => ("dism.exe", vec!["/Online".into(), "/Cleanup-Image".into(), "/AnalyzeComponentStore".into()]),
        "dism_cleanup" => ("dism.exe", vec!["/Online".into(), "/Cleanup-Image".into(), "/StartComponentCleanup".into()]),
        "chkdsk" => ("chkdsk.exe", vec![d, "/scan".into()]),
        "optimize" => ("defrag.exe", vec![d, "/O".into(), "/U".into(), "/V".into()]),
        "analyze_disk" => ("defrag.exe", vec![d, "/A".into(), "/V".into()]),
        "flushdns" => ("ipconfig.exe", vec!["/flushdns".into()]),
        "winsock" => ("netsh.exe", vec!["winsock".into(), "reset".into()]),
        "ipreset" => ("netsh.exe", vec!["int".into(), "ip".into(), "reset".into()]),
        "iprenew" => ("ipconfig.exe", vec!["/renew".into()]),
        _ => return None,
    })
}

fn run(cmd: &str, a: &Value, cancel: &AtomicBool, progress: &(dyn Fn(Value) + Sync)) -> Result<Value, String> {
    match cmd {
        "search.start" => {
            let root = a["root"].as_str().unwrap_or("");
            let hidden = a["hidden"].as_bool().unwrap_or(false);
            if root == "*" { search::start_all(win::drives().into_iter().map(|(drive, _, _)| drive).collect(), hidden) }
            else { search::start(root, hidden) }
        },
        "search.status" => Ok(search::status()),
        "search.query" => Ok(search::query(a)),
        "search.stop" => Ok(search::stop()),
        "info" => {
            let (total, avail) = win::memory();
            Ok(json!({
                "elevated": win::is_elevated(),
                "version": env!("CARGO_PKG_VERSION"),
                "memory": { "total": total, "available": avail },
                "drives": win::drives().into_iter().map(|(d, t, f)| json!({ "drive": d, "total": t, "free": f })).collect::<Vec<_>>(),
                "uptime": win::uptime_secs(),
                "computer": std::env::var("COMPUTERNAME").unwrap_or_default(),
                "user": std::env::var("USERNAME").unwrap_or_default(),
                "home": std::env::var("USERPROFILE").unwrap_or_default(),
                "userFolders": user_folders().iter().map(|p| p.to_string_lossy().to_string()).collect::<Vec<_>>(),
                "dataDir": win::data_dir().to_string_lossy(),
            }))
        }
        // script intégré ; une modification revient avec { undo } et entre dans l'historique
        "ps" => {
            let name = a["script"].as_str().unwrap_or("");
            let r = ps::run(name, &a["args"])?;
            if let Some(u) = r.get("undo").filter(|u| u.is_object()) {
                let title = a["title"].as_str().unwrap_or(name);
                let detail = r["detail"].as_str().unwrap_or("");
                journal::add(title, detail, u["script"].as_str().unwrap_or(""), u["args"].clone());
            }
            Ok(r)
        }
        "procs.list" => Ok(procs::list()),
        "clean.analyze" => Ok(clean::analyze(win::is_elevated())),
        "clean.run" => {
            let ids: Vec<String> = a["ids"].as_array().map(|x| x.iter().filter_map(|i| i.as_str().map(String::from)).collect()).unwrap_or_default();
            let r = clean::clean(&ids, |label| progress(json!({ "label": label })));
            let freed = r["freed"].as_u64().unwrap_or(0);
            journal::add("Nettoyage", &format!("{} libérés ({} catégories)", human(freed), ids.len()), "", Value::Null);
            Ok(r)
        }
        "scan.large" => {
            let root = a["root"].as_str().map(PathBuf::from).unwrap_or_else(|| PathBuf::from(format!("{}\\", win::system_drive())));
            if !root.is_dir() {
                return Err("dossier introuvable".into());
            }
            let min = a["min"].as_u64().unwrap_or(100 << 20);
            let top = a["top"].as_u64().unwrap_or(300) as usize;
            Ok(files::scan_large(&root, min, top, cancel, progress))
        }
        // analyse façon WizTree : arbre complet en mémoire, puis requêtes instantanées
        "tree.scan" => {
            let root = PathBuf::from(a["root"].as_str().unwrap_or(""));
            if !root.is_dir() {
                return Err("dossier introuvable".into());
            }
            disktree::scan(&root, cancel, progress)
        }
        "tree.children" => disktree::children(a),
        "tree.map" => disktree::treemap(a),
        "tree.types" => disktree::types(a),
        "tree.top" => disktree::top(a),
        "tree.info" => disktree::info(a),
        "tree.recycle" => {
            let ids: Vec<u32> = a["ids"].as_array().map(|x| x.iter().filter_map(|i| i.as_u64()).map(|i| i as u32).collect()).unwrap_or_default();
            let items = disktree::paths(&ids)?;
            let list: Vec<PathBuf> = items.iter().map(|(_, p)| PathBuf::from(p)).collect();
            if list.is_empty() {
                return Err("rien à supprimer".into());
            }
            if list.iter().any(|p| is_protected_path(p)) {
                return Err("un des éléments est un dossier système protégé".into());
            }
            let failed = win::recycle(&list);
            let ok = list.len() - failed;
            disktree::forget(&ids);
            if ok > 0 {
                journal::add(&format!("Mis à la Corbeille : {ok} élément(s) (analyse de disque)"), "Récupérables depuis la Corbeille tant qu'elle n'est pas vidée", "", Value::Null);
            }
            Ok(json!({ "recycled": ok, "failed": failed }))
        }
        "tree.export" => {
            use windows::Win32::UI::Shell::FOLDERID_Downloads;
            let dir = shell::known_folder(&FOLDERID_Downloads).ok_or("dossier Téléchargements introuvable")?;
            let name: String = a["name"].as_str().unwrap_or("Analyse disque").chars().filter(|c| c.is_alphanumeric() || " -_".contains(*c)).take(80).collect();
            let dest = dir.join(format!("{}.csv", if name.trim().is_empty() { "Analyse disque" } else { name.trim() }));
            let r = disktree::export(a, &dest)?;
            win::reveal(&dest);
            Ok(r)
        }
        "scan.dupes" => {
            let mut roots = paths(&a["roots"]);
            if roots.is_empty() {
                roots = user_folders();
            }
            Ok(files::duplicates(&roots, a["min"].as_u64().unwrap_or(1 << 20), cancel, progress))
        }
        "scan.empty" => {
            let mut roots = paths(&a["roots"]);
            if roots.is_empty() {
                roots = user_folders();
            }
            Ok(json!({ "dirs": files::empty_dirs(&roots, cancel) }))
        }
        "files.sizes" => {
            let list = paths(&a["paths"]);
            let sizes: Vec<u64> = std::thread::scope(|s| {
                let hs: Vec<_> = list.iter().map(|p| s.spawn(move || files::dir_size(p, 0).0)).collect();
                hs.into_iter().map(|h| h.join().unwrap_or(0)).collect()
            });
            Ok(json!(sizes))
        }
        "ghosts.versions" => Ok(json!({ "items": clean::old_versions() })),
        "ghosts.downloads" => Ok(json!({ "items": clean::old_downloads() })),
        "files.recycle" => {
            let list = paths(&a["paths"]);
            if list.iter().any(|p| is_protected_path(p)) {
                return Err("un des éléments est un dossier système protégé".into());
            }
            let failed = win::recycle(&list);
            let ok = list.len() - failed;
            if ok > 0 {
                let what = a["what"].as_str().unwrap_or("éléments");
                journal::add(&format!("Mis à la Corbeille : {ok} {what}"), "Récupérables depuis la Corbeille tant qu'elle n'est pas vidée", "", Value::Null);
            }
            Ok(json!({ "recycled": ok, "failed": failed }))
        }
        "files.delete_dirs" => {
            // dossiers vides uniquement : remove_dir échoue sur un dossier non vide
            let list = paths(&a["paths"]);
            let mut ok = 0;
            for p in &list {
                if !is_protected_path(p) && remove_empty_tree(p) {
                    ok += 1;
                }
            }
            if ok > 0 {
                journal::add(&format!("Dossiers vides supprimés : {ok}"), "", "", Value::Null);
            }
            Ok(json!({ "removed": ok, "failed": list.len() - ok }))
        }
        "files.reveal" => {
            win::reveal(&PathBuf::from(a["path"].as_str().unwrap_or("")));
            Ok(Value::Null)
        }
        "open" => {
            // pages des Paramètres et consoles de Windows uniquement
            let t = a["target"].as_str().unwrap_or("");
            let allowed = ["mdsched.exe", "perfmon.exe", "taskschd.msc", "services.msc", "devmgmt.msc", "diskmgmt.msc", "cleanmgr.exe", "msconfig.exe", "rstrui.exe", "SystemPropertiesProtection.exe", "appwiz.cpl"];
            if t.starts_with("ms-settings:") || allowed.contains(&t) {
                win::shell_open(t);
                Ok(Value::Null)
            } else if t == "reliability" {
                let _ = std::process::Command::new(win::system_tool("perfmon.exe")).arg("/rel").spawn();
                Ok(Value::Null)
            } else if t.starts_with("https://") {
                win::shell_open(t);
                Ok(Value::Null)
            } else {
                Err("cible non autorisée".into())
            }
        }
        "tool" => {
            let name = a["name"].as_str().unwrap_or("");
            let (exe, targs) = tool_line(name, a["drive"].as_str().unwrap_or("")).ok_or("outil inconnu")?;
            let refs: Vec<&str> = targs.iter().map(String::as_str).collect();
            let (code, text) = ps::tool(exe, &refs, |line| progress(json!({ "line": line })))?;
            Ok(json!({ "code": code, "output": text }))
        }
        "live" => Ok(live::sample()),
        "sensors" => Ok(sensors::sample()),
        // PawnIO : installé par winget (paquet officiel namazso.PawnIO), dans une fenêtre visible
        "pawnio.install" => {
            if !winget::available() {
                return Err("winget est absent de ce PC : installez PawnIO depuis pawnio.eu, puis relancez la Boîte à outils".into());
            }
            use std::os::windows::process::CommandExt;
            let line = format!("\"\"{}\" install --id namazso.PawnIO -e --accept-package-agreements --accept-source-agreements & echo. & echo Relancez la Boite a outils une fois l'installation terminee. & pause\"", winget::exe()?.display());
            std::process::Command::new(win::system_tool("cmd.exe")).raw_arg(format!("/C {line}")).spawn().map_err(|e| e.to_string())?;
            Ok(Value::Null)
        }
        "sensors.reset" => {
            sensors::reset();
            Ok(Value::Null)
        }
        "hw.cpu" => Ok(hwinfo::cpu()),
        "stress.start" => stress::start(
            a["kind"].as_str().unwrap_or(""),
            a["threads"].as_u64().unwrap_or(0) as usize,
            a["minutes"].as_u64().unwrap_or(0),
            a["memPct"].as_u64().unwrap_or(70),
        ),
        "stress.stop" => {
            stress::stop();
            Ok(stress::status())
        }
        "stress.status" => Ok(stress::status()),
        "bench.disk" => user_context::as_standard_user(|| {
            stress::disk_bench(
                a["drive"].as_str().unwrap_or(&win::system_drive()),
                a["sizeMb"].as_u64().unwrap_or(1024),
                cancel,
                &|l| progress(json!({ "line": l })),
            )
        })
        .map_err(|e| e.to_string())?,
        "taskbar.get" => Ok(json!({ "config": taskbar::load(), "running": taskbar::running() })),
        "taskbar.set" => {
            let c: taskbar::Config = serde_json::from_value(a["config"].clone()).map_err(|e| e.to_string())?;
            taskbar::set(&c)?;
            Ok(Value::Null)
        }
        // Mode Dieu : élément du panneau de configuration, ouvert par l'Explorateur de l'utilisateur
        "godmode.open" => {
            let p = a["path"].as_str().unwrap_or("");
            if !p.starts_with("::{") || p.contains('"') {
                return Err("élément inconnu".into());
            }
            win::open_as_user(&format!("shell:{p}"));
            Ok(Value::Null)
        }
        // page de téléchargement d'un logiciel de l'auteur : l'interface donne un identifiant,
        // l'adresse vient de la table MES_LOGICIELS (jamais d'adresse fournie par la page)
        "apps.open" => {
            let id = a["id"].as_str().unwrap_or("");
            let url = MES_LOGICIELS.iter().find(|x| x.0 == id).map(|x| x.1).ok_or("logiciel inconnu")?;
            win::open_as_user(url); // navigateur ouvert avec les droits de l'utilisateur, pas en administrateur
            Ok(Value::Null)
        }
        // opération sans retour arrière possible, notée dans l'historique
        "journal.add" => {
            journal::add(a["title"].as_str().unwrap_or(""), a["detail"].as_str().unwrap_or(""), "", Value::Null);
            Ok(Value::Null)
        }
        "gpu.restart" => {
            win::restart_gpu_driver();
            Ok(Value::Null)
        }
        // rapport généré par la Boîte à outils (rapport de batterie)
        "open.report" => {
            let p = win::data_dir().join("rapport-batterie.html");
            if !p.is_file() {
                return Err("rapport introuvable".into());
            }
            win::open_as_user(&p.to_string_lossy());
            Ok(Value::Null)
        }
        "sysint.state" => Ok(sysint::state()),
        "sysint.get" => {
            let files: Vec<&str> = a["files"].as_array().map(|x| x.iter().filter_map(|f| f.as_str()).collect()).unwrap_or_default();
            if files.is_empty() || !files.iter().all(|f| sysint::allowed(f)) {
                return Err("outil inconnu".into());
            }
            ps::run("sysint", &json!({ "action": "get", "files": files }))?;
            Ok(sysint::state())
        }
        "sysint.run" => {
            let file = a["file"].as_str().unwrap_or("");
            if !sysint::allowed(file) {
                return Err("outil inconnu".into());
            }
            // signature Microsoft vérifiée à chaque lancement (le dossier est modifiable par l'utilisateur)
            ps::run("sysint", &json!({ "action": "verify", "files": [file] }))?;
            sysint::run(file, a["args"].as_str().unwrap_or(""), a["gui"].as_bool().unwrap_or(false), a["eula"].as_bool().unwrap_or(true), cancel, &|l| progress(json!({ "line": l })))
        }
        "display.list" => Ok(display::list()),
        "display.test" => display::set_mode(a["device"].as_str().unwrap_or(""), a["width"].as_u64().unwrap_or(0) as u32, a["height"].as_u64().unwrap_or(0) as u32, a["hz"].as_u64().unwrap_or(0) as u32, true),
        "display.set" => display::set_mode(a["device"].as_str().unwrap_or(""), a["width"].as_u64().unwrap_or(0) as u32, a["height"].as_u64().unwrap_or(0) as u32, a["hz"].as_u64().unwrap_or(0) as u32, false),
        "display.confirm" => {
            display::confirm(a["id"].as_u64().unwrap_or(0))?;
            journal::add(a["title"].as_str().unwrap_or("Mode d'écran changé"), "", "", Value::Null);
            Ok(Value::Null)
        }
        "display.revert" => {
            display::revert(a["id"].as_u64().unwrap_or(0))?;
            Ok(Value::Null)
        }
        "display.hdr" => {
            display::set_hdr(a["device"].as_str().unwrap_or(""), a["on"].as_bool().unwrap_or(false))?;
            Ok(Value::Null)
        }
        "usb.tree" => Ok(usb::tree()),
        "usb.label" => {
            usb::set_label(a["id"].as_str().unwrap_or(""), a["label"].as_str().unwrap_or(""))?;
            Ok(Value::Null)
        }
        "winget.list" => {
            if !winget::available() {
                return Err("winget absent : installez « Programme d'installation d'application » depuis le Microsoft Store".into());
            }
            winget::list()
        }
        "winget.install" => {
            let id = a["id"].as_str().unwrap_or("");
            let r = winget::install(id, cancel, &|l| progress(json!({ "line": l })))?;
            if r["ok"] == true {
                journal::add(&format!("Installé : {}", a["name"].as_str().unwrap_or(id)), "", "", Value::Null);
            }
            Ok(r)
        }
        "winget.upgradeAll" => {
            let r = winget::upgrade_all(cancel, &|l| progress(json!({ "line": l })))?;
            journal::add("Mise à jour de tous les logiciels", r["message"].as_str().unwrap_or(""), "", Value::Null);
            Ok(r)
        }
        "backup.pick" => Ok(json!({ "path": backup::pick_folder(), })),
        "backup.free" => Ok(json!({ "free": backup::free_space(a["path"].as_str().unwrap_or("")) })),
        "backup.run" => {
            let r = backup::run(a, cancel, progress)?;
            journal::add("Sauvegarde propre", r["report"][0].as_str().unwrap_or(""), "", Value::Null);
            Ok(r)
        }
        "journal.list" => Ok(serde_json::to_value(journal::load()).unwrap_or(Value::Null)),
        "journal.undo" => journal::undo(a["id"].as_u64().unwrap_or(0)),
        "quit" => {
            post(UserEvent::Quit);
            Ok(Value::Null)
        }
        _ => Err(format!("commande inconnue : {cmd}")),
    }
}

/// Dossiers qu'aucune action de fichiers ne doit toucher, même par erreur.
fn is_protected_path(p: &std::path::Path) -> bool {
    let s = p.to_string_lossy().to_lowercase().trim_end_matches('\\').to_string();
    if s.len() <= 3 {
        return true; // racine d'un lecteur
    }
    let env = |k: &str| std::env::var(k).unwrap_or_default().to_lowercase();
    let exact = [env("SystemRoot"), env("ProgramFiles"), env("ProgramFiles(x86)"), env("ProgramData"), env("USERPROFILE"), env("APPDATA"), env("LOCALAPPDATA"), format!("{}\\users", env("SystemDrive"))];
    if exact.iter().any(|e| !e.is_empty() && *e == s) {
        return true;
    }
    let win = env("SystemRoot");
    !win.is_empty() && (s.starts_with(&format!("{win}\\system32")) || s.starts_with(&format!("{win}\\winsxs")) || s.starts_with(&format!("{win}\\syswow64")))
}

/// Supprime un dossier qui ne contient que des dossiers vides.
fn remove_empty_tree(p: &std::path::Path) -> bool {
    if let Ok(rd) = std::fs::read_dir(p) {
        for e in rd.flatten() {
            let Ok(ft) = e.file_type() else { return false };
            if !ft.is_dir() || ft.is_symlink() || !remove_empty_tree(&e.path()) {
                return false;
            }
        }
    }
    std::fs::remove_dir(p).is_ok()
}

fn human(b: u64) -> String {
    let b = b as f64;
    if b >= 1e9 {
        format!("{:.1} Go", b / 1e9)
    } else if b >= 1e6 {
        format!("{:.0} Mo", b / 1e6)
    } else {
        format!("{:.0} Ko", b / 1e3)
    }
}

/// Logiciels de l'auteur (jeremdevgit) : identifiant utilisé par l'interface → page de téléchargement.
const MES_LOGICIELS: &[(&str, &str)] = &[
    ("profil", "https://github.com/jeremdevgit"),
    ("boite-a-outils", "https://github.com/jeremdevgit/boite-a-outils/releases/latest"),
    ("pomme", "https://github.com/jeremdevgit/pomme/releases/latest"),
    ("rjb", "https://github.com/jeremdevgit/rjb/releases/latest"),
    ("ludotheque", "https://github.com/jeremdevgit/ludotheque/releases/latest"),
    ("suite-libre", "https://jeremdevgit.github.io/suite-libre/"),
    ("batailles-de-france", "https://github.com/jeremdevgit/batailles-de-france/releases/latest"),
];
