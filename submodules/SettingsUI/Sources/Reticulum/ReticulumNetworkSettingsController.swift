import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import TelegramUIPreferences
import ItemListUI
import PresentationDataUtils
import AccountContext
import ShareController
import UndoUI
import ReticulumEngine

/// Settings ▸ Reticulum Network: the address, the interfaces and their state, the TCP nodes, the
/// RNode radio, RTNode linking, the propagation node, and the identity's backup. Takes the place
/// of the Proxy screen on a Reticulum build (`proxySettingsController` routes here).

private final class ReticulumNetworkArguments {
    let sharedContext: SharedAccountContext
    let context: AccountContext?
    let updateSettings: ((ReticulumSettings) -> ReticulumSettings) -> Void
    let copyAddress: () -> Void
    let shareAddress: () -> Void
    let announce: () -> Void
    let reconnect: () -> Void
    let editNode: (ReticulumSettings.TCPNode?) -> Void
    let pickRNode: () -> Void
    let updateRadio: (ReticulumRadioField, String) -> Void
    let exportIdentity: () -> Void

    init(sharedContext: SharedAccountContext, context: AccountContext?, updateSettings: @escaping ((ReticulumSettings) -> ReticulumSettings) -> Void, copyAddress: @escaping () -> Void, shareAddress: @escaping () -> Void, announce: @escaping () -> Void, reconnect: @escaping () -> Void, editNode: @escaping (ReticulumSettings.TCPNode?) -> Void, pickRNode: @escaping () -> Void, updateRadio: @escaping (ReticulumRadioField, String) -> Void, exportIdentity: @escaping () -> Void) {
        self.sharedContext = sharedContext
        self.context = context
        self.updateSettings = updateSettings
        self.copyAddress = copyAddress
        self.shareAddress = shareAddress
        self.announce = announce
        self.reconnect = reconnect
        self.editNode = editNode
        self.pickRNode = pickRNode
        self.updateRadio = updateRadio
        self.exportIdentity = exportIdentity
    }
}

enum ReticulumRadioField: Int32 {
    case frequency
    case bandwidth
    case spreadingFactor
    case codingRate
    case txPower

    var title: String {
        switch self {
        case .frequency:
            return "Frequency (Hz)"
        case .bandwidth:
            return "Bandwidth (Hz)"
        case .spreadingFactor:
            return "Spreading Factor"
        case .codingRate:
            return "Coding Rate"
        case .txPower:
            return "TX Power (dBm)"
        }
    }

    func value(in radio: ReticulumSettings.RNodeRadio) -> String {
        switch self {
        case .frequency:
            return "\(radio.frequency)"
        case .bandwidth:
            return "\(radio.bandwidth)"
        case .spreadingFactor:
            return "\(radio.spreadingFactor)"
        case .codingRate:
            return "\(radio.codingRate)"
        case .txPower:
            return "\(radio.txPower)"
        }
    }
}

private enum ReticulumNetworkSection: Int32 {
    case address
    case status
    case nodes
    case rnode
    case rtnode
    case propagation
    case options
    case identity
}

private enum ReticulumNetworkEntry: ItemListNodeEntry {
    case addressHeader(String)
    case address(String)
    case copyAddress(String)
    case shareAddress(String)
    case announce(String)
    case addressInfo(String)

    case statusHeader(String)
    case interface(Int32, String, String)
    case noInterfaces(String)
    case reconnect(String)

    case nodesHeader(String)
    case node(Int32, ReticulumSettings.TCPNode)
    case addNode(String)
    case nodesInfo(String)

    case rnodeEnabled(String, Bool)
    case rnodeDevice(String, String)
    case rnodeRadio(ReticulumRadioField, String)
    case rnodeInfo(String)

    case rtnodeEnabled(String, Bool)
    case rtnodeInfo(String)

    case propagationHeader(String)
    case propagationNode(String, String)
    case propagationInfo(String)

    case typingIndicators(String, Bool)
    case typingInfo(String)

    case exportIdentity(String)
    case identityInfo(String)

