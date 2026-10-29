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

/// Who a rotation gives the new circle key to.
///
/// The server alone must not decide membership: wrapping the new key (and,
/// through the key chain, all history) to every user `member-public-keys`
/// returns would hand it to whoever the server names. A member is wrapped to
/// only when they are on the complete roster AND confirmed on this device AND
/// pass the pin gate:
///   * someone listed there but NOT on the roster the user sees is never
///     wrapped to (logged);
///   * a roster member this device has not confirmed is left pending —
///     whatever the server claims they already hold. Nothing is seeded from a
///     roster: legacy approvals stay as `preRound2Seed` entries; everything
///     else comes from this device's own choices and from signed statements
///     (`MembershipConfirmationTests`).
/// One member with an unapproved key change must not abort the whole rotation,
/// or a removed member's key stays current indefinitely: they are left pending
/// and everyone else is re-keyed.
final class KeyDeliveryPlanTests: XCTestCase {

    private let me = "a0000000-0000-4000-8000-000000000001"
    private let alice = "a0000000-0000-4000-8000-00000000000a"
    private let bob = "a0000000-0000-4000-8000-00000000000b"
    private let newcomer = "a0000000-0000-4000-8000-00000000000c"
    private let ghost = "a0000000-0000-4000-8000-00000000000d"

    private func decide(
        cause: String? = "member_removed",
        wrapSet: [(userId: String, keyVersion: Int?)],
        roster: Set<String>,
        blocked: Set<String> = [],
        approved: Set<String> = []
    ) -> CircleManager.RotationDecision {
        CircleManager.rotationDecision(
            selfUserId: me,
            circleKeyVersion: 4,
            cause: cause,
            wrapSet: wrapSet,
            roster: roster,
            blocked: blocked,
            confirmed: CircleManager.confirmedMembers(roster: roster, approved: approved, selfUserId: me)
        )
    }

    // MARK: - Members nobody can see

    func testSomeoneMissingFromTheRosterIsNeverWrappedTo() {
        let d = decide(
            wrapSet: [(me, 4), (alice, 4), (ghost, 4)],
            roster: [me, alice],
            approved: [alice, ghost]
        )
        XCTAssertEqual(d.wrap.sorted(), [me, alice].sorted())
        XCTAssertEqual(d.pending, [ghost])
        XCTAssertEqual(d.ghosts, [ghost], "a member nobody can see is logged, never wrapped")
        XCTAssertFalse(d.wrap.contains(ghost))
    }

    // MARK: - Members this device never approved

    func testAnUnapprovedNewcomerWaitsForApproval() {
        let d = decide(
            cause: "member_joined",
            wrapSet: [(me, 4), (alice, 4), (newcomer, nil)],
            roster: [me, alice, newcomer],
            approved: [alice]
        )
        XCTAssertEqual(d.pending, [newcomer])
        XCTAssertEqual(d.unconfirmed, [newcomer], "not confirmed on this device: nothing before that")
        XCTAssertTrue(d.skip, "a keyless join with nobody approved is no reason to bump the key")
    }

    func testAnApprovedMemberIsWrappedTo() {
        let d = decide(
            cause: "member_joined",
            wrapSet: [(me, 4), (alice, 4), (newcomer, nil)],
            roster: [me, alice, newcomer],
            approved: [alice, newcomer]
        )
        XCTAssertTrue(d.wrap.contains(newcomer))
        XCTAssertTrue(d.pending.isEmpty)
        XCTAssertFalse(d.skip, "the rotation now delivers to someone")
    }

    /// A member left pending by an earlier rotation holds an OLDER wrap. Being
    /// owed decides only that a rotation would deliver something; approval
    /// decides whether it goes to them.
    func testAnOlderWrapIsADeliveryNotATrustDecision() {
        let asked = decide(cause: "member_joined", wrapSet: [(me, 4), (alice, 3)], roster: [me, alice])
        XCTAssertEqual(asked.unconfirmed, [alice])
        XCTAssertTrue(asked.skip)
        let delivered = decide(cause: "member_joined", wrapSet: [(me, 4), (alice, 3)], roster: [me, alice],
                               approved: [alice])
        XCTAssertEqual(Set(delivered.wrap), [me, alice])
        XCTAssertFalse(delivered.skip, "an approved member is owed the key: worth a rotation")
    }

    /// Approved members are wrapped to without a question — rotations after a
    /// removal must not stall on prompts.
    func testApprovedMembersAreWrappedWithoutAsking() {
        let d = decide(wrapSet: [(me, 4), (alice, 4), (bob, 4)], roster: [me, alice, bob],
                       approved: [alice, bob])
        XCTAssertEqual(Set(d.wrap), [me, alice, bob])
        XCTAssertTrue(d.pending.isEmpty)
        XCTAssertFalse(d.skip)
    }

