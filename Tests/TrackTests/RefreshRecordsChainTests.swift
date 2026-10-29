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

/// Refresh records end to end: an owner's device writes the records, a
/// member's device imports them, and the app's rules run on what the SDK
/// then says.
final class RefreshRecordsChainTests: XCTestCase {
    private struct Party {
        let userId = UUID().uuidString.lowercased()
        let sdk = CryptoManager()
        let sharing: String
        let signing: String

        init() {
            sharing = Self.hex(sdk.generateKeypair().publicKey)
            signing = Self.hex(sdk.generateSigningKeypair().verifyingKeyB64)
        }

        static func hex(_ b64: String) -> String {
            Data(base64Encoded: b64)!.map { String(format: "%02x", $0) }.joined()
        }

        var keys: MemberKeyPair { MemberKeyPair(sharingKeyHex: sharing, signingKeyHex: signing) }
    }

    private let circle = UUID().uuidString.lowercased()
    /// The circle's key chain so far, as GET /circles/keys serves it.
    private var links: [KeyChainLinkData] = []
    private let now = Int64(Date().timeIntervalSince1970)

    private func invitation(by signer: Party, of subject: Party, atVersion: Int32) throws -> SignedStatementRecord {
        let signed = try signer.sdk.signMembershipStatement(statement: MembershipStatement(
            kind: .invitationToAccount, circleId: circle, statementId: UUID().uuidString.lowercased(),
            signerUserId: signer.userId, issuedAt: now, expiresAt: now + 604_800, atVersion: atVersion,
            subjectUserId: subject.userId, subjectSharingPublicKeyHex: subject.sharing,
            subjectSigningPublicKeyHex: subject.signing, subjectEmail: nil))
        return SignedStatementRecord(statementHex: signed.statementHex, signatureHex: signed.signatureHex)
    }

    private func row(_ party: Party, keys: Bool = true, confirmed: Bool = true, listed: Bool = true,
                     role: CircleRole = .member, statements: [SignedStatementRecord] = []) -> RecordMemberRow {
        RecordMemberRow(userId: party.userId, keys: keys ? party.keys : nil, confirmed: confirmed && keys,
                        listed: listed, listedRole: role, statements: statements, personConfirmedKeys: false,
                        serverSaysKeyless: false)
    }

    private func wrap(for party: Party, in bundle: RecordedRotationBundle) throws -> MemberKeyBundle {
        try XCTUnwrap(bundle.rotation.memberKeys.first { $0.userId == party.userId }).bundle
    }

    private func record(_ bundle: RecordedRotationBundle) -> SignedRefreshRecord { bundle.refreshRecord }

    /// One rotation by the owner's device, and its record taken back by that
    /// device, as it is once the server took it.
    private func ownerRotates(_ owner: Party, planned: [PlannedEntry], members: [RecordMemberRow]) throws
        -> RecordedRotationBundle {
        let bundle = try owner.sdk.prepareRecordedRotation(
            circleId: circle, senderUserId: owner.userId, kind: .rotation, planned: planned,
            members: members.map(\.sdkMember), rosterComplete: true, currentCircleNamePlaintext: "Family")
        // The server took it: the owner's device imports its own record back,
        // with the circle's key chain as the keys route serves it.
        links.append(try XCTUnwrap(bundle.rotation.keyChainLink))
        let report = try owner.sdk.importRefreshRecords(
            circleId: circle, records: [record(bundle)], keyChain: links, members: members.map(\.sdkMember),
            rosterComplete: true, ownHead: nil, memberHeads: [])
        XCTAssertFalse(report.forked)
        XCTAssertEqual(report.versions.map { "\($0.version) \($0.state) \($0.problem)" },
                       ["\(bundle.rotation.newKeyVersion) accepted none"], "the owner's own record, taken back")
        return bundle
    }

    /// This device holds the key for v3 before it has accepted v3's record,
    /// the person taps "Let them in" about x, and then the record arrives: it
    /// removes x at v3. The version kept at the tap is the one ACCEPTED (2),
    /// so the change ends with `PendingChangeCopy.memberLeft` and signs
    /// nothing; the version merely held (3) would have let it sign.
    func testARemovalInARecordAcceptedAfterTheTapEndsTheChange() throws {
        let (owner, me, x) = (Party(), Party(), Party())
        let genesis = try owner.sdk.prepareRecordedCircleCreation(creatorUserId: owner.userId, circleId: circle).genesis
        let invitedMe = try invitation(by: owner, of: me, atVersion: 1)
        let invitedX = try invitation(by: owner, of: x, atVersion: 1)
        let ownersView = [row(owner, role: .owner), row(me, statements: [invitedMe]), row(x, statements: [invitedX])]
        let v2 = try ownerRotates(owner, planned: [
            PlannedEntry(userId: owner.userId, state: .included, role: nil),
            PlannedEntry(userId: me.userId, state: .included, role: nil),
            PlannedEntry(userId: x.userId, state: .included, role: nil),
        ], members: ownersView)
        let v3 = try ownerRotates(owner, planned: [
            PlannedEntry(userId: owner.userId, state: .included, role: nil),
            PlannedEntry(userId: me.userId, state: .included, role: nil),
            PlannedEntry(userId: x.userId, state: .removed, role: nil),
        ], members: ownersView)

        // This device: its first key (v2) from the owner it confirms, then v1
        // and v2's records.
        _ = try me.sdk.pinMemberKeys(circleId: circle, userId: owner.userId,
                                     sharingPubkeyHex: owner.sharing, signingPubkeyHex: owner.signing)
        let first = try wrap(for: me, in: v2)
        try me.sdk.storeFirstCircleKey(
            circleId: circle, encryptedKey: first.encryptedCircleKey.nonce + first.encryptedCircleKey.ciphertext,
            senderPublicKey: first.ephemeralPublicKey, keyVersion: 2, senderUserId: owner.userId,
            recipientUserId: me.userId, wrapSignatureHex: first.wrapSignature,
            confirmedSenderSigningPubkeyHex: owner.signing, sealedCircleName: nil)
        let mine = [row(me, statements: [invitedMe]), row(owner, role: .owner), row(x, statements: [invitedX])]
        _ = try me.sdk.importRefreshRecords(
            circleId: circle, records: [genesis, record(v2)], keyChain: links,
            members: mine.map(\.sdkMember), rosterComplete: true, ownHead: nil, memberHeads: [])
        XCTAssertEqual(try me.sdk.getActiveVersion(circleId: circle), 2)

        // v3's key arrives before its record.
        let third = try wrap(for: me, in: v3)
        try me.sdk.storeCircleKey(
            circleId: circle, encryptedKey: third.encryptedCircleKey.nonce + third.encryptedCircleKey.ciphertext,
            senderPublicKey: third.ephemeralPublicKey, keyVersion: 3, senderUserId: owner.userId,
            recipientUserId: me.userId, wrapSignatureHex: third.wrapSignature, senderSigningPubkeyHex: owner.signing)
        XCTAssertEqual(me.sdk.newestHeldVersion(circleId: circle), 3, "held")
        XCTAssertEqual(try me.sdk.getActiveVersion(circleId: circle), 2, "not accepted: never the tap's version")

        // The tap keeps getActiveVersion (PendingChanges.queue, heldVersion).
        var change = PendingChanges.make(.letIn, account: me.userId, circleId: circle,
                                         inputs: .letIn(.init(memberId: x.userId, questionKind: "reset")),
                                         circleName: "Family", subject: "Xan")
        change.versionAtTap = Int(try me.sdk.getActiveVersion(circleId: circle))

        // Then v3's record: x removed by the owner, at v3.
        let report = try me.sdk.importRefreshRecords(
            circleId: circle, records: [record(v3)], keyChain: links, members: mine.map(\.sdkMember),
            rosterComplete: true, ownHead: nil, memberHeads: [])
        XCTAssertFalse(report.forked)
        XCTAssertEqual(try me.sdk.getActiveVersion(circleId: circle), 3)
        let eligibility = try me.sdk.refreshEligibility(circleId: circle, members: mine.map(\.sdkMember), purpose: .include)
        let removedAt = try XCTUnwrap(eligibility.first { $0.userId == x.userId }).removedAtVersion
        XCTAssertEqual(removedAt, 3)

        XCTAssertEqual(PendingChangeKinds.removedSinceTheTap(.lastWord(removedAt: removedAt), change: change, name: "Xan"),
                       .drop(line: "Letting Xan in wasn't done: Xan is no longer in Family."))
        var heldAtTheTap = change
        heldAtTheTap.versionAtTap = 3
        XCTAssertNil(PendingChangeKinds.removedSinceTheTap(.lastWord(removedAt: removedAt), change: heldAtTheTap, name: "Xan"),
                     "the version merely held would have let it sign")
    }

    /// An owner's device with v1 and v2 accepted, then its own v3 (y
    /// removed), which the server took; nothing imported since. `before`: the
    /// circle's links from before v3, as a key fetch before it served them.
    private struct OwnChange {
        let owner: Party
        let x: Party
        let y: Party
        let view: [RecordMemberRow]
        let v3: RecordedRotationBundle
        let before: [KeyChainLinkData]
    }

