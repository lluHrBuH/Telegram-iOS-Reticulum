//! `telegram_reticulum_ffi`: the C ABI the Telegram-iOS Reticulum backend links.
//!
//! The bulk of the ABI is the two upstream crates' own universal C layers, which this
//! staticlib re-exports by linking them (`rns_*` from `reticulum_rust::cffi`, `lxmf_*` from
//! `lxmf_rust::cffi`, `rns_rnode_*` under the `rnode` feature, `rns_prns_ble_*` under
//! `prns-ble`). The `tgrns_*` functions below add what the app needs on top and nothing
//! else: arbitrary-typed LXMF fields (the upstream layer sets only strings and bools), a
//! snapshot of every interface for the settings screen, and a bounded wait for a path.
//!
//! Conventions follow upstream: opaque `u64` handles, `0`/`-1` for errors with the reason in
//! `rns_last_error()`, and bytes returned by this library are freed with `rns_free_bytes`.

use std::ffi::{c_char, c_void, CStr, CString};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use lxmf_rust::LXMessage;
use reticulum_rust::ffi::{get_handle, set_error};
use reticulum_rust::transport::Transport;

// Linking: a `staticlib` carries every upstream object, and the `#[no_mangle]` functions in
// these modules are kept because they are exported symbols. The `use`s make the dependency
// explicit so a feature that removes a module fails here rather than at the Swift link.
#[allow(unused_imports)]
use lxmf_rust::cffi as _lxmf_c_abi;
#[allow(unused_imports)]
use reticulum_rust::cffi as _rns_c_abi;
#[cfg(feature = "prns-ble")]
#[allow(unused_imports)]
use reticulum_rust::interfaces::prns_ble::cffi as _prns_c_abi;

pub const VERSION: &str = env!("CARGO_PKG_VERSION");

/// LXMF field ids this backend reads and writes (LXMF `LXMF.py` constants).
pub mod fields {
    pub const FILE_ATTACHMENTS: u8 = 0x05;
    pub const IMAGE: u8 = 0x06;
    pub const AUDIO: u8 = 0x07;
    pub const RENDERER: u8 = 0x0F;
    pub const REPLY_TO: u8 = 0x30;
    pub const REACTION: u8 = 0x40;
    pub const CUSTOM_TYPE: u8 = 0xFB;
    pub const CUSTOM_DATA: u8 = 0xFC;
    pub const CUSTOM_META: u8 = 0xFD;
}

fn with_message(handle: u64, f: impl FnOnce(&mut LXMessage)) -> i32 {
    let msg: Option<Arc<Mutex<LXMessage>>> = get_handle(handle);
    let Some(msg) = msg else {
        set_error("invalid message handle".to_string());
        return -1;
    };
    let result = match msg.lock() {
        Ok(mut guard) => {
            f(&mut guard);
            0
        }
        Err(e) => {
            set_error(e.to_string());
            -1
        }
    };
    result
}

unsafe fn slice<'a>(ptr: *const u8, len: u32) -> &'a [u8] {
    if ptr.is_null() || len == 0 {
        &[]
    } else {
        std::slice::from_raw_parts(ptr, len as usize)
    }
}

/// "tgrns <ffi version> / rns <Reticulum-rust version> / lxmf <LXMF-rust version>".
/// Free with `rns_free_string`.
#[no_mangle]
pub extern "C" fn tgrns_version() -> *mut c_char {
    let text = format!(
        "tgrns {} / rns {} / lxmf {}",
        VERSION,
        reticulum_rust::version(),
        lxmf_rust::version::VERSION
    );
    CString::new(text).unwrap_or_default().into_raw()
}

/// Set top-level LXMF field `key` of an outbound message to a msgpack binary value
/// (FIELD_CUSTOM_DATA, FIELD_REPLY_TO hashes, ...). Replaces an existing entry.
///
/// # Safety
/// `data` must point to `len` readable bytes (or be NULL with `len` 0, which stores empty bytes).
#[no_mangle]
pub unsafe extern "C" fn tgrns_message_set_field_bytes(msg: u64, key: u8, data: *const u8, len: u32) -> i32 {
    let value = rmpv::Value::Binary(slice(data, len).to_vec());
    with_message(msg, |m| m.set_field(key, value))
}

/// Set top-level LXMF field `key` to a msgpack string (FIELD_CUSTOM_TYPE, ...).
///
/// # Safety
/// `value` must be a NUL-terminated UTF-8 string.
#[no_mangle]
pub unsafe extern "C" fn tgrns_message_set_field_string(msg: u64, key: u8, value: *const c_char) -> i32 {
    if value.is_null() {
        set_error("value is NULL".to_string());
        return -1;
    }
    let text = match CStr::from_ptr(value).to_str() {
        Ok(v) => v.to_string(),
        Err(_) => {
            set_error("value is not UTF-8".to_string());
            return -1;
        }
    };
    with_message(msg, |m| m.set_field(key, rmpv::Value::String(text.into())))
}

/// Set top-level LXMF field `key` to a msgpack unsigned integer (FIELD_RENDERER, ...).
#[no_mangle]
pub extern "C" fn tgrns_message_set_field_u64(msg: u64, key: u8, value: u64) -> i32 {
    with_message(msg, |m| m.set_field(key, rmpv::Value::Integer(value.into())))
}

