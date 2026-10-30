import Foundation
import Postbox
import SwiftSignalKit
import MtProtoKit
internal import TelegramApi

/// Media over the mesh. The client uploads a file in parts (`upload.saveFilePart`,
/// `upload.saveBigFilePart`) into `<store>/uploads/<fileId>/`, then sends it
/// (`messages.sendMedia`): the parts are joined into `<store>/files/<id>`, a photo or document with
/// local ids is minted for the message, and the bytes travel in the standard LXMF fields so stock
/// clients show them too: `0x06` image `[ext, bytes]`, `0x07` audio `[mode, bytes]` for a voice
/// message (Opus in Ogg, mode `0x16`), `0x05` attachments `[[name, bytes]]` for everything else. A
/// Telegram peer also gets the sender's `MessageMedia` in the envelope, so a document keeps its
/// attributes (file name, dimensions, duration, waveform); the receiver mints its own ids and
/// serves the bytes back to its client through `upload.getFile`, the same way a server would.
extension LocalServer {
    private static let maxFileSize: Int64 = 64 * 1024 * 1024

    func mediaHandlers() -> [String: LocalServerHandler] {
        var handlers: [String: LocalServerHandler] = [:]

        let savePart: LocalServerHandler = { server, call in
            let fileId: Int64 = call.argument("fileId") ?? 0
            let part: Int32 = call.argument("filePart") ?? 0
            guard let bytes: Buffer = call.argument("bytes"), fileId != 0, part >= 0 else {
                return .fail(localServerError(400, "FILE_PART_INVALID"))
            }
            return .single(.value(server.saveUploadPart(fileId: fileId, part: part, bytes: bytes.makeData()) ? Api.Bool.boolTrue : Api.Bool.boolFalse))
        }
        handlers["upload.saveFilePart"] = savePart
        handlers["upload.saveBigFilePart"] = savePart

        handlers["upload.getFile"] = { server, call in
            guard let location: Api.InputFileLocation = call.argument("location") else {
                return .fail(localServerError(400, "LOCATION_INVALID"))
            }
            let offset: Int64 = call.argument("offset") ?? 0
            let limit: Int32 = call.argument("limit") ?? 0
            guard let fileId = server.fileId(for: location), let record = server.store.file(id: fileId), let data = server.fileData(record) else {
                return .fail(localServerError(400, "FILE_REFERENCE_EXPIRED"))
            }
            var bytes = Data()
            if offset >= 0, offset < Int64(data.count) {
                let start = Int(offset)
                let end = min(data.count, start + Int(max(0, limit)))
                bytes = data.subdata(in: start..<end)
            }
            return .single(.value(Api.upload.File.file(.init(type: Api.storage.FileType.fileUnknown, mtime: server.now(), bytes: Buffer(data: bytes)))))
        }

        handlers["messages.sendMedia"] = { server, call in
            guard let peer: Api.InputPeer = call.argument("peer"), let record = server.peerRecord(inputPeer: peer) else {
                return .fail(localServerError(400, "PEER_ID_INVALID"))
            }
            guard let inputMedia: Api.InputMedia = call.argument("media") else {
                return .fail(localServerError(400, "MEDIA_INVALID"))
            }
            let text: String = call.argument("message") ?? ""
            let randomId: Int64 = call.argument("randomId") ?? 0
            let entities: [Api.MessageEntity] = call.elements("entities") ?? []
            let replyTo: Api.InputReplyTo? = call.argument("replyTo")
            guard let (media, attachment) = server.media(from: inputMedia) else {
                return .fail(localServerError(400, "MEDIA_INVALID"))
            }
            return server.send(text: text, entities: entities, media: media, attachment: attachment, replyTo: replyTo, randomId: randomId, to: record)
        }
        handlers["messages.uploadMedia"] = { server, call in
            guard let inputMedia: Api.InputMedia = call.argument("media"), let (media, _) = server.media(from: inputMedia) else {
                return .fail(localServerError(400, "MEDIA_INVALID"))
            }
            return .single(.value(media))
        }

        handlers["photos.uploadProfilePhoto"] = { server, call in
            guard let selfRecord = server.selfUserId.flatMap({ server.store.peer(id: $0) }) else {
                return .fail(localServerError(401, "AUTH_KEY_UNREGISTERED"))
            }
            guard let file: Api.InputFile = call.argument("file"), let data = server.assembleUpload(file), let (photo, _) = server.makePhoto(data: data) else {
                return .fail(localServerError(400, "PHOTO_INVALID"))
            }
            var updated = selfRecord
            updated.photoId = server.photoId(of: photo)
            server.store.setPeer(updated)
            server.emit([.updateUser(.init(userId: updated.peerId))], users: [server.apiUser(updated)])
            server.sendProfileToContacts()
            return .single(.value(Api.photos.Photo.photo(.init(photo: photo, users: [server.apiUser(updated)]))))
        }
        handlers["photos.updateProfilePhoto"] = { server, call in
            guard let selfRecord = server.selfUserId.flatMap({ server.store.peer(id: $0) }) else {
                return .fail(localServerError(401, "AUTH_KEY_UNREGISTERED"))
            }
            // Only "no photo" is reachable here: the client sends the chosen photo's input when it
            // picks an older one, which this server has no gallery for.
            var updated = selfRecord
            if let photoId = updated.photoId {
                server.store.removeFile(id: photoId)
            }
            updated.photoId = nil
            server.store.setPeer(updated)
            server.emit([.updateUser(.init(userId: updated.peerId))], users: [server.apiUser(updated)])
            server.sendProfileToContacts()
            return .single(.value(Api.photos.Photo.photo(.init(photo: .photoEmpty(.init(id: 0)), users: [server.apiUser(updated)]))))
        }
        handlers["photos.getUserPhotos"] = { server, call in
            guard let user: Api.InputUser = call.argument("userId"), let record = server.peerRecord(inputUser: user) else {
                return .fail(localServerError(400, "USER_ID_INVALID"))
            }
            var photos: [Api.Photo] = []
            if let photoId = record.photoId, let file = server.store.file(id: photoId) {
                photos.append(server.apiPhoto(file))
            }
            return .single(.value(Api.photos.Photos.photos(.init(photos: photos, users: [server.apiUser(record)]))))
        }

        return handlers
    }

