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
import Security

/// Secure storage using iOS Keychain
final class KeychainService {
    static let shared = KeychainService()

    private let service = "com.pingolin.track"

    private init() {}

    // MARK: - Keys

    enum Key: String {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case tokenExpiry = "token_expiry"
        case userId = "user_id"
        case deviceId = "device_id"
        case privateKey = "private_key"
        case publicKey = "public_key"
        case recoveryKey = "recovery_key"
        // Vault-key chain (Argon2id-derived from password on login). The
        // SDK uses sharingPrivateKey for X25519 ECDH-unwrap of incoming
        // wrapped circle keys; masterKey is kept around as a derivation
        // byproduct.
        case masterKey = "master_key"
        case sharingPrivateKey = "sharing_private_key"
        case sharingPublicKey = "sharing_public_key"
        // Privacy-preserving geocode tokens (VOPRF). The pool holds anonymous
        // single-use bearer credits, so it is device-pinned like the secret
        // keys; the pinned key_id + public_key are published material, not
        // secret. All three are cleared by deleteAll() on logout so leftover
        // credits can't be inherited by the next account on this device.
        case geocodeTokenPool = "geocode_token_pool"
        case geocodeKeyId = "geocode_key_id"
        case geocodePublicKey = "geocode_public_key"

        /// Keychain accessibility class for this item.
        ///
        /// Long-term secret key material is pinned to *this device*
        /// (`AfterFirstUnlockThisDeviceOnly`) so it cannot be restored onto a
        /// different device via an encrypted iCloud/iTunes backup — the
        /// server is E2EE-blind, so leaking these off-device would expose the
        /// user's location history. Session tokens are device-pinned too: a
        /// refresh token restored from a backup is a usable bearer credential.
        /// Identifiers and public keys stay `AfterFirstUnlock` so they survive a
        /// legitimate device migration (re-fetched from the server, or not secret).
        var accessibility: CFString {
            switch self {
            case .privateKey, .recoveryKey, .masterKey, .sharingPrivateKey,
                 .geocodeTokenPool,
                 .accessToken, .refreshToken:
                return kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            case .tokenExpiry, .userId, .deviceId,
                 .publicKey, .sharingPublicKey,
                 .geocodeKeyId, .geocodePublicKey:
                return kSecAttrAccessibleAfterFirstUnlock
            }
        }
    }

    // MARK: - Public API

    func save(_ value: String, for key: Key) throws {
        let data = value.data(using: .utf8)!
        try save(data, for: key.rawValue, accessible: key.accessibility)
    }

    func save(_ value: Data, for key: Key) throws {
        try save(value, for: key.rawValue, accessible: key.accessibility)
    }

