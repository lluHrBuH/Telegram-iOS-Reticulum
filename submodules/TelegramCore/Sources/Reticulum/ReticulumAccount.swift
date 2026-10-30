import Foundation
import Postbox
import SwiftSignalKit
import MtProtoKit

public enum ReticulumIdentityError: Error {
    case failed(String)
}

/// The app's hold on Reticulum identities (the Rust stack owns the key files): one identity per
/// account directory, created or imported at onboarding, exported for backup. Starting an identity
/// also starts the mesh transport the `LocalServer` of that account receives.
public protocol ReticulumIdentityProvider: AnyObject {
    /// Makes a new identity for the account (or starts the one its directory already holds) and
    /// starts the transport; the account's LXMF address.
    func createIdentity(accountBasePath: String) -> Signal<ReticulumAddress, ReticulumIdentityError>
    /// Starts the transport on the given 64-byte private key (`exportIdentity`'s format, also what a
    /// Reticulum identity file holds), replacing any identity the directory had.
    func importIdentity(privateKey: Data, accountBasePath: String) -> Signal<ReticulumAddress, ReticulumIdentityError>
    /// The 64-byte private key of the account's identity, nil when the directory has none.
    func exportIdentity(accountBasePath: String) -> Data?
}

public enum ReticulumAccountError: Error {
    case noReticulumBackend
    case serverUnavailable
}

extension ReticulumNetworkEngineFactory {
    /// The server an account's network already opened, for the onboarding that sets the account's
    /// identity on it before the authorized network exists.
    public func server(accountBasePath: String) -> LocalServer? {
        return self.server(for: NetworkEngineAccountEnvironment(accountId: AccountRecordId(rawValue: 0), basePath: accountBasePath, encryptionParameters: nil, isAppExtension: false))
    }
}

/// Turns an unauthorized account into this device's Reticulum account: the identity's address
/// becomes the account's own user, the account state is written as a login would write it, and
/// the account manager switches to it. Nothing talks to any server: the local server records the
/// identity, and the authorized network that follows answers the launch chain from it.
public func createReticulumAccount(accountManager: AccountManager<TelegramAccountManagerTypes>, account: UnauthorizedAccount, address: ReticulumAddress, firstName: String, lastName: String) -> Signal<Never, ReticulumAccountError> {
    guard let factory = account.networkArguments.networkEngineFactory as? ReticulumNetworkEngineFactory else {
        return .fail(.noReticulumBackend)
    }
    guard let server = factory.server(accountBasePath: account.basePath) else {
        return .fail(.serverUnavailable)
    }
    let peerId = LocalServerPeerIdentity.peerId(for: address)
    let accessHash = LocalServerPeerIdentity.accessHash(for: address)
    let appVersion = account.networkArguments.appVersion
    let postbox = account.postbox
    let identityRecorded = Signal<Never, NoError> { subscriber in
        server.setSelfIdentity(address: address, firstName: firstName, lastName: lastName, completion: {
            subscriber.putCompletion()
        })
        return EmptyDisposable
    }
    return identityRecorded
    |> castError(ReticulumAccountError.self)
    |> then(
        postbox.transaction { transaction -> Void in
            let user = TelegramUser(id: peerId, accessHash: .personal(accessHash), firstName: firstName.isEmpty ? nil : firstName, lastName: lastName.isEmpty ? nil : lastName, username: LocalServerPeerIdentity.username(for: address), phone: nil, photo: [], botInfo: nil, restrictionInfo: nil, flags: [], emojiStatus: nil, usernames: [], storiesHidden: nil, nameColor: nil, backgroundEmojiId: nil, profileColor: nil, profileBackgroundEmojiId: nil, subscriberCount: nil, verificationIconFileId: nil)
            updatePeersCustom(transaction: transaction, peers: [user], update: { _, updated in
                return updated
            })
            initializedAppSettingsAfterLogin(transaction: transaction, appVersion: appVersion, syncContacts: false)
            transaction.setState(AuthorizedAccountState(isTestingEnvironment: false, masterDatacenterId: 1, peerId: peerId, state: nil, invalidatedChannels: []))
        }
        |> castError(ReticulumAccountError.self)
        |> mapToSignal { _ -> Signal<Never, ReticulumAccountError> in
            return accountManager.transaction { transaction -> Void in
                switchToAuthorizedAccount(transaction: transaction, account: account, isSupportUser: false)
            }
            |> castError(ReticulumAccountError.self)
            |> ignoreValues
        }
    )
}