    var section: ItemListSectionId {
        switch self {
        case .addressHeader, .address, .copyAddress, .shareAddress, .announce, .addressInfo:
            return ReticulumNetworkSection.address.rawValue
        case .statusHeader, .interface, .noInterfaces, .reconnect:
            return ReticulumNetworkSection.status.rawValue
        case .nodesHeader, .node, .addNode, .nodesInfo:
            return ReticulumNetworkSection.nodes.rawValue
        case .rnodeEnabled, .rnodeDevice, .rnodeRadio, .rnodeInfo:
            return ReticulumNetworkSection.rnode.rawValue
        case .rtnodeEnabled, .rtnodeInfo:
            return ReticulumNetworkSection.rtnode.rawValue
        case .propagationHeader, .propagationNode, .propagationInfo:
            return ReticulumNetworkSection.propagation.rawValue
        case .typingIndicators, .typingInfo:
            return ReticulumNetworkSection.options.rawValue
        case .exportIdentity, .identityInfo:
            return ReticulumNetworkSection.identity.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case .addressHeader:
            return 0
        case .address:
            return 1
        case .copyAddress:
            return 2
        case .shareAddress:
            return 3
        case .announce:
            return 4
        case .addressInfo:
            return 5
        case .statusHeader:
            return 10
        case let .interface(index, _, _):
            return 11 + index
        case .noInterfaces:
            return 100
        case .reconnect:
            return 101
        case .nodesHeader:
            return 110
        case let .node(index, _):
            return 111 + index
        case .addNode:
            return 300
        case .nodesInfo:
            return 301
        case .rnodeEnabled:
            return 310
        case .rnodeDevice:
            return 311
        case let .rnodeRadio(field, _):
            return 312 + field.rawValue
        case .rnodeInfo:
            return 330
        case .rtnodeEnabled:
            return 340
        case .rtnodeInfo:
            return 341
        case .propagationHeader:
            return 350
        case .propagationNode:
            return 351
        case .propagationInfo:
            return 352
        case .typingIndicators:
            return 360
        case .typingInfo:
            return 361
        case .exportIdentity:
            return 370
        case .identityInfo:
            return 371
        }
    }

    static func < (lhs: ReticulumNetworkEntry, rhs: ReticulumNetworkEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! ReticulumNetworkArguments
        switch self {
        case let .addressHeader(text), let .statusHeader(text), let .nodesHeader(text), let .propagationHeader(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .addressInfo(text), let .nodesInfo(text), let .rnodeInfo(text), let .rtnodeInfo(text), let .propagationInfo(text), let .typingInfo(text), let .identityInfo(text), let .noInterfaces(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .address(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .copyAddress(title):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: title, kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.copyAddress()
            })
        case let .shareAddress(title):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: title, kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.shareAddress()
            })
        case let .announce(title):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: title, kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.announce()
            })
        case let .interface(_, name, state):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: name, label: state, sectionId: self.section, style: .blocks, disclosureStyle: .none, action: nil)
        case let .reconnect(title):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: title, kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.reconnect()
            })
        case let .node(_, node):
            let label = node.enabled ? "\(node.host):\(node.port)" : "Off"
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: node.name.isEmpty ? node.host : node.name, label: label, sectionId: self.section, style: .blocks, action: {
                arguments.editNode(node)
            })
        case let .addNode(title):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: title, kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.editNode(nil)
            })
        case let .rnodeEnabled(title, value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: title, value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.updateSettings { settings in
                    var settings = settings
                    settings.rnode.enabled = value
                    return settings
                }
            })
        case let .rnodeDevice(title, label):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: title, label: label, sectionId: self.section, style: .blocks, action: {
                arguments.pickRNode()
            })
        case let .rnodeRadio(field, value):
            return ItemListSingleLineInputItem(presentationData: presentationData, systemStyle: .glass, title: NSAttributedString(string: field.title, textColor: presentationData.theme.list.itemPrimaryTextColor), text: value, placeholder: "", type: .number, sectionId: self.section, textUpdated: { text in
                arguments.updateRadio(field, text)
            }, action: {})
        case let .rtnodeEnabled(title, value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: title, value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.updateSettings { settings in
                    var settings = settings
                    settings.rtnodeEnabled = value
                    return settings
                }
            })
        case let .propagationNode(placeholder, value):
            return ItemListSingleLineInputItem(presentationData: presentationData, systemStyle: .glass, title: NSAttributedString(), text: value, placeholder: placeholder, type: .regular(capitalization: false, autocorrection: false), sectionId: self.section, textUpdated: { text in
                arguments.updateSettings { settings in
                    var settings = settings
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    settings.propagationNode = trimmed.isEmpty ? nil : trimmed
                    return settings
                }
            }, action: {})
        case let .typingIndicators(title, value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: title, value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.updateSettings { settings in
                    var settings = settings
                    settings.sendsTypingIndicators = value
                    return settings
                }
            })
        case let .exportIdentity(title):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: title, kind: .destructive, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.exportIdentity()
            })
        }
    }
}