    private func ownChangeTaken() throws -> OwnChange {
        links = []
        let (owner, x, y) = (Party(), Party(), Party())
        _ = try owner.sdk.prepareRecordedCircleCreation(creatorUserId: owner.userId, circleId: circle)
        let view = [row(owner, role: .owner), row(x, statements: [try invitation(by: owner, of: x, atVersion: 1)]),
                    row(y, statements: [try invitation(by: owner, of: y, atVersion: 1)])]
        _ = try ownerRotates(owner, planned: [
            PlannedEntry(userId: owner.userId, state: .included, role: nil),
            PlannedEntry(userId: x.userId, state: .included, role: nil),
            PlannedEntry(userId: y.userId, state: .included, role: nil),
        ], members: view)
        let v3 = try owner.sdk.prepareRecordedRotation(
            circleId: circle, senderUserId: owner.userId, kind: .rotation, planned: [
                PlannedEntry(userId: owner.userId, state: .included, role: nil),
                PlannedEntry(userId: x.userId, state: .included, role: nil),
                PlannedEntry(userId: y.userId, state: .removed, role: nil),
            ], members: view.map(\.sdkMember), rosterComplete: true, currentCircleNamePlaintext: "Family")
        return OwnChange(owner: owner, x: x, y: y, view: view, v3: v3, before: links)
    }

    /// The next change on it: x removed as well (y still named removed).
    private func nextChange(_ change: OwnChange) throws -> RecordedRotationBundle {
        try change.owner.sdk.prepareRecordedRotation(
            circleId: circle, senderUserId: change.owner.userId, kind: .rotation, planned: [
                PlannedEntry(userId: change.owner.userId, state: .included, role: nil),
                PlannedEntry(userId: change.x.userId, state: .removed, role: nil),
                PlannedEntry(userId: change.y.userId, state: .removed, role: nil),
            ], members: change.view.map(\.sdkMember), rosterComplete: true, currentCircleNamePlaintext: "Family")
    }

    /// One listed SOS, every part sealed by `sealer` under the key it seals the
    /// circle under now.
    private func sosRow(id: String, sealedBy sealer: Party) throws -> SOSResponse {
        func blob(_ e: EncryptedData) -> [String: Any] { ["nonce": e.nonce, "ciphertext": e.ciphertext] }
        let point = Location(latitude: 52.52, longitude: 13.405, altitude: nil, speed: nil, heading: nil, accuracy: 7,
                             timestamp: now * 1000, batteryLevel: nil, isCharging: nil)
        let row: [String: Any] = [
            "id": id, "circle_id": circle, "status": "active", "day_bucket": 20_000,
            "encrypted_user_id": blob(try sealer.sdk.encryptDataV2(circleId: circle, plaintext: sealer.userId,
                                                                   fieldTag: "user_id")),
            "encrypted_device_id": blob(try sealer.sdk.encryptDataV2(circleId: circle, plaintext: "device-1",
                                                                     fieldTag: "device_id")),
            "encrypted_timestamp": blob(try sealer.sdk.encryptDataV2(circleId: circle, plaintext: String(now * 1000),
                                                                     fieldTag: "timestamp")),
            "encrypted_location": blob(try sealer.sdk.encryptLocation(circleId: circle, location: point)),
        ]
        return try APIService.makeWireDecoder().decode(SOSResponse.self, from: JSONSerialization.data(withJSONObject: row))
    }

    /// The owner rotates to v3 and raises an SOS under it while this device still
    /// holds v2. Its SOS load opens nothing, asks for ONE key refresh (what the
    /// app's light circle load does for a newer own wrap: the wrap stored, the
    /// record imported), opens the SOS again, finds it current and alarming, and
    /// the real alarm replaces the server's banner silently (it rang), or rings
    /// once when no banner is left.
    @MainActor
    func testAnSOSUnderAKeyNotYetFetchedOpensAfterOneLoadAndRingsOnce() async throws {
        links = []
        let (owner, me) = (Party(), Party())
        let genesis = try owner.sdk.prepareRecordedCircleCreation(creatorUserId: owner.userId, circleId: circle).genesis
        let invitedMe = try invitation(by: owner, of: me, atVersion: 1)
        let ownersView = [row(owner, role: .owner), row(me, statements: [invitedMe])]
        let both = [PlannedEntry(userId: owner.userId, state: .included, role: nil),
                    PlannedEntry(userId: me.userId, state: .included, role: nil)]
        let v2 = try ownerRotates(owner, planned: both, members: ownersView)
        _ = try me.sdk.pinMemberKeys(circleId: circle, userId: owner.userId,
                                     sharingPubkeyHex: owner.sharing, signingPubkeyHex: owner.signing)
        let first = try wrap(for: me, in: v2)
        try me.sdk.storeFirstCircleKey(
            circleId: circle, encryptedKey: first.encryptedCircleKey.nonce + first.encryptedCircleKey.ciphertext,
            senderPublicKey: first.ephemeralPublicKey, keyVersion: 2, senderUserId: owner.userId,
            recipientUserId: me.userId, wrapSignatureHex: first.wrapSignature,
            confirmedSenderSigningPubkeyHex: owner.signing, sealedCircleName: nil)
        let mine = [row(me, statements: [invitedMe]), row(owner, role: .owner)]
        _ = try me.sdk.importRefreshRecords(
            circleId: circle, records: [genesis, record(v2)], keyChain: links,
            members: mine.map(\.sdkMember), rosterComplete: true, ownHead: nil, memberHeads: [])
        XCTAssertEqual(try me.sdk.getActiveVersion(circleId: circle), 2)

        // The owner rotates to v3 (this device included) and raises under it.
        let v3 = try ownerRotates(owner, planned: both, members: ownersView)
        let sos = try sosRow(id: "c7070000-0000-4000-8000-0000000000e1", sealedBy: owner)
        let open = { (response: SOSResponse) in
            SOSManager.openAlert(response, myUserId: me.userId, myDeviceId: nil, crypto: me.sdk)
        }
        XCTAssertTrue(open(sos).opened.nothingOpened, "CONTROL: under v3, nothing opens on v2")

        var loads = 0
        var tried: [String: Date] = [:]
        let opened = await SOSManager.openListed([sos], open: open, refreshKeys: {
            loads += 1
            do {
                let third = try self.wrap(for: me, in: v3)
                try me.sdk.storeCircleKey(
                    circleId: self.circle,
                    encryptedKey: third.encryptedCircleKey.nonce + third.encryptedCircleKey.ciphertext,
                    senderPublicKey: third.ephemeralPublicKey, keyVersion: 3, senderUserId: owner.userId,
                    recipientUserId: me.userId, wrapSignatureHex: third.wrapSignature,
                    senderSigningPubkeyHex: owner.signing)
                _ = try me.sdk.importRefreshRecords(
                    circleId: self.circle, records: [self.record(v3)], keyChain: self.links,
                    members: mine.map(\.sdkMember), rosterComplete: true, ownHead: nil, memberHeads: [])
            } catch {
                XCTFail("the light load's work: \(error)")
            }
        }, tried: &tried, now: Date())
        XCTAssertEqual(loads, 1, "one load")
        let entry = try XCTUnwrap(opened.first)
        XCTAssertTrue(entry.opened.opened)
        XCTAssertTrue(entry.opened.current, "opened under the version this device now seals under")
        let verdict = SOSReceiverRules.verdict(
            live: true, opened: entry.opened, behind: me.sdk.isBehind(circleId: circle),
            marks: .read(ended: false, seenCurrent: false), raiserShown: true,
            now: Int64(Date().timeIntervalSince1970 * 1000))
        XCTAssertEqual(verdict, .alarming)

        let key = CanonicalId.key(sos.id)
        let banner = SOSNotices.Delivered(identifier: "7AE4-180C", alertType: "sos", alertId: sos.id, kind: nil,
                                          title: "Alert", body: "Tap to view details")
        let replaced = SOSNotices.plan(delivered: [banner], verdicts: [key: verdict], names: [:], level: "full",
                                       rang: [], newPosts: false)
        XCTAssertEqual(replaced.post.map(\.identifier), ["7AE4-180C"])
        XCTAssertEqual(replaced.post.map(\.sound), [false], "the server's banner rang: replaced silently")
        let swiped = SOSNotices.plan(delivered: [], verdicts: [key: verdict], names: [:], level: "full", rang: [],
                                     newPosts: true)
        XCTAssertEqual(swiped.post.map(\.sound), [true], "no banner left: it rings once")
        XCTAssertEqual(SOSNotices.plan(delivered: [], verdicts: [key: verdict], names: [:], level: "full", rang: [key],
                                       newPosts: true), SOSNotices.Plan(), "then never again")
    }

    /// This device's own change, which the server took, and then a key fetch
    /// that failed, so the records import has only the links from before the
    /// change. With its own link (`importLinks`) the record is accepted, sealed
    /// under, and the next change goes after it. The CONTROL, without it: the
    /// record waits for its link, and the next change is refused until a later
    /// fetch.
    func testAnOwnChangeIsJudgedWithItsOwnLinkAfterAFailedKeyFetch() throws {
        typealias Manager = Track.CircleManager
        func importOwn(_ change: OwnChange, own: [KeyChainLinkData]) throws -> [String] {
            try change.owner.sdk.importRefreshRecords(
                circleId: circle, records: [record(change.v3)],
                keyChain: Manager.importLinks(fetched: change.before, own: own),
                members: change.view.map(\.sdkMember), rosterComplete: true, ownHead: nil, memberHeads: [])
                .versions.map { "\($0.version) \($0.state) \($0.problem)" }
        }

        // CONTROL: no own link.
        let control = try ownChangeTaken()
        XCTAssertEqual(try importOwn(control, own: []), ["3 waiting linkMissing"])
        XCTAssertThrowsError(try nextChange(control)) { error in
            XCTAssertTrue(String(describing: error).contains("waits here"), "\(error)")
        }

        let mine = try ownChangeTaken()
        let own = Manager.noting(try XCTUnwrap(mine.v3.rotation.keyChainLink), in: [])
        XCTAssertEqual(try importOwn(mine, own: own), ["3 accepted none"])
        XCTAssertEqual(try mine.owner.sdk.getActiveVersion(circleId: circle), 3)
        XCTAssertFalse(mine.owner.sdk.isBehind(circleId: circle))
        XCTAssertEqual(try nextChange(mine).rotation.newKeyVersion, 4, "the next change goes after it")
    }

