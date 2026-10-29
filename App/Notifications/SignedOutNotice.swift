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
import UserNotifications

/// A session that ends without the person asking (signed out from another
/// device or the account page, an 11th sign-in elsewhere taking its place, a
/// password change) stops location sharing, and while Track isn't in front
/// nobody sees it: its banner is in-app only and gone in 5 s. So the person
/// hears of it where they will see it, as on Android
/// (`tracking_health_signed_out_*`): a notification when Track was sharing,
/// and the sign-in screen says why it is showing and fills in the address.
/// Signing in starts sharing again by itself (`completeLogin` starts
/// tracking).
enum SignedOutNotice {
    static let identifier = "signed-out"
    static let title = "You have been signed out of Track"
    static let body = "Location sharing has stopped. Tap to enter your password, and it starts again by itself."

    /// What the sign-in screen says (`AuthManager.signInNotice`).
    static func signInText(wasSharing: Bool) -> String {
        wasSharing
            ? "You have been signed out, and location sharing has stopped. Enter your password, and it starts again by itself."
            : "You have been signed out. Enter your password to sign in again."
    }

    /// Pure: post only when Track was sharing (an install that wasn't stays
    /// quiet, as on Android) and is in the background: in front, or coming to
    /// the front at a launch, the sign-in screen is showing, and says it.
    static func shouldPost(wasSharing: Bool, inBackground: Bool) -> Bool {
        wasSharing && inBackground
    }

    static func post() {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["alert_type": "signed_out"]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }

    /// Signed in again: the notification has done its work.
    static func clear() {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
    }
}
