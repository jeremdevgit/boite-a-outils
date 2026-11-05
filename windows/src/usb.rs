// SPDX-License-Identifier: GPL-3.0-or-later — Copyright (C) 2026 jeremdevgit — voir LICENSE
//! Ports USB : arbre contrôleurs → concentrateurs → ports, lu par les IOCTL du
//! pilote USB (comme USBView). Chaque port : protocoles, USB-C, port compagnon,
//! appareil, vitesse négociée, courant demandé, défauts signalés.
//!
//! Limite de Windows : aucun capteur de courant par port n'existe sur un PC, et
//! la puce e-marker d'un câble USB-C n'est pas lisible depuis une application.
//! Le courant affiché est celui que l'appareil déclare, et le verdict sur le câble
//! est déduit de la vitesse négociée, comparée à ce que l'appareil et le port savent faire.

use crate::win::w;
use serde_json::{json, Value};
use std::cell::Cell;
use std::collections::HashMap;
use std::sync::Mutex;
use windows_sys::core::GUID;
use windows_sys::Win32::Devices::DeviceAndDriverInstallation::*;
use windows_sys::Win32::Devices::Properties::DEVPROPKEY;
use windows_sys::Win32::Devices::Usb::*;
use windows_sys::Win32::Foundation::*;
use windows_sys::Win32::Storage::FileSystem::*;
use windows_sys::Win32::System::IO::DeviceIoControl;

const HCD_GUID: GUID = GUID { data1: 0x3ABF6F2D, data2: 0x71C4, data3: 0x462A, data4: [0x8A, 0x92, 0x1E, 0x68, 0x61, 0xE6, 0xAF, 0x27] };
// DEVPKEY_Device_PhysicalDeviceLocation : tampon ACPI _PLD (panneau, forme, couleur du connecteur)
const PLD_KEY: DEVPROPKEY = DEVPROPKEY { fmtid: GUID { data1: 0x540b947e, data2: 0x8b40, data3: 0x45bc, data4: [0xa8, 0xa2, 0x6a, 0x0b, 0x89, 0x4c, 0xbd, 0xa2] }, pid: 9 };
// DEVPKEY_Device_BusReportedDeviceDesc : le nom annoncé par l'appareil lui-même
const BUSDESC_KEY: DEVPROPKEY = DEVPROPKEY { fmtid: GUID { data1: 0x540b947e, data2: 0x8b40, data3: 0x45bc, data4: [0xa8, 0xa2, 0x6a, 0x0b, 0x89, 0x4c, 0xbd, 0xa2] }, pid: 4 };

struct Handle(HANDLE);
impl Drop for Handle {
    fn drop(&mut self) {
        unsafe { CloseHandle(self.0) };
    }
}

fn open(path: &str) -> Option<Handle> {
    let p = w(path);
    let h = unsafe { CreateFileW(p.as_ptr(), GENERIC_WRITE, FILE_SHARE_WRITE, std::ptr::null(), OPEN_EXISTING, 0, std::ptr::null_mut()) };
    (h != INVALID_HANDLE_VALUE).then(|| Handle(h))
}

/// IOCTL avec le même tampon en entrée et en sortie ; nombre d'octets reçus.
fn ioctl(h: &Handle, code: u32, buf: &mut [u8], input: usize) -> Option<usize> {
    let mut got = 0u32;
    let p = buf.as_mut_ptr() as *mut _;
    let ok = unsafe { DeviceIoControl(h.0, code, p, input as u32, p, buf.len() as u32, &mut got, std::ptr::null_mut()) };
    (ok != 0).then_some(got as usize)
}

fn u16_at(b: &[u8], o: usize) -> u16 {
    u16::from_le_bytes([b[o], b[o + 1]])
}
fn u32_at(b: &[u8], o: usize) -> u32 {
    u32::from_le_bytes([b[o], b[o + 1], b[o + 2], b[o + 3]])
}
fn wide_at(b: &[u8], o: usize) -> String {
    let u: Vec<u16> = b[o.min(b.len())..].chunks_exact(2).map(|c| u16::from_le_bytes([c[0], c[1]])).take_while(|c| *c != 0).collect();
    String::from_utf16_lossy(&u)
}

