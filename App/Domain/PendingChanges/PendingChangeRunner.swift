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
import os
import UIKit
import PingolinTrackSDK

/// What a kind's re-check found. It re-reads the server's state through the
/// calls the screens use, no stronger or weaker than the live path's own
/// trust in that data.
enum PendingRecheck: Equatable {
    /// Still makes sense: run it (with inputs the re-check may have adjusted,
    /// e.g. a check-in whose place was deleted goes without it).
    case run(PendingChange)
    /// Nothing left to do: someone already did it (the line says so) or it is
    /// in effect already (no line).
    case done(line: String?)
    /// It no longer makes sense: dropped with its line.
    case drop(line: String?)
    /// Only the person can decide, asked about what `seen` holds (the
    /// keys the question shows).
    case needsPerson(PendingChange.NeedsPerson, seen: PendingChange.Seen)
    /// What it needs to know isn't loaded yet: left for the next trigger.
    case notYet
}

/// How one run of a change ended.
enum PendingOutcome: Equatable {
    case done(line: String?)
    case drop(line: String?)
    /// No answer, or refused for now: it waits, with backoff. `sent`: the
    /// request may have reached the server (a timeout, a 5xx).
    case transient(sent: Bool)
    /// The live gate refused: this device is behind again.
    case behind
    /// The person cancelled it: how `.invite`, `.makeAdmin` and `.letIn` end
    /// after a lost answer, once their look has run.
    case cancelled
    /// Only the person can decide: asked about what `seen` holds.
    case needsPerson(PendingChange.NeedsPerson, seen: PendingChange.Seen)
}

/// One kind of change: how it is re-checked and run. The runner is generic and
/// knows nothing of the kinds.
@MainActor
protocol PendingChangeHandler {
    func recheck(_ change: PendingChange) async -> PendingRecheck
    /// The SAME function the button calls, with the stored inputs. It keeps its
    /// own gate: a "behind" refusal from it comes back as `.behind`.
    func perform(_ change: PendingChange) async throws
    /// A refusal from `perform` this kind knows ("already", "deleted", …); nil
    /// leaves it to the runner's general rules.
    func classify(_ error: Error, change: PendingChange) -> PendingOutcome?
}

/// Carries out waiting changes once this device holds their circle's current
/// version. Runs from the end of every circle load, the background passes and
/// the return to the foreground; one run at a time.
@MainActor
final class PendingChangeRunner {
    static let shared = PendingChangeRunner(handlers: PendingChangeKinds.live)

    static let log = Logger(subsystem: "com.pingolin.track", category: "PendingChanges")

    let store: PendingChangeStore
    var handlers: [PendingChange.Kind: PendingChangeHandler]
    /// The gate the live path asks (`CircleManager.holdsCurrentKey(for:)`).
    var holdsCurrentKey: (String) -> Bool
    /// The signed-in account, if any.
    var signedInAccount: () -> String?
    /// Whether this process has loaded the circle list: nothing runs before
    /// (a re-check against an empty list would drop every change).
    var circlesLoaded: () -> Bool = { CircleManager.shared.circlesLoaded }
    var now: () -> Date
    /// The background token rule, as `BackgroundTaskScheduler` applies it: true
    /// when the access token lasts long enough to finish without refreshing it.
    var tokenLastsWithoutRefresh: () -> Bool = { AuthManager.shared.accessTokenValid(forAtLeast: 120) }
    /// Whether this device can sign (its signing key is here): a change
    /// waiting for the password carries on once it is.
    var signingKeyReady: () -> Bool = { !SelfKeyManager.signingKeyMissing }
    /// The look at which of a change's statements the server
    /// holds; tests pass their own.
    var look: (_ circleId: String, _ statementIds: [String]) async -> LookAnswer = { circleId, ids in
        await PendingChangeRunner.liveLook(circleId: circleId, statementIds: ids)
    }
    /// Writes a change's dead ids, and an `.invite`'s invitee record,
    /// before its record goes; false when they aren't stored (then it is
    /// parked). Tests pass their own.
    var settleStatements: (_ change: PendingChange, _ held: String?, _ dead: [String]) -> Bool = { change, held, dead in
        PendingChangeRunner.liveSettle(change, held: held, dead: dead)
    }
    /// A `.makeAdmin` cancelled after a lost answer, with its admission held:
    /// whether the role changed too (only then did the promotion go out), by
    /// the circle's complete roster; nil when unknown.
    var roleChanged: (_ change: PendingChange) -> Bool? = { change in
        PendingChangeRunner.liveRoleChanged(change)
    }
    /// A `.letIn` ending otherwise than by its run (a cancel, too old), with
    /// its own admission held: this device's choice, as its run records it.
    /// False when it isn't stored yet (then it is parked). Tests pass their
    /// own.
    var recordChoice: (_ change: PendingChange) -> Bool = { change in
        PendingChangeRunner.liveRecordChoice(change)
    }
    /// A change now asks its question again: in the background, the
    /// existing question notifiers, once. Tests pass their own.
    var askPerson: (_ change: PendingChange) -> Void = { change in
        PendingChangeRunner.liveAsk(change)
    }

