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

/// Who a recorded rotation, a repair and a transition name, and how. The
/// SDK's builder checks the record; these pin what the app asks it for.
final class RecordedRotationTests: XCTestCase {
    private let me = "0F0F0F0F-1111-2222-3333-444455556666"
    private let owner = "a0a0a0a0-0000-0000-0000-000000000001"
    private let admin = "a0a0a0a0-0000-0000-0000-000000000002"
    private let plain = "a0a0a0a0-0000-0000-0000-000000000003"
    private let newcomer = "a0a0a0a0-0000-0000-0000-000000000004"
    private let keyless = "a0a0a0a0-0000-0000-0000-000000000005"

    private func listed(_ id: String, _ role: CircleRole = .member, keys: Bool = true) -> RecordedRotation.Listed {
        RecordedRotation.Listed(userId: id, role: role, hasKeys: keys)
    }

    private func entries(_ plan: [PlannedEntry]) -> [String: (RecordMemberState, CircleRole?)] {
        Dictionary(plan.map { ($0.userId.lowercased(), ($0.state, $0.role)) }, uniquingKeysWith: { a, _ in a })
    }

    /// This account included; the eligibility rule's yes included; the chain's
    /// other members pending; a newcomer the rule doesn't allow not named; a
    /// blocked member pending even when the rule allows them; roles carried
    /// (nil). A member with no keys is never included: carried pending if the
    /// chain counts them (the builder refuses a listed member left out), else
    /// not named.
    func testARotationNamesIncludedPendingAndNobodyElse() {
        let keylessNewcomer = "a0a0a0a0-0000-0000-0000-000000000006"
        let plan = RecordedRotation.rotationPlan(
            me: me,
            roster: [listed(me, .admin), listed(owner, .owner), listed(plain), listed(newcomer),
                     listed(keyless, keys: false), listed(keylessNewcomer, keys: false), listed(admin, .admin)],
            includable: [owner, plain, admin, keyless, keylessNewcomer],
            blocked: [admin],
            counted: [me: .admin, owner: .owner, plain: .member, admin: .admin, keyless: .member],
            removing: [])
        let got = entries(plan)
        XCTAssertEqual(plan.first?.userId, me, "this account first, as the caller's id")
        XCTAssertEqual(got[me.lowercased()]?.0, .included)
        XCTAssertEqual(got[owner]?.0, .included)
        XCTAssertEqual(got[plain]?.0, .included)
        XCTAssertEqual(got[admin]?.0, .pending, "a blocked key change stays pending")
        XCTAssertNil(got[newcomer], "not in the chain and not allowed in: never named")
        XCTAssertEqual(got[keyless]?.0, .pending, "no keys: carried with the chain's commitment, never included")
        XCTAssertNil(got[keylessNewcomer], "no keys and not in the chain: never named")
        XCTAssertEqual(plan.count, 5)
        XCTAssertTrue(plan.allSatisfy { $0.role == nil }, "roles are carried by the chain")
    }

    /// The eligibility rule's no for a member the chain counts:
    /// pending, never dropped.
    func testAMemberTheChainCountsButTheEligibilityRuleRefusesIsCarriedPending() {
        let plan = RecordedRotation.rotationPlan(
            me: me, roster: [listed(me), listed(plain)], includable: [], blocked: [],
            counted: [me: .member, plain: .member], removing: [])
        XCTAssertEqual(entries(plan)[plain]?.0, .pending)
    }

    /// The person's own removals are "removed", named once, and only for
    /// someone the chain counts, listed or not (a revoke took them off the
    /// list already).
    func testOwnRemovalsAreRemovedOnlyForMembersTheChainCounts() {
        let plan = RecordedRotation.rotationPlan(
            me: me, roster: [listed(me, .owner), listed(plain), listed(admin, .admin)],
            includable: [plain, admin], blocked: [],
            counted: [me: .owner, plain: .member, admin: .admin, newcomer: .member],
            removing: [plain.uppercased(), newcomer, keyless])
        let got = entries(plan)
        XCTAssertEqual(got[plain]?.0, .removed, "listed, but this person removed them")
        XCTAssertEqual(got[newcomer]?.0, .removed, "off the list already (a revoke)")
        XCTAssertNil(got[keyless], "the chain never counted them: nothing to remove")
        XCTAssertEqual(got[admin]?.0, .included)
        XCTAssertEqual(plan.filter { $0.userId.lowercased() == plain }.count, 1)
    }

    /// An own removal of someone the chain doesn't count here but the rejected
    /// record before this one names is named removed too: left out, the
    /// builder would fill them in as departed.
    func testAnOwnRemovalTheRejectedTipNamesIsRemoved() {
        let plan = RecordedRotation.rotationPlan(
            me: me, roster: [listed(me, .owner), listed(plain)], includable: [plain], blocked: [],
            counted: [me: .owner, plain: .member], removing: [newcomer.uppercased(), keyless],
            rejectedIncluded: [newcomer, plain])
        let got = entries(plan)
        XCTAssertEqual(got[newcomer]?.0, .removed, "named by the rejected tip")
        XCTAssertNil(got[keyless], "named by nothing: nothing to remove")
        XCTAssertEqual(plan.filter { $0.userId.lowercased() == newcomer }.count, 1)
        XCTAssertEqual(got[plain]?.0, .included)
    }

