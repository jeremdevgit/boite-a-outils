// SPDX-License-Identifier: GPL-3.0-or-later — Copyright (C) 2026 jeremdevgit — voir LICENSE
//! Capteurs matériels (façon HWMonitor) : processeur, carte mère, carte
//! graphique, disques, batterie. Chaque lecture garde le minimum et le maximum
//! depuis l'ouverture de la page.
//!
//! Sources, sans aucun pilote douteux :
//! - compteurs de performances de Windows (charge et fréquence de chaque cœur) ;
//! - PawnIO, s'il est installé (température et puissance du processeur, puce
//!   de surveillance Super I/O de la carte mère), en lecture seule ;
//! - NVML (pilote NVIDIA) et l'interface noyau graphique de Windows (AMD, Intel) ;
//! - les requêtes de stockage de Windows (température des SSD et disques).

use crate::pawnio::{blobs, GlobalLock, Module};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::Mutex;
use std::time::Instant;

// ── modèle ───────────────────────────────────────────────────────────────

#[derive(Clone, Copy)]
enum Kind {
    Temp,
    Freq,
    Load,
    Power,
    Fan,
    Volt,
    Data,
    Pct,
}

impl Kind {
    fn id(self) -> &'static str {
        match self {
            Kind::Temp => "temp",
            Kind::Freq => "freq",
            Kind::Load => "load",
            Kind::Power => "power",
            Kind::Fan => "fan",
            Kind::Volt => "volt",
            Kind::Data => "data",
            Kind::Pct => "pct",
        }
    }
}

struct Group {
    id: String,
    name: String,
    icon: &'static str,
    items: Vec<(Kind, String, f64)>,
}

impl Group {
    fn new(id: impl Into<String>, name: impl Into<String>, icon: &'static str) -> Group {
        Group { id: id.into(), name: name.into(), icon, items: Vec::new() }
    }
    fn add(&mut self, k: Kind, label: impl Into<String>, v: f64) {
        if v.is_finite() {
            self.items.push((k, label.into(), v));
        }
    }
}

struct State {
    started: Instant,
    pdh: Option<Pdh>,
    cpu: Option<Cpu>,
    sio: Option<SuperIo>,
    sio_tried: bool,
    nvml: Option<Nvml>,
    nvml_tried: bool,
    disks: Vec<(String, String)>,
    disks_at: Option<Instant>,
    minmax: HashMap<String, (f64, f64)>,
    notes: Vec<String>,
}

static STATE: Mutex<Option<State>> = Mutex::new(None);

/// Remet à zéro les minimums et maximums.
pub fn reset() {
    if let Some(s) = STATE.lock().unwrap().as_mut() {
        s.minmax.clear();
    }
}

pub fn sample() -> Value {
    let mut g = STATE.lock().unwrap();
    let s = g.get_or_insert_with(|| State {
        started: Instant::now(),
        pdh: Pdh::open(),
        cpu: None,
        sio: None,
        sio_tried: false,
        nvml: None,
        nvml_tried: false,
        disks: Vec::new(),
        disks_at: None,
        minmax: HashMap::new(),
        notes: Vec::new(),
    });
    let pawn = crate::pawnio::installed();
    if s.cpu.is_none() {
        s.cpu = Some(Cpu::open(&mut s.notes));
    }
    if !s.sio_tried && pawn {
        s.sio_tried = true;
        match SuperIo::detect() {
            Ok(x) => s.sio = x,
            Err(e) => s.notes.push(format!("Carte mère : {e}")),
        }
    }
    if !s.nvml_tried {
        s.nvml_tried = true;
        s.nvml = Nvml::open();
    }
    if s.disks_at.is_none_or(|t| t.elapsed().as_secs() >= 5) {
        s.disks = disk_temps();
        s.disks_at = Some(Instant::now());
    }

    let mut groups: Vec<Group> = Vec::new();
    let pdh = s.pdh.as_mut().map(|p| p.read());
    if let Some(cpu) = s.cpu.as_mut() {
        groups.push(cpu.read(pdh.as_ref()));
    }
    if let Some(sio) = s.sio.as_ref() {
        if let Some(gr) = sio.read() {
            groups.push(gr);
        }
    }
    groups.extend(gpus(s.nvml.as_ref(), pdh.as_ref()));
    groups.push(memory());
    if !s.disks.is_empty() {
        let mut gr = Group::new("disks", "Stockage", "disk");
        for (name, t) in &s.disks {
            if let Ok(v) = t.parse::<f64>() {
                gr.add(Kind::Temp, name.clone(), v);
            }
        }
        if !gr.items.is_empty() {
            groups.push(gr);
        }
    }
    if let Some(b) = battery() {
        groups.push(b);
    }

    let mut out = Vec::new();
    for gr in groups {
        let items: Vec<Value> = gr
            .items
            .iter()
            .map(|(k, l, v)| {
                let key = format!("{}|{}|{}", gr.id, k.id(), l);
                let e = s.minmax.entry(key).or_insert((*v, *v));
                e.0 = e.0.min(*v);
                e.1 = e.1.max(*v);
                json!({ "k": k.id(), "l": l, "v": v, "min": e.0, "max": e.1 })
            })
            .collect();
        out.push(json!({ "id": gr.id, "name": gr.name, "icon": gr.icon, "items": items }));
    }
    json!({
        "groups": out,
        "pawnio": pawn,
        "elevated": crate::win::is_elevated(),
        "notes": s.notes,
        "since": s.started.elapsed().as_secs(),
    })
}