private func reticulumNetworkEntries(settings: ReticulumSettings, address: ReticulumAddress?, interfaces: [ReticulumInterfaceStatus], canShare: Bool, canExport: Bool) -> [ReticulumNetworkEntry] {
    var entries: [ReticulumNetworkEntry] = []

    entries.append(.addressHeader("MY ADDRESS"))
    entries.append(.address(address?.hex ?? "The mesh is not running yet."))
    if address != nil {
        entries.append(.copyAddress("Copy Address"))
        if canShare {
            entries.append(.shareAddress("Share Address"))
        }
        entries.append(.announce("Announce Now"))
    }
    entries.append(.addressInfo("Others reach you at this address from any LXMF client. Announcing tells the mesh where you are; the app announces on every start."))

    entries.append(.statusHeader("INTERFACES"))
    if interfaces.isEmpty {
        entries.append(.noInterfaces("No interface is configured or the mesh is starting."))
    } else {
        for (index, interface) in interfaces.enumerated() {
            var state = interface.online ? "Online" : "Offline"
            if interface.online, let bitrate = interface.bitrate, bitrate > 0 {
                state += " · \(Int(bitrate / 1000)) kbps"
            }
            if let rssi = interface.rssi {
                state += " · \(Int(rssi)) dBm"
            }
            entries.append(.interface(Int32(index), interface.name, state))
        }
    }
    entries.append(.reconnect("Reconnect"))

    entries.append(.nodesHeader("TCP NODES"))
    for (index, node) in settings.tcpNodes.enumerated() {
        entries.append(.node(Int32(index), node))
    }
    entries.append(.addNode("Add Node"))
    entries.append(.nodesInfo("Public Reticulum nodes reached over the internet. Changing the list restarts the mesh."))

    entries.append(.rnodeEnabled("RNode over Bluetooth", settings.rnode.enabled))
    if settings.rnode.enabled {
        entries.append(.rnodeDevice("Device", settings.rnode.peripheralName ?? "Choose…"))
        for field in [ReticulumRadioField.frequency, .bandwidth, .spreadingFactor, .codingRate, .txPower] {
            entries.append(.rnodeRadio(field, field.value(in: settings.rnode.radio)))
        }
    }
    entries.append(.rnodeInfo("A LoRa RNode paired over Bluetooth LE carries messages with no internet at all. Every radio on a channel must use the same parameters."))

    entries.append(.rtnodeEnabled("Link to RTNodes nearby", settings.rtnodeEnabled))
    entries.append(.rtnodeInfo("Connects over Bluetooth LE to any RTNode in range and routes through it."))

    entries.append(.propagationHeader("PROPAGATION NODE"))
    entries.append(.propagationNode("Node address (optional)", settings.propagationNode ?? ""))
    entries.append(.propagationInfo("A propagation node stores messages for you while you are offline. Leave empty to receive directly only."))

    entries.append(.typingIndicators("Send Typing Indicators", settings.sendsTypingIndicators))
    entries.append(.typingInfo("Typing indicators are extra packets on the mesh; keep them off on slow radio links."))

    if canExport {
        entries.append(.exportIdentity("Export Identity Key"))
        entries.append(.identityInfo("Copies the identity's private key as hex. Anyone with it can read your messages and send as you: keep it as a backup only."))
    }

    return entries
}

