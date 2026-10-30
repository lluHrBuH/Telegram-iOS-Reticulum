import Foundation
import SwiftSignalKit
import TelegramCore
import TelegramUIPreferences
import ReticulumFFI

/// The Rust Reticulum stack is one transport per process, so the app runs one identity at a
/// time: the account that last asked. `ReticulumRuntime` owns that lifecycle, the identity files
/// (`<account>/reticulum/identity`, 64 bytes: X25519 then Ed25519 private key), the config file
/// written from `ReticulumSettings`, the radios' Bluetooth hosts, and the mesh transport the
/// account's `LocalServer` receives through the engine factory.
///
/// Every callback from the Rust side is copied out and dispatched to `queue`: the router holds
/// its lock while it calls, and calling back into the library from a callback deadlocks.
public final class ReticulumRuntime: ReticulumIdentityProvider {
    public static let shared = ReticulumRuntime()

    public struct LogLine: Equatable {
        public let timestamp: Double
        public let text: String
    }

    private final class RunningStack {
        let accountBasePath: String
        let client: UInt64
        let transport: ReticulumMeshTransport
        var rnodeHost: RNodeBluetoothHost?
        var rtnodeHost: RTNodeBluetoothHost?

        init(accountBasePath: String, client: UInt64, transport: ReticulumMeshTransport) {
            self.accountBasePath = accountBasePath
            self.client = client
            self.transport = transport
        }
    }

    let queue = Queue(name: "org.telegram.reticulum.runtime")
    /// Blocking stack calls (path requests, the RNode handshake, `rns_prns_ble_stop`) run here, off
    /// the runtime queue, so a wait never holds up a send.
    let blockingQueue = Queue(name: "org.telegram.reticulum.blocking", qos: .utility)

    private var settings: ReticulumSettings = .defaultSettings
    private var settingsInstalled = false
    /// An account that asked for its transport before the settings arrived.
    private var startWaitingForSettings: String?
    private let settingsDisposable = MetaDisposable()
    private var running: RunningStack?
    /// The transport of the running stack, keyed by the account directory it serves.
    private let transportPromise = Promise<(String, ReticulumTransport)?>(nil)
    private let logPipe = ValuePipe<LogLine>()
    private var recentLogLines: [LogLine] = []
    private let logLock = NSLock()
    public let version: String

