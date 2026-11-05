// SPDX-License-Identifier: GPL-3.0-or-later — Copyright (C) 2026 jeremdevgit — voir LICENSE
//! Accès matériel en lecture via PawnIO (pilote noyau signé, utilisé aussi
//! par LibreHardwareMonitor, FanControl, OpenRGB, rJb). La bibliothèque est
//! chargée dynamiquement : sans PawnIO, seuls les capteurs sans pilote restent.

use std::ffi::c_void;
use std::sync::{Mutex, OnceLock};
use windows_sys::Win32::Foundation::{CloseHandle, HANDLE};
use windows_sys::Win32::System::LibraryLoader::{GetProcAddress, LoadLibraryExW, LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR, LOAD_LIBRARY_SEARCH_SYSTEM32};
use windows_sys::Win32::System::Threading::{CreateMutexW, ReleaseMutex, WaitForSingleObject};

/// Modules PawnIO officiels (signés), intégrés à l'exécutable.
pub mod blobs {
    pub static LPC_IO: &[u8] = include_bytes!("../assets/pawnio/LpcIO.bin");
    pub static AMD17: &[u8] = include_bytes!("../assets/pawnio/AMDFamily17.bin");
    pub static INTEL_MSR: &[u8] = include_bytes!("../assets/pawnio/IntelMSR.bin");
}

fn dll_path() -> std::path::PathBuf {
    std::env::var_os("ProgramFiles").map(std::path::PathBuf::from).unwrap_or_else(|| r"C:\Program Files".into()).join("PawnIO").join("PawnIOLib.dll")
}

pub fn installed() -> bool {
    dll_path().exists()
}

type Handle = *mut c_void;
type FnOpen = unsafe extern "system" fn(*mut Handle) -> i32;
type FnLoad = unsafe extern "system" fn(Handle, *const u8, usize) -> i32;
type FnExec = unsafe extern "system" fn(Handle, *const u8, *const u64, usize, *mut u64, usize, *mut usize) -> i32;
type FnClose = unsafe extern "system" fn(Handle) -> i32;

struct Lib {
    open: FnOpen,
    load: FnLoad,
    exec: FnExec,
    close: FnClose,
}

static LIB: OnceLock<Result<Lib, String>> = OnceLock::new();

fn lib() -> Result<&'static Lib, String> {
    LIB.get_or_init(|| unsafe {
        // seulement l'emplacement officiel (protégé en écriture) : jamais une DLL
        // posée à côté de l'application, qui tourne en administrateur
        let p = dll_path();
        if !p.exists() {
            return Err("PawnIO n'est pas installé".into());
        }
        let w = crate::win::w(&p.to_string_lossy());
        let h = LoadLibraryExW(w.as_ptr(), std::ptr::null_mut(), LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32);
        if h.is_null() {
            return Err("PawnIO : bibliothèque illisible".into());
        }
        let get = |n: &[u8]| GetProcAddress(h, n.as_ptr());
        let (Some(o), Some(l), Some(e), Some(c)) = (get(b"pawnio_open\0"), get(b"pawnio_load\0"), get(b"pawnio_execute\0"), get(b"pawnio_close\0")) else {
            return Err("PawnIO : version non reconnue".into());
        };
        Ok(Lib {
            open: std::mem::transmute::<_, FnOpen>(o),
            load: std::mem::transmute::<_, FnLoad>(l),
            exec: std::mem::transmute::<_, FnExec>(e),
            close: std::mem::transmute::<_, FnClose>(c),
        })
    })
    .as_ref()
    .map_err(|e| e.clone())
}

/// Un module chargé (une instance du pilote).
pub struct Module {
    h: Mutex<usize>,
}

impl Module {
    pub fn load(blob: &[u8]) -> Result<Module, String> {
        let l = lib()?;
        unsafe {
            let mut h: Handle = std::ptr::null_mut();
            let r = (l.open)(&mut h);
            if r != 0 {
                return Err(if r as u32 == 0x8007_0005 { "droits administrateur requis".into() } else { format!("ouverture de PawnIO impossible ({r:#x})") });
            }
            let r = (l.load)(h, blob.as_ptr(), blob.len());
            if r != 0 {
                (l.close)(h);
                return Err(format!("module non pris en charge par ce matériel ({r:#x})"));
            }
            Ok(Module { h: Mutex::new(h as usize) })
        }
    }

    pub fn exec(&self, name: &str, input: &[u64], out_len: usize) -> Result<Vec<u64>, String> {
        let l = lib()?;
        let cname: Vec<u8> = name.bytes().chain(Some(0)).collect();
        let mut out = vec![0u64; out_len];
        let mut ret = 0usize;
        let h = self.h.lock().unwrap();
        let r = unsafe { (l.exec)(*h as Handle, cname.as_ptr(), input.as_ptr(), input.len(), if out_len > 0 { out.as_mut_ptr() } else { std::ptr::null_mut() }, out_len, &mut ret) };
        if r != 0 {
            return Err(format!("{name} : erreur {r:#x}"));
        }
        Ok(out)
    }

    pub fn one(&self, name: &str, input: &[u64]) -> Option<u64> {
        self.exec(name, input, 1).ok().map(|v| v[0])
    }
}

impl Drop for Module {
    fn drop(&mut self) {
        if let Ok(l) = lib() {
            unsafe { (l.close)(*self.h.lock().unwrap() as Handle) };
        }
    }
}

/// Verrou partagé entre logiciels de surveillance (« Global\Access_ISABUS.HTP.Method »,
/// « Global\Access_PCI ») : évite que deux programmes parlent à la puce en même temps.
pub struct GlobalLock(usize);

impl GlobalLock {
    pub fn new(name: &str) -> GlobalLock {
        let name = crate::win::w(name);
        GlobalLock(unsafe { CreateMutexW(std::ptr::null(), 0, name.as_ptr()) } as usize)
    }
    pub fn hold(&self) -> Option<LockGuard<'_>> {
        if self.0 == 0 {
            return None;
        }
        let r = unsafe { WaitForSingleObject(self.0 as HANDLE, 500) };
        // 0 = acquis, 0x80 = abandonné par un autre processus (acquis aussi)
        (r == 0 || r == 0x80).then_some(LockGuard(self))
    }
}

pub struct LockGuard<'a>(&'a GlobalLock);
impl Drop for LockGuard<'_> {
    fn drop(&mut self) {
        unsafe { ReleaseMutex(self.0 .0 as HANDLE) };
    }
}

impl Drop for GlobalLock {
    fn drop(&mut self) {
        if self.0 != 0 {
            unsafe { CloseHandle(self.0 as HANDLE) };
        }
    }
}

unsafe impl Send for Module {}
unsafe impl Sync for Module {}
unsafe impl Send for GlobalLock {}
unsafe impl Sync for GlobalLock {}
