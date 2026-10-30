import XCTest
import SwiftSignalKit
import MtProtoKit
import Postbox
@testable import TelegramApi
@testable import TelegramCore

/// A mesh in memory: what the server sends is recorded, what arrives is pushed by the test.
private final class FakeTransport: ReticulumTransport {
    let ownAddress: ReticulumAddress
    private let incomingPipe = ValuePipe<ReticulumIncomingMessage>()
    private let announcePipe = ValuePipe<ReticulumAnnounce>()
    private let interfacesPromise = Promise<[ReticulumInterfaceStatus]>([ReticulumInterfaceStatus(name: "Test", online: true, bitrate: nil, rssi: nil, snr: nil, rxBytes: 0, txBytes: 0)])
    private let lock = NSLock()
    private(set) var sent: [ReticulumOutgoingMessage] = []
    private(set) var pathRequests: [ReticulumAddress] = []
    var knownIdentities = Set<ReticulumAddress>()
    var displayName: String?
    /// What `send` answers: delivered by default.
    var outcome: ReticulumSendOutcome = .delivered
    var reachable = true

    init(address: ReticulumAddress) {
        self.ownAddress = address
    }

    var incomingMessages: Signal<ReticulumIncomingMessage, NoError> {
        return self.incomingPipe.signal()
    }

    var announces: Signal<ReticulumAnnounce, NoError> {
        return self.announcePipe.signal()
    }

    var interfaces: Signal<[ReticulumInterfaceStatus], NoError> {
        return self.interfacesPromise.get()
    }

    func send(_ message: ReticulumOutgoingMessage) -> Signal<ReticulumSendOutcome, NoError> {
        self.lock.lock()
        self.sent.append(message)
        let outcome = self.outcome
        self.lock.unlock()
        return .single(outcome)
    }

    func requestPath(to address: ReticulumAddress, timeout: Double) -> Signal<Bool, NoError> {
        self.lock.lock()
        self.pathRequests.append(address)
        let reachable = self.reachable
        self.lock.unlock()
        return .single(reachable)
    }

    func knowsIdentity(of address: ReticulumAddress) -> Bool {
        return self.knownIdentities.contains(address)
    }

    func announce() {
    }

    func setDisplayName(_ name: String) {
        self.displayName = name
    }

    func deliver(_ message: ReticulumIncomingMessage) {
        self.incomingPipe.putNext(message)
    }

    func hear(_ announce: ReticulumAnnounce) {
        self.announcePipe.putNext(announce)
    }

    var lastSent: ReticulumOutgoingMessage? {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.sent.last
    }
}

private final class RecordingSink: NetworkEngineUpdateSink {
    private let lock = NSLock()
    private(set) var received: [Api.Updates] = []
    var onReceive: ((Api.Updates) -> Void)?

    func networkSessionDidReset() {
    }

    func networkSessionDidReceive(message: Any) {
        guard let updates = (message as? BoxedMessage)?.body as? Api.Updates else {
            return
        }
        self.lock.lock()
        self.received.append(updates)
        self.lock.unlock()
        self.onReceive?(updates)
    }

    func updates() -> [Api.Update] {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        var result: [Api.Update] = []
        for item in self.received {
            if case let .updates(data) = item {
                result.append(contentsOf: data.updates)
            }
        }
        return result
    }
}

/// `LocalServer` driven through the engine seam: requests built by the generated builders, sent
/// as `NetworkEngineRequest`s and parsed by the builders' own parsers, as `Network.request` does.
final class LocalServerTests: XCTestCase {
    private var basePath: String!
    private var transport: FakeTransport!
    private var transportPromise: Promise<ReticulumTransport?>!
    private var server: LocalServer!
    private var engine: ReticulumNetworkEngine!
    private var session: NetworkEngineSession!
    private var sink: RecordingSink!

    static let ownAddress = ReticulumAddress(hex: "0123456789abcdef0123456789abcdef")!
    static let peerAddress = ReticulumAddress(hex: "91a664e798f1bee3ed0e9dec7c1d7c9f")!

