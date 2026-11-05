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

fn path() -> std::path::PathBuf {
    crate::win::data_dir().join("historique.json")
}

pub fn load() -> Vec<Entry> {
    std::fs::read(path()).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default()
}

fn save(list: &[Entry]) {
    let tmp = path().with_extension("tmp");
    if std::fs::write(&tmp, serde_json::to_vec_pretty(list).unwrap_or_default()).is_ok() {
        let _ = std::fs::rename(&tmp, path());
    }
}

pub fn add(title: &str, detail: &str, undo_script: &str, undo_args: Value) -> u64 {
    let _g = LOCK.lock().unwrap();
    let mut list = load();
    let id = list.iter().map(|e| e.id).max().unwrap_or(0) + 1;
    let time = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
    list.push(Entry { id, time, title: title.into(), detail: detail.into(), undo_script: undo_script.into(), undo_args, undone: false });
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
        load().into_iter().find(|e| e.id == id).ok_or("modification introuvable")?
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
