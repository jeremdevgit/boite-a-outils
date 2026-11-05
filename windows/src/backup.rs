// SPDX-License-Identifier: GPL-3.0-or-later — Copyright (C) 2026 jeremdevgit — voir LICENSE
//! Sauvegarde propre : copie des données choisies, captures du bureau, derniers
//! installateurs, inventaire lisible et scripts de réinstallation, le tout dans
//! un seul dossier. Rien n'est supprimé ni déplacé à la source.

use crate::win::{self, w};
use serde_json::{json, Value};
use std::io::Write;
use std::os::windows::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

/// Dossiers régénérés par les logiciels : inutiles dans une sauvegarde.
const SKIP_DIRS: &[&str] = &["cache", "cache2", "caches", "code cache", "gpucache", "dawncache", "dawngraphitecache", "dawnwebgpucache", "grshadercache", "shadercache", "cachestorage", "scriptcache", "temp", "tmp", "crashdumps", "crashpad", "node_modules", "__pycache__", "inetcache", "dxcache", "glcache", "d3dscache", "nv_cache", "webcache", "blob_storage", "$recycle.bin", "system volume information"];
/// Fichiers verrouillés en permanence par Windows ou sans valeur hors de ce PC.
const SKIP_FILES: &[&str] = &["ntuser.dat", "ntuser.dat.log1", "ntuser.dat.log2", "usrclass.dat", "usrclass.dat.log1", "usrclass.dat.log2", "desktop.ini", "thumbs.db", "pagefile.sys", "hiberfil.sys"];

struct Copy<'a> {
    files: u64,
    bytes: u64,
    skipped: u64,
    errors: Vec<String>,
    dest_root: String,
    skip_caches: bool,
    cancel: &'a AtomicBool,
    last: Instant,
    progress: &'a (dyn Fn(Value) + Sync),
    label: String,
}

/// Chemin étendu : les profils contiennent souvent des chemins de plus de 260 caractères.
fn long(p: &Path) -> PathBuf {
    // le préfixe \\?\ exige un chemin strict : aucune barre « / » ni « \\ » en double
    let s = p.to_string_lossy().replace('/', "\\");
    if s.starts_with("\\\\") {
        return PathBuf::from(s);
    }
    let mut clean = String::with_capacity(s.len());
    for c in s.chars() {
        if c != '\\' || !clean.ends_with('\\') {
            clean.push(c);
        }
    }
    PathBuf::from(format!("\\\\?\\{clean}"))
}

fn norm(p: &Path) -> String {
    p.to_string_lossy().to_lowercase().trim_end_matches('\\').to_string()
}

fn walk(c: &mut Copy, src: &Path, dst: &Path) {
    if c.cancel.load(Ordering::Relaxed) || norm(src) == c.dest_root {
        return;
    }
    let rd = match std::fs::read_dir(long(src)) {
        Ok(r) => r,
        Err(e) => {
            c.errors.push(format!("{} : {e}", src.display()));
            return;
        }
    };
    let _ = std::fs::create_dir_all(long(dst));
    for e in rd.flatten() {
        if c.cancel.load(Ordering::Relaxed) {
            return;
        }
        let Ok(md) = e.metadata() else { continue };
        // jonctions (« Mes documents »…) et liens : suivis, ils copieraient deux fois ou en boucle
        if md.file_attributes() & 0x400 != 0 {
            continue;
        }
        let name = e.file_name();
        let low = name.to_string_lossy().to_lowercase();
        let (from, to) = (src.join(&name), dst.join(&name));
        if md.is_dir() {
            if c.skip_caches && SKIP_DIRS.contains(&low.as_str()) {
                continue;
            }
            walk(c, &from, &to);
            continue;
        }
        if SKIP_FILES.contains(&low.as_str()) {
            continue;
        }
        // relance possible : un fichier identique déjà copié est sauté
        if let Ok(old) = std::fs::metadata(long(&to)) {
            if old.len() == md.len() && old.last_write_time() == md.last_write_time() {
                c.skipped += 1;
                continue;
            }
        }
        match std::fs::copy(long(&from), long(&to)) {
            Ok(n) => {
                c.files += 1;
                c.bytes += n;
            }
            Err(err) => c.errors.push(format!("{} : {err}", from.display())),
        }
        if c.last.elapsed() > Duration::from_millis(250) {
            c.last = Instant::now();
            (c.progress)(json!({ "step": "data", "label": c.label, "files": c.files, "bytes": c.bytes, "errors": c.errors.len(), "current": name.to_string_lossy() }));
        }
    }
}