public func reticulumNetworkSettingsController(sharedContext: SharedAccountContext, context: AccountContext?, accountBasePath: String?, modal: Bool, presentationData: PresentationData, updatedPresentationData: Signal<PresentationData, NoError>) -> ViewController {
    var pushControllerImpl: ((ViewController) -> Void)?
    var presentControllerImpl: ((ViewController) -> Void)?
    var dismissImpl: (() -> Void)?
    let accountManager = sharedContext.accountManager
    let runtime = ReticulumRuntime.shared

    let transport = runtime.currentTransport
    let address: Signal<ReticulumAddress?, NoError> = transport
    |> map { $0?.ownAddress }
    |> distinctUntilChanged
    let interfaces: Signal<[ReticulumInterfaceStatus], NoError> = transport
    |> mapToSignal { transport -> Signal<[ReticulumInterfaceStatus], NoError> in
        guard let transport = transport else {
            return .single([])
        }
        return transport.interfaces
    }
    |> distinctUntilChanged

    let settingsSignal = reticulumSettings(accountManager: accountManager)
    let updateSettings: ((ReticulumSettings) -> ReticulumSettings) -> Void = { f in
        let _ = updateReticulumSettingsInteractively(accountManager: accountManager, f).start()
    }

    let arguments = ReticulumNetworkArguments(sharedContext: sharedContext, context: context, updateSettings: updateSettings, copyAddress: {
        let _ = (address
        |> take(1)
        |> deliverOnMainQueue).start(next: { address in
            guard let address = address else {
                return
            }
            UIPasteboard.general.string = address.hex
            let presentationData = sharedContext.currentPresentationData.with { $0 }
            presentControllerImpl?(UndoOverlayController(presentationData: presentationData, content: .copy(text: "Address copied."), elevatedLayout: false, animateInAsReplacement: false, action: { _ in return false }))
        })
    }, shareAddress: {
        guard let context = context else {
            return
        }
        let _ = (address
        |> take(1)
        |> deliverOnMainQueue).start(next: { address in
            guard let address = address else {
                return
            }
            presentControllerImpl?(ShareController(context: context, subject: .text(address.hex)))
        })
    }, announce: {
        let _ = (transport
        |> take(1)
        |> deliverOnMainQueue).start(next: { transport in
            transport?.announce()
            let presentationData = sharedContext.currentPresentationData.with { $0 }
            presentControllerImpl?(UndoOverlayController(presentationData: presentationData, content: .succeed(text: "Announced.", timeout: nil, customUndoText: nil), elevatedLayout: false, animateInAsReplacement: false, action: { _ in return false }))
        })
    }, reconnect: {
        runtime.restart()
    }, editNode: { node in
        pushControllerImpl?(reticulumNodeEditController(sharedContext: sharedContext, node: node, updatedPresentationData: updatedPresentationData))
    }, pickRNode: {
        pushControllerImpl?(reticulumRNodePickerController(sharedContext: sharedContext, updatedPresentationData: updatedPresentationData))
    }, updateRadio: { field, text in
        guard let value = Int64(text.trimmingCharacters(in: .whitespaces)) else {
            return
        }
        updateSettings { settings in
            var settings = settings
            switch field {
            case .frequency:
                settings.rnode.radio.frequency = value
            case .bandwidth:
                settings.rnode.radio.bandwidth = Int32(clamping: value)
            case .spreadingFactor:
                settings.rnode.radio.spreadingFactor = Int32(clamping: value)
            case .codingRate:
                settings.rnode.radio.codingRate = Int32(clamping: value)
            case .txPower:
                settings.rnode.radio.txPower = Int32(clamping: value)
            }
            return settings
        }
    }, exportIdentity: {
        guard let accountBasePath = accountBasePath else {
            return
        }
        let presentationData = sharedContext.currentPresentationData.with { $0 }
        presentControllerImpl?(textAlertController(sharedContext: sharedContext, title: "Export Identity Key", text: "The key will be copied to the clipboard. Anyone who gets it can read your messages and send as you.", actions: [TextAlertAction(type: .genericAction, title: presentationData.strings.Common_Cancel, action: {}), TextAlertAction(type: .destructiveAction, title: "Copy", action: {
            guard let key = runtime.exportIdentity(accountBasePath: accountBasePath) else {
                presentControllerImpl?(textAlertController(sharedContext: sharedContext, title: nil, text: "No identity is stored for this account.", actions: [TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})]))
                return
            }
            UIPasteboard.general.string = ReticulumHex.string(key)
            presentControllerImpl?(UndoOverlayController(presentationData: presentationData, content: .copy(text: "Identity key copied."), elevatedLayout: false, animateInAsReplacement: false, action: { _ in return false }))
        })]))
    })

    let signal = combineLatest(updatedPresentationData, settingsSignal, address, interfaces)
    |> map { presentationData, settings, address, interfaces -> (ItemListControllerState, (ItemListNodeState, Any)) in
        var leftNavigationButton: ItemListNavigationButton?
        if modal {
            leftNavigationButton = ItemListNavigationButton(content: .icon(.close), style: .regular, enabled: true, action: {
                dismissImpl?()
            })
        }
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text("Reticulum Network"), leftNavigationButton: leftNavigationButton, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let entries = reticulumNetworkEntries(settings: settings, address: address, interfaces: interfaces, canShare: context != nil, canExport: accountBasePath != nil)
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: false)
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(sharedContext: sharedContext, state: signal)
    if modal {
        controller.navigationPresentation = .modal
    }
    pushControllerImpl = { [weak controller] c in
        (controller?.navigationController as? NavigationController)?.pushViewController(c)
    }
    presentControllerImpl = { [weak controller] c in
        controller?.present(c, in: .window(.root))
    }
    dismissImpl = { [weak controller] in
        controller?.dismiss()
    }
    return controller
}

