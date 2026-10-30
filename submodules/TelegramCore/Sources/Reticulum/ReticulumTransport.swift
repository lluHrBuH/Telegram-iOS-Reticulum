import Foundation
import SwiftSignalKit

/// A 16-byte Reticulum destination hash: an LXMF address.
public struct ReticulumAddress: Hashable, CustomStringConvertible {
    public let hash: Data

    public init?(hash: Data) {
        guard hash.count == 16 else {
            return nil
        }
        self.hash = hash
    }

    /// 32 hexadecimal characters, in either case, with or without surrounding whitespace.
    public init?(hex: String) {
        let text = hex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard text.count == 32, let data = Data(hexString: text) else {
            return nil
        }
        self.hash = data
    }

    public var hex: String {
        return self.hash.map { String(format: "%02x", $0) }.joined()
    }

    public var description: String {
        return self.hex
    }
}

/// Hex for keys and addresses, in the one spelling every screen uses (lowercase, no separators).
public enum ReticulumHex {
    public static func data(from text: String) -> Data? {
        return Data(hexString: text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    public static func string(_ data: Data) -> String {
        return data.map { String(format: "%02x", $0) }.joined()
    }
}

extension Data {
    init?(hexString: String) {
        let characters = Array(hexString.utf8)
        guard characters.count % 2 == 0 else {
            return nil
        }
        var bytes = Data(capacity: characters.count / 2)
        var index = 0
        while index < characters.count {
            guard let high = Data.hexDigit(characters[index]), let low = Data.hexDigit(characters[index + 1]) else {
                return nil
            }
            bytes.append(high << 4 | low)
            index += 2
        }
        self = bytes
    }

    private static func hexDigit(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0") ... UInt8(ascii: "9"):
            return byte - UInt8(ascii: "0")
        case UInt8(ascii: "a") ... UInt8(ascii: "f"):
            return byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A") ... UInt8(ascii: "F"):
            return byte - UInt8(ascii: "A") + 10
        default:
            return nil
        }
    }
}

/// How an LXMF message travels (LXMessage delivery methods).
public enum ReticulumDeliveryMethod: Equatable {
    /// One encrypted packet, no link; small messages only.
    case opportunistic
    /// An encrypted link to the recipient, with proof of delivery.
    case direct
    /// Store-and-forward through a propagation node.
    case propagated
}

/// An LXMF message to send: content and title bytes, the fields map, where and how.
public struct ReticulumOutgoingMessage {
    public var destination: ReticulumAddress
    public var content: Data
    public var title: Data
    /// Top-level LXMF fields by id (0xFB custom type, 0xFC custom data, 0x06 image, ...).
    public var fields: [(id: UInt8, value: MsgPackValue)]
    public var method: ReticulumDeliveryMethod

    public init(destination: ReticulumAddress, content: Data, title: Data = Data(), fields: [(id: UInt8, value: MsgPackValue)] = [], method: ReticulumDeliveryMethod = .direct) {
        self.destination = destination
        self.content = content
        self.title = title
        self.fields = fields
        self.method = method
    }
}

/// What became of a sent message. `sent` is a propagation node's acceptance, `delivered` the
/// recipient's proof; `failed` carries the router's reason.
public enum ReticulumSendOutcome: Equatable {
    case sending
    case sent
    case delivered
    case failed(String)

    public var isFinal: Bool {
        switch self {
        case .sending:
            return false
        case .sent, .delivered, .failed:
            return true
        }
    }
}

/// An LXMF message that arrived for this identity.
public struct ReticulumIncomingMessage {
    /// The LXMF message hash (32 bytes), the id other clients refer to it by (replies, reactions).
    public var hash: Data
    public var source: ReticulumAddress
    public var title: Data
    public var content: Data
    /// Seconds since 1970, the sender's clock.
    public var timestamp: Double
    public var signatureValid: Bool
    /// The decoded LXMF fields map (`.map` with integer keys), `.nil` when absent.
    public var fields: MsgPackValue
    /// The sender's display name as the router knows it (its announce, or the name inside the
    /// message), nil when it never gave one.
    public var displayName: String?
    public var rssi: Double?
    public var snr: Double?

    public init(hash: Data, source: ReticulumAddress, title: Data, content: Data, timestamp: Double, signatureValid: Bool, fields: MsgPackValue, displayName: String? = nil, rssi: Double? = nil, snr: Double? = nil) {
        self.hash = hash
        self.source = source
        self.title = title
        self.content = content
        self.timestamp = timestamp
        self.signatureValid = signatureValid
        self.fields = fields
        self.displayName = displayName
        self.rssi = rssi
        self.snr = snr
    }

    /// The LXMF field with id `id`.
    public func field(_ id: UInt8) -> MsgPackValue? {
        return self.fields[Int64(id)]
    }
}

/// An `lxmf.delivery` announce heard on the mesh.
public struct ReticulumAnnounce: Equatable {
    public var address: ReticulumAddress
    public var displayName: String?
    public var timestamp: Double

    public init(address: ReticulumAddress, displayName: String?, timestamp: Double) {
        self.address = address
        self.displayName = displayName
        self.timestamp = timestamp
    }
}

/// One interface of the running transport.
public struct ReticulumInterfaceStatus: Equatable {
    public var name: String
    public var online: Bool
    public var bitrate: Double?
    public var rssi: Double?
    public var snr: Double?
    public var rxBytes: UInt64
    public var txBytes: UInt64

    public init(name: String, online: Bool, bitrate: Double?, rssi: Double?, snr: Double?, rxBytes: UInt64, txBytes: UInt64) {
        self.name = name
        self.online = online
        self.bitrate = bitrate
        self.rssi = rssi
        self.snr = snr
        self.rxBytes = rxBytes
        self.txBytes = txBytes
    }
}

/// The mesh as the local server sees it: one identity, LXMF in and out, announces and interfaces.
/// Implemented over the Rust stack by `ReticulumEngine` (app side) and by fakes in tests. This
/// module (shared with Telegram-Mac) owns the protocol and nothing UIKit-shaped.
///
/// Callbacks from the Rust router run on its own thread while it is busy, so an implementation
/// delivers every signal on its own queue and never calls back into the stack from a callback.
public protocol ReticulumTransport: AnyObject {
    /// This identity's `lxmf.delivery` address.
    var ownAddress: ReticulumAddress { get }
    /// Messages for this identity, as they arrive.
    var incomingMessages: Signal<ReticulumIncomingMessage, NoError> { get }
    /// Delivery announces heard on the mesh.
    var announces: Signal<ReticulumAnnounce, NoError> { get }
    /// The interfaces and whether each is online; emits the current list first.
    var interfaces: Signal<[ReticulumInterfaceStatus], NoError> { get }
    /// Sends one message; emits every state change and completes with the final outcome.
    func send(_ message: ReticulumOutgoingMessage) -> Signal<ReticulumSendOutcome, NoError>
    /// Asks the mesh for a path to `address` and waits up to `timeout` seconds; `true` when one is known.
    func requestPath(to address: ReticulumAddress, timeout: Double) -> Signal<Bool, NoError>
    /// Whether the peer's identity (public key) is known, which a direct send needs.
    func knowsIdentity(of address: ReticulumAddress) -> Bool
    /// Announces this identity's delivery destination now.
    func announce()
    /// The display name carried by announces and messages.
    func setDisplayName(_ name: String)
}
