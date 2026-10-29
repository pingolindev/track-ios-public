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

/// The words of a notification once this device has put names to it. One copy
/// for the inbox (`NotificationsView`) and the notification extension
/// (`NamedBanner`), so a banner and its row never say different things.
/// Compiled into the app and the extension (project.yml); Foundation only.
///
/// The server writes every row and push with nobody in it — "Member arrived at
/// a place", "A circle member has checked in." — because it holds no names. It
/// writes ids at most; this device turns them into names from what it opens
/// itself (`NotificationNames`, `NamedBanner`), and only as far as the
/// "Notification detail" setting allows: generic keeps the server's words,
/// "Names only" never says where. An unknown person is "A member", an unknown
/// place "a place". Never "SOS": the feature asks a circle to check on someone.
/// The sentences are the Android app's (`NamedNotificationCopy`), apart from
/// a place alert, which reads like the one this app posts itself
/// (`PlaceAlertRules`: "Arrival" / "Sam arrived at Home").
enum NamedNotificationCopy {
    /// What this device resolved for one notification. `person` is whoever it
    /// is about (the crosser, the one checking in, the one who asked to be
    /// checked on, who is responding or closed it, the newcomer, the new owner,
    /// the claimant), as their sealed name opened here; nil when it did not.
    /// `place` and `circle` likewise.
    struct Names: Equatable {
        var person: String?
        /// The person is this account.
        var personIsMe = false
        var place: String?
        var circle: String?
        /// The person is who closed the alert (a "resolved" row with `closed_by`).
        var personClosed = false
        /// How many other people were already responding (a "someone is
        /// responding" row).
        var others = 0
    }

    static let someone = "Someone"

    static let aMember = "A member"
    static let aPlace = "a place"

    /// How much the "Notification detail" setting lets a notification name.
    enum Detail: Equatable {
        case generic, names, full

        /// `level` is the STORED raw value of `NotificationDetailLevel` —
        /// "full", "names" or "generic". Anything else, including nil, reads as
        /// full, which is what `UserSettings.notificationDetailLevel` does with
        /// an unset key.
        init(level: String?) {
            switch level {
            case "generic": self = .generic
            case "names": self = .names
            default: self = .full
            }
        }
    }

    /// The types whose rows this file names. Everything else keeps the
    /// server's words. Who responded (`acknowledged_by`) and who closed an
    /// alert (`closed_by`) are on the asker's rows.
    static let namedTypes: Set<String> = [
        "place_alert", "check_in", "sos_alert", "sos_acknowledged", "sos_resolved", "member_joined",
        "circle_ownership_claim", "circle_ownership_transferred", "privacy_resumed",
    ]

