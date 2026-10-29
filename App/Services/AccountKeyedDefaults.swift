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

/// UserDefaults keys that end in an account's lowercased id: ids, times and
/// a hash (renewal marks, the personal copy's marks, a signing-key count, the
/// circles' order, the circle questions' marks, the own admissions' attempts).
/// Each is kept for its account across a sign-out, and goes when another
/// account signs in here or at an erasure. Nobody else reads another
/// account's.
enum AccountKeyedDefaults {
    static let prefixes = [
        "invitationRenewals.asked.", "invitationRenewals.reasked.", "invitationRenewals.withdrawn.",
        "selfKey.lastRepublishAt.", "selfKey.flaggedCopy.", "signingKey.legacyShapeSeen.",
        "circles.userOrder.", "circleQuestion.notifiedAt.", "selfAdmission.attempts.",
    ]

    /// Every such key except `owner`'s, compared case-insensitively (nil: all).
    static func wipe(except owner: String?, defaults: UserDefaults = .standard) {
        let keep = owner?.lowercased()
        for key in defaults.dictionaryRepresentation().keys {
            guard let prefix = prefixes.first(where: { key.hasPrefix($0) }) else { continue }
            if let keep, key.dropFirst(prefix.count).lowercased() == keep { continue }
            defaults.removeObject(forKey: key)
        }
    }

    /// The global keys earlier versions kept, once, when the Keychain has said
    /// who is signed in (nil: nobody). The signed-in account's circle order
    /// and question marks become its own; with nobody signed in they go. The
    /// active circle's id, which nothing read, goes.
    static func migrateGlobals(signedIn: String?, defaults: UserDefaults = .standard) {
        for global in ["circles.userOrder", "circleQuestion.notifiedAt"] {
            guard let value = defaults.object(forKey: global) else { continue }
            if let signedIn, defaults.object(forKey: "\(global).\(signedIn.lowercased())") == nil {
                defaults.set(value, forKey: "\(global).\(signedIn.lowercased())")
            }
            defaults.removeObject(forKey: global)
        }
        defaults.removeObject(forKey: "activeCircleId")
    }
}
