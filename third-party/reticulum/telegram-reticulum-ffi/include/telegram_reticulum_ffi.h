//
//  telegram_reticulum_ffi.h
//
//  C header for libtelegram_reticulum_ffi.a, the Reticulum/LXMF stack the Telegram-iOS Reticulum
//  backend links (third-party/reticulum/VENDOR.md). Imported by the Swift module ReticulumEngine
//  through the Clang module "ReticulumFFI" (Bazel objc_library in third-party/reticulum/BUILD).
//
//  Four layers:
//    rns_*            universal Reticulum transport client API  (Reticulum-rust/src/cffi.rs)
//    lxmf_*           universal LXMF client API                 (LXMF-rust/src/cffi.rs)
//    rns_rnode_*,     host-driven radios: RNode over BLE/USB, RTNode over the Prns BLE protocol
//    rns_prns_ble_*                                             (Reticulum-rust/src/cffi.rs, src/interfaces/prns_ble/cffi.rs)
//    tgrns_*          this repository's additions                (telegram-reticulum-ffi/src/lib.rs)
//
//  The rns_*/lxmf_*/radio declarations are taken from Retichat-iOS's CRetichatFFI.h
//  (MIT License, Copyright (c) 2026 James LaFarge), which upstream keeps in step with the Rust
//  sources; re-check them against cffi.rs when a submodule is bumped.
//

#ifndef telegram_reticulum_ffi_h
#define telegram_reticulum_ffi_h

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// ===========================================================================
//  Reticulum Transport API — universal, language-bridge-friendly
// ===========================================================================

#pragma mark - RNS Library

char *rns_last_error(void);
void  rns_free_string(char *ptr);
void  rns_free_bytes(uint8_t *ptr, uint32_t len);

#pragma mark - RNS Client Lifecycle

uint64_t rns_client_start(const char *config_dir,
                           const char *identity_path,
                           int32_t create_identity,
                           int32_t log_level);

int32_t rns_client_shutdown(uint64_t client);

#pragma mark - RNS Client Queries

uint64_t rns_client_identity_handle(uint64_t client);
int32_t  rns_client_identity_hash(uint64_t client, uint8_t *out_buf, uint32_t buf_len);
int32_t  rns_client_dest_hash(uint64_t client,
                               const char *app_name,
                               const char *aspects,
                               uint8_t *out_buf, uint32_t buf_len);
void     rns_client_persist(uint64_t client);

#pragma mark - RNS Transport

int32_t rns_transport_has_path(const uint8_t *dest_hash, uint32_t len);
int32_t rns_identity_known(const uint8_t *dest_hash, uint32_t len);
int32_t rns_transport_request_path(const uint8_t *dest_hash, uint32_t len);
int32_t rns_transport_hops_to(const uint8_t *dest_hash, uint32_t len);

/// Query whether a configured interface is currently online.
/// Returns: 1 = online, 0 = offline, -1 = unknown / no such interface.
int32_t rns_interface_online(const char *name);

#pragma mark - RNS Settings

void    rns_set_drop_announces(int32_t enabled);
int32_t rns_set_keepalive_interval(double secs);

#pragma mark - RNS Network Connectivity

/// Signal that network connectivity has been restored.
/// Wakes all TCP client reconnect loops for an immediate retry.
void rns_nudge_reconnect(void);

#pragma mark - RNS Identity (standalone)

uint64_t rns_identity_from_bytes(const uint8_t *bytes, uint32_t len);
int32_t  rns_identity_public_key(uint64_t handle, uint8_t *out_buf, uint32_t buf_len);
int32_t  rns_identity_destroy(uint64_t handle);

#pragma mark - RNS Packet

int32_t rns_packet_send_to_hash(const uint8_t *dest_hash, uint32_t dest_hash_len,
                                 const char *app_name,
                                 const char *aspects,
                                 const uint8_t *payload, uint32_t payload_len);

#pragma mark - RNS Link Request

/// Blocking — call from a background thread.
/// Returns response bytes (free with rns_free_bytes), or NULL.
uint8_t *rns_link_request(const uint8_t *dest_hash, uint32_t dest_hash_len,
                           const char *app_name,
                           const char *aspects,
                           uint64_t identity_handle,
                           const char *path,
                           const uint8_t *payload, uint32_t payload_len,
                           double timeout_secs,
                           uint32_t *out_len);

// ===========================================================================
//  LXMF Client API — universal, high-level, language-bridge-friendly
// ===========================================================================


// ===========================================================================
//  LXMF Client API — universal, high-level, language-bridge-friendly
// ===========================================================================

#pragma mark - LXMF Library

char *lxmf_last_error(void);
void  lxmf_free_string(char *ptr);
void  lxmf_free_bytes(uint8_t *ptr, uint32_t len);

#pragma mark - LXMF Client Lifecycle

