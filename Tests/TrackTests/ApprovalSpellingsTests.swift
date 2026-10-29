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

/// The approval records key every owner, circle and invitee by its one
/// canonical form, the compares that let someone in take account ids only, and
/// a circle an earlier build kept under two spellings folds into one record,
/// whatever keeps someone out winning.
@MainActor
final class ApprovalSpellingsTests: XCTestCase {
    private var suites: [String] = []
    private static let tag = "device-tag"
    private let me = "0e0e0e0e-1111-4222-8333-444455556666"
    private let circle = "c3000000-0000-4000-8000-000000000001"
    private var upper: String { circle.uppercased() }
    private var bare: String { circle.replacingOccurrences(of: "-", with: "") }
    private func member(_ n: Int) -> String { String(format: "d3000000-0000-4000-8000-%012d", n) }

    override func tearDown() {
        for name in suites { UserDefaults().removePersistentDomain(forName: name) }
        super.tearDown()
    }

    private func suite() -> UserDefaults {
        let name = "ApprovalSpellingsTests.\(UUID().uuidString)"
        suites.append(name)
        return UserDefaults(suiteName: name)!
    }

    private func approvals(_ defaults: UserDefaults) -> KeyDeliveryApprovals {
        KeyDeliveryApprovals(
            defaults: defaults, deviceTag: { Self.tag },
            lock: AppGroupLock(url: FileManager.default.temporaryDirectory
                .appendingPathComponent("approvals-\(UUID().uuidString).lock")))
    }

    private func record(entries: [String: ApprovalOrigin] = [:], tombstones: [String: ApprovalTombstone] = [:],
                        invitees: [String: PendingInvitee] = [:], seeds: Set<String> = [], owed: Set<String> = [],
                        receiveOnly: [String: MemberKeyPair] = [:], dead: Set<String> = [],
                        tag: String? = ApprovalSpellingsTests.tag) -> CircleApprovalRecord {
        var record = CircleApprovalRecord()
        record.entries = entries
        record.tombstones = tombstones
        record.invitees = invitees
        record.seedCandidates = seeds
        record.admissionsOwed = owed
        record.receiveOnlyKeys = receiveOnly
        record.deadStatementIds = dead
        record.deviceTag = tag
        return record
    }

    private func key(_ circleId: String) -> String { "keyDeliveryApprovals.v2.\(me).\(circleId)" }

    private func put(_ record: CircleApprovalRecord, _ circleId: String, in defaults: UserDefaults) throws {
        defaults.set(try JSONEncoder().encode(record), forKey: key(circleId))
    }

    private func stored(_ circleId: String, in defaults: UserDefaults) -> CircleApprovalRecord? {
        defaults.data(forKey: key(circleId)).flatMap { try? JSONDecoder().decode(CircleApprovalRecord.self, from: $0) }
    }

    // MARK: - Keys

    func testSameKeyIsForKeysOnly() {
        XCTAssertTrue(CanonicalId.sameKey(circle, upper))
        XCTAssertTrue(CanonicalId.sameKey(bare, "{\(circle)}"))
        XCTAssertTrue(CanonicalId.sameKey("Alice", "alice"), "equal non-UUIDs file together")
        XCTAssertFalse(CanonicalId.sameKey(nil, nil), "a nil is never a key")
        XCTAssertFalse(CanonicalId.sameKey(circle, nil))
        XCTAssertFalse(CanonicalId.sameKey(circle, member(1)))
        XCTAssertFalse(CanonicalId.same("alice", "alice"), "the including compare: no account")
    }

    /// Every spelling of an owner or a circle names one record.
    func testEverySpellingNamesOneRecord() {
        for spelling in [circle, upper, bare, "{\(circle)}", "urn:uuid:\(circle)"] {
            XCTAssertEqual(ApprovalRecordStore.key(owner: me.uppercased(), circleId: spelling), key(circle), spelling)
            XCTAssertEqual(ApprovalRecordStore.legacyKey(owner: me, circleId: spelling),
                           "keyDeliveryApproved.\(me).\(circle)", spelling)
        }
        XCTAssertEqual(ApprovalRecordStore.transitionKey(owner: me.replacingOccurrences(of: "-", with: "")),
                       "keyDeliveryApprovals.transitionSeed.\(me)")
        let defaults = suite()
        let store = approvals(defaults)
        store.approve(owner: me.uppercased(), circleId: bare, userId: member(1), origin: .ownAction)
        XCTAssertEqual(store.record(owner: me, circleId: "{\(circle)}").entries, [member(1): .ownAction])
        XCTAssertEqual(ApprovalRecordStore.stored(in: defaults, owner: me, circleId: upper, deviceTag: Self.tag),
                       .record(store.record(owner: me, circleId: circle)))
    }

