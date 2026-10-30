import Foundation
import Postbox
import SwiftSignalKit

/// The local server's own database: what a Telegram server keeps about an account, for one account,
/// in a second `SqliteValueBox` beside the Postbox (`<account>/reticulum-server/`). It is the
/// server's state, not the client's: the Postbox still learns everything through updates and
/// requests, exactly as from a remote server. Every method runs on `queue`.
final class LocalServerStore {
    struct State: Codable, Equatable {
        var pts: Int32
        var qts: Int32
        var seq: Int32
        var date: Int32
        var nextMessageId: Int32

        static var initial: State {
            return State(pts: 1, qts: 0, seq: 1, date: Int32(Date().timeIntervalSince1970), nextMessageId: 1)
        }
    }

    /// A peer the server knows: the 16-byte LXMF address behind a Telegram user id.
    struct PeerRecord: Codable, Equatable {
        var peerId: Int64
        var accessHash: Int64
        var destinationHash: Data
        var firstName: String
        var lastName: String
        /// The name the peer announced or sent, kept apart from a name the user assigned as a contact.
        var announcedName: String?
        var lastAnnounceTimestamp: Double?
        var isContact: Bool
        /// The peer has sent a message carrying the Telegram envelope: control messages (typing,
        /// read receipts, edits) are worth sending to it.
        var speaksTelegram: Bool
        var lastSeenTimestamp: Int32?
        var photoId: Int64?
    }

    struct DialogRecord: Codable, Equatable {
        var peerId: Int64
        var topMessageId: Int32
        var topMessageDate: Int32
        var readInboxMaxId: Int32
        var readOutboxMaxId: Int32
        var unreadCount: Int32
        var pinned: Bool
    }

    private enum Table {
        static let state = ValueBoxTable(id: 1, keyType: .binary, compactValuesOnCreation: false)
        static let peers = ValueBoxTable(id: 2, keyType: .binary, compactValuesOnCreation: false)
        static let peersByHash = ValueBoxTable(id: 3, keyType: .binary, compactValuesOnCreation: false)
        static let dialogs = ValueBoxTable(id: 4, keyType: .binary, compactValuesOnCreation: false)
        static let messages = ValueBoxTable(id: 5, keyType: .binary, compactValuesOnCreation: false)
        static let events = ValueBoxTable(id: 6, keyType: .binary, compactValuesOnCreation: false)
        static let randomIds = ValueBoxTable(id: 7, keyType: .binary, compactValuesOnCreation: false)
        static let messageHashes = ValueBoxTable(id: 8, keyType: .binary, compactValuesOnCreation: false)
        static let files = ValueBoxTable(id: 9, keyType: .binary, compactValuesOnCreation: false)
        static let messagePeers = ValueBoxTable(id: 10, keyType: .binary, compactValuesOnCreation: false)
    }

    let queue: Queue
    let basePath: String
    private let valueBox: SqliteValueBox
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// Opens (or creates) the store at `basePath`. `queue` must be current. `inMemory` is for tests.
    init?(basePath: String, queue: Queue, encryptionParameters: ValueBoxEncryptionParameters?, inMemory: Bool = false) {
        precondition(queue.isCurrent())
        self.queue = queue
        self.basePath = basePath
        if !inMemory {
            let _ = try? FileManager.default.createDirectory(atPath: basePath, withIntermediateDirectories: true, attributes: nil)
        }
        guard let valueBox = SqliteValueBox(basePath: basePath + "/db", queue: queue, isTemporary: inMemory, isReadOnly: false, useCaches: false, removeDatabaseOnError: false, encryptionParameters: encryptionParameters, upgradeProgress: { _ in }, inMemory: inMemory) else {
            return nil
        }
        self.valueBox = valueBox
    }

    // MARK: - Keys

    private static func key(_ string: String) -> ValueBoxKey {
        return ValueBoxKey(string)
    }

    private static func key(int64 value: Int64) -> ValueBoxKey {
        let key = ValueBoxKey(length: 8)
        key.setInt64(0, value: value)
        return key
    }

    private static func key(peerId: Int64, messageId: Int32) -> ValueBoxKey {
        let key = ValueBoxKey(length: 12)
        key.setInt64(0, value: peerId)
        key.setInt32(8, value: messageId)
        return key
    }

    private static func key(data: Data) -> ValueBoxKey {
        let key = ValueBoxKey(length: data.count)
        key.setData(0, value: data)
        return key
    }

    // MARK: - Codable values

    private func read<T: Decodable>(_ table: ValueBoxTable, key: ValueBoxKey, as type: T.Type) -> T? {
        guard let buffer = self.valueBox.get(table, key: key) else {
            return nil
        }
        return try? self.decoder.decode(type, from: buffer.makeData())
    }

    private func write<T: Encodable>(_ table: ValueBoxTable, key: ValueBoxKey, value: T) {
        guard let data = try? self.encoder.encode(value) else {
            return
        }
        self.valueBox.set(table, key: key, value: MemoryBuffer(data: data))
    }

    // MARK: - Transactions

