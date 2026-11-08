// SPDX-License-Identifier: GPL-3.0-or-later — Copyright (C) 2026 jeremdevgit — voir LICENSE
//! Scripts PowerShell intégrés à l'exécutable et outils système (SFC, DISM,
//! chkdsk, defrag) lancés sans fenêtre, avec leur progression.

use crate::win::{system_tool, NO_WINDOW};
use serde_json::Value;
use std::io::Read;
use std::os::windows::process::CommandExt;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

/// Scripts intégrés : jamais lus depuis le disque (personne ne peut les
/// modifier entre deux exécutions en administrateur).
pub fn script(name: &str) -> Option<&'static str> {
    Some(match name {
        "startup" => include_str!("../ps/startup.ps1"),
        "startup_set" => include_str!("../ps/startup_set.ps1"),
        "services" => include_str!("../ps/services.ps1"),
        "service_set" => include_str!("../ps/service_set.ps1"),
        "processes" => include_str!("../ps/processes.ps1"),
        "reg" => include_str!("../ps/reg.ps1"),
        "programs" => include_str!("../ps/programs.ps1"),
        "registry" => include_str!("../ps/registry.ps1"),
        "shortcuts" => include_str!("../ps/shortcuts.ps1"),
        "disks" => include_str!("../ps/disks.ps1"),
        "restore" => include_str!("../ps/restore.ps1"),
        "system" => include_str!("../ps/system.ps1"),
        "apps" => include_str!("../ps/apps.ps1"),
        "features" => include_str!("../ps/features.ps1"),
        "power" => include_str!("../ps/power.ps1"),
        "repair" => include_str!("../ps/repair.ps1"),
        "sysint" => include_str!("../ps/sysint.ps1"),
        "winget_path" => include_str!("../ps/winget_path.ps1"),
        "hwinfo" => include_str!("../ps/hwinfo.ps1"),
        "godmode" => include_str!("../ps/godmode.ps1"),
        "personal" => include_str!("../ps/personal.ps1"),
        "capture" => include_str!("../ps/capture.ps1"),
        "games" => include_str!("../ps/games.ps1"),
        "backup_scan" => include_str!("../ps/backup_scan.ps1"),
        "drivers" => include_str!("../ps/drivers.ps1"),
        "drvcat" => include_str!("../ps/drvcat.ps1"),
        "hwplus" => include_str!("../ps/hwplus.ps1"),
        "webview2" => include_str!("../ps/webview2.ps1"),
        _ => return None,
    })
}

const PRELUDE: &str = r#"$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';$WarningPreference='SilentlyContinue'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$A=if($env:BAO_ARGS){$env:BAO_ARGS|ConvertFrom-Json}else{[pscustomobject]@{}}
function Out-Json($o){[Console]::Out.WriteLine(($o|ConvertTo-Json -Depth 6 -Compress))}
try {
"#;
const EPILOGUE: &str = r#"
} catch { [Console]::Out.WriteLine((@{__error=$_.Exception.Message}|ConvertTo-Json -Compress)); exit 1 }
"#;

fn base64(bytes: &[u8]) -> String {
    const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut s = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for c in bytes.chunks(3) {
        let n = (c[0] as u32) << 16
            | (*c.get(1).unwrap_or(&0) as u32) << 8
            | *c.get(2).unwrap_or(&0) as u32;
        s.push(T[(n >> 18) as usize & 63] as char);
        s.push(T[(n >> 12) as usize & 63] as char);
        s.push(if c.len() > 1 {
            T[(n >> 6) as usize & 63] as char
        } else {
            '='
        });
        s.push(if c.len() > 2 {
            T[n as usize & 63] as char
        } else {
            '='
        });
    }
    s
}

/// Sur un PC abîmé (WMI cassé, disque mourant) une requête peut ne jamais finir :
/// l'interface ne doit pas attendre indéfiniment. Marge large, réparations et
/// recherches de pilotes étant lentes par nature.
fn time_limit(name: &str) -> Duration {
    Duration::from_secs(match name {
        "repair" | "drivers" | "drvcat" | "features" | "restore" | "webview2" | "sysint"
        | "apps" | "programs" | "backup_scan" => 3600,
        _ => 600,
    })
}

fn is_user_scoped_operation(name: &str, args: &Value) -> bool {
    let user_key = args["key"].as_str().unwrap_or("").to_ascii_uppercase();
    (name == "programs"
        && matches!(args["action"].as_str(), Some("uninstall" | "stop"))
        && (user_key.starts_with("HKEY_CURRENT_USER\\") || user_key.starts_with("HKCU:\\")))
        || (name == "repair"
            && matches!(
                args["action"].as_str(),
                Some("history" | "iconcache" | "spotlight" | "godmode")
            ))
}

struct Output {
    stdout: Vec<u8>,
    stderr: Vec<u8>,
}

