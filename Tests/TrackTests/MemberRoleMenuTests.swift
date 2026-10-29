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

/// The member menu offers the role change that applies: "Make Admin" for a
/// member, "Remove as Admin" for an admin, and neither where it wouldn't take
/// effect.
///
/// WHY THIS IS WORTH TESTING
///   An owner who promoted someone by mistake (an admin can remove members and
///   re-key the circle) must be able to undo it from the phone, as the web
///   ("Make admin" / "Remove admin") and Android (Member / Admin) allow. "Make
///   Admin" on an admin would run the promotion again — and for someone
///   invited by email ask its "Is this really …" question — for no change.
///   The server takes both directions (`role` 'admin' | 'member', owner only).
///
///   Roles reach the other apps only through the chain owner's record: a
///   demotion that record misses fails UNSAFE, every other app honouring an
///   admin the owner removed. So a demotion is owed before the server hears of
///   it, nothing is sent while the ledger can't take it, and no role change is
///   offered where no record of this device's would carry it (a claimant's
///   circle).
@MainActor
final class MemberRoleMenuTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// The member row, from its declaration to the next view in the file.
    private func memberRow() throws -> String {
        let view = try source("App/Views/Circles/CirclesView.swift")
        let start = try XCTUnwrap(view.range(of: "struct MemberRow: View {"))
        let end = try XCTUnwrap(view.range(of: "\nstruct ", range: start.upperBound..<view.endIndex))
        return String(view[start.lowerBound..<end.lowerBound])
    }

    /// `updateMemberRole`, from its signature to the rule after it.
    private func updateMemberRole() throws -> String {
        let manager = try source("App/Managers/CircleManager.swift")
        let start = try XCTUnwrap(manager.range(of: "    func updateMemberRole(in circleId: String, userId: String, role: CircleMember.MemberRole,"))
        let end = try XCTUnwrap(manager.range(of: "    /// How a role change is owed to the circle's records", range: start.upperBound..<manager.endIndex))
        return String(manager[start.lowerBound..<end.lowerBound])
    }

    // MARK: - The menu

    func testEachRoleIsOfferedTheChangeThatApplies() {
        XCTAssertEqual(MemberRow.roleChange(for: .member), .makeAdmin)
        XCTAssertEqual(MemberRow.roleChange(for: .admin), .removeAdmin, "an admin can be made a member again")
        XCTAssertNil(MemberRow.roleChange(for: .owner), "the owner's role moves only with the circle")
    }

    func testTheFailureNamesTheChangeThatDidNotGoThrough() {
        XCTAssertEqual(MemberRow.roleFailureTitle(.makeAdmin, name: "Ava"), "Couldn't make Ava an admin")
        XCTAssertEqual(MemberRow.roleFailureTitle(.removeAdmin, name: "Ava"), "Couldn't remove Ava as an admin")
    }

    /// The menu asks `roleChange` for its button, where role changes take
    /// effect: "Make Admin" only for a member, "Remove as Admin" for an admin
    /// ("Remove Admin" would read as removing the person), and "Remove from
    /// Circle" either way.
    func testTheMenuOffersOneRoleChangeByRole() throws {
        let row = try memberRow()
        XCTAssertTrue(row.contains("""
                        if canManage {
                            if canChangeRole {
                                switch Self.roleChange(for: member.role) {
                                case .makeAdmin?:
                                    Button("Make Admin") {
        """))
        XCTAssertTrue(row.contains("""
                                case .removeAdmin?:
                                    Button("Remove as Admin") { demote() }
                                case nil:
                                    EmptyView()
                                }
                            }

                            Button("Transfer Ownership") {
        """))
        // One "Make Admin" in the menu (the other is the promotion question's).
        XCTAssertEqual(row.components(separatedBy: "Button(\"Make Admin\")").count - 1, 2)
        XCTAssertEqual(row.components(separatedBy: "Button(\"Remove as Admin\")").count - 1, 1)
        XCTAssertFalse(row.contains("Button(\"Remove Admin\")"))
    }

    /// A demotion is the plain role change: no admission, and no question.
    /// Its failure says which change failed.
    func testRemoveAsAdminMakesThemAMember() throws {
        let row = try memberRow()
        XCTAssertTrue(row.contains("""
            private func demote() {
                Task {
                    do {
                        try await circleManager.updateMemberRole(in: circle.id, userId: member.userId, role: .member)
                    } catch {
                        roleErrorChange = .removeAdmin
                        roleError = error.plainText
                    }
                }
            }
        """))
        XCTAssertTrue(row.contains("                Self.roleFailureTitle(roleErrorChange, name: member.displayName),\n"))
        // Only a promotion signs an admission first.
        let manager = try source("App/Managers/CircleManager.swift")
        XCTAssertTrue(manager.contains("""
                // A new admin invites and admits others, so every app must be able to
                // rely on their signing key: an admission — which also lifts a
                // receive-only (kind-2) member. It carries this device's version,
                // so not while behind.
                if role == .admin {
        """))
    }

    // MARK: - Where a role change takes effect

    /// The Android app's rule: on a circle without records the first record
    /// takes the list's roles; on one with records only the chain owner's
    /// record changes a role; and nothing while its records wait here.
    func testARoleChangeTakesEffectOnlyWhereARecordCarriesIt() {
        XCTAssertTrue(CircleManager.roleChangesTakeEffect(standing: .noRecords, chainOwner: false))
        XCTAssertTrue(CircleManager.roleChangesTakeEffect(standing: .recorded, chainOwner: true))
        XCTAssertFalse(CircleManager.roleChangesTakeEffect(standing: .recorded, chainOwner: false),
                       "a claimant's circle: the records keep their owner, and no record of this device's changes a role")
        XCTAssertFalse(CircleManager.roleChangesTakeEffect(standing: .wait, chainOwner: true),
                       "a fresh install before its import: whether a record is owed isn't known yet")
    }

    func testTheMenuAsksWhetherRoleChangesTakeEffect() throws {
        let row = try memberRow()
        XCTAssertTrue(row.contains("""
            private var canChangeRole: Bool {
                canManage && circleManager.roleChangesTakeEffect(circle.id)
            }
        """))
        let manager = try source("App/Managers/CircleManager.swift")
        XCTAssertTrue(manager.contains(
            "        Self.roleChangesTakeEffect(standing: standing(of: circleId), chainOwner: writesRoleRecords(circleId))\n"))
        // And at the change itself: nothing while the records wait, as a
        // waiting change (the runner waits on `.waitingToSync`).
        let body = try updateMemberRole()
        let wait = try XCTUnwrap(body.range(of: "        guard standing(of: circleId) != .wait else { throw CircleError.waitingToSync }\n"))
        let readable = try XCTUnwrap(body.range(of: "RefreshLedger.shared.isReadable(account: me)"))
        XCTAssertLessThan(wait.lowerBound, readable.lowerBound, "first of all")
    }

    // MARK: - What the record owes can't be lost

    func testADemotionIsOwedFirstAndAPromotionAfter() {
        XCTAssertEqual(CircleManager.roleRecord(chainOwner: true, role: .member), .owedFirst,
                       "lost after the server's yes, every other app would go on honouring them")
        XCTAssertEqual(CircleManager.roleRecord(chainOwner: true, role: .admin), .owedAfter,
                       "lost, a promotion fails safe")
        XCTAssertEqual(CircleManager.roleRecord(chainOwner: false, role: .member), .notOwed)
        XCTAssertEqual(CircleManager.roleRecord(chainOwner: false, role: .admin), .notOwed)
    }

    /// Nothing is signed or sent while the ledger can't be read; a demotion
    /// is written before the server call and sends nothing if it can't be,
    /// and is taken back on a refusal; a promotion is owed after the server's
    /// yes, held for the session if the file can't take it.
    func testTheOwedChangeIsWrittenInTheRightPlace() throws {
        let body = try updateMemberRole()
        let readable = try XCTUnwrap(body.range(of: "            guard let me, RefreshLedger.shared.isReadable(account: me) else { throw CircleError.roleChangeNotKept }\n"))
        let admission = try XCTUnwrap(body.range(of: "        if role == .admin {\n"))
        let owedFirst = try XCTUnwrap(body.range(of: """
                    guard RefreshLedger.shared.update(account: me, circleId: circleId, {
                        $0.roleChanges[CanonicalId.key(userId)] = role.rawValue
                    }) else { throw CircleError.roleChangeNotKept }

        """))
        let sent = try XCTUnwrap(body.range(of: "            _ = try await api.updateMemberRole(circleId: circleId, userId: userId, role: role.rawValue)\n"))
        let takenBack = try XCTUnwrap(body.range(of: """
                    if let me, case .some(let before) = owedBefore {
                        RefreshLedger.shared.noteRoleChange(account: me, circleId: circleId, userId: userId, role: before)
                    }
                    throw error

        """))
        let owedAfter = try XCTUnwrap(body.range(of: """
                    if record == .owedAfter {
                        RefreshLedger.shared.noteRoleChange(account: me, circleId: circleId, userId: userId, role: role.rawValue)
                    }
                    rotateOwedNow(circleId)

        """))
        XCTAssertLessThan(readable.lowerBound, admission.lowerBound, "checked before anything is signed")
        XCTAssertLessThan(owedFirst.lowerBound, sent.lowerBound, "a demotion is owed before the server hears of it")
        XCTAssertLessThan(sent.lowerBound, takenBack.lowerBound)
        XCTAssertLessThan(takenBack.lowerBound, owedAfter.lowerBound)
        // A demotion goes out while behind: only a promotion waits for the
        // current version (it signs an admission).
        let waits = try XCTUnwrap(body.range(of: "            guard holdsCurrentKey(for: circleId) else {\n"))
        XCTAssertLessThan(admission.lowerBound, waits.lowerBound)
        XCTAssertLessThan(waits.lowerBound, owedFirst.lowerBound)
        XCTAssertEqual(body.components(separatedBy: "holdsCurrentKey(").count - 1, 1)
        // And the sweep reads what is owed: a role change a record can carry
        // makes a rotation due (the shared role vector's `due`,
        // RoleChangesVectorTests).
        let manager = try source("App/Managers/CircleManager.swift")
        XCTAssertTrue(manager.contains("return roleChangesDue(circle.id, owed: owed.roleChanges, me: me)"))
    }

    /// The ledger keeps an owed role change: written, read back under any
    /// spelling of the member's id, taken back by nil; and when the file can't
    /// take it, kept for the session and written with the next write that
    /// succeeds. A demotion's own write (`update`) fails there instead, so the
    /// demotion is never sent.
    func testTheLedgerKeepsAnOwedRoleChange() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("roles-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let me = "0f0f0f0f-1111-2222-3333-444455556666"
        let circle = "c1c1c1c1-0000-0000-0000-000000000001"
        let ava = "a1000000-0000-4000-8000-00000000000a"
        let ben = "a1000000-0000-4000-8000-00000000000b"
        let ledger = RefreshLedger(directory: directory)
        XCTAssertTrue(ledger.noteRoleChange(account: me, circleId: circle, userId: ava.uppercased(), role: "member"))
        XCTAssertEqual(ledger.circle(account: me, circleId: circle).roleChanges, [ava: "member"])
        XCTAssertTrue(ledger.noteRoleChange(account: me, circleId: circle, userId: ava, role: nil))
        XCTAssertEqual(ledger.circle(account: me, circleId: circle).roleChanges, [:], "taken back")

        let locked: [FileAttributeKey: Any] = [.posixPermissions: 0o555]
        let open: [FileAttributeKey: Any] = [.posixPermissions: 0o755]
        try FileManager.default.setAttributes(locked, ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes(open, ofItemAtPath: directory.path) }
        XCTAssertFalse(ledger.update(account: me, circleId: circle) { $0.roleChanges[ava] = "member" },
                       "a demotion's own write fails: it is not sent")
        XCTAssertEqual(ledger.circle(account: me, circleId: circle).roleChanges, [:], "and nothing is owed")
        XCTAssertFalse(ledger.noteRoleChange(account: me, circleId: circle, userId: ben, role: "admin"))
        XCTAssertEqual(ledger.circle(account: me, circleId: circle).roleChanges, [ben: "admin"], "kept for the session")
        try FileManager.default.setAttributes(open, ofItemAtPath: directory.path)
        XCTAssertTrue(ledger.noteRemoval(account: me, circleId: circle, userId: ava, at: Date(timeIntervalSince1970: 1_800_000_000)))
        let relaunched = RefreshLedger(directory: directory).circle(account: me, circleId: circle)
        XCTAssertEqual(relaunched.roleChanges, [ben: "admin"], "written with the next write that succeeded")
    }
}