    func transaction<T>(_ f: () -> T) -> T {
        precondition(self.queue.isCurrent())
        self.valueBox.begin()
        let result = f()
        self.valueBox.commit()
        return result
    }

    // MARK: - State and settings

    func state() -> State {
        return self.read(Table.state, key: LocalServerStore.key("state"), as: State.self) ?? State.initial
    }

    func setState(_ state: State) {
        self.write(Table.state, key: LocalServerStore.key("state"), value: state)
    }

    func setting(_ name: String) -> Data? {
        return self.valueBox.get(Table.state, key: LocalServerStore.key("setting:" + name))?.makeData()
    }

    func setSetting(_ name: String, _ value: Data?) {
        if let value = value {
            self.valueBox.set(Table.state, key: LocalServerStore.key("setting:" + name), value: MemoryBuffer(data: value))
        } else {
            self.valueBox.remove(Table.state, key: LocalServerStore.key("setting:" + name), secure: false)
        }
    }

    // MARK: - Peers

    func peer(id: Int64) -> PeerRecord? {
        return self.read(Table.peers, key: LocalServerStore.key(int64: id), as: PeerRecord.self)
    }

    func peer(destinationHash: Data) -> PeerRecord? {
        guard let buffer = self.valueBox.get(Table.peersByHash, key: LocalServerStore.key(data: destinationHash)), buffer.length == 8 else {
            return nil
        }
        var peerId: Int64 = 0
        buffer.read(&peerId, offset: 0, length: 8)
        return self.peer(id: peerId)
    }

    func setPeer(_ record: PeerRecord) {
        self.write(Table.peers, key: LocalServerStore.key(int64: record.peerId), value: record)
        var peerId = record.peerId
        self.valueBox.set(Table.peersByHash, key: LocalServerStore.key(data: record.destinationHash), value: MemoryBuffer(data: Data(bytes: &peerId, count: 8)))
    }

    func allPeers() -> [PeerRecord] {
        var result: [PeerRecord] = []
        self.valueBox.scan(Table.peers, values: { _, buffer in
            if let record = try? self.decoder.decode(PeerRecord.self, from: buffer.makeData()) {
                result.append(record)
            }
            return true
        })
        return result
    }

    // MARK: - Dialogs

    func dialog(peerId: Int64) -> DialogRecord? {
        return self.read(Table.dialogs, key: LocalServerStore.key(int64: peerId), as: DialogRecord.self)
    }

    func setDialog(_ record: DialogRecord) {
        self.write(Table.dialogs, key: LocalServerStore.key(int64: record.peerId), value: record)
    }

    func removeDialog(peerId: Int64) {
        self.valueBox.remove(Table.dialogs, key: LocalServerStore.key(int64: peerId), secure: false)
    }

    /// Every dialog, newest top message first.
    func allDialogs() -> [DialogRecord] {
        var result: [DialogRecord] = []
        self.valueBox.scan(Table.dialogs, values: { _, buffer in
            if let record = try? self.decoder.decode(DialogRecord.self, from: buffer.makeData()) {
                result.append(record)
            }
            return true
        })
        return result.sorted(by: { lhs, rhs in
            if lhs.topMessageDate != rhs.topMessageDate {
                return lhs.topMessageDate > rhs.topMessageDate
            }
            return lhs.topMessageId > rhs.topMessageId
        })
    }

    // MARK: - Messages (TL bytes of an Api.Message, keyed by peer and id)

    func message(peerId: Int64, id: Int32) -> Data? {
        return self.valueBox.get(Table.messages, key: LocalServerStore.key(peerId: peerId, messageId: id))?.makeData()
    }

    func setMessage(peerId: Int64, id: Int32, bytes: Data) {
        self.valueBox.set(Table.messages, key: LocalServerStore.key(peerId: peerId, messageId: id), value: MemoryBuffer(data: bytes))
        var peerIdValue = peerId
        self.valueBox.set(Table.messagePeers, key: LocalServerStore.key(int64: Int64(id)), value: MemoryBuffer(data: Data(bytes: &peerIdValue, count: 8)))
    }

    func removeMessage(peerId: Int64, id: Int32) {
        self.valueBox.remove(Table.messages, key: LocalServerStore.key(peerId: peerId, messageId: id), secure: false)
        self.valueBox.remove(Table.messagePeers, key: LocalServerStore.key(int64: Int64(id)), secure: false)
    }

    /// The peer a message id belongs to: ids are allocated per account, so one id names one message.
    func messagePeer(id: Int32) -> Int64? {
        guard let buffer = self.valueBox.get(Table.messagePeers, key: LocalServerStore.key(int64: Int64(id))), buffer.length == 8 else {
            return nil
        }
        var peerId: Int64 = 0
        buffer.read(&peerId, offset: 0, length: 8)
        return peerId
    }

    /// Messages of `peerId` with ids strictly below `upperBound` (`Int32.max` for all), newest first.
    func history(peerId: Int64, below upperBound: Int32, limit: Int) -> [(id: Int32, bytes: Data)] {
        var result: [(id: Int32, bytes: Data)] = []
        guard limit > 0, upperBound > 0 else {
            return result
        }
        let start = LocalServerStore.key(peerId: peerId, messageId: upperBound)
        let end = LocalServerStore.key(peerId: peerId, messageId: 0)
        self.valueBox.range(Table.messages, start: start, end: end, values: { key, buffer in
            result.append((key.getInt32(8), buffer.makeData()))
            return true
        }, limit: limit)
        return result
    }

