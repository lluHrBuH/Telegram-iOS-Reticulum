import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import AccountContext
import AlertUI

/// The first step of the Reticulum onboarding: a new identity on this device, or an existing
/// identity's private key (64 bytes, 128 hex characters, what a Reticulum identity file holds).
/// The identity's address becomes the account.

private final class ReticulumIdentityControllerArguments {
    let updateKey: (String) -> Void
    let createIdentity: () -> Void
    let importIdentity: () -> Void

    init(updateKey: @escaping (String) -> Void, createIdentity: @escaping () -> Void, importIdentity: @escaping () -> Void) {
        self.updateKey = updateKey
        self.createIdentity = createIdentity
        self.importIdentity = importIdentity
    }
}

private enum ReticulumIdentitySection: Int32 {
    case create
    case importKey
}

private enum ReticulumIdentityEntry: ItemListNodeEntry {
    case createInfo(String)
    case create(String, Bool)
    case importHeader(String)
    case importKey(String, String)
    case importAction(String, Bool)
    case importInfo(String)

    var section: ItemListSectionId {
        switch self {
        case .createInfo, .create:
            return ReticulumIdentitySection.create.rawValue
        case .importHeader, .importKey, .importAction, .importInfo:
            return ReticulumIdentitySection.importKey.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case .createInfo:
            return 0
        case .create:
            return 1
        case .importHeader:
            return 2
        case .importKey:
            return 3
        case .importAction:
            return 4
        case .importInfo:
            return 5
        }
    }

    static func < (lhs: ReticulumIdentityEntry, rhs: ReticulumIdentityEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! ReticulumIdentityControllerArguments
        switch self {
        case let .createInfo(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .create(title, enabled):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: title, kind: enabled ? .generic : .disabled, alignment: .center, sectionId: self.section, style: .blocks, action: {
                arguments.createIdentity()
            })
        case let .importHeader(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .importKey(placeholder, text):
            return ItemListSingleLineInputItem(presentationData: presentationData, systemStyle: .glass, title: NSAttributedString(), text: text, placeholder: placeholder, type: .regular(capitalization: false, autocorrection: false), sectionId: self.section, textUpdated: { value in
                arguments.updateKey(value)
            }, action: {})
        case let .importAction(title, enabled):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: title, kind: enabled ? .generic : .disabled, alignment: .center, sectionId: self.section, style: .blocks, action: {
                arguments.importIdentity()
            })
        case let .importInfo(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        }
    }
}

private struct ReticulumIdentityState: Equatable {
    var key: String = ""
    var inProgress: Bool = false
}

private func reticulumIdentityEntries(state: ReticulumIdentityState) -> [ReticulumIdentityEntry] {
    let keyData = ReticulumHex.data(from: state.key)
    return [
        .createInfo("Your Reticulum identity is your account. It is made on this device and never leaves it unless you export it. Anyone can reach you at its address, on any network that carries Reticulum: the internet, a LoRa radio, Bluetooth."),
        .create("Create New Identity", !state.inProgress),
        .importHeader("OR IMPORT AN EXISTING IDENTITY"),
        .importKey("Identity private key (128 hex characters)", state.key),
        .importAction("Import Identity", !state.inProgress && keyData?.count == 64),
        .importInfo("The 64-byte private key of a Reticulum identity, as hex: what Sideband or NomadNet export, or the bytes of an identity file. Importing it here moves your address to this device."),
    ]
}

func reticulumIdentityController(sharedContext: SharedAccountContext, account: UnauthorizedAccount, presentationData: PresentationData, completed: @escaping (ReticulumAddress) -> Void) -> ViewController {
    let statePromise = ValuePromise(ReticulumIdentityState(), ignoreRepeated: true)
    let stateValue = Atomic(value: ReticulumIdentityState())
    let updateState: ((ReticulumIdentityState) -> ReticulumIdentityState) -> Void = { f in
        statePromise.set(stateValue.modify { f($0) })
    }
    let actionDisposable = MetaDisposable()
    var presentControllerImpl: ((ViewController) -> Void)?

    let identityProvider = (account.networkArguments.networkEngineFactory as? ReticulumNetworkEngineFactory)?.identityProvider
    let accountBasePath = account.basePath

    let presentError: (String) -> Void = { text in
        presentControllerImpl?(textAlertController(sharedContext: sharedContext, title: nil, text: text, actions: [TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})]))
    }

    let run: (Signal<ReticulumAddress, ReticulumIdentityError>) -> Void = { signal in
        updateState { state in
            var state = state
            state.inProgress = true
            return state
        }
        actionDisposable.set((signal
        |> deliverOnMainQueue).start(next: { address in
            updateState { state in
                var state = state
                state.inProgress = false
                return state
            }
            completed(address)
        }, error: { error in
            updateState { state in
                var state = state
                state.inProgress = false
                return state
            }
            switch error {
            case let .failed(reason):
                presentError("The identity could not be started: \(reason)")
            }
        }))
    }

    let arguments = ReticulumIdentityControllerArguments(updateKey: { value in
        updateState { state in
            var state = state
            state.key = value
            return state
        }
    }, createIdentity: {
        guard let identityProvider = identityProvider else {
            presentError("This build has no Reticulum backend.")
            return
        }
        run(identityProvider.createIdentity(accountBasePath: accountBasePath))
    }, importIdentity: {
        guard let identityProvider = identityProvider else {
            presentError("This build has no Reticulum backend.")
            return
        }
        let key = stateValue.with { $0.key }
        guard let data = ReticulumHex.data(from: key), data.count == 64 else {
            presentError("A private key is 128 hex characters.")
            return
        }
        run(identityProvider.importIdentity(privateKey: data, accountBasePath: accountBasePath))
    })

    let signal = combineLatest(sharedContext.presentationData, statePromise.get())
    |> map { presentationData, state -> (ItemListControllerState, (ItemListNodeState, Any)) in
        var rightNavigationButton: ItemListNavigationButton?
        if state.inProgress {
            rightNavigationButton = ItemListNavigationButton(content: .none, style: .activity, enabled: true, action: {})
        }
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text("Reticulum Identity"), leftNavigationButton: nil, rightNavigationButton: rightNavigationButton, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: reticulumIdentityEntries(state: state), style: .blocks)
        return (controllerState, (listState, arguments))
    }
    |> afterDisposed {
        actionDisposable.dispose()
    }

    let controller = ItemListController(sharedContext: sharedContext, state: signal)
    presentControllerImpl = { [weak controller] c in
        controller?.present(c, in: .window(.root))
    }
    return controller
}