    // MARK: - Uploads

    private var uploadsDirectory: String {
        return self.store.basePath + "/uploads"
    }

    private var filesDirectory: String {
        return self.store.basePath + "/files"
    }

    private func saveUploadPart(fileId: Int64, part: Int32, bytes: Data) -> Bool {
        let directory = self.uploadsDirectory + "/\(UInt64(bitPattern: fileId))"
        do {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: nil)
            try bytes.write(to: URL(fileURLWithPath: directory + "/\(part)"), options: .atomic)
            return true
        } catch {
            Logger.shared.log("LocalServer", "Could not store part \(part) of upload \(fileId): \(error)")
            return false
        }
    }

    /// The uploaded file's bytes, parts in order, and the parts removed.
    func assembleUpload(_ file: Api.InputFile) -> Data? {
        let fileId: Int64
        let parts: Int32
        switch file {
        case let .inputFile(data):
            fileId = data.id
            parts = data.parts
        case let .inputFileBig(data):
            fileId = data.id
            parts = data.parts
        case .inputFileStoryDocument:
            return nil
        }
        let directory = self.uploadsDirectory + "/\(UInt64(bitPattern: fileId))"
        var result = Data()
        var index: Int32 = 0
        while index < parts {
            guard let part = FileManager.default.contents(atPath: directory + "/\(index)") else {
                Logger.shared.log("LocalServer", "Upload \(fileId) is missing part \(index) of \(parts)")
                return nil
            }
            result.append(part)
            if Int64(result.count) > LocalServer.maxFileSize {
                return nil
            }
            index += 1
        }
        try? FileManager.default.removeItem(atPath: directory)
        return result
    }

    // MARK: - The file store

    /// Stores bytes under a fresh id and returns the record.
    func storeFile(data: Data, name: String, mimeType: String, width: Int32? = nil, height: Int32? = nil) -> LocalServerStore.FileRecord? {
        var id = Int64.random(in: Int64.min...Int64.max)
        while id == 0 || self.store.file(id: id) != nil {
            id = Int64.random(in: Int64.min...Int64.max)
        }
        let relativePath = "files/\(UInt64(bitPattern: id))"
        do {
            try FileManager.default.createDirectory(atPath: self.filesDirectory, withIntermediateDirectories: true, attributes: nil)
            try data.write(to: URL(fileURLWithPath: self.store.basePath + "/" + relativePath), options: .atomic)
        } catch {
            Logger.shared.log("LocalServer", "Could not store a \(data.count)-byte file: \(error)")
            return nil
        }
        let record = LocalServerStore.FileRecord(id: id, size: Int64(data.count), mimeType: mimeType, name: name, relativePath: relativePath, width: width, height: height, accessHash: Int64.random(in: Int64.min...Int64.max))
        self.store.setFile(record)
        return record
    }

    func fileData(_ record: LocalServerStore.FileRecord) -> Data? {
        return FileManager.default.contents(atPath: self.store.basePath + "/" + record.relativePath)
    }

    private func fileId(for location: Api.InputFileLocation) -> Int64? {
        switch location {
        case let .inputPhotoFileLocation(data):
            return data.id
        case let .inputDocumentFileLocation(data):
            return data.id
        case let .inputPeerPhotoFileLocation(data):
            return data.photoId
        default:
            return nil
        }
    }

    // MARK: - Minting media

    func apiPhoto(_ file: LocalServerStore.FileRecord) -> Api.Photo {
        let width = file.width ?? 0
        let height = file.height ?? 0
        return .photo(.init(flags: 0, id: file.id, accessHash: file.accessHash ?? 0, fileReference: Buffer(), date: self.now(), sizes: [.photoSize(.init(type: "x", w: width, h: height, size: Int32(clamping: file.size)))], videoSizes: nil, dcId: 1))
    }

    func apiDocument(_ file: LocalServerStore.FileRecord, attributes: [Api.DocumentAttribute]) -> Api.Document {
        var attributes = attributes
        if !attributes.contains(where: { if case .documentAttributeFilename = $0 { return true } else { return false } }), !file.name.isEmpty {
            attributes.append(.documentAttributeFilename(.init(fileName: file.name)))
        }
        return .document(.init(flags: 0, id: file.id, accessHash: file.accessHash ?? 0, fileReference: Buffer(), date: self.now(), mimeType: file.mimeType, size: file.size, thumbs: nil, videoThumbs: nil, dcId: 1, attributes: attributes))
    }

    func photoId(of photo: Api.Photo) -> Int64? {
        if case let .photo(data) = photo {
            return data.id
        }
        return nil
    }

    func makePhoto(data: Data) -> (Api.Photo, LocalServerStore.FileRecord)? {
        guard let image = ImageHeader.parse(data) else {
            return nil
        }
        guard let file = self.storeFile(data: data, name: "photo.\(image.fileExtension)", mimeType: image.mimeType, width: image.width, height: image.height) else {
            return nil
        }
        return (self.apiPhoto(file), file)
    }

    func makeDocument(data: Data, name: String, mimeType: String, attributes: [Api.DocumentAttribute]) -> (Api.Document, LocalServerStore.FileRecord)? {
        guard let file = self.storeFile(data: data, name: name, mimeType: mimeType) else {
            return nil
        }
        return (self.apiDocument(file, attributes: attributes), file)
    }

    /// The bytes of a sent media as LXMF fields for the peer.
    struct MediaAttachment {
        var fields: [(id: UInt8, value: MsgPackValue)]
    }

    /// The server's media for the client's input media, with the LXMF fields that carry its bytes.
    func media(from inputMedia: Api.InputMedia) -> (Api.MessageMedia, MediaAttachment)? {
        switch inputMedia {
        case let .inputMediaUploadedPhoto(data):
            guard let bytes = self.assembleUpload(data.file), let (photo, file) = self.makePhoto(data: bytes) else {
                return nil
            }
            let media = Api.MessageMedia.messageMediaPhoto(.init(flags: 1 << 0, photo: photo, ttlSeconds: nil, video: nil))
            return (media, MediaAttachment(fields: [(0x06, .array([.string(ImageHeader.fileExtension(forMimeType: file.mimeType)), .binary(bytes)]))]))
        case let .inputMediaUploadedDocument(data):
            guard let bytes = self.assembleUpload(data.file) else {
                return nil
            }
            var name = ""
            var isVoice = false
            for attribute in data.attributes {
                if case let .documentAttributeFilename(filename) = attribute {
                    name = filename.fileName
                }
                if case let .documentAttributeAudio(audio) = attribute, (audio.flags & (1 << 10)) != 0 {
                    isVoice = true
                }
            }
            if name.isEmpty {
                name = isVoice ? "voice.ogg" : "file"
            }
            guard let (document, _) = self.makeDocument(data: bytes, name: name, mimeType: data.mimeType, attributes: data.attributes) else {
                return nil
            }
            var flags: Int32 = 1 << 0
            if isVoice {
                flags |= 1 << 8
            }
            let media = Api.MessageMedia.messageMediaDocument(.init(flags: flags, document: document, altDocuments: nil, videoCover: nil, videoTimestamp: nil, ttlSeconds: nil))
            let field: (id: UInt8, value: MsgPackValue)
            if isVoice {
                field = (0x07, .array([.uint(LXMFAudioMode.opusStandard), .binary(bytes)]))
            } else {
                field = (0x05, .array([.array([.string(name), .binary(bytes)])]))
            }
            return (media, MediaAttachment(fields: [field]))
        case let .inputMediaPhoto(data):
            guard case let .inputPhoto(input) = data.id, let file = self.store.file(id: input.id), let bytes = self.fileData(file) else {
                return nil
            }
            let media = Api.MessageMedia.messageMediaPhoto(.init(flags: 1 << 0, photo: self.apiPhoto(file), ttlSeconds: nil, video: nil))
            return (media, MediaAttachment(fields: [(0x06, .array([.string(ImageHeader.fileExtension(forMimeType: file.mimeType)), .binary(bytes)]))]))
        case let .inputMediaDocument(data):
            guard case let .inputDocument(input) = data.id, let file = self.store.file(id: input.id), let bytes = self.fileData(file) else {
                return nil
            }
            let media = Api.MessageMedia.messageMediaDocument(.init(flags: 1 << 0, document: self.apiDocument(file, attributes: []), altDocuments: nil, videoCover: nil, videoTimestamp: nil, ttlSeconds: nil))
            return (media, MediaAttachment(fields: [(0x05, .array([.array([.string(file.name), .binary(bytes)])]))]))
        default:
            return nil
        }
    }

    // MARK: - Incoming media

    /// The media of an incoming LXMF message: the bytes from the standard fields, the attributes
    /// from a Telegram peer's envelope when present.
    func media(fromIncoming incoming: ReticulumIncomingMessage, envelope: LXMFEnvelope?) -> Api.MessageMedia? {
        var senderDocument: Api.Document.Cons_document?
        var senderIsVoice = false
        if case let .messageMediaDocument(data)? = envelope?.media, case let .document(document)? = data.document {
            senderDocument = document
            senderIsVoice = (data.flags & (1 << 8)) != 0
        }

        if let image = incoming.field(0x06)?.arrayValue, image.count >= 2, let bytes = image[1].binaryValue, let (photo, _) = self.makePhoto(data: bytes) {
            return .messageMediaPhoto(.init(flags: 1 << 0, photo: photo, ttlSeconds: nil, video: nil))
        }
        if let audio = incoming.field(0x07)?.arrayValue, audio.count >= 2, let mode = audio[0].intValue, let bytes = audio[1].binaryValue {
            if LXMFAudioMode.isOpus(mode) {
                var attributes: [Api.DocumentAttribute] = senderDocument?.attributes ?? []
                if !attributes.contains(where: { if case .documentAttributeAudio = $0 { return true } else { return false } }) {
                    attributes.append(.documentAttributeAudio(.init(flags: 1 << 10, duration: 0, title: nil, performer: nil, waveform: nil)))
                }
                if let (document, _) = self.makeDocument(data: bytes, name: "voice.ogg", mimeType: "audio/ogg", attributes: attributes) {
                    return .messageMediaDocument(.init(flags: (1 << 0) | (1 << 8), document: document, altDocuments: nil, videoCover: nil, videoTimestamp: nil, ttlSeconds: nil))
                }
            } else if let (document, _) = self.makeDocument(data: bytes, name: "audio-codec2-\(mode).bin", mimeType: "application/octet-stream", attributes: []) {
                // Codec2 modes have no decoder here; the bytes are kept as a file.
                return .messageMediaDocument(.init(flags: 1 << 0, document: document, altDocuments: nil, videoCover: nil, videoTimestamp: nil, ttlSeconds: nil))
            }
        }
        if let attachments = incoming.field(0x05)?.arrayValue, let first = attachments.first?.arrayValue, first.count >= 2, let bytes = first[1].binaryValue {
            let name = first[0].stringValue ?? senderDocument?.attributes.compactMap { attribute -> String? in
                if case let .documentAttributeFilename(data) = attribute {
                    return data.fileName
                }
                return nil
            }.first ?? "file"
            let mimeType = senderDocument?.mimeType ?? ImageHeader.mimeType(forFileName: name)
            if let (document, _) = self.makeDocument(data: bytes, name: name, mimeType: mimeType, attributes: senderDocument?.attributes ?? []) {
                var flags: Int32 = 1 << 0
                if senderIsVoice {
                    flags |= 1 << 8
                }
                return .messageMediaDocument(.init(flags: flags, document: document, altDocuments: nil, videoCover: nil, videoTimestamp: nil, ttlSeconds: nil))
            }
        }
        return nil
    }

    /// The LXMF fields that carry this account's profile photo to a peer (the `.profile` envelope).
    func profilePhotoFields() -> [(id: UInt8, value: MsgPackValue)] {
        guard let selfRecord = self.selfUserId.flatMap({ self.store.peer(id: $0) }), let photoId = selfRecord.photoId, let file = self.store.file(id: photoId), let bytes = self.fileData(file) else {
            return []
        }
        return [(0x06, .array([.string(ImageHeader.fileExtension(forMimeType: file.mimeType)), .binary(bytes)]))]
    }

    /// A peer's profile photo from a `.profile` envelope's image field; true when it changed.
    func receiveProfilePhoto(_ incoming: ReticulumIncomingMessage, record: inout LocalServerStore.PeerRecord) -> Bool {
        guard let image = incoming.field(0x06)?.arrayValue, image.count >= 2, let bytes = image[1].binaryValue else {
            return false
        }
        if let photoId = record.photoId, let existing = self.store.file(id: photoId), let existingData = self.fileData(existing), existingData == bytes {
            return false
        }
        guard let (photo, _) = self.makePhoto(data: bytes) else {
            return false
        }
        if let photoId = record.photoId {
            self.store.removeFile(id: photoId)
        }
        record.photoId = self.photoId(of: photo)
        return true
    }
}

