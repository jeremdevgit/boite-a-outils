// SPDX-License-Identifier: GPL-3.0-or-later — Copyright (C) 2026 jeremdevgit — voir LICENSE
//! Suite Sysinternals : liste des fichiers autorisés, état local, lancement
//! (fenêtre pour les outils graphiques, sortie capturée pour la ligne de commande).

use crate::win::NO_WINDOW;
use serde_json::{json, Value};
use std::io::Read;
use std::os::windows::process::CommandExt;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};

/// Seuls ces fichiers de live.sysinternals.com peuvent être téléchargés et lancés.
const FILES: &[&str] = &[
    "accesschk64.exe", "AccessEnum.exe", "ADExplorer64.exe", "ADInsight64.exe", "adrestore64.exe", "Autologon64.exe", "Autoruns64.exe", "autorunsc64.exe",
    "Bginfo64.exe", "Cacheset64.exe", "Clockres64.exe", "Contig64.exe", "Coreinfo64.exe", "CPUSTRES64.EXE", "ctrl2cap.exe", "dbgview64.exe", "Desktops64.exe",
    "disk2vhd64.exe", "diskext64.exe", "Diskmon64.exe", "DiskView64.exe", "du64.exe", "efsdump.exe", "FindLinks64.exe", "handle64.exe", "hex2dec64.exe",
    "junction64.exe", "ldmdump.exe", "Listdlls64.exe", "livekd64.exe", "LoadOrd64.exe", "LoadOrdC64.exe", "logonsessions64.exe", "movefile64.exe",
    "notmyfault64.exe", "notmyfaultc64.exe", "ntfsinfo64.exe", "pendmoves64.exe", "pipelist64.exe", "portmon.exe", "procdump64.exe", "procexp64.exe",
    "Procmon64.exe", "PsExec64.exe", "psfile64.exe", "PsGetsid64.exe", "PsInfo64.exe", "pskill64.exe", "pslist64.exe", "PsLoggedon64.exe",
    "psloglist64.exe", "pspasswd64.exe", "psping64.exe", "PsService64.exe", "psshutdown64.exe", "pssuspend64.exe", "RAMMap64.exe", "RDCMan.exe",
    "RegDelNull64.exe", "regjump.exe", "ru64.exe", "sdelete64.exe", "ShareEnum64.exe", "ShellRunas.exe", "sigcheck64.exe", "streams64.exe",
    "strings64.exe", "sync64.exe", "Sysmon64.exe", "tcpvcon64.exe", "tcpview64.exe", "Testlimit64.exe", "vmmap64.exe", "Volumeid64.exe", "whois64.exe",
    "Winobj64.exe", "ZoomIt64.exe",
];

pub fn allowed(f: &str) -> bool {
    FILES.contains(&f)
}

fn dir() -> PathBuf {
    crate::win::data_dir().join("sysinternals")
}

/// Fichiers déjà téléchargés : { nom: { size, date } }.
pub fn state() -> Value {
    let mut m = serde_json::Map::new();
    if let Ok(rd) = std::fs::read_dir(dir()) {
        for e in rd.flatten() {
            let name = e.file_name().to_string_lossy().to_string();
            if let (true, Ok(md)) = (allowed(&name), e.metadata()) {
                let t = md.modified().ok().and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok()).map(|d| d.as_secs()).unwrap_or(0);
                m.insert(name, json!({ "size": md.len(), "date": t }));
            }
        }
    }
    Value::Object(m)
}

/// Lance un outil déjà vérifié. Graphique : détaché. Ligne de commande :
/// sortie renvoyée (2 Mo au plus), arrêt possible avec `cancel`.
pub fn run(file: &str, args: &str, gui: bool, eula: bool, cancel: &AtomicBool, progress: &dyn Fn(&str)) -> Result<Value, String> {
    let path = dir().join(file);
    let mut cmd = Command::new(&path);
    cmd.current_dir(dir());
    let line = format!("{}{}", if eula { "-accepteula " } else { "" }, args.trim());
    if !line.trim().is_empty() {
        cmd.raw_arg(line.trim());
    }
    if gui {
        cmd.spawn().map_err(|e| e.to_string())?;
        return Ok(json!({ "started": true }));
    }
    let mut child = cmd.creation_flags(NO_WINDOW).stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped()).spawn().map_err(|e| e.to_string())?;
    let read = |mut r: Box<dyn Read + Send>| {
        std::thread::spawn(move || {
            let mut all = Vec::new();
            let mut buf = [0u8; 8192];
            // au-delà de 2 Mo la sortie est lue puis jetée : arrêter de la lire
            // bloquerait l'outil sur un tampon plein, et il ne finirait jamais
            while let Ok(n) = r.read(&mut buf) {
                if n == 0 {
                    break;
                }
                if all.len() < 2 << 20 {
                    all.extend_from_slice(&buf[..n]);
                }
            }
            all
        })
    };
    let out = read(Box::new(child.stdout.take().unwrap()));
    let err = read(Box::new(child.stderr.take().unwrap()));
    let start = std::time::Instant::now();
    let mut shown = u64::MAX;
    let code = loop {
        if let Ok(Some(s)) = child.try_wait() {
            break s.code().unwrap_or(-1);
        }
        if cancel.load(Ordering::Relaxed) {
            let _ = child.kill();
            let _ = child.wait();
            break -2;
        }
        if start.elapsed().as_secs() != shown {
            shown = start.elapsed().as_secs();
            progress(&format!("En cours… {shown} s"));
        }
        std::thread::sleep(std::time::Duration::from_millis(250));
    };
    let mut text = crate::ps::decode(&out.join().unwrap_or_default());
    let e = crate::ps::decode(&err.join().unwrap_or_default());
    if !e.trim().is_empty() {
        text.push('\n');
        text.push_str(&e);
    }
    Ok(json!({ "code": code, "output": text.replace("\r\n", "\n") }))
}
