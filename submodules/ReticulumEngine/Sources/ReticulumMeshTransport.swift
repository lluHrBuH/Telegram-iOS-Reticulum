import Foundation
import SwiftSignalKit
import TelegramCore
import ReticulumFFI

/// `ReticulumTransport` over the Rust LXMF client: messages in and out, announces, the interface
/// list, path requests. Owned by `ReticulumRuntime` for the lifetime of one started stack.
///
/// The Rust router calls back on its own thread while holding its lock, so every callback copies
/// its arguments and hops to `queue`, and no callback calls into the library. Sends live in
/// `pendingSends` keyed by the message hash until the router reports a final state (or the
/// safety timeout), and the message handle is destroyed only then.
final class ReticulumMeshTransport: ReticulumTransport {
    private final class PendingSend {
        let handle: UInt64
        let started: Double
        let report: (ReticulumSendOutcome) -> Void
        var lastState: UInt8 = 0

        init(handle: UInt64, started: Double, report: @escaping (ReticulumSendOutcome) -> Void) {
            self.handle = handle
            self.started = started
            self.report = report
        }
    }

    /// LXMF message states (`LXMessage` in LXMF.py and LXMF-rust).
    private enum MessageState {
        static let sending: UInt8 = 0x02
        static let sent: UInt8 = 0x04
        static let delivered: UInt8 = 0x08
        static let rejected: UInt8 = 0xFD
        static let cancelled: UInt8 = 0xFE
        static let failed: UInt8 = 0xFF
    }

    /// A direct link that never comes up is reported by the router; this is the net under it.
    private static let sendTimeout: Double = 180.0

    let client: UInt64
    let ownAddress: ReticulumAddress
    private let queue: Queue
    private let blockingQueue: Queue
    private let incomingPipe = ValuePipe<ReticulumIncomingMessage>()
    private let announcePipe = ValuePipe<ReticulumAnnounce>()
    private let interfacesPromise = ValuePromise<[ReticulumInterfaceStatus]>([], ignoreRepeated: true)
    private var pendingSends: [Data: PendingSend] = [:]
    private var interfaceTimer: SwiftSignalKit.Timer?
    private var sendTimer: SwiftSignalKit.Timer?
    private var invalidated = false

    init(client: UInt64, ownAddress: ReticulumAddress, queue: Queue, blockingQueue: Queue) {
        self.client = client
        self.ownAddress = ownAddress
        self.queue = queue
        self.blockingQueue = blockingQueue

        let context = Unmanaged.passUnretained(self).toOpaque()
        lxmf_client_set_delivery_callback(client, { context, hash, hashLength, source, sourceLength, _, _, title, content, timestamp, signatureValid, _, fieldsRaw, fieldsLength in
            guard let context = context else {
                return
            }
            let transport = Unmanaged<ReticulumMeshTransport>.fromOpaque(context).takeUnretainedValue()
            let hashData = ReticulumMeshTransport.copy(hash, hashLength)
            let sourceData = ReticulumMeshTransport.copy(source, sourceLength)
            let titleData = title.flatMap { Data(String(cString: $0).utf8) } ?? Data()
            let contentData = content.flatMap { Data(String(cString: $0).utf8) } ?? Data()
            let fieldsData = ReticulumMeshTransport.copy(fieldsRaw, fieldsLength)
            transport.queue.async {
                transport.receiveDelivery(hash: hashData, source: sourceData, title: titleData, content: contentData, timestamp: timestamp, signatureValid: signatureValid == 1, fieldsRaw: fieldsData)
            }
        }, context)
        lxmf_client_set_announce_callback(client, { context, destination, destinationLength, displayName in
            guard let context = context else {
                return
            }
            let transport = Unmanaged<ReticulumMeshTransport>.fromOpaque(context).takeUnretainedValue()
            let destinationData = ReticulumMeshTransport.copy(destination, destinationLength)
            let name = displayName.map { String(cString: $0) }
            transport.queue.async {
                transport.receiveAnnounce(destination: destinationData, displayName: name)
            }
        }, context)
        lxmf_client_set_message_state_callback(client, { context, hash, hashLength, state in
            guard let context = context else {
                return
            }
            let transport = Unmanaged<ReticulumMeshTransport>.fromOpaque(context).takeUnretainedValue()
            let hashData = ReticulumMeshTransport.copy(hash, hashLength)
            transport.queue.async {
                transport.receiveState(hash: hashData, state: state)
            }
        }, context)

        self.queue.async { [weak self] in
            guard let self else {
                return
            }
            self.pollInterfaces()
            let timer = SwiftSignalKit.Timer(timeout: 3.0, repeat: true, completion: { [weak self] in
                self?.pollInterfaces()
            }, queue: self.queue)
            self.interfaceTimer = timer
            timer.start()
        }
    }