    private var inFlight: Task<Void, Never>?
    private var runAgain = false

    init(store: PendingChangeStore? = nil,
         handlers: [PendingChange.Kind: PendingChangeHandler] = [:],
         holdsCurrentKey: ((String) -> Bool)? = nil,
         signedInAccount: (() -> String?)? = nil,
         now: @escaping () -> Date = Date.init) {
        self.store = store ?? .shared
        self.handlers = handlers
        self.holdsCurrentKey = holdsCurrentKey ?? { CircleManager.shared.holdsCurrentKey(for: $0) }
        self.signedInAccount = signedInAccount ?? {
            AuthManager.shared.isAuthenticated ? AuthManager.shared.userId?.lowercased() : nil
        }
        self.now = now
    }

    // MARK: - Triggers

    /// Start a run unless one is going; a run already going runs once more
    /// after it ends. Cheap when nothing waits.
    func trigger() {
        Task { await run() }
    }

    /// One run over every circle with waiting changes. In the background it
    /// follows the token rule of the other background work: nothing needing a
    /// token refresh (`BackgroundTaskScheduler`); the next foreground run picks
    /// it up. `background` nil: whatever the app's state says.
    func run(background: Bool? = nil) async {
        guard let account = signedInAccount() else { return }
        store.use(account: account)
        guard !store.changes.isEmpty, circlesLoaded() else { return }
        let inBackground = background ?? (UIApplication.shared.applicationState == .background)
        if inBackground, !tokenLastsWithoutRefresh() { return }
        if let running = inFlight {
            runAgain = true
            await running.value
            return
        }
        let task = Task { @MainActor in
            await self.runOnce()
            while self.runAgain {
                self.runAgain = false
                await self.runOnce()
            }
            self.inFlight = nil
        }
        inFlight = task
        await task.value
    }

    private func runOnce() async {
        guard let account = signedInAccount() else { return }
        store.use(account: account)
        store.pruneNotices(now: now())
        for circleId in store.circlesWithWork {
            // Never across accounts: the store holds only this
            // account's, and each change is checked again.
            guard signedInAccount() == account else { return }
            await runCircle(circleId, account: account)
        }
    }

    /// First in, first out within a circle: a change that has to wait ends
    /// the circle's pass, so a later one never overtakes it. A dropped one
    /// never blocks the rest.
    private func runCircle(_ circleId: String, account: String) async {
        // Ended changes kept only for their statement ids settle
        // first: a look needs no key, so behind or not.
        for change in store.all(circleId: circleId) where change.state == .cancelling || change.state == .settling {
            await settle(change)
        }
        // Too old is too old, behind or not: a server that keeps this device
        // behind gets the expiry lines, never a late surprise weeks on.
        for change in store.all(circleId: circleId) where now() >= change.expiresAt {
            switch change.state {
            case .waiting, .needsPerson:
                await end(change, as: .drop(line: PendingChangeCopy.tooOld(change)))
            case .running, .cancelling, .settling:
                break
            }
        }
        guard holdsCurrentKey(circleId) else { return }
        let ids = store.all(circleId: circleId).sorted { $0.createdAt < $1.createdAt }.map(\.id)
        for id in ids {
            guard let found = store.change(id: id), found.account == account else { continue }
            switch found.state {
            case .needsPerson(.password) where signingKeyReady():
                // The password was given: it carries on.
                store.update(id) { $0.state = .waiting }
            case .needsPerson, .running, .cancelling, .settling:
                continue
            case .waiting:
                break
            }
            guard let change = store.change(id: id) else { continue }
            if now() >= change.expiresAt {
                await end(change, as: .drop(line: PendingChangeCopy.tooOld(change)))
                continue
            }
            if let next = change.nextAttemptAt, next > now() { return }
            guard let handler = handlers[change.kind] else { continue }
            var noneHeld = false
            if change.kind.signs, !change.signedIds.isEmpty, change.heldStatementId == nil {
                switch await lookBeforeSigning(change) {
                case .wait: return
                case .ended: continue
                case .noneHeld: noneHeld = true
                case .go: break
                }
            }
            guard let checked = store.change(id: id), checked.state == .waiting else { continue }
            let recheck = await handler.recheck(checked)
            // Cancelled, or changed again by the person, while its re-check ran:
            // gone, or checked again with what they asked for last.
            guard let latest = store.change(id: id), latest.state == .waiting else { continue }
            guard latest.inputs == checked.inputs else {
                runAgain = true
                return
            }
            switch recheck {
            case .run(let adjusted):
                if await runOne(adjusted, handler: handler, noneHeld: noneHeld) == .stop { return }
            case .done(let line):
                await end(latest, as: .done(line: line), noneHeld: noneHeld)
            case .drop(let line):
                await end(latest, as: .drop(line: line), noneHeld: noneHeld)
            case .needsPerson(let what, let seen):
                needsPerson(id, what, seen: seen)
            case .notYet:
                return
            }
        }
    }

