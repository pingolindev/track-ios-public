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

/// The runner, with fake kinds. Order, failures, age, accounts, cancel, and
/// the general rules for a refusal.
@MainActor
final class PendingChangeRunnerTests: XCTestCase {
    private var directory: URL!
    private let me = "0f0f0f0f-1111-2222-3333-444455556666"
    private let circle = "c1c1c1c1-0000-0000-0000-000000000001"
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)

    /// A kind whose re-check and run the test decides.
    @MainActor
    final class Fake: PendingChangeHandler {
        var recheckResult: @MainActor (PendingChange) -> PendingRecheck = { .run($0) }
        var failures: [String: Error] = [:]
        private(set) var performed: [String] = []
        private(set) var rechecked: [String] = []
        /// The inputs each call was given, in order.
        private(set) var inputsRechecked: [PendingChange.Inputs] = []
        private(set) var inputsPerformed: [PendingChange.Inputs] = []

        func recheck(_ change: PendingChange) async -> PendingRecheck {
            rechecked.append(change.id)
            inputsRechecked.append(change.inputs)
            return recheckResult(change)
        }

        func perform(_ change: PendingChange) async throws {
            performed.append(change.id)
            inputsPerformed.append(change.inputs)
            if let error = failures[change.id] { throw error }
        }

        func classify(_ error: Error, change: PendingChange) -> PendingOutcome? { nil }
    }

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-runner-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func setup(current: Bool = true, account: String? = nil, loaded: Bool = true)
        -> (PendingChangeStore, PendingChangeRunner, Fake) {
        let store = PendingChangeStore(directory: directory)
        let fake = Fake()
        let runner = PendingChangeRunner(
            store: store, handlers: [.checkIn: fake, .batteryAlert: fake, .renameCircle: fake],
            holdsCurrentKey: { _ in current }, signedInAccount: { account ?? self.me },
            now: { self.clock })
        runner.circlesLoaded = { loaded }
        runner.tokenLastsWithoutRefresh = { true }
        return (store, runner, fake)
    }

    @discardableResult
    private func queue(_ store: PendingChangeStore, _ message: String, kind: PendingChange.Kind = .checkIn)
        -> PendingChange {
        clock = clock.addingTimeInterval(5)
        let inputs: PendingChange.Inputs = kind == .checkIn
            ? .checkIn(.init(type: "general", message: message, latitude: nil, longitude: nil, placeId: nil,
                             checkedInAt: clock))
            : .batteryAlert(.init(targetUserId: message, threshold: 20, notifyPush: true, notifyEmail: false,
                                  cooldownMinutes: 60))
        let change = PendingChanges.make(kind, account: me, circleId: circle, inputs: inputs, now: clock)
        _ = store.queue(change, now: clock)
        return change
    }

    /// Never while this device is behind in the circle; once current, the
    /// change runs once, through the kind's function, and is gone.
    func testRunsOnlyWhenCurrentAndOnce() async {
        var (store, runner, fake) = setup(current: false)
        let change = queue(store, "a")
        await runner.run(background: false)
        XCTAssertTrue(fake.performed.isEmpty, "the live gate would refuse: nothing runs while behind")
        XCTAssertEqual(store.changes.count, 1, "and nothing is lost")

        (store, runner, fake) = setup(current: true)
        await runner.run(background: false)
        await runner.run(background: false)
        XCTAssertEqual(fake.performed, [change.id])
        XCTAssertTrue(store.changes.isEmpty)
    }

    /// First in, first out; a transient failure ends the circle's pass, so C
    /// never overtakes B; a permanent one is dropped and the rest go on.
    func testOrderAndFailures() async {
        let (store, runner, fake) = setup()
        let a = queue(store, "a")
        let b = queue(store, "b")
        let c = queue(store, "c")
        fake.failures[b.id] = APIError(code: "http_503", message: "Unavailable")
        await runner.run(background: false)
        XCTAssertEqual(fake.performed, [a.id, b.id], "C does not run before B")
        XCTAssertNil(store.change(id: a.id))
        XCTAssertEqual(store.change(id: b.id)?.state, .waiting)
        XCTAssertEqual(store.change(id: b.id)?.attempts, 1)
        XCTAssertEqual(store.change(id: b.id)?.mayHaveGoneOut, true, "a 5xx may have been stored")
        XCTAssertEqual(store.change(id: b.id)?.nextAttemptAt, clock.addingTimeInterval(30))
        XCTAssertNotNil(store.change(id: c.id))

        // Still in its backoff: the whole circle waits behind it.
        await runner.run(background: false)
        XCTAssertEqual(fake.performed, [a.id, b.id])

        // A permanent refusal: dropped with the plain line, never the server's.
        clock = clock.addingTimeInterval(31)
        fake.failures[b.id] = APIError(code: "http_400", message: "server words, id 1234")
        await runner.run(background: false)
        XCTAssertEqual(fake.performed, [a.id, b.id, b.id, c.id])
        XCTAssertTrue(store.changes.isEmpty)
        XCTAssertEqual(store.notices.map(\.line), ["Your check-in wasn't done."])
    }

    /// Too old is dropped with its line and never sent.
    func testTooOldIsDroppedNeverSent() async {
        let (store, runner, fake) = setup()
        let change = queue(store, "a")
        clock = clock.addingTimeInterval(25 * 3600)
        await runner.run(background: false)
        XCTAssertTrue(fake.performed.isEmpty)
        XCTAssertNil(store.change(id: change.id))
        XCTAssertEqual(store.notices.map(\.line), ["Your check-in wasn't done: this iPhone took too long to catch up."])
    }

    /// A device kept behind still gets the expiry lines.
    func testTooOldWhileBehindIsDroppedWithItsLine() async {
        let (store, runner, fake) = setup(current: false)
        let change = queue(store, "a")
        clock = clock.addingTimeInterval(25 * 3600)
        await runner.run(background: false)
        XCTAssertTrue(fake.performed.isEmpty)
        XCTAssertNil(store.change(id: change.id))
        XCTAssertEqual(store.notices.map(\.line), ["Your check-in wasn't done: this iPhone took too long to catch up."])
    }

    /// A merge restarts the age limit: renamed again on day 6 of its 7 days,
    /// it is still waiting on day 8 and too old only after day 13; one never
    /// merged is too old after day 7.
    func testAMergeRestartsTheAgeLimit() async {
        let day: TimeInterval = 24 * 3600
        let (store, runner, fake) = setup(current: false)
        let work = "c1c1c1c1-0000-0000-0000-000000000002"
        let start = clock
        func rename(_ name: String, in circleId: String) -> PendingChange {
            PendingChanges.make(.renameCircle, account: me, circleId: circleId, inputs: .renameCircle(newName: name),
                                circleName: circleId == circle ? "Family" : "Work", now: clock)
        }
        let merged = rename("Home", in: circle)
        _ = store.queue(merged, now: clock)
        let alone = rename("Office", in: work)
        _ = store.queue(alone, now: clock)
        clock = start.addingTimeInterval(6 * day)
        if case .merged = store.queue(rename("Our home", in: circle), now: clock) {} else { XCTFail("not merged") }

        clock = start.addingTimeInterval(8 * day)
        await runner.run(background: false)
        XCTAssertNotNil(store.change(id: merged.id), "still waiting on day 8")
        XCTAssertNil(store.change(id: alone.id))
        XCTAssertEqual(store.notices.map(\.line), ["Renaming Work wasn't done: this iPhone took too long to catch up."])

        clock = start.addingTimeInterval(13 * day - 60)
        await runner.run(background: false)
        XCTAssertNotNil(store.change(id: merged.id), "still waiting just before day 13")

        clock = start.addingTimeInterval(13 * day + 60)
        await runner.run(background: false)
        XCTAssertNil(store.change(id: merged.id))
        XCTAssertEqual(store.notices.map(\.line), ["Renaming Work wasn't done: this iPhone took too long to catch up.",
                                                   "Renaming Family wasn't done: this iPhone took too long to catch up."])
        XCTAssertTrue(fake.performed.isEmpty)
    }

    /// A change sent with no answer on day 1 and merged on day 6 keeps its own
    /// limit, so it is dropped after day 7 and never sent after it (the
    /// server's request-id record lasts 8 days).
    func testAMergeNeverRestartsAChangeThatMayHaveGoneOut() async {
        let day: TimeInterval = 24 * 3600
        let (store, runner, fake) = setup()
        let start = clock
        func rename(_ name: String) -> PendingChange {
            PendingChanges.make(.renameCircle, account: me, circleId: circle, inputs: .renameCircle(newName: name),
                                circleName: "Family", now: clock)
        }
        let first = rename("Home")
        _ = store.queue(first, now: clock)
        clock = start.addingTimeInterval(day)
        fake.failures[first.id] = URLError(.timedOut)
        await runner.run(background: false)
        XCTAssertEqual(fake.performed, [first.id])
        XCTAssertEqual(store.change(id: first.id)?.mayHaveGoneOut, true, "sent, no answer")

        clock = start.addingTimeInterval(6 * day)
        guard case .merged(let merged) = store.queue(rename("Our home"), now: clock) else {
            return XCTFail("not merged")
        }
        XCTAssertEqual(merged.expiresAt, start.addingTimeInterval(7 * day), "its own limit")

        clock = start.addingTimeInterval(7 * day + 60)
        await runner.run(background: false)
        XCTAssertNil(store.change(id: first.id))
        XCTAssertEqual(fake.performed, [first.id], "never sent after day 7")
        XCTAssertEqual(store.notices.map(\.line), ["Renaming Family wasn't done: this iPhone took too long to catch up."])
    }

    /// Durability: a change goes out only once its running mark, which says
    /// it may have gone out, is on disk. A write that fails sends nothing,
    /// and the change keeps waiting.
    func testAFailedWriteSendsNothing() async throws {
        // A "directory" that is a file: every write of this store fails.
        let blocked = FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-blocked-\(UUID().uuidString)", isDirectory: false)
        try Data("x".utf8).write(to: blocked)
        defer { try? FileManager.default.removeItem(at: blocked) }
        let store = PendingChangeStore(directory: blocked)
        let fake = Fake()
        let runner = PendingChangeRunner(store: store, handlers: [.checkIn: fake], holdsCurrentKey: { _ in true },
                                         signedInAccount: { self.me }, now: { self.clock })
        runner.circlesLoaded = { true }
        runner.tokenLastsWithoutRefresh = { true }
        let change = queue(store, "a")
        await runner.run(background: false)
        XCTAssertEqual(fake.rechecked, [change.id])
        XCTAssertTrue(fake.performed.isEmpty, "not sent without its mark on disk")
        XCTAssertEqual(store.change(id: change.id)?.state, .waiting)
        XCTAssertEqual(store.change(id: change.id)?.attempts, 0)
    }

    /// Too old by its turn in the pass (an earlier change took that long):
    /// dropped with its line, never sent.
    func testTooOldByItsTurnIsNeverSent() async {
        let (store, runner, fake) = setup()
        let alert = queue(store, "u1", kind: .batteryAlert)
        let checkIn = queue(store, "a")
        fake.recheckResult = { change in
            if change.id == alert.id { self.clock = self.clock.addingTimeInterval(25 * 3600) }
            return .run(change)
        }
        await runner.run(background: false)
        XCTAssertEqual(fake.performed, [alert.id])
        XCTAssertNil(store.change(id: checkIn.id))
        XCTAssertEqual(store.notices.map(\.line), ["Your check-in wasn't done: this iPhone took too long to catch up."])
    }

    /// Cancelled while its re-check was running: never sent.
    func testCancelledDuringTheRecheckIsNeverSent() async {
        let (store, runner, fake) = setup()
        let change = queue(store, "a")
        fake.recheckResult = { change in
            _ = runner.cancel(change.id)
            return .run(change)
        }
        await runner.run(background: false)
        XCTAssertTrue(fake.performed.isEmpty)
        XCTAssertNil(store.change(id: change.id))
    }

    /// The newest inputs win: renamed again while its re-check ran (this
    /// iPhone fell behind meanwhile, so the new name was queued and merged).
    /// It is checked again with the new name and sent with it, never with the
    /// old one.
    func testChangedDuringTheRecheckRunsWithTheNewestInputs() async {
        let (store, runner, fake) = setup()
        let first = PendingChanges.make(.renameCircle, account: me, circleId: circle,
                                        inputs: .renameCircle(newName: "Old plan"), now: clock)
        _ = store.queue(first, now: clock)
        var renamedAgain = false
        fake.recheckResult = { change in
            if !renamedAgain {
                renamedAgain = true
                let again = PendingChanges.make(.renameCircle, account: self.me, circleId: self.circle,
                                                inputs: .renameCircle(newName: "New plan"), now: self.clock)
                if case .merged = store.queue(again, now: self.clock) {} else { XCTFail("not merged") }
            }
            return .run(change)
        }
        await runner.run(background: false)
        XCTAssertEqual(fake.inputsRechecked, [.renameCircle(newName: "Old plan"), .renameCircle(newName: "New plan")])
        XCTAssertEqual(fake.inputsPerformed, [.renameCircle(newName: "New plan")], "never sent with the old name")
        XCTAssertEqual(fake.performed, [first.id])
        XCTAssertTrue(store.changes.isEmpty)
    }

    /// What goes out is what the re-check made of the change (here the
    /// circle's sharing was off at send, so no position and no place), never
    /// the inputs as stored.
    func testTheRunSendsWhatTheRecheckMadeOfIt() async {
        let (store, runner, fake) = setup()
        let stored = PendingChanges.make(.checkIn, account: me, circleId: circle, inputs: .checkIn(.init(
            type: "general", message: "a", latitude: 51.513609, longitude: -0.16842, placeId: "p",
            checkedInAt: clock)), now: clock)
        _ = store.queue(stored, now: clock)
        let atSend: PendingChange.Inputs = .checkIn(.init(type: "general", message: "a", latitude: nil,
                                                          longitude: nil, placeId: nil, checkedInAt: clock))
        fake.recheckResult = { change in
            var adjusted = change
            adjusted.inputs = atSend
            return .run(adjusted)
        }
        await runner.run(background: false)
        XCTAssertEqual(fake.inputsPerformed, [atSend])
        XCTAssertTrue(store.changes.isEmpty)
    }

    /// The live gate refused after all (behind again): back to waiting, no
    /// attempt spent, the pass ends.
    func testBehindAgainPutsItBack() async {
        let (store, runner, fake) = setup()
        let a = queue(store, "a")
        let b = queue(store, "b")
        fake.failures[a.id] = CircleManager.CircleError.keyNotCurrent
        await runner.run(background: false)
        XCTAssertEqual(fake.performed, [a.id])
        XCTAssertEqual(store.change(id: a.id)?.state, .waiting)
        XCTAssertEqual(store.change(id: a.id)?.attempts, 0)
        XCTAssertNotNil(store.change(id: b.id))
    }

    /// Another account never runs them; nothing runs before the circle list
    /// has loaded; in the background, nothing that would need the token
    /// refreshed.
    func testNeverAcrossAccountsBeforeTheListOrOnAStaleToken() async {
        var (store, runner, fake) = setup(account: "99999999-aaaa-bbbb-cccc-dddddddddddd")
        let other = PendingChangeStore(directory: directory)
        _ = other.queue(PendingChanges.make(.checkIn, account: me, circleId: circle, inputs: .checkIn(.init(
            type: "general", message: "a", latitude: nil, longitude: nil, placeId: nil, checkedInAt: clock)),
                                            now: clock), now: clock)
        await runner.run(background: false)
        XCTAssertTrue(fake.performed.isEmpty)

        (store, runner, fake) = setup(loaded: false)
        await runner.run(background: false)
        XCTAssertTrue(fake.performed.isEmpty)

        (store, runner, fake) = setup()
        runner.tokenLastsWithoutRefresh = { false }
        await runner.run(background: true)
        XCTAssertTrue(fake.performed.isEmpty)
        await runner.run(background: false)
        XCTAssertEqual(fake.performed.count, 1)
        XCTAssertTrue(store.changes.isEmpty)
    }

    /// A 404 at send is not "gone", and neither is a thing this iPhone
    /// couldn't find to send: the change waits with backoff, and its next
    /// re-check decides from lists the server gives whole.
    func testA404AtSendIsNotGone() async {
        let (store, runner, fake) = setup()
        let change = queue(store, "a")
        fake.failures[change.id] = APIError(code: "http_404", message: "Not found")
        await runner.run(background: false)
        XCTAssertEqual(fake.performed, [change.id])
        XCTAssertEqual(store.change(id: change.id)?.state, .waiting)
        XCTAssertEqual(store.change(id: change.id)?.attempts, 1)
        XCTAssertEqual(store.change(id: change.id)?.mayHaveGoneOut, false)
        XCTAssertTrue(store.notices.isEmpty, "nothing dropped, so no line")
        for code in ["missing_place", "destination_not_found", "rule_not_found", "destination_not_active"] {
            XCTAssertEqual(PendingChangeRunner.classify(APIError(code: code, message: ""), change: change),
                           .transient(sent: false), code)
        }
    }

    /// A resend answered "already done" (409 request_already_done) is done.
    func testRequestAlreadyDoneIsDone() async {
        let (store, runner, fake) = setup()
        let change = queue(store, "a")
        fake.failures[change.id] = APIError(code: "request_already_done", message: "")
        await runner.run(background: false)
        XCTAssertTrue(store.changes.isEmpty)
        XCTAssertTrue(store.notices.isEmpty, "done: no line")
    }

    /// A limit is said with its number.
    func testALimitIsSaidWithItsNumber() {
        let change = PendingChanges.make(.batteryAlert, account: me, circleId: circle, inputs: .batteryAlert(.init(
            targetUserId: "u", threshold: 20, notifyPush: true, notifyEmail: false, cooldownMinutes: 60)),
                                         circleName: "Family")
        let quota = APIError(code: "quota_alert_rules_exceeded", message: "",
                             errorCode: "quota_alert_rules_exceeded",
                             quota: QuotaError(resource: "alert_rules", isCountLimit: true, current: 3, limit: 3,
                                               tier: "free"))
        XCTAssertEqual(PendingChangeRunner.classify(quota, change: change),
                       .drop(line: "This alert wasn't done: Family has reached its limit of 3 alerts on the free plan."))
        XCTAssertEqual(PendingChangeRunner.classify(APIError(code: "rate_limited", message: ""), change: change),
                       .transient(sent: false))
        XCTAssertEqual(PendingChangeRunner.classify(URLError(.notConnectedToInternet), change: change),
                       .transient(sent: false))
        XCTAssertEqual(PendingChangeRunner.classify(URLError(.timedOut), change: change), .transient(sent: true))
        XCTAssertEqual(PendingChangeRunner.classify(CircleManager.CircleError.waitingToSync, change: change), .behind)
    }

    /// Backoff: 30 s, then 1, 2, 4… minutes, at most hourly.
    func testBackoff() {
        XCTAssertEqual((1...9).map { PendingChangeRunner.backoff(afterAttempts: $0) },
                       [30, 60, 120, 240, 480, 960, 1920, 3600, 3600])
    }

    /// Cancel.
    func testCancel() async {
        let (store, runner, _) = setup(current: false)
        let waiting = queue(store, "a")
        XCTAssertEqual(runner.cancel(waiting.id), .removed)
        XCTAssertTrue(store.changes.isEmpty)
        XCTAssertTrue(store.notices.isEmpty, "never sent: gone, with no line")

        let sending = queue(store, "b")
        store.update(sending.id) { $0.state = .running(attemptId: "x", startedAt: Date()) }
        XCTAssertEqual(runner.cancel(sending.id), .sending, "can't be cancelled while it goes out")
        XCTAssertNotNil(store.change(id: sending.id))

        let lost = queue(store, "c")
        store.update(lost.id) { $0.mayHaveGoneOut = true }
        XCTAssertEqual(runner.cancel(lost.id), .removedMayHaveGoneOut)
        XCTAssertNil(store.change(id: lost.id))
        XCTAssertEqual(store.notices.map(\.line),
                       ["Cancelled, but your check-in may already have gone out. If it did, it shows as usual."])
    }

    /// A re-check that drops, or finds it done already.
    func testRecheckOutcomes() async {
        let (store, runner, fake) = setup()
        let a = queue(store, "a")
        let b = queue(store, "b")
        fake.recheckResult = { $0.id == a.id ? .drop(line: "gone") : .done(line: nil) }
        await runner.run(background: false)
        XCTAssertTrue(fake.performed.isEmpty)
        XCTAssertNil(store.change(id: a.id))
        XCTAssertNil(store.change(id: b.id))
        XCTAssertEqual(store.notices.map(\.line), ["gone"])
    }
}
