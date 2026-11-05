// SPDX-License-Identifier: GPL-3.0-or-later — Copyright (C) 2026 jeremdevgit — voir LICENSE
//! Analyse de disque façon WizTree : la table MFT d'un volume NTFS est lue
//! directement (administrateur requis, quelques secondes pour tout un disque),
//! sinon les dossiers sont parcourus un par un. L'arborescence complète reste
//! en mémoire : navigation, carte, types et recherche sont ensuite instantanés.

use serde_json::{json, Value};
use std::collections::{BinaryHeap, HashMap};
use std::io::{Read, Seek, SeekFrom};
use std::os::windows::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Condvar, Mutex};
use std::time::{Instant, SystemTime};

const NONE: u32 = u32::MAX;
const USED: u8 = 1;
const DIR: u8 = 2;
const NAMED: u8 = 4; // nom Win32 ou POSIX trouvé (sinon nom court DOS)

#[derive(Clone, Copy)]
struct Node {
    parent: u32,
    first: u32,
    next: u32,
    name: u32,
    name_len: u16,
    flags: u8,
    ext: u16,
    size: u64,
    alloc: u64,
    mtime: u32,
    files: u32,
    dirs: u32,
}

impl Default for Node {
    fn default() -> Self {
        Node { parent: NONE, first: NONE, next: NONE, name: 0, name_len: 0, flags: 0, ext: 0, size: 0, alloc: 0, mtime: 0, files: 0, dirs: 0 }
    }
}

pub struct Tree {
    nodes: Vec<Node>,
    names: String,
    /// nœud du volume (MFT : enregistrement 5) ou dossier de départ
    top: u32,
    /// chemin du nœud `top`
    top_path: String,
    /// nœud demandé (dossier analysé)
    root: u32,
    exts: Vec<String>,
}

static TREE: Mutex<Option<Tree>> = Mutex::new(None);

fn filetime_unix(ft: u64) -> u32 {
    (ft / 10_000_000).saturating_sub(11_644_473_600).min(u32::MAX as u64) as u32
}

fn rd16(b: &[u8], o: usize) -> u16 {
    b.get(o..o + 2).map(|s| u16::from_le_bytes([s[0], s[1]])).unwrap_or(0)
}
fn rd32(b: &[u8], o: usize) -> u32 {
    b.get(o..o + 4).map(|s| u32::from_le_bytes(s.try_into().unwrap())).unwrap_or(0)
}
fn rd64(b: &[u8], o: usize) -> u64 {
    b.get(o..o + 8).map(|s| u64::from_le_bytes(s.try_into().unwrap())).unwrap_or(0)
}

// ── lecture de la MFT ────────────────────────────────────────────────────

/// Applique la correction « update sequence » d'un enregistrement FILE.
fn fixup(r: &mut [u8]) -> bool {
    let uo = rd16(r, 4) as usize;
    let uc = rd16(r, 6) as usize;
    if uc < 2 || uo + uc * 2 > r.len() {
        return false;
    }
    let stride = r.len() / (uc - 1);
    let (a, b) = (r[uo], r[uo + 1]);
    for i in 1..uc {
        let p = i * stride - 2;
        if p + 2 > r.len() || r[p] != a || r[p + 1] != b {
            return false;
        }
        r[p] = r[uo + 2 * i];
        r[p + 1] = r[uo + 2 * i + 1];
    }
    true
}

/// Liste des extents (LCN, nombre de clusters) d'un attribut non résident.
fn data_runs(b: &[u8]) -> Vec<(i64, u64)> {
    let mut out = Vec::new();
    let (mut i, mut lcn) = (0usize, 0i64);
    while i < b.len() && b[i] != 0 {
        let h = b[i];
        let (ln, lo) = ((h & 0xF) as usize, (h >> 4) as usize);
        i += 1;
        if ln == 0 || ln > 8 || lo > 8 || i + ln + lo > b.len() {
            break;
        }
        let mut len = 0u64;
        for k in 0..ln {
            len |= (b[i + k] as u64) << (8 * k);
        }
        i += ln;
        if lo == 0 {
            out.push((-1, len)); // trou (clairsemé)
        } else {
            let mut off = 0i64;
            for k in 0..lo {
                off |= (b[i + k] as i64) << (8 * k);
            }
            let shift = 64 - 8 * lo as u32;
            off = (off << shift) >> shift; // signe
            lcn += off;
            out.push((lcn, len));
        }
        i += lo;
    }
    out
}

struct Builder {
    nodes: Vec<Node>,
    names: String,
    cluster: u64,
}

impl Builder {
    fn set_name(&mut self, idx: usize, utf16: &[u16]) {
        let s = String::from_utf16_lossy(utf16);
        let n = &mut self.nodes[idx];
        n.name = self.names.len() as u32;
        n.name_len = s.len().min(u16::MAX as usize) as u16;
        self.names.push_str(&s[..n.name_len as usize]);
    }

