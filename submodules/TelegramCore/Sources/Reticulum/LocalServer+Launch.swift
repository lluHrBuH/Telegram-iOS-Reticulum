import Foundation
import Postbox
import SwiftSignalKit
import MtProtoKit
internal import TelegramApi

/// The calls a client makes before and right after it shows a chat list: configuration, the
/// update state, dialogs and histories, users and contacts, account settings. Everything is
/// answered from the store; nothing here touches the mesh except `contacts.resolveUsername`,
/// which asks it for a path to an address the store has never seen.
extension LocalServer {
    static let appConfigHash: Int32 = 1

    func launchHandlers() -> [String: LocalServerHandler] {
        var handlers: [String: LocalServerHandler] = [:]

        handlers["help.getConfig"] = { server, _ in
            return .single(.value(server.configAnswer()))
        }
        handlers["help.getAppConfig"] = { server, call in
            if let hash: Int32 = call.argument("hash"), hash == LocalServer.appConfigHash {
                return .single(.value(Api.help.AppConfig.appConfigNotModified))
            }
            return .single(.value(Api.help.AppConfig.appConfig(.init(hash: LocalServer.appConfigHash, config: server.appConfigJson()))))
        }
        handlers["messages.getDefaultHistoryTTL"] = { _, _ in
            return .single(.value(Api.DefaultHistoryTTL.defaultHistoryTTL(.init(period: 0))))
        }
        handlers["help.getPromoData"] = { server, _ in
            return .single(.value(Api.help.PromoData.promoDataEmpty(.init(expires: server.now() + 3600))))
        }
        handlers["help.getTermsOfServiceUpdate"] = { server, _ in
            return .single(.value(Api.help.TermsOfServiceUpdate.termsOfServiceUpdateEmpty(.init(expires: server.now() + 86400))))
        }

        handlers["updates.getState"] = { server, _ in
            return .single(.value(server.stateAnswer()))
        }
        handlers["updates.getDifference"] = { server, call in
            let pts: Int32 = call.argument("pts") ?? 0
            return .single(.value(server.differenceAnswer(since: pts)))
        }

        handlers["messages.getDialogs"] = { server, _ in
            return .single(.value(server.dialogsAnswer()))
        }
        handlers["messages.getPeerDialogs"] = { server, call in
            let peers: [Api.InputDialogPeer] = call.elements("peers") ?? []
            return .single(.value(server.peerDialogsAnswer(peers: peers)))
        }
        handlers["messages.getHistory"] = { server, call in
            guard let peer: Api.InputPeer = call.argument("peer"), let record = server.peerRecord(inputPeer: peer) else {
                return .fail(localServerError(400, "PEER_ID_INVALID"))
            }
            let offsetId: Int32 = call.argument("offsetId") ?? 0
            let addOffset: Int32 = call.argument("addOffset") ?? 0
            let limit: Int32 = call.argument("limit") ?? 100
            let maxId: Int32 = call.argument("maxId") ?? 0
            let minId: Int32 = call.argument("minId") ?? 0
            return .single(.value(server.historyAnswer(peerId: record.peerId, offsetId: offsetId, addOffset: addOffset, limit: limit, maxId: maxId, minId: minId)))
        }
        handlers["messages.getMessages"] = { server, call in
            let ids: [Api.InputMessage] = call.elements("id") ?? []
            var messageIds: [Int32] = []
            for id in ids {
                if case let .inputMessageID(data) = id {
                    messageIds.append(data.id)
                }
            }
            return .single(.value(server.messagesAnswer(ids: messageIds)))
        }

        handlers["users.getUsers"] = { server, call in
            let ids: [Api.InputUser] = call.elements("id") ?? []
            var users: [Api.User] = []
            for id in ids {
                if let record = server.peerRecord(inputUser: id) {
                    users.append(server.apiUser(record))
                } else if case let .inputUser(data) = id {
                    users.append(.userEmpty(.init(id: data.userId)))
                }
            }
            return .single(.value(users))
        }
        handlers["users.getFullUser"] = { server, call in
            guard let id: Api.InputUser = call.argument("id"), let record = server.peerRecord(inputUser: id) else {
                return .fail(localServerError(400, "USER_ID_INVALID"))
            }
            return .single(.value(server.fullUserAnswer(record)))
        }

        handlers["contacts.getContacts"] = { server, _ in
            let contacts = server.store.allPeers().filter { $0.isContact && $0.peerId != server.selfUserId }
            return .single(.value(Api.contacts.Contacts.contacts(.init(contacts: contacts.map { .contact(.init(userId: $0.peerId, mutual: $0.speaksTelegram ? .boolTrue : .boolFalse)) }, savedCount: 0, users: contacts.map { server.apiUser($0) }))))
        }
        handlers["contacts.getStatuses"] = { _, _ in
            return .single(.value([Api.ContactStatus]()))
        }
        handlers["contacts.importContacts"] = { _, _ in
            return .single(.value(Api.contacts.ImportedContacts.importedContacts(.init(imported: [], popularInvites: [], retryContacts: [], users: []))))
        }
        handlers["contacts.addContact"] = { server, call in
            guard let id: Api.InputUser = call.argument("id"), var record = server.peerRecord(inputUser: id) else {
                return .fail(localServerError(400, "USER_ID_INVALID"))
            }
            let firstName: String = call.argument("firstName") ?? ""
            let lastName: String = call.argument("lastName") ?? ""
            record.isContact = true
            if !firstName.isEmpty || !lastName.isEmpty {
                record.firstName = firstName
                record.lastName = lastName
            }
            server.store.setPeer(record)
            return .single(.value(server.usersUpdates([record])))
        }
        handlers["contacts.deleteContacts"] = { server, call in
            let ids: [Api.InputUser] = call.elements("id") ?? []
            var records: [LocalServerStore.PeerRecord] = []
            for id in ids {
                if var record = server.peerRecord(inputUser: id) {
                    record.isContact = false
                    if let announced = record.announcedName {
                        (record.firstName, record.lastName) = LocalServerPeerIdentity.splitName(announced)
                    }
                    server.store.setPeer(record)
                    records.append(record)
                }
            }
            return .single(.value(server.usersUpdates(records)))
        }
        handlers["contacts.resolveUsername"] = { server, call in
            let username: String = call.argument("username") ?? ""
            return server.resolve(username: username)
        }
        handlers["contacts.search"] = { server, call in
            let query = (call.argument("q") as String? ?? "").lowercased()
            let limit = Int(call.argument("limit") as Int32? ?? 20)
            let matches = server.store.allPeers().filter { record in
                guard record.peerId != server.selfUserId else {
                    return false
                }
                let name = (record.firstName + " " + record.lastName).lowercased()
                let address = ReticulumAddress(hash: record.destinationHash)?.hex ?? ""
                return name.contains(query) || address.hasPrefix(query.replacingOccurrences(of: "@", with: ""))
            }.prefix(max(1, limit))
            return .single(.value(Api.contacts.Found.found(.init(myResults: matches.filter { $0.isContact }.map { server.apiPeer($0) }, results: matches.filter { !$0.isContact }.map { server.apiPeer($0) }, chats: [], users: matches.map { server.apiUser($0) }))))
        }

        handlers["account.updateStatus"] = { _, _ in
            return .single(.value(Api.Bool.boolTrue))
        }
        handlers["account.getNotifySettings"] = { server, _ in
            return .single(.value(server.defaultNotifySettings()))
        }
        handlers["account.getPassword"] = { _, _ in
            return .single(.value(Api.account.Password.password(.init(flags: 0, currentAlgo: nil, srpB: nil, srpId: nil, hint: nil, emailUnconfirmedPattern: nil, newAlgo: .passwordKdfAlgoUnknown, newSecureAlgo: .securePasswordKdfAlgoUnknown, secureRandom: Buffer(), pendingResetDate: nil, loginEmailPattern: nil))))
        }
        handlers["account.getAuthorizations"] = { server, _ in
            let now = server.now()
            let current = Api.Authorization.authorization(.init(flags: (1 << 0) | (1 << 1), hash: 0, deviceModel: "This device", platform: "iOS", systemVersion: "", apiId: 0, appName: "Telegram Reticulum", appVersion: "", dateCreated: now, dateActive: now, ip: "", country: "", region: ""))
            return .single(.value(Api.account.Authorizations.authorizations(.init(authorizationTtlDays: 365, authorizations: [current]))))
        }
        handlers["account.updateProfile"] = { server, call in
            guard var record = server.selfRecord() else {
                return .fail(localServerError(401, "AUTH_KEY_UNREGISTERED"))
            }
            let flags: Int32 = call.argument("flags") ?? 0
            var (first, last) = server.selfName()
            if (flags & (1 << 0)) != 0, let firstName: String = call.argument("firstName") {
                first = firstName
            }
            if (flags & (1 << 1)) != 0, let lastName: String = call.argument("lastName") {
                last = lastName
            }
            server.setSelfName(firstName: first, lastName: last)
            record = server.selfRecord() ?? record
            server.sendProfileToContacts()
            return .single(.value(server.apiUser(record)))
        }

        handlers["messages.getPeerSettings"] = { server, call in
            guard let peer: Api.InputPeer = call.argument("peer"), let record = server.peerRecord(inputPeer: peer) else {
                return .fail(localServerError(400, "PEER_ID_INVALID"))
            }
            return .single(.value(Api.messages.PeerSettings.peerSettings(.init(settings: server.apiPeerSettings(record), chats: [], users: [server.apiUser(record)]))))
        }
        handlers["messages.getDialogFilters"] = { _, _ in
            return .single(.value(Api.messages.DialogFilters.dialogFilters(.init(flags: 0, filters: []))))
        }
        handlers["messages.getDialogUnreadMarks"] = { _, _ in
            return .single(.value([Api.DialogPeer]()))
        }

        return handlers
    }

