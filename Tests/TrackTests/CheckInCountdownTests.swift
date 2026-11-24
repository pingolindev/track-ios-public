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

import SwiftUI
import XCTest
import PingolinTrackSDK
@testable import Track

/// The countdown on this account's own check-in rule ("Alert about me" on a
/// check-in rule): "Your circle is alerted in 3 h 12 min", or once due "Your
/// circle was alerted at 9:40 PM. Check in to clear it." A one-time rule counts
/// from its arming and ends at my first check-in after it that the server has
/// (never one still waiting on this phone), as the circle's phones judge it.
/// The words, the deadline, the read behind it (rows sealed for real), the
/// line as VoiceOver reads it, and the wiring into the two screens. (A
/// scheduled rule's lines: `CheckInScheduleTests`.)
@MainActor
final class CheckInCountdownTests: XCTestCase {

    private let circle = "3f7a1b2c-0000-4000-8000-0123456789ab"
    private let other = "3f7a1b2c-0000-4000-8000-0123456789ac"
    private let me = "a0000000-0000-4000-8000-000000000001"
    private let ana = "a0000000-0000-4000-8000-000000000002"
    /// 2027-01-15 08:00 UTC.
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func hours(_ h: Double) -> Date { t0.addingTimeInterval(h * 3600) }

    // MARK: - Words

    func testTheTimeLeftIsInWholeMinutesAndNeverMoreThanIsLeft() {
        XCTAssertEqual(CheckInCountdown.duration(0), "less than a minute")
        XCTAssertEqual(CheckInCountdown.duration(59.9), "less than a minute")
        XCTAssertEqual(CheckInCountdown.duration(60), "1 min")
        XCTAssertEqual(CheckInCountdown.duration(45 * 60 + 59), "45 min")
        XCTAssertEqual(CheckInCountdown.duration(59 * 60 + 59), "59 min")
        XCTAssertEqual(CheckInCountdown.duration(3600), "1 h", "on the hour: hours alone")
        XCTAssertEqual(CheckInCountdown.duration(3600 + 59), "1 h")
        XCTAssertEqual(CheckInCountdown.duration(3600 + 60), "1 h 1 min")
        XCTAssertEqual(CheckInCountdown.duration(3 * 3600 + 12 * 60 + 59), "3 h 12 min")
        XCTAssertEqual(CheckInCountdown.duration(12 * 3600 + 30), "12 h")
        XCTAssertEqual(CheckInCountdown.duration(24 * 3600), "24 h")
        XCTAssertEqual(CheckInCountdown.duration(-5), "less than a minute")
    }

    private func line(_ deadline: Date, _ now: Date) -> String {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        // Newer ICU puts a narrow no-break space before "PM".
        return CheckInCountdown.line(deadline: deadline, now: now, locale: Locale(identifier: "en_US"),
                                     calendar: utc, timeZone: TimeZone(identifier: "UTC")!)
            .replacingOccurrences(of: "\u{202F}", with: " ")
    }

    func testBeforeTheDeadlineItSaysHowLongIsLeft() {
        let deadline = hours(3.2)
        XCTAssertEqual(line(deadline, t0), "Your circle is alerted in 3 h 12 min")
        XCTAssertEqual(line(deadline, deadline.addingTimeInterval(-3 * 3600)), "Your circle is alerted in 3 h")
        XCTAssertEqual(line(deadline, deadline.addingTimeInterval(-45 * 60)), "Your circle is alerted in 45 min")
        XCTAssertEqual(line(deadline, deadline.addingTimeInterval(-1)), "Your circle is alerted in less than a minute")
    }

    func testFromTheDeadlineOnItSaysWhenTheCircleWasAlerted() {
        let deadline = hours(13 + 40.0 / 60)  // 2027-01-15 21:40 UTC
        XCTAssertEqual(line(deadline, deadline), "Your circle was alerted at 9:40 PM. Check in to clear it.",
                       "at the deadline itself")
        XCTAssertEqual(line(deadline, deadline.addingTimeInterval(3600)),
                       "Your circle was alerted at 9:40 PM. Check in to clear it.")
        XCTAssertEqual(line(deadline, deadline.addingTimeInterval(5 * 3600)),
                       "Your circle was alerted on Jan 15 at 9:40 PM. Check in to clear it.", "on another day")
    }