/// LXMF `FIELD_AUDIO` modes (LXMF.py): Codec2 below 0x10, Opus in Ogg from 0x10.
enum LXMFAudioMode {
    static let opusOgg: UInt64 = 0x10
    static let opusStandard: UInt64 = 0x16

    static func isOpus(_ mode: Int64) -> Bool {
        return mode >= 0x10 && mode < 0x20
    }
}

/// Image dimensions and type from a file's header: JPEG, PNG, GIF and WebP, enough to mint a
/// `photoSize` without an image library (TelegramCore cannot import UIKit).
enum ImageHeader {
    struct Info {
        var width: Int32
        var height: Int32
        var mimeType: String
        var fileExtension: String
    }

    static func parse(_ data: Data) -> Info? {
        let bytes = [UInt8](data.prefix(64 * 1024))
        guard bytes.count >= 12 else {
            return nil
        }
        if bytes[0] == 0xFF && bytes[1] == 0xD8 {
            return self.parseJPEG(bytes).map { Info(width: $0.0, height: $0.1, mimeType: "image/jpeg", fileExtension: "jpg") }
        }
        if bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47, bytes.count >= 24 {
            let width = self.uint32BE(bytes, 16)
            let height = self.uint32BE(bytes, 20)
            return Info(width: Int32(clamping: width), height: Int32(clamping: height), mimeType: "image/png", fileExtension: "png")
        }
        if bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46 {
            let width = Int32(bytes[6]) | (Int32(bytes[7]) << 8)
            let height = Int32(bytes[8]) | (Int32(bytes[9]) << 8)
            return Info(width: width, height: height, mimeType: "image/gif", fileExtension: "gif")
        }
        if bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46 && bytes[8] == 0x57 && bytes[9] == 0x45 && bytes[10] == 0x42 && bytes[11] == 0x50 {
            return self.parseWebP(bytes).map { Info(width: $0.0, height: $0.1, mimeType: "image/webp", fileExtension: "webp") }
        }
        return nil
    }