// ── compteurs de performances (charge et fréquence par cœur) ─────────────

use windows_sys::Win32::System::Performance::*;

struct Pdh {
    q: isize,
    time: isize,
    perf: isize,
    nominal: isize,
    gpu3d: isize,
    vram: isize,
}

struct PdhValues {
    /// (instance, valeur) : « 0,3 » = processeur 0, cœur logique 3
    time: Vec<(String, f64)>,
    perf: Vec<(String, f64)>,
    nominal: f64,
    gpu3d: Vec<(String, f64)>,
    vram: Vec<(String, f64)>,
}

impl Pdh {
    fn open() -> Option<Pdh> {
        unsafe {
            let mut q: windows_sys::Win32::System::Performance::PDH_HQUERY = std::ptr::null_mut();
            if PdhOpenQueryW(std::ptr::null(), 0, &mut q) != 0 {
                return None;
            }
            let add = |p: &str| {
                let w = crate::win::w(p);
                let mut c: windows_sys::Win32::System::Performance::PDH_HCOUNTER = std::ptr::null_mut();
                if PdhAddEnglishCounterW(q, w.as_ptr(), 0, &mut c) == 0 {
                    c as isize
                } else {
                    0
                }
            };
            let p = Pdh {
                q: q as isize,
                time: add("\\Processor Information(*)\\% Processor Time"),
                perf: add("\\Processor Information(*)\\% Processor Performance"),
                nominal: add("\\Processor Information(_Total)\\Processor Frequency"),
                gpu3d: add("\\GPU Engine(*engtype_3D)\\Utilization Percentage"),
                vram: add("\\GPU Adapter Memory(*)\\Dedicated Usage"),
            };
            PdhCollectQueryData(q);
            Some(p)
        }
    }

    fn array(c: isize) -> Vec<(String, f64)> {
        if c == 0 {
            return Vec::new();
        }
        unsafe {
            let (mut size, mut count) = (0u32, 0u32);
            PdhGetFormattedCounterArrayW(c as _, PDH_FMT_DOUBLE | 0x8000, &mut size, &mut count, std::ptr::null_mut());
            if size == 0 {
                return Vec::new();
            }
            let mut buf = vec![0u8; size as usize];
            let items = buf.as_mut_ptr() as *mut PDH_FMT_COUNTERVALUE_ITEM_W;
            if PdhGetFormattedCounterArrayW(c as _, PDH_FMT_DOUBLE | 0x8000, &mut size, &mut count, items) != 0 {
                return Vec::new();
            }
            std::slice::from_raw_parts(items, count as usize)
                .iter()
                .map(|i| {
                    let mut n = 0;
                    while *i.szName.add(n) != 0 {
                        n += 1;
                    }
                    (String::from_utf16_lossy(std::slice::from_raw_parts(i.szName, n)), i.FmtValue.Anonymous.doubleValue)
                })
                .collect()
        }
    }

    fn read(&mut self) -> PdhValues {
        unsafe { PdhCollectQueryData(self.q as _) };
        PdhValues {
            time: Self::array(self.time),
            perf: Self::array(self.perf),
            nominal: Self::array(self.nominal).first().map(|x| x.1).unwrap_or(0.0),
            gpu3d: Self::array(self.gpu3d),
            vram: Self::array(self.vram),
        }
    }
}

unsafe impl Send for Pdh {}

// ── processeur ───────────────────────────────────────────────────────────

enum CpuDriver {
    None,
    Amd { m: Module, ccd_base: u32, offset: f64, energy_unit: f64, last: Option<(u64, Instant)> },
    Intel { m: Module, tjmax: f64, energy_unit: f64, last: Option<(u64, Instant)>, cores: Vec<usize> },
}

struct Cpu {
    name: String,
    driver: CpuDriver,
    pci: GlobalLock,
}

pub fn cpuid(leaf: u32, sub: u32) -> [u32; 4] {
    #[allow(unused_unsafe)]
    let r = unsafe { std::arch::x86_64::__cpuid_count(leaf, sub) };
    [r.eax, r.ebx, r.ecx, r.edx]
}

pub fn cpu_brand() -> String {
    let mut b = Vec::new();
    if cpuid(0x8000_0000, 0)[0] >= 0x8000_0004 {
        for l in 0x8000_0002..=0x8000_0004u32 {
            for r in cpuid(l, 0) {
                b.extend_from_slice(&r.to_le_bytes());
            }
        }
    }
    String::from_utf8_lossy(&b).trim_matches(char::from(0)).trim().to_string()
}

/// (fabricant, famille, modèle, révision) selon CPUID.
pub fn cpu_fms() -> (String, u32, u32, u32) {
    let v = cpuid(0, 0);
    let mut vendor = Vec::new();
    for r in [v[1], v[3], v[2]] {
        vendor.extend_from_slice(&r.to_le_bytes());
    }
    let a = cpuid(1, 0)[0];
    let base_f = (a >> 8) & 0xF;
    let family = if base_f == 0xF { base_f + ((a >> 20) & 0xFF) } else { base_f };
    let model = if base_f == 0x6 || base_f == 0xF { ((a >> 4) & 0xF) | (((a >> 16) & 0xF) << 4) } else { (a >> 4) & 0xF };
    (String::from_utf8_lossy(&vendor).to_string(), family, model, a & 0xF)
}

