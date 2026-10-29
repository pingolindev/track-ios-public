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

/// The approval records live in the app group, where the notification
/// extension can read them. They move there once from the app's own defaults,
/// and the extension's way in reads without changing anything. They are this
/// device's only (its tag), the extension records departures into them, and
/// the app merges with what it finds — never overwrites.
@MainActor
final class ApprovalRecordStoreTests: XCTestCase {
    private static let tag = "this-devices-tag"
    private var suites: [String] = []

    override func tearDown() {
        for name in suites { UserDefaults().removePersistentDomain(forName: name) }
        suites.removeAll()
        super.tearDown()
    }

    private func suite() -> (name: String, defaults: UserDefaults) {
        let name = "ApprovalRecordStoreTests.\(UUID().uuidString)"
        suites.append(name)
        return (name, UserDefaults(suiteName: name)!)
    }

    private func encoded(_ entries: [String: ApprovalOrigin], tag: String? = nil) throws -> Data {
        var record = CircleApprovalRecord()
        record.entries = entries
        record.deviceTag = tag
        return try JSONEncoder().encode(record)
    }

    /// The app's store on `defaults`, as this device (`tag`).
    func approvals(_ defaults: UserDefaults, tag: String? = ApprovalRecordStoreTests.tag,
                   lock: AppGroupLock? = nil, lockWait: TimeInterval = 3) -> KeyDeliveryApprovals {
        KeyDeliveryApprovals(defaults: defaults, deviceTag: { tag }, lock: lock ?? scratchLock(), lockWait: lockWait)
    }

    private func scratchLock() -> AppGroupLock {
        AppGroupLock(url: FileManager.default.temporaryDirectory.appendingPathComponent("approvals-\(UUID().uuidString).lock"))
    }