/// `display_name` is the initial Message Display Name (DISPLAY_NAMES.md §4.1):
/// sent inside messages (key 0 of the Retichat field 0xD1) by the name-ledger
/// rule, never announced.
/// NULL/"" = none. The Announce Display Name starts empty; set both at runtime
/// with lxmf_client_set_message_display_name / lxmf_client_set_announce_display_name.
uint64_t lxmf_client_start(const char *config_dir,
                            const char *storage_path,
                            const char *identity_path,
                            int32_t create_identity,
                            const char *display_name,
                            int32_t log_level,
                            int32_t stamp_cost);

/// lxmf_client_start with the delivery ratchets' mirror and freeze in place
/// before the ratchets load and before the delivery destination is registered
/// with Transport (which can announce it, and so rotate, from then on).
/// Reticulum-rust PARITY-AUDIT-1.5.2.md A29: a named departure, off by default.
/// `ratchets_mirror_dir`: NULL/"" = none; else an existing directory that
///   receives the identical ratchet file (`<dest hexhash>.ratchets`) after every
///   write of it. The app passes the directory the NSE loads its ratchets from.
/// `ratchets_frozen`: non-zero = read-only ratchets: never rotated, the file
///   never written or created; announces carry the newest ratchet held and
///   decryption reloads the file after a miss. The NSE passes 1.
uint64_t lxmf_client_start_with_ratchets(const char *config_dir,
                                         const char *storage_path,
                                         const char *identity_path,
                                         int32_t create_identity,
                                         const char *display_name,
                                         int32_t log_level,
                                         int32_t stamp_cost,
                                         const char *ratchets_mirror_dir,
                                         int32_t ratchets_frozen);

/// A29 at runtime, on every copy of the delivery destination (router,
/// Transport, client handle). Prefer lxmf_client_start_with_ratchets: set
/// here, a rotation already under way is not covered. NULL/"" stops the
/// mirror; `frozen` 0 unfreezes. Return 0 on success, -1 on error.
int32_t lxmf_client_set_ratchets_mirror_dir(uint64_t client, const char *dir);
int32_t lxmf_client_set_ratchets_frozen(uint64_t client, int32_t frozen);

int32_t lxmf_client_shutdown(uint64_t client);

#pragma mark - LXMF Client Callbacks

/// `signature_valid`: 1 validated, 0 not. `unverified_reason`: 0 validated,
/// 1 source unknown (no key for the source yet), 2 signature invalid.
/// DISPLAY_NAMES.md §5.2 accepts a 0xD1 name differently for 1 and 2, so
/// decide on `unverified_reason`, never on `signature_valid` alone.
typedef void (*lxmf_delivery_callback_t)(
    void *context,
    const uint8_t *hash, uint32_t hash_len,
    const uint8_t *src_hash, uint32_t src_len,
    const uint8_t *dest_hash, uint32_t dest_len,
    const char *title,
    const char *content,
    double timestamp,
    int32_t signature_valid,
    int32_t unverified_reason,
    const uint8_t *fields_raw, uint32_t fields_len
);

/// `display_name` is the announce's name cleaned with the announce rules
/// (DISPLAY_NAMES.md §5.1 announceName; "Anonymous Peer" is none), or NULL.
typedef void (*lxmf_announce_callback_t)(
    void *context,
    const uint8_t *dest_hash, uint32_t dest_len,
    const char *display_name
);

typedef void (*lxmf_sync_complete_callback_t)(
    void *context,
    uint32_t message_count
);

typedef void (*lxmf_message_state_callback_t)(
    void *context,
    const uint8_t *msg_hash, uint32_t hash_len,
    uint8_t state
);

typedef void (*lxmf_app_link_status_callback_t)(
    void *context,
    const uint8_t *dest_hash, uint32_t hash_len,
    uint8_t status
);

typedef void (*lxmf_app_link_packet_callback_t)(
    void *context,
    const uint8_t *bytes, uint32_t bytes_len
);

/// APP_LINK request completion callback (async variant).
///
/// Fires exactly once per `lxmf_app_link_request_async` invocation.
///
/// `status`:
///   0 = success — `bytes`/`bytes_len` describe the response payload.
///       Pointer is only valid for the duration of the callback; copy
///       before returning.
///   1 = timeout
///   2 = failed (peer rejected / link torn down before response)
///   3 = error (link not active, invalid args; check `lxmf_last_error`)
typedef void (*lxmf_app_link_request_callback_t)(
    void *context,
    const uint8_t *bytes, uint32_t bytes_len,
    int32_t status
);

/// APP_LINK plain-DATA send completion callback.
///
/// Fires exactly once per `lxmf_app_link_send_async` invocation.
///
/// `status`:
///   0 = delivered (Reticulum LRPROOF received)
///   1 = failed (tier chain exhausted without delivery proof)
typedef void (*lxmf_app_link_send_callback_t)(
    void *context,
    int32_t status
);