    func getString(for key: Key) -> String? {
        guard let data = getData(for: key.rawValue) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func getData(for key: Key) -> Data? {
        return getData(for: key.rawValue)
    }

    /// What a read of one item found. Only `.notFound` means nothing is stored:
    /// any other failure (above all `errSecInteractionNotAllowed`, the Keychain
    /// before the first unlock after a restart) is no answer yet.
    enum Read: Equatable {
        case value(Data)
        case notFound
        case unavailable(OSStatus)

        /// Pure: `SecItemCopyMatching`'s status and result, as a read.
        static func of(status: OSStatus, result: AnyObject?) -> Read {
            switch status {
            case errSecSuccess:
                guard let data = result as? Data else { return .unavailable(errSecDecode) }
                return .value(data)
            case errSecItemNotFound:
                return .notFound
            default:
                return .unavailable(status)
            }
        }
    }

    func read(_ key: Key) -> Read {
        read(item: key.rawValue)
    }

    func read(item: String) -> Read {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: item,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return Read.of(status: status, result: result)
    }

    func delete(key: Key) {
        delete(key: key.rawValue)
    }

    func deleteAll() {
        // Blanket-wipe EVERY keychain item under our service — the static Key
        // cases AND the dynamic entries (circle_key_<id>, sdk_<k>) that
        // Key.allCases can't enumerate. Called on logout / account deletion so no
        // key material outlives the session. `onboarding.complete` lives in
        // UserDefaults, not here, so the one-time walkthrough state is untouched.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Circle Keys (dynamic keys)

    func saveCircleKey(_ encryptedKey: String, for circleId: String) throws {
        // Circle keys are long-term secret key material — device-pinned.
        try save(encryptedKey.data(using: .utf8)!, for: "circle_key_\(circleId)",
                 accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
    }

    func getCircleKey(for circleId: String) -> String? {
        guard let data = getData(for: "circle_key_\(circleId)") else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func deleteCircleKey(for circleId: String) {
        delete(key: "circle_key_\(circleId)")
    }

    // MARK: - Items of their own (dynamic keys)

    /// An item of this service named by its caller: device-pinned, and
    /// `deleteAll()` takes it at a sign-out and at an erasure.
    func save(_ value: String, item: String) throws {
        try save(Data(value.utf8), for: item, accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
    }

    /// Items a retired store left behind, by name prefix. Nothing reads them:
    /// - "circle_name_read_": circle names an earlier version kept for repairing
    ///   a misattributed key version. Plaintext names, so they go.
    static let retiredItemPrefixes = ["circle_name_read_"]

    /// Deletes every item a retired store left (`retiredItemPrefixes`), at
    /// every launch and sign-in. Idempotent and best effort: before the first
    /// unlock the Keychain doesn't answer and nothing happens, and the next
    /// launch tries again. Never fails anything.
    func purgeRetiredItems() {
        for prefix in Self.retiredItemPrefixes {
            for item in items(withPrefix: prefix) {
                delete(item: item)
            }
        }
    }

    func delete(item: String) {
        delete(key: item)
    }

    /// The items of this service whose names start with `prefix`; none when
    /// the Keychain doesn't answer.
    func items(withPrefix prefix: String) -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }.filter { $0.hasPrefix(prefix) }
    }

    // MARK: - SDK Secure Storage Callback Support

    func saveSDKData(_ value: String, for key: String) throws {
        // SDK secure-storage payloads (private key, circle-keys JSON, signing
        // seed) are long-term secret key material — device-pinned.
        try save(value.data(using: .utf8)!, for: "sdk_\(key)",
                 accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
    }

    func getSDKData(for key: String) -> String? {
        guard let data = getData(for: "sdk_\(key)") else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func deleteSDKData(for key: String) {
        delete(key: "sdk_\(key)")
    }

    func containsSDKData(for key: String) -> Bool {
        return getData(for: "sdk_\(key)") != nil
    }

    func clearAllSDKData() {
        // Query all items with sdk_ prefix and delete them
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let items = result as? [[String: Any]] else { return }

        for item in items {
            if let account = item[kSecAttrAccount as String] as? String,
               account.hasPrefix("sdk_") {
                delete(key: account)
            }
        }
    }

    // MARK: - Private Implementation

    private func save(_ data: Data, for key: String, accessible: CFString) throws {
        // Identity of the item (class + service + account).
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        // `accessible` is included in the update attributes too, so an existing
        // item written under the old (AfterFirstUnlock) class is upgraded to
        // the device-pinned class the next time it's saved.
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessible
        ]

        // Update-or-add rather than delete-then-add. Delete+add is
        // racy: during a cold-start burst of refreshes, two concurrent
        // saves of the same key could both delete then both add, and
        // the loser would get errSecDuplicateItem → the save throws →
        // the rotated token is never persisted → "Token expired" on
        // every call → re-login loop. An in-place update has no such
        // window. (Also avoids the brief moment where the item doesn't
        // exist at all, between delete and add.)
        let updateStatus = SecItemUpdate(identity as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus == errSecItemNotFound {
            let addQuery = identity.merging(attributes) { _, new in new }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            // Tolerate a concurrent add that beat us to it — the value we'd
            // write is identical (same rotated token), so a duplicate is a
            // success from the caller's perspective.
            guard addStatus == errSecSuccess || addStatus == errSecDuplicateItem else {
                throw KeychainError.saveFailed(addStatus)
            }
            return
        }
        throw KeychainError.saveFailed(updateStatus)
    }

    private func getData(for key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    private func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]

        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Errors

    enum KeychainError: Error {
        case saveFailed(OSStatus)
        case notFound
        case unexpectedData
    }
}

// MARK: - Key CaseIterable

extension KeychainService.Key: CaseIterable {}
