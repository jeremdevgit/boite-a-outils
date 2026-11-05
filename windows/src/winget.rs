// SPDX-License-Identifier: GPL-3.0-or-later — Copyright (C) 2026 jeremdevgit — voir LICENSE
//! Gestionnaire de paquets de Windows : inventaire, installation, téléchargement
//! des installateurs. Lancé sans shell, l'identifiant du paquet est validé.

use crate::win::NO_WINDOW;
use serde_json::{json, Value};
use std::io::Read;
use std::os::windows::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

const ACCEPT: [&str; 3] = ["--accept-source-agreements", "--disable-interactivity", "--nowarn"];

pub fn exe() -> PathBuf {
    let alias = std::env::var_os("LOCALAPPDATA").map(|l| PathBuf::from(l).join("Microsoft\\WindowsApps\\winget.exe"));
    alias.filter(|p| p.exists()).unwrap_or_else(|| "winget.exe".into())
}

pub fn available() -> bool {
    Command::new(exe()).arg("--version").creation_flags(NO_WINDOW).stdin(Stdio::null()).output().is_ok_and(|o| o.status.success())
}

/// Identifiant de paquet : jamais d'espace ni de caractère de ligne de commande.
pub fn valid_id(id: &str) -> bool {
    !id.is_empty() && id.len() < 128 && !id.starts_with('-') && id.chars().all(|c| c.is_ascii_alphanumeric() || "._+-".contains(c))
}

/// Tableau de `winget list` : colonnes repérées par la position des titres.
fn parse_table(text: &str) -> Vec<Value> {
    let lines: Vec<&str> = text.split(['\n', '\r']).collect();
    let Some(sep) = lines.iter().position(|l| l.len() > 20 && l.trim().chars().all(|c| c == '-')) else { return vec![] };
    let head: Vec<char> = lines[..sep].iter().rev().find(|l| !l.trim().is_empty()).unwrap_or(&"").chars().collect();
    let mut cols = Vec::new();
    for i in 0..head.len() {
        if head[i] != ' ' && (i == 0 || (head[i - 1] == ' ' && (i < 2 || head[i - 2] == ' ' || cols.is_empty()))) {
            cols.push(i);
        }
    }
    // Nom, ID, Version, [Disponible], [Source]
    if cols.len() < 3 {
        return vec![];
    }
    let mut out = Vec::new();
    for l in &lines[sep + 1..] {
        let ch: Vec<char> = l.chars().collect();
        if ch.len() <= cols[1] {
            continue;
        }
        let cell = |i: usize| -> String {
            let (a, b) = (cols[i], cols.get(i + 1).copied().unwrap_or(ch.len()));
            ch[a.min(ch.len())..b.min(ch.len())].iter().collect::<String>().trim().to_string()
        };
        let name = cell(0);
        let id = cell(1);
        if name.is_empty() || id.contains(' ') && !id.starts_with("ARP\\") && !id.starts_with("MSIX\\") {
            continue;
        }
        let (avail, source) = match cols.len() {
            5 => (cell(3), cell(4)),
            4 => (String::new(), cell(3)),
            _ => (String::new(), String::new()),
        };
        out.push(json!({ "name": name, "id": id, "version": cell(2), "available": avail, "source": source }));
    }
    out
}

pub fn list() -> Result<Value, String> {
    let o = Command::new(exe()).args(["list"]).args(ACCEPT).creation_flags(NO_WINDOW).stdin(Stdio::null()).output().map_err(|_| "winget indisponible sur ce PC".to_string())?;
    Ok(json!({ "items": parse_table(&crate::ps::decode(&o.stdout)) }))
}

/// Exécute winget, transmet la dernière ligne lisible, s'arrête sur annulation.
fn stream(args: &[&str], cancel: &AtomicBool, progress: &dyn Fn(&str)) -> Result<i32, String> {
    let mut child = Command::new(exe()).args(args).args(ACCEPT).creation_flags(NO_WINDOW).stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::null()).spawn().map_err(|_| "winget indisponible sur ce PC".to_string())?;
    let mut out = child.stdout.take().ok_or("sortie indisponible")?;
    let (tx, rx) = std::sync::mpsc::channel::<Vec<u8>>();
    std::thread::spawn(move || {
        let mut b = [0u8; 2048];
        while let Ok(n) = out.read(&mut b) {
            if n == 0 || tx.send(b[..n].to_vec()).is_err() {
                break;
            }
        }
    });
    let mut last = String::new();
    loop {
        if cancel.load(Ordering::Relaxed) {
            let _ = child.kill();
            return Err("annulé".into());
        }
        match rx.recv_timeout(Duration::from_millis(200)) {
            Ok(chunk) => {
                let t = crate::ps::decode(&chunk);
                // on ignore l'animation de winget (\ | / -)
                if let Some(l) = t.split(['\r', '\n']).map(str::trim).rfind(|l| l.chars().count() > 3) {
                    if l != last {
                        last = l.to_string();
                        progress(&last);
                    }
                }
            }
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {}
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
        }
    }
    child.wait().map(|s| s.code().unwrap_or(-1)).map_err(|e| e.to_string())
}

fn explain(code: i32) -> String {
    match code as u32 {
        0 => "ok".into(),
        0x8A15_0014 => "paquet introuvable dans les sources".into(),
        0x8A15_002B => "aucune version plus récente applicable".into(),
        0x8A15_0061 => "déjà installé".into(),
        0x8A15_0056 | 0x8A15_0101 => "installateur non téléchargeable (magasin ou licence)".into(),
        0x8A15_0109 => "un redémarrage est nécessaire".into(),
        c => format!("échec (code 0x{c:08X})"),
    }
}

pub fn install(id: &str, cancel: &AtomicBool, progress: &dyn Fn(&str)) -> Result<Value, String> {
    if !valid_id(id) {
        return Err("identifiant de paquet invalide".into());
    }
    let code = stream(&["install", "--id", id, "-e", "--silent", "--accept-package-agreements"], cancel, progress)?;
    Ok(json!({ "ok": code == 0 || code as u32 == 0x8A15_0061, "message": explain(code) }))
}

pub fn upgrade_all(cancel: &AtomicBool, progress: &dyn Fn(&str)) -> Result<Value, String> {
    let code = stream(&["upgrade", "--all", "--silent", "--accept-package-agreements"], cancel, progress)?;
    Ok(json!({ "ok": code == 0, "message": explain(code) }))
}

/// Dernier installateur du paquet, dans `dir`.
pub fn download(id: &str, dir: &Path, cancel: &AtomicBool, progress: &dyn Fn(&str)) -> Result<(bool, String), String> {
    if !valid_id(id) {
        return Err("identifiant de paquet invalide".into());
    }
    let d = dir.to_string_lossy().to_string();
    let code = stream(&["download", "--id", id, "-e", "-d", &d, "--accept-package-agreements", "--skip-dependencies"], cancel, progress)?;
    Ok((code == 0, explain(code)))
}

/// Fichier d'import standard (`winget import`), `false` si impossible.
pub fn export(file: &Path) -> bool {
    Command::new(exe()).args(["export", "-o"]).arg(file).args(ACCEPT).creation_flags(NO_WINDOW).stdin(Stdio::null()).output().is_ok() && file.exists()
}