    // MARK: - Answers

    func configAnswer() -> Api.Config {
        let now = self.now()
        let dcOptions: [Api.DcOption] = [.dcOption(.init(flags: 0, id: 1, ipAddress: "127.0.0.1", port: 443, secret: nil))]
        // Bit 6, revoke_pm_inbox: a message may be deleted for the other side too.
        return .config(.init(flags: 1 << 6, date: now, expires: now + 3600, testMode: .boolFalse, thisDc: 1, dcOptions: dcOptions, dcTxtDomainName: "", chatSizeMax: 200, megagroupSizeMax: 200, forwardedCountMax: 100, onlineUpdatePeriodMs: 120000, offlineBlurTimeoutMs: 5000, offlineIdleTimeoutMs: 30000, onlineCloudTimeoutMs: 300000, notifyCloudDelayMs: 30000, notifyDefaultDelayMs: 1500, pushChatPeriodMs: 60000, pushChatLimit: 2, editTimeLimit: Int32.max, revokeTimeLimit: Int32.max, revokePmTimeLimit: Int32.max, ratingEDecay: 2419200, stickersRecentLimit: 200, channelsReadMediaPeriod: 604800, tmpSessions: nil, callReceiveTimeoutMs: 20000, callRingTimeoutMs: 90000, callConnectTimeoutMs: 30000, callPacketTimeoutMs: 10000, meUrlPrefix: "https://t.me/", autoupdateUrlPrefix: nil, gifSearchUsername: nil, venueSearchUsername: nil, imgSearchUsername: nil, staticMapsProvider: nil, captionLengthMax: 1024, messageLengthMax: 4096, webfileDcId: 1, suggestedLangCode: nil, langPackVersion: 0, baseLangPackVersion: 0, reactionsDefault: nil, autologinToken: nil))
    }