    /// Eject #1 is taken (v3), the load after it fails, and the person removes
    /// someone else. With both rules (the listed version is the taken one, v3;
    /// the second change waits), nothing is built, v3's key stays, and the
    /// write gate seals under v3, never under v2, which the member eject #1
    /// removed holds. The CONTROL, without them: the second change is built at
    /// v3 again and replaces v3's key, is refused (409) and discarded, and the
    /// gate, comparing 2 with the stale listed 2, seals under v2. The
    /// listed-version rule on its own closes the gate there.
    func testASecondChangeWaitsForTheFirstAndNothingIsSealedUnderTheKeyItReplaced() throws {
        typealias Manager = Track.CircleManager
        let versions: [Int32] = [3, 2]
        // The write gate's version check, then a seal: the version that opens it.
        func sealedUnder(_ device: CryptoManager, listed: Int) throws -> Int32? {
            let active = Int(try device.getActiveVersion(circleId: circle))
            guard Manager.holdsCurrentKey(localActiveVersion: active, circleKeyVersion: listed) else { return nil }
            let sealed = try device.encryptData(circleId: circle, plaintext: "meanwhile")
            return versions.first { version in
                (try? device.decryptDataWithVersion(circleId: circle, encryptedData: sealed, keyVersion: version)) == "meanwhile"
            }
        }

        // With both rules. Eject #1 taken (recordedChangeTaken); the
        // load after it fails, so the list still says 2.
        let mine = try ownChangeTaken()
        let earlier = try mine.owner.sdk.encryptData(circleId: circle, plaintext: "under v3")
        let own = Manager.noting(try XCTUnwrap(mine.v3.rotation.keyChainLink), in: [])
        let listed = Manager.listedVersion(2, taken: mine.v3.rotation.newKeyVersion)
        XCTAssertEqual(listed, 3, "(b′): the taken version, the load after it having failed")
        let mode = Manager.rotationMode(Manager.rotationMode(.recorded, ownerOrAdmin: true, repairDue: false),
                                        ownChangeUndecided: !own.isEmpty)
        if mode != .wait {
            // What the app would do: build it; the server refuses it (409); the catch discards.
            _ = try? nextChange(mine)
            _ = mine.owner.sdk.discardUnconfirmedRotation(circleId: circle)
        }
        XCTAssertEqual(mode, .wait, "(a): the second change waits, and nothing is built")
        XCTAssertEqual(try mine.owner.sdk.getActiveVersion(circleId: circle), 3)
        XCTAssertEqual(try mine.owner.sdk.decryptDataWithVersion(circleId: circle, encryptedData: earlier, keyVersion: 3),
                       "under v3", "v3's key stays")
        XCTAssertEqual(try sealedUnder(mine.owner.sdk, listed: listed), 3, "sealed under v3, never v2")

        // CONTROL: without the rules. No own link, and the list left at
        // 2.
        let before = try ownChangeTaken()
        let earlierBefore = try before.owner.sdk.encryptData(circleId: circle, plaintext: "under v3")
        XCTAssertEqual(Manager.rotationMode(.recorded, ownerOrAdmin: true, repairDue: false), .recorded(.rotation))
        XCTAssertEqual(try nextChange(before).rotation.newKeyVersion, 3, "built at v3 again")
        XCTAssertThrowsError(try before.owner.sdk.decryptDataWithVersion(circleId: circle, encryptedData: earlierBefore,
                                                                         keyVersion: 3), "v3's key replaced")
        XCTAssertTrue(before.owner.sdk.discardUnconfirmedRotation(circleId: circle), "the 409's catch")
        XCTAssertEqual(try before.owner.sdk.getActiveVersion(circleId: circle), 2)
        XCTAssertEqual(try sealedUnder(before.owner.sdk, listed: 2), 2, "the hole: sealed under v2")
        // The listed-version rule on its own: the same build and discard,
        // with the list at the taken version, keeps the gate closed.
        XCTAssertNil(try sealedUnder(before.owner.sdk, listed: Manager.listedVersion(2, taken: before.v3.rotation.newKeyVersion)))
    }

    /// The from-below eject: an admin whose device was left pending at v3
    /// holds v3's record as reference (its head) but not v3's key. It ejects x
    /// at once, from below: v4, planned by the app's own planner against v3's
    /// record, linked down to v2, the highest it holds; x gets no wrap; the
    /// owner's device, holding v3, accepts v4. A device whose head isn't the
    /// circle's version doesn't eject from below.
    func testAnAdminEjectsFromBelowWhileLeftPending() throws {
        let (owner, admin, x) = (Party(), Party(), Party())
        let genesis = try owner.sdk.prepareRecordedCircleCreation(creatorUserId: owner.userId, circleId: circle).genesis
        let invitedAdmin = try invitation(by: owner, of: admin, atVersion: 1)
        let invitedX = try invitation(by: owner, of: x, atVersion: 1)
        let ownersView = [row(owner, role: .owner), row(admin, role: .admin, statements: [invitedAdmin]),
                          row(x, statements: [invitedX])]
        let v2 = try ownerRotates(owner, planned: [
            PlannedEntry(userId: owner.userId, state: .included, role: nil),
            PlannedEntry(userId: admin.userId, state: .included, role: .admin),
            PlannedEntry(userId: x.userId, state: .included, role: nil),
        ], members: ownersView)
        // v3 leaves the admin pending: no wrap for them.
        let v3 = try ownerRotates(owner, planned: [
            PlannedEntry(userId: owner.userId, state: .included, role: nil),
            PlannedEntry(userId: admin.userId, state: .pending, role: nil),
            PlannedEntry(userId: x.userId, state: .included, role: nil),
        ], members: ownersView)
        XCTAssertNil(v3.rotation.memberKeys.first { $0.userId == admin.userId })

        // The admin's device: v2's key from the owner, then the records.
        _ = try admin.sdk.pinMemberKeys(circleId: circle, userId: owner.userId,
                                        sharingPubkeyHex: owner.sharing, signingPubkeyHex: owner.signing)
        let first = try wrap(for: admin, in: v2)
        try admin.sdk.storeFirstCircleKey(
            circleId: circle, encryptedKey: first.encryptedCircleKey.nonce + first.encryptedCircleKey.ciphertext,
            senderPublicKey: first.ephemeralPublicKey, keyVersion: 2, senderUserId: owner.userId,
            recipientUserId: admin.userId, wrapSignatureHex: first.wrapSignature,
            confirmedSenderSigningPubkeyHex: owner.signing, sealedCircleName: nil)
        let adminsView = [row(admin, role: .admin, statements: [invitedAdmin]), row(owner, role: .owner),
                          row(x, statements: [invitedX])]
        let report = try admin.sdk.importRefreshRecords(
            circleId: circle, records: [genesis, record(v2), record(v3)], keyChain: links,
            members: adminsView.map(\.sdkMember), rosterComplete: true, ownHead: nil, memberHeads: [])
        XCTAssertFalse(report.forked)
        XCTAssertEqual(report.versions.first { $0.version == 3 }?.state, .reference, "v3's record, not its key")
        XCTAssertEqual(admin.sdk.refreshHeadVersions()[circle], 3, "its head is the circle's version")
        XCTAssertEqual(try admin.sdk.getActiveVersion(circleId: circle), 2, "it seals under v2 only")
        XCTAssertTrue(Track.CircleManager.ejectsFromBelow(standing: .recorded, head: 3, circleVersion: 3, holdsCurrent: false,
                                                          ownerOrAdmin: true))

        // The eject, planned by the app against v3's record.
        let includable = Set(try admin.sdk.refreshEligibility(
            circleId: circle, members: adminsView.map(\.sdkMember), purpose: .include).filter(\.eligible).map(\.userId))
        var counted: [String: CircleRole] = [:]
        for party in [owner, admin, x] { counted[party.userId] = admin.sdk.chainRole(circleId: circle, userId: party.userId) }
        XCTAssertEqual(counted[admin.userId], .admin)
        let plan = RecordedRotation.rotationPlan(
            me: admin.userId, roster: Track.CircleManager.listed(adminsView), includable: includable, blocked: [],
            counted: counted.compactMapValues { $0 }, removing: [x.userId])
        XCTAssertEqual(plan.first { $0.userId == x.userId }?.state, .removed)
        // V's name can't be read here (sealed under v3): it never blocks the
        // eject, which seals a placeholder that is never sent.
        let name = try XCTUnwrap(Track.CircleManager.nameToSeal(readable: nil, sealable: nil, ejectingFromBelow: true,
                                                                holds: false))
        let v4 = try admin.sdk.prepareRecordedRotation(
            circleId: circle, senderUserId: admin.userId, kind: .rotation, planned: plan,
            members: adminsView.map(\.sdkMember), rosterComplete: true, currentCircleNamePlaintext: name.plaintext)
        XCTAssertEqual(v4.rotation.newKeyVersion, 4)
        XCTAssertNil(v4.rotation.memberKeys.first { $0.userId == x.userId }, "the ejected member gets no wrap")
        XCTAssertEqual(v4.rotation.keyChainLink?.toVersion, 2, "linked down to the highest version it holds")
        // The request: no name at all (left out, never null), and no wrap for
        // the ejected member. Nothing here writes a name anywhere: the list's
        // stays what this device shows.
        let change = Track.CircleManager.RecordedChange(
            bundle: v4, kind: .rotation, pendingMembers: [], removals: [x.userId], roleChanges: [:], repairing: nil,
            name: name)
        let request = Track.CircleManager.ejectRequest(userId: x.userId, change: change)
        XCTAssertNil(request.encryptedName)
        XCTAssertFalse(request.memberWraps.contains { $0.userId == x.userId })
        func wire(_ request: EjectAndRotateRequest) throws -> [String: Any] {
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase  // as APIService encodes
            return try XCTUnwrap(try JSONSerialization.jsonObject(with: encoder.encode(request)) as? [String: Any])
        }
        XCTAssertFalse(try wire(request).keys.contains("encrypted_name"), "left out, never null")
        XCTAssertNotNil(try wire(request)["refresh_record"])
        let named = Track.CircleManager.ejectRequest(userId: x.userId, change: Track.CircleManager.RecordedChange(
            bundle: v4, kind: .rotation, pendingMembers: [], removals: [x.userId], roleChanges: [:], repairing: nil,
            name: .name("Family")))
        XCTAssertNotNil(try wire(named)["encrypted_name"], "a name this device reads is sealed again")

        // The owner's device, holding v3, accepts v4 with its wrap (from the
        // admin it confirms, and so pins).
        links.append(try XCTUnwrap(v4.rotation.keyChainLink))
        _ = try owner.sdk.pinMemberKeys(circleId: circle, userId: admin.userId,
                                        sharingPubkeyHex: admin.sharing, signingPubkeyHex: admin.signing)
        let ownerWrap = try wrap(for: owner, in: v4)
        try owner.sdk.storeCircleKey(
            circleId: circle, encryptedKey: ownerWrap.encryptedCircleKey.nonce + ownerWrap.encryptedCircleKey.ciphertext,
            senderPublicKey: ownerWrap.ephemeralPublicKey, keyVersion: 4, senderUserId: admin.userId,
            recipientUserId: owner.userId, wrapSignatureHex: ownerWrap.wrapSignature, senderSigningPubkeyHex: admin.signing)
        let accepted = try owner.sdk.importRefreshRecords(
            circleId: circle, records: [record(v4)], keyChain: links, members: ownersView.map(\.sdkMember),
            rosterComplete: true, ownHead: nil, memberHeads: [])
        XCTAssertEqual(accepted.versions.map { "\($0.version) \($0.state)" }, ["4 accepted"])
        XCTAssertNil(owner.sdk.chainRole(circleId: circle, userId: x.userId), "x removed, counting")

        // Where the circle's version isn't this device's head (v3 waiting), or
        // it forked: no eject from below.
        XCTAssertFalse(Track.CircleManager.ejectsFromBelow(standing: .recorded, head: 2, circleVersion: 3, holdsCurrent: false,
                                                           ownerOrAdmin: true))
        XCTAssertFalse(Track.CircleManager.ejectsFromBelow(standing: .wait, head: 3, circleVersion: 3, holdsCurrent: false,
                                                           ownerOrAdmin: true))
        XCTAssertFalse(Track.CircleManager.ejectsFromBelow(standing: .recorded, head: 3, circleVersion: 3, holdsCurrent: false,
                                                           ownerOrAdmin: false))
        XCTAssertFalse(Track.CircleManager.ejectsFromBelow(standing: .recorded, head: 3, circleVersion: 3, holdsCurrent: true,
                                                           ownerOrAdmin: true),
                       "holding the current version, it ejects as usual")
    }