/// Premier processeur logique de chaque cœur physique (groupe 0).
fn first_thread_of_cores() -> Vec<usize> {
    use windows_sys::Win32::System::SystemInformation::*;
    let mut out = Vec::new();
    unsafe {
        let mut len = 0u32;
        GetLogicalProcessorInformationEx(RelationProcessorCore, std::ptr::null_mut(), &mut len);
        let mut buf = vec![0u8; len as usize];
        if GetLogicalProcessorInformationEx(RelationProcessorCore, buf.as_mut_ptr() as _, &mut len) == 0 {
            return out;
        }
        let mut off = 0usize;
        while off < len as usize {
            let p = buf.as_ptr().add(off) as *const SYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX;
            let mask = (*p).Anonymous.Processor.GroupMask[0];
            if mask.Group == 0 && mask.Mask != 0 {
                out.push(mask.Mask.trailing_zeros() as usize);
            }
            off += (*p).Size as usize;
        }
    }
    out
}

impl Cpu {
    fn open(notes: &mut Vec<String>) -> Cpu {
        let name = cpu_brand();
        let (vendor, family, model, _) = cpu_fms();
        let pci = GlobalLock::new("Global\\Access_PCI");
        let mut driver = CpuDriver::None;
        if crate::pawnio::installed() {
            if vendor == "AuthenticAMD" && family >= 0x17 {
                match Module::load(blobs::AMD17) {
                    Ok(m) => {
                        // Zen 4 et suivants : sondes des CCD à une autre adresse
                        let zen4 = (family == 0x19 && matches!(model, 0x10..=0x1F | 0x60..=0x7F | 0xA0..=0xAF)) || family >= 0x1A;
                        let ccd_base = if zen4 { 0x0005_9B08 } else { 0x0005_9954 };
                        // Tctl décalé sur certains modèles (valeurs d'AMD)
                        let n = name.to_uppercase();
                        let offset = if ["1600X", "1700X", "1800X"].iter().any(|x| n.contains(x)) {
                            20.0
                        } else if n.contains("2700X") {
                            10.0
                        } else if n.contains("THREADRIPPER") && (n.contains(" 19") || n.contains(" 29")) {
                            27.0
                        } else {
                            0.0
                        };
                        let unit = m.one("ioctl_read_msr", &[0xC001_0299]).unwrap_or(0);
                        let energy_unit = 1.0 / (1u64 << ((unit >> 8) & 0x1F)) as f64;
                        driver = CpuDriver::Amd { m, ccd_base, offset, energy_unit, last: None };
                    }
                    Err(e) => notes.push(format!("Processeur : {e}")),
                }
            } else if vendor == "GenuineIntel" {
                match Module::load(blobs::INTEL_MSR) {
                    Ok(m) => {
                        let tjmax = m.one("ioctl_read_msr", &[0x1A2]).map(|v| ((v >> 16) & 0xFF) as f64).filter(|t| *t > 50.0).unwrap_or(100.0);
                        let unit = m.one("ioctl_read_msr", &[0x606]).unwrap_or(0);
                        let energy_unit = 1.0 / (1u64 << ((unit >> 8) & 0x1F)) as f64;
                        driver = CpuDriver::Intel { m, tjmax, energy_unit, last: None, cores: first_thread_of_cores() };
                    }
                    Err(e) => notes.push(format!("Processeur : {e}")),
                }
            }
        }
        Cpu { name, driver, pci }
    }

