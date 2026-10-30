import Foundation
import Postbox
import SwiftSignalKit
import MtProtoKit

/// The `NetworkEngine` of the Reticulum backend: every session is a view onto one `LocalServer`,
/// which answers requests from its store and the mesh. Nothing here speaks MTProto to anyone.
public final class ReticulumNetworkEngine: NetworkEngine {
    public let kind: NetworkEngineKind = .reticulum
    public let server: LocalServer

    public init(server: LocalServer) {
        self.server = server
    }

    public func makeSession(datacenterId: Int, role: NetworkEngineSessionRole, usageCalculationInfo: MTNetworkUsageCalculationInfo?, delegate: NetworkEngineSessionDelegate?) -> NetworkEngineSession {
        return ReticulumNetworkSession(server: self.server, datacenterId: datacenterId, role: role, delegate: delegate)
    }
}

private final class ReticulumRequestService: NetworkEngineRequestService {
    private let server: LocalServer

    init(server: LocalServer) {
        self.server = server
    }

    func add(_ request: NetworkEngineRequest) -> Disposable {
        return self.server.handle(request)
    }
}

private final class ReticulumNetworkSession: NetworkEngineSession {
    let datacenterId: Int
    let requestService: NetworkEngineRequestService
    private let server: LocalServer
    private let role: NetworkEngineSessionRole
    private weak var delegate: NetworkEngineSessionDelegate?
    private let stateDisposable = MetaDisposable()

    init(server: LocalServer, datacenterId: Int, role: NetworkEngineSessionRole, delegate: NetworkEngineSessionDelegate?) {
        self.server = server
        self.datacenterId = datacenterId
        self.role = role
        self.delegate = delegate
        self.requestService = ReticulumRequestService(server: server)
        if case .main = role, delegate != nil {
            self.stateDisposable.set(server.addStateObserver({ [weak self] state in
                self?.delegate?.networkSessionConnectionStateChanged(state)
            }))
        }
    }

    deinit {
        self.stateDisposable.dispose()
    }

    func setPaused(_ paused: Bool) {
        if case .main = self.role {
            self.server.setPaused(paused)
        }
    }

    func setOnline(_ online: Bool) {
    }

    func addUpdateSink(_ sink: NetworkEngineUpdateSink) {
        self.server.addUpdateSink(sink)
    }

    func stop() {
        self.stateDisposable.set(nil)
    }

    func movePendingRequests(to service: NetworkEngineRequestService, deadline: Double, completion: @escaping () -> Void) {
        // Requests complete on the server regardless of the session that submitted them.
        completion()
    }
}

/// Supplies `ReticulumNetworkEngine`s: one `LocalServer` per account directory, reused across the
/// networks an account opens (an unauthorized one, then the authorized one), each with the mesh
/// transport the app provides for that directory.
public final class ReticulumNetworkEngineFactory: NetworkEngineFactory {
    public typealias TransportProvider = (NetworkEngineAccountEnvironment) -> Signal<ReticulumTransport?, NoError>

    public let kind: NetworkEngineKind = .reticulum
    public let identityProvider: ReticulumIdentityProvider
    private let transportProvider: TransportProvider
    /// The factory for the MTProto engines (`.rust`), when the Debug Settings switch prefers one.
    private let fallback: NetworkEngineFactory?
    private let lock = NSLock()
    private var servers: [String: LocalServer] = [:]

    public init(identityProvider: ReticulumIdentityProvider, transportProvider: @escaping TransportProvider, fallback: NetworkEngineFactory? = nil) {
        self.identityProvider = identityProvider
        self.transportProvider = transportProvider
        self.fallback = fallback
    }

    public var supportsWebProxy: Bool {
        return self.fallback?.supportsWebProxy ?? false
    }

    public func makeEngine(context: MTContext, isAppExtension: Bool) -> NetworkEngine? {
        return self.fallback?.makeEngine(context: context, isAppExtension: isAppExtension)
    }

    public func makeEngine(context: MTContext, environment: NetworkEngineAccountEnvironment) -> NetworkEngine? {
        if environment.isAppExtension {
            return nil
        }
        guard let server = self.server(for: environment) else {
            return nil
        }
        return ReticulumNetworkEngine(server: server)
    }

    /// The account's server, for the onboarding that sets its identity before the network exists.
    public func server(for environment: NetworkEngineAccountEnvironment) -> LocalServer? {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        let path = environment.basePath + "/reticulum-server"
        if let server = self.servers[path] {
            return server
        }
        guard let server = LocalServer(basePath: path, encryptionParameters: environment.encryptionParameters, transport: self.transportProvider(environment)) else {
            Logger.shared.log("LocalServer", "Could not open the local server at \(path)")
            return nil
        }
        self.servers[path] = server
        return server
    }
}

/// The engine of a process that cannot reach the mesh: an app extension of a Reticulum build.
/// It never connects and answers every request with an error at once, so nothing in an extension
/// contacts the Telegram servers (there is no auth key for them) or waits on a network that will
/// not come. The Postbox still serves what the app stored.
public final class IdleNetworkEngine: NetworkEngine {
    public let kind: NetworkEngineKind = .reticulum
    private let reason: String

    public init(reason: String) {
        self.reason = reason
    }

    public func makeSession(datacenterId: Int, role: NetworkEngineSessionRole, usageCalculationInfo: MTNetworkUsageCalculationInfo?, delegate: NetworkEngineSessionDelegate?) -> NetworkEngineSession {
        return IdleNetworkSession(datacenterId: datacenterId, reason: self.reason, delegate: delegate)
    }
}

private final class IdleRequestService: NetworkEngineRequestService {
    private let reason: String

    init(reason: String) {
        self.reason = reason
    }

    func add(_ request: NetworkEngineRequest) -> Disposable {
        let info = NetworkEngineResponseInfo(timestamp: Date().timeIntervalSince1970, networkType: 0, duration: 0.0)
        request.completed(.failure(NetworkEngineRequestFailure(error: localServerError(500, self.reason), info: info)))
        return EmptyDisposable
    }
}

private final class IdleNetworkSession: NetworkEngineSession {
    let datacenterId: Int
    let requestService: NetworkEngineRequestService

    init(datacenterId: Int, reason: String, delegate: NetworkEngineSessionDelegate?) {
        self.datacenterId = datacenterId
        self.requestService = IdleRequestService(reason: reason)
        delegate?.networkSessionConnectionStateChanged(NetworkEngineConnectionState(isNetworkAvailable: false, isConnected: false, isUpdatingConnectionContext: false, isPerformingServiceTasks: false, proxyAddress: nil, proxyHasConnectionIssues: false))
    }

    func setPaused(_ paused: Bool) {
    }

    func setOnline(_ online: Bool) {
    }

    func addUpdateSink(_ sink: NetworkEngineUpdateSink) {
    }

    func stop() {
    }

    func movePendingRequests(to service: NetworkEngineRequestService, deadline: Double, completion: @escaping () -> Void) {
        completion()
    }
}
