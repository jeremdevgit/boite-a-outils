// SPDX-License-Identifier: GPL-3.0-or-later — Copyright (C) 2026 jeremdevgit — voir LICENSE
//! Tests de stabilité (façon OCCT) et mesure de vitesse des disques.
//!
//! - Processeur : chaque fil refait sans cesse le même calcul flottant intensif
//!   et compare son résultat à une référence ; une seule différence signale un
//!   processeur instable (surcadençage, sous-tension, surchauffe).
//! - Mémoire : écrit puis relit des motifs dans une grande partie de la mémoire
//!   libre ; une valeur relue différente signale une barrette ou un réglage
//!   (XMP/EXPO) instable.

use serde_json::{json, Value};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

struct Run {
    kind: String,
    started: Instant,
    limit: Option<Duration>,
    threads: usize,
    stop: Arc<AtomicBool>,
    iterations: Arc<AtomicU64>,
    errors: Arc<AtomicU64>,
    bytes: u64,
    first_error: Arc<Mutex<Option<String>>>,
    ended: Arc<Mutex<Option<Instant>>>,
}

static RUN: Mutex<Option<Run>> = Mutex::new(None);

pub fn status() -> Value {
    let g = RUN.lock().unwrap();
    let Some(r) = g.as_ref() else { return json!({ "running": false }) };
    let ended = *r.ended.lock().unwrap();
    let elapsed = ended.unwrap_or_else(Instant::now).duration_since(r.started).as_secs();
    json!({
        "running": ended.is_none(),
        "kind": r.kind,
        "elapsed": elapsed,
        "limit": r.limit.map(|d| d.as_secs()),
        "threads": r.threads,
        "iterations": r.iterations.load(Ordering::Relaxed),
        "errors": r.errors.load(Ordering::Relaxed),
        "bytes": r.bytes,
        "firstError": r.first_error.lock().unwrap().clone(),
    })
}

pub fn stop() {
    if let Some(r) = RUN.lock().unwrap().as_ref() {
        r.stop.store(true, Ordering::Relaxed);
    }
}

/// Lance un test : kind = "cpu" ou "mem" ; minutes = 0 pour un test sans fin.
pub fn start(kind: &str, threads: usize, minutes: u64, mem_pct: u64) -> Result<Value, String> {
    let mut g = RUN.lock().unwrap();
    if g.as_ref().is_some_and(|r| r.ended.lock().unwrap().is_none()) {
        return Err("un test est déjà en cours".into());
    }
    let max = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(4);
    let threads = if threads == 0 { max } else { threads.min(max * 2) };
    let stop = Arc::new(AtomicBool::new(false));
    let iterations = Arc::new(AtomicU64::new(0));
    let errors = Arc::new(AtomicU64::new(0));
    let first_error = Arc::new(Mutex::new(None));
    let ended = Arc::new(Mutex::new(None));
    let limit = (minutes > 0).then(|| Duration::from_secs(minutes * 60));
    let mut bytes = 0u64;
    let handles: Vec<std::thread::JoinHandle<()>> = match kind {
        "cpu" => {
            let reference = cpu_kernel(0);
            (0..threads)
                .map(|t| {
                    let (stop, it, er, fe) = (stop.clone(), iterations.clone(), errors.clone(), first_error.clone());
                    std::thread::spawn(move || {
                        while !stop.load(Ordering::Relaxed) {
                            let r = cpu_kernel(0);
                            if r != reference {
                                er.fetch_add(1, Ordering::Relaxed);
                                fe.lock().unwrap().get_or_insert_with(|| format!("fil {} : résultat {r:#018x} au lieu de {reference:#018x}", t + 1));
                            }
                            it.fetch_add(1, Ordering::Relaxed);
                        }
                    })
                })
                .collect()
        }
        "mem" => {
            let (_, avail) = crate::win::memory();
            // une part de la mémoire libre, partagée entre les fils (au moins 64 Mo chacun)
            let pct = mem_pct.clamp(10, 90);
            let total = avail / 100 * pct;
            let per = (total / threads as u64 / 8).max(8 << 20) as usize;
            bytes = per as u64 * 8 * threads as u64;
            (0..threads)
                .map(|t| {
                    let (stop, it, er, fe) = (stop.clone(), iterations.clone(), errors.clone(), first_error.clone());
                    std::thread::spawn(move || {
                        let Ok(mut buf) = try_alloc(per) else {
                            fe.lock().unwrap().get_or_insert_with(|| "mémoire insuffisante pour ce test".into());
                            er.fetch_add(1, Ordering::Relaxed);
                            return;
                        };
                        let mut pass = 0u64;
                        while !stop.load(Ordering::Relaxed) {
                            let seed = (t as u64 + 1).wrapping_mul(0x9E37_79B9_7F4A_7C15) ^ pass;
                            mem_pass(&mut buf, seed, pass, &stop, &er, &fe, t);
                            pass += 1;
                            it.fetch_add(1, Ordering::Relaxed);
                        }
                    })
                })
                .collect()
        }
        _ => return Err("test inconnu".into()),
    };
    // surveille la durée et note la fin
    {
        let (stop, ended) = (stop.clone(), ended.clone());
        let started = Instant::now();
        std::thread::spawn(move || {
            while !stop.load(Ordering::Relaxed) && limit.is_none_or(|l| started.elapsed() < l) {
                std::thread::sleep(Duration::from_millis(200));
            }
            stop.store(true, Ordering::Relaxed);
            for h in handles {
                let _ = h.join();
            }
            *ended.lock().unwrap() = Some(Instant::now());
        });
    }
    *g = Some(Run { kind: kind.into(), started: Instant::now(), limit, threads, stop, iterations, errors, bytes, first_error, ended });
    drop(g);
    Ok(status())
}