    override func setUp() {
        super.setUp()
        self.basePath = NSTemporaryDirectory() + "LocalServerTests-" + UUID().uuidString
        self.transport = FakeTransport(address: LocalServerTests.ownAddress)
        self.transportPromise = Promise<ReticulumTransport?>(self.transport)
        self.server = LocalServer(basePath: self.basePath, encryptionParameters: nil, transport: self.transportPromise.get(), inMemory: true)
        XCTAssertNotNil(self.server)
        let ready = expectation(description: "identity")
        self.server.setSelfIdentity(address: LocalServerTests.ownAddress, firstName: "Ada", lastName: "Lovelace", completion: {
            ready.fulfill()
        })
        wait(for: [ready], timeout: 5.0)
        self.engine = ReticulumNetworkEngine(server: self.server)
        self.session = self.engine.makeSession(datacenterId: 1, role: .main, usageCalculationInfo: nil, delegate: nil)
        self.sink = RecordingSink()
        self.session.addUpdateSink(self.sink)
        self.session.setPaused(false)
    }

    override func tearDown() {
        self.session = nil
        self.engine = nil
        self.server = nil
        let _ = try? FileManager.default.removeItem(atPath: self.basePath)
        super.tearDown()
    }

    private enum Answer<T> {
        case result(T)
        case error(MTRpcError)
    }

    /// Runs a builder's call through the session, as `Network.request` would.
    private func call<T>(_ data: (FunctionDescription, Buffer, DeserializeFunctionResponse<T>), file: StaticString = #filePath, line: UInt = #line) -> Answer<T> {
        let done = expectation(description: data.0.name)
        var answer: Answer<T>?
        let request = NetworkEngineRequest(payload: data.1.makeData(), name: data.0.name, parse: { response in
            return data.2.parse(Buffer(data: response)).map { $0 as Any }
        }, shouldContinueAfterError: { _ in false }, completed: { result in
            switch result {
            case let .success(response):
                if let value = response.result as? T {
                    answer = .result(value)
                } else {
                    answer = .error(MTRpcError(errorCode: 500, errorDescription: "TL_VERIFICATION_ERROR"))
                }
            case let .failure(failure):
                answer = .error(failure.error)
            }
            done.fulfill()
        })
        let disposable = self.session.requestService.add(request)
        wait(for: [done], timeout: 10.0)
        disposable.dispose()
        guard let answer = answer else {
            XCTFail("\(data.0.name): no answer", file: file, line: line)
            return .error(MTRpcError(errorCode: 0, errorDescription: "NO_ANSWER"))
        }
        return answer
    }

    private func result<T>(_ data: (FunctionDescription, Buffer, DeserializeFunctionResponse<T>), file: StaticString = #filePath, line: UInt = #line) -> T? {
        switch self.call(data, file: file, line: line) {
        case let .result(value):
            return value
        case let .error(error):
            XCTFail("\(data.0.name): \(error.errorCode) \(error.errorDescription ?? "")", file: file, line: line)
            return nil
        }
    }

    private var selfUserId: Int64 {
        return LocalServerPeerIdentity.peerId(for: LocalServerTests.ownAddress).id._internalGetInt64Value()
    }

    private var peerUserId: Int64 {
        return LocalServerPeerIdentity.peerId(for: LocalServerTests.peerAddress).id._internalGetInt64Value()
    }

    private func incoming(text: String, hash: UInt8 = 1, fields: MsgPackValue = .nil, name: String? = "Grace Hopper") -> ReticulumIncomingMessage {
        return ReticulumIncomingMessage(hash: Data(repeating: hash, count: 32), source: LocalServerTests.peerAddress, title: Data(), content: Data(text.utf8), timestamp: Date().timeIntervalSince1970, signatureValid: true, fields: fields, displayName: name)
    }

    private func waitForUpdates(count: Int, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(5.0)
        while self.sink.received.count < count && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertGreaterThanOrEqual(self.sink.received.count, count, "pushed updates", file: file, line: line)
    }

    // MARK: - Identity

    func testAddressBecomesUserIdAccessHashAndUsername() {
        let peerId = LocalServerPeerIdentity.peerId(for: LocalServerTests.peerAddress)
        XCTAssertEqual(peerId.namespace, Namespaces.Peer.CloudUser)
        XCTAssertEqual(peerId.id._internalGetInt64Value(), 0x91a664e798f1be)
        XCTAssertEqual(LocalServerPeerIdentity.accessHash(for: LocalServerTests.peerAddress), Int64(bitPattern: 0xed0e9dec7c1d7c9f))
        XCTAssertEqual(LocalServerPeerIdentity.username(for: LocalServerTests.peerAddress), "91a664e798f1bee3ed0e9dec7c1d7c9f")
        XCTAssertEqual(LocalServerPeerIdentity.splitName("Grace Brewster Hopper").firstName, "Grace")
        XCTAssertEqual(LocalServerPeerIdentity.splitName("Grace Brewster Hopper").lastName, "Brewster Hopper")
        XCTAssertNil(ReticulumAddress(hex: "91a664e798f1bee3ed0e9dec7c1d7c9"))
    }

