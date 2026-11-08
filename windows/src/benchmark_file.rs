// SPDX-License-Identifier: GPL-3.0-or-later — Copyright (C) 2026 jeremdevgit
//! Exclusive creation for the temporary file used by the disk benchmark.

use std::fs::File;
use std::io;
use std::path::Path;

pub fn create_new(path: &Path) -> io::Result<File> {
    let mut options = std::fs::OpenOptions::new();
    options.read(true).write(true).create_new(true);
    configure_benchmark_flags(&mut options);
    options.open(path)
}

#[cfg(windows)]
fn configure_benchmark_flags(options: &mut std::fs::OpenOptions) {
    use std::os::windows::fs::OpenOptionsExt;
    const FILE_FLAG_NO_BUFFERING: u32 = 0x2000_0000;
    const FILE_FLAG_WRITE_THROUGH: u32 = 0x8000_0000;
    options.custom_flags(FILE_FLAG_NO_BUFFERING | FILE_FLAG_WRITE_THROUGH);
}

#[cfg(not(windows))]
fn configure_benchmark_flags(_options: &mut std::fs::OpenOptions) {
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn refuses_a_preexisting_benchmark_path_without_truncating_it() {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!("bao-bench-test-{}-{nonce}", std::process::id()));
        std::fs::create_dir(&root).unwrap();
        let path = root.join("preexisting.tmp");
        std::fs::write(&path, b"keep me").unwrap();
        assert!(create_new(&path).is_err());
        assert_eq!(std::fs::read(&path).unwrap(), b"keep me");
        std::fs::remove_file(path).unwrap();
        std::fs::remove_dir(root).unwrap();
    }
}