    /// Every message id of `peerId`, ascending.
    func messageIds(peerId: Int64) -> [Int32] {
        var result: [Int32] = []
        let start = LocalServerStore.key(peerId: peerId, messageId: 0)
        let end = LocalServerStore.key(peerId: peerId, messageId: Int32.max)
        self.valueBox.range(Table.messages, start: start, end: end, keys: { key in
            result.append(key.getInt32(8))
            return true
        }, limit: 0)
        return result
    }

    /// The server-side id of a message by the sender's random id (a resend answers the same id).
    func messageId(randomId: Int64) -> (peerId: Int64, id: Int32)? {
        guard let buffer = self.valueBox.get(Table.randomIds, key: LocalServerStore.key(int64: randomId)), buffer.length == 12 else {
            return nil
        }
        var peerId: Int64 = 0
        var id: Int32 = 0
        buffer.read(&peerId, offset: 0, length: 8)
        buffer.read(&id, offset: 8, length: 4)
        return (peerId, id)
    }

    func setMessageId(randomId: Int64, peerId: Int64, id: Int32) {
        var peerIdValue = peerId
        var idValue = id
        var data = Data(bytes: &peerIdValue, count: 8)
        data.append(Data(bytes: &idValue, count: 4))
        self.valueBox.set(Table.randomIds, key: LocalServerStore.key(int64: randomId), value: MemoryBuffer(data: data))
    }

    /// The LXMF hash (32 bytes) of a message, in both directions.
    func messageHash(peerId: Int64, id: Int32) -> Data? {
        return self.valueBox.get(Table.messageHashes, key: LocalServerStore.key(peerId: peerId, messageId: id))?.makeData()
    }

    func messageId(lxmfHash: Data) -> (peerId: Int64, id: Int32)? {
        guard let buffer = self.valueBox.get(Table.messageHashes, key: LocalServerStore.key(data: lxmfHash)), buffer.length == 12 else {
            return nil
        }
        var peerId: Int64 = 0
        var id: Int32 = 0
        buffer.read(&peerId, offset: 0, length: 8)
        buffer.read(&id, offset: 8, length: 4)
        return (peerId, id)
    }

    func setMessageHash(peerId: Int64, id: Int32, lxmfHash: Data) {
        self.valueBox.set(Table.messageHashes, key: LocalServerStore.key(peerId: peerId, messageId: id), value: MemoryBuffer(data: lxmfHash))
        var peerIdValue = peerId
        var idValue = id
        var data = Data(bytes: &peerIdValue, count: 8)
        data.append(Data(bytes: &idValue, count: 4))
        self.valueBox.set(Table.messageHashes, key: LocalServerStore.key(data: lxmfHash), value: MemoryBuffer(data: data))
    }

    // MARK: - Events (the pts log that answers updates.getDifference)

    func appendEvent(pts: Int32, bytes: Data) {
        self.valueBox.set(Table.events, key: LocalServerStore.key(int64: Int64(pts)), value: MemoryBuffer(data: bytes))
    }

    /// Events with pts above `pts`, ascending.
    func events(after pts: Int32) -> [(pts: Int32, bytes: Data)] {
        var result: [(pts: Int32, bytes: Data)] = []
        self.valueBox.range(Table.events, start: LocalServerStore.key(int64: Int64(pts)), end: LocalServerStore.key(int64: Int64(Int32.max)), values: { key, buffer in
            result.append((Int32(clamping: key.getInt64(0)), buffer.makeData()))
            return true
        }, limit: 0)
        return result
    }

    /// The oldest pts the log still holds, nil when empty.
    func oldestEventPts() -> Int32? {
        var result: Int32?
        self.valueBox.range(Table.events, start: LocalServerStore.key(int64: 0), end: LocalServerStore.key(int64: Int64(Int32.max)), keys: { key in
            result = Int32(clamping: key.getInt64(0))
            return false
        }, limit: 1)
        return result
    }

    func pruneEvents(below pts: Int32) {
        self.valueBox.removeRange(Table.events, start: LocalServerStore.key(int64: 0), end: LocalServerStore.key(int64: Int64(pts)))
    }

    // MARK: - Files (uploaded parts and received media, by file id)

    struct FileRecord: Codable, Equatable {
        var id: Int64
        var size: Int64
        var mimeType: String
        var name: String
        /// The file's path, relative to the store's directory.
        var relativePath: String
    }

    func file(id: Int64) -> FileRecord? {
        return self.read(Table.files, key: LocalServerStore.key(int64: id), as: FileRecord.self)
    }

    func setFile(_ record: FileRecord) {
        self.write(Table.files, key: LocalServerStore.key(int64: record.id), value: record)
    }

    func removeFile(id: Int64) {
        self.valueBox.remove(Table.files, key: LocalServerStore.key(int64: id), secure: false)
    }
}
