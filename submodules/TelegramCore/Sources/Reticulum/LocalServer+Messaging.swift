import Foundation
import Postbox
import SwiftSignalKit
import MtProtoKit
internal import TelegramApi

/// Private messages over the mesh. A sent message is stored as the server's copy, carried to the
/// peer as LXMF (its text as the content, the Telegram envelope in the fields) and answered to the
/// client once the router reports it sent or delivered; what comes back from a peer becomes a
/// server-side message and an `updateNewMessage`. Read receipts, typing, edits, deletes and
/// reactions are envelopes without content, sent only to peers that have shown the envelope.
extension LocalServer {
    func messagingHandlers() -> [String: LocalServerHandler] {
        var handlers: [String: LocalServerHandler] = [:]

        handlers["messages.sendMessage"] = { server, call in
            guard let peer: Api.InputPeer = call.argument("peer"), let record = server.peerRecord(inputPeer: peer) else {
                return .fail(localServerError(400, "PEER_ID_INVALID"))
            }
            let text: String = call.argument("message") ?? ""
            let randomId: Int64 = call.argument("randomId") ?? 0
            let entities: [Api.MessageEntity] = call.elements("entities") ?? []
            let replyTo: Api.InputReplyTo? = call.argument("replyTo")
            return server.send(text: text, entities: entities, replyTo: replyTo, randomId: randomId, to: record)
        }
        handlers["messages.readHistory"] = { server, call in
            guard let peer: Api.InputPeer = call.argument("peer"), let record = server.peerRecord(inputPeer: peer) else {
                return .fail(localServerError(400, "PEER_ID_INVALID"))
            }
            let maxId: Int32 = call.argument("maxId") ?? 0
            return .single(.value(server.readHistory(record: record, maxId: maxId)))
        }
        handlers["messages.readMessageContents"] = { server, _ in
            return .single(.value(Api.messages.AffectedMessages.affectedMessages(.init(pts: server.store.state().pts, ptsCount: 0))))
        }
        handlers["messages.setTyping"] = { server, call in
            if let peer: Api.InputPeer = call.argument("peer"), let record = server.peerRecord(inputPeer: peer), let action: Api.SendMessageAction = call.argument("action"), case .sendMessageTypingAction = action {
                server.sendTyping(to: record)
            }
            return .single(.value(Api.Bool.boolTrue))
        }
        handlers["messages.deleteMessages"] = { server, call in
            let flags: Int32 = call.argument("flags") ?? 0
            let ids: [Int32] = call.argument("id") ?? []
            return .single(.value(server.deleteMessages(ids: ids, revoke: (flags & (1 << 0)) != 0)))
        }
        handlers["messages.deleteHistory"] = { server, call in
            guard let peer: Api.InputPeer = call.argument("peer"), let record = server.peerRecord(inputPeer: peer) else {
                return .fail(localServerError(400, "PEER_ID_INVALID"))
            }
            let flags: Int32 = call.argument("flags") ?? 0
            return .single(.value(server.deleteHistory(record: record, revoke: (flags & (1 << 1)) != 0, justClear: (flags & (1 << 0)) != 0)))
        }
        handlers["messages.editMessage"] = { server, call in
            guard let peer: Api.InputPeer = call.argument("peer"), let record = server.peerRecord(inputPeer: peer) else {
                return .fail(localServerError(400, "PEER_ID_INVALID"))
            }
            let id: Int32 = call.argument("id") ?? 0
            let flags: Int32 = call.argument("flags") ?? 0
            let text: String? = (flags & (1 << 11)) != 0 ? call.argument("message") : nil
            let entities: [Api.MessageEntity] = call.elements("entities") ?? []
            return server.edit(record: record, id: id, text: text, entities: entities)
        }
        handlers["messages.sendReaction"] = { server, call in
            guard let peer: Api.InputPeer = call.argument("peer"), let record = server.peerRecord(inputPeer: peer) else {
                return .fail(localServerError(400, "PEER_ID_INVALID"))
            }
            let msgId: Int32 = call.argument("msgId") ?? 0
            let reactions: [Api.Reaction] = call.elements("reaction") ?? []
            var emoticon = ""
            if case let .reactionEmoji(data)? = reactions.first {
                emoticon = data.emoticon
            }
            return server.react(record: record, id: msgId, emoticon: emoticon)
        }
        handlers["messages.getMessagesReactions"] = { server, _ in
            return .single(.value(Api.Updates.updates(.init(updates: [], users: [], chats: [], date: server.now(), seq: 0))))
        }

        return handlers
    }

