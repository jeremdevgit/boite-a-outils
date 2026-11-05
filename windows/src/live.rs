// SPDX-License-Identifier: GPL-3.0-or-later — Copyright (C) 2026 jeremdevgit — voir LICENSE
//! Activité en direct pour l'accueil : processeur, carte graphique, réseau.
//! Chaque appel renvoie l'activité depuis l'appel précédent.

use serde_json::{json, Value};
use std::sync::Mutex;
use windows_sys::Win32::Foundation::FILETIME;
use windows_sys::Win32::NetworkManagement::IpHelper::{FreeMibTable, GetIfTable2, MIB_IF_TABLE2};
use windows_sys::Win32::System::Performance::*;
use windows_sys::Win32::System::Threading::GetSystemTimes;

struct Prev {
    at: std::time::Instant,
    idle: u64,
    total: u64,
    rx: u64,
    tx: u64,
    gpu_query: isize,
    gpu_counter: isize,
}
unsafe impl Send for Prev {}

static PREV: Mutex<Option<Prev>> = Mutex::new(None);

fn ft(f: FILETIME) -> u64 {
    (f.dwHighDateTime as u64) << 32 | f.dwLowDateTime as u64
}

fn cpu_times() -> (u64, u64) {
    let mut i = FILETIME { dwLowDateTime: 0, dwHighDateTime: 0 };
    let (mut k, mut u) = (i, i);
    unsafe { GetSystemTimes(&mut i, &mut k, &mut u) };
    // le temps noyau inclut le temps d'inactivité
    (ft(i), ft(k) + ft(u))
}

/// Octets reçus et envoyés par les cartes réseau physiques connectées.
fn net_bytes() -> (u64, u64) {
    let (mut rx, mut tx) = (0, 0);
    unsafe {
        let mut t: *mut MIB_IF_TABLE2 = std::ptr::null_mut();
        if GetIfTable2(&mut t) != 0 || t.is_null() {
            return (0, 0);
        }
        let rows = std::slice::from_raw_parts((*t).Table.as_ptr(), (*t).NumEntries as usize);
        for r in rows {
            let hardware = r.InterfaceAndOperStatusFlags._bitfield & 1 != 0;
            // OperStatus 1 = connectée ; type 24 = boucle locale
            if hardware && r.OperStatus == 1 && r.Type != 24 {
                rx += r.InOctets;
                tx += r.OutOctets;
            }
        }
        FreeMibTable(t as _);
    }
    (rx, tx)
}

/// Compteur « Moteur GPU 3D » (somme sur les processus) ; 0 si indisponible.
fn gpu_open() -> (isize, isize) {
    unsafe {
        let mut q = 0isize;
        if PdhOpenQueryW(std::ptr::null(), 0, &mut q) != 0 {
            return (0, 0);
        }
        let path = crate::win::w("\\GPU Engine(*engtype_3D)\\Utilization Percentage");
        let mut c = 0isize;
        if PdhAddEnglishCounterW(q, path.as_ptr(), 0, &mut c) != 0 {
            PdhCloseQuery(q);
            return (0, 0);
        }
        PdhCollectQueryData(q);
        (q, c)
    }
}

fn gpu_read(q: isize, c: isize) -> Option<f64> {
    if q == 0 {
        return None;
    }
    unsafe {
        if PdhCollectQueryData(q) != 0 {
            return None;
        }
        let (mut size, mut count) = (0u32, 0u32);
        PdhGetFormattedCounterArrayW(c, PDH_FMT_DOUBLE, &mut size, &mut count, std::ptr::null_mut());
        if size == 0 {
            return Some(0.0);
        }
        let mut buf = vec![0u8; size as usize];
        let items = buf.as_mut_ptr() as *mut PDH_FMT_COUNTERVALUE_ITEM_W;
        if PdhGetFormattedCounterArrayW(c, PDH_FMT_DOUBLE, &mut size, &mut count, items) != 0 {
            return None;
        }
        let sum: f64 = std::slice::from_raw_parts(items, count as usize).iter().map(|i| i.FmtValue.Anonymous.doubleValue).sum();
        Some(sum.min(100.0))
    }
}

pub fn sample() -> Value {
    let (idle, total) = cpu_times();
    let (rx, tx) = net_bytes();
    let now = std::time::Instant::now();
    let (mem_total, mem_avail) = crate::win::memory();
    let mut g = PREV.lock().unwrap();
    let out = match g.as_mut() {
        Some(p) => {
            let dt = now.duration_since(p.at).as_secs_f64().max(0.001);
            let (di, dtot) = (idle.saturating_sub(p.idle), total.saturating_sub(p.total));
            let cpu = if dtot > 0 { 100.0 * (1.0 - di as f64 / dtot as f64) } else { 0.0 };
            let gpu = gpu_read(p.gpu_query, p.gpu_counter);
            json!({
                "cpu": cpu.clamp(0.0, 100.0),
                "gpu": gpu,
                "rx": (rx.saturating_sub(p.rx) as f64 / dt) as u64,
                "tx": (tx.saturating_sub(p.tx) as f64 / dt) as u64,
                "memTotal": mem_total, "memAvail": mem_avail,
            })
        }
        None => json!({ "cpu": 0, "gpu": null, "rx": 0, "tx": 0, "memTotal": mem_total, "memAvail": mem_avail }),
    };
    let (gq, gc) = g.as_ref().map(|p| (p.gpu_query, p.gpu_counter)).unwrap_or_else(gpu_open);
    *g = Some(Prev { at: now, idle, total, rx, tx, gpu_query: gq, gpu_counter: gc });
    out
}
