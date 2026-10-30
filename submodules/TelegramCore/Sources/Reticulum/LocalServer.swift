import Foundation
import Postbox
import SwiftSignalKit
import MtProtoKit
internal import TelegramApi

/// An error the local server answers a request with, in the server's own vocabulary.
func localServerError(_ code: Int32, _ text: String) -> MTRpcError {
    return MTRpcError(errorCode: code, errorDescription: text)
}

/// A request's end: the result's wire bytes, or the error the client gets. (`MTRpcError` is not a
/// Swift `Error`, so this is not a `Result`.)
enum LocalServerCompletion {
    case success(Data)
    case failure(MTRpcError)
}

/// What a handler answers with: an `Api.*` value or a vector of them (serialized by
/// `Api.serializeFunctionResult`), or bytes already in the result's wire form.
enum LocalServerAnswer {
    case value(Any)
    case bytes(Buffer)
}

typealias LocalServerHandler = (LocalServer, ApiFunctionCall) -> Signal<LocalServerAnswer, MTRpcError>

/// The in-process server behind `ReticulumNetworkEngine`: it answers the client's own MTProto
/// calls from `LocalServerStore` and carries messages over the mesh through a
/// `ReticulumTransport`. One per account; every session of the account's `Network` (main and
/// workers) reaches the same server. All state changes on `queue`.
///
/// Peers are LXMF addresses: the 16-byte destination hash gives the 56-bit user id (its first
/// seven bytes) and the access hash (its last eight), see `LocalServerPeerIdentity`.
public final class LocalServer {
    public let queue = Queue(name: "org.telegram.reticulum.local-server")
    let store: LocalServerStore
    let basePath: String

    private var handlers: [String: LocalServerHandler] = [:]
    private var unsupportedLogged = Set<String>()

    private(set) var transport: ReticulumTransport?
    private let transportDisposable = MetaDisposable()
    private let incomingDisposable = MetaDisposable()
    private let announceDisposable = MetaDisposable()
    private let interfacesDisposable = MetaDisposable()
    private(set) var interfaces: [ReticulumInterfaceStatus] = []

    private final class WeakSink {
        weak var sink: NetworkEngineUpdateSink?
        init(_ sink: NetworkEngineUpdateSink) {
            self.sink = sink
        }
    }
    private var sinks: [WeakSink] = []
    private var stateObservers = Bag<(NetworkEngineConnectionState) -> Void>()
    private var isPaused = true
    private var lastReportedState: NetworkEngineConnectionState?

    /// `transport` delivers the mesh transport once the account's identity exists (nil before and
    /// after); the server answers requests without one and starts carrying messages when it arrives.
    public init?(basePath: String, encryptionParameters: ValueBoxEncryptionParameters?, transport: Signal<ReticulumTransport?, NoError>, inMemory: Bool = false) {
        self.basePath = basePath
        var store: LocalServerStore?
        let queue = self.queue
        queue.sync {
            store = LocalServerStore(basePath: basePath, queue: queue, encryptionParameters: encryptionParameters, inMemory: inMemory)
        }
        guard let store = store else {
            return nil
        }
        self.store = store
        self.handlers = self.launchHandlers().merging(self.messagingHandlers(), uniquingKeysWith: { _, second in second }).merging(self.mediaHandlers(), uniquingKeysWith: { _, second in second })

        self.transportDisposable.set((transport
        |> deliverOn(self.queue)).start(next: { [weak self] transport in
            self?.attach(transport: transport)
        }))
    }

    deinit {
        self.transportDisposable.dispose()
        self.incomingDisposable.dispose()
        self.announceDisposable.dispose()
        self.interfacesDisposable.dispose()
    }

    // MARK: - Time and ids

    func now() -> Int32 {
        return Int32(Date().timeIntervalSince1970)
    }

    /// The next pts, recorded in the store's state.
    func allocatePts() -> Int32 {
        var state = self.store.state()
        state.pts += 1
        state.date = self.now()
        self.store.setState(state)
        return state.pts
    }

