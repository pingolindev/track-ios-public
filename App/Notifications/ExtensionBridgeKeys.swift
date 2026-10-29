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

/// The app-group keys the app writes (`ExtensionBridge`) and its Notification
/// Service Extension reads. Compiled into both (project.yml), so the two cannot
/// drift apart.
enum ExtensionBridgeKeys {
    static let suite = "group.com.pingolin.track"
    static let detailLevel = "notification_detail_level"
    static let apiBaseURL = "api_base_url"
    /// Where the extension refreshes the session.
    static let authBaseURL = "auth_base_url"
    /// The signed-in account's email as the app last loaded it, and whose it is
    /// (the keychain's `user_id`). The confirmation pass needs the email for an
    /// invitation to an email, so the extension's handover uses exactly the one
    /// the app's pass uses — and none when it is missing.
    static let accountUserId = "account_user_id"
    static let accountEmail = "account_email"
    /// What /auth/me last said of that account's guardian: whether one holds
    /// it, and the handover day they named. The map's standing line shows
    /// from them until this process's /auth/me answers.
    static let accountGuardianManaged = "account_guardian_managed"
    static let accountGuardianHandoverDate = "account_guardian_handover_date"
    /// A wipe of the SDK's key store is owed (`OwedWipe`): the app loads
    /// nothing until it is paid, and the extension loads nothing at all.
    static let keyStoreWipeOwed = "sdk_key_store_wipe_owed"
}