    /// The app configuration: what the client reads to decide what to show. Keys gate features the
    /// mesh cannot carry (see `LocalServerAppConfiguration`).
    func appConfigJson() -> Api.JSONValue {
        return .jsonObject(.init(value: LocalServerAppConfiguration.entries.map { key, value in
            .jsonObjectValue(.init(key: key, value: value))
        }))
    }

    func stateAnswer() -> Api.updates.State {
        let state = self.store.state()
        let unread = self.store.allDialogs().reduce(0) { $0 + $1.unreadCount }
        return .state(.init(pts: state.pts, qts: state.qts, date: state.date, seq: state.seq, unreadCount: unread))
    }

    func differenceAnswer(since pts: Int32) -> Api.updates.Difference {
        let state = self.store.state()
        if pts >= state.pts {
            return .differenceEmpty(.init(date: state.date, seq: state.seq))
        }
        if let oldest = self.store.oldestEventPts(), oldest > pts + 1 {
            return .differenceTooLong(.init(pts: state.pts))
        }
        var newMessages: [Api.Message] = []
        var otherUpdates: [Api.Update] = []
        var userIds = Set<Int64>()
        for event in self.store.events(after: pts) {
            guard let update = Api.parse(Buffer(data: event.bytes)) as? Api.Update else {
                continue
            }
            switch update {
            case let .updateNewMessage(data):
                newMessages.append(data.message)
                userIds.formUnion(self.userIds(in: data.message))
            default:
                otherUpdates.append(update)
            }
        }
        if let selfUserId = self.selfUserId {
            userIds.insert(selfUserId)
        }
        return .difference(.init(newMessages: newMessages, newEncryptedMessages: [], otherUpdates: otherUpdates, chats: [], users: self.apiUsers(ids: userIds), state: self.stateAnswer()))
    }

