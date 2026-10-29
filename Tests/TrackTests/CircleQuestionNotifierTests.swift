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

import XCTest
@testable import Track

/// The two questions only a person can answer don't wait for someone to
/// open the app. Same words as the Android app.
@MainActor
final class CircleQuestionNotifierTests: XCTestCase {

    func testTheWordsAtEachDetailLevel() {
        XCTAssertEqual(CircleQuestionCopy.body(.reset, name: "Nadia", circle: "Family", level: "full"),
                       "Nadia reset their password. Check it's really them.")
        XCTAssertEqual(CircleQuestionCopy.body(.join, name: "Nadia", circle: "Family", level: "full"),
                       "Nadia is waiting to join Family.")
        XCTAssertEqual(CircleQuestionCopy.body(.join, name: "Nadia", circle: "Family", level: nil),
                       "Nadia is waiting to join Family.")
        XCTAssertEqual(CircleQuestionCopy.body(.join, name: "Nadia", circle: "Family", level: "names"),
                       "Nadia is waiting to join a circle.", "names only: the circle's name goes")
        XCTAssertEqual(CircleQuestionCopy.body(.reset, name: "Nadia", circle: nil, level: "names"),
                       "Nadia reset their password. Check it's really them.")
        for question in [CircleQuestion.reset, .join] {
            XCTAssertEqual(CircleQuestionCopy.body(question, name: "Nadia", circle: "Family", level: "generic"),
                           "A circle needs your answer.")
        }
        XCTAssertEqual(CircleQuestionCopy.body(.join, name: nil, circle: "Family", level: "full"),
                       "A new member is waiting to join Family.")
        XCTAssertEqual(CircleQuestionCopy.body(.reset, name: "", circle: nil, level: "full"),
                       "A member reset their password. Check it's really them.")
        for question in [CircleQuestion.reset, .join] {
            let body = CircleQuestionCopy.body(question, name: "Nadia", circle: "Family", level: "full")
            XCTAssertNil(body.range(of: "key", options: .caseInsensitive), "no key talk: \(body)")
        }
    }

    /// Never while the app is in front (the question is on screen), and at
    /// most once a day per circle, member and question.
    func testAtMostOnceADayAndNeverWhileTheAppIsInFront() throws {
        let suite = "CircleQuestionNotifierTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let now = Date()
        func post(_ q: CircleQuestion, _ circle: String, _ user: String, active: Bool = false, at: Date = now) -> Bool {
            CircleQuestionNotifier.shouldPost(q, circleId: circle, userId: user, appActive: active, owner: "me", now: at,
                                              defaults: defaults)
        }
        XCTAssertFalse(post(.reset, "c1", "u1", active: true), "on screen already")
        XCTAssertTrue(post(.reset, "c1", "u1"))
        XCTAssertFalse(post(.reset, "c1", "U1"), "the same member, the same day")
        XCTAssertTrue(post(.join, "c1", "u1"), "another question")
        XCTAssertTrue(post(.reset, "c2", "u1"), "another circle")
        XCTAssertTrue(post(.reset, "c1", "u2"), "another member")
        XCTAssertTrue(post(.reset, "c1", "u1", at: now.addingTimeInterval(24 * 60 * 60 + 1)), "a day later")
        XCTAssertTrue(CircleQuestionNotifier.shouldPost(.join, circleId: "c1", userId: "u1", appActive: false,
                                                        owner: "another", now: now, defaults: defaults),
                      "per account: another account's marks are its own")
    }

    /// Raised → posted; answered either way → gone; a tap opens Circles and asks
    /// it again at once (source).
    func testRaisedAnsweredAndTapped() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func source(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }
        let pinner = try source("App/Managers/MemberKeyPinner.swift")
        XCTAssertTrue(pinner.contains("CircleQuestionNotifier.post(.reset, circleId: alert.circleId, userId: alert.userId,"))
        XCTAssertEqual(pinner.components(separatedBy: "CircleQuestionNotifier.answered(.reset,").count - 1, 3,
                       "It's them, Not now, and a receive-only answer")
        let approvals = try source("App/Managers/KeyDeliveryApprovals.swift")
        XCTAssertTrue(approvals.contains("CircleQuestionNotifier.post(.join, circleId: request.circleId, userId: request.userId,"))
        XCTAssertEqual(approvals.components(separatedBy: "CircleQuestionNotifier.answered(.join,").count - 1, 4,
                       "Let them in, the answer kept as a waiting change, Not now, and a Let them in "
                       + "whose keys moved (asked again)")
        let push = try source("App/Managers/PushNotificationManager.swift")
        XCTAssertTrue(push.contains("if alertType == CircleQuestionNotifier.alertType,"))
        XCTAssertTrue(push.contains("MemberKeyPinner.shared.askAgainNow(userId: memberId)"))
        XCTAssertTrue(push.contains("try? await CircleManager.shared.loadMembers(for: circleId)"))
    }
}
