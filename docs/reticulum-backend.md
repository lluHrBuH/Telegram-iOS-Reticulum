# The Reticulum backend: Telegram with no server

This fork runs the Telegram client with **no Telegram backend**. The account is a Reticulum
identity, peers are LXMF addresses, and messages travel as LXMF over the Reticulum mesh (TCP to a
public node, Bluetooth LE to an RNode LoRa radio or an RTNode). Two such clients talk to each
other with the full Telegram semantics they need; plain text and media also reach stock LXMF
clients (Sideband, NomadNet, Retichat), which is how it is tested against an existing address.

Everything above TelegramCore's network engine seam is unchanged. What replaces the server is an
**in-process local server** behind that seam, and what replaces the wire is LXMF. "Wrap MTProto in
LXMF" is literally the design: the client still speaks MTProto to a server, the server runs inside
the app, and the server speaks LXMF to its peers.

## Layering

```
Telegram UI (unchanged)
TelegramCore: Postbox, AccountStateManager, pending messages, media fetch ... (unchanged)
      │ Network.request(TL bytes)                 ▲ BoxedMessage(Api.Updates)
ReticulumNetworkEngine (NetworkEngineKind.reticulum)     submodules/TelegramCore/Sources/Reticulum/
      │ Api.parseFunctionCall(payload) → typed arguments
LocalServer: handlers per TL method + LocalServerStore (a second SqliteValueBox) + pts event log
      │ LXMFEnvelope: plain content + Telegram fields     protocol ReticulumTransport (UIKit-free)
ReticulumEngine (submodules/ReticulumEngine): ReticulumRuntime, ReticulumMeshTransport, BLE hosts
      │ C ABI  third-party/reticulum/telegram-reticulum-ffi
Rust: Reticulum-rust (transport, interfaces) + LXMF-rust (router), vendored by jrl290
```

## The seam: a local server answers the client's own MTProto calls

- `NetworkEngine` is TL bytes in, TL bytes out. `ReticulumNetworkEngine` gives every session
  (main, workers, downloads) a view onto one `LocalServer` per account directory
  (`<account>/reticulum-server/`), made by `ReticulumNetworkEngineFactory` and cached by path.
- `Api.parseFunctionCall` (TelegramApi, `ApiFunctionCall.swift`) decodes a serialized
  `Api.functions.*` call through the table-driven TL C engine (`TLParseFunctionCall`) into the
  function's name and typed arguments; the handler's result is serialized back and fed to
  `request.parse`. Nothing in the generated API changed.
- Handlers are grouped by concern: `LocalServer+Launch.swift` (the launch chain: `help.getConfig`
  with one datacenter, `help.getAppConfig`, `updates.getState`/`getDifference`, dialogs, history,
  users, contacts, settings), `LocalServer+Messaging.swift` (send, read, typing, edit, delete,
  reactions, incoming LXMF), `LocalServer+Media.swift` (uploads, downloads, `sendMedia`, profile
  photos), `LocalServer+Peers.swift` (identity mapping, `Api.User` values, announces).
- **Every method the server does not implement gets the schema's empty answer** (an empty vector,
  `boolFalse`, an empty `updates`), or `400 RETICULUM_UNSUPPORTED` when the result type has no
  empty value. This is what lets the ~70 `managed*` tasks settle instead of retrying forever.
- Updates are produced by the server with `pts += 1`, appended to its event log (what
  `getDifference` replays) and pushed to every update sink as `Api.Updates`, so
  `AccountStateManager` applies them like any server's: notifications, unread counts, chat-list
  order all come for free.

## Identity and ids

- The identity is a Reticulum keypair (64 bytes: X25519 then Ed25519 private key) at
  `<account>/reticulum/identity`, made or imported at onboarding, exportable as hex from
  Settings ▸ Reticulum Network. The LXMF address is the 16-byte `lxmf.delivery` destination hash.
- `LocalServerPeerIdentity`: a Telegram user id is 56 bits, so `peerId = first 7 bytes of the
  hash` (`Namespaces.Peer.CloudUser`), `accessHash = last 8 bytes` (it must be non-nil or
  `apiInputPeer` refuses to address the peer), `username = the 32-hex address` (so "@address" works
  in search and `contacts.resolveUsername` maps onto a path request). Collisions are 2^-56 per pair
  and refused on insert.
- The account is `AuthorizedAccountState(masterDatacenterId: 1, peerId: self)`;
  `createReticulumAccount` (`ReticulumAccount.swift`) stores the self user and switches the account
  manager, after which `SharedAccountContextImpl` picks the account up as after any login.

