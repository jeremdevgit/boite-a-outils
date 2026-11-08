#![cfg(windows)]
#![allow(dead_code)]
mod win {
    pub fn w(s: &str) -> Vec<u16> {
        s.encode_utf16().chain(Some(0)).collect()
    }
    pub fn memory() -> (u64, u64) {
        (0, 0)
    }
}
#[path = "../../src/live.rs"]
mod live;
