import Foundation
import Postbox
import SwiftSignalKit
import MtProtoKit
internal import TelegramApi

/// How an LXMF address becomes a Telegram user. `PeerId.Id` holds 56 bits, so the user id is the
/// address's first seven bytes; the access hash (which `apiInputPeer` requires to be present) is
/// its last eight; the "@username" is the whole address in hex, so sharing and searching a user
/// works with the address itself. The server's store keeps the full address beside the id.
public enum LocalServerPeerIdentity {
    public static func peerId(for address: ReticulumAddress) -> PeerId {
        var value: UInt64 = 0
        for byte in address.hash.prefix(7) {
            value = (value << 8) | UInt64(byte)
        }
        if value == 0 {
            value = 1
        }
        return PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt64Value(Int64(value)))
    }

    public static func accessHash(for address: ReticulumAddress) -> Int64 {
        var value: UInt64 = 0
        for byte in address.hash.suffix(8) {
            value = (value << 8) | UInt64(byte)
        }
        return Int64(bitPattern: value)
    }

    public static func username(for address: ReticulumAddress) -> String {
        return address.hex
    }

    /// "Peer 91a664e7" for an address nobody has named.
    public static func placeholderName(for address: ReticulumAddress) -> String {
        return "Peer " + String(address.hex.prefix(8))
    }

    /// A display name as Telegram's two fields: the first word, and the rest.
    public static func splitName(_ name: String) -> (firstName: String, lastName: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ("", "")
        }
        let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        if parts.count == 2 {
            return (String(parts[0]), String(parts[1]).trimmingCharacters(in: .whitespaces))
        }
        return (trimmed, "")
    }
}

extension LocalServer {
    private static let selfAddressSetting = "self.address"
    private static let selfFirstNameSetting = "self.firstName"
    private static let selfLastNameSetting = "self.lastName"

    /// This account's LXMF address, once an identity was adopted.
    var selfAddress: ReticulumAddress? {
        return self.store.setting(LocalServer.selfAddressSetting).flatMap { ReticulumAddress(hash: $0) }
    }

    var selfPeerId: PeerId? {
        return self.selfAddress.map(LocalServerPeerIdentity.peerId(for:))
    }

    var selfUserId: Int64? {
        return self.selfPeerId?.id._internalGetInt64Value()
    }

    func selfName() -> (firstName: String, lastName: String) {
        let first = self.store.setting(LocalServer.selfFirstNameSetting).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let last = self.store.setting(LocalServer.selfLastNameSetting).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return (first, last)
    }