    fn read(&mut self, pdh: Option<&PdhValues>) -> Group {
        let mut g = Group::new("cpu", self.name.clone(), "cpu");
        let now = Instant::now();
        match &mut self.driver {
            CpuDriver::Amd { m, ccd_base, offset, energy_unit, last } => {
                let _l = self.pci.hold();
                if let Some(v) = m.one("ioctl_read_smn", &[0x0005_9800]) {
                    let mut t = ((v >> 21) & 0x7FF) as f64 * 0.125;
                    if v & (1 << 19) != 0 {
                        t -= 49.0;
                    }
                    g.add(Kind::Temp, "Processeur (Tctl/Tdie)", t - *offset);
                }
                for ccd in 0..8u32 {
                    if let Some(v) = m.one("ioctl_read_smn", &[(*ccd_base + ccd * 4) as u64]) {
                        if v & 0x800 != 0 {
                            g.add(Kind::Temp, format!("CCD {}", ccd + 1), (v & 0x7FF) as f64 / 8.0 - 49.0);
                        }
                    }
                }
                if let Some(e) = m.one("ioctl_read_msr", &[0xC001_029B]) {
                    let e = e & 0xFFFF_FFFF;
                    if let Some((pe, pt)) = *last {
                        let d = if e >= pe { e - pe } else { e + (1 << 32) - pe };
                        let dt = now.duration_since(pt).as_secs_f64();
                        if dt > 0.05 {
                            g.add(Kind::Power, "Puissance du processeur", d as f64 * *energy_unit / dt);
                        }
                    }
                    *last = Some((e, now));
                }
            }
            CpuDriver::Intel { m, tjmax, energy_unit, last, cores } => {
                if let Some(v) = m.one("ioctl_read_msr", &[0x1B1]) {
                    g.add(Kind::Temp, "Processeur (boîtier)", *tjmax - ((v >> 16) & 0x7F) as f64);
                }
                // température de chaque cœur : lue depuis ce cœur
                use windows_sys::Win32::System::Threading::{GetCurrentThread, SetThreadAffinityMask};
                let th = unsafe { GetCurrentThread() };
                let old = unsafe { SetThreadAffinityMask(th, 1) };
                for (i, &lp) in cores.iter().enumerate() {
                    if lp >= usize::BITS as usize {
                        break;
                    }
                    unsafe { SetThreadAffinityMask(th, 1usize << lp) };
                    if let Some(v) = m.one("ioctl_read_msr", &[0x19C]) {
                        if v & (1 << 31) != 0 {
                            g.add(Kind::Temp, format!("Cœur #{}", i + 1), *tjmax - ((v >> 16) & 0x7F) as f64);
                        }
                    }
                }
                if old != 0 {
                    unsafe { SetThreadAffinityMask(th, old) };
                }
                if let Some(e) = m.one("ioctl_read_msr", &[0x611]) {
                    let e = e & 0xFFFF_FFFF;
                    if let Some((pe, pt)) = *last {
                        let d = if e >= pe { e - pe } else { e + (1 << 32) - pe };
                        let dt = now.duration_since(pt).as_secs_f64();
                        if dt > 0.05 {
                            g.add(Kind::Power, "Puissance du processeur", d as f64 * *energy_unit / dt);
                        }
                    }
                    *last = Some((e, now));
                }
            }
            CpuDriver::None => {}
        }
        if let Some(p) = pdh {
            // « 0,3 » = groupe 0, processeur logique 3 ; les totaux sont ignorés
            let parse = |n: &str| n.split_once(',').and_then(|(a, b)| Some(a.parse::<u32>().ok()? * 64 + b.parse::<u32>().ok()?));
            let mut freq: Vec<(u32, f64)> = p.perf.iter().filter_map(|(n, v)| Some((parse(n)?, v * p.nominal / 100.0))).collect();
            freq.sort_by_key(|x| x.0);
            if !freq.is_empty() {
                let max = freq.iter().map(|x| x.1).fold(0.0, f64::max);
                let avg = freq.iter().map(|x| x.1).sum::<f64>() / freq.len() as f64;
                g.add(Kind::Freq, "Fréquence maximale des cœurs", max);
                g.add(Kind::Freq, "Fréquence moyenne", avg);
            }
            if let Some(t) = p.time.iter().find(|x| x.0 == "_Total") {
                g.add(Kind::Load, "Charge totale", t.1.min(100.0));
            }
            let mut load: Vec<(u32, f64)> = p.time.iter().filter_map(|(n, v)| Some((parse(n)?, *v))).collect();
            load.sort_by_key(|x| x.0);
            for (i, (_, v)) in load.iter().enumerate() {
                g.add(Kind::Load, format!("Thread #{}", i + 1), v.min(100.0));
            }
            for (i, (_, v)) in freq.iter().enumerate() {
                g.add(Kind::Freq, format!("Thread #{}", i + 1), *v);
            }
        }
        g
    }
}

unsafe impl Send for Cpu {}

// ── carte mère : puce Super I/O (Nuvoton NCT67xx, ITE IT86xx/IT87xx) ──────

#[derive(Clone, Copy, PartialEq)]
enum SioKind {
    Nuvoton { fans: usize },
    Ite { gain: f64 },
}

struct SuperIo {
    m: Module,
    lock: GlobalLock,
    kind: SioKind,
    chip: String,
    base: u16,
    msi: bool,
}

