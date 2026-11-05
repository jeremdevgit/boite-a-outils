// SPDX-License-Identifier: GPL-3.0-or-later — Copyright (C) 2026 jeremdevgit — voir LICENSE
//! Écrans : modes (résolution, fréquence), connecteur, HDR. Tout changement de
//! mode s'annule seul au bout de 15 s sans confirmation : un mode que l'écran ne
//! sait pas afficher ne laisse jamais l'utilisateur devant un écran noir.

use crate::win::w;
use serde_json::{json, Value};
use std::sync::atomic::{AtomicU64, Ordering};
use windows_sys::Win32::Devices::Display::*;
use windows_sys::Win32::Foundation::*;
use windows_sys::Win32::Graphics::Gdi::*;

const REVERT_SECS: u64 = 15;
// numéro du changement en attente : 0 = rien à annuler
static PENDING: AtomicU64 = AtomicU64::new(0);
static NEXT: AtomicU64 = AtomicU64::new(1);

fn wstr(b: &[u16]) -> String {
    String::from_utf16_lossy(&b[..b.iter().position(|c| *c == 0).unwrap_or(b.len())])
}

fn devmode() -> DEVMODEW {
    let mut m: DEVMODEW = unsafe { std::mem::zeroed() };
    m.dmSize = std::mem::size_of::<DEVMODEW>() as u16;
    m
}

fn current(device: &str) -> Option<DEVMODEW> {
    let d = w(device);
    let mut m = devmode();
    (unsafe { EnumDisplaySettingsExW(d.as_ptr(), ENUM_CURRENT_SETTINGS, &mut m, 0) } != 0).then_some(m)
}

fn connector(t: i32) -> &'static str {
    match t {
        0 => "VGA",
        1 => "S-Vidéo",
        2 => "Composite",
        3 => "Composantes",
        4 => "DVI",
        5 => "HDMI",
        6 => "LVDS (écran intégré)",
        8 => "D-Jack",
        9 => "SDI",
        10 => "DisplayPort",
        11 => "DisplayPort intégré",
        12 => "UDI",
        13 => "UDI intégré",
        14 => "Adaptateur",
        15 => "Miracast",
        16 => "Pilote indirect",
        17 => "Pilote indirect virtuel",
        18 => "DisplayPort tunnelé (USB-C)",
        _ => "",
    }
}

/// Informations de DisplayConfig, par nom de source (\\.\DISPLAY1).
struct Target {
    adapter: LUID,
    id: u32,
    tech: i32,
    hz: f64,
    monitor: String,
    hdr_supported: bool,
    hdr_on: bool,
    bits: u32,
}

fn targets() -> Vec<(String, Target)> {
    let mut out = Vec::new();
    unsafe {
        let (mut np, mut nm) = (0u32, 0u32);
        if GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, &mut np, &mut nm) != 0 {
            return out;
        }
        let mut paths = vec![std::mem::zeroed::<DISPLAYCONFIG_PATH_INFO>(); np as usize];
        let mut modes = vec![std::mem::zeroed::<DISPLAYCONFIG_MODE_INFO>(); nm as usize];
        if QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, &mut np, paths.as_mut_ptr(), &mut nm, modes.as_mut_ptr(), std::ptr::null_mut()) != 0 {
            return out;
        }
        paths.truncate(np as usize);
        for p in &paths {
            let mut src: DISPLAYCONFIG_SOURCE_DEVICE_NAME = std::mem::zeroed();
            src.header.r#type = DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME;
            src.header.size = std::mem::size_of_val(&src) as u32;
            src.header.adapterId = p.sourceInfo.adapterId;
            src.header.id = p.sourceInfo.id;
            if DisplayConfigGetDeviceInfo(&mut src.header) != 0 {
                continue;
            }
            let mut tgt: DISPLAYCONFIG_TARGET_DEVICE_NAME = std::mem::zeroed();
            tgt.header.r#type = DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME;
            tgt.header.size = std::mem::size_of_val(&tgt) as u32;
            tgt.header.adapterId = p.targetInfo.adapterId;
            tgt.header.id = p.targetInfo.id;
            let monitor = if DisplayConfigGetDeviceInfo(&mut tgt.header) == 0 { wstr(&tgt.monitorFriendlyDeviceName) } else { String::new() };
            let mut col: DISPLAYCONFIG_GET_ADVANCED_COLOR_INFO = std::mem::zeroed();
            col.header.r#type = DISPLAYCONFIG_DEVICE_INFO_GET_ADVANCED_COLOR_INFO;
            col.header.size = std::mem::size_of_val(&col) as u32;
            col.header.adapterId = p.targetInfo.adapterId;
            col.header.id = p.targetInfo.id;
            let has_col = DisplayConfigGetDeviceInfo(&mut col.header) == 0;
            let val = if has_col { col.Anonymous.value } else { 0 };
            let r = p.targetInfo.refreshRate;
            out.push((wstr(&src.viewGdiDeviceName), Target {
                adapter: p.targetInfo.adapterId,
                id: p.targetInfo.id,
                tech: p.targetInfo.outputTechnology,
                hz: if r.Denominator != 0 { r.Numerator as f64 / r.Denominator as f64 } else { 0.0 },
                monitor,
                hdr_supported: val & 1 != 0,
                hdr_on: val & 2 != 0,
                bits: if has_col { col.bitsPerColorChannel } else { 0 },
            }));
        }
    }
    out
}