    /// Someone this person removes is never included, even when the
    /// eligibility rule would allow them and the chain never counted them (a
    /// newcomer ejected at once).
    func testAMemberBeingRemovedIsNeverIncluded() {
        let plan = RecordedRotation.rotationPlan(
            me: me, roster: [listed(me, .owner), listed(newcomer), listed(plain)],
            includable: [newcomer, plain], blocked: [], counted: [me: .owner, plain: .member],
            removing: [newcomer.uppercased()])
        XCTAssertNil(entries(plan)[newcomer])
        XCTAssertEqual(entries(plan)[plain]?.0, .included)
    }

    /// The chain owner's own role changes go in; nobody else's role moves.
    func testOnlyThePersonsOwnRoleChangesAreWritten() {
        let plan = RecordedRotation.rotationPlan(
            me: me, roster: [listed(me, .owner), listed(plain, .admin), listed(admin, .admin)],
            includable: [plain, admin], blocked: [],
            counted: [me: .owner, plain: .member, admin: .admin], removing: [],
            roleChanges: [plain: .admin])
        let got = entries(plan)
        XCTAssertEqual(got[plain]?.1, .admin)
        XCTAssertNil(got[admin]?.1 ?? nil, "the list's word is never copied")
        XCTAssertNil(got[me.lowercased()]?.1 ?? nil)
    }

    /// A repair names the rejected record's not-allowed members pending (the
    /// record format needs them), never included.
    func testARepairCarriesTheRejectedRecordsNotAllowedMembersPending() {
        let plan = RecordedRotation.rotationPlan(
            me: me, roster: [listed(me, .admin), listed(newcomer)], includable: [], blocked: [],
            counted: [me: .admin], removing: [], rejectedIncluded: [newcomer])
        XCTAssertEqual(entries(plan)[newcomer]?.0, .pending)
    }

    /// Only an admin in the chain who is the listed owner; in the record that
    /// removes the chain's owner, or when no member this device knows is the
    /// chain's owner any more (a gone owner; the builder refuses the claim if
    /// the chain still counts one, and the app plans again without it).
    func testTheListedOwnerClaimsWhenRemovingOrWhenNoOwnerIsCounted() {
        XCTAssertTrue(RecordedRotation.claimsOwner(myChainRole: .admin, myListedRole: .owner,
                                                   removing: [owner], counted: [owner: .owner]))
        XCTAssertTrue(RecordedRotation.claimsOwner(myChainRole: .admin, myListedRole: .owner,
                                                   removing: [], counted: [me: .admin, plain: .member]),
                      "no owner counted among those this device knows: tried, the chain decides")
        XCTAssertFalse(RecordedRotation.claimsOwner(myChainRole: .admin, myListedRole: .owner,
                                                    removing: [plain], counted: [owner: .owner, plain: .member]),
                       "a listed old owner: only in the record that removes them")
        XCTAssertFalse(RecordedRotation.claimsOwner(myChainRole: .member, myListedRole: .owner,
                                                    removing: [owner], counted: [owner: .owner]))
        XCTAssertFalse(RecordedRotation.claimsOwner(myChainRole: .admin, myListedRole: .admin,
                                                    removing: [owner], counted: [owner: .owner]))
        XCTAssertFalse(RecordedRotation.claimsOwner(myChainRole: .owner, myListedRole: .owner,
                                                    removing: [], counted: [me: .owner]), "already the owner")
        let plan = RecordedRotation.rotationPlan(
            me: me, roster: [listed(me, .owner)], includable: [], blocked: [],
            counted: [me: .admin, owner: .owner], removing: [owner], claimsOwner: true)
        XCTAssertEqual(entries(plan)[me.lowercased()]?.1, .owner)
        XCTAssertEqual(entries(plan)[owner]?.0, .removed)
    }

    /// A transition: every role exactly as listed, set explicitly;
    /// confirmed and not blocked included, every other listed key-holder
    /// pending, keyless members left out.
    func testATransitionTakesTheListsRolesAndEveryListedKeyHolder() throws {
        let plan = try XCTUnwrap(RecordedRotation.transitionPlan(
            me: me,
            roster: [listed(owner, .owner), listed(me, .admin), listed(admin, .admin), listed(plain),
                     listed(newcomer), listed(keyless, keys: false)],
            confirmed: [owner, admin, newcomer], blocked: [newcomer]))
        let got = entries(plan)
        XCTAssertEqual(plan.first?.userId, me)
        XCTAssertEqual(got[me.lowercased()]?.0, .included)
        XCTAssertEqual(got[me.lowercased()]?.1, .admin)
        XCTAssertEqual(got[owner]?.0, .included)
        XCTAssertEqual(got[owner]?.1, .owner)
        XCTAssertEqual(got[admin]?.1, .admin)
        XCTAssertEqual(got[plain]?.0, .pending, "listed, not confirmed")
        XCTAssertEqual(got[plain]?.1, .member)
        XCTAssertEqual(got[newcomer]?.0, .pending, "blocked")
        XCTAssertNil(got[keyless])
        XCTAssertEqual(plan.count, 5)
    }

