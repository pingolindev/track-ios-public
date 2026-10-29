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

/// Why a member's position may not be updating in a circle: the roster's
/// `location_sharing` / `sharing_paused_until` (GET /circles/{id}/members), or
/// the person's own privacy row for that circle.
///
/// Without it, switching real-time sharing off, or pausing, would leave a
/// frozen marker on everyone else's map with nothing to say why. The Android
/// and web apps use the same three states and the same words.
enum MemberSharingStatus: Equatable {
    case on
    /// `until` nil: paused until they resume.
    case paused(until: Date?)
    /// Real-time sharing switched off in this circle. Wins over a pause.
    case off

    /// The roster's two fields. Anything missing or unrecognised — an older
    /// server, a value from a newer one — is `.on`, which changes nothing.
    init(wire: String?, pausedUntil: Date?) {
        switch wire {
        case "off": self = .off
        case "paused": self = .paused(until: pausedUntil)
        default: self = .on
        }
    }

    /// The rule the server applies to the roster, applied to the person's own
    /// privacy row, so their screen and everyone else's cannot disagree.
    init(settings: PrivacySettings) {
        if !settings.shareRealtime {
            self = .off
        } else if settings.sharingMode == "paused" {
            self = .paused(until: settings.pausedUntil)
        } else {
            self = .on
        }
    }

    /// The status as of `now`. A timed pause whose end has passed is `.on`: the
    /// server serves the member again from that instant and its next roster
    /// says so, so the label must not outlive the pause in the meantime.
    func at(_ now: Date) -> MemberSharingStatus {
        if case .paused(let until?) = self, until <= now { return .on }
        return self
    }

    /// Whether a member who is not sharing keeps a marker on the map. This is
    /// the one switch for it.
    static let keepsMarkerWhileNotSharing = false

    /// Whether the map draws this member, for a status already taken `at` now.
    var showsMarker: Bool {
        Self.keepsMarkerWhileNotSharing || self == .on
    }

    /// `sharing_paused_until` as the server sends it: written like the privacy
    /// route's `paused_until` (chrono `to_rfc3339()`: "+00:00", fractions only
    /// when the stored time has them), and read the way `privacySettings(from:)`
    /// reads that, with or without fractions, "Z" or an offset. It is decoded as
    /// text because the wire decoder's date strategy reads only the fractional
    /// form and throws on a whole second — on a `Date` field, the whole roster.
    /// Anything unreadable is a pause with no end.
    static func wireDate(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

extension CircleMember {
    /// Their sharing in this circle as of `now`.
    func sharing(at now: Date = Date()) -> MemberSharingStatus {
        MemberSharingStatus(wire: locationSharing, pausedUntil: sharingPausedUntil).at(now)
    }
}

/// The words for a member who is not sharing, shared with the Android app and
/// the web. Swift literals like the rest of the app; nil wherever the member is
/// sharing.
enum SharingStatusCopy {
    /// A member's row, in place of "Last seen".
    static func rowLine(_ status: MemberSharingStatus, now: Date = Date(),
                        calendar: Calendar = .current, locale: Locale = .current) -> String? {
        switch status.at(now) {
        case .on:
            return nil
        case .off:
            return "Location sharing off"
        case .paused(let until):
            guard let until else { return "Paused" }
            return "Paused until \(time(until, now: now, calendar: calendar, locale: locale))"
        }
    }

    /// A member's card on the map and their details screen.
    static func detailSentence(name: String, _ status: MemberSharingStatus, now: Date = Date(),
                               calendar: Calendar = .current, locale: Locale = .current) -> String? {
        switch status.at(now) {
        case .on:
            return nil
        case .off:
            return "\(name) turned off location sharing in this circle."
        case .paused(let until):
            guard let until else { return "\(name) paused location sharing." }
            return "\(name) paused location sharing until \(time(until, now: now, calendar: calendar, locale: locale))."
        }
    }

    /// A member whose location history the circle isn't shown: the history
    /// view opened for them, and their card.
    static func historyOffSentence(name: String) -> String {
        "\(name) doesn't share their location history in this circle."
    }

    /// The person's own circle screen: the truth, and what the others see.
    /// `historyOn`: whether their location history is shown to the circle.
    /// A pause says the pause, whatever the history.
    static func ownSentence(_ status: MemberSharingStatus, historyOn: Bool = true, now: Date = Date(),
                            calendar: Calendar = .current, locale: Locale = .current) -> String? {
        switch status.at(now) {
        case .on:
            return historyOn ? nil
                : "Location history is off in this circle. Members see only where you are now. "
                    + "Track still keeps your history, and they'll see all of it if you turn it back on."
        case .off:
            return historyOn
                ? "Location sharing is off in this circle. Members see your history up to then and may still see the last location you shared, with “Location sharing off” next to your name."
                : "Location sharing and location history are off in this circle. Members see “Location sharing off” next to your name, and none of your locations."
        case .paused(let until):
            guard let until else { return "Paused. Members see this next to your name." }
            return "Paused until \(time(until, now: now, calendar: calendar, locale: locale)). Members see this next to your name."
        }
    }

    /// `{time}`: the short time when the pause ends today ("5:00 PM"), else the
    /// short weekday and the time ("Tue 5:00 PM"), in the locale's own style —
    /// a 24-hour locale reads "Tue 17:00". "Today" is the viewer's.
    static func time(_ date: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(style.hour().minute())
        }
        return date.formatted(style.weekday(.abbreviated).hour().minute())
    }
}