    // MARK: - Launch chain

    func testLaunchChainIsAnsweredFromTheStore() {
        guard case let .config(config)? = self.result(Api.functions.help.getConfig()) else {
            return XCTFail("config")
        }
        XCTAssertEqual(config.thisDc, 1)
        XCTAssertEqual(config.dcOptions.count, 1)

        guard case let .state(state)? = self.result(Api.functions.updates.getState()) else {
            return XCTFail("state")
        }
        XCTAssertEqual(state.unreadCount, 0)
        XCTAssertGreaterThan(state.pts, 0)

        guard case .differenceEmpty? = self.result(Api.functions.updates.getDifference(flags: 0, pts: state.pts, ptsLimit: nil, ptsTotalLimit: nil, date: state.date, qts: state.qts, qtsLimit: nil)) else {
            return XCTFail("difference")
        }

        guard case let .dialogs(dialogs)? = self.result(Api.functions.messages.getDialogs(flags: 0, folderId: nil, offsetDate: 0, offsetId: 0, offsetPeer: .inputPeerEmpty, limit: 100, hash: 0)) else {
            return XCTFail("dialogs")
        }
        XCTAssertEqual(dialogs.dialogs.count, 0)

        guard let users = self.result(Api.functions.users.getUsers(id: [.inputUserSelf])), users.count == 1, case let .user(me) = users[0] else {
            return XCTFail("self user")
        }
        XCTAssertEqual(me.id, self.selfUserId)
        XCTAssertEqual(me.firstName, "Ada")
        XCTAssertEqual(me.lastName, "Lovelace")
        XCTAssertEqual(me.username, LocalServerTests.ownAddress.hex)
        XCTAssertNotEqual(me.flags & (1 << 10), 0, "self flag")
        XCTAssertEqual(self.transport.displayName, "Ada Lovelace")

        guard case .appConfig? = self.result(Api.functions.help.getAppConfig(hash: 0)), case .appConfigNotModified? = self.result(Api.functions.help.getAppConfig(hash: LocalServer.appConfigHash)) else {
            return XCTFail("app config")
        }
        guard case .boolTrue? = self.result(Api.functions.account.updateStatus(offline: .boolFalse)) else {
            return XCTFail("status")
        }
        guard case let .password(password)? = self.result(Api.functions.account.getPassword()) else {
            return XCTFail("password")
        }
        XCTAssertEqual(password.flags & (1 << 2), 0)
    }

    func testUnimplementedFunctionsGetTheSchemaEmptyAnswerOrAnError() {
        // A Vector result: an empty vector.
        guard let hashes = self.result(Api.functions.upload.getFileHashes(location: .inputTakeoutFileLocation, offset: 0)) else {
            return XCTFail("vector")
        }
        XCTAssertEqual(hashes.count, 0)
        // A type with a *NotModified constructor.
        guard case .allStickersNotModified? = self.result(Api.functions.messages.getAllStickers(hash: 0)) else {
            return XCTFail("not modified")
        }
        // A type with neither: an error, not a hang.
        guard case let .error(error) = self.call(Api.functions.auth.exportAuthorization(dcId: 2)) else {
            return XCTFail("error expected")
        }
        XCTAssertEqual(error.errorCode, 400)
        XCTAssertEqual(error.errorDescription, "RETICULUM_UNSUPPORTED")
    }

    // MARK: - Messaging

