#![allow(dead_code)]
#[path = "../../src/install_security.rs"]
mod install_security;
#[cfg(windows)]
#[path = "../../src/user_context.rs"]
mod user_context;
#[cfg(windows)]
#[path = "../../src/win.rs"]
mod win;
#[cfg(windows)]
#[path = "../../src/files.rs"]
mod files;
#[cfg(windows)]
#[path = "../../src/ps.rs"]
mod ps;
#[cfg(windows)]
#[path = "../../src/journal.rs"]
mod journal;
#[cfg(windows)]
#[path = "../../src/winget.rs"]
mod winget;
#[cfg(all(test, windows))]
mod regression;
