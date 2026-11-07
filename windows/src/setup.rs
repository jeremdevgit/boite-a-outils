// SPDX-License-Identifier: GPL-3.0-or-later — Copyright (C) 2026 jeremdevgit — voir LICENSE
//! Installateur et outil de maintenance (réparer / désinstaller), dans le même
//! verre sombre que l'application. C'est le même exécutable : nommé
//! BoiteAOutils-Setup.exe il installe, nommé uninstall.exe il entretient.

use crate::install::{self, Options};
use serde_json::{json, Value};
use std::borrow::Cow;
use std::sync::atomic::{AtomicBool, Ordering};
use tao::event::{Event, WindowEvent};
use tao::event_loop::{ControlFlow, EventLoopBuilder};
use tao::platform::windows::WindowExtWindows;
use tao::window::WindowBuilder;
use wry::WebViewBuilder;

const URL: &str = "http://bao.localhost/setup.html";

static UNINSTALLED: AtomicBool = AtomicBool::new(false);

#[derive(Clone, Copy, PartialEq)]
pub enum Mode {
    Setup,
    Maintenance,
}

enum Ev {
    Ipc(String),
    Ui(Value),
}

/// Installer demande les droits administrateur (Program Files, inscription
/// pour tout le PC) : relance avec l'invite UAC, message si elle est refusée.
pub fn ensure_admin(args: &[String]) -> bool {
    if crate::win::is_elevated() {
        return true;
    }
    let params: Vec<String> = args.iter().skip(1).map(|a| format!("\"{}\"", a.replace('"', ""))).collect();
    if !crate::win::relaunch_elevated_with(&params.join(" ")) {
        use windows_sys::Win32::UI::WindowsAndMessaging::{MessageBoxW, MB_ICONWARNING, MB_OK};
        let text = crate::win::w(&format!("{}\n\n{}", crate::langue::tr("L'installation de la Boîte à outils demande les droits administrateur : elle s'installe pour tout le PC, dans un dossier protégé."), crate::langue::tr("Relancez l'installateur et acceptez l'invite de Windows.")));
        let title = crate::win::w("Boîte à outils");
        unsafe { MessageBoxW(std::ptr::null_mut(), text.as_ptr(), title.as_ptr(), MB_OK | MB_ICONWARNING) };
    }
    false
}

