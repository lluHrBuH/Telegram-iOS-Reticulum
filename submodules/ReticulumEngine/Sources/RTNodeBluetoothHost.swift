import Foundation
import CoreBluetooth
import SwiftSignalKit
import TelegramCore
import ReticulumFFI
#if canImport(UIKit)
import UIKit
#endif

/// RTNodes over Bluetooth LE, the Prns protocol (`Reticulum-rust/PRNS_BLE.md`). The app is only
/// the radio: it scans when Rust asks, reports every advertisement of the Prns service, connects
/// on the link Rust returns, discovers the service and subscribes to both characteristics,
/// performs the writes it is asked for and reports every event. Rust decides what to dial, does
/// the handshake, and makes each settled RTNode an interface named `PrnsBLE[<identity>]`.
///
/// Callbacks from Rust hop to `bleQueue`; the CoreBluetooth delegate runs there too, and the
/// `rns_prns_ble_*` reports it makes are not callbacks, so they may call into the library.
final class RTNodeBluetoothHost: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let serviceUUID = CBUUID(string: "37145B00-442D-4A94-917F-8F42C5DA28E3")
    static let controlUUID = CBUUID(string: "37145B00-442D-4A94-917F-8F42C5DA28E7")
    static let dataUUID = CBUUID(string: "37145B00-442D-4A94-917F-8F42C5DA28E8")

    private final class Link {
        let id: UInt64
        let peripheral: CBPeripheral
        var control: CBCharacteristic?
        var data: CBCharacteristic?
        var subscribed = 0
        var ready = false
        /// A write without response waiting for `peripheralIsReady`.
        var deferredWrite: (CBCharacteristic, Data)?

        init(id: UInt64, peripheral: CBPeripheral) {
            self.id = id
            self.peripheral = peripheral
        }
    }

    private let storageDirectory: String
    private let blockingQueue: Queue
    private let bleQueue = DispatchQueue(label: "org.telegram.reticulum.rtnode")
    private var central: CBCentralManager?
    private var links: [UInt64: Link] = [:]
    private var linksByPeripheral: [UUID: UInt64] = [:]
    private var wantsScan = false
    private var started = false
    private var stopped = false

    init(storageDirectory: String, blockingQueue: Queue) {
        self.storageDirectory = storageDirectory
        self.blockingQueue = blockingQueue
        super.init()
    }

    func start() {
        self.bleQueue.async {
            if self.central == nil {
                self.central = CBCentralManager(delegate: self, queue: self.bleQueue, options: [CBCentralManagerOptionShowPowerAlertKey: false])
            }
            self.startEngineIfReady()
        }
    }

    /// Blocks briefly while the links close; the runtime calls it off the main thread before the
    /// stack shuts down.
    func stop() {
        var shouldStopEngine = false
        self.bleQueue.sync {
            self.stopped = true
            shouldStopEngine = self.started
            self.started = false
            self.central?.stopScan()
            for (_, link) in self.links {
                self.central?.cancelPeripheralConnection(link.peripheral)
            }
            self.links.removeAll()
            self.linksByPeripheral.removeAll()
        }
        if shouldStopEngine {
            rns_prns_ble_stop()
        }
    }

    private static var endpointHost: UInt8 {
        #if canImport(UIKit)
        return UIDevice.current.userInterfaceIdiom == .pad ? 2 : 1
        #else
        return 0
        #endif
    }

    private func startEngineIfReady() {
        guard !self.started, !self.stopped, let central = self.central, central.state == .poweredOn else {
            return
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        let result = rns_prns_ble_start(self.storageDirectory, 1, RTNodeBluetoothHost.endpointHost, { userData, on in
            guard let userData = userData else {
                return
            }
            let host = Unmanaged<RTNodeBluetoothHost>.fromOpaque(userData).takeUnretainedValue()
            host.bleQueue.async {
                host.setScanning(on != 0)
            }
        }, { userData, link, characteristic, data, length in
            guard let userData = userData else {
                return
            }
            let host = Unmanaged<RTNodeBluetoothHost>.fromOpaque(userData).takeUnretainedValue()
            let bytes = data.map { Data(bytes: $0, count: Int(length)) } ?? Data()
            host.bleQueue.async {
                host.write(link: link, characteristic: characteristic, data: bytes)
            }
        }, { userData, link in
            guard let userData = userData else {
                return
            }
            let host = Unmanaged<RTNodeBluetoothHost>.fromOpaque(userData).takeUnretainedValue()
            host.bleQueue.async {
                host.disconnect(link: link)
            }
        }, { userData, link, state, _, interfaceName in
            guard let userData = userData else {
                return
            }
            let host = Unmanaged<RTNodeBluetoothHost>.fromOpaque(userData).takeUnretainedValue()
            let name = interfaceName.map { String(cString: $0) }
            host.bleQueue.async {
                host.linkStateChanged(link: link, state: state, interfaceName: name)
            }
        }, context, nil)
        if result != 0 {
            Logger.shared.log("Reticulum", "RTNode engine not started: \(ReticulumRuntime.lastError())")
            return
        }
        self.started = true
    }

    // MARK: - Requests from Rust (bleQueue)

    private func setScanning(_ on: Bool) {
        self.wantsScan = on
        guard let central = self.central, central.state == .poweredOn else {
            return
        }
        if on {
            central.scanForPeripherals(withServices: [RTNodeBluetoothHost.serviceUUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        } else {
            central.stopScan()
        }
    }

    private func write(link id: UInt64, characteristic index: UInt8, data: Data) {
        guard let link = self.links[id], link.ready, let characteristic = index == 0 ? link.control : link.data else {
            rns_prns_ble_link_write_done(id, 0)
            return
        }
        if index == 1 && characteristic.properties.contains(.writeWithoutResponse) {
            // A data fragment goes without response when the node allows it; it is done once the
            // OS has taken it.
            if link.peripheral.canSendWriteWithoutResponse {
                link.peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
                rns_prns_ble_link_write_done(id, 1)
            } else {
                link.deferredWrite = (characteristic, data)
            }
        } else {
            link.peripheral.writeValue(data, for: characteristic, type: .withResponse)
        }
    }

    private func disconnect(link id: UInt64) {
        guard let link = self.links.removeValue(forKey: id) else {
            return
        }
        self.linksByPeripheral.removeValue(forKey: link.peripheral.identifier)
        self.central?.cancelPeripheralConnection(link.peripheral)
    }

    private func linkStateChanged(link: UInt64, state: Int32, interfaceName: String?) {
        let description: String
        switch state {
        case 0:
            description = "handshaking"
        case 1:
            description = "settled"
        case 2:
            description = "closed"
        case 3:
            description = "dialling"
        default:
            description = "state \(state)"
        }
        Logger.shared.log("Reticulum", "RTNode link \(link) \(description)\(interfaceName.map { " (\($0))" } ?? "")")
    }

    private func closeLink(_ link: Link) {
        self.links.removeValue(forKey: link.id)
        self.linksByPeripheral.removeValue(forKey: link.peripheral.identifier)
        rns_prns_ble_link_closed(link.id)
    }

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            self.startEngineIfReady()
            if self.wantsScan {
                self.setScanning(true)
            }
        } else {
            for (_, link) in self.links {
                self.closeLink(link)
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard self.started, self.linksByPeripheral[peripheral.identifier] == nil else {
            return
        }
        let manufacturerData = (advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data) ?? Data()
        let bytes = [UInt8](manufacturerData)
        let id = rns_prns_ble_sighted(peripheral.identifier.uuidString, bytes, UInt32(bytes.count))
        if id == 0 {
            return
        }
        let link = Link(id: id, peripheral: peripheral)
        self.links[id] = link
        self.linksByPeripheral[peripheral.identifier] = id
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([RTNodeBluetoothHost.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard let id = self.linksByPeripheral[peripheral.identifier], let link = self.links[id] else {
            return
        }
        self.closeLink(link)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard let id = self.linksByPeripheral[peripheral.identifier], let link = self.links[id] else {
            return
        }
        self.closeLink(link)
    }

    // MARK: - CBPeripheralDelegate

    private func link(for peripheral: CBPeripheral) -> Link? {
        guard let id = self.linksByPeripheral[peripheral.identifier] else {
            return nil
        }
        return self.links[id]
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let link = self.link(for: peripheral) else {
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == RTNodeBluetoothHost.serviceUUID }) else {
            self.central?.cancelPeripheralConnection(peripheral)
            self.closeLink(link)
            return
        }
        peripheral.discoverCharacteristics([RTNodeBluetoothHost.controlUUID, RTNodeBluetoothHost.dataUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let link = self.link(for: peripheral) else {
            return
        }
        guard let characteristics = service.characteristics, let control = characteristics.first(where: { $0.uuid == RTNodeBluetoothHost.controlUUID }), let data = characteristics.first(where: { $0.uuid == RTNodeBluetoothHost.dataUUID }) else {
            self.central?.cancelPeripheralConnection(peripheral)
            self.closeLink(link)
            return
        }
        link.control = control
        link.data = data
        peripheral.setNotifyValue(true, for: control)
        peripheral.setNotifyValue(true, for: data)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard let link = self.link(for: peripheral) else {
            return
        }
        if !characteristic.isNotifying {
            if error != nil {
                self.central?.cancelPeripheralConnection(peripheral)
                self.closeLink(link)
            }
            return
        }
        link.subscribed += 1
        if link.subscribed == 2 && !link.ready {
            link.ready = true
            rns_prns_ble_link_ready(link.id, UInt32(peripheral.maximumWriteValueLength(for: .withoutResponse)))
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let link = self.link(for: peripheral), let value = characteristic.value else {
            return
        }
        let index: UInt8
        if characteristic.uuid == RTNodeBluetoothHost.controlUUID {
            index = 0
        } else if characteristic.uuid == RTNodeBluetoothHost.dataUUID {
            index = 1
        } else {
            return
        }
        let bytes = [UInt8](value)
        rns_prns_ble_link_received(link.id, index, bytes, UInt32(bytes.count))
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let link = self.link(for: peripheral) else {
            return
        }
        rns_prns_ble_link_write_done(link.id, error == nil ? 1 : 0)
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard let link = self.link(for: peripheral), let (characteristic, data) = link.deferredWrite else {
            return
        }
        link.deferredWrite = nil
        peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
        rns_prns_ble_link_write_done(link.id, 1)
    }
}