pub fn free_space(path: &str) -> u64 {
    let p = w(path);
    let (mut free, mut total, mut all) = (0u64, 0u64, 0u64);
    unsafe {
        if windows_sys::Win32::Storage::FileSystem::GetDiskFreeSpaceExW(p.as_ptr(), &mut free, &mut total, &mut all) != 0 {
            free
        } else {
            0
        }
    }
}

/// Sélecteur de dossier de Windows.
pub fn pick_folder() -> Option<String> {
    use windows::core::*;
    use windows::Win32::System::Com::*;
    use windows::Win32::UI::Shell::*;
    unsafe {
        let _ = CoInitializeEx(None, COINIT_APARTMENTTHREADED);
        let d: IFileOpenDialog = CoCreateInstance(&FileOpenDialog, None, CLSCTX_INPROC_SERVER).ok()?;
        d.SetOptions(FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST).ok()?;
        let owner = windows_sys::Win32::UI::WindowsAndMessaging::GetForegroundWindow();
        d.Show(Some(windows::Win32::Foundation::HWND(owner as _))).ok()?;
        let item = d.GetResult().ok()?;
        let name: PWSTR = item.GetDisplayName(SIGDN_FILESYSPATH).ok()?;
        let s = name.to_string().ok();
        CoTaskMemFree(Some(name.0 as _));
        s
    }
}

fn html(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;")
}

/// Encodage d'URL : tout sauf les caractères sûrs.
fn url_q(s: &str) -> String {
    s.bytes().map(|b| if b.is_ascii_alphanumeric() || b"-_.".contains(&b) { (b as char).to_string() } else { format!("%{b:02X}") }).collect()
}

/// Lien vers le site d'un logiciel : adresse déclarée par l'éditeur, sinon recherche web.
pub fn link_for(name: &str, url: &str) -> String {
    if (url.starts_with("https://") || url.starts_with("http://")) && !url.contains(['"', ' ', '<', '>', '^', '|', '\n', '\r']) {
        url.to_string()
    } else {
        format!("https://duckduckgo.com/?q={}", url_q(&format!("{name} télécharger site officiel")))
    }
}

/// Texte sûr dans un fichier .cmd : lettres, chiffres et ponctuation inoffensive.
fn cmd_text(s: &str) -> String {
    s.chars().filter(|c| c.is_alphanumeric() || " .-_+()".contains(*c)).collect()
}

