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

/// iOS KeyStorageCallback backed by the system Keychain. The SDK's
/// CryptoManager calls into this whenever it needs to persist or load the
/// pair `(user_private_key, circle_keys_json)`. Mirrors the Android app's
/// `KeyStorageCallbackImpl` so both platforms have identical semantics.
final class KeychainKeyStorageCallback: KeyStorageCallback {
    private static let service = "com.pingolin.track.sdk.cryptomanager"
    private static let privateKeyAccount = "private_key"
    private static let circleKeysJsonAccount = "circle_keys_json"
    // Slots for the wrap-signature (Ed25519) key and the TOFU pin
    // records. Optional — accounts that never stored them return
    // nil and the SDK falls back.
    private static let pinnedKeysJsonAccount = "pinned_keys_json"
    private static let signingPrivateKeyAccount = "signing_private_key_b64"

    func storeKeys(data: StoredKeyData) throws {
        try writeString(data.privateKey, account: Self.privateKeyAccount)
        try writeString(data.circleKeysJson, account: Self.circleKeysJsonAccount)
        if let pinned = data.pinnedKeysJson {
            try writeString(pinned, account: Self.pinnedKeysJsonAccount)
        } else {
            try deleteEntry(account: Self.pinnedKeysJsonAccount)
        }
        if let signing = data.signingPrivateKeyB64 {
            try writeString(signing, account: Self.signingPrivateKeyAccount)
        } else {
            try deleteEntry(account: Self.signingPrivateKeyAccount)
        }
    }

    /// nil means NOTHING IS STORED, and only that. Every other failure throws.
    ///
    /// The SDK reads nil as "no keys on this device", so turning a read failure
    /// into nil would bring a process started while the Keychain was still
    /// locked (a location event relaunches the app before the first unlock
    /// after a reboot: `…AfterFirstUnlock…` items are unreadable then) up
    /// keyless — and the next ordinary import would persist that empty state
    /// over the real one: circle keys, every TOFU pin, the signing seed. A
    /// throw makes the SDK refuse to write until a load succeeds; `SDKCrypto`
    /// retries the load when protected data comes back.
    func loadKeys() throws -> StoredKeyData? {
        Self.stored(
            privateKey: try readString(account: Self.privateKeyAccount),
            circleKeysJson: try readString(account: Self.circleKeysJsonAccount),
            pinnedKeysJson: try readString(account: Self.pinnedKeysJsonAccount),
            signingPrivateKeyB64: try readString(account: Self.signingPrivateKeyAccount)
        )
    }

    /// nil ONLY when none of the four entries is stored. A store with some
    /// missing (a write cut short) gives what it has, with "" for a missing
    /// private key or circle-key map: the SDK then finds it doesn't decode, and
    /// the next explicit sign-in clears it. nil would let the next write
    /// replace what is there; "{}" would claim an empty set.
    static func stored(privateKey: String?, circleKeysJson: String?, pinnedKeysJson: String?,
                       signingPrivateKeyB64: String?) -> StoredKeyData? {
        if privateKey == nil, circleKeysJson == nil, pinnedKeysJson == nil, signingPrivateKeyB64 == nil {
            return nil
        }
        return StoredKeyData(
            privateKey: privateKey ?? "",
            circleKeysJson: circleKeysJson ?? "",
            pinnedKeysJson: pinnedKeysJson,
            signingPrivateKeyB64: signingPrivateKeyB64
        )
    }

    func deleteKeys() throws {
        try deleteEntry(account: Self.privateKeyAccount)
        try deleteEntry(account: Self.circleKeysJsonAccount)
        try deleteEntry(account: Self.pinnedKeysJsonAccount)
        try deleteEntry(account: Self.signingPrivateKeyAccount)
    }

    // MARK: - Keychain primitives

    private func writeString(_ value: String, account: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainKeyStorageError.encoding
        }
        // Add-or-update rather than delete-then-add. Delete+add is racy:
        // two concurrent saves of the same key could both delete then
        // both add, and the loser would get errSecDuplicateItem → the save
        // throws → the long-term key is never persisted. It also loses the
        // key entirely if a SecItemAdd fails after the SecItemDelete has
        // already run.
        var attrs = baseQuery(account: account)
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attrs as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updateQuery = baseQuery(account: account)
            // Re-apply the accessibility class on update too (mirrors the Note iOS
            // app's KeychainService update path) so a pre-existing item written with a
            // weaker class self-heals to ...ThisDeviceOnly. Not exploitable — the first
            // write above is already ThisDeviceOnly — but keeps the invariant if a
            // legacy path ever created the item weaker.
            let updateAttrs: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]
            let updateStatus = SecItemUpdate(updateQuery as CFDictionary, updateAttrs as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainKeyStorageError.osStatus(updateStatus)
            }
        } else {
            guard status == errSecSuccess else {
                throw KeychainKeyStorageError.osStatus(status)
            }
        }
    }

    /// The item's value, nil when it does not exist, and a THROW for anything
    /// else — `errSecInteractionNotAllowed` (locked) above all. See `loadKeys`.
    private func readString(account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainKeyStorageError.osStatus(status) }
        guard let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            throw KeychainKeyStorageError.encoding
        }
        return string
    }

    private func deleteEntry(account: String) throws {
        let query = baseQuery(account: account)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainKeyStorageError.osStatus(status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
    }
}

enum KeychainKeyStorageError: Error, CustomStringConvertible {
    case encoding
    case osStatus(OSStatus)

    var description: String {
        switch self {
        case .encoding:
            return "Failed to UTF-8 encode value for keychain"
        case .osStatus(let status):
            return "Keychain operation failed with OSStatus \(status)"
        }
    }
}