impl SuperIo {
    fn detect() -> Result<Option<SuperIo>, String> {
        if !crate::win::is_elevated() {
            return Err("droits administrateur requis".into());
        }
        let m = Module::load(blobs::LPC_IO)?;
        let lock = GlobalLock::new("Global\\Access_ISABUS.HTP.Method");
        let board = board_vendor();
        let msi = board.contains("micro-star") || board.contains("msi");
        let found = {
            let _l = lock.hold().ok_or("bus occupé par un autre logiciel")?;
            let mut found = None;
            for slot in 0..2u64 {
                if m.exec("ioctl_select_slot", &[slot], 0).is_err() {
                    continue;
                }
                let port = if slot == 0 { 0x2E } else { 0x4E };
                let out = |p: u64, v: u64| m.exec("ioctl_pio_outb", &[p, v], 0).is_ok();
                let inb = |r: u64| m.one("ioctl_superio_inb", &[r]).unwrap_or(0xFF) as u8;
                let outb = |r: u64, v: u64| {
                    let _ = m.exec("ioctl_superio_outb", &[r, v], 0);
                };
                let word = |r: u64| ((inb(r) as u16) << 8) | inb(r + 1) as u16;

                // Nuvoton / Winbond
                out(port, 0x87);
                out(port, 0x87);
                let (id, rev) = (inb(0x20), inb(0x21));
                let nct = match (id, rev) {
                    (0xC5, r) if r & 0xF0 == 0x60 => Some(("NCT6779D", 5)),
                    (0xC8, 0x03) => Some(("NCT6791D", 6)),
                    (0xC9, 0x11) | (0xC9, 0x13) => Some(("NCT6792D", 6)),
                    (0xD1, 0x21) => Some(("NCT6793D", 6)),
                    (0xD3, 0x52) => Some(("NCT6795D", 6)),
                    (0xD4, 0x23) => Some(("NCT6796D", 6)),
                    (0xD4, 0x2A) => Some(("NCT6796D-R", 7)),
                    (0xD4, 0x51) => Some(("NCT6797D", 7)),
                    (0xD4, 0x2B) => Some(("NCT6798D", 7)),
                    (0xD5, 0x92) => Some(("NCT6799D", 7)),
                    _ => None,
                };
                if let Some((chip, fans)) = nct {
                    outb(0x07, 0x0B); // circuit de surveillance
                    let base = word(0x60);
                    std::thread::sleep(std::time::Duration::from_millis(1));
                    let verify = word(0x60);
                    // verrou d'accès aux registres des NCT679x (comme LibreHardwareMonitor)
                    let lockreg = inb(0x28);
                    if lockreg & 0x10 != 0 {
                        outb(0x28, (lockreg & !0x10) as u64);
                    }
                    let _ = m.exec("ioctl_find_bars", &[], 0);
                    out(port, 0xAA);
                    if base == verify && base != 0 && base != 0xFFFF {
                        found = Some((SioKind::Nuvoton { fans }, chip.to_string(), base & 0xFFF8));
                        break;
                    }
                    continue;
                }
                out(port, 0xAA);

                // ITE
                out(port, 0x87);
                out(port, 0x01);
                out(port, 0x55);
                out(port, if slot == 0 { 0x55 } else { 0xAA });
                let id = word(0x20);
                let known = [
                    0x8613, 0x8620, 0x8625, 0x8628, 0x8631, 0x8655, 0x8665, 0x8686, 0x8688, 0x8689, 0x8695, 0x8696, 0x8705, 0x8712, 0x8716, 0x8718, 0x8720, 0x8721, 0x8726, 0x8728, 0x8771, 0x8772, 0x8790, 0x8792, 0x8795,
                ];
                if known.contains(&id) {
                    outb(0x07, 0x04);
                    let base = word(0x60);
                    let _ = m.exec("ioctl_find_bars", &[], 0);
                    outb(0x02, 0x02); // sortie du mode configuration
                    // pas de 12 mV pour les puces récentes, 16 mV pour les anciennes
                    let gain = if matches!(id, 0x8613) {
                        0.0109
                    } else if matches!(id, 0x8620 | 0x8628 | 0x8631 | 0x8655 | 0x8665 | 0x8686 | 0x8688 | 0x8689 | 0x8695 | 0x8696 | 0x8721 | 0x8728 | 0x8790 | 0x8792) {
                        0.012
                    } else {
                        0.016
                    };
                    if base != 0 && base != 0xFFFF {
                        found = Some((SioKind::Ite { gain }, format!("IT{id:04X}"), base & 0xFFF8));
                        break;
                    }
                } else {
                    outb(0x02, 0x02);
                }
            }
            found
        };
        let Some((kind, chip, base)) = found else { return Ok(None) };
        let s = SuperIo { m, lock, kind, chip, base, msi };
        // les NCT exposent l'identifiant Nuvoton une fois le verrou levé
        if let SioKind::Nuvoton { .. } = s.kind {
            let _l = s.lock.hold();
            if ((s.nct(0x804F) as u16) << 8 | s.nct(0x004F) as u16) != 0x5CA3 {
                return Err(format!("{} détectée mais illisible", s.chip));
            }
        }
        Ok(Some(s))
    }

    fn pio_out(&self, p: u16, v: u8) {
        let _ = self.m.exec("ioctl_pio_outb", &[p as u64, v as u64], 0);
    }
    fn pio_in(&self, p: u16) -> u8 {
        self.m.one("ioctl_pio_inb", &[p as u64]).unwrap_or(0) as u8
    }

    /// Registre Nuvoton « banque:adresse » (0x0490 = banque 4, registre 0x90).
    fn nct(&self, addr: u16) -> u8 {
        self.pio_out(self.base + 5, 0x4E);
        self.pio_out(self.base + 6, (addr >> 8) as u8);
        self.pio_out(self.base + 5, addr as u8);
        self.pio_in(self.base + 6)
    }

    fn ite(&self, reg: u8) -> u8 {
        self.pio_out(self.base + 5, reg);
        self.pio_in(self.base + 6)
    }