    // MARK: - Outgoing

    /// What a send ends with; `MTRpcError` is not a Swift `Error`, so not a `Result`.
    enum SendOutcome {
        case success(Api.Updates)
        case failure(MTRpcError)
    }

    /// Sends in flight by random id, so a resend of a message still travelling joins it.
    private static var pendingSends: [Int64: Promise<SendOutcome>] = [:]

    private func apiMessage(id: Int32, out: Bool, peerId: Int64, fromId: Int64, text: String, entities: [Api.MessageEntity], replyToId: Int32?, date: Int32, editDate: Int32? = nil, reactions: Api.MessageReactions? = nil) -> Api.Message {
        var flags: Int32 = 1 << 8
        if out {
            flags |= 1 << 1
        }
        if !entities.isEmpty {
            flags |= 1 << 7
        }
        var replyHeader: Api.MessageReplyHeader?
        if let replyToId = replyToId {
            flags |= 1 << 3
            replyHeader = .messageReplyHeader(.init(flags: 1 << 4, replyToMsgId: replyToId, replyToPeerId: nil, replyFrom: nil, replyMedia: nil, replyToTopId: nil, quoteText: nil, quoteEntities: nil, quoteOffset: nil, todoItemId: nil, pollOption: nil, quoteRich: nil))
        }
        if editDate != nil {
            flags |= 1 << 15
        }
        if reactions != nil {
            flags |= 1 << 20
        }
        return .message(.init(flags: flags, flags2: 0, id: id, fromId: .peerUser(.init(userId: fromId)), fromBoostsApplied: nil, fromRank: nil, peerId: .peerUser(.init(userId: peerId)), savedPeerId: nil, fwdFrom: nil, viaBotId: nil, viaBusinessBotId: nil, guestchatViaFrom: nil, replyTo: replyHeader, date: date, message: text, media: nil, replyMarkup: nil, entities: entities.isEmpty ? nil : entities, views: nil, forwards: nil, replies: nil, editDate: editDate, postAuthor: nil, groupedId: nil, reactions: reactions, restrictionReason: nil, ttlPeriod: nil, quickReplyShortcutId: nil, effect: nil, factcheck: nil, reportDeliveryUntilDate: nil, paidMessageStars: nil, suggestedPost: nil, scheduleRepeatPeriod: nil, summaryFromLanguage: nil, richMessage: nil))
    }

    func storeMessage(_ message: Api.Message, peerId: Int64) {
        guard case let .message(data) = message else {
            return
        }
        let buffer = Buffer()
        message.serialize(buffer, true)
        self.store.setMessage(peerId: peerId, id: data.id, bytes: buffer.makeData())
    }

    private func bumpDialog(peerId: Int64, message: Api.Message, incoming: Bool) {
        guard case let .message(data) = message else {
            return
        }
        var dialog = self.store.dialog(peerId: peerId) ?? LocalServerStore.DialogRecord(peerId: peerId, topMessageId: 0, topMessageDate: 0, readInboxMaxId: 0, readOutboxMaxId: 0, unreadCount: 0, pinned: false)
        if data.id > dialog.topMessageId {
            dialog.topMessageId = data.id
            dialog.topMessageDate = data.date
        }
        if incoming {
            dialog.unreadCount += 1
        }
        self.store.setDialog(dialog)
    }

