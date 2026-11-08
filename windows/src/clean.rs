// SPDX-License-Identifier: GPL-3.0-or-later — Copyright (C) 2026 jeremdevgit — voir LICENSE
//! Caches et fichiers temporaires : catégories connues, taille réelle,
//! nettoyage en ignorant les fichiers en cours d'utilisation.

use crate::files;
use serde_json::{json, Value};
use std::path::PathBuf;

pub struct Cat {
    pub id: &'static str,
    pub group: &'static str,
    pub label: &'static str,
    pub desc: &'static str,
    /// sur : aucune conséquence · prudence : effet visible (à lire) · admin : droits requis
    pub risk: &'static str,
    pub default: bool,
    pub admin: bool,
    pub paths: &'static [&'static str],
    /// fichiers plus récents ignorés (en heures)
    pub min_age: u64,
}

const H24: u64 = 24;

pub const CATS: &[Cat] = &[
    Cat { id: "temp_user", group: "Windows", label: "Fichiers temporaires de l'utilisateur", desc: "Fichiers laissés par les installations et les applications dans %TEMP%. Ceux de moins de 24 h sont gardés : une installation en cours peut encore en avoir besoin.", risk: "sur", default: true, admin: false, paths: &["%TEMP%"], min_age: H24 },
    Cat { id: "temp_win", group: "Windows", label: "Fichiers temporaires de Windows", desc: "Dossier Temp de Windows. Même règle des 24 h.", risk: "sur", default: true, admin: true, paths: &["%SystemRoot%\\Temp"], min_age: H24 },
    Cat { id: "wer", group: "Windows", label: "Rapports d'erreurs et vidages mémoire", desc: "Rapports de plantage envoyés (ou en attente) à Microsoft et vidages mémoire des applications. Inutiles sauf pour un développeur qui analyse un plantage précis.", risk: "sur", default: true, admin: true, paths: &["%ProgramData%\\Microsoft\\Windows\\WER\\ReportArchive", "%ProgramData%\\Microsoft\\Windows\\WER\\ReportQueue", "%LOCALAPPDATA%\\Microsoft\\Windows\\WER", "%LOCALAPPDATA%\\CrashDumps", "%SystemRoot%\\Minidump", "%SystemRoot%\\LiveKernelReports"], min_age: 0 },
    Cat { id: "update", group: "Windows", label: "Téléchargements de Windows Update", desc: "Mises à jour déjà installées qui restent dans SoftwareDistribution\\Download. Une mise à jour en attente sera simplement re-téléchargée. Le service Windows Update est arrêté le temps du nettoyage puis relancé.", risk: "sur", default: false, admin: true, paths: &["%SystemRoot%\\SoftwareDistribution\\Download"], min_age: 0 },
    Cat { id: "delivery", group: "Windows", label: "Cache d'optimisation de la distribution", desc: "Morceaux de mises à jour gardés pour être partagés avec d'autres PC. Vidé avec la commande officielle de Windows.", risk: "sur", default: true, admin: true, paths: &["%SystemRoot%\\ServiceProfiles\\NetworkService\\AppData\\Local\\Microsoft\\Windows\\DeliveryOptimization\\Cache"], min_age: 0 },
    Cat { id: "logs", group: "Windows", label: "Journaux d'installation de Windows", desc: "Journaux CBS et DISM de plus de 7 jours. Utiles seulement pour diagnostiquer une mise à jour ratée.", risk: "sur", default: true, admin: true, paths: &["%SystemRoot%\\Logs\\CBS", "%SystemRoot%\\Logs\\DISM"], min_age: 24 * 7 },
    Cat { id: "thumbs", group: "Windows", label: "Miniatures de l'explorateur", desc: "Aperçus des photos et vidéos. Ils sont recréés à l'ouverture des dossiers : les premiers affichages seront un peu plus lents. Une partie est utilisée par l'explorateur et restera.", risk: "prudence", default: false, admin: false, paths: &["%LOCALAPPDATA%\\Microsoft\\Windows\\Explorer\\thumbcache_*.db", "%LOCALAPPDATA%\\Microsoft\\Windows\\Explorer\\iconcache_*.db"], min_age: 0 },
    Cat { id: "recycle", group: "Windows", label: "Corbeille", desc: "Les fichiers que vous avez supprimés. Une fois la Corbeille vidée, ils ne sont plus récupérables.", risk: "prudence", default: false, admin: false, paths: &[], min_age: 0 },
    Cat { id: "chromium", group: "Navigateurs", label: "Cache de Chrome, Edge, Brave, Vivaldi, Opera", desc: "Pages et images gardées pour aller plus vite. Vos onglets, mots de passe, cookies et historique ne sont pas touchés. Les sites rechargeront leurs images la première fois. Fermez le navigateur pour tout vider.", risk: "sur", default: true, admin: false, paths: &[
        "%LOCALAPPDATA%\\Google\\Chrome\\User Data\\*\\Cache", "%LOCALAPPDATA%\\Google\\Chrome\\User Data\\*\\Code Cache", "%LOCALAPPDATA%\\Google\\Chrome\\User Data\\*\\GPUCache",
        "%LOCALAPPDATA%\\Microsoft\\Edge\\User Data\\*\\Cache", "%LOCALAPPDATA%\\Microsoft\\Edge\\User Data\\*\\Code Cache", "%LOCALAPPDATA%\\Microsoft\\Edge\\User Data\\*\\GPUCache",
        "%LOCALAPPDATA%\\BraveSoftware\\Brave-Browser\\User Data\\*\\Cache", "%LOCALAPPDATA%\\BraveSoftware\\Brave-Browser\\User Data\\*\\Code Cache", "%LOCALAPPDATA%\\BraveSoftware\\Brave-Browser\\User Data\\*\\GPUCache",
        "%LOCALAPPDATA%\\Vivaldi\\User Data\\*\\Cache", "%LOCALAPPDATA%\\Vivaldi\\User Data\\*\\Code Cache",
        "%LOCALAPPDATA%\\Opera Software\\*\\Cache", "%APPDATA%\\Opera Software\\*\\Code Cache",
    ], min_age: 0 },
    Cat { id: "firefox", group: "Navigateurs", label: "Cache de Firefox", desc: "Même chose pour Firefox : seules les pages et images en cache sont effacées.", risk: "sur", default: true, admin: false, paths: &["%LOCALAPPDATA%\\Mozilla\\Firefox\\Profiles\\*\\cache2", "%LOCALAPPDATA%\\Mozilla\\Firefox\\Profiles\\*\\startupCache"], min_age: 0 },
    Cat { id: "electron", group: "Applications", label: "Cache de Discord, Teams, Slack, Spotify (interface)", desc: "Images et scripts mis en cache par ces applications. Elles les rechargent au besoin. Fermez-les pour tout vider ; vos messages et réglages ne sont pas touchés.", risk: "sur", default: true, admin: false, paths: &[
        "%APPDATA%\\discord\\Cache", "%APPDATA%\\discord\\Code Cache", "%APPDATA%\\discord\\GPUCache",
        "%APPDATA%\\Slack\\Cache", "%APPDATA%\\Slack\\Code Cache", "%APPDATA%\\Slack\\GPUCache",
        "%APPDATA%\\Microsoft\\Teams\\Cache", "%APPDATA%\\Microsoft\\Teams\\Code Cache", "%APPDATA%\\Microsoft\\Teams\\GPUCache",
        "%APPDATA%\\Spotify\\Browser\\Cache", "%LOCALAPPDATA%\\Spotify\\Browser\\Cache",
    ], min_age: 0 },
    Cat { id: "spotify", group: "Applications", label: "Musique en cache de Spotify", desc: "Titres gardés pour éviter de les re-télécharger (pas les titres téléchargés pour l'écoute hors ligne, gardés ailleurs). Ils seront re-téléchargés à la prochaine écoute.", risk: "prudence", default: false, admin: false, paths: &["%LOCALAPPDATA%\\Spotify\\Data"], min_age: 0 },
    Cat { id: "steamweb", group: "Jeux", label: "Cache web de Steam", desc: "Pages du magasin et de la communauté gardées par Steam. Rechargées au besoin. Fermez Steam pour tout vider.", risk: "sur", default: true, admin: false, paths: &["%LOCALAPPDATA%\\Steam\\htmlcache\\Cache", "%LOCALAPPDATA%\\Steam\\htmlcache\\Code Cache", "%LOCALAPPDATA%\\Steam\\htmlcache\\GPUCache"], min_age: 0 },
    Cat { id: "shaders", group: "Jeux", label: "Caches de shaders (NVIDIA, AMD, DirectX)", desc: "Effets graphiques déjà préparés pour vos jeux. Les vider ne fait rien gagner en performances : au contraire, chaque jeu les recalculera, avec des saccades pendant les premières minutes. Utile uniquement en cas de bug graphique après une mise à jour de pilote.", risk: "prudence", default: false, admin: false, paths: &["%LOCALAPPDATA%\\NVIDIA\\DXCache", "%LOCALAPPDATA%\\NVIDIA\\GLCache", "%LOCALAPPDATA%Low\\NVIDIA\\PerDriverVersion\\DXCache", "%LOCALAPPDATA%\\AMD\\DxCache", "%LOCALAPPDATA%\\AMD\\DxcCache", "%LOCALAPPDATA%\\AMD\\VkCache", "%LOCALAPPDATA%\\D3DSCache"], min_age: 0 },
];