    func userIds(in message: Api.Message) -> Set<Int64> {
        var ids = Set<Int64>()
        switch message {
        case let .message(data):
            if case let .peerUser(peer) = data.peerId {
                ids.insert(peer.userId)
            }
            if case let .peerUser(peer)? = data.fromId {
                ids.insert(peer.userId)
            }
        case let .messageEmpty(data):
            if case let .peerUser(peer)? = data.peerId {
                ids.insert(peer.userId)
            }
        default:
            break
        }
        return ids
    }

    func apiDialog(_ dialog: LocalServerStore.DialogRecord) -> Api.Dialog {
        var flags: Int32 = 1 << 0
        if dialog.pinned {
            flags |= 1 << 2
        }
        return .dialog(.init(flags: flags, peer: .peerUser(.init(userId: dialog.peerId)), topMessage: dialog.topMessageId, readInboxMaxId: dialog.readInboxMaxId, readOutboxMaxId: dialog.readOutboxMaxId, unreadCount: dialog.unreadCount, unreadMentionsCount: 0, unreadReactionsCount: 0, unreadPollVotesCount: 0, notifySettings: self.defaultNotifySettings(), pts: self.store.state().pts, draft: nil, folderId: nil, ttlPeriod: nil))
    }

    func storedMessage(peerId: Int64, id: Int32) -> Api.Message? {
        guard let bytes = self.store.message(peerId: peerId, id: id) else {
            return nil
        }
        return Api.parse(Buffer(data: bytes)) as? Api.Message
    }

    func dialogsAnswer() -> Api.messages.Dialogs {
        let dialogs = self.store.allDialogs()
        var messages: [Api.Message] = []
        var userIds = Set<Int64>()
        for dialog in dialogs {
            userIds.insert(dialog.peerId)
            if let message = self.storedMessage(peerId: dialog.peerId, id: dialog.topMessageId) {
                messages.append(message)
                userIds.formUnion(self.userIds(in: message))
            }
        }
        if let selfUserId = self.selfUserId {
            userIds.insert(selfUserId)
        }
        return .dialogs(.init(dialogs: dialogs.map { self.apiDialog($0) }, messages: messages, chats: [], users: self.apiUsers(ids: userIds)))
    }

    func peerDialogsAnswer(peers: [Api.InputDialogPeer]) -> Api.messages.PeerDialogs {
        var dialogs: [Api.Dialog] = []
        var messages: [Api.Message] = []
        var userIds = Set<Int64>()
        for peer in peers {
            guard case let .inputDialogPeer(data) = peer, let record = self.peerRecord(inputPeer: data.peer) else {
                continue
            }
            userIds.insert(record.peerId)
            let dialog = self.store.dialog(peerId: record.peerId) ?? LocalServerStore.DialogRecord(peerId: record.peerId, topMessageId: 0, topMessageDate: 0, readInboxMaxId: 0, readOutboxMaxId: 0, unreadCount: 0, pinned: false)
            dialogs.append(self.apiDialog(dialog))
            if let message = self.storedMessage(peerId: record.peerId, id: dialog.topMessageId) {
                messages.append(message)
            }
        }
        if let selfUserId = self.selfUserId {
            userIds.insert(selfUserId)
        }
        return .peerDialogs(.init(dialogs: dialogs, messages: messages, chats: [], users: self.apiUsers(ids: userIds), state: self.stateAnswer()))
    }

    /// Telegram's history paging: ids below `offsetId` (every id when 0), shifted by `addOffset`
    /// (negative reaches newer ids), `limit` of them, within `(minId, maxId)` when set.
    func historyAnswer(peerId: Int64, offsetId: Int32, addOffset: Int32, limit: Int32, maxId: Int32, minId: Int32) -> Api.messages.Messages {
        var ids = self.store.messageIds(peerId: peerId).reversed().filter { id in
            if maxId > 0 && id >= maxId {
                return false
            }
            if minId > 0 && id <= minId {
                return false
            }
            return true
        }
        var start = 0
        if offsetId > 0 {
            start = ids.firstIndex(where: { $0 < offsetId }) ?? ids.count
        }
        start = max(0, min(ids.count, start + Int(addOffset)))
        let end = min(ids.count, start + Int(max(0, limit)))
        if start >= end {
            ids = []
        } else {
            ids = Array(ids[start ..< end])
        }
        let messages = ids.compactMap { self.storedMessage(peerId: peerId, id: $0) }
        var userIds: Set<Int64> = [peerId]
        if let selfUserId = self.selfUserId {
            userIds.insert(selfUserId)
        }
        return .messages(.init(messages: messages, topics: [], chats: [], users: self.apiUsers(ids: userIds)))
    }

