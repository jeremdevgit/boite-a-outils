// SPDX-License-Identifier: GPL-3.0-or-later — Copyright (C) 2026 jeremdevgit — voir LICENSE
//! Détail du processeur (façon CPU-Z), lu directement par CPUID et Windows.

use crate::sensors::{cpu_brand, cpu_fms, cpuid};
use serde_json::{json, Value};

/// Nom de la microarchitecture, quand il est connu avec certitude.
fn codename(vendor: &str, family: u32, model: u32) -> &'static str {
    match (vendor, family, model) {
        ("AuthenticAMD", 0x17, 0x01 | 0x11) => "Zen",
        ("AuthenticAMD", 0x17, 0x08 | 0x18) => "Zen+",
        ("AuthenticAMD", 0x17, 0x31 | 0x47 | 0x60 | 0x68 | 0x71 | 0x90 | 0xA0) => "Zen 2",
        ("AuthenticAMD", 0x19, 0x00..=0x0F | 0x20..=0x2F | 0x40..=0x4F | 0x50..=0x5F) => "Zen 3",
        ("AuthenticAMD", 0x19, 0x10..=0x1F | 0x60..=0x7F | 0xA0..=0xAF) => "Zen 4",
        ("AuthenticAMD", 0x1A, _) => "Zen 5",
        ("GenuineIntel", 6, 0x9E | 0x8E | 0xA5 | 0xA6) => "Coffee Lake / Comet Lake",
        ("GenuineIntel", 6, 0xA7) => "Rocket Lake",
        ("GenuineIntel", 6, 0x97 | 0x9A) => "Alder Lake",
        ("GenuineIntel", 6, 0xB7 | 0xBA | 0xBF) => "Raptor Lake",
        ("GenuineIntel", 6, 0xAA | 0xAC) => "Meteor Lake",
        ("GenuineIntel", 6, 0xC5 | 0xC6) => "Arrow Lake",
        ("GenuineIntel", 6, 0xBD) => "Lunar Lake",
        ("GenuineIntel", 6, 0x7E | 0x7D) => "Ice Lake",
        ("GenuineIntel", 6, 0x8C | 0x8D) => "Tiger Lake",
        ("GenuineIntel", 6, 0x5E | 0x4E) => "Skylake",
        ("GenuineIntel", 6, 0x3C | 0x45 | 0x46) => "Haswell",
        _ => "",
    }
}

/// Jeux d'instructions pris en charge.
fn features() -> Vec<&'static str> {
    let l1 = cpuid(1, 0);
    let l7 = if cpuid(0, 0)[0] >= 7 { cpuid(7, 0) } else { [0; 4] };
    let e1 = if cpuid(0x8000_0000, 0)[0] >= 0x8000_0001 { cpuid(0x8000_0001, 0) } else { [0; 4] };
    let bit = |r: u32, b: u32| r & (1 << b) != 0;
    let mut f = Vec::new();
    let checks: [(&str, bool); 22] = [
        ("MMX", bit(l1[3], 23)),
        ("SSE", bit(l1[3], 25)),
        ("SSE2", bit(l1[3], 26)),
        ("SSE3", bit(l1[2], 0)),
        ("SSSE3", bit(l1[2], 9)),
        ("SSE4.1", bit(l1[2], 19)),
        ("SSE4.2", bit(l1[2], 20)),
        ("SSE4A", bit(e1[2], 6)),
        ("x86-64", bit(e1[3], 29)),
        ("AES", bit(l1[2], 25)),
        ("AVX", bit(l1[2], 28)),
        ("AVX2", bit(l7[1], 5)),
        ("AVX-512F", bit(l7[1], 16)),
        ("AVX-VNNI", false),
        ("FMA3", bit(l1[2], 12)),
        ("SHA", bit(l7[1], 29)),
        ("BMI1", bit(l7[1], 3)),
        ("BMI2", bit(l7[1], 8)),
        ("F16C", bit(l1[2], 29)),
        ("RDRAND", bit(l1[2], 30)),
        ("VT-x", bit(l1[2], 5)),
        ("AMD-V", bit(e1[2], 2)),
    ];
    for (n, ok) in checks {
        if ok {
            f.push(n);
        }
    }
    if cpuid(0, 0)[0] >= 7 && cpuid(7, 1)[0] & (1 << 4) != 0 {
        f.push("AVX-VNNI");
    }
    f
}

pub fn cpu() -> Value {
    use windows_sys::Win32::System::SystemInformation::*;
    let (vendor, family, model, stepping) = cpu_fms();
    let (mut cores, mut threads) = (0u32, 0u32);
    let mut caches: Vec<(u8, u8, u32)> = Vec::new(); // (niveau, type, taille)
    unsafe {
        let mut len = 0u32;
        GetLogicalProcessorInformationEx(RelationAll, std::ptr::null_mut(), &mut len);
        let mut buf = vec![0u8; len as usize];
        if GetLogicalProcessorInformationEx(RelationAll, buf.as_mut_ptr() as _, &mut len) != 0 {
            let mut off = 0usize;
            while off < len as usize {
                let p = buf.as_ptr().add(off) as *const SYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX;
                match (*p).Relationship {
                    r if r == RelationProcessorCore => {
                        cores += 1;
                        let pr = &(*p).Anonymous.Processor;
                        for i in 0..pr.GroupCount as usize {
                            threads += (*pr.GroupMask.as_ptr().add(i)).Mask.count_ones();
                        }
                    }
                    r if r == RelationCache => {
                        let c = &(*p).Anonymous.Cache;
                        caches.push((c.Level, c.Type as u8, c.CacheSize));
                    }
                    _ => {}
                }
                off += (*p).Size as usize;
            }
        }
    }
    // regroupe les caches identiques : « 12 × 32 Ko »
    let mut grouped: Vec<Value> = Vec::new();
    for (level, kind) in [(1u8, 1u8), (1, 2), (2, 0), (3, 0)] {
        let list: Vec<u32> = caches.iter().filter(|c| c.0 == level && (kind == 0 || c.1 == kind)).map(|c| c.2).collect();
        if let Some(&size) = list.first() {
            let name = match (level, kind) {
                (1, 1) => "L1 instructions",
                (1, 2) => "L1 données",
                (2, _) => "L2",
                _ => "L3",
            };
            grouped.push(json!({ "name": name, "count": list.len(), "size": size }));
        }
    }
    let base_mhz = {
        use windows_sys::Win32::System::Registry::*;
        let key = crate::win::w("HARDWARE\\DESCRIPTION\\System\\CentralProcessor\\0");
        let name = crate::win::w("~MHz");
        let mut v = 0u32;
        let mut l = 4u32;
        unsafe { RegGetValueW(HKEY_LOCAL_MACHINE, key.as_ptr(), name.as_ptr(), RRF_RT_REG_DWORD, std::ptr::null_mut(), &mut v as *mut u32 as _, &mut l) };
        v
    };
    let raw = cpuid(1, 0)[0];
    json!({
        "brand": cpu_brand(),
        "vendor": match vendor.as_str() { "AuthenticAMD" => "AMD", "GenuineIntel" => "Intel", v => v },
        "codename": codename(&vendor, family, model),
        "family": format!("{family:X}"), "model": format!("{model:X}"), "stepping": stepping,
        "signature": format!("{raw:08X}"),
        "cores": cores, "threads": threads,
        "caches": grouped,
        "features": features(),
        "baseMhz": base_mhz,
    })
}
