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

/// Refresh records in CircleManager: what a circle's records standing
/// allows, and where the records import, the recorded rotations, the SDK's
/// delivery rule and the ledger sit in the app's own flows.
final class RefreshRecordsGlueTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func body(of start: String, until end: String, in text: String) throws -> Substring {
        let from = try XCTUnwrap(text.range(of: start), start)
        let to = try XCTUnwrap(text[from.upperBound...].range(of: end), end)
        return text[from.upperBound..<to.lowerBound]
    }

    /// Records imported and not forked: the eligibility rule and the
    /// records. A legacy circle (no records, none learned of since): the
    /// legacy rules. Anything else waits: not imported in this process,
    /// withheld, forked.
    func testWhatACirclesStandingAllows() {
        typealias Manager = Track.CircleManager
        XCTAssertEqual(Manager.standing(.legacy, hasRecords: false), .noRecords)
        XCTAssertEqual(Manager.standing(.legacy, hasRecords: true), .wait, "records learned of since the import")
        XCTAssertEqual(Manager.standing(.imported(forked: false), hasRecords: true), .recorded)
        XCTAssertEqual(Manager.standing(.imported(forked: true), hasRecords: true), .wait)
        XCTAssertEqual(Manager.standing(.latched, hasRecords: true), .wait)
        XCTAssertEqual(Manager.standing(nil, hasRecords: false), .wait, "no import in this process yet")
        XCTAssertEqual(Manager.standing(nil, hasRecords: true), .wait)

        XCTAssertEqual(Manager.rotationMode(.noRecords, ownerOrAdmin: true, repairDue: false), .transition)
        XCTAssertEqual(Manager.rotationMode(.noRecords, ownerOrAdmin: false, repairDue: true), .legacy)
        XCTAssertEqual(Manager.rotationMode(.recorded, ownerOrAdmin: false, repairDue: false), .recorded(.rotation))
        XCTAssertEqual(Manager.rotationMode(.recorded, ownerOrAdmin: true, repairDue: true), .recorded(.repair))
        XCTAssertEqual(Manager.rotationMode(.wait, ownerOrAdmin: true, repairDue: true), .wait)
    }

    /// Every key import is followed by the records import, after the rosters
    /// are judged and before the rotations, which wait for it; so is a light
    /// pass's while a listed circle owes one.
    func testTheRecordsImportFollowsTheRostersAndPrecedesTheRotations() throws {
        let circles = try source("App/Managers/CircleManager.swift")
        let load = try body(of: "    func loadCircles(light: Bool = false) async throws {",
                            until: "    private(set) var circlesLoaded = false", in: circles)
        let rosters = try XCTUnwrap(load.range(of: "_ = try? await self.loadMembers(for: id)"))
        let records = try XCTUnwrap(load.range(of: "        if needHistoricalKeys || recordsImportDue(now: Date()) {\n"
            + "            await importRefreshRecords()\n"
            + "            // After a reset, an owner's or admin's own admission,\n"
            + "            // before the rotations below (which wait for it).\n"
            + "            await publishSelfAdmissionsIfDue()\n        }"))
        let sweep = try XCTUnwrap(load.range(of: "let circlesNeedingRotation = circles.filter {"))
        XCTAssertLessThan(rosters.upperBound, records.lowerBound)
        XCTAssertLessThan(records.upperBound, sweep.lowerBound)
        XCTAssertTrue(load.contains("|| rotationStepPending($0.id) || recordedRotationDue($0))"))
        XCTAssertTrue(load.contains("&& rotationMode(for: $0) != .wait"))
        // A repair runs on the key of the version it repairs (held, rejected
        // here), every other rotation on the current version sealed under.
        XCTAssertTrue(load.contains("&& !nameHoldsBack($0, due: repairsDue[CanonicalId.key($0.id)]) && holdsWhatItRotates($0)\n"
                                    + "                && !inRotationBackoff($0.id) && rotationMode(for: $0) != .wait"))
        XCTAssertTrue(circles.contains("        if case .recorded(.repair) = rotationMode(for: circle) {\n"
                                       + "            return Self.holdsWhatARepairNeeds(\n"
                                       + "                held: cryptoManager.newestHeldVersion(circleId: circle.id).map { Int($0) },\n"
                                       + "                circleKeyVersion: circle.keyVersion, answering: repairsDue[CanonicalId.key(circle.id)]?.problem)\n"
                                       + "        }"))
        XCTAssertTrue(load.contains("keyChainsLastImport = chains"))
    }

    /// The circle made here is imported once, after the server took it and
    /// after its first roster pass; a light pass imports for the circles that
    /// owe one (`circlesOwingRecordsImport`, by circle key), at their retry
    /// time, never while an import runs; every import notes what it left
    /// owing. Only an import's outcome writes a circle's state.
    func testACircleMadeHereAndALightPassImportWhatIsOwed() throws {
        let circles = try source("App/Managers/CircleManager.swift")
        let create = try body(of: "    func createCircle(name: String, consent: ShownNotice?) async throws -> Circle {",
                              until: "    func updateCircle(", in: circles)
        let taken = try XCTUnwrap(create.range(of: "guard response.id.caseInsensitiveCompare(recorded.circleId) == .orderedSame else {"))
        let listed = try XCTUnwrap(create.range(of: "        circles.append(circle)\n"))
        let imported = try XCTUnwrap(create.range(of: "        _ = try? await loadMembers(for: circle.id)\n"
                                                  + "        await importRefreshRecords()\n        return circle\n    }"))
        XCTAssertLessThan(taken.upperBound, listed.lowerBound)
        XCTAssertLessThan(listed.upperBound, imported.lowerBound)
        XCTAssertFalse(create.contains("recordsState"), "the import's outcome decides, never the create")
        XCTAssertFalse(create.contains("recordsImportRetry"), "nothing holds the import after a create back")
        XCTAssertEqual(circles.components(separatedBy: "await importRefreshRecords()").count - 1, 2)

        let owed = try body(of: "    func circlesOwingRecordsImport() -> [String] {", until: "\n    }\n", in: circles)
        XCTAssertTrue(owed.contains("Self.circlesOwingRecordsImport(circles.map(\\.id), states: recordsState,"))
        XCTAssertTrue(owed.contains("holdsKey: { [cryptoManager] in cryptoManager.hasCircleKey(circleId: $0) })"))
        let due = try body(of: "    func recordsImportDue(now: Date) -> Bool {", until: "\n    }\n", in: circles)
        XCTAssertTrue(due.contains("Self.recordsImportDue(owing: circlesOwingRecordsImport(), retry: recordsImportRetry,\n"
                                   + "                              running: recordsImportsRunning > 0, now: now)"))
        let importer = try body(of: "    private func importRefreshRecords() async {",
                                until: "    nonisolated static func importLinks(", in: circles)
        XCTAssertTrue(importer.hasPrefix("\n        guard let me = AuthManager.shared.userId else { return }\n"
                                         + "        recordsImportsRunning += 1\n        defer {\n"
                                         + "            recordsImportsRunning -= 1\n"
                                         + "            recordsImportRetry.imported(owing: circlesOwingRecordsImport(), at: Date())\n"
                                         + "        }\n"), "every import notes what it left owing, whatever ran it")
        XCTAssertEqual(importer.components(separatedBy: "recordsState[CanonicalId.key(circleId)] = ").count - 1, 3)
        XCTAssertEqual(circles.components(separatedBy: "recordsState[").count - 1, 4, "the accessor and the import's three")
        XCTAssertEqual(circles.components(separatedBy: "recordsState.").count - 1, 1, "the sign-out's removeAll")
        XCTAssertFalse(circles.contains("recordsState = "))
        let reset = try body(of: "    func reset() {\n        circles = []", until: "\n    }\n", in: circles)
        XCTAssertTrue(reset.contains("        recordsState.removeAll()\n        recordsImportRetry.removeAll()\n"), "signed out")
    }

    /// Deliveries: nothing while a circle waits; the SDK's delivery answer
    /// on one with records; the three delivery cases only on one without.
    func testDeliveriesWaitForTheRecordsAndTakeEDeliver() throws {
        let circles = try source("App/Managers/CircleManager.swift")
        let deliver = try body(of: "    func deliverToConfirmedMembers(circleId: String) async {",
                               until: "    private func sendSideGate(", in: circles)
        XCTAssertTrue(deliver.contains("        switch standing(of: circleId) {\n        case .noRecords:\n            eDeliver = nil"))
        XCTAssertTrue(deliver.contains("purpose: .deliver) else { return }"))
        XCTAssertTrue(deliver.contains("        case .wait:\n            return\n        }"))
        XCTAssertTrue(deliver.contains("            eDeliver: eDeliver,\n"))
    }

    /// Rotations and ejects: nothing while a circle waits; with its record on
    /// a circle with records, and the transition from an owner or admin.
    func testRotationsAndEjectsCarryTheirRecord() throws {
        let circles = try source("App/Managers/CircleManager.swift")
        let rotate = try body(of: "    func rotateCircleKey(for circleId: String) async throws {",
                              until: "    // MARK: - Errors", in: circles)
        XCTAssertTrue(rotate.contains("        case .wait:\n            print(\"[Track] rotateCircleKey: \\(circleId) waits for its records\")\n            return"))
        XCTAssertTrue(rotate.contains("change = try prepareRecordedChange(circle, me: senderUserId, mode: mode, due: due, decision: plan,\n"
                                      + "                                                   blocked: blocked)"))
        XCTAssertTrue(rotate.contains("            try await sendRecordedRotation(circle, me: senderUserId, change: change)\n            try await loadCircles()\n            return"))
        let eject = try body(of: "    func removeMember(from circleId: String, userId: String) async throws {",
                             until: "    func removesWithoutNewKey(_ circleId: String) -> Bool {", in: circles)
        XCTAssertTrue(eject.contains("        case .wait:\n            throw CircleError.ejectFailed(CircleError.notDoneWhileWaitingToSync)"))
        XCTAssertTrue(eject.contains("try await sendRecordedEject(circle, userId: userId, me: senderUserId, change: change)"))
        let send = try body(of: "    private func sendRecordedRotation(", until: "    private func sendRecordedEject(", in: circles)
        XCTAssertTrue(send.contains("        if response.alreadyRotated == true {\n            _ = cryptoManager.discardUnconfirmedRotation(circleId: circle.id)"),
                      "a lost race's record isn't stored: the unconfirmed key goes")
        XCTAssertTrue(send.contains("        } catch {\n            _ = cryptoManager.discardUnconfirmedRotation(circleId: circle.id)\n            throw error"))
        let removes = try body(of: "    func removesWithoutNewKey(_ circleId: String) -> Bool {", until: "\n    }\n", in: circles)
        XCTAssertTrue(removes.contains("|| standing(of: circleId) == .wait)\n            && !ejectsFromBelow(circle)"),
                      "an owner's or admin's eject from below makes a new key")
        XCTAssertTrue(eject.contains("if circle.isLocked && !ejectsFromBelow(circle) {"))
        // A server-only admin (not an owner or admin in the chain) removes
        // without a new key; only the chain's owners and admins name anyone
        // removed, and only they owe a rotation for it.
        XCTAssertTrue(removes.contains("if standing(of: circleId) == .recorded, !removesInTheChain(circleId) { return true }"))
        let due = try body(of: "    private func recordedRotationDue(_ circle: Circle) -> Bool {", until: "\n    }\n", in: circles)
        XCTAssertTrue(due.contains("&& removesInTheChain(circle.id)"))
        let prepare = try body(of: "    private func prepareRecordedChange(", until: "    private func recordedChangeTaken(", in: circles)
        XCTAssertTrue(prepare.contains("guard RefreshLedger.shared.isReadable(account: me) else { throw CircleError.waitingToSync }"),
                      "nothing the ledger decides while its file can't be read")
        XCTAssertTrue(prepare.contains(
            "        guard let name = Self.nameToSeal(\n"
            + "            readable: circle.readableName, sealable: sealableName(circle),\n"
            + "            ejectingFromBelow: ejecting != nil && ejectsFromBelow(circle), holds: holdsForTheName(circle, mode: mode, due: due),\n"
            + "            misattributionRepair: Self.repairsMisattribution(mode: mode, answering: due?.problem)) else {\n"
            + "            throw CircleError.waitingToSync\n        }"),
                      "the new key never seals the placeholder name, nor one read under another version (G)")
        XCTAssertEqual(prepare.components(separatedBy: "currentCircleNamePlaintext: name.plaintext)").count, 3)
        let sendEject = try body(of: "    private func sendRecordedEject(", until: "    nonisolated static func linkRequest(", in: circles)
        XCTAssertTrue(sendEject.contains(
            "_ = try await api.ejectAndRotate(circleId: circle.id, request: Self.ejectRequest(userId: userId, change: change))"))
        // No name kept here: none is sent, by either recorded send, and the
        // server keeps the stored one. The sealed empty name goes nowhere.
        XCTAssertEqual(circles.components(separatedBy: "rotation.encryptedName").count - 1, 4)
        XCTAssertEqual(circles.components(
            separatedBy: "encryptedName: change.name == .keepStored ? nil\n                : EncryptedBlobRequest(nonce: rotation.encryptedName.nonce, ciphertext: rotation.encryptedName.ciphertext),").count - 1, 2)
        XCTAssertTrue(prepare.contains("var removing = removesInTheChain(circle.id)\n                ? Set(standingRemovals(circle.id, owed.removals, me: me).map(\\.userId)) : []"))
        // A refused owner's claim is planned again once without it.
        XCTAssertTrue(prepare.contains("} catch MobileError.InvalidInput(let message) where withoutClaim != nil\n"
                                       + "                    && !message.contains(RecordedRotation.notYetText) {"))
        XCTAssertTrue(prepare.contains("            built = withoutClaim ?? planned\n"))
        XCTAssertTrue(prepare.contains("circle.id, senderUserId: me, kind: kind, planned: built,"))
    }

    /// The circle's name never blocks an eject from below: a name sealable
    /// from the key in use is sealed again; none readable, none is sent. Any
    /// other change waits for a readable name: the new key never seals the
    /// placeholder.
    func testTheNameNeverBlocksAnEjectFromBelow() {
        typealias Manager = Track.CircleManager
        XCTAssertEqual(Manager.nameToSeal(readable: "Family", sealable: "Family", ejectingFromBelow: false,
                                          holds: true), .name("Family"))
        XCTAssertEqual(Manager.nameToSeal(readable: "Family", sealable: "Family", ejectingFromBelow: true,
                                          holds: false), .name("Family"))
        XCTAssertEqual(Manager.nameToSeal(readable: nil, sealable: nil, ejectingFromBelow: true, holds: false),
                       .keepStored)
        XCTAssertNil(Manager.nameToSeal(readable: nil, sealable: nil, ejectingFromBelow: false, holds: false),
                     "behind")
        XCTAssertEqual(Manager.NameToSeal.keepStored.plaintext, "")
        XCTAssertEqual(Manager.NameToSeal.name("Family").plaintext, "Family")
    }

    /// A first record the SDK refuses for a list is never tried again on that
    /// list: no line, a log; a refresh the server's flag asks for, and a
    /// removal the person asked for, go ahead, with no record.
    func testARefusedTransitionWaitsForItsListToChange() throws {
        let circles = try source("App/Managers/CircleManager.swift")
        let rotate = try body(of: "    func rotateCircleKey(for circleId: String) async throws {",
                              until: "    // MARK: - Errors", in: circles)
        XCTAssertTrue(rotate.contains("if mode == .transition, transitionRefused(circleId) { mode = .legacy }"))
        XCTAssertTrue(rotate.contains("} catch let refusal as MobileError where mode == .transition {"))
        XCTAssertTrue(rotate.contains("noteTransitionRefused(circleId, refusal)\n                guard circle.keyRotationNeeded || rotationStepPending(circleId) else { return }\n                break"))
        let eject = try body(of: "    func removeMember(from circleId: String, userId: String) async throws {",
                             until: "    func removesWithoutNewKey(_ circleId: String) -> Bool {", in: circles)
        XCTAssertTrue(eject.contains("if mode == .transition, transitionRefused(circleId) { mode = .legacy }"))
        XCTAssertTrue(eject.contains("throw CircleError.ejectFailed(CircleError.notDoneWhileWaitingToSync)\n                }\n                // Its first record"))
        let due = try body(of: "    private func recordedRotationDue(_ circle: Circle) -> Bool {", until: "\n    }\n", in: circles)
        XCTAssertTrue(due.contains("!transitionRefused(circle.id) else { return false }"))
    }

    /// The server takes one rotation of a circle per 30 s: its 429 is tried
    /// again after the reply's Retry-After, else 35 s, plus jitter, never after
    /// the 5 minutes other failures wait (they outlast the read deadline a
    /// departure sets).
    func testARateLimitedRotationIsTriedAgainSoon() throws {
        typealias Manager = Track.CircleManager
        var limited = APIError(code: "rate_limited", message: "x")
        XCTAssertEqual(Manager.rotationRetryDelay(after: limited, jitter: 2), 37)
        limited.retryAfter = 42
        XCTAssertEqual(Manager.rotationRetryDelay(after: limited, jitter: 2), 44, "the reply's Retry-After")
        // Within 30 s to 5 min: never at once, over and over; never for days.
        for (asked, delay) in [(0.0, 32.0), (-5, 32), (12, 32), (86_400, 302), (.nan, 37), (.infinity, 37)] {
            limited.retryAfter = asked
            XCTAssertEqual(Manager.rotationRetryDelay(after: limited, jitter: 2), delay, "Retry-After \(asked)")
        }
        XCTAssertEqual(Manager.rotationRetryDelay(after: APIError(code: "http_429", message: "x"), jitter: 0), 35)
        XCTAssertEqual(Manager.rotationRetryDelay(after: APIError(code: "server_error", message: "x"), jitter: 3), 300)
        XCTAssertEqual(Manager.rotationRetryDelay(after: URLError(.timedOut), jitter: 3), 300)
        XCTAssertEqual(Manager.rotationRetryDelay(after: MobileError.InvalidInput(message: "x"), jitter: 3), 300)
        let api = try source("App/Services/APIService.swift")
        XCTAssertTrue(api.contains("limited.retryAfter = header.flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }"))
        let circles = try source("App/Managers/CircleManager.swift")
        XCTAssertTrue(circles.contains("await self.recordRotationFailure(circle.id, error)"))
        XCTAssertTrue(circles.contains("self.recordRotationFailure(circleId, error)"))
        XCTAssertTrue(circles.contains("Self.rotationRetryDelay(after: error, jitter: .random(in: 0...5)))"))
    }

    /// The person's own revoke and, as the chain's owner, role change go into
    /// the ledger for the device's own next record.
    func testOwnRemovalsAndRoleChangesAreKeptForTheNextRecord() throws {
        let circles = try source("App/Managers/CircleManager.swift")
        let revoke = try body(of: "    func revokeMemberAccess(from circleId: String, userId: String) async throws -> String? {",
                              until: "    /// `keys`: for a promotion to admin", in: circles)
        XCTAssertTrue(revoke.contains("if let me = AuthManager.shared.userId, standing(of: circleId) != .noRecords {\n            RefreshLedger.shared.noteRemoval(account: me, circleId: circleId, userId: userId, at: Date())"))
        // A later decision of this device's person clears it: an admission, a
        // waiting let-in or promotion (not an owed one), a re-invite.
        XCTAssertTrue(circles.contains("RefreshLedger.shared.clearRemoval(account: me, circleId: circleId, userId: userId, decidedAt: Date())"))
        XCTAssertTrue(circles.contains("if case .letIn(let inputs) = change.inputs, inputs.questionKind == \"owed\" {} else {\n            RefreshLedger.shared.clearRemoval(account: me, circleId: circleId, userId: userId, decidedAt: change.createdAt)"))
        // A re-invite only with its signed statement: withdrawn from here, it
        // brings the removal back, in both places an invitation is withdrawn.
        XCTAssertTrue(circles.contains("                invitation = signed.statement\n"))
        XCTAssertTrue(circles.contains("if let me = AuthManager.shared.userId, let inviteeUserId = lookup.userId, let invitation {\n                RefreshLedger.shared.clearRemoval(account: me, circleId: circleId, userId: inviteeUserId,\n                                                  decidedAt: waiting?.createdAt ?? Date(), invitation: invitation)"))
        let withdraw = try body(of: "    func revokeInvite(circleId: String, inviteId: String) async throws {",
                                until: "    func forgetInviteesNoLongerPending(", in: circles)
        XCTAssertTrue(withdraw.contains("        if withdrawn, let statementId, let me = AuthManager.shared.userId {\n            KeyDeliveryApprovals.shared.withdrawInvitation(owner: me, circleId: circleId, statementId: statementId)\n            InvitationRenewals.markWithdrawn(statementId, owner: me)\n            // A re-invite that cleared a removal, withdrawn unused: the\n            // removal is noted again.\n            RefreshLedger.shared.invitationWithdrawn(account: me, circleId: circleId, statementId: statementId)\n        }"))
        let renewals = try source("App/Managers/InvitationRenewals.swift")
        let notThem = try body(of: "    func notThem(_ question: Question) async throws {", until: "    /// Whether this account is an owner or admin", in: renewals)
        XCTAssertTrue(notThem.contains("        if let me = AuthManager.shared.userId {\n            Self.markWithdrawn(question.statementId, owner: me)"))
        XCTAssertTrue(notThem.contains("            RefreshLedger.shared.invitationWithdrawn(account: me, circleId: question.circleId,\n                                                     statementId: question.statementId)\n        }"))
        // Only what still stands is named removed: judged in this circle, with
        // the ids dead here (withdrawn, or a departed member's) left out.
        XCTAssertTrue(circles.contains("? Set(standingRemovals(circle.id, owed.removals, me: me).map(\\.userId)) : []"))
        XCTAssertTrue(circles.contains(
            "        let dead = record.deadStatementIds.union(record.tombstones.values.flatMap(\\.statementIds))\n        return RefreshLedger.removalsStanding(removals, me: me, circleId: circleId, statements: statements, dead: dead,\n"))
        let role = try body(of: "    func updateMemberRole(in circleId: String, userId: String, role: CircleMember.MemberRole,",
                            until: "    private func pruneLocalCircle(circleId: String) {", in: circles)
        // Owed by the chain's owner only: a demotion before the server call,
        // a promotion after it, then the rotation.
        XCTAssertTrue(role.contains("        return cryptoManager.circleHasRefreshRecords(circleId: circleId)\n            && cryptoManager.chainRole(circleId: circleId, userId: me) == .owner\n"))
        XCTAssertTrue(role.contains("            guard RefreshLedger.shared.update(account: me, circleId: circleId, {\n                $0.roleChanges[CanonicalId.key(userId)] = role.rawValue\n            }) else { throw CircleError.roleChangeNotKept }\n"))
        XCTAssertTrue(role.contains("            if record == .owedAfter {\n                RefreshLedger.shared.noteRoleChange(account: me, circleId: circleId, userId: userId, role: role.rawValue)\n            }\n            rotateOwedNow(circleId)"))
    }

    /// After an import: a fresh copy asked for when the report says so, and the
    /// account's head published only when the circle didn't fork.
    /// Every recorded change after a record rejected here names every listed
    /// member that record names, pending those it can't include, a repair or
    /// not: the SDK's `tipNamedListed`, kept from each import with no version
    /// picking of the app's own, used by every kind, and dropped once this
    /// device's own record is taken. The ping-pong stop counts the tip's names
    /// the chain doesn't count here, at the budget and when a repair is taken.
    func testEveryRecordedChangeNamesTheRejectedTipsListedMembers() throws {
        let circles = try source("App/Managers/CircleManager.swift")
        let noted = try body(of: "    private func noteRejected(circleId: String, report: RefreshRecordsReport, me: String) {",
                             until: "\n    }\n", in: circles)
        XCTAssertTrue(noted.contains("        let uncounted = uncountedNamed(report.tipNamedListed, circleId: circleId)\n"))
        XCTAssertTrue(noted.contains(".first { RefreshLedger.mayRepair($0, circle: before, now: Date(), uncountedNamed: uncounted) }"))
        XCTAssertTrue(noted.contains("        tipNamedListed[CanonicalId.key(circleId)] = report.tipNamedListed\n"))
        XCTAssertTrue(circles.contains(
            "        named.filter { cryptoManager.chainRole(circleId: circleId, userId: $0) == nil }\n"))
        XCTAssertTrue(circles.contains(
            "            let rejectedIncluded = Set(tipNamedListed[CanonicalId.key(circle.id)] ?? [])\n"
            + "            if repairing != nil { uncounted = uncountedNamed(Array(rejectedIncluded), circleId: circle.id) }\n"))
        XCTAssertEqual(circles.components(separatedBy: "removing: removing, rejectedIncluded: rejectedIncluded, roleChanges: changes,").count - 1, 2)
        XCTAssertFalse(circles.contains("rejectedTip("), "the SDK names the tip")
        let taken = try body(of: "    private func recordedChangeTaken(", until: "\n    }\n", in: circles)
        XCTAssertTrue(taken.contains("tipNamedListed.removeValue(forKey: CanonicalId.key(circleId))"))
        XCTAssertTrue(taken.contains("RefreshLedger.rejectedFor(repairing, uncountedNamed: change.uncountedNamed)"))
    }

    /// At a plan, before the ledger is read: a re-invite from here that ran
    /// out unused is settled with the complete list.
    func testARunOutReInviteIsSettledAtThePlan() throws {
        let circles = try source("App/Managers/CircleManager.swift")
        let prepare = try body(of: "    private func prepareRecordedChange(", until: "    private func recordedChangeTaken(", in: circles)
        XCTAssertTrue(prepare.contains(
            "            RefreshLedger.shared.settleRunOutReInvites(account: me, circleId: circle.id,\n"
            + "                                                       listed: Set(rows.filter(\\.listed).map(\\.userId)), now: Date())\n"
            + "            let owed = RefreshLedger.shared.circle(account: me, circleId: circle.id)\n"))
        XCTAssertTrue(prepare.contains("guard let listing = recordMemberRows(for: circle.id), listing.complete else {"),
                      "only with a complete list")
    }

    /// An own link goes into a records import where the fetched chain
    /// doesn't serve its versions, one per versions, until an import decides
    /// its version.
    func testOwnLinksGoWithTheFetchedChainUntilAnImportDecidesThem() {
        typealias Manager = Track.CircleManager
        func link(_ from: Int32, _ to: Int32, _ bytes: String) -> KeyChainLinkData {
            KeyChainLinkData(fromVersion: from, toVersion: to, encryptedKey: bytes, nonce: bytes)
        }
        let served = [link(2, 1, "s21")]
        XCTAssertEqual(Manager.importLinks(fetched: served, own: []), served)
        XCTAssertEqual(Manager.importLinks(fetched: served, own: [link(3, 2, "o32")]), [link(2, 1, "s21"), link(3, 2, "o32")])
        XCTAssertEqual(Manager.importLinks(fetched: [link(3, 2, "s32")], own: [link(3, 2, "o32")]), [link(3, 2, "s32")],
                       "the server's copy stays")
        XCTAssertEqual(Manager.importLinks(fetched: [link(3, 1, "s31")], own: [link(3, 2, "o32")]),
                       [link(3, 1, "s31"), link(3, 2, "o32")], "the same from, another to")
        XCTAssertEqual(Manager.importLinks(fetched: [link(4, 2, "s42")], own: [link(3, 2, "o32")]),
                       [link(4, 2, "s42"), link(3, 2, "o32")], "the same to, another from")

        XCTAssertEqual(Manager.noting(link(3, 2, "new"), in: [link(3, 2, "old"), link(2, 1, "o21")]),
                       [link(2, 1, "o21"), link(3, 2, "new")])
        XCTAssertEqual(Manager.noting(link(3, 2, "new"), in: [link(3, 1, "o31"), link(4, 2, "o42")]),
                       [link(3, 1, "o31"), link(4, 2, "o42"), link(3, 2, "new")])

        func status(_ version: Int32, _ state: RecordVersionState) -> RecordVersionStatus {
            RecordVersionStatus(version: version, state: state, problem: RecordProblem.none, notAllowed: [],
                                unmatchedEntries: 0, namedListed: [])
        }
        let own = [link(3, 2, "o32")]
        XCTAssertEqual(Manager.ownLinksAfterImport(own, versions: [status(3, .accepted)]), [])
        XCTAssertEqual(Manager.ownLinksAfterImport(own, versions: [status(3, .reference)]), [])
        XCTAssertEqual(Manager.ownLinksAfterImport(own, versions: [status(3, .rejected)]), [])
        XCTAssertEqual(Manager.ownLinksAfterImport(own, versions: [status(3, .waiting)]), own, "not decided yet")
        XCTAssertEqual(Manager.ownLinksAfterImport(own, versions: [status(2, .accepted)]), own, "another version")
        XCTAssertEqual(Manager.ownLinksAfterImport(own, versions: []), own, "not judged")
    }

    /// An own change taken and not yet decided holds every next record, and a
    /// taken change raises the listed version, never lowering it.
    func testAnUndecidedOwnChangeHoldsTheNextAndATakenOneIsListed() {
        typealias Manager = Track.CircleManager
        let modes: [Manager.RotationMode] = [.legacy, .transition, .recorded(.rotation), .recorded(.repair), .wait]
        for mode in modes {
            XCTAssertEqual(Manager.rotationMode(mode, ownChangeUndecided: true), .wait, "\(mode)")
            XCTAssertEqual(Manager.rotationMode(mode, ownChangeUndecided: false), mode, "\(mode)")
        }
        XCTAssertEqual(Manager.listedVersion(2, taken: 3), 3)
        XCTAssertEqual(Manager.listedVersion(3, taken: 3), 3)
        XCTAssertEqual(Manager.listedVersion(5, taken: 3), 5, "never lowered")
    }

    /// An own change's link is noted only where the server took the change,
    /// goes into every records import, is scoped by the import's report, and
    /// goes where the circle's keys go. While it is there, the next record
    /// waits; a taken change sets the listed version.
    func testOwnLinksAreWiredIn() throws {
        let circles = try source("App/Managers/CircleManager.swift")
        let taken = try body(of: "    private func recordedChangeTaken(", until: "\n    }\n", in: circles)
        XCTAssertTrue(taken.contains(
            "        if let link = change.bundle.rotation.keyChainLink {\n"
            + "            ownLinks[CanonicalId.key(circleId)] = Self.noting(link, in: ownLinks[CanonicalId.key(circleId)] ?? [])\n"
            + "        }\n"))
        XCTAssertEqual(circles.components(separatedBy: "Self.noting(").count - 1, 1, "noted there only")
        XCTAssertEqual(circles.components(separatedBy: "recordedChangeTaken(change, circleId: circle.id, me: me)").count - 1, 2)
        let rotation = try body(of: "    private func sendRecordedRotation(", until: "\n    }\n", in: circles)
        let alreadyRotated = try XCTUnwrap(rotation.range(of: "        if response.alreadyRotated == true {\n"
                                                          + "            _ = cryptoManager.discardUnconfirmedRotation(circleId: circle.id)\n"))
        let rotationTaken = try XCTUnwrap(rotation.range(of: "recordedChangeTaken(change, circleId: circle.id, me: me)"))
        XCTAssertLessThan(alreadyRotated.upperBound, rotationTaken.lowerBound, "a lost race notes nothing")
        let eject = try body(of: "    private func sendRecordedEject(", until: "\n    }\n", in: circles)
        XCTAssertTrue(eject.contains("        } catch {\n"
                                     + "            _ = cryptoManager.discardUnconfirmedRotation(circleId: circle.id)\n"
                                     + "            throw error\n"
                                     + "        }\n"
                                     + "        recordedChangeTaken(change, circleId: circle.id, me: me)\n"),
                      "a refused eject notes nothing")

        let imported = try body(of: "    private func importRefreshRecords() async {",
                                until: "    nonisolated static func importLinks(", in: circles)
        XCTAssertTrue(imported.contains(
            "                keyChain: Self.importLinks(fetched: keyChainsLastImport[CanonicalId.key(circle.id)] ?? [],\n"
            + "                                           own: ownLinks[CanonicalId.key(circle.id)] ?? []))\n"))
        XCTAssertTrue(imported.contains(
            "                changesAwaitingImport.end(circleId)\n"
            + "                // An own link whose version this import decided has done its work.\n"
            + "                if let own = ownLinks[CanonicalId.key(circleId)] {\n"
            + "                    let undecided = Self.ownLinksAfterImport(own, versions: report.versions)\n"
            + "                    ownLinks[CanonicalId.key(circleId)] = undecided.isEmpty ? nil : undecided\n"
            + "                }\n"))
        XCTAssertEqual(circles.components(separatedBy: "ownLinks[CanonicalId.key(circleId)] =").count - 1, 2,
                       "written where noted and where an import decides")

        let reset = try body(of: "    func reset() {\n        circles = []", until: "\n    }\n", in: circles)
        XCTAssertTrue(reset.contains("        keyChainsLastImport.removeAll()\n        ownLinks.removeAll()\n"), "signed out")
        let forget = try body(of: "    private func forgetCircleKeys(_ circleId: String) {", until: "\n    }\n", in: circles)
        XCTAssertTrue(forget.contains("        ownLinks.removeValue(forKey: CanonicalId.key(circleId))"), "left or deleted")
        let prune = try body(of: "    private func pruneLocalCircle(circleId: String) {", until: "\n    }\n", in: circles)
        XCTAssertFalse(prune.contains("ownLinks"), "a roster's 404 or 403 keeps the keys, and the links")
        XCTAssertEqual(circles.components(separatedBy: "ownLinks.remove").count - 1, 2)

        // Every recorded change asks the instance rotationMode.
        let mode = try body(of: "    func rotationMode(for circle: Circle, due: RecordVersionStatus?) -> RotationMode {",
                            until: "\n    }\n", in: circles)
        XCTAssertTrue(mode.hasSuffix(
            "        return Self.rotationMode(mode, ownChangeUndecided: !(ownLinks[CanonicalId.key(circle.id)] ?? []).isEmpty)"))
        // a taken change sets the listed version
        XCTAssertTrue(taken.contains(
            "        if let index = circles.firstIndex(where: { CanonicalId.sameKey($0.id, circleId) }) {\n"
            + "            let listed = Self.listedVersion(circles[index].keyVersion, taken: change.bundle.rotation.newKeyVersion)\n"
            + "            if circles[index].keyVersion != listed {\n"
            + "                circles[index].keyVersion = listed\n"
            + "                if let active = activeCircle, CanonicalId.sameKey(active.id, circleId) {\n"
            + "                    activeCircle = circles[index]\n"))
    }

    func testAnImportsReportIsActedOn() throws {
        let circles = try source("App/Managers/CircleManager.swift")
        let imported = try body(of: "    private func importRefreshRecords() async {",
                                until: "    private func askForFreshCopy(_ circleId: String) async {", in: circles)
        XCTAssertTrue(imported.contains("if report.askForFreshCopy { await askForFreshCopy(id) }"))
        XCTAssertTrue(imported.contains("                if !report.forked {\n                    // Only an accepted head, never while forked, at most one PUT\n"))
        XCTAssertTrue(imported.contains("await AccountHeads.publishIfNeeded(circleId: id, me: me, served: heads)"))
    }
}