    private enum Continue { case next, stop }

    private func runOne(_ change: PendingChange, handler: PendingChangeHandler, noneHeld: Bool) async -> Continue {
        let attemptId = UUID().uuidString.lowercased()
        // Marked running on disk BEFORE anything goes out: found so after a
        // crash, it may have gone out, and a merge then keeps its age
        // limit. A mark that can't be saved sends nothing (fails closed).
        let saved = store.update(change.id) {
            // What the re-check made of it: stricter inputs, or the
            // keys the person approved since (`.makeAdmin`).
            $0.inputs = change.inputs
            $0.seen = change.seen
            $0.state = .running(attemptId: attemptId, startedAt: self.now())
            $0.lastSentAt = self.now()
        }
        guard saved else {
            store.update(change.id) { $0.state = .waiting }
            return .stop
        }
        guard let marked = store.change(id: change.id) else { return .next }
        let outcome: PendingOutcome
        var answered = false
        do {
            try await handler.perform(marked)
            outcome = .done(line: nil)
            answered = true
        } catch {
            outcome = handler.classify(error, change: change) ?? Self.classify(error, change: change)
        }
        guard let current = store.change(id: change.id) else { return .next }
        // A statement this run signed: its request's answer is about it alone,
        // and the look's "none held" no longer covers every saved id.
        let signedNow = current.signedIds.count > marked.signedIds.count ? current.signedIds.last : nil
        let stillNoneHeld = noneHeld && signedNow == nil
        switch outcome {
        case .done:
            // A 2xx for the request that carried it: that statement is
            // held. For `.makeAdmin` and `.letIn` it is the admission.
            // Anything else is looked up.
            let held = answered ? (signedNow ?? current.heldStatementId) : nil
            await end(current, as: outcome, heldId: held, noneHeld: stillNoneHeld, choiceMade: answered)
            return .next
        case .drop, .cancelled:
            // A refusal is no answer about the statements of earlier runs.
            await end(current, as: outcome)
            return .next
        case .needsPerson(let what, let seen):
            needsPerson(change.id, what, seen: seen)
            return .next
        case .behind:
            store.update(change.id) { $0.state = .waiting; $0.lastOutcome = "behind" }
            return .stop
        case .transient(let sent):
            let attempts = current.attempts + 1
            store.update(change.id) {
                $0.state = .waiting
                $0.attempts = attempts
                $0.mayHaveGoneOut = $0.mayHaveGoneOut || sent
                $0.nextAttemptAt = self.now().addingTimeInterval(Self.backoff(afterAttempts: attempts))
                $0.lastOutcome = sent ? "no answer" : "not sent"
            }
            Self.log.info("pending \(change.kind.rawValue, privacy: .public) \(change.id, privacy: .public) waits (\(sent ? "no answer" : "not sent", privacy: .public))")
            return .stop
        }
    }