/// Remplace %VAR% par la variable d'environnement correspondante.
fn expand_env(s: &str) -> Option<String> {
    let mut out = String::new();
    let mut rest = s;
    while let Some(i) = rest.find('%') {
        out.push_str(&rest[..i]);
        let after = &rest[i + 1..];
        let j = after.find('%')?;
        let val = std::env::var(&after[..j]).ok()?;
        out.push_str(&val);
        rest = &after[j + 1..];
    }
    out.push_str(rest);
    Some(out)
}

/// Motif avec `*` dans un composant (dossier ou nom de fichier) → chemins existants.
pub fn expand(pattern: &str) -> Vec<PathBuf> {
    let Some(p) = expand_env(pattern) else { return vec![] };
    let mut acc = vec![PathBuf::new()];
    for (i, comp) in p.split('\\').enumerate() {
        let mut next = Vec::new();
        for base in &acc {
            if comp.contains('*') {
                let (pre, post) = comp.split_once('*').unwrap();
                if let Ok(rd) = std::fs::read_dir(base) {
                    for e in rd.flatten() {
                        let n = e.file_name().to_string_lossy().to_lowercase();
                        if n.starts_with(&pre.to_lowercase()) && n.ends_with(&post.to_lowercase()) && n.len() >= pre.len() + post.len() {
                            next.push(e.path());
                        }
                    }
                }
            } else if i == 0 {
                next.push(PathBuf::from(format!("{comp}\\")));
            } else {
                next.push(base.join(comp));
            }
        }
        acc = next;
    }
    acc.into_iter().filter(|p| p.exists()).collect()
}