## Messages over LXMF (`LXMFEnvelope`)

- Content is the plain text; the Telegram semantics ride in two custom fields:
  `0xFB FIELD_CUSTOM_TYPE = "org.telegram.reticulum/1"` and `0xFC FIELD_CUSTOM_DATA`, a msgpack map
  with integer keys (`LXMFEnvelope.Key`): kind (message, read, typing, edit, delete, reaction,
  profile), targets by LXMF hash, the text as a TL `textWithEntities`, the sender's date, the
  sender's `MessageMedia` for attributes. Replies use the standard `0x30 FIELD_REPLY_TO`.
- Both sides store the LXMF hash beside their own message id (`messageHashes`), which is how
  edits, deletes, reactions and reads name a message across two independent id spaces.
- A message **without** the envelope is a stock LXMF client's: its content is the text, its
  `0x06` image, `0x07` audio and `0x05` attachments become photo, voice and document messages.
- Control envelopes (read, typing, edit, delete, reaction, profile) have no content and go only to
  peers that have shown the envelope at least once (`PeerRecord.speaksTelegram`): a stock client
  would render them as empty messages. Typing is off by default
  (`LocalServerPreferences.sendsTypingIndicators`, from Settings) because LoRa is slow.
- `messages.sendMessage` stores the server's copy first and answers only when the router reports
  SENT or DELIVERED; a FAILED delivery drops the copy and answers `400 PEER_UNREACHABLE`, so the
  bubble shows the retry mark and a resend starts over. A resend with the same random id while the
  first is still travelling joins it.

## Media

- Uploads go part by part into `<store>/uploads/<fileId>/`; `sendMedia` joins them into
  `<store>/files/<id>`, mints an `Api.Photo` / `Api.Document` with random local ids on datacenter 1
  and serves the bytes back through `upload.getFile` by id, so MediaBox and the fetch pipeline are
  untouched. Image dimensions come from the file header (`ImageHeader`: JPEG, PNG, GIF, WebP),
  because TelegramCore cannot import UIKit.
- On the wire: `0x06 [ext, bytes]` for a photo, `0x07 [0x16 (Opus/Ogg), bytes]` for a voice
  message, `0x05 [[name, bytes]]` for everything else. The receiver mints its own ids, taking the
  attributes (file name, duration, waveform, dimensions) from the envelope when the sender is a
  Telegram peer. A media send is answered with the whole message (`updateMessageID` +
  `updateNewMessage`): `updateShortSentMessage` cannot carry the minted media.
- Profile photos: `photos.uploadProfilePhoto` stores the photo on the self user
  (`userProfilePhoto`, served by `inputPeerPhotoFileLocation`), and the `.profile` envelope carries
  it in field `0x06` to contacts.

## The app side (`submodules/ReticulumEngine`)

- **The Rust transport is one instance per process**, so `ReticulumRuntime.shared` runs the stack
  for one account at a time (the account that last asked). It writes the Reticulum `config` file
  from `ReticulumSettings` (TelegramUIPreferences, shared-data key 23: TCP nodes, the RNode radio,
  RTNode linking, the propagation node, typing, log level), starts `lxmf_client_start`, and
  restarts when the nodes change. It waits for the settings before the first start.
