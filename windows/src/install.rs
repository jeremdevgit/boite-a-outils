// SPDX-License-Identifier: GPL-3.0-or-later — Copyright (C) 2026 jeremdevgit — voir LICENSE
//! Installation, réparation et désinstallation de la Boîte à outils.
//!
//! L'application travaille en administrateur : elle s'installe donc pour tout
//! le PC, dans un dossier que seuls les administrateurs peuvent modifier
//! (Program Files, ou un autre dossier verrouillé par l'installateur). Sinon
//! n'importe quel programme de l'utilisateur pourrait remplacer l'exécutable
//! et obtenir les droits administrateur au lancement suivant.

use crate::win::{system_tool, w, NO_WINDOW};
use std::os::windows::process::CommandExt;
use std::path::{Path, PathBuf};
use windows_sys::Win32::System::Registry::*;

pub const UNINSTALL_KEY: &str =
    "SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\BoiteAOutils";
pub const APP_KEY: &str = "SOFTWARE\\BoiteAOutils";
pub const APP_EXE: &str = "BoiteAOutils.exe";
pub const MAINTENANCE_EXE: &str = "uninstall.exe";
const LNK: &str = "Boîte à outils.lnk";

#[derive(Clone, Debug, serde::Deserialize, serde::Serialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Options {
    pub dir: String,
    pub desktop: bool,
    pub start_menu: bool,
}

impl Default for Options {
    /// Choix par défaut, ou ceux de l'installation existante.
    fn default() -> Self {
        let get = |n: &str| reg_get_dword(APP_KEY, n).map(|v| v != 0).unwrap_or(true);
        Options {
            dir: installed_dir()
                .unwrap_or_else(default_dir)
                .to_string_lossy()
                .into_owned(),
            desktop: get("Desktop"),
            start_menu: get("StartMenu"),
        }
    }
}

fn program_files() -> PathBuf {
    std::env::var_os("ProgramW6432")
        .or_else(|| std::env::var_os("ProgramFiles"))
        .map(PathBuf::from)
        .unwrap_or_else(|| "C:\\Program Files".into())
}

pub fn default_dir() -> PathBuf {
    program_files().join("BoiteAOutils")
}

pub fn installed_dir() -> Option<PathBuf> {
    reg_get_str(UNINSTALL_KEY, "InstallLocation")
        .filter(|s| !s.is_empty())
        .map(PathBuf::from)
}

pub fn installed_version() -> Option<String> {
    installed_dir().and(reg_get_str(UNINSTALL_KEY, "DisplayVersion"))
}

// ── registre (HKLM, vue 64 bits) ────────────────────────────────────────

fn reg_set_str(key: &str, name: &str, value: &str) {
    let (k, n, v) = (w(key), w(name), w(value));
    unsafe {
        RegSetKeyValueW(
            HKEY_LOCAL_MACHINE,
            k.as_ptr(),
            n.as_ptr(),
            REG_SZ,
            v.as_ptr() as _,
            (v.len() * 2) as u32,
        )
    };
}

fn reg_set_dword(key: &str, name: &str, value: u32) {
    let (k, n) = (w(key), w(name));
    unsafe {
        RegSetKeyValueW(
            HKEY_LOCAL_MACHINE,
            k.as_ptr(),
            n.as_ptr(),
            REG_DWORD,
            &value as *const u32 as _,
            4,
        )
    };
}

fn reg_get_str(key: &str, name: &str) -> Option<String> {
    let (k, n) = (w(key), w(name));
    let mut buf = vec![0u16; 1024];
    let mut size = (buf.len() * 2) as u32;
    let r = unsafe {
        RegGetValueW(
            HKEY_LOCAL_MACHINE,
            k.as_ptr(),
            n.as_ptr(),
            RRF_RT_REG_SZ,
            std::ptr::null_mut(),
            buf.as_mut_ptr() as _,
            &mut size,
        )
    };
    if r != 0 {
        return None;
    }
    let len = (size as usize / 2).saturating_sub(1);
    Some(String::from_utf16_lossy(&buf[..len]))
}