int32_t lxmf_client_set_delivery_callback(uint64_t client,
                                           lxmf_delivery_callback_t callback,
                                           void *context);

int32_t lxmf_client_set_announce_callback(uint64_t client,
                                           lxmf_announce_callback_t callback,
                                           void *context);

int32_t lxmf_client_set_sync_complete_callback(uint64_t client,
                                                lxmf_sync_complete_callback_t callback,
                                                void *context);

int32_t lxmf_client_set_message_state_callback(uint64_t client,
                                                lxmf_message_state_callback_t callback,
                                                void *context);

#pragma mark - LXMF Client Queries

uint64_t lxmf_client_identity_handle(uint64_t client);
int32_t lxmf_client_identity_hash(uint64_t client, uint8_t *out_buf, uint32_t buf_len);
int32_t lxmf_client_dest_hash(uint64_t client, uint8_t *out_buf, uint32_t buf_len);

#pragma mark - LXMF Propagation

int32_t lxmf_client_set_propagation_node(uint64_t client, const uint8_t *node_hash, uint32_t node_len);
int32_t lxmf_client_sync(uint64_t client, const uint8_t *node_hash, uint32_t node_len);
int32_t lxmf_client_ingest_propagated(uint64_t client, const uint8_t *lxmf_data, uint32_t lxmf_len);
int32_t lxmf_client_propagation_state(uint64_t client);
float   lxmf_client_propagation_progress(uint64_t client);
int32_t lxmf_client_cancel_propagation(uint64_t client);

#pragma mark - LXMF Peer Link Status

/// Query the current direct-link status for a peer.
/// Returns: 0 = no link / closed, 1 = pending (establishing), 2 = active, -1 on error.
int32_t lxmf_peer_link_status(uint64_t client, const uint8_t *dest_hash, uint32_t dest_len);

#pragma mark - LXMF App Links

/// Open an app link.  Watches dest, requests path, establishes link
/// when path arrives.  Push-driven (no polling).  Link kept alive
/// automatically and exempt from inactivity cleanup.
///
/// `app_name` and `aspects_csv` describe the destination identity that the
/// router must resolve when (re)establishing the link. Examples:
///   app_name="lxmf", aspects_csv="delivery"  — peer chat link.
///   app_name="rfed", aspects_csv="channel"   — rfed channel link.
///   app_name="rfed", aspects_csv="notify"    — rfed notify link.
/// `aspects_csv` is `.`-separated; pass "" if the app has no aspects.
/// Returns 0 on success, -1 on error.
int32_t lxmf_app_link_open(uint64_t client,
                            const uint8_t *dest_hash, uint32_t dest_len,
                            const char *app_name,
                            const char *aspects_csv);

/// Open a persistent app link.
///
/// Same registration semantics as `lxmf_app_link_open`, but once the
/// path-race succeeds AppLinks holds the outbound link open so request-style
/// traffic can reuse it directly.
/// Returns 0 on success, -1 on error.
int32_t lxmf_app_link_open_persistent(uint64_t client,
                                       const uint8_t *dest_hash, uint32_t dest_len,
                                       const char *app_name,
                                       const char *aspects_csv);

/// Close an app link.  Tears down the direct link.
/// Returns 0 on success, -1 on error.
int32_t lxmf_app_link_close(uint64_t client,
                             const uint8_t *dest_hash, uint32_t dest_len);

/// Query app link status.
///   0 = not tracked (NONE)
///   1 = path requested (PATH_REQUESTED)
///   2 = link establishing (ESTABLISHING)
///   3 = link active, ready to send (ACTIVE)
///   4 = disconnected, will reconnect on next announce (DISCONNECTED)
///  -1 = parameter error
int32_t lxmf_app_link_status(uint64_t client,
                              const uint8_t *dest_hash, uint32_t dest_len);

/// Explicit deterministic re-open trigger for an existing app link.
///
/// Invalidates the cached liveness winner for `dest_hash` and runs one fresh
/// AppLinks re-open cycle. Intended for host-driven nudges when the app has a
/// concrete reason to refresh a persistent link now.
/// Returns 0 on success, -1 on error.
int32_t lxmf_app_link_reopen(uint64_t client,
                              const uint8_t *dest_hash, uint32_t dest_len);

/// Register an app-link reconnect handler for a non-LXMF destination aspect.
///
/// The built-in announce handler only fires for `lxmf.delivery`; call this for
/// every extra aspect (e.g. "rfed.channel", "rfed.notify") so that when that
/// destination announces the router re-establishes any open app-link to it.
/// Call once per aspect during startup.
/// Returns 0 on success, -1 on error.
int32_t lxmf_app_link_register_reconnect(uint64_t client,
                                          const char *aspect_filter);