    /// No transition from a plain member, without exactly one listed owner, or
    /// while the owner has no keys (the circle stays legacy; nobody else is
    /// named owner).
    func testNoTransitionFromAPlainMemberOrWithoutAnOwnerWithKeys() {
        XCTAssertNil(RecordedRotation.transitionPlan(
            me: me, roster: [listed(owner, .owner), listed(me)], confirmed: [owner], blocked: []))
        XCTAssertNil(RecordedRotation.transitionPlan(
            me: me, roster: [listed(owner, .owner, keys: false), listed(me, .admin)], confirmed: [], blocked: []))
        XCTAssertNil(RecordedRotation.transitionPlan(
            me: me, roster: [listed(me, .admin), listed(admin, .admin)], confirmed: [admin], blocked: []))
        XCTAssertNil(RecordedRotation.transitionPlan(
            me: me, roster: [listed(owner, .owner), listed(plain, .owner), listed(me, .admin)],
            confirmed: [], blocked: []))
        XCTAssertNil(RecordedRotation.transitionPlan(
            me: me, roster: [listed(owner, .owner)], confirmed: [owner], blocked: []),
            "this account not on the list")
        XCTAssertNotNil(RecordedRotation.transitionPlan(
            me: me, roster: [listed(me, .owner)], confirmed: [], blocked: []))
    }

    /// Only a rejection by the SDK's R2 check (`.r2NotAllowed`,
    /// `.r2UnmatchedEntry`, `.role`, `.removal`), or a MISATTRIBUTED one, is
    /// repaired: a record that fails its structure, signature or chain is no
    /// record to link a repair to.
    func testOnlyR2AndMisattributedRejectionsAreRepaired() {
        func status(_ version: Int32, _ state: RecordVersionState, _ problem: RecordProblem) -> RecordVersionStatus {
            RecordVersionStatus(version: version, state: state, problem: problem, notAllowed: [], unmatchedEntries: 0, namedListed: [])
        }
        let versions = [status(3, .rejected, .r2NotAllowed), status(4, .rejected, .r2UnmatchedEntry),
                        status(5, .rejected, .role), status(6, .rejected, .removal),
                        status(7, .rejected, .signature), status(8, .rejected, .structure),
                        status(9, .waiting, .r2NotAllowed), status(10, .accepted, .none),
                        status(11, .rejected, .misattributed), status(12, .waiting, .signature)]
        XCTAssertEqual(RecordedRotation.repairable(versions).map(\.version), [3, 4, 5, 6, 11])
    }

    /// A repair needs the key of the version it answers; one answering a
    /// MISATTRIBUTED version links from below at once, with any version held.
    /// Nothing held: no repair.
    func testAMisattributedRepairLinksFromBelowAtOnce() {
        XCTAssertTrue(CircleManager.holdsWhatARepairNeeds(held: 5, circleKeyVersion: 5, answering: .r2NotAllowed))
        XCTAssertFalse(CircleManager.holdsWhatARepairNeeds(held: 4, circleKeyVersion: 5, answering: .r2NotAllowed))
        XCTAssertFalse(CircleManager.holdsWhatARepairNeeds(held: 4, circleKeyVersion: 5, answering: nil))
        XCTAssertTrue(CircleManager.holdsWhatARepairNeeds(held: 4, circleKeyVersion: 5, answering: .misattributed))
        XCTAssertTrue(CircleManager.holdsWhatARepairNeeds(held: 2, circleKeyVersion: 5, answering: .misattributed))
        XCTAssertFalse(CircleManager.holdsWhatARepairNeeds(held: nil, circleKeyVersion: 5, answering: .misattributed))
    }

    /// The wiring: the repair's hold rule asks what the due repair answers.
    func testTheRepairAsksWhatItAnswers() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let circles = try String(contentsOf: root.appendingPathComponent("App/Managers/CircleManager.swift"), encoding: .utf8)
        XCTAssertTrue(circles.contains("""
                    if case .recorded(.repair) = rotationMode(for: circle) {
                        return Self.holdsWhatARepairNeeds(
                            held: cryptoManager.newestHeldVersion(circleId: circle.id).map { Int($0) },
                            circleKeyVersion: circle.keyVersion, answering: repairsDue[CanonicalId.key(circle.id)]?.problem)
                    }
            """))
    }
}
