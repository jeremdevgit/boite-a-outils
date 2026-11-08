// SPDX-License-Identifier: GPL-3.0-or-later — Copyright (C) 2026 jeremdevgit
//! Restricted user authority for operations whose inputs belong to the user.
//! There is deliberately no fallback to the elevated token on failure.
use std::io::{self, Read};
use std::os::windows::ffi::OsStrExt;
use std::os::windows::io::{AsRawHandle, FromRawHandle, OwnedHandle};
use std::path::Path;
use std::time::{Duration, Instant};
use windows_sys::Win32::Foundation::*;
use windows_sys::Win32::Security::AppLocker::*;
use windows_sys::Win32::Security::Authorization::{ConvertSidToStringSidW, ConvertStringSidToSidW};
use windows_sys::Win32::Security::*;
use windows_sys::Win32::Storage::FileSystem::*;
use windows_sys::Win32::System::Pipes::{CreatePipe, PeekNamedPipe};
use windows_sys::Win32::System::Threading::*;
use windows_sys::Win32::UI::Shell::IsUserAnAdmin;

fn wide(s: &std::ffi::OsStr) -> Vec<u16> {
    s.encode_wide().chain(Some(0)).collect()
}
fn failed() -> io::Error {
    io::Error::last_os_error()
}
unsafe fn owned(h: HANDLE) -> io::Result<OwnedHandle> {
    if h.is_null() || h == INVALID_HANDLE_VALUE {
        Err(failed())
    } else {
        Ok(OwnedHandle::from_raw_handle(h))
    }
}
fn token_buffer(token: HANDLE, class: TOKEN_INFORMATION_CLASS) -> io::Result<Vec<usize>> {
    let mut n = 0;
    unsafe {
        GetTokenInformation(token, class, std::ptr::null_mut(), 0, &mut n);
    }
    if n == 0 {
        return Err(failed());
    }
    let mut buf = vec![0usize; (n as usize).div_ceil(std::mem::size_of::<usize>())];
    if unsafe { GetTokenInformation(token, class, buf.as_mut_ptr().cast(), n, &mut n) } == 0 {
        return Err(failed());
    }
    Ok(buf)
}
unsafe fn sid_text(sid: PSID) -> io::Result<String> {
    if sid.is_null() || IsValidSid(sid) == 0 {
        return Err(io::Error::other("invalid user identity"));
    }
    let mut p = std::ptr::null_mut();
    if ConvertSidToStringSidW(sid, &mut p) == 0 {
        return Err(failed());
    }
    let mut n = 0;
    while *p.add(n) != 0 {
        n += 1;
    }
    let text = String::from_utf16_lossy(std::slice::from_raw_parts(p, n));
    LocalFree(p.cast());
    Ok(text)
}
pub fn current_user_sid() -> io::Result<String> {
    let mut h = std::ptr::null_mut();
    if unsafe { OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut h) } == 0 {
        return Err(failed());
    }
    let token = unsafe { owned(h)? };
    let buf = token_buffer(token.as_raw_handle(), TokenUser)?;
    unsafe { sid_text((*buf.as_ptr().cast::<TOKEN_USER>()).User.Sid) }
}
fn restricted_token() -> io::Result<OwnedHandle> {
    // Do not pretend that filtering a service/SYSTEM identity makes it a user.
    let sid = current_user_sid()?;
    if !sid.starts_with("S-1-5-21-") && !sid.starts_with("S-1-12-1-") {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "interactive user token unavailable",
        ));
    }
    let mut level = SAFER_LEVEL_HANDLE::default();
    if unsafe {
        SaferCreateLevel(
            SAFER_SCOPEID_USER,
            SAFER_LEVELID_NORMALUSER,
            SAFER_LEVEL_OPEN,
            &mut level,
            std::ptr::null(),
        )
    } == 0
    {
        return Err(failed());
    }
    let mut raw = std::ptr::null_mut();
    let ok = unsafe {
        SaferComputeTokenFromLevel(
            level,
            std::ptr::null_mut(),
            &mut raw,
            0,
            std::ptr::null_mut(),
        )
    };
    let error = failed();
    unsafe {
        SaferCloseLevel(level);
    }
    if ok == 0 {
        return Err(error);
    }
    let token = unsafe { owned(raw)? };
    // Independently ensure Administrators is not an enabled allow SID.
    let buf = token_buffer(token.as_raw_handle(), TokenGroups)?;
    let groups = buf.as_ptr().cast::<TOKEN_GROUPS>();
    let count = unsafe { (*groups).GroupCount as usize };
    let offset = std::mem::offset_of!(TOKEN_GROUPS, Groups);
    if count
        > (buf.len() * std::mem::size_of::<usize>() - offset)
            / std::mem::size_of::<SID_AND_ATTRIBUTES>()
    {
        return Err(io::Error::other("invalid token groups"));
    }
    let first = unsafe { std::ptr::addr_of!((*groups).Groups).cast::<SID_AND_ATTRIBUTES>() };
    for i in 0..count {
        let group = unsafe { *first.add(i) };
        if group.Attributes & 0x4 /* SE_GROUP_ENABLED */ != 0
            && group.Attributes & 0x10 /* SE_GROUP_USE_FOR_DENY_ONLY */ == 0
            && unsafe { sid_text(group.Sid)? } == "S-1-5-32-544"
        {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "administrative token refused",
            ));
        }
    }
    let mut integrity = std::ptr::null_mut();
    if unsafe {
        ConvertStringSidToSidW(
            wide(std::ffi::OsStr::new("S-1-16-8192")).as_ptr(),
            &mut integrity,
        )
    } == 0
    {
        return Err(failed());
    }
    let label = TOKEN_MANDATORY_LABEL {
        Label: SID_AND_ATTRIBUTES {
            Sid: integrity,
            Attributes: 0x20, /* SE_GROUP_INTEGRITY */
        },
    };
    let ok = unsafe {
        SetTokenInformation(
            token.as_raw_handle(),
            TokenIntegrityLevel,
            (&label as *const TOKEN_MANDATORY_LABEL).cast(),
            (std::mem::size_of::<TOKEN_MANDATORY_LABEL>() + GetLengthSid(integrity) as usize)
                as u32,
        )
    };
    let error = failed();
    unsafe {
        LocalFree(integrity);
    }
    if ok == 0 {
        return Err(error);
    }
    Ok(token)
}
struct Impersonation;
impl Drop for Impersonation {
    fn drop(&mut self) {
        // Continuing with an unexpected thread identity is not safe.
        if unsafe { RevertToSelf() } == 0 {
            std::process::abort();
        }
    }
}
pub fn as_standard_user<T>(operation: impl FnOnce() -> T) -> io::Result<T> {
    if unsafe { IsUserAnAdmin() } == 0 {
        return Ok(operation());
    }
    let token = restricted_token()?;
    if unsafe { ImpersonateLoggedOnUser(token.as_raw_handle()) } == 0 {
        return Err(failed());
    }
    let _restore = Impersonation;
    if unsafe { IsUserAnAdmin() } != 0 {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "administrative impersonation refused",
        ));
    }
    Ok(operation())
}
fn quote(s: &str) -> io::Result<String> {
    if s.contains('\0') {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "NUL in argument",
        ));
    }
    let mut out = String::from("\"");
    let mut slashes = 0;
    for c in s.chars() {
        if c == '\\' {
            slashes += 1;
            continue;
        }
        out.extend(std::iter::repeat_n(
            '\\',
            slashes * if c == '"' { 2 } else { 1 },
        ));
        if c == '"' {
            out.push('\\');
        }
        out.push(c);
        slashes = 0;
    }
    out.extend(std::iter::repeat_n('\\', slashes * 2));
    out.push('"');
    Ok(out)
}
fn pipe() -> io::Result<(OwnedHandle, OwnedHandle)> {
    let mut read = std::ptr::null_mut();
    let mut write = std::ptr::null_mut();
    let sa = SECURITY_ATTRIBUTES {
        nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32,
        lpSecurityDescriptor: std::ptr::null_mut(),
        bInheritHandle: 1,
    };
    if unsafe { CreatePipe(&mut read, &mut write, &sa, 0) } == 0 {
        return Err(failed());
    }
    let read = unsafe { owned(read)? };
    let write = unsafe { owned(write)? };
    if unsafe { SetHandleInformation(read.as_raw_handle(), HANDLE_FLAG_INHERIT, 0) } == 0 {
        return Err(failed());
    }
    Ok((read, write))
}
fn drain_available(file: &mut std::fs::File, result: &mut Vec<u8>) {
    let mut buf = [0u8; 8192];
    for _ in 0..32 {
        let mut available = 0;
        if unsafe {
            PeekNamedPipe(
                file.as_raw_handle(),
                std::ptr::null_mut(),
                0,
                std::ptr::null_mut(),
                &mut available,
                std::ptr::null_mut(),
            )
        } == 0
            || available == 0
        {
            break;
        }
        let take = (available as usize).min(buf.len());
        let Ok(n) = file.read(&mut buf[..take]) else {
            break;
        };
        if n == 0 {
            break;
        }
        result.extend_from_slice(&buf[..n]);
        if result.len() > 8 * 1024 * 1024 {
            result.drain(..result.len() - 8 * 1024 * 1024);
        }
    }
}
pub struct Output {
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
}
/// Spawn with an explicit restricted primary token; thread impersonation alone
/// does not lower a CreateProcess child's primary token.
pub fn output(
    exe: &Path,
    args: &[&str],
    env: &[(&str, String)],
    timeout: Duration,
) -> io::Result<Output> {
    if !exe.is_absolute() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "absolute executable required",
        ));
    }
    let token = restricted_token()?;
    let (out_read, out_write) = pipe()?;
    let (err_read, err_write) = pipe()?;
    let sa = SECURITY_ATTRIBUTES {
        nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32,
        lpSecurityDescriptor: std::ptr::null_mut(),
        bInheritHandle: 1,
    };
    let input = unsafe {
        owned(CreateFileW(
            wide(std::ffi::OsStr::new("NUL")).as_ptr(),
            GENERIC_READ,
            FILE_SHARE_READ | FILE_SHARE_WRITE,
            &sa,
            OPEN_EXISTING,
            FILE_ATTRIBUTE_NORMAL,
            std::ptr::null_mut(),
        ))?
    };
    let handles = [
        input.as_raw_handle(),
        out_write.as_raw_handle(),
        err_write.as_raw_handle(),
    ];
    let mut attribute_size = 0;
    unsafe {
        InitializeProcThreadAttributeList(std::ptr::null_mut(), 1, 0, &mut attribute_size);
    }
    if attribute_size == 0 {
        return Err(failed());
    }
    let mut attributes = vec![0usize; attribute_size.div_ceil(std::mem::size_of::<usize>())];
    let list = attributes.as_mut_ptr().cast();
    if unsafe { InitializeProcThreadAttributeList(list, 1, 0, &mut attribute_size) } == 0 {
        return Err(failed());
    }
    struct AttributeList(LPPROC_THREAD_ATTRIBUTE_LIST);
    impl Drop for AttributeList {
        fn drop(&mut self) {
            unsafe {
                DeleteProcThreadAttributeList(self.0);
            }
        }
    }
    let _attributes = AttributeList(list);
    if unsafe {
        UpdateProcThreadAttribute(
            list,
            0,
            PROC_THREAD_ATTRIBUTE_HANDLE_LIST as usize,
            handles.as_ptr().cast(),
            std::mem::size_of_val(&handles),
            std::ptr::null_mut(),
            std::ptr::null(),
        )
    } == 0
    {
        return Err(failed());
    }
    let mut startup: STARTUPINFOEXW = unsafe { std::mem::zeroed() };
    startup.StartupInfo.cb = std::mem::size_of::<STARTUPINFOEXW>() as u32;
    startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
    startup.StartupInfo.hStdInput = input.as_raw_handle();
    startup.StartupInfo.hStdOutput = out_write.as_raw_handle();
    startup.StartupInfo.hStdError = err_write.as_raw_handle();
    startup.lpAttributeList = list;
    let mut desktop = wide(std::ffi::OsStr::new("winsta0\\default"));
    startup.StartupInfo.lpDesktop = desktop.as_mut_ptr();
    let mut command = quote(&exe.to_string_lossy())?;
    for arg in args {
        command.push(' ');
        command.push_str(&quote(arg)?);
    }
    let mut command = wide(std::ffi::OsStr::new(&command));
    let mut environment: Vec<_> = std::env::vars_os().collect();
    for (key, value) in env {
        environment.retain(|(k, _)| !k.to_string_lossy().eq_ignore_ascii_case(key));
        environment.push((
            std::ffi::OsString::from(*key),
            std::ffi::OsString::from(value.as_str()),
        ));
    }
    environment.sort_by_key(|(k, _)| k.to_string_lossy().to_lowercase());
    let mut block = Vec::new();
    for (key, value) in environment {
        block.extend(key.encode_wide());
        block.push(b'=' as u16);
        block.extend(value.encode_wide());
        block.push(0);
    }
    block.push(0);
    let mut process: PROCESS_INFORMATION = unsafe { std::mem::zeroed() };
    let cwd = exe
        .parent()
        .ok_or_else(|| io::Error::other("no executable directory"))?;
    if unsafe {
        CreateProcessAsUserW(
            token.as_raw_handle(),
            wide(exe.as_os_str()).as_ptr(),
            command.as_mut_ptr(),
            std::ptr::null(),
            std::ptr::null(),
            1,
            CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT | EXTENDED_STARTUPINFO_PRESENT,
            block.as_ptr().cast(),
            wide(cwd.as_os_str()).as_ptr(),
            &startup.StartupInfo,
            &mut process,
        )
    } == 0
    {
        return Err(failed());
    }
    let process_handle = unsafe { owned(process.hProcess)? };
    let _thread = unsafe { owned(process.hThread)? };
    drop(out_write);
    drop(err_write);
    drop(input);
    let mut out = std::fs::File::from(out_read);
    let mut err = std::fs::File::from(err_read);
    let mut stdout = Vec::new();
    let mut stderr = Vec::new();
    let start = Instant::now();
    loop {
        drain_available(&mut out, &mut stdout);
        drain_available(&mut err, &mut stderr);
        let status = unsafe { WaitForSingleObject(process_handle.as_raw_handle(), 50) };
        if status == WAIT_OBJECT_0 {
            drain_available(&mut out, &mut stdout);
            drain_available(&mut err, &mut stderr);
            break;
        }
        if status == WAIT_FAILED || start.elapsed() > timeout {
            unsafe {
                TerminateProcess(process_handle.as_raw_handle(), 1);
                WaitForSingleObject(process_handle.as_raw_handle(), 5000);
            }
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "user operation timed out",
            ));
        }
    }
    Ok(Output { stdout, stderr })
}
