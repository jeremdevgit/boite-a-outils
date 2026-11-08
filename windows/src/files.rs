// SPDX-License-Identifier: GPL-3.0-or-later — Copyright (C) 2026 jeremdevgit — voir LICENSE
//! Analyse des fichiers : fichiers et dossiers lourds (plusieurs fils),
//! doublons (taille puis empreinte xxh3), dossiers vides.

use serde_json::{json, Value};
use std::collections::{BinaryHeap, HashMap};
use std::os::windows::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Condvar, Mutex};
use std::time::{Instant, SystemTime};

// fichiers « dans le nuage » (OneDrive…) : leur taille n'occupe pas le disque
const FILE_ATTRIBUTE_OFFLINE: u32 = 0x1000;
const FILE_ATTRIBUTE_RECALL_ON_OPEN: u32 = 0x40000;
const FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS: u32 = 0x400000;
const CLOUD: u32 =
    FILE_ATTRIBUTE_OFFLINE | FILE_ATTRIBUTE_RECALL_ON_OPEN | FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS;

pub fn age_days(t: SystemTime) -> u64 {
    SystemTime::now()
        .duration_since(t)
        .map(|d| d.as_secs() / 86400)
        .unwrap_or(0)
}

fn mtime_secs(m: &std::fs::Metadata) -> u64 {
    m.modified()
        .ok()
        .and_then(|t| t.duration_since(SystemTime::UNIX_EPOCH).ok())
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

const FILE_ATTRIBUTE_SPARSE_FILE: u32 = 0x200;
const FILE_ATTRIBUTE_COMPRESSED: u32 = 0x800;

/// Place réellement occupée sur le disque : 0 pour un fichier resté dans le
/// nuage ; pour un fichier clairsemé (disques virtuels, émulateurs) ou
/// compressé, l'espace alloué et non sa taille apparente.
pub fn disk_size(path: &Path, m: &std::fs::Metadata) -> u64 {
    let attr = m.file_attributes();
    if attr & CLOUD != 0 {
        return 0;
    }
    if attr & (FILE_ATTRIBUTE_SPARSE_FILE | FILE_ATTRIBUTE_COMPRESSED) != 0 {
        use windows_sys::Win32::Storage::FileSystem::GetCompressedFileSizeW;
        let wp = crate::win::w(&path.to_string_lossy());
        let mut high = 0u32;
        let low = unsafe { GetCompressedFileSizeW(wp.as_ptr(), &mut high) };
        if low != u32::MAX || unsafe { windows_sys::Win32::Foundation::GetLastError() } == 0 {
            return (high as u64) << 32 | low as u64;
        }
    }
    m.len()
}

#[derive(Eq, PartialEq, Ord, PartialOrd)]
struct Big(std::cmp::Reverse<u64>, PathBuf, u64);

/// Parcours parallèle de `root` : `on_dir(dossier, profondeur, fichiers)` est
/// appelé une fois par dossier lu. Les jonctions et liens ne sont pas suivis.
fn walk_parallel<F>(root: &Path, cancel: &AtomicBool, counter: &AtomicU64, on_dir: F)
where
    F: Fn(&Path, usize, &[(PathBuf, std::fs::Metadata)]) + Sync,
{
    let state = Mutex::new((vec![(root.to_path_buf(), 0usize)], 0usize));
    let cv = Condvar::new();
    let threads = std::thread::available_parallelism()
        .map(|n| n.get())
        .unwrap_or(4)
        .clamp(2, 12);
    std::thread::scope(|s| {
        for _ in 0..threads {
            s.spawn(|| loop {
                let job = {
                    let mut g = state.lock().unwrap();
                    loop {
                        if cancel.load(Ordering::Relaxed) {
                            cv.notify_all();
                            return;
                        }
                        if let Some(j) = g.0.pop() {
                            g.1 += 1;
                            break j;
                        }
                        if g.1 == 0 {
                            cv.notify_all();
                            return;
                        }
                        g = cv.wait(g).unwrap();
                    }
                };
                let (dir, depth) = job;
                let mut files = Vec::new();
                let mut subdirs = Vec::new();
                if let Ok(rd) = std::fs::read_dir(&dir) {
                    for e in rd.flatten() {
                        let Ok(ft) = e.file_type() else { continue };
                        if ft.is_symlink() {
                            continue;
                        }
                        if ft.is_dir() {
                            subdirs.push((e.path(), depth + 1));
                        } else if let Ok(m) = e.metadata() {
                            files.push((e.path(), m));
                        }
                    }
                }
                counter.fetch_add(files.len() as u64, Ordering::Relaxed);
                on_dir(&dir, depth, &files);
                let mut g = state.lock().unwrap();
                g.0.extend(subdirs);
                g.1 -= 1;
                cv.notify_all();
            });
        }
    });
}

/// Fichiers les plus lourds et taille des dossiers (3 niveaux) sous `root`.
pub fn scan_large(
    root: &Path,
    min_size: u64,
    top: usize,
    cancel: &AtomicBool,
    progress: impl Fn(Value) + Sync,
) -> Value {
    let started = Instant::now();
    let counter = AtomicU64::new(0);
    let total = AtomicU64::new(0);
    let heap = Mutex::new(BinaryHeap::<Big>::new());
    let dirs: Mutex<HashMap<PathBuf, u64>> = Mutex::new(HashMap::new());
    let last = Mutex::new(Instant::now());
    let root_depth = root.components().count();
    walk_parallel(root, cancel, &counter, |dir, _depth, files| {
        let mut sum = 0u64;
        let mut local = Vec::new();
        for (p, m) in files {
            let sz = disk_size(p, m);
            sum += sz;
            if sz >= min_size {
                local.push(Big(std::cmp::Reverse(sz), p.clone(), mtime_secs(m)));
            }
        }
        total.fetch_add(sum, Ordering::Relaxed);
        if !local.is_empty() {
            let mut h = heap.lock().unwrap();
            for b in local {
                h.push(b);
                if h.len() > top {
                    h.pop();
                }
            }
        }
        if sum > 0 {
            // la taille du dossier compte pour lui et ses parents jusqu'à 3 niveaux sous la racine
            let comps: Vec<_> = dir.components().collect();
            let mut d = dirs.lock().unwrap();
            for k in 1..=3usize {
                if comps.len() >= root_depth + k {
                    let p: PathBuf = comps[..root_depth + k].iter().collect();
                    *d.entry(p).or_default() += sum;
                }
            }
        }
        let mut l = last.lock().unwrap();
        if l.elapsed().as_millis() > 250 {
            *l = Instant::now();
            progress(
                json!({ "files": counter.load(Ordering::Relaxed), "bytes": total.load(Ordering::Relaxed), "dir": dir.to_string_lossy() }),
            );
        }
    });
    let mut files: Vec<_> = heap.into_inner().unwrap().into_sorted_vec();
    files.truncate(top);
    let files: Vec<Value> = files.into_iter().map(|Big(std::cmp::Reverse(sz), p, t)| json!({ "path": p.to_string_lossy(), "size": sz, "mtime": t })).collect();
    let mut folders: Vec<(PathBuf, u64)> = dirs.into_inner().unwrap().into_iter().collect();
    folders.sort_by(|a, b| b.1.cmp(&a.1));
    let folders: Vec<Value> = folders
        .into_iter()
        .filter(|(_, s)| *s >= 50 << 20)
        .take(400)
        .map(|(p, s)| json!({ "path": p.to_string_lossy(), "size": s, "depth": p.components().count() - root_depth }))
        .collect();
    json!({ "files": files, "folders": folders, "count": counter.load(Ordering::Relaxed), "total": total.load(Ordering::Relaxed), "ms": started.elapsed().as_millis() as u64, "cancelled": cancel.load(Ordering::Relaxed) })
}

/// Empreinte xxh3 d'un fichier (début seulement si `head` est donné).
fn hash(path: &Path, head: Option<usize>) -> Option<u64> {
    use std::io::Read;
    let mut f = std::fs::File::open(path).ok()?;
    let mut h = xxhash_rust::xxh3::Xxh3::new();
    let mut buf = vec![0u8; 1 << 20];
    let mut left = head.unwrap_or(usize::MAX);
    while left > 0 {
        let take = buf.len().min(left);
        let n = f.read(&mut buf[..take]).ok()?;
        if n == 0 {
            break;
        }
        h.update(&buf[..n]);
        left -= n;
    }
    Some(h.digest())
}

/// Doublons parmi les fichiers d'au moins `min_size` octets sous `roots` :
/// même taille, puis même début (64 Ko), puis même contenu complet.
pub fn duplicates(
    roots: &[PathBuf],
    min_size: u64,
    cancel: &AtomicBool,
    progress: impl Fn(Value) + Sync,
) -> Value {
    let counter = AtomicU64::new(0);
    let by_size: Mutex<HashMap<u64, Vec<(PathBuf, u64)>>> = Mutex::new(HashMap::new());
    for r in roots {
        walk_parallel(r, cancel, &counter, |_, _, files| {
            let mut g = by_size.lock().unwrap();
            for (p, m) in files {
                let sz = m.len(); // doublons : taille du contenu
                if sz >= min_size {
                    g.entry(sz).or_default().push((p.clone(), mtime_secs(m)));
                }
            }
        });
    }
    let candidates: Vec<(u64, Vec<(PathBuf, u64)>)> = by_size
        .into_inner()
        .unwrap()
        .into_iter()
        .filter(|(_, v)| v.len() > 1)
        .collect();
    let total = candidates.len();
    let mut groups = Vec::new();
    for (i, (size, list)) in candidates.into_iter().enumerate() {
        if cancel.load(Ordering::Relaxed) {
            break;
        }
        if i % 20 == 0 {
            progress(json!({ "phase": "hash", "done": i, "total": total }));
        }
        let mut by_head: HashMap<u64, Vec<(PathBuf, u64)>> = HashMap::new();
        for (p, t) in list {
            if let Some(h) = hash(&p, Some(64 << 10)) {
                by_head.entry(h).or_default().push((p, t));
            }
        }
        for (_, l) in by_head.into_iter().filter(|(_, v)| v.len() > 1) {
            let mut by_full: HashMap<u64, Vec<(PathBuf, u64)>> = HashMap::new();
            for (p, t) in l {
                let h = if size <= 64 << 10 {
                    hash(&p, Some(64 << 10))
                } else {
                    hash(&p, None)
                };
                if let Some(h) = h {
                    by_full.entry(h).or_default().push((p, t));
                }
            }
            for (_, g) in by_full.into_iter().filter(|(_, v)| v.len() > 1) {
                groups.push(json!({ "size": size, "files": g.iter().map(|(p, t)| json!({ "path": p.to_string_lossy(), "mtime": t })).collect::<Vec<_>>() }));
            }
        }
    }
    groups.sort_by(|a, b| {
        let w = |v: &Value| {
            v["size"].as_u64().unwrap_or(0)
                * (v["files"].as_array().map(|a| a.len()).unwrap_or(1) as u64 - 1)
        };
        w(b).cmp(&w(a))
    });
    json!({ "groups": groups, "scanned": counter.load(Ordering::Relaxed), "cancelled": cancel.load(Ordering::Relaxed) })
}

/// Dossiers vides (aucun fichier, même dans leurs sous-dossiers) placés
/// directement dans l'un des dossiers `roots`.
pub fn empty_dirs(roots: &[PathBuf], cancel: &AtomicBool) -> Vec<Value> {
    fn visit(dir: &Path, out: &mut Vec<PathBuf>, cancel: &AtomicBool, depth: u32) -> bool {
        if cancel.load(Ordering::Relaxed) || depth > 14 {
            return false;
        }
        let Ok(rd) = std::fs::read_dir(dir) else {
            return false;
        };
        let mut empty = true;
        let mut empties = Vec::new();
        for e in rd.flatten() {
            let Ok(ft) = e.file_type() else {
                empty = false;
                continue;
            };
            if ft.is_dir() && !ft.is_symlink() {
                let mut sub = Vec::new();
                if visit(&e.path(), &mut sub, cancel, depth + 1) {
                    empties.push(e.path());
                } else {
                    empty = false;
                    out.extend(sub);
                }
            } else {
                empty = false;
            }
        }
        if !empty {
            out.extend(empties);
        }
        empty
    }
    let mut out = Vec::new();
    for r in roots {
        // la racine elle-même n'est jamais proposée
        let Ok(rd) = std::fs::read_dir(r) else {
            continue;
        };
        for e in rd.flatten() {
            // seulement les dossiers posés directement dans Bureau, Documents… : plus bas,
            // les dossiers vides appartiennent souvent à un jeu ou un logiciel qui les attend
            if e.file_type()
                .map(|t| t.is_dir() && !t.is_symlink())
                .unwrap_or(false)
            {
                let mut sub = Vec::new();
                if visit(&e.path(), &mut sub, cancel, 1) {
                    out.push(e.path());
                }
            }
        }
    }
    out.into_iter()
        .map(|p| json!({ "path": p.to_string_lossy() }))
        .collect()
}

/// No reparse component is an authorized cleanup root. The privilege boundary
/// below also covers replacements after this check: user-writable trees run
/// with a restricted user token, never with ambient administrator authority.
fn ordinary_path(path: &Path) -> bool {
    path.is_absolute()
        && path
            .ancestors()
            .all(|p| std::fs::symlink_metadata(p).is_ok_and(|m| m.file_attributes() & 0x400 == 0))
}
fn in_directory_context<T>(path: &Path, operation: impl FnOnce() -> T) -> Option<T> {
    if !ordinary_path(path) {
        return None;
    }
    if crate::win::is_elevated() && !crate::install_security::trusted(path) {
        crate::user_context::as_standard_user(operation).ok()
    } else {
        Some(operation())
    }
}

/// Taille et nombre de fichiers d'un dossier (récursif, sans suivre les liens).
pub fn dir_size(path: &Path, min_age_hours: u64) -> (u64, u64) {
    in_directory_context(path, || dir_size_in_context(path, min_age_hours)).unwrap_or((0, 0))
}
fn dir_size_in_context(path: &Path, min_age_hours: u64) -> (u64, u64) {
    let mut size = 0;
    let mut count = 0;
    let mut stack = vec![path.to_path_buf()];
    let now = SystemTime::now();
    while let Some(d) = stack.pop() {
        let Ok(rd) = std::fs::read_dir(&d) else {
            continue;
        };
        for e in rd.flatten() {
            let Ok(ft) = e.file_type() else { continue };
            if ft.is_symlink() {
                continue;
            }
            if ft.is_dir() {
                let child = e.path();
                if crate::win::is_elevated() && !crate::install_security::trusted(&child) {
                    let (s, n) = dir_size(&child, min_age_hours);
                    size += s;
                    count += n;
                } else if ordinary_path(&child) {
                    stack.push(child);
                }
            } else if let Ok(m) = e.metadata() {
                if min_age_hours > 0 {
                    let age = m
                        .modified()
                        .ok()
                        .and_then(|t| now.duration_since(t).ok())
                        .map(|d| d.as_secs() / 3600)
                        .unwrap_or(0);
                    if age < min_age_hours {
                        continue;
                    }
                }
                size += disk_size(&e.path(), &m);
                count += 1;
            }
        }
    }
    (size, count)
}

/// Supprime le contenu d'un dossier (fichiers assez anciens), en ignorant les
/// fichiers en cours d'utilisation ; le dossier lui-même est gardé.
pub fn clear_dir(path: &Path, min_age_hours: u64) -> (u64, u64, u64) {
    let (mut freed, mut removed, mut skipped) = (0u64, 0u64, 0u64);
    let now = SystemTime::now();
    fn inner(
        d: &Path,
        now: SystemTime,
        min_age: u64,
        freed: &mut u64,
        removed: &mut u64,
        skipped: &mut u64,
    ) {
        if !ordinary_path(d) {
            *skipped += 1;
            return;
        }
        if crate::win::is_elevated() && !crate::install_security::trusted(d) {
            if crate::user_context::as_standard_user(|| {
                contents(d, now, min_age, freed, removed, skipped)
            })
            .is_err()
            {
                *skipped += 1;
            }
        } else {
            contents(d, now, min_age, freed, removed, skipped);
        }
    }
    fn contents(
        d: &Path,
        now: SystemTime,
        min_age: u64,
        freed: &mut u64,
        removed: &mut u64,
        skipped: &mut u64,
    ) {
        let Ok(rd) = std::fs::read_dir(d) else {
            *skipped += 1;
            return;
        };
        for e in rd.flatten() {
            let Ok(ft) = e.file_type() else { continue };
            let p = e.path();
            if ft.is_symlink()
                || std::fs::symlink_metadata(&p).is_ok_and(|m| m.file_attributes() & 0x400 != 0)
            {
                *skipped += 1;
                continue;
            }
            if ft.is_dir() {
                inner(&p, now, min_age, freed, removed, skipped);
                let _ = std::fs::remove_dir(&p); // seulement s'il est vide
            } else if let Ok(m) = e.metadata() {
                let age = m
                    .modified()
                    .ok()
                    .and_then(|t| now.duration_since(t).ok())
                    .map(|d| d.as_secs() / 3600)
                    .unwrap_or(0);
                if age < min_age {
                    *skipped += 1;
                    continue;
                }
                let erase = || {
                    if !ordinary_path(&p) {
                        return None;
                    }
                    let metadata = std::fs::symlink_metadata(&p).ok()?;
                    if metadata.file_attributes() & 0x400 != 0 {
                        return None;
                    }
                    let size = disk_size(&p, &metadata);
                    if metadata.permissions().readonly() {
                        let mut permissions = metadata.permissions();
                        #[allow(clippy::permissions_set_readonly_false)]
                        permissions.set_readonly(false);
                        std::fs::set_permissions(&p, permissions).ok()?;
                    }
                    std::fs::remove_file(&p).ok()?;
                    Some(size)
                };
                let result = if crate::win::is_elevated() && !crate::install_security::trusted(&p) {
                    crate::user_context::as_standard_user(erase).ok().flatten()
                } else {
                    erase()
                };
                if let Some(size) = result {
                    *freed += size;
                    *removed += 1;
                } else {
                    *skipped += 1;
                }
            }
        }
    }
    inner(
        path,
        now,
        min_age_hours,
        &mut freed,
        &mut removed,
        &mut skipped,
    );
    (freed, removed, skipped)
}

/// Remove one expanded cleanup match without ever using the elevated token
/// for a user-writable or reparse-point path. Keep the metadata read and delete
/// in the same restricted-token operation so callers cannot accidentally
/// validate under one identity and delete under another.
pub fn remove_file(path: &Path) -> Option<u64> {
    let erase = || {
        if !ordinary_path(path) {
            return None;
        }
        let metadata = std::fs::symlink_metadata(path).ok()?;
        if metadata.file_attributes() & 0x400 != 0 || !metadata.is_file() {
            return None;
        }
        let size = disk_size(path, &metadata);
        if metadata.permissions().readonly() {
            let mut permissions = metadata.permissions();
            #[allow(clippy::permissions_set_readonly_false)]
            permissions.set_readonly(false);
            std::fs::set_permissions(path, permissions).ok()?;
        }
        std::fs::remove_file(path).ok()?;
        Some(size)
    };
    if crate::win::is_elevated() && !crate::install_security::trusted(path) {
        crate::user_context::as_standard_user(erase).ok().flatten()
    } else {
        erase()
    }
}