    // MARK: - The deadline

    func testAOneTimeRuleCountsFromItsArmingAndEndsAtMyNextCheckIn() throws {
        XCTAssertEqual(CheckInCountdown.deadline(myNewest: hours(-10), armedAt: hours(-2), timeoutHours: 6), hours(4),
                       "armed after my last check-in: from the arming")
        XCTAssertEqual(CheckInCountdown.deadline(myNewest: nil, armedAt: hours(-2), timeoutHours: 6), hours(4),
                       "no check-in at all: from the arming")
        XCTAssertNil(CheckInCountdown.deadline(myNewest: hours(-1), armedAt: hours(-2), timeoutHours: 6),
                     "a check-in after the arming ended it: nothing to count down")
        let overdue = try XCTUnwrap(CheckInCountdown.deadline(myNewest: hours(-40), armedAt: hours(-30), timeoutHours: 6))
        XCTAssertEqual(overdue, hours(-24))
        XCTAssertTrue(line(overdue, t0).hasPrefix("Your circle was alerted on "), "overdue since yesterday")
    }

    /// One of this account's rules, as the list serves it. Armed by default
    /// 12 hours before t0.
    private func rule(_ id: String, circle: String? = nil, active: Bool = true, aboutMe: Bool = true,
                      watches: String? = "check_in", armedAt: String? = "2027-01-14T20:00:00Z",
                      timeout: Int = 6) throws -> InactivityAlertResponse {
        var json = "{\"id\":\"\(id)\",\"user_id\":\"\(me)\",\"circle_id\":\"\(circle ?? self.circle)\","
            + "\"encrypted_target_user_id\":{\"nonce\":\"nn\",\"ciphertext\":\"cc\"},\"timeout_hours\":\(timeout),"
            + "\"is_self_alert\":\(aboutMe),\"notify_push\":true,\"notify_email\":false,\"cooldown_minutes\":60,"
            + "\"is_active\":\(active),\"day_bucket\":20800"
        if let watches { json += ",\"watches\":\"\(watches)\"" }
        if let armedAt { json += ",\"armed_at\":\"\(armedAt)\"" }
        return try APIService.makeWireDecoder().decode(InactivityAlertResponse.self, from: Data((json + "}").utf8))
    }

    func testOnlyMyOwnActiveCheckInRulesAboutMeCountDown() throws {
        // Armed 12 hours before t0, and my newest check-in is from before that.
        let mine = CheckInCountdown.MyCheckIns(newest: hours(-20), sinceDay: 0)
        XCTAssertEqual(CheckInCountdown.countdown(of: try rule("r1", timeout: 24), mine: mine), .once(deadline: hours(12)))
        XCTAssertNil(CheckInCountdown.countdown(of: try rule("r2", active: false), mine: mine), "turned off")
        XCTAssertNil(CheckInCountdown.countdown(of: try rule("r3", aboutMe: false), mine: mine), "about someone else")
        XCTAssertNil(CheckInCountdown.countdown(of: try rule("r4", watches: nil), mine: mine),
                     "a location rule: its clock restarts with every location sent")
        XCTAssertNil(CheckInCountdown.countdown(of: try rule("r5", watches: "location"), mine: mine))
        XCTAssertNil(CheckInCountdown.countdown(of: try rule("r6", armedAt: nil), mine: mine), "no arming known")
        XCTAssertNil(CheckInCountdown.countdown(of: try rule("r1"), mine: nil),
                     "not read, or the read failed: nothing rather than a wrong time")
        let shortRead = CheckInCountdown.MyCheckIns(newest: nil, sinceDay: CheckInCountdown.dayBucket(t0))
        XCTAssertNil(CheckInCountdown.countdown(of: try rule("r1"), mine: shortRead),
                     "a read that didn't reach back to the arming day")
        XCTAssertNil(CheckInCountdown.countdown(of: try rule("r1"), mine: CheckInCountdown.MyCheckIns(newest: hours(-1), sinceDay: 0)),
                     "checked in since the arming: the rule has ended")
    }