    func testIncomingPlainLxmfBecomesAMessageAndADialog() {
        self.transport.deliver(self.incoming(text: "hello from the mesh"))
        self.waitForUpdates(count: 1)
        let updates = self.sink.updates()
        guard case let .updateNewMessage(data)? = updates.first, case let .message(message) = data.message else {
            return XCTFail("updateNewMessage expected, got \(updates)")
        }
        XCTAssertEqual(message.message, "hello from the mesh")
        XCTAssertEqual(message.flags & (1 << 1), 0, "incoming")
        guard case let .peerUser(peer) = message.peerId else {
            return XCTFail("peer")
        }
        XCTAssertEqual(peer.userId, self.peerUserId)
        if case let .updates(pushed)? = self.sink.received.first, case let .user(user)? = pushed.users.first {
            XCTAssertEqual(user.firstName, "Grace")
            XCTAssertEqual(user.lastName, "Hopper")
            XCTAssertEqual(user.username, LocalServerTests.peerAddress.hex)
        } else {
            XCTFail("the sender travels with the update")
        }

        guard case let .dialogs(dialogs)? = self.result(Api.functions.messages.getDialogs(flags: 0, folderId: nil, offsetDate: 0, offsetId: 0, offsetPeer: .inputPeerEmpty, limit: 100, hash: 0)), case let .dialog(dialog)? = dialogs.dialogs.first else {
            return XCTFail("dialog")
        }
        XCTAssertEqual(dialog.unreadCount, 1)
        XCTAssertEqual(dialog.topMessage, message.id)
        XCTAssertEqual(dialogs.messages.count, 1)

        let peer = Api.InputPeer.inputPeerUser(.init(userId: self.peerUserId, accessHash: LocalServerPeerIdentity.accessHash(for: LocalServerTests.peerAddress)))
        guard case let .messages(history)? = self.result(Api.functions.messages.getHistory(peer: peer, offsetId: 0, offsetDate: 0, addOffset: 0, limit: 50, maxId: 0, minId: 0, hash: 0)) else {
            return XCTFail("history")
        }
        XCTAssertEqual(history.messages.count, 1)

        // Reading it tells the peer (it speaks the envelope only after sending one; here it did not).
        guard case let .affectedMessages(affected)? = self.result(Api.functions.messages.readHistory(peer: peer, maxId: message.id)) else {
            return XCTFail("read")
        }
        XCTAssertEqual(affected.ptsCount, 1)
        XCTAssertNil(self.transport.lastSent, "a plain LXMF peer gets no read receipt")
        guard case let .state(state)? = self.result(Api.functions.updates.getState()) else {
            return XCTFail("state")
        }
        XCTAssertEqual(state.unreadCount, 0)

        // The same LXMF hash a second time is a duplicate.
        self.transport.deliver(self.incoming(text: "hello from the mesh"))
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(self.sink.updates().filter { if case .updateNewMessage = $0 { return true } else { return false } }.count, 1)
    }

    func testSendingCarriesTextAndTheEnvelopeAndAnswersAfterDelivery() {
        self.transport.deliver(self.incoming(text: "ping"))
        self.waitForUpdates(count: 1)
        let peer = Api.InputPeer.inputPeerUser(.init(userId: self.peerUserId, accessHash: 0))
        let entities: [Api.MessageEntity] = [.messageEntityBold(.init(offset: 0, length: 4))]
        guard case let .updateShortSentMessage(sent)? = self.result(Api.functions.messages.sendMessage(flags: 1 << 3, peer: peer, replyTo: nil, message: "pong back", randomId: 77, replyMarkup: nil, entities: entities, scheduleDate: nil, scheduleRepeatPeriod: nil, sendAs: nil, quickReplyShortcut: nil, effect: nil, allowPaidStars: nil, suggestedPost: nil, richMessage: nil)) else {
            return XCTFail("sent")
        }
        XCTAssertEqual(sent.ptsCount, 1)
        XCTAssertNotEqual(sent.flags & (1 << 1), 0, "out")
        guard let outgoing = self.transport.lastSent else {
            return XCTFail("nothing sent")
        }
        XCTAssertEqual(outgoing.destination, LocalServerTests.peerAddress)
        XCTAssertEqual(String(decoding: outgoing.content, as: UTF8.self), "pong back")
        XCTAssertEqual(outgoing.method, .direct)
        let fields = MsgPackValue.map(outgoing.fields.map { (key: MsgPackValue.int(Int64($0.id)), value: $0.value) })
        XCTAssertEqual(fields[0xFB]?.stringValue, LXMFEnvelope.customType)
        guard let envelope = LXMFEnvelope(fields: fields) else {
            return XCTFail("envelope")
        }
        XCTAssertEqual(envelope.kind, .message)
        XCTAssertEqual(envelope.text, "pong back")
        XCTAssertEqual(envelope.entities.count, 1)
        // The msgpack bytes the transport will put on the wire decode to the same map.
        XCTAssertEqual(MsgPackValue.decode(fields.encoded()), fields)

        // A resend with the same random id answers the stored message without a second LXMF.
        guard case let .updateShortSentMessage(again)? = self.result(Api.functions.messages.sendMessage(flags: 0, peer: peer, replyTo: nil, message: "pong back", randomId: 77, replyMarkup: nil, entities: nil, scheduleDate: nil, scheduleRepeatPeriod: nil, sendAs: nil, quickReplyShortcut: nil, effect: nil, allowPaidStars: nil, suggestedPost: nil, richMessage: nil)) else {
            return XCTFail("resend")
        }
        XCTAssertEqual(again.id, sent.id)
        XCTAssertEqual(self.transport.sent.count, 1)

        // The difference since before the exchange lists both messages.
        guard case let .difference(difference)? = self.result(Api.functions.updates.getDifference(flags: 0, pts: 1, ptsLimit: nil, ptsTotalLimit: nil, date: 0, qts: 0, qtsLimit: nil)) else {
            return XCTFail("difference")
        }
        XCTAssertEqual(difference.newMessages.count, 2)
        XCTAssertEqual(Set(difference.users.map { user -> Int64 in
            if case let .user(data) = user { return data.id }
            return 0
        }), Set([self.selfUserId, self.peerUserId]))
    }

