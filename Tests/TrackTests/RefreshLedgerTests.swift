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

/// What a circle's records don't carry yet, per account, and the repair
/// budget.
@MainActor
final class RefreshLedgerTests: XCTestCase {
    private var directory: URL!
    private let me = "0f0f0f0f-1111-2222-3333-444455556666"
    private let other = "9f9f9f9f-1111-2222-3333-444455556666"
    private let circle = "c1c1c1c1-0000-0000-0000-000000000001"
    private let clock = Date(timeIntervalSince1970: 1_800_000_000)
    // Members by account id: only an account's id takes a removal back
    // (CanonicalId.same).
    private let x = "a1000000-0000-4000-8000-00000000000a"
    private let y = "a1000000-0000-4000-8000-00000000000b"
    private let z = "a1000000-0000-4000-8000-00000000000c"
    private let w = "a1000000-0000-4000-8000-00000000000d"

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("refresh-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    /// Kept per account and per circle, on disk: a new launch finds them.
    func testWhatTheChainDoesntCarryYetOutlivesTheProcess() {
        let ledger = RefreshLedger(directory: directory)
        XCTAssertTrue(ledger.update(account: me, circleId: circle.uppercased()) {
            $0.removals.append(RefreshLedger.Removal(userId: "x", at: self.clock))
            $0.roleChanges["y"] = "admin"
        })
        let relaunched = RefreshLedger(directory: directory)
        XCTAssertEqual(relaunched.circle(account: me, circleId: circle).removals.map(\.userId), ["x"])
        XCTAssertEqual(relaunched.circle(account: me, circleId: circle).roleChanges, ["y": "admin"])
        XCTAssertEqual(relaunched.circle(account: other, circleId: circle), RefreshLedger.Circle(),
                       "another account's is its own")
        relaunched.wipeAll()
        XCTAssertEqual(RefreshLedger(directory: directory).circle(account: me, circleId: circle), RefreshLedger.Circle())
    }

    /// An entry an earlier build wrote, with fewer fields, still reads: its
    /// removals stand, and the next write keeps them.
    func testAnEntryAnEarlierBuildWroteStillReads() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"c1c1c1c1-0000-0000-0000-000000000001":{"removals":[{"userId":"x","at":0}]}}"#.utf8)
            .write(to: directory.appendingPathComponent("\(me).json"))
        let ledger = RefreshLedger(directory: directory)
        XCTAssertEqual(ledger.circle(account: me, circleId: circle).removals.map(\.userId), ["x"])
        XCTAssertTrue(ledger.update(account: me, circleId: circle) { $0.roleChanges["y"] = "admin" })
        let relaunched = RefreshLedger(directory: directory).circle(account: me, circleId: circle)
        XCTAssertEqual(relaunched.removals.map(\.userId), ["x"])
        XCTAssertEqual(relaunched.roleChanges, ["y": "admin"])
    }

    /// A file that is there but doesn't decode (damaged, or a newer build's)
    /// is never taken for an empty ledger: nothing is written over it, nothing
    /// it decides runs (`isReadable`), and it's read again at the next use.
    func testAFileThatDoesntDecodeIsNeverWrittenOver() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("\(me).json")
        let damaged = Data("{not json".utf8)
        try damaged.write(to: file)
        let ledger = RefreshLedger(directory: directory)
        XCTAssertFalse(ledger.isReadable(account: me))
        XCTAssertFalse(ledger.noteRemoval(account: me, circleId: circle, userId: "x", at: clock))
        XCTAssertFalse(ledger.update(account: me, circleId: circle) { $0.roleChanges["y"] = "admin" })
        XCTAssertEqual(try Data(contentsOf: file), damaged, "not written over")
        try Data(#"{"c1c1c1c1-0000-0000-0000-000000000001":{"removals":[{"userId":"x","at":0}]}}"#.utf8).write(to: file)
        XCTAssertTrue(ledger.isReadable(account: me))
        XCTAssertEqual(ledger.circle(account: me, circleId: circle).removals.map(\.userId), ["x"])
    }

    /// Protected until the first unlock after a restart, the file can't even
    /// be opened (a folder where it is stands in for that): the same.
    func testAFileThatCantBeOpenedIsNeverWrittenOver() throws {
        let file = directory.appendingPathComponent("\(me).json")
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        let ledger = RefreshLedger(directory: directory)
        XCTAssertFalse(ledger.isReadable(account: me))
        XCTAssertFalse(ledger.update(account: me, circleId: circle) { $0.roleChanges["y"] = "admin" })
        var folder: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path, isDirectory: &folder) && folder.boolValue)
    }

    /// An entry written without the late joiners' answers still reads: the
    /// removals it holds stand, and the next write keeps them.
    func testAnEntryWithoutTheLateJoinersAnswersStillReads() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let written = #"{"c1c1c1c1-0000-0000-0000-000000000001":{"removals":[{"userId":"x","at":0}],"roleChanges":{},"#
            + #""rejectedSeen":[],"repaired":[],"repairs":{}}}"#
        try Data(written.utf8).write(to: directory.appendingPathComponent("\(me).json"))
        let ledger = RefreshLedger(directory: directory)
        XCTAssertEqual(ledger.circle(account: me, circleId: circle).removals.map(\.userId), ["x"])
        let invitation = LateJoiner.Invitation(statementId: "s", signerUserId: other, person: "p", issuedAt: 1)
        XCTAssertTrue(ledger.noteLateJoinerAnswered(account: me, circleId: circle, invitation: invitation))
        let relaunched = RefreshLedger(directory: directory).circle(account: me, circleId: circle)
        XCTAssertEqual(relaunched.removals.map(\.userId), ["x"])
        XCTAssertEqual(relaunched.lateJoinerAnswered, [invitation])
    }

    /// A write that fails changes nothing, and says so.
    func testAWriteThatFailsChangesNothing() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("refresh-file-\(UUID().uuidString)")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let ledger = RefreshLedger(directory: file)  // a file, not a folder: nothing can be written in it
        XCTAssertFalse(ledger.update(account: me, circleId: circle) {
            $0.removals.append(RefreshLedger.Removal(userId: "x", at: self.clock))
        })
        XCTAssertEqual(ledger.circle(account: me, circleId: circle), RefreshLedger.Circle())
    }

    private func rejected(_ version: Int32, _ notAllowed: [String] = []) -> RecordVersionStatus {
        RecordVersionStatus(version: version, state: .rejected, problem: .r2NotAllowed, notAllowed: notAllowed,
                            unmatchedEntries: 0, namedListed: [])
    }

    /// One roster pass first, once per version, once an hour per circle.
    func testTheRepairBudget() {
        var entry = RefreshLedger.Circle()
        XCTAssertFalse(RefreshLedger.mayRepair(rejected(5), circle: entry, now: clock), "first seen: wait a pass")
        entry.rejectedSeen = [5]
        XCTAssertTrue(RefreshLedger.mayRepair(rejected(5), circle: entry, now: clock))
        entry.repaired = [5]
        XCTAssertFalse(RefreshLedger.mayRepair(rejected(5), circle: entry, now: clock), "once per version")
        entry = RefreshLedger.Circle(rejectedSeen: [7], lastRepairAt: clock.addingTimeInterval(-3599))
        XCTAssertFalse(RefreshLedger.mayRepair(rejected(7), circle: entry, now: clock), "once an hour")
        entry.lastRepairAt = clock.addingTimeInterval(-3600)
        XCTAssertTrue(RefreshLedger.mayRepair(rejected(7), circle: entry, now: clock))
    }

    /// The successor of this device's own repair, rejected for the same member
    /// again: it stops (no ping-pong); for someone else, it repairs.
    func testNoRepairOfOwnRepairsSuccessorForTheSameMember() {
        let entry = RefreshLedger.Circle(rejectedSeen: [6], repaired: [4], repairs: ["5": ["X"]])
        XCTAssertFalse(RefreshLedger.mayRepair(rejected(6, ["x"]), circle: entry, now: clock))
        XCTAssertTrue(RefreshLedger.mayRepair(rejected(6, ["y"]), circle: entry, now: clock))
    }

    /// A sign-out keeps it for the same account's next sign-in here. Another
    /// account signing in takes it only by the guarded tidy, once that sign-in
    /// has succeeded (`SignInTidy`); an erasure takes it.
    func testItStaysWithTheAccountAcrossASignOutOnly() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let auth = try String(contentsOf: root.appendingPathComponent("App/Managers/AuthManager.swift"), encoding: .utf8)
        XCTAssertTrue(auth.contains("        BackfillLedger.shared.wipeAll()\n        RefreshLedger.shared.signedOut()\n"))
        XCTAssertEqual(auth.components(separatedBy: "RefreshLedger.shared.wipeAll()").count - 1, 1, "the erasure's only")
        XCTAssertTrue(auth.contains("                KeyDeliveryApprovals.shared.clearAll(exceptOwner: nil)\n"
                                    + "                RefreshLedger.shared.wipeAll()\n"))
        XCTAssertTrue(auth.contains("        SignInTidy.run(signedIn: me, typedEmail: typedEmail)\n"))
        XCTAssertFalse(auth.contains("clearAll(exceptOwner: me)"), "no sign-in clears another account's approvals by itself")
    }

    /// A removal this account still owes a record for survives its sign-out:
    /// the same account signs in again, and its next record names them
    /// removed. The guarded tidy takes another account's; an erasure takes all.
    func testAnOwedRemovalSurvivesASignOutOfTheSameAccount() {
        let removed = "a0a0a0a0-0000-0000-0000-00000000000a"
        let ledger = RefreshLedger(directory: directory)
        XCTAssertTrue(ledger.noteRemoval(account: me, circleId: circle, userId: removed, at: clock))
        XCTAssertTrue(ledger.noteRemoval(account: other, circleId: circle, userId: removed, at: clock))
        ledger.signedOut()
        XCTAssertEqual(ledger.accounts(), [me, other])
        ledger.forget(account: other.uppercased())
        let signedIn = RefreshLedger(directory: directory)
        let owed = signedIn.circle(account: me, circleId: circle)
        XCTAssertEqual(owed.removals, [RefreshLedger.Removal(userId: removed, at: clock)])
        let plan = RecordedRotation.rotationPlan(
            me: me, roster: [RecordedRotation.Listed(userId: me, role: .owner, hasKeys: true)], includable: [],
            blocked: [], counted: [me: .owner, removed: .member], removing: Set(owed.removals.map(\.userId)))
        XCTAssertEqual(plan.first { $0.userId == removed }?.state, .removed)
        XCTAssertEqual(signedIn.circle(account: other, circleId: circle), RefreshLedger.Circle(),
                       "the tidy took the other account's")
        signedIn.wipeAll()
        XCTAssertEqual(RefreshLedger(directory: directory).circle(account: me, circleId: circle), RefreshLedger.Circle(),
                       "an erasure takes all")
    }

    /// An account switch: account A owes a removal, B signs in, and A's file
    /// can't be deleted (the folder refuses). B's ledger and plan still name
    /// nothing of A's: each account reads its own file only. The account is
    /// compared case-insensitively.
    func testAnotherAccountsOwedRemovalsNeverReachANewAccount() throws {
        let removed = "a0a0a0a0-0000-0000-0000-00000000000a"
        let ledger = RefreshLedger(directory: directory)
        XCTAssertTrue(ledger.noteRemoval(account: me.uppercased(), circleId: circle, userId: removed, at: clock))
        ledger.signedOut()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }
        ledger.forget(account: me)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(me).json").path),
                      "the delete failed")
        for reader in [ledger, RefreshLedger(directory: directory)] {
            let owed = reader.circle(account: other, circleId: circle)
            XCTAssertEqual(owed, RefreshLedger.Circle(), "nothing of A's")
            let plan = RecordedRotation.rotationPlan(
                me: other, roster: [RecordedRotation.Listed(userId: other, role: .owner, hasKeys: true)], includable: [],
                blocked: [], counted: [other: .owner, removed: .member], removing: Set(owed.removals.map(\.userId)))
            XCTAssertNil(plan.first { $0.userId == removed })
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        ledger.forget(account: me)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(me).json").path),
                       "gone at the next tidy that can delete it")
    }

    /// What an account's sessions couldn't write stays with the account when
    /// another signs in, and across its sign-out; it goes into the file as
    /// soon as the file takes it, and only the guarded tidy or an erasure
    /// takes it.
    func testWhatAnAccountCouldntWriteStaysWithItAcrossAnotherSignIn() throws {
        let removed = "a0a0a0a0-0000-0000-0000-00000000000a"
        let ledger = RefreshLedger(directory: directory)
        XCTAssertTrue(ledger.noteRemoval(account: me, circleId: circle, userId: "x", at: clock))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }
        XCTAssertFalse(ledger.noteRemoval(account: me, circleId: circle, userId: removed, at: clock), "held, unwritten")
        ledger.signedOut()
        XCTAssertEqual(ledger.circle(account: other, circleId: circle), RefreshLedger.Circle(), "another account signs in")
        XCTAssertTrue(ledger.accounts().contains(me))
        XCTAssertTrue(ledger.circle(account: me, circleId: circle).removals.contains { $0.userId == removed },
                      "still owed on the way back")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        ledger.signedOut()
        XCTAssertTrue(RefreshLedger(directory: directory).circle(account: me, circleId: circle).removals
                        .contains { $0.userId == removed }, "written once the file takes it")

        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        XCTAssertFalse(ledger.noteRemoval(account: me, circleId: circle, userId: "z", at: clock))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        ledger.forget(account: me.uppercased())
        XCTAssertFalse(ledger.accounts().contains(me))
        XCTAssertEqual(ledger.circle(account: me, circleId: circle), RefreshLedger.Circle(), "the tidy took it all")
    }

    /// A sign-out writes what the session couldn't if the file takes it now,
    /// and never writes over a file that doesn't read.
    func testASignOutWritesWhatItCanAndNeverOverAnUnreadableFile() throws {
        let ledger = RefreshLedger(directory: directory)
        XCTAssertTrue(ledger.noteRemoval(account: me, circleId: circle, userId: "x", at: clock))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        XCTAssertFalse(ledger.noteRemoval(account: me, circleId: circle, userId: "y", at: clock))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        ledger.signedOut()
        XCTAssertEqual(Set(RefreshLedger(directory: directory).circle(account: me, circleId: circle).removals.map(\.userId)),
                       ["x", "y"], "written at the sign-out")

        let file = directory.appendingPathComponent("\(me).json")
        let damaged = Data("{not json".utf8)
        try damaged.write(to: file)
        let unreadable = RefreshLedger(directory: directory)
        XCTAssertFalse(unreadable.noteRemoval(account: me, circleId: circle, userId: "z", at: clock))
        unreadable.signedOut()
        XCTAssertEqual(try Data(contentsOf: file), damaged, "not written over")
        XCTAssertFalse(RefreshLedger(directory: directory).isReadable(account: me), "still strict at the next sign-in")
    }

    /// A removal this device's person made is cleared by that person's own
    /// later re-invite or admission from this device, never by one decided
    /// before it.
    func testOnlyALaterDecisionFromThisDeviceClearsARemoval() {
        let ledger = RefreshLedger(directory: directory)
        XCTAssertTrue(ledger.noteRemoval(account: me, circleId: circle, userId: x.uppercased(), at: clock))
        XCTAssertTrue(ledger.clearRemoval(account: me, circleId: circle, userId: x, decidedAt: clock.addingTimeInterval(-60)))
        XCTAssertEqual(ledger.circle(account: me, circleId: circle).removals.map(\.userId), [x.uppercased()], "decided before it")
        XCTAssertTrue(ledger.clearRemoval(account: me, circleId: circle, userId: x, decidedAt: clock.addingTimeInterval(60)))
        XCTAssertTrue(ledger.circle(account: me, circleId: circle).removals.isEmpty)
        // Removed again: the newer time counts.
        ledger.noteRemoval(account: me, circleId: circle, userId: x, at: clock)
        ledger.noteRemoval(account: me, circleId: circle, userId: x, at: clock.addingTimeInterval(120))
        XCTAssertEqual(ledger.circle(account: me, circleId: circle).removals,
                       [RefreshLedger.Removal(userId: x, at: clock.addingTimeInterval(120))])
    }

    /// A removal made while the file can't be read is kept for the session
    /// and counts: it is never lost to a departure. Nothing is written over
    /// the file meanwhile; once it reads, the removal goes in beside what it
    /// holds.
    func testARemovalMadeWhileTheFileCantBeReadIsKeptAndWrittenOnceItReads() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("\(me).json")
        let damaged = Data("{not json".utf8)
        try damaged.write(to: file)
        let ledger = RefreshLedger(directory: directory)
        XCTAssertFalse(ledger.noteRemoval(account: me, circleId: circle, userId: "x", at: clock))
        XCTAssertEqual(ledger.circle(account: me, circleId: circle.uppercased()).removals,
                       [RefreshLedger.Removal(userId: "x", at: clock)])
        XCTAssertEqual(try Data(contentsOf: file), damaged, "not written over")
        try Data(#"{"c1c1c1c1-0000-0000-0000-000000000001":{"removals":[{"userId":"y","at":0}]}}"#.utf8).write(to: file)
        XCTAssertTrue(ledger.isReadable(account: me))
        XCTAssertEqual(Set(ledger.circle(account: me, circleId: circle).removals.map(\.userId)), ["x", "y"])
        let relaunched = RefreshLedger(directory: directory).circle(account: me, circleId: circle)
        XCTAssertEqual(Set(relaunched.removals.map(\.userId)), ["x", "y"], "written as soon as the file read")
    }

    /// A removal whose write fails is kept for the session all the same, a
    /// later decision of the person's still clears it, and what is kept goes
    /// in with the next write that succeeds.
    func testARemovalWhoseWriteFailsIsKeptForTheSession() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let locked: [FileAttributeKey: Any] = [.posixPermissions: 0o555]
        let open: [FileAttributeKey: Any] = [.posixPermissions: 0o755]
        let ledger = RefreshLedger(directory: directory)
        try FileManager.default.setAttributes(locked, ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes(open, ofItemAtPath: directory.path) }
        XCTAssertFalse(ledger.noteRemoval(account: me, circleId: circle, userId: x, at: clock))
        XCTAssertFalse(ledger.noteRemoval(account: me, circleId: circle, userId: y, at: clock))
        XCTAssertEqual(ledger.circle(account: me, circleId: circle).removals.map(\.userId), [x, y])
        XCTAssertFalse(ledger.clearRemoval(account: me, circleId: circle, userId: y, decidedAt: clock.addingTimeInterval(60)))
        XCTAssertEqual(ledger.circle(account: me, circleId: circle).removals.map(\.userId), [x])
        XCTAssertNil(try? Data(contentsOf: directory.appendingPathComponent("\(me).json")), "nothing written")
        try FileManager.default.setAttributes(open, ofItemAtPath: directory.path)
        XCTAssertTrue(ledger.update(account: me, circleId: circle) { $0.roleChanges["z"] = "admin" })
        let relaunched = RefreshLedger(directory: directory).circle(account: me, circleId: circle)
        XCTAssertEqual(relaunched.removals.map(\.userId), [x])
        XCTAssertEqual(relaunched.roleChanges, ["z": "admin"])
    }

    private func invitation(_ id: String, about subject: String, until: Date) -> MembershipStatement {
        MembershipStatement(
            kind: .invitationToAccount, circleId: circle, statementId: id, signerUserId: me,
            issuedAt: Int64(until.timeIntervalSince1970) - 604_800, expiresAt: Int64(until.timeIntervalSince1970),
            atVersion: 3, subjectUserId: subject, subjectSharingPublicKeyHex: nil, subjectSigningPublicKeyHex: nil,
            subjectEmail: nil)
    }

    /// A re-invite from here that cleared a removal, withdrawn from here: the
    /// removal is noted again, as it was, also after a relaunch. Once only.
    /// Another invitation, or a clear that came with no invitation (an
    /// admission), brings nothing back; a later removal of them stays as it is.
    func testAWithdrawnReInviteBringsTheRemovalBack() {
        let removal = RefreshLedger.Removal(userId: x.uppercased(), at: clock)
        let week = Date().addingTimeInterval(604_800)  // the pruning goes by the real time
        var ledger = RefreshLedger(directory: directory)
        XCTAssertTrue(ledger.noteRemoval(account: me, circleId: circle, userId: x.uppercased(), at: clock))
        XCTAssertTrue(ledger.clearRemoval(account: me, circleId: circle, userId: x, decidedAt: clock.addingTimeInterval(60),
                                          invitation: invitation("S1", about: x, until: week)))
        XCTAssertTrue(ledger.circle(account: me, circleId: circle).removals.isEmpty)
        ledger = RefreshLedger(directory: directory)
        XCTAssertTrue(ledger.invitationWithdrawn(account: me, circleId: circle, statementId: "s2"))
        XCTAssertTrue(ledger.circle(account: me, circleId: circle).removals.isEmpty, "another invitation")
        XCTAssertTrue(ledger.invitationWithdrawn(account: me, circleId: circle.uppercased(), statementId: "s1"))
        XCTAssertEqual(ledger.circle(account: me, circleId: circle).removals, [removal])
        XCTAssertEqual(RefreshLedger(directory: directory).circle(account: me, circleId: circle).removals, [removal],
                       "on file")
        // Cleared by an admission now: withdrawing S1 again brings nothing back.
        XCTAssertTrue(ledger.clearRemoval(account: me, circleId: circle, userId: x, decidedAt: clock.addingTimeInterval(90)))
        XCTAssertTrue(ledger.invitationWithdrawn(account: me, circleId: circle, statementId: "S1"))
        XCTAssertTrue(ledger.circle(account: me, circleId: circle).removals.isEmpty, "once only")
        // Removed again later than the removal a withdrawn re-invite cleared:
        // the later one stays.
        XCTAssertTrue(ledger.noteRemoval(account: me, circleId: circle, userId: x, at: clock.addingTimeInterval(100)))
        XCTAssertTrue(ledger.clearRemoval(account: me, circleId: circle, userId: x, decidedAt: clock.addingTimeInterval(200),
                                          invitation: invitation("S3", about: x, until: week)))
        XCTAssertTrue(ledger.noteRemoval(account: me, circleId: circle, userId: x, at: clock.addingTimeInterval(300)))
        XCTAssertTrue(ledger.invitationWithdrawn(account: me, circleId: circle, statementId: "S3"))
        XCTAssertEqual(ledger.circle(account: me, circleId: circle).removals,
                       [RefreshLedger.Removal(userId: x, at: clock.addingTimeInterval(300))])
    }

    /// At the plan: a re-invite from here that ran out unused brings its
    /// removal back when the member isn't on the complete list; one who is
    /// (they joined with it) stays cleared and is never removed. Either way its
    /// entry goes; one still running stays as it is.
    func testARunOutReInviteBringsItsRemovalBackUnlessTheyAreListed() {
        let ledger = RefreshLedger(directory: directory)
        let now = Date()
        let ended = now.addingTimeInterval(-60), running = now.addingTimeInterval(86_400)
        for (user, until) in [(x, ended), (y, ended), (z, running)] {
            XCTAssertTrue(ledger.noteRemoval(account: me, circleId: circle, userId: user, at: clock))
            XCTAssertTrue(ledger.clearRemoval(account: me, circleId: circle, userId: user, decidedAt: clock.addingTimeInterval(60),
                                              invitation: invitation("s-\(user)", about: user, until: until)))
        }
        XCTAssertTrue(ledger.circle(account: me, circleId: circle).removals.isEmpty)
        XCTAssertTrue(ledger.settleRunOutReInvites(account: me, circleId: circle.uppercased(), listed: [y.uppercased(), w],
                                                   now: now))
        let settled = RefreshLedger(directory: directory).circle(account: me, circleId: circle)
        XCTAssertEqual(settled.removals, [RefreshLedger.Removal(userId: x, at: clock)],
                       "x ran out and isn't listed: back, as it was; y joined with it: never removed")
        XCTAssertEqual(Array(settled.clearedByInvitations.keys), ["s-\(z)"], "z's invitation still runs")
        XCTAssertTrue(ledger.settleRunOutReInvites(account: me, circleId: circle, listed: [], now: now))
        XCTAssertEqual(ledger.circle(account: me, circleId: circle).removals.map(\.userId), [x], "nothing more ran out")
        XCTAssertTrue(ledger.settleRunOutReInvites(account: me, circleId: circle, listed: [],
                                                   now: running.addingTimeInterval(1)))
        XCTAssertEqual(ledger.circle(account: me, circleId: circle).removals.map(\.userId), [x, z])
        XCTAssertTrue(ledger.circle(account: me, circleId: circle).clearedByInvitations.isEmpty)
    }

    /// The ping-pong stop counts the rejected tip's names the chain doesn't
    /// count here, not only the eligibility rule's refusals: the successor
    /// of this device's own repair, rejected for a newcomer nobody here
    /// matched (no id in `notAllowed`), stops too; one rejected for someone
    /// else doesn't. A repair keeps both kinds.
    func testThePingPongStopCountsTheTipsUncountedNames() {
        let entry = RefreshLedger.Circle(rejectedSeen: [6], repaired: [4], repairs: ["5": ["n"]])
        let unmatched = RecordVersionStatus(version: 6, state: .rejected, problem: .r2UnmatchedEntry, notAllowed: [],
                                            unmatchedEntries: 1, namedListed: ["N", "m"])
        XCTAssertTrue(RefreshLedger.mayRepair(unmatched, circle: entry, now: clock), "notAllowed alone can't see them")
        XCTAssertFalse(RefreshLedger.mayRepair(unmatched, circle: entry, now: clock, uncountedNamed: ["N"]))
        XCTAssertTrue(RefreshLedger.mayRepair(unmatched, circle: entry, now: clock, uncountedNamed: ["m"]),
                      "rejected for someone else: it repairs")
        XCTAssertEqual(RefreshLedger.rejectedFor(rejected(5, ["X"]), uncountedNamed: ["N", "x"]), ["n", "x"])
    }

    /// While the file can't be read, re-invites' clears and a withdrawal are
    /// kept for the session, and made on what the file holds, in order, once
    /// it reads: the withdrawn one's removal stands, the other is cleared.
    func testClearsAndWithdrawalsWhileTheFileCantBeReadAreMadeOnItOnceItReads() throws {
        let week = Date().addingTimeInterval(604_800)  // the pruning goes by the real time
        let ledger = RefreshLedger(directory: directory)
        XCTAssertTrue(ledger.noteRemoval(account: me, circleId: circle, userId: x, at: clock))
        XCTAssertTrue(ledger.noteRemoval(account: me, circleId: circle, userId: y, at: clock))
        let file = directory.appendingPathComponent("\(me).json")
        let good = try Data(contentsOf: file)
        try Data("{not json".utf8).write(to: file)
        let relaunched = RefreshLedger(directory: directory)
        XCTAssertFalse(relaunched.clearRemoval(account: me, circleId: circle, userId: x, decidedAt: clock.addingTimeInterval(60),
                                               invitation: invitation("s1", about: x, until: week)))
        XCTAssertFalse(relaunched.clearRemoval(account: me, circleId: circle, userId: y, decidedAt: clock.addingTimeInterval(60),
                                               invitation: invitation("s2", about: y, until: week)))
        XCTAssertFalse(relaunched.invitationWithdrawn(account: me, circleId: circle, statementId: "S1"))
        try good.write(to: file)
        XCTAssertEqual(relaunched.circle(account: me, circleId: circle).removals, [RefreshLedger.Removal(userId: x, at: clock)])
        let again = RefreshLedger(directory: directory).circle(account: me, circleId: circle)
        XCTAssertEqual(again.removals, [RefreshLedger.Removal(userId: x, at: clock)], "written as soon as it read")
        XCTAssertEqual(Array(again.clearedByInvitations.keys), ["s2"])
    }

    /// While writes fail, a re-invite's clear and its withdrawal hold for the
    /// session, and go in with the next write that succeeds.
    func testAClearAndItsWithdrawalWhileWritesFailHoldForTheSession() throws {
        let ledger = RefreshLedger(directory: directory)
        XCTAssertTrue(ledger.noteRemoval(account: me, circleId: circle, userId: x, at: clock))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }
        XCTAssertFalse(ledger.clearRemoval(account: me, circleId: circle, userId: x, decidedAt: clock.addingTimeInterval(60),
                                           invitation: invitation("s1", about: x, until: Date().addingTimeInterval(604_800))))
        XCTAssertTrue(ledger.circle(account: me, circleId: circle).removals.isEmpty)
        XCTAssertFalse(ledger.invitationWithdrawn(account: me, circleId: circle, statementId: "s1"))
        XCTAssertEqual(ledger.circle(account: me, circleId: circle).removals, [RefreshLedger.Removal(userId: x, at: clock)])
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        XCTAssertTrue(ledger.update(account: me, circleId: circle) { $0.roleChanges["z"] = "admin" })
        let relaunched = RefreshLedger(directory: directory).circle(account: me, circleId: circle)
        XCTAssertEqual(relaunched.removals, [RefreshLedger.Removal(userId: x, at: clock)])
        XCTAssertTrue(relaunched.clearedByInvitations.isEmpty)
    }

    private final class Checker: MembershipStatementChecking {
        var parsed: [String: MembershipStatement] = [:]
        var signers: [String: OwnStatementSigner] = [:]
        func parse(_ statementHex: String) throws -> MembershipStatement {
            guard let statement = parsed[statementHex] else { throw MobileError.InvalidInput(message: "unknown") }
            return statement
        }
        func verify(statementHex: String, signatureHex: String, signerKeyHex: String) throws -> Bool { false }
        func pinnedSigningKey(circleId: String, userId: String) -> String? { nil }
        func pinnedSharingKey(circleId: String, userId: String) -> String? { nil }
        func ownSigningKey() -> String? { nil }
        func ownSigner(statementHex: String, signatureHex: String) -> OwnStatementSigner? { signers[statementHex] }
        func holdsPreviousIdentity(sharingKeyHex: String) -> Bool { false }
    }

    /// A removal made while behind stands at the next rotation even if someone
    /// re-invited the member, except that a NEWER statement about them IN THIS
    /// CIRCLE, signed by THIS account under its CURRENT key (another of its
    /// devices), clears it. Another admin's, an older one, one under a key from
    /// before a reset, one about someone else, one from another circle, or one
    /// this account withdrew doesn't.
    func testANewerStatementOfThisAccountClearsAPendingRemoval() {
        let checker = Checker()
        let removed = "a0a0a0a0-0000-0000-0000-00000000000a"
        let other = "b0b0b0b0-0000-0000-0000-00000000000b"
        func statement(_ id: String, by signer: String, about subject: String, at offset: TimeInterval,
                       signer own: OwnStatementSigner?, in circleId: String? = nil) -> SignedStatementRecord {
            checker.parsed[id] = MembershipStatement(
                kind: .invitationToAccount, circleId: circleId ?? circle, statementId: id, signerUserId: signer,
                issuedAt: Int64(clock.addingTimeInterval(offset).timeIntervalSince1970), expiresAt: 0, atVersion: 3,
                subjectUserId: subject, subjectSharingPublicKeyHex: nil, subjectSigningPublicKeyHex: nil, subjectEmail: nil)
            checker.signers[id] = own
            return SignedStatementRecord(statementHex: id, signatureHex: "00")
        }
        let removal = RefreshLedger.Removal(userId: removed, at: clock)
        func stands(_ statements: [SignedStatementRecord], dead: Set<String> = []) -> Bool {
            !RefreshLedger.removalsStanding([removal], me: me, circleId: circle.uppercased(),
                                            statements: [removed.uppercased(): statements], dead: dead,
                                            checker: checker).isEmpty
        }
        XCTAssertTrue(stands([]))
        XCTAssertFalse(stands([statement("mine", by: me, about: removed, at: 60, signer: .currentKey)]))
        XCTAssertTrue(stands([statement("older", by: me, about: removed, at: -60, signer: .currentKey)]))
        XCTAssertTrue(stands([statement("admin", by: other, about: removed, at: 60, signer: .notOurs)]),
                      "another admin's statement doesn't clear it")
        XCTAssertTrue(stands([statement("old key", by: me, about: removed, at: 60, signer: .previousKey)]))
        XCTAssertTrue(stands([statement("someone else", by: me, about: other, at: 60, signer: .currentKey)]))
        XCTAssertTrue(stands([statement("forged", by: me, about: removed, at: 60, signer: .notOurs)]),
                      "a statement that says it's this account's but doesn't verify")
        XCTAssertTrue(stands([statement("elsewhere", by: me, about: removed, at: 60, signer: .currentKey,
                                        in: "c2c2c2c2-0000-0000-0000-000000000002")]),
                      "this account's newer statement in ANOTHER circle, served on their row")
        XCTAssertTrue(stands([statement("withdrawn", by: me, about: removed, at: 60, signer: .currentKey)],
                             dead: ["WITHDRAWN"]), "a re-invite this account withdrew")
        XCTAssertFalse(stands([statement("live", by: me, about: removed, at: 60, signer: .currentKey)], dead: ["withdrawn"]),
                       "a live re-invite here still clears it")
    }

    /// Only versions still rejected as repairable
    /// (`RecordedRotation.repairable`) stay seen.
    func testRejectedSeenFollowsTheLastReport() {
        let versions = [rejected(6), RecordVersionStatus(version: 3, state: .rejected, problem: .signature,
                                                         notAllowed: [], unmatchedEntries: 0, namedListed: []),
                        RecordVersionStatus(version: 4, state: .accepted, problem: .none, notAllowed: [],
                                            unmatchedEntries: 0, namedListed: []), rejected(5)]
        XCTAssertEqual(RefreshLedger.rejectedSeen(after: versions), [5, 6])
    }
}