// MARK: - Node editor

private final class ReticulumNodeEditArguments {
    let updateState: ((ReticulumNodeEditState) -> ReticulumNodeEditState) -> Void
    let delete: () -> Void

    init(updateState: @escaping ((ReticulumNodeEditState) -> ReticulumNodeEditState) -> Void, delete: @escaping () -> Void) {
        self.updateState = updateState
        self.delete = delete
    }
}

private struct ReticulumNodeEditState: Equatable {
    var name: String
    var host: String
    var port: String
    var enabled: Bool

    var isValid: Bool {
        guard let port = Int32(self.port), port > 0, port < 65536 else {
            return false
        }
        return !self.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private enum ReticulumNodeEditEntry: ItemListNodeEntry {
    case name(String)
    case host(String)
    case port(String)
    case enabled(Bool)
    case info(String)
    case delete(String)

    var section: ItemListSectionId {
        switch self {
        case .name, .host, .port, .enabled, .info:
            return 0
        case .delete:
            return 1
        }
    }

    var stableId: Int32 {
        switch self {
        case .name:
            return 0
        case .host:
            return 1
        case .port:
            return 2
        case .enabled:
            return 3
        case .info:
            return 4
        case .delete:
            return 5
        }
    }

    static func < (lhs: ReticulumNodeEditEntry, rhs: ReticulumNodeEditEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! ReticulumNodeEditArguments
        switch self {
        case let .name(value):
            return ItemListSingleLineInputItem(presentationData: presentationData, systemStyle: .glass, title: NSAttributedString(string: "Name", textColor: presentationData.theme.list.itemPrimaryTextColor), text: value, placeholder: "Optional", type: .regular(capitalization: true, autocorrection: false), sectionId: self.section, textUpdated: { text in
                arguments.updateState { state in
                    var state = state
                    state.name = text
                    return state
                }
            }, action: {})
        case let .host(value):
            return ItemListSingleLineInputItem(presentationData: presentationData, systemStyle: .glass, title: NSAttributedString(string: "Host", textColor: presentationData.theme.list.itemPrimaryTextColor), text: value, placeholder: "rmap.world", type: .regular(capitalization: false, autocorrection: false), sectionId: self.section, textUpdated: { text in
                arguments.updateState { state in
                    var state = state
                    state.host = text
                    return state
                }
            }, action: {})
        case let .port(value):
            return ItemListSingleLineInputItem(presentationData: presentationData, systemStyle: .glass, title: NSAttributedString(string: "Port", textColor: presentationData.theme.list.itemPrimaryTextColor), text: value, placeholder: "4242", type: .number, sectionId: self.section, textUpdated: { text in
                arguments.updateState { state in
                    var state = state
                    state.port = text
                    return state
                }
            }, action: {})
        case let .enabled(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Enabled", value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.updateState { state in
                    var state = state
                    state.enabled = value
                    return state
                }
            })
        case let .info(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .delete(title):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: title, kind: .destructive, alignment: .center, sectionId: self.section, style: .blocks, action: {
                arguments.delete()
            })
        }
    }
}

