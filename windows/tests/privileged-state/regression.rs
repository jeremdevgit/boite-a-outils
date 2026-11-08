use super::*;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use windows_sys::Win32::System::Registry::*;
fn unique() -> String {
    format!(
        "BaoSecurityFixture-{}-{}",
        std::process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    )
}
fn program_files() -> PathBuf {
    use windows_sys::Win32::UI::Shell::{FOLDERID_ProgramFiles, SHGetKnownFolderPath};
    let mut p = std::ptr::null_mut();
    assert_eq!(
        unsafe { SHGetKnownFolderPath(&FOLDERID_ProgramFiles, 0, std::ptr::null_mut(), &mut p) },
        0
    );
    let mut n = 0;
    while unsafe { *p.add(n) } != 0 {
        n += 1;
    }
    let root = PathBuf::from(String::from_utf16_lossy(unsafe {
        std::slice::from_raw_parts(p, n)
    }));
    unsafe { windows_sys::Win32::System::Com::CoTaskMemFree(p.cast()) };
    root
}
fn literal(p: &Path) -> String {
    p.to_string_lossy().replace('\'', "''")
}
fn encoded(script: &str) -> String {
    const CHARS: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let bytes: Vec<u8> = script.encode_utf16().flat_map(u16::to_le_bytes).collect();
    let mut out = String::new();
    for part in bytes.chunks(3) {
        let n = ((part[0] as u32) << 16)
            | ((part.get(1).copied().unwrap_or(0) as u32) << 8)
            | part.get(2).copied().unwrap_or(0) as u32;
        out.push(CHARS[((n >> 18) & 63) as usize] as char);
        out.push(CHARS[((n >> 12) & 63) as usize] as char);
        out.push(if part.len() > 1 {
            CHARS[((n >> 6) & 63) as usize] as char
        } else {
            '='
        });
        out.push(if part.len() > 2 {
            CHARS[(n & 63) as usize] as char
        } else {
            '='
        });
    }
    out
}
fn ps_standard(script: &str) -> String {
    let result = user_context::output(
        &win::system_tool(r"WindowsPowerShell\v1.0\powershell.exe"),
        &[
            "-NoProfile",
            "-NonInteractive",
            "-EncodedCommand",
            &encoded(script),
        ],
        &[],
        Duration::from_secs(30),
    )
    .unwrap();
    assert!(
        result.stderr.is_empty(),
        "{}",
        String::from_utf8_lossy(&result.stderr)
    );
    String::from_utf8_lossy(&result.stdout).trim().to_string()
}
#[test]
fn restricted_primary_token_and_thread_cannot_modify_protected_state() {
    assert!(
        win::is_elevated(),
        "native fixtures require elevated CI runner"
    );
    let root = program_files().join(unique());
    install_security::prepare_private(&root).unwrap();
    let witness = root.join("private.txt");
    std::fs::write(&witness, b"unchanged").unwrap();
    let (admin, write, read) = user_context::as_standard_user(|| {
        (
            win::is_elevated(),
            std::fs::write(&witness, b"changed").is_ok(),
            std::fs::read(&witness).is_ok(),
        )
    })
    .unwrap();
    assert!(!admin);
    assert!(!write);
    assert!(!read);
    assert!(win::is_elevated());
    let result=ps_standard(&format!("$p=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent());$p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator);try{{[IO.File]::WriteAllText('{}','changed');'wrote'}}catch{{'denied'}}",literal(&witness)));
    assert_eq!(result.replace('\r', ""), "False\ndenied");
    assert_eq!(std::fs::read(&witness).unwrap(), b"unchanged");
    std::fs::remove_dir_all(root).unwrap();
}
#[test]
fn cleanup_rejects_root_and_ancestor_junctions_and_preserves_controls() {
    let protected = program_files().join(unique());
    install_security::prepare(&protected).unwrap();
    let target = protected.join("outside");
    std::fs::create_dir(&target).unwrap();
    let witness = target.join("witness.txt");
    std::fs::write(&witness, b"keep").unwrap();
    let user = std::env::temp_dir().join(unique());
    std::fs::create_dir(&user).unwrap();
    let link = user.join("junction");
    let script=format!("$ErrorActionPreference='Stop';New-Item -ItemType Junction -Path '{}' -Target '{}'|Out-Null",literal(&link),literal(&target));
    let status =
        std::process::Command::new(win::system_tool(r"WindowsPowerShell\v1.0\powershell.exe"))
            .args([
                "-NoProfile",
                "-NonInteractive",
                "-EncodedCommand",
                &encoded(&script),
            ])
            .status()
            .unwrap();
    assert!(status.success());
    assert_eq!(files::clear_dir(&link, 0).1, 0);
    assert!(witness.exists());
    let nested = target.join("nested");
    std::fs::create_dir(&nested).unwrap();
    std::fs::write(nested.join("kept.txt"), b"keep").unwrap();
    assert_eq!(files::clear_dir(&link.join("nested"), 0).1, 0);
    assert!(nested.join("kept.txt").exists());
    std::fs::remove_dir(&link).unwrap();
    std::fs::write(user.join("ordinary.tmp"), b"ordinary").unwrap();
    assert_eq!(files::clear_dir(&user, 0).1, 1);
    let system_cache = protected.join("system-cache");
    install_security::prepare(&system_cache).unwrap();
    std::fs::write(system_cache.join("ordinary.tmp"), b"ordinary").unwrap();
    assert_eq!(files::clear_dir(&system_cache, 0).1, 1);
    assert_eq!(std::fs::read(&witness).unwrap(), b"keep");
    std::fs::remove_dir_all(user).unwrap();
    std::fs::remove_dir_all(protected).unwrap();
}
#[test]
fn individual_cleanup_file_rejects_reparse_parent_and_deletes_user_file_safely() {
    let protected = program_files().join(unique());
    install_security::prepare(&protected).unwrap();
    let target = protected.join("witness.tmp");
    std::fs::write(&target, b"keep").unwrap();
    let user = std::env::temp_dir().join(unique());
    std::fs::create_dir(&user).unwrap();
    let link = user.join("junction");
    let script = format!(
        "$ErrorActionPreference='Stop';New-Item -ItemType Junction -Path '{}' -Target '{}'|Out-Null",
        literal(&link), literal(&protected)
    );
    let status = std::process::Command::new(win::system_tool(r"WindowsPowerShell\v1.0\powershell.exe"))
        .args(["-NoProfile", "-NonInteractive", "-EncodedCommand", &encoded(&script)])
        .status()
        .unwrap();
    assert!(status.success());
    assert!(files::remove_file(&link.join("witness.tmp")).is_none());
    assert_eq!(std::fs::read(&target).unwrap(), b"keep");
    let ordinary = user.join("ordinary.tmp");
    std::fs::write(&ordinary, b"remove").unwrap();
    assert_eq!(files::remove_file(&ordinary), Some(6));
    assert!(!ordinary.exists());
    std::fs::remove_dir(&link).unwrap();
    std::fs::remove_dir(user).unwrap();
    std::fs::remove_dir_all(protected).unwrap();
}
#[test]
fn trusted_journal_round_trip_and_unsigned_tool_rejected() {
    std::env::set_var("BAO_TEST", "1");
    let private = win::operation_data_dir().unwrap();
    assert!(install_security::trusted(&private));
    let id = journal::add(
        "fixture",
        "demo",
        "programs",
        serde_json::json!({"action":"list"}),
    );
    assert!(journal::load().iter().any(|e| e.id == id && !e.undone));
    journal::undo(id).unwrap();
    assert!(journal::load().iter().any(|e| e.id == id && e.undone));
    let dir = private.join("sysinternals");
    std::fs::create_dir_all(&dir).unwrap();
    let tool = dir.join("whois64.exe");
    std::fs::write(&tool, b"unsigned fixture").unwrap();
    assert!(ps::run(
        "sysint",
        &serde_json::json!({"action":"verify","files":["whois64.exe"]})
    )
    .is_err());
    assert!(!tool.exists());
    std::fs::copy(win::system_tool("cmd.exe"), &tool).unwrap();
    assert_eq!(
        ps::run(
            "sysint",
            &serde_json::json!({"action":"verify","files":["whois64.exe"]})
        )
        .unwrap()["ok"],
        true
    );
    std::fs::remove_file(tool).unwrap();
}
#[test]
fn hkcu_uninstaller_runs_without_administrative_authority() {
    let id = unique();
    let folder = std::env::temp_dir().join(&id);
    std::fs::create_dir(&folder).unwrap();
    let marker = folder.join("token.txt");
    let sub = format!(r"Software\Microsoft\Windows\CurrentVersion\Uninstall\{id}");
    let key = format!(r"HKEY_CURRENT_USER\{sub}");
    let mut h = std::ptr::null_mut();
    assert_eq!(
        unsafe {
            RegCreateKeyExW(
                HKEY_CURRENT_USER,
                win::w(&sub).as_ptr(),
                0,
                std::ptr::null(),
                0,
                KEY_ALL_ACCESS,
                std::ptr::null(),
                &mut h,
                std::ptr::null_mut(),
            )
        },
        0
    );
    struct Key {
        h: HKEY,
        path: String,
    }
    impl Drop for Key {
        fn drop(&mut self) {
            unsafe {
                RegCloseKey(self.h);
                RegDeleteTreeW(HKEY_CURRENT_USER, win::w(&self.path).as_ptr());
            }
        }
    }
    let guard = Key { h, path: sub };
    let script=format!("$p=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent());[IO.File]::WriteAllText('{}',[string]$p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))",literal(&marker));
    let command = format!(
        "\"{}\" -NoProfile -NonInteractive -EncodedCommand {}",
        win::system_tool(r"WindowsPowerShell\v1.0\powershell.exe").display(),
        encoded(&script)
    );
    for (name, value) in [
        ("DisplayName", "Security regression fixture".to_string()),
        ("UninstallString", command),
    ] {
        let value = win::w(&value);
        assert_eq!(
            unsafe {
                RegSetValueExW(
                    guard.h,
                    win::w(name).as_ptr(),
                    0,
                    REG_SZ,
                    value.as_ptr().cast(),
                    (value.len() * 2) as u32,
                )
            },
            0
        );
    }
    let result = ps::run(
        "programs",
        &serde_json::json!({"action":"uninstall","key":key}),
    )
    .unwrap();
    assert_eq!(result["ok"], true);
    assert!(result.get("undo").is_none());
    for _ in 0..100 {
        if marker.exists() {
            break;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    assert_eq!(std::fs::read_to_string(&marker).unwrap(), "False");
    drop(guard);
    std::fs::remove_dir_all(folder).unwrap();
}