/// Register an APP_LINK status callback on the global registry.
///
/// The callback fires whenever an APP_LINK transitions state.  Status byte:
///   0 = NONE, 1 = PATH_REQUESTED, 2 = ESTABLISHING,
///   3 = ACTIVE, 4 = DISCONNECTED, and the event 5 = RECOVERED (a held STALE
///   link heard from its peer again and is ACTIVE once more; never a state,
///   so lxmf_app_link_status never returns it, and a handler that acts on
///   ACTIVE alone ignores it).
///
/// Multiple callbacks may be registered.  The callback runs on the link
/// actor thread and MUST NOT block — copy any data and dispatch off-thread.
/// Returns 0 on success, -1 on error.
int32_t lxmf_app_link_register_status_callback(uint64_t client,
                                                lxmf_app_link_status_callback_t callback,
                                                void *context);

/// Register a packet callback for DATA received on a persistent APP_LINK.
///
/// The callback is attached to the tracked persistent link for `dest_hash`.
/// If the link is already ACTIVE, it is installed immediately; if the link
/// reconnects later, it is reattached on the next ACTIVE transition.
/// Returns 0 on success, -1 on error.
int32_t lxmf_app_link_register_packet_callback(uint64_t client,
                                                const uint8_t *dest_hash,
                                                uint32_t dest_len,
                                                lxmf_app_link_packet_callback_t callback,
                                                void *context);

/// A request the node sends on a held outbound APP_LINK (rfed.link's
/// `/delivery` and `/lxmf/delivery` pushes, RFed-spec Link.md). Return true only
/// when the app now holds the blob: the answer goes back as msgpack bool and is
/// the delivery proof. Runs on a link worker thread, which waits for it.
typedef bool (*lxmf_app_link_inbound_request_callback_t)(
    void *context,
    const char *path,
    const uint8_t *data,
    uint32_t data_len);

/// Set up every held outbound link to `dest_hash` from now on: identify as this
/// client once established (`identify` != 0), and answer the node's requests on
/// each path in `paths_csv` (comma-separated) with `callback`. Call before
/// opening the link; an open link keeps its setup until it re-opens.
/// Returns 0 on success, -1 on error.
int32_t lxmf_app_link_set_outbound_setup(uint64_t client,
                                         const uint8_t *dest_hash,
                                         uint32_t dest_len,
                                         int32_t identify,
                                         const char *paths_csv,
                                         lxmf_app_link_inbound_request_callback_t callback,
                                         void *context);

/// Notify the router that the host's network reachability state has
/// changed (interface up/down, Wi-Fi <-> cellular, VPN flipped, etc.).
///
/// Triggers ONE fresh app-link establishment attempt for every registered
/// app-link that is not currently active or already establishing. The
/// router does not retry on its own — call this from a network-state
/// observer (NWPathMonitor on iOS, ConnectivityManager on Android).
/// Returns 0 on success, -1 on error.
int32_t lxmf_app_link_network_changed(uint64_t client);

/// Send a blocking request on an existing app-link.
///
/// Reuses an existing active app-link handle, typically one established by
/// `lxmf_app_link_open_persistent`, instead of opening a fresh outbound link
/// per request.  The link must already be in the ACTIVE state (call
/// `lxmf_app_link_status` first) — returns NULL with `lxmf_last_error`
/// describing the reason if not.
///
/// Blocking call — invoke from a background thread.
/// Returns response bytes (free with `lxmf_free_bytes`) or NULL on error
/// / timeout / link not active.
uint8_t *lxmf_app_link_request(uint64_t client,
                                const uint8_t *dest_hash, uint32_t dest_len,
                                const char *path,
                                const uint8_t *payload, uint32_t payload_len,
                                double timeout_secs,
                                uint32_t *out_len);

/// Non-blocking variant of `lxmf_app_link_request`.
///
/// Issues a request on the existing app-link to `dest_hash` and fires
/// `callback(context, bytes, bytes_len, status)` exactly once when the
/// response arrives, the request fails, or `timeout_secs` elapses.
///
/// Returns 0 on success (callback will fire), -1 on immediate error
/// (callback will NOT fire; check `lxmf_last_error`).
///
/// Preferred over the blocking variant when called from cooperative
/// concurrency contexts (Swift async, Kotlin coroutines): avoids parking
/// a high-QoS pool thread on a Default-QoS Rust receive. See
/// DESIGN_PRINCIPLES.md §1.
int32_t lxmf_app_link_request_async(uint64_t client,
                                     const uint8_t *dest_hash, uint32_t dest_len,
                                     const char *path,
                                     const uint8_t *payload, uint32_t payload_len,
                                     double timeout_secs,
                                     lxmf_app_link_request_callback_t callback,
                                     void *context);

