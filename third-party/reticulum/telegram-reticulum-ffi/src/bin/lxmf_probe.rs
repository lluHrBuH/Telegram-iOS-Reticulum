//! End-to-end probe: connect to a public Reticulum TCP node, resolve a path to an LXMF address
//! and deliver one text message, printing every state change. Run it on a machine with raw TCP
//! egress (the cloud container only has an HTTPS proxy):
//!
//!   cargo run --features prns-ble --bin lxmf_probe -- \
//!       --to 91a664e798f1bee3ed0e9dec7c1d7c9f --text "hello from Telegram-Reticulum" \
//!       [--node rmap.world:4242] [--dir /tmp/lxmf_probe] [--method direct|opportunistic|propagated] \
//!       [--listen <secs>]
//!
//! `--listen` keeps the probe alive after sending to print replies (its own address is printed
//! as `OWN <hex>` so the other side can answer).

use std::ffi::{c_char, c_void, CStr, CString};
use std::io::Write;
use std::sync::atomic::{AtomicU8, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use lxmf_rust::cffi::*;
use reticulum_rust::cffi::*;
use telegram_reticulum_ffi::*;

fn last_error() -> String {
    let p = rns_last_error();
    if p.is_null() {
        return String::new();
    }
    let s = unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned();
    rns_free_string(p);
    s
}

fn hex_decode(s: &str) -> Vec<u8> {
    (0..s.len()).step_by(2).map(|i| u8::from_str_radix(&s[i..i + 2], 16).expect("hex")).collect()
}

fn hex_encode(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

extern "C" fn on_state(context: *mut c_void, _hash: *const u8, _len: u32, state: u8) {
    let flag = unsafe { &*(context as *const AtomicU8) };
    let name = match state {
        0x02 => "SENDING",
        0x04 => "SENT",
        0x08 => "DELIVERED",
        0xFD => "REJECTED",
        0xFE => "CANCELLED",
        0xFF => "FAILED",
        _ => "?",
    };
    println!("STATE {state:#04x} {name}");
    let _ = std::io::stdout().flush();
    flag.store(state, Ordering::SeqCst);
}

extern "C" fn on_delivery(
    _context: *mut c_void,
    _hash: *const u8,
    _hash_len: u32,
    src_hash: *const u8,
    src_len: u32,
    _dest_hash: *const u8,
    _dest_len: u32,
    _title: *const c_char,
    content: *const c_char,
    _timestamp: f64,
    signature_valid: i32,
    _unverified_reason: i32,
    _fields_raw: *const u8,
    _fields_len: u32,
) {
    let src = unsafe { std::slice::from_raw_parts(src_hash, src_len as usize) };
    let content = unsafe { CStr::from_ptr(content) }.to_string_lossy();
    println!("RECV from {} (signature {}): {}", hex_encode(src), if signature_valid != 0 { "valid" } else { "UNVERIFIED" }, content);
    let _ = std::io::stdout().flush();
}

extern "C" fn on_announce(_context: *mut c_void, dest_hash: *const u8, dest_len: u32, display_name: *const c_char) {
    let dest = unsafe { std::slice::from_raw_parts(dest_hash, dest_len as usize) };
    let name = if display_name.is_null() { String::new() } else { unsafe { CStr::from_ptr(display_name) }.to_string_lossy().into_owned() };
    println!("ANNOUNCE {} {}", hex_encode(dest), name);
    let _ = std::io::stdout().flush();
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let mut node = "rmap.world:4242".to_string();
    let mut dir = "/tmp/lxmf_probe".to_string();
    let mut to = String::new();
    let mut text = "hello from Telegram-Reticulum".to_string();
    let mut method: u8 = 2;
    let mut listen = 0u64;
    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--node" => { node = args[i + 1].clone(); i += 2; }
            "--dir" => { dir = args[i + 1].clone(); i += 2; }
            "--to" => { to = args[i + 1].clone(); i += 2; }
            "--text" => { text = args[i + 1].clone(); i += 2; }
            "--listen" => { listen = args[i + 1].parse().expect("secs"); i += 2; }
            "--method" => {
                method = match args[i + 1].as_str() { "opportunistic" => 1, "direct" => 2, "propagated" => 3, m => panic!("unknown method {m}") };
                i += 2;
            }
            other => panic!("unknown argument {other}"),
        }
    }
    let (host, port) = node.split_once(':').expect("--node host:port");
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(
        format!("{dir}/config"),
        format!(
            "[reticulum]\n  enable_transport = false\n  share_instance = false\n  panic_on_interface_errors = false\n\n[logging]\n  loglevel = 4\n\n[interfaces]\n  [[Node]]\n    type = TCPClientInterface\n    enabled = yes\n    target_host = {host}\n    target_port = {port}\n"
        ),
    )
    .unwrap();

    let c_dir = CString::new(dir.clone()).unwrap();
    let c_storage = CString::new(format!("{dir}/lxmf_storage")).unwrap();
    let c_identity = CString::new(format!("{dir}/identity")).unwrap();
    let c_name = CString::new("Telegram-Reticulum probe").unwrap();
    let client = lxmf_client_start(c_dir.as_ptr(), c_storage.as_ptr(), c_identity.as_ptr(), 1, c_name.as_ptr(), 4, -1);
    assert!(client != 0, "lxmf_client_start failed: {}", last_error());
    let state = Arc::new(AtomicU8::new(0));
    assert_eq!(lxmf_client_set_message_state_callback(client, on_state, Arc::as_ptr(&state) as *mut c_void), 0);
    assert_eq!(lxmf_client_set_delivery_callback(client, on_delivery, std::ptr::null_mut()), 0);
    assert_eq!(lxmf_client_set_announce_callback(client, on_announce, std::ptr::null_mut()), 0);
    let announce_name = CString::new("Telegram-Reticulum probe").unwrap();
    let _ = lxmf_client_set_announce_display_name(client, announce_name.as_ptr());

    let mut own = [0u8; 16];
    assert_eq!(lxmf_client_dest_hash(client, own.as_mut_ptr(), 16), 16);
    println!("OWN {}", hex_encode(&own));

    let iface = CString::new("Node").unwrap();
    let start = Instant::now();
    while rns_interface_online(iface.as_ptr()) != 1 {
        if start.elapsed() > Duration::from_secs(30) {
            panic!("the TCP interface to {node} did not come online in 30 s");
        }
        std::thread::sleep(Duration::from_millis(200));
    }
    println!("ONLINE {node} after {:.1} s", start.elapsed().as_secs_f64());
    let _ = lxmf_client_announce(client);

    if !to.is_empty() {
        let dest = hex_decode(&to);
        assert_eq!(dest.len(), 16, "--to must be 32 hex characters");
        print!("PATH requesting ... ");
        let _ = std::io::stdout().flush();
        let found = unsafe { tgrns_transport_wait_for_path(dest.as_ptr(), 16, 60.0) };
        println!("{}", if found == 1 { "known" } else { "not found in 60 s (sending anyway; direct delivery will fail without a path)" });

        let c_text = CString::new(text.clone()).unwrap();
        let c_title = CString::new("").unwrap();
        let msg = lxmf_message_new(client, dest.as_ptr(), 16, c_text.as_ptr(), c_title.as_ptr(), method);
        assert!(msg != 0, "lxmf_message_new failed: {}", last_error());
        let c_type = CString::new("org.telegram.reticulum/probe").unwrap();
        unsafe { tgrns_message_set_field_string(msg, TGRNS_FIELD_CUSTOM_TYPE as u8, c_type.as_ptr()) };
        assert_eq!(lxmf_message_send(client, msg), 0, "lxmf_message_send failed: {}", last_error());
        println!("SENT request to {to} (method {method})");
        let deadline = Instant::now() + Duration::from_secs(120);
        while Instant::now() < deadline {
            match state.load(Ordering::SeqCst) {
                0x04 | 0x08 => break,
                0xFD | 0xFE | 0xFF => { eprintln!("delivery failed"); std::process::exit(1) }
                _ => std::thread::sleep(Duration::from_millis(200)),
            }
        }
    }
    if listen > 0 {
        println!("LISTENING {listen} s for replies to {}", hex_encode(&own));
        std::thread::sleep(Duration::from_secs(listen));
    }
    let _ = lxmf_client_shutdown(client);
}

#[allow(dead_code)]
const TGRNS_FIELD_CUSTOM_TYPE: u32 = 0xFB;
