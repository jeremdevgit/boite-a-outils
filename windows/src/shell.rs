// SPDX-License-Identifier: GPL-3.0-or-later — Copyright (C) 2026 jeremdevgit — voir LICENSE
//! Objets COM du shell pour l'installateur : dossiers connus, raccourcis,
//! choix d'un dossier.

use std::path::{Path, PathBuf};
use windows::core::{Interface, GUID, HSTRING};
use windows::Win32::Foundation::HWND;
use windows::Win32::System::Com::*;
use windows::Win32::UI::Shell::*;

pub fn known_folder(id: &GUID) -> Option<PathBuf> {
    unsafe {
        let p = SHGetKnownFolderPath(id, KNOWN_FOLDER_FLAG(0), None).ok()?;
        let s = p.to_string().ok();
        CoTaskMemFree(Some(p.0 as _));
        s.map(PathBuf::from)
    }
}

pub fn create_shortcut(lnk: &Path, target: &Path, description: &str) -> bool {
    let h = |p: &Path| HSTRING::from(p.to_string_lossy().as_ref());
    unsafe {
        let _ = CoInitializeEx(None, COINIT_APARTMENTTHREADED);
        let Ok(link) = CoCreateInstance::<_, IShellLinkW>(&ShellLink, None, CLSCTX_INPROC_SERVER) else { return false };
        let _ = link.SetPath(&h(target));
        if let Some(d) = target.parent() {
            let _ = link.SetWorkingDirectory(&h(d));
        }
        let _ = link.SetDescription(&HSTRING::from(description));
        let _ = link.SetIconLocation(&h(target), 0);
        let Ok(file) = link.cast::<IPersistFile>() else { return false };
        file.Save(&h(lnk), true).is_ok()
    }
}

pub fn pick_folder(owner: isize, title: &str) -> Option<String> {
    unsafe {
        let _ = CoInitializeEx(None, COINIT_APARTMENTTHREADED);
        let dlg: IFileOpenDialog = CoCreateInstance(&FileOpenDialog, None, CLSCTX_INPROC_SERVER).ok()?;
        let opts = dlg.GetOptions().ok()?;
        dlg.SetOptions(opts | FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM).ok()?;
        let _ = dlg.SetTitle(&HSTRING::from(title));
        dlg.Show(Some(HWND(owner as *mut _))).ok()?;
        let item = dlg.GetResult().ok()?;
        let p = item.GetDisplayName(SIGDN_FILESYSPATH).ok()?;
        let s = p.to_string().ok();
        CoTaskMemFree(Some(p.0 as _));
        s
    }
}
