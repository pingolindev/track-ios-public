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
import Security
import PingolinTrackSDK
@testable import Track

/// A rotation seals the circle's name again only from the key IN USE, and only
/// while that is the version the rotation replaces. Otherwise it goes without
/// one and the server keeps the stored name (readable through the chain,
/// fixable by a rename). A repair answering a MISATTRIBUTED version seals none:
/// it runs from below, where the key in use is held by the member who
/// misattributed.
///
/// With real devices: the keys, the records, the name sealed under key 3 and
/// the repair built from below are the SDK's own. Swift can't make a
/// MISATTRIBUTED record: the builder refuses one, and the SDK's own test has
/// it (`v2_a_misattributed_version_whose_key_reached_nobody_is_repaired_from_below`).
/// So v3 is REJECTED here as `r2NotAllowed` (a newcomer this device doesn't
/// allow), a real `.repair` answers it, and the app's rules are given v3 as
/// MISATTRIBUTED, as the report would give it.
@MainActor
final class CircleNameSealingTests: XCTestCase {
    private typealias C = Track.CircleManager

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

    private func row(_ party: Party, role: CircleRole = .member, statements: [SignedStatementRecord] = [])
        -> RecordMemberRow {
        RecordMemberRow(userId: party.userId, keys: party.keys, confirmed: true, listed: true, listedRole: role,
                        statements: statements, personConfirmedKeys: false, serverSaysKeyless: false)
    }

    /// `party` takes its copy of `bundle`'s key from `sender`, whom it confirms.
    private func take(_ party: Party, from sender: Party, version: Int32, in bundle: RecordedRotationBundle,
                      first: Bool = false) throws {
        let wrap = try XCTUnwrap(bundle.rotation.memberKeys.first { $0.userId == party.userId }).bundle
        let sealed = wrap.encryptedCircleKey.nonce + wrap.encryptedCircleKey.ciphertext
        if first {
            try party.sdk.storeFirstCircleKey(
                circleId: circle, encryptedKey: sealed, senderPublicKey: wrap.ephemeralPublicKey, keyVersion: version,
                senderUserId: sender.userId, recipientUserId: party.userId, wrapSignatureHex: wrap.wrapSignature,
                confirmedSenderSigningPubkeyHex: sender.signing, sealedCircleName: nil)
        } else {
            try party.sdk.storeCircleKey(
                circleId: circle, encryptedKey: sealed, senderPublicKey: wrap.ephemeralPublicKey, keyVersion: version,
                senderUserId: sender.userId, recipientUserId: party.userId, wrapSignatureHex: wrap.wrapSignature,
                senderSigningPubkeyHex: sender.signing)
        }
    }

    private func pin(_ party: Party, _ others: Party...) throws {
        for other in others {
            _ = try party.sdk.pinMemberKeys(circleId: circle, userId: other.userId,
                                            sharingPubkeyHex: other.sharing, signingPubkeyHex: other.signing)
        }
    }

    private func rows(_ report: RefreshRecordsReport) -> [String] {
        report.versions.map { "\($0.version) \($0.state) \($0.problem)" }
    }

    private func readName(_ party: Party, _ sealed: EncryptedData) -> String? {
        opened(party, sealed)?.text
    }

    private func opened(_ party: Party, _ sealed: EncryptedData) -> OpenedText? {
        try? party.sdk.decryptDataV2Opened(circleId: circle, encryptedData: sealed, fieldTag: "name")
    }

    /// The circle as `party`'s list would hold it: the name the served row's
    /// name opens to here, with the version that opened it.
    private func listedHere(_ served: CircleResponse, by party: Party) -> Track.Circle {
        let name = opened(party, EncryptedData(nonce: served.encryptedName.nonce, ciphertext: served.encryptedName.ciphertext))
        return served.toModel(name: name?.text, nameOpenedUnder: name?.keyVersion)
    }