    /// EVERY record built after a record this device rejected names every
    /// listed member that record names, pending those the eligibility rule
    /// doesn't allow here, a repair or not: the report's `tipNamedListed`. An
    /// admin's v3 includes a newcomer the owner's device doesn't allow, so it
    /// rejects v3 (`.r2NotAllowed`); then, with no repair due, a plain rotation
    /// and an eject of another member from the owner's device both go through
    /// with the newcomer pending. Leaving them out is what the real builder
    /// refuses.
    func testEveryRotationOnARejectedTipCarriesItsNewcomerPending() throws {
        let (owner, b, c, d, ghost) = (Party(), Party(), Party(), Party(), Party())
        let genesis = try owner.sdk.prepareRecordedCircleCreation(creatorUserId: owner.userId, circleId: circle).genesis
        let invitedB = try invitation(by: owner, of: b, atVersion: 1)
        let invitedC = try invitation(by: owner, of: c, atVersion: 1)
        let invitedD = try invitation(by: owner, of: d, atVersion: 1)
        let ownersView = [row(owner, role: .owner), row(b, statements: [invitedB]),
                          row(c, role: .admin, statements: [invitedC]), row(d, statements: [invitedD])]
        let v2 = try ownerRotates(owner, planned: [
            PlannedEntry(userId: owner.userId, state: .included, role: nil),
            PlannedEntry(userId: b.userId, state: .included, role: nil),
            PlannedEntry(userId: c.userId, state: .included, role: .admin),
            PlannedEntry(userId: d.userId, state: .included, role: nil),
        ], members: ownersView)

        // The admin's device: v2, then v3 with a newcomer it invited itself.
        _ = try c.sdk.pinMemberKeys(circleId: circle, userId: owner.userId,
                                    sharingPubkeyHex: owner.sharing, signingPubkeyHex: owner.signing)
        let first = try wrap(for: c, in: v2)
        try c.sdk.storeFirstCircleKey(
            circleId: circle, encryptedKey: first.encryptedCircleKey.nonce + first.encryptedCircleKey.ciphertext,
            senderPublicKey: first.ephemeralPublicKey, keyVersion: 2, senderUserId: owner.userId,
            recipientUserId: c.userId, wrapSignatureHex: first.wrapSignature,
            confirmedSenderSigningPubkeyHex: owner.signing, sealedCircleName: nil)
        let invitedGhost = try invitation(by: c, of: ghost, atVersion: 2)
        let ghostHere = RecordMemberRow(userId: ghost.userId, keys: ghost.keys, confirmed: true, listed: true,
                                        listedRole: .member, statements: [invitedGhost], personConfirmedKeys: false,
                                        serverSaysKeyless: true)
        let adminsView = [row(c, role: .admin, statements: [invitedC]), row(owner, role: .owner),
                          row(b, statements: [invitedB]), row(d, statements: [invitedD]), ghostHere]
        _ = try c.sdk.importRefreshRecords(
            circleId: circle, records: [genesis, record(v2)], keyChain: links, members: adminsView.map(\.sdkMember),
            rosterComplete: true, ownHead: nil, memberHeads: [])
        let v3 = try c.sdk.prepareRecordedRotation(
            circleId: circle, senderUserId: c.userId, kind: .rotation, planned: [
                PlannedEntry(userId: c.userId, state: .included, role: nil),
                PlannedEntry(userId: owner.userId, state: .included, role: nil),
                PlannedEntry(userId: b.userId, state: .included, role: nil),
                PlannedEntry(userId: d.userId, state: .included, role: nil),
                PlannedEntry(userId: ghost.userId, state: .included, role: nil),
            ], members: adminsView.map(\.sdkMember), rosterComplete: true, currentCircleNamePlaintext: "Family")
        links.append(try XCTUnwrap(v3.rotation.keyChainLink))

        // The owner's device: v3's key from the admin it confirms, then v3's
        // record, which it rejects: the newcomer is listed and confirmed here,
        // and no statement lets them in here (`.r2NotAllowed`).
        _ = try owner.sdk.pinMemberKeys(circleId: circle, userId: c.userId,
                                        sharingPubkeyHex: c.sharing, signingPubkeyHex: c.signing)
        let third = try wrap(for: owner, in: v3)
        try owner.sdk.storeCircleKey(
            circleId: circle, encryptedKey: third.encryptedCircleKey.nonce + third.encryptedCircleKey.ciphertext,
            senderPublicKey: third.ephemeralPublicKey, keyVersion: 3, senderUserId: c.userId,
            recipientUserId: owner.userId, wrapSignatureHex: third.wrapSignature, senderSigningPubkeyHex: c.signing)
        let ownersNow = ownersView + [row(ghost)]
        let report = try owner.sdk.importRefreshRecords(
            circleId: circle, records: [record(v3)], keyChain: links, members: ownersNow.map(\.sdkMember),
            rosterComplete: true, ownHead: nil, memberHeads: [])
        let tip = try XCTUnwrap(report.versions.first { $0.version == 3 }, "\(report.versions)")
        XCTAssertEqual(tip.state, .rejected)
        XCTAssertEqual(tip.notAllowed, [ghost.userId])
        XCTAssertEqual(Set(report.tipNamedListed), Set([owner, b, c, d, ghost].map(\.userId)),
                       "every listed member v3 names")

        // The app's planner, as prepareRecordedChange runs it with no repair due.
        let includable = Set(try owner.sdk.refreshEligibility(
            circleId: circle, members: ownersNow.map(\.sdkMember), purpose: .include).filter(\.eligible).map(\.userId))
        var counted: [String: CircleRole] = [:]
        for party in [owner, b, c, d, ghost] {
            counted[party.userId] = owner.sdk.chainRole(circleId: circle, userId: party.userId)
        }
        func plan(removing: Set<String>, rejectedIncluded: Set<String>) -> [PlannedEntry] {
            RecordedRotation.rotationPlan(
                me: owner.userId, roster: Track.CircleManager.listed(ownersNow), includable: includable, blocked: [],
                counted: counted.compactMapValues { $0 }, removing: removing, rejectedIncluded: rejectedIncluded)
        }
        func build(_ planned: [PlannedEntry]) throws -> RecordedRotationBundle {
            try owner.sdk.prepareRecordedRotation(
                circleId: circle, senderUserId: owner.userId, kind: .rotation, planned: planned,
                members: ownersNow.map(\.sdkMember), rosterComplete: true, currentCircleNamePlaintext: "Family")
        }
        XCTAssertThrowsError(try build(plan(removing: [], rejectedIncluded: [])),
                             "the newcomer left out: what the real builder refuses")
        _ = owner.sdk.discardUnconfirmedRotation(circleId: circle)

        let plain = plan(removing: [], rejectedIncluded: Set(report.tipNamedListed))
        XCTAssertEqual(plain.first { $0.userId == ghost.userId }?.state, .pending)
        let refreshed = try build(plain)
        XCTAssertNil(refreshed.rotation.memberKeys.first { $0.userId == ghost.userId }, "pending: no key for them")
        _ = owner.sdk.discardUnconfirmedRotation(circleId: circle)

        let eject = plan(removing: [d.userId], rejectedIncluded: Set(report.tipNamedListed))
        XCTAssertEqual(eject.first { $0.userId == d.userId }?.state, .removed)
        XCTAssertEqual(eject.first { $0.userId == ghost.userId }?.state, .pending)
        let ejected = try build(eject)
        XCTAssertNil(ejected.rotation.memberKeys.first { $0.userId == d.userId }, "the ejected member gets no key")
        _ = owner.sdk.discardUnconfirmedRotation(circleId: circle)
    }