    /// An account the server put on the roster and reports as already holding
    /// the CURRENT key is not wrapped to on that say-so. It is asked about and
    /// left pending like any other stranger.
    func testAGhostOnTheRosterClaimingTheCurrentKeyIsAskedNotWrapped() {
        let d = decide(
            cause: "member_removed",
            wrapSet: [(me, 4), (alice, 4), (ghost, 4)],
            roster: [me, alice, ghost],
            approved: [alice]
        )
        XCTAssertFalse(d.wrap.contains(ghost), "the server's claim is not an approval")
        XCTAssertEqual(d.pending, [ghost])
        XCTAssertEqual(d.unconfirmed, [ghost])
        XCTAssertTrue(d.ghosts.isEmpty, "on the roster: a stranger to approve, not a hidden member")
        XCTAssertEqual(Set(d.wrap), [me, alice])
    }

    /// An older server reports no versions. Approval does not depend on them,
    /// so the rule is the same: approved members are wrapped, others asked.
    func testAnOlderServerStillAsksAboutStrangers() {
        let d = decide(
            cause: "member_removed",
            wrapSet: [(me, nil), (alice, nil), (newcomer, nil)],
            roster: [me, alice, newcomer],
            approved: [alice]
        )
        XCTAssertEqual(Set(d.wrap), [me, alice])
        XCTAssertEqual(d.unconfirmed, [newcomer])
    }

    // MARK: - Rotate around a blocked member

    func testABlockedKeyChangeDoesNotAbortTheRotation() {
        let d = decide(
            cause: "member_removed",
            wrapSet: [(me, 4), (alice, 4), (bob, 4)],
            roster: [me, alice, bob],
            blocked: [bob],
            approved: [alice, bob]
        )
        XCTAssertEqual(Set(d.wrap), [me, alice], "everyone verified is re-keyed")
        XCTAssertEqual(d.pending, [bob], "the blocked member keeps what they had and gets nothing newer")
        XCTAssertFalse(d.skip, "a removal must be re-keyed even with someone blocked")
    }

    /// A roster member who has published no key is not in member-public-keys.
    /// The server wants every active member wrapped or pending, so they are
    /// named pending — quietly: no alarm, nothing to approve.
    func testAMemberWithNoPublishedKeyIsPendingNotRefused() {
        let d = decide(wrapSet: [(me, 4), (alice, 4)], roster: [me, alice, bob], approved: [alice, bob])
        XCTAssertEqual(Set(d.wrap), [me, alice])
        XCTAssertEqual(d.pending, [bob])
        XCTAssertTrue(d.ghosts.isEmpty)
        XCTAssertTrue(d.unconfirmed.isEmpty)
    }

    func testTheRotatorIsAlwaysWrapped() {
        let d = decide(wrapSet: [(me, nil)], roster: [])
        XCTAssertEqual(d.wrap, [me])
    }

    // MARK: - The wire

    func testPendingMembersTravelAsPendingMembers() throws {
        let blob = EncryptedBlobRequest(nonce: "00", ciphertext: "11")
        let request = RotateKeysRequest(
            encryptedName: blob, memberKeys: [], expectedKeyVersion: 4, keyChainLink: nil,
            pendingMembers: [bob]
        )
        let json = try JSONSerialization.jsonObject(with: APIService.makeWireEncoder().encode(request)) as? [String: Any]
        XCTAssertEqual(json?["pending_members"] as? [String], [bob])

        let none = RotateKeysRequest(encryptedName: blob, memberKeys: [], expectedKeyVersion: 4, keyChainLink: nil)
        let bare = try JSONSerialization.jsonObject(with: APIService.makeWireEncoder().encode(none)) as? [String: Any]
        XCTAssertNil(bare?["pending_members"], "no pending members: the body is what an older server always got")

        let eject = EjectAndRotateRequest(
            ejectUserId: alice, newKeyVersion: 5, memberWraps: [], encryptedName: nil, keyChainLink: nil,
            pendingMembers: [bob]
        )
        let ejectJSON = try JSONSerialization.jsonObject(with: APIService.makeWireEncoder().encode(eject)) as? [String: Any]
        XCTAssertEqual(ejectJSON?["pending_members"] as? [String], [bob])
    }

    func testOwedMembersCarryTheirVersionAndEmail() throws {
        let body = Data("""
        {"success":true,"data":[
          {"user_id":"\(alice)","sharing_public_key":"aa","signing_public_key":"bb","key_version":4,"can_rotate_keys":false},
          {"user_id":"\(newcomer)","sharing_public_key":"cc","signing_public_key":"dd","email":"sam@example.com","can_rotate_keys":false}
        ]}
        """.utf8)
        let keys: [MemberPublicKeyResponse] = try APIService.decodeResponseBody(body)
        XCTAssertEqual(keys[0].keyVersion, 4)
        XCTAssertNil(keys[1].keyVersion, "no wrap at all: owed")
        XCTAssertEqual(keys[1].email, "sam@example.com")
    }