    /// `messages.sendMessage`: the server's copy, then the LXMF, then the answer once the router
    /// reports the message sent or delivered. A failure drops the copy so a resend starts over.
    func send(text: String, entities: [Api.MessageEntity], replyTo: Api.InputReplyTo?, randomId: Int64, to record: LocalServerStore.PeerRecord) -> Signal<LocalServerAnswer, MTRpcError> {
        guard let selfUserId = self.selfUserId else {
            return .fail(localServerError(401, "AUTH_KEY_UNREGISTERED"))
        }
        if let pending = LocalServer.pendingSends[randomId] {
            return pending.get() |> castError(MTRpcError.self) |> take(1) |> mapToSignal { result -> Signal<LocalServerAnswer, MTRpcError> in
                switch result {
                case let .success(updates):
                    return .single(.value(updates))
                case let .failure(error):
                    return .fail(error)
                }
            }
        }
        if randomId != 0, let existing = self.store.messageId(randomId: randomId), let message = self.storedMessage(peerId: existing.peerId, id: existing.id), case let .message(data) = message {
            return .single(.value(Api.Updates.updateShortSentMessage(.init(flags: 1 << 1, id: data.id, pts: self.store.state().pts, ptsCount: 0, date: data.date, media: nil, entities: data.entities, ttlPeriod: nil))))
        }

        var replyToId: Int32?
        if case let .inputReplyToMessage(data)? = replyTo {
            replyToId = data.replyToMsgId
        }
        let id = self.allocateMessageId()
        let date = self.now()
        let message = self.apiMessage(id: id, out: true, peerId: record.peerId, fromId: selfUserId, text: text, entities: entities, replyToId: replyToId, date: date)
        self.store.transaction {
            self.storeMessage(message, peerId: record.peerId)
            if randomId != 0 {
                self.store.setMessageId(randomId: randomId, peerId: record.peerId, id: id)
            }
            self.bumpDialog(peerId: record.peerId, message: message, incoming: false)
        }
        let answer: () -> Api.Updates = {
            let pts = self.allocatePts()
            self.store.appendEvent(pts: pts, bytes: {
                let buffer = Buffer()
                Api.Update.updateNewMessage(.init(message: message, pts: pts, ptsCount: 1)).serialize(buffer, true)
                return buffer.makeData()
            }())
            return .updateShortSentMessage(.init(flags: 1 << 1, id: id, pts: pts, ptsCount: 1, date: date, media: nil, entities: entities.isEmpty ? nil : entities, ttlPeriod: nil))
        }

        // Saved Messages, or no mesh yet: the message stays on this device.
        if record.peerId == selfUserId {
            return .single(.value(answer()))
        }
        guard let transport = self.transport, let address = self.address(of: record) else {
            self.discardMessage(peerId: record.peerId, id: id, randomId: randomId)
            return .fail(localServerError(400, "PEER_UNREACHABLE"))
        }

        var envelope = LXMFEnvelope(kind: .message)
        envelope.text = text
        envelope.entities = entities
        envelope.date = date
        let replyHash = replyToId.flatMap { self.store.messageHash(peerId: record.peerId, id: $0) }
        let outgoing = ReticulumOutgoingMessage(destination: address, content: Data(text.utf8), title: Data(), fields: envelope.fields(replyTo: replyHash), method: .direct)

        let promise = Promise<SendOutcome>()
        LocalServer.pendingSends[randomId] = promise
        let outcome = transport.send(outgoing)
        |> deliverOn(self.queue)
        |> mapToSignal { outcome -> Signal<SendOutcome, NoError> in
            switch outcome {
            case .sending:
                return .complete()
            case .sent, .delivered:
                return .single(.success(answer()))
            case let .failed(reason):
                Logger.shared.log("LocalServer", "Message \(id) to \(address) failed: \(reason)")
                self.discardMessage(peerId: record.peerId, id: id, randomId: randomId)
                return .single(.failure(localServerError(400, "PEER_UNREACHABLE")))
            }
        }
        |> take(1)
        |> afterNext { _ in
            LocalServer.pendingSends.removeValue(forKey: randomId)
        }
        promise.set(outcome)
        return promise.get()
        |> take(1)
        |> castError(MTRpcError.self)
        |> mapToSignal { result -> Signal<LocalServerAnswer, MTRpcError> in
            switch result {
            case let .success(updates):
                return .single(.value(updates))
            case let .failure(error):
                return .fail(error)
            }
        }
    }