/// Non-blocking plain DATA send via an ephemeral APP_LINK.
///
/// Registers the destination spec for `app_name` / `aspects_csv`, sends one
/// DATA packet, and fires `callback` exactly once on LRPROOF delivery or
/// terminal failure.
/// Returns 0 on success (callback will fire), -1 on immediate error.
int32_t lxmf_app_link_send_async(uint64_t client,
                                  const uint8_t *dest_hash, uint32_t dest_len,
                                  const char *app_name,
                                  const char *aspects_csv,
                                  const uint8_t *payload, uint32_t payload_len,
                                  lxmf_app_link_send_callback_t callback,
                                  void *context);

#pragma mark - LXMF Announce

int32_t lxmf_client_announce(uint64_t client);
int32_t lxmf_client_watch(uint64_t client, const uint8_t *dest_hash, uint32_t dest_len);

/// Opt this client's delivery destination into Transport's auto-announce
/// daemon. Transport will then re-announce automatically:
///   * once on every interface false→true `online` transition, and
///   * every `refresh_secs` seconds (pass 0.0 to disable periodic
///     refresh and only re-announce on interface up-edges).
/// Idempotent: a second call updates the entry. Returns 0 on success.
int32_t lxmf_client_publish(uint64_t client, double refresh_secs);

/// Remove this client's delivery destination from the auto-announce
/// daemon. Returns 0 on success.
int32_t lxmf_client_unpublish(uint64_t client);

/// Buffer size, NUL included, that holds any cleaned display name: 64
/// scalars of up to 4 UTF-8 bytes each, plus the NUL.
#define LXMF_DISPLAY_NAME_BUF_LEN 257

/// Look up the Announce Display Name last heard from a destination hash
/// (DISPLAY_NAMES.md §5.1 announceName: cleaned, "Anonymous Peer" is none).
/// Writes a NUL-terminated UTF-8 string into out_buf.
/// Returns the number of bytes written (including NUL), or 0 if none / buffer too small.
/// Pass a buffer of LXMF_DISPLAY_NAME_BUF_LEN bytes: a smaller one reports
/// the longest names as none.
int32_t lxmf_client_recall_display_name(uint64_t client,
                                         const uint8_t *dest_hash, uint32_t dest_len,
                                         char *out_buf, uint32_t buf_len);

#pragma mark - Display names (DISPLAY_NAMES.md)

/// Set the Message Display Name at runtime (§4.1): the router adds it (key 0
/// of the Retichat field 0xD1) to outbound messages by the name-ledger rule,
/// merged with any app entries in that map. NULL or "" clears it.
/// Cleaned (§3). No restart. Returns 0 on success, -1 on error (e.g. not UTF-8).
int32_t lxmf_client_set_message_display_name(uint64_t client, const char *name);

/// Set the Announce Display Name at runtime (§2.2): the PUBLIC name in this
/// client's lxmf.delivery announce. NULL or "" (the default) announces nil.
/// Cleaned with the announce rules ("Anonymous Peer" is none). The next
/// announce carries it. Returns 0 on success, -1 on error.
int32_t lxmf_client_set_announce_display_name(uint64_t client, const char *name);

/// Clean a display name exactly as the router does (§3), for the settings
/// screens. `announce` non-zero also maps "Anonymous Peer" to none.
/// Returns a NUL-terminated UTF-8 string (free with lxmf_free_string), or
/// NULL when the input cleans to no name. Never fails.
char *lxmf_display_name_clean(const uint8_t *raw, uint32_t raw_len, int32_t announce);

/// Decode the name, key 0 of the Retichat field 0xD1 ({0xD1: {0: name}}; a
/// 0xD1 that is not a map is absent), from the msgpack `fields_raw` a
/// delivery callback hands over. Returns a heap buffer (free with lxmf_free_bytes), at least 3 bytes:
///     [0]     name_state  0 = absent, 1 = clear, 2 = name
///     [1..3]  name_len    u16 BE (0 unless state 2)
///     [3..]   name        cleaned UTF-8
/// Accepting it depends on the message's signature (§5.2).
uint8_t *lxmf_display_name_decode(const uint8_t *fields_raw, uint32_t fields_len,
                                  uint32_t *out_len);

#pragma mark - LXMF Messages

uint64_t lxmf_message_new(uint64_t client,
                           const uint8_t *dest_hash, uint32_t dest_len,
                           const char *content, const char *title,
                           uint8_t method);

