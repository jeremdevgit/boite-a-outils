// SPDX-License-Identifier: GPL-3.0-or-later — Copyright (C) 2026 jeremdevgit — voir LICENSE
//! Historique des modifications : chaque changement garde de quoi être annulé
//! (script et arguments qui remettent l'état d'avant).

use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::sync::Mutex;

#[derive(Serialize, Deserialize, Clone)]
pub struct Entry {
    pub id: u64,
    /// secondes depuis 1970
    pub time: u64,
    pub title: String,
    pub detail: String,
    /// script intégré et arguments qui annulent la modification (vide : définitif)
    pub undo_script: String,
    pub undo_args: Value,
    pub undone: bool,
}

static LOCK: Mutex<()> = Mutex::new(());

fn path() -> Result<std::path::PathBuf, String> {
    Ok(crate::win::operation_data_dir()?.join("historique.json"))
}
fn read(path: &std::path::Path) -> Vec<Entry> {
    std::fs::read(path)
        .ok()
        .and_then(|b| serde_json::from_slice(&b).ok())
        .unwrap_or_default()
}
fn legacy_display_only(mut list: Vec<Entry>) -> Vec<Entry> {
    if list.len() > 2000 {
        list.drain(..list.len() - 2000);
    }
    for (i, entry) in list.iter_mut().enumerate() {
        entry.id = i as u64 + 1;
        entry.undo_script.clear();
        entry.undo_args = Value::Null;
    }
    list
}

pub fn load() -> Vec<Entry> {
    let Ok(path) = path() else {
        return Vec::new();
    };
    if !crate::win::is_elevated() {
        return read(&path);
    }
    if path.exists() {
        return if crate::install_security::trusted(&path) {
            read(&path)
        } else {
            Vec::new()
        };
    }
    legacy_display_only(read(&crate::win::data_dir().join("historique.json")))
}

fn save(list: &[Entry]) {
    use std::io::Write;
    let Ok(path) = path() else {
        return;
    };
    let nonce = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let tmp = path.with_extension(format!("{}-{nonce}.tmp", std::process::id()));
    let result = (|| -> std::io::Result<()> {
        let mut out = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&tmp)?;
        out.write_all(&serde_json::to_vec_pretty(list)?)?;
        out.sync_all()?;
        drop(out);
        std::fs::rename(&tmp, &path)
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(tmp);
    }
}

pub fn add(title: &str, detail: &str, undo_script: &str, undo_args: Value) -> u64 {
    let _g = LOCK.lock().unwrap();
    let mut list = load();
    let id = list
        .iter()
        .map(|e| e.id)
        .max()
        .unwrap_or(0)
        .saturating_add(1);
    let time = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    list.push(Entry {
        id,
        time,
        title: title.into(),
        detail: detail.into(),
        undo_script: undo_script.into(),
        undo_args,
        undone: false,
    });
    // les 2000 dernières modifications suffisent
    if list.len() > 2000 {
        let n = list.len() - 2000;
        list.drain(..n);
    }
    save(&list);
    id
}

/// Annule une modification en rejouant son script d'annulation.
pub fn undo(id: u64) -> Result<Value, String> {
    let entry = {
        let _g = LOCK.lock().unwrap();
        load()
            .into_iter()
            .find(|e| e.id == id)
            .ok_or("modification introuvable")?
    };
    if entry.undone {
        return Err("déjà annulée".into());
    }
    if entry.undo_script.is_empty() {
        return Err("cette opération ne peut pas être annulée".into());
    }
    let r = crate::ps::run(&entry.undo_script, &entry.undo_args)?;
    let _g = LOCK.lock().unwrap();
    let mut list = load();
    if let Some(e) = list.iter_mut().find(|e| e.id == id) {
        e.undone = true;
    }
    save(&list);
    Ok(r)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn legacy_history_never_authorizes_elevated_undo() {
        let list = legacy_display_only(vec![Entry {
            id: u64::MAX,
            time: 1,
            title: "demo".into(),
            detail: "kept".into(),
            undo_script: "startup_set".into(),
            undo_args: serde_json::json!({"kind":"restoreTask","xml":"attacker.xml"}),
            undone: false,
        }]);
        assert_eq!(list[0].title, "demo");
        assert_eq!(list[0].detail, "kept");
        assert_eq!(list[0].id, 1);
        assert!(list[0].undo_script.is_empty());
        assert!(list[0].undo_args.is_null());
    }
}