    /// Waits for the person: a question asked again, or the password.
    private func needsPerson(_ id: String, _ what: PendingChange.NeedsPerson, seen: PendingChange.Seen) {
        store.update(id) {
            $0.state = .needsPerson(what)
            $0.seen = seen
        }
        if what == .keysChanged, let change = store.change(id: id) { askPerson(change) }
    }

    /// The question's notification, when the app isn't on screen.
    static func liveAsk(_ change: PendingChange) {
        let circleName = change.labels.circleName
        switch change.inputs {
        case .invite(let inputs):
            guard let subject = change.seen.subjectUserId else { return }
            CircleQuestionNotifier.post(.invitee, circleId: change.circleId, userId: subject, name: inputs.email,
                                        circleName: circleName)
        case .renewInvitation(let inputs):
            CircleQuestionNotifier.post(.invitee, circleId: change.circleId, userId: inputs.inviteeUserId,
                                        name: inputs.email, circleName: circleName)
        case .letIn(let inputs):
            CircleQuestionNotifier.post(.join, circleId: change.circleId, userId: inputs.memberId,
                                        name: change.labels.subject, circleName: circleName)
        default:
            break
        }
    }

    /// Answered: its notification goes.
    static func liveAnswered(_ change: PendingChange) {
        switch change.inputs {
        case .invite:
            if let subject = change.seen.subjectUserId {
                CircleQuestionNotifier.answered(.invitee, circleId: change.circleId, userId: subject)
            }
        case .renewInvitation(let inputs):
            CircleQuestionNotifier.answered(.invitee, circleId: change.circleId, userId: inputs.inviteeUserId)
        case .letIn(let inputs):
            CircleQuestionNotifier.answered(.join, circleId: change.circleId, userId: inputs.memberId)
        default:
            break
        }
    }

    // MARK: - The statements a change signed

    /// At most this many statement ids per change, which is one look.
    /// After that the change is dropped with item 32
    /// (`PendingChangeCopy.notDone`).
    nonisolated static let maxSignedIds = 20
    /// No look sooner than this after the change's newest send: a
    /// request the server is still working on isn't "not held".
    nonisolated static let lookAfterSend: TimeInterval = 120

    enum LookAnswer: Equatable {
        /// These of the change's own ids the server holds; none is a positive
        /// "none".
        case held(Set<String>)
        /// Offline, refused, a 5xx, or a 404 while the circle is still listed:
        /// nothing is decided and nothing killed.
        case couldNotLook
        /// A 404, and the circle list, fetched whole now, no longer has the
        /// circle: the change goes with the circle's other local state.
        case circleGone
    }

    private enum LookFirst { case wait, ended, noneHeld, go }

    /// A request carrying one of its statements may have been stored, so a
    /// change that signed looks before it signs again.
    private func lookBeforeSigning(_ change: PendingChange) async -> LookFirst {
        guard !tooSoonToLook(change) else { return .wait }
        switch await look(change.circleId, change.signedIds) {
        case .couldNotLook:
            store.update(change.id) {
                $0.nextAttemptAt = self.now().addingTimeInterval(Self.backoff(afterAttempts: max(1, $0.attempts)))
                $0.lastOutcome = "look failed"
            }
            return .wait
        case .circleGone:
            forget(change)
            return .ended
        case .held(let held):
            if let id = change.signedIds.first(where: { held.contains($0) }) {
                if change.kind == .makeAdmin || change.kind == .letIn {
                    // `.makeAdmin`, `.letIn`: its admission
                    // is stored; only the role (make-admin)
                    // or this device's choice (let-in) is
                    // left. Ending a let-in here would
                    // leave its choice unrecorded.
                    store.update(change.id) { $0.heldStatementId = id }
                    return .go
                }
                await end(change, as: .done(line: nil), heldId: id)
                return .ended
            }
            if change.signedIds.count >= Self.maxSignedIds {
                // The bound: this many statements and none of them held.
                await end(change, as: .drop(line: PendingChangeCopy.notDone(change)), noneHeld: true)
                return .ended
            }
            return .noneHeld
        }
    }

    private func tooSoonToLook(_ change: PendingChange) -> Bool {
        guard let sent = change.lastSentAt else { return false }
        return now() < sent.addingTimeInterval(Self.lookAfterSend)
    }