/// Set a top-level LXMF field (e.g. 0xA0-0xA8, the group fields senders use
/// until the switch, DISPLAY_NAMES.md §10). 0xD1, the Retichat field, is
/// refused (-1): set its entries with lxmf_message_set_retichat_*.
int32_t lxmf_message_add_field(uint64_t msg, uint8_t key, const char *value);
int32_t lxmf_message_add_field_bool(uint64_t msg, uint8_t key, int32_t value);
/// Set an entry of the Retichat field 0xD1 (DISPLAY_NAMES.md §10): the fields
/// get {0xD1: {key: value}}, merged with the entries already there (ascending
/// key order). `key` must be 1..127: key 0 is the display name, which only
/// the router writes. Keys 1-9 are the group entries (1 group id, 2 members,
/// 3 name, 4 action, 5 sender, 6 relay seen, 7 relay for, 8 relay done,
/// 9 member keys); all are strings except 8, a bool, and the wrong setter
/// for a defined key is refused. `value` must be non-NULL UTF-8.
/// Returns 0 on success, -1 on error (lxmf_last_error), changing nothing.
int32_t lxmf_message_set_retichat_string(uint64_t msg, int32_t key, const char *value);
/// As lxmf_message_set_retichat_string, for a bool entry; `value` non-zero
/// is true.
int32_t lxmf_message_set_retichat_bool(uint64_t msg, int32_t key, int32_t value);
/// Make a message a reaction (upstream FIELD_REACTION 0x40,
/// REACTIONS-DESIGN.md): the fields get {0x40: {0x00: bin to, 0x01: bin
/// content}}. `to` is `to_len` bytes: the target's 32-byte LXMF hash or, in a
/// Group, its 16-byte post id. `content` is non-NULL UTF-8, at most 64 bytes;
/// "" removes the sender's reaction.
/// Returns 0 on success, -1 on error (lxmf_last_error), changing nothing.
int32_t lxmf_message_set_reaction(uint64_t msg, const uint8_t *to, uint32_t to_len,
                                  const char *content);
int32_t lxmf_message_add_attachment(uint64_t msg, const char *filename,
                                     const uint8_t *data, uint32_t data_len);
/// Set FIELD_IMAGE (0x06) to [image_type, data], how MeshChat and Sideband send
/// a picture and show it inline. One per message. `image_type` is 1 to 16
/// ASCII letters or digits ("jpg", no "image/"); `data` is not empty.
/// Returns 0 on success, -1 on error (lxmf_last_error), changing nothing.
int32_t lxmf_message_set_image(uint64_t msg, const char *image_type,
                               const uint8_t *data, uint32_t data_len);
/// Clone an existing message as a fresh PROPAGATED message, preserving fields
/// and attachments. Returns 0 on error.
uint64_t lxmf_message_clone_propagated(uint64_t msg);
int32_t lxmf_message_send(uint64_t client, uint64_t msg);
/// Send via the top-level AppLinks::send pipeline (iface-race + 2 s
/// liveness cache; no client/router handle required — uses the global
/// router registered by lxmf_router_create).
int32_t lxmf_message_send_via_app_links(uint64_t msg);
/// Forget the cached liveness winner for `dest_hash` so the next
/// lxmf_message_send_via_app_links re-races interfaces. Call on
/// known network-state changes (WiFi→cellular, etc).
int32_t lxmf_app_links_invalidate_liveness(const uint8_t *dest_hash, uint32_t dest_len);
int32_t lxmf_message_state(uint64_t msg);
float   lxmf_message_progress(uint64_t msg);
int32_t lxmf_message_hash(uint64_t msg, uint8_t *out_buf, uint32_t buf_len);
int32_t lxmf_message_destroy(uint64_t msg);

#pragma mark - LXMF Utility

int32_t lxmf_client_process_outbound(uint64_t client);
void    lxmf_client_persist(uint64_t client);


#pragma mark - RNS RNode callback interface (BLE / Serial via native bridge)

/// Radio configuration for an RNode interface.
/// `_set` flags select whether the matching optional value is applied.
typedef struct RnsRNodeRadioConfig {
    uint64_t frequency;
    uint32_t bandwidth;
    uint8_t  txpower;
    uint8_t  sf;
    uint8_t  cr;
    uint8_t  flow_control;       // 0 = off, non-zero = on
    uint8_t  st_alock_set;       // 0 = none, 1 = use st_alock_pct
    float    st_alock_pct;
    uint8_t  lt_alock_set;
    float    lt_alock_pct;
    uint8_t  id_beacon_set;      // 0 = none, 1 = use id_interval_secs + id_callsign
    uint64_t id_interval_secs;
    const uint8_t *id_callsign;  // may be NULL when id_beacon_set == 0
    uint32_t id_callsign_len;
} RnsRNodeRadioConfig;

/// Latest device telemetry snapshot.
typedef struct RnsRNodeStats {
    uint8_t  online;
    uint8_t  detected;
    uint8_t  frequency_set;     uint64_t frequency;
    uint8_t  bandwidth_set;     uint32_t bandwidth;
    uint8_t  txpower_set;       uint8_t  txpower;
    uint8_t  sf_set;            uint8_t  sf;
    uint8_t  cr_set;            uint8_t  cr;
    uint8_t  rssi_set;          int16_t  rssi;
    uint8_t  snr_set;           float    snr;
    uint8_t  q_set;             float    q;
    uint8_t  rx_packets_set;    uint32_t rx_packets;
    uint8_t  tx_packets_set;    uint32_t tx_packets;
    float    airtime_short;
    float    airtime_long;
    float    channel_load_short;
    float    channel_load_long;
    uint8_t  battery_state;
    uint8_t  battery_percent;
    uint8_t  temperature_set;   int8_t   temperature;
    uint8_t  firmware_maj;
    uint8_t  firmware_min;
} RnsRNodeStats;

