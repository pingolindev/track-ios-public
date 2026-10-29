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

/// What the app does with the SOS notices this phone has shown, once a load of
/// the open alerts has worked, never after one that failed: the extension
/// can't drop a notification, and it may have shown one before this phone
/// could tell.
///
/// - An SOS that alarms now rings ONCE on this phone, as on Android: one that
///   hasn't rung here (no "rang" mark, no alarm of the extension's shown, no
///   server banner of it shown, not handled by this person) gets the real
///   alarm with sound, in place of what is shown of it (a quiet notice) or, on
///   a quiet refresh, as a new post (the person swiped the quiet notice away).
///   The server's own banner, shown when the extension couldn't check, rang
///   already: the real alarm replaces it silently (as Android's `ringOnce`).
///   Otherwise what is shown is re-worded in place, silently, with the names
///   this app shows, or left as it is.
/// - One this phone can't check: what is shown stays as it is, and nothing rings.
/// - Anything else (listed quietly, hidden, or not listed at all any more):
///   every notice for it goes, and nothing rings.
enum SOSNotices {
    /// A delivered notification about a new SOS.
    struct Delivered: Equatable {
        let identifier: String
        let alertType: String
        let alertId: String
        /// `SOSAlarmCopy.quietNotice` or `.alarmNotice`; nil for the server's own banner.
        let kind: String?
        let title: String
        let body: String
    }

    /// A notice posted for an SOS: in place of a delivered one (its identifier),
    /// or a new one (`identifier(alertId:)`).
    struct Post: Equatable {
        let identifier: String
        let alertType: String
        let alertId: String
        let title: String
        let body: String
        /// Rings: the first alarm for this SOS on this phone. Its "rang" mark is
        /// set once the post is made (`post`).
        let sound: Bool
    }

    struct Plan: Equatable {
        var remove: [String] = []
        var post: [Post] = []
    }

    /// The identifier of an alarm the app posts for an SOS it shows nothing of.
    static func identifier(alertId: String) -> String { "sos-alarm-" + CanonicalId.key(alertId) }

    /// One delivered notification, when it is about a new SOS.
    static func delivered(_ notification: UNNotification) -> Delivered? {
        let content = notification.request.content
        let info = content.userInfo
        guard let type = info["alert_type"] as? String, SOSAlarmCopy.newAlertTypes.contains(type),
              let alertId = info["alert_id"] as? String else { return nil }
        return Delivered(identifier: notification.request.identifier, alertType: type, alertId: alertId,
                         kind: info[SOSAlarmCopy.noticeKey] as? String, title: content.title, body: content.body)
    }

    /// Pure, for tests. `verdicts` by the SOS's key (`CanonicalId.key`), for
    /// every SOS the load listed; `names`: the raiser and the circle this app
    /// shows, for each that alarms; `rang`: the SOSes that rang on this phone
    /// already or that this person has handled (acknowledged or dismissed);
    /// `newPosts`: a quiet refresh, which posts the alarm of an SOS that shows
    /// nothing here (a load a push started never does: the extension is showing
    /// that push).
    static func plan(delivered: [Delivered], verdicts: [String: SOSReceiverRules.Verdict],
                     names: [String: (name: String?, circle: String?)], level: String?,
                     rang: Set<String>, newPosts: Bool) -> Plan {
        var plan = Plan()
        // An alarm of the extension's that is shown rang when it was shown, or
        // was shown silently because this SOS had rung; so did the server's own
        // banner of it (no kind), shown when the extension couldn't check.
        var rung = rang.union(delivered.filter { $0.kind == SOSAlarmCopy.alarmNotice || $0.kind == nil }
            .map { CanonicalId.key($0.alertId) })
        var shown = Set<String>()
        for notice in delivered {
            let key = CanonicalId.key(notice.alertId)
            switch verdicts[key] {
            case .cantCheck?:
                continue
            case .alarming?:
                shown.insert(key)
                let words = SOSAlarmCopy.alarm(name: names[key]?.name, circle: names[key]?.circle, level: level)
                let rings = !rung.contains(key)
                guard rings || notice.kind != SOSAlarmCopy.alarmNotice
                        || words.title != notice.title || words.body != notice.body else { continue }
                if rings { rung.insert(key) }
                plan.post.append(Post(identifier: notice.identifier, alertType: notice.alertType, alertId: notice.alertId,
                                      title: words.title, body: words.body, sound: rings))
            default:
                plan.remove.append(notice.identifier)
            }
        }
        guard newPosts else { return plan }
        for (key, verdict) in verdicts.sorted(by: { $0.key < $1.key })
        where verdict == .alarming && !shown.contains(key) && !rung.contains(key) {
            let words = SOSAlarmCopy.alarm(name: names[key]?.name, circle: names[key]?.circle, level: level)
            plan.post.append(Post(identifier: identifier(alertId: key), alertType: "sos", alertId: key,
                                  title: words.title, body: words.body, sound: true))
        }
        return plan
    }

    /// Makes the plan's posts in order. A post that rings marks its SOS "rang"
    /// (`rang`) once iOS has taken it, never before: a mark without a post would
    /// leave a genuine SOS that never rang. A post iOS refuses marks nothing, and
    /// the next pass tries again.
    @MainActor
    static func post(_ plan: Plan, add: (UNNotificationRequest) async throws -> Void,
                     rang: (Post) -> Void) async {
        for post in plan.post {
            do {
                try await add(UNNotificationRequest(identifier: post.identifier, content: content(post), trigger: nil))
            } catch {
                continue
            }
            if post.sound { rang(post) }
        }
    }

    /// The content of one post.
    static func content(_ post: Post) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = post.title
        content.body = post.body
        content.sound = post.sound ? .default : nil
        content.interruptionLevel = .active
        content.userInfo = ["alert_type": post.alertType, "alert_id": post.alertId,
                            SOSAlarmCopy.noticeKey: SOSAlarmCopy.alarmNotice]
        return content
    }
}