fn try_alloc(n: usize) -> Result<Vec<u64>, ()> {
    let mut v: Vec<u64> = Vec::new();
    v.try_reserve_exact(n).map_err(|_| ())?;
    v.resize(n, 0);
    Ok(v)
}

/// Calcul flottant intensif et déterministe (FMA si disponible).
fn cpu_kernel(seed: u64) -> u64 {
    #[cfg(target_arch = "x86_64")]
    {
        if std::is_x86_feature_detected!("avx2") && std::is_x86_feature_detected!("fma") {
            return unsafe { kernel_avx2(seed) };
        }
    }
    kernel_generic(seed)
}

#[inline(always)]
fn kernel_body(seed: u64) -> u64 {
    let mut a = [0f64; 64];
    for (i, x) in a.iter_mut().enumerate() {
        *x = 1.0 + ((seed as usize + i) % 17) as f64 * 1e-3;
    }
    let (m, c) = (0.999_999_7f64, 1.3e-7f64);
    for _ in 0..20_000 {
        for x in a.iter_mut() {
            *x = x.mul_add(m, c);
        }
    }
    a.iter().fold(0u64, |h, x| h.rotate_left(5) ^ x.to_bits())
}

fn kernel_generic(seed: u64) -> u64 {
    kernel_body(seed)
}

#[cfg(target_arch = "x86_64")]
#[target_feature(enable = "avx2,fma")]
unsafe fn kernel_avx2(seed: u64) -> u64 {
    kernel_body(seed)
}

#[allow(clippy::too_many_arguments)]
fn mem_pass(buf: &mut [u64], seed: u64, pass: u64, stop: &AtomicBool, er: &AtomicU64, fe: &Mutex<Option<String>>, t: usize) {
    // motif selon la passe : pseudo-aléatoire, damier, inverse
    let gen = |i: usize| -> u64 {
        match pass % 3 {
            0 => {
                let mut x = seed ^ (i as u64).wrapping_mul(0xD6E8_FEB8_6659_FD93);
                x ^= x >> 33;
                x = x.wrapping_mul(0xFF51_AFD7_ED55_8CCD);
                x ^ (x >> 29)
            }
            1 => {
                if i % 2 == 0 {
                    0x5555_5555_5555_5555
                } else {
                    0xAAAA_AAAA_AAAA_AAAA
                }
            }
            _ => !(i as u64 ^ seed),
        }
    };
    for (i, x) in buf.iter_mut().enumerate() {
        *x = gen(i);
        if i % (1 << 20) == 0 && stop.load(Ordering::Relaxed) {
            return;
        }
    }
    for (i, x) in buf.iter().enumerate() {
        let v = unsafe { std::ptr::read_volatile(x) };
        let want = gen(i);
        if v != want {
            er.fetch_add(1, Ordering::Relaxed);
            fe.lock().unwrap().get_or_insert_with(|| format!("fil {} : {v:#018x} relu au lieu de {want:#018x}", t + 1));
        }
        if i % (1 << 20) == 0 && stop.load(Ordering::Relaxed) {
            return;
        }
    }
}

// ── vitesse des disques ──────────────────────────────────────────────────

struct Aligned {
    ptr: *mut u8,
    layout: std::alloc::Layout,
}

impl Aligned {
    fn new(size: usize) -> Aligned {
        let layout = std::alloc::Layout::from_size_align(size, 4096).unwrap();
        let ptr = unsafe { std::alloc::alloc(layout) };
        assert!(!ptr.is_null());
        // contenu peu compressible (les SSD compressent parfois les données)
        let s = unsafe { std::slice::from_raw_parts_mut(ptr, size) };
        let mut x = 0x2545_F491_4F6C_DD1Du64;
        for c in s.chunks_mut(8) {
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            c.copy_from_slice(&x.to_le_bytes()[..c.len()]);
        }
        Aligned { ptr, layout }
    }
}

impl Drop for Aligned {
    fn drop(&mut self) {
        unsafe { std::alloc::dealloc(self.ptr, self.layout) };
    }
}