fn write_scripts(root: &Path, programs: &[Value]) -> Result<(), String> {
    let installable: Vec<&Value> = programs.iter().filter(|p| p["kind"] == "winget" || p["kind"] == "store").filter(|p| crate::winget::valid_id(p["id"].as_str().unwrap_or(""))).collect();
    let manual: Vec<&Value> = programs.iter().filter(|p| p["kind"] == "manual").collect();
    let mut s = String::from("@echo off\r\nchcp 65001>nul\r\ntitle Reinstallation de mes logiciels\r\nwhere winget >nul 2>nul || (echo winget est absent : installez \"App Installer\" depuis le Microsoft Store. & pause & exit /b 1)\r\n");
    let n = installable.len();
    for (i, p) in installable.iter().enumerate() {
        let id = p["id"].as_str().unwrap_or("");
        let src = if p["kind"] == "store" { "msstore" } else { "winget" };
        s += &format!("echo.\r\necho [{}/{n}] {}\r\nwinget install --id {id} -e -s {src} --silent --accept-package-agreements --accept-source-agreements\r\n", i + 1, cmd_text(p["name"].as_str().unwrap_or(id)));
    }
    s += "echo.\r\necho Termine. Les logiciels sans paquet sont dans Ouvrir-les-sites.cmd\r\npause\r\n";
    std::fs::write(root.join("Tout-reinstaller.cmd"), s).map_err(|e| e.to_string())?;
    let mut o = String::from("@echo off\r\nchcp 65001>nul\r\ntitle Sites de telechargement\r\necho Ouvre une page par logiciel sans paquet automatique (");
    o += &format!("{} pages), par groupes de 10.\r\npause\r\n", manual.len());
    for (i, p) in manual.iter().enumerate() {
        let link = link_for(p["name"].as_str().unwrap_or(""), p["url"].as_str().unwrap_or("")).replace('%', "%%");
        o += &format!("start \"\" \"{link}\"\r\n");
        if (i + 1) % 10 == 0 && i + 1 < manual.len() {
            o += "pause\r\n";
        }
    }
    std::fs::write(root.join("Ouvrir-les-sites.cmd"), o).map_err(|e| e.to_string())
}

fn write_report(root: &Path, programs: &[Value], games: &[Value], dl: &[Value], summary: &str) -> Result<(), String> {
    let mut h = String::from("<!doctype html><meta charset=utf-8><title>Inventaire du PC</title><style>body{font:14px/1.5 'Segoe UI',sans-serif;max-width:1000px;margin:30px auto;padding:0 16px;color:#1b2030}h1{font-size:26px}h2{margin-top:30px;border-bottom:1px solid #ccd;padding-bottom:4px}table{border-collapse:collapse;width:100%}td,th{padding:5px 8px;border-bottom:1px solid #e4e6ee;text-align:left}code{font-size:12px}</style><h1>Inventaire de sauvegarde</h1>");
    h += &format!("<p>{}</p>", html(summary));
    let name = |p: &Value| html(p["name"].as_str().unwrap_or(""));
    let ver = |p: &Value| html(p["version"].as_str().unwrap_or(""));
    h += "<h2>Logiciels réinstallables automatiquement</h2><p>Lancez <b>Tout-reinstaller.cmd</b> après la réinstallation de Windows.</p><table><tr><th>Logiciel</th><th>Version</th><th>Identifiant</th><th>Source</th></tr>";
    for p in programs.iter().filter(|p| p["kind"] == "winget" || p["kind"] == "store") {
        h += &format!("<tr><td>{}</td><td>{}</td><td><code>{}</code></td><td>{}</td></tr>", name(p), ver(p), html(p["id"].as_str().unwrap_or("")), if p["kind"] == "store" { "Microsoft Store" } else { "winget" });
    }
    h += "</table><h2>Logiciels à réinstaller à la main</h2><p>Aucun paquet automatique. Le lien mène au site indiqué par l'éditeur, sinon à une recherche web : vérifiez que vous êtes bien sur le site officiel.</p><table><tr><th>Logiciel</th><th>Version</th><th>Lien</th></tr>";
    for p in programs.iter().filter(|p| p["kind"] == "manual") {
        let l = html(&link_for(p["name"].as_str().unwrap_or(""), p["url"].as_str().unwrap_or("")));
        h += &format!("<tr><td>{}</td><td>{}</td><td><a href=\"{l}\">Ouvrir</a></td></tr>", name(p), ver(p));
    }
    h += "</table><h2>Jeux</h2><p>Non sauvegardés : à retélécharger depuis leur plateforme.</p><table><tr><th>Jeu</th><th>Plateforme</th><th>Emplacement</th></tr>";
    for g in games {
        h += &format!("<tr><td>{}</td><td>{}</td><td><code>{}</code></td></tr>", name(g), html(g["platform"].as_str().unwrap_or("")), html(g["path"].as_str().unwrap_or("")));
    }
    h += "</table>";
    if !dl.is_empty() {
        h += "<h2>Installateurs téléchargés</h2><table><tr><th>Paquet</th><th>Résultat</th></tr>";
        for d in dl {
            h += &format!("<tr><td>{}</td><td>{}</td></tr>", html(d["id"].as_str().unwrap_or("")), html(d["message"].as_str().unwrap_or("")));
        }
        h += "</table>";
    }
    std::fs::write(root.join("Inventaire.html"), h).map_err(|e| e.to_string())
}

