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

/// The words on a circle-invite banner, and the choice of which pending invite a
/// push is about.
///
/// Compiled into BOTH the app and the Notification Service Extension
/// (project.yml lists this file under the extension's sources) so the two can
/// never disagree about what a detail level shows. Foundation only — the
/// extension must not drag in UIKit, SwiftUI or the app's managers.
///
/// Where the names come from: never the push. The relay (Apple) sees only the
/// server's generic copy, "Circle invitation / You've been invited to join a
/// circle". The extension fetches the pending invite over the app's own
/// authenticated connection and the app reads its refreshed list; either way
/// the names travel encrypted end to end between this device and the API, and
/// `NotificationDetailLevel` decides how much of them the lock screen gets —
/// exactly as for every other notification kind.
enum InviteNotificationCopy {
    /// Never redacted: titles only name the event type, and this one matches the
    /// server's relay copy so a rewritten banner and an un-rewritten one read as
    /// the same event.
    static let title = "Circle invitation"

    /// The generic level shows no names, no places, no message content — the same
    /// words `NotificationDetailLevel.genericBody` uses for every other kind.
    static let genericBody = "Tap to view"

    /// `level` is the STORED raw value of `NotificationDetailLevel` — "full",
    /// "names" or "generic". Anything else, including nil, reads as full, which is
    /// what `UserSettings.notificationDetailLevel` does with an unset key.
    static func body(inviter: String?, circle: String?, level: String?) -> String {
        let inviter = inviter.flatMap { $0.isEmpty ? nil : $0 }
        let circle = circle.flatMap { $0.isEmpty ? nil : $0 }
        switch level {
        case "generic":
            return genericBody
        case "names":
            // The inviter stays, the circle name goes.
            return inviter.map { "\($0) invited you to a circle." }
                ?? "You've been invited to join a circle."
        default:
            switch (inviter, circle) {
            case let (name?, circle?): return "\(name) invited you to join \(circle)."
            case let (name?, nil): return "\(name) invited you to a circle."
            case let (nil, circle?): return "You've been invited to join \(circle)."
            default: return "You've been invited to join a circle."
            }
        }
    }

    /// True for an invite body that names nobody: the server's relay copy, the
    /// generic-level rewrite, or the older "Tap to view" fallback. The app uses
    /// it to decide whether a delivered server banner is worth replacing with a
    /// named one.
    static func isGeneric(body: String) -> Bool {
        let b = body.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return b == "you've been invited to join a circle"
            || b == "you've been invited to join a circle."
            || b == genericBody.lowercased()
    }

    /// The fields of a pending invite this copy needs, as `GET
    /// /api/v1/invites/received` serves them (snake_case on the wire — decode
    /// with `.convertFromSnakeCase`).
    struct PendingInvite: Decodable, Equatable {
        let id: String
        let circleId: String
        let circleName: String?
        let inviterDisplayName: String?
    }

    private struct Envelope: Decodable {
        let data: [PendingInvite]?
    }

    /// Decodes the server's `{ success, data: [...] }` envelope. Anything
    /// malformed is an empty list — a banner must never be lost to a decode.
    static func decodePending(_ data: Data) -> [PendingInvite] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return (try? decoder.decode(Envelope.self, from: data))?.data ?? []
    }

    /// The circle of this user's notification row, as `GET
    /// /api/v1/notifications/{id}` serves it — what an invite push names
    /// (`alert_id` = the row, never the circle). nil for anything else.
    static func decodeRowCircle(_ data: Data) -> String? {
        struct Row: Decodable { let circleId: String? }
        struct RowEnvelope: Decodable { let data: Row? }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return (try? decoder.decode(RowEnvelope.self, from: data))?.data?.circleId.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The pending invite a push is about: the one for the push's circle (an
    /// invite push from an older server carries the circle id as `alert_id`; a
    /// current one names its notification row, which the caller reads for the
    /// circle), else the only pending invite there is. Two or more pending invites and no circle to pick by is
    /// nil — naming the wrong inviter would be worse than naming none.
    static func pick(from invites: [PendingInvite], circleId: String?) -> PendingInvite? {
        if let circleId, !circleId.isEmpty,
           let match = invites.first(where: { $0.circleId == circleId }) {
            return match
        }
        return invites.count == 1 ? invites[0] : nil
    }
}