    static func fileExtension(forMimeType mimeType: String) -> String {
        switch mimeType {
        case "image/png":
            return "png"
        case "image/gif":
            return "gif"
        case "image/webp":
            return "webp"
        default:
            return "jpg"
        }
    }

    static func mimeType(forFileName name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg":
            return "image/jpeg"
        case "png":
            return "image/png"
        case "gif":
            return "image/gif"
        case "webp":
            return "image/webp"
        case "mp4", "m4v":
            return "video/mp4"
        case "mov":
            return "video/quicktime"
        case "mp3":
            return "audio/mpeg"
        case "ogg", "oga", "opus":
            return "audio/ogg"
        case "m4a":
            return "audio/mp4"
        case "pdf":
            return "application/pdf"
        case "txt":
            return "text/plain"
        case "zip":
            return "application/zip"
        default:
            return "application/octet-stream"
        }
    }

    private static func uint32BE(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        return (UInt32(bytes[offset]) << 24) | (UInt32(bytes[offset + 1]) << 16) | (UInt32(bytes[offset + 2]) << 8) | UInt32(bytes[offset + 3])
    }

    private static func parseJPEG(_ bytes: [UInt8]) -> (Int32, Int32)? {
        var index = 2
        while index + 9 < bytes.count {
            guard bytes[index] == 0xFF else {
                index += 1
                continue
            }
            let marker = bytes[index + 1]
            if marker == 0xFF {
                index += 1
                continue
            }
            if marker == 0xD8 || (marker >= 0xD0 && marker <= 0xD7) || marker == 0x01 {
                index += 2
                continue
            }
            let length = Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
            // SOF0 to SOF15 except DHT (C4), JPG (C8), DAC (CC).
            if marker >= 0xC0 && marker <= 0xCF && marker != 0xC4 && marker != 0xC8 && marker != 0xCC {
                let height = Int32(bytes[index + 5]) << 8 | Int32(bytes[index + 6])
                let width = Int32(bytes[index + 7]) << 8 | Int32(bytes[index + 8])
                return (width, height)
            }
            if length < 2 {
                return nil
            }
            index += 2 + length
        }
        return nil
    }

    private static func parseWebP(_ bytes: [UInt8]) -> (Int32, Int32)? {
        guard bytes.count >= 30 else {
            return nil
        }
        let chunk = String(bytes: bytes[12..<16], encoding: .ascii) ?? ""
        switch chunk {
        case "VP8X":
            let width = Int32(bytes[24]) | (Int32(bytes[25]) << 8) | (Int32(bytes[26]) << 16)
            let height = Int32(bytes[27]) | (Int32(bytes[28]) << 8) | (Int32(bytes[29]) << 16)
            return (width + 1, height + 1)
        case "VP8L":
            let b0 = Int32(bytes[21]), b1 = Int32(bytes[22]), b2 = Int32(bytes[23]), b3 = Int32(bytes[24])
            let width = (b0 | (b1 << 8)) & 0x3FFF
            let height = ((b1 >> 6) | (b2 << 2) | (b3 << 10)) & 0x3FFF
            return (width + 1, height + 1)
        case "VP8 ":
            let width = Int32(bytes[26]) | (Int32(bytes[27]) << 8)
            let height = Int32(bytes[28]) | (Int32(bytes[29]) << 8)
            return (width & 0x3FFF, height & 0x3FFF)
        default:
            return nil
        }
    }
}
