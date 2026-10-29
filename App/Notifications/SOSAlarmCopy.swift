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

/// The words on an SOS notification once this phone has checked it, and
/// which pushes are which. Compiled into the app and the notification
/// extension (project.yml); Foundation only.
///
/// - The real alarm uses the Android app's words exactly (`AlertHandler`
///   and its detail levels): "{name} needs attention" / "Asked their circle
///   to check on them in {circle}".
/// - A checked SOS that isn't live gets a quiet notice (the app's own name
///   in its body), with no sound: an extension can't drop a notification,
///   and the app removes it at its next check. English only, as the rest of
///   the app.
/// - One this phone can't check rings with the server's own words.
enum SOSAlarmCopy {
    /// `alert_type`s of a NEW alert: what the check is for.
    static let newAlertTypes: Set<String> = ["sos", "sos_alert", "emergency"]
    /// Notices about an alert already raised (someone responding, the alert
    /// closed): their words stay, and they never ring.
    static let followUpTypes: Set<String> = ["sos_acknowledged", "sos_resolved"]

    /// Which kind of SOS notice a delivered notification is, in its userInfo:
    /// absent for the server's own words.
    static let noticeKey = "sos_notice"
    static let quietNotice = "quiet"
    static let alarmNotice = "alarm"

    static let quietTitle = "Someone may need help."
    static let quietBody = "Open Track to check."

    /// The real alarm at the user's detail level (`level`: "full", "names" or
    /// "generic"; anything else reads as full, as `UserSettings` does). No
    /// name or circle: the Android app's fallbacks.
    static func alarm(name: String?, circle: String?, level: String?) -> (title: String, body: String) {
        let who = name.flatMap { $0.isEmpty ? nil : $0 } ?? "A circle member"
        let place = circle.flatMap { $0.isEmpty ? nil : $0 } ?? "your circle"
        switch level {
        case "generic":
            return ("A circle member needs attention", "Tap to view")
        case "names":
            return ("\(who) needs attention", "\(who) needs attention")
        default:
            return ("\(who) needs attention", "Asked their circle to check on them in \(place)")
        }
    }
}