    /// The invitees, by member key: every spelling is one entry, and two an
    /// earlier build kept give one where they name one statement (the
    /// earlier expiry) and none where they don't.
    func testTheInviteesAreByMemberKey() throws {
        var record = CircleApprovalRecord()
        record.recordInvitee(userId: member(1).uppercased(), statementId: "S-1", expiresAt: 100)
        record.recordInvitee(userId: member(1).replacingOccurrences(of: "-", with: ""), statementId: "s-1", expiresAt: 90)
        XCTAssertEqual(record.invitees, [member(1): PendingInvitee(statementId: "s-1", expiresAt: 90)])
        let kept = #"{"invitees":{"\#(member(2))":{"statementId":"s-2","expiresAt":100},"#
            + #""\#(member(2).uppercased())":{"statementId":"s-2","expiresAt":80},"#
            + #""\#(member(3))":{"statementId":"s-3","expiresAt":100},"#
            + #""\#(member(3).uppercased())":{"statementId":"s-4","expiresAt":100}}}"#
        let read = try JSONDecoder().decode(CircleApprovalRecord.self, from: Data(kept.utf8))
        XCTAssertEqual(read.invitees, [member(2): PendingInvitee(statementId: "s-2", expiresAt: 80)],
                       "one statement: the earlier expiry; two: none")
    }

    /// The compares that let someone in take account ids only: a non-UUID is
    /// nobody's invitee, is never listed and is never seeded; a UUID in any
    /// spelling is.
    func testOnlyAnAccountsIdIsLetIn() {
        var record = CircleApprovalRecord()
        record.recordInvitee(userId: member(1), statementId: "s-1", expiresAt: 4_000_000_000)
        record.recordInvitee(userId: "nadia", statementId: "s-n", expiresAt: 4_000_000_000)
        XCTAssertTrue(record.holdsPendingInvitation(subject: member(1).uppercased(), statementId: "S-1", now: 3_000_000_000))
        XCTAssertFalse(record.holdsPendingInvitation(subject: "nadia", statementId: "s-n", now: 3_000_000_000))
        var kept = record
        kept.keepInvitees(pendingStatementIds: [], listedUsers: ["NADIA", "{\(member(1))}"])
        XCTAssertEqual(Array(kept.invitees.keys), [member(1)], "listed by id only")
        record.settleInvitees(roster: [member(1).uppercased(): "S-1", "nadia": "s-n"], now: 3_000_000_000)
        XCTAssertEqual(record.entries.count, 1)
        XCTAssertEqual(record.entries.first.map { CanonicalId.key($0.key) }, member(1))
        XCTAssertEqual(record.entries.first?.value, .ownAction)
        XCTAssertEqual(Array(record.invitees.keys), ["nadia"], "nobody's: it goes at expiry")
        record.settleInvitees(roster: ["nadia": "s-n"], now: 4_000_000_301)
        XCTAssertTrue(record.invitees.isEmpty)

        var seeded = CircleApprovalRecord()
        seeded.seedCandidates = [member(2).uppercased(), "omar"]
        seeded.applySeed(roster: [member(2), "omar"])
        XCTAssertEqual(seeded.entries, [member(2): .preRound2Seed], "a pin names an account, or nobody")
    }