pub fn run(a: &Value, cancel: &AtomicBool, progress: &(dyn Fn(Value) + Sync)) -> Result<Value, String> {
    let dest = PathBuf::from(a["dest"].as_str().unwrap_or(""));
    if !dest.is_dir() {
        return Err("dossier de destination introuvable".into());
    }
    let stamp: String = a["stamp"].as_str().unwrap_or("sauvegarde").chars().filter(|c| c.is_ascii_alphanumeric() || *c == '-').collect();
    let root = dest.join(format!("Sauvegarde-{}-{stamp}", std::env::var("COMPUTERNAME").unwrap_or_else(|_| "PC".into())));
    std::fs::create_dir_all(&root).map_err(|e| format!("destination non inscriptible : {e}"))?;
    let empty = vec![];
    let items = a["items"].as_array().unwrap_or(&empty);
    let programs = a["programs"].as_array().unwrap_or(&empty);
    let games = a["games"].as_array().unwrap_or(&empty);
    let mut report = Vec::new();

    // 1. captures d'écran : d'abord, avant que quoi que ce soit ne change sur le bureau
    if a["captures"].as_bool().unwrap_or(false) {
        progress(json!({ "step": "captures", "label": "Captures du bureau" }));
        let dir = root.join("Captures");
        match crate::ps::run("capture", &json!({ "dir": dir, "minimize": a["minimize"].as_bool().unwrap_or(true) })) {
            Ok(v) => report.push(format!("{} capture(s) du bureau", v["files"].as_array().map_or(0, |f| f.len()))),
            Err(e) => report.push(format!("Captures impossibles : {e}")),
        }
    }

    // 2. données
    let mut c = Copy { files: 0, bytes: 0, skipped: 0, errors: Vec::new(), dest_root: norm(&root), skip_caches: a["skipCaches"].as_bool().unwrap_or(true), cancel, last: Instant::now(), progress, label: String::new() };
    for it in items {
        let src = PathBuf::from(it["path"].as_str().unwrap_or(""));
        let id: String = it["label"].as_str().unwrap_or("Dossier").chars().map(|x| if "\\/:*?\"<>|".contains(x) { '_' } else { x }).collect();
        c.label = id.clone();
        progress(json!({ "step": "data", "label": id, "files": c.files, "bytes": c.bytes, "errors": c.errors.len() }));
        if src.is_file() {
            let to = root.join("Donnees").join(&id);
            let _ = std::fs::create_dir_all(&to);
            match src.file_name().map(|n| std::fs::copy(&src, to.join(n))) {
                Some(Ok(n)) => {
                    c.files += 1;
                    c.bytes += n;
                }
                Some(Err(e)) => c.errors.push(format!("{} : {e}", src.display())),
                None => {}
            }
        } else if src.is_dir() {
            walk(&mut c, &src, &root.join("Donnees").join(&id));
        } else {
            c.errors.push(format!("{} : introuvable", src.display()));
        }
    }
    let (files, bytes, skipped, errors) = (c.files, c.bytes, c.skipped, std::mem::take(&mut c.errors));

    // 3. installateurs
    let mut dl = Vec::new();
    let ids = a["download"].as_array().unwrap_or(&empty);
    for (i, id) in ids.iter().filter_map(|x| x.as_str()).enumerate() {
        if cancel.load(Ordering::Relaxed) {
            break;
        }
        progress(json!({ "step": "installers", "label": id, "index": i + 1, "total": ids.len() }));
        let dir = root.join("Installateurs").join(id);
        let _ = std::fs::create_dir_all(&dir);
        let r = crate::winget::download(id, &dir, cancel, &|l| progress(json!({ "step": "installers", "label": id, "index": i + 1, "total": ids.len(), "line": l })));
        let (ok, message) = r.unwrap_or_else(|e| (false, e));
        if !ok {
            let _ = std::fs::remove_dir(&dir);
        }
        dl.push(json!({ "id": id, "ok": ok, "message": message }));
    }

    // 4. pilotes et Wi-Fi
    if a["drivers"].as_bool().unwrap_or(false) && !cancel.load(Ordering::Relaxed) {
        progress(json!({ "step": "extra", "label": "Export des pilotes" }));
        let dir = root.join("Pilotes");
        let _ = std::fs::create_dir_all(&dir);
        let arg = format!("\"{}\"", dir.display());
        match crate::ps::tool("pnputil.exe", &["/export-driver", "*", &arg], |l| progress(json!({ "step": "extra", "label": "Export des pilotes", "line": l }))) {
            Ok((0, _)) => report.push("Pilotes exportés dans Pilotes\\ (réinstallables avec pnputil /add-driver)".to_string()),
            Ok((code, _)) => report.push(format!("Export des pilotes incomplet (code {code})")),
            Err(e) => report.push(format!("Export des pilotes impossible : {e}")),
        }
    }
    if a["wifi"].as_bool().unwrap_or(false) && !cancel.load(Ordering::Relaxed) {
        progress(json!({ "step": "extra", "label": "Réseaux Wi-Fi" }));
        let dir = root.join("Wi-Fi");
        let _ = std::fs::create_dir_all(&dir);
        let arg = format!("folder=\"{}\"", dir.display());
        match crate::ps::tool("netsh.exe", &["wlan", "export", "profile", &arg, "key=clear"], |_| {}) {
            Ok((0, _)) => report.push("Réseaux Wi-Fi exportés : ces fichiers contiennent les mots de passe en clair".to_string()),
            Ok(_) => report.push("Aucun réseau Wi-Fi exporté (pas de carte Wi-Fi ou aucun réseau enregistré)".to_string()),
            Err(e) => report.push(format!("Export Wi-Fi impossible : {e}")),
        }
    }

    // 5. inventaire et scripts, écrits en dernier mais même après une annulation
    progress(json!({ "step": "report", "label": "Inventaire et scripts" }));
    let cancelled = cancel.load(Ordering::Relaxed);
    let ok_dl = dl.iter().filter(|d| d["ok"] == true).count();
    report.insert(0, format!("{files} fichiers copiés ({:.2} Go), {skipped} déjà à jour, {} erreur(s)", bytes as f64 / 1e9, errors.len()));
    if !dl.is_empty() {
        report.push(format!("{ok_dl} installateur(s) téléchargé(s) sur {}", dl.len()));
    }
    if cancelled {
        report.push("Sauvegarde interrompue : relancez-la pour compléter (les fichiers déjà copiés sont conservés).".to_string());
    }
    let summary = report.join(" · ");
    write_scripts(&root, programs)?;
    let _ = crate::winget::export(&root.join("winget-import.json"));
    write_report(&root, programs, games, &dl, &summary)?;
    if !errors.is_empty() {
        if let Ok(mut f) = std::fs::File::create(root.join("Erreurs de copie.txt")) {
            let _ = f.write_all(errors.join("\r\n").as_bytes());
        }
    }
    win::reveal(&root);
    Ok(json!({ "folder": root, "files": files, "bytes": bytes, "skipped": skipped, "errors": errors.len(), "firstErrors": errors.iter().take(5).collect::<Vec<_>>(), "report": report, "downloads": dl, "cancelled": cancelled }))
}