    func testTheCheckInScreenShowsTheSoonestOfItsCirclesRules() throws {
        let rules = [try rule("r1", timeout: 6), try rule("r2", timeout: 2), try rule("r3", circle: other, timeout: 1),
                     try rule("r4", aboutMe: false, timeout: 1)]
        let mine = [CanonicalId.key(circle): CheckInCountdown.MyCheckIns(newest: nil, sinceDay: 0),
                    CanonicalId.key(other): CheckInCountdown.MyCheckIns(newest: nil, sinceDay: 0)]
        XCTAssertEqual(CheckInCountdown.soonest(circleId: circle.uppercased(), alerts: rules, mine: mine, now: t0),
                       .once(deadline: hours(-10)), "this circle's 2 h rule")
        XCTAssertEqual(CheckInCountdown.soonest(circleId: other, alerts: rules, mine: mine, now: t0),
                       .once(deadline: hours(-11)))
        XCTAssertNil(CheckInCountdown.soonest(circleId: circle, alerts: rules, mine: [:], now: t0))
    }

    func testEachCircleIsReadBackToItsEarliestArmingDay() throws {
        let reads = CheckInCountdown.reads(for: [
            try rule("r1", armedAt: "2027-01-14T20:00:00Z"), try rule("r2", armedAt: "2027-01-10T08:00:00Z"),
            try rule("r3", circle: other, armedAt: "2027-01-15T07:00:00Z"),
            try rule("r4", active: false, armedAt: "2026-01-01T00:00:00Z"),
        ])
        XCTAssertEqual(reads.count, 2)
        XCTAssertEqual(reads[CanonicalId.key(circle)]?.sinceDay, CheckInCountdown.dayBucket(hours(-5 * 24)))
        XCTAssertEqual(reads[CanonicalId.key(other)]?.sinceDay, CheckInCountdown.dayBucket(t0))
    }

    /// A check-in still waiting on this phone (queued while it is behind in
    /// the circle) is not on the server: the circle would still be alerted, so
    /// the countdown doesn't move for it. It restarts when the server accepts
    /// a check-in: one sent now, or the waiting one once it goes out.
    func testACheckInStillWaitingOnThisPhoneMovesNothing() throws {
        let rule = try rule("r1", timeout: 24)
        var mine = CheckInCountdown.MyCheckIns(newest: hours(-15), sinceDay: 0)
        XCTAssertEqual(CheckInCountdown.countdown(of: rule, mine: mine), .once(deadline: hours(12)),
                       "from the arming: the server has nothing of mine since")
        mine.accepted(at: t0)
        XCTAssertNil(CheckInCountdown.countdown(of: rule, mine: mine), "ended once accepted")
        mine.accepted(at: hours(-13))
        XCTAssertEqual(mine.newest, t0, "a waiting one that went out late carries its own time and never moves it back")

        // The wiring: only `remember`, which an accepted check-in reaches,
        // moves it, and a check-in queued while behind returns before that.
        let manager = try source("App/Managers/CheckInManager.swift")
        XCTAssertTrue(try body(of: "private func remember(_ checkIn: CheckIn) {", in: manager)
            .contains("myCheckIns[CanonicalId.key(checkIn.circleId)]?.accepted(at: checkIn.timestamp)"))
        XCTAssertEqual(manager.components(separatedBy: ".accepted(at:").count - 1, 1)
        let checkIn = try body(of: "    func checkIn(\n", in: manager)
        let queued = try XCTUnwrap(checkIn.range(of: "try PendingChanges.queue("))
        let returned = try XCTUnwrap(checkIn.range(of: "return nil", range: queued.upperBound..<checkIn.endIndex))
        let remembered = try XCTUnwrap(checkIn.range(of: "remember(checkIn)"))
        XCTAssertLessThan(returned.lowerBound, remembered.lowerBound, "queued: back before the countdown hears of it")
        XCTAssertTrue(try body(of: "func sendWaitingCheckIn(_ change: PendingChange) async throws {", in: manager)
            .contains("remember(checkIn)"), "the waiting one counts once it has gone out")
        XCTAssertFalse(try source("App/Managers/CheckInCountdown.swift").contains("PendingChange"),
                       "nothing waiting on this phone is read")
    }