    /// Stops reporting; the runtime shuts the client down right after, which ends the callbacks.
    func invalidate() {
        self.queue.async {
            self.invalidated = true
            self.interfaceTimer?.invalidate()
            self.interfaceTimer = nil
            self.sendTimer?.invalidate()
            self.sendTimer = nil
            for (_, pending) in self.pendingSends {
                pending.report(.failed("stack stopped"))
                lxmf_message_destroy(pending.handle)
            }
            self.pendingSends.removeAll()
            self.interfacesPromise.set([])
        }
    }

    private static func copy(_ pointer: UnsafePointer<UInt8>?, _ length: UInt32) -> Data {
        guard let pointer = pointer, length > 0 else {
            return Data()
        }
        return Data(bytes: pointer, count: Int(length))
    }

    // MARK: - ReticulumTransport

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
        return Signal { [weak self] subscriber in
            guard let self else {
                subscriber.putNext(.failed("stack stopped"))
                subscriber.putCompletion()
                return EmptyDisposable
            }
            self.queue.async {
                self.startSend(message, report: { outcome in
                    subscriber.putNext(outcome)
                    if outcome.isFinal {
                        subscriber.putCompletion()
                    }
                })
            }
            return EmptyDisposable
        }
    }

    func requestPath(to address: ReticulumAddress, timeout: Double) -> Signal<Bool, NoError> {
        return Signal { [weak self] subscriber in
            guard let self else {
                subscriber.putNext(false)
                subscriber.putCompletion()
                return EmptyDisposable
            }
            self.blockingQueue.async {
                let bytes = [UInt8](address.hash)
                let result = tgrns_transport_wait_for_path(bytes, UInt32(bytes.count), timeout)
                subscriber.putNext(result == 1)
                subscriber.putCompletion()
            }
            return EmptyDisposable
        }
    }

    func knowsIdentity(of address: ReticulumAddress) -> Bool {
        let bytes = [UInt8](address.hash)
        return rns_identity_known(bytes, UInt32(bytes.count)) == 1
    }

    func announce() {
        self.queue.async {
            if self.invalidated {
                return
            }
            if lxmf_client_announce(self.client) != 0 {
                Logger.shared.log("Reticulum", "Announce failed: \(ReticulumRuntime.lastError())")
            }
        }
    }

    func setDisplayName(_ name: String) {
        self.queue.async {
            if self.invalidated {
                return
            }
            lxmf_client_set_announce_display_name(self.client, name)
            lxmf_client_set_message_display_name(self.client, name)
        }
    }

    // MARK: - Sending (queue)

    private func startSend(_ message: ReticulumOutgoingMessage, report: @escaping (ReticulumSendOutcome) -> Void) {
        if self.invalidated {
            report(.failed("stack stopped"))
            return
        }
        let method: UInt8
        switch message.method {
        case .opportunistic:
            method = 1
        case .direct:
            method = 2
        case .propagated:
            method = 3
        }
        let destination = [UInt8](message.destination.hash)
        let title = String(decoding: message.title, as: UTF8.self)
        let handle = lxmf_message_new(self.client, destination, UInt32(destination.count), "", title, method)
        if handle == 0 {
            report(.failed(ReticulumRuntime.lastError()))
            return
        }
        let content = [UInt8](message.content)
        if tgrns_message_set_content_bytes(handle, content, UInt32(content.count)) != 0 {
            lxmf_message_destroy(handle)
            report(.failed(ReticulumRuntime.lastError()))
            return
        }
        for field in message.fields {
            let encoded = [UInt8](field.value.encoded())
            if tgrns_message_set_field_msgpack(handle, field.id, encoded, UInt32(encoded.count)) != 0 {
                lxmf_message_destroy(handle)
                report(.failed(ReticulumRuntime.lastError()))
                return
            }
        }
        if lxmf_message_send(self.client, handle) != 0 {
            lxmf_message_destroy(handle)
            report(.failed(ReticulumRuntime.lastError()))
            return
        }
        var hashBytes = [UInt8](repeating: 0, count: 32)
        let hashLength = lxmf_message_hash(handle, &hashBytes, 32)
        // Without a hash the state callback cannot find the send; the state poll still can.
        let key = hashLength > 0 ? Data(hashBytes[0..<Int(hashLength)]) : Data("handle:\(handle)".utf8)
        let pending = PendingSend(handle: handle, started: CFAbsoluteTimeGetCurrent(), report: report)
        self.pendingSends[key] = pending
        report(.sending)
        self.applyState(UInt8(clamping: max(0, lxmf_message_state(handle))), to: pending, key: key)
        self.ensureSendTimer()
    }

    private func ensureSendTimer() {
        if self.sendTimer != nil || self.pendingSends.isEmpty {
            return
        }
        let timer = SwiftSignalKit.Timer(timeout: 1.0, repeat: true, completion: { [weak self] in
            self?.pollSends()
        }, queue: self.queue)
        self.sendTimer = timer
        timer.start()
    }

    private func pollSends() {
        let now = CFAbsoluteTimeGetCurrent()
        for (key, pending) in self.pendingSends {
            if now - pending.started > ReticulumMeshTransport.sendTimeout {
                self.finish(pending, key: key, outcome: .failed("timed out"))
                continue
            }
            let state = lxmf_message_state(pending.handle)
            if state >= 0 {
                self.applyState(UInt8(clamping: state), to: pending, key: key)
            }
        }
        if self.pendingSends.isEmpty {
            self.sendTimer?.invalidate()
            self.sendTimer = nil
        }
    }

    private func receiveState(hash: Data, state: UInt8) {
        guard let pending = self.pendingSends[hash] else {
            return
        }
        self.applyState(state, to: pending, key: hash)
    }

    private func applyState(_ state: UInt8, to pending: PendingSend, key: Data) {
        if state == pending.lastState {
            return
        }
        pending.lastState = state
        switch state {
        case MessageState.sent:
            pending.report(.sent)
        case MessageState.delivered:
            self.finish(pending, key: key, outcome: .delivered)
        case MessageState.rejected:
            self.finish(pending, key: key, outcome: .failed("rejected"))
        case MessageState.cancelled:
            self.finish(pending, key: key, outcome: .failed("cancelled"))
        case MessageState.failed:
            self.finish(pending, key: key, outcome: .failed("delivery failed"))
        default:
            break
        }
    }

    private func finish(_ pending: PendingSend, key: Data, outcome: ReticulumSendOutcome) {
        self.pendingSends.removeValue(forKey: key)
        lxmf_message_destroy(pending.handle)
        pending.report(outcome)
    }

    // MARK: - Receiving (queue)

    private func receiveDelivery(hash: Data, source: Data, title: Data, content: Data, timestamp: Double, signatureValid: Bool, fieldsRaw: Data) {
        if self.invalidated {
            return
        }
        guard let address = ReticulumAddress(hash: source) else {
            Logger.shared.log("Reticulum", "Dropped a message with a \(source.count)-byte source hash")
            return
        }
        var fields: MsgPackValue = .nil
        if !fieldsRaw.isEmpty {
            if let decoded = MsgPackValue.decode(fieldsRaw) {
                fields = decoded
            } else {
                Logger.shared.log("Reticulum", "Undecodable fields (\(fieldsRaw.count) bytes) on a message from \(address.hex)")
            }
        }
        let message = ReticulumIncomingMessage(hash: hash, source: address, title: title, content: content, timestamp: timestamp, signatureValid: signatureValid, fields: fields, displayName: self.recallDisplayName(of: address))
        self.incomingPipe.putNext(message)
    }

    private func receiveAnnounce(destination: Data, displayName: String?) {
        if self.invalidated {
            return
        }
        guard let address = ReticulumAddress(hash: destination) else {
            return
        }
        self.announcePipe.putNext(ReticulumAnnounce(address: address, displayName: displayName, timestamp: Date().timeIntervalSince1970))
    }

    private func recallDisplayName(of address: ReticulumAddress) -> String? {
        let bytes = [UInt8](address.hash)
        var buffer = [CChar](repeating: 0, count: Int(LXMF_DISPLAY_NAME_BUF_LEN))
        let written = lxmf_client_recall_display_name(self.client, bytes, UInt32(bytes.count), &buffer, UInt32(buffer.count))
        if written <= 1 {
            return nil
        }
        let name = String(cString: buffer)
        return name.isEmpty ? nil : name
    }

    // MARK: - Interfaces (queue)

    private func pollInterfaces() {
        if self.invalidated {
            return
        }
        var result: [ReticulumInterfaceStatus] = []
        let count = tgrns_interface_count()
        var index: UInt32 = 0
        while index < count {
            var status = TgrnsInterfaceStatus()
            if tgrns_interface_at(index, &status) == 0 {
                let name = withUnsafePointer(to: &status.name) { pointer -> String in
                    return pointer.withMemoryRebound(to: CChar.self, capacity: 128) { String(cString: $0) }
                }
                result.append(ReticulumInterfaceStatus(name: name, online: status.online != 0, bitrate: status.bitrate_set != 0 ? status.bitrate : nil, rssi: status.rssi_set != 0 ? status.rssi : nil, snr: status.snr_set != 0 ? status.snr : nil, rxBytes: status.rx_bytes, txBytes: status.tx_bytes))
            }
            index += 1
        }
        self.interfacesPromise.set(result)
    }
}