fn reg_get_dword(key: &str, name: &str) -> Option<u32> {
    let (k, n) = (w(key), w(name));
    let mut v = 0u32;
    let mut size = 4u32;
    let r = unsafe {
        RegGetValueW(
            HKEY_LOCAL_MACHINE,
            k.as_ptr(),
            n.as_ptr(),
            RRF_RT_REG_DWORD,
            std::ptr::null_mut(),
            &mut v as *mut u32 as _,
            &mut size,
        )
    };
    (r == 0).then_some(v)
}

fn reg_delete_tree(key: &str) {
    let k = w(key);
    unsafe {
        RegDeleteTreeW(HKEY_LOCAL_MACHINE, k.as_ptr());
        RegDeleteKeyW(HKEY_LOCAL_MACHINE, k.as_ptr());
    }
}

// ── dossiers ─────────────────────────────────────────────────────────────

fn eq_path(a: &Path, b: &Path) -> bool {
    a.to_string_lossy()
        .trim_end_matches('\\')
        .eq_ignore_ascii_case(b.to_string_lossy().trim_end_matches('\\'))
}

fn under(p: &Path, root: &Path) -> bool {
    let p = p.to_string_lossy().to_lowercase();
    let r = root.to_string_lossy().to_lowercase();
    p.starts_with(&format!("{}\\", r.trim_end_matches('\\')))
}

/// Vérifie le dossier choisi ; un dossier existant qui contient autre chose
/// reçoit un sous-dossier « BoiteAOutils » (il sera verrouillé, et la
/// désinstallation ne doit jamais toucher aux fichiers de quelqu'un d'autre).
pub fn normalize_dir(input: &str) -> Result<PathBuf, String> {
    let p = crate::install_security::normalize(input)?;
    let s = p.to_string_lossy().to_string();
    if !(s.len() > 3 && s.as_bytes()[1] == b':' && s.as_bytes()[2] == b'\\') {
        return Err(
            "Indiquez un chemin complet, par exemple C:\\Program Files\\BoiteAOutils".into(),
        );
    }
    if s.contains(['<', '>', '"', '|', '?', '*']) || s[2..].contains(':') {
        return Err("Le chemin contient des caractères interdits.".into());
    }
    let windir = std::env::var_os("SystemRoot")
        .map(PathBuf::from)
        .unwrap_or_else(|| "C:\\Windows".into());
    if eq_path(&p, &windir) || under(&p, &windir) {
        return Err("Impossible d'installer dans le dossier de Windows.".into());
    }
    if let Some(profile) = std::env::var_os("USERPROFILE").map(PathBuf::from) {
        if eq_path(&p, &profile) || under(&p, &profile) {
            return Err("Choisissez un dossier hors de votre profil (Program Files par exemple) : la Boîte à outils fonctionne en administrateur et son dossier doit être protégé.".into());
        }
    }
    let non_empty = std::fs::read_dir(&p).is_ok_and(|mut it| it.next().is_some());
    Ok(if non_empty && !p.join(APP_EXE).exists() {
        p.join("BoiteAOutils")
    } else {
        p
    })
}

/// Seuls les administrateurs et le système peuvent modifier le dossier.
fn lock_down(dir: &Path) -> Result<(), String> {
    crate::install_security::prepare(dir)
}

fn shortcut_paths() -> [Option<PathBuf>; 2] {
    use windows::Win32::UI::Shell::{FOLDERID_CommonPrograms, FOLDERID_PublicDesktop};
    [
        crate::shell::known_folder(&FOLDERID_PublicDesktop).map(|d| d.join(LNK)),
        crate::shell::known_folder(&FOLDERID_CommonPrograms).map(|d| d.join(LNK)),
    ]
}

