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
import PingolinTrackSDK
@testable import Track

/// Past check-ins in the Alerts history (`CheckInHistory`): those of the
/// people the check-in rules that can alert this account are about, and
/// nobody else's, merged by time with the alert entries, newest first. Who is
/// listed, what a row says, the order, the read behind it (rows sealed for
/// real: the last 30 days, rows that don't open skipped), and the screen.
@MainActor
final class CheckInHistoryTests: XCTestCase {

    private let circle = "3f7a1b2c-0000-4000-8000-0123456789ab"
    private let other = "3f7a1b2c-0000-4000-8000-0123456789ac"
    private let me = "a0000000-0000-4000-8000-000000000001"
    private let ana = "a0000000-0000-4000-8000-000000000002"
    private let ben = "a0000000-0000-4000-8000-000000000003"
    private let cat = "a0000000-0000-4000-8000-000000000004"
    private let dan = "a0000000-0000-4000-8000-000000000005"
    private let eve = "a0000000-0000-4000-8000-000000000006"
    /// 2027-01-15 08:00 UTC.
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func hours(_ h: Double) -> Date { t0.addingTimeInterval(h * 3600) }

    // MARK: - Fixtures

    /// One of this account's rules, as the list serves it; `id` names whom it
    /// watches in the tests' `targets`.
    private func rule(_ id: String, circle: String? = nil, active: Bool = true, aboutMe: Bool = false,
                      watches: String? = "check_in") throws -> InactivityAlertResponse {
        var json = "{\"id\":\"\(id)\",\"user_id\":\"\(me)\",\"circle_id\":\"\(circle ?? self.circle)\","
            + "\"encrypted_target_user_id\":{\"nonce\":\"nn\",\"ciphertext\":\"cc\"},\"timeout_hours\":6,"
            + "\"is_self_alert\":\(aboutMe),\"notify_push\":true,\"notify_email\":false,\"cooldown_minutes\":60,"
            + "\"is_active\":\(active),\"day_bucket\":20800,\"armed_at\":\"2027-01-14T20:00:00Z\""
        if let watches { json += ",\"watches\":\"\(watches)\"" }
        return try APIService.makeWireDecoder().decode(InactivityAlertResponse.self, from: Data((json + "}").utf8))
    }

    private func request(_ id: String, from userId: String, circle: String? = nil,
                         watches: String = "check_in") throws -> CircleSelfAlertResponse {
        let json = "{\"id\":\"\(id)\",\"user_id\":\"\(userId)\",\"circle_id\":\"\(circle ?? self.circle)\","
            + "\"timeout_hours\":3,\"notify_on_return\":false,\"watches\":\"\(watches)\"}"
        return try APIService.makeWireDecoder().decode(CircleSelfAlertResponse.self, from: Data(json.utf8))
    }

    private func checkIn(_ id: String, _ userId: String, circle: String? = nil, at date: Date,
                         type: CheckIn.CheckInType = .general) -> CheckIn {
        CheckIn(id: id, circleId: circle ?? self.circle, userId: userId, type: type, message: nil, latitude: nil,
                longitude: nil, placeId: nil, timestamp: date, isSynced: true)
    }

    // MARK: - Whose