/// Lecture et écriture séquentielles (blocs de 1 Mo) puis aléatoires (4 Ko,
/// une requête à la fois), sans cache de Windows. Fichier de test supprimé à la fin.
pub fn disk_bench(drive: &str, size_mb: u64, cancel: &AtomicBool, progress: &dyn Fn(&str)) -> Result<Value, String> {
    use std::os::windows::io::AsRawHandle;
    use std::io::{Read, Write};
    let letter = drive.chars().next().filter(|c| c.is_ascii_alphabetic()).ok_or("lecteur invalide")?.to_ascii_uppercase();
    let sys = std::env::var("SystemDrive").unwrap_or_else(|_| "C:".into());
    let dir = if sys.starts_with(letter) { std::env::temp_dir() } else { std::path::PathBuf::from(format!("{letter}:\\")) };
    let size = size_mb.clamp(64, 8192) << 20;
    const NO_BUFFERING: u32 = 0x2000_0000;
    const WRITE_THROUGH: u32 = 0x8000_0000;
    static NEXT: AtomicU64 = AtomicU64::new(0);
    let (path, mut f) = (0..128)
        .find_map(|_| {
            let nonce = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default()
                .as_nanos();
            let sequence = NEXT.fetch_add(1, Ordering::Relaxed);
            let path = dir.join(format!("BoiteAOutils-test-disque-{}-{nonce}-{sequence}.tmp", std::process::id()));
            match crate::benchmark_file::create_new(&path) {
                Ok(file) => Some(Ok((path, file))),
                Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => None,
                Err(e) => Some(Err(e)),
            }
        })
        .unwrap_or_else(|| Err(std::io::Error::new(std::io::ErrorKind::AlreadyExists, "nom temporaire indisponible")))
        .map_err(|e| format!("création du fichier de test impossible : {e}"))?;
    let h = f.as_raw_handle() as _;
    let block = Aligned::new(1 << 20);
    let small = Aligned::new(4096);
    let result = (|| -> Result<Value, String> {
        // écriture séquentielle
        progress("Écriture séquentielle…");
        let t = Instant::now();
        let mut done = 0u64;
        while done < size {
            if cancel.load(Ordering::Relaxed) {
                return Err("annulé".into());
            }
            f.write_all(unsafe { std::slice::from_raw_parts(block.ptr, 1 << 20) }).map_err(|e| e.to_string())?;
            done += 1 << 20;
        }
        let seq_write = size as f64 / t.elapsed().as_secs_f64() / 1e6;
        // lecture séquentielle
        progress("Lecture séquentielle…");
        unsafe {
            use windows_sys::Win32::Storage::FileSystem::{SetFilePointerEx, FILE_BEGIN};
            if SetFilePointerEx(h, 0, std::ptr::null_mut(), FILE_BEGIN) == 0 {
                return Err("positionnement du fichier de test impossible".into());
            }
        }
        let t = Instant::now();
        let mut done = 0u64;
        while done < size {
            if cancel.load(Ordering::Relaxed) {
                return Err("annulé".into());
            }
            f.read_exact(unsafe { std::slice::from_raw_parts_mut(block.ptr, 1 << 20) }).map_err(|e| e.to_string())?;
            done += 1 << 20;
        }
        let seq_read = size as f64 / t.elapsed().as_secs_f64() / 1e6;
        // accès aléatoires de 4 Ko pendant 5 s chacun
        let blocks = size / 4096;
        let random = |write: bool| -> Result<f64, String> {
            use windows_sys::Win32::Storage::FileSystem::{ReadFile, SetFilePointerEx, WriteFile, FILE_BEGIN};
            let mut x = 0x9E37_79B9u64;
            let mut n = 0u64;
            let t = Instant::now();
            while t.elapsed() < Duration::from_secs(5) {
                if cancel.load(Ordering::Relaxed) {
                    return Err("annulé".into());
                }
                x ^= x << 13;
                x ^= x >> 7;
                x ^= x << 17;
                let off = (x % blocks) * 4096;
                let mut io = 0u32;
                unsafe {
                    if SetFilePointerEx(h, off as i64, std::ptr::null_mut(), FILE_BEGIN) == 0 {
                        return Err("positionnement du fichier de test impossible".into());
                    }
                    let ok = if write { WriteFile(h, small.ptr, 4096, &mut io, std::ptr::null_mut()) } else { ReadFile(h, small.ptr, 4096, &mut io, std::ptr::null_mut()) };
                    if ok == 0 {
                        return Err("erreur d'accès au disque".into());
                    }
                }
                n += 1;
            }
            Ok(n as f64 / t.elapsed().as_secs_f64())
        };
        progress("Lecture aléatoire 4 Ko…");
        let rnd_read = random(false)?;
        progress("Écriture aléatoire 4 Ko…");
        let rnd_write = random(true)?;
        Ok(json!({
            "seqRead": seq_read, "seqWrite": seq_write,
            "rndReadIops": rnd_read, "rndWriteIops": rnd_write,
            "rndRead": rnd_read * 4096.0 / 1e6, "rndWrite": rnd_write * 4096.0 / 1e6,
            "sizeMb": size >> 20,
        }))
    })();
    drop(f);
    let _ = std::fs::remove_file(&path);
    result
}


unsafe impl Send for Aligned {}