    private func discardMessage(peerId: Int64, id: Int32, randomId: Int64) {
        self.store.transaction {
            self.store.removeMessage(peerId: peerId, id: id)
            if var dialog = self.store.dialog(peerId: peerId), dialog.topMessageId == id {
                if let previous = self.store.history(peerId: peerId, below: id, limit: 1).first, let message = Api.parse(Buffer(data: previous.bytes)) as? Api.Message, case let .message(data) = message {
                    dialog.topMessageId = data.id
                    dialog.topMessageDate = data.date
                    self.store.setDialog(dialog)
                } else {
                    self.store.removeDialog(peerId: peerId)
                }
            }
        }
    }

    /// A control envelope to a peer, fire and forget; only peers that have shown the envelope get
    /// one (a stock LXMF client would show it as an empty message).
    private func sendControl(_ envelope: LXMFEnvelope, to record: LocalServerStore.PeerRecord, opportunistic: Bool = false) {
        guard record.speaksTelegram, record.peerId != self.selfUserId, let transport = self.transport, let address = self.address(of: record) else {
            return
        }
        let message = ReticulumOutgoingMessage(destination: address, content: Data(), title: Data(), fields: envelope.fields(replyTo: nil), method: opportunistic ? .opportunistic : .direct)
        let _ = transport.send(message).start()
    }

    func sendTyping(to record: LocalServerStore.PeerRecord) {
        if LocalServerPreferences.sendsTypingIndicators {
            self.sendControl(LXMFEnvelope(kind: .typing), to: record, opportunistic: true)
        }
    }

    func sendProfileToContacts() {
        let (first, last) = self.selfName()
        var envelope = LXMFEnvelope(kind: .profile)
        envelope.firstName = first
        envelope.lastName = last
        for record in self.store.allPeers() where record.isContact || self.store.dialog(peerId: record.peerId) != nil {
            self.sendControl(envelope, to: record)
        }
    }

    func readHistory(record: LocalServerStore.PeerRecord, maxId: Int32) -> Api.messages.AffectedMessages {
        var dialog = self.store.dialog(peerId: record.peerId) ?? LocalServerStore.DialogRecord(peerId: record.peerId, topMessageId: 0, topMessageDate: 0, readInboxMaxId: 0, readOutboxMaxId: 0, unreadCount: 0, pinned: false)
        let newMaxId = maxId == 0 ? dialog.topMessageId : max(dialog.readInboxMaxId, min(maxId, dialog.topMessageId))
        if newMaxId <= dialog.readInboxMaxId {
            return .affectedMessages(.init(pts: self.store.state().pts, ptsCount: 0))
        }
        dialog.readInboxMaxId = newMaxId
        dialog.unreadCount = Int32(self.store.messageIds(peerId: record.peerId).filter { $0 > newMaxId }.count)
        self.store.setDialog(dialog)
        let pts = self.allocatePts()
        if let hash = self.store.messageHash(peerId: record.peerId, id: newMaxId) {
            var envelope = LXMFEnvelope(kind: .read)
            envelope.target = hash
            self.sendControl(envelope, to: record)
        }
        return .affectedMessages(.init(pts: pts, ptsCount: 1))
    }

