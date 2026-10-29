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
import UIKit
import UserNotifications

/// The two questions only a person can answer — "Is this really {name}?" (a
/// member reset their password) and "Let {name} into {circle}?" (an owner's or
/// admin's device, about a member it cannot confirm) — would otherwise wait for
/// someone to open the app, so the app says so with a local notification (the
/// same words as the Android app): at most once a day per circle, member and
/// question; never while the app is in front (the question is on screen then);
/// a tap opens Circles, where the question shows with the member's number; an
/// answer takes the notification away.
enum CircleQuestion: String {
    case reset
    case join
    /// "Is this really {email}?" about an invitation whose invitee reset their
    /// password: `name` is the email the invitation went to.
    case invitee
}

/// The words, per detail level — the same setting as every other banner.
enum CircleQuestionCopy {
    /// `level` is the STORED raw value of `NotificationDetailLevel`; anything
    /// else, including nil, reads as full.
    static func body(_ question: CircleQuestion, name: String?, circle: String?, level: String?) -> String {
        let name = name.flatMap { $0.isEmpty ? nil : $0 }
        let circle = circle.flatMap { $0.isEmpty ? nil : $0 }
        if level == "generic" { return "A circle needs your answer." }
        switch question {
        case .reset:
            return "\(name ?? "A member") reset their password. Check it's really them."
        case .invitee:
            // An address is identifying, so the "names" level keeps it too:
            // the invitation went to it.
            return "\(name ?? "Someone you invited") reset their password. Check it's really them."
        case .join:
            let who = name ?? "A new member"
            if level == "names" { return "\(who) is waiting to join a circle." }
            return circle.map { "\(who) is waiting to join \($0)." } ?? "\(who) is waiting to join a circle."
        }
    }
}

@MainActor
enum CircleQuestionNotifier {
    static let alertType = "circle_question"
    static let interval: TimeInterval = 24 * 60 * 60
    /// Per account (`AccountKeyedDefaults`): another account signing in here,
    /// or an erasure, takes it.
    private static func postedKey(owner: String) -> String { "circleQuestion.notifiedAt.\(owner.lowercased())" }

    static func identifier(_ question: CircleQuestion, circleId: String, userId: String) -> String {
        "circle-question:\(question.rawValue):\(circleId):\(userId)"
    }

    /// Whether to post now: not while the app is in front, and not twice in a
    /// day for the same question about the same member in the same circle.
    /// Records the post when it says yes.
    static func shouldPost(_ question: CircleQuestion, circleId: String, userId: String, appActive: Bool,
                           owner: String, now: Date = Date(), defaults: UserDefaults = .standard) -> Bool {
        guard !appActive else { return false }
        let key = identifier(question, circleId: circleId, userId: userId.lowercased())
        var posted = (defaults.dictionary(forKey: postedKey(owner: owner)) as? [String: Double] ?? [:])
            .filter { now.timeIntervalSince1970 - $0.value < interval }
        if posted[key] != nil { return false }
        posted[key] = now.timeIntervalSince1970
        defaults.set(posted, forKey: postedKey(owner: owner))
        return true
    }

    /// Posts the question's notification, when `shouldPost` says to.
    static func post(_ question: CircleQuestion, circleId: String, userId: String, name: String?, circleName: String?) {
        guard let owner = AuthManager.shared.userId,
              shouldPost(question, circleId: circleId, userId: userId,
                         appActive: UIApplication.shared.applicationState == .active, owner: owner) else { return }
        let content = UNMutableNotificationContent()
        content.body = CircleQuestionCopy.body(question, name: name, circle: circleName,
                                               level: UserSettings.shared.notificationDetailLevel.rawValue)
        content.sound = .default
        content.userInfo = ["alert_type": alertType, "question": question.rawValue,
                            "circle_id": circleId, "member_id": userId]
        let request = UNNotificationRequest(
            identifier: identifier(question, circleId: circleId, userId: userId), content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// The question was answered: its notification goes.
    static func answered(_ question: CircleQuestion, circleId: String, userId: String) {
        let id = identifier(question, circleId: circleId, userId: userId)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
    }
}
