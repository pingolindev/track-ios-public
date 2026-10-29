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

/// What the Notification Service Extension needs to know from the app, written
/// into the shared app-group defaults.
///
/// The extension is a separate process: it cannot read `UserDefaults.standard`
/// or the app's compiled-in environment. It CAN read the app's keychain items
/// (shared keychain-access-group — see NotificationExtension.entitlements), so
/// the session token is already reachable; these values are what it lacks.
/// Mirrored at launch, so a level chosen earlier is picked up, and again
/// whenever the level changes.
///
/// Mirroring the API base URL rather than re-deriving it keeps the extension
/// pointed wherever the app is pointed — including the DEBUG runtime override
/// — with no second copy of the environment switch to drift.
enum ExtensionBridge {
    static let suite = ExtensionBridgeKeys.suite
    static let detailLevelKey = ExtensionBridgeKeys.detailLevel
    static let apiBaseURLKey = ExtensionBridgeKeys.apiBaseURL

    static func sync() {
        guard let defaults = UserDefaults(suiteName: suite) else { return }
        defaults.set(UserSettings.shared.notificationDetailLevel.rawValue, forKey: detailLevelKey)
        defaults.set(AppConfiguration.shared.apiBaseURL, forKey: apiBaseURLKey)
        defaults.set(AppConfiguration.shared.authBaseURL, forKey: ExtensionBridgeKeys.authBaseURL)
    }

    /// The signed-in account for the extension's handover: its user id and the
    /// email the app's confirmation pass uses (`currentUser`, as the app last
    /// loaded it), and its guardian status for the map's standing line before
    /// /auth/me answers. Mirrored whenever `currentUser` changes; gone at
    /// sign-out, so nothing is decided or shown for an account that is not
    /// signed in here.
    static func syncAccount(userId: String?, email: String?, guardianManaged: Bool = false,
                            guardianHandoverDate: String? = nil,
                            defaults: UserDefaults? = UserDefaults(suiteName: suite)) {
        guard let defaults else { return }
        if let userId, let email {
            // The account's fields, then its id: a process
            // stopped in between never pairs one account's id
            // with another's fields. Another account's id goes
            // first.
            if defaults.string(forKey: ExtensionBridgeKeys.accountUserId) != userId {
                defaults.removeObject(forKey: ExtensionBridgeKeys.accountUserId)
            }
            defaults.set(email, forKey: ExtensionBridgeKeys.accountEmail)
            defaults.set(guardianManaged, forKey: ExtensionBridgeKeys.accountGuardianManaged)
            if let guardianHandoverDate {
                defaults.set(guardianHandoverDate, forKey: ExtensionBridgeKeys.accountGuardianHandoverDate)
            } else {
                defaults.removeObject(forKey: ExtensionBridgeKeys.accountGuardianHandoverDate)
            }
            defaults.set(userId, forKey: ExtensionBridgeKeys.accountUserId)
        } else {
            defaults.removeObject(forKey: ExtensionBridgeKeys.accountUserId)
            defaults.removeObject(forKey: ExtensionBridgeKeys.accountEmail)
            defaults.removeObject(forKey: ExtensionBridgeKeys.accountGuardianManaged)
            defaults.removeObject(forKey: ExtensionBridgeKeys.accountGuardianHandoverDate)
        }
    }

    /// The guardian status last mirrored, and whose it is. A key that was
    /// never written reads as not managed, with no handover day.
    struct MirroredGuardian: Equatable {
        let userId: String?
        let managed: Bool
        let handoverDate: String?
    }

    static func mirroredGuardian(defaults: UserDefaults? = UserDefaults(suiteName: suite)) -> MirroredGuardian {
        MirroredGuardian(
            userId: defaults?.string(forKey: ExtensionBridgeKeys.accountUserId),
            managed: defaults?.bool(forKey: ExtensionBridgeKeys.accountGuardianManaged) ?? false,
            handoverDate: defaults?.string(forKey: ExtensionBridgeKeys.accountGuardianHandoverDate))
    }

    /// The account last mirrored, and its email, as the extension reads them:
    /// what the app's own confirmation pass falls back on in a process that
    /// hasn't read /auth/me (`CircleManager.ownEmail`).
    static var accountUserId: String? {
        UserDefaults(suiteName: suite)?.string(forKey: ExtensionBridgeKeys.accountUserId)
    }

    static var accountEmail: String? {
        UserDefaults(suiteName: suite)?.string(forKey: ExtensionBridgeKeys.accountEmail)
    }
}