func reticulumNodeEditController(sharedContext: SharedAccountContext, node: ReticulumSettings.TCPNode?, updatedPresentationData: Signal<PresentationData, NoError>) -> ViewController {
    let initialState = ReticulumNodeEditState(name: node?.name ?? "", host: node?.host ?? "", port: node.map { "\($0.port)" } ?? "4242", enabled: node?.enabled ?? true)
    let stateValue = Atomic(value: initialState)
    let statePromise = ValuePromise(initialState, ignoreRepeated: true)
    let updateState: ((ReticulumNodeEditState) -> ReticulumNodeEditState) -> Void = { f in
        statePromise.set(stateValue.modify { f($0) })
    }
    var dismissImpl: (() -> Void)?
    let accountManager = sharedContext.accountManager

    let arguments = ReticulumNodeEditArguments(updateState: updateState, delete: {
        guard let node = node else {
            return
        }
        let _ = updateReticulumSettingsInteractively(accountManager: accountManager, { settings in
            var settings = settings
            settings.tcpNodes.removeAll(where: { $0.id == node.id })
            return settings
        }).start()
        dismissImpl?()
    })

    let signal = combineLatest(updatedPresentationData, statePromise.get())
    |> map { presentationData, state -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let rightNavigationButton = ItemListNavigationButton(content: .text(presentationData.strings.Common_Done), style: .bold, enabled: state.isValid, action: {
            let state = stateValue.with { $0 }
            guard let port = Int32(state.port) else {
                return
            }
            let _ = updateReticulumSettingsInteractively(accountManager: accountManager, { settings in
                var settings = settings
                let id = node?.id ?? (settings.tcpNodes.map { $0.id }.max() ?? 0) + 1
                let updated = ReticulumSettings.TCPNode(id: id, name: state.name.trimmingCharacters(in: .whitespacesAndNewlines), host: state.host.trimmingCharacters(in: .whitespacesAndNewlines), port: port, enabled: state.enabled)
                if let index = settings.tcpNodes.firstIndex(where: { $0.id == id }) {
                    settings.tcpNodes[index] = updated
                } else {
                    settings.tcpNodes.append(updated)
                }
                return settings
            }).start()
            dismissImpl?()
        })
        var entries: [ReticulumNodeEditEntry] = [.name(state.name), .host(state.host), .port(state.port), .enabled(state.enabled), .info("A TCPClientInterface to a Reticulum node that accepts connections, such as the public rmap.world:4242.")]
        if node != nil {
            entries.append(.delete("Remove Node"))
        }
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(node == nil ? "New Node" : "Node"), leftNavigationButton: nil, rightNavigationButton: rightNavigationButton, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, focusItemTag: nil, emptyStateItem: nil, animateChanges: false)
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(sharedContext: sharedContext, state: signal)
    dismissImpl = { [weak controller] in
        controller?.dismiss()
    }
    return controller
}

// MARK: - RNode picker

private enum ReticulumRNodePickerEntry: ItemListNodeEntry {
    case info(String)
    case device(Int32, DiscoveredRNode, Bool)

    var section: ItemListSectionId {
        return 0
    }

    var stableId: Int32 {
        switch self {
        case .info:
            return 0
        case let .device(index, _, _):
            return 1 + index
        }
    }

    static func < (lhs: ReticulumRNodePickerEntry, rhs: ReticulumRNodePickerEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let select = arguments as! (DiscoveredRNode) -> Void
        switch self {
        case let .info(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .device(_, device, checked):
            return ItemListCheckboxItem(presentationData: presentationData, systemStyle: .glass, title: device.name, subtitle: "\(device.rssi) dBm", style: .left, checked: checked, zeroSeparatorInsets: false, sectionId: self.section, action: {
                select(device)
            })
        }
    }
}

func reticulumRNodePickerController(sharedContext: SharedAccountContext, updatedPresentationData: Signal<PresentationData, NoError>) -> ViewController {
    let scanner = RNodeScanner()
    let accountManager = sharedContext.accountManager
    var dismissImpl: (() -> Void)?

    let select: (DiscoveredRNode) -> Void = { device in
        let _ = updateReticulumSettingsInteractively(accountManager: accountManager, { settings in
            var settings = settings
            settings.rnode.peripheralId = device.id
            settings.rnode.peripheralName = device.name
            settings.rnode.enabled = true
            return settings
        }).start()
        dismissImpl?()
    }

    let signal = combineLatest(updatedPresentationData, scanner.scan(), reticulumSettings(accountManager: accountManager))
    |> map { presentationData, devices, settings -> (ItemListControllerState, (ItemListNodeState, Any)) in
        var entries: [ReticulumRNodePickerEntry] = [.info(devices.isEmpty ? "Scanning for RNodes… Make sure the RNode is powered on with Bluetooth enabled." : "Choose the RNode to use.")]
        for (index, device) in devices.enumerated() {
            entries.append(.device(Int32(index), device, device.id == settings.rnode.peripheralId))
        }
        let rightNavigationButton = ItemListNavigationButton(content: .none, style: .activity, enabled: true, action: {})
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text("RNode"), leftNavigationButton: nil, rightNavigationButton: rightNavigationButton, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: true)
        return (controllerState, (listState, select as Any))
    }
    |> afterDisposed {
        let _ = scanner
    }

    let controller = ItemListController(sharedContext: sharedContext, state: signal)
    dismissImpl = { [weak controller] in
        controller?.dismiss()
    }
    return controller
}