/// TX callback signature: invoked from Rust when KISS-framed bytes are ready
/// to be written to the radio. The bridge is responsible for any link-MTU
/// chunking (e.g. 20-byte BLE writes). Return non-zero on success.
typedef int32_t (*RnsRNodeSendFn)(void *user_data, const uint8_t *data, uint32_t len);

/// Register an RNode callback interface. Spawns the read loop and runs the
/// DETECT/init handshake (~3s while bytes are fed in).
/// Returns a handle (>0) or 0 on error (check rns_last_error).
uint64_t rns_rnode_iface_register(const char *name,
                                  RnsRNodeSendFn send_fn,
                                  void *user_data,
                                  const RnsRNodeRadioConfig *cfg);

/// Build the RNode interface and spawn its read loop, but do NOT run the
/// DETECT/init handshake. Lets the bridge obtain the handle (and start
/// feeding RX bytes via rns_rnode_iface_feed) BEFORE blocking inside the
/// handshake. Call rns_rnode_iface_configure next.
/// Returns a handle (>0) or 0 on error (check rns_last_error).
uint64_t rns_rnode_iface_create(const char *name,
                                RnsRNodeSendFn send_fn,
                                void *user_data,
                                const RnsRNodeRadioConfig *cfg);

/// Run the DETECT/init handshake on a previously-created RNode handle and
/// wire it into the Transport. Blocks for ~2-4 seconds while DETECT/setup
/// bytes are exchanged with the device. Returns 0 on success, -1 on error.
int32_t  rns_rnode_iface_configure(uint64_t handle);

/// Push RX bytes (received from the radio) into the read loop. Returns 0 on
/// success, -1 on error.
int32_t  rns_rnode_iface_feed(uint64_t handle, const uint8_t *data, uint32_t len);

/// Fetch the latest device telemetry into `out`. Returns 0 on success, -1 on error.
int32_t  rns_rnode_iface_get_stats(uint64_t handle, RnsRNodeStats *out);

/// Send the configured ID-beacon callsign immediately. Returns 0 on success, -1 on error.
int32_t  rns_rnode_iface_id_beacon_now(uint64_t handle);

/// Deregister and tear down the Transport binding. The bridge must stop
/// calling rns_rnode_iface_feed before invoking this. Returns 0 on success, -1 on error.
int32_t  rns_rnode_iface_deregister(uint64_t handle);

#pragma mark - RTNode over Bluetooth (Prns native protocol, central only)
//
// Reticulum-rust interfaces/prns_ble (cffi.rs). The app is the radio: it
// scans when asked, reports each advertisement of the Prns service, connects
// when handed a link, discovers the service and subscribes to both
// characteristics, performs the writes it is asked for, and reports every
// event. Rust decides what to dial and does the protocol. Every function
// returns 0 on success or -1 with the reason in rns_last_error(), except
// rns_prns_ble_sighted.

/// Start (on != 0) or stop scanning for the Prns service.
typedef void (*RnsPrnsBleScanFn)(void *user_data, int32_t on);
/// Write len bytes to characteristic 0 (control) or 1 (data), with response,
/// then report the result with rns_prns_ble_link_write_done.
typedef void (*RnsPrnsBleWriteFn)(void *user_data, uint64_t link, uint8_t characteristic,
                                  const uint8_t *data, uint32_t len);
/// Cancel the connection or connection attempt. No link_closed needed after.
typedef void (*RnsPrnsBleDisconnectFn)(void *user_data, uint64_t link);
/// Link state: 0 handshaking, 1 settled, 2 closed, 3 dialling. peer_identity
/// (16 bytes) and interface_name may be NULL; valid only during the call.
typedef void (*RnsPrnsBleStateFn)(void *user_data, uint64_t link, int32_t state,
                                  const uint8_t *peer_identity, const char *interface_name);

/// Start once the stack runs and the delivery destination is published; then
/// start scanning. endpoint: stack 1 (CoreBluetooth), host 1 iOS / 2 iPadOS /
/// 0 macOS. storage_dir keeps the Bluetooth identity; identity_out gets it
/// (16 bytes, or NULL). user_data must stay valid until rns_prns_ble_stop returns.
int32_t  rns_prns_ble_start(const char *storage_dir, uint8_t endpoint_stack, uint8_t endpoint_host,
                            RnsPrnsBleScanFn scan_fn, RnsPrnsBleWriteFn write_fn,
                            RnsPrnsBleDisconnectFn disconnect_fn, RnsPrnsBleStateFn state_fn,
                            void *user_data, uint8_t *identity_out);
