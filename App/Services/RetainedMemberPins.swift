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
import os
import PingolinTrackSDK

/// Keeps this account's member-key pins across an explicit sign-out.
///
/// Trust-on-first-use is only as strong as the pin store. A sign-out that
/// wiped every pin (`clearAllKeys`) would make the next sign-in trust every
/// member's keys afresh — a server could substitute a key at exactly that
/// moment and no "Member identity changed" alert would ever fire — and every
/// safety number a user had compared would stop meaning anything. The web app
/// and both Note apps keep pins for a same-account re-login too.
///
/// Flow:
///   * explicit sign-out of U: `exportMemberPins(U)` → saved here under U →
///     THEN `clearAllKeys()` (which still wipes the SDK's own copy);
///   * sign-in of U: right after the private and signing keys are imported and
///     before any circle key or roster is touched → `importMemberPins(U, blob)`,
///     and the blob is deleted (consumed: a later session's approvals must not
///     be rolled back by an old export);
///   * another account's blob goes only when a sign-in's guarded tidy says so
///     (`SignInTidy`): losing it is a trust-on-first-use reset, so a server
///     naming some other account at a sign-in never does it.
///
/// Stored in the Keychain under its OWN service: `KeychainService.deleteAll()`
/// at sign-out wipes `com.pingolin.track`, which is exactly what this must
/// survive. The blob is public keys and timestamps — no secrets — but it is
/// social-graph metadata, so it stays device-only (`…ThisDeviceOnly`).
enum RetainedMemberPins {
    private static let service = "com.pingolin.track.retained-member-pins"
    static let log = Logger(subsystem: "com.pingolin.track", category: "MemberPins")

    /// Export the signed-out account's pins. Returns whether they were kept —
    /// the caller keeps the user's "verified" marks only if so, because a mark
    /// vouching for a pin that did not survive would vouch for whatever key the
    /// next sign-in trusts afresh.
    @discardableResult
    static func retain(owner: String, crypto: PingolinTrackSDK.CryptoManager) -> Bool {
        do {
            let blob = try crypto.exportMemberPins(ownerUserId: owner)
            try write(blob, account: owner.lowercased())
            return true
        } catch {
            log.error("could not keep member pins across sign-out: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// Restore the signing-in account's pins, if it left any. Another
    /// account's stay: the sign-in's guarded tidy decides about them
    /// (`SignInTidy`). Returns how many pin records were imported.
    @discardableResult
    static func restore(owner: String, crypto: PingolinTrackSDK.CryptoManager) -> UInt32 {
        // This account's, whatever its spelling: an entry stored by an older
        // version is under the id as it was given. The lowercase one first;
        // all are consumed.
        let lower = owner.lowercased()
        let mine = [lower] + accounts().filter { $0 != lower && CanonicalId.key($0) == CanonicalId.key(owner) }
        defer { mine.forEach { delete(account: $0) } }
        guard let blob = mine.lazy.compactMap({ read(account: $0) }).first else { return 0 }
        do {
            return try crypto.importMemberPins(ownerUserId: owner, exportedPins: blob)
        } catch {
            log.error("could not restore member pins: \(String(describing: error), privacy: .public)")
            return 0
        }
    }

    // MARK: - Keychain

    static func write(_ value: String, account: String) throws {
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let update = SecItemUpdate(identity as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeychainKeyStorageError.osStatus(update) }
        let add = SecItemAdd(identity.merging(attributes) { _, new in new } as CFDictionary, nil)
        guard add == errSecSuccess else { throw KeychainKeyStorageError.osStatus(add) }
    }

    static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Every stored account except `owner` (nil: all of them), compared
    /// case-insensitively: the same account in another case is never taken
    /// for another's.
    static func deleteAll(except owner: String?) {
        for account in accounts() where owner.map({ account.caseInsensitiveCompare($0) != .orderedSame }) ?? true {
            delete(account: account)
        }
    }

    /// One account's pins, under any spelling of its id: the sign-in's
    /// guarded tidy (`SignInTidy`).
    static func forget(owner: String) {
        for account in accounts() where CanonicalId.key(account) == CanonicalId.key(owner) {
            delete(account: account)
        }
    }

    /// The accounts stored here.
    static func accounts() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }
}