    // MARK: - The read, sealed for real

    /// This account's copy of the circle key: it seals rows as phones in the
    /// circle do, and opens them as this phone does.
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

    private func readMine(_ crypto: CryptoManager, sinceDay: Int, pages: [[CheckInResponse]]) async throws -> (Date?, Int) {
        var fetches = 0
        let newest = try await CheckInManager.readMyNewestCheckIn(
            circleId: circle, userId: me, sinceDay: sinceDay, now: t0, crypto: crypto
        ) { _, _ in
            fetches += 1
            return pages[min(fetches, pages.count) - 1]
        }
        return (newest, fetches)
    }

    private func assertCannotTell(_ crypto: CryptoManager, sinceDay: Int, pages: [[CheckInResponse]], _ what: String) async {
        do {
            _ = try await readMine(crypto, sinceDay: sinceDay, pages: pages)
            XCTFail("\(what): must not tell")
        } catch is CheckInCountdown.CannotTell {
        } catch {
            XCTFail("\(what): \(error)")
        }
    }

    func testTheReadFindsMyNewestReadingItsDayToTheEnd() async throws {
        let crypto = try sealer()
        let today = CheckInCountdown.dayBucket(t0)
        // A full page of today's rows, with one of mine; my newer one is on
        // the next page, the same day: rows within a day aren't in time order.
        var first = try (0..<99).map { try row("a-\($0)", by: crypto, sender: ana, at: hours(-0.5), day: today) }
        first.insert(try row("m-1", by: crypto, sender: me, at: hours(-3), day: today), at: 50)
        let second = [try row("m-2", by: crypto, sender: me, at: hours(-2), day: today),
                      try row("a-y", by: crypto, sender: ana, at: hours(-20), day: today - 1)]
        let (newest, fetches) = try await readMine(crypto, sinceDay: today - 3, pages: [first, second])
        XCTAssertEqual(newest, hours(-2), "mine only, the newest of the day")
        XCTAssertEqual(fetches, 2)

        // A full page that reaches a day before my newest one's: done.
        var full = try (0..<98).map { try row("b-\($0)", by: crypto, sender: ana, at: hours(-1), day: today) }
        full.append(try row("m-3", by: crypto, sender: me, at: hours(-4), day: today))
        full.append(try row("b-old", by: crypto, sender: ana, at: hours(-30), day: today - 1))
        let (stopped, onePage) = try await readMine(crypto, sinceDay: today - 3, pages: [full, second])
        XCTAssertEqual(stopped, hours(-4))
        XCTAssertEqual(onePage, 1, "no page past my newest one's day")
    }

    func testWithNoneOfMineSinceTheArmingDayItIsNil() async throws {
        let crypto = try sealer()
        let today = CheckInCountdown.dayBucket(t0)
        let page = try (0..<100).map {
            try row("o-\($0)", by: crypto, sender: ana, at: hours(-1), day: $0 < 50 ? today : today - 2)
        }
        let (newest, fetches) = try await readMine(crypto, sinceDay: today - 1, pages: [page])
        XCTAssertNil(newest)
        XCTAssertEqual(fetches, 1, "it read past the arming day")
        let (old, _) = try await readMine(crypto, sinceDay: today - 1,
                                          pages: [[try row("m-old", by: crypto, sender: me, at: hours(-60), day: today - 3)]])
        XCTAssertEqual(old, hours(-60), "one from before the arming day is read but moves nothing: the arming wins")
        XCTAssertEqual(CheckInCountdown.deadline(myNewest: old, armedAt: hours(-20), timeoutHours: 6), hours(-14))
    }