    func testAFailedDeliveryIsAnErrorAndLeavesNothingBehind() {
        self.transport.deliver(self.incoming(text: "ping"))
        self.waitForUpdates(count: 1)
        self.transport.outcome = .failed("no path")
        let peer = Api.InputPeer.inputPeerUser(.init(userId: self.peerUserId, accessHash: 0))
        guard case let .error(error) = self.call(Api.functions.messages.sendMessage(flags: 0, peer: peer, replyTo: nil, message: "lost", randomId: 5, replyMarkup: nil, entities: nil, scheduleDate: nil, scheduleRepeatPeriod: nil, sendAs: nil, quickReplyShortcut: nil, effect: nil, allowPaidStars: nil, suggestedPost: nil, richMessage: nil)) else {
            return XCTFail("error expected")
        }
        XCTAssertEqual(error.errorDescription, "PEER_UNREACHABLE")
        guard case let .messages(history)? = self.result(Api.functions.messages.getHistory(peer: peer, offsetId: 0, offsetDate: 0, addOffset: 0, limit: 50, maxId: 0, minId: 0, hash: 0)) else {
            return XCTFail("history")
        }
        XCTAssertEqual(history.messages.count, 1, "only the incoming message remains")
    }

    func testEnvelopeControlMessagesFromATelegramPeer() {
        // A message with the envelope marks the peer as speaking it.
        var first = LXMFEnvelope(kind: .message)
        first.text = "with envelope"
        first.entities = [.messageEntityItalic(.init(offset: 0, length: 4))]
        let fields = MsgPackValue.map(first.fields(replyTo: nil).map { (key: MsgPackValue.int(Int64($0.id)), value: $0.value) })
        self.transport.deliver(self.incoming(text: "with envelope", hash: 1, fields: fields))
        self.waitForUpdates(count: 1)
        guard case let .updateNewMessage(data)? = self.sink.updates().first, case let .message(message) = data.message else {
            return XCTFail("message")
        }
        XCTAssertEqual(message.entities?.count, 1)

        // Our read receipt now goes out as an envelope.
        let peer = Api.InputPeer.inputPeerUser(.init(userId: self.peerUserId, accessHash: 0))
        let _ = self.result(Api.functions.messages.readHistory(peer: peer, maxId: message.id))
        guard let receipt = self.transport.lastSent, let receiptEnvelope = LXMFEnvelope(fields: .map(receipt.fields.map { (key: MsgPackValue.int(Int64($0.id)), value: $0.value) })) else {
            return XCTFail("read receipt")
        }
        XCTAssertEqual(receiptEnvelope.kind, .read)
        XCTAssertEqual(receiptEnvelope.target, Data(repeating: 1, count: 32))
        XCTAssertTrue(receipt.content.isEmpty)

        // Their edit of that message.
        var edit = LXMFEnvelope(kind: .edit)
        edit.target = Data(repeating: 1, count: 32)
        edit.text = "edited"
        self.transport.deliver(self.incoming(text: "", hash: 2, fields: .map(edit.fields(replyTo: nil).map { (key: MsgPackValue.int(Int64($0.id)), value: $0.value) })))
        self.waitForUpdates(count: 2)
        guard case let .updateEditMessage(edited)? = self.sink.updates().last, case let .message(editedMessage) = edited.message else {
            return XCTFail("edit")
        }
        XCTAssertEqual(editedMessage.message, "edited")
        XCTAssertEqual(editedMessage.id, message.id)

        // Their reaction, then their deletion.
        var reaction = LXMFEnvelope(kind: .reaction)
        reaction.target = Data(repeating: 1, count: 32)
        reaction.reaction = "👍"
        self.transport.deliver(self.incoming(text: "", hash: 3, fields: .map(reaction.fields(replyTo: nil).map { (key: MsgPackValue.int(Int64($0.id)), value: $0.value) })))
        self.waitForUpdates(count: 3)
        guard case let .updateMessageReactions(reacted)? = self.sink.updates().last, case let .messageReactions(reactions) = reacted.reactions else {
            return XCTFail("reaction")
        }
        XCTAssertEqual(reactions.results.count, 1)

        var delete = LXMFEnvelope(kind: .delete)
        delete.targets = [Data(repeating: 1, count: 32)]
        self.transport.deliver(self.incoming(text: "", hash: 4, fields: .map(delete.fields(replyTo: nil).map { (key: MsgPackValue.int(Int64($0.id)), value: $0.value) })))
        self.waitForUpdates(count: 4)
        guard case let .updateDeleteMessages(deleted)? = self.sink.updates().last else {
            return XCTFail("delete")
        }
        XCTAssertEqual(deleted.messages, [message.id])
        guard case let .messages(history)? = self.result(Api.functions.messages.getHistory(peer: peer, offsetId: 0, offsetDate: 0, addOffset: 0, limit: 50, maxId: 0, minId: 0, hash: 0)) else {
            return XCTFail("history")
        }
        XCTAssertEqual(history.messages.count, 0)
    }

