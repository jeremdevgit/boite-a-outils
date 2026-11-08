// SPDX-License-Identifier: GPL-3.0-or-later — Copyright (C) 2026 jeremdevgit — voir LICENSE
//! Processus regroupés par nom, lus directement par l'API de Windows (comme le
//! Gestionnaire des tâches) : mémoire privée active, processeur mesuré sur
//! 0,8 s, chemin, éditeur et description de l'exécutable.

use crate::win::w;
use serde_json::{json, Value};
use std::collections::HashMap;
use windows_sys::Win32::Foundation::{CloseHandle, FILETIME, HANDLE};
use windows_sys::Win32::Storage::FileSystem::{
    GetFileVersionInfoSizeW, GetFileVersionInfoW, VerQueryValueW,
};
use windows_sys::Win32::System::Diagnostics::ToolHelp::{
    CreateToolhelp32Snapshot, Process32FirstW, Process32NextW, PROCESSENTRY32W, TH32CS_SNAPPROCESS,
};
use windows_sys::Win32::System::ProcessStatus::GetProcessMemoryInfo;
use windows_sys::Win32::System::Threading::{
    GetProcessTimes, OpenProcess, QueryFullProcessImageNameW, PROCESS_QUERY_LIMITED_INFORMATION,
};

/// PROCESS_MEMORY_COUNTERS_EX2 (Windows 10 1809+) : jeu de travail privé.
#[repr(C)]
#[derive(Default)]
struct Counters {
    cb: u32,
    page_fault_count: u32,
    peak_working_set: usize,
    working_set: usize,
    quota_peak_paged: usize,
    quota_paged: usize,
    quota_peak_non_paged: usize,
    quota_non_paged: usize,
    pagefile_usage: usize,
    peak_pagefile_usage: usize,
    private_usage: usize,
    private_working_set: usize,
    shared_commit: u64,
}

struct Proc {
    name: String,
    handle: HANDLE,
}

fn snapshot() -> Vec<(u32, String)> {
    let mut out = Vec::new();
    unsafe {
        let snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        if snap.is_null() || snap as isize == -1 {
            return out;
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
                let name = String::from_utf16_lossy(&e.szExeFile[..n]);
                out.push((e.th32ProcessID, name));
                if Process32NextW(snap, &mut e) == 0 {
                    break;
                }
            }
        }
        CloseHandle(snap);
    }
    out
}

fn cpu_time(h: HANDLE) -> u64 {
    let z = FILETIME {
        dwLowDateTime: 0,
        dwHighDateTime: 0,
    };
    let (mut c, mut e, mut k, mut u) = (z, z, z, z);
    unsafe {
        if GetProcessTimes(h, &mut c, &mut e, &mut k, &mut u) == 0 {
            return 0;
        }
    }
    let t = |f: FILETIME| (f.dwHighDateTime as u64) << 32 | f.dwLowDateTime as u64;
    t(k) + t(u)
}

fn image_path(h: HANDLE) -> String {
    let mut buf = [0u16; 1024];
    let mut len = buf.len() as u32;
    unsafe {
        if QueryFullProcessImageNameW(h, 0, buf.as_mut_ptr(), &mut len) == 0 {
            return String::new();
        }
    }
    String::from_utf16_lossy(&buf[..len as usize])
}