    /// An eject of a member only the rejected tip names (the chain doesn't
    /// count them here) plans them `removed`, never leaves them to the
    /// builder's fill as departed. On the admin's device, which let them in
    /// and still lists them, the owner's removal counts and sticks; a
    /// departure would not count while they are listed there.
    func testAnEjectOfANewcomerOnlyTheRejectedTipNamesIsRemoved() throws {
        let (owner, b, c, ghost) = (Party(), Party(), Party(), Party())
        let genesis = try owner.sdk.prepareRecordedCircleCreation(creatorUserId: owner.userId, circleId: circle).genesis
        let invitedB = try invitation(by: owner, of: b, atVersion: 1)
        let invitedC = try invitation(by: owner, of: c, atVersion: 1)
        let ownersView = [row(owner, role: .owner), row(b, statements: [invitedB]), row(c, role: .admin, statements: [invitedC])]
        let v2 = try ownerRotates(owner, planned: [
            PlannedEntry(userId: owner.userId, state: .included, role: nil),
            PlannedEntry(userId: b.userId, state: .included, role: nil),
            PlannedEntry(userId: c.userId, state: .included, role: .admin),
        ], members: ownersView)

        // The admin's device: v2, then its own v3 with a newcomer it invited.
        _ = try c.sdk.pinMemberKeys(circleId: circle, userId: owner.userId,
                                    sharingPubkeyHex: owner.sharing, signingPubkeyHex: owner.signing)
        let first = try wrap(for: c, in: v2)
        try c.sdk.storeFirstCircleKey(
            circleId: circle, encryptedKey: first.encryptedCircleKey.nonce + first.encryptedCircleKey.ciphertext,
            senderPublicKey: first.ephemeralPublicKey, keyVersion: 2, senderUserId: owner.userId,
            recipientUserId: c.userId, wrapSignatureHex: first.wrapSignature,
            confirmedSenderSigningPubkeyHex: owner.signing, sealedCircleName: nil)
        let invitedGhost = try invitation(by: c, of: ghost, atVersion: 2)
        let adminsView = [row(c, role: .admin, statements: [invitedC]), row(owner, role: .owner),
                          row(b, statements: [invitedB]), row(ghost, statements: [invitedGhost])]
        _ = try c.sdk.importRefreshRecords(
            circleId: circle, records: [genesis, record(v2)], keyChain: links, members: adminsView.map(\.sdkMember),
            rosterComplete: true, ownHead: nil, memberHeads: [])
        let v3 = try c.sdk.prepareRecordedRotation(
            circleId: circle, senderUserId: c.userId, kind: .rotation, planned: [
                PlannedEntry(userId: c.userId, state: .included, role: nil),
                PlannedEntry(userId: owner.userId, state: .included, role: nil),
                PlannedEntry(userId: b.userId, state: .included, role: nil),
                PlannedEntry(userId: ghost.userId, state: .included, role: nil),
            ], members: adminsView.map(\.sdkMember), rosterComplete: true, currentCircleNamePlaintext: "Family")
        links.append(try XCTUnwrap(v3.rotation.keyChainLink))

        // The owner's device rejects v3: the newcomer isn't allowed here.
        _ = try owner.sdk.pinMemberKeys(circleId: circle, userId: c.userId,
                                        sharingPubkeyHex: c.sharing, signingPubkeyHex: c.signing)
        let third = try wrap(for: owner, in: v3)
        try owner.sdk.storeCircleKey(
            circleId: circle, encryptedKey: third.encryptedCircleKey.nonce + third.encryptedCircleKey.ciphertext,
            senderPublicKey: third.ephemeralPublicKey, keyVersion: 3, senderUserId: c.userId,
            recipientUserId: owner.userId, wrapSignatureHex: third.wrapSignature, senderSigningPubkeyHex: c.signing)
        let ownersNow = ownersView + [row(ghost)]
        let report = try owner.sdk.importRefreshRecords(
            circleId: circle, records: [record(v3)], keyChain: links, members: ownersNow.map(\.sdkMember),
            rosterComplete: true, ownHead: nil, memberHeads: [])
        XCTAssertEqual(report.versions.first { $0.version == 3 }?.state, .rejected)
        XCTAssertTrue(report.tipNamedListed.contains(ghost.userId))
        XCTAssertNil(owner.sdk.chainRole(circleId: circle, userId: ghost.userId), "the chain doesn't count them here")

        // The owner ejects the newcomer, as prepareRecordedChange plans an
        // eject: off the list, and the member it removes.
        let ejecting = ownersNow.map { row in
            row.userId != ghost.userId ? row : RecordMemberRow(
                userId: row.userId, keys: row.keys, confirmed: row.confirmed, listed: false, listedRole: row.listedRole,
                statements: row.statements, personConfirmedKeys: row.personConfirmedKeys,
                serverSaysKeyless: row.serverSaysKeyless)
        }
        let includable = Set(try owner.sdk.refreshEligibility(
            circleId: circle, members: ejecting.map(\.sdkMember), purpose: .include).filter(\.eligible).map(\.userId))
        var counted: [String: CircleRole] = [:]
        for party in [owner, b, c, ghost] { counted[party.userId] = owner.sdk.chainRole(circleId: circle, userId: party.userId) }
        let planned = RecordedRotation.rotationPlan(
            me: owner.userId, roster: Track.CircleManager.listed(ejecting), includable: includable, blocked: [],
            counted: counted.compactMapValues { $0 }, removing: [ghost.userId], rejectedIncluded: Set(report.tipNamedListed))
        XCTAssertEqual(planned.first { $0.userId == ghost.userId }?.state, .removed)
        let v4 = try owner.sdk.prepareRecordedRotation(
            circleId: circle, senderUserId: owner.userId, kind: .rotation, planned: planned,
            members: ejecting.map(\.sdkMember), rosterComplete: true, currentCircleNamePlaintext: "Family")
        XCTAssertNil(v4.rotation.memberKeys.first { $0.userId == ghost.userId }, "no key for the ejected member")
        links.append(try XCTUnwrap(v4.rotation.keyChainLink))

        // The admin's device still lists the newcomer. The owner's removal
        // counts there, and they are out.
        XCTAssertNotNil(try c.sdk.importRefreshRecords(
            circleId: circle, records: [record(v3)], keyChain: links, members: adminsView.map(\.sdkMember),
            rosterComplete: true, ownHead: nil, memberHeads: []).versions.first { $0.version == 3 && $0.state == .accepted })
        XCTAssertNotNil(c.sdk.chainRole(circleId: circle, userId: ghost.userId), "let in by the admin's own v3")
        let fourth = try wrap(for: c, in: v4)
        try c.sdk.storeCircleKey(
            circleId: circle, encryptedKey: fourth.encryptedCircleKey.nonce + fourth.encryptedCircleKey.ciphertext,
            senderPublicKey: fourth.ephemeralPublicKey, keyVersion: 4, senderUserId: owner.userId,
            recipientUserId: c.userId, wrapSignatureHex: fourth.wrapSignature, senderSigningPubkeyHex: owner.signing)
        let adminsReport = try c.sdk.importRefreshRecords(
            circleId: circle, records: [record(v4)], keyChain: links, members: adminsView.map(\.sdkMember),
            rosterComplete: true, ownHead: nil, memberHeads: [])
        XCTAssertEqual(adminsReport.versions.first { $0.version == 4 }?.state, .accepted, "\(adminsReport.versions)")
        XCTAssertNil(c.sdk.chainRole(circleId: circle, userId: ghost.userId),
                     "removed by the owner: out, though still listed there")
    }