    fn read(&self) -> Option<Group> {
        let _l = self.lock.hold()?;
        let mut g = Group::new("board", format!("Carte mère ({})", self.chip), "board");
        match self.kind {
            SioKind::Nuvoton { fans } => {
                // températures (registres de lecture directe, en °C entiers)
                let names: [(&str, &str); 7] = [
                    ("Carte mère (SYSTIN)", "Système"),
                    ("Processeur (CPUTIN)", "Processeur (socket)"),
                    ("Sonde AUXTIN0", "VRM (MOS)"),
                    ("Sonde AUXTIN1", "Sonde AUXTIN1"),
                    ("Sonde AUXTIN2", "Chipset"),
                    ("Sonde AUXTIN3", "Sonde AUXTIN3"),
                    ("Sonde TSENSOR", "Sonde TSENSOR"),
                ];
                for (i, (generic, msi)) in names.iter().enumerate() {
                    let v = self.nct(0x490 + i as u16) as i8 as f64;
                    if (1.0..=125.0).contains(&v) {
                        g.add(Kind::Temp, if self.msi { *msi } else { *generic }, v);
                    }
                }
                // ventilateurs : compteur 13 bits
                let regs = [0x4B0u16, 0x4B2, 0x4B4, 0x4B6, 0x4B8, 0x4BA, 0x4CC];
                for (i, r) in regs.iter().take(fans).enumerate() {
                    let count = ((self.nct(*r) as u32) << 5) | (self.nct(r + 1) as u32 & 0x1F);
                    if (0x15..0x1FFF).contains(&count) {
                        let label = if self.msi {
                            match i {
                                0 => "Pompe".to_string(),
                                1 => "Ventilateur du processeur".to_string(),
                                n => format!("Ventilateur système #{}", n - 1),
                            }
                        } else {
                            format!("Ventilateur #{}", i + 1)
                        };
                        g.add(Kind::Fan, label, 1.35e6 / count as f64);
                    }
                }
                // tensions : 8 mV par unité, ponts diviseurs selon la carte
                let vbat_ok = self.nct(0x005D) & 1 != 0;
                for i in 0..16u16 {
                    let raw = self.nct(0x480 + i) as f64 * 0.008;
                    if raw <= 0.0 || (i == 8 && !vbat_ok) {
                        continue;
                    }
                    let (label, mul) = match (i, self.msi) {
                        (0, _) => ("Vcore".to_string(), 1.0),
                        (2, _) => ("AVCC".to_string(), 2.0),
                        (3, _) => ("+3,3 V".to_string(), 2.0),
                        (7, _) => ("+3,3 V veille".to_string(), 2.0),
                        (8, _) => ("Pile CMOS".to_string(), 2.0),
                        (1, true) => ("+5 V".to_string(), 5.0),
                        (4, true) => ("+12 V".to_string(), 12.0),
                        (12, true) => ("SoC".to_string(), 1.0),
                        (13, true) => ("Mémoire (DIMM)".to_string(), 2.0),
                        (5 | 6 | 9 | 10 | 11 | 14 | 15, true) => continue,
                        (n, false) => (format!("Entrée VIN{n}"), 1.0),
                        _ => continue,
                    };
                    g.add(Kind::Volt, label, raw * mul);
                }
            }
            SioKind::Ite { gain } => {
                for i in 0..6u8 {
                    let v = self.ite(0x29 + i) as i8 as f64;
                    if (1.0..=125.0).contains(&v) {
                        g.add(Kind::Temp, format!("Sonde #{}", i + 1), v);
                    }
                }
                let lo = [0x0Du8, 0x0E, 0x0F, 0x80, 0x82];
                let hi = [0x18u8, 0x19, 0x1A, 0x81, 0x83];
                for i in 0..5 {
                    let count = self.ite(lo[i]) as u32 | ((self.ite(hi[i]) as u32) << 8);
                    if count > 0x3F && count < 0xFFFF {
                        g.add(Kind::Fan, format!("Ventilateur #{}", i + 1), 1.35e6 / (count as f64 * 2.0));
                    }
                }
                for i in 0..9u8 {
                    let raw = self.ite(0x20 + i) as f64 * gain;
                    if raw > 0.0 {
                        g.add(Kind::Volt, if i == 0 { "Vcore".to_string() } else { format!("Entrée VIN{i}") }, raw);
                    }
                }
            }
        }
        Some(g)
    }
}

unsafe impl Send for SuperIo {}

fn board_vendor() -> String {
    use windows_sys::Win32::System::Registry::*;
    let key = crate::win::w("HARDWARE\\DESCRIPTION\\System\\BIOS");
    let name = crate::win::w("BaseBoardManufacturer");
    let mut buf = [0u16; 128];
    let mut len = (buf.len() * 2) as u32;
    let r = unsafe { RegGetValueW(HKEY_LOCAL_MACHINE, key.as_ptr(), name.as_ptr(), RRF_RT_REG_SZ, std::ptr::null_mut(), buf.as_mut_ptr() as _, &mut len) };
    if r != 0 {
        return String::new();
    }
    String::from_utf16_lossy(&buf[..(len as usize / 2).saturating_sub(1)]).to_lowercase()
}

// ── cartes graphiques ────────────────────────────────────────────────────

type NvDev = *mut std::ffi::c_void;

struct Nvml {
    count: unsafe extern "C" fn(*mut u32) -> i32,
    handle: unsafe extern "C" fn(u32, *mut NvDev) -> i32,
    name: unsafe extern "C" fn(NvDev, *mut u8, u32) -> i32,
    temp: unsafe extern "C" fn(NvDev, i32, *mut u32) -> i32,
    util: unsafe extern "C" fn(NvDev, *mut [u32; 2]) -> i32,
    clock: unsafe extern "C" fn(NvDev, i32, *mut u32) -> i32,
    power: unsafe extern "C" fn(NvDev, *mut u32) -> i32,
    fan: unsafe extern "C" fn(NvDev, *mut u32) -> i32,
    mem: unsafe extern "C" fn(NvDev, *mut [u64; 3]) -> i32,
}

impl Nvml {
    fn open() -> Option<Nvml> {
        use windows_sys::Win32::System::LibraryLoader::*;
        unsafe {
            // nvml.dll est installée par le pilote NVIDIA dans System32
            let w = crate::win::w("nvml.dll");
            let h = LoadLibraryExW(w.as_ptr(), std::ptr::null_mut(), LOAD_LIBRARY_SEARCH_SYSTEM32);
            if h.is_null() {
                return None;
            }
            let f = |n: &[u8]| GetProcAddress(h, n.as_ptr());
            let init: unsafe extern "C" fn() -> i32 = std::mem::transmute(f(b"nvmlInit_v2\0")?);
            if init() != 0 {
                return None;
            }
            Some(Nvml {
                count: std::mem::transmute(f(b"nvmlDeviceGetCount_v2\0")?),
                handle: std::mem::transmute(f(b"nvmlDeviceGetHandleByIndex_v2\0")?),
                name: std::mem::transmute(f(b"nvmlDeviceGetName\0")?),
                temp: std::mem::transmute(f(b"nvmlDeviceGetTemperature\0")?),
                util: std::mem::transmute(f(b"nvmlDeviceGetUtilizationRates\0")?),
                clock: std::mem::transmute(f(b"nvmlDeviceGetClockInfo\0")?),
                power: std::mem::transmute(f(b"nvmlDeviceGetPowerUsage\0")?),
                fan: std::mem::transmute(f(b"nvmlDeviceGetFanSpeed\0")?),
                mem: std::mem::transmute(f(b"nvmlDeviceGetMemoryInfo\0")?),
            })
        }
    }