pub fn list() -> Value {
    let tg = targets();
    let mut out = Vec::new();
    for i in 0.. {
        let mut dd: DISPLAY_DEVICEW = unsafe { std::mem::zeroed() };
        dd.cb = std::mem::size_of::<DISPLAY_DEVICEW>() as u32;
        if unsafe { EnumDisplayDevicesW(std::ptr::null(), i, &mut dd, 0) } == 0 {
            break;
        }
        if dd.StateFlags & DISPLAY_DEVICE_ATTACHED_TO_DESKTOP == 0 {
            continue;
        }
        let device = wstr(&dd.DeviceName);
        let Some(cur) = current(&device) else { continue };
        let d = w(&device);
        let mut modes: Vec<(u32, u32, u32)> = Vec::new();
        for k in 0.. {
            let mut m = devmode();
            if unsafe { EnumDisplaySettingsExW(d.as_ptr(), k, &mut m, 0) } == 0 {
                break;
            }
            if m.dmBitsPerPel == 32 && unsafe { m.Anonymous2.dmDisplayFlags } & 2 == 0 {
                let t = (m.dmPelsWidth, m.dmPelsHeight, m.dmDisplayFrequency);
                if !modes.contains(&t) {
                    modes.push(t);
                }
            }
        }
        modes.sort_by(|a, b| (b.0 * b.1, b.2).cmp(&(a.0 * a.1, a.2)));
        let t = tg.iter().find(|(n, _)| *n == device).map(|(_, t)| t);
        let pos = unsafe { cur.Anonymous1.Anonymous2.dmPosition };
        out.push(json!({
            "device": device, "adapter": wstr(&dd.DeviceString), "primary": dd.StateFlags & DISPLAY_DEVICE_PRIMARY_DEVICE != 0,
            "name": t.map(|t| t.monitor.clone()).filter(|m| !m.is_empty()).unwrap_or_else(|| device.trim_start_matches("\\\\.\\").to_string()),
            "width": cur.dmPelsWidth, "height": cur.dmPelsHeight, "hz": cur.dmDisplayFrequency, "exactHz": t.map(|t| t.hz).unwrap_or(0.0),
            "x": pos.x, "y": pos.y,
            "connector": t.map(|t| connector(t.tech)).unwrap_or(""), "hdrSupported": t.is_some_and(|t| t.hdr_supported), "hdrOn": t.is_some_and(|t| t.hdr_on), "bits": t.map(|t| t.bits).unwrap_or(0),
            "modes": modes.iter().map(|m| json!([m.0, m.1, m.2])).collect::<Vec<_>>(),
        }));
    }
    json!({ "displays": out, "revertSecs": REVERT_SECS })
}

fn cds_error(code: i32) -> String {
    match code {
        DISP_CHANGE_BADMODE => "mode refusé par le pilote : l'écran n'annonce pas cette combinaison".into(),
        DISP_CHANGE_RESTART => "un redémarrage est nécessaire".into(),
        DISP_CHANGE_NOTUPDATED => "le registre n'a pas pu être mis à jour".into(),
        DISP_CHANGE_FAILED => "le pilote a échoué".into(),
        c => format!("erreur {c}"),
    }
}