    func testARowThatMayBeNewerThanMineAndDoesNotOpenMeansItCannotTell() async throws {
        let crypto = try sealer()
        let today = CheckInCountdown.dayBucket(t0)
        let mine = try row("m", by: crypto, sender: me, at: hours(-4), day: today)
        await assertCannotTell(crypto, sinceDay: today - 3,
                               pages: [[mine, try row("x1", by: crypto, sender: me, at: nil, day: today)]],
                               "its time doesn't open, the same day as my newest")
        await assertCannotTell(crypto, sinceDay: today - 3,
                               pages: [[try row("x2", by: crypto, sender: nil, at: hours(-1), day: today), mine]],
                               "its sender doesn't open, before any of mine")
        let (newest, _) = try await readMine(crypto, sinceDay: today - 3, pages: [
            [mine, try row("x3", by: crypto, sender: nil, at: hours(-30), day: today - 1)],
        ])
        XCTAssertEqual(newest, hours(-4), "from a day before my newest one's: it can't be newer")
        let (none, _) = try await readMine(crypto, sinceDay: today - 1, pages: [
            [try row("x4", by: crypto, sender: nil, at: hours(-80), day: today - 4)],
        ])
        XCTAssertNil(none, "from before the arming day: it moves nothing")
    }

    func testAFailedPageAFarFutureOneAndRunningOutOfPages() async throws {
        let crypto = try sealer()
        let today = CheckInCountdown.dayBucket(t0)
        struct PageDidNotCome: Error {}
        do {
            _ = try await CheckInManager.readMyNewestCheckIn(circleId: circle, userId: me, sinceDay: today, now: t0,
                                                              crypto: crypto) { _, _ in throw PageDidNotCome() }
            XCTFail("a page that didn't come fails the read")
        } catch is PageDidNotCome {
        }

        let skew = TimeInterval(CircleManager.maxFutureSkewMs) / 1000
        let (newest, _) = try await readMine(crypto, sinceDay: today - 1, pages: [[
            try row("m-far", by: crypto, sender: me, at: t0.addingTimeInterval(skew + 60), day: today),
            try row("m-ok", by: crypto, sender: me, at: hours(-1), day: today),
        ]])
        XCTAssertEqual(newest, hours(-1), "one dated further ahead than any clock may be is left out")

        let others = try (0..<100).map { try row("p-\($0)", by: crypto, sender: ana, at: hours(-1), day: today) }
        await assertCannotTell(crypto, sinceDay: today, pages: [others], "twenty full pages and still no answer")
    }

    // MARK: - The line, as VoiceOver reads it