    // MARK: - The approvals store

    private let circle = "c0000000-0000-4000-8000-000000000001"

    /// The approvals lock on a scratch file: the store writes nothing without one.
    static func scratchLock() -> AppGroupLock {
        AppGroupLock(url: FileManager.default.temporaryDirectory.appendingPathComponent("approvals-\(UUID().uuidString).lock"))
    }

    @MainActor
    private func freshStore() throws -> (KeyDeliveryApprovals, () -> Void) {
        let suite = "KeyDeliveryPlanTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return (KeyDeliveryApprovals(defaults: defaults, deviceTag: { "test-tag" }, lock: Self.scratchLock()), { defaults.removePersistentDomain(forName: suite) })
    }

    /// The decision this device would make for `circle`, with the store's approvals.
    @MainActor
    private func decide(_ store: KeyDeliveryApprovals, wrapSet: [(userId: String, keyVersion: Int?)],
                        roster: Set<String>) -> CircleManager.RotationDecision {
        decide(cause: "member_removed", wrapSet: wrapSet, roster: roster,
               approved: store.approvedMembers(owner: me, circleId: circle))
    }

    /// Legacy approvals become `preRound2Seed` entries, read once; their
    /// invitees stay invitees — on the device that adopted them
    /// (`bindToThisDevice`); a restored backup's are nobody's.
    @MainActor
    func testLegacyApprovalsBecomeSeeds() throws {
        let suite = "KeyDeliveryPlanTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set([alice, bob], forKey: "keyDeliveryApproved.\(me).\(circle)")
        defaults.set([newcomer], forKey: "keyDeliveryApproved.\(me).\(circle).invited")
        let restored = KeyDeliveryApprovals(defaults: defaults, deviceTag: { "test-tag" }, lock: Self.scratchLock())
        XCTAssertEqual(restored.record(owner: me, circleId: circle), CircleApprovalRecord(), "not adopted: nobody's")
        defaults.set("test-tag", forKey: ApprovalRecordStore.adoptedByKey)
        let store = KeyDeliveryApprovals(defaults: defaults, deviceTag: { "test-tag" }, lock: Self.scratchLock())
        let record = store.record(owner: me, circleId: circle)
        XCTAssertEqual(record.entries, [alice: .preRound2Seed, bob: .preRound2Seed])
        XCTAssertTrue(record.invitees.isEmpty,
                      "the legacy invitees are not carried over: nothing says which invitation was theirs")
        let d = decide(store, wrapSet: [(me, 4), (alice, 4), (bob, 3)], roster: [me, alice, bob])
        XCTAssertTrue(d.unconfirmed.isEmpty)
        XCTAssertEqual(Set(d.wrap), [me, alice, bob])
    }

    /// The transition from legacy builds: the pins a device held before this
    /// record format first ran seed the circles it has no record for, ONCE,
    /// as `preRound2Seed` entries. A pin made after that (a confirmation)
    /// never seeds, and a circle with a record keeps it.
    @MainActor
    func testTheTransitionSeedIsTakenOnceFromThePinsHeldBefore() throws {
        let (store, cleanup) = try freshStore()
        defer { cleanup() }
        let other = "c0000000-0000-4000-8000-000000000002"
        let later = "c0000000-0000-4000-8000-000000000003"
        store.approve(owner: me, circleId: other, userId: bob, origin: .statement)  // already has a record
        XCTAssertFalse(store.transitionSeedTaken(owner: me))
        XCTAssertEqual(store.takeTransitionSeed(owner: me, pins: [circle: [me, alice, bob], other: [alice]]), 1)
        XCTAssertTrue(store.transitionSeedTaken(owner: me))
        XCTAssertTrue(store.record(owner: me, circleId: circle).entries.isEmpty,
                      "nothing is trusted from a pin alone until a complete roster lists them")
        XCTAssertEqual(store.record(owner: me, circleId: circle).seedCandidates, [alice, bob])
        XCTAssertEqual(store.record(owner: me, circleId: other).entries, [bob: .statement], "a record is kept as it is")
        store.applySeed(owner: me, circleId: circle, roster: [me, alice, bob])
        XCTAssertEqual(store.record(owner: me, circleId: circle).entries, [alice: .preRound2Seed, bob: .preRound2Seed])
        XCTAssertTrue(store.record(owner: me, circleId: circle).seedCandidates.isEmpty, "taken effect once")

        // Pins made afterwards — a newcomer confirmed, a circle joined later — never seed.
        XCTAssertEqual(store.takeTransitionSeed(owner: me, pins: [circle: [alice, bob, newcomer], later: [ghost]]), 0)
        XCTAssertNil(store.record(owner: me, circleId: circle).entries[newcomer])
        XCTAssertTrue(store.record(owner: me, circleId: later).entries.isEmpty)
        let d = decide(store, wrapSet: [(me, 4), (alice, 4), (bob, 4)], roster: [me, alice, bob])
        XCTAssertTrue(d.unconfirmed.isEmpty, "after the transition: the members this phone already had are still there")

        // Once per account: an account's mark goes with its records.
        store.forget(owners: [alice])
        XCTAssertTrue(store.transitionSeedTaken(owner: me))
        store.forget(owners: [me])
        XCTAssertFalse(store.transitionSeedTaken(owner: me))
    }