    /// The seed leaves the account itself out in any spelling (a compare that
    /// keeps someone OUT: equal non-UUIDs too); the owners are listed by key;
    /// a record under the owner's bare spelling moves to the one form's key.
    func testTheOwnersKeys() throws {
        let defaults = suite()
        let store = approvals(defaults)
        XCTAssertEqual(store.takeTransitionSeed(owner: "Me", pins: ["c1": ["me", "alice"]]), 1)
        XCTAssertEqual(store.record(owner: "me", circleId: "c1").seedCandidates, ["alice"])
        let bareOwnersKey = "keyDeliveryApprovals.v2.\(me.replacingOccurrences(of: "-", with: "")).\(circle)"
        defaults.set(try JSONEncoder().encode(record(entries: [member(1): .statement])), forKey: bareOwnersKey)
        XCTAssertEqual(store.owners(), ["me", me])
        approvals(defaults).normalizeOwners()
        XCTAssertEqual(stored(circle, in: defaults)?.entries, [member(1): .statement])
        XCTAssertNil(defaults.object(forKey: bareOwnersKey))
        // Both owner spellings there: the owner rule, restrictions only.
        defaults.set(try JSONEncoder().encode(record(
            entries: [member(2): .ownAction],
            tombstones: [member(3): ApprovalTombstone(statementIds: ["s-3"], activeVersion: 1)])), forKey: bareOwnersKey)
        approvals(defaults).normalizeOwners()
        XCTAssertEqual(stored(circle, in: defaults)?.entries, [member(1): .statement], "nothing that grants comes with it")
        XCTAssertEqual(stored(circle, in: defaults)?.tombstones[member(3)],
                       ApprovalTombstone(statementIds: ["s-3"], activeVersion: 1))
    }

    // MARK: - Two spellings of one circle

    /// A removed member's tombstone kept under the upper-case spelling is
    /// read under the one form, and the removal beats the approval the other
    /// record holds. The other spelling goes.
    func testATombstoneUnderAnotherSpellingIsReadAndBeatsAnApproval() throws {
        let defaults = suite()
        try put(record(entries: [member(1): .statement, member(2): .ownAction]), circle, in: defaults)
        try put(record(tombstones: [member(1): ApprovalTombstone(statementIds: ["s-1"], activeVersion: 3)], dead: ["d-1"]),
                upper, in: defaults)
        let store = approvals(defaults)
        store.normalizeOwners()
        let folded = store.record(owner: me, circleId: upper)
        XCTAssertNil(folded.entries[member(1)], "the removal wins")
        XCTAssertEqual(folded.entries[member(2)], .ownAction)
        XCTAssertEqual(folded.tombstones[member(1)], ApprovalTombstone(statementIds: ["s-1"], activeVersion: 3))
        XCTAssertEqual(folded.deadStatementIds, ["d-1"])
        XCTAssertNil(defaults.object(forKey: key(upper)), "the other spelling goes once the fold reads back")
        XCTAssertEqual(stored(circle, in: defaults), folded)
    }

    /// Approvals that disagree: the canonical spelling's, and with none there,
    /// none (asked again). One spelling alone, or all agreeing, holds.
    func testDisagreeingApprovalsGiveTheCanonicalOrNone() throws {
        let defaults = suite()
        try put(record(entries: [member(1): .statement, member(2): .ownAction]), circle, in: defaults)
        try put(record(entries: [member(1): .ownAction, member(3).uppercased(): .statement]), upper, in: defaults)
        let other = "c3000000-0000-4000-8000-000000000002"
        try put(record(entries: [member(4): .statement, member(5): .ownAction]), other.uppercased(), in: defaults)
        try put(record(entries: [member(4): .ownAction, member(5): .ownAction]),
                other.replacingOccurrences(of: "-", with: ""), in: defaults)
        approvals(defaults).normalizeOwners()
        XCTAssertEqual(stored(circle, in: defaults)?.entries,
                       [member(1): .statement, member(2): .ownAction, member(3): .statement])
        XCTAssertEqual(stored(other, in: defaults)?.entries, [member(5): .ownAction],
                       "no canonical spelling: the disagreeing member gets none")
    }