    /// The tip carries a newcomer PENDING. An admin's v3 includes n, whom the
    /// owner's device doesn't allow; its v4 carries n pending and includes o,
    /// whom the owner's device doesn't allow either. The owner's device
    /// rejects both, and v4's `notAllowed` names o alone. A plan with only
    /// that is refused; the report's `tipNamedListed` names n too, and the
    /// plan with it builds, n and o pending.
    func testATipCarryingANewcomerPendingIsNamedWhole() throws {
        let (owner, b, c, n, o) = (Party(), Party(), Party(), Party(), Party())
        let genesis = try owner.sdk.prepareRecordedCircleCreation(creatorUserId: owner.userId, circleId: circle).genesis
        let invitedB = try invitation(by: owner, of: b, atVersion: 1)
        let invitedC = try invitation(by: owner, of: c, atVersion: 1)
        let ownersView = [row(owner, role: .owner), row(b, statements: [invitedB]),
                          row(c, role: .admin, statements: [invitedC])]
        let v2 = try ownerRotates(owner, planned: [
            PlannedEntry(userId: owner.userId, state: .included, role: nil),
            PlannedEntry(userId: b.userId, state: .included, role: nil),
            PlannedEntry(userId: c.userId, state: .included, role: .admin),
        ], members: ownersView)

        // The admin's device: v2, then its own v3 (n included) and v4 (n
        // pending, o included), each taken back as the server took it.
        _ = try c.sdk.pinMemberKeys(circleId: circle, userId: owner.userId,
                                    sharingPubkeyHex: owner.sharing, signingPubkeyHex: owner.signing)
        let first = try wrap(for: c, in: v2)
        try c.sdk.storeFirstCircleKey(
            circleId: circle, encryptedKey: first.encryptedCircleKey.nonce + first.encryptedCircleKey.ciphertext,
            senderPublicKey: first.ephemeralPublicKey, keyVersion: 2, senderUserId: owner.userId,
            recipientUserId: c.userId, wrapSignatureHex: first.wrapSignature,
            confirmedSenderSigningPubkeyHex: owner.signing, sealedCircleName: nil)
        let invitedN = try invitation(by: c, of: n, atVersion: 2)
        let invitedO = try invitation(by: c, of: o, atVersion: 3)
        let adminsView = [row(c, role: .admin, statements: [invitedC]), row(owner, role: .owner),
                          row(b, statements: [invitedB]), row(n, statements: [invitedN]), row(o, statements: [invitedO])]
        _ = try c.sdk.importRefreshRecords(
            circleId: circle, records: [genesis, record(v2)], keyChain: links, members: adminsView.map(\.sdkMember),
            rosterComplete: true, ownHead: nil, memberHeads: [])
        func adminRotates(_ planned: [PlannedEntry]) throws -> RecordedRotationBundle {
            let bundle = try c.sdk.prepareRecordedRotation(
                circleId: circle, senderUserId: c.userId, kind: .rotation, planned: planned,
                members: adminsView.map(\.sdkMember), rosterComplete: true, currentCircleNamePlaintext: "Family")
            links.append(try XCTUnwrap(bundle.rotation.keyChainLink))
            let report = try c.sdk.importRefreshRecords(
                circleId: circle, records: [record(bundle)], keyChain: links, members: adminsView.map(\.sdkMember),
                rosterComplete: true, ownHead: nil, memberHeads: [])
            XCTAssertEqual(report.versions.map(\.state), [.accepted], "the admin's own record, taken back")
            return bundle
        }
        let v3 = try adminRotates([
            PlannedEntry(userId: c.userId, state: .included, role: nil),
            PlannedEntry(userId: owner.userId, state: .included, role: nil),
            PlannedEntry(userId: b.userId, state: .included, role: nil),
            PlannedEntry(userId: n.userId, state: .included, role: nil),
        ])
        let v4 = try adminRotates([
            PlannedEntry(userId: c.userId, state: .included, role: nil),
            PlannedEntry(userId: owner.userId, state: .included, role: nil),
            PlannedEntry(userId: b.userId, state: .included, role: nil),
            PlannedEntry(userId: n.userId, state: .pending, role: nil),
            PlannedEntry(userId: o.userId, state: .included, role: nil),
        ])

        // The owner's device: both keys from the admin it confirms, then both
        // records, which it rejects.
        _ = try owner.sdk.pinMemberKeys(circleId: circle, userId: c.userId,
                                        sharingPubkeyHex: c.sharing, signingPubkeyHex: c.signing)
        for (bundle, version) in [(v3, Int32(3)), (v4, Int32(4))] {
            let key = try wrap(for: owner, in: bundle)
            try owner.sdk.storeCircleKey(
                circleId: circle, encryptedKey: key.encryptedCircleKey.nonce + key.encryptedCircleKey.ciphertext,
                senderPublicKey: key.ephemeralPublicKey, keyVersion: version, senderUserId: c.userId,
                recipientUserId: owner.userId, wrapSignatureHex: key.wrapSignature, senderSigningPubkeyHex: c.signing)
        }
        let ownersNow = ownersView + [row(n), row(o)]
        let report = try owner.sdk.importRefreshRecords(
            circleId: circle, records: [record(v3), record(v4)], keyChain: links, members: ownersNow.map(\.sdkMember),
            rosterComplete: true, ownHead: nil, memberHeads: [])
        XCTAssertEqual(report.versions.map { "\($0.version) \($0.state)" }, ["3 rejected", "4 rejected"])
        let tip = try XCTUnwrap(report.versions.first { $0.version == 4 })
        XCTAssertEqual(tip.notAllowed, [o.userId], "v4's own refusal names o alone")
        XCTAssertTrue(Set(report.tipNamedListed).isSuperset(of: [n.userId, o.userId]), "\(report.tipNamedListed)")

        let includable = Set(try owner.sdk.refreshEligibility(
            circleId: circle, members: ownersNow.map(\.sdkMember), purpose: .include).filter(\.eligible).map(\.userId))
        var counted: [String: CircleRole] = [:]
        for party in [owner, b, c, n, o] {
            counted[party.userId] = owner.sdk.chainRole(circleId: circle, userId: party.userId)
        }
        func build(rejectedIncluded: Set<String>) throws -> [PlannedEntry] {
            let planned = RecordedRotation.rotationPlan(
                me: owner.userId, roster: Track.CircleManager.listed(ownersNow), includable: includable, blocked: [],
                counted: counted.compactMapValues { $0 }, removing: [], rejectedIncluded: rejectedIncluded)
            _ = try owner.sdk.prepareRecordedRotation(
                circleId: circle, senderUserId: owner.userId, kind: .rotation, planned: planned,
                members: ownersNow.map(\.sdkMember), rosterComplete: true, currentCircleNamePlaintext: "Family")
            _ = owner.sdk.discardUnconfirmedRotation(circleId: circle)
            return planned
        }
        XCTAssertThrowsError(try build(rejectedIncluded: Set(tip.notAllowed)),
                             "n, pending on the tip, left out: what the real builder refuses")
        let planned = try build(rejectedIncluded: Set(report.tipNamedListed))
        XCTAssertEqual(planned.first { $0.userId == n.userId }?.state, .pending)
        XCTAssertEqual(planned.first { $0.userId == o.userId }?.state, .pending)
    }

    /// The tip includes a newcomer who is listed but not confirmed on the
    /// owner's device. The report counts it only as an unmatched entry
    /// (`notAllowed` empty), and `tipNamedListed` names them: the plan carries
    /// them pending and builds.
    func testAnUnconfirmedNewcomerOnTheTipIsNamedPending() throws {
        let (owner, c, ghost) = (Party(), Party(), Party())
        let genesis = try owner.sdk.prepareRecordedCircleCreation(creatorUserId: owner.userId, circleId: circle).genesis
        let invitedC = try invitation(by: owner, of: c, atVersion: 1)
        let ownersView = [row(owner, role: .owner), row(c, role: .admin, statements: [invitedC])]
        let v2 = try ownerRotates(owner, planned: [
            PlannedEntry(userId: owner.userId, state: .included, role: nil),
            PlannedEntry(userId: c.userId, state: .included, role: .admin),
        ], members: ownersView)
        _ = try c.sdk.pinMemberKeys(circleId: circle, userId: owner.userId,
                                    sharingPubkeyHex: owner.sharing, signingPubkeyHex: owner.signing)
        let first = try wrap(for: c, in: v2)
        try c.sdk.storeFirstCircleKey(
            circleId: circle, encryptedKey: first.encryptedCircleKey.nonce + first.encryptedCircleKey.ciphertext,
            senderPublicKey: first.ephemeralPublicKey, keyVersion: 2, senderUserId: owner.userId,
            recipientUserId: c.userId, wrapSignatureHex: first.wrapSignature,
            confirmedSenderSigningPubkeyHex: owner.signing, sealedCircleName: nil)
        let invitedGhost = try invitation(by: c, of: ghost, atVersion: 2)
        let adminsView = [row(c, role: .admin, statements: [invitedC]), row(owner, role: .owner),
                          row(ghost, statements: [invitedGhost])]
        _ = try c.sdk.importRefreshRecords(
            circleId: circle, records: [genesis, record(v2)], keyChain: links, members: adminsView.map(\.sdkMember),
            rosterComplete: true, ownHead: nil, memberHeads: [])
        let v3 = try c.sdk.prepareRecordedRotation(
            circleId: circle, senderUserId: c.userId, kind: .rotation, planned: [
                PlannedEntry(userId: c.userId, state: .included, role: nil),
                PlannedEntry(userId: owner.userId, state: .included, role: nil),
                PlannedEntry(userId: ghost.userId, state: .included, role: nil),
            ], members: adminsView.map(\.sdkMember), rosterComplete: true, currentCircleNamePlaintext: "Family")
        links.append(try XCTUnwrap(v3.rotation.keyChainLink))

        _ = try owner.sdk.pinMemberKeys(circleId: circle, userId: c.userId,
                                        sharingPubkeyHex: c.sharing, signingPubkeyHex: c.signing)
        let third = try wrap(for: owner, in: v3)
        try owner.sdk.storeCircleKey(
            circleId: circle, encryptedKey: third.encryptedCircleKey.nonce + third.encryptedCircleKey.ciphertext,
            senderPublicKey: third.ephemeralPublicKey, keyVersion: 3, senderUserId: c.userId,
            recipientUserId: owner.userId, wrapSignatureHex: third.wrapSignature, senderSigningPubkeyHex: c.signing)
        let ownersNow = ownersView + [row(ghost, confirmed: false)]
        let report = try owner.sdk.importRefreshRecords(
            circleId: circle, records: [record(v3)], keyChain: links, members: ownersNow.map(\.sdkMember),
            rosterComplete: true, ownHead: nil, memberHeads: [])
        let tip = try XCTUnwrap(report.versions.first { $0.version == 3 }, "\(report.versions)")
        XCTAssertEqual(tip.state, .rejected)
        XCTAssertEqual(tip.notAllowed, [], "matched to nobody confirmed: no id in notAllowed")
        XCTAssertTrue(report.tipNamedListed.contains(ghost.userId), "\(report.tipNamedListed)")

        let includable = Set(try owner.sdk.refreshEligibility(
            circleId: circle, members: ownersNow.map(\.sdkMember), purpose: .include).filter(\.eligible).map(\.userId))
        XCTAssertFalse(includable.contains(ghost.userId))
        var counted: [String: CircleRole] = [:]
        for party in [owner, c, ghost] { counted[party.userId] = owner.sdk.chainRole(circleId: circle, userId: party.userId) }
        let planned = RecordedRotation.rotationPlan(
            me: owner.userId, roster: Track.CircleManager.listed(ownersNow), includable: includable,
            blocked: [], counted: counted.compactMapValues { $0 }, removing: [],
            rejectedIncluded: Set(report.tipNamedListed))
        XCTAssertEqual(planned.first { $0.userId == ghost.userId }?.state, .pending)
        let built = try owner.sdk.prepareRecordedRotation(
            circleId: circle, senderUserId: owner.userId, kind: .rotation, planned: planned,
            members: ownersNow.map(\.sdkMember), rosterComplete: true, currentCircleNamePlaintext: "Family")
        XCTAssertNil(built.rotation.memberKeys.first { $0.userId == ghost.userId })
        _ = owner.sdk.discardUnconfirmedRotation(circleId: circle)
    }

