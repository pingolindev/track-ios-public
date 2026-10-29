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

/// Single source of truth for the device-local "I compared this member's safety
/// number out of band" marker shown in `MemberDetailView`. Mirrors
/// the Android app's `MemberVerificationStore` (a `member_verification`
/// SharedPreferences file) and the web client's localStorage keys.
///
/// The marker is just a per-(circleId, userId) timestamp; the data is
/// non-secret (a flag + when it was set), so UserDefaults is the right home —
/// nothing here belongs in the keychain.
///
/// SECURITY: the marker asserts trust in a SPECIFIC pinned key. When that pin
/// is overwritten with new keys (an approved member-key change) the old
/// verification no longer applies and MUST be cleared, otherwise the badge
/// would keep vouching for a key the user never actually compared — see
/// `MemberKeyPinner.approve`. It is cleared wholesale when a DIFFERENT account
/// signs in (`adopt(owner:)`), and on a sign-out whose pins could not be kept
/// (`AuthManager.logout`): a same-account sign-out keeps both the SDK pins
/// (`RetainedMemberPins`) and these markers.
enum MemberVerificationStore {
    /// UserDefaults is one flat namespace shared with every other preference on
    /// the app, unlike android's dedicated prefs FILE — so `clearAll()` can't
    /// just wipe the domain. Every key carries this prefix and the sweep
    /// filters on it.
    private static let prefix = "memberVerification."

    /// By the circle's and the member's ids in their one form: a mark set,
    /// read and cleared under any spelling of the same ids is one mark, so a
    /// key change clears it whatever spelling its caller had. A mark stored
    /// under another spelling is not read: a lost tick is the safe side.
    private static func key(circleId: String, userId: String) -> String {
        "\(prefix)\(CanonicalId.key(circleId)):\(CanonicalId.key(userId)):verifiedAt"
    }

    /// When the member was marked verified, or nil if they never were.
    static func verifiedAt(circleId: String, userId: String) -> Date? {
        let seconds = UserDefaults.standard.double(forKey: key(circleId: circleId, userId: userId))
        // `double(forKey:)` returns 0 for an absent key, which is also a valid
        // (if absurd) 1970 timestamp — treat 0 as "not verified", matching
        // android's `getLong(..., 0L)` sentinel.
        guard seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// Mark the member verified at `date` (defaults to now).
    static func setVerified(circleId: String, userId: String, at date: Date = Date()) {
        UserDefaults.standard.set(
            date.timeIntervalSince1970,
            forKey: key(circleId: circleId, userId: userId)
        )
    }

    /// Drop a single member's verification marker (e.g. after their pin changes).
    static func clearVerified(circleId: String, userId: String) {
        UserDefaults.standard.removeObject(forKey: key(circleId: circleId, userId: userId))
    }

    /// Wipe every stored verification marker.
    static func clearAll() {
        let defaults = UserDefaults.standard
        for k in defaults.dictionaryRepresentation().keys where k.hasPrefix(prefix) {
            defaults.removeObject(forKey: k)
        }
    }

    /// Which account the stored markers belong to. Under the same prefix, so
    /// `clearAll()` takes it too.
    private static let ownerKey = "\(prefix)owner"

    /// Called at every sign-in. Markers survive a SAME-account sign-out — they
    /// vouch for pins that `RetainedMemberPins` keeps across it — so the only
    /// boundary is a DIFFERENT account signing in: then every marker goes,
    /// because the next account compared nothing.
    ///
    /// A store with no owner recorded holds markers written by an older
    /// version, whose sign-out wiped them, so any present were made by the
    /// account signed in at the time: adopt them rather than wipe. The
    /// owner is compared case-insensitively and kept lowercased: the same
    /// account in another case keeps its marks.
    static func adopt(owner: String) {
        let defaults = UserDefaults.standard
        if let recorded = defaults.string(forKey: ownerKey), recorded.caseInsensitiveCompare(owner) != .orderedSame {
            clearAll()
        }
        defaults.set(owner.lowercased(), forKey: ownerKey)
    }
}