    /// Invitees: the earlier expiry for one statement, none for two, and none
    /// where two members name one statement. Seed candidates only when every
    /// spelling holds them; owed admissions from any, never for anyone the fold
    /// tombstones; receive-only keys only for receive-only entries.
    func testTheRestOfTheFold() throws {
        let defaults = suite()
        let keys = MemberKeyPair(sharingKeyHex: "aa", signingKeyHex: "bb")
        try put(record(entries: [member(6): .kind2],
                       tombstones: [member(9): ApprovalTombstone(statementIds: [], activeVersion: 1)],
                       invitees: [member(1): PendingInvitee(statementId: "s-1", expiresAt: 100),
                                  member(3): PendingInvitee(statementId: "s-9", expiresAt: 100)],
                       seeds: [member(7), member(8)], owed: [member(1)], receiveOnly: [member(6): keys]),
                circle, in: defaults)
        try put(record(entries: [member(6): .kind2],
                       invitees: [member(1): PendingInvitee(statementId: "s-1", expiresAt: 50),
                                  member(2): PendingInvitee(statementId: "s-2", expiresAt: 70),
                                  member(4): PendingInvitee(statementId: "s-9", expiresAt: 100)],
                       seeds: [member(8)], owed: [member(2), member(9)], receiveOnly: [member(7): keys]),
                upper, in: defaults)
        try put(record(invitees: [member(2): PendingInvitee(statementId: "s-3", expiresAt: 80)], seeds: [member(8)]),
                bare, in: defaults)
        approvals(defaults).normalizeOwners()
        let folded = try XCTUnwrap(stored(circle, in: defaults))
        XCTAssertEqual(folded.invitees, [member(1): PendingInvitee(statementId: "s-1", expiresAt: 50)])
        XCTAssertEqual(folded.seedCandidates, [member(8)])
        XCTAssertEqual(folded.admissionsOwed, [member(1), member(2)])
        XCTAssertEqual(folded.receiveOnlyKeys, [member(6): keys], "none for a member with no receive-only entry")
        XCTAssertNil(defaults.object(forKey: key(upper)))
        XCTAssertNil(defaults.object(forKey: key(bare)))
    }

    /// A record another device's (restored from a backup) gives only what
    /// restricts. One that doesn't read keeps every spelling as it is.
    func testAnotherDevicesRecordOnlyRestrictsAndAnUnreadableOneStops() throws {
        let defaults = suite()
        try put(record(entries: [member(1): .statement]), circle, in: defaults)
        try put(record(entries: [member(2): .ownAction],
                       tombstones: [member(3): ApprovalTombstone(statementIds: ["s-3"], activeVersion: 2)], tag: "other"),
                upper, in: defaults)
        let other = "c3000000-0000-4000-8000-000000000002"
        try put(record(entries: [member(4): .statement]), other, in: defaults)
        defaults.set(Data("{not json".utf8), forKey: key(other.uppercased()))
        approvals(defaults).normalizeOwners()
        let folded = try XCTUnwrap(stored(circle, in: defaults))
        XCTAssertEqual(folded.entries, [member(1): .statement], "another device's approval grants nothing here")
        XCTAssertEqual(folded.tombstones[member(3)], ApprovalTombstone(statementIds: ["s-3"], activeVersion: 2))
        XCTAssertEqual(folded.deviceTag, Self.tag)
        XCTAssertEqual(stored(other, in: defaults)?.entries, [member(4): .statement])
        XCTAssertEqual(defaults.data(forKey: key(other.uppercased())), Data("{not json".utf8), "kept verbatim")
    }

    /// While a spelling doesn't read, the circle grants NOTHING (that one
    /// may hold a tombstone), in the app and in the extension, before the
    /// fold and after it; what the readable spellings restrict still holds.
    func testAnUndecodableSpellingGrantsNothing() throws {
        let defaults = suite()
        try put(record(entries: [member(1): .statement], invitees: [member(2): PendingInvitee(statementId: "s-2", expiresAt: 9)],
                       seeds: [member(3)], owed: [member(4)]), circle, in: defaults)
        defaults.set(Data("{not json".utf8), forKey: key(upper))
        try put(record(tombstones: [member(5): ApprovalTombstone(statementIds: ["s-5"], activeVersion: 4)], dead: ["d-5"]),
                bare, in: defaults)
        func check(_ store: KeyDeliveryApprovals, _ when: String) throws {
            let read = store.record(owner: me, circleId: circle)
            XCTAssertEqual(read.entries, [:], "no approval (\(when))")
            XCTAssertEqual(read.invitees, [:], when)
            XCTAssertEqual(read.seedCandidates, [], when)
            XCTAssertEqual(read.admissionsOwed, [], when)
            XCTAssertEqual(read.tombstones[member(5)], ApprovalTombstone(statementIds: ["s-5"], activeVersion: 4), when)
            XCTAssertEqual(read.deadStatementIds, ["d-5"], when)
            guard case .record(let extensionRead) = ApprovalRecordStore.stored(
                in: defaults, owner: me, circleId: circle, deviceTag: Self.tag) else { return XCTFail(when) }
            XCTAssertEqual(extensionRead, read, "the extension reads the same (\(when))")
        }
        try check(approvals(defaults), "before the fold")
        let store = approvals(defaults)
        store.normalizeOwners()
        try check(store, "after it")
        XCTAssertEqual(stored(circle, in: defaults)?.entries, [member(1): .statement], "kept as it is, verbatim")
        XCTAssertEqual(defaults.data(forKey: key(upper)), Data("{not json".utf8))
        XCTAssertNotNil(defaults.object(forKey: key(bare)))
    }