    /// How a change ended: deleted, with a line when someone must be told.
    /// One that signed settles its statements first: the one the server
    /// holds stays (an invitation's becomes this device's invitee record),
    /// every other goes dead here, and only a positive answer from one
    /// response decides which. Without one, or when that can't be stored, it
    /// is parked (`settling`, or still `cancelling`) with nothing killed.
    private func end(_ change: PendingChange, as outcome: PendingOutcome, heldId: String? = nil,
                     noneHeld: Bool = false, choiceMade: Bool = false) async {
        switch outcome {
        case .done, .drop, .cancelled: break
        case .transient, .behind, .needsPerson: return
        }
        guard change.kind.signs, !change.signedIds.isEmpty else {
            close(change, line: Self.line(for: outcome))
            return
        }
        var held: String?
        if let heldId, change.signedIds.contains(heldId.lowercased()) {
            held = heldId.lowercased()
        } else if !noneHeld {
            guard !tooSoonToLook(change) else { return park(change, outcome) }
            switch await look(change.circleId, change.signedIds) {
            case .couldNotLook:
                return park(change, outcome)
            case .circleGone:
                return forget(change)
            case .held(let ids):
                held = change.signedIds.first { ids.contains($0) }
            }
        }
        var line: String?
        if held != nil {
            if change.kind == .letIn, !choiceMade {
                // Its own admission is held: the let-in went out,
                // and it never ends without this device's choice.
                // Unless its run just made it, it is made here (a
                // cancel, too old), or the change stays parked
                // ("Cancelling…" for a cancel).
                guard recordChoice(change) else { return park(change, outcome) }
            }
            switch outcome {
            case .cancelled:
                if change.kind == .makeAdmin {
                    // A stored admission is not a promotion: only a changed role is.
                    guard let changed = roleChanged(change) else { return park(change, outcome) }
                    line = changed ? PendingChangeCopy.alreadyWentOut(change) : nil
                } else {
                    line = PendingChangeCopy.alreadyWentOut(change)
                }
            case .done(let doneLine):
                line = doneLine
            default:
                // One of its own is held: it went out, whatever this run was
                // told. A `.makeAdmin`'s is only its admission: how the run
                // ended stands.
                line = change.kind == .makeAdmin ? Self.line(for: outcome) : nil
            }
        } else if case .drop(let dropLine) = outcome {
            line = dropLine
        }
        let dead = change.signedIds.filter { $0 != held }
        guard settleStatements(change, held, dead) else { return park(change, outcome) }
        close(change, line: line)
    }

    private nonisolated static func line(for outcome: PendingOutcome) -> String? {
        switch outcome {
        case .done(let line), .drop(let line): return line
        default: return nil
        }
    }

    /// Deleted, leaving its line when it has one.
    private func close(_ change: PendingChange, line: String?) {
        if let line {
            store.drop(change.id, line: line, now: now())
        } else {
            store.remove(change.id)
        }
        Self.log.info("pending \(change.kind.rawValue, privacy: .public) \(change.id, privacy: .public) ended")
    }

    /// Kept for its ids until a look can settle them, and not shown as
    /// pending; a cancel stays "Cancelling…".
    private func park(_ change: PendingChange, _ outcome: PendingOutcome) {
        store.update(change.id) {
            if case .cancelled = outcome {
                $0.state = .cancelling
            } else {
                $0.state = .settling
                // What it ends with if none of its statements turns out held.
                if case .drop(let line) = outcome { $0.parkedLine = line } else { $0.parkedLine = nil }
            }
            $0.nextAttemptAt = self.now().addingTimeInterval(Self.backoff(afterAttempts: max(1, $0.attempts)))
        }
        Self.log.info("pending \(change.kind.rawValue, privacy: .public) \(change.id, privacy: .public) parked")
    }

    /// Its circle is gone, as the whole list says: it goes with the circle's
    /// other local state, and nothing is settled against it.
    private func forget(_ change: PendingChange) {
        store.remove(change.id)
    }

    /// A parked change: its look again, when due.
    private func settle(_ change: PendingChange) async {
        if let next = change.nextAttemptAt, next > now() { return }
        switch change.state {
        case .cancelling:
            await end(change, as: .cancelled)
        case .settling:
            await end(change, as: .drop(line: change.parkedLine))
        default:
            return
        }
    }