/// Attend la fin du processus et lit ses sorties ; une fois le délai dépassé,
/// arrête toute son arborescence et renvoie `None`.
fn wait_limited(child: &mut Child, limit: Duration) -> Option<Output> {
    fn drain(mut r: impl Read + Send + 'static) -> std::thread::JoinHandle<Vec<u8>> {
        std::thread::spawn(move || {
            let mut b = Vec::new();
            let _ = r.read_to_end(&mut b);
            b
        })
    }
    let out = child.stdout.take().map(drain);
    let err = child.stderr.take().map(drain);
    let start = Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(_)) | Err(_) => break,
            Ok(None) if start.elapsed() > limit => {
                let _ = Command::new(system_tool("taskkill.exe"))
                    .args(["/PID", &child.id().to_string(), "/T", "/F"])
                    .creation_flags(NO_WINDOW)
                    .status();
                let _ = child.kill();
                let _ = child.wait();
                return None;
            }
            Ok(None) => std::thread::sleep(Duration::from_millis(40)),
        }
    }
    let get = |h: Option<std::thread::JoinHandle<Vec<u8>>>| {
        h.and_then(|h| h.join().ok()).unwrap_or_default()
    };
    Some(Output {
        stdout: get(out),
        stderr: get(err),
    })
}

/// Exécute un script intégré ; ses arguments passent en JSON par une variable
/// d'environnement (jamais insérés dans le texte du script). Le script écrit
/// un seul objet JSON avec Out-Json.
pub fn run(name: &str, args: &Value) -> Result<Value, String> {
    let body = script(name).ok_or_else(|| format!("script inconnu : {name}"))?;
    let full = format!("{PRELUDE}{body}{EPILOGUE}");
    let utf16: Vec<u8> = full.encode_utf16().flat_map(|u| u.to_le_bytes()).collect();
    let encoded = base64(&utf16);
    // ligne de commande Windows limitée à 32 767 caractères
    if encoded.len() > 32_000 {
        return Err(format!(
            "script {name} trop long ({} caractères encodés)",
            encoded.len()
        ));
    }
    let ps = system_tool("WindowsPowerShell\\v1.0\\powershell.exe");
    let user_operation = is_user_scoped_operation(name, args);
    let system = system_tool("");
    let safe_path = format!(
        "{};{};{}",
        system.display(),
        system_tool("Wbem").display(),
        ps.parent().unwrap().display()
    );
    let modules = ps
        .parent()
        .unwrap()
        .join("Modules")
        .to_string_lossy()
        .into_owned();
    let env = [
        ("BAO_ARGS", args.to_string()),
        (
            "BAO_DATA",
            if user_operation {
                crate::win::data_dir()
            } else {
                crate::win::operation_data_dir()?
            }
            .to_string_lossy()
            .into_owned(),
        ),
        ("PATH", safe_path),
        ("PSModulePath", modules),
    ];
    let arguments = [
        "-NoProfile",
        "-NonInteractive",
        "-ExecutionPolicy",
        "Bypass",
        "-EncodedCommand",
        &encoded,
    ];
    let limit = time_limit(name);
    let out = if user_operation && crate::win::is_elevated() {
        let result =
            crate::user_context::output(&ps, &arguments, &env, limit).map_err(|e| e.to_string())?;
        Output {
            stdout: result.stdout,
            stderr: result.stderr,
        }
    } else {
        let mut child = Command::new(&ps)
            .args(arguments)
            .envs(env)
            .creation_flags(NO_WINDOW)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|e| format!("PowerShell introuvable : {e}"))?;
        wait_limited(&mut child, limit).ok_or_else(|| {
            format!(
                "{name} : aucune réponse de Windows après {} minutes, opération arrêtée",
                limit.as_secs() / 60
            )
        })?
    };
    let text = String::from_utf8_lossy(&out.stdout);
    let line = text
        .lines()
        .rev()
        .find(|l| l.starts_with('{') || l.starts_with('['))
        .unwrap_or("");
    let mut v: Value = serde_json::from_str(line).map_err(|_| {
        let err = String::from_utf8_lossy(&out.stderr);
        let first = err
            .lines()
            .find(|l| !l.trim().is_empty() && !l.starts_with("#<"))
            .unwrap_or("réponse illisible");
        format!("{name} : {}", first.trim())
    })?;
    if let Some(e) = v.get("__error").and_then(|e| e.as_str()) {
        return Err(e.to_string());
    }
    // A lower-authority reply is display data, never a source of elevated undo.
    if user_operation {
        if let Some(object) = v.as_object_mut() {
            object.remove("undo");
        }
    }
    Ok(v)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn user_owned_operations_run_without_admin_authority() {
        assert!(is_user_scoped_operation("repair", &serde_json::json!({"action":"history"})));
        for action in ["iconcache", "spotlight", "godmode"] {
            assert!(is_user_scoped_operation("repair", &serde_json::json!({"action":action})));
        }
        assert!(is_user_scoped_operation(
            "programs",
            &serde_json::json!({"action":"uninstall","key":"HKEY_CURRENT_USER\\Software\\x"})
        ));
        assert!(!is_user_scoped_operation("repair", &serde_json::json!({"action":"wureset"})));
        assert!(!is_user_scoped_operation("repair", &serde_json::json!({"action":"battery"})));
        assert!(!is_user_scoped_operation(
            "programs",
            &serde_json::json!({"action":"uninstall","key":"HKEY_LOCAL_MACHINE\\Software\\x"})
        ));
    }
}