    func allocateMessageId() -> Int32 {
        var state = self.store.state()
        let id = state.nextMessageId
        state.nextMessageId += 1
        self.store.setState(state)
        return id
    }

    // MARK: - Transport

    private func attach(transport: ReticulumTransport?) {
        self.transport = transport
        self.incomingDisposable.set(nil)
        self.announceDisposable.set(nil)
        self.interfacesDisposable.set(nil)
        self.interfaces = []
        guard let transport = transport else {
            self.reportConnectionState()
            return
        }
        self.adoptIdentity(address: transport.ownAddress)
        self.incomingDisposable.set((transport.incomingMessages
        |> deliverOn(self.queue)).start(next: { [weak self] message in
            self?.receiveIncoming(message)
        }))
        self.announceDisposable.set((transport.announces
        |> deliverOn(self.queue)).start(next: { [weak self] announce in
            self?.receiveAnnounce(announce)
        }))
        self.interfacesDisposable.set((transport.interfaces
        |> deliverOn(self.queue)).start(next: { [weak self] interfaces in
            guard let self = self else {
                return
            }
            self.interfaces = interfaces
            self.reportConnectionState()
        }))
        self.reportConnectionState()
    }

    // MARK: - Sessions

    func addUpdateSink(_ sink: NetworkEngineUpdateSink) {
        self.queue.async {
            self.sinks = self.sinks.filter { $0.sink != nil }
            self.sinks.append(WeakSink(sink))
        }
    }

    func addStateObserver(_ observer: @escaping (NetworkEngineConnectionState) -> Void) -> Disposable {
        let index = Atomic<Bag<(NetworkEngineConnectionState) -> Void>.Index?>(value: nil)
        self.queue.async {
            let _ = index.swap(self.stateObservers.add(observer))
            observer(self.connectionState())
        }
        return ActionDisposable { [weak self] in
            guard let self = self else {
                return
            }
            self.queue.async {
                if let value = index.swap(nil) {
                    self.stateObservers.remove(value)
                }
            }
        }
    }

    func setPaused(_ paused: Bool) {
        self.queue.async {
            if self.isPaused != paused {
                self.isPaused = paused
                self.reportConnectionState()
            }
        }
    }

    /// Connected whenever the server runs: it answers from the store without a mesh. The network is
    /// "available" while an interface is online, or before a transport exists at all (the title
    /// should not read "Waiting for network" during onboarding).
    func connectionState() -> NetworkEngineConnectionState {
        let networkAvailable = self.transport == nil || self.interfaces.contains(where: { $0.online })
        return NetworkEngineConnectionState(
            isNetworkAvailable: networkAvailable,
            isConnected: !self.isPaused,
            isUpdatingConnectionContext: false,
            isPerformingServiceTasks: false,
            proxyAddress: nil,
            proxyHasConnectionIssues: false
        )
    }

    private func reportConnectionState() {
        let state = self.connectionState()
        if state == self.lastReportedState {
            return
        }
        self.lastReportedState = state
        for observer in self.stateObservers.copyItems() {
            observer(state)
        }
    }

    // MARK: - Requests

