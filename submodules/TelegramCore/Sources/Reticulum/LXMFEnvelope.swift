import Foundation
internal import TelegramApi

/// What two Telegram-Reticulum clients put into an LXMF message beyond its plain content, so
/// stock LXMF clients (Sideband, Retichat) still read the text:
///
/// - field `0xFB` (FIELD_CUSTOM_TYPE): `LXMFEnvelope.customType`;
/// - field `0xFC` (FIELD_CUSTOM_DATA): a msgpack map with integer keys (`Key`), the envelope;
/// - field `0x30` (FIELD_REPLY_TO): the replied message's LXMF hash, the standard way.
///
/// Text and entities travel as a TL `textWithEntities` so the client's entity set round-trips
/// unchanged; everything that names another message does so by its LXMF hash, which both sides
/// store beside their own message ids. A message without the envelope is a plain LXMF message.
struct LXMFEnvelope: Equatable {
    static let customType = "org.telegram.reticulum/1"

    enum Kind: UInt64, Equatable {
        case message = 1
        case read = 2
        case typing = 3
        case edit = 4
        case delete = 5
        case reaction = 6
        case profile = 7
    }

    enum Key: Int64 {
        case kind = 1
        /// The LXMF hash of the message this refers to (read: the newest read; edit, reaction: the target).
        case target = 2
        /// The LXMF hashes of the messages a delete removes.
        case targets = 3
        /// TL bytes of a boxed `textWithEntities` (message, edit).
        case text = 4
        /// The reaction's emoticon, empty to remove one.
        case reaction = 5
        /// First name (profile).
        case firstName = 7
        /// Last name (profile).
        case lastName = 8
        /// The sender's client version, informational.
        case client = 9
        /// The sender's message date, seconds since 1970 (message, edit).
        case date = 10
        /// TL bytes of the sender's boxed `MessageMedia` (message): the attributes of the bytes
        /// in the standard image/audio/attachment fields; the receiver mints its own ids.
        case media = 11
    }

    var kind: Kind
    var target: Data?
    var targets: [Data] = []
    var text: String?
    var entities: [Api.MessageEntity] = []
    var reaction: String?
    var firstName: String?
    var lastName: String?
    var date: Int32?
    var media: Api.MessageMedia?

    static let clientVersion = "telegram-ios-reticulum/1"

    init(kind: Kind) {
        self.kind = kind
    }

    /// The msgpack value for field `0xFC`.
    func encoded() -> MsgPackValue {
        var entries: [(key: MsgPackValue, value: MsgPackValue)] = []
        entries.append((.int(Key.kind.rawValue), .uint(self.kind.rawValue)))
        if let target = self.target {
            entries.append((.int(Key.target.rawValue), .binary(target)))
        }
        if !self.targets.isEmpty {
            entries.append((.int(Key.targets.rawValue), .array(self.targets.map { .binary($0) })))
        }
        if let text = self.text {
            let buffer = Buffer()
            Api.TextWithEntities.textWithEntities(.init(text: text, entities: self.entities)).serialize(buffer, true)
            entries.append((.int(Key.text.rawValue), .binary(buffer.makeData())))
        }
        if let reaction = self.reaction {
            entries.append((.int(Key.reaction.rawValue), .string(reaction)))
        }
        if let firstName = self.firstName {
            entries.append((.int(Key.firstName.rawValue), .string(firstName)))
        }
        if let lastName = self.lastName {
            entries.append((.int(Key.lastName.rawValue), .string(lastName)))
        }
        entries.append((.int(Key.client.rawValue), .string(LXMFEnvelope.clientVersion)))
        if let date = self.date {
            entries.append((.int(Key.date.rawValue), .int(Int64(date))))
        }
        if let media = self.media {
            let buffer = Buffer()
            media.serialize(buffer, true)
            entries.append((.int(Key.media.rawValue), .binary(buffer.makeData())))
        }
        return .map(entries)
    }

    /// The envelope of an incoming message, nil when it carries none (a stock LXMF client) or an
    /// unknown one.
    init?(fields: MsgPackValue) {
        guard fields[0xFB]?.stringValue == LXMFEnvelope.customType, let data = fields[0xFC], let kindValue = data[Key.kind.rawValue]?.intValue, let kind = Kind(rawValue: UInt64(max(0, kindValue))) else {
            return nil
        }
        self.kind = kind
        self.target = data[Key.target.rawValue]?.binaryValue
        self.targets = data[Key.targets.rawValue]?.arrayValue?.compactMap { $0.binaryValue } ?? []
        if let textData = data[Key.text.rawValue]?.binaryValue, case let .textWithEntities(textWithEntities)? = Api.parse(Buffer(data: textData)) as? Api.TextWithEntities {
            self.text = textWithEntities.text
            self.entities = textWithEntities.entities
        }
        self.reaction = data[Key.reaction.rawValue]?.stringValue
        self.firstName = data[Key.firstName.rawValue]?.stringValue
        self.lastName = data[Key.lastName.rawValue]?.stringValue
        self.date = data[Key.date.rawValue]?.intValue.map { Int32(clamping: $0) }
        if let mediaData = data[Key.media.rawValue]?.binaryValue {
            self.media = Api.parse(Buffer(data: mediaData)) as? Api.MessageMedia
        }
    }

    /// The LXMF fields of an outgoing message: the envelope, and the standard reply field.
    func fields(replyTo: Data?) -> [(id: UInt8, value: MsgPackValue)] {
        var fields: [(id: UInt8, value: MsgPackValue)] = [
            (0xFB, .string(LXMFEnvelope.customType)),
            (0xFC, self.encoded()),
        ]
        if let replyTo = replyTo {
            fields.append((0x30, .binary(replyTo)))
        }
        return fields
    }

    static func == (lhs: LXMFEnvelope, rhs: LXMFEnvelope) -> Bool {
        return lhs.kind == rhs.kind && lhs.target == rhs.target && lhs.targets == rhs.targets && lhs.text == rhs.text && lhs.entities.count == rhs.entities.count && lhs.reaction == rhs.reaction && lhs.firstName == rhs.firstName && lhs.lastName == rhs.lastName && lhs.date == rhs.date && (lhs.media == nil) == (rhs.media == nil)
    }
}