    /// After a completed claim the claimant is the listed owner but an admin
    /// in the chain. While the old owner still counts (gone from the list,
    /// never recorded gone), the builder refuses the claim, and the app plans
    /// again without it: the departure is recorded (the builder fills it in).
    /// At the next rotation no owner counts, and the claimant names itself
    /// owner.
    func testAClaimantNamesItselfOwnerOnceTheOldOwnerIsGone() throws {
        let (owner, claimant) = (Party(), Party())
        let genesis = try owner.sdk.prepareRecordedCircleCreation(creatorUserId: owner.userId, circleId: circle).genesis
        let invited = try invitation(by: owner, of: claimant, atVersion: 1)
        let v2 = try ownerRotates(owner, planned: [
            PlannedEntry(userId: owner.userId, state: .included, role: nil),
            PlannedEntry(userId: claimant.userId, state: .included, role: .admin),
        ], members: [row(owner, role: .owner), row(claimant, role: .admin, statements: [invited])])
        _ = try claimant.sdk.pinMemberKeys(circleId: circle, userId: owner.userId,
                                           sharingPubkeyHex: owner.sharing, signingPubkeyHex: owner.signing)
        let first = try wrap(for: claimant, in: v2)
        try claimant.sdk.storeFirstCircleKey(
            circleId: circle, encryptedKey: first.encryptedCircleKey.nonce + first.encryptedCircleKey.ciphertext,
            senderPublicKey: first.ephemeralPublicKey, keyVersion: 2, senderUserId: owner.userId,
            recipientUserId: claimant.userId, wrapSignatureHex: first.wrapSignature,
            confirmedSenderSigningPubkeyHex: owner.signing, sealedCircleName: nil)
        // The claim completed on the server and the old owner left: the list
        // shows the claimant as owner, alone.
        let view = [row(claimant, role: .owner, statements: [invited])]
        _ = try claimant.sdk.importRefreshRecords(
            circleId: circle, records: [genesis, record(v2)], keyChain: links, members: view.map(\.sdkMember),
            rosterComplete: true, ownHead: nil, memberHeads: [])

        func rotate() throws -> (bundle: RecordedRotationBundle, claimed: Bool) {
            var counted: [String: CircleRole] = [:]
            counted[claimant.userId] = claimant.sdk.chainRole(circleId: circle, userId: claimant.userId)
            let claims = RecordedRotation.claimsOwner(myChainRole: counted[claimant.userId] ?? nil, myListedRole: .owner,
                                                      removing: [], counted: counted.compactMapValues { $0 })
            XCTAssertTrue(claims, "no owner this device knows is counted: tried")
            func plan(_ claim: Bool) -> [PlannedEntry] {
                RecordedRotation.rotationPlan(me: claimant.userId, roster: Track.CircleManager.listed(view),
                                              includable: [], blocked: [], counted: counted.compactMapValues { $0 },
                                              removing: [], claimsOwner: claim)
            }
            let members = view.map(\.sdkMember)
            do {
                return (try claimant.sdk.prepareRecordedRotation(
                    circleId: circle, senderUserId: claimant.userId, kind: .rotation, planned: plan(true),
                    members: members, rosterComplete: true, currentCircleNamePlaintext: "Family"), true)
            } catch MobileError.InvalidInput {
                return (try claimant.sdk.prepareRecordedRotation(
                    circleId: circle, senderUserId: claimant.userId, kind: .rotation, planned: plan(false),
                    members: members, rosterComplete: true, currentCircleNamePlaintext: "Family"), false)
            }
        }
        let v3 = try rotate()
        XCTAssertFalse(v3.claimed, "the old owner still counts: the builder refuses the claim")
        links.append(try XCTUnwrap(v3.bundle.rotation.keyChainLink))
        _ = try claimant.sdk.importRefreshRecords(
            circleId: circle, records: [record(v3.bundle)], keyChain: links, members: view.map(\.sdkMember),
            rosterComplete: true, ownHead: nil, memberHeads: [])
        XCTAssertNil(claimant.sdk.chainRole(circleId: circle, userId: owner.userId), "recorded gone")
        XCTAssertEqual(claimant.sdk.chainRole(circleId: circle, userId: claimant.userId), .admin)

        let v4 = try rotate()
        XCTAssertTrue(v4.claimed)
        links.append(try XCTUnwrap(v4.bundle.rotation.keyChainLink))
        _ = try claimant.sdk.importRefreshRecords(
            circleId: circle, records: [record(v4.bundle)], keyChain: links, members: view.map(\.sdkMember),
            rosterComplete: true, ownHead: nil, memberHeads: [])
        XCTAssertEqual(claimant.sdk.chainRole(circleId: circle, userId: claimant.userId), .owner)
    }

    /// While an inactive old owner stays listed, the claimant (the server's
    /// owner, an admin in the chain) changes roles on the server only. Its app
    /// never plans them (a role change goes into a record only on the chain
    /// owner's device), so nothing is refused or retried; were one planned,
    /// the builder would refuse it (Role), and the same rotation with the
    /// roles carried is taken.
    func testAClaimantsRoleChangesStayOnTheServer() throws {
        let (owner, claimant, plain) = (Party(), Party(), Party())
        let genesis = try owner.sdk.prepareRecordedCircleCreation(creatorUserId: owner.userId, circleId: circle).genesis
        let invitedClaimant = try invitation(by: owner, of: claimant, atVersion: 1)
        let invitedPlain = try invitation(by: owner, of: plain, atVersion: 1)
        let v2 = try ownerRotates(owner, planned: [
            PlannedEntry(userId: owner.userId, state: .included, role: nil),
            PlannedEntry(userId: claimant.userId, state: .included, role: .admin),
            PlannedEntry(userId: plain.userId, state: .included, role: nil),
        ], members: [row(owner, role: .owner), row(claimant, role: .admin, statements: [invitedClaimant]),
                     row(plain, statements: [invitedPlain])])
        _ = try claimant.sdk.pinMemberKeys(circleId: circle, userId: owner.userId,
                                           sharingPubkeyHex: owner.sharing, signingPubkeyHex: owner.signing)
        let first = try wrap(for: claimant, in: v2)
        try claimant.sdk.storeFirstCircleKey(
            circleId: circle, encryptedKey: first.encryptedCircleKey.nonce + first.encryptedCircleKey.ciphertext,
            senderPublicKey: first.ephemeralPublicKey, keyVersion: 2, senderUserId: owner.userId,
            recipientUserId: claimant.userId, wrapSignatureHex: first.wrapSignature,
            confirmedSenderSigningPubkeyHex: owner.signing, sealedCircleName: nil)
        // A completed claim: the claimant is the listed owner, the old owner is
        // still listed, as an admin.
        let view = [row(claimant, role: .owner, statements: [invitedClaimant]), row(owner, role: .admin),
                    row(plain, statements: [invitedPlain])]
        _ = try claimant.sdk.importRefreshRecords(
            circleId: circle, records: [genesis, record(v2)], keyChain: links, members: view.map(\.sdkMember),
            rosterComplete: true, ownHead: nil, memberHeads: [])
        XCTAssertEqual(claimant.sdk.chainRole(circleId: circle, userId: claimant.userId), .admin)
        XCTAssertEqual(claimant.sdk.chainRole(circleId: circle, userId: owner.userId), .owner)
        var counted: [String: CircleRole] = [:]
        for party in [owner, claimant, plain] { counted[party.userId] = claimant.sdk.chainRole(circleId: circle, userId: party.userId) }
        let includable = Set(try claimant.sdk.refreshEligibility(
            circleId: circle, members: view.map(\.sdkMember), purpose: .include).filter(\.eligible).map(\.userId))
        XCTAssertFalse(RecordedRotation.claimsOwner(myChainRole: .admin, myListedRole: .owner, removing: [],
                                                    counted: counted.compactMapValues { $0 }),
                       "the old owner is counted and not removed: no claim")
        func plan(_ roleChanges: [String: CircleRole]) -> [PlannedEntry] {
            RecordedRotation.rotationPlan(me: claimant.userId, roster: Track.CircleManager.listed(view),
                                          includable: includable, blocked: [], counted: counted.compactMapValues { $0 },
                                          removing: [], roleChanges: roleChanges)
        }
        XCTAssertThrowsError(try claimant.sdk.prepareRecordedRotation(
            circleId: circle, senderUserId: claimant.userId, kind: .rotation, planned: plan([plain.userId: .admin]),
            members: view.map(\.sdkMember), rosterComplete: true, currentCircleNamePlaintext: "Family"),
                             "a role change by an admin in the chain: refused (Role)") { error in
            guard case MobileError.InvalidInput? = error as? MobileError else { return XCTFail("\(error)") }
        }
        let carried = try claimant.sdk.prepareRecordedRotation(
            circleId: circle, senderUserId: claimant.userId, kind: .rotation, planned: plan([:]),
            members: view.map(\.sdkMember), rosterComplete: true, currentCircleNamePlaintext: "Family")
        XCTAssertEqual(carried.rotation.newKeyVersion, 3, "the rotation itself, roles carried, is taken")
        // The app plans a role change only on the chain owner's device.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let circles = try String(contentsOf: root.appendingPathComponent("App/Managers/CircleManager.swift"), encoding: .utf8)
        XCTAssertTrue(circles.contains("        let record = Self.roleRecord(chainOwner: writesRoleRecords(circleId), role: role)\n"))
        XCTAssertTrue(circles.contains("        guard let me = AuthManager.shared.userId else { return false }\n        return cryptoManager.circleHasRefreshRecords(circleId: circleId)\n            && cryptoManager.chainRole(circleId: circleId, userId: me) == .owner\n"))
        XCTAssertEqual(CircleManager.roleRecord(chainOwner: false, role: .member), .notOwed, "nothing owed off the chain owner's device")
        XCTAssertEqual(CircleManager.roleRecord(chainOwner: false, role: .admin), .notOwed)
        XCTAssertTrue(circles.contains("let changes = RecordedRotation.writtenRoles(myChainRole: myChainRole, owed: owedRoles)"),
                      "and a record carries them only from the chain's owner")
        XCTAssertEqual(RecordedRotation.writtenRoles(myChainRole: .admin, owed: ["x": .admin]), [:])
        XCTAssertEqual(RecordedRotation.writtenRoles(myChainRole: nil, owed: ["x": .admin]), [:])
        XCTAssertEqual(RecordedRotation.writtenRoles(myChainRole: .owner, owed: ["x": .admin]), ["x": .admin])
    }