    func testOnlyThePeopleTheCheckInRulesThatCanAlertMeAreAboutAreListed() throws {
        let targets: [String: [String]] = ["r-ana": [ana], "r-ben": [ben], "r-cat": [cat], "r-two": [ana, dan]]
        let watched = CheckInHistory.watched(
            rules: [
                try rule("r-ana"),                                  // about Ana
                try rule("r-ben", active: false),                   // about Ben, turned off: still listed
                try rule("r-cat", watches: "location"),             // about Cat, but location: no
                try rule("r-me", aboutMe: true),                    // about me: "You checked in"
                try rule("r-me-loc", circle: other, aboutMe: true, watches: "location"),
                try rule("r-gone"),                                 // whom it watches doesn't open: nobody
                try rule("r-new", watches: "something_new"),        // a kind this version doesn't know: nobody
            ],
            requests: [
                try request("q-dan", from: dan, circle: other),     // Dan asked to be watched for check-ins
                try request("q-eve", from: eve, watches: "location"),
                try request("q-me", from: me.uppercased()),         // never this account through a request
            ],
            selfId: me,
            targets: { targets[$0.id] })
        XCTAssertEqual(watched[CanonicalId.key(circle)]?.members, [CanonicalId.key(ana), CanonicalId.key(ben), CanonicalId.key(me)])
        XCTAssertEqual(watched[CanonicalId.key(other)]?.members, [CanonicalId.key(dan)])
        XCTAssertEqual(watched.count, 2)
    }

    func testARuleAboutSeveralListsEachAndCirclesMeetInTheirOneForm() throws {
        let watched = CheckInHistory.watched(
            rules: [try rule("r-two"), try rule("r-ana-again", circle: circle.uppercased())],
            requests: [], selfId: me,
            targets: { $0.id == "r-two" ? [ana, dan, me] : [ana.uppercased()] })
        XCTAssertEqual(watched.count, 1)
        XCTAssertEqual(watched[CanonicalId.key(circle)]?.members, [CanonicalId.key(ana), CanonicalId.key(dan)],
                       "a rule for everyone lists the roster, never this account through it")
    }

    // MARK: - What

    func testEachWatchedCheckInIsARowAndNobodyElsesIs() throws {
        let watched = [
            CanonicalId.key(circle): CheckInHistory.Watched(circleId: circle, members: [CanonicalId.key(ana), CanonicalId.key(me),
                                                                                       CanonicalId.key(ben)]),
        ]
        let names = [CanonicalId.key(ana): "Ana"]
        let entries = CheckInHistory.entries([
            checkIn("k1", ana, at: hours(-1), type: .safeArrival),
            checkIn("k2", me.uppercased(), at: hours(-2)),
            checkIn("k3", ana, circle: other, at: hours(-3)),       // Ana, but not watched in that circle
            checkIn("k4", cat, at: hours(-4)),                      // not watched at all
            checkIn("k5", ben, at: hours(-5)),                      // watched, but not in the circle any more
            checkIn("k1", ana, at: hours(-1), type: .safeArrival),  // the same row twice
            checkIn("k6", ana, at: hours(-6), type: .emergencyOk),
        ], watched: watched, selfId: me) { _, userId in names[CanonicalId.key(userId)] }

        XCTAssertEqual(entries.map(\.id), ["k1", "k2", "k6"])
        XCTAssertEqual(entries.map(\.title), ["Ana checked in", "You checked in", "Ana checked in"])
        XCTAssertEqual(entries.map(\.typeLabel), ["Safe Arrival", nil, "All Clear"], "the type unless it is the plain one")
        XCTAssertEqual(entries.first?.circleId, circle)
        XCTAssertEqual(entries.first?.at, hours(-1))
    }

    // MARK: - In order

    func testTheHistoryIsOneListNewestFirst() {
        let lapse = LocalInactivityEvent(id: "local-l", ruleId: "r", circleId: circle, userId: ana, memberName: "Ana",
                                         triggeredAt: hours(-2), resolvedAt: nil, isRead: false,
                                         watches: "check_in", lapseSince: hours(-8), timeoutHours: 6)
        let battery = LocalBatteryEvent(id: "local-b", ruleId: "r2", circleId: circle, userId: ben, memberName: "Ben",
                                        batteryLevel: 9, triggeredAt: hours(-4), resolvedAt: nil, isRead: false)
        let checkIns = [
            CheckInHistory.Entry(id: "k1", circleId: circle, userId: ana, name: "Ana", type: .general, at: hours(-1)),
            CheckInHistory.Entry(id: "k2", circleId: circle, userId: ana, name: "Ana", type: .general, at: hours(-3)),
            CheckInHistory.Entry(id: "k0", circleId: circle, userId: ben, name: "Ben", type: .general, at: hours(-4)),
        ]
        let merged = CheckInHistory.merged(lapses: [lapse], batteries: [battery], checkIns: checkIns)
        XCTAssertEqual(merged.map(\.id), ["c-k1", "l-local-l", "c-k2", "b-local-b", "c-k0"],
                       "by time, the alert entries among the check-ins; a tie in a fixed order")
        XCTAssertEqual(CheckInHistory.merged(lapses: [lapse], batteries: [battery], checkIns: []).map(\.id),
                       ["l-local-l", "b-local-b"], "check-ins that couldn't be read: the alert entries as before")
    }