    /// The seed's capture point (source): both entry points to a roster load
    /// take the seed FIRST, and the retire that follows confirmation never runs
    /// before the seed has been taken from those very pins.
    func testTheSeedIsTakenBeforeAnythingTouchesThePins() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let circles = try String(contentsOf: root.appendingPathComponent("App/Managers/CircleManager.swift"), encoding: .utf8)
        XCTAssertTrue(circles.contains("    func loadCircles(light: Bool = false) async throws {\n        takeTransitionSeedIfNeeded()\n"))
        XCTAssertTrue(circles.contains("    func loadMembers(for circleId: String) async throws {\n        takeTransitionSeedIfNeeded()\n"))
        XCTAssertTrue(circles.contains("if rosterComplete, approvals.transitionSeedTaken(owner: me) {"))
        XCTAssertEqual(circles.components(separatedBy: "retainMemberPins(").count - 1, 2,
                       "no other path retires pins")
        XCTAssertEqual(circles.components(separatedBy: "pinMemberKeys(").count - 1, 2,
                       "the only direct pins outside the pinner: the invite-time pin of someone this user invites, "
                       + "and \"Let them in\" for the keys behind the number")
        // "Let them in" pins when its waiting `letIn` change runs, and the
        // seed is taken first there.
        XCTAssertTrue(circles.contains("    func letInWaiting(_ change: PendingChange) async throws {\n        // It may pin: the one-time transition seed is taken first, as for\n        // an invite.\n        takeTransitionSeedIfNeeded()\n"))
    }

    /// No roster is approved wholesale: a fresh device confirms nobody from
    /// the server's list on its own.
    @MainActor
    func testNothingIsSeededFromARoster() throws {
        let (store, cleanup) = try freshStore()
        defer { cleanup() }
        store.retain(owner: me, circleId: circle, roster: [me, alice, ghost], activeVersion: 4)
        XCTAssertTrue(store.record(owner: me, circleId: circle).entries.isEmpty)
        let d = decide(store, wrapSet: [(me, 4), (alice, 4), (ghost, 4)], roster: [me, alice, ghost])
        XCTAssertEqual(Set(d.unconfirmed), [alice, ghost])
    }

    /// A circle created here is recorded at creation: its creator, nobody else.
    @MainActor
    func testACreatedCircleConfirmsOnlyItsCreator() throws {
        let (store, cleanup) = try freshStore()
        defer { cleanup() }
        store.recordCreatedCircle(owner: me, circleId: circle)
        XCTAssertEqual(store.origin(owner: me, circleId: circle, userId: me), .ownAction)
        let d = decide(store, wrapSet: [(me, 1), (ghost, 1)], roster: [me, ghost])
        XCTAssertEqual(d.unconfirmed, [ghost])
    }

    /// Someone this device's user invited to their account is theirs once they
    /// join with THAT invitation — and the choice survives the roster loads
    /// before they accept, never tombstoned.
    @MainActor
    func testOwnInviteNeedsNoQuestion() throws {
        let (store, cleanup) = try freshStore()
        defer { cleanup() }
        let now = Date()
        store.recordCreatedCircle(owner: me, circleId: circle)
        store.approveInvitee(owner: me, circleId: circle, userId: newcomer, statementId: "s-new",
                             expiresAt: Int64(now.timeIntervalSince1970) + 604_800)
        store.settleInvitees(owner: me, circleId: circle, roster: [me: nil], now: now)  // not joined yet
        store.retain(owner: me, circleId: circle, roster: [me], activeVersion: 4)
        XCTAssertNil(store.record(owner: me, circleId: circle).tombstones[newcomer], "never tombstoned while pending")
        XCTAssertNil(store.origin(owner: me, circleId: circle, userId: newcomer), "not a member yet")
        store.settleInvitees(owner: me, circleId: circle, roster: [me: nil, newcomer: "S-NEW"], now: now)  // joined
        store.retain(owner: me, circleId: circle, roster: [me, newcomer], activeVersion: 4)
        XCTAssertEqual(store.origin(owner: me, circleId: circle, userId: newcomer), .ownAction)
        XCTAssertTrue(store.record(owner: me, circleId: circle).invitees.isEmpty, "the record goes on appearance")
        let d = decide(store, wrapSet: [(me, 4), (newcomer, nil)], roster: [me, newcomer])
        XCTAssertTrue(d.unconfirmed.isEmpty)
        XCTAssertEqual(Set(d.wrap), [me, newcomer])
    }

    /// Removal takes the confirmation with it, and TOMBSTONES them: their
    /// statement ids never confirm anyone again, and they come back only by a
    /// statement made at or after the version this device held when they left.
    @MainActor
    func testARemovedMemberIsTombstoned() throws {
        let (store, cleanup) = try freshStore()
        defer { cleanup() }
        store.approve(owner: me, circleId: circle, userId: alice, origin: .statement)
        store.approve(owner: me, circleId: circle, userId: bob, origin: .statement, statementIds: ["s-bob"])
        store.retain(owner: me, circleId: circle, roster: [me, alice], activeVersion: 7)
        let record = store.record(owner: me, circleId: circle)
        XCTAssertNil(record.entries[bob])
        XCTAssertEqual(record.tombstones[bob], ApprovalTombstone(statementIds: ["s-bob"], activeVersion: 7))
        let d = decide(store, wrapSet: [(me, 4), (alice, 4), (bob, 3)], roster: [me, alice, bob])
        XCTAssertEqual(d.unconfirmed, [bob])

        // An invitee who joined and then left goes the same way.
        store.approveInvitee(owner: me, circleId: circle, userId: newcomer, statementId: "s-new",
                             expiresAt: Int64(Date().timeIntervalSince1970) + 604_800)
        store.settleInvitees(owner: me, circleId: circle, roster: [me: nil, alice: nil, newcomer: "s-new"])
        store.retain(owner: me, circleId: circle, roster: [me, alice, newcomer], activeVersion: 7)
        store.retain(owner: me, circleId: circle, roster: [me, alice], activeVersion: 8)
        XCTAssertFalse(store.approvedMembers(owner: me, circleId: circle).contains(newcomer))
        XCTAssertEqual(store.record(owner: me, circleId: circle).tombstones[newcomer]?.activeVersion, 8)
    }

    /// Receive-only: a kind-2 member's keys are kept in the record — never an
    /// SDK pin — and only an admission lifts them; nothing downgrades a member
    /// this device's user chose.
    @MainActor
    func testReceiveOnlyMembersKeepTheirKeysInTheRecord() throws {
        let (store, cleanup) = try freshStore()
        defer { cleanup() }
        let keys = MemberKeyPair(sharingKeyHex: "aa", signingKeyHex: "bb")
        store.approve(owner: me, circleId: circle, userId: newcomer, origin: .kind2, keys: keys)
        XCTAssertEqual(store.record(owner: me, circleId: circle).receiveOnlyKeys[newcomer], keys)
        XCTAssertTrue(keys.matches(sharing: "AA", signing: "bb"))
        XCTAssertFalse(keys.matches(sharing: "aa", signing: nil))

        // "It's them" about them: new keys, chosen here, still receive-only.
        let newKeys = MemberKeyPair(sharingKeyHex: "cc", signingKeyHex: "dd")
        store.replaceReceiveOnlyKeys(owner: me, circleId: circle, userId: newcomer, keys: newKeys)
        XCTAssertEqual(store.origin(owner: me, circleId: circle, userId: newcomer), .ownKind2)
        XCTAssertEqual(store.record(owner: me, circleId: circle).receiveOnlyKeys[newcomer], newKeys)

        // An admission lifts it; the record's keys go (the member is pinned now).
        store.approve(owner: me, circleId: circle, userId: newcomer, origin: .statement)
        XCTAssertEqual(store.origin(owner: me, circleId: circle, userId: newcomer), .statement)
        XCTAssertNil(store.record(owner: me, circleId: circle).receiveOnlyKeys[newcomer])

        // Never downgraded.
        store.approve(owner: me, circleId: circle, userId: newcomer, origin: .kind2)
        XCTAssertEqual(store.origin(owner: me, circleId: circle, userId: newcomer), .statement)
    }

    func testTheOriginOrder() {
        typealias O = ApprovalOrigin
        XCTAssertTrue(ApprovalOriginOrder.replaces(nil, with: .kind2))
        XCTAssertTrue(ApprovalOriginOrder.replaces(O.kind2, with: .statement), "an admission lifts receive-only")
        XCTAssertTrue(ApprovalOriginOrder.replaces(O.kind2, with: .ownKind2), "chosen here")
        XCTAssertFalse(ApprovalOriginOrder.replaces(O.ownKind2, with: .kind2))
        XCTAssertFalse(ApprovalOriginOrder.replaces(O.statement, with: .kind2), "never downgraded")
        XCTAssertTrue(ApprovalOriginOrder.replaces(O.statement, with: .ownAction))
        XCTAssertTrue(ApprovalOriginOrder.replaces(O.anchor, with: .statement), "a statement beats trust on first use")
        XCTAssertFalse(ApprovalOriginOrder.replaces(O.preRound2Seed, with: .statement), "a seed stays a seed")
        XCTAssertFalse(ApprovalOriginOrder.replaces(O.ownAction, with: .statement))
        XCTAssertTrue(O.kind2.isReceiveOnly && O.ownKind2.isReceiveOnly)
        XCTAssertTrue(O.ownAction.isChosen && O.ownKind2.isChosen)
        XCTAssertFalse(O.statement.isChosen || O.anchor.isChosen || O.preRound2Seed.isChosen || O.kind2.isChosen)
    }

    /// A record a later build wrote that this one cannot read is never rebuilt
    /// from the legacy keys over the top of it: it reads as empty (nobody
    /// confirmed — the safe side) and stays untouched.
    @MainActor
    func testAnUnreadableRecordIsNeverOverwritten() throws {
        let suite = "KeyDeliveryPlanTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "keyDeliveryApprovals.v2.\(me).\(circle)"
        let unreadable = Data(#"{"entries":{"x":"fromTheFuture"}}"#.utf8)
        defaults.set(unreadable, forKey: key)
        defaults.set([alice], forKey: "keyDeliveryApproved.\(me).\(circle)")
        let store = KeyDeliveryApprovals(defaults: defaults, deviceTag: { "test-tag" }, lock: Self.scratchLock())
        XCTAssertTrue(store.record(owner: me, circleId: circle).entries.isEmpty)
        store.approve(owner: me, circleId: circle, userId: bob)
        XCTAssertEqual(defaults.data(forKey: key), unreadable)
    }

    /// The lifecycle of the member pins: a same-account sign-out keeps the
    /// approvals; another account's sign-in takes them only when its guarded
    /// tidy says so (`SignInTidy`); deletion wipes them.
    @MainActor
    func testApprovalsSurviveASameAccountSignOutOnly() throws {
        let (store, cleanup) = try freshStore()
        defer { cleanup() }
        store.approve(owner: me, circleId: circle, userId: alice, origin: .statement)
        store.approveInvitee(owner: me, circleId: circle, userId: newcomer, statementId: "s-new",
                             expiresAt: Int64(Date().timeIntervalSince1970) + 604_800)
        XCTAssertTrue(store.approvedMembers(owner: alice, circleId: circle).isEmpty, "approvals are per account")

        store.reset()                     // what sign-out does (purgeAccountData)
        XCTAssertEqual(store.owners(), [me.lowercased()])
        XCTAssertEqual(store.approvedMembers(owner: me, circleId: circle), [alice], "an invitee is not a member yet")
        XCTAssertNotNil(store.record(owner: me, circleId: circle).invitees[newcomer.lowercased()], "and is kept too")

        store.forget(owners: [me.uppercased()])  // another account's sign-in, whose tidy forgets this one
        XCTAssertTrue(store.approvedMembers(owner: me, circleId: circle).isEmpty)
        XCTAssertTrue(store.owners().isEmpty)

        store.approve(owner: me, circleId: circle, userId: alice)
        store.clearAll(exceptOwner: nil)    // account deletion
        XCTAssertTrue(store.approvedMembers(owner: me, circleId: circle).isEmpty)
    }

    /// Where the app does each of the above (source).
    func testTheApprovalsAreKeptWhereThePinsAre() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func source(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }
        let auth = try source("App/Managers/AuthManager.swift")
        XCTAssertTrue(auth.contains("SignInTidy.run(signedIn: me, typedEmail: typedEmail)"),
                      "another account's approvals go at a sign-in only by the guarded tidy")
        XCTAssertTrue(auth.contains("            if !retainingTrust {\n                RetainedMemberPins.deleteAll(except: nil)\n                KeyDeliveryApprovals.shared.clearAll(exceptOwner: nil)"),
                      "only a deleted account's sign-out drops its approvals")
        let circles = try source("App/Managers/CircleManager.swift")
        XCTAssertFalse(circles.contains("seedIfNeeded"), "nothing is seeded from a roster")
        // Retire the departed FIRST, then confirm, then pin only the confirmed,
        // then retire every pin but theirs. The record's half — the departed
        // tombstoned, then the confirmations — is the roster pass the
        // notification extension runs too, stored here as one change.
        let departed = try XCTUnwrap(circles.range(of: "cryptoManager.retainMemberPins(circleId: circleId, memberUserIds: Array(keepIds))"))
        let confirm = try XCTUnwrap(circles.range(of: "var pass = AccessHandover.rosterPass("))
        let stored = try XCTUnwrap(circles.range(of: "guard approvals.store(pass.record, base: base, owner: me, circleId: circleId,"))
        let pin = try XCTUnwrap(circles.range(of: "pinner.pinConfirmed("))
        let unconfirmed = try XCTUnwrap(circles.range(of: "cryptoManager.retainMemberPins(circleId: circleId, memberUserIds: Array(keep))"))
        XCTAssertLessThan(departed.lowerBound, confirm.lowerBound, "retire the departed first")
        XCTAssertLessThan(confirm.lowerBound, stored.lowerBound)
        XCTAssertLessThan(stored.lowerBound, pin.lowerBound)
        XCTAssertLessThan(pin.lowerBound, unconfirmed.lowerBound, "then only the confirmed keep a pin")
        let handover = try source("App/Managers/AccessHandover.swift")
        let retain = try XCTUnwrap(handover.range(of: "record.retain(roster: Set(roster.map(\\.userId)), activeVersion: activeVersion)"))
        let evaluate = try XCTUnwrap(handover.range(of: "let result = MembershipConfirmation.evaluate("))
        let approve = try XCTUnwrap(handover.range(of: "record.approve(userId: userId, origin: confirmation.origin,"))
        XCTAssertLessThan(retain.lowerBound, evaluate.lowerBound, "tombstone the departed before confirming anyone")
        XCTAssertLessThan(evaluate.lowerBound, approve.lowerBound)
        XCTAssertFalse(circles.contains("MemberKeyPinner.shared.pin("), "no pinning on sight")
        XCTAssertTrue(circles.contains("KeyDeliveryApprovals.shared.approveInvitee(owner: me, circleId: circleId, userId: inviteeUserId,"))
        let settle = try XCTUnwrap(handover.range(of: "record.settleInvitees(roster: invitations, now: Int64(now.timeIntervalSince1970))"))
        let seed = try XCTUnwrap(handover.range(of: "record.applySeed(roster: Set(roster.map(\\.userId)))"))
        XCTAssertLessThan(settle.lowerBound, retain.lowerBound, "invitees settle before anyone is tombstoned")
        XCTAssertLessThan(seed.lowerBound, retain.lowerBound, "the seed takes effect before anyone is tombstoned")
        XCTAssertTrue(circles.contains("KeyDeliveryApprovals.shared.recordCreatedCircle(owner: me, circleId: response.id)"))
        // "It's them" is this device's own choice: no statement signed at the
        // tap, so it confirms the reset for nobody else by itself. On an
        // owner's or admin's device, for a member the chain doesn't count, it
        // queues the waiting "Let them in", whose run admits exactly the keys
        // shown.
        let host = try source("App/Views/Circles/MemberKeyAlertHost.swift")
        XCTAssertTrue(host.contains("            try CircleManager.shared.answerItsThem(alert)\n"))
        XCTAssertFalse(host.contains("admit(") || host.contains("signMembership"))
        let itsThem = try XCTUnwrap(circles.range(of: "    func answerItsThem(_ alert: MemberKeyAlert) throws {"))
        let body = circles[itsThem.upperBound...].prefix(2_600)
        XCTAssertTrue(body.contains("KeyDeliveryApprovals.shared.approve(owner: me, circleId: alert.circleId, userId: alert.userId, origin: .ownAction)"))
        XCTAssertTrue(body.contains("KeyDeliveryApprovals.shared.replaceReceiveOnlyKeys("))
        XCTAssertFalse(body.contains("admit(") || body.contains("signMembership"),
                       "nothing is signed at the tap: only the waiting change's run signs")
        XCTAssertTrue(body.contains("if Self.itsThemAdmits(receiveOnly: alert.receiveOnly, ownerOrAdmin: isOwnerOrAdmin(circle),\n"
                                    + "                                  chainRole: cryptoManager.chainRole(circleId: alert.circleId, userId: alert.userId),\n"))
        XCTAssertTrue(body.contains("let shown = MemberKeyPair(sharingKeyHex: alert.newSharingPubkeyHex, signingKeyHex: signing)\n"))
        XCTAssertTrue(body.contains("inputs: .letIn(.init(memberId: alert.userId, questionKind: Self.itsThemQuestionKind)),\n"
                                    + "                        seen: .init(keys: shown), subject: alert.displayName)"),
                      "exactly the keys the question showed")
    }

    @MainActor
    func testNotNowDefersAndDeduplicates() throws {
        let suite = "KeyDeliveryPlanTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = KeyDeliveryApprovals(defaults: defaults, deviceTag: { "test-tag" }, lock: Self.scratchLock())
        let request = KeyDeliveryRequest(circleId: "c1", circleName: "Family", userId: newcomer,
                                         displayName: "Sam", email: "sam@example.com")
        store.ask(request)
        store.ask(request)
        XCTAssertEqual(store.requests.count, 1)
        store.notNow(request)
        XCTAssertTrue(store.requests.isEmpty)
        XCTAssertEqual(store.deferredMembers(circleId: "c1"), [newcomer])
        store.ask(request)
        XCTAssertTrue(store.requests.isEmpty, "Not now is not re-asked in the same session")
        store.reset()
        store.ask(request)
        XCTAssertEqual(store.requests.count, 1, "a new session asks again")
        XCTAssertTrue(store.isQueued(circleId: "c1", userId: newcomer))

        store.letIn(request, owner: me)
        XCTAssertFalse(store.isQueued(circleId: "c1", userId: newcomer))
        XCTAssertTrue(store.approvedMembers(owner: me, circleId: "c1").contains(newcomer),
                      "let in: confirmed on this device from now on")
    }

    /// There is no question about someone with no statement: its words
    /// appear nowhere in the app.
    @MainActor
    func testThereIsNoQuestionAboutSomeoneWithNoStatement() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let files = FileManager.default.enumerator(at: root.appendingPathComponent("App"), includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(text.contains("older version of Pingolin"), file.lastPathComponent)
            XCTAssertFalse(text.contains(".olderVersion"), file.lastPathComponent)
        }
    }

    /// Someone invited by a person this device can't confirm — their
    /// number is shown so the answer can be checked another way first.
    @MainActor
    func testTheUnconfirmedInviterQuestionShowsTheirNumber() {
        let request = KeyDeliveryRequest(
            circleId: "c1", circleName: "Family", userId: newcomer, displayName: "Sam", email: "sam@example.com",
            reason: .unconfirmedInviter, sharingKeyHex: "aa", signingKeyHex: "bb",
            number: "12345 67890")
        XCTAssertEqual(KeyDeliveryApprovals.title(for: request), "Let Sam into Family?")
        XCTAssertEqual(KeyDeliveryApprovals.question(for: request, device: "phone"),
                       "Sam (sam@example.com) was invited by someone this phone can't confirm. If you're not sure it's them, check with Sam another way first. Their number: 12345 67890.")
        let bare = KeyDeliveryRequest(
            circleId: "c1", circleName: "Family", userId: newcomer, displayName: "Sam", email: nil,
            reason: .unconfirmedInviter)
        XCTAssertEqual(KeyDeliveryApprovals.question(for: bare, device: "iPad"),
                       "Sam was invited by someone this iPad can't confirm. If you're not sure it's them, check with Sam another way first.")
    }

    // MARK: - The banner

    func testTheRemovalBannerShowsOnlyWhileARemovalIsPending() {
        var circle = Circle(id: "c1", name: "Family", isOwner: true, keyRotationNeeded: true,
                            keyVersion: 4, keyRotationCause: "member_removed")
        XCTAssertTrue(circle.removedMemberStillHasKey)
        circle.keyRotationCause = "member_left"
        XCTAssertTrue(circle.removedMemberStillHasKey)
        circle.keyRotationCause = "periodic"
        XCTAssertFalse(circle.removedMemberStillHasKey, "a scheduled re-key is not a removal")
        circle.keyRotationCause = "member_removed"
        circle.keyRotationNeeded = false
        XCTAssertFalse(circle.removedMemberStillHasKey, "re-keyed: nothing to warn about")

        XCTAssertEqual(CircleKeyNoticeCopy.removalPending(cause: "member_removed", name: "Sam"),
                       "Finishing removing Sam. This completes as soon as a member's app is online.")
        XCTAssertEqual(CircleKeyNoticeCopy.removalPending(cause: "member_removed", name: nil),
                       "Finishing removing a member. This completes as soon as a member's app is online.")
        XCTAssertEqual(CircleKeyNoticeCopy.removalPending(cause: "member_left", name: nil),
                       "Finishing the update after someone left. This completes as soon as a member's app is online.")
    }

    /// The converter carries the cause only while the flag is set.
    func testTheCauseArrivesFromTheCircleList() throws {
        let body = Data("""
        {"success":true,"data":{"id":"11111111-1111-4111-8111-1111111111c1","owner_id":"u1","is_owner":true,
         "encrypted_name":{"nonce":"00","ciphertext":"00"},"day_bucket":20000,"member_count":2,
         "key_version":4,"key_rotation_needed":true,"key_rotation_cause":"member_removed"}}
        """.utf8)
        let response: CircleResponse = try APIService.decodeResponseBody(body)
        XCTAssertTrue(response.toModel(name: "Family").removedMemberStillHasKey)
    }
}