/// Copie en passant par un fichier temporaire : un fichier à moitié écrit ne
/// remplace jamais une version qui fonctionne.
fn copy_atomic(src: &Path, dst: &Path) -> std::io::Result<()> {
    let policy_error = |e: String| std::io::Error::new(std::io::ErrorKind::PermissionDenied, e);
    if eq_path(src, dst) {
        return crate::install_security::seal_file(dst).map_err(policy_error);
    }
    let nonce = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let tmp = dst.with_extension(format!("install-{}-{nonce}.tmp", std::process::id()));
    let result = (|| {
        let mut input = std::fs::File::open(src)?;
        let mut output = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&tmp)?;
        std::io::copy(&mut input, &mut output)?;
        output.sync_all()?;
        drop(output);
        crate::install_security::seal_file(&tmp).map_err(policy_error)?;
        std::fs::rename(&tmp, dst)?;
        if !crate::install_security::trusted(dst) {
            return Err(policy_error(
                crate::install_security::PERMISSIONS_FAILED.into(),
            ));
        }
        Ok(())
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
    result
}

fn dir_size_kb(dir: &Path) -> u32 {
    std::fs::read_dir(dir)
        .map(|it| {
            it.flatten()
                .filter_map(|e| e.metadata().ok())
                .map(|m| m.len())
                .sum::<u64>()
        })
        .unwrap_or(0) as u32
        / 1024
}

// ── instances ouvertes ──────────────────────────────────────────────────

/// Ferme toutes les Boîtes à outils ouvertes (fenêtre principale et barre des
/// tâches transparente), où qu'elles aient été lancées : demande polie d'abord,
/// arrêt forcé au bout de 5 s.
fn stop_running() {
    use windows_sys::Win32::Foundation::{CloseHandle, HWND, LPARAM};
    use windows_sys::Win32::System::Diagnostics::ToolHelp::*;
    use windows_sys::Win32::System::Threading::*;
    use windows_sys::Win32::UI::WindowsAndMessaging::*;
    let me = std::process::id();
    let mut pids = Vec::new();
    unsafe {
        let snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        if snap.is_null() || snap as isize == -1 {
            return;
        }
        let mut e: PROCESSENTRY32W = std::mem::zeroed();
        e.dwSize = std::mem::size_of::<PROCESSENTRY32W>() as u32;
        if Process32FirstW(snap, &mut e) != 0 {
            loop {
                let n = e
                    .szExeFile
                    .iter()
                    .position(|c| *c == 0)
                    .unwrap_or(e.szExeFile.len());
                if e.th32ProcessID != me
                    && String::from_utf16_lossy(&e.szExeFile[..n]).eq_ignore_ascii_case(APP_EXE)
                {
                    pids.push(e.th32ProcessID);
                }
                if Process32NextW(snap, &mut e) == 0 {
                    break;
                }
            }
        }
        CloseHandle(snap);
    }
    if pids.is_empty() {
        return;
    }
    unsafe extern "system" fn close(h: HWND, l: LPARAM) -> i32 {
        let pids = &*(l as *const Vec<u32>);
        let mut pid = 0u32;
        GetWindowThreadProcessId(h, &mut pid);
        if pids.contains(&pid) && IsWindowVisible(h) != 0 {
            PostMessageW(h, WM_CLOSE, 0, 0);
        }
        1
    }
    unsafe { EnumWindows(Some(close), &pids as *const _ as LPARAM) };
    for pid in pids {
        unsafe {
            let h = OpenProcess(PROCESS_SYNCHRONIZE | PROCESS_TERMINATE, 0, pid);
            if h.is_null() {
                continue;
            }
            if WaitForSingleObject(h, 5000) != 0 {
                TerminateProcess(h, 1);
                WaitForSingleObject(h, 3000);
            }
            CloseHandle(h);
        }
    }
    // les processus du moteur web se ferment juste après leur fenêtre
    std::thread::sleep(std::time::Duration::from_millis(800));
}

// ── versions précédentes ────────────────────────────────────────────────

/// Une Boîte à outils déjà inscrite dans « Applications installées ».
#[derive(serde::Serialize)]
pub struct Previous {
    pub version: String,
    pub dir: PathBuf,
    #[serde(skip)]
    root: HKEY,
    #[serde(skip)]
    view: u32,
    #[serde(skip)]
    key: String,
}

const UNINSTALL_BASE: &str = "SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall";

fn reg_str_in(h: HKEY, sub: &str, name: &str) -> Option<String> {
    let (k, n) = (w(sub), w(name));
    let mut buf = vec![0u16; 2048];
    let mut size = (buf.len() * 2) as u32;
    let r = unsafe {
        RegGetValueW(
            h,
            k.as_ptr(),
            n.as_ptr(),
            RRF_RT_REG_SZ,
            std::ptr::null_mut(),
            buf.as_mut_ptr() as _,
            &mut size,
        )
    };
    (r == 0).then(|| String::from_utf16_lossy(&buf[..(size as usize / 2).saturating_sub(1)]))
}

fn is_ours(key: &str, display: &str) -> bool {
    let d = display.to_lowercase().replace('î', "i").replace('à', "a");
    key.to_lowercase().starts_with("boiteaoutils") || d.starts_with("boite a outils")
}

/// Toutes les inscriptions de la Boîte à outils : 64 bits, 32 bits et par
/// utilisateur (anciennes versions).
pub fn previous_installs() -> Vec<Previous> {
    let mut out: Vec<Previous> = Vec::new();
    for (root, view) in [
        (HKEY_LOCAL_MACHINE, KEY_WOW64_64KEY),
        (HKEY_LOCAL_MACHINE, KEY_WOW64_32KEY),
        (HKEY_CURRENT_USER, 0),
    ] {
        let base = w(UNINSTALL_BASE);
        let mut h: HKEY = std::ptr::null_mut();
        if unsafe { RegOpenKeyExW(root, base.as_ptr(), 0, KEY_READ | view, &mut h) } != 0 {
            continue;
        }
        let mut i = 0;
        loop {
            let mut name = [0u16; 256];
            let mut len = name.len() as u32;
            let r = unsafe {
                RegEnumKeyExW(
                    h,
                    i,
                    name.as_mut_ptr(),
                    &mut len,
                    std::ptr::null(),
                    std::ptr::null_mut(),
                    std::ptr::null_mut(),
                    std::ptr::null_mut(),
                )
            };
            if r != 0 {
                break;
            }
            i += 1;
            let key = String::from_utf16_lossy(&name[..len as usize]);
            let display = reg_str_in(h, &key, "DisplayName").unwrap_or_default();
            if !is_ours(&key, &display) {
                continue;
            }
            let loc = reg_str_in(h, &key, "InstallLocation")
                .filter(|s| !s.trim().is_empty())
                .map(|s| PathBuf::from(s.trim().trim_matches('"')));
            // sans InstallLocation : dossier du programme de désinstallation
            let dir = loc.or_else(|| {
                let u = reg_str_in(h, &key, "UninstallString")?;
                let exe = u
                    .trim()
                    .trim_start_matches('"')
                    .split('"')
                    .next()?
                    .to_string();
                Path::new(&exe).parent().map(Path::to_path_buf)
            });
            let Some(dir) = dir else { continue };
            out.push(Previous {
                version: reg_str_in(h, &key, "DisplayVersion").unwrap_or_default(),
                dir,
                root,
                view,
                key,
            });
        }
        unsafe { RegCloseKey(h) };
    }
    out
}

/// Désinstalle une version précédente : ses fichiers (seulement les nôtres,
/// jamais le reste du dossier ni l'exécutable en cours), ses raccourcis par
/// utilisateur et son inscription. Historique, sauvegardes et réglages gardés.
fn remove_previous(p: &Previous, new_dir: &Path, running: &Path) {
    if !eq_path(&p.dir, new_dir) {
        for f in [
            APP_EXE,
            MAINTENANCE_EXE,
            "BoiteAOutils.new",
            "uninstall.new",
        ] {
            let file = p.dir.join(f);
            if !eq_path(&file, running) {
                let _ = std::fs::remove_file(&file);
            }
        }
        let _ = std::fs::remove_dir(&p.dir); // seulement s'il est vide
    }
    use windows::Win32::UI::Shell::{FOLDERID_Desktop, FOLDERID_Programs};
    for d in [FOLDERID_Desktop, FOLDERID_Programs]
        .iter()
        .filter_map(crate::shell::known_folder)
    {
        let _ = std::fs::remove_file(d.join(LNK));
    }
    // l'inscription de la nouvelle version est réécrite juste après
    let base = w(UNINSTALL_BASE);
    let mut h: HKEY = std::ptr::null_mut();
    if unsafe { RegOpenKeyExW(p.root, base.as_ptr(), 0, KEY_ALL_ACCESS | p.view, &mut h) } == 0 {
        let k = w(&p.key);
        unsafe {
            RegDeleteTreeW(h, k.as_ptr());
            RegDeleteKeyExW(h, k.as_ptr(), p.view, 0);
            RegCloseKey(h);
        }
    }
}

// ── installation ────────────────────────────────────────────────────────

pub fn install(o: &Options, step: &dyn Fn(&str)) -> Result<Vec<String>, String> {
    let mut notes = Vec::new();
    let dir = normalize_dir(&o.dir)?;
    let src = std::env::current_exe().map_err(|e| e.to_string())?;
    // une réparation lancée depuis le dossier installé ne se désinstalle pas elle-même
    let src_dir = src.parent().map(Path::to_path_buf).unwrap_or_default();
    let previous: Vec<Previous> = previous_installs()
        .into_iter()
        .filter(|p| !eq_path(&p.dir, &src_dir))
        .collect();
    for p in &previous {
        step(&format!(
            "Version {} trouvée dans {}",
            if p.version.is_empty() {
                "inconnue"
            } else {
                p.version.as_str()
            },
            p.dir.display()
        ));
    }
    step("Fermeture de la Boîte à outils si elle est ouverte…");
    stop_running();

    step("Copie des fichiers…");
    lock_down(&dir)?;
    let app = dir.join(APP_EXE);
    let maint = dir.join(MAINTENANCE_EXE);
    copy_atomic(&src, &app).map_err(|e| format!("Copie de {APP_EXE} impossible : {e}"))?;
    copy_atomic(&src, &maint)
        .map_err(|e| format!("Copie du programme de désinstallation impossible : {e}"))?;
    // versions déjà installées (même dossier ou ailleurs) : désinstallées une fois
    // la nouvelle copiée, pour ne jamais laisser le PC sans Boîte à outils
    for p in &previous {
        let v = if p.version.is_empty() {
            "inconnue"
        } else {
            p.version.as_str()
        };
        step(&format!("Désinstallation de l'ancienne version {v}…"));
        remove_previous(p, &dir, &src);
        notes.push(format!(
            "Ancienne version {v} désinstallée ({}).",
            p.dir.display()
        ));
    }

    step("Raccourcis…");
    let [desk, menu] = shortcut_paths();
    for (want, path) in [(o.desktop, desk), (o.start_menu, menu)] {
        let Some(path) = path else { continue };
        if want {
            if !crate::shell::create_shortcut(
                &path,
                &app,
                crate::langue::tr("Démarrage, services, nettoyage et entretien de Windows"),
            ) {
                notes.push(format!("Raccourci non créé : {}", path.display()));
            }
        } else {
            let _ = std::fs::remove_file(&path);
        }
    }

    step("Inscription dans Windows…");
    let m = format!("\"{}\" --maintenance", maint.display());
    let k = UNINSTALL_KEY;
    reg_set_str(k, "DisplayName", "Boîte à outils");
    reg_set_str(k, "DisplayVersion", env!("CARGO_PKG_VERSION"));
    reg_set_str(k, "Publisher", "Boîte à outils");
    reg_set_str(k, "DisplayIcon", &format!("{},0", app.display()));
    reg_set_str(k, "InstallLocation", &dir.to_string_lossy());
    reg_set_str(k, "UninstallString", &m);
    reg_set_str(k, "ModifyPath", &m);
    reg_set_str(
        k,
        "QuietUninstallString",
        &format!("\"{}\" --uninstall", maint.display()),
    );
    reg_set_str(
        k,
        "Comments",
        crate::langue::tr(
            "Démarrage, services, nettoyage et entretien de Windows, sans rien casser",
        ),
    );
    reg_set_dword(k, "EstimatedSize", dir_size_kb(&dir));
    reg_set_dword(k, "NoRepair", 0);
    reg_set_dword(APP_KEY, "Desktop", o.desktop as u32);
    reg_set_dword(APP_KEY, "StartMenu", o.start_menu as u32);

    // barre des tâches transparente déjà réglée : elle repart depuis la version installée
    if crate::taskbar::reattach(&app) {
        notes.push(
            "La barre des tâches transparente utilise maintenant la version installée.".into(),
        );
    }
    Ok(notes)
}

/// Réparation : recopie les fichiers, raccourcis et inscription avec les choix d'origine.
pub fn repair(step: &dyn Fn(&str)) -> Result<Vec<String>, String> {
    let mut o = Options::default();
    if let Some(d) = std::env::current_exe()
        .ok()
        .and_then(|e| e.parent().map(Path::to_path_buf))
    {
        o.dir = d.to_string_lossy().into_owned();
    }
    install(&o, step)
}

/// Désinstalle. `everything` supprime aussi l'historique, les sauvegardes,
/// les outils Sysinternals téléchargés et les réglages.
pub fn uninstall(everything: bool, step: &dyn Fn(&str)) -> Result<(), String> {
    let dir = installed_dir()
        .or_else(|| {
            std::env::current_exe()
                .ok()
                .and_then(|e| e.parent().map(Path::to_path_buf))
        })
        .ok_or("Installation introuvable")?;
    step("Barre des tâches d'origine…");
    // « normale » : le processus de la barre remet l'aspect de Windows puis s'arrête
    // seul, et son lancement avec Windows est retiré
    if crate::taskbar::load().mode != "normal" {
        let _ = crate::taskbar::set(&crate::taskbar::Config::default());
        std::thread::sleep(std::time::Duration::from_millis(1500));
    }
    step("Fermeture de la Boîte à outils…");
    stop_running();
    step("Raccourcis…");
    for p in shortcut_paths().into_iter().flatten() {
        let _ = std::fs::remove_file(p);
    }
    step("Suppression des fichiers…");
    // uniquement nos fichiers, jamais le contenu complet du dossier
    for f in [APP_EXE, "BoiteAOutils.new", "uninstall.new"] {
        let _ = std::fs::remove_file(dir.join(f));
    }
    if everything {
        let data = crate::win::data_dir();
        for _ in 0..10 {
            if std::fs::remove_dir_all(&data).is_ok() || !data.exists() {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(500));
        }
    }
    let _ = std::fs::remove_dir_all(std::env::temp_dir().join("BoiteAOutilsSetup"));
    step("Retrait de l'inscription Windows…");
    reg_delete_tree(UNINSTALL_KEY);
    reg_delete_tree(APP_KEY);
    Ok(())
}

/// Le programme de désinstallation ne peut pas s'effacer pendant qu'il tourne :
/// une invite de commandes invisible s'en charge juste après sa fermeture.
pub fn finish_uninstall() {
    let Ok(maint) = std::env::current_exe() else {
        return;
    };
    let Some(dir) = maint.parent() else { return };
    if !maint
        .file_name()
        .is_some_and(|n| n.eq_ignore_ascii_case(MAINTENANCE_EXE))
    {
        return; // seulement depuis le programme de désinstallation installé
    }
    let script = format!(
        "ping -n 3 127.0.0.1 >nul & del /f /q \"{}\" & rmdir \"{}\"",
        maint.display(),
        dir.display()
    );
    let _ = std::process::Command::new(system_tool("cmd.exe"))
        .raw_arg(format!("/C \"{script}\""))
        .current_dir(system_tool(""))
        // CREATE_NO_WINDOW seul : avec DETACHED_PROCESS il est ignoré et `ping` ouvre une console
        .creation_flags(NO_WINDOW)
        .spawn();
}

pub fn quiet_uninstall(everything: bool) -> i32 {
    let r = uninstall(everything, &|_| {});
    finish_uninstall();
    if r.is_ok() {
        0
    } else {
        1
    }
}

#[cfg(test)]
mod tests {
    #[test]
    #[ignore]
    fn detects_previous() {
        for p in super::previous_installs() {
            println!("TROUVÉ {} dans {} ({})", p.version, p.dir.display(), p.key);
        }
    }
}
