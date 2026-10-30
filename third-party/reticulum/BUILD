load("@rules_cc//cc:objc_library.bzl", "objc_library")
load("@rules_rust//rust:defs.bzl", "rust_library", "rust_static_library")

# The Reticulum stack (VENDOR.md): Reticulum-rust (transport, interfaces), its prns-ble member (RTNode
# over Bluetooth LE), app-links, LXMF-rust (message router) and this repository's telegram-reticulum-ffi,
# which exports the C ABI the Swift module ReticulumEngine imports as the Clang module ReticulumFFI.
#
# Pinned, not inherited: rules_rust follows Bazel's compilation mode, so under --configuration=debug_*
# these would otherwise compile at -Copt-level=0 and the per-packet crypto would crawl. -Cpanic=abort as
# for tlottie: a panic cannot unwind across `extern "C"` anyway. Never -Clto (CLAUDE.md, "Rust MTProto
# engine on iOS"): every rust_static_library in the app shares one std and LTO would duplicate it.
_RETICULUM_FLAGS = [
    "-Copt-level=3",
    "-Ccodegen-units=1",
    "-Cpanic=abort",
]

rust_library(
    name = "prns_ble",
    crate_name = "prns_ble",
    crate_root = "Reticulum-rust/prns-ble/src/lib.rs",
    srcs = glob(["Reticulum-rust/prns-ble/src/**/*.rs"]),
    edition = "2021",
    rustc_flags = _RETICULUM_FLAGS,
    version = "0.1.0",
    deps = [
        "@reticulum_crates//:rand",
    ],
)

# `serial` is what the RNode interface (rns_rnode_iface_*, host-fed KISS bytes over BLE) compiles under;
# it also pulls serialport and btleplug, as Retichat-iOS builds it. `prns-ble` is the RTNode interface.
rust_library(
    name = "reticulum_rust",
    crate_name = "reticulum_rust",
    crate_root = "Reticulum-rust/src/lib.rs",
    srcs = glob(["Reticulum-rust/src/**/*.rs"]),
    compile_data = glob(["Reticulum-rust/tests/fixtures/**"], allow_empty = True),
    crate_features = [
        "serial",
        "prns-ble",
    ],
    edition = "2021",
    rustc_flags = _RETICULUM_FLAGS,
    version = "0.1.0",
    deps = [
        ":prns_ble",
        "@reticulum_crates//:aes",
        "@reticulum_crates//:block-padding",
        "@reticulum_crates//:btleplug",
        "@reticulum_crates//:bzip2",
        "@reticulum_crates//:cbc",
        "@reticulum_crates//:chrono",
        "@reticulum_crates//:ctrlc",
        "@reticulum_crates//:ed25519-dalek",
        "@reticulum_crates//:futures",
        "@reticulum_crates//:hkdf",
        "@reticulum_crates//:hmac",
        "@reticulum_crates//:if-addrs",
        "@reticulum_crates//:libc",
        "@reticulum_crates//:once_cell",
        "@reticulum_crates//:parking_lot",
        "@reticulum_crates//:rand",
        "@reticulum_crates//:rmp",
        "@reticulum_crates//:rmp-serde",
        "@reticulum_crates//:rmpv",
        "@reticulum_crates//:rusqlite",
        "@reticulum_crates//:serde",
        "@reticulum_crates//:serde_bytes",
        "@reticulum_crates//:serialport",
        "@reticulum_crates//:sha2",
        "@reticulum_crates//:socket2",
        "@reticulum_crates//:tokio",
        "@reticulum_crates//:uuid",
        "@reticulum_crates//:windows-sys",
        "@reticulum_crates//:x25519-dalek",
    ],
)

rust_library(
    name = "app_links",
    crate_name = "app_links",
    crate_root = "app-links/src/lib.rs",
    srcs = glob(["app-links/src/**/*.rs"]),
    edition = "2021",
    rustc_flags = _RETICULUM_FLAGS,
    version = "0.1.0",
    deps = [
        ":reticulum_rust",
        "@reticulum_crates//:once_cell",
    ],
)

rust_library(
    name = "lxmf_rust",
    crate_name = "lxmf_rust",
    crate_root = "LXMF-rust/src/lib.rs",
    srcs = glob(["LXMF-rust/src/**/*.rs"]),
    edition = "2021",
    rustc_flags = _RETICULUM_FLAGS,
    version = "0.1.0",
    deps = [
        ":app_links",
        ":reticulum_rust",
        "@reticulum_crates//:atty",
        "@reticulum_crates//:base64",
        "@reticulum_crates//:ctrlc",
        "@reticulum_crates//:data-encoding",
        "@reticulum_crates//:hkdf",
        "@reticulum_crates//:once_cell",
        "@reticulum_crates//:rand",
        "@reticulum_crates//:rmp",
        "@reticulum_crates//:rmp-serde",
        "@reticulum_crates//:rmpv",
        "@reticulum_crates//:rusqlite",
        "@reticulum_crates//:serde",
        "@reticulum_crates//:serde_bytes",
        "@reticulum_crates//:serde_json",
        "@reticulum_crates//:sha2",
        "@reticulum_crates//:uuid",
    ],
)

rust_static_library(
    name = "telegram_reticulum_ffi_archive",
    crate_name = "telegram_reticulum_ffi",
    crate_root = "telegram-reticulum-ffi/src/lib.rs",
    srcs = glob(["telegram-reticulum-ffi/src/*.rs"]),
    crate_features = [
        "rnode",
        "prns-ble",
    ],
    edition = "2021",
    rustc_flags = _RETICULUM_FLAGS,
    version = "0.1.0",
    deps = [
        ":lxmf_rust",
        ":reticulum_rust",
        "@reticulum_crates//:rmpv",
    ],
    visibility = ["//visibility:public"],
)

# The Clang module the Swift wrapper imports: one header, the archive behind it. btleplug's CoreBluetooth
# backend and the sockets need these frameworks; rusqlite is bundled so no system sqlite is linked.
objc_library(
    name = "ReticulumFFI",
    module_name = "ReticulumFFI",
    enable_modules = True,
    hdrs = ["telegram-reticulum-ffi/include/telegram_reticulum_ffi.h"],
    includes = ["telegram-reticulum-ffi/include"],
    sdk_frameworks = [
        "CoreBluetooth",
        "Foundation",
        "Security",
    ],
    deps = [":telegram_reticulum_ffi_archive"],
    visibility = ["//visibility:public"],
)
