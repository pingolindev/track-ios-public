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

import CryptoKit
import XCTest
import PingolinTrackSDK
@testable import Track

/// Owed role changes in a circle with records, run against the vector the
/// apps share (Fixtures/role-changes-vector.json): when a record is due, what
/// it names, what it settles.
///
/// WHY THIS IS WORTH TESTING
///   Settling a record's role changes by member alone is unsafe: "Make admin"
///   and then "Remove admin" while that record is on its way would leave the
///   chain counting them an admin, with nothing owed — a lost demotion fails
///   unsafe. And if any owed change on an owner's or admin's device made a
///   record due, a change no record can carry (never named, not includable)
///   would rotate the circle on every sweep.
final class RoleChangesVectorTests: XCTestCase {

    private static let sha256 = "d7ac0420bcb83c2f60e5292ad3c81f559e2ca5788fb212a8b4bee5d2fd31cf93"

    private func vectorData() throws -> Data {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/role-changes-vector.json")
        return try Data(contentsOf: url)
    }

    private func role(_ value: Any?) -> CircleRole? {
        switch value as? String {
        case "owner": return .owner
        case "admin": return .admin
        case "member": return .member
        default: return nil
        }
    }

    /// `canonical`: the ledger's own form (it is canonical by construction).
    /// The rules are given the case's spelling as it stands, so the vector's
    /// case R10 asks them to match an id spelled otherwise.
    private func roles(_ value: Any?, canonical: Bool = false) -> [String: CircleRole] {
        (value as? [String: String] ?? [:]).reduce(into: [:]) { out, pair in
            if let role = role(pair.value) { out[canonical ? CanonicalId.key(pair.key) : pair.key] = role }
        }
    }

    private func names(_ roles: [String: CircleRole]) -> [String: String] {
        roles.mapValues(RecordedRotation.roleName)
    }

    /// The fixture is the shared vector, unchanged.
    func testTheFixtureIsTheSharedVector() throws {
        let digest = SHA256.hash(data: try vectorData()).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, Self.sha256)
    }

    func testEveryCase() throws {
        let object = try JSONSerialization.jsonObject(with: try vectorData())
        let cases = try XCTUnwrap((object as? [String: Any])?["cases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 12, "R1–R10 with R5b and R6b")
        for vectorCase in cases {
            let name = try XCTUnwrap(vectorCase["name"] as? String)
            let input = try XCTUnwrap(vectorCase["input"] as? [String: Any])
            let expect = try XCTUnwrap(vectorCase["expect"] as? [String: Any])
            let me = try XCTUnwrap(input["me"] as? String)
            let myChainRole = role(input["myChainRole"])
            let owed = roles(input["owed"])
            let members = try XCTUnwrap(input["members"] as? [[String: Any]]).map { fields in
                RecordedRotation.RoleMember(
                    userId: fields["userId"] as? String ?? "", listed: fields["listed"] as? Bool ?? false,
                    hasKeys: fields["hasKeys"] as? Bool ?? false, eligible: fields["eligible"] as? Bool ?? false,
                    chainRole: role(fields["chainRole"]))
            }

            // due
            XCTAssertEqual(RecordedRotation.roleChangesDue(myChainRole: myChainRole, owed: owed, members: members),
                           expect["due"] as? Bool, "\(name): due")

            // plan: the shared rotation plan, with the roles this device writes
            var counted: [String: CircleRole] = [:]
            for member in members { if let chainRole = member.chainRole { counted[member.userId] = chainRole } }
            let plan = RecordedRotation.rotationPlan(
                me: me,
                roster: members.filter(\.listed).map { RecordedRotation.Listed(userId: $0.userId, role: .member, hasKeys: $0.hasKeys) },
                includable: Set(members.filter { $0.hasKeys && $0.eligible }.map(\.userId)), blocked: [],
                counted: counted, removing: [],
                roleChanges: RecordedRotation.writtenRoles(myChainRole: myChainRole, owed: owed))
            let expectedPlan = try XCTUnwrap(expect["plan"] as? [String: [String: Any]])
            for (userId, entry) in expectedPlan {
                let planned = plan.first { CanonicalId.sameKey($0.userId, userId) }
                let state: String
                switch planned?.state {
                case .included?: state = "included"
                case .pending?: state = "pending"
                case nil: state = "absent"
                default: state = "other"
                }
                XCTAssertEqual(state, entry["state"] as? String, "\(name): \(userId)'s state")
                XCTAssertEqual(planned?.role.map(RecordedRotation.roleName), entry["role"] as? String, "\(name): \(userId)'s role")
            }

            // settles, and what stays owed, when the server takes it
            let carried = RecordedRotation.roleChangesSettled(
                owed: owed, myChainRole: myChainRole, listed: Set(members.filter(\.listed).map(\.userId)), plan: plan)
            let atTake = names(roles(input["ledgerAtTake"] ?? input["owed"], canonical: true))
            let after = RefreshLedger.settling(atTake, taken: names(carried))
            let settled = atTake.filter { after[$0.key] == nil }
            XCTAssertEqual(settled, try XCTUnwrap(expect["settles"] as? [String: String]), "\(name): settles")
            XCTAssertEqual(after, try XCTUnwrap(expect["owedAfter"] as? [String: String]), "\(name): owed after")
        }
    }

    /// The app runs these rules: the sweep's trigger, the plan's roles, the
    /// settle list and the settle itself.
    func testTheAppAsksTheseRules() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let manager = try String(contentsOf: root.appendingPathComponent("App/Managers/CircleManager.swift"), encoding: .utf8)
        XCTAssertTrue(manager.contains("            return roleChangesDue(circle.id, owed: owed.roleChanges, me: me)\n"),
                      "the sweep: only a change a record can carry is due")
        XCTAssertFalse(manager.contains("!owed.roleChanges.isEmpty"), "not any owed change")
        XCTAssertTrue(manager.contains("return RecordedRotation.roleChangesDue(myChainRole: .owner, owed: wanted, members: rows.map { row in"))
        XCTAssertTrue(manager.contains("let changes = RecordedRotation.writtenRoles(myChainRole: myChainRole, owed: owedRoles)"))
        XCTAssertTrue(manager.contains("""
                    roleChanges = RecordedRotation.roleChangesSettled(
                        owed: owedRoles, myChainRole: chainRoleHere, listed: Set(members.filter(\\.listed).map(\\.userId)),
                        plan: built).mapValues(RecordedRotation.roleName)
        """), "settled from the plan the record was built from")
        XCTAssertTrue(manager.contains("            entry.roleChanges = RefreshLedger.settling(entry.roleChanges, taken: change.roleChanges)\n"),
                      "by member AND role when the server takes it")
        XCTAssertFalse(manager.contains("roleChanges = Set(owed.roleChanges.keys)"))
        XCTAssertFalse(manager.contains("entry.roleChanges.removeValue(forKey:"))
    }
}