/// Requête { numéro de port, … } dont la réponse est un nom Unicode à l'octet 8.
fn node_name(hub: &Handle, code: u32, port: u32) -> Option<String> {
    let mut b = vec![0u8; 1024];
    b[..4].copy_from_slice(&port.to_le_bytes());
    ioctl(hub, code, &mut b, 8)?;
    Some(wide_at(&b, 8)).filter(|s| !s.is_empty())
}

/// Descripteur USB lu auprès de l'appareil par son port.
fn descriptor(hub: &Handle, port: u32, kind: u8, index: u8, lang: u16, len: u16) -> Option<Vec<u8>> {
    let mut b = vec![0u8; 12 + len as usize];
    b[..4].copy_from_slice(&port.to_le_bytes());
    b[4] = 0x80;
    b[5] = 6;
    b[6..8].copy_from_slice(&(((kind as u16) << 8) | index as u16).to_le_bytes());
    b[8..10].copy_from_slice(&lang.to_le_bytes());
    b[10..12].copy_from_slice(&len.to_le_bytes());
    let n = b.len();
    let got = ioctl(hub, IOCTL_USB_GET_DESCRIPTOR_FROM_NODE_CONNECTION, &mut b, n)?;
    (got > 12).then(|| b[12..got].to_vec())
}

fn string_desc(hub: &Handle, port: u32, index: u8) -> String {
    if index == 0 {
        return String::new();
    }
    let Some(d) = descriptor(hub, port, 3, index, 0x0409, 255).filter(|d| d.len() >= 4) else { return String::new() };
    let u: Vec<u16> = d[2..].chunks_exact(2).map(|c| u16::from_le_bytes([c[0], c[1]])).collect();
    String::from_utf16_lossy(&u).trim().to_string()
}

/// Fonctions d'un appareil, d'après ses classes d'interface.
fn class_name(c: u8) -> &'static str {
    match c {
        1 => "Audio",
        2 | 10 => "Communication / réseau",
        3 => "Clavier, souris ou manette (HID)",
        5 => "Retour de force / capteur physique",
        6 => "Appareil photo (PTP)",
        7 => "Imprimante",
        8 => "Stockage",
        9 => "Concentrateur USB",
        11 => "Carte à puce",
        13 => "Sécurité",
        14 => "Webcam / vidéo",
        15 => "Santé",
        16 => "Audio / vidéo",
        17 => "Affichage (Billboard)",
        18 => "Pont USB-C",
        0xDC => "Diagnostic",
        0xE0 => "Sans fil (Bluetooth, Wi-Fi)",
        0xEF => "Composite",
        0xFE => "Mise à jour de micrologiciel",
        0xFF => "Propre au fabricant",
        _ => "Autre",
    }
}

/// Lit le plus haut débit annoncé dans le descripteur BOS (Gbit/s, 0 si inconnu).
fn bos_max_gbps(hub: &Handle, port: u32) -> f64 {
    let Some(head) = descriptor(hub, port, 15, 0, 0, 5).filter(|d| d.len() >= 5) else { return 0.0 };
    let total = u16_at(&head, 2).min(1024);
    let Some(d) = descriptor(hub, port, 15, 0, 0, total) else { return 0.0 };
    let (mut i, mut best) = (head[0] as usize, 0.0f64);
    while i + 3 < d.len() && d[i] >= 3 {
        let len = d[i] as usize;
        if d[i + 1] == 16 && i + len <= d.len() {
            match d[i + 2] {
                3 if d.len() > i + 5 && u16_at(&d, i + 4) & 8 != 0 => best = best.max(5.0),
                0x0A if len >= 16 => {
                    let n = (d[i + 4] & 0x1f) as usize + 1;
                    for k in 0..n {
                        let o = i + 12 + k * 4;
                        if o + 4 > i + len {
                            break;
                        }
                        let a = u32_at(&d, o);
                        let exp = [1e-9, 1e-6, 1e-3, 1.0][((a >> 4) & 3) as usize];
                        best = best.max((a >> 16) as f64 * exp);
                    }
                }
                _ => {}
            }
        }
        i += len;
    }
    best
}

