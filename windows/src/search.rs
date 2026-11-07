// SPDX-License-Identifier: GPL-3.0-or-later — Copyright (C) 2026 jeremdevgit
//! Read-only name/path index. No links or Windows reparse points are traversed.
//! The index lives in memory; rebuilding explicitly refreshes filesystem changes.
use serde::Serialize;
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::UNIX_EPOCH;

#[derive(Clone, Serialize)]
struct Entry {
    path: String,
    name: String,
    dir: bool,
    size: u64,
    modified: u64,
}
struct State {
    entries: Vec<Entry>,
    root: String,
    running: bool,
    skipped: usize,
    generation: u64,
    cancelled: bool,
    cancel: Arc<AtomicBool>,
}
impl Default for State {
    fn default() -> Self {
        Self {
            entries: Vec::new(),
            root: String::new(),
            running: false,
            skipped: 0,
            generation: 0,
            cancelled: false,
            cancel: Arc::new(AtomicBool::new(false)),
        }
    }
}
static INDEX: OnceLock<Mutex<State>> = OnceLock::new();
fn index() -> &'static Mutex<State> {
    INDEX.get_or_init(|| Mutex::new(State::default()))
}

fn traversable(meta: &std::fs::Metadata) -> bool {
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        if meta.file_attributes() & 0x400 != 0 {
            return false;
        }
    }
    !meta.file_type().is_symlink()
}
fn hidden(path: &Path, meta: &std::fs::Metadata) -> bool {
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        if meta.file_attributes() & 2 != 0 {
            return true;
        }
    }
    let _ = meta;
    path.file_name()
        .is_some_and(|s| s.to_string_lossy().starts_with('.'))
}
/// Iterative DFS, bounded lock duration and cooperative cancellation for large trees.
fn walk(
    root: &Path,
    include_hidden: bool,
    cancel: &AtomicBool,
    mut publish: impl FnMut(Vec<Entry>, usize),
) {
    let mut stack = vec![root.to_path_buf()];
    let mut batch = Vec::new();
    let mut skipped = 0;
    while let Some(path) = stack.pop() {
        if cancel.load(Ordering::Relaxed) {
            break;
        }
        let meta = match std::fs::symlink_metadata(&path) {
            Ok(m) => m,
            Err(_) => {
                skipped += 1;
                continue;
            }
        };
        if !traversable(&meta) || (!include_hidden && path != root && hidden(&path, &meta)) {
            continue;
        }
        let dir = meta.is_dir();
        batch.push(Entry {
            name: path
                .file_name()
                .unwrap_or(path.as_os_str())
                .to_string_lossy()
                .into_owned(),
            path: path.to_string_lossy().into_owned(),
            dir,
            size: if dir { 0 } else { meta.len() },
            modified: meta
                .modified()
                .ok()
                .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
                .map_or(0, |t| t.as_secs()),
        });
        if dir {
            match std::fs::read_dir(&path) {
                Ok(children) => {
                    for item in children {
                        if cancel.load(Ordering::Relaxed) {
                            break;
                        }
                        match item {
                            Ok(it) => stack.push(it.path()),
                            Err(_) => skipped += 1,
                        }
                    }
                }
                Err(_) => skipped += 1,
            }
        }
        if batch.len() >= 512 {
            publish(std::mem::take(&mut batch), skipped);
            skipped = 0;
        }
    }
    publish(batch, skipped);
}
pub fn start(root: &str, include_hidden: bool) -> Result<Value, String> {
    start_roots(vec![PathBuf::from(root)], root, include_hidden)
}
pub fn start_all(roots: Vec<String>, include_hidden: bool) -> Result<Value, String> {
    let paths: Vec<_> = roots
        .into_iter()
        .map(PathBuf::from)
        .filter(|p| p.is_absolute() && p.is_dir())
        .collect();
    start_roots(paths, "*", include_hidden)
}
fn start_roots(paths: Vec<PathBuf>, root: &str, include_hidden: bool) -> Result<Value, String> {
    if paths.is_empty() || paths.iter().any(|p| !p.is_absolute() || !p.is_dir()) {
        return Err("Choisissez un dossier accessible.".into());
    }
    let (generation, cancel) = {
        let mut s = index().lock().unwrap();
        s.cancel.store(true, Ordering::Relaxed);
        s.generation += 1;
        s.entries.clear();
        s.root = root.into();
        s.running = true;
        s.skipped = 0;
        s.cancelled = false;
        s.cancel = Arc::new(AtomicBool::new(false));
        (s.generation, s.cancel.clone())
    };
    std::thread::spawn(move || {
        for path in paths {
            if cancel.load(Ordering::Relaxed) {
                break;
            }
            walk(&path, include_hidden, &cancel, |batch, skipped| {
                let mut s = index().lock().unwrap();
                if s.generation == generation {
                    s.entries.extend(batch);
                    s.skipped += skipped;
                }
            });
        }
        let mut s = index().lock().unwrap();
        if s.generation == generation {
            s.running = false;
            s.cancelled = cancel.load(Ordering::Relaxed);
        }
    });
    Ok(status())
}
pub fn stop() -> Value {
    index()
        .lock()
        .unwrap()
        .cancel
        .store(true, Ordering::Relaxed);
    status()
}
pub fn status() -> Value {
    let s = index().lock().unwrap();
    json!({ "root": s.root, "count": s.entries.len(), "running": s.running, "skipped": s.skipped, "cancelled": s.cancelled, "generation": s.generation })
}
/// Unicode wildcard matching with a single backtracking point (no regex dependency).
fn glob(text: &str, pattern: &str) -> bool {
    let t: Vec<char> = text.chars().collect();
    let p: Vec<char> = pattern.chars().collect();
    let (mut i, mut j, mut star, mut mark) = (0, 0, None, 0);
    while i < t.len() {
        if j < p.len() && (p[j] == '?' || p[j] == t[i]) {
            i += 1;
            j += 1;
        } else if j < p.len() && p[j] == '*' {
            star = Some(j);
            j += 1;
            mark = i;
        } else if let Some(s) = star {
            mark += 1;
            i = mark;
            j = s + 1;
        } else {
            return false;
        }
    }
    while j < p.len() && p[j] == '*' {
        j += 1;
    }
    j == p.len()
}
fn matches(e: &Entry, a: &Value) -> bool {
    let kind = a["kind"].as_str().unwrap_or("");
    if (kind == "folders" && !e.dir) || (kind == "files" && e.dir) {
        return false;
    }
    let min = a["min"].as_u64().unwrap_or(0);
    if min > 0 && (e.dir || e.size < min) {
        return false;
    }
    if a["since"]
        .as_u64()
        .is_some_and(|since| since > 0 && e.modified < since)
    {
        return false;
    }
    let target = if a["fullPath"].as_bool().unwrap_or(false) {
        &e.path
    } else {
        &e.name
    }
    .to_lowercase();
    let q = a["q"].as_str().unwrap_or("").to_lowercase();
    q.split_whitespace().all(|word| {
        if word.contains(['*', '?']) {
            glob(&target, &format!("*{word}*"))
        } else {
            target.contains(word)
        }
    })
}
pub fn query(a: &Value) -> Value {
    let s = index().lock().unwrap();
    let mut items: Vec<_> = s.entries.iter().filter(|e| matches(e, a)).collect();
    let total = items.len();
    let sort = a["sort"].as_str().unwrap_or("name");
    let compare = |a: &&Entry, b: &&Entry| match sort {
        "size" => b.size.cmp(&a.size).then_with(|| a.path.cmp(&b.path)),
        "date" => b
            .modified
            .cmp(&a.modified)
            .then_with(|| a.path.cmp(&b.path)),
        _ => a
            .name
            .to_lowercase()
            .cmp(&b.name.to_lowercase())
            .then_with(|| a.path.cmp(&b.path)),
    };
    let limit = a["limit"].as_u64().unwrap_or(500).clamp(1, 2000) as usize;
    if items.len() > limit {
        items.select_nth_unstable_by(limit, compare);
        items.truncate(limit);
    }
    items.sort_by(compare);
    json!({ "items": items, "total": total, "generation": s.generation, "indexed": s.entries.len(), "running": s.running, "skipped": s.skipped, "root": s.root, "cancelled": s.cancelled })
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn wildcard_unicode() {
        assert!(glob("réunion.pdf", "*ré?ni*.pdf*"));
        assert!(!glob("report.txt", "*.pdf*"));
        assert!(glob("abc", "***"));
    }
    #[test]
    fn query_filters() {
        let e = Entry {
            path: "/Demo/Reports/annual.pdf".into(),
            name: "annual.pdf".into(),
            dir: false,
            size: 100,
            modified: 1000,
        };
        assert!(matches(&e, &json!({"q":"ANNUAL *.pdf"})));
        assert!(!matches(&e, &json!({"q":"Reports"})));
        assert!(matches(&e, &json!({"q":"Reports", "fullPath":true})));
        assert!(!matches(&e, &json!({"kind":"folders"})));
        assert!(!matches(&e, &json!({"min":101})));
        assert!(!matches(&e, &json!({"since":1001})));
    }
    #[test]
    fn read_only_walk_and_cancel() {
        let root = std::env::temp_dir().join(format!("bao-search-test-{}", std::process::id()));
        std::fs::create_dir_all(root.join("folder")).unwrap();
        std::fs::write(root.join("folder/demo.txt"), b"demo").unwrap();
        std::fs::write(root.join(".hidden"), b"private").unwrap();
        #[cfg(unix)]
        std::os::unix::fs::symlink(&root, root.join("folder/cycle")).unwrap();
        let mut entries = Vec::new();
        walk(&root, false, &AtomicBool::new(false), |b, _| {
            entries.extend(b)
        });
        assert!(entries.iter().any(|e| e.name == "demo.txt"));
        assert!(!entries
            .iter()
            .any(|e| e.name == ".hidden" || e.name == "cycle"));
        let mut n = 0;
        walk(&root, true, &AtomicBool::new(true), |b, _| n += b.len());
        assert_eq!(n, 0);
        assert_eq!(
            std::fs::read(root.join("folder/demo.txt")).unwrap(),
            b"demo"
        );
        std::fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn bounded_sorted_results_and_rebuild() {
        let root = std::env::temp_dir().join(format!("bao-search-rank-{}", std::process::id()));
        std::fs::create_dir_all(root.join("empty")).unwrap();
        for n in 1..=620 {
            std::fs::write(root.join(format!("file{n:04}.dat")), vec![42; n]).unwrap();
        }
        start(root.to_str().unwrap(), false).unwrap();
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        while status()["running"] == true && std::time::Instant::now() < deadline {
            std::thread::sleep(std::time::Duration::from_millis(2));
        }
        let r = query(&json!({"q":"*.dat","sort":"size","limit":17}));
        assert_eq!(r["total"], 620);
        assert_eq!(r["items"].as_array().unwrap().len(), 17);
        assert_eq!(r["items"][0]["size"], 620);
        assert_eq!(r["items"][16]["size"], 604);
        start(root.to_str().unwrap(), false).unwrap();
        stop();
        start(root.join("empty").to_str().unwrap(), false).unwrap();
        while status()["running"] == true && std::time::Instant::now() < deadline {
            std::thread::sleep(std::time::Duration::from_millis(2));
        }
        assert_eq!(query(&json!({"kind":"files"}))["total"], 0);
        std::fs::remove_dir_all(root).unwrap();
    }
}
