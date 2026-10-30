# Vendored Reticulum stack

Three git submodules by James LaFarge (jrl290), pinned to the revisions below. They are the Rust ports
Retichat-iOS ships, chosen because they are the only Reticulum/LXMF implementation proven on iOS with
host-driven BLE radios (RNode over Nordic UART, RTNode over the Prns protocol).

| Submodule | Upstream | Revision (2026-10-30) | License |
|---|---|---|---|
| `Reticulum-rust` ("Rusticulum", crate `reticulum_rust`, RNS parity 1.1.3) | https://github.com/jrl290/Reticulum-rust | `b1a12b2ed5c6c9964a49f7c448fe9dd964a948cf` | Reticulum License (`Reticulum-rust/LICENSE`); `prns-ble/` is MIT OR Apache-2.0 |
| `LXMF-rust` (crate `lxmf_rust`, LXMF parity 0.9.4) | https://github.com/jrl290/LXMF-rust | `738f5c194722bc714e2e02c76c56b6144e9b3536` | Reticulum License |
| `app-links` (crate `app_links`, LXMF-rust's dependency) | https://github.com/jrl290/app-links | `f090351916a9f073f0298c34a77976644e7d0d01` | see `app-links/LICENSE` |

`telegram-reticulum-ffi/` is this repository's own crate: a `staticlib` that links the two crates'
universal C ABIs (`rns_*` from `Reticulum-rust/src/cffi.rs`, `lxmf_*` from `LXMF-rust/src/cffi.rs`,
`rns_rnode_*` and `rns_prns_ble_*` for the radios) and adds the `tgrns_*` helpers the app needs
(custom LXMF fields, interface status, path waits). `include/telegram_reticulum_ffi.h` declares what
the Swift module imports; its `rns_*`/`lxmf_*`/radio declarations are taken from Retichat-iOS's
`CRetichatFFI.h` (MIT, Copyright (c) 2026 James LaFarge), which upstream keeps in step with the
Rust sources. Re-check the header against `cffi.rs` whenever a submodule is bumped.

The Reticulum License is MIT plus two use restrictions (no systems built to harm people, no
AI/ML training datasets). Telegram-iOS is GPLv2; shipping a combined binary needs a licensing
review before distribution. The GPL-compatible alternative is FreeTAKTeam's `reticulum-rs`/`lxmf`
(EPL-2.0 OR GPL-2.0+), which would sit behind the same Swift `ReticulumTransport` seam.

The transport is a process-global singleton in these crates: one Reticulum instance per process,
so one account runs the mesh at a time and tests that need two peers run a second process
(`src/bin/tgrns_peer.rs`).
