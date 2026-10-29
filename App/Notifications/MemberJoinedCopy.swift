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

/// The words on a "New Circle Member" banner once the device knows who joined
/// and where.
///
/// The relay (Apple) only ever carries the server's generic copy, "New Circle
/// Member / A new member joined your circle". The Notification Service
/// Extension learns the names over the app's own connection while it hands
/// the newcomer access and rewrites the body here, at the user's detail
/// level. Compiled into both the app and the extension (project.yml);
/// Foundation only.
enum MemberJoinedCopy {
    /// The new body, or nil to keep the server's words.
    ///
    /// `level` is the STORED raw value of `NotificationDetailLevel`: "full",
    /// "names" or "generic"; anything else, including nil, reads as full, which
    /// is what `UserSettings.notificationDetailLevel` does with an unset key.
    /// Generic keeps the server's copy, which names nobody. "Names only" keeps
    /// the person and drops the circle, as it drops places everywhere else.
    /// Only a member this device confirmed is ever named: someone it keeps out
    /// is not shown anywhere, so the banner stays generic about them.
    static func body(member: String?, circle: String?, level: String?) -> String? {
        let member = member.flatMap { $0.isEmpty ? nil : $0 }
        let circle = circle.flatMap { $0.isEmpty ? nil : $0 }
        switch level {
        case "generic":
            return nil
        case "names":
            return member.map { "\($0) joined your circle." }
        default:
            switch (member, circle) {
            case let (member?, circle?): return "\(member) joined \(circle)."
            case let (member?, nil): return "\(member) joined your circle."
            case let (nil, circle?): return "A new member joined \(circle)."
            default: return nil
            }
        }
    }
}