    // SwiftUI builds its accessibility tree only while an assistive technology
    // is on (the switch RuleEmailSwitchTests borrows).
    private func spokenElements(of view: some View) throws -> [(label: String, traits: UIAccessibilityTraits)] {
        typealias Getter = @convention(c) () -> Bool
        typealias Setter = @convention(c) (Bool) -> Void
        guard let lib = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW),
              let getter = dlsym(lib, "_AXSApplicationAccessibilityEnabled"),
              let setter = dlsym(lib, "_AXSApplicationAccessibilitySetEnabled") else {
            throw XCTSkip("this simulator runtime has no application accessibility switch")
        }
        let get = unsafeBitCast(getter, to: Getter.self)
        let set = unsafeBitCast(setter, to: Setter.self)
        let was = get()
        set(true)
        defer { set(was) }
        let host = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        var found: [(String, UIAccessibilityTraits)] = []
        collect(host.view, into: &found, depth: 0)
        window.isHidden = true
        return found.map { (label: $0.0, traits: $0.1) }
    }

    private func collect(_ object: NSObject, into found: inout [(String, UIAccessibilityTraits)], depth: Int) {
        guard depth < 30 else { return }
        if object.isAccessibilityElement, let label = object.accessibilityLabel, !label.isEmpty {
            found.append((label, object.accessibilityTraits))
        }
        if let elements = object.accessibilityElements as? [NSObject] {
            for element in elements { collect(element, into: &found, depth: depth + 1) }
        } else {
            let count = object.accessibilityElementCount()
            if count != NSNotFound, count > 0 {
                for index in 0..<count {
                    if let element = object.accessibilityElement(at: index) as? NSObject {
                        collect(element, into: &found, depth: depth + 1)
                    }
                }
            }
        }
        if let view = object as? UIView {
            for subview in view.subviews { collect(subview, into: &found, depth: depth + 1) }
        }
    }

    func testVoiceOverReadsTheLineAndIsNotToldOfEachMinute() throws {
        let deadline = Date().addingTimeInterval(3 * 3600 + 12 * 60 + 30)
        let spoken = try spokenElements(of: CheckInCountdownLine(deadline: deadline))
        let element = try XCTUnwrap(spoken.first { $0.label == "Your circle is alerted in 3 h 12 min" }, "\(spoken.map(\.label))")
        XCTAssertFalse(element.traits.contains(.updatesFrequently), "no live updates read out")
        let view = try source("App/Views/Shared/CheckInCountdownLine.swift")
        XCTAssertFalse(view.contains(".updatesFrequently"))
        XCTAssertFalse(view.contains("AccessibilityNotification"))
        XCTAssertFalse(view.contains(".accessibilityHidden("))
    }

    func testTheLineTurnsOverInStepWithTheDeadline() {
        let deadline = t0.addingTimeInterval(130)
        var ticks = DeadlineMinutes(deadline: deadline).entries(from: t0, mode: .normal)
        XCTAssertEqual(ticks.next(), deadline.addingTimeInterval(-180), "the tick in force when it opens")
        XCTAssertEqual(ticks.next(), deadline.addingTimeInterval(-120))
        XCTAssertEqual(ticks.next(), deadline.addingTimeInterval(-60))
        XCTAssertEqual(ticks.next(), deadline, "and one at the deadline itself")
        XCTAssertEqual(ticks.next(), deadline.addingTimeInterval(60))
        // Just past each tick, the minutes left have just turned over.
        XCTAssertEqual(line(deadline, deadline.addingTimeInterval(-120 + 0.001)), "Your circle is alerted in 1 min")
        XCTAssertEqual(line(deadline, deadline.addingTimeInterval(-60 + 0.001)), "Your circle is alerted in less than a minute")
        XCTAssertTrue(line(deadline, deadline).hasPrefix("Your circle was alerted at "))
    }

    // MARK: - Wiring (source)

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

    func testTheAlertsListShowsItOnTheRuleAndReadsWhenItOpens() throws {
        let alerts = try source("App/Views/Alerts/AlertsView.swift")
        XCTAssertTrue(try body(of: "private func refreshAll() async {", in: alerts)
            .contains("await checkInManager.refreshMyCheckIns(for: inactivityManager.alerts)"), "from the server as it opens")
        XCTAssertTrue(alerts.contains("""
                        countdown: CheckInCountdown.countdown(
                            of: alert, mine: checkInManager.myCheckIns[CanonicalId.key(alert.circleId)])
            """))
        XCTAssertTrue(alerts.contains("CheckInCountdownLine(countdown: countdown).font(.caption)"))
    }

    func testTheCheckInScreenShowsItForItsOwnCircleAndReadsWhenItOpens() throws {
        let map = try source("App/Views/Map/MapView.swift")
        let sheet = try XCTUnwrap(map.range(of: "struct QuickCheckInSheet: View {\n"))
        let rest = String(map[sheet.upperBound...])
        XCTAssertTrue(rest.contains("""
                                if let countdown {
                                    CheckInCountdownLine(countdown: countdown)
                                }
            """), "under the Check in buttons")
        XCTAssertTrue(rest.contains(".task { await refreshCountdown() }"))
        let deadline = try body(of: "private var countdown: CheckInCountdown.Countdown? {", in: rest)
        XCTAssertTrue(deadline.contains("return CheckInCountdown.soonest(circleId: circleId,"))
        let refresh = try body(of: "private func refreshCountdown() async {", in: rest)
        XCTAssertTrue(refresh.contains("await checkInManager.refreshMyCheckIns(for: inactivityManager.alerts, circleId: circleId)"))
        for part in [deadline, refresh] {
            XCTAssertFalse(part.contains("activeCircle"), "the circle the sheet opened for, never the map's")
        }
    }
}
