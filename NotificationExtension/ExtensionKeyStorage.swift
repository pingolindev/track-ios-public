// Copyright (c) 2026 Pingolin LLC
//
// This file is part of Pingolin Track.
//
// Pingolin Track is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// Pingolin Track is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with Pingolin Track. If not, see <https://www.gnu.org/licenses/>.

import Foundation
import PingolinTrackSDK

/// READ-ONLY key storage for the Notification Service Extension.
///
/// The extension needs the circle keys for exactly one thing: opening the sealed
/// `encrypted_occurred_at` so a banner can be stamped with when the crossing
/// actually happened instead of when the push was dispatched. It must never
/// write or delete key material — a background process racing the app over the
/// user's keys is a far worse outcome than a missing timestamp, so both mutating
/// callbacks are hard no-ops here.
///
/// Reads the SAME items as the app's `KeychainKeyStorageCallback` (identical
/// service and account names, deliberately duplicated rather than shared —
/// pulling the app's file in would drag its dependencies into the extension).
/// They are readable because the extension declares the app's
/// keychain-access-group; see NotificationExtension.entitlements for why that
/// needs no migration.
///
/// Items are `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, so this works
/// on a locked device after the first unlock since boot — the usual case for a
/// place alert. Before first unlock the read fails and the caller falls back to
/// the dispatch time (and hands nobody anything).
///
/// Every read that fails for a reason other than "no such item", and a pin set
/// that is there but does not read, THROWS instead of reading as "nothing": the
/// SDK takes an unparsable pin set as an EMPTY one ("continuing with empty pin
/// set"), and an empty pin set would make every member first contact to the
/// background handover. An unreadable trust state hands nobody anything.
final class ExtensionKeyStorage: KeyStorageCallback {
    private static let service = "com.pingolin.track.sdk.cryptomanager"
    private static let privateKeyAccount = "private_key"
    private static let circleKeysJsonAccount = "circle_keys_json"
    private static let pinnedKeysJsonAccount = "pinned_keys_json"
    private static let signingPrivateKeyAccount = "signing_private_key_b64"

    enum ReadError: Error, Equatable {
        /// The keychain refused the read (before first unlock, for one).
        case keychain(OSStatus)
        /// The item is there and does not read as what it must be.
        case unreadable(String)
    }

    func loadKeys() throws -> StoredKeyData? {
        guard let privateKey = try readString(account: Self.privateKeyAccount),
              let circleKeysJson = try readString(account: Self.circleKeysJsonAccount) else {
            return nil
        }
        let pins = try readString(account: Self.pinnedKeysJsonAccount)
        if let pins { try Self.checkPins(pins) }
        return StoredKeyData(
            privateKey: privateKey,
            circleKeysJson: circleKeysJson,
            pinnedKeysJson: pins,
            signingPrivateKeyB64: try readString(account: Self.signingPrivateKeyAccount)
        )
    }

    /// The shape the SDK's `PinRecord` requires of every stored pin (circle
    /// pins, identity pins and rotation markers alike): if this does not read,
    /// neither would the SDK, which would carry on with no pins at all.
    static func checkPins(_ json: String) throws {
        struct Pin: Decodable {
            let sharingPubkeyHex: String
            let signingPubkeyHex: String
            let firstPinnedAt: Int64
            let lastVerifiedAt: Int64
            let userApprovedChangeAt: Int64?
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard (try? decoder.decode([String: Pin].self, from: Data(json.utf8))) != nil else {
            throw ReadError.unreadable("pins")
        }
    }

    /// Deliberately does nothing. The extension is a reader; the app owns the
    /// lifecycle of these keys.
    func storeKeys(data: StoredKeyData) throws {}

    /// Deliberately does nothing — see `storeKeys`. An extension deleting the
    /// user's keys would log them out from a background process.
    func deleteKeys() throws {}

    /// nil only when the item does not exist.
    private func readString(account: String) throws -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw ReadError.keychain(status) }
        guard let data = result as? Data, let string = String(data: data, encoding: .utf8) else {
            throw ReadError.unreadable(account)
        }
        return string
    }
}