fn size_of(cat: &Cat) -> (u64, u64) {
    if cat.id == "recycle" {
        return crate::win::recycle_bin_info();
    }
    let mut total = (0, 0);
    for pat in cat.paths {
        for p in expand(pat) {
            let (s, n) = if p.is_dir() {
                files::dir_size(&p, cat.min_age)
            } else {
                std::fs::metadata(&p).map(|m| (files::disk_size(&p, &m), 1)).unwrap_or((0, 0))
            };
            total.0 += s;
            total.1 += n;
        }
    }
    total
}

/// Toutes les catégories avec leur taille actuelle.
pub fn analyze(elevated: bool) -> Value {
    let list: Vec<Value> = std::thread::scope(|s| {
        let handles: Vec<_> = CATS.iter().map(|c| s.spawn(move || (c, size_of(c)))).collect();
        handles
            .into_iter()
            .map(|h| {
                let (c, (size, count)) = h.join().unwrap();
                json!({ "id": c.id, "group": c.group, "label": c.label, "desc": c.desc, "risk": c.risk, "default": c.default, "admin": c.admin, "size": size, "count": count, "locked": c.admin && !elevated })
            })
            .collect()
    });
    json!({ "cats": list })
}

fn stop_services(names: &[&str], start: bool) {
    let sc = crate::win::system_tool("sc.exe");
    for n in names {
        let _ = std::process::Command::new(&sc)
            .args([if start { "start" } else { "stop" }, n])
            .creation_flags(crate::win::NO_WINDOW)
            .output();
    }
    if !start {
        std::thread::sleep(std::time::Duration::from_secs(2));
    }
}
use std::os::windows::process::CommandExt;