    private func wire(_ request: RotateKeysRequest) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase  // as APIService encodes
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: encoder.encode(request)) as? [String: Any])
    }

    /// The circle as the list serves it to `me`: its version, its name as
    /// sealed and the version it names for it, and `me`'s own copy's version.
    private func served(keyVersion: Int, name: EncryptedData, nameKeyVersion: Int, myCopy: Int, owner: Party)
        -> CircleResponse {
        CircleResponse(
            id: circle, ownerId: owner.userId, isOwner: true,
            encryptedName: EncryptedBlobResponse(nonce: name.nonce, ciphertext: name.ciphertext),
            dayBucket: 0, memberCount: 4, keyRotationNeeded: nil, keyVersion: keyVersion,
            keyRotationRequestedDayBucket: nil, keyRotationDeadlineDayBucket: nil, keyRotationOverdue: nil,
            encryptedCircleKey: nil, circleKeyNonce: nil, ephemeralPublicKey: nil, wrapSignature: nil,
            senderUserId: nil, memberKeyVersion: myCopy, nameKeyVersion: nameKeyVersion)
    }

    /// What the chain is up to v3: A (the owner, this device) made the circle
    /// and v2 ("Family"), and reads that name at v2. The admin C's v3
    /// lets in a newcomer A's list doesn't allow and names the circle
    /// "Renamed at v3"; `v3ReachesA`: whether C wrapped v3's key to A.
    private struct Chain {
        let a: Party, b: Party, c: Party, newcomer: Party
        let genesis: SignedRefreshRecord
        let v2: RecordedRotationBundle, v3: RecordedRotationBundle
        let aView: [RecordMemberRow], bView: [RecordMemberRow]
        let aReport: RefreshRecordsReport
    }

    private func chain(v3ReachesA: Bool) throws -> Chain {
        let (a, b, c, newcomer) = (Party(), Party(), Party(), Party())
        let genesis = try a.sdk.prepareRecordedCircleCreation(creatorUserId: a.userId, circleId: circle).genesis
        let invitedB = try invitation(by: a, of: b, atVersion: 1)
        let invitedC = try invitation(by: a, of: c, atVersion: 1)
        let aListed = [row(a, role: .owner), row(b, statements: [invitedB]), row(c, role: .admin, statements: [invitedC])]
        let v2 = try a.sdk.prepareRecordedRotation(
            circleId: circle, senderUserId: a.userId, kind: .rotation, planned: [
                PlannedEntry(userId: a.userId, state: .included, role: nil),
                PlannedEntry(userId: b.userId, state: .included, role: nil),
                PlannedEntry(userId: c.userId, state: .included, role: .admin),
            ], members: aListed.map(\.sdkMember), rosterComplete: true, currentCircleNamePlaintext: "Family")
        links.append(try XCTUnwrap(v2.rotation.keyChainLink))
        XCTAssertEqual(rows(try a.sdk.importRefreshRecords(
            circleId: circle, records: [v2.refreshRecord], keyChain: links, members: aListed.map(\.sdkMember),
            rosterComplete: true, ownHead: nil, memberHeads: [])), ["2 accepted none"])

        // A reads the name at v2, under the key in use.
        let atV2 = try XCTUnwrap(opened(a, v2.rotation.encryptedName))
        XCTAssertEqual(atV2.text, "Family")
        XCTAssertEqual(atV2.keyVersion, 2)

        // The admin C: v2 from A, then v3 with a newcomer it invited itself.
        try pin(c, a)
        try take(c, from: a, version: 2, in: v2, first: true)
        let invitedNewcomer = try invitation(by: c, of: newcomer, atVersion: 2)
        let cListed = [row(c, role: .admin, statements: [invitedC]), row(a, role: .owner),
                       row(b, statements: [invitedB]), row(newcomer, statements: [invitedNewcomer])]
        _ = try c.sdk.importRefreshRecords(
            circleId: circle, records: [genesis, v2.refreshRecord], keyChain: links, members: cListed.map(\.sdkMember),
            rosterComplete: true, ownHead: nil, memberHeads: [])
        let v3 = try c.sdk.prepareRecordedRotation(
            circleId: circle, senderUserId: c.userId, kind: .rotation, planned: [
                PlannedEntry(userId: c.userId, state: .included, role: nil),
                PlannedEntry(userId: a.userId, state: v3ReachesA ? .included : .pending, role: nil),
                PlannedEntry(userId: b.userId, state: .included, role: nil),
                PlannedEntry(userId: newcomer.userId, state: .included, role: nil),
            ], members: cListed.map(\.sdkMember), rosterComplete: true, currentCircleNamePlaintext: "Renamed at v3")
        links.append(try XCTUnwrap(v3.rotation.keyChainLink))
        XCTAssertEqual(v3.rotation.memberKeys.contains(where: { $0.userId == a.userId }), v3ReachesA)

        // A: v3's record (and its key, if it came), rejected here: the newcomer
        // is listed and confirmed, and no statement lets them in here
        // (`r2NotAllowed`).
        try pin(a, c)
        if v3ReachesA { try take(a, from: c, version: 3, in: v3) }
        let aView = aListed + [row(newcomer)]
        let aReport = try a.sdk.importRefreshRecords(
            circleId: circle, records: [v3.refreshRecord], keyChain: links, members: aView.map(\.sdkMember),
            rosterComplete: true, ownHead: nil, memberHeads: [])
        XCTAssertEqual(rows(aReport), ["3 rejected r2NotAllowed"])
        XCTAssertEqual(a.sdk.newestHeldVersion(circleId: circle), v3ReachesA ? 3 : 2)
        XCTAssertEqual(try a.sdk.getActiveVersion(circleId: circle), 2, "v3 isn't sealed under here")

        // B, a member: v2 from A, v3 from C, their records.
        try pin(b, a, c)
        try take(b, from: a, version: 2, in: v2, first: true)
        try take(b, from: c, version: 3, in: v3)
        let bView = [row(b, statements: [invitedB]), row(a, role: .owner), row(c, role: .admin, statements: [invitedC]),
                     row(newcomer)]
        _ = try b.sdk.importRefreshRecords(
            circleId: circle, records: [genesis, v2.refreshRecord, v3.refreshRecord], keyChain: links,
            members: bView.map(\.sdkMember), rosterComplete: true, ownHead: nil, memberHeads: [])
        return Chain(a: a, b: b, c: c, newcomer: newcomer, genesis: genesis, v2: v2, v3: v3, aView: aView,
                     bView: bView, aReport: aReport)
    }

    /// v3 as the report would give it to the app's rules: MISATTRIBUTED.
    private func misattributed(_ chain: Chain) throws -> RecordVersionStatus {
        let status = RecordVersionStatus(version: 3, state: .rejected, problem: .misattributed, notAllowed: [],
                                         unmatchedEntries: 0, namedListed: chain.aReport.tipNamedListed)
        return try XCTUnwrap(RecordedRotation.repairable([status]).first)
    }

    /// A's repair: planned by the app's planner, built by the real builder.
    private func aRepairs(_ chain: Chain, sealing name: C.NameToSeal) throws -> RecordedRotationBundle {
        let (a, members) = (chain.a, chain.aView.map(\.sdkMember))
        let includable = Set(try a.sdk.refreshEligibility(circleId: circle, members: members, purpose: .include)
            .filter(\.eligible).map(\.userId))
        var counted: [String: CircleRole] = [:]
        for party in [chain.a, chain.b, chain.c, chain.newcomer] {
            counted[party.userId] = a.sdk.chainRole(circleId: circle, userId: party.userId)
        }
        let plan = RecordedRotation.rotationPlan(
            me: a.userId, roster: C.listed(chain.aView), includable: includable, blocked: [],
            counted: counted.compactMapValues { $0 }, removing: [], rejectedIncluded: Set(chain.aReport.tipNamedListed))
        return try a.sdk.prepareRecordedRotation(
            circleId: circle, senderUserId: a.userId, kind: .repair, planned: plan, members: members,
            rosterComplete: true, currentCircleNamePlaintext: name.plaintext)
    }

    /// B takes A's v4 with its record, and reads its name.
    private func bReads(_ chain: Chain, _ v4: RecordedRotationBundle) throws -> String? {
        var served = links
        served.append(try XCTUnwrap(v4.rotation.keyChainLink))
        try take(chain.b, from: chain.a, version: 4, in: v4)
        let report = try chain.b.sdk.importRefreshRecords(
            circleId: circle, records: [v4.refreshRecord], keyChain: served, members: chain.bView.map(\.sdkMember),
            rosterComplete: true, ownHead: nil, memberHeads: [])
        XCTAssertEqual(rows(report), ["4 accepted none"])
        XCTAssertEqual(try chain.b.sdk.getActiveVersion(circleId: circle), 4)
        return readName(chain.b, v4.rotation.encryptedName)
    }

    /// v3's key AND its name reached nobody here (A was left pending): the
    /// circle is locked on A. The repair isn't held back by the name, runs from
    /// below at once, and seals none: the request leaves the name out, and the
    /// server keeps the stored one.
    func testTheRepairOfAMisattributedVersionSealsNoName() throws {
        let chain = try chain(v3ReachesA: false)
        let a = chain.a

        let listed = served(keyVersion: 3, name: chain.v3.rotation.encryptedName, nameKeyVersion: 3, myCopy: 2, owner: a)
        let circleHere = listedHere(listed, by: a)
        XCTAssertTrue(C.isShownLocked(nameOpened: circleHere.readableName != nil, listed))
        XCTAssertTrue(circleHere.isLocked)
        XCTAssertNil(circleHere.readableName, "v3's name reached nobody here either")
        XCTAssertNil(circleHere.nameOpenedUnder)

        // The app's rules on v3 as MISATTRIBUTED: never held back by the name,
        // from below at once, and no name.
        let due = try misattributed(chain)
        let mode = C.rotationMode(.recorded, ownerOrAdmin: true, repairDue: true)
        XCTAssertEqual(mode, .recorded(.repair))
        let holdsKeyInUse = C.holdsCurrentKey(
            localActiveVersion: Int(try a.sdk.getActiveVersion(circleId: circle)), circleKeyVersion: 3)
            && !a.sdk.isBehind(circleId: circle)
        XCTAssertFalse(holdsKeyInUse, "v2 in use, the circle at v3")
        XCTAssertFalse(C.nameHoldsBack(holds: holdsKeyInUse, mode: mode, answering: due.problem))
        XCTAssertTrue(C.holdsWhatARepairNeeds(held: 2, circleKeyVersion: 3, answering: due.problem))
        XCTAssertTrue(C.repairsMisattribution(mode: mode, answering: due.problem))
        let name = try XCTUnwrap(C.nameToSeal(
            readable: circleHere.readableName, sealable: C.sealableName(circleHere, crypto: a.sdk),
            ejectingFromBelow: false, holds: holdsKeyInUse, misattributionRepair: true))
        XCTAssertEqual(name, .keepStored)
        // With v3's real problem (`r2NotAllowed`) the same state
        // stays held back: by the name, and by v3's key, which a
        // repair of it needs and A lacks.
        let r2 = try XCTUnwrap(chain.aReport.versions.first)
        XCTAssertFalse(C.holdsWhatARepairNeeds(held: 2, circleKeyVersion: 3, answering: r2.problem))
        let holdsForR2 = C.holdsForTheName(mode: mode, keyInUse: holdsKeyInUse, repairNeeds: false)
        XCTAssertFalse(holdsForR2)
        XCTAssertTrue(C.nameHoldsBack(holds: holdsForR2, mode: mode, answering: r2.problem))
        XCTAssertNil(C.nameToSeal(readable: nil, sealable: nil, ejectingFromBelow: false, holds: holdsForR2),
                     "lacking the version it answers: it waits")

        // The real repair, kind .repair, from below: v4 linked down to v2, and
        // the request leaves the name out (never null).
        let v4 = try aRepairs(chain, sealing: name)
        XCTAssertEqual(v4.rotation.newKeyVersion, 4)
        XCTAssertEqual(v4.rotation.keyChainLink?.toVersion, 2, "linked from below v3, at once")
        let request = C.rotateKeysRequest(expectedKeyVersion: 3, change: C.RecordedChange(
            bundle: v4, kind: .repair, pendingMembers: [chain.newcomer.userId], removals: [], roleChanges: [:],
            repairing: due, name: name))
        XCTAssertNil(request.encryptedName)
        XCTAssertFalse(try wire(request).keys.contains("encrypted_name"), "left out, never null")
        XCTAssertEqual(try wire(request)["expected_key_version"] as? Int, 3)
        // B, a member, takes v4 with its record; the name it seals is never
        // sent, and the server keeps the stored one.
        _ = try bReads(chain, v4)
    }

    /// v3's key DID reach A: A reads the misattributed record's name, under v3,
    /// which isn't the version A seals under. Neither the repair nor any other
    /// change seals it; none waits for it either.
    func testOnADeviceHoldingV3sKeyItsNameIsNeverSealed() throws {
        let chain = try chain(v3ReachesA: true)
        let a = chain.a

        let listed = served(keyVersion: 3, name: chain.v3.rotation.encryptedName, nameKeyVersion: 3, myCopy: 3, owner: a)
        let circleHere = listedHere(listed, by: a)
        XCTAssertEqual(circleHere.readableName, "Renamed at v3", "the misattributed record's name reads here")
        XCTAssertEqual(circleHere.nameOpenedUnder, 3)
        XCTAssertFalse(a.sdk.isCurrentKeyVersion(circleId: circle, keyVersion: 3), "v3 was rejected here")
        XCTAssertNil(C.sealableName(circleHere, crypto: a.sdk))

        let due = try misattributed(chain)
        let mode = C.rotationMode(.recorded, ownerOrAdmin: true, repairDue: true)
        XCTAssertFalse(C.nameHoldsBack(holds: false, mode: mode, answering: due.problem))
        XCTAssertTrue(C.holdsWhatARepairNeeds(held: 3, circleKeyVersion: 3, answering: due.problem))
        XCTAssertEqual(C.nameToSeal(readable: circleHere.readableName, sealable: nil, ejectingFromBelow: false,
                                    holds: false, misattributionRepair: true), .keepStored)
        XCTAssertEqual(C.nameToSeal(readable: circleHere.readableName, sealable: nil, ejectingFromBelow: false,
                                    holds: false),
                       .keepStored, "any other change omits it too, and never waits for it")

        let v4 = try aRepairs(chain, sealing: .keepStored)
        XCTAssertEqual(v4.rotation.newKeyVersion, 4)
        XCTAssertEqual(v4.rotation.keyChainLink?.toVersion, 3, "holding v3, which included it: linked to v3")
    }

    /// A HOLDS v3 but rejected it, for its real problem (`r2NotAllowed`, not
    /// a misattribution). Its key in use is v2 by definition, and the SDK
    /// counts it behind, so judged by the key in use the name would hold every
    /// such repair back for good. Judged by the version it answers, which A
    /// holds, it goes: the name never holds it back, the stored name is kept
    /// whether A reads it or not (never sealed again), the real builder builds
    /// the repair, and B takes it.
    func testARepairOfAVersionHeldButRejectedForR2IsAdmittedAndBuilt() throws {
        let chain = try chain(v3ReachesA: true)
        let a = chain.a
        let r2 = try XCTUnwrap(chain.aReport.versions.first)
        XCTAssertEqual(r2.problem, .r2NotAllowed, "the report's own problem")
        XCTAssertFalse(C.repairsMisattribution(mode: .recorded(.repair), answering: r2.problem))

        let mode = C.rotationMode(.recorded, ownerOrAdmin: true, repairDue: true)
        XCTAssertEqual(mode, .recorded(.repair))
        let keyInUse = C.holdsCurrentKey(
            localActiveVersion: Int(try a.sdk.getActiveVersion(circleId: circle)), circleKeyVersion: 3)
            && !a.sdk.isBehind(circleId: circle)
        XCTAssertFalse(keyInUse, "v2 in use, v3 rejected here: a repair never holds the key in use")
        XCTAssertTrue(a.sdk.isBehind(circleId: circle))
        XCTAssertEqual(a.sdk.newestHeldVersion(circleId: circle), 3)
        let repairNeeds = C.holdsWhatARepairNeeds(
            held: a.sdk.newestHeldVersion(circleId: circle).map { Int($0) }, circleKeyVersion: 3, answering: r2.problem)
        XCTAssertTrue(repairNeeds, "A holds v3, the version it answers")
        let holds = C.holdsForTheName(mode: mode, keyInUse: keyInUse, repairNeeds: repairNeeds)
        XCTAssertTrue(holds)
        XCTAssertFalse(C.nameHoldsBack(holds: holds, mode: mode, answering: r2.problem), "admitted")
        XCTAssertTrue(C.nameHoldsBack(holds: keyInUse, mode: mode, answering: r2.problem),
                      "control: judged by the key in use it waited for good")

        // The name: never sealed by a repair (sealing v2, replacing v3), kept
        // whether A reads it or not.
        let listed = served(keyVersion: 3, name: chain.v3.rotation.encryptedName, nameKeyVersion: 3, myCopy: 3, owner: a)
        let circleHere = listedHere(listed, by: a)
        XCTAssertNil(C.sealableName(circleHere, crypto: a.sdk))
        let name = try XCTUnwrap(C.nameToSeal(readable: circleHere.readableName, sealable: C.sealableName(circleHere, crypto: a.sdk),
                                              ejectingFromBelow: false, holds: holds))
        XCTAssertEqual(name, .keepStored)
        XCTAssertEqual(C.nameToSeal(readable: nil, sealable: nil, ejectingFromBelow: false, holds: holds), .keepStored,
                       "unreadable: the repair goes without one")

        // The repair, by the real builder: v4, the request leaves the name out,
        // and B takes it with its record.
        let v4 = try aRepairs(chain, sealing: name)
        XCTAssertEqual(v4.rotation.newKeyVersion, 4)
        let request = C.rotateKeysRequest(expectedKeyVersion: 3, change: C.RecordedChange(
            bundle: v4, kind: .repair, pendingMembers: [], removals: [], roleChanges: [:], repairing: r2, name: name))
        XCTAssertNil(request.encryptedName)
        XCTAssertFalse(try wire(request).keys.contains("encrypted_name"), "left out, never null")
        _ = try bReads(chain, v4)
    }

    /// A recorded circle whose chain holds a NEWER version than the accepted
    /// one (delivered, not accepted). A name sealed under that newer version
    /// is never sealed again, even when the list names the accepted version;
    /// a name under the accepted one is.
    func testADeliveredButNotAcceptedVersionsNameIsNeverSealed() throws {
        let chain = try chain(v3ReachesA: true)
        let a = chain.a
        XCTAssertEqual(a.sdk.newestHeldVersion(circleId: circle), 3, "v3 delivered")
        XCTAssertEqual(try a.sdk.getActiveVersion(circleId: circle), 2, "v2 in use")

        let underV3 = listedHere(served(keyVersion: 2, name: chain.v3.rotation.encryptedName, nameKeyVersion: 2,
                                        myCopy: 2, owner: a), by: a)
        XCTAssertEqual(underV3.nameOpenedUnder, 3)
        XCTAssertNil(C.sealableName(underV3, crypto: a.sdk), "the newest held is not the key in use")

        let underV2 = listedHere(served(keyVersion: 2, name: chain.v2.rotation.encryptedName, nameKeyVersion: 2,
                                        myCopy: 2, owner: a), by: a)
        XCTAssertEqual(underV2.nameOpenedUnder, 2)
        XCTAssertEqual(C.sealableName(underV2, crypto: a.sdk), "Family")
        XCTAssertEqual(C.nameToSeal(readable: underV2.readableName, sealable: C.sealableName(underV2, crypto: a.sdk),
                                    ejectingFromBelow: false, holds: true), .name("Family"))

        // From below: the list names v3, the key in use is v2. The v2 name is
        // not the version the change replaces: none.
        let fromBelow = listedHere(served(keyVersion: 3, name: chain.v2.rotation.encryptedName, nameKeyVersion: 2,
                                          myCopy: 3, owner: a), by: a)
        XCTAssertEqual(fromBelow.nameOpenedUnder, 2)
        XCTAssertNil(C.sealableName(fromBelow, crypto: a.sdk))
    }

    /// A circle with no records (legacy): this device holds v1 and v2, and
    /// seals under v2. A name a v1 holder sealed opens here, and is not sealed
    /// again; a v2 name is. The legacy requests carry the name only then.
    func testALegacyRotationSealsANameOnlyFromTheKeyInUse() throws {
        let (owner, me, leftOut) = (Party(), Party(), Party())
        for member in [me, leftOut] { try pin(member, owner) }
        let creation = try owner.sdk.prepareCircleCreation()
        try owner.sdk.finalizeCircleCreation(tempCircleId: creation.tempCircleId, realCircleId: circle)
        func give(_ member: Party, _ bundle: MemberKeyBundle, _ version: Int32) throws {
            try member.sdk.storeCircleKey(
                circleId: circle, encryptedKey: bundle.encryptedCircleKey.nonce + bundle.encryptedCircleKey.ciphertext,
                senderPublicKey: bundle.ephemeralPublicKey, keyVersion: version, senderUserId: owner.userId,
                recipientUserId: member.userId, wrapSignatureHex: bundle.wrapSignature,
                senderSigningPubkeyHex: owner.signing)
        }
        for member in [me, leftOut] {
            try give(member, try owner.sdk.wrapCircleKeyForMemberFull(
                circleId: circle, memberPublicKeyHex: member.sharing, senderUserId: owner.userId,
                recipientUserId: member.userId, recipientSigningPubkeyHex: member.signing), 1)
        }
        let v2 = try owner.sdk.prepareKeyRotation(
            circleId: circle, senderUserId: owner.userId, memberUserIds: [owner.userId, me.userId],
            memberPublicKeysHex: [owner.sharing, me.sharing], memberSigningPubkeysHex: [owner.signing, me.signing],
            currentCircleNamePlaintext: "Family")
        try give(me, try XCTUnwrap(v2.memberKeys.first { $0.userId == me.userId }).bundle, 2)
        XCTAssertTrue(me.sdk.isCurrentKeyVersion(circleId: circle, keyVersion: 2))

        let planted = try leftOut.sdk.encryptDataV2(circleId: circle, plaintext: "Planted", fieldTag: "name")
        let atV1 = listedHere(served(keyVersion: 2, name: planted, nameKeyVersion: 2, myCopy: 2, owner: owner), by: me)
        XCTAssertEqual(atV1.readableName, "Planted", "it shows")
        XCTAssertEqual(atV1.nameOpenedUnder, 1)
        XCTAssertNil(C.sealableName(atV1, crypto: me.sdk), "never carried into a new key")
        XCTAssertNil(C.legacyEncryptedName(sealable: nil, sealed: v2.encryptedName))

        let atV2 = listedHere(served(keyVersion: 2, name: v2.encryptedName, nameKeyVersion: 2, myCopy: 2, owner: owner),
                              by: me)
        XCTAssertEqual(C.sealableName(atV2, crypto: me.sdk), "Family")
        let sent = try XCTUnwrap(C.legacyEncryptedName(sealable: "Family", sealed: v2.encryptedName))
        XCTAssertEqual(sent.ciphertext, v2.encryptedName.ciphertext)
    }

    // MARK: - The rules, pure

    /// Behind, only a misattribution's repair goes; holding the key in use,
    /// a name holds nothing back.
    func testOnlyAMisattributionsRepairGoesPastALockedName() {
        let problems: [RecordProblem] = [.misattributed, .r2NotAllowed, .r2UnmatchedEntry, .role, .removal, .signature]
        let modes: [C.RotationMode] = [.recorded(.repair), .recorded(.rotation), .transition, .legacy, .wait]
        for mode in modes {
            for problem in problems {
                let admitted = mode == .recorded(.repair) && problem == .misattributed
                XCTAssertEqual(C.repairsMisattribution(mode: mode, answering: problem), admitted, "\(mode) \(problem)")
                XCTAssertEqual(C.nameHoldsBack(holds: false, mode: mode, answering: problem), !admitted,
                               "behind: \(mode) \(problem)")
                XCTAssertFalse(C.nameHoldsBack(holds: true, mode: mode, answering: problem),
                               "the key in use held: \(mode) \(problem)")
            }
            XCTAssertTrue(C.nameHoldsBack(holds: false, mode: mode, answering: nil), "nothing answered: \(mode)")
        }
    }

    func testTheNameARecordedChangeSeals() {
        for readable in [nil, "Family"] as [String?] {
            for sealable in [nil, "Family"] as [String?] {
                for ejecting in [false, true] {
                    for held in [false, true] {
                        XCTAssertEqual(C.nameToSeal(readable: readable, sealable: sealable, ejectingFromBelow: ejecting,
                                                    holds: held, misattributionRepair: true), .keepStored,
                                       "a misattribution's repair seals none")
                    }
                }
            }
        }
        for held in [false, true] {
            XCTAssertEqual(C.nameToSeal(readable: "Family", sealable: "Family", ejectingFromBelow: false,
                                        holds: held), .name("Family"))
            XCTAssertEqual(C.nameToSeal(readable: "Planted", sealable: nil, ejectingFromBelow: false, holds: held),
                           .keepStored, "read only under another version: omitted, never waited for")
            XCTAssertEqual(C.nameToSeal(readable: nil, sealable: nil, ejectingFromBelow: true, holds: held),
                           .keepStored)
        }
        // Unreadable: with the key in use held the change goes without
        // it; behind, it waits.
        XCTAssertEqual(C.nameToSeal(readable: nil, sealable: nil, ejectingFromBelow: false, holds: true),
                       .keepStored)
        XCTAssertNil(C.nameToSeal(readable: nil, sealable: nil, ejectingFromBelow: false, holds: false),
                     "behind: the change waits")
    }

    func testANameIsSealableOnlyUnderTheKeyInUseAndTheVersionReplaced() {
        let current: (Int32) -> Bool = { $0 == 2 }
        XCTAssertEqual(C.sealableName(readable: "Family", openedUnder: 2, isCurrent: current,
                                      sealingVersion: 2, replacedVersion: 2), "Family")
        XCTAssertNil(C.sealableName(readable: "Family", openedUnder: 1, isCurrent: current,
                                    sealingVersion: 2, replacedVersion: 2), "a retired version")
        XCTAssertNil(C.sealableName(readable: "Family", openedUnder: 3, isCurrent: current,
                                    sealingVersion: 2, replacedVersion: 2), "a newer one not accepted")
        XCTAssertNil(C.sealableName(readable: "Family", openedUnder: 2, isCurrent: current,
                                    sealingVersion: 2, replacedVersion: 3), "from below")
        XCTAssertNil(C.sealableName(readable: "Family", openedUnder: nil, isCurrent: current,
                                    sealingVersion: 2, replacedVersion: 2), "no version known")
        XCTAssertNil(C.sealableName(readable: nil, openedUnder: 2, isCurrent: current,
                                    sealingVersion: 2, replacedVersion: 2), "the placeholder")
        XCTAssertNil(C.sealableName(readable: "Family", openedUnder: 2, isCurrent: current,
                                    sealingVersion: nil, replacedVersion: 2), "no key in use")
    }

    // MARK: - The kept names' store is gone

    func testWhatTheRetiredStoreLeftIsPurged() throws {
        let keychain = KeychainService.shared
        let account = UUID().uuidString.lowercased(), other = UUID().uuidString.lowercased()
        try keychain.save("Family", item: "circle_name_read_\(account)|\(circle)")
        try keychain.save("Work", item: "circle_name_read_\(other)|\(circle)")
        try keychain.save("kept", item: "g_purge_control_\(account)")
        defer { keychain.delete(item: "g_purge_control_\(account)") }
        XCTAssertTrue(Set(keychain.items(withPrefix: "circle_name_read_")).isSuperset(of: [
            "circle_name_read_\(account)|\(circle)", "circle_name_read_\(other)|\(circle)"]))

        keychain.purgeRetiredItems()
        XCTAssertEqual(keychain.items(withPrefix: "circle_name_read_"), [], "no item with the prefix remains")
        XCTAssertEqual(keychain.items(withPrefix: "g_purge_control_"), ["g_purge_control_\(account)"],
                       "nothing else goes")
        keychain.purgeRetiredItems()  // idempotent
        XCTAssertEqual(keychain.items(withPrefix: "circle_name_read_"), [])
    }

    // MARK: - A name nobody opens

    /// Any member can plant a name nobody opens (rotate-keys keeps a stored
    /// name or takes one). On a device holding the key in use, the circle shows
    /// locked, yet a rotation and an eject go: nothing holds them back, and they
    /// go without a name, so the server keeps the stored one. Behind, both wait.
    func testANameNobodyOpensNeverHoldsAKeyChangeBack() throws {
        let owner = Party()
        let creation = try owner.sdk.prepareCircleCreation()
        try owner.sdk.finalizeCircleCreation(tempCircleId: creation.tempCircleId, realCircleId: circle)
        let stranger = Party().sdk
        let strangers = try stranger.prepareCircleCreation()
        try stranger.finalizeCircleCreation(tempCircleId: strangers.tempCircleId, realCircleId: circle)
        let planted = try stranger.encryptDataV2(circleId: circle, plaintext: "Planted", fieldTag: "name")

        let listed = served(keyVersion: 1, name: planted, nameKeyVersion: 1, myCopy: 1, owner: owner)
        let circleHere = listedHere(listed, by: owner)
        XCTAssertNil(circleHere.readableName, "the planted name doesn't open")
        XCTAssertTrue(circleHere.isLocked, "and the circle shows locked")
        let holdsKeyInUse = C.holdsCurrentKey(
            localActiveVersion: Int(try owner.sdk.getActiveVersion(circleId: circle)), circleKeyVersion: listed.keyVersion)
            && !owner.sdk.isBehind(circleId: circle)
        XCTAssertTrue(holdsKeyInUse, "the key in use is held")

        for mode in [C.RotationMode.recorded(.rotation), .transition, .legacy] {
            XCTAssertFalse(C.nameHoldsBack(holds: holdsKeyInUse, mode: mode, answering: nil), "\(mode)")
        }
        for ejecting in [false, true] {
            let name = try XCTUnwrap(C.nameToSeal(readable: circleHere.readableName, sealable: nil,
                                                  ejectingFromBelow: ejecting, holds: holdsKeyInUse))
            XCTAssertEqual(name, .keepStored)
            XCTAssertEqual(name.plaintext, "", "no name is sealed, so none is sent")
        }
        // Behind (the circle moved to v2 without this device): both wait.
        let behind = served(keyVersion: 2, name: planted, nameKeyVersion: 2, myCopy: 1, owner: owner)
        let heldThen = C.holdsCurrentKey(
            localActiveVersion: Int(try owner.sdk.getActiveVersion(circleId: circle)), circleKeyVersion: behind.keyVersion)
        XCTAssertFalse(heldThen)
        XCTAssertTrue(C.nameHoldsBack(holds: heldThen, mode: .recorded(.rotation), answering: nil))
        XCTAssertNil(C.nameToSeal(readable: nil, sealable: nil, ejectingFromBelow: false, holds: heldThen))
    }

    /// The one helper both waits key off, and the line the manual rotation
    /// logs when it goes without the name: the circle id, never the name.
    func testHoldingTheKeyInUseIsWiredIn() throws {
        let circles = try source("App/Managers/CircleManager.swift")
        XCTAssertTrue(circles.contains("""
                func holdsKeyInUse(_ circleId: String) -> Bool {
                    holdsCurrentVersion(for: circleId) && !isBehind(circleId)
                }
            """))
        // The key in use is what any change but a repair needs held; a
        // repair, the version it answers (`holdsForTheName`).
        // RepairNameGateTests pins the rest of the wiring.
        XCTAssertTrue(circles.contains(
            "Self.nameHoldsBack(holds: holdsForTheName(circle, mode: mode, due: due), mode: mode,"))
        XCTAssertTrue(circles.contains("            mode: mode, keyInUse: holdsKeyInUse(circle.id),\n"))
        XCTAssertTrue(circles.contains("ejectingFromBelow: ejecting != nil && ejectsFromBelow(circle), "
                                       + "holds: holdsForTheName(circle, mode: mode, due: due),"))
        XCTAssertFalse(circles.contains("nameHoldsBack(locked:"))
        XCTAssertFalse(circles.contains("nameHoldsBack(holdsKeyInUse:"))
        XCTAssertTrue(circles.contains("""
                    if circle.readableName == nil {
                        // A name that doesn't open holds nothing back while the key in use
                        // is held: the change goes without one.
                        print("[Track] rotateCircleKey: circle \\(circleId): the name doesn't open here; the stored one stays")
                    }
            """))
    }

    // MARK: - Wiring

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func body(of start: String, until end: String, in text: String) throws -> String {
        let from = try XCTUnwrap(text.range(of: start), start)
        let to = try XCTUnwrap(text.range(of: end, range: from.upperBound..<text.endIndex), end)
        return String(text[from.lowerBound..<to.lowerBound])
    }

    /// The lock checks admit exactly this repair, each on the repair entry the
    /// change is built on; the list reads which version opened a name; every
    /// rotation seals only a sealable name; the store is gone and purged.
    func testTheChecksAndTheNameRuleAreWiredIn() throws {
        let circles = try source("App/Managers/CircleManager.swift")
        XCTAssertFalse(circles.contains("!$0.isLocked"), "the sweep")
        let owed = try body(of: "    private func rotateOwedNow(_ circleId: String) {", until: "\n    }\n", in: circles)
        XCTAssertTrue(owed.contains("recordedRotationDue(circle), !nameHoldsBack(circle, due: repairsDue[CanonicalId.key(circleId)]),"))
        XCTAssertFalse(owed.contains("isLocked"))
        let rotate = try body(of: "    func rotateCircleKey(for circleId: String) async throws {", until: "    // MARK: - Errors",
                              in: circles)
        XCTAssertTrue(rotate.contains("        let due = repairsDue[CanonicalId.key(circleId)]\n        if nameHoldsBack(circle, due: due) {\n"))
        XCTAssertTrue(rotate.contains("        var mode = rotationMode(for: circle, due: due)\n"))
        XCTAssertEqual(rotate.components(separatedBy: "repairsDue[").count - 1, 1, "read once")
        XCTAssertFalse(rotate.contains("isLocked"))
        let eject = try body(of: "    func removeMember(from circleId: String, userId: String) async throws {",
                             until: "    func removesWithoutNewKey(_ circleId: String) -> Bool {", in: circles)
        XCTAssertTrue(eject.contains("        let due = repairsDue[CanonicalId.key(circleId)]\n        var mode = rotationMode(for: circle, due: due)\n"))
        XCTAssertTrue(eject.contains("if circle.isLocked && !ejectsFromBelow(circle) {"), "the eject keeps its own rule")
        let prepare = try body(of: "    private func prepareRecordedChange(", until: "    private func recordedChangeTaken(", in: circles)
        XCTAssertTrue(prepare.contains("if recordedKind == .repair { repairing = due }"))
        XCTAssertFalse(prepare.contains("repairsDue["), "the entry the admission read")

        // The list: which version opened the name.
        let load = try body(of: "    func loadCircles(light: Bool = false) async throws {",
                            until: "    func setActiveCircle(", in: circles)
        XCTAssertTrue(load.contains("return try cryptoManager.decryptDataV2Opened(circleId: response.id, encryptedData: blob, fieldTag: \"name\")"))
        XCTAssertTrue(load.contains("            return response.toModel(name: decryptedName, lockReason: lockReason,\n"
                                    + "                                    nameOpenedUnder: openedName?.keyVersion)\n"))
        // Both legacy paths seal and send only a sealable name.
        for path in [eject, rotate] {
            XCTAssertTrue(path.contains("        let sealable = sealableName(circle)\n"))
            XCTAssertTrue(path.contains("            currentCircleNamePlaintext: sealable ?? \"\"\n"))
            XCTAssertTrue(path.contains("encryptedName: Self.legacyEncryptedName(sealable: sealable, sealed: bundle.encryptedName),"))
            XCTAssertFalse(path.contains("currentCircleNamePlaintext: circle.name"))
        }

        // The store: gone, and what it left purged at every launch and sign-in.
        for path in ["App/Managers/CircleManager.swift", "App/Managers/AuthManager.swift", "App/TrackApp.swift",
                     "App/Services/KeychainService.swift", "App/Models/Models.swift"] {
            XCTAssertFalse(try source(path).contains("CircleNamesReadHere"), path)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App/Services/CircleNamesReadHere.swift").path), "the type is gone")
        XCTAssertFalse(circles.contains("keepNamesReadHere"))
        let auth = try source("App/Managers/AuthManager.swift")
        XCTAssertTrue(auth.contains("        KeychainService.shared.purgeRetiredItems()\n"
                                    + "        SignInTidy.run(signedIn: me, typedEmail: typedEmail)\n"), "at a sign-in")
        let app = try source("App/TrackApp.swift")
        let setup = try body(of: "    private func setupApp() {", until: "\n    }\n", in: app)
        XCTAssertTrue(setup.contains("        KeychainService.shared.purgeRetiredItems()\n"), "at every launch")
        let keychain = try source("App/Services/KeychainService.swift")
        XCTAssertTrue(keychain.contains("    static let retiredItemPrefixes = [\"circle_name_read_\"]\n"))
        let converters = try source("App/Services/APIService+Converters.swift")
        XCTAssertTrue(converters.contains("            nameKeyVersion: nameKeyVersion,\n"))
    }
}