    fn read(&self) -> Vec<Group> {
        let mut out = Vec::new();
        unsafe {
            let mut n = 0u32;
            if (self.count)(&mut n) != 0 {
                return out;
            }
            for i in 0..n {
                let mut d: NvDev = std::ptr::null_mut();
                if (self.handle)(i, &mut d) != 0 {
                    continue;
                }
                let mut name = [0u8; 96];
                (self.name)(d, name.as_mut_ptr(), name.len() as u32);
                let name = String::from_utf8_lossy(&name[..name.iter().position(|b| *b == 0).unwrap_or(0)]).to_string();
                let mut g = Group::new(format!("gpu{i}"), name, "gpu");
                let mut v = 0u32;
                if (self.temp)(d, 0, &mut v) == 0 {
                    g.add(Kind::Temp, "Processeur graphique", v as f64);
                }
                let mut u = [0u32; 2];
                if (self.util)(d, &mut u) == 0 {
                    g.add(Kind::Load, "Charge du processeur graphique", u[0] as f64);
                    g.add(Kind::Load, "Contrôleur mémoire", u[1] as f64);
                }
                if (self.clock)(d, 0, &mut v) == 0 {
                    g.add(Kind::Freq, "Fréquence du processeur graphique", v as f64);
                }
                if (self.clock)(d, 2, &mut v) == 0 {
                    g.add(Kind::Freq, "Fréquence de la mémoire", v as f64);
                }
                if (self.power)(d, &mut v) == 0 {
                    g.add(Kind::Power, "Puissance", v as f64 / 1000.0);
                }
                if (self.fan)(d, &mut v) == 0 {
                    g.add(Kind::Pct, "Ventilateurs", v as f64);
                }
                let mut m = [0u64; 3];
                if (self.mem)(d, &mut m) == 0 && m[0] > 0 {
                    g.add(Kind::Data, "Mémoire vidéo utilisée", m[2] as f64 / 1e9);
                    g.add(Kind::Load, "Mémoire vidéo", m[2] as f64 * 100.0 / m[0] as f64);
                }
                out.push(g);
            }
        }
        out
    }
}

unsafe impl Send for Nvml {}

#[repr(C)]
struct KmtAdapterInfo {
    h: u32,
    luid_low: u32,
    luid_high: i32,
    sources: u32,
    precise: i32,
}

#[repr(C)]
struct KmtEnum2 {
    count: u32,
    adapters: *mut KmtAdapterInfo,
}

#[repr(C)]
struct KmtQuery {
    h: u32,
    kind: i32,
    data: *mut std::ffi::c_void,
    size: u32,
}

#[repr(C)]
struct KmtPerf {
    index: u32,
    mem_freq: u64,
    max_mem_freq: u64,
    max_mem_freq_oc: u64,
    mem_bw: u64,
    pcie_bw: u64,
    fan_rpm: u32,
    power: u32,
    temp: u32,
    override_: u8,
}

#[link(name = "gdi32")]
extern "system" {
    fn D3DKMTEnumAdapters2(p: *mut KmtEnum2) -> i32;
    fn D3DKMTQueryAdapterInfo(p: *mut KmtQuery) -> i32;
    fn D3DKMTCloseAdapter(p: *const u32) -> i32;
}

/// Cartes graphiques : NVML pour NVIDIA, interface noyau de Windows pour les autres.
fn gpus(nvml: Option<&Nvml>, pdh: Option<&PdhValues>) -> Vec<Group> {
    let mut out = nvml.map(|n| n.read()).unwrap_or_default();
    unsafe {
        let mut e = KmtEnum2 { count: 0, adapters: std::ptr::null_mut() };
        if D3DKMTEnumAdapters2(&mut e) != 0 || e.count == 0 {
            return out;
        }
        let mut list: Vec<KmtAdapterInfo> = (0..e.count).map(|_| KmtAdapterInfo { h: 0, luid_low: 0, luid_high: 0, sources: 0, precise: 0 }).collect();
        e.adapters = list.as_mut_ptr();
        if D3DKMTEnumAdapters2(&mut e) != 0 {
            return out;
        }
        for (i, a) in list.iter().take(e.count as usize).enumerate() {
            // nom de l'adaptateur (KMTQAITYPE_ADAPTERREGISTRYINFO)
            let mut reg = [0u16; 260 * 4];
            let mut q = KmtQuery { h: a.h, kind: 8, data: reg.as_mut_ptr() as _, size: (reg.len() * 2) as u32 };
            let name = if D3DKMTQueryAdapterInfo(&mut q) == 0 {
                String::from_utf16_lossy(&reg[..reg[..260].iter().position(|c| *c == 0).unwrap_or(0)])
            } else {
                String::new()
            };
            let skip = name.is_empty() || name.contains("Basic Render") || name.contains("Microsoft") || out.iter().any(|g| g.name.contains(name.trim_start_matches("NVIDIA ").trim()) || name.contains(g.name.trim_start_matches("NVIDIA ")));
            if !skip {
                let mut g = Group::new(format!("kmt{i}"), name, "gpu");
                let mut p: KmtPerf = std::mem::zeroed();
                let mut q = KmtQuery { h: a.h, kind: 62, data: &mut p as *mut _ as _, size: std::mem::size_of::<KmtPerf>() as u32 };
                if D3DKMTQueryAdapterInfo(&mut q) == 0 {
                    if p.temp > 0 {
                        g.add(Kind::Temp, "Processeur graphique", p.temp as f64 / 10.0);
                    }
                    if p.fan_rpm > 0 {
                        g.add(Kind::Fan, "Ventilateur", p.fan_rpm as f64);
                    }
                    if p.mem_freq > 0 {
                        g.add(Kind::Freq, "Fréquence de la mémoire", p.mem_freq as f64 / 1e6);
                    }
                    if p.power > 0 {
                        g.add(Kind::Pct, "Puissance (part de la limite)", p.power as f64 / 10.0);
                    }
                }
                if let Some(pdh) = pdh {
                    let tag = format!("luid_0x{:08x}_0x{:08x}", a.luid_high as u32, a.luid_low).to_lowercase();
                    let load: f64 = pdh.gpu3d.iter().filter(|(n, _)| n.to_lowercase().contains(&tag)).map(|x| x.1).sum();
                    g.add(Kind::Load, "Charge 3D", load.min(100.0));
                    if let Some((_, v)) = pdh.vram.iter().find(|(n, _)| n.to_lowercase().contains(&tag)) {
                        g.add(Kind::Data, "Mémoire vidéo utilisée", v / 1e9);
                    }
                }
                if !g.items.is_empty() {
                    out.push(g);
                }
            }
            D3DKMTCloseAdapter(&a.h);
        }
    }
    out
}