pub fn run(mode: Mode, args: &[String]) {
    if !ensure_admin(args) {
        return;
    }
    // installation silencieuse : BoiteAOutils-Setup.exe /S [--dir "C:\…"]
    if mode == Mode::Setup && args.iter().any(|a| a == "/S" || a == "--quiet") {
        let mut o = Options::default();
        if let Some(d) = args.iter().position(|a| a == "--dir").and_then(|i| args.get(i + 1)) {
            o.dir = d.clone();
        }
        std::process::exit(if install::install(&o, &|_| {}).is_ok() { 0 } else { 1 });
    }

    if !crate::runtime::ensure_webview2() {
        return;
    }

    let event_loop = EventLoopBuilder::<Ev>::with_user_event().build();
    let proxy = event_loop.create_proxy();
    let title = crate::langue::tr(if mode == Mode::Setup { "Installer la Boîte à outils" } else { "Boîte à outils — désinstaller ou réparer" });
    let window = WindowBuilder::new()
        .with_title(title)
        .with_inner_size(tao::dpi::LogicalSize::new(640.0, 640.0))
        .with_min_inner_size(tao::dpi::LogicalSize::new(480.0, 460.0))
        .with_window_icon(crate::window_icon())
        .build(&event_loop)
        .expect("fenêtre");
    crate::dark_title_bar(window.hwnd() as isize);
    let p = proxy.clone();
    let png = crate::icon_png();
    let mut ctx = wry::WebContext::new(Some(std::env::temp_dir().join("BoiteAOutilsSetup")));
    let webview = WebViewBuilder::new_with_web_context(&mut ctx)
        .with_background_color((14, 16, 24, 255))
        .with_custom_protocol("bao".into(), move |_id, req| {
            let resp = wry::http::Response::builder().header("Cache-Control", "no-store");
            match req.uri().path() {
                "/setup.html" => resp.header("Content-Type", "text/html; charset=utf-8").body(Cow::Borrowed(&include_bytes!("../ui/setup.html")[..])).unwrap(),
                "/icon.png" => resp.header("Content-Type", "image/png").body(Cow::Owned(png.clone())).unwrap(),
                _ => resp.status(404).body(Cow::Borrowed(&b""[..])).unwrap(),
            }
        })
        .with_navigation_handler(|url| url == URL)
        .with_ipc_handler(move |m| {
            if m.uri().to_string() == URL {
                let _ = p.send_event(Ev::Ipc(m.body().clone()));
            }
        })
        .with_url(URL)
        .build(&window);
    let webview = match webview {
        Ok(w) => w,
        Err(e) => return crate::runtime::webview_failed(&e),
    };

    event_loop.run(move |event, _, flow| {
        *flow = ControlFlow::Wait;
        match event {
            Event::UserEvent(Ev::Ui(v)) => {
                let _ = webview.evaluate_script(&format!("window.setup&&setup.recv({v})"));
            }
            Event::UserEvent(Ev::Ipc(msg)) => {
                let Ok(v) = serde_json::from_str::<Value>(&msg) else { return };
                let send = {
                    let p = proxy.clone();
                    move |v: Value| {
                        let _ = p.send_event(Ev::Ui(v));
                    }
                };
                match v["cmd"].as_str().unwrap_or("") {
                    "init" => {
                        // langue de la page (celle de Windows, ou celle choisie dans l'application)
                        if crate::langue::definir(v["lang"].as_str().unwrap_or("")) {
                            window.set_title(crate::langue::tr(if mode == Mode::Setup { "Installer la Boîte à outils" } else { "Boîte à outils — désinstaller ou réparer" }));
                        }
                        send(json!({
                            "type": "init",
                            "mode": if mode == Mode::Setup { "setup" } else { "maintenance" },
                            "existing": install::installed_dir().is_some(),
                            "installedVersion": install::installed_version(),
                            "previous": install::previous_installs(),
                            "opts": Options::default(),
                            "version": env!("CARGO_PKG_VERSION"),
                        }))
                    }
                    "browse" => {
                        if let Some(d) = crate::shell::pick_folder(window.hwnd() as isize, crate::langue::tr("Dossier d'installation de la Boîte à outils")) {
                            let p = std::path::PathBuf::from(&d);
                            let d = if p.file_name().is_some_and(|n| n.eq_ignore_ascii_case("BoiteAOutils")) { p } else { p.join("BoiteAOutils") };
                            send(json!({ "type": "dir", "dir": d.to_string_lossy() }));
                        }
                    }
                    "run" => {
                        let task = v["task"].as_str().unwrap_or("").to_string();
                        let opts: Options = serde_json::from_value(v["opts"].clone()).unwrap_or_default();
                        std::thread::spawn(move || {
                            let step = |s: &str| send(json!({ "type": "step", "text": s }));
                            let r = match task.as_str() {
                                "install" => install::install(&opts, &step),
                                "repair" => install::repair(&step),
                                "uninstall" => install::uninstall(false, &step).map(|_| Vec::new()),
                                "uninstall-all" => install::uninstall(true, &step).map(|_| Vec::new()),
                                _ => Err("action inconnue".into()),
                            };
                            if r.is_ok() && task.starts_with("uninstall") {
                                UNINSTALLED.store(true, Ordering::Relaxed);
                            }
                            match r {
                                Ok(notes) => send(json!({ "type": "done", "ok": true, "notes": notes })),
                                Err(e) => send(json!({ "type": "done", "ok": false, "error": e })),
                            }
                        });
                    }
                    "launch" => {
                        let dir = install::installed_dir().unwrap_or_else(install::default_dir);
                        let _ = std::process::Command::new(dir.join(install::APP_EXE)).current_dir(&dir).spawn();
                    }
                    "close" => *flow = ControlFlow::Exit,
                    _ => {}
                }
            }
            Event::WindowEvent { event: WindowEvent::CloseRequested, .. } => *flow = ControlFlow::Exit,
            Event::LoopDestroyed => {
                if UNINSTALLED.load(Ordering::Relaxed) {
                    install::finish_uninstall();
                }
            }
            _ => {}
        }
    });
}