    func deleteMessages(ids: [Int32], revoke: Bool) -> Api.messages.AffectedMessages {
        var byPeer: [Int64: [Int32]] = [:]
        for id in ids {
            if let peerId = self.store.messagePeer(id: id) {
                byPeer[peerId, default: []].append(id)
            }
        }
        if byPeer.isEmpty {
            return .affectedMessages(.init(pts: self.store.state().pts, ptsCount: 0))
        }
        self.store.transaction {
            for (peerId, ids) in byPeer {
                var hashes: [Data] = []
                for id in ids {
                    if let hash = self.store.messageHash(peerId: peerId, id: id) {
                        hashes.append(hash)
                    }
                    self.store.removeMessage(peerId: peerId, id: id)
                }
                if var dialog = self.store.dialog(peerId: peerId), ids.contains(dialog.topMessageId) {
                    if let previous = self.store.history(peerId: peerId, below: Int32.max, limit: 1).first, let message = Api.parse(Buffer(data: previous.bytes)) as? Api.Message, case let .message(data) = message {
                        dialog.topMessageId = data.id
                        dialog.topMessageDate = data.date
                        self.store.setDialog(dialog)
                    } else {
                        self.store.removeDialog(peerId: peerId)
                    }
                }
                if revoke, !hashes.isEmpty, let record = self.store.peer(id: peerId) {
                    var envelope = LXMFEnvelope(kind: .delete)
                    envelope.targets = hashes
                    self.sendControl(envelope, to: record)
                }
            }
        }
        let pts = self.allocatePts()
        let buffer = Buffer()
        Api.Update.updateDeleteMessages(.init(messages: ids, pts: pts, ptsCount: 1)).serialize(buffer, true)
        self.store.appendEvent(pts: pts, bytes: buffer.makeData())
        return .affectedMessages(.init(pts: pts, ptsCount: 1))
    }

    func deleteHistory(record: LocalServerStore.PeerRecord, revoke: Bool, justClear: Bool) -> Api.messages.AffectedHistory {
        let ids = self.store.messageIds(peerId: record.peerId)
        let _ = self.deleteMessages(ids: ids, revoke: revoke)
        if !justClear {
            self.store.removeDialog(peerId: record.peerId)
        }
        return .affectedHistory(.init(pts: self.store.state().pts, ptsCount: 1, offset: 0))
    }

    func edit(record: LocalServerStore.PeerRecord, id: Int32, text: String?, entities: [Api.MessageEntity]) -> Signal<LocalServerAnswer, MTRpcError> {
        guard let message = self.storedMessage(peerId: record.peerId, id: id), case let .message(data) = message else {
            return .fail(localServerError(400, "MESSAGE_ID_INVALID"))
        }
        guard let text = text else {
            return .fail(localServerError(400, "MESSAGE_NOT_MODIFIED"))
        }
        let editDate = self.now()
        var fromId: Int64 = self.selfUserId ?? 0
        if case let .peerUser(from)? = data.fromId {
            fromId = from.userId
        }
        let edited = self.apiMessage(id: id, out: (data.flags & (1 << 1)) != 0, peerId: record.peerId, fromId: fromId, text: text, entities: entities, replyToId: self.replyToId(of: data), date: data.date, editDate: editDate, reactions: data.reactions)
        self.storeMessage(edited, peerId: record.peerId)
        if let hash = self.store.messageHash(peerId: record.peerId, id: id) {
            var envelope = LXMFEnvelope(kind: .edit)
            envelope.target = hash
            envelope.text = text
            envelope.entities = entities
            envelope.date = editDate
            self.sendControl(envelope, to: record)
        }
        let pts = self.allocatePts()
        let update = Api.Update.updateEditMessage(.init(message: edited, pts: pts, ptsCount: 1))
        let buffer = Buffer()
        update.serialize(buffer, true)
        self.store.appendEvent(pts: pts, bytes: buffer.makeData())
        return .single(.value(Api.Updates.updates(.init(updates: [update], users: [], chats: [], date: editDate, seq: 0))))
    }

    private func replyToId(of data: Api.Message.Cons_message) -> Int32? {
        if case let .messageReplyHeader(header)? = data.replyTo {
            return header.replyToMsgId
        }
        return nil
    }

