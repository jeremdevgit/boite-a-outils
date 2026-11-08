// SPDX-License-Identifier: GPL-3.0-or-later — Copyright (C) 2026 jeremdevgit
//! Construit les composants de chemin de sauvegarde à partir de valeurs externes.

use std::path::{Path, PathBuf};

/// Une valeur utilisée comme composant Windows ne doit jamais devenir un segment de traversal.
pub fn component(value: &str, fallback: &str) -> String {
    let cleaned: String = value
        .chars()
        .map(|c| {
            if "\\/:*?\"<>|".contains(c) || c.is_control() {
                '_'
            } else {
                c
            }
        })
        .collect();
    let cleaned = cleaned.trim_end_matches(|c| c == ' ' || c == '.');
    if cleaned.is_empty() || cleaned == "." || cleaned == ".." {
        fallback.to_string()
    } else {
        cleaned.to_string()
    }
}

pub fn installer_dir(root: &Path, id: &str) -> Option<PathBuf> {
    (crate::winget::valid_id(id) && !id.ends_with('.')).then(|| root.join("Installateurs").join(id))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn components_cannot_escape_their_parent() {
        assert_eq!(component("PC-01", "PC"), "PC-01");
        assert_eq!(component("../../Windows", "PC"), ".._.._Windows");
        assert_eq!(component("..", "PC"), "PC");
        assert_eq!(component(". ", "Dossier"), "Dossier");
    }

    #[test]
    fn invalid_package_ids_never_become_output_paths() {
        let root = Path::new("C:\\Backup");
        assert_eq!(
            installer_dir(root, "Vendor.App"),
            Some(root.join("Installateurs/Vendor.App"))
        );
        assert_eq!(installer_dir(root, "../../outside"), None);
        assert_eq!(installer_dir(root, "-h"), None);
        assert_eq!(installer_dir(root, ".."), None);
        assert_eq!(installer_dir(root, "..."), None);
        assert_eq!(installer_dir(root, "Vendor.App."), None);
    }
}