    func messagesAnswer(ids: [Int32]) -> Api.messages.Messages {
        var messages: [Api.Message] = []
        var userIds = Set<Int64>()
        for id in ids {
            if let peerId = self.store.messagePeer(id: id), let message = self.storedMessage(peerId: peerId, id: id) {
                messages.append(message)
                userIds.formUnion(self.userIds(in: message))
            } else {
                messages.append(.messageEmpty(.init(flags: 0, id: id, peerId: nil)))
            }
        }
        return .messages(.init(messages: messages, topics: [], chats: [], users: self.apiUsers(ids: userIds)))
    }

    func fullUserAnswer(_ record: LocalServerStore.PeerRecord) -> Api.users.UserFull {
        let full = Api.UserFull.userFull(.init(flags: 0, flags2: 0, id: record.peerId, about: nil, settings: self.apiPeerSettings(record), personalPhoto: nil, profilePhoto: nil, fallbackPhoto: nil, notifySettings: self.defaultNotifySettings(), botInfo: nil, pinnedMsgId: nil, commonChatsCount: 0, folderId: nil, ttlPeriod: nil, theme: nil, privateForwardName: nil, botGroupAdminRights: nil, botBroadcastAdminRights: nil, wallpaper: nil, stories: nil, businessWorkHours: nil, businessLocation: nil, businessGreetingMessage: nil, businessAwayMessage: nil, businessIntro: nil, birthday: nil, personalChannelId: nil, personalChannelMessage: nil, stargiftsCount: nil, starrefProgram: nil, botVerification: nil, sendPaidMessagesStars: nil, disallowedGifts: nil, starsRating: nil, starsMyPendingRating: nil, starsMyPendingRatingDate: nil, mainTab: nil, savedMusic: nil, note: nil, botManagerId: nil, walletCard: nil, shareTheme: nil))
        return .userFull(.init(fullUser: full, chats: [], users: [self.apiUser(record)]))
    }

    /// An `Updates` that carries only users, for answers whose effect is a changed user record.
    func usersUpdates(_ records: [LocalServerStore.PeerRecord]) -> Api.Updates {
        return .updates(.init(updates: [], users: records.map { self.apiUser($0) }, chats: [], date: self.now(), seq: 0))
    }

    /// "@address": a user the store knows, or one the mesh can reach (a path request, then the
    /// announce that answers it names the peer).
    func resolve(username: String) -> Signal<LocalServerAnswer, MTRpcError> {
        let cleaned = username.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "@", with: "")
        guard let address = ReticulumAddress(hex: cleaned) else {
            return .fail(localServerError(400, "USERNAME_INVALID"))
        }
        let resolved: (LocalServerStore.PeerRecord) -> LocalServerAnswer = { record in
            return .value(Api.contacts.ResolvedPeer.resolvedPeer(.init(peer: self.apiPeer(record), chats: [], users: [self.apiUser(record)])))
        }
        if address == self.selfAddress, let record = self.selfRecord() {
            return .single(resolved(record))
        }
        if let record = self.store.peer(destinationHash: address.hash) {
            return .single(resolved(record))
        }
        guard let transport = self.transport else {
            return .fail(localServerError(400, "USERNAME_NOT_OCCUPIED"))
        }
        return transport.requestPath(to: address, timeout: 30.0)
        |> deliverOn(self.queue)
        |> castError(MTRpcError.self)
        |> mapToSignal { found -> Signal<LocalServerAnswer, MTRpcError> in
            if let record = self.store.peer(destinationHash: address.hash) {
                return .single(resolved(record))
            }
            if found {
                return .single(resolved(self.record(for: address, name: nil)))
            }
            return .fail(localServerError(400, "USERNAME_NOT_OCCUPIED"))
        }
    }
}

/// The app configuration the local server hands out. The mesh carries text, media and a few
/// control messages between users, so everything else is switched off where the client reads a
/// flag for it; `help.getAppConfig` is answered from these entries.
enum LocalServerAppConfiguration {
    static let entries: [(String, Api.JSONValue)] = [
        ("reticulum_backend", .jsonBool(.init(value: .boolTrue))),
        ("ios_killswitch_disable_corelist_chat_backend", .jsonBool(.init(value: .boolFalse))),
        ("stories_posting", .jsonString(.init(value: "disabled"))),
        ("premium_purchase_blocked", .jsonBool(.init(value: .boolTrue))),
        ("stars_purchase_blocked", .jsonBool(.init(value: .boolTrue))),
        ("news_feed_enabled", .jsonBool(.init(value: .boolFalse))),
        ("reactions_in_chat_max", .jsonNumber(.init(value: 1))),
        ("reactions_user_max_default", .jsonNumber(.init(value: 1))),
    ]
}