    /// Lit un enregistrement FILE (déjà corrigé) numéro `idx`.
    fn record(&mut self, rec: &[u8], idx: usize) {
        if &rec[0..4] != b"FILE" {
            return;
        }
        let hflags = rd16(rec, 0x16);
        if hflags & 1 == 0 {
            return; // enregistrement libre
        }
        let base = (rd64(rec, 0x20) & 0xFFFF_FFFF_FFFF) as usize;
        let t = if base != 0 { base } else { idx };
        if t >= self.nodes.len() {
            self.nodes.resize(t + 1, Node::default());
        }
        if base == 0 {
            self.nodes[t].flags |= USED;
            if hflags & 2 != 0 {
                self.nodes[t].flags |= DIR;
            }
        }
        let used = (rd32(rec, 0x18) as usize).min(rec.len());
        let mut off = rd16(rec, 0x14) as usize;
        while off + 16 <= used {
            let typ = rd32(rec, off);
            let len = rd32(rec, off + 4) as usize;
            if typ == 0xFFFF_FFFF || len < 16 || off + len > used {
                break;
            }
            let a = &rec[off..off + len];
            let nonres = a[8] != 0;
            let named = a[9] != 0;
            match typ {
                0x10 if !nonres => {
                    let v = rd16(a, 0x14) as usize;
                    self.nodes[t].mtime = filetime_unix(rd64(a, v + 8));
                }
                0x30 if !nonres => {
                    let v = rd16(a, 0x14) as usize;
                    let ns = a.get(v + 0x41).copied().unwrap_or(2);
                    let nl = a.get(v + 0x40).copied().unwrap_or(0) as usize;
                    let has = self.nodes[t].flags & NAMED != 0;
                    let dos_only = ns == 2;
                    // le premier nom long gagne (un lien physique n'est compté qu'une fois)
                    if !has && (!dos_only || self.nodes[t].name_len == 0) && v + 0x42 + nl * 2 <= a.len() {
                        let parent = (rd64(a, v) & 0xFFFF_FFFF_FFFF) as u32;
                        let name: Vec<u16> = (0..nl).map(|k| rd16(a, v + 0x42 + k * 2)).collect();
                        self.set_name(t, &name);
                        self.nodes[t].parent = parent;
                        if !dos_only {
                            self.nodes[t].flags |= NAMED;
                        }
                    }
                }
                0x80 => {
                    if !nonres {
                        if !named {
                            self.nodes[t].size = rd32(a, 0x10) as u64; // contenu dans la MFT : rien d'alloué
                        }
                    } else {
                        if !named && rd64(a, 0x10) == 0 {
                            self.nodes[t].size = rd64(a, 0x30);
                        }
                        // espace réellement occupé : clusters des extents, trous exclus
                        // (fichiers clairsemés ou compressés, $BadClus:$Bad qui déclare tout le disque) ;
                        // chaque fragment ne décrit que ses propres extents, flux nommés compris
                        let ro = rd16(a, 0x20) as usize;
                        if ro < a.len() {
                            let clusters: u64 = data_runs(&a[ro..]).iter().filter(|r| r.0 >= 0).map(|r| r.1).sum();
                            self.nodes[t].alloc += clusters * self.cluster;
                        }
                    }
                }
                _ => {}
            }
            off += len;
        }
    }
}