    func react(record: LocalServerStore.PeerRecord, id: Int32, emoticon: String) -> Signal<LocalServerAnswer, MTRpcError> {
        guard let message = self.storedMessage(peerId: record.peerId, id: id), case let .message(data) = message, let selfUserId = self.selfUserId else {
            return .fail(localServerError(400, "MESSAGE_ID_INVALID"))
        }
        let reactions = self.reactions(of: data, settingFor: selfUserId, emoticon: emoticon)
        var fromId: Int64 = selfUserId
        if case let .peerUser(from)? = data.fromId {
            fromId = from.userId
        }
        let updated = self.apiMessage(id: id, out: (data.flags & (1 << 1)) != 0, peerId: record.peerId, fromId: fromId, text: data.message, entities: data.entities ?? [], replyToId: self.replyToId(of: data), date: data.date, editDate: data.editDate, reactions: reactions)
        self.storeMessage(updated, peerId: record.peerId)
        if let hash = self.store.messageHash(peerId: record.peerId, id: id) {
            var envelope = LXMFEnvelope(kind: .reaction)
            envelope.target = hash
            envelope.reaction = emoticon
            self.sendControl(envelope, to: record)
        }
        let update = Api.Update.updateMessageReactions(.init(flags: 0, peer: .peerUser(.init(userId: record.peerId)), msgId: id, topMsgId: nil, savedPeerId: nil, reactions: reactions ?? .messageReactions(.init(flags: 0, results: [], recentReactions: nil, topReactors: nil))))
        return .single(.value(Api.Updates.updates(.init(updates: [update], users: [], chats: [], date: self.now(), seq: 0))))
    }

    /// The message's reactions with `userId`'s set to `emoticon` ("" removes it). Each user holds
    /// at most one; `recent_reactions` names who reacted, as the client's reaction list expects.
    private func reactions(of data: Api.Message.Cons_message, settingFor userId: Int64, emoticon: String) -> Api.MessageReactions? {
        var recent: [(userId: Int64, emoticon: String, date: Int32)] = []
        if case let .messageReactions(existing)? = data.reactions, let recentReactions = existing.recentReactions {
            for reaction in recentReactions {
                if case let .messagePeerReaction(peerReaction) = reaction, case let .peerUser(peer) = peerReaction.peerId, case let .reactionEmoji(emoji) = peerReaction.reaction, peer.userId != userId {
                    recent.append((peer.userId, emoji.emoticon, peerReaction.date))
                }
            }
        }
        if !emoticon.isEmpty {
            recent.append((userId, emoticon, self.now()))
        }
        if recent.isEmpty {
            return nil
        }
        var counts: [(emoticon: String, count: Int32, chosen: Bool)] = []
        for reaction in recent {
            if let index = counts.firstIndex(where: { $0.emoticon == reaction.emoticon }) {
                counts[index].count += 1
                counts[index].chosen = counts[index].chosen || reaction.userId == self.selfUserId
            } else {
                counts.append((reaction.emoticon, 1, reaction.userId == self.selfUserId))
            }
        }
        let results: [Api.ReactionCount] = counts.map { count in
            .reactionCount(.init(flags: count.chosen ? (1 << 0) : 0, chosenOrder: count.chosen ? 0 : nil, reaction: .reactionEmoji(.init(emoticon: count.emoticon)), count: count.count))
        }
        let recentReactions: [Api.MessagePeerReaction] = recent.map { reaction in
            .messagePeerReaction(.init(flags: reaction.userId == self.selfUserId ? (1 << 2) : 0, peerId: .peerUser(.init(userId: reaction.userId)), date: reaction.date, reaction: .reactionEmoji(.init(emoticon: reaction.emoticon))))
        }
        return .messageReactions(.init(flags: (1 << 1) | (1 << 2), results: results, recentReactions: recentReactions, topReactors: nil))
    }

    // MARK: - Incoming

