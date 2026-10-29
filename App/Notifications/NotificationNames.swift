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

/// Who and where an inbox row is about, from this device's own data only.
/// `NamedNotificationCopy` has the words; these are the rules:
/// - The row says WHICH person and place — by id, or sealed by the sender (a
///   check-in's own `encrypted_user_id`) — never by name.
/// - A person is named only when this device shows them (`CircleManager.members`
///   holds exactly the members it confirmed) AND their sealed name opened here
///   (`CircleManager.openedNames`): the rule an alarm's raiser is named by
///   (`SOSManager.openedName`). Never the plaintext name the server sends for
///   older clients. A miss loads that circle's roster once per refresh
///   (`NotificationsManager`); still a miss — someone who left, or isn't
///   confirmed — stays "A member".
/// - A place only when this device holds it, opened. Nothing is fetched for one
///   it can't open.
enum NotificationNames {
    /// The ids a row is about. Names are looked up when the row is drawn, so a
    /// roster or a place that loads after the list names the row by itself.
    struct Subject: Equatable {
        var circleId: String
        var personId: String?
        var placeId: String?
        /// The person is who CLOSED the alert (`closed_by`), not who asked.
        var personClosed = false
        /// For a "someone is responding" row: the alert, and how many other
        /// people were already responding to it (`respondersBefore`).
        var alertId: String?
        var others = 0
    }

    /// What `row` is about, from its metadata. A check-in's sender is the id it
    /// sealed with the circle key (field tag "user_id"), opened by
    /// `openSealedUserId(circleId, nonce, ciphertext)`. Who asked to be checked
    /// on comes from `raisers` (by alert id), and who is asking to take a circle
    /// over from `claimants` (by claim id), both as this device opened or
    /// fetched them; keys in the one form (`CanonicalId`). nil for a type with
    /// nobody to name, or a row in no circle.
    static func subject(of row: NotificationResponse,
                        openSealedUserId: (_ circleId: String, _ nonce: String, _ ciphertext: String) -> String?,
                        raisers: [String: String] = [:], claimants: [String: String] = [:]) -> Subject? {
        guard NamedNotificationCopy.namedTypes.contains(row.notificationType),
              let circleId = CanonicalId.circle(row.circleId) else { return nil }
        let meta = strings(row.metadata)
        var subject = Subject(circleId: circleId)
        switch row.notificationType {
        case "place_alert":
            subject.personId = CanonicalId.of(meta["target_user_id"])
            subject.placeId = CanonicalId.of(meta["place_id"])
        case "check_in":
            if let sealed = meta["encrypted_user_id"], let nonce = meta["user_id_nonce"] {
                subject.personId = CanonicalId.of(openSealedUserId(circleId, nonce, sealed))
            }
            subject.placeId = CanonicalId.of(meta["place_id"])
        case "sos_alert":
            subject.personId = CanonicalId.of(meta["sos_id"]).flatMap { raisers[$0] }
        case "sos_resolved":
            // Who closed it, when the row says (the asker's own
            // row, when someone else closed it); every other row names only
            // the alert, and then who asked.
            if let closer = CanonicalId.of(meta["closed_by"]) {
                subject.personId = closer
                subject.personClosed = true
            } else {
                subject.personId = CanonicalId.of(meta["sos_id"]).flatMap { raisers[$0] }
            }
        case "sos_acknowledged":
            // Only the person who asked gets this row; it says who responded.
            subject.personId = CanonicalId.of(meta["acknowledged_by"])
            subject.alertId = CanonicalId.of(meta["sos_id"])
        case "member_joined":
            subject.personId = CanonicalId.of(meta["joined_user_id"])
        case "circle_ownership_transferred":
            subject.personId = CanonicalId.of(meta["new_owner_id"])
        case "circle_ownership_claim":
            subject.personId = CanonicalId.of(meta["claim_id"]).flatMap { claimants[$0] }
        case "privacy_resumed":
            break // only the circle
        default:
            return nil
        }
        return subject
    }

    /// For each "someone is responding" row, how many OTHER people were
    /// already responding to the same alert: distinct responders on that
    /// alert's earlier rows (by `createdAt`, then id). One row arrives per new
    /// responder, so the newest reads "Ana and 2 others are responding".
    /// Someone this device can't name still counts; the count names nobody.
    static func respondersBefore(_ subjects: [String: Subject],
                                 rows: [NotificationResponse]) -> [String: Subject] {
        var out = subjects
        let responses = rows.filter { $0.notificationType == "sos_acknowledged" && subjects[$0.id]?.alertId != nil }
            .map { (id: $0.id, at: $0.createdAt.flatMap(NotificationResponse.parseTimestamp) ?? .distantPast) }
            .sorted { ($0.at, $0.id) < ($1.at, $1.id) }
        var seen: [String: Set<String>] = [:]
        for row in responses {
            guard var subject = out[row.id], let alert = subject.alertId else { continue }
            let before = seen[alert, default: []]
            subject.others = before.subtracting([subject.personId ?? ""]).count
            out[row.id] = subject
            if let person = subject.personId { seen[alert, default: []].insert(person) }
        }
        return out
    }

    /// The names for `subject` from what this device holds now: `members` and
    /// `opened` as `CircleManager` keeps them (by circle id in its one form),
    /// `places` as `PlaceManager` does, and the circle's readable name.
    static func names(for subject: Subject, me: String?, members: [String: [CircleMember]],
                      opened: [String: Set<String>], places: [Place],
                      circleName: String?) -> NamedNotificationCopy.Names {
        var names = NamedNotificationCopy.Names()
        if let person = subject.personId {
            if CanonicalId.same(person, me) {
                names.personIsMe = true
            } else {
                names.person = SOSManager.openedName(of: person, in: members[subject.circleId],
                                                     opened: opened[subject.circleId])
            }
        }
        names.place = subject.placeId.flatMap { id in
            places.first { CanonicalId.same($0.id, id) }?.name
        }.flatMap { $0.isEmpty || $0 == Place.unopenedName ? nil : $0 }
        names.circle = circleName
        names.personClosed = subject.personClosed
        names.others = subject.others
        return names
    }

    /// Whether `subject` names someone this device does not name yet: a
    /// person other than this account, missing from the circle's shown roster
    /// or without an opened name. Those are what one roster load may fix.
    static func misses(_ subject: Subject, me: String?, members: [String: [CircleMember]],
                       opened: [String: Set<String>]) -> Bool {
        guard let person = subject.personId, !CanonicalId.same(person, me) else { return false }
        return SOSManager.openedName(of: person, in: members[subject.circleId], opened: opened[subject.circleId]) == nil
    }

    /// The row's metadata as strings: the values these rules read are all
    /// strings on the wire (ids and hex).
    static func strings(_ metadata: [String: AnyCodableValue]?) -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in metadata ?? [:] {
            if case .string(let text) = value, !text.isEmpty { out[key] = text }
        }
        return out
    }
}
