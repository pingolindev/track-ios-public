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

/// The signed-id rule for the kinds that sign (`invite`, `makeAdmin`,
/// `letIn`), with its bound and its durability rule: every statement a run
/// signs is saved before its request goes out, a change that signed looks
/// before it signs again, only a positive answer from one response kills an
/// id, and a look that can't run (or a write that fails) kills nothing.
@MainActor
final class PendingChangeSignedIdTests: XCTestCase {
    private var directory: URL!
    private let me = "0f0f0f0f-1111-2222-3333-444455556666"
    private let circle = "c1c1c1c1-0000-0000-0000-000000000001"
    private let invitee = "1a1a1a1a-2222-3333-4444-555566667777"
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)

    /// A kind that signs: each run signs one statement, saves its id before
    /// "sending" (the live path's `PendingChanges.keepSigned`), then gets the
    /// answer the test scripted (nil: a 2xx).
    @MainActor
    final class Signer: PendingChangeHandler {
        let store: PendingChangeStore
        var answers: [Error?] = []
        var recheckResult: @MainActor (PendingChange) -> PendingRecheck = { .run($0) }
        private(set) var sent: [String] = []
        /// `.makeAdmin`: the runs that only changed the role (the admission
        /// was held).
        private(set) var roleOnly = 0
        /// `.letIn`: each time this device's choice was made, and whether
        /// each one reads back as stored (scripted; none left: stored).
        private(set) var choices = 0
        var choiceStored: [Bool] = []
        /// `.invite`: this many runs find that the address can't be checked,
        /// as `inviteMember` does: marked, nothing signed,
        /// `AddressNotChecked`.
        var lookupFails = 0
        init(store: PendingChangeStore) { self.store = store }

        func recheck(_ change: PendingChange) async -> PendingRecheck { recheckResult(change) }

        func perform(_ change: PendingChange) async throws {
            if change.kind == .makeAdmin, change.heldStatementId != nil {
                roleOnly += 1
                return
            }
            // `.letIn` with its admission held: only the choice
            // (`letInWaiting`).
            if change.kind == .letIn, change.heldStatementId != nil { return try choose() }
            if change.kind == .invite, lookupFails > 0 {
                lookupFails -= 1
                store.update(change.id) { $0.addressUnchecked = true }
                throw PendingChanges.AddressNotChecked()
            }
            let id = UUID().uuidString.lowercased()
            let kind: MembershipStatementKind = change.kind == .invite ? .invitationToAccount : .admission
            let statement = MembershipStatement(
                kind: kind, circleId: change.circleId, statementId: id, signerUserId: change.account,
                issuedAt: 1_800_000_000, expiresAt: kind == .admission ? 0 : 1_800_604_800, atVersion: 3,
                subjectUserId: "1a1a1a1a-2222-3333-4444-555566667777", subjectSharingPublicKeyHex: nil,
                subjectSigningPublicKeyHex: nil, subjectEmail: nil)
            try PendingChanges.keepSigned(statement, for: change, store: store)
            sent.append(id)
            if !answers.isEmpty, let answer = answers.removeFirst() { throw answer }
            if change.kind == .letIn {
                // Stored, and its answer saved (`admitWaiting`); then the choice.
                store.update(change.id) { $0.heldStatementId = id }
                try choose()
            }
        }

        /// The last step of a let-in: read back, else the change stays.
        private func choose() throws {
            choices += 1
            if !choiceStored.isEmpty, !choiceStored.removeFirst() { throw PendingChanges.ChoiceNotSaved() }
        }

        func classify(_ error: Error, change: PendingChange) -> PendingOutcome? { nil }
    }

    /// What the runner asked the server and wrote here.
    private var looks: [[String]] = []
    private var lookAnswers: [PendingChangeRunner.LookAnswer] = []
    private var settled: [(held: String?, dead: [String])] = []
    private var settleWorks = true
    /// A `.letIn` choice made at an end other than its run (a cancel, too
    /// old), and whether it reads back as stored.
    private var endChoices: [String] = []
    private var endChoiceStored = true

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-s13-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func setup(store: PendingChangeStore? = nil) -> (PendingChangeStore, PendingChangeRunner, Signer) {
        let store = store ?? PendingChangeStore(directory: directory)
        let signer = Signer(store: store)
        let runner = PendingChangeRunner(
            store: store, handlers: [.invite: signer, .makeAdmin: signer, .letIn: signer],
            holdsCurrentKey: { _ in true }, signedInAccount: { self.me }, now: { self.clock })
        runner.circlesLoaded = { true }
        runner.tokenLastsWithoutRefresh = { true }
        runner.signingKeyReady = { true }
        runner.look = { _, ids in
            self.looks.append(ids)
            return self.lookAnswers.isEmpty ? .couldNotLook : self.lookAnswers.removeFirst()
        }
        runner.settleStatements = { _, held, dead in
            guard self.settleWorks else { return false }
            self.settled.append((held, dead))
            return true
        }
        runner.roleChanged = { _ in nil }
        runner.recordChoice = { change in
            guard self.endChoiceStored else { return false }
            self.endChoices.append(change.id)
            return true
        }
        return (store, runner, signer)
    }

    @discardableResult
    private func queue(_ store: PendingChangeStore, _ kind: PendingChange.Kind = .invite) -> PendingChange {
        let inputs: PendingChange.Inputs
        switch kind {
        case .makeAdmin: inputs = .makeAdmin(memberId: invitee)
        case .letIn: inputs = .letIn(.init(memberId: invitee, questionKind: "unconfirmedInviter"))
        default: inputs = .invite(.init(email: "sam@example.com", confirmedUserId: nil))
        }
        let change = PendingChanges.make(kind, account: me, circleId: circle, inputs: inputs,
                                         circleName: "Family", subject: "sam@example.com", now: clock)
        _ = store.queue(change, now: clock)
        return change
    }

    /// Past the backoff and the 2 minutes a look waits after a send.
    private func later(_ seconds: TimeInterval = 121) { clock = clock.addingTimeInterval(seconds) }

    /// No answer twice, then a 2xx. Exactly one id is alive here (the stored
    /// one); the two spares are dead. Each run looked before signing again,
    /// and each look found nothing held.
    func testTwoLostAnswersThenAStoredOneLeavesExactlyOneIdAlive() async {
        let (store, runner, signer) = setup()
        let change = queue(store)
        signer.answers = [URLError(.timedOut), APIError(code: "http_503", message: ""), nil]
        await runner.run(background: false)
        later()
        lookAnswers = [.held([])]
        await runner.run(background: false)
        later(300)
        lookAnswers = [.held([])]
        await runner.run(background: false)
        XCTAssertEqual(signer.sent.count, 3)
        XCTAssertEqual(looks.count, 2, "a look before each signature after a lost answer")
        XCTAssertNil(store.change(id: change.id), "done")
        XCTAssertEqual(settled.count, 1)
        XCTAssertEqual(settled.first?.held, signer.sent[2], "the 2xx's statement is the one held")
        XCTAssertEqual(settled.first?.dead, Array(signer.sent[0...1]))
    }

    /// A lost answer the server did store: the look finds it, and nothing is
    /// signed again.
    func testALostAnswerThatWasStoredIsNeverSignedAgain() async {
        let (store, runner, signer) = setup()
        let change = queue(store)
        signer.answers = [URLError(.timedOut)]
        await runner.run(background: false)
        let first = signer.sent
        later()
        lookAnswers = [.held(Set(first))]
        await runner.run(background: false)
        XCTAssertEqual(signer.sent, first, "no second signature")
        XCTAssertNil(store.change(id: change.id))
        XCTAssertEqual(settled.first?.held, first.first)
        XCTAssertEqual(settled.first?.dead, [])
    }

    /// No look sooner than 2 minutes after the newest send: the server may
    /// still be storing it.
    func testNoLookSoonerThanTwoMinutesAfterASend() async {
        let (store, runner, signer) = setup()
        queue(store)
        signer.answers = [URLError(.timedOut)]
        await runner.run(background: false)
        later(60)
        lookAnswers = [.held([])]
        await runner.run(background: false)
        XCTAssertTrue(looks.isEmpty, "the backoff is due, but the look waits")
        XCTAssertEqual(signer.sent.count, 1)
        later(61)
        await runner.run(background: false)
        XCTAssertEqual(looks.count, 1)
        XCTAssertEqual(signer.sent.count, 2)
    }

    /// Nor when a change ends right after a send: refused at once, it is
    /// parked with nothing killed, and looks 2 minutes later.
    func testNoLookSoonerThanTwoMinutesWhenItEndsEither() async {
        let (store, runner, signer) = setup()
        let change = queue(store)
        signer.answers = [APIError(code: "http_400", message: "")]
        await runner.run(background: false)
        XCTAssertTrue(looks.isEmpty)
        XCTAssertEqual(store.change(id: change.id)?.state, .settling)
        XCTAssertTrue(settled.isEmpty)
        later()
        lookAnswers = [.held([])]
        await runner.run(background: false)
        XCTAssertEqual(looks.count, 1)
        XCTAssertNil(store.change(id: change.id))
        XCTAssertEqual(settled.first?.dead, signer.sent)
    }

    /// A look that can't run (offline, a 5xx, a 404 while the circle is still
    /// listed) decides nothing: no signature, no id killed, and it waits.
    func testALookThatCantRunKillsNothingAndSignsNothing() async {
        let (store, runner, signer) = setup()
        let change = queue(store)
        signer.answers = [URLError(.timedOut)]
        await runner.run(background: false)
        later()
        lookAnswers = [.couldNotLook]
        await runner.run(background: false)
        XCTAssertEqual(signer.sent.count, 1)
        XCTAssertTrue(settled.isEmpty)
        XCTAssertEqual(store.change(id: change.id)?.state, .waiting)
        XCTAssertEqual(store.change(id: change.id)?.signedIds, signer.sent)
    }

    /// A 404 means the circle is gone only when the circle list, fetched
    /// whole now, agrees; then the change goes with the circle, unsettled.
    func testA404IsGoneOnlyWhenTheWholeCircleListAgrees() async {
        XCTAssertEqual(PendingChangeRunner.lookAfter404(circleListed: true), .couldNotLook)
        XCTAssertEqual(PendingChangeRunner.lookAfter404(circleListed: nil), .couldNotLook, "the list didn't load")
        XCTAssertEqual(PendingChangeRunner.lookAfter404(circleListed: false), .circleGone)
        let (store, runner, signer) = setup()
        let change = queue(store)
        signer.answers = [URLError(.timedOut)]
        await runner.run(background: false)
        later()
        lookAnswers = [.circleGone]
        await runner.run(background: false)
        XCTAssertNil(store.change(id: change.id))
        XCTAssertTrue(settled.isEmpty, "nothing is settled against a circle that's gone")
    }

    /// The bound: a change holds at most 20 statement ids. At 20 with none
    /// held it is dropped with its "wasn't done" line
    /// (`PendingChangeCopy.notDone`) after that look, every id dead, and a
    /// 21st is never saved.
    func testTwentyIdsAreTheLast() async throws {
        let (store, runner, signer) = setup()
        let change = queue(store)
        let ids = (0..<20).map { _ in UUID().uuidString.lowercased() }
        store.update(change.id) { $0.signedIds = ids; $0.lastSentAt = self.clock }
        store.update(change.id) { $0.state = .running(attemptId: "a", startedAt: self.clock) }
        XCTAssertFalse(store.keepSigned(UUID().uuidString, invitation: nil, changeId: change.id,
                                        limit: PendingChangeRunner.maxSignedIds), "no 21st id")
        store.update(change.id) { $0.state = .waiting }
        later()
        lookAnswers = [.held([])]
        await runner.run(background: false)
        XCTAssertTrue(signer.sent.isEmpty)
        XCTAssertNil(store.change(id: change.id))
        XCTAssertEqual(store.notices.map(\.line), ["sam@example.com's invitation wasn't done."])
        XCTAssertEqual(settled.first?.dead, ids)
    }

    /// Cancel after a lost answer: "Cancelling…" until the look. Held → done
    /// with the "had already gone out" line (`alreadyWentOut`) and the held
    /// id kept; none held → removed with every id dead; a look that can't
    /// run → still "Cancelling…", nothing killed.
    func testCancelAfterALostAnswerWaitsForTheLook() async {
        let (store, runner, signer) = setup()
        let change = queue(store)
        signer.answers = [URLError(.timedOut)]
        await runner.run(background: false)
        XCTAssertEqual(runner.cancel(change.id), .cancelling)
        later()
        lookAnswers = [.couldNotLook]
        await runner.run(background: false)
        XCTAssertEqual(store.change(id: change.id)?.state, .cancelling)
        XCTAssertTrue(settled.isEmpty)
        later(3600)
        lookAnswers = [.held(Set(signer.sent))]
        await runner.run(background: false)
        XCTAssertNil(store.change(id: change.id))
        XCTAssertEqual(store.notices.map(\.line),
                       ["sam@example.com's invitation had already gone out, so it couldn't be cancelled."])
        XCTAssertEqual(settled.first?.held, signer.sent.first)

        let other = queue(store)
        signer.answers = [URLError(.timedOut)]
        await runner.run(background: false)
        runner.cancel(other.id)
        later()
        lookAnswers = [.held([])]
        await runner.run(background: false)
        XCTAssertNil(store.change(id: other.id))
        XCTAssertEqual(settled.last?.held, nil)
        XCTAssertEqual(settled.last?.dead, [signer.sent.last!])
        XCTAssertEqual(store.notices.count, 1, "a cancel that went nowhere has no line")
    }

    /// Durability: a change's record goes only once its dead ids are
    /// stored; if they can't be, it is parked, and settled later.
    func testAFailedDeadIdWriteParksTheChange() async {
        let (store, runner, signer) = setup()
        let change = queue(store)
        // Refused at once: parked until it may look (2 minutes after the send).
        signer.answers = [APIError(code: "http_400", message: "")]
        await runner.run(background: false)
        XCTAssertEqual(store.change(id: change.id)?.state, .settling)
        // The look says none is held, but the dead ids can't be written.
        settleWorks = false
        later()
        lookAnswers = [.held([])]
        await runner.run(background: false)
        XCTAssertEqual(looks.count, 1)
        XCTAssertEqual(store.change(id: change.id)?.state, .settling, "parked, not deleted")
        XCTAssertFalse(store.pending(circleId: circle).contains { $0.id == change.id }, "no longer shown")
        XCTAssertTrue(store.notices.isEmpty)
        settleWorks = true
        later(3600)
        lookAnswers = [.held([])]
        await runner.run(background: false)
        XCTAssertNil(store.change(id: change.id))
        XCTAssertEqual(settled.last?.dead, signer.sent)
        XCTAssertEqual(store.notices.map(\.line), ["sam@example.com's invitation wasn't done."])
    }

    /// Save before send fails CLOSED: an id that can't be written means the
    /// request never goes out.
    func testAnIdThatCantBeSavedIsNeverSent() async throws {
        let blocked = FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-s13-blocked-\(UUID().uuidString)", isDirectory: false)
        try Data("x".utf8).write(to: blocked)
        defer { try? FileManager.default.removeItem(at: blocked) }
        let store = PendingChangeStore(directory: blocked)
        let change = queue(store)
        store.update(change.id) { $0.state = .running(attemptId: "a", startedAt: self.clock) }
        let statement = MembershipStatement(
            kind: .invitationToAccount, circleId: circle, statementId: UUID().uuidString, signerUserId: me,
            issuedAt: 0, expiresAt: 604_800, atVersion: 3, subjectUserId: invitee, subjectSharingPublicKeyHex: nil,
            subjectSigningPublicKeyHex: nil, subjectEmail: nil)
        XCTAssertThrowsError(try PendingChanges.keepSigned(statement, for: change, store: store)) {
            XCTAssertEqual($0 as? PendingChanges.NotSaved, PendingChanges.NotSaved())
        }
        XCTAssertEqual(PendingChangeRunner.classify(PendingChanges.NotSaved(), change: change), .transient(sent: false))
    }

    /// The held invitation to an account keeps whom it names, for this
    /// device's invitee record, even after a lost answer.
    func testAnInvitationKeepsWhomItNames() throws {
        let store = PendingChangeStore(directory: directory)
        let change = queue(store)
        store.update(change.id) { $0.state = .running(attemptId: "a", startedAt: self.clock) }
        let id = UUID().uuidString
        let statement = MembershipStatement(
            kind: .invitationToAccount, circleId: circle, statementId: id, signerUserId: me, issuedAt: 0,
            expiresAt: 604_800, atVersion: 3, subjectUserId: invitee, subjectSharingPublicKeyHex: nil,
            subjectSigningPublicKeyHex: nil, subjectEmail: nil)
        try PendingChanges.keepSigned(statement, for: change, store: store)
        let kept = try XCTUnwrap(store.change(id: change.id))
        XCTAssertEqual(kept.signedIds, [id.lowercased()])
        XCTAssertEqual(kept.signedInvitations?[id.lowercased()],
                       PendingChange.SignedInvitation(subjectUserId: invitee, expiresAt: 604_800))
    }

    /// A held admission (the look, after a lost answer) is not signed again;
    /// the run only changes the role, and the admission's id is kept.
    func testAHeldAdmissionIsNotSignedAgain() async {
        let (store, runner, signer) = setup()
        let change = queue(store, .makeAdmin)
        signer.answers = [URLError(.timedOut)]
        await runner.run(background: false)
        let admission = signer.sent
        later()
        lookAnswers = [.held(Set(admission))]
        await runner.run(background: false)
        XCTAssertEqual(signer.sent, admission, "not signed again")
        XCTAssertEqual(signer.roleOnly, 1)
        XCTAssertNil(store.change(id: change.id))
        XCTAssertEqual(settled.first?.held, admission.first)
    }

    // MARK: - A let-in run that stops between its admission and its choice

    /// What this device's roster pass makes of the member: once the admission
    /// is stored, confirmed from it, as `.statement` (an admission never makes
    /// anyone chosen).
    private var verdict: MembershipVerdict? = .unconfirmable
    /// Whether this account is still an owner or admin, by the complete roster.
    private var ownerOrAdmin: Bool? = true

    /// The `.letIn` re-check as the app makes it once the circle and the
    /// member are listed, with `ownerOrAdmin` and `verdict`; past that point
    /// the keys and the signing key hold here.
    private func letInRecheck(_ change: PendingChange) -> PendingRecheck {
        LetInKind.admitted(change, ownerOrAdmin: ownerOrAdmin, verdict: verdict) ?? .run(change)
    }

    /// The re-check: its own admission held → it runs, whatever this
    /// account's role is now, though that admission already confirms them
    /// here; else the owner/admin check (`notOwnerOrAdmin`); else confirmed
    /// here → "already let in", except an owed one; else it carries on.
    func testALetInWithItsAdmissionHeldRunsBeforeTheRoleAndAlreadyLetIn() {
        var change = PendingChanges.make(.letIn, account: me, circleId: circle, inputs: .letIn(
            .init(memberId: invitee, questionKind: "unconfirmedInviter")), circleName: "Family", subject: "Sam")
        XCTAssertEqual(LetInKind.admitted(change, ownerOrAdmin: true, verdict: .confirmed(.statement)),
                       .done(line: "Sam was already let in."), "someone else let them in")
        XCTAssertNil(LetInKind.admitted(change, ownerOrAdmin: true, verdict: .unconfirmable))
        XCTAssertNil(LetInKind.admitted(change, ownerOrAdmin: true, verdict: nil))
        XCTAssertEqual(LetInKind.admitted(change, ownerOrAdmin: false, verdict: nil),
                       .drop(line: "Letting Sam in wasn't done: you're no longer an owner or admin of Family."))
        XCTAssertEqual(LetInKind.admitted(change, ownerOrAdmin: nil, verdict: .confirmed(.statement)), .notYet)
        change.heldStatementId = "5e5e5e5e-0000-4000-8000-000000000001"
        for role in [true, false, nil] as [Bool?] {
            XCTAssertEqual(LetInKind.admitted(change, ownerOrAdmin: role, verdict: .confirmed(.statement)),
                           .run(change), "only the choice is left")
            XCTAssertEqual(LetInKind.admitted(change, ownerOrAdmin: role, verdict: nil), .run(change))
        }
        var owed = PendingChanges.make(.letIn, account: me, circleId: circle, inputs: .letIn(
            .init(memberId: invitee, questionKind: "owed")), subject: "Sam")
        XCTAssertNil(LetInKind.admitted(owed, ownerOrAdmin: true, verdict: .confirmed(.ownAction)),
                     "owed: it only signs")
        owed.heldStatementId = "5e5e5e5e-0000-4000-8000-000000000002"
        XCTAssertEqual(LetInKind.admitted(owed, ownerOrAdmin: true, verdict: .confirmed(.ownAction)), .run(owed))
    }

    /// The first stop path: the admission's answer is lost, and the server
    /// stored it. This device now confirms them from it; the look's "held"
    /// doesn't end the change: its run signs nothing and only records the
    /// choice, and it never ends as "already let in".
    func testALetInWhoseLostAdmissionIsHeldOnlyRecordsTheChoice() async {
        let (store, runner, signer) = setup()
        signer.recheckResult = { self.letInRecheck($0) }
        let change = queue(store, .letIn)
        signer.answers = [URLError(.timedOut)]
        await runner.run(background: false)
        let admission = signer.sent
        XCTAssertEqual(admission.count, 1)
        XCTAssertEqual(signer.choices, 0, "no choice before the admission is known to be stored")
        verdict = .confirmed(.statement)
        later()
        lookAnswers = [.held(Set(admission))]
        await runner.run(background: false)
        XCTAssertEqual(looks, [admission])
        XCTAssertEqual(signer.sent, admission, "not signed again")
        XCTAssertEqual(signer.choices, 1, "the choice is recorded")
        XCTAssertTrue(endChoices.isEmpty, "by its run")
        XCTAssertNil(store.change(id: change.id))
        XCTAssertTrue(store.notices.isEmpty, "never \"already let in\"")
        XCTAssertEqual(settled.first?.held, admission.first)
        XCTAssertEqual(settled.first?.dead, [])
    }

    /// The second stop path: the admission was stored and its answer saved,
    /// and the app stopped before the choice. After the relaunch there is no
    /// look, and the re-check doesn't end it as "already let in": its run signs
    /// nothing and only records the choice.
    func testALetInStoppedAfterItsAdmissionWasStoredOnlyRecordsTheChoice() async {
        let (store, _, _) = setup()
        let change = queue(store, .letIn)
        let admission = "5e5e5e5e-0000-4000-8000-000000000003"
        store.update(change.id) {
            $0.signedIds = [admission]
            $0.heldStatementId = admission
            $0.state = .running(attemptId: "a1", startedAt: self.clock)
            $0.lastSentAt = self.clock
        }
        verdict = .confirmed(.statement)
        // The app stops here, and starts again from the file.
        let (relaunched, runner, signer) = setup(store: PendingChangeStore(directory: directory))
        signer.recheckResult = { self.letInRecheck($0) }
        await runner.run(background: false)
        XCTAssertTrue(looks.isEmpty, "its answer was saved: no look")
        XCTAssertTrue(signer.sent.isEmpty, "not signed again")
        XCTAssertEqual(signer.choices, 1, "the choice is recorded")
        XCTAssertTrue(endChoices.isEmpty, "by its run")
        XCTAssertNil(relaunched.change(id: change.id))
        XCTAssertTrue(relaunched.notices.isEmpty, "never \"already let in\"")
        XCTAssertEqual(settled.first?.held, admission)
        XCTAssertEqual(settled.first?.dead, [])
    }

    /// The choice itself not stored (another process held the approvals'
    /// lock): the change isn't done. It waits, and its next run signs nothing
    /// and only records the choice.
    func testALetInWhoseChoiceIsNotStoredRunsAgainForTheChoiceOnly() async {
        let (store, runner, signer) = setup()
        signer.recheckResult = { self.letInRecheck($0) }
        let change = queue(store, .letIn)
        signer.choiceStored = [false]
        await runner.run(background: false)
        let admission = signer.sent
        XCTAssertEqual(signer.choices, 1)
        XCTAssertEqual(store.change(id: change.id)?.state, .waiting, "not done without the choice")
        XCTAssertEqual(store.change(id: change.id)?.heldStatementId, admission.first)
        XCTAssertTrue(settled.isEmpty)
        verdict = .confirmed(.statement)
        later()
        await runner.run(background: false)
        XCTAssertTrue(looks.isEmpty, "its answer was saved: no look")
        XCTAssertEqual(signer.sent, admission, "not signed again")
        XCTAssertEqual(signer.choices, 2)
        XCTAssertTrue(endChoices.isEmpty, "by its run")
        XCTAssertNil(store.change(id: change.id))
        XCTAssertTrue(store.notices.isEmpty)
        XCTAssertEqual(settled.first?.held, admission.first)
        // The app's own error: it waits, like any local failure.
        XCTAssertNil(LetInKind().classify(PendingChanges.ChoiceNotSaved(), change: change))
        XCTAssertEqual(PendingChangeRunner.classify(PendingChanges.ChoiceNotSaved(), change: change),
                       .transient(sent: false))
    }

    /// A cancel after a lost answer, and the look finds its admission held.
    /// The let-in stands, as its "had already gone out" line says, so the
    /// choice is made too. Not stored: it stays "Cancelling…" and settles
    /// again.
    func testACancelledLetInWhoseAdmissionIsHeldRecordsTheChoice() async {
        let (store, runner, signer) = setup()
        signer.recheckResult = { self.letInRecheck($0) }
        let change = queue(store, .letIn)
        signer.answers = [URLError(.timedOut)]
        await runner.run(background: false)
        let admission = signer.sent
        XCTAssertEqual(runner.cancel(change.id), .cancelling)
        endChoiceStored = false
        later()
        lookAnswers = [.held(Set(admission))]
        await runner.run(background: false)
        XCTAssertEqual(store.change(id: change.id)?.state, .cancelling, "the choice isn't stored: it stays")
        XCTAssertTrue(settled.isEmpty, "nothing killed")
        endChoiceStored = true
        later(3600)
        lookAnswers = [.held(Set(admission))]
        await runner.run(background: false)
        XCTAssertEqual(endChoices, [change.id], "the choice is made")
        XCTAssertNil(store.change(id: change.id))
        XCTAssertEqual(store.notices.map(\.line),
                       ["Letting sam@example.com in had already gone out, so it couldn't be cancelled."])
        XCTAssertEqual(settled.first?.held, admission.first)
        XCTAssertEqual(signer.choices, 0, "never run again")
    }

    /// This account is no longer an owner or admin, and its own admission is
    /// held: the run still records the choice (the role gates signing only),
    /// with no "no longer an owner or admin" line.
    func testADemotedAccountsHeldLetInStillRecordsTheChoice() async {
        let (store, runner, signer) = setup()
        signer.recheckResult = { self.letInRecheck($0) }
        let change = queue(store, .letIn)
        signer.answers = [URLError(.timedOut)]
        await runner.run(background: false)
        let admission = signer.sent
        ownerOrAdmin = false
        verdict = .confirmed(.statement)
        later()
        lookAnswers = [.held(Set(admission))]
        await runner.run(background: false)
        XCTAssertEqual(signer.sent, admission, "not signed again")
        XCTAssertEqual(signer.choices, 1, "the choice is recorded")
        XCTAssertNil(store.change(id: change.id))
        XCTAssertTrue(store.notices.isEmpty, "no notOwnerOrAdmin line")
        // One whose admission the look finds not held is refused
        // (`PendingChangeCopy.notOwnerOrAdmin`).
        let other = queue(store, .letIn)
        ownerOrAdmin = true
        verdict = .unconfirmable
        signer.answers = [URLError(.timedOut)]
        await runner.run(background: false)
        ownerOrAdmin = false
        later()
        lookAnswers = [.held([])]
        await runner.run(background: false)
        XCTAssertNil(store.change(id: other.id))
        XCTAssertEqual(store.notices.map(\.line),
                       ["Letting sam@example.com in wasn't done: you're no longer an owner or admin of Family."])
        XCTAssertEqual(signer.choices, 1)
    }

    /// Too old with its admission held: it never ends without the
    /// choice either, and says nothing (the let-in went out).
    func testALetInTooOldWithItsAdmissionHeldRecordsTheChoice() async {
        let (store, runner, signer) = setup()
        signer.recheckResult = { self.letInRecheck($0) }
        let change = queue(store, .letIn)
        signer.answers = [URLError(.timedOut)]
        await runner.run(background: false)
        let admission = signer.sent
        clock = change.expiresAt.addingTimeInterval(1)
        lookAnswers = [.held(Set(admission))]
        await runner.run(background: false)
        XCTAssertEqual(endChoices, [change.id], "the choice is made")
        XCTAssertNil(store.change(id: change.id))
        XCTAssertTrue(store.notices.isEmpty, "it went out: no line")
        XCTAssertEqual(settled.first?.held, admission.first)
    }

    /// The choice at such an end is made only while the complete roster lists
    /// the member: an entry made for someone who has left would confirm them
    /// again if a server listed them. Gone: nothing to choose, it ends. No
    /// complete roster yet: it waits.
    func testTheChoiceAtAnEndIsMadeOnlyForAListedMember() {
        var made = 0
        XCTAssertTrue(PendingChangeRunner.choiceAtEnd(listed: true) { made += 1; return true })
        XCTAssertEqual(made, 1)
        XCTAssertFalse(PendingChangeRunner.choiceAtEnd(listed: true) { made += 1; return false }, "not stored")
        XCTAssertTrue(PendingChangeRunner.choiceAtEnd(listed: false) { made += 1; return true }, "they left")
        XCTAssertFalse(PendingChangeRunner.choiceAtEnd(listed: nil) { made += 1; return true }, "no complete roster")
        XCTAssertEqual(made, 2, "never for someone not listed")
    }

    /// A 403 at send is not "no longer an owner or admin" by itself: the
    /// change waits, and its re-check decides from the complete roster.
    func testA403AtSendWaits() {
        let change = PendingChanges.make(.invite, account: me, circleId: circle,
                                         inputs: .invite(.init(email: "sam@example.com")))
        XCTAssertEqual(PendingChangeRunner.classify(APIError(code: "http_403", message: ""), change: change),
                       .transient(sent: false))
    }

    // MARK: - The person again

    private let newKeys = MemberKeyPair(sharingKeyHex: "cc11", signingKeyHex: "cc22")

    /// "Is this really {email}?" at most once per change: the run's question
    /// keeps the keys and the account it shows; asked already, the change is
    /// dropped with the `detailsKeepChanging…` line.
    func testTheInviteQuestionIsAskedOnceThenDropped() {
        let change = PendingChanges.make(.invite, account: me, circleId: circle,
                                         inputs: .invite(.init(email: "sam@example.com")))
        let found = CircleManager.CircleError.inviteeChanged(InviteeChange(
            circleId: circle, email: "sam@example.com", userId: invitee, sharingKeyHex: "cc11",
            signingKeyHex: "cc22", number: nil))
        var seen = change.seen
        seen.askedAgain = true
        seen.keys = newKeys
        seen.subjectUserId = invitee
        XCTAssertEqual(InviteKind().classify(found, change: change), .needsPerson(.keysChanged, seen: seen))
        var asked = change
        asked.seen = seen
        XCTAssertEqual(InviteKind().classify(found, change: asked),
                       .drop(line: "Their details keep changing, so sam@example.com wasn't invited."))
    }

    /// A waiting renewal whose invitee's keys moved: asked once about the new
    /// keys, then dropped with the apps' renewal line.
    func testTheRenewalQuestionIsAskedOnceThenDropped() {
        let change = PendingChanges.make(.renewInvitation, account: me, circleId: circle, inputs: .renewInvitation(
            .init(inviteId: "i1", statementId: "s1", inviteeUserId: invitee, email: "sam@example.com")))
        let moved = InvitationRenewals.RenewalError.keysChangedWaiting(newKeys)
        guard case .needsPerson(.keysChanged, let seen)? = RenewInvitationKind().classify(moved, change: change) else {
            return XCTFail("not asked")
        }
        XCTAssertEqual(seen.keys, newKeys)
        XCTAssertTrue(seen.askedAgain)
        var asked = change
        asked.seen = seen
        XCTAssertEqual(RenewInvitationKind().classify(moved, change: asked),
                       .drop(line: "Their details keep changing, so the invitation wasn't renewed."))
        XCTAssertEqual(RenewInvitationKind().classify(APIError(code: "invite_not_found", message: ""), change: change),
                       .drop(line: "sam@example.com's invitation wasn't renewed: it was withdrawn or ran out."))
    }

    // MARK: - An invitation after "It's them"

    private func lookup(_ userId: String?, _ sharing: String?, _ signing: String?) -> UserPublicKeyResponse {
        UserPublicKeyResponse(email: "sam@example.com", sharingPublicKey: sharing, signingPublicKey: signing,
                              userId: userId)
    }

    /// After "It's them" about one account, the invitation goes only to that
    /// account with exactly the keys confirmed: another account, other keys
    /// or none at the second lookup get nothing (never a first contact, never
    /// an invitation to the address): the `detailsKeepChanging…` line, live
    /// or waiting.
    func testAfterItsThemOnlyTheConfirmedAccountAndKeysAreInvited() throws {
        let other = "2b2b2b2b-3333-4444-5555-666677778888"
        let live = InviteeChange(circleId: circle, email: "sam@example.com", userId: invitee,
                                 sharingKeyHex: "cc11", signingKeyHex: "cc22", number: nil)
        let confirmed = try XCTUnwrap(CircleManager.confirmedInvitee(live: live, waiting: nil))
        XCTAssertTrue(CircleManager.lookupShows(confirmed, lookup(invitee.uppercased(), "CC11", "cc22")))
        XCTAssertFalse(CircleManager.lookupShows(confirmed, lookup(other, "cc11", "cc22")), "another account")
        XCTAssertFalse(CircleManager.lookupShows(confirmed, lookup(invitee, "dd11", "cc22")), "other keys")
        XCTAssertFalse(CircleManager.lookupShows(confirmed, lookup(invitee, "cc11", "dd22")), "other keys")
        XCTAssertFalse(CircleManager.lookupShows(confirmed, lookup(invitee, "cc11", nil)), "a key missing")
        XCTAssertFalse(CircleManager.lookupShows(confirmed, lookup(nil, nil, nil)), "no account: never the address")
        // A waiting invitation's answer ("It's them" while behind, or asked again).
        var waiting = PendingChanges.make(.invite, account: me, circleId: circle,
                                          inputs: .invite(.init(email: "sam@example.com", confirmedUserId: invitee)))
        waiting.seen.keys = newKeys
        let fromWaiting = try XCTUnwrap(CircleManager.confirmedInvitee(live: nil, waiting: waiting))
        XCTAssertEqual(fromWaiting.userId, invitee)
        XCTAssertTrue(CircleManager.lookupShows(fromWaiting, lookup(invitee, "cc11", "cc22")))
        XCTAssertFalse(CircleManager.lookupShows(fromWaiting, lookup(other, "cc11", "cc22")), "another account")
        var keyless = waiting
        keyless.seen.keys = nil
        XCTAssertFalse(CircleManager.lookupShows(try XCTUnwrap(CircleManager.confirmedInvitee(live: nil, waiting: keyless)),
                                                 lookup(invitee, "cc11", "cc22")), "no keys kept: nothing matches")
        // Nobody confirmed anyone: the lookup decides.
        let plain = PendingChanges.make(.invite, account: me, circleId: circle,
                                        inputs: .invite(.init(email: "sam@example.com")))
        XCTAssertNil(CircleManager.confirmedInvitee(live: nil, waiting: plain))
        XCTAssertNil(CircleManager.confirmedInvitee(live: nil, waiting: nil))
        // What the person is told.
        let changed = CircleManager.CircleError.inviteeDetailsChanged(email: "sam@example.com")
        XCTAssertEqual(InviteKind().classify(changed, change: waiting),
                       .drop(line: "Their details keep changing, so sam@example.com wasn't invited."))
        XCTAssertEqual(changed.errorDescription, "Their details keep changing, so sam@example.com wasn't invited.",
                       "detailsKeepChangingInvite, live too")
    }

    /// The wiring: the check comes right after the lookup, before anything is
    /// asked, pinned, wrapped, signed or sent; the live answer passes what it
    /// confirmed, and the lookup's one retry keeps it. The lookup's answer is
    /// taken only with its account id in its one canonical form; any other
    /// form is no answer, and goes the way of an address that couldn't be
    /// checked.
    func testTheConfirmedCheckComesBeforeAnythingIsPinnedOrSigned() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let circles = try String(contentsOf: root.appendingPathComponent("App/Managers/CircleManager.swift"), encoding: .utf8)
        let invite = try XCTUnwrap(circles.range(of: "    func inviteMember(to circleId: String, email: String, lookupRetried: Bool = false,"))
        let end = try XCTUnwrap(circles[invite.upperBound...].range(of: "    nonisolated static func confirmedInvitee("))
        let body = circles[invite.upperBound..<end.lowerBound]
        let lookup = try XCTUnwrap(body.range(of: """
                        guard let answer = Self.canonicalLookup(try await api.lookupPublicKey(email: email)) else {
                            throw PendingChanges.AnswerNotReadable()
                        }
                        lookup = answer

            """))
        XCTAssertEqual(body.components(separatedBy: "api.lookupPublicKey(").count, 2, "one lookup, read only through canonicalLookup")
        let answered = try XCTUnwrap(body[lookup.upperBound...].range(of: "            return\n        }\n"),
                                     "the lookup's catch, which keeps it waiting")
        let check = try XCTUnwrap(body.range(of: "let confirmedAs = Self.confirmedInvitee(live: confirmed, waiting: waiting)\n        if let confirmedAs, !Self.lookupShows(confirmedAs, lookup) {\n            throw CircleError.inviteeDetailsChanged(email: email)\n        }"))
        XCTAssertLessThan(answered.upperBound, check.lowerBound)
        let between = body[answered.upperBound..<check.lowerBound].split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        XCTAssertTrue(between.allSatisfy { $0.hasPrefix("//") }, "nothing runs between the answered lookup and the check")
        for step in ["throw CircleError.inviteeChanged(", "try cryptoManager.approveMemberKeyChange(",
                     "_ = try cryptoManager.pinMemberKeys(", "try cryptoManager.wrapCircleKeyForMemberFull(",
                     "try cryptoManager.signInvitationToAccount(", "signed = try cryptoManager.signInvitationToEmail(",
                     "_ = try await api.inviteByEmail("] {
            let at = try XCTUnwrap(body.range(of: step), step)
            XCTAssertLessThan(check.upperBound, at.lowerBound, step)
        }
        XCTAssertTrue(body.contains("try await inviteMember(to: circleId, email: email, lookupRetried: true, confirmed: confirmed,\n                                   waiting: waiting)"))
        let answer = try XCTUnwrap(circles.range(of: "    func confirmInviteeAndInvite(_ change: InviteeChange) async throws {"))
        XCTAssertTrue(circles[answer.upperBound...].prefix(1_600)
            .contains("try await inviteMember(to: change.circleId, email: change.email, confirmed: change)"))
    }

    // MARK: - An address that can't be checked waits

    /// What counts as "couldn't check": the server's 503 `lookup_unavailable`
    /// (either shape the envelope gives), offline, a timeout, a 5xx, no
    /// answer. A real answer never does, and nor does a refusal.
    func testWhatCountsAsAnAddressThatCouldntBeChecked() {
        for error in [APIError(code: "lookup_unavailable", message: "", errorCode: "lookup_unavailable"),
                      APIError(code: "http_503", message: "", errorCode: "lookup_unavailable"),
                      APIError(code: "http_500", message: ""), APIError(code: "http_502", message: ""),
                      APIError(code: "server_error", message: ""), APIError(code: "network_error", message: ""),
                      APIError(code: "circuit_open", message: ""),
                      // 408 and 429 are no answer too.
                      APIError(code: "http_408", message: ""), APIError(code: "http_429", message: ""),
                      APIError(code: "rate_limited", message: ""),
                      URLError(.timedOut), URLError(.notConnectedToInternet), URLError(.networkConnectionLost)] as [Error] {
            XCTAssertTrue(PendingChanges.addressCouldNotBeChecked(error), "\(error)")
        }
        for error in [APIError(code: "http_404", message: ""), APIError(code: "http_403", message: ""),
                      APIError(code: "http_400", message: ""), APIError(code: "http_401", message: ""),
                      APIError(code: "invite_lookup_changed", message: "", errorCode: "invite_lookup_changed"),
                      CircleManager.CircleError.waitingToSync, PendingChanges.NotSaved()] as [Error] {
            XCTAssertFalse(PendingChanges.addressCouldNotBeChecked(error), "\(error)")
        }
        // Kept, it waits like any local failure: nothing went out.
        let invite = PendingChanges.make(.invite, account: me, circleId: circle,
                                         inputs: .invite(.init(email: "sam@example.com")))
        let renewal = PendingChanges.make(.renewInvitation, account: me, circleId: circle, inputs: .renewInvitation(
            .init(inviteId: "i1", statementId: "s1", inviteeUserId: invitee, email: "sam@example.com")))
        XCTAssertNil(InviteKind().classify(PendingChanges.AddressNotChecked(), change: invite))
        XCTAssertNil(RenewInvitationKind().classify(PendingChanges.AddressNotChecked(), change: renewal))
        XCTAssertEqual(PendingChangeRunner.classify(PendingChanges.AddressNotChecked(), change: invite),
                       .transient(sent: false))
        XCTAssertEqual(PendingChangeRunner.classify(PendingChanges.AddressNotChecked(), change: renewal),
                       .transient(sent: false))
        // And the code itself, wherever it comes from, waits too.
        XCTAssertEqual(PendingChangeRunner.classify(APIError(code: "lookup_unavailable", message: "",
                                                             errorCode: "lookup_unavailable"), change: invite),
                       .transient(sent: false))
    }

    /// Kept, it says so (it waits for the address check) instead of the
    /// usual pending line; a live tap keeps it plain, an "It's them"
    /// keeps that account and exactly those keys, asked already.
    func testAKeptInvitationSaysItWaitsForTheAddressCheck() throws {
        var invite = PendingChanges.make(.invite, account: me, circleId: circle,
                                         inputs: .invite(.init(email: "sam@example.com")))
        XCTAssertEqual(PendingChangeCopy.waiting(invite),
                       "Waiting to sync. sam@example.com will be invited as soon as this iPhone catches up.")
        invite.addressUnchecked = true
        XCTAssertEqual(PendingChangeCopy.waiting(invite),
                       "Waiting to sync. sam@example.com will be invited as soon as Pingolin can check the address.")
        var renewal = PendingChanges.make(.renewInvitation, account: me, circleId: circle, inputs: .renewInvitation(
            .init(inviteId: "i1", statementId: "s1", inviteeUserId: invitee, email: "sam@example.com")))
        renewal.addressUnchecked = true
        XCTAssertEqual(PendingChangeCopy.waiting(renewal),
                       "Waiting to sync. sam@example.com's invitation will be renewed as soon as Pingolin can check the address.")

        let plain = CircleManager.keptInvitation(email: "Sam@Example.com", confirmed: nil)
        XCTAssertEqual(plain.inputs, .invite(.init(email: "sam@example.com")))
        XCTAssertEqual(plain.seen, PendingChange.Seen())
        let live = InviteeChange(circleId: circle, email: "sam@example.com", userId: invitee,
                                 sharingKeyHex: "cc11", signingKeyHex: "cc22", number: nil)
        let confirmed = CircleManager.keptInvitation(email: "sam@example.com", confirmed: live)
        XCTAssertEqual(confirmed.inputs, .invite(.init(email: "sam@example.com", confirmedUserId: invitee)))
        XCTAssertEqual(confirmed.seen.keys, newKeys)
        XCTAssertTrue(confirmed.seen.askedAgain)
        XCTAssertEqual(confirmed.seen.subjectUserId, invitee)
    }

    /// A kept invitation that meets "It's them" later (its own merge): the
    /// confirmation comes with the tap, so the run binds that account and
    /// those keys; why it waits is the newest tap's.
    func testATapCarryingItsThemBringsItsConfirmationIntoAKeptInvitation() throws {
        let store = PendingChangeStore(directory: directory)
        var kept = PendingChanges.make(.invite, account: me, circleId: circle,
                                       inputs: .invite(.init(email: "sam@example.com")), now: clock)
        kept.addressUnchecked = true
        kept.versionAtTap = 3
        _ = store.queue(kept, now: clock)
        let live = InviteeChange(circleId: circle, email: "sam@example.com", userId: invitee,
                                 sharingKeyHex: "cc11", signingKeyHex: "cc22", number: nil)
        let answer = CircleManager.keptInvitation(email: "sam@example.com", confirmed: live)
        var tap = PendingChanges.make(.invite, account: me, circleId: circle, inputs: answer.inputs,
                                      seen: answer.seen, now: clock)
        tap.addressUnchecked = true
        tap.versionAtTap = 4
        guard case .merged(let merged) = store.queue(tap, now: clock) else { return XCTFail("merged") }
        XCTAssertEqual(merged.id, kept.id)
        let bound = try XCTUnwrap(CircleManager.confirmedInvitee(live: nil, waiting: merged))
        XCTAssertTrue(CircleManager.lookupShows(bound, lookup(invitee, "cc11", "cc22")))
        XCTAssertEqual(merged.addressUnchecked, true)
        XCTAssertEqual(merged.versionAtTap, 4, "a new tap is a new decision")
        // Another tap while behind: why it waits is the sync now.
        var behind = PendingChanges.make(.invite, account: me, circleId: circle,
                                         inputs: .invite(.init(email: "sam@example.com")), now: clock)
        behind.versionAtTap = 5
        guard case .merged(let again) = store.queue(behind, now: clock) else { return XCTFail("merged") }
        XCTAssertNil(again.addressUnchecked)
        XCTAssertEqual(again.versionAtTap, 5)
        // Kept on disk: a relaunch reads both back.
        let relaunched = PendingChangeStore(directory: directory)
        relaunched.use(account: me)
        XCTAssertEqual(relaunched.change(id: kept.id)?.versionAtTap, 5)
    }

    /// The runner: a kept invitation whose address still can't be checked
    /// waits with backoff, nothing signed and nothing gone out; once the check
    /// answers it goes, once.
    func testAKeptInvitationWaitsUntilItsAddressCanBeCheckedThenGoesOnce() async {
        let (store, runner, signer) = setup()
        var kept = PendingChanges.make(.invite, account: me, circleId: circle,
                                       inputs: .invite(.init(email: "sam@example.com")), now: clock)
        kept.addressUnchecked = true
        _ = store.queue(kept, now: clock)
        signer.lookupFails = 2
        await runner.run(background: false)
        var waiting = store.change(id: kept.id)
        XCTAssertEqual(waiting?.state, .waiting)
        XCTAssertEqual(waiting?.signedIds, [], "nothing signed until the check answers")
        XCTAssertEqual(waiting?.mayHaveGoneOut, false, "nothing went out")
        XCTAssertEqual(waiting.map(PendingChangeCopy.waiting),
                       "Waiting to sync. sam@example.com will be invited as soon as Pingolin can check the address.")
        later(3600)
        await runner.run(background: false)
        waiting = store.change(id: kept.id)
        XCTAssertEqual(waiting?.attempts, 2)
        XCTAssertTrue(signer.sent.isEmpty)
        later(3600)
        await runner.run(background: false)
        XCTAssertEqual(signer.sent.count, 1, "sent once")
        XCTAssertNil(store.change(id: kept.id))
        XCTAssertEqual(settled.first?.held, signer.sent.first)
    }

    /// Cancel works while it waits: nothing went out, so it goes at once,
    /// with no line.
    func testAKeptInvitationCanBeCancelledWhileItWaits() async {
        let (store, runner, signer) = setup()
        var kept = PendingChanges.make(.invite, account: me, circleId: circle,
                                       inputs: .invite(.init(email: "sam@example.com")), now: clock)
        kept.addressUnchecked = true
        _ = store.queue(kept, now: clock)
        signer.lookupFails = 1
        await runner.run(background: false)
        XCTAssertEqual(runner.cancel(kept.id), .removed)
        XCTAssertNil(store.change(id: kept.id))
        XCTAssertTrue(store.notices.isEmpty)
        later(3600)
        await runner.run(background: false)
        XCTAssertTrue(signer.sent.isEmpty, "never sent after a cancel")
    }

    /// One whose address never can be checked: dropped with the `tooOld`
    /// line when its age runs out, and never sent another way.
    func testAKeptInvitationThatCantBeCheckedForSevenDaysEndsWithTooOld() async {
        let (store, runner, signer) = setup()
        var kept = PendingChanges.make(.invite, account: me, circleId: circle,
                                       inputs: .invite(.init(email: "sam@example.com")), now: clock)
        kept.addressUnchecked = true
        _ = store.queue(kept, now: clock)
        signer.lookupFails = 1_000
        await runner.run(background: false)
        clock = kept.expiresAt.addingTimeInterval(1)
        await runner.run(background: false)
        XCTAssertNil(store.change(id: kept.id))
        XCTAssertEqual(store.notices.map(\.line),
                       ["sam@example.com's invitation wasn't done: this iPhone took too long to catch up."])
        XCTAssertTrue(signer.sent.isEmpty, "never sent, never another way")
        XCTAssertTrue(looks.isEmpty, "nothing was signed, so nothing to look for")
    }

    /// The wiring: the live tap, "It's them" and a renewal keep a change when
    /// the check can't be done, before anything is signed; a run marks it and
    /// waits. A real answer (an account, or none) goes on.
    func testAnAddressThatCantBeCheckedIsKeptOnEveryPath() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let circles = try String(contentsOf: root.appendingPathComponent("App/Managers/CircleManager.swift"), encoding: .utf8)
        let invite = try XCTUnwrap(circles.range(of: "    func inviteMember(to circleId: String, email: String, lookupRetried: Bool = false,"))
        let end = try XCTUnwrap(circles[invite.upperBound...].range(of: "    nonisolated static func keptInvitation("))
        let body = circles[invite.upperBound..<end.lowerBound]
        let kept = try XCTUnwrap(body.range(of: """
                } catch where PendingChanges.addressCouldNotBeChecked(error) {
        """))
        XCTAssertTrue(body[kept.upperBound...].prefix(900).contains("""
                    if let waiting {
                        PendingChangeStore.shared.update(waiting.id) { $0.addressUnchecked = true }
                        throw PendingChanges.AddressNotChecked()
                    }
                    let kept = Self.keptInvitation(email: email, confirmed: confirmed)
                    try PendingChanges.queue(.invite, circleId: circleId, inputs: kept.inputs, seen: kept.seen,
                                             subject: email.lowercased(), addressUnchecked: true)
                    return
                }
        """))
        for step in ["try cryptoManager.signInvitationToAccount(", "signed = try cryptoManager.signInvitationToEmail(",
                     "_ = try await api.inviteByEmail(", "_ = try cryptoManager.pinMemberKeys("] {
            let at = try XCTUnwrap(body.range(of: step), step)
            XCTAssertLessThan(kept.upperBound, at.lowerBound, step)
        }
        // Kept while behind too with the "It's them" it carries.
        XCTAssertEqual(body.components(separatedBy: "Self.keptInvitation(email: email, confirmed: confirmed)").count - 1, 2)
        let answer = try XCTUnwrap(circles.range(of: "    func confirmInviteeAndInvite(_ change: InviteeChange) async throws {"))
        let answerEnd = try XCTUnwrap(circles[answer.upperBound...].range(of: "\n    }\n"))
        let answerBody = circles[answer.upperBound..<answerEnd.lowerBound]
        XCTAssertTrue(answerBody.contains("let kept = Self.keptInvitation(email: change.email, confirmed: change)"))
        // The tap pins, approves and signs nothing: what "It's them" confirmed
        // is taken once the check has answered.
        for step in ["approveMemberKeyChange(", "pinMemberKeys(", "clearVerified(", "sign"] {
            XCTAssertFalse(answerBody.contains(step), step)
        }
        let question = try XCTUnwrap(body.range(of: "if confirmedAs == nil, let inviteeUserId = lookup.userId,"),
                                     "the question only when nothing was confirmed")
        let taken = try XCTUnwrap(body.range(of: "if confirmedAs != nil, let inviteeUserId = lookup.userId,"))
        let approve = try XCTUnwrap(body.range(of: "try cryptoManager.approveMemberKeyChange("))
        XCTAssertLessThan(kept.upperBound, question.lowerBound)
        XCTAssertLessThan(question.lowerBound, taken.lowerBound)
        XCTAssertLessThan(taken.lowerBound, approve.lowerBound)
        // The version held at the tap goes with the change.
        let queueing = try String(contentsOf: root.appendingPathComponent("App/Domain/PendingChanges/PendingChanges.swift"), encoding: .utf8)
        XCTAssertTrue(queueing.contains("change.versionAtTap = CircleManager.shared.heldVersion(for: circleId)"))
        // A real "no account" still goes to the address.
        XCTAssertTrue(body.contains("""
                        } else {
                            signed = try cryptoManager.signInvitationToEmail(circleId: circleId, signerUserId: me, email: email)
                        }
        """))
        let renewals = try String(contentsOf: root.appendingPathComponent("App/Managers/InvitationRenewals.swift"), encoding: .utf8)
        XCTAssertEqual(renewals.components(separatedBy: "} catch where PendingChanges.addressCouldNotBeChecked(error) {").count - 1, 2,
                       "the renewal's lookup, and its second one after invite_lookup_changed")
        XCTAssertTrue(renewals.contains("""
                    if let waiting {
                        PendingChangeStore.shared.update(waiting.id) { $0.addressUnchecked = true }
                        throw PendingChanges.AddressNotChecked()
                    }
                    try keep(question, addressUnchecked: true)
                    return
        """))
    }

    /// The answer: yes carries on with exactly the keys and account the
    /// question showed; no drops it silently, since the person decided.
    func testTheAnswerCarriesOnOrDropsSilently() async {
        let (store, runner, _) = setup()
        let yes = queue(store)
        store.update(yes.id) {
            $0.state = .needsPerson(.keysChanged)
            $0.seen.keys = self.newKeys
            $0.seen.subjectUserId = self.invitee
            $0.seen.askedAgain = true
        }
        await runner.answer(yes.id, yes: true)
        let carried = store.change(id: yes.id)
        XCTAssertEqual(carried?.state, .waiting)
        XCTAssertEqual(carried?.inputs, .invite(.init(email: "sam@example.com", confirmedUserId: invitee)))
        XCTAssertEqual(carried?.seen.keys, newKeys)

        let no = PendingChanges.make(.letIn, account: me, circleId: circle,
                                     inputs: .letIn(.init(memberId: invitee, questionKind: "unconfirmedInviter")),
                                     subject: "Sam", now: clock)
        _ = store.queue(no, now: clock)
        store.update(no.id) { $0.state = .needsPerson(.keysChanged) }
        await runner.answer(no.id, yes: false)
        XCTAssertNil(store.change(id: no.id))
        XCTAssertTrue(store.notices.isEmpty, "no line: the person decided")
    }

    /// "Waiting for your password": nothing runs without the signing key, and
    /// the change carries on once it is back.
    func testAChangeWaitingForThePasswordCarriesOnOnceItIsBack() async {
        let (store, runner, signer) = setup()
        let change = queue(store)
        store.update(change.id) { $0.state = .needsPerson(.password) }
        runner.signingKeyReady = { false }
        await runner.run(background: false)
        XCTAssertTrue(signer.sent.isEmpty)
        XCTAssertEqual(store.change(id: change.id)?.state, .needsPerson(.password))
        runner.signingKeyReady = { true }
        await runner.run(background: false)
        XCTAssertEqual(signer.sent.count, 1)
        XCTAssertNil(store.change(id: change.id))
        XCTAssertEqual(PendingChangeRunner.classify(PendingChanges.NeedsPassword(), change: change),
                       .needsPerson(.password, seen: change.seen))
    }

    /// A re-check that asks again notifies once (the existing question
    /// notifiers, for the background).
    func testAQuestionAskedAgainIsNotifiedOnce() async {
        let (store, runner, signer) = setup()
        var asked: [String] = []
        runner.askPerson = { asked.append($0.id) }
        let change = queue(store, .letIn)
        var seen = change.seen
        seen.keys = newKeys
        seen.askedAgain = true
        signer.recheckResult = { _ in .needsPerson(.keysChanged, seen: seen) }
        await runner.run(background: false)
        XCTAssertEqual(asked, [change.id])
        XCTAssertEqual(store.change(id: change.id)?.state, .needsPerson(.keysChanged))
        XCTAssertEqual(store.change(id: change.id)?.seen.keys, newKeys)
        await runner.run(background: false)
        XCTAssertEqual(asked, [change.id], "not again while it waits for the answer")
    }
}