/// Close every link and remove the RTNodes' interfaces. Blocks briefly: call
/// off the main thread, before the stack shuts down, never from a callback.
int32_t  rns_prns_ble_stop(void);
/// An advertisement of the Prns service. address: the peripheral identifier's
/// UUID string; manufacturer_data: kCBAdvDataManufacturerData whole. Returns
/// the link to dial it on, or 0 (not an RTNode, linked, busy, or paused).
uint64_t rns_prns_ble_sighted(const char *address, const uint8_t *manufacturer_data, uint32_t len);
/// Connected, service discovered, both characteristics subscribed.
/// max_write_len: maximumWriteValueLength(for: .withoutResponse).
int32_t  rns_prns_ble_link_ready(uint64_t link, uint32_t max_write_len);
/// A notification from characteristic 0 (control) or 1 (data).
int32_t  rns_prns_ble_link_received(uint64_t link, uint8_t characteristic,
                                    const uint8_t *data, uint32_t len);
/// The write asked for completed (ok != 0) or failed.
int32_t  rns_prns_ble_link_write_done(uint64_t link, int32_t ok);
/// The connection or attempt is gone (disconnect, connect failure, or a
/// failure setting the link up).
int32_t  rns_prns_ble_link_closed(uint64_t link);


// ===========================================================================
//  Telegram additions (telegram-reticulum-ffi/src/lib.rs)
// ===========================================================================

#pragma mark - Telegram: versions and logging

/// "tgrns <ffi> / rns <Reticulum-rust> / lxmf <LXMF-rust>". Free with rns_free_string.
char *tgrns_version(void);

typedef void (*tgrns_log_callback_t)(void *context, const char *line);

/// Route the library's log lines to `callback` (one NUL-terminated line per call, valid only
/// during the call) instead of stderr. NULL restores stderr.
void tgrns_set_log_callback(tgrns_log_callback_t callback, void *context);

#pragma mark - Telegram: LXMF fields

/// LXMF field ids (LXMF.py). FIELD_CUSTOM_TYPE/DATA/META carry the Telegram envelope.
enum {
    TGRNS_FIELD_FILE_ATTACHMENTS = 0x05,
    TGRNS_FIELD_IMAGE            = 0x06,
    TGRNS_FIELD_AUDIO            = 0x07,
    TGRNS_FIELD_RENDERER         = 0x0F,
    TGRNS_FIELD_REPLY_TO         = 0x30,
    TGRNS_FIELD_REACTION         = 0x40,
    TGRNS_FIELD_CUSTOM_TYPE      = 0xFB,
    TGRNS_FIELD_CUSTOM_DATA      = 0xFC,
    TGRNS_FIELD_CUSTOM_META      = 0xFD,
};

/// Set top-level field `key` of an outbound message (replacing an existing entry) to a
/// msgpack binary / string / unsigned integer / already-encoded msgpack value.
/// Return 0 on success, -1 on error (rns_last_error).
int32_t tgrns_message_set_field_bytes(uint64_t msg, uint8_t key, const uint8_t *data, uint32_t len);
int32_t tgrns_message_set_field_string(uint64_t msg, uint8_t key, const char *value);
int32_t tgrns_message_set_field_u64(uint64_t msg, uint8_t key, uint64_t value);
int32_t tgrns_message_set_field_msgpack(uint64_t msg, uint8_t key, const uint8_t *data, uint32_t len);
int32_t tgrns_message_remove_field(uint64_t msg, uint8_t key);

/// Replace the content with arbitrary bytes (lxmf_message_new takes a C string).
int32_t tgrns_message_set_content_bytes(uint64_t msg, const uint8_t *data, uint32_t len);

#pragma mark - Telegram: interfaces and paths

typedef struct TgrnsInterfaceStatus {
    char     name[128];
    uint8_t  online;
    uint8_t  bitrate_set;
    double   bitrate;
    uint64_t rx_bytes;
    uint64_t tx_bytes;
    uint8_t  rssi_set;
    double   rssi;
    uint8_t  snr_set;
    double   snr;
} TgrnsInterfaceStatus;

/// The interfaces Transport knows: configured TCP/UDP ones and registered radios.
uint32_t tgrns_interface_count(void);
/// Fill `out` with interface `index` (0-based). Returns 0, or -1 when out of range.
int32_t  tgrns_interface_at(uint32_t index, TgrnsInterfaceStatus *out);
/// 1 when any interface is online.
int32_t  tgrns_any_interface_online(void);

/// Request a path to the 16-byte `dest_hash` if none is known and wait up to `budget_secs`.
/// Returns 1 when a path is known on return, 0 otherwise, -1 on a bad argument.
int32_t  tgrns_transport_wait_for_path(const uint8_t *dest_hash, uint32_t len, double budget_secs);

#ifdef __cplusplus
}
#endif

#endif /* telegram_reticulum_ffi_h */
