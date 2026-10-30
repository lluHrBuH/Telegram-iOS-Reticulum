import Foundation
import CoreBluetooth
import SwiftSignalKit
import TelegramCore
import ReticulumFFI

/// An RNode over Bluetooth LE. The RNode firmware exposes the Nordic UART service; this host is
/// the radio's serial line: notifications from the TX characteristic are fed to the Rust RNode
/// interface (`rns_rnode_iface_feed`), and the KISS frames Rust hands to `sendFn` are written to
/// the RX characteristic in link-sized chunks, paced by `canSendWriteWithoutResponse`.
///
/// The interface is registered once the notification is on, and its DETECT handshake
/// (`rns_rnode_iface_configure`, which blocks for a few seconds) runs on the blocking queue while
/// bytes keep flowing. A disconnect deregisters it and reconnects after a pause until `stop()`.
final class RNodeBluetoothHost: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let serviceUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    /// Written by the central (the radio's serial input).
    static let rxUUID = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
    /// Notified by the radio (its serial output).
    static let txUUID = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")

    private let peripheralId: UUID?
    private let radio: TelegramCoreReticulumRadio
    private let blockingQueue: Queue
    private let bleQueue = DispatchQueue(label: "org.telegram.reticulum.rnode")
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var rxCharacteristic: CBCharacteristic?
    private var handle: UInt64 = 0
    private var outgoing: [Data] = []
    private var stopped = false
    private var configuring = false

    init(peripheralId: String, radio: TelegramCoreReticulumRadio, blockingQueue: Queue) {
        self.peripheralId = UUID(uuidString: peripheralId)
        self.radio = radio
        self.blockingQueue = blockingQueue
        super.init()
    }

    func start() {
        self.bleQueue.async {
            if self.central == nil {
                self.central = CBCentralManager(delegate: self, queue: self.bleQueue, options: [CBCentralManagerOptionShowPowerAlertKey: false])
            }
        }
    }

    func stop() {
        self.bleQueue.sync {
            self.stopped = true
            self.deregisterInterface()
            if let peripheral = self.peripheral {
                self.central?.cancelPeripheralConnection(peripheral)
            }
            self.central?.stopScan()
            self.peripheral = nil
        }
    }

    /// The radio's telemetry as the interface last saw it, nil while no interface is registered.
    func stats() -> RnsRNodeStats? {
        return self.bleQueue.sync { () -> RnsRNodeStats? in
            guard self.handle != 0 else {
                return nil
            }
            var stats = RnsRNodeStats()
            if rns_rnode_iface_get_stats(self.handle, &stats) != 0 {
                return nil
            }
            return stats
        }
    }

    // MARK: - Connecting (bleQueue)

    private func connectIfPossible() {
        guard !self.stopped, let central = self.central, central.state == .poweredOn, self.peripheral == nil else {
            return
        }
        if let peripheralId = self.peripheralId, let known = central.retrievePeripherals(withIdentifiers: [peripheralId]).first {
            self.connect(known)
        } else {
            central.scanForPeripherals(withServices: [RNodeBluetoothHost.serviceUUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        }
    }

    private func connect(_ peripheral: CBPeripheral) {
        self.central?.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        self.central?.connect(peripheral, options: nil)
    }

    private func scheduleReconnect() {
        self.bleQueue.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            self?.connectIfPossible()
        }
    }

    // MARK: - The Rust interface (bleQueue)

    private func registerInterface() {
        guard self.handle == 0, !self.configuring else {
            return
        }
        var config = RnsRNodeRadioConfig()
        config.frequency = UInt64(max(0, self.radio.frequency))
        config.bandwidth = UInt32(max(0, self.radio.bandwidth))
        config.txpower = UInt8(clamping: self.radio.txPower)
        config.sf = UInt8(clamping: self.radio.spreadingFactor)
        config.cr = UInt8(clamping: self.radio.codingRate)
        let name = "RNode[\(self.peripheral?.name ?? "BLE")]"
        let handle = rns_rnode_iface_create(name, { userData, data, length in
            guard let userData = userData, let data = data else {
                return 0
            }
            let host = Unmanaged<RNodeBluetoothHost>.fromOpaque(userData).takeUnretainedValue()
            let bytes = Data(bytes: data, count: Int(length))
            host.bleQueue.async {
                host.outgoing.append(bytes)
                host.drainOutgoing()
            }
            return 1
        }, Unmanaged.passUnretained(self).toOpaque(), &config)
        if handle == 0 {
            Logger.shared.log("Reticulum", "RNode interface not created: \(ReticulumRuntime.lastError())")
            return
        }
        self.handle = handle
        self.configuring = true
        self.blockingQueue.async { [weak self] in
            let result = rns_rnode_iface_configure(handle)
            let error = result == 0 ? nil : ReticulumRuntime.lastError()
            guard let self else {
                return
            }
            self.bleQueue.async {
                self.configuring = false
                if let error = error {
                    Logger.shared.log("Reticulum", "RNode handshake failed: \(error)")
                    self.deregisterInterface()
                    self.scheduleReconnect()
                } else {
                    Logger.shared.log("Reticulum", "RNode \(name) configured")
                }
            }
        }
    }

    private func deregisterInterface() {
        let handle = self.handle
        self.handle = 0
        self.outgoing.removeAll()
        if handle != 0 {
            rns_rnode_iface_deregister(handle)
        }
    }

    private func drainOutgoing() {
        guard let peripheral = self.peripheral, let characteristic = self.rxCharacteristic else {
            self.outgoing.removeAll()
            return
        }
        let chunkSize = max(20, peripheral.maximumWriteValueLength(for: .withoutResponse))
        while !self.outgoing.isEmpty, peripheral.canSendWriteWithoutResponse {
            var frame = self.outgoing[0]
            let chunk = frame.prefix(chunkSize)
            peripheral.writeValue(Data(chunk), for: characteristic, type: .withoutResponse)
            frame.removeFirst(chunk.count)
            if frame.isEmpty {
                self.outgoing.removeFirst()
            } else {
                self.outgoing[0] = frame
            }
        }
    }

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            self.connectIfPossible()
        } else {
            self.deregisterInterface()
            self.peripheral = nil
            self.rxCharacteristic = nil
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        if let peripheralId = self.peripheralId, peripheral.identifier != peripheralId {
            return
        }
        self.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([RNodeBluetoothHost.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Logger.shared.log("Reticulum", "RNode connect failed: \(String(describing: error))")
        self.peripheral = nil
        self.scheduleReconnect()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        self.deregisterInterface()
        self.peripheral = nil
        self.rxCharacteristic = nil
        if !self.stopped {
            self.scheduleReconnect()
        }
    }

    // MARK: - CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == RNodeBluetoothHost.serviceUUID }) else {
            Logger.shared.log("Reticulum", "RNode has no UART service: \(String(describing: error))")
            self.central?.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.discoverCharacteristics([RNodeBluetoothHost.rxUUID, RNodeBluetoothHost.txUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristics = service.characteristics, let rx = characteristics.first(where: { $0.uuid == RNodeBluetoothHost.rxUUID }), let tx = characteristics.first(where: { $0.uuid == RNodeBluetoothHost.txUUID }) else {
            Logger.shared.log("Reticulum", "RNode UART characteristics missing: \(String(describing: error))")
            self.central?.cancelPeripheralConnection(peripheral)
            return
        }
        self.rxCharacteristic = rx
        peripheral.setNotifyValue(true, for: tx)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if characteristic.isNotifying {
            self.registerInterface()
        } else if let error = error {
            Logger.shared.log("Reticulum", "RNode notifications refused: \(error)")
            self.central?.cancelPeripheralConnection(peripheral)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard self.handle != 0, let value = characteristic.value, !value.isEmpty else {
            return
        }
        let bytes = [UInt8](value)
        rns_rnode_iface_feed(self.handle, bytes, UInt32(bytes.count))
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        self.drainOutgoing()
    }
}

/// The LoRa parameters the host configures the RNode with (`ReticulumSettings.RNodeRadio`'s
/// values, without the preferences dependency in this file's signature).
struct TelegramCoreReticulumRadio {
    var frequency: Int64
    var bandwidth: Int32
    var txPower: Int32
    var spreadingFactor: Int32
    var codingRate: Int32
}

/// A nearby RNode seen while scanning, for the settings screen's picker.
public struct DiscoveredRNode: Equatable {
    public let id: String
    public let name: String
    public let rssi: Int
}

/// Scans for RNodes (the Nordic UART service) while subscribed; emits the list as it grows.
public final class RNodeScanner: NSObject, CBCentralManagerDelegate {
    private let queue = DispatchQueue(label: "org.telegram.reticulum.rnode-scan")
    private var central: CBCentralManager?
    private var found: [String: DiscoveredRNode] = [:]
    private let promise = ValuePromise<[DiscoveredRNode]>([], ignoreRepeated: true)

    public override init() {
        super.init()
    }

    public func scan() -> Signal<[DiscoveredRNode], NoError> {
        return Signal { [weak self] subscriber in
            guard let self else {
                subscriber.putCompletion()
                return EmptyDisposable
            }
            self.queue.async {
                self.found.removeAll()
                self.promise.set([])
                self.central = CBCentralManager(delegate: self, queue: self.queue, options: [CBCentralManagerOptionShowPowerAlertKey: true])
            }
            let disposable = self.promise.get().start(next: { value in
                subscriber.putNext(value)
            })
            return ActionDisposable { [weak self] in
                disposable.dispose()
                self?.queue.async {
                    self?.central?.stopScan()
                    self?.central = nil
                }
            }
        }
    }

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            central.scanForPeripherals(withServices: [RNodeBluetoothHost.serviceUUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? "RNode"
        self.found[peripheral.identifier.uuidString] = DiscoveredRNode(id: peripheral.identifier.uuidString, name: name, rssi: RSSI.intValue)
        self.promise.set(self.found.values.sorted(by: { $0.rssi > $1.rssi }))
    }
}