    private init() {
        if let cString = tgrns_version() {
            self.version = String(cString: cString)
            rns_free_string(cString)
        } else {
            self.version = "unknown"
        }
        tgrns_set_log_callback({ context, line in
            guard let context = context, let line = line else {
                return
            }
            let runtime = Unmanaged<ReticulumRuntime>.fromOpaque(context).takeUnretainedValue()
            runtime.receiveLogLine(String(cString: line))
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    // MARK: - Settings

    /// Installs the settings the stack is configured from. Changing the nodes or the radios
    /// restarts the stack; the propagation node and the log level apply in place.
    public func install(settings: Signal<ReticulumSettings, NoError>) {
        self.settingsDisposable.set((settings
        |> deliverOn(self.queue)).start(next: { [weak self] settings in
            guard let self else {
                return
            }
            let previous = self.settings
            let firstInstall = !self.settingsInstalled
            self.settings = settings
            self.settingsInstalled = true
            // The local server's own behaviour on the mesh follows the same settings.
            LocalServerPreferences.sendsTypingIndicators = settings.sendsTypingIndicators
            if firstInstall {
                if let accountBasePath = self.startWaitingForSettings {
                    self.startWaitingForSettings = nil
                    if case let .failure(error) = self.start(accountBasePath: accountBasePath, createIdentity: false) {
                        Logger.shared.log("Reticulum", "Could not start the stack for \(accountBasePath): \(error)")
                    }
                }
                return
            }
            guard let running = self.running else {
                return
            }
            if previous.tcpNodes != settings.tcpNodes || previous.logLevel != settings.logLevel {
                self.restart(accountBasePath: running.accountBasePath)
                return
            }
            if previous.rnode != settings.rnode {
                self.applyRNodeSettings(running)
            }
            if previous.rtnodeEnabled != settings.rtnodeEnabled {
                self.applyRTNodeSettings(running)
            }
            if previous.propagationNode != settings.propagationNode {
                self.applyPropagationNode(running)
            }
        }))
    }

    public var currentSettings: ReticulumSettings {
        var settings = ReticulumSettings.defaultSettings
        self.queue.sync {
            settings = self.settings
        }
        return settings
    }

    // MARK: - Logging

    /// Every line the stack logs, for the Debug Settings screen.
    public var logLines: Signal<LogLine, NoError> {
        return self.logPipe.signal()
    }

    public func recentLog() -> [LogLine] {
        self.logLock.lock()
        defer {
            self.logLock.unlock()
        }
        return self.recentLogLines
    }

    private func receiveLogLine(_ text: String) {
        let line = LogLine(timestamp: Date().timeIntervalSince1970, text: text)
        Logger.shared.log("Reticulum", text)
        self.logLock.lock()
        self.recentLogLines.append(line)
        if self.recentLogLines.count > 500 {
            self.recentLogLines.removeFirst(self.recentLogLines.count - 500)
        }
        self.logLock.unlock()
        self.logPipe.putNext(line)
    }

    // MARK: - Paths

    public static func directory(accountBasePath: String) -> String {
        return accountBasePath + "/reticulum"
    }

    static func identityPath(accountBasePath: String) -> String {
        return self.directory(accountBasePath: accountBasePath) + "/identity"
    }

    public static func hasIdentity(accountBasePath: String) -> Bool {
        return FileManager.default.fileExists(atPath: self.identityPath(accountBasePath: accountBasePath))
    }

    private static func prepareDirectory(accountBasePath: String) throws -> String {
        let directory = self.directory(accountBasePath: accountBasePath)
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        for sub in ["lxmf_storage", "ble"] {
            try FileManager.default.createDirectory(atPath: directory + "/" + sub, withIntermediateDirectories: true, attributes: nil)
        }
        var url = URL(fileURLWithPath: directory)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return directory
    }

    // MARK: - ReticulumIdentityProvider

    public func createIdentity(accountBasePath: String) -> Signal<ReticulumAddress, ReticulumIdentityError> {
        return Signal { [weak self] subscriber in
            guard let self else {
                subscriber.putError(.failed("runtime gone"))
                return EmptyDisposable
            }
            self.queue.async {
                switch self.start(accountBasePath: accountBasePath, createIdentity: true) {
                case let .success(address):
                    subscriber.putNext(address)
                    subscriber.putCompletion()
                case let .failure(error):
                    subscriber.putError(error)
                }
            }
            return EmptyDisposable
        }
    }

    public func importIdentity(privateKey: Data, accountBasePath: String) -> Signal<ReticulumAddress, ReticulumIdentityError> {
        return Signal { [weak self] subscriber in
            guard let self else {
                subscriber.putError(.failed("runtime gone"))
                return EmptyDisposable
            }
            self.queue.async {
                guard privateKey.count == 64 else {
                    subscriber.putError(.failed("a private key is 64 bytes"))
                    return
                }
                do {
                    _ = try ReticulumRuntime.prepareDirectory(accountBasePath: accountBasePath)
                    self.stopIfRunning(accountBasePath: accountBasePath)
                    try privateKey.write(to: URL(fileURLWithPath: ReticulumRuntime.identityPath(accountBasePath: accountBasePath)), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                } catch {
                    subscriber.putError(.failed("could not write the identity: \(error)"))
                    return
                }
                switch self.start(accountBasePath: accountBasePath, createIdentity: false) {
                case let .success(address):
                    subscriber.putNext(address)
                    subscriber.putCompletion()
                case let .failure(error):
                    subscriber.putError(error)
                }
            }
            return EmptyDisposable
        }
    }

    public func exportIdentity(accountBasePath: String) -> Data? {
        guard let data = FileManager.default.contents(atPath: ReticulumRuntime.identityPath(accountBasePath: accountBasePath)), data.count == 64 else {
            return nil
        }
        return data
    }

    // MARK: - Transport for the engine factory

    /// The mesh transport for an account directory: the running one when it serves that
    /// directory, otherwise the stack is started for it if its identity exists. An account whose
    /// identity does not exist yet (onboarding) gets nil until `createIdentity`/`importIdentity`.
    public func transport(for environment: NetworkEngineAccountEnvironment) -> Signal<ReticulumTransport?, NoError> {
        let accountBasePath = environment.basePath
        self.queue.async { [weak self] in
            guard let self else {
                return
            }
            if let running = self.running, running.accountBasePath == accountBasePath {
                return
            }
            if ReticulumRuntime.hasIdentity(accountBasePath: accountBasePath) {
                if !self.settingsInstalled {
                    // The config file is written from the settings: wait for them.
                    self.startWaitingForSettings = accountBasePath
                    return
                }
                if case let .failure(error) = self.start(accountBasePath: accountBasePath, createIdentity: false) {
                    Logger.shared.log("Reticulum", "Could not start the stack for \(accountBasePath): \(error)")
                }
            }
        }
        return self.transportPromise.get()
        |> map { value -> ReticulumTransport? in
            guard let (path, transport) = value, path == accountBasePath else {
                return nil
            }
            return transport
        }
    }

    /// The running transport, for the settings screens.
    public var currentTransport: Signal<ReticulumTransport?, NoError> {
        return self.transportPromise.get()
        |> map { value -> ReticulumTransport? in
            return value?.1
        }
    }

    /// Restarts the stack with the current settings (the settings screen's "Apply").
    public func restart() {
        self.queue.async { [weak self] in
            guard let self, let running = self.running else {
                return
            }
            self.restart(accountBasePath: running.accountBasePath)
        }
    }

    /// Stops the stack and forgets the account's identity: logout.
    public func removeIdentity(accountBasePath: String) {
        self.queue.async { [weak self] in
            guard let self else {
                return
            }
            self.stopIfRunning(accountBasePath: accountBasePath)
            try? FileManager.default.removeItem(atPath: ReticulumRuntime.directory(accountBasePath: accountBasePath))
        }
    }

    // MARK: - Lifecycle (runtime queue)

    private enum StartResult {
        case success(ReticulumAddress)
        case failure(ReticulumIdentityError)
    }

    private func start(accountBasePath: String, createIdentity: Bool) -> StartResult {
        if let running = self.running {
            if running.accountBasePath == accountBasePath {
                return .success(running.transport.ownAddress)
            }
            self.stop(running)
        }
        let directory: String
        do {
            directory = try ReticulumRuntime.prepareDirectory(accountBasePath: accountBasePath)
            try ReticulumConfigFile.text(settings: self.settings).write(toFile: directory + "/config", atomically: true, encoding: .utf8)
        } catch {
            return .failure(.failed("could not prepare \(accountBasePath): \(error)"))
        }
        let identityPath = ReticulumRuntime.identityPath(accountBasePath: accountBasePath)
        if !createIdentity && !FileManager.default.fileExists(atPath: identityPath) {
            return .failure(.failed("no identity at \(identityPath)"))
        }
        let client = lxmf_client_start(directory, directory + "/lxmf_storage", identityPath, createIdentity ? 1 : 0, "", self.settings.logLevel, -1)
        if client == 0 {
            return .failure(.failed(ReticulumRuntime.lastError()))
        }
        var hashBytes = [UInt8](repeating: 0, count: 32)
        let count = lxmf_client_dest_hash(client, &hashBytes, 32)
        guard count == 16, let address = ReticulumAddress(hash: Data(hashBytes[0..<16])) else {
            lxmf_client_shutdown(client)
            return .failure(.failed("the delivery destination has no 16-byte hash (\(count))"))
        }
        let transport = ReticulumMeshTransport(client: client, ownAddress: address, queue: self.queue, blockingQueue: self.blockingQueue)
        let running = RunningStack(accountBasePath: accountBasePath, client: client, transport: transport)
        self.running = running
        self.applyPropagationNode(running)
        self.applyRNodeSettings(running)
        self.applyRTNodeSettings(running)
        transport.announce()
        self.transportPromise.set(.single((accountBasePath, transport)))
        Logger.shared.log("Reticulum", "Started \(self.version) for \(accountBasePath), address \(address.hex)")
        return .success(address)
    }

    private func restart(accountBasePath: String) {
        if let running = self.running {
            self.stop(running)
        }
        if case let .failure(error) = self.start(accountBasePath: accountBasePath, createIdentity: false) {
            Logger.shared.log("Reticulum", "Restart failed: \(error)")
        }
    }

    private func stopIfRunning(accountBasePath: String) {
        if let running = self.running, running.accountBasePath == accountBasePath {
            self.stop(running)
        }
    }

    private func stop(_ running: RunningStack) {
        self.transportPromise.set(.single(nil))
        running.rtnodeHost?.stop()
        running.rtnodeHost = nil
        running.rnodeHost?.stop()
        running.rnodeHost = nil
        running.transport.invalidate()
        if lxmf_client_shutdown(running.client) != 0 {
            Logger.shared.log("Reticulum", "Shutdown failed: \(ReticulumRuntime.lastError())")
        }
        if self.running === running {
            self.running = nil
        }
    }

    private func applyPropagationNode(_ running: RunningStack) {
        guard let hex = self.settings.propagationNode, let address = ReticulumAddress(hex: hex) else {
            return
        }
        let bytes = [UInt8](address.hash)
        if lxmf_client_set_propagation_node(running.client, bytes, UInt32(bytes.count)) != 0 {
            Logger.shared.log("Reticulum", "Propagation node refused: \(ReticulumRuntime.lastError())")
        }
    }

    private func applyRNodeSettings(_ running: RunningStack) {
        running.rnodeHost?.stop()
        running.rnodeHost = nil
        let rnode = self.settings.rnode
        guard rnode.enabled, let peripheralId = rnode.peripheralId else {
            return
        }
        let host = RNodeBluetoothHost(peripheralId: peripheralId, radio: TelegramCoreReticulumRadio(frequency: rnode.radio.frequency, bandwidth: rnode.radio.bandwidth, txPower: rnode.radio.txPower, spreadingFactor: rnode.radio.spreadingFactor, codingRate: rnode.radio.codingRate), blockingQueue: self.blockingQueue)
        running.rnodeHost = host
        host.start()
    }

    private func applyRTNodeSettings(_ running: RunningStack) {
        running.rtnodeHost?.stop()
        running.rtnodeHost = nil
        guard self.settings.rtnodeEnabled else {
            return
        }
        let host = RTNodeBluetoothHost(storageDirectory: ReticulumRuntime.directory(accountBasePath: running.accountBasePath) + "/ble", blockingQueue: self.blockingQueue)
        running.rtnodeHost = host
        host.start()
    }

    static func lastError() -> String {
        guard let cString = rns_last_error() else {
            return "unknown error"
        }
        let text = String(cString: cString)
        rns_free_string(cString)
        return text
    }
}