    func receiveIncoming(_ incoming: ReticulumIncomingMessage) {
        guard incoming.signatureValid else {
            Logger.shared.log("LocalServer", "Dropped an LXMF message from \(incoming.source) whose signature did not verify")
            return
        }
        guard let selfUserId = self.selfUserId else {
            return
        }
        if self.store.messageId(lxmfHash: incoming.hash) != nil {
            return
        }
        let envelope = LXMFEnvelope(fields: incoming.fields)
        let record = self.record(for: incoming.source, name: incoming.displayName, speaksTelegram: envelope != nil)
        var seen = record
        seen.lastSeenTimestamp = self.now()
        self.store.setPeer(seen)

        switch envelope?.kind {
        case .read?:
            self.receiveRead(envelope!, from: record)
        case .typing?:
            self.emit([.updateUserTyping(.init(flags: 0, userId: record.peerId, topMsgId: nil, action: .sendMessageTypingAction))])
        case .edit?:
            self.receiveEdit(envelope!, from: record)
        case .delete?:
            self.receiveDelete(envelope!, from: record)
        case .reaction?:
            self.receiveReaction(envelope!, from: record)
        case .profile?:
            self.receiveProfile(envelope!, from: record)
        case .message?, .none:
            self.receiveMessage(incoming, envelope: envelope, from: record, selfUserId: selfUserId)
        }
    }

    private func receiveMessage(_ incoming: ReticulumIncomingMessage, envelope: LXMFEnvelope?, from record: LocalServerStore.PeerRecord, selfUserId: Int64) {
        var text = envelope?.text ?? String(decoding: incoming.content, as: UTF8.self)
        let entities = envelope?.entities ?? []
        if text.isEmpty, let title = String(data: incoming.title, encoding: .utf8), !title.isEmpty {
            text = title
        }
        if text.isEmpty {
            text = LXMFPlainFields.describeAttachments(incoming) ?? ""
        }
        if text.isEmpty {
            return
        }
        var replyToId: Int32?
        if let replyHash = incoming.field(0x30)?.binaryValue, let reply = self.store.messageId(lxmfHash: replyHash), reply.peerId == record.peerId {
            replyToId = reply.id
        }
        let now = self.now()
        var date = now
        let sent = Int32(clamping: Int64(incoming.timestamp))
        if abs(Int64(sent) - Int64(now)) < 86400 {
            date = min(sent, now)
        }
        let id = self.allocateMessageId()
        let message = self.apiMessage(id: id, out: false, peerId: record.peerId, fromId: record.peerId, text: text, entities: entities, replyToId: replyToId, date: date)
        self.store.transaction {
            self.storeMessage(message, peerId: record.peerId)
            self.store.setMessageHash(peerId: record.peerId, id: id, lxmfHash: incoming.hash)
            self.bumpDialog(peerId: record.peerId, message: message, incoming: true)
        }
        let pts = self.allocatePts()
        self.emit([.updateNewMessage(.init(message: message, pts: pts, ptsCount: 1))], users: [self.apiUser(record)])
    }

    private func receiveRead(_ envelope: LXMFEnvelope, from record: LocalServerStore.PeerRecord) {
        guard let target = envelope.target, let reference = self.store.messageId(lxmfHash: target), reference.peerId == record.peerId, var dialog = self.store.dialog(peerId: record.peerId) else {
            return
        }
        if reference.id <= dialog.readOutboxMaxId {
            return
        }
        dialog.readOutboxMaxId = reference.id
        self.store.setDialog(dialog)
        let pts = self.allocatePts()
        self.emit([.updateReadHistoryOutbox(.init(peer: .peerUser(.init(userId: record.peerId)), maxId: reference.id, pts: pts, ptsCount: 1))])
    }

    private func receiveEdit(_ envelope: LXMFEnvelope, from record: LocalServerStore.PeerRecord) {
        guard let target = envelope.target, let reference = self.store.messageId(lxmfHash: target), reference.peerId == record.peerId, let message = self.storedMessage(peerId: record.peerId, id: reference.id), case let .message(data) = message, let text = envelope.text else {
            return
        }
        let edited = self.apiMessage(id: reference.id, out: false, peerId: record.peerId, fromId: record.peerId, text: text, entities: envelope.entities, replyToId: self.replyToId(of: data), date: data.date, editDate: envelope.date ?? self.now(), reactions: data.reactions)
        self.storeMessage(edited, peerId: record.peerId)
        let pts = self.allocatePts()
        self.emit([.updateEditMessage(.init(message: edited, pts: pts, ptsCount: 1))], users: [self.apiUser(record)])
    }

