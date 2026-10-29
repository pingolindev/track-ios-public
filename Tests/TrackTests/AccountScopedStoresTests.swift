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

/// The stores that keep an account's data across a sign-out compare the
/// account case-insensitively, and the account-keyed marks go when another
/// account signs in here or at an erasure.
@MainActor
final class AccountScopedStoresTests: XCTestCase {
    private var suites: [String] = []

    override func tearDown() {
        for name in suites { UserDefaults().removePersistentDomain(forName: name) }
        super.tearDown()
    }

    private func suite() -> UserDefaults {
        let name = "AccountScopedStoresTests.\(UUID().uuidString)"
        suites.append(name)
        return UserDefaults(suiteName: name)!
    }

    private static let tag = "device-tag"

    private func approvals(_ defaults: UserDefaults) -> KeyDeliveryApprovals {
        KeyDeliveryApprovals(
            defaults: defaults, deviceTag: { Self.tag },
            lock: AppGroupLock(url: FileManager.default.temporaryDirectory
                .appendingPathComponent("approvals-\(UUID().uuidString).lock")))
    }

    private func record(entries: [String: ApprovalOrigin] = [:], tombstones: [String: ApprovalTombstone] = [:],
                        dead: Set<String> = [], receiveOnly: [String: MemberKeyPair] = [:],
                        owed: Set<String> = []) -> CircleApprovalRecord {
        var record = CircleApprovalRecord()
        record.entries = entries
        record.tombstones = tombstones
        record.deadStatementIds = dead
        record.receiveOnlyKeys = receiveOnly
        record.admissionsOwed = owed
        record.deviceTag = Self.tag
        return record
    }