fn apply(device: &str, m: &DEVMODEW, flags: u32) -> i32 {
    let d = w(device);
    unsafe { ChangeDisplaySettingsExW(d.as_ptr(), m, std::ptr::null_mut(), flags, std::ptr::null()) }
}

/// `test` : demande seulement au pilote s'il accepte le mode, sans rien changer.
pub fn set_mode(device: &str, width: u32, height: u32, hz: u32, test: bool) -> Result<Value, String> {
    if !device.starts_with("\\\\.\\DISPLAY") {
        return Err("écran inconnu".into());
    }
    if !(1..=2000).contains(&hz) || width == 0 || height == 0 {
        return Err("valeurs invalides".into());
    }
    let before = current(device).ok_or("écran introuvable")?;
    let mut m = before;
    m.dmPelsWidth = width;
    m.dmPelsHeight = height;
    m.dmDisplayFrequency = hz;
    m.dmFields = DM_PELSWIDTH | DM_PELSHEIGHT | DM_DISPLAYFREQUENCY;
    let r = apply(device, &m, CDS_TEST);
    if r != DISP_CHANGE_SUCCESSFUL {
        return Err(cds_error(r));
    }
    if test {
        return Ok(json!({ "accepted": true }));
    }
    let r = apply(device, &m, 0);
    if r != DISP_CHANGE_SUCCESSFUL {
        return Err(cds_error(r));
    }
    let id = NEXT.fetch_add(1, Ordering::SeqCst);
    PENDING.store(id, Ordering::SeqCst);
    let dev = device.to_string();
    std::thread::spawn(move || {
        std::thread::sleep(std::time::Duration::from_secs(REVERT_SECS));
        if PENDING.compare_exchange(id, 0, Ordering::SeqCst, Ordering::SeqCst).is_ok() {
            apply(&dev, &before, 0);
        }
    });
    *PENDING_MODE.lock().unwrap() = Some((device.to_string(), Mode(m), Mode(before)));
    Ok(json!({ "pending": id, "seconds": REVERT_SECS }))
}

// DEVMODEW ne contient que des valeurs : partageable entre fils
struct Mode(DEVMODEW);
unsafe impl Send for Mode {}
static PENDING_MODE: std::sync::Mutex<Option<(String, Mode, Mode)>> = std::sync::Mutex::new(None);

/// Garde le mode essayé : inscrit dans le registre, plus d'annulation automatique.
pub fn confirm(id: u64) -> Result<(), String> {
    if PENDING.compare_exchange(id, 0, Ordering::SeqCst, Ordering::SeqCst).is_err() {
        return Err("délai dépassé : le mode précédent a été rétabli".into());
    }
    let slot = PENDING_MODE.lock().unwrap();
    let Some((device, m, _)) = slot.as_ref() else { return Ok(()) };
    let r = apply(device, &m.0, CDS_UPDATEREGISTRY);
    if r == DISP_CHANGE_SUCCESSFUL {
        Ok(())
    } else {
        Err(cds_error(r))
    }
}

/// Rétablit tout de suite le mode précédent.
pub fn revert(id: u64) -> Result<(), String> {
    if PENDING.compare_exchange(id, 0, Ordering::SeqCst, Ordering::SeqCst).is_err() {
        return Ok(());
    }
    let slot = PENDING_MODE.lock().unwrap();
    if let Some((device, _, before)) = slot.as_ref() {
        apply(device, &before.0, 0);
    }
    Ok(())
}

pub fn set_hdr(device: &str, on: bool) -> Result<(), String> {
    let tg = targets();
    let (_, t) = tg.iter().find(|(n, _)| n == device).ok_or("écran introuvable")?;
    if !t.hdr_supported {
        return Err("cet écran n'annonce pas le HDR".into());
    }
    unsafe {
        let mut s: DISPLAYCONFIG_SET_ADVANCED_COLOR_STATE = std::mem::zeroed();
        s.header.r#type = DISPLAYCONFIG_DEVICE_INFO_SET_ADVANCED_COLOR_STATE;
        s.header.size = std::mem::size_of_val(&s) as u32;
        s.header.adapterId = t.adapter;
        s.header.id = t.id;
        s.Anonymous.value = on as u32;
        let r = DisplayConfigSetDeviceInfo(&s.header);
        if r as u32 != ERROR_SUCCESS {
            return Err(format!("erreur {r}"));
        }
    }
    Ok(())
}