    private func receiveDelete(_ envelope: LXMFEnvelope, from record: LocalServerStore.PeerRecord) {
        let ids = envelope.targets.compactMap { self.store.messageId(lxmfHash: $0) }.filter { $0.peerId == record.peerId }.map { $0.id }
        if ids.isEmpty {
            return
        }
        let affected = self.deleteMessages(ids: ids, revoke: false)
        if case let .affectedMessages(data) = affected {
            self.push(.updates(.init(updates: [.updateDeleteMessages(.init(messages: ids, pts: data.pts, ptsCount: data.ptsCount))], users: [], chats: [], date: self.now(), seq: 0)))
        }
    }

    private func receiveReaction(_ envelope: LXMFEnvelope, from record: LocalServerStore.PeerRecord) {
        guard let target = envelope.target, let reference = self.store.messageId(lxmfHash: target), reference.peerId == record.peerId, let message = self.storedMessage(peerId: record.peerId, id: reference.id), case let .message(data) = message else {
            return
        }
        let reactions = self.reactions(of: data, settingFor: record.peerId, emoticon: envelope.reaction ?? "")
        var fromId: Int64 = record.peerId
        if case let .peerUser(from)? = data.fromId {
            fromId = from.userId
        }
        let updated = self.apiMessage(id: reference.id, out: (data.flags & (1 << 1)) != 0, peerId: record.peerId, fromId: fromId, text: data.message, entities: data.entities ?? [], replyToId: self.replyToId(of: data), date: data.date, editDate: data.editDate, reactions: reactions)
        self.storeMessage(updated, peerId: record.peerId)
        let update = Api.Update.updateMessageReactions(.init(flags: 0, peer: .peerUser(.init(userId: record.peerId)), msgId: reference.id, topMsgId: nil, savedPeerId: nil, reactions: reactions ?? .messageReactions(.init(flags: 0, results: [], recentReactions: nil, topReactors: nil))))
        self.emit([update], users: [self.apiUser(record)])
    }

    private func receiveProfile(_ envelope: LXMFEnvelope, from record: LocalServerStore.PeerRecord) {
        var updated = record
        let name = [envelope.firstName ?? "", envelope.lastName ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
        guard !name.isEmpty else {
            return
        }
        updated.announcedName = name
        if !updated.isContact {
            updated.firstName = envelope.firstName ?? ""
            updated.lastName = envelope.lastName ?? ""
        }
        self.store.setPeer(updated)
        self.emit([.updateUserName(.init(userId: updated.peerId, firstName: updated.firstName, lastName: updated.lastName, usernames: []))], users: [self.apiUser(updated)])
    }
}

/// What the server does on its own behalf, settable by the app (Settings ▸ Reticulum Network).
public enum LocalServerPreferences {
    /// Typing indicators are an envelope per keystroke burst: off by default, LoRa is slow.
    public static var sendsTypingIndicators: Bool = false
}

/// Readable text from a stock LXMF client's fields: Sideband's attachments are described in words
/// until the media path (file, image, audio fields) lands.
enum LXMFPlainFields {
    static func describeAttachments(_ message: ReticulumIncomingMessage) -> String? {
        var parts: [String] = []
        if let attachments = message.field(0x05)?.arrayValue {
            for attachment in attachments {
                if let name = attachment.arrayValue?.first?.stringValue {
                    parts.append("📎 \(name)")
                }
            }
        }
        if message.field(0x06) != nil {
            parts.append("🖼 Image")
        }
        if message.field(0x07) != nil {
            parts.append("🎤 Audio message")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }
}
