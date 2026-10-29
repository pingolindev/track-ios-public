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

/// The admission backfill signs with no person deciding, so it keeps the
/// rule a waiting "Let them in" keeps: each id is saved before its request,
/// it looks before it signs again, it is done once the server holds one (the
/// others dead here), and it stops after 20.
@MainActor
final class AdmissionBackfillTests: XCTestCase {
    private var directory: URL!
    private let me = "0f0f0f0f-1111-2222-3333-444455556666"
    private let circle = "c1c1c1c1-0000-0000-0000-000000000001"
    private let member = "1a1a1a1a-2222-3333-4444-555566667777"
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)

    private var signed: [String] = []
    private var stored: [String] = []
    private var storeAnswers: [Error?] = []
    private var looks: [[String]] = []
    private var lookAnswers: [PendingChangeRunner.LookAnswer] = []
    private var settled: [[String]] = []
    private var settleWorks = true
    /// What the ledger held when each request went out.
    private var keptAtSend: [[String]] = []

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("backfill-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func backfill(_ ledger: BackfillLedger) -> AdmissionBackfill {
        AdmissionBackfill(ledger: ledger, account: me, deps: AdmissionBackfill.Deps(
            look: { _, ids in
                self.looks.append(ids)
                return self.lookAnswers.isEmpty ? .couldNotLook : self.lookAnswers.removeFirst()
            },
            sign: { _, _ in
                let id = UUID().uuidString.lowercased()
                self.signed.append(id)
                return AdmissionBackfill.Signed(statementId: id, statementHex: "00", signatureHex: "00")
            },
            store: { circleId, userId, signed in
                self.keptAtSend.append(ledger.entry(account: self.me, circleId: circleId, userId: userId)?.ids ?? [])
                self.stored.append(signed.statementId)
                if !self.storeAnswers.isEmpty, let answer = self.storeAnswers.removeFirst() { throw answer }
            },
            settle: { _, dead in
                guard self.settleWorks else { return false }
                self.settled.append(dead)
                return true
            },
            now: { self.clock }))
    }

    private func later(_ seconds: TimeInterval = 121) { clock = clock.addingTimeInterval(seconds) }

    func testAStoredAdmissionIsDoneAndItsIdWasSavedFirst() async {
        let ledger = BackfillLedger(directory: directory)
        let outcome = await backfill(ledger).run(circleId: circle, userId: member)
        XCTAssertEqual(outcome, .stored)
        XCTAssertEqual(keptAtSend, [signed], "on disk before the request went out")
        XCTAssertEqual(settled, [[]])
        XCTAssertNil(ledger.entry(account: me, circleId: circle, userId: member), "settled: nothing kept")
    }

    /// Lost answers, for the backfill: no answer twice, then a stored one.
    /// One signature per run, a look before each after the first, and the
    /// two spares go dead.
    func testLostAnswersAreLookedAtBeforeSigningAgain() async {
        let ledger = BackfillLedger(directory: directory)
        let backfill = backfill(ledger)
        storeAnswers = [URLError(.timedOut), APIError(code: "http_503", message: ""), nil]
        let outcome1 = await backfill.run(circleId: circle, userId: member)
        XCTAssertEqual(outcome1, .notYet)
        let outcome2 = await backfill.run(circleId: circle, userId: member)
        XCTAssertEqual(outcome2, .notYet, "too soon to look")
        XCTAssertTrue(looks.isEmpty)
        XCTAssertEqual(signed.count, 1)
        later()
        lookAnswers = [.held([])]
        let outcome3 = await backfill.run(circleId: circle, userId: member)
        XCTAssertEqual(outcome3, .notYet)
        later()
        lookAnswers = [.held([])]
        let outcome4 = await backfill.run(circleId: circle, userId: member)
        XCTAssertEqual(outcome4, .stored)
        XCTAssertEqual(signed.count, 3)
        XCTAssertEqual(looks.count, 2)
        XCTAssertEqual(settled, [Array(signed[0...1])], "the spares go dead")
    }

    /// A lost answer the server did store: the look finds it, and nothing is
    /// signed again.
    func testAHeldAdmissionIsNeverSignedAgain() async {
        let ledger = BackfillLedger(directory: directory)
        let backfill = backfill(ledger)
        storeAnswers = [URLError(.timedOut)]
        _ = await backfill.run(circleId: circle, userId: member)
        later()
        lookAnswers = [.held(Set(signed))]
        let outcome5 = await backfill.run(circleId: circle, userId: member)
        XCTAssertEqual(outcome5, .stored)
        XCTAssertEqual(signed.count, 1)
        XCTAssertEqual(settled, [[]])
    }

    /// A look that can't run signs nothing and kills nothing.
    func testALookThatCantRunSignsNothing() async {
        let ledger = BackfillLedger(directory: directory)
        let backfill = backfill(ledger)
        storeAnswers = [URLError(.timedOut)]
        _ = await backfill.run(circleId: circle, userId: member)
        later()
        lookAnswers = [.couldNotLook]
        let outcome6 = await backfill.run(circleId: circle, userId: member)
        XCTAssertEqual(outcome6, .notYet)
        later()
        lookAnswers = [.circleGone]
        let outcome7 = await backfill.run(circleId: circle, userId: member)
        XCTAssertEqual(outcome7, .notYet)
        XCTAssertEqual(signed.count, 1)
        XCTAssertTrue(settled.isEmpty)
    }

    /// Twenty ids and none held: it stops for that member, for good.
    func testTwentyIdsAreTheLast() async {
        let ledger = BackfillLedger(directory: directory)
        let backfill = backfill(ledger)
        for _ in 0..<BackfillLedger.maxIds {
            storeAnswers = [URLError(.timedOut)]
            lookAnswers = [.held([])]
            _ = await backfill.run(circleId: circle, userId: member)
            later()
        }
        XCTAssertEqual(signed.count, 20)
        lookAnswers = [.held([])]
        let outcome8 = await backfill.run(circleId: circle, userId: member)
        XCTAssertEqual(outcome8, .stopped)
        let looked = looks.count
        let outcome9 = await backfill.run(circleId: circle, userId: member)
        XCTAssertEqual(outcome9, .stopped)
        XCTAssertEqual(looks.count, looked, "left alone")
        XCTAssertEqual(signed.count, 20)
        XCTAssertEqual(BackfillLedger(directory: directory).entry(account: me, circleId: circle, userId: member)?.stopped,
                       true, "kept across a relaunch")
    }

    /// An id that can't be saved is never sent (fails closed).
    func testAnIdThatCantBeSavedIsNeverSent() async throws {
        let blocked = directory!
        try Data().write(to: blocked)  // a file where the directory should be
        let ledger = BackfillLedger(directory: blocked.appendingPathComponent("nested"))
        let outcome10 = await backfill(ledger).run(circleId: circle, userId: member)
        XCTAssertEqual(outcome10, .notYet)
        XCTAssertEqual(signed.count, 1)
        XCTAssertTrue(stored.isEmpty)
    }

    /// Dead ids that can't be written keep the entry: the next run looks again
    /// and settles then.
    func testASettleThatFailsIsDoneAgainLater() async {
        let ledger = BackfillLedger(directory: directory)
        let backfill = backfill(ledger)
        settleWorks = false
        let outcome11 = await backfill.run(circleId: circle, userId: member)
        XCTAssertEqual(outcome11, .notYet)
        XCTAssertNotNil(ledger.entry(account: me, circleId: circle, userId: member))
        settleWorks = true
        later()
        lookAnswers = [.held(Set(signed))]
        let outcome12 = await backfill.run(circleId: circle, userId: member)
        XCTAssertEqual(outcome12, .stored)
        XCTAssertEqual(signed.count, 1)
    }

    /// A ledger file that can't be read: the ids signed earlier aren't known,
    /// so nothing is signed, and the file is never written over.
    func testNothingIsSignedWhileTheLedgersFileCantBeRead() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("\(me).json")
        let damaged = Data("{not json".utf8)
        try damaged.write(to: file)
        let ledger = BackfillLedger(directory: directory)
        let outcome = await backfill(ledger).run(circleId: circle, userId: member)
        XCTAssertEqual(outcome, .notYet)
        XCTAssertTrue(signed.isEmpty)
        XCTAssertFalse(ledger.keep("s", account: me, circleId: circle, userId: member, now: clock))
        XCTAssertFalse(ledger.stop(account: me, circleId: circle, userId: member))
        XCTAssertEqual(try Data(contentsOf: file), damaged)
    }

    /// An eject taken while the look before signing awaits signs nothing.
    /// The signature asks the chain again after the look (the real `sign`
    /// starts with this very rule, `backfillSigns`): the removed member gets
    /// no admission, and nothing is stored.
    func testAnEjectTakenDuringTheLookSignsNothing() async {
        let ledger = BackfillLedger(directory: directory)
        // One sent, no answer: the next run looks first.
        storeAnswers = [URLError(.timedOut)]
        _ = await backfill(ledger).run(circleId: circle, userId: member)
        XCTAssertEqual(signed.count, 1)
        later()
        var memberCounted: CircleRole? = .member
        var looked = false
        let chainAsked = AdmissionBackfill(ledger: ledger, account: me, deps: AdmissionBackfill.Deps(
            look: { _, _ in
                looked = true
                memberCounted = nil  // the eject's record, taken while the look awaits
                return .held([])
            },
            sign: { _, _ in
                guard Track.CircleManager.backfillSigns(hasRecords: true, standing: .recorded, myChainRole: .owner,
                                                        memberChainRole: memberCounted) else {
                    throw Track.CircleManager.CircleError.waitingToSync
                }
                self.signed.append("after the eject")
                return AdmissionBackfill.Signed(statementId: "late", statementHex: "00", signatureHex: "00")
            },
            store: { _, _, signed in self.stored.append(signed.statementId) },
            settle: { _, _ in true },
            now: { self.clock }))
        let outcome = await chainAsked.run(circleId: circle, userId: member)
        XCTAssertTrue(looked)
        XCTAssertEqual(outcome, .notYet)
        XCTAssertEqual(signed.count, 1, "nothing signed after the eject")
        XCTAssertFalse(stored.contains("late"))
    }

    /// On a circle with records, only while the chain counts the member, only
    /// as an owner or admin in the chain, never while the circle waits;
    /// without records, the chain asks nothing.
    func testTheBackfillSignsOnlyWhatTheChainAllows() {
        typealias Manager = Track.CircleManager
        XCTAssertTrue(Manager.backfillSigns(hasRecords: false, standing: .wait, myChainRole: nil, memberChainRole: nil))
        XCTAssertTrue(Manager.backfillSigns(hasRecords: true, standing: .recorded, myChainRole: .admin, memberChainRole: .member))
        XCTAssertTrue(Manager.backfillSigns(hasRecords: true, standing: .recorded, myChainRole: .owner, memberChainRole: .admin))
        XCTAssertFalse(Manager.backfillSigns(hasRecords: true, standing: .recorded, myChainRole: .admin, memberChainRole: nil),
                       "the chain doesn't count them (ejected)")
        XCTAssertFalse(Manager.backfillSigns(hasRecords: true, standing: .recorded, myChainRole: .member, memberChainRole: .member))
        XCTAssertFalse(Manager.backfillSigns(hasRecords: true, standing: .wait, myChainRole: .owner, memberChainRole: .member),
                       "never while the circle waits")
    }

    /// The wiring: on a circle with records, only as an owner or admin in the
    /// chain and only for a member the chain counts, asked again with the
    /// signature; always through `AdmissionBackfill`, never the one-shot
    /// `admit`.
    func testTheBackfillFollowsTheChainThroughAdmissionBackfill() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let circles = try String(contentsOf: root.appendingPathComponent("App/Managers/CircleManager.swift"), encoding: .utf8)
        let start = try XCTUnwrap(circles.range(of: "    private func backfillAdmissions(in circle: Circle, result: MembershipConfirmation.Result) async {"))
        let end = try XCTUnwrap(circles[start.upperBound...].range(of: "    private func backfillDeps(me: String) -> AdmissionBackfill.Deps {"))
        let body = circles[start.upperBound..<end.lowerBound]
        XCTAssertTrue(body.contains("guard let role = cryptoManager.chainRole(circleId: circle.id, userId: me),\n                  role == .owner || role == .admin else { return }"))
        XCTAssertTrue(body.contains("            guard backfillSigns(circleId: circle.id, me: me, userId: userId) else { continue }\n            if await backfill.run(circleId: circle.id, userId: userId) == .stored {"))
        XCTAssertFalse(body.contains("admit("), "never the one-shot admission")
        XCTAssertTrue(body.contains("holdsCurrentKey(for: circle.id)"), "never while behind")
        // The signature asks again, after the look's await.
        let deps = try XCTUnwrap(circles.range(of: "            sign: { [self, cryptoManager, membershipCandidates] circleId, userId in\n                guard holdsCurrentKey(for: circleId), backfillSigns(circleId: circleId, me: me, userId: userId) else {\n                    throw CircleError.waitingToSync\n                }\n"))
        XCTAssertGreaterThan(deps.lowerBound, end.lowerBound)
        let auth = try String(contentsOf: root.appendingPathComponent("App/Managers/AuthManager.swift"), encoding: .utf8)
        XCTAssertTrue(auth.contains("BackfillLedger.shared.wipeAll()"))
    }
}