    /// A circle whose listed owner has no published keys gets no first record.
    /// The app's own plan is nil for it (it never asks), and the SDK refuses
    /// such a transition anyway; the circle stays as it was.
    func testNoTransitionWhileTheListedOwnerHasNoKeys() throws {
        let (me, owner) = (Party(), Party())
        let creation = try me.sdk.prepareCircleCreation()
        try me.sdk.finalizeCircleCreation(tempCircleId: creation.tempCircleId, realCircleId: circle)
        let rows = [row(me, role: .admin), row(owner, keys: false, role: .owner)]
        XCTAssertNil(RecordedRotation.transitionPlan(me: me.userId, roster: Track.CircleManager.listed(rows),
                                                     confirmed: [], blocked: []))
        XCTAssertThrowsError(try me.sdk.prepareRecordedRotation(
            circleId: circle, senderUserId: me.userId, kind: .transition,
            planned: [PlannedEntry(userId: me.userId, state: .included, role: .admin)],
            members: rows.map(\.sdkMember), rosterComplete: true, currentCircleNamePlaintext: "Family")) { error in
            guard case MobileError.InvalidInput? = error as? MobileError else { return XCTFail("\(error)") }
        }
        XCTAssertFalse(me.sdk.circleHasRefreshRecords(circleId: circle))
        XCTAssertEqual(try me.sdk.getActiveVersion(circleId: circle), 1, "nothing rotated")
        // Once the owner has keys, the list differs, and the app may try again.
        let withKeys = [row(me, role: .admin), row(owner, confirmed: false, role: .owner)]
        XCTAssertNotEqual(Track.CircleManager.transitionListing(rows), Track.CircleManager.transitionListing(withKeys))
        XCTAssertEqual(Track.CircleManager.transitionListing(rows),
                       Track.CircleManager.transitionListing(rows.reversed()), "the same list, in any order")
    }

    /// A listed member with no published keys is present and nothing more. A
    /// member the chain counts who has none now (a reset before they publish
    /// again) is carried pending by the app's own planner, with the chain's
    /// commitment (the builder refuses a listed member left out), and never
    /// included; on another device they are never matched, allowed in or
    /// vouched for, and a row claiming them confirmed is refused.
    func testAListedMemberWithNoKeysIsCarriedAndNeverMatched() throws {
        let (owner, me, y) = (Party(), Party(), Party())
        let genesis = try owner.sdk.prepareRecordedCircleCreation(creatorUserId: owner.userId, circleId: circle).genesis
        let invitedMe = try invitation(by: owner, of: me, atVersion: 1)
        let invitedY = try invitation(by: owner, of: y, atVersion: 1)
        let v2 = try ownerRotates(owner, planned: [
            PlannedEntry(userId: owner.userId, state: .included, role: nil),
            PlannedEntry(userId: me.userId, state: .included, role: nil),
            PlannedEntry(userId: y.userId, state: .included, role: nil),
        ], members: [row(owner, role: .owner), row(me, statements: [invitedMe]), row(y, statements: [invitedY])])

        // The owner's list now shows y with no keys: the app's planner.
        let ownersView = [row(owner, role: .owner), row(me, statements: [invitedMe]), row(y, keys: false)]
        let includable = Set(try owner.sdk.refreshEligibility(
            circleId: circle, members: ownersView.map(\.sdkMember), purpose: .include).filter(\.eligible).map(\.userId))
        var counted: [String: CircleRole] = [:]
        for party in [owner, me, y] { counted[party.userId] = owner.sdk.chainRole(circleId: circle, userId: party.userId) }
        let plan = RecordedRotation.rotationPlan(
            me: owner.userId, roster: Track.CircleManager.listed(ownersView), includable: includable, blocked: [],
            counted: counted.compactMapValues { $0 }, removing: [])
        XCTAssertEqual(plan.first { $0.userId == y.userId }?.state, .pending)
        XCTAssertFalse(includable.contains(y.userId))
        let v3 = try ownerRotates(owner, planned: plan, members: ownersView)
        XCTAssertNil(v3.rotation.memberKeys.first { $0.userId == y.userId }, "nothing wrapped to them")

        // This device: y listed with no keys.
        _ = try me.sdk.pinMemberKeys(circleId: circle, userId: owner.userId,
                                     sharingPubkeyHex: owner.sharing, signingPubkeyHex: owner.signing)
        for (version, bundle) in [(Int32(2), v2), (Int32(3), v3)] {
            let wrapped = try wrap(for: me, in: bundle)
            let sealed = wrapped.encryptedCircleKey.nonce + wrapped.encryptedCircleKey.ciphertext
            if version == 2 {
                try me.sdk.storeFirstCircleKey(
                    circleId: circle, encryptedKey: sealed, senderPublicKey: wrapped.ephemeralPublicKey,
                    keyVersion: version, senderUserId: owner.userId, recipientUserId: me.userId,
                    wrapSignatureHex: wrapped.wrapSignature, confirmedSenderSigningPubkeyHex: owner.signing,
                    sealedCircleName: nil)
            } else {
                try me.sdk.storeCircleKey(
                    circleId: circle, encryptedKey: sealed, senderPublicKey: wrapped.ephemeralPublicKey,
                    keyVersion: version, senderUserId: owner.userId, recipientUserId: me.userId,
                    wrapSignatureHex: wrapped.wrapSignature, senderSigningPubkeyHex: owner.signing)
            }
        }
        let mine = [row(me, statements: [invitedMe]), row(owner, role: .owner), row(y, keys: false)]
        XCTAssertNil(mine[2].keys)
        XCTAssertFalse(mine[2].confirmed)
        let report = try me.sdk.importRefreshRecords(
            circleId: circle, records: [genesis, record(v2), record(v3)], keyChain: links,
            members: mine.map(\.sdkMember), rosterComplete: true, ownHead: nil, memberHeads: [])
        XCTAssertFalse(report.forked)
        XCTAssertEqual(try me.sdk.getActiveVersion(circleId: circle), 3)
        XCTAssertEqual(me.sdk.chainRole(circleId: circle, userId: y.userId), .member, "still counted: carried pending")
        let include = try me.sdk.refreshEligibility(circleId: circle, members: mine.map(\.sdkMember), purpose: .include)
        XCTAssertEqual(include.first { $0.userId == y.userId }?.eligible, false, "never matched")
        let deliver = try me.sdk.refreshEligibility(circleId: circle, members: mine.map(\.sdkMember), purpose: .deliver)
        XCTAssertEqual(deliver.first { $0.userId == y.userId }?.eligible, false, "never handed the circle")
        XCTAssertFalse(report.headConfirmedMembers.contains(y.userId), "never vouched for")
        // Passed as confirmed with no keys, the SDK refuses the whole call.
        let wrong = RecordMember(userId: y.userId, sharingPublicKeyHex: nil, signingPublicKeyHex: nil, confirmed: true,
                                 listed: true, listedRole: .member, statements: [], personConfirmedKeys: false,
                                 serverSaysKeyless: false)
        XCTAssertThrowsError(try me.sdk.refreshEligibility(circleId: circle, members: [wrong], purpose: .include))
    }
}