/// Éditeur et description d'un exécutable (ressource de version).
pub fn version_info(path: &str) -> (String, String) {
    let wp = w(path);
    unsafe {
        let size = GetFileVersionInfoSizeW(wp.as_ptr(), std::ptr::null_mut());
        if size == 0 {
            return Default::default();
        }
        let mut data = vec![0u8; size as usize];
        if GetFileVersionInfoW(wp.as_ptr(), 0, size, data.as_mut_ptr() as _) == 0 {
            return Default::default();
        }
        // VerQueryValue returns views into `data`. Keep pointer arithmetic as
        // checked offsets and read bytes through Rust's bounds-checked slices.
        let query = |key: &str| -> Option<(usize, u32)> {
            let mut value: *mut std::ffi::c_void = std::ptr::null_mut();
            let mut len = 0u32;
            if VerQueryValueW(data.as_ptr() as _, w(key).as_ptr(), &mut value, &mut len) == 0
                || value.is_null()
            {
                return None;
            }
            let offset = (value as usize).checked_sub(data.as_ptr() as usize)?;
            (offset < data.len()).then_some((offset, len))
        };
        let lang = query("\\VarFileInfo\\Translation")
            .and_then(|(offset, len)| {
                if len < 4 {
                    return None;
                }
                let tr = data.get(offset..offset.checked_add(4)?)?;
                Some(format!(
                    "{:04x}{:04x}",
                    u16::from_le_bytes([tr[0], tr[1]]),
                    u16::from_le_bytes([tr[2], tr[3]])
                ))
            })
            .unwrap_or_else(|| "040904b0".into());
        let get = |key: &str| -> String {
            let Some((offset, len)) = query(&format!("\\StringFileInfo\\{lang}\\{key}")) else {
                return String::new();
            };
            let Some(end) = (len as usize)
                .checked_mul(2)
                .and_then(|n| offset.checked_add(n))
            else {
                return String::new();
            };
            let Some(bytes) = data.get(offset..end) else {
                return String::new();
            };
            let chars: Vec<u16> = bytes
                .chunks_exact(2)
                .map(|p| u16::from_le_bytes([p[0], p[1]]))
                .take_while(|c| *c != 0)
                .collect();
            String::from_utf16_lossy(&chars).trim().to_string()
        };
        (get("CompanyName"), get("FileDescription"))
    }
}

pub fn list() -> Value {
    let cores = std::thread::available_parallelism()
        .map(|n| n.get())
        .unwrap_or(1) as f64;
    let procs: Vec<Proc> = snapshot()
        .into_iter()
        .map(|(pid, name)| Proc {
            name,
            handle: unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) },
        })
        .collect();
    let t0: Vec<u64> = procs
        .iter()
        .map(|p| {
            if p.handle.is_null() {
                0
            } else {
                cpu_time(p.handle)
            }
        })
        .collect();
    let start = std::time::Instant::now();
    std::thread::sleep(std::time::Duration::from_millis(800));
    let elapsed = start.elapsed().as_secs_f64() * 1e7; // en unités de 100 ns
    let mut groups: HashMap<String, (u32, u64, f64, String)> = HashMap::new();
    for (i, p) in procs.iter().enumerate() {
        // nom sans « .exe », comme Get-Process
        let name = p
            .name
            .strip_suffix(".exe")
            .or_else(|| p.name.strip_suffix(".EXE"))
            .unwrap_or(&p.name)
            .to_string();
        let (mut ram, mut cpu, mut path) = (0u64, 0.0, String::new());
        if !p.handle.is_null() {
            let mut c = Counters {
                cb: std::mem::size_of::<Counters>() as u32,
                ..Default::default()
            };
            unsafe {
                if GetProcessMemoryInfo(p.handle, &mut c as *mut _ as _, c.cb) != 0 {
                    ram = if c.private_working_set > 0 {
                        c.private_working_set as u64
                    } else {
                        c.private_usage as u64
                    };
                }
            }
            cpu = (cpu_time(p.handle).saturating_sub(t0[i]) as f64 / elapsed / cores * 100.0)
                .max(0.0);
            path = image_path(p.handle);
            unsafe { CloseHandle(p.handle) };
        }
        let g = groups.entry(name).or_insert((0, 0, 0.0, String::new()));
        g.0 += 1;
        g.1 += ram;
        g.2 += cpu;
        if g.3.is_empty() {
            g.3 = path;
        }
    }
    let mut vinfo: HashMap<String, (String, String)> = HashMap::new();
    let items: Vec<Value> = groups
        .into_iter()
        .filter(|(n, _)| n != "[System Process]")
        .map(|(name, (count, ram, cpu, path))| {
            let (company, description) = if path.is_empty() { Default::default() } else { vinfo.entry(path.clone()).or_insert_with(|| version_info(&path)).clone() };
            json!({ "name": name, "count": count, "ram": ram, "cpu": (cpu * 100.0).round() / 100.0, "path": path, "company": company, "description": description })
        })
        .collect();
    json!({ "items": items, "cores": cores })
}
