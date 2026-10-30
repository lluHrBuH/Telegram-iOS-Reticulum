//! Two-process loopback: `tgrns_peer` listens on a TCPServerInterface, this process connects with
//! a TCPClientInterface, resolves the peer's LXMF destination from its announce, sends a message
//! carrying the Telegram custom fields, and checks that the peer delivers it and that its echo
//! comes back with the fields intact.

use std::ffi::{c_char, c_void, CStr, CString};
use std::io::{BufRead, BufReader};
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use lxmf_rust::cffi::*;
use reticulum_rust::cffi::*;
use telegram_reticulum_ffi::*;

#[derive(Default)]
struct Seen {
    announces: Vec<Vec<u8>>,
    states: Vec<u8>,
    received: Vec<(Vec<u8>, String, Vec<u8>)>,
}

extern "C" fn on_announce(context: *mut c_void, dest_hash: *const u8, dest_len: u32, _display_name: *const c_char) {
    let seen = unsafe { &*(context as *const Mutex<Seen>) };
    let dest = unsafe { std::slice::from_raw_parts(dest_hash, dest_len as usize) }.to_vec();
    seen.lock().unwrap().announces.push(dest);
}

extern "C" fn on_state(context: *mut c_void, _hash: *const u8, _len: u32, state: u8) {
    let seen = unsafe { &*(context as *const Mutex<Seen>) };
    seen.lock().unwrap().states.push(state);
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
    signature_valid: i32,
    _unverified_reason: i32,
    fields_raw: *const u8,
    fields_len: u32,
) {
    assert_eq!(signature_valid, 1, "the echo must carry a valid signature");
    let seen = unsafe { &*(context as *const Mutex<Seen>) };
    let src = unsafe { std::slice::from_raw_parts(src_hash, src_len as usize) }.to_vec();
    let content = unsafe { CStr::from_ptr(content) }.to_string_lossy().into_owned();
    let fields = unsafe { std::slice::from_raw_parts(fields_raw, fields_len as usize) }.to_vec();
    seen.lock().unwrap().received.push((src, content, fields));
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

fn wait_until(budget: Duration, mut condition: impl FnMut() -> bool) -> bool {
    let deadline = Instant::now() + budget;
    while Instant::now() < deadline {
        if condition() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    condition()
}

#[test]
fn text_with_telegram_fields_round_trips_over_tcp() {
    let port = 40000 + (std::process::id() % 20000) as u16;
    let peer_dir = tempfile::tempdir().unwrap();
    let our_dir = tempfile::tempdir().unwrap();

    let mut peer = Command::new(env!("CARGO_BIN_EXE_tgrns_peer"))
        .args(["--dir", peer_dir.path().to_str().unwrap(), "--port", &port.to_string(), "--announce-every", "1"])
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .expect("spawn tgrns_peer");
    let mut peer_stdout = BufReader::new(peer.stdout.take().unwrap());
    let mut line = String::new();
    loop {
        line.clear();
        assert!(peer_stdout.read_line(&mut line).unwrap() > 0, "peer exited before printing DEST");
        if line.starts_with("DEST ") {
            break;
        }
    }
    let peer_dest = hex::decode(line.trim().strip_prefix("DEST ").unwrap()).unwrap();
    assert_eq!(peer_dest.len(), 16);

    std::fs::write(
        our_dir.path().join("config"),
        format!(
            "[reticulum]\n  enable_transport = false\n  share_instance = false\n  panic_on_interface_errors = false\n\n[logging]\n  loglevel = 3\n\n[interfaces]\n  [[Peer]]\n    type = TCPClientInterface\n    enabled = yes\n    target_host = 127.0.0.1\n    target_port = {port}\n"
        ),
    )
    .unwrap();
    let dir = our_dir.path().to_str().unwrap().to_string();
    let c_dir = CString::new(dir.clone()).unwrap();
    let c_storage = CString::new(format!("{dir}/lxmf_storage")).unwrap();
    let c_identity = CString::new(format!("{dir}/identity")).unwrap();
    let c_name = CString::new("loopback test").unwrap();
    let client = lxmf_client_start(c_dir.as_ptr(), c_storage.as_ptr(), c_identity.as_ptr(), 1, c_name.as_ptr(), 3, -1);
    assert!(client != 0, "lxmf_client_start: {}", last_error());

    let seen = Arc::new(Mutex::new(Seen::default()));
    let ctx = Arc::as_ptr(&seen) as *mut c_void;
    assert_eq!(lxmf_client_set_announce_callback(client, on_announce, ctx), 0);
    assert_eq!(lxmf_client_set_message_state_callback(client, on_state, ctx), 0);
    assert_eq!(lxmf_client_set_delivery_callback(client, on_delivery, ctx), 0);

    let iface = CString::new("Peer").unwrap();
    assert!(wait_until(Duration::from_secs(20), || rns_interface_online(iface.as_ptr()) == 1), "TCP interface never came online");
    assert_eq!(tgrns_any_interface_online(), 1);
    let mut status = TgrnsInterfaceStatus { name: [0; 128], online: 0, bitrate_set: 0, bitrate: 0.0, rx_bytes: 0, tx_bytes: 0, rssi_set: 0, rssi: 0.0, snr_set: 0, snr: 0.0 };
    assert_eq!(tgrns_interface_count(), 1);
    assert_eq!(unsafe { tgrns_interface_at(0, &mut status) }, 0);
    assert_eq!(unsafe { CStr::from_ptr(status.name.as_ptr()) }.to_str().unwrap(), "Peer");
    assert_eq!(status.online, 1);

    // The peer announces every second; its announce gives us its identity and a path.
    assert!(wait_until(Duration::from_secs(30), || seen.lock().unwrap().announces.contains(&peer_dest)), "no announce from the peer");
    assert_eq!(unsafe { tgrns_transport_wait_for_path(peer_dest.as_ptr(), 16, 10.0) }, 1);
    // Our own announce, so the peer can verify our signature and answer.
    assert_eq!(lxmf_client_announce(client), 0);

    let content = CString::new("hello over loopback").unwrap();
    let title = CString::new("").unwrap();
    let msg = lxmf_message_new(client, peer_dest.as_ptr(), 16, content.as_ptr(), title.as_ptr(), 2);
    assert!(msg != 0, "lxmf_message_new: {}", last_error());
    let custom_type = CString::new("org.telegram.reticulum/1").unwrap();
    assert_eq!(unsafe { tgrns_message_set_field_string(msg, 0xFB, custom_type.as_ptr()) }, 0);
    let envelope = [0x01u8, 0x02, 0x03, 0xFF, 0x00, 0x7E];
    assert_eq!(unsafe { tgrns_message_set_field_bytes(msg, 0xFC, envelope.as_ptr(), envelope.len() as u32) }, 0);
    assert_eq!(tgrns_message_set_field_u64(msg, 0x0F, 0), 0);
    assert_eq!(lxmf_message_send(client, msg), 0, "lxmf_message_send: {}", last_error());

    // The peer prints RECV for our message; its own stdout is line-buffered by it.
    // The library logs to stdout as well, so skip every line that is not the RECV report.
    loop {
        line.clear();
        assert!(peer_stdout.read_line(&mut line).unwrap() > 0, "peer exited before reporting RECV");
        if line.starts_with("RECV ") {
            break;
        }
    }
    assert!(line.trim().ends_with("hello over loopback"), "peer line: {line}");

    assert!(wait_until(Duration::from_secs(30), || seen.lock().unwrap().states.iter().any(|s| *s == 0x08 || *s == 0x04)), "our message never reached SENT/DELIVERED: {:?}", seen.lock().unwrap().states);
    assert!(wait_until(Duration::from_secs(30), || !seen.lock().unwrap().received.is_empty()), "no echo from the peer");

    let (src, echoed, fields) = seen.lock().unwrap().received[0].clone();
    assert_eq!(src, peer_dest);
    assert_eq!(echoed, "echo: hello over loopback");
    let decoded = rmpv::decode::read_value(&mut fields.as_slice()).expect("fields are a msgpack value");
    let rmpv::Value::Map(entries) = decoded else { panic!("fields are not a map: {decoded:?}") };
    let get = |key: u64| entries.iter().find(|(k, _)| k.as_u64() == Some(key)).map(|(_, v)| v.clone());
    assert_eq!(get(0xFB), Some(rmpv::Value::String("org.telegram.reticulum/1".into())));
    assert_eq!(get(0xFC), Some(rmpv::Value::Binary(envelope.to_vec())));

    let _ = lxmf_client_shutdown(client);
    let _ = peer.kill();
    let _ = peer.wait();
}