/// Lit toute la MFT du volume `letter`. Ok(None) si le volume n'est pas NTFS
/// ou ne peut pas être ouvert (droits).
fn read_mft(letter: char, cancel: &AtomicBool, progress: &(dyn Fn(Value) + Sync)) -> Result<Option<Builder>, String> {
    let path = format!("\\\\.\\{letter}:");
    let Ok(mut f) = std::fs::OpenOptions::new().read(true).share_mode(3).open(&path) else { return Ok(None) };
    let mut boot = [0u8; 512];
    if f.read_exact(&mut boot).is_err() || &boot[3..11] != b"NTFS    " {
        return Ok(None);
    }
    let bps = rd16(&boot, 0x0B) as u64;
    let cluster = bps * boot[0x0D] as u64;
    let mft_lcn = rd64(&boot, 0x30);
    let cpr = boot[0x40] as i8;
    let rec_size = if cpr > 0 { cpr as u64 * cluster } else { 1u64 << (-cpr as u32) };
    if cluster == 0 || !(256..=65536).contains(&rec_size) {
        return Ok(None);
    }
    // enregistrement 0 : $MFT elle-même, pour connaître ses extents
    let mut rec0 = vec![0u8; rec_size as usize];
    f.seek(SeekFrom::Start(mft_lcn * cluster)).map_err(|e| e.to_string())?;
    f.read_exact(&mut rec0).map_err(|e| e.to_string())?;
    if &rec0[0..4] != b"FILE" || !fixup(&mut rec0) {
        return Err("MFT illisible".into());
    }
    let (mut runs, mut mft_size) = (Vec::new(), 0u64);
    let mut off = rd16(&rec0, 0x14) as usize;
    while off + 16 < rec0.len() {
        let typ = rd32(&rec0, off);
        let len = rd32(&rec0, off + 4) as usize;
        if typ == 0xFFFF_FFFF || len < 16 || off + len > rec0.len() {
            break;
        }
        if typ == 0x80 && rec0[off + 8] != 0 && rec0[off + 9] == 0 {
            let a = &rec0[off..off + len];
            mft_size = rd64(a, 0x30);
            runs = data_runs(&a[rd16(a, 0x20) as usize..]);
            break;
        }
        off += len;
    }
    if runs.is_empty() {
        return Err("MFT illisible".into());
    }
    let total = (mft_size / rec_size) as usize;
    let mut b = Builder { nodes: vec![Node::default(); total], names: String::with_capacity(total * 16), cluster };
    // un fil lit le disque, celui-ci décode
    let (tx, rx) = std::sync::mpsc::sync_channel::<Vec<u8>>(4);
    let chunk = (4u64 << 20).max(rec_size);
    std::thread::scope(|s| -> Result<(), String> {
        let reader = s.spawn(move || -> Result<(), String> {
            let mut left = mft_size;
            for (lcn, clusters) in runs {
                let mut pos = lcn.max(0) as u64 * cluster;
                let mut bytes = (clusters * cluster).min(left);
                while bytes > 0 {
                    if cancel.load(Ordering::Relaxed) {
                        return Ok(());
                    }
                    let n = bytes.min(chunk);
                    let mut buf = vec![0u8; n as usize];
                    if lcn >= 0 {
                        f.seek(SeekFrom::Start(pos)).map_err(|e| e.to_string())?;
                        f.read_exact(&mut buf).map_err(|e| e.to_string())?;
                    }
                    if tx.send(buf).is_err() {
                        return Ok(());
                    }
                    pos += n;
                    bytes -= n;
                    left -= n;
                }
            }
            Ok(())
        });
        let (mut idx, mut last) = (0usize, Instant::now());
        let rs = rec_size as usize;
        for mut buf in rx {
            for rec in buf.chunks_exact_mut(rs) {
                if idx < total && &rec[0..4] == b"FILE" && fixup(rec) {
                    b.record(rec, idx);
                }
                idx += 1;
            }
            if last.elapsed().as_millis() > 200 {
                last = Instant::now();
                progress(json!({ "phase": "mft", "done": idx, "total": total }));
            }
        }
        reader.join().unwrap_or_else(|_| Err("lecture interrompue".into()))
    })?;
    Ok(Some(b))
}

// ── parcours classique (non NTFS, ou sans droits administrateur) ────────

const CLOUD: u32 = 0x1000 | 0x40000 | 0x400000;