// ── mémoire, stockage, batterie ──────────────────────────────────────────

fn memory() -> Group {
    let (total, avail) = crate::win::memory();
    let mut g = Group::new("mem", "Mémoire vive", "mem");
    let used = total.saturating_sub(avail);
    g.add(Kind::Data, "Utilisée", used as f64 / 1e9);
    g.add(Kind::Data, "Disponible", avail as f64 / 1e9);
    if total > 0 {
        g.add(Kind::Load, "Occupation", used as f64 * 100.0 / total as f64);
    }
    g
}

/// Température de chaque disque (SSD NVMe, SATA) : (nom, °C).
fn disk_temps() -> Vec<(String, String)> {
    use windows_sys::Win32::Storage::FileSystem::*;
    use windows_sys::Win32::System::IO::DeviceIoControl;
    let mut out = Vec::new();
    for n in 0..16 {
        let path = crate::win::w(&format!("\\\\.\\PhysicalDrive{n}"));
        unsafe {
            let h = CreateFileW(path.as_ptr(), 0, FILE_SHARE_READ | FILE_SHARE_WRITE, std::ptr::null(), OPEN_EXISTING, 0, std::ptr::null_mut());
            if h == windows_sys::Win32::Foundation::INVALID_HANDLE_VALUE {
                continue;
            }
            let query = |prop: i32, buf: &mut [u8]| -> bool {
                let q: [u32; 3] = [prop as u32, 0, 0]; // STORAGE_PROPERTY_QUERY : identifiant, type standard
                let mut ret = 0u32;
                DeviceIoControl(h, 0x002D_1400, q.as_ptr() as _, 12, buf.as_mut_ptr() as _, buf.len() as u32, &mut ret, std::ptr::null_mut()) != 0
            };
            let mut desc = [0u8; 1024];
            let mut name = format!("Disque {n}");
            if query(0, &mut desc) {
                // STORAGE_DEVICE_DESCRIPTOR : décalages du fabricant et du modèle
                let at = |o: usize| u32::from_le_bytes([desc[o], desc[o + 1], desc[o + 2], desc[o + 3]]) as usize;
                let s = |off: usize| {
                    if off == 0 || off >= desc.len() {
                        return String::new();
                    }
                    let end = desc[off..].iter().position(|b| *b == 0).map_or(desc.len(), |e| off + e);
                    String::from_utf8_lossy(&desc[off..end]).trim().to_string()
                };
                let (vendor, product) = (s(at(12)), s(at(16)));
                let full = format!("{vendor} {product}").trim().to_string();
                if !full.is_empty() {
                    name = full;
                }
            }
            let mut t = [0u8; 256];
            if query(52, &mut t) {
                // STORAGE_TEMPERATURE_DATA_DESCRIPTOR : InfoCount à l'octet 12, première mesure à 24
                let count = u16::from_le_bytes([t[12], t[13]]);
                if count > 0 {
                    let temp = i16::from_le_bytes([t[26], t[27]]);
                    if (1..150).contains(&temp) {
                        out.push((name, temp.to_string()));
                    }
                }
            }
            windows_sys::Win32::Foundation::CloseHandle(h);
        }
    }
    out
}

fn battery() -> Option<Group> {
    use windows_sys::Win32::System::Power::*;
    let mut s: SYSTEM_POWER_STATUS = unsafe { std::mem::zeroed() };
    if unsafe { GetSystemPowerStatus(&mut s) } == 0 || s.BatteryFlag & 128 != 0 || s.BatteryLifePercent == 255 {
        return None;
    }
    let mut g = Group::new("battery", if s.ACLineStatus == 1 { "Batterie (sur secteur)" } else { "Batterie" }, "battery");
    g.add(Kind::Pct, "Charge", s.BatteryLifePercent as f64);
    Some(g)
}