    /// Answers one request as a server would, from `queue`. The returned disposable cancels it:
    /// nothing is delivered after that.
    public func handle(_ request: NetworkEngineRequest) -> Disposable {
        let cancelled = Atomic<Bool>(value: false)
        let running = MetaDisposable()
        let started = Date()
        self.queue.async {
            if cancelled.with({ $0 }) {
                return
            }
            let complete: (LocalServerCompletion) -> Void = { result in
                if cancelled.swap(true) {
                    return
                }
                let info = NetworkEngineResponseInfo(timestamp: Date().timeIntervalSince1970, networkType: 0, duration: Date().timeIntervalSince(started))
                switch result {
                case let .success(data):
                    if let parsed = request.parse(data) {
                        request.completed(.success(NetworkEngineResponse(result: parsed, info: info)))
                    } else {
                        request.completed(.failure(NetworkEngineRequestFailure(error: localServerError(500, "TL_PARSING_ERROR"), info: info)))
                    }
                case let .failure(error):
                    request.completed(.failure(NetworkEngineRequestFailure(error: error, info: info)))
                }
            }
            guard let call = Api.parseFunctionCall(Buffer(data: request.payload)) else {
                Logger.shared.log("LocalServer", "Request \(request.shortMetadata) could not be decoded")
                complete(.failure(localServerError(400, "INPUT_METHOD_INVALID")))
                return
            }
            running.set((self.dispatch(call)
            |> deliverOn(self.queue)).start(next: { answer in
                switch answer {
                case let .value(value):
                    if let buffer = Api.serializeFunctionResult(value) {
                        complete(.success(buffer.makeData()))
                    } else {
                        Logger.shared.log("LocalServer", "\(call.name): the handler answered with a value that is not a result (\(type(of: value)))")
                        complete(.failure(localServerError(500, "INTERNAL_SERVER_ERROR")))
                    }
                case let .bytes(buffer):
                    complete(.success(buffer.makeData()))
                }
            }, error: { error in
                complete(.failure(error))
            }, completed: {
                if !cancelled.with({ $0 }) {
                    complete(.failure(localServerError(500, "INTERNAL_SERVER_ERROR")))
                }
            }))
        }
        return ActionDisposable {
            let _ = cancelled.swap(true)
            running.dispose()
        }
    }

    /// Routes a decoded call to its handler. A function without one gets the schema's empty
    /// answer where the result type has one (an empty vector, `boolTrue`, `*NotModified`), so the
    /// client's retry loops settle, and `400 RETICULUM_UNSUPPORTED` otherwise.
    func dispatch(_ call: ApiFunctionCall) -> Signal<LocalServerAnswer, MTRpcError> {
        if let handler = self.handlers[call.name] {
            return handler(self, call)
        }
        if !self.unsupportedLogged.contains(call.name) {
            self.unsupportedLogged.insert(call.name)
            Logger.shared.log("LocalServer", "\(call.name): no handler, answering with the schema's empty result if there is one")
        }
        if let empty = call.emptyResult() {
            return .single(.bytes(empty))
        }
        return .fail(localServerError(400, "RETICULUM_UNSUPPORTED"))
    }

    // MARK: - Updates

    /// Pushes `updates` to every session that listens, as a server does, and records the
    /// pts-bearing ones for `updates.getDifference`. Every update that carries a pts must have
    /// taken it from `allocatePts()` already.
    func emit(_ updates: [Api.Update], users: [Api.User] = []) {
        var state = self.store.state()
        state.seq += 1
        state.date = self.now()
        self.store.setState(state)
        for update in updates {
            if let pts = localServerUpdatePts(update) {
                let buffer = Buffer()
                update.serialize(buffer, true)
                self.store.appendEvent(pts: pts, bytes: buffer.makeData())
            }
        }
        self.pruneEvents()
        let message = Api.Updates.updates(.init(updates: updates, users: users, chats: [], date: state.date, seq: state.seq))
        self.push(message)
    }

    func push(_ updates: Api.Updates) {
        self.sinks = self.sinks.filter { $0.sink != nil }
        let boxed = BoxedMessage(updates)
        for sink in self.sinks {
            sink.sink?.networkSessionDidReceive(message: boxed)
        }
    }

    /// The pts log holds a bounded tail: beyond it `updates.getDifference` answers
    /// `differenceTooLong`, which makes the client reload its dialogs from this server.
    private func pruneEvents() {
        let keep: Int32 = 5000
        let pts = self.store.state().pts
        if pts > keep, let oldest = self.store.oldestEventPts(), oldest < pts - keep {
            self.store.pruneEvents(below: pts - keep)
        }
    }
}

/// The pts an update carries, nil for updates outside the pts sequence.
func localServerUpdatePts(_ update: Api.Update) -> Int32? {
    switch update {
    case let .updateNewMessage(data):
        return data.pts
    case let .updateDeleteMessages(data):
        return data.pts
    case let .updateEditMessage(data):
        return data.pts
    case let .updateReadHistoryInbox(data):
        return data.pts
    case let .updateReadHistoryOutbox(data):
        return data.pts
    default:
        return nil
    }
}