    func testResolvingAnAddressAsksTheMeshForAPath() {
        guard case let .resolvedPeer(resolved)? = self.result(Api.functions.contacts.resolveUsername(flags: 0, username: LocalServerTests.peerAddress.hex, referer: nil)) else {
            return XCTFail("resolved")
        }
        guard case let .peerUser(peer) = resolved.peer else {
            return XCTFail("peer")
        }
        XCTAssertEqual(peer.userId, self.peerUserId)
        XCTAssertEqual(self.transport.pathRequests, [LocalServerTests.peerAddress])

        self.transport.reachable = false
        guard case let .error(error) = self.call(Api.functions.contacts.resolveUsername(flags: 0, username: "ffffffffffffffffffffffffffffffff", referer: nil)) else {
            return XCTFail("unreachable")
        }
        XCTAssertEqual(error.errorDescription, "USERNAME_NOT_OCCUPIED")
        guard case let .error(invalid) = self.call(Api.functions.contacts.resolveUsername(flags: 0, username: "not-an-address", referer: nil)) else {
            return XCTFail("invalid")
        }
        XCTAssertEqual(invalid.errorDescription, "USERNAME_INVALID")
    }

    func testAnnounceNamesAKnownPeer() {
        self.transport.deliver(self.incoming(text: "hi", name: nil))
        self.waitForUpdates(count: 1)
        self.transport.hear(ReticulumAnnounce(address: LocalServerTests.peerAddress, displayName: "Grace Hopper", timestamp: Date().timeIntervalSince1970))
        self.waitForUpdates(count: 2)
        guard let users = self.result(Api.functions.users.getUsers(id: [.inputUser(.init(userId: self.peerUserId, accessHash: 0))])), case let .user(user)? = users.first else {
            return XCTFail("user")
        }
        XCTAssertEqual(user.firstName, "Grace")
        XCTAssertEqual(user.lastName, "Hopper")
    }

    func testMsgPackRoundTrip() {
        let value = MsgPackValue.map([
            (.int(1), .uint(5)),
            (.int(0xFC), .binary(Data([0, 1, 255]))),
            (.int(-3), .string("héllo")),
            (.int(300), .array([.bool(true), .nil, .float(1.5), .int(-200), .uint(70000), .uint(5_000_000_000)])),
            (.string("k"), .map([(.int(7), .int(Int64.min))])),
        ])
        XCTAssertEqual(MsgPackValue.decode(value.encoded()), value)
        XCTAssertNil(MsgPackValue.decode(Data([0x92, 0x01])))
        XCTAssertEqual(value[1]?.intValue, 5)
        XCTAssertEqual(value[0xFC]?.binaryValue, Data([0, 1, 255]))
        XCTAssertEqual(MsgPackValue.uint(5), MsgPackValue.int(5))
    }
}
