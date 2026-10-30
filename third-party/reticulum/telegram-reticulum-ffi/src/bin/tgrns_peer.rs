//! A second Reticulum peer for tests (the transport is a process singleton, so a test that
//! needs two nodes runs this binary as the other one).
//!
//! Listens on a TCPServerInterface, announces its LXMF delivery destination, prints
//! `DEST <hex>` once and `RECV <hex source> <content>` for every delivered message, and answers
//! each message with one that echoes the content and the Telegram custom fields (0xFB, 0xFC).
//!
//! Usage: tgrns_peer --dir <config dir> --port <listen port> [--announce-every <secs>]

use std::ffi::{c_char, c_void, CStr, CString};
use std::io::Write;
use std::sync::mpsc::{channel, Sender};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use lxmf_rust::cffi::*;
use reticulum_rust::cffi::*;
use telegram_reticulum_ffi::*;

/// The delivery callback runs on the router's own thread while the router is busy, so it must not
/// call back into the library (`lxmf_message_new` + `lxmf_message_send` from inside it deadlock,
/// measured 2026-10-30). It hands the echo to the main loop through a channel instead; the Swift
/// side follows the same rule and dispatches every callback onto its own queue.
struct Shared {
    echoes: Sender<(Vec<u8>, String, Vec<u8>)>,
}

extern "C" fn on_delivery(
    context: *mut c_void,
    _hash: *const u8,
    _hash_len: u32,
    src_hash: *const u8,
    src_len: u32,
    _dest_hash: *const u8,
    _dest_len: u32,
    _title: *const c_char,
    content: *const c_char,
    _timestamp: f64,
    _signature_valid: i32,
    _unverified_reason: i32,
    fields_raw: *const u8,
    fields_len: u32,
) {
    let shared = unsafe { &*(context as *const Mutex<Shared>) };
    let src = unsafe { std::slice::from_raw_parts(src_hash, src_len as usize) }.to_vec();
    let content = unsafe { CStr::from_ptr(content) }.to_string_lossy().into_owned();
    let fields = unsafe { std::slice::from_raw_parts(fields_raw, fields_len as usize) }.to_vec();
    println!("RECV {} {}", hex_encode(&src), content);
    let _ = std::io::stdout().flush();

    let _ = shared.lock().unwrap().echoes.send((src, content, fields));
}

/// Echo: same content, and the custom fields copied over so the sender can verify the round
/// trip. Fields come back as one msgpack map; copy 0xFB and 0xFC if present.
fn send_echo(client: u64, src: &[u8], content: &str, fields: &[u8]) {
    let reply = format!("echo: {content}");
    let c_reply = CString::new(reply).unwrap();
    let title = CString::new("").unwrap();
    let msg = lxmf_message_new(client, src.as_ptr(), src.len() as u32, c_reply.as_ptr(), title.as_ptr(), 2);
    if msg == 0 {
        eprintln!("peer: lxmf_message_new failed: {}", last_error());
        return;
    }
    if let Ok(rmpv::Value::Map(entries)) = rmpv::decode::read_value(&mut &fields[..]) {
        for (key, value) in entries {
            let Some(key) = key.as_u64() else { continue };
            match (key as u8, value) {
                (0xFB, rmpv::Value::String(s)) => {
                    let c = CString::new(s.into_str().unwrap_or_default()).unwrap();
                    unsafe { tgrns_message_set_field_string(msg, 0xFB, c.as_ptr()) };
                }
                (0xFC, rmpv::Value::Binary(b)) => unsafe {
                    tgrns_message_set_field_bytes(msg, 0xFC, b.as_ptr(), b.len() as u32);
                },
                _ => {}
            }
        }
    }
    if lxmf_message_send(client, msg) != 0 {
        eprintln!("peer: lxmf_message_send failed: {}", last_error());
    }
}

fn last_error() -> String {
    let p = rns_last_error();
    if p.is_null() {
        return String::new();
    }
    let s = unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned();
    rns_free_string(p);
    s
}

fn hex_encode(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let mut dir = String::new();
    let mut port: u16 = 0;
    let mut announce_every = 2.0f64;
    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--dir" => { dir = args[i + 1].clone(); i += 2; }
            "--port" => { port = args[i + 1].parse().expect("port"); i += 2; }
            "--announce-every" => { announce_every = args[i + 1].parse().expect("secs"); i += 2; }
            other => panic!("unknown argument {other}"),
        }
    }
    assert!(!dir.is_empty() && port != 0, "usage: tgrns_peer --dir <dir> --port <port>");
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(
        format!("{dir}/config"),
        format!(
            "[reticulum]\n  enable_transport = false\n  share_instance = false\n  panic_on_interface_errors = false\n\n[logging]\n  loglevel = 3\n\n[interfaces]\n  [[Server]]\n    type = TCPServerInterface\n    enabled = yes\n    listen_ip = 127.0.0.1\n    listen_port = {port}\n"
        ),
    )
    .unwrap();

    let c_dir = CString::new(dir.clone()).unwrap();
    let c_storage = CString::new(format!("{dir}/lxmf_storage")).unwrap();
    let c_identity = CString::new(format!("{dir}/identity")).unwrap();
    let c_name = CString::new("tgrns peer").unwrap();
    let client = lxmf_client_start(c_dir.as_ptr(), c_storage.as_ptr(), c_identity.as_ptr(), 1, c_name.as_ptr(), 3, -1);
    assert!(client != 0, "lxmf_client_start failed: {}", last_error());

    let (echoes, pending) = channel();
    let shared: Arc<Mutex<Shared>> = Arc::new(Mutex::new(Shared { echoes }));
    let ctx = Arc::as_ptr(&shared) as *mut c_void;
    assert_eq!(lxmf_client_set_delivery_callback(client, on_delivery, ctx), 0);

    let mut dest = [0u8; 16];
    assert_eq!(lxmf_client_dest_hash(client, dest.as_mut_ptr(), 16), 16, "{}", last_error());
    println!("DEST {}", hex_encode(&dest));
    let _ = std::io::stdout().flush();

    let mut last_announce = std::time::Instant::now() - Duration::from_secs(3600);
    loop {
        if last_announce.elapsed().as_secs_f64() >= announce_every {
            let _ = lxmf_client_announce(client);
            last_announce = std::time::Instant::now();
        }
        if let Ok((src, content, fields)) = pending.recv_timeout(Duration::from_millis(100)) {
            send_echo(client, &src, &content, &fields);
        }
    }
}
