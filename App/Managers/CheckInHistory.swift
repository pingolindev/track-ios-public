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

/// Past check-ins in the Alerts history: those of the people the check-in
/// rules that can alert this account are about, merged by time with the alert
/// entries. Nobody else's (the check-in screens keep their own full lists).
///
/// Pure, so who is listed and in what order is tested without a network;
/// `CheckInManager.historyCheckIns` reads the check-ins and `AlertsView`
/// shows them.
enum CheckInHistory {

    // MARK: - Words

    /// One line under the history when a circle's check-ins couldn't be read:
    /// the alert entries are still shown.
    static let couldNotLoad = "Check-ins couldn't be loaded."

    // MARK: - How far back

    /// The last 30 days (the server keeps 90).
    static let depth: TimeInterval = 30 * 86_400
    /// The most pages of a circle's check-ins one read walks.
    static let maxPages = 5

    // MARK: - Whose

    /// One circle's people whose check-ins are listed.
    struct Watched: Equatable {
        var circleId: String
        /// Their ids in their one forms.
        var members: Set<String>
    }

    /// Whose check-ins the history lists, by circle (its id in its one form):
    /// the members the check-in rules that can alert this account are about,
    /// in those rules' circles.
    /// - this account's own check-in rules about others, on or off: that member
    ///   (`targets`: whom the rule watches, as `InactivityAlertsManager.watchSpec`
    ///   resolves it; nil when it can't);
    /// - its own check-in rules about itself: itself;
    /// - circle-mates' requests to be watched for check-ins: that member.
    /// Location rules add nobody.
    static func watched(rules: [InactivityAlertResponse], requests: [CircleSelfAlertResponse], selfId: String?,
                        targets: (InactivityAlertResponse) -> [String]?) -> [String: Watched] {
        var watched: [String: Watched] = [:]
        func add(_ circleId: String, _ userId: String) {
            let key = CanonicalId.key(circleId)
            watched[key, default: Watched(circleId: circleId, members: [])].members.insert(CanonicalId.key(userId))
        }
        func isMe(_ userId: String) -> Bool {
            selfId.map { CanonicalId.key($0) == CanonicalId.key(userId) } ?? false
        }
        for rule in rules where rule.watchKind == .checkIn {
            if rule.isSelfAlert {
                if let selfId { add(rule.circleId, selfId) }
            } else {
                for member in targets(rule) ?? [] where !isMe(member) {
                    add(rule.circleId, member)
                }
            }
        }
        for request in requests where request.watchKind == .checkIn && !isMe(request.userId) {
            add(request.circleId, request.userId)
        }
        return watched
    }

    // MARK: - What

    /// One past check-in, as the history lists it.
    struct Entry: Equatable, Identifiable {
        /// The check-in's own id.
        let id: String
        let circleId: String
        let userId: String
        /// Their name in the circle; nil when it is this account's own.
        let name: String?
        let type: CheckIn.CheckInType
        let at: Date

        var title: String { name.map { "\($0) checked in" } ?? "You checked in" }
        /// The check-in's type, unless it is the plain one.
        var typeLabel: String? { type == .general ? nil : type.displayName }
    }

    /// The check-ins listed, from those read: only the watched people's in
    /// their circles, once each. `name`: a member's name in the circle; one
    /// who isn't in it any more is left out (no rule can alert about them).
    static func entries(_ checkIns: [CheckIn], watched: [String: Watched], selfId: String?,
                        name: (_ circleId: String, _ userId: String) -> String?) -> [Entry] {
        var seen = Set<String>()
        var entries: [Entry] = []
        for checkIn in checkIns {
            let user = CanonicalId.key(checkIn.userId)
            guard let circle = watched[CanonicalId.key(checkIn.circleId)], circle.members.contains(user),
                  seen.insert(CanonicalId.key(checkIn.id)).inserted else { continue }
            let mine = selfId.map { CanonicalId.key($0) == user } ?? false
            let shown: String?
            if mine {
                shown = nil
            } else {
                guard let theirs = name(circle.circleId, checkIn.userId) else { continue }
                shown = theirs
            }
            entries.append(Entry(id: checkIn.id, circleId: circle.circleId, userId: checkIn.userId, name: shown,
                                 type: checkIn.type, at: checkIn.timestamp))
        }
        return entries
    }

    // MARK: - In order

    /// One row of the history.
    enum Item: Identifiable, Equatable {
        case lapse(LocalInactivityEvent)
        case battery(LocalBatteryEvent)
        case checkIn(Entry)

        var id: String {
            switch self {
            case .lapse(let event): return "l-\(event.id)"
            case .battery(let event): return "b-\(event.id)"
            case .checkIn(let entry): return "c-\(entry.id)"
            }
        }

        var at: Date {
            switch self {
            case .lapse(let event): return event.triggeredAt
            case .battery(let event): return event.triggeredAt
            case .checkIn(let entry): return entry.at
            }
        }
    }

    /// The alert entries and the check-ins in one list, newest first.
    static func merged(lapses: [LocalInactivityEvent], batteries: [LocalBatteryEvent],
                       checkIns: [Entry]) -> [Item] {
        (lapses.map(Item.lapse) + batteries.map(Item.battery) + checkIns.map(Item.checkIn))
            .sorted { $0.at != $1.at ? $0.at > $1.at : $0.id < $1.id }
    }
}