    private func stored(_ defaults: UserDefaults, _ key: String) -> CircleApprovalRecord? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(CircleApprovalRecord.self, from: $0) }
    }

    // MARK: - The approvals

    /// "ME"'s record is kept at "me"'s sign-in (and read as "me"'s), while
    /// another account's goes; the owners are lowercased first.
    func testTheSameAccountInAnotherCaseKeepsItsApprovals() throws {
        let defaults = suite()
        defaults.set(try JSONEncoder().encode(record(entries: ["alice": .ownAction],
                                                     tombstones: ["x": ApprovalTombstone(statementIds: ["s1"], activeVersion: 2)])),
                     forKey: "keyDeliveryApprovals.v2.ME.c1")
        defaults.set(try JSONEncoder().encode(record(entries: ["bob": .ownAction])), forKey: "keyDeliveryApprovals.v2.other.c1")
        defaults.set(true, forKey: "keyDeliveryApprovals.transitionSeed.ME")
        defaults.set(true, forKey: "keyDeliveryApprovals.transitionSeed.other")
        let store = approvals(defaults)
        store.clearAll(exceptOwner: "me")
        XCTAssertNil(defaults.object(forKey: "keyDeliveryApprovals.v2.ME.c1"), "moved")
        let kept = try XCTUnwrap(stored(defaults, "keyDeliveryApprovals.v2.me.c1"))
        XCTAssertEqual(kept.entries, ["alice": .ownAction])
        XCTAssertEqual(kept.tombstones["x"]?.statementIds, ["s1"])
        XCTAssertEqual(store.record(owner: "Me", circleId: "c1").entries, ["alice": .ownAction], "read in any case")
        XCTAssertNil(defaults.object(forKey: "keyDeliveryApprovals.v2.other.c1"), "another account's goes")
        XCTAssertTrue(store.transitionSeedTaken(owner: "me"))
        XCTAssertNil(defaults.object(forKey: "keyDeliveryApprovals.transitionSeed.other"))
        // The other way round: kept at "ME"'s sign-in.
        store.clearAll(exceptOwner: "ME")
        XCTAssertNotNil(stored(defaults, "keyDeliveryApprovals.v2.me.c1"))
        store.clearAll(exceptOwner: nil)
        XCTAssertNil(defaults.object(forKey: "keyDeliveryApprovals.v2.me.c1"), "an erasure takes it")
    }

    /// Both cases stored: the upper-case record's tombstones and dead ids join
    /// the lowercase one's (they only restrict); nothing that grants comes with
    /// them; the upper-case key goes. A record that doesn't read is never
    /// folded or dropped.
    func testAnUpperCaseRecordsRestrictionsFoldIntoTheLowercaseOne() throws {
        let defaults = suite()
        let keys = MemberKeyPair(sharingKeyHex: "aa", signingKeyHex: "bb")
        defaults.set(try JSONEncoder().encode(record(
            tombstones: ["x": ApprovalTombstone(statementIds: ["s1"], activeVersion: 3),
                         "w": ApprovalTombstone(statementIds: ["s9"], activeVersion: 1)],
            dead: ["d1"], receiveOnly: ["y": keys], owed: ["z"])), forKey: "keyDeliveryApprovals.v2.ME.c1")
        defaults.set(try JSONEncoder().encode(record(
            entries: ["w": .ownAction], tombstones: ["w": ApprovalTombstone(statementIds: ["s2"], activeVersion: 2)])),
                     forKey: "keyDeliveryApprovals.v2.me.c1")
        defaults.set(Data("{not json".utf8), forKey: "keyDeliveryApprovals.v2.ME.c2")
        defaults.set(try JSONEncoder().encode(record(entries: ["v": .ownAction])), forKey: "keyDeliveryApprovals.v2.me.c2")
        approvals(defaults).normalizeOwners()
        let into = try XCTUnwrap(stored(defaults, "keyDeliveryApprovals.v2.me.c1"))
        XCTAssertEqual(into.tombstones["x"], ApprovalTombstone(statementIds: ["s1"], activeVersion: 3))
        XCTAssertEqual(into.tombstones["w"], ApprovalTombstone(statementIds: ["s2", "s9"], activeVersion: 2))
        XCTAssertEqual(into.deadStatementIds, ["d1"])
        XCTAssertEqual(into.entries, ["w": .ownAction], "the lowercase record's own, untouched")
        XCTAssertTrue(into.receiveOnlyKeys.isEmpty, "nothing that grants")
        XCTAssertTrue(into.admissionsOwed.isEmpty)
        XCTAssertNil(defaults.object(forKey: "keyDeliveryApprovals.v2.ME.c1"))
        XCTAssertEqual(defaults.data(forKey: "keyDeliveryApprovals.v2.ME.c2"), Data("{not json".utf8), "never dropped")
        XCTAssertEqual(stored(defaults, "keyDeliveryApprovals.v2.me.c2")?.entries, ["v": .ownAction])
    }

    /// The app and the extension write and read under the lowercased owner.
    func testEveryWriteGoesUnderTheLowercasedOwner() {
        XCTAssertEqual(ApprovalRecordStore.key(owner: "ME", circleId: "c1"), "keyDeliveryApprovals.v2.me.c1")
        XCTAssertEqual(ApprovalRecordStore.legacyKey(owner: "ME", circleId: "c1"), "keyDeliveryApproved.me.c1")
        XCTAssertEqual(ApprovalRecordStore.transitionKey(owner: "ME"), "keyDeliveryApprovals.transitionSeed.me")
        let defaults = suite()
        let store = approvals(defaults)
        store.approve(owner: "ME", circleId: "c1", userId: "alice", origin: .ownAction)
        XCTAssertNotNil(defaults.object(forKey: "keyDeliveryApprovals.v2.me.c1"))
        XCTAssertEqual(store.record(owner: "me", circleId: "c1").entries, ["alice": .ownAction])
    }

    // MARK: - The retained pins

    /// An older build's blob under the id in upper case is this account's at
    /// its sign-in: kept, restored and consumed; another account's stays for
    /// the guarded tidy (`SignInTidy`). Real ids: the SDK writes pins only for
    /// ids in their one form.
    func testTheRetainedPinsOfTheSameAccountInAnotherCaseAreRestored() throws {
        defer { RetainedMemberPins.deleteAll(except: nil) }
        RetainedMemberPins.deleteAll(except: nil)
        let (me, circle, memberId) = ("0e0e0e0e-1111-4222-8333-444455556666", "c1c1c1c1-0000-4000-8000-000000000001",
                                      "d1d1d1d1-0000-4000-8000-000000000002")
        let before = CryptoManager()
        _ = before.generateKeypair()
        _ = before.generateSigningKeypair()
        let member = CryptoManager()
        let sharing = Data(base64Encoded: member.generateKeypair().publicKey)!.map { String(format: "%02x", $0) }.joined()
        let signing = Data(base64Encoded: member.generateSigningKeypair().verifyingKeyB64)!
            .map { String(format: "%02x", $0) }.joined()
        _ = try before.pinMemberKeys(circleId: circle, userId: memberId, sharingPubkeyHex: sharing, signingPubkeyHex: signing)
        try RetainedMemberPins.write(try before.exportMemberPins(ownerUserId: me), account: me.uppercased())
        try RetainedMemberPins.write("{}", account: "other")
        let after = CryptoManager()
        _ = after.generateKeypair()
        _ = after.generateSigningKeypair()
        XCTAssertGreaterThan(RetainedMemberPins.restore(owner: me, crypto: after), 0)
        XCTAssertNotNil(after.pinnedSharingKey(circleId: circle, userId: memberId))
        XCTAssertEqual(RetainedMemberPins.accounts(), ["other"], "consumed; another account's stays")
        try RetainedMemberPins.write("{}", account: "Me")
        RetainedMemberPins.deleteAll(except: "mE")
        XCTAssertEqual(RetainedMemberPins.accounts(), ["Me"], "the same account in another case is kept")
    }

    // MARK: - The verification marks

    /// Marks made by "ME" stay at "me"'s sign-in; another account's sign-in
    /// takes them.
    func testVerificationMarksKeepTheSameAccountInAnotherCase() {
        defer { MemberVerificationStore.clearAll() }
        MemberVerificationStore.clearAll()
        UserDefaults.standard.set("ME", forKey: "memberVerification.owner")  // as an older build stored it
        MemberVerificationStore.setVerified(circleId: "c1", userId: "m1")
        MemberVerificationStore.adopt(owner: "me")
        XCTAssertNotNil(MemberVerificationStore.verifiedAt(circleId: "c1", userId: "m1"))
        MemberVerificationStore.adopt(owner: "OTHER")
        XCTAssertNil(MemberVerificationStore.verifiedAt(circleId: "c1", userId: "m1"))
    }

    // MARK: - The device flags

    func testDeviceFlagsAreResetInAnyCase() {
        let defaults = UserDefaults.standard
        let keys = ["device.registered.ME.dev1", "device.registered.me.dev2", "device.registered.other.dev3"]
        for key in keys { defaults.set(true, forKey: key) }
        defer { keys.forEach { defaults.removeObject(forKey: $0) } }
        DeviceRegistrar.reset(userId: "Me")
        XCTAssertNil(defaults.object(forKey: keys[0]))
        XCTAssertNil(defaults.object(forKey: keys[1]))
        XCTAssertNotNil(defaults.object(forKey: keys[2]), "another account's own flag")
    }

    // MARK: - The account-keyed marks

    /// Kept for the account signing in, in any case; another account's go; an
    /// erasure takes them all. Nothing else is touched.
    func testTheAccountKeyedMarksGoForAnotherAccountAndAtAnErasure() {
        let defaults = suite()
        for prefix in AccountKeyedDefaults.prefixes {
            defaults.set(1, forKey: prefix + "me")
            defaults.set(1, forKey: prefix + "other")
        }
        defaults.set(1, forKey: "someSetting")
        AccountKeyedDefaults.wipe(except: "ME", defaults: defaults)
        for prefix in AccountKeyedDefaults.prefixes {
            XCTAssertNotNil(defaults.object(forKey: prefix + "me"), prefix)
            XCTAssertNil(defaults.object(forKey: prefix + "other"), prefix)
        }
        AccountKeyedDefaults.wipe(except: nil, defaults: defaults)
        for prefix in AccountKeyedDefaults.prefixes { XCTAssertNil(defaults.object(forKey: prefix + "me"), prefix) }
        XCTAssertNotNil(defaults.object(forKey: "someSetting"))
        XCTAssertEqual(Set(AccountKeyedDefaults.prefixes), [
            "invitationRenewals.asked.", "invitationRenewals.reasked.", "invitationRenewals.withdrawn.",
            "selfKey.lastRepublishAt.", "selfKey.flaggedCopy.", "signingKey.legacyShapeSeen.",
            "circles.userOrder.", "circleQuestion.notifiedAt.", "selfAdmission.attempts.",
        ])
    }

    /// Earlier builds' global keys, once: the signed-in account's become its
    /// own (never over one it has), with nobody signed in they go, and the
    /// active circle's id goes either way.
    func testEarlierBuildsGlobalKeysBecomeTheSignedInAccounts() {
        var defaults = suite()
        defaults.set(["c2", "c1"], forKey: "circles.userOrder")
        defaults.set(["q": 1.0], forKey: "circleQuestion.notifiedAt")
        defaults.set("c1", forKey: "activeCircleId")
        defaults.set(["mine"], forKey: "circles.userOrder.me")
        AccountKeyedDefaults.migrateGlobals(signedIn: "ME", defaults: defaults)
        XCTAssertEqual(defaults.stringArray(forKey: "circles.userOrder.me"), ["mine"], "never over one it has")
        XCTAssertEqual(defaults.dictionary(forKey: "circleQuestion.notifiedAt.me") as? [String: Double], ["q": 1.0])
        for key in ["circles.userOrder", "circleQuestion.notifiedAt", "activeCircleId"] {
            XCTAssertNil(defaults.object(forKey: key), key)
        }
        defaults = suite()
        defaults.set(["c2"], forKey: "circles.userOrder")
        AccountKeyedDefaults.migrateGlobals(signedIn: nil, defaults: defaults)
        XCTAssertNil(defaults.object(forKey: "circles.userOrder"))
        XCTAssertTrue(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("circles.userOrder.") }.isEmpty)
    }

    /// The circles' order is per account.
    func testTheCirclesOrderIsPerAccount() {
        struct C: Identifiable { let id: String }
        defer { UserDefaults.standard.removeObject(forKey: "circles.userOrder.me") }
        CircleOrderStore.save(["b", "a"], owner: "ME")
        XCTAssertEqual(CircleOrderStore.apply(to: [C(id: "a"), C(id: "b")], owner: "me").map(\.id), ["b", "a"])
        XCTAssertEqual(CircleOrderStore.apply(to: [C(id: "a"), C(id: "b")], owner: "other").map(\.id), ["a", "b"])
        XCTAssertEqual(CircleOrderStore.load(owner: nil), [])
    }

    // MARK: - Wiring

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// Another account's sign-in and an erasure wipe the marks; the launch
    /// moves earlier builds' globals once the Keychain has answered; the
    /// foreground lowercases the approvals before a sign-in; the active
    /// circle's id is written nowhere.
    func testTheWipesAndTheMovesAreWiredIn() throws {
        let auth = try source("App/Managers/AuthManager.swift")
        XCTAssertTrue(auth.contains("        SignInTidy.run(signedIn: me, typedEmail: typedEmail)\n"
                                    + "        AccountKeyedDefaults.wipe(except: me)\n        MemberVerificationStore.adopt(owner: me)\n"))
        XCTAssertTrue(auth.contains("                RefreshLedger.shared.wipeAll()\n                SOSAlarmMarks.shared.wipeAll()\n"
                                    + "                AccountKeyedDefaults.wipe(except: nil)\n"))
        XCTAssertTrue(auth.contains("        switch keychain.read(.userId) {\n"
                                    + "        case .value(let data): AccountKeyedDefaults.migrateGlobals(signedIn: String(data: data, encoding: .utf8))\n"
                                    + "        case .notFound: AccountKeyedDefaults.migrateGlobals(signedIn: nil)\n"
                                    + "        case .unavailable: break\n        }\n"))
        XCTAssertTrue(try source("App/TrackApp.swift").contains("KeyDeliveryApprovals.shared.normalizeOwners()"))
        let approvals = try source("App/Managers/KeyDeliveryApprovals.swift")
        XCTAssertTrue(approvals.contains("    private func drainPending() {\n        normalizeOwnersIfNeeded()\n"))
        XCTAssertTrue(approvals.contains("    private func performClear(exceptOwner owner: String?) {\n        normalizeOwnersIfNeeded()\n"))
        XCTAssertTrue(try source("App/Notifications/CircleQuestionNotifier.swift")
            .contains("private static func postedKey(owner: String) -> String { \"circleQuestion.notifiedAt.\\(owner.lowercased())\" }"))
        for path in ["App/Managers/CircleManager.swift", "App/Views/Circles/CirclesView.swift"] {
            XCTAssertFalse(try source(path).contains("\"activeCircleId\""), path)
        }
    }
}