    /// The record stored under `key`, decoded (JSON key order is not stable,
    /// so bytes are not compared).
    private func entries(_ defaults: UserDefaults, _ key: String) -> [String: ApprovalOrigin]? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(CircleApprovalRecord.self, from: $0) }?.entries
    }

    /// Every record — the v2 records, the legacy keys (`legacyPrefix`) and
    /// the one-time-seed marks — moves; nothing else does; the copies in the
    /// app's own defaults go once the group holds them.
    func testTheRecordsMoveToTheAppGroupOnce() throws {
        let old = suite().defaults
        let group = suite()
        let v2 = ApprovalRecordStore.key(owner: "me", circleId: "c1")
        old.set(try encoded(["alice": .statement]), forKey: v2)
        old.set(["bob"], forKey: "keyDeliveryApproved.me.c2")
        old.set(true, forKey: "keyDeliveryApprovals.transitionSeed.me")
        old.set("unrelated", forKey: "memberKeyQuestion.askedAt")

        let store = KeyDeliveryApprovals.movedToAppGroup(from: old, suiteName: group.name)

        XCTAssertEqual(entries(store, v2), ["alice": .statement])
        XCTAssertEqual(store.stringArray(forKey: "keyDeliveryApproved.me.c2"), ["bob"])
        XCTAssertTrue(store.bool(forKey: "keyDeliveryApprovals.transitionSeed.me"))
        XCTAssertTrue(store.bool(forKey: KeyDeliveryApprovals.movedMark))
        XCTAssertNil(old.object(forKey: v2))
        XCTAssertNil(old.object(forKey: "keyDeliveryApproved.me.c2"))
        XCTAssertNil(old.object(forKey: "keyDeliveryApprovals.transitionSeed.me"))
        XCTAssertEqual(old.string(forKey: "memberKeyQuestion.askedAt"), "unrelated", "nothing else moves")
        XCTAssertNil(group.defaults.object(forKey: "memberKeyQuestion.askedAt"))
        // Moved already: what the app wrote in the group since stays, and a
        // leftover old copy (a clean-up cut short) is only removed.
        store.set(try encoded(["alice": .statement, "carol": .ownAction]), forKey: v2)
        old.set(try encoded(["alice": .statement]), forKey: v2)
        let again = KeyDeliveryApprovals.movedToAppGroup(from: old, suiteName: group.name)
        XCTAssertEqual(entries(again, v2), ["alice": .statement, "carol": .ownAction])
        XCTAssertNil(old.object(forKey: v2))
    }

    /// A move cut short before its mark is redone over its partial copy: until
    /// the mark, the copies in the app's own defaults are the record.
    func testAMoveCutShortIsRedoneFromTheOldCopies() throws {
        let old = suite().defaults
        let group = suite()
        let v2 = ApprovalRecordStore.key(owner: "me", circleId: "c1")
        old.set(try encoded(["alice": .statement, "bob": .ownAction]), forKey: v2)
        group.defaults.set(try encoded(["alice": .statement]), forKey: v2)  // partial, no mark

        let store = KeyDeliveryApprovals.movedToAppGroup(from: old, suiteName: group.name)

        XCTAssertEqual(entries(store, v2), ["alice": .statement, "bob": .ownAction])
        XCTAssertNil(old.object(forKey: v2))
    }

    /// The extension's only way in: the stored record exactly as it is, never
    /// migrated, never written.
    func testTheExtensionsReadChangesNothing() throws {
        let defaults = suite().defaults
        let tag = Self.tag
        XCTAssertEqual(ApprovalRecordStore.stored(in: defaults, owner: "me", circleId: "c1", deviceTag: tag), .none)
        defaults.set(["alice"], forKey: "keyDeliveryApproved.me.c1")
        XCTAssertEqual(ApprovalRecordStore.stored(in: defaults, owner: "me", circleId: "c1", deviceTag: tag), .none,
                       "the legacy keys: only the app migrates them")
        defaults.set(Data("not a record".utf8), forKey: ApprovalRecordStore.key(owner: "me", circleId: "c1"))
        XCTAssertEqual(ApprovalRecordStore.stored(in: defaults, owner: "me", circleId: "c1", deviceTag: tag), .unreadable)
        defaults.set(try encoded(["alice": .statement], tag: tag), forKey: ApprovalRecordStore.key(owner: "me", circleId: "c2"))
        let before = defaults.dictionaryRepresentation() as NSDictionary
        var expected = CircleApprovalRecord()
        expected.entries = ["alice": .statement]
        expected.deviceTag = tag
        XCTAssertEqual(ApprovalRecordStore.stored(in: defaults, owner: "me", circleId: "c2", deviceTag: tag), .record(expected))
        XCTAssertEqual(defaults.dictionaryRepresentation() as NSDictionary, before)
        // Another device's (a backup's), an untagged one, or no tag here: none.
        XCTAssertEqual(ApprovalRecordStore.stored(in: defaults, owner: "me", circleId: "c2", deviceTag: "another"), .none)
        XCTAssertEqual(ApprovalRecordStore.stored(in: defaults, owner: "me", circleId: "c2", deviceTag: nil), .none)
        defaults.set(try encoded(["alice": .statement]), forKey: ApprovalRecordStore.key(owner: "me", circleId: "c3"))
        XCTAssertEqual(ApprovalRecordStore.stored(in: defaults, owner: "me", circleId: "c3", deviceTag: tag), .none)
    }

    /// The app keeps its records where the extension reads them.
    func testTheAppKeepsItsRecordsWhereTheExtensionReadsThem() throws {
        XCTAssertEqual(ApprovalRecordStore.suiteName, ExtensionBridge.suite)
        XCTAssertEqual(ExtensionBridgeKeys.suite, ExtensionBridge.suite)
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("App/Managers/KeyDeliveryApprovals.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("static let shared = KeyDeliveryApprovals(defaults: movedToAppGroup())"))
        let auth = try String(contentsOf: root.appendingPathComponent("App/Managers/AuthManager.swift"), encoding: .utf8)
        XCTAssertTrue(auth.contains("ExtensionBridge.syncAccount(userId: currentUser.flatMap { CanonicalId.of($0.id) }, email: currentUser?.email,"),
                      "the extension decides with the email the app's pass uses, and the account in its one form")
    }

    /// A roster pass's record is stored as one change, never over a record this
    /// build cannot read, and ends a "Not now" on whoever it confirmed.
    func testARosterPassIsStoredAsOneChange() throws {
        let (name, defaults) = suite()
        _ = name
        let store = approvals(defaults)
        var passRecord = CircleApprovalRecord()
        passRecord.entries = ["alice": .statement]
        XCTAssertFalse(store.store(passRecord, base: CircleApprovalRecord(), owner: "me", circleId: "c1", confirmed: ["alice"]),
                       "nothing changed meanwhile")
        passRecord.deviceTag = Self.tag
        XCTAssertEqual(store.record(owner: "me", circleId: "c1"), passRecord, "stored as this device's")
        defaults.set(Data("from a newer build".utf8), forKey: ApprovalRecordStore.key(owner: "me", circleId: "c2"))
        store.store(passRecord, base: CircleApprovalRecord(), owner: "me", circleId: "c2", confirmed: ["alice"])
        XCTAssertEqual(defaults.data(forKey: ApprovalRecordStore.key(owner: "me", circleId: "c2")),
                       Data("from a newer build".utf8), "a record this build cannot read is never overwritten")
    }

    // MARK: - This device's records only

    /// A record another device made (restored from its backup: another tag) or
    /// that nobody stamped is no record here: it confirms nobody, and the next
    /// write replaces it with this device's own. Without a tag nothing is read
    /// or written at all.
    func testARecordFromAnotherDeviceIsNoRecord() throws {
        let defaults = suite().defaults
        let key = ApprovalRecordStore.key(owner: "me", circleId: "c1")
        defaults.set(try encoded(["alice": .ownAction, "me": .ownAction], tag: "another-phone"), forKey: key)
        let store = approvals(defaults)
        XCTAssertEqual(store.record(owner: "me", circleId: "c1"), CircleApprovalRecord())
        XCTAssertEqual(store.approvedMembers(owner: "me", circleId: "c1"), [])
        XCTAssertFalse(AccessHandover.createdHere(store.record(owner: "me", circleId: "c1"), me: "me"),
                       "a backup's word that this user created the circle counts for nothing")

        store.approve(owner: "me", circleId: "c1", userId: "bob", origin: .statement)
        var fresh = CircleApprovalRecord()
        fresh.entries = ["bob": .statement]
        fresh.deviceTag = Self.tag
        XCTAssertEqual(store.record(owner: "me", circleId: "c1"), fresh, "started fresh, as this device's")

        defaults.set(try encoded(["alice": .ownAction]), forKey: key)
        XCTAssertEqual(store.record(owner: "me", circleId: "c1"), CircleApprovalRecord(), "untagged: nobody's")

        let untaggedDevice = approvals(defaults, tag: nil)
        untaggedDevice.approve(owner: "me", circleId: "c2", userId: "bob")
        XCTAssertNil(defaults.object(forKey: ApprovalRecordStore.key(owner: "me", circleId: "c2")),
                     "no tag, no write: an untagged record would never be read back")
    }

    /// The first run of this build binds the records already here to this
    /// device — only when the keychain still holds this device's own items (an
    /// update keeps them; a backup restored onto another phone never carries
    /// them). Otherwise the tag is made and nothing is adopted: the device
    /// starts fresh. The legacy keys follow the same rule. Once bound, never
    /// again.
    func testBindingAdoptsTheRecordsOnlyOnTheDeviceThatMadeThem() throws {
        let keyA = ApprovalRecordStore.key(owner: "me", circleId: "c1")
        let keyB = ApprovalRecordStore.key(owner: "me", circleId: "c2")
        func prepared() throws -> UserDefaults {
            let defaults = suite().defaults
            defaults.set(try encoded(["alice": .statement]), forKey: keyA)
            defaults.set(try encoded(["carol": .ownAction], tag: "another-phone"), forKey: keyB)
            defaults.set(["dave"], forKey: "keyDeliveryApproved.me.c3")
            return defaults
        }

        // An update on the same phone: adopted.
        let updated = try prepared()
        var created = 0
        XCTAssertTrue(KeyDeliveryApprovals.bindToThisDevice(
            updated, tag: { nil }, createTag: { created += 1; return "new-tag" }, keychainIsThisDevices: true,
            lock: scratchLock()))
        XCTAssertEqual(created, 1)
        let adopted = approvals(updated, tag: "new-tag")
        XCTAssertEqual(adopted.record(owner: "me", circleId: "c1").entries, ["alice": .statement])
        XCTAssertEqual(adopted.record(owner: "me", circleId: "c2"), CircleApprovalRecord(), "another phone's stays another's")
        XCTAssertEqual(adopted.record(owner: "me", circleId: "c3").entries, ["dave": .preRound2Seed], "the legacy record, adopted")

        // Restored from a backup onto another phone: the tag is made, nothing adopted.
        let restored = try prepared()
        XCTAssertFalse(KeyDeliveryApprovals.bindToThisDevice(
            restored, tag: { nil }, createTag: { "new-tag" }, keychainIsThisDevices: false, lock: scratchLock()))
        let fresh = approvals(restored, tag: "new-tag")
        XCTAssertEqual(fresh.record(owner: "me", circleId: "c1"), CircleApprovalRecord())
        XCTAssertEqual(fresh.record(owner: "me", circleId: "c3"), CircleApprovalRecord(), "the legacy keys too")
        XCTAssertNil(restored.object(forKey: ApprovalRecordStore.key(owner: "me", circleId: "c3")), "and nothing migrated")

        // Already bound, or no tag to be had: nothing happens.
        let bound = try prepared()
        XCTAssertFalse(KeyDeliveryApprovals.bindToThisDevice(
            bound, tag: { "old-tag" }, createTag: { XCTFail("never made twice"); return nil },
            keychainIsThisDevices: true, lock: scratchLock()))
        XCTAssertFalse(KeyDeliveryApprovals.bindToThisDevice(
            bound, tag: { nil }, createTag: { nil }, keychainIsThisDevices: true, lock: scratchLock()))
        XCTAssertEqual(approvals(bound, tag: "old-tag").record(owner: "me", circleId: "c1"), CircleApprovalRecord())
    }

    /// A legacy record, read from its `legacyPrefix` keys, is stored as a v2
    /// record at the first change the app makes — a no-op one included — so
    /// the extension, which never reads the legacy keys, sees it from then
    /// on. Reading alone stores nothing.
    func testALegacyRecordIsStoredAtTheFirstChange() throws {
        let defaults = suite().defaults
        defaults.set(["dave"], forKey: "keyDeliveryApproved.me.c1")
        defaults.set(Self.tag, forKey: ApprovalRecordStore.adoptedByKey)
        let store = approvals(defaults)
        XCTAssertEqual(store.record(owner: "me", circleId: "c1").entries, ["dave": .preRound2Seed])
        XCTAssertEqual(ApprovalRecordStore.stored(in: defaults, owner: "me", circleId: "c1", deviceTag: Self.tag), .none,
                       "reading stores nothing")
        store.retain(owner: "me", circleId: "c1", roster: ["me", "dave"], activeVersion: 1)
        guard case .record(let stored) = ApprovalRecordStore.stored(
            in: defaults, owner: "me", circleId: "c1", deviceTag: Self.tag) else {
            return XCTFail("stored as this round's, as this device's")
        }
        XCTAssertEqual(stored.entries, ["dave": .preRound2Seed])
    }

    // MARK: - Never written without the lock

    /// Another process holding the approvals lock (the extension, mid-write).
    private func held(_ lock: AppGroupLock) async throws -> AppGroupLock.Held {
        let taken = await AppGroupLock(url: lock.url).acquire(timeout: 1)
        return try XCTUnwrap(taken, "the other process holds the lock")
    }

    /// Without the lock nothing is written. A person's decision is kept and
    /// made once the lock is free (the next write, or a return to the
    /// foreground); a roster pass's is dropped — the next pass decides again.
    func testNothingIsWrittenWithoutTheLockAndAPersonsDecisionIsMadeLater() async throws {
        let defaults = suite().defaults
        let lock = scratchLock()
        let store = approvals(defaults, lock: lock, lockWait: 0.2)
        let key = ApprovalRecordStore.key(owner: "me", circleId: "c1")
        let other = try await held(lock)

        store.approve(owner: "me", circleId: "c1", userId: "alice", origin: .ownAction)
        var passRecord = CircleApprovalRecord()
        passRecord.entries = ["bob": .statement]
        XCTAssertFalse(store.store(passRecord, base: CircleApprovalRecord(), owner: "me", circleId: "c1", confirmed: []))
        XCTAssertNil(defaults.object(forKey: key), "nothing written while another process holds the lock")
        XCTAssertTrue(store.hasPendingWrites, "the decision waits")

        other.release()
        store.retryPending()
        XCTAssertFalse(store.hasPendingWrites)
        XCTAssertEqual(store.record(owner: "me", circleId: "c1").entries, ["alice": .ownAction],
                       "the person's decision is made; the pass's is not replayed")
    }

    /// A waiting "Let them in"'s choice counts only
    /// once it reads back as stored: while another process holds the lock it
    /// doesn't, and the change runs again. Stored, it replaces the
    /// confirmation this device made from its own admission.
    func testALetInsChoiceCountsOnlyOnceStored() async throws {
        let defaults = suite().defaults
        let lock = scratchLock()
        let store = approvals(defaults, lock: lock, lockWait: 0.2)
        store.approve(owner: "me", circleId: "c1", userId: "sam", origin: .statement)
        let other = try await held(lock)
        XCTAssertFalse(store.approveAnswer(owner: "me", circleId: "c1", userId: "sam"))
        XCTAssertEqual(store.record(owner: "me", circleId: "c1").entries, ["sam": .statement])
        other.release()
        XCTAssertTrue(store.approveAnswer(owner: "me", circleId: "c1", userId: "sam"))
        XCTAssertEqual(store.record(owner: "me", circleId: "c1").entries, ["sam": .ownAction])
    }

    /// The next write that gets the lock makes the queued ones first.
    func testTheNextWriteMakesTheQueuedOnesFirst() async throws {
        let defaults = suite().defaults
        let lock = scratchLock()
        let store = approvals(defaults, lock: lock, lockWait: 0.2)
        let other = try await held(lock)
        store.approve(owner: "me", circleId: "c1", userId: "alice", origin: .ownAction)
        other.release()
        store.approveInvitee(owner: "me", circleId: "c1", userId: "carol", statementId: "s-c", expiresAt: 4_000_000_000)
        let record = store.record(owner: "me", circleId: "c1")
        XCTAssertEqual(record.entries, ["alice": .ownAction])
        XCTAssertEqual(record.invitees, ["carol": PendingInvitee(statementId: "s-c", expiresAt: 4_000_000_000)])
        XCTAssertFalse(store.hasPendingWrites)
    }

    /// An account switch's wipe waits for the lock and runs before anything
    /// else; decisions queued for the other account are dropped at once.
    func testAnAccountSwitchWaitsForTheLockAndRunsFirst() async throws {
        let defaults = suite().defaults
        let lock = scratchLock()
        let store = approvals(defaults, lock: lock, lockWait: 0.2)
        store.approve(owner: "a", circleId: "c1", userId: "alice", origin: .ownAction)
        let other = try await held(lock)
        store.approve(owner: "a", circleId: "c2", userId: "bob", origin: .ownAction)
        store.clearAll(exceptOwner: "b")
        XCTAssertNotNil(defaults.object(forKey: ApprovalRecordStore.key(owner: "a", circleId: "c1")), "not wiped unlocked")
        other.release()
        store.approve(owner: "b", circleId: "c9", userId: "dan", origin: .ownAction)
        XCTAssertNil(defaults.object(forKey: ApprovalRecordStore.key(owner: "a", circleId: "c1")), "wiped first, once locked")
        XCTAssertNil(defaults.object(forKey: ApprovalRecordStore.key(owner: "a", circleId: "c2")),
                     "the other account's queued decision was dropped")
        XCTAssertEqual(store.record(owner: "b", circleId: "c9").entries, ["dan": .ownAction])
    }

    /// A sign-in's guarded tidy (`forget`) waits for the lock and runs first;
    /// the decisions queued for the account it forgets go with it, and
    /// another account's queued decisions stay.
    func testTheGuardedForgetWaitsForTheLockAndKeepsAnotherAccountsQueuedDecisions() async throws {
        let defaults = suite().defaults
        let lock = scratchLock()
        let store = approvals(defaults, lock: lock, lockWait: 0.2)
        store.approve(owner: "a", circleId: "c1", userId: "alice", origin: .ownAction)
        let other = try await held(lock)
        store.approve(owner: "a", circleId: "c2", userId: "bob", origin: .ownAction)
        store.approve(owner: "c", circleId: "c3", userId: "carl", origin: .ownAction)
        store.forget(owners: ["A"])
        XCTAssertNotNil(defaults.object(forKey: ApprovalRecordStore.key(owner: "a", circleId: "c1")), "not deleted unlocked")
        XCTAssertTrue(store.hasPendingWrites)
        other.release()
        store.retryPending()
        XCTAssertFalse(store.hasPendingWrites)
        XCTAssertNil(defaults.object(forKey: ApprovalRecordStore.key(owner: "a", circleId: "c1")), "deleted, once locked")
        XCTAssertNil(defaults.object(forKey: ApprovalRecordStore.key(owner: "a", circleId: "c2")),
                     "the forgotten account's queued decision went with it")
        XCTAssertEqual(store.record(owner: "c", circleId: "c3").entries, ["carl": .ownAction],
                       "another account's queued decision is made")
        XCTAssertEqual(store.owners(), ["c"])
    }

    /// The one-time seed is neither taken nor marked taken without the lock.
    func testTheTransitionSeedWaitsForTheLock() async throws {
        let defaults = suite().defaults
        let lock = scratchLock()
        let store = approvals(defaults, lock: lock, lockWait: 0.2)
        let other = try await held(lock)
        XCTAssertEqual(store.takeTransitionSeed(owner: "me", pins: ["c1": ["alice"]]), 0)
        XCTAssertFalse(store.transitionSeedTaken(owner: "me"), "not marked taken: the next call takes it")
        other.release()
        XCTAssertEqual(store.takeTransitionSeed(owner: "me", pins: ["c1": ["alice"]]), 1)
        XCTAssertEqual(store.record(owner: "me", circleId: "c1").seedCandidates, ["alice"])
    }

    /// Binding takes the lock BEFORE it makes the tag: without the lock no tag
    /// is made, so the next attempt can still adopt.
    func testBindingTakesTheLockBeforeTheTag() async throws {
        let defaults = suite().defaults
        defaults.set(try encoded(["alice": .statement]), forKey: ApprovalRecordStore.key(owner: "me", circleId: "c1"))
        let lock = scratchLock()
        let other = try await held(lock)
        var made = 0
        XCTAssertFalse(KeyDeliveryApprovals.bindToThisDevice(
            defaults, tag: { nil }, createTag: { made += 1; return "new-tag" }, keychainIsThisDevices: true,
            lock: lock, wait: 0.2))
        XCTAssertEqual(made, 0, "no tag without the lock")
        other.release()
        XCTAssertTrue(KeyDeliveryApprovals.bindToThisDevice(
            defaults, tag: { nil }, createTag: { made += 1; return "new-tag" }, keychainIsThisDevices: true,
            lock: lock, wait: 0.2))
        XCTAssertEqual(approvals(defaults, tag: "new-tag").record(owner: "me", circleId: "c1").entries, ["alice": .statement])
    }

    /// A sign-in before this device was bound blocks adoption for good: from
    /// then on the keychain holds this account's keys either way, so records
    /// here cannot be told apart from a restored backup's. The mark survives
    /// the account wipe; with a tag already made, a sign-in sets nothing.
    func testASignInBeforeBindingBlocksAdoption() throws {
        let defaults = suite().defaults
        defaults.set(try encoded(["alice": .statement]), forKey: ApprovalRecordStore.key(owner: "me", circleId: "c1"))
        KeyDeliveryApprovals.noteSignInStarting(defaults, tag: { nil })
        approvals(defaults).clearAll(exceptOwner: nil)
        XCTAssertTrue(defaults.bool(forKey: ApprovalRecordStore.signedInBeforeBoundKey), "kept through the account wipe")
        defaults.set(try encoded(["alice": .statement]), forKey: ApprovalRecordStore.key(owner: "me", circleId: "c1"))

        var made = 0
        XCTAssertFalse(KeyDeliveryApprovals.bindToThisDevice(
            defaults, tag: { nil }, createTag: { made += 1; return "new-tag" }, keychainIsThisDevices: true,
            lock: scratchLock(), wait: 0.2), "nothing adopted")
        XCTAssertEqual(made, 1, "the tag is still made, so records are written from now on")
        XCTAssertEqual(approvals(defaults, tag: "new-tag").record(owner: "me", circleId: "c1"), CircleApprovalRecord())

        let bound = suite().defaults
        KeyDeliveryApprovals.noteSignInStarting(bound, tag: { "existing-tag" })
        XCTAssertFalse(bound.bool(forKey: ApprovalRecordStore.signedInBeforeBoundKey), "a bound device's sign-in sets nothing")
    }

    // MARK: - The extension's departures, and the app's merge

    private func record(_ entries: [String: ApprovalOrigin], ids: [String: [String]] = [:]) -> CircleApprovalRecord {
        var record = CircleApprovalRecord()
        record.entries = entries
        record.statementIds = ids
        return record
    }

    /// A departure only ever takes trust away: entries, receive-only keys,
    /// owed admissions and backfill marks shrink; tombstones only grow;
    /// invitees stay.
    func testADepartureOnlyEverTakesTrustAway() {
        var before = record(["alice": .kind2, "bob": .statement], ids: ["alice": ["s1"], "bob": ["s2"]])
        before.receiveOnlyKeys["alice"] = MemberKeyPair(sharingKeyHex: "aa", signingKeyHex: "bb")
        before.admissionsOwed = ["alice"]
        before.backfilled = ["alice"]
        before.recordInvitee(userId: "carol", statementId: "s-c", expiresAt: 4_000_000_000)
        before.tombstones["alice"] = ApprovalTombstone(statementIds: ["s0"], activeVersion: 2)
        for (userId, tombstone) in [("alice", ApprovalTombstone(statementIds: ["s9"], activeVersion: 1)),
                                    ("bob", ApprovalTombstone(statementIds: [], activeVersion: 5)),
                                    ("nobody", ApprovalTombstone(statementIds: ["s7"], activeVersion: 3))] {
            var after = before
            after.depart(userId, tombstone: tombstone)
            XCTAssertTrue(Set(after.entries.keys).isSubset(of: before.entries.keys))
            XCTAssertNil(after.entries[userId])
            XCTAssertTrue(after.entries.allSatisfy { before.entries[$0.key] == $0.value }, "nobody else changes")
            XCTAssertTrue(Set(after.receiveOnlyKeys.keys).isSubset(of: before.receiveOnlyKeys.keys))
            XCTAssertTrue(after.admissionsOwed.isSubset(of: before.admissionsOwed))
            XCTAssertTrue(after.backfilled.isSubset(of: before.backfilled))
            XCTAssertEqual(after.invitees, before.invitees)
            for (id, old) in before.tombstones {
                XCTAssertTrue(Set(old.statementIds).isSubset(of: after.tombstones[id]?.statementIds ?? []))
                XCTAssertGreaterThanOrEqual(after.tombstones[id]?.activeVersion ?? -1, old.activeVersion)
            }
            let kept = try? XCTUnwrap(after.tombstones[userId])
            XCTAssertTrue(Set(tombstone.statementIds + (before.statementIds[userId] ?? [])).isSubset(of: kept?.statementIds ?? []),
                          "their statements go into the tombstone")
            XCTAssertGreaterThanOrEqual(kept?.activeVersion ?? -1, tombstone.activeVersion)
        }
    }

    /// The extension records a departure while the app's pass is running; the
    /// pass stores what it decided — merged: the departure stays, the pass's
    /// own confirmation stays, and the app is told to decide again.
    func testTheAppMergesADepartureTheExtensionRecordedMeanwhile() async throws {
        let defaults = suite().defaults
        let lock = scratchLock()
        let store = approvals(defaults, lock: lock)
        store.approve(owner: "me", circleId: "c1", userId: "alice", origin: .statement, statementIds: ["s-a"])
        store.approve(owner: "me", circleId: "c1", userId: "bob", origin: .statement, statementIds: ["s-b"])
        let base = store.record(owner: "me", circleId: "c1")

        // The pass: carol confirmed — and bob, whom its (older) roster still listed.
        var pass = base
        pass.approve(userId: "carol", origin: .statement, statementIds: ["s-c"], keys: nil)
        // Meanwhile, the extension saw bob leave.
        let recorded = await ApprovalRecordStore.persistDepartures(
            ["bob": ApprovalTombstone(statementIds: ["s-b"], activeVersion: 4)], in: defaults, owner: "me", circleId: "c1",
            deviceTag: Self.tag, lock: lock)
        XCTAssertTrue(recorded)

        XCTAssertTrue(store.store(pass, base: base, owner: "me", circleId: "c1", confirmed: ["carol"]),
                      "the pass decided without the departure: decide again")
        let now = store.record(owner: "me", circleId: "c1")
        XCTAssertEqual(now.entries, ["alice": .statement, "carol": .statement])
        XCTAssertEqual(now.tombstones["bob"], ApprovalTombstone(statementIds: ["s-b"], activeVersion: 4))
        XCTAssertNil(now.statementIds["bob"])
    }

    /// A pass that re-confirmed someone from a roster listing them again —
    /// deciding without the tombstone the extension wrote meanwhile — cannot
    /// undo the departure: less trust wins, and the next pass decides with it.
    func testAPassThatDecidedWithoutADepartureCannotUndoIt() {
        let base = record(["alice": .statement], ids: ["alice": ["s-a"]])
        var theirs = base
        theirs.depart("alice", tombstone: ApprovalTombstone(statementIds: ["s-a"], activeVersion: 3))
        var ours = base
        ours.approve(userId: "alice", origin: .ownAction, statementIds: ["s-a2"], keys: nil)
        let merged = CircleApprovalRecord.merged(ours: ours, base: base, theirs: theirs)
        XCTAssertNil(merged.entries["alice"])
        XCTAssertEqual(merged.tombstones["alice"]?.activeVersion, 3)
        XCTAssertEqual(Set(merged.tombstones["alice"]?.statementIds ?? []), ["s-a", "s-a2"])
    }

    /// What was written meanwhile is kept, whoever wrote it: a person's "Let
    /// them in" during a pass, a pass's own departure, and changes on both
    /// sides to different members. Where nothing happened meanwhile the pass's
    /// record is stored as it is.
    func testTheMergeKeepsEveryonesChanges() {
        let erin = "a2000000-0000-4000-8000-0000000000c1"  // an invitee appears by account id only
        var base = record(["alice": .statement, "bob": .kind2, "dan": .statement], ids: ["dan": ["s-d"]])
        base.recordInvitee(userId: erin, statementId: "s-e", expiresAt: 4_000_000_000)
        base.receiveOnlyKeys["bob"] = MemberKeyPair(sharingKeyHex: "aa", signingKeyHex: "bb")
        var theirs = base  // meanwhile: a person let carol in; bob was lifted by their own choice
        theirs.approve(userId: "carol", origin: .ownAction, statementIds: [], keys: nil)
        theirs.entries["bob"] = .ownKind2
        theirs.admissionsOwed = ["carol"]
        var ours = base  // the pass: dan left; erin joined with the invitation made here
        ours.settleInvitees(roster: ["alice": nil, "bob": nil, erin: "s-e", "me": nil], now: 3_000_000_000)
        ours.retain(roster: ["alice", "bob", erin, "me"], activeVersion: 2)

        let merged = CircleApprovalRecord.merged(ours: ours, base: base, theirs: theirs)

        XCTAssertEqual(merged.entries, ["alice": .statement, "bob": .ownKind2, "carol": .ownAction, erin: .ownAction])
        XCTAssertEqual(merged.tombstones["dan"], ApprovalTombstone(statementIds: ["s-d"], activeVersion: 2))
        XCTAssertEqual(merged.invitees, [:])
        XCTAssertEqual(merged.admissionsOwed, ["carol"])
        XCTAssertEqual(merged.receiveOnlyKeys["bob"], base.receiveOnlyKeys["bob"])
        XCTAssertEqual(CircleApprovalRecord.merged(ours: ours, base: base, theirs: base), ours, "nothing meanwhile")
        XCTAssertEqual(CircleApprovalRecord.merged(ours: base, base: base, theirs: theirs), theirs, "a pass that changed nothing")
    }

    /// The app and the extension writing the same record at once lose nothing:
    /// every departure the extension records and every confirmation the app
    /// stores (through the merge, from a base read before it) are all there.
    /// Separate locks on one file, as the two processes hold it; the app keeps
    /// storing for as long as the extension runs.
    func testTheAppAndTheExtensionWritingAtOnceLoseNothing() async throws {
        let (name, defaults) = suite()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("approvals-\(UUID().uuidString).lock")
        let store = approvals(defaults, lock: AppGroupLock(url: file))
        let count = 300
        for i in 0..<count { store.approve(owner: "me", circleId: "c1", userId: "x\(i)", origin: .statement, statementIds: ["s\(i)"]) }

        final class Finished: @unchecked Sendable {
            private let lock = NSLock()
            private var value = false
            var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
            func set() { lock.lock(); value = true; lock.unlock() }
        }
        let finished = Finished()
        let tag = Self.tag
        let extensionSide = Task.detached {
            let other = UserDefaults(suiteName: name)!
            let lock = AppGroupLock(url: file)
            var ok = 0
            for i in 0..<count {
                if await ApprovalRecordStore.persistDepartures(
                    ["x\(i)": ApprovalTombstone(statementIds: [], activeVersion: 1)], in: other, owner: "me", circleId: "c1",
                    deviceTag: tag, lock: lock, wait: 10) { ok += 1 }
                // As a real run: one write, then other work — the app gets its turn.
                try? await Task.sleep(nanoseconds: 500_000)
            }
            finished.set()
            return ok
        }
        var stored = 0
        while !finished.isSet, stored < 5_000 {
            let base = store.record(owner: "me", circleId: "c1")
            var pass = base
            pass.approve(userId: "y\(stored)", origin: .statement, statementIds: ["t\(stored)"], keys: nil)
            try await Task.sleep(nanoseconds: 300_000)
            store.store(pass, base: base, owner: "me", circleId: "c1", confirmed: [])
            stored += 1
        }
        let recorded = await extensionSide.value
        XCTAssertEqual(recorded, count)

        let final = store.record(owner: "me", circleId: "c1")
        XCTAssertEqual((0..<count).filter { final.entries["x\($0)"] == nil && final.tombstones["x\($0)"] != nil }.count, count,
                       "every departure kept")
        XCTAssertEqual((0..<stored).filter { final.entries["y\($0)"] == .statement }.count, stored, "every confirmation kept")
        XCTAssertGreaterThan(stored, 5, "the two really overlapped")
        print("[approvals-merge] app stored \(stored) confirmations while the extension recorded \(recorded) departures")
    }
}