/// Set top-level LXMF field `key` to a raw msgpack value (already encoded), for the structured
/// fields (FIELD_IMAGE `[type, bytes]`, FIELD_FILE_ATTACHMENTS `[[name, bytes], ...]`, ...).
///
/// # Safety
/// `data` must point to `len` readable bytes holding exactly one msgpack value.
#[no_mangle]
pub unsafe extern "C" fn tgrns_message_set_field_msgpack(msg: u64, key: u8, data: *const u8, len: u32) -> i32 {
    let mut bytes = slice(data, len);
    let value = match rmpv::decode::read_value(&mut bytes) {
        Ok(v) => v,
        Err(e) => {
            set_error(format!("field {key:#x}: not a msgpack value: {e}"));
            return -1;
        }
    };
    if !bytes.is_empty() {
        set_error(format!("field {key:#x}: {} trailing bytes after the msgpack value", bytes.len()));
        return -1;
    }
    with_message(msg, |m| m.set_field(key, value))
}

/// Remove top-level LXMF field `key` from an outbound message.
#[no_mangle]
pub extern "C" fn tgrns_message_remove_field(msg: u64, key: u8) -> i32 {
    with_message(msg, |m| m.remove_field(key))
}

/// Set the message content to arbitrary bytes (the C `lxmf_message_new` takes a C string, so
/// content with NUL bytes or a non-UTF-8 payload goes through here).
///
/// # Safety
/// `data` must point to `len` readable bytes.
#[no_mangle]
pub unsafe extern "C" fn tgrns_message_set_content_bytes(msg: u64, data: *const u8, len: u32) -> i32 {
    let bytes = slice(data, len).to_vec();
    with_message(msg, |m| m.content = bytes)
}

/// One interface of the running transport, for the settings screen.
#[repr(C)]
pub struct TgrnsInterfaceStatus {
    /// NUL-terminated interface name (the config section name), truncated to fit.
    pub name: [c_char; 128],
    pub online: u8,
    pub bitrate_set: u8,
    pub bitrate: f64,
    pub rx_bytes: u64,
    pub tx_bytes: u64,
    pub rssi_set: u8,
    pub rssi: f64,
    pub snr_set: u8,
    pub snr: f64,
}

/// The number of interfaces Transport knows (configured TCP/UDP ones and registered radios).
#[no_mangle]
pub extern "C" fn tgrns_interface_count() -> u32 {
    Transport::get_interface_list().len() as u32
}

/// Fill `out` with interface `index` (0-based, see `tgrns_interface_count`). Returns 0, or -1
/// when `index` is out of range (the list may have changed since it was counted).
///
/// # Safety
/// `out` must point to a writable `TgrnsInterfaceStatus`.
#[no_mangle]
pub unsafe extern "C" fn tgrns_interface_at(index: u32, out: *mut TgrnsInterfaceStatus) -> i32 {
    if out.is_null() {
        set_error("out is NULL".to_string());
        return -1;
    }
    let list = Transport::get_interface_list();
    let Some(iface) = list.get(index as usize) else {
        set_error(format!("no interface at index {index}"));
        return -1;
    };
    let status = &mut *out;
    status.name = [0; 128];
    for (slot, byte) in status.name.iter_mut().zip(iface.name.bytes().take(127)) {
        *slot = byte as c_char;
    }
    status.online = iface.online as u8;
    status.bitrate_set = iface.bitrate.is_some() as u8;
    status.bitrate = iface.bitrate.unwrap_or(0.0);
    status.rx_bytes = iface.rxb;
    status.tx_bytes = iface.txb;
    status.rssi_set = iface.r_stat_rssi.is_some() as u8;
    status.rssi = iface.r_stat_rssi.unwrap_or(0.0);
    status.snr_set = iface.r_stat_snr.is_some() as u8;
    status.snr = iface.r_stat_snr.unwrap_or(0.0);
    0
}

/// Whether any interface is online (the backend's "network available").
#[no_mangle]
pub extern "C" fn tgrns_any_interface_online() -> i32 {
    Transport::get_interface_list().iter().any(|i| i.online) as i32
}

/// Request a path to `dest_hash` if none is known and wait up to `budget_secs` for one.
/// Returns 1 when a path is known when it returns, 0 otherwise, -1 on a bad argument.
///
/// # Safety
/// `dest_hash` must point to `len` readable bytes (16 for a destination hash).
#[no_mangle]
pub unsafe extern "C" fn tgrns_transport_wait_for_path(dest_hash: *const u8, len: u32, budget_secs: f64) -> i32 {
    let hash = slice(dest_hash, len).to_vec();
    if hash.len() != 16 {
        set_error(format!("destination hash is {} bytes, not 16", hash.len()));
        return -1;
    }
    if reticulum_rust::ffi::transport_has_path(&hash) {
        return 1;
    }
    if let Err(e) = reticulum_rust::ffi::transport_request_path(&hash) {
        set_error(e);
        return 0;
    }
    let deadline = Instant::now() + Duration::from_secs_f64(budget_secs.max(0.0));
    while Instant::now() < deadline {
        if reticulum_rust::ffi::transport_has_path(&hash) {
            return 1;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    reticulum_rust::ffi::transport_has_path(&hash) as i32
}

/// Route the library's log lines to `callback` (one NUL-terminated line per call, valid only
/// during the call) instead of stderr. `context` is passed back unchanged.
#[no_mangle]
pub extern "C" fn tgrns_set_log_callback(
    callback: Option<extern "C" fn(context: *mut c_void, line: *const c_char)>,
    context: *mut c_void,
) {
    struct SendPtr(usize);
    let ctx = SendPtr(context as usize);
    match callback {
        Some(cb) => reticulum_rust::ffi::set_log_callback(move |line: String| {
            if let Ok(text) = CString::new(line) {
                cb(ctx.0 as *mut c_void, text.as_ptr());
            }
        }),
        None => reticulum_rust::ffi::set_log_callback(|line: String| eprintln!("{line}")),
    }
}