    /// Before the app's fold, a read folds the spellings in memory: the
    /// extension never reads one spelling alone.
    func testAReadBeforeTheFoldFoldsInMemory() throws {
        let defaults = suite()
        try put(record(entries: [member(1): .statement, member(2): .ownAction]), circle, in: defaults)
        try put(record(tombstones: [member(1): ApprovalTombstone(statementIds: ["s-1"], activeVersion: 3)]), upper, in: defaults)
        guard case .record(let read) = ApprovalRecordStore.stored(
            in: defaults, owner: me, circleId: bare, deviceTag: Self.tag) else { return XCTFail("no record") }
        XCTAssertEqual(read.entries, [member(2): .ownAction], "the removal wins, unfolded on disk still")
        XCTAssertEqual(approvals(defaults).record(owner: me, circleId: circle), read)
        XCTAssertNotNil(defaults.object(forKey: key(upper)), "a read writes nothing")
    }

    /// One spelling alone moves; folding again changes nothing; the legacy
    /// keys move when the one form's is free, and it stays when both are
    /// there.
    func testAMoveTheSecondPassAndTheLegacyKeys() throws {
        let defaults = suite()
        try put(record(entries: [member(1): .statement]), upper, in: defaults)
        defaults.set([member(2)], forKey: "keyDeliveryApproved.\(me).\(bare)")
        defaults.set([member(3)], forKey: "keyDeliveryApproved.\(me).\(bare).invited")
        let other = "c3000000-0000-4000-8000-000000000002"
        defaults.set([member(4)], forKey: "keyDeliveryApproved.\(me).\(other)")
        defaults.set([member(5)], forKey: "keyDeliveryApproved.\(me).\(other.uppercased())")
        approvals(defaults).normalizeOwners()
        XCTAssertEqual(stored(circle, in: defaults)?.entries, [member(1): .statement])
        XCTAssertNil(defaults.object(forKey: key(upper)))
        XCTAssertEqual(defaults.stringArray(forKey: "keyDeliveryApproved.\(me).\(circle)"), [member(2)])
        XCTAssertEqual(defaults.stringArray(forKey: "keyDeliveryApproved.\(me).\(circle).invited"), [member(3)])
        XCTAssertNil(defaults.object(forKey: "keyDeliveryApproved.\(me).\(bare)"))
        XCTAssertEqual(defaults.stringArray(forKey: "keyDeliveryApproved.\(me).\(other)"), [member(4)], "the one form's stays")
        XCTAssertNil(defaults.object(forKey: "keyDeliveryApproved.\(me).\(other.uppercased())"))

        let before = defaults.dictionaryRepresentation().filter { $0.key.hasPrefix("keyDelivery") }
        approvals(defaults).normalizeOwners()
        let after = defaults.dictionaryRepresentation().filter { $0.key.hasPrefix("keyDelivery") }
        XCTAssertEqual(Set(before.keys), Set(after.keys))
        for (key, value) in before { XCTAssertEqual(after[key] as? NSObject, value as? NSObject, key) }
    }

    /// The fold itself is the same folded again.
    func testTheFoldIsIdempotent() {
        let one = record(entries: [member(1): .statement, member(2): .ownAction],
                         invitees: [member(4): PendingInvitee(statementId: "s-4", expiresAt: 9)], seeds: [member(5)])
        let two = record(entries: [member(1): .ownAction],
                         tombstones: [member(2): ApprovalTombstone(statementIds: ["s-2"], activeVersion: 1)],
                         invitees: [member(4).uppercased(): PendingInvitee(statementId: "s-4", expiresAt: 7)], seeds: [member(5)])
        let folded = CircleApprovalRecord.folded([(canonical: true, record: one), (canonical: false, record: two)], tag: Self.tag)
        XCTAssertEqual(CircleApprovalRecord.folded([(canonical: true, record: folded)], tag: Self.tag), folded)
        XCTAssertEqual(folded.entries, [member(1): .statement])
        XCTAssertEqual(folded.invitees, [member(4): PendingInvitee(statementId: "s-4", expiresAt: 7)])
        XCTAssertEqual(folded.seedCandidates, [member(5)])
    }
}