    /// The look, as the server answers it. A 404 means the circle is gone
    /// only when the circle list, fetched whole now, agrees.
    static func liveLook(circleId: String, statementIds: [String]) async -> LookAnswer {
        let api = APIService.shared
        do {
            let held = try await api.statementsHeld(
                circleId: circleId, statementIds: statementIds.map(PendingChange.wireStatementId))
            let wire = Set(held.map { $0.statementId.lowercased() })
            return .held(Set(statementIds.filter { wire.contains(PendingChange.wireStatementId($0)) }))
        } catch let error as APIError where PendingChangeKinds.isNotFound(error) {
            // Missing counts only from a list that came on one page.
            let list = try? await api.getCircleList()
            return lookAfter404(circleListed: list.flatMap { list in
                CircleManager.listsCircle(circleId, listed: Set(list.circles.map { $0.id.lowercased() }),
                                          whole: list.whole)
            })
        } catch {
            return .couldNotLook
        }
    }

    /// A look answered 404: the circle is gone only when the circle list,
    /// fetched whole now, no longer has it; nil: that list didn't load.
    nonisolated static func lookAfter404(circleListed: Bool?) -> LookAnswer {
        circleListed == false ? .circleGone : .couldNotLook
    }

    /// The dead ids and an `.invite`'s invitee record, in this account's
    /// record for the circle (`KeyDeliveryApprovals`), as the signed-in
    /// account only.
    static func liveSettle(_ change: PendingChange, held: String?, dead: [String]) -> Bool {
        guard let me = AuthManager.shared.userId, me.lowercased() == change.account else { return false }
        let invitee = held.flatMap { id in
            change.signedInvitations?[id].map { (userId: $0.subjectUserId, statementId: id, expiresAt: $0.expiresAt) }
        }
        return KeyDeliveryApprovals.shared.settleSignedStatements(owner: me, circleId: change.circleId, dead: dead,
                                                                   invitee: invitee)
    }

    /// A `.letIn`'s choice at an end other than its run: made only while the
    /// circle's complete roster lists the member, since an entry made for
    /// someone who has left would confirm them again if a server listed them.
    /// Gone: there is nothing to choose, and it ends. No complete roster yet:
    /// it waits.
    static func liveRecordChoice(_ change: PendingChange) -> Bool {
        guard case .letIn(let inputs) = change.inputs else { return true }
        return choiceAtEnd(listed: CircleManager.shared.rosterLists(inputs.memberId, in: change.circleId)) {
            CircleManager.shared.recordLetInChoice(change, reload: true)
        }
    }

    /// Pure, for tests: `listed` is the complete roster's word on the member.
    static func choiceAtEnd(listed: Bool?, record: () -> Bool) -> Bool {
        switch listed {
        case true?: return record()
        case false?: return true
        case nil: return false
        }
    }

    /// Whether a `.makeAdmin`'s member is an admin now, by the circle's
    /// complete roster.
    static func liveRoleChanged(_ change: PendingChange) -> Bool? {
        guard case .makeAdmin(let memberId) = change.inputs,
              CircleManager.shared.rosterLists(memberId, in: change.circleId) == true else { return nil }
        return CircleManager.shared.rosters[change.circleId]?
            .first { $0.userId.caseInsensitiveCompare(memberId) == .orderedSame }?.role == .admin
    }

    // MARK: - The person's answer

    /// The answer to the question a waiting change asked: yes ("It's them",
    /// "Let them in") carries on with exactly the keys the question showed;
    /// no drops it silently, since the person decided.
    func answer(_ id: String, yes: Bool) async {
        guard let change = store.change(id: id), case .needsPerson(.keysChanged) = change.state else { return }
        Self.liveAnswered(change)
        guard yes else {
            await end(change, as: .drop(line: nil))
            return
        }
        store.update(id) {
            $0.state = .waiting
            $0.nextAttemptAt = nil
            if case .invite(var inputs) = $0.inputs {
                inputs.confirmedUserId = $0.seen.subjectUserId
                $0.inputs = .invite(inputs)
            }
        }
        trigger()
    }

    // MARK: - Cancel

    enum CancelResult: Equatable {
        case removed
        /// Being sent: it can't be cancelled until it ends.
        case sending
        /// It may have gone out: removed, with item 35's line.
        case removedMayHaveGoneOut
        /// The kinds that sign, after a lost answer: "Cancelling…" until
        /// the runner has looked.
        case cancelling
    }