    // MARK: - The read, sealed for real

    private func sealer() throws -> CryptoManager {
        let crypto = CryptoManager()
        _ = crypto.generateKeypair()
        _ = crypto.generateSigningKeypair()
        let creation = try crypto.prepareCircleCreation()
        try crypto.finalizeCircleCreation(tempCircleId: creation.tempCircleId, realCircleId: circle)
        return crypto
    }

    /// A check-in row as the server serves it; a nil sender or time doesn't open.
    private func row(_ id: String, by crypto: CryptoManager, sender: String?, at time: Date?, day: Int) throws -> CheckInResponse {
        func sealed(_ text: String?, _ fieldTag: String) throws -> [String: String] {
            guard let text else { return ["nonce": "00", "ciphertext": "00"] }
            let blob = try crypto.encryptDataV2(circleId: circle, plaintext: text, fieldTag: fieldTag)
            return ["nonce": blob.nonce, "ciphertext": blob.ciphertext]
        }
        let json: [String: Any] = [
            "id": id, "circle_id": circle, "check_in_type": "general", "day_bucket": day,
            "encrypted_user_id": try sealed(sender, "user_id"),
            "encrypted_device_id": ["nonce": "00", "ciphertext": "00"],
            "encrypted_timestamp": try sealed(time.map { String(Int64(($0.timeIntervalSince1970 * 1000).rounded())) },
                                              "timestamp"),
        ]
        return try APIService.makeWireDecoder().decode(CheckInResponse.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func read(_ crypto: CryptoManager, pages: [[CheckInResponse]]) async throws -> ([CheckIn], Int) {
        var fetches = 0
        let found = try await CheckInManager.readHistoryCheckIns(circleId: circle, now: t0, crypto: crypto) { _, _ in
            fetches += 1
            return pages[min(fetches, pages.count) - 1]
        }
        return (found, fetches)
    }

    func testTheReadSkipsWhatDoesNotOpenAndKeepsTheLastThirtyDays() async throws {
        let crypto = try sealer()
        let today = CheckInCountdown.dayBucket(t0)
        let skew = TimeInterval(CircleManager.maxFutureSkewMs) / 1000
        let (found, fetches) = try await read(crypto, pages: [[
            try row("k-ana", by: crypto, sender: ana, at: hours(-1), day: today),
            try row("k-no-time", by: crypto, sender: ben, at: nil, day: today),
            try row("k-no-sender", by: crypto, sender: nil, at: hours(-2), day: today),
            try row("k-far", by: crypto, sender: ana, at: t0.addingTimeInterval(skew + 60), day: today),
            try row("k-old", by: crypto, sender: ana, at: hours(-31 * 24), day: today - 31),
        ]])
        XCTAssertEqual(found.map(\.id), ["k-ana"],
                       "what doesn't open is skipped, not a failure; nothing older than 30 days, nothing from the future")
        XCTAssertEqual(found.first?.userId, ana)
        XCTAssertEqual(found.first?.timestamp, hours(-1))
        XCTAssertEqual(fetches, 1, "a short page is the last")
    }

    func testTheReadStopsAtThirtyDaysOrFivePagesAndFailsWhenAPageDoes() async throws {
        let crypto = try sealer()
        let today = CheckInCountdown.dayBucket(t0)
        let full = try (0..<CheckInAlerts.pageSize).map { try row("k-\($0)", by: crypto, sender: ana, at: hours(-1), day: today) }
        let (five, fetches) = try await read(crypto, pages: [full])
        XCTAssertEqual(fetches, CheckInHistory.maxPages, "full pages inside the 30 days: five, then it stops")
        XCTAssertEqual(five.count, 5 * CheckInAlerts.pageSize)

        let floor = CheckInCountdown.dayBucket(t0.addingTimeInterval(-CheckInHistory.depth))
        let reachingBack = try (0..<CheckInAlerts.pageSize).map {
            try row("j-\($0)", by: crypto, sender: ana, at: hours(-1), day: $0 < 99 ? today : floor - 1)
        }
        let (_, onePage) = try await read(crypto, pages: [reachingBack, full])
        XCTAssertEqual(onePage, 1, "a page that reaches past 30 days is the last")

        struct PageDidNotCome: Error {}
        do {
            _ = try await CheckInManager.readHistoryCheckIns(circleId: circle, now: t0, crypto: crypto) { _, _ in
                throw PageDidNotCome()
            }
            XCTFail("a page that didn't come fails the read")
        } catch is PageDidNotCome {
        }
    }

    // MARK: - The words and the screen

    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    private func body(of function: String, in text: String) throws -> String {
        let start = try XCTUnwrap(text.range(of: function), function)
        let end = try XCTUnwrap(text.range(of: "\n    }\n", range: start.upperBound..<text.endIndex), function)
        return String(text[start.upperBound..<end.lowerBound])
    }

    func testTheWords() {
        XCTAssertEqual(CheckInHistory.couldNotLoad, "Check-ins couldn't be loaded.")
        XCTAssertEqual(CheckInHistory.depth, 30 * 86_400)
        XCTAssertEqual(CheckInHistory.maxPages, 5)
    }

    func testTheAlertsScreenListsThemAndSaysWhenTheyCouldNotBeRead() throws {
        let alerts = try source("App/Views/Alerts/AlertsView.swift")
        let refresh = try body(of: "private func refreshAll() async {", in: alerts)
        XCTAssertTrue(refresh.contains("let past = await checkInManager.historyCheckIns(rules: inactivityManager.alerts)"),
                      "from the server as it opens and on its refresh")
        XCTAssertTrue(refresh.contains("checkInHistory = past.entries"))
        XCTAssertTrue(refresh.contains("checkInHistoryComplete = past.complete"))
        XCTAssertTrue(alerts.contains(
            "CheckInHistory.merged(lapses: localStore.events, batteries: localBatteryStore.events, checkIns: checkInHistory)"))
        XCTAssertTrue(alerts.contains("""
                                if !checkInHistoryComplete {
                                    Text(CheckInHistory.couldNotLoad)
            """), "the alert entries stay, with one line")
        XCTAssertTrue(alerts.contains("case .checkIn(let entry): checkInRow(entry)"))
        XCTAssertTrue(alerts.contains("Image(systemName: entry.type.icon)"), "the check-in screens' own mark")
        XCTAssertTrue(alerts.contains(".fill(entry.type.tint.opacity(0.15))"), "and colour")
        XCTAssertTrue(try source("App/Views/CheckIns/CheckInHistoryView.swift").contains(".fill(row.type.tint.opacity(0.15))"))
        XCTAssertTrue(alerts.contains("(event.isMissedCheckIn && resolved ? \" · \\(CheckInAlerts.endedMark)\" : \"\")"),
                      "a missed check-in that has ended is marked so, keeping its words")
        XCTAssertFalse(try source("App/Managers/CheckInAlerts.swift").contains("checkedInLine"),
                       "the entry's words are no longer swapped for \"{name} checked in\"")
    }
}
