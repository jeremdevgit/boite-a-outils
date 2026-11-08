// SPDX-License-Identifier: GPL-3.0-or-later — Copyright (C) 2026 jeremdevgit — voir LICENSE
//! Petites fonctions Windows : droits administrateur, Corbeille, explorateur,
//! outils système lancés sans fenêtre.

use std::os::windows::process::CommandExt;
use std::path::{Path, PathBuf};
use windows_sys::Win32::UI::Shell::*;

pub const NO_WINDOW: u32 = 0x0800_0000; // CREATE_NO_WINDOW

pub fn w(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

/// Dossier de données : %LOCALAPPDATA%\BoiteAOutils (historique, sauvegardes .reg).
pub fn data_dir() -> PathBuf {
    let base = std::env::var_os("LOCALAPPDATA")
        .map(PathBuf::from)
        .unwrap_or_else(std::env::temp_dir);
    let d = base.join(
        if cfg!(feature = "test-hooks") && std::env::var_os("BAO_TEST").is_some() {
            "BoiteAOutilsTest"
        } else {
            "BoiteAOutils"
        },
    );
    let _ = std::fs::create_dir_all(&d);
    d
}

/// State that may authorize elevated replay/execution never lives in LOCALAPPDATA.
/// Limited mode keeps its own user state; elevated mode uses a new private store.
pub fn operation_data_dir() -> Result<PathBuf, String> {
    if !is_elevated() {
        return Ok(data_dir());
    }
    static ROOT: std::sync::OnceLock<Result<PathBuf, String>> = std::sync::OnceLock::new();
    let result = ROOT
        .get_or_init(|| {
            use windows_sys::Win32::System::Com::CoTaskMemFree;
            let mut p = std::ptr::null_mut();
            if unsafe {
                SHGetKnownFolderPath(&FOLDERID_ProgramData, 0, std::ptr::null_mut(), &mut p)
            } != 0
                || p.is_null()
            {
                return Err(crate::install_security::PERMISSIONS_FAILED.into());
            }
            let mut n = 0;
            while unsafe { *p.add(n) } != 0 {
                n += 1;
            }
            let base = PathBuf::from(String::from_utf16_lossy(unsafe {
                std::slice::from_raw_parts(p, n)
            }));
            unsafe {
                CoTaskMemFree(p.cast());
            }
            let sid = crate::user_context::current_user_sid()
                .map_err(|_| crate::install_security::PERMISSIONS_FAILED.to_string())?;
            let name = if cfg!(feature = "test-hooks") && std::env::var_os("BAO_TEST").is_some() {
                "BoiteAOutilsTest-Privileged"
            } else {
                "BoiteAOutils-Privileged"
            };
            let dir = base.join(name).join(sid);
            crate::install_security::prepare_private(&dir)?;
            Ok(dir)
        })
        .clone()?;
    if !crate::install_security::trusted(&result) {
        return Err(crate::install_security::UNSAFE_DIRECTORY.into());
    }
    Ok(result)
}

/// Lecteur de Windows, sans barre oblique (« C: » le plus souvent).
pub fn system_drive() -> String {
    std::env::var("SystemDrive")
        .ok()
        .filter(|d| d.len() == 2)
        .unwrap_or_else(|| "C:".into())
}

/// Chemin complet d'un outil de System32 : jamais résolu par le PATH ni par le
/// dossier courant (un exécutable déposé à côté ne peut pas se faire passer pour lui).
pub fn system_tool(name: &str) -> PathBuf {
    let mut buf = vec![0u16; 32768];
    let n = unsafe {
        windows_sys::Win32::System::SystemInformation::GetSystemDirectoryW(
            buf.as_mut_ptr(),
            buf.len() as u32,
        )
    } as usize;
    // Never search PATH or use caller-controlled SystemRoot after an API failure.
    if n == 0 || n >= buf.len() {
        return PathBuf::from(r"\\?\invalid-system-directory").join(name);
    }
    PathBuf::from(String::from_utf16_lossy(&buf[..n])).join(name)
}

pub fn is_elevated() -> bool {
    unsafe { IsUserAnAdmin() != 0 }
}

/// Relance l'application en administrateur (invite UAC). Faux si refusé.
pub fn relaunch_elevated() -> bool {
    relaunch_elevated_with("--eleve")
}

/// Relance l'exécutable en administrateur avec ces arguments. Faux si refusé.
pub fn relaunch_elevated_with(args: &str) -> bool {
    let Ok(exe) = std::env::current_exe() else {
        return false;
    };
    let verb = w("runas");
    let file = w(&exe.to_string_lossy());
    let params = w(args);
    unsafe {
        let mut info: SHELLEXECUTEINFOW = std::mem::zeroed();
        info.cbSize = std::mem::size_of::<SHELLEXECUTEINFOW>() as u32;
        info.lpVerb = verb.as_ptr();
        info.lpFile = file.as_ptr();
        info.lpParameters = params.as_ptr();
        info.nShow = 1; // SW_SHOWNORMAL
        ShellExecuteExW(&mut info) != 0
    }
}

/// Envoie des fichiers ou dossiers à la Corbeille (récupérables).
/// Renvoie le nombre d'éléments qui n'ont pas pu y aller.
pub fn recycle(paths: &[PathBuf]) -> usize {
    let mut failed = 0;
    // par paquets : une liste trop longue est refusée par l'API
    for chunk in paths.chunks(200) {
        let mut from: Vec<u16> = Vec::new();
        for p in chunk {
            from.extend(p.to_string_lossy().encode_utf16());
            from.push(0);
        }
        from.push(0);
        unsafe {
            let mut op: SHFILEOPSTRUCTW = std::mem::zeroed();
            op.wFunc = FO_DELETE;
            op.pFrom = from.as_ptr();
            op.fFlags = (FOF_ALLOWUNDO
                | FOF_NOCONFIRMATION
                | FOF_SILENT
                | FOF_NOERRORUI
                | FOF_WANTNUKEWARNING) as u16;
            if SHFileOperationW(&mut op) != 0 || op.fAnyOperationsAborted != 0 {
                failed += chunk.iter().filter(|p| p.exists()).count();
            }
        }
    }
    failed
}

/// Taille et nombre d'éléments de la Corbeille (tous les lecteurs).
pub fn recycle_bin_info() -> (u64, u64) {
    unsafe {
        let mut q: SHQUERYRBINFO = std::mem::zeroed();
        q.cbSize = std::mem::size_of::<SHQUERYRBINFO>() as u32;
        if SHQueryRecycleBinW(std::ptr::null(), &mut q) == 0 {
            (q.i64Size.max(0) as u64, q.i64NumItems.max(0) as u64)
        } else {
            (0, 0)
        }
    }
}

pub fn empty_recycle_bin() -> bool {
    unsafe {
        SHEmptyRecycleBinW(
            std::ptr::null_mut(),
            std::ptr::null(),
            SHERB_NOCONFIRMATION | SHERB_NOPROGRESSUI | SHERB_NOSOUND,
        ) == 0
    }
}

/// Affiche un fichier ou un dossier dans l'explorateur.
pub fn reveal(path: &Path) {
    let explorer = std::env::var_os("SystemRoot")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("C:\\Windows"))
        .join("explorer.exe");
    let arg = if path.is_dir() {
        format!("\"{}\"", path.display())
    } else {
        format!("/select,\"{}\"", path.display())
    };
    let _ = std::process::Command::new(explorer).raw_arg(arg).spawn();
}