    func selfDisplayName() -> String {
        let (first, last) = self.selfName()
        return [first, last].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Records the identity the transport runs (the account's own address); a different address
    /// than the one adopted before is logged and ignored, since the store belongs to that identity.
    func adoptIdentity(address: ReticulumAddress) {
        if let current = self.selfAddress {
            if current != address {
                Logger.shared.log("LocalServer", "Transport identity \(address) differs from the account's \(current); keeping the account's")
            }
            self.transport?.setDisplayName(self.selfDisplayName())
            return
        }
        self.store.transaction {
            self.store.setSetting(LocalServer.selfAddressSetting, address.hash)
            self.ensureSelfRecord(address: address)
        }
        self.transport?.setDisplayName(self.selfDisplayName())
    }

    /// Sets the account's identity and name, from the account's creation. Runs on `queue`.
    public func setSelfIdentity(address: ReticulumAddress, firstName: String, lastName: String, completion: @escaping () -> Void) {
        self.queue.async {
            self.store.transaction {
                self.store.setSetting(LocalServer.selfAddressSetting, address.hash)
                self.store.setSetting(LocalServer.selfFirstNameSetting, firstName.data(using: .utf8))
                self.store.setSetting(LocalServer.selfLastNameSetting, lastName.data(using: .utf8))
                self.ensureSelfRecord(address: address)
            }
            self.transport?.setDisplayName(self.selfDisplayName())
            completion()
        }
    }

    func setSelfName(firstName: String, lastName: String) {
        self.store.setSetting(LocalServer.selfFirstNameSetting, firstName.data(using: .utf8))
        self.store.setSetting(LocalServer.selfLastNameSetting, lastName.data(using: .utf8))
        if let address = self.selfAddress {
            self.ensureSelfRecord(address: address)
        }
        self.transport?.setDisplayName(self.selfDisplayName())
    }

    private func ensureSelfRecord(address: ReticulumAddress) {
        let peerId = LocalServerPeerIdentity.peerId(for: address).id._internalGetInt64Value()
        let (first, last) = self.selfName()
        var record = self.store.peer(id: peerId) ?? LocalServerStore.PeerRecord(peerId: peerId, accessHash: LocalServerPeerIdentity.accessHash(for: address), destinationHash: address.hash, firstName: "", lastName: "", announcedName: nil, lastAnnounceTimestamp: nil, isContact: false, speaksTelegram: true, lastSeenTimestamp: nil, photoId: nil)
        record.firstName = first.isEmpty ? LocalServerPeerIdentity.placeholderName(for: address) : first
        record.lastName = last
        record.speaksTelegram = true
        self.store.setPeer(record)
    }

    func selfRecord() -> LocalServerStore.PeerRecord? {
        guard let selfUserId = self.selfUserId else {
            return nil
        }
        return self.store.peer(id: selfUserId)
    }

    // MARK: - Records

    /// The record for `address`, made on first sight. `name` (from an announce or a message) names
    /// a peer the user has not named; a contact keeps the name the user gave it.
    @discardableResult
    func record(for address: ReticulumAddress, name: String?, speaksTelegram: Bool = false) -> LocalServerStore.PeerRecord {
        let peerId = LocalServerPeerIdentity.peerId(for: address).id._internalGetInt64Value()
        var record: LocalServerStore.PeerRecord
        if let existing = self.store.peer(id: peerId) {
            if existing.destinationHash != address.hash {
                Logger.shared.log("LocalServer", "Address \(address) collides with \(existing.destinationHash.map { String(format: "%02x", $0) }.joined()) on user id \(peerId)")
            }
            record = existing
        } else {
            record = LocalServerStore.PeerRecord(peerId: peerId, accessHash: LocalServerPeerIdentity.accessHash(for: address), destinationHash: address.hash, firstName: LocalServerPeerIdentity.placeholderName(for: address), lastName: "", announcedName: nil, lastAnnounceTimestamp: nil, isContact: false, speaksTelegram: false, lastSeenTimestamp: nil, photoId: nil)
        }
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty, name != record.announcedName {
            record.announcedName = name
            if !record.isContact {
                let (first, last) = LocalServerPeerIdentity.splitName(name)
                record.firstName = first
                record.lastName = last
            }
        }
        if speaksTelegram {
            record.speaksTelegram = true
        }
        self.store.setPeer(record)
        return record
    }

    func peerRecord(id: Int64) -> LocalServerStore.PeerRecord? {
        return self.store.peer(id: id)
    }

    func peerRecord(inputUser: Api.InputUser) -> LocalServerStore.PeerRecord? {
        switch inputUser {
        case .inputUserSelf:
            return self.selfRecord()
        case let .inputUser(data):
            return self.store.peer(id: data.userId)
        case let .inputUserFromMessage(data):
            return self.store.peer(id: data.userId)
        case .inputUserEmpty:
            return nil
        }
    }

    func peerRecord(inputPeer: Api.InputPeer) -> LocalServerStore.PeerRecord? {
        switch inputPeer {
        case .inputPeerSelf:
            return self.selfRecord()
        case let .inputPeerUser(data):
            return self.store.peer(id: data.userId)
        case let .inputPeerUserFromMessage(data):
            return self.store.peer(id: data.userId)
        default:
            return nil
        }
    }

    func address(of record: LocalServerStore.PeerRecord) -> ReticulumAddress? {
        return ReticulumAddress(hash: record.destinationHash)
    }

    // MARK: - Api values

    func apiPeer(_ record: LocalServerStore.PeerRecord) -> Api.Peer {
        return .peerUser(.init(userId: record.peerId))
    }

    func apiUser(_ record: LocalServerStore.PeerRecord) -> Api.User {
        let isSelf = record.peerId == self.selfUserId
        var flags: Int32 = 1 << 0
        if !record.firstName.isEmpty {
            flags |= 1 << 1
        }
        if !record.lastName.isEmpty {
            flags |= 1 << 2
        }
        flags |= 1 << 3
        flags |= 1 << 6
        if isSelf {
            flags |= 1 << 10
        }
        if record.isContact {
            flags |= 1 << 11
            if record.speaksTelegram {
                flags |= 1 << 12
            }
        }
        let status: Api.UserStatus
        if isSelf {
            status = .userStatusOnline(.init(expires: self.now() + 300))
        } else if let lastSeen = record.lastSeenTimestamp {
            status = .userStatusOffline(.init(wasOnline: lastSeen))
        } else {
            status = .userStatusEmpty
        }
        let username = ReticulumAddress(hash: record.destinationHash).map(LocalServerPeerIdentity.username(for:)) ?? ""
        return .user(.init(flags: flags, flags2: 0, id: record.peerId, accessHash: record.accessHash, firstName: record.firstName.isEmpty ? nil : record.firstName, lastName: record.lastName.isEmpty ? nil : record.lastName, username: username, phone: nil, photo: nil, status: status, botInfoVersion: nil, restrictionReason: nil, botInlinePlaceholder: nil, langCode: nil, emojiStatus: nil, usernames: nil, storiesMaxId: nil, color: nil, profileColor: nil, botActiveUsers: nil, botVerificationIcon: nil, sendPaidMessagesStars: nil, linkedCommunityId: nil))
    }

    func apiUsers(ids: Set<Int64>) -> [Api.User] {
        return ids.sorted().compactMap { self.store.peer(id: $0) }.map { self.apiUser($0) }
    }

    func defaultNotifySettings() -> Api.PeerNotifySettings {
        return .peerNotifySettings(.init(flags: 0, showPreviews: nil, silent: nil, muteUntil: nil, iosSound: nil, androidSound: nil, otherSound: nil, storiesMuted: nil, storiesHideSender: nil, storiesIosSound: nil, storiesAndroidSound: nil, storiesOtherSound: nil))
    }

    func apiPeerSettings(_ record: LocalServerStore.PeerRecord) -> Api.PeerSettings {
        // `add_contact` only: no report or block offer, so the chat is not treated as a suspicious
        // peer's (links stay tappable and reads are not held, see CLAUDE.md).
        let flags: Int32 = record.isContact || record.peerId == self.selfUserId ? 0 : (1 << 1)
        return .peerSettings(.init(flags: flags, geoDistance: nil, requestChatTitle: nil, requestChatDate: nil, businessBotId: nil, businessBotManageUrl: nil, chargePaidMessageStars: nil, registrationMonth: nil, phoneCountry: nil, nameChangeDate: nil, photoChangeDate: nil))
    }

    // MARK: - Announces

    func receiveAnnounce(_ announce: ReticulumAnnounce) {
        if announce.address == self.selfAddress {
            return
        }
        let before = self.store.peer(id: LocalServerPeerIdentity.peerId(for: announce.address).id._internalGetInt64Value())
        var record = self.record(for: announce.address, name: announce.displayName)
        record.lastAnnounceTimestamp = announce.timestamp
        record.lastSeenTimestamp = self.now()
        self.store.setPeer(record)
        // The client only holds users it has met; an announce from a stranger stays in the store
        // until a message or a search brings the user in.
        guard let before = before else {
            return
        }
        var updates: [Api.Update] = [.updateUserStatus(.init(userId: record.peerId, status: .userStatusOffline(.init(wasOnline: self.now()))))]
        if before.firstName != record.firstName || before.lastName != record.lastName {
            updates.append(.updateUserName(.init(userId: record.peerId, firstName: record.firstName, lastName: record.lastName, usernames: [])))
        }
        self.emit(updates, users: [self.apiUser(record)])
    }
}