/// Emplacement physique déclaré par la carte mère (ACPI _PLD), quand elle le renseigne.
fn parse_pld(b: &[u8]) -> Value {
    if b.len() < 16 {
        return Value::Null;
    }
    let bits = u64::from_le_bytes(b[8..16].try_into().unwrap_or([0; 8]));
    let panel = ["Dessus", "Dessous", "Gauche", "Droite", "Avant", "Arrière", "Inconnu", "Inconnu"][((bits >> 3) & 7) as usize];
    let vert = ["haut", "milieu", "bas", ""][((bits >> 6) & 3) as usize];
    let hor = ["gauche", "centre", "droite", ""][((bits >> 8) & 3) as usize];
    let color = u32_at(b, 0) >> 8 & 0xff_ffff;
    json!({ "panel": panel, "vertical": vert, "horizontal": hor, "visible": bits & 1 != 0, "color": if b[0] & 0x80 != 0 { format!("#{color:06x}") } else { String::new() } })
}

struct Dev {
    name: String,
    instance: String,
    pld: Value,
}

/// Appareils du bus USB, indexés par clé de pilote (lien avec les ports).
fn devices() -> HashMap<String, Dev> {
    let mut map = HashMap::new();
    let usb = w("USB");
    unsafe {
        let set = SetupDiGetClassDevsW(std::ptr::null(), usb.as_ptr(), std::ptr::null_mut(), DIGCF_ALLCLASSES | DIGCF_PRESENT);
        if set as isize == -1 {
            return map;
        }
        let mut i = 0;
        loop {
            let mut info: SP_DEVINFO_DATA = std::mem::zeroed();
            info.cbSize = std::mem::size_of::<SP_DEVINFO_DATA>() as u32;
            if SetupDiEnumDeviceInfo(set, i, &mut info) == 0 {
                break;
            }
            i += 1;
            let reg = |prop: u32| -> String {
                let mut b = [0u8; 1024];
                if SetupDiGetDeviceRegistryPropertyW(set, &info, prop, std::ptr::null_mut(), b.as_mut_ptr(), b.len() as u32, std::ptr::null_mut()) != 0 {
                    wide_at(&b, 0)
                } else {
                    String::new()
                }
            };
            let propb = |key: &DEVPROPKEY| -> Vec<u8> {
                let mut b = vec![0u8; 512];
                let (mut ty, mut n) = (0u32, 0u32);
                if SetupDiGetDevicePropertyW(set, &info, key, &mut ty, b.as_mut_ptr(), b.len() as u32, &mut n, 0) != 0 {
                    b.truncate(n as usize);
                    b
                } else {
                    Vec::new()
                }
            };
            let key = reg(SPDRP_DRIVER);
            if key.is_empty() {
                continue;
            }
            let bus = wide_at(&propb(&BUSDESC_KEY), 0);
            let mut name = reg(SPDRP_FRIENDLYNAME);
            if name.is_empty() {
                name = if bus.is_empty() { reg(SPDRP_DEVICEDESC) } else { bus };
            }
            let mut id = [0u16; 512];
            SetupDiGetDeviceInstanceIdW(set, &info, id.as_mut_ptr(), 512, std::ptr::null_mut());
            let end = id.iter().position(|c| *c == 0).unwrap_or(0);
            map.insert(key.to_lowercase(), Dev { name, instance: String::from_utf16_lossy(&id[..end]), pld: parse_pld(&propb(&PLD_KEY)) });
        }
        SetupDiDestroyDeviceInfoList(set);
    }
    map
}