/// Ouvre une page des Paramètres de Windows ou un outil (ms-settings:…, mdsched…).
pub fn shell_open(target: &str) {
    let verb = w("open");
    let t = w(target);
    unsafe {
        ShellExecuteW(
            std::ptr::null_mut(),
            verb.as_ptr(),
            t.as_ptr(),
            std::ptr::null(),
            std::ptr::null(),
            1,
        );
    }
}

/// Mémoire physique totale et disponible (octets).
pub fn memory() -> (u64, u64) {
    use windows_sys::Win32::System::SystemInformation::*;
    unsafe {
        let mut m: MEMORYSTATUSEX = std::mem::zeroed();
        m.dwLength = std::mem::size_of::<MEMORYSTATUSEX>() as u32;
        if GlobalMemoryStatusEx(&mut m) != 0 {
            (m.ullTotalPhys, m.ullAvailPhys)
        } else {
            (0, 0)
        }
    }
}

/// Lecteurs fixes : (lettre, total, libre).
pub fn drives() -> Vec<(String, u64, u64)> {
    use windows_sys::Win32::Storage::FileSystem::*;
    let mut out = Vec::new();
    let mask = unsafe { GetLogicalDrives() };
    for i in 0..26u32 {
        if mask & (1 << i) == 0 {
            continue;
        }
        let root = format!("{}:\\", (b'A' + i as u8) as char);
        let wr = w(&root);
        unsafe {
            if GetDriveTypeW(wr.as_ptr()) != 3 {
                continue; // DRIVE_FIXED uniquement
            }
            let (mut free, mut total, mut _all) = (0u64, 0u64, 0u64);
            if GetDiskFreeSpaceExW(wr.as_ptr(), &mut free, &mut total, &mut _all) != 0 {
                out.push((root, total, free));
            }
        }
    }
    out
}

pub fn uptime_secs() -> u64 {
    unsafe { windows_sys::Win32::System::SystemInformation::GetTickCount64() / 1000 }
}

/// Ouvre un fichier ou un lien avec le programme par défaut, sans les droits
/// administrateur (l'Explorateur déjà ouvert de l'utilisateur s'en charge).
pub fn open_as_user(target: &str) {
    let explorer = std::env::var_os("SystemRoot")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(r"C:\Windows"))
        .join("explorer.exe");
    let _ = std::process::Command::new(explorer)
        .raw_arg(format!("\"{target}\""))
        .spawn();
}

/// Redémarre le pilote graphique comme Win+Ctrl+Maj+B (écran noir une seconde).
pub fn restart_gpu_driver() {
    use windows_sys::Win32::UI::Input::KeyboardAndMouse::*;
    let keys = [VK_LWIN, VK_LCONTROL, VK_LSHIFT, 0x42 /* B */];
    let input = |vk: u16, up: bool| INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 {
            ki: KEYBDINPUT {
                wVk: vk,
                wScan: 0,
                dwFlags: if up { KEYEVENTF_KEYUP } else { 0 },
                time: 0,
                dwExtraInfo: 0,
            },
        },
    };
    let mut seq: Vec<INPUT> = keys.iter().map(|k| input(*k, false)).collect();
    seq.extend(keys.iter().rev().map(|k| input(*k, true)));
    unsafe {
        SendInput(
            seq.len() as u32,
            seq.as_ptr(),
            std::mem::size_of::<INPUT>() as i32,
        )
    };
}

/// Lance un programme avec des arguments, sans les droits administrateur
/// (jeton d'utilisateur standard), même depuis une instance élevée.
pub fn open_as_user_args(exe: &str, args: &str) {
    if !is_elevated() {
        let _ = std::process::Command::new(exe).raw_arg(args).spawn();
        return;
    }
    let _ = std::process::Command::new(system_tool("runas.exe"))
        .raw_arg(format!(
            "/trustlevel:0x20000 \"\\\"{exe}\\\" {}\"",
            args.replace('"', "\\\"")
        ))
        .creation_flags(NO_WINDOW)
        .spawn();
}