fn walk(root: &Path, cancel: &AtomicBool, progress: &(dyn Fn(Value) + Sync)) -> Builder {
    let b = Mutex::new(Builder { nodes: Vec::with_capacity(1 << 16), names: String::new(), cluster: 0 });
    {
        let mut g = b.lock().unwrap();
        g.nodes.push(Node { flags: USED | DIR | NAMED, ..Default::default() });
        let name: Vec<u16> = root.to_string_lossy().encode_utf16().collect();
        g.set_name(0, &name);
    }
    let state = Mutex::new((vec![(root.to_path_buf(), 0u32)], 0usize));
    let cv = Condvar::new();
    let (count, bytes) = (AtomicU64::new(0), AtomicU64::new(0));
    let last = Mutex::new(Instant::now());
    let threads = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(4).clamp(2, 12);
    std::thread::scope(|s| {
        for _ in 0..threads {
            s.spawn(|| loop {
                let (dir, idx) = {
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
                let mut entries = Vec::new();
                if let Ok(rd) = std::fs::read_dir(&dir) {
                    for e in rd.flatten() {
                        let Ok(ft) = e.file_type() else { continue };
                        if ft.is_symlink() {
                            continue;
                        }
                        let Ok(m) = e.metadata() else { continue };
                        let mtime = m.modified().ok().and_then(|t| t.duration_since(SystemTime::UNIX_EPOCH).ok()).map(|d| d.as_secs() as u32).unwrap_or(0);
                        let (size, alloc) = if ft.is_dir() {
                            (0, 0)
                        } else if m.file_attributes() & CLOUD != 0 {
                            (m.len(), 0)
                        } else {
                            (m.len(), crate::files::disk_size(&e.path(), &m))
                        };
                        entries.push((e.file_name(), ft.is_dir(), size, alloc, mtime));
                    }
                }
                let mut subdirs = Vec::new();
                {
                    let mut g = b.lock().unwrap();
                    let mut sum = 0;
                    for (name, is_dir, size, alloc, mtime) in entries {
                        let i = g.nodes.len();
                        let first = g.nodes[idx as usize].first;
                        g.nodes.push(Node { parent: idx, next: first, flags: USED | NAMED | if is_dir { DIR } else { 0 }, size, alloc, mtime, ..Default::default() });
                        g.nodes[idx as usize].first = i as u32;
                        let w: Vec<u16> = name.to_string_lossy().encode_utf16().collect();
                        g.set_name(i, &w);
                        sum += alloc;
                        if is_dir {
                            subdirs.push((dir.join(&name), i as u32));
                        } else {
                            count.fetch_add(1, Ordering::Relaxed);
                        }
                    }
                    bytes.fetch_add(sum, Ordering::Relaxed);
                }
                {
                    let mut l = last.lock().unwrap();
                    if l.elapsed().as_millis() > 250 {
                        *l = Instant::now();
                        progress(json!({ "phase": "walk", "files": count.load(Ordering::Relaxed), "bytes": bytes.load(Ordering::Relaxed), "dir": dir.to_string_lossy() }));
                    }
                }
                let mut g = state.lock().unwrap();
                g.0.extend(subdirs);
                g.1 -= 1;
                cv.notify_all();
            });
        }
    });
    b.into_inner().unwrap()
}

// ── construction de l'arbre ──────────────────────────────────────────────

fn ext_of(name: &str) -> Option<String> {
    let (stem, ext) = name.rsplit_once('.')?;
    (!stem.is_empty() && !ext.is_empty() && ext.len() <= 12 && !ext.contains(' ')).then(|| ext.to_lowercase())
}

/// Relie les enfants (MFT), cumule les tailles des dossiers, classe les extensions.
fn finish(mut b: Builder, top: u32, top_path: String, linked: bool) -> Tree {
    let n = b.nodes.len();
    if !linked {
        for i in 0..n {
            let nd = b.nodes[i];
            if nd.flags & USED == 0 || i as u32 == top {
                continue;
            }
            let p = nd.parent as usize;
            if p < n && p != i && b.nodes[p].flags & (USED | DIR) == USED | DIR {
                b.nodes[i].next = b.nodes[p].first;
                b.nodes[p].first = i as u32;
            }
        }
    }
    // ordre de parcours depuis le sommet, puis cumul des feuilles vers la racine
    let mut order = Vec::with_capacity(n);
    let mut seen = vec![false; n];
    let mut stack = vec![top];
    while let Some(v) = stack.pop() {
        if std::mem::replace(&mut seen[v as usize], true) {
            continue;
        }
        order.push(v);
        let mut c = b.nodes[v as usize].first;
        while c != NONE {
            stack.push(c);
            c = b.nodes[c as usize].next;
        }
    }
    let mut exts: Vec<String> = vec![String::new()];
    let mut ext_ids: HashMap<String, u16> = HashMap::new();
    for &v in order.iter().rev() {
        let nd = b.nodes[v as usize];
        if nd.flags & DIR == 0 {
            let name = &b.names[nd.name as usize..(nd.name + nd.name_len as u32) as usize];
            if let Some(e) = ext_of(name) {
                let id = match ext_ids.get(&e) {
                    Some(&id) => id,
                    None if exts.len() < u16::MAX as usize => {
                        exts.push(e.clone());
                        ext_ids.insert(e, (exts.len() - 1) as u16);
                        (exts.len() - 1) as u16
                    }
                    None => 0,
                };
                b.nodes[v as usize].ext = id;
            }
        }
        if v != top {
            let p = nd.parent as usize;
            let is_dir = nd.flags & DIR != 0;
            let pn = &mut b.nodes[p];
            pn.size += nd.size;
            pn.alloc += nd.alloc;
            pn.files += nd.files + !is_dir as u32;
            pn.dirs += nd.dirs + is_dir as u32;
        }
    }
    b.names.shrink_to_fit();
    Tree { nodes: b.nodes, names: b.names, top, top_path, root: top, exts }
}

impl Tree {
    fn name(&self, i: u32) -> &str {
        let n = &self.nodes[i as usize];
        &self.names[n.name as usize..(n.name + n.name_len as u32) as usize]
    }

    fn children(&self, i: u32) -> Vec<u32> {
        let mut out = Vec::new();
        let mut c = self.nodes[i as usize].first;
        while c != NONE {
            out.push(c);
            c = self.nodes[c as usize].next;
        }
        out
    }

    fn chain(&self, mut i: u32) -> Vec<u32> {
        let mut out = vec![i];
        while i != self.top && out.len() < 4096 {
            i = self.nodes[i as usize].parent;
            if i == NONE || i as usize >= self.nodes.len() {
                break;
            }
            out.push(i);
        }
        out.reverse();
        out
    }

    pub fn path(&self, i: u32) -> String {
        let mut s = self.top_path.clone();
        for &c in self.chain(i).iter().skip(1) {
            if !s.ends_with('\\') {
                s.push('\\');
            }
            s.push_str(self.name(c));
        }
        s
    }

    fn valid(&self, i: u32) -> bool {
        (i as usize) < self.nodes.len() && self.nodes[i as usize].flags & USED != 0
    }

    fn is_dir(&self, i: u32) -> bool {
        self.nodes[i as usize].flags & DIR != 0
    }

    fn ext(&self, i: u32) -> &str {
        &self.exts[self.nodes[i as usize].ext as usize]
    }

    fn item(&self, i: u32, with_path: bool) -> Value {
        let n = &self.nodes[i as usize];
        let mut v = json!({ "id": i, "name": self.name(i), "dir": n.flags & DIR != 0, "size": n.size, "alloc": n.alloc, "mtime": n.mtime, "files": n.files, "dirs": n.dirs, "kids": n.first != NONE });
        if with_path {
            v["path"] = json!(self.path(i));
        }
        v
    }

    /// Tous les nœuds du sous-arbre de `i` (sans `i`).
    fn each_below(&self, i: u32, mut f: impl FnMut(u32)) {
        let mut stack = vec![self.nodes[i as usize].first];
        while let Some(mut c) = stack.pop() {
            while c != NONE {
                f(c);
                let first = self.nodes[c as usize].first;
                if first != NONE {
                    stack.push(first);
                }
                c = self.nodes[c as usize].next;
            }
        }
    }

    fn find(&self, from: u32, rel: &Path) -> Option<u32> {
        let mut cur = from;
        for comp in rel.components() {
            let want = comp.as_os_str().to_string_lossy().to_lowercase();
            cur = self.children(cur).into_iter().find(|&c| self.name(c).to_lowercase() == want)?;
        }
        Some(cur)
    }

    /// Retire un nœud supprimé et soustrait sa taille à ses parents.
    fn remove(&mut self, i: u32) {
        let n = self.nodes[i as usize];
        let is_dir = n.flags & DIR != 0;
        let p = n.parent;
        if p == NONE || i == self.top {
            return;
        }
        // détacher de la liste des enfants
        if self.nodes[p as usize].first == i {
            self.nodes[p as usize].first = n.next;
        } else {
            let mut c = self.nodes[p as usize].first;
            while c != NONE {
                if self.nodes[c as usize].next == i {
                    self.nodes[c as usize].next = n.next;
                    break;
                }
                c = self.nodes[c as usize].next;
            }
        }
        self.nodes[i as usize].flags &= !USED;
        let mut a = p;
        loop {
            let pn = &mut self.nodes[a as usize];
            pn.size = pn.size.saturating_sub(n.size);
            pn.alloc = pn.alloc.saturating_sub(n.alloc);
            pn.files = pn.files.saturating_sub(n.files + !is_dir as u32);
            pn.dirs = pn.dirs.saturating_sub(n.dirs + is_dir as u32);
            if a == self.top {
                break;
            }
            a = pn.parent;
            if a == NONE {
                break;
            }
        }
    }
}

// ── commandes ────────────────────────────────────────────────────────────

/// Analyse `root` (lecteur ou dossier) et garde l'arbre en mémoire.
pub fn scan(root: &Path, cancel: &AtomicBool, progress: &(dyn Fn(Value) + Sync)) -> Result<Value, String> {
    let started = Instant::now();
    let rs = root.to_string_lossy().to_string();
    let letter = rs.chars().next().filter(|c| c.is_ascii_alphabetic() && rs.get(1..2) == Some(":")).map(|c| c.to_ascii_uppercase());
    *TREE.lock().unwrap() = None; // libère l'ancienne analyse avant d'en construire une autre
    let mut method = "walk";
    let mut tree = None;
    if let Some(l) = letter {
        if crate::win::is_elevated() {
            if let Some(b) = read_mft(l, cancel, progress)? {
                if cancel.load(Ordering::Relaxed) {
                    return Err("analyse arrêtée".into());
                }
                progress(json!({ "phase": "build" }));
                let mut t = finish(b, 5, format!("{l}:\\"), false);
                let rel: PathBuf = Path::new(&rs).components().skip(2).collect(); // sans « C: » ni « \ »
                // un dossier absent de la MFT (lien, autre volume monté) : parcours classique
                if let Some(r) = t.find(5, &rel) {
                    t.root = r;
                    method = "mft";
                    tree = Some(t);
                }
            }
        }
    }
    let tree = match tree {
        Some(t) => t,
        None => {
            let b = walk(root, cancel, progress);
            progress(json!({ "phase": "build" }));
            finish(b, 0, rs.clone(), true)
        }
    };
    let r = &tree.nodes[tree.root as usize];
    let out = json!({
        "root": tree.root, "path": tree.path(tree.root), "method": method,
        "size": r.size, "alloc": r.alloc, "files": r.files, "dirs": r.dirs,
        "ms": started.elapsed().as_millis() as u64, "cancelled": cancel.load(Ordering::Relaxed),
    });
    *TREE.lock().unwrap() = Some(tree);
    Ok(out)
}

fn with<T>(f: impl FnOnce(&Tree) -> Result<T, String>) -> Result<T, String> {
    let g = TREE.lock().unwrap();
    let t = g.as_ref().ok_or("aucune analyse en mémoire : relancez l'analyse")?;
    f(t)
}

fn node_arg(t: &Tree, a: &Value) -> Result<u32, String> {
    let i = a["id"].as_u64().map(|x| x as u32).unwrap_or(t.root);
    if t.valid(i) {
        Ok(i)
    } else {
        Err("élément introuvable (supprimé ?)".into())
    }
}

/// Contenu d'un dossier, trié par place occupée, avec le fil d'Ariane depuis la racine.
pub fn children(a: &Value) -> Result<Value, String> {
    with(|t| {
        let i = node_arg(t, a)?;
        let limit = a["limit"].as_u64().unwrap_or(1500) as usize;
        let mut kids = t.children(i);
        kids.sort_by(|&x, &y| t.nodes[y as usize].alloc.cmp(&t.nodes[x as usize].alloc).then(t.nodes[y as usize].size.cmp(&t.nodes[x as usize].size)));
        let more = kids.len().saturating_sub(limit);
        let rest: u64 = kids.iter().skip(limit).map(|&k| t.nodes[k as usize].alloc).sum();
        let chain = t.chain(i);
        let crumbs: Vec<Value> = chain.iter().skip_while(|&&c| c != t.root).map(|&c| json!({ "id": c, "name": if c == t.root { t.path(c) } else { t.name(c).to_string() } })).collect();
        Ok(json!({
            "node": t.item(i, true), "crumbs": crumbs,
            "items": kids.iter().take(limit).map(|&k| t.item(k, false)).collect::<Vec<_>>(),
            "more": more, "moreAlloc": rest,
        }))
    })
}

/// Nœuds de la carte (treemap) : les plus gros dossiers sont dépliés en premier,
/// jusqu'à `max` éléments. Liste plate [id, parent, alloc, type, ext, nom] ;
/// type : 0 fichier, 1 dossier replié, 2 dossier déplié.
pub fn treemap(a: &Value) -> Result<Value, String> {
    with(|t| {
        let i = node_arg(t, a)?;
        let max = a["max"].as_u64().unwrap_or(20000).clamp(500, 60000) as usize;
        let total = t.nodes[i as usize].alloc.max(1);
        let min = total / 2_000_000; // bien en dessous d'un pixel
        let mut out: Vec<Value> = Vec::new();
        let mut heap = BinaryHeap::new();
        heap.push((total, i));
        let mut slot: HashMap<u32, usize> = HashMap::new();
        while let Some((_, d)) = heap.pop() {
            if out.len() >= max {
                break;
            }
            if let Some(&k) = slot.get(&d) {
                out[k][3] = json!(2);
            }
            let mut kids = t.children(d);
            kids.retain(|&k| t.nodes[k as usize].alloc > min);
            kids.sort_by(|&x, &y| t.nodes[y as usize].alloc.cmp(&t.nodes[x as usize].alloc));
            kids.truncate(600);
            for k in kids {
                let n = &t.nodes[k as usize];
                let dir = n.flags & DIR != 0;
                if dir && n.first != NONE {
                    slot.insert(k, out.len());
                    heap.push((n.alloc, k));
                }
                out.push(json!([k, d, n.alloc, dir as u8, n.ext, t.name(k)]));
            }
        }
        Ok(json!({ "root": i, "alloc": total, "items": out, "exts": t.exts }))
    })
}

/// Place occupée par type de fichier (extension) sous le dossier.
pub fn types(a: &Value) -> Result<Value, String> {
    with(|t| {
        let i = node_arg(t, a)?;
        let mut agg: HashMap<u16, (u64, u64, u64)> = HashMap::new();
        t.each_below(i, |c| {
            let n = &t.nodes[c as usize];
            if n.flags & DIR == 0 {
                let e = agg.entry(n.ext).or_default();
                e.0 += n.alloc;
                e.1 += n.size;
                e.2 += 1;
            }
        });
        let mut v: Vec<_> = agg.into_iter().collect();
        v.sort_by(|a, b| b.1 .0.cmp(&a.1 .0));
        let total = v.len();
        Ok(json!({ "total": total, "types": v.into_iter().take(400).map(|(e, (alloc, size, count))| json!({ "ext": e, "name": t.exts[e as usize], "alloc": alloc, "size": size, "count": count })).collect::<Vec<_>>() }))
    })
}

/// Correspondance avec * et ? (sans tenir compte de la casse).
fn wild(p: &[char], s: &[char]) -> bool {
    let (mut pi, mut si, mut star, mut mark) = (0, 0, usize::MAX, 0);
    while si < s.len() {
        if pi < p.len() && (p[pi] == '?' || p[pi] == s[si]) {
            pi += 1;
            si += 1;
        } else if pi < p.len() && p[pi] == '*' {
            star = pi;
            mark = si;
            pi += 1;
        } else if star != usize::MAX {
            pi = star + 1;
            mark += 1;
            si = mark;
        } else {
            return false;
        }
    }
    p[pi..].iter().all(|&c| c == '*')
}

/// Plus gros fichiers du dossier ; avec `q`, fichiers et dossiers dont le nom
/// correspond (« *.iso », « setup », « jeux;*.mp4 »).
pub fn top(a: &Value) -> Result<Value, String> {
    with(|t| {
        let i = node_arg(t, a)?;
        let n = a["n"].as_u64().unwrap_or(1000).min(5000) as usize;
        let q = a["q"].as_str().unwrap_or("").trim().to_lowercase();
        let ext = a["ext"].as_u64().map(|e| e as u16);
        let pats: Vec<(bool, Vec<char>, String)> = q.split(';').map(str::trim).filter(|s| !s.is_empty()).map(|s| (s.contains('*') || s.contains('?'), s.chars().collect(), s.to_string())).collect();
        let mut heap: BinaryHeap<std::cmp::Reverse<(u64, u64, u32)>> = BinaryHeap::new();
        let (mut count, mut sum) = (0u64, 0u64);
        t.each_below(i, |c| {
            let nd = &t.nodes[c as usize];
            let dir = nd.flags & DIR != 0;
            if let Some(e) = ext {
                if dir || nd.ext != e {
                    return;
                }
            } else if pats.is_empty() {
                if dir {
                    return;
                }
            } else {
                let name = t.name(c).to_lowercase();
                let chars: Vec<char> = name.chars().collect();
                if !pats.iter().any(|(w, p, s)| if *w { wild(p, &chars) } else { name.contains(s.as_str()) }) {
                    return;
                }
            }
            count += 1;
            sum += nd.alloc;
            heap.push(std::cmp::Reverse((nd.alloc, nd.size, c)));
            if heap.len() > n {
                heap.pop();
            }
        });
        let mut v: Vec<u32> = heap.into_iter().map(|std::cmp::Reverse((_, _, c))| c).collect();
        v.sort_by(|&x, &y| t.nodes[y as usize].alloc.cmp(&t.nodes[x as usize].alloc).then(t.nodes[y as usize].size.cmp(&t.nodes[x as usize].size)));
        Ok(json!({ "count": count, "alloc": sum, "items": v.into_iter().map(|c| t.item(c, true)).collect::<Vec<_>>() }))
    })
}

/// Fil d'Ariane et détails d'un élément (sélection depuis la carte).
pub fn info(a: &Value) -> Result<Value, String> {
    with(|t| {
        let i = node_arg(t, a)?;
        let chain: Vec<u32> = t.chain(i).into_iter().skip_while(|&c| c != t.root).collect();
        Ok(json!({ "item": t.item(i, true), "chain": chain, "ext": t.ext(i), "dirItem": t.is_dir(i) }))
    })
}

pub fn paths(ids: &[u32]) -> Result<Vec<(u32, String)>, String> {
    with(|t| Ok(ids.iter().filter(|&&i| t.valid(i) && i != t.root).map(|&i| (i, t.path(i))).collect()))
}

/// Retire de l'arbre les éléments qui n'existent plus sur le disque.
pub fn forget(ids: &[u32]) {
    if let Some(t) = TREE.lock().unwrap().as_mut() {
        for &i in ids {
            if t.valid(i) && !Path::new(&t.path(i)).exists() {
                t.remove(i);
            }
        }
    }
}

/// Exporte le dossier en CSV (séparateur « ; », lisible par Excel en français) :
/// tous les dossiers et les fichiers d'au moins `min` octets.
pub fn export(a: &Value, dest: &Path) -> Result<Value, String> {
    use std::io::Write;
    with(|t| {
        let i = node_arg(t, a)?;
        let min = a["min"].as_u64().unwrap_or(1 << 20);
        let f = std::fs::File::create(dest).map_err(|e| e.to_string())?;
        let mut w = std::io::BufWriter::with_capacity(1 << 20, f);
        let q = |s: &str| format!("\"{}\"", s.replace('"', "\"\""));
        let mut rows = 0u64;
        let mut line = |w: &mut std::io::BufWriter<std::fs::File>, c: u32| -> std::io::Result<()> {
            let n = &t.nodes[c as usize];
            let dir = n.flags & DIR != 0;
            let date = if n.mtime > 0 { fmt_date(n.mtime) } else { String::new() };
            rows += 1;
            writeln!(w, "{};{};{};{};{};{};{}", q(&t.path(c)), if dir { "Dossier" } else { "Fichier" }, n.size, n.alloc, if dir { n.files.to_string() } else { String::new() }, if dir { n.dirs.to_string() } else { String::new() }, date)
        };
        let err = |e: std::io::Error| e.to_string();
        w.write_all("\u{feff}Chemin;Type;Taille (octets);Alloué (octets);Fichiers;Dossiers;Modifié\r\n".as_bytes()).map_err(err)?;
        line(&mut w, i).map_err(err)?;
        let mut res = Ok(());
        t.each_below(i, |c| {
            let n = &t.nodes[c as usize];
            if res.is_ok() && (n.flags & DIR != 0 || n.alloc.max(n.size) >= min) {
                res = line(&mut w, c);
            }
        });
        res.map_err(err)?;
        w.flush().map_err(err)?;
        Ok(json!({ "path": dest.to_string_lossy(), "rows": rows }))
    })
}

/// AAAA-MM-JJ HH:MM (UTC) sans dépendance de date.
fn fmt_date(secs: u32) -> String {
    let s = secs as i64;
    let (days, rem) = (s.div_euclid(86400), s.rem_euclid(86400));
    // algorithme civil de H. Hinnant
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + (m <= 2) as i64;
    format!("{y:04}-{m:02}-{d:02} {:02}:{:02}", rem / 3600, rem % 3600 / 60)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn wildcard() {
        let c = |s: &str| s.chars().collect::<Vec<_>>();
        assert!(wild(&c("*.iso"), &c("win11.iso")));
        assert!(!wild(&c("*.iso"), &c("win11.isox")));
        assert!(wild(&c("set?p*"), &c("setup.exe")));
    }
    #[test]
    fn runs() {
        // 0x21 : 1 octet de longueur, 2 octets de décalage
        assert_eq!(data_runs(&[0x21, 0x10, 0x00, 0x01, 0x11, 0x05, 0xFF, 0x00]), vec![(256, 16), (255, 5)]);
    }
    /// Lecture MFT réelle (administrateur) : `cargo test -- --ignored mft_vs_walk`, BAO_MFT_DIR = dossier à comparer.
    #[test]
    #[ignore]
    fn mft_vs_walk() {
        let dir = std::env::var("BAO_MFT_DIR").unwrap_or_else(|_| "C:\\Users".into());
        let cancel = AtomicBool::new(false);
        let t0 = Instant::now();
        let b = read_mft(dir.chars().next().unwrap(), &cancel, &|_| {}).unwrap().expect("NTFS + administrateur");
        let mut t = finish(b, 5, format!("{}:\\", &dir[..1]), false);
        let r = &t.nodes[5];
        println!("VOLUME: {} fichiers, {} dossiers, alloc {} Go, taille {} Go en {:?}", r.files, r.dirs, r.alloc / 1_000_000_000, r.size / 1_000_000_000, t0.elapsed());
        let rel: PathBuf = Path::new(&dir).components().skip(2).collect();
        t.root = t.find(5, &rel).expect("dossier");
        let m = t.nodes[t.root as usize];
        let w = finish(walk(Path::new(&dir), &cancel, &|_| {}), 0, dir.clone(), true);
        let n = w.nodes[0];
        println!("MFT  {dir}: {} fichiers, {} dossiers, alloc {}, taille {}", m.files, m.dirs, m.alloc, m.size);
        println!("WALK {dir}: {} fichiers, {} dossiers, alloc {}, taille {}", n.files, n.dirs, n.alloc, n.size);
        let mut kids = t.children(t.root);
        kids.sort_by_key(|&k| std::cmp::Reverse(t.nodes[k as usize].alloc));
        for k in kids.into_iter().take(8) {
            println!("  {} {}", t.path(k), t.nodes[k as usize].alloc);
        }
    }
    #[test]
    fn date() {
        assert_eq!(fmt_date(1_700_000_000), "2023-11-14 22:13");
    }
}