/// Contrôleurs hôtes : (nom, chemin du périphérique).
fn controllers() -> Vec<(String, String)> {
    let mut out = Vec::new();
    unsafe {
        let set = SetupDiGetClassDevsW(&HCD_GUID, std::ptr::null(), std::ptr::null_mut(), DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
        if set as isize == -1 {
            return out;
        }
        let mut i = 0;
        loop {
            let mut itf: SP_DEVICE_INTERFACE_DATA = std::mem::zeroed();
            itf.cbSize = std::mem::size_of::<SP_DEVICE_INTERFACE_DATA>() as u32;
            if SetupDiEnumDeviceInterfaces(set, std::ptr::null(), &HCD_GUID, i, &mut itf) == 0 {
                break;
            }
            i += 1;
            let mut buf = vec![0u64; 256];
            let detail = buf.as_mut_ptr() as *mut SP_DEVICE_INTERFACE_DETAIL_DATA_W;
            (*detail).cbSize = std::mem::size_of::<SP_DEVICE_INTERFACE_DETAIL_DATA_W>() as u32;
            let mut info: SP_DEVINFO_DATA = std::mem::zeroed();
            info.cbSize = std::mem::size_of::<SP_DEVINFO_DATA>() as u32;
            if SetupDiGetDeviceInterfaceDetailW(set, &itf, detail, 2048, std::ptr::null_mut(), &mut info) == 0 {
                continue;
            }
            let path = wide_at(std::slice::from_raw_parts(buf.as_ptr() as *const u8, 2048), 4);
            let mut b = [0u8; 512];
            let name = if SetupDiGetDeviceRegistryPropertyW(set, &info, SPDRP_DEVICEDESC, std::ptr::null_mut(), b.as_mut_ptr(), 512, std::ptr::null_mut()) != 0 { wide_at(&b, 0) } else { "Contrôleur USB".into() };
            out.push((name, path));
        }
        SetupDiDestroyDeviceInfoList(set);
    }
    out
}

fn status_text(s: u32) -> (&'static str, &'static str) {
    match s {
        0 => ("free", ""),
        1 => ("ok", ""),
        2 => ("bad", "L'appareil ne répond pas correctement à l'énumération (câble, port ou appareil défaillant)."),
        3 => ("bad", "Erreur générale signalée par le port."),
        4 => ("bad", "Surintensité : l'appareil a tiré trop de courant, le port l'a coupé. Débranchez-le et vérifiez câble et appareil."),
        5 => ("bad", "Courant insuffisant : ce port ne peut pas fournir ce que demande l'appareil. Essayez un port de la carte mère ou un concentrateur alimenté."),
        6 => ("warn", "Bande passante insuffisante sur ce contrôleur (trop d'appareils en même temps)."),
        7 => ("bad", "Trop de concentrateurs en chaîne."),
        8 => ("warn", "Appareil rapide sur un ancien concentrateur."),
        9 => ("warn", "Énumération en cours."),
        10 => ("warn", "Réinitialisation en cours."),
        _ => ("warn", "État inconnu."),
    }
}

/// Verdict sur le câble, déduit des vitesses : (niveau, titre, explication).
fn cable_verdict(type_c: bool, port_ss: bool, op_ss: bool, op_ssp: bool, cap_ss: bool, cap_ssp: bool, bcd: u16, via_hub: bool) -> (&'static str, String, String) {
    let hub = if via_hub { " (ou le concentrateur en amont)" } else { "" };
    let c = if type_c { "USB-C" } else { "USB" };
    if op_ssp {
        return ("ok", format!("Câble {c} : 10 Gbit/s ou plus, confirmé"), "Le lien fonctionne en SuperSpeed+ : ce câble a forcément les paires rapides et la qualité nécessaire.".into());
    }
    if op_ss {
        if cap_ssp {
            return ("warn", format!("Câble {c} : limité à 5 Gbit/s ?"), format!("L'appareil sait aller à 10 Gbit/s ou plus mais fonctionne à 5. Le câble, le port{hub} en est la cause : essayez un câble certifié 10 Gbit/s ou un autre port."));
        }
        return ("ok", format!("Câble {c} : au moins 5 Gbit/s, confirmé"), "Le lien SuperSpeed fonctionne. L'appareil ne va pas plus vite, donc le maximum du câble ne peut pas être testé ici.".into());
    }
    if cap_ss {
        if port_ss {
            return ("bad", "Câble USB 2.0 probable : appareil bridé à 480 Mbit/s".to_string(), format!("L'appareil et le port savent faire de l'USB 3, mais le lien est en USB 2. La cause la plus fréquente est un câble sans paires rapides (câble de charge). Sinon : prise mal enfoncée ou faux contact{hub}."));
        }
        return ("warn", "Limité par le port".to_string(), "L'appareil sait faire de l'USB 3, mais ce port n'est qu'en USB 2 : branchez-le sur un port USB 3 pour tester le câble.".into());
    }
    if bcd >= 0x0200 {
        return ("info", "Câble non testable avec cet appareil".to_string(), "Cet appareil est en USB 2 : il n'utilise que les fils USB 2 du câble. Branchez un SSD externe USB 3 avec ce câble pour le tester.".into());
    }
    ("info", "Câble non testable avec cet appareil".to_string(), "Appareil lent (USB 1) : il ne dit rien des capacités du câble.".into())
}

/// Ce qu'on demande à l'appareil lui-même : ne change pas tant qu'il reste branché.
/// Le redemander à chaque rafraîchissement dérangerait inutilement les appareils.
#[derive(Clone)]
struct Described {
    power: u32,
    self_powered: bool,
    classes: Vec<&'static str>,
    product: String,
    maker: String,
    bos: f64,
}
static DESCRIBED: Mutex<Option<HashMap<String, Described>>> = Mutex::new(None);
static DEVICES: Mutex<Option<HashMap<String, Dev>>> = Mutex::new(None);

fn walk_hub(path: &str, chain: &str, depth: u32, devs: &HashMap<String, Dev>, labels: &Value, missing: &Cell<bool>) -> Value {
    let Some(hub) = open(path) else { return json!({ "error": "accès refusé" }) };
    let mut info = vec![0u8; 76];
    if ioctl(&hub, IOCTL_USB_GET_NODE_INFORMATION, &mut info, 76).is_none() {
        return json!({ "error": "lecture impossible" });
    }
    let nports = info[6] as u32;
    let bus_powered = info[75] != 0;
    let mut ex = vec![0u8; 64];
    let hub_type = if ioctl(&hub, IOCTL_USB_GET_HUB_INFORMATION_EX, &mut ex, 0).is_some() { u32_at(&ex, 0) } else { 0 };
    let mut ports = Vec::new();
    for port in 1..=nports {
        let mut c = vec![0u8; 35 + 30 * 11];
        c[..4].copy_from_slice(&port.to_le_bytes());
        if ioctl(&hub, IOCTL_USB_GET_NODE_CONNECTION_INFORMATION_EX, &mut c, 4).is_none() {
            continue;
        }
        let (is_hub, status) = (c[24] != 0, u32_at(&c, 31));
        // protocoles du port et capacités de l'appareil
        let mut v2 = vec![0u8; 16];
        v2[..4].copy_from_slice(&port.to_le_bytes());
        v2[4..8].copy_from_slice(&16u32.to_le_bytes());
        v2[8..12].copy_from_slice(&4u32.to_le_bytes()); // Usb300 demandé
        let has_v2 = ioctl(&hub, IOCTL_USB_GET_NODE_CONNECTION_INFORMATION_EX_V2, &mut v2, 16).is_some();
        let (protos, flags) = if has_v2 { (u32_at(&v2, 8), u32_at(&v2, 12)) } else { (0, 0) };
        // connecteur physique
        let mut pc = vec![0u8; 512];
        pc[..4].copy_from_slice(&port.to_le_bytes());
        pc[4..8].copy_from_slice(&512u32.to_le_bytes());
        let has_pc = ioctl(&hub, IOCTL_USB_GET_PORT_CONNECTOR_PROPERTIES, &mut pc, 512).is_some();
        let props = if has_pc { u32_at(&pc, 8) } else { 0 };
        let type_c = props & 8 != 0;
        // un connecteur USB 3 est vu comme deux ports logiques (USB 2 et USB 3) : un
        // appareil lent se place sur le port USB 2, dont le compagnon prouve le connecteur USB 3
        let companion = if has_pc { u16_at(&pc, 14) } else { 0 };
        let port_ss = protos & 4 != 0 || hub_type == 3 || companion != 0;
        // en SuperSpeed, Windows peut encore annoncer « High Speed » dans cette structure (comme le note USBView)
        let speed = if flags & 1 != 0 { c[23].max(3) } else { c[23] };
        let (level, problem) = status_text(status);
        let id = format!("{chain}#{port}");
        let label = labels[&id].as_str().unwrap_or("");
        let mut p = json!({
            "id": id, "port": port, "typeC": type_c, "userConnectable": !has_pc || props & 1 != 0, "debug": props & 2 != 0,
            "usb1": protos & 1 != 0, "usb2": protos & 2 != 0, "usb3": port_ss, "companion": companion,
            "status": level, "problem": problem, "label": label,
            "budget": if port_ss { 900 } else { 500 } as u32,
        });
        if status != 0 {
            let key = node_name(&hub, IOCTL_USB_GET_NODE_CONNECTION_DRIVERKEY_NAME, port).unwrap_or_default().to_lowercase();
            let dev = devs.get(&key);
            if dev.is_none() {
                missing.set(true);
            }
            let bcd = u16_at(&c, 6);
            let (vid, pid) = (u16_at(&c, 12), u16_at(&c, 14));
            let cache_key = format!("{id}|{vid:04x}{pid:04x}{bcd:04x}|{speed}|{status}");
            let cached = DESCRIBED.lock().unwrap().get_or_insert_with(HashMap::new).get(&cache_key).cloned();
            let info = cached.unwrap_or_else(|| {
                let (mut power, mut self_powered, mut classes) = (0u32, false, Vec::<&'static str>::new());
                if c[4 + 4] != 0 {
                    classes.push(class_name(c[4 + 4]));
                }
                if let Some(d) = descriptor(&hub, port, 2, 0, 0, 1024).filter(|d| d.len() >= 9) {
                    self_powered = d[7] & 0x40 != 0;
                    power = d[8] as u32 * if speed >= 3 { 8 } else { 2 };
                    let mut i = d[0] as usize;
                    while i + 8 < d.len() && d[i] >= 2 {
                        if d[i + 1] == 4 {
                            let n = class_name(d[i + 5]);
                            if !classes.contains(&n) {
                                classes.push(n);
                            }
                        }
                        i += d[i] as usize;
                    }
                }
                classes.retain(|x| *x != "Composite");
                let bos = if status == 1 && bcd >= 0x0201 { bos_max_gbps(&hub, port) } else { 0.0 };
                let info = Described { power, self_powered, classes, product: string_desc(&hub, port, c[4 + 15]), maker: string_desc(&hub, port, c[4 + 14]), bos };
                DESCRIBED.lock().unwrap().get_or_insert_with(HashMap::new).insert(cache_key, info.clone());
                info
            });
            let Described { power, self_powered: self_pow, classes, product, maker, bos } = info;
            let (op_ss, cap_ss, op_ssp, cap_ssp) = (flags & 1 != 0 || speed >= 3, flags & 2 != 0, flags & 4 != 0, flags & 8 != 0);
            let (cable_level, cable, why) = cable_verdict(type_c, port_ss, op_ss, op_ssp, cap_ss || bos >= 5.0, cap_ssp || bos >= 10.0, bcd, depth > 0);
            let name = dev.map(|d| d.name.clone()).filter(|n| !n.is_empty() && !n.starts_with("Périphérique USB") && !n.starts_with("USB ")).or_else(|| Some(product.clone()).filter(|p| !p.is_empty())).unwrap_or_else(|| dev.map(|d| d.name.clone()).unwrap_or_else(|| "Appareil inconnu".into()));
            let speed_txt = if op_ssp { "SuperSpeed+ · 10 Gbit/s ou plus" } else { match speed { 0 => "Low Speed · 1,5 Mbit/s", 1 => "Full Speed · 12 Mbit/s", 2 => "High Speed · 480 Mbit/s", _ => "SuperSpeed · 5 Gbit/s" } };
            let budget = if op_ss { 900 } else { 500 };
            p["device"] = json!({
                "name": name, "product": product, "maker": maker, "vid": format!("{vid:04X}"), "pid": format!("{pid:04X}"), "usb": format!("{:x}.{:x}", bcd >> 8, (bcd >> 4) & 15),
                "speed": speed_txt, "speedCode": if op_ssp { 4 } else { speed }, "power": power, "selfPowered": self_pow, "budget": budget,
                "functions": classes, "isHub": is_hub, "instance": dev.map(|d| d.instance.clone()).unwrap_or_default(), "place": dev.map(|d| d.pld.clone()).unwrap_or(Value::Null),
                "cable": { "level": cable_level, "title": cable, "why": why },
                "maxGbps": bos,
            });
            if is_hub {
                if let Some(child) = node_name(&hub, IOCTL_USB_GET_NODE_CONNECTION_NAME, port) {
                    p["hub"] = walk_hub(&format!("\\\\.\\{child}"), &id, depth + 1, devs, labels, missing);
                }
            }
        }
        ports.push(p);
    }
    json!({ "ports": ports, "busPowered": bus_powered, "type": match hub_type { 1 => "Racine", 2 => "USB 2", 3 => "USB 3", _ => "" } })
}

fn labels_path() -> std::path::PathBuf {
    crate::win::data_dir().join("ports-usb.json")
}

pub fn set_label(id: &str, label: &str) -> Result<(), String> {
    let mut v: Value = std::fs::read(labels_path()).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_else(|| json!({}));
    if label.trim().is_empty() {
        v.as_object_mut().map(|o| o.remove(id));
    } else {
        v[id] = json!(label.trim());
    }
    std::fs::write(labels_path(), v.to_string()).map_err(|e| e.to_string())
}

pub fn tree() -> Value {
    let labels: Value = std::fs::read(labels_path()).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_else(|| json!({}));
    let mut cache = DEVICES.lock().unwrap();
    let devs = cache.get_or_insert_with(devices);
    let ctrl = controllers();
    let walk = |devs: &HashMap<String, Dev>, missing: &Cell<bool>| {
        let mut list = Vec::new();
        for (i, (name, path)) in ctrl.iter().enumerate() {
            let Some(hcd) = open(path) else {
                list.push(json!({ "name": name, "error": "accès refusé" }));
                continue;
            };
            let mut b = vec![0u8; 1024];
            let root = ioctl(&hcd, IOCTL_USB_GET_ROOT_HUB_NAME, &mut b, 0).map(|_| wide_at(&b, 4));
            let hub = root.map(|r| walk_hub(&format!("\\\\.\\{r}"), &format!("c{i}"), 0, devs, &labels, missing)).unwrap_or(Value::Null);
            list.push(json!({ "name": name, "hub": hub }));
        }
        list
    };
    let missing = Cell::new(false);
    let mut list = walk(devs, &missing);
    // appareil inconnu (tout juste branché) : la liste de Windows est relue, une seule fois
    if missing.get() {
        *devs = devices();
        list = walk(devs, &missing);
    }
    json!({ "controllers": list })
}