    @discardableResult
    func cancel(_ id: String) -> CancelResult {
        guard let change = store.change(id: id) else { return .removed }
        if change.isSending { return .sending }
        if change.kind.signs, !change.signedIds.isEmpty {
            store.update(id) { $0.state = .cancelling }
            trigger()
            return .cancelling
        }
        if change.mayHaveGoneOut {
            store.remove(id)
            store.addNotice(account: change.account, circleId: change.circleId,
                            line: PendingChangeCopy.mayHaveGoneOut(change), now: now())
            return .removedMayHaveGoneOut
        }
        store.remove(id)
        return .removed
    }

    // MARK: - The general rules

    /// 30 s, then 1, 2, 4… minutes, at most hourly; bounded by the age limit,
    /// never by a count.
    nonisolated static func backoff(afterAttempts attempts: Int) -> TimeInterval {
        guard attempts > 1 else { return 30 }
        return min(3600, 60 * pow(2, Double(min(attempts - 2, 12))))
    }

    /// A refusal no kind claimed. Never matched on text, and never the server's
    /// own text on screen.
    nonisolated static func classify(_ error: Error, change: PendingChange) -> PendingOutcome {
        if let circleError = error as? CircleManager.CircleError {
            switch circleError {
            case .keyNotCurrent, .waitingToSync: return .behind
            default: return .drop(line: PendingChangeCopy.notDone(change))
            }
        }
        if let urlError = error as? URLError {
            let notSent: Set<URLError.Code> = [.notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff,
                                               .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed]
            return .transient(sent: !notSent.contains(urlError.code))
        }
        if error is PendingChanges.NeedsPassword {
            return .needsPerson(.password, seen: change.seen)
        }
        guard let api = error as? APIError else {
            // A local failure (sealing, the keychain): not a refusal, so it
            // waits, bounded by its age.
            return .transient(sent: false)
        }
        if api.isServerCode("request_already_done") { return .done(line: nil) }
        if let quota = api.quota {
            return .drop(line: PendingChangeCopy.limitReached(change, limit: quota.limit,
                                                              things: things(quota.resource)))
        }
        let codes = [api.code, api.errorCode].compactMap { $0 }
        // A cap the server names won't free up for hours: dropped,
        // saying so, never waited out as throttling.
        if codes.contains(where: { APIError.capsNotWaitedOut.contains($0) }) {
            return .drop(line: PendingChangeCopy.inviteLimitReached(change))
        }
        if codes.contains(where: { ["rate_limited", "http_429", "circuit_open", "rate_limit_exceeded"].contains($0) }) {
            return .transient(sent: false)
        }
        // The directory couldn't answer (the server's 503
        // `lookup_unavailable`): couldn't check, so it waits, and
        // nothing went out. Never "no account".
        if codes.contains("lookup_unavailable") { return .transient(sent: false) }
        if codes.contains("network_error") { return .transient(sent: true) }
        if codes.contains(where: { $0.hasPrefix("http_5") || $0 == "server_error" || $0 == "internal_error" }) {
            return .transient(sent: true)
        }
        // A 404 is not "gone" by itself, and a 403 is not "no longer an owner
        // or admin": the change waits, and its next re-check decides from the
        // lists and the roster the server gives whole.
        if PendingChangeKinds.isNotFound(api) { return .transient(sent: false) }
        if codes.contains(where: { $0 == "http_403" || $0.hasPrefix("auth_not_") || $0 == "auth_insufficient_permissions" }) {
            return .transient(sent: false)
        }
        return .drop(line: PendingChangeCopy.notDone(change))
    }

    /// {things} in item 28, from the quota's resource.
    nonisolated static func things(_ resource: String) -> String {
        switch resource {
        case let r where r.contains("place_alert"): return "place alerts"
        case let r where r.contains("place"): return "places"
        case let r where r.contains("destination"): return "destinations"
        case let r where r.contains("inactivity"): return "inactivity alerts"
        case let r where r.contains("alert"): return "alerts"
        case let r where r.contains("member"): return "members"
        default: return "of these"
        }
    }
}

extension PendingChange.Kind {
    /// Only an owner or admin may do these: the re-check asks the circle's
    /// complete roster (item 27, `PendingChangeCopy.notOwnerOrAdmin`, when
    /// they no longer are).
    var needsOwnerOrAdmin: Bool {
        switch self {
        case .invite, .makeAdmin, .letIn, .renewInvitation, .renameCircle: return true
        default: return false
        }
    }
}