/// Décode la sortie d'un outil : UTF-16 (sfc), UTF-8, ou page de code OEM de
/// la console (ipconfig, defrag, dism écrivent en 850 même après chcp 65001).
pub fn decode(bytes: &[u8]) -> String {
    let zeros = bytes
        .iter()
        .skip(1)
        .step_by(2)
        .take(400)
        .filter(|b| **b == 0)
        .count();
    if bytes.len() > 4 && zeros * 3 > bytes.len().min(800) / 2 {
        let u: Vec<u16> = bytes
            .chunks_exact(2)
            .map(|c| u16::from_le_bytes([c[0], c[1]]))
            .collect();
        return String::from_utf16_lossy(&u);
    }
    if let Ok(s) = std::str::from_utf8(bytes) {
        return s.to_string();
    }
    // selon l'outil : page OEM (850) ou ANSI (1252) ; on garde celle qui donne
    // des lettres accentuées françaises plutôt que des symboles
    use windows_sys::Win32::Globalization::{MultiByteToWideChar, CP_ACP, CP_OEMCP};
    let conv = |cp: u32| unsafe {
        let n = MultiByteToWideChar(
            cp,
            0,
            bytes.as_ptr(),
            bytes.len() as i32,
            std::ptr::null_mut(),
            0,
        );
        if n <= 0 {
            return String::new();
        }
        let mut out = vec![0u16; n as usize];
        MultiByteToWideChar(
            cp,
            0,
            bytes.as_ptr(),
            bytes.len() as i32,
            out.as_mut_ptr(),
            n,
        );
        String::from_utf16_lossy(&out)
    };
    let score = |s: &str| {
        s.chars()
            .filter(|c| "éèàùçêâôîûëïÉÈÀ’«»".contains(*c))
            .count() as i64
            - s.chars().filter(|c| "ÚÆáÞÔ┬├│┤╗▒░█".contains(*c)).count() as i64
    };
    let (oem, ansi) = (conv(CP_OEMCP), conv(CP_ACP));
    if oem.is_empty() && ansi.is_empty() {
        return String::from_utf8_lossy(bytes).into_owned();
    }
    if score(&ansi) > score(&oem) {
        ansi
    } else {
        oem
    }
}

/// Lance un outil de System32 en UTF-8, transmet chaque nouvelle ligne à
/// `progress` et renvoie (code de sortie, texte complet).
pub fn tool(
    exe: &str,
    args: &[&str],
    mut progress: impl FnMut(&str),
) -> Result<(i32, String), String> {
    let cmd = system_tool("cmd.exe");
    let line = format!(
        "chcp 65001>nul & \"{}\" {}",
        system_tool(exe).display(),
        args.join(" ")
    );
    let mut child = Command::new(cmd)
        .raw_arg(format!("/d /s /c \"{line}\""))
        .creation_flags(NO_WINDOW)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| e.to_string())?;
    let mut stdout = child.stdout.take().unwrap();
    // erreurs lues en parallèle : un tampon d'erreurs plein bloquerait l'outil
    let stderr = child.stderr.take().map(|mut e| {
        std::thread::spawn(move || {
            let mut err = Vec::new();
            let _ = e.read_to_end(&mut err);
            err
        })
    });
    let mut all = Vec::new();
    let mut buf = [0u8; 4096];
    let mut last = String::new();
    loop {
        match stdout.read(&mut buf) {
            Ok(0) | Err(_) => break,
            Ok(n) => {
                all.extend_from_slice(&buf[..n]);
                // dernière ligne non vide (les outils réécrivent leur progression avec \r),
                // cherchée dans la fin du texte seulement (DISM écrit des milliers de mises à jour)
                let text = decode(&all[all.len().saturating_sub(4096) & !1..]);
                if let Some(l) = text
                    .rsplit(['\r', '\n'])
                    .map(str::trim)
                    .find(|l| !l.is_empty())
                {
                    if l != last {
                        last = l.to_string();
                        progress(&last);
                    }
                }
            }
        }
    }
    let err = stderr.and_then(|h| h.join().ok()).unwrap_or_default();
    let code = child.wait().map(|s| s.code().unwrap_or(-1)).unwrap_or(-1);
    let mut text = decode(&all);
    if !err.is_empty() {
        text.push('\n');
        text.push_str(&decode(&err));
    }
    // lignes de progression intermédiaires retirées du compte rendu
    let clean: Vec<&str> = text
        .split(['\r', '\n'])
        .map(str::trim_end)
        .filter(|l| !l.trim().is_empty())
        .collect();
    let mut dedup: Vec<&str> = Vec::new();
    for l in clean {
        let is_progress = l.contains('%') && (l.contains('[') || l.len() < 60);
        if is_progress && dedup.last().is_some_and(|p| p.contains('%')) {
            dedup.pop();
        }
        dedup.push(l);
    }
    Ok((code, dedup.join("\n")))
}