    /// A row's title and body with names, at `level`; nil keeps the server's
    /// words: generic, nothing resolved, or a type or wording this does not
    /// know. `title` and `body` are the row's own (the server's).
    static func row(type: String, title: String, body: String?, names: Names,
                    level: String?) -> (title: String, body: String?)? {
        let detail = Detail(level: level)
        guard detail != .generic, namedTypes.contains(type) else { return nil }
        let person = names.person.flatMap { $0.isEmpty ? nil : $0 }
        let place = detail == .full ? names.place.flatMap { $0.isEmpty ? nil : $0 } : nil
        let circle = detail == .full ? names.circle.flatMap { $0.isEmpty ? nil : $0 } : nil

        switch type {
        case "place_alert":
            guard person != nil || names.personIsMe || place != nil,
                  let arrival = placeAlertIsArrival(title: title) else { return nil }
            let who = names.personIsMe ? "You" : person ?? aMember
            let spot = place ?? aPlace
            if arrival { return ("Arrival", "\(who) arrived at \(spot)") }
            return ("Departure", "\(who) left \(spot)")
        case "check_in":
            // Nobody gets a row for their own check-in.
            guard !names.personIsMe, person != nil || place != nil,
                  let kind = checkInKind(body: body) else { return nil }
            let who = person ?? aMember
            let at = place.map { " at \($0)" } ?? ""
            switch kind {
            case .safeArrival: return (title, "\(who) has checked in safely\(at).")
            case .emergencyOK:
                guard person != nil else { return nil }
                return (title, "\(who) has confirmed they are OK.")
            case .general: return (title, "\(who) has checked in\(at).")
            }
        case "sos_alert":
            guard let person, !names.personIsMe else { return nil }
            let words = SOSAlarmCopy.alarm(name: person, circle: circle, level: level)
            return (words.title, words.body)
        case "sos_acknowledged":
            // Only the person who asked gets this row (they see who).
            guard !names.personIsMe, person != nil || names.others > 0 else { return nil }
            return (responding(person ?? someone, others: names.others),
                    person.map { "\($0) acknowledged your request to check on you" } ?? body)
        case "sos_resolved":
            if names.personClosed {
                // Who closed it; someone this device can't name is "Someone".
                if names.personIsMe { return (title, "You closed the alert") }
                return (title, "\(person ?? someone) closed the alert")
            }
            if names.personIsMe { return (title, "Your request to be checked on was marked resolved") }
            guard let person else { return nil }
            return (title, "\(person)'s request to be checked on was marked resolved")
        case "member_joined":
            guard let person, !names.personIsMe,
                  var joined = MemberJoinedCopy.body(member: person, circle: circle, level: level) else { return nil }
            // The server's second sentence stays: it is the part that matters.
            let history = "They can see its location history."
            if body?.contains(history) == true { joined += " " + history }
            return (title, joined)
        case "circle_ownership_transferred":
            if names.personIsMe {
                return (title, "You are now this circle's owner. "
                        + "The previous owner did not respond to a request to take it over.")
            }
            guard let person else { return nil }
            if body?.hasPrefix("You did not respond") == true {
                return (title, "You did not respond to the request, so this circle has been transferred to \(person).")
            }
            return (title, "\(person) is now this circle's owner. "
                    + "The previous owner did not respond to a request to take it over.")
        case "circle_ownership_claim":
            guard let person, !names.personIsMe else { return nil }
            return ("\(person) asked to take over your circle", body)
        case "privacy_resumed":
            // This account's own timed pause ended: the
            // server's sentence, with the circle it was in.
            guard let circle else { return nil }
            return (title, "Your location sharing pause in \(circle) has ended and sharing has automatically resumed.")
        default:
            return nil
        }
    }

    /// "{who} is responding", "{who} and 1 other are responding", "{who} and
    /// {n} others are responding".
    static func responding(_ who: String, others: Int) -> String {
        switch others {
        case ...0: return "\(who) is responding"
        case 1: return "\(who) and 1 other are responding"
        default: return "\(who) and \(others) others are responding"
        }
    }

    /// The asker's own live line: one name, that of the first
    /// responder (oldest first) whose name `nameOf` gives, and how many
    /// others; "Someone" when it gives none. nil when nobody is responding or
    /// the list wasn't served (an older server). `me` is never counted.
    static func responding(_ responders: [String]?, me: String?, nameOf: (String) -> String?) -> String? {
        guard let responders = responders?.filter({ !CanonicalId.same($0, me) }), !responders.isEmpty else {
            return nil
        }
        var name: String?
        for responder in responders {
            if let opened = nameOf(responder), !opened.isEmpty {
                name = opened
                break
            }
        }
        return responding(name ?? someone, others: responders.count - 1)
    }

    /// A place-alert row's direction, from the server's title ("Member arrived
    /// at a place" / "Member left a place"): the event type itself is sealed,
    /// and the server matched it by hash. nil for a title it does not write.
    static func placeAlertIsArrival(title: String) -> Bool? {
        let lowered = title.lowercased()
        if lowered.contains("arrived") { return true }
        if lowered.contains(" left") { return false }
        return nil
    }

    enum CheckInKind: Equatable {
        case general, safeArrival, emergencyOK
    }

    /// A check-in row's kind, read back from the server's sentence: the row
    /// carries no type. An older row's "A circle member checked in
    /// (emergency_ok)" too; nil for words it does not write.
    static func checkInKind(body: String?) -> CheckInKind? {
        guard let body = body?.lowercased(), body.contains("circle member") else { return nil }
        if body.contains("safely") || body.contains("safe_arrival") { return .safeArrival }
        if body.contains("they are ok") || body.contains("emergency_ok") { return .emergencyOK }
        if body.contains("checked in") { return .general }
        return nil
    }
}
