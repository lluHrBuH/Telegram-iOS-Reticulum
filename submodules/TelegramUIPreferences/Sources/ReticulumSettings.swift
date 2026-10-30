import Foundation
import Postbox
import TelegramCore
import SwiftSignalKit

/// How this device reaches the Reticulum mesh (Settings ▸ Reticulum Network), shared by every
/// account: the TCP nodes the stack dials, the RNode radio it talks to over Bluetooth, whether it
/// links to nearby RTNodes, the propagation node it syncs with, and what the local server does on
/// its own behalf. Applied by restarting the stack, which reads a config file written from this.
public struct ReticulumSettings: Codable, Equatable {
    public struct TCPNode: Codable, Equatable, Identifiable {
        public var id: Int64
        public var name: String
        public var host: String
        public var port: Int32
        public var enabled: Bool

        public init(id: Int64, name: String, host: String, port: Int32, enabled: Bool) {
            self.id = id
            self.name = name
            self.host = host
            self.port = port
            self.enabled = enabled
        }
    }

    /// An RNode's LoRa parameters (the RNode interface's radio config).
    public struct RNodeRadio: Codable, Equatable {
        public var frequency: Int64
        public var bandwidth: Int32
        public var txPower: Int32
        public var spreadingFactor: Int32
        public var codingRate: Int32

        public init(frequency: Int64, bandwidth: Int32, txPower: Int32, spreadingFactor: Int32, codingRate: Int32) {
            self.frequency = frequency
            self.bandwidth = bandwidth
            self.txPower = txPower
            self.spreadingFactor = spreadingFactor
            self.codingRate = codingRate
        }

        /// 868 MHz, 125 kHz, SF 8, CR 4/5, 7 dBm: the Reticulum manual's example.
        public static var defaultRadio: RNodeRadio {
            return RNodeRadio(frequency: 868_000_000, bandwidth: 125_000, txPower: 7, spreadingFactor: 8, codingRate: 5)
        }
    }

    public struct RNode: Codable, Equatable {
        public var enabled: Bool
        /// The CoreBluetooth peripheral identifier of the paired RNode, nil until one is chosen.
        public var peripheralId: String?
        public var peripheralName: String?
        public var radio: RNodeRadio

        public init(enabled: Bool, peripheralId: String?, peripheralName: String?, radio: RNodeRadio) {
            self.enabled = enabled
            self.peripheralId = peripheralId
            self.peripheralName = peripheralName
            self.radio = radio
        }
    }

    public var tcpNodes: [TCPNode]
    public var rnode: RNode
    /// Link to any RTNode in range over Bluetooth LE (the Prns protocol).
    public var rtnodeEnabled: Bool
    /// The LXMF propagation node (hex address) messages are fetched from, nil for none.
    public var propagationNode: String?
    public var sendsTypingIndicators: Bool
    public var logLevel: Int32

    public init(tcpNodes: [TCPNode], rnode: RNode, rtnodeEnabled: Bool, propagationNode: String?, sendsTypingIndicators: Bool, logLevel: Int32) {
        self.tcpNodes = tcpNodes
        self.rnode = rnode
        self.rtnodeEnabled = rtnodeEnabled
        self.propagationNode = propagationNode
        self.sendsTypingIndicators = sendsTypingIndicators
        self.logLevel = logLevel
    }

    /// One public TCP node (rmap.world:4242), no radio, no RTNode, no typing indicators.
    public static var defaultSettings: ReticulumSettings {
        return ReticulumSettings(tcpNodes: [TCPNode(id: 1, name: "rmap.world", host: "rmap.world", port: 4242, enabled: true)], rnode: RNode(enabled: false, peripheralId: nil, peripheralName: nil, radio: .defaultRadio), rtnodeEnabled: false, propagationNode: nil, sendsTypingIndicators: false, logLevel: 4)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StringCodingKey.self)
        let defaults = ReticulumSettings.defaultSettings
        self.tcpNodes = (try? container.decodeIfPresent([TCPNode].self, forKey: "tcpNodes")) ?? defaults.tcpNodes
        self.rnode = (try? container.decodeIfPresent(RNode.self, forKey: "rnode")) ?? defaults.rnode
        self.rtnodeEnabled = (try? container.decodeIfPresent(Bool.self, forKey: "rtnodeEnabled")) ?? defaults.rtnodeEnabled
        self.propagationNode = try? container.decodeIfPresent(String.self, forKey: "propagationNode")
        self.sendsTypingIndicators = (try? container.decodeIfPresent(Bool.self, forKey: "sendsTypingIndicators")) ?? defaults.sendsTypingIndicators
        self.logLevel = (try? container.decodeIfPresent(Int32.self, forKey: "logLevel")) ?? defaults.logLevel
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: StringCodingKey.self)
        try container.encode(self.tcpNodes, forKey: "tcpNodes")
        try container.encode(self.rnode, forKey: "rnode")
        try container.encode(self.rtnodeEnabled, forKey: "rtnodeEnabled")
        try container.encodeIfPresent(self.propagationNode, forKey: "propagationNode")
        try container.encode(self.sendsTypingIndicators, forKey: "sendsTypingIndicators")
        try container.encode(self.logLevel, forKey: "logLevel")
    }
}

public func updateReticulumSettingsInteractively(accountManager: AccountManager<TelegramAccountManagerTypes>, _ f: @escaping (ReticulumSettings) -> ReticulumSettings) -> Signal<Void, NoError> {
    return accountManager.transaction { transaction -> Void in
        transaction.updateSharedData(ApplicationSpecificSharedDataKeys.reticulumSettings, { entry in
            let current = entry?.get(ReticulumSettings.self) ?? ReticulumSettings.defaultSettings
            return SharedPreferencesEntry(f(current))
        })
    }
}

public func reticulumSettings(accountManager: AccountManager<TelegramAccountManagerTypes>) -> Signal<ReticulumSettings, NoError> {
    return accountManager.sharedData(keys: [ApplicationSpecificSharedDataKeys.reticulumSettings])
    |> map { sharedData -> ReticulumSettings in
        return sharedData.entries[ApplicationSpecificSharedDataKeys.reticulumSettings]?.get(ReticulumSettings.self) ?? ReticulumSettings.defaultSettings
    }
    |> distinctUntilChanged
}
