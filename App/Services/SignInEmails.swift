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

/// The email each account on this device was last signed in with, as its
/// person typed it, trimmed and lower-cased: one record per account. It is
/// what a sign-in's guarded tidy (`SignInTidy`) compares with the email
/// typed now, so a server naming some other account at a sign-in can't make
/// this device forget what holds against it.
///
/// In the Keychain under its own service, so the sign-out's
/// `KeychainService.deleteAll()` keeps it, as `RetainedMemberPins` is kept;
/// device-only. An erasure deletes every record (`deleteAll`).
enum SignInEmails {
    private static let service = "com.pingolin.track.sign-in-email"

    /// An email as it is compared: trimmed, lower-cased.
    static func normalized(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The email saved with `account`; nil when there is none (an older
    /// store) or it can't be read.
    static func saved(for account: String) -> String? {
        read(account: CanonicalId.key(account))
    }

    /// At a sign-in that succeeded with a typed email.
    static func save(_ email: String, for account: String) {
        write(normalized(email), account: CanonicalId.key(account))
    }

    static func forget(account: String) {
        for stored in accounts() where CanonicalId.key(stored) == CanonicalId.key(account) {
            delete(account: stored)
        }
    }

    /// An erasure.
    static func deleteAll() {
        for account in accounts() { delete(account: account) }
    }

    // MARK: - Keychain

    private static func write(_ value: String, account: String) {
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        if SecItemUpdate(identity as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            SecItemAdd(identity.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
    }

    private static func read(account: String) -> String? {
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

    private static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// The accounts with a record here.
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

/// A sign-in's tidy of what other accounts left here that holds against the
/// server: the removals an account still owes a record for, with what its
/// sessions couldn't write and the role changes it owes (`RefreshLedger`);
/// its approvals with their tombstones, dead ids and queued changes
/// (`KeyDeliveryApprovals`); its retained pins (`RetainedMemberPins`); what
/// it saw of each SOS (`SOSAlarmMarks`); and its email record. Another
/// account's go only when the person typed an email now AND it differs from
/// the one saved with that account; with no typed email, or none saved (an
/// older store), they stay. Run only once a sign-in has fully succeeded.
@MainActor
enum SignInTidy {
    /// Pure, for tests: whether another account's guarded data may go.
    nonisolated static func mayForget(typedEmail: String?, savedEmail: String?) -> Bool {
        guard let typedEmail, let savedEmail else { return false }
        return SignInEmails.normalized(typedEmail) != SignInEmails.normalized(savedEmail)
    }

    /// The accounts whose guarded data went.
    @discardableResult
    static func run(signedIn: String, typedEmail: String?,
                    ledger: RefreshLedger = .shared, approvals: KeyDeliveryApprovals = .shared,
                    marks: SOSAlarmMarks = .shared) -> Set<String> {
        let me = CanonicalId.key(signedIn)
        let found = ledger.accounts().union(approvals.owners()).union(marks.accounts())
            .union(RetainedMemberPins.accounts()).union(SignInEmails.accounts())
        var others: [String: String] = [:]
        for account in found where CanonicalId.key(account) != me { others[CanonicalId.key(account)] = account }
        var gone = Set<String>()
        for (key, account) in others
        where mayForget(typedEmail: typedEmail, savedEmail: SignInEmails.saved(for: account)) {
            ledger.forget(account: account)
            marks.forget(account: account)
            RetainedMemberPins.forget(owner: account)
            SignInEmails.forget(account: account)
            gone.insert(key)
        }
        approvals.forget(owners: gone)
        if let typedEmail { SignInEmails.save(typedEmail, for: me) }
        return gone
    }
}