- **Every callback from Rust hops to the runtime queue.** The router holds its lock while it calls
  back; calling into the library from a callback deadlocks (measured in the loopback test while
  the peer's echo was issued from the delivery callback). `ReticulumMeshTransport` copies the
  arguments out and dispatches; sends are keyed by LXMF hash until a final state, with a state poll
  and a 180 s net under the callback.
- **RNode** (`RNodeBluetoothHost`): Nordic UART over BLE; TX notifications are fed to the Rust
  RNode interface (`rns_rnode_iface_feed`), KISS frames from Rust are written in
  `maximumWriteValueLength` chunks paced by `canSendWriteWithoutResponse`. The DETECT handshake
  (`rns_rnode_iface_configure`) blocks for seconds and runs off the BLE queue while bytes flow.
- **RTNode** (`RTNodeBluetoothHost`): the Prns protocol (`Reticulum-rust/PRNS_BLE.md`); the app
  is only the radio (scan, sight, connect, subscribe to control and data, write, report), Rust
  dials and does the handshake, and each settled node is an interface `PrnsBLE[<identity>]`.
  Data writes go without response when the characteristic allows it, control writes with.
- `AppDelegate` passes `ReticulumNetworkEngineFactory(identityProvider: ReticulumRuntime.shared,
  transportProvider:, fallback: RustNetworkEngineFactory())`; `NetworkEngineSettings.defaultSettings`
  is `.reticulum` on iOS (`.rust` on macOS); Debug Settings has a "Reticulum Backend" switch beside
  the Rust one. App extensions have no factory and get `IdleNetworkEngine`, which never connects
  and fails every request at once, so an extension of a Reticulum build never dials the Telegram
  servers (there is no key for them).
- Onboarding: the splash's Start button branches on the network's engine kind to
  `ReticulumIdentityController` (create, or import a 128-hex private key), then the existing name
  screen, then `createReticulumAccount`.
- Settings ▸ Reticulum Network replaces Proxy everywhere (`proxySettingsController` routes on the
  engine kind): address with copy/share/announce, interfaces and their state, TCP nodes
  (`rmap.world:4242` by default), RNode device and radio parameters, RTNode, propagation node,
  typing, identity export.

## Feature gating

`help.getAppConfig` is answered from `LocalServerAppConfiguration.entries` (`reticulum_backend`,
`stories_posting = disabled`, `premium_purchase_blocked`, `stars_purchase_blocked`,
`news_feed_enabled = false`, one reaction per message); `help.getConfig` lists one datacenter and
no CDNs. Calls, stories, channels, bots, payments and folder sync are not implemented: their
methods get the schema's empty answer so nothing loops. Groups (client-side fan-out) and
RFed-style channels are follow-ups.

## Building on a Mac (`build.sh`)

The fork's bundle id is `org.reticulum.telegram` (`build-system/reticulum-development-configuration.json`;
the team id there is a placeholder until a device build needs a real one). Extensions, the app group,
the keychain group and the watch app derive from it. `./build.sh` at the repository root runs the
simulator build with `--codesigningInformationPath build-system/fake-codesigning
--disableProvisioningProfiles` (a `Make.py` option added for this fork: `build`, `test` and
`generateProject` pass `--//Telegram:disableProvisioningProfiles` and accept a missing
aps-environment, so no profile has to match the bundle id and no codesigning repository is needed),
re-resolves the Reticulum crates on the first run (`CARGO_BAZEL_REPIN_ONLY=reticulum_crates`), and
writes `build-output/<timestamp>.log` plus an error digest in `build-output/errors.txt`.
`RUN_TESTS=1` adds the TelegramApi and TelegramCore test targets, `RUN_RUST_TESTS=1` the crate's
own tests. With the official Telegram app installed beside it, iOS picks either app for `tg://`
links.

## Verification

Nothing here can be built in the cloud container (no Xcode, no raw TCP egress). On the Mac:

1. `CARGO_BAZEL_REPIN=1 CARGO_BAZEL_REPIN_ONLY=reticulum_crates` once, then the full
   `Make.py build --continueOnError` (`CLAUDE.md`, Build).
2. `Make.py test --target //submodules/TelegramApi:TelegramApiTests` (`FunctionCallTests`) and
   `--target //submodules/TelegramCore:TelegramCoreTests` (`LocalServerTests`: identity mapping,
   the launch chain, empty answers, incoming plain LXMF, send with the envelope, failed delivery,
   control envelopes, resolveUsername, announces, media, msgpack).
3. Rust, anywhere: `cargo test` in `third-party/reticulum/telegram-reticulum-ffi` (two in-process
   routers over loopback TCP). `cargo run --bin lxmf_probe -- --to 91a664e798f1bee3ed0e9dec7c1d7c9f
   --node rmap.world:4242 --text hello --listen 60` sends to a real address through the public node.
4. Simulator: fresh install → Create New Identity → name → Settings ▸ Reticulum Network shows
   `rmap.world` online → "@91a664e798f1bee3ed0e9dec7c1d7c9f" in search → send text → delivered
   mark; a reply from Sideband arrives as an incoming bubble. Two simulators exchange text, edits,
   deletes, reactions and a photo; kill and relaunch keeps history and pts (watch the log for
   `getDifference` loops).
5. Device: RNode over BLE with the TCP node off; RTNode likewise.

## Licensing

The vendored crates are under the Reticulum License (MIT plus use restrictions), Telegram-iOS is
GPLv2: see `third-party/reticulum/VENDOR.md` before distributing a combined binary. The
GPL-compatible alternative (FreeTAKTeam `reticulum-rs`/`lxmf`) would sit behind the same
`ReticulumTransport` seam.