/// Nettoie les catégories demandées ; renvoie l'espace libéré par catégorie.
pub fn clean(ids: &[String], progress: impl Fn(&str)) -> Value {
    let mut results = Vec::new();
    let mut total = 0u64;
    for c in CATS.iter().filter(|c| ids.iter().any(|i| i == c.id)) {
        progress(c.label);
        let before = size_of(c).0;
        let (mut freed, mut removed, mut skipped) = (0u64, 0u64, 0u64);
        match c.id {
            "recycle" => {
                if crate::win::empty_recycle_bin() {
                    freed = before;
                }
            }
            "delivery" => {
                let _ = crate::ps::run("system", &json!({ "action": "clearDelivery" }));
                freed = before.saturating_sub(size_of(c).0);
            }
            _ => {
                let services: &[&str] = if c.id == "update" { &["wuauserv", "bits"] } else { &[] };
                if !services.is_empty() {
                    stop_services(services, false);
                }
                for pat in c.paths {
                    for p in expand(pat) {
                        if p.is_dir() {
                            let (f, r, s) = files::clear_dir(&p, c.min_age);
                            freed += f;
                            removed += r;
                            skipped += s;
                        } else if let Some(size) = files::remove_file(&p) {
                            freed += size;
                            removed += 1;
                        } else {
                            skipped += 1;
                        }
                    }
                }
                if !services.is_empty() {
                    stop_services(services, true);
                }
            }
        }
        total += freed;
        results.push(json!({ "id": c.id, "label": c.label, "freed": freed, "removed": removed, "skipped": skipped }));
    }
    json!({ "results": results, "freed": total })
}

/// Anciennes versions d'applications installées par Squirrel (Discord, Teams
/// classique, Slack, GitHub Desktop…) : dossiers app-x.y.z sauf le plus récent.
pub fn old_versions() -> Vec<Value> {
    let mut out = Vec::new();
    let Some(base) = std::env::var_os("LOCALAPPDATA").map(PathBuf::from) else { return out };
    let Ok(rd) = std::fs::read_dir(&base) else { return out };
    for e in rd.flatten() {
        let dir = e.path();
        if !dir.join("Update.exe").exists() {
            continue;
        }
        let mut versions: Vec<(Vec<u64>, PathBuf)> = std::fs::read_dir(&dir)
            .into_iter()
            .flatten()
            .flatten()
            .filter_map(|v| {
                let n = v.file_name().to_string_lossy().to_string();
                let ver = n.strip_prefix("app-")?;
                let parts: Vec<u64> = ver.split('.').map(|x| x.parse().unwrap_or(0)).collect();
                v.path().is_dir().then_some((parts, v.path()))
            })
            .collect();
        if versions.len() < 2 {
            continue;
        }
        versions.sort();
        versions.pop(); // la plus récente reste
        let app = dir.file_name().unwrap_or_default().to_string_lossy().to_string();
        for (_, p) in versions {
            let (size, _) = files::dir_size(&p, 0);
            out.push(json!({ "path": p.to_string_lossy(), "size": size, "app": app }));
        }
    }
    out
}

/// Installateurs et archives oubliés dans Téléchargements (plus de 30 jours).
pub fn old_downloads() -> Vec<Value> {
    let Some(dl) = crate::shell::known_folder(&windows::Win32::UI::Shell::FOLDERID_Downloads) else { return vec![] };
    let mut out = Vec::new();
    let Ok(rd) = std::fs::read_dir(&dl) else { return out };
    for e in rd.flatten() {
        let p = e.path();
        let ext = p.extension().map(|x| x.to_string_lossy().to_lowercase()).unwrap_or_default();
        if !["exe", "msi", "msix", "msixbundle", "iso", "zip", "7z", "rar"].contains(&ext.as_str()) {
            continue;
        }
        let Ok(m) = e.metadata() else { continue };
        if !m.is_file() {
            continue;
        }
        let age = m.modified().map(files::age_days).unwrap_or(0);
        if age >= 30 {
            out.push(json!({ "path": p.to_string_lossy(), "size": files::disk_size(&p, &m), "age": age }));
        }
    }
    out
}

