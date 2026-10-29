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

/// Behind is the device's own knowledge: while this device knows it is behind
/// on a circle (`isBehind`), nothing new is sealed or handed over there,
/// whatever key version the server lists; SOS still goes out.
final class IsBehindTests: XCTestCase {
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

    private func invitation(by signer: Party, of subject: Party) throws -> SignedStatementRecord {
        let signed = try signer.sdk.signMembershipStatement(statement: MembershipStatement(
            kind: .invitationToAccount, circleId: circle, statementId: UUID().uuidString.lowercased(),
            signerUserId: signer.userId, issuedAt: now, expiresAt: now + 604_800, atVersion: 1,
            subjectUserId: subject.userId, subjectSharingPublicKeyHex: subject.sharing,
            subjectSigningPublicKeyHex: subject.signing, subjectEmail: nil))
        return SignedStatementRecord(statementHex: signed.statementHex, signatureHex: signed.signatureHex)
    }

    private func row(_ party: Party, role: CircleRole = .member, statements: [SignedStatementRecord] = []) -> RecordMemberRow {
        RecordMemberRow(userId: party.userId, keys: party.keys, confirmed: true, listed: true, listedRole: role,
                        statements: statements, personConfirmedKeys: false, serverSaysKeyless: false)
    }

    /// One rotation by the owner's device, taken back by it once the server took it.
    private func ownerRotates(_ owner: Party, planned: [PlannedEntry], members: [RecordMemberRow]) throws
        -> RecordedRotationBundle {
        let bundle = try owner.sdk.prepareRecordedRotation(
            circleId: circle, senderUserId: owner.userId, kind: .rotation, planned: planned,
            members: members.map(\.sdkMember), rosterComplete: true, currentCircleNamePlaintext: "Family")
        links.append(try XCTUnwrap(bundle.rotation.keyChainLink))
        _ = try owner.sdk.importRefreshRecords(
            circleId: circle, records: [bundle.refreshRecord], keyChain: links, members: members.map(\.sdkMember),
            rosterComplete: true, ownHead: nil, memberHeads: [])
        return bundle
    }

    /// The gate's rules: behind refuses, whatever else holds.
    func testNothingIsSealedOrHandedOverWhileBehind() {
        XCTAssertTrue(CircleManager.holdsCurrentKey(currentVersion: true, rotationStepDue: false, behind: false))
        XCTAssertFalse(CircleManager.holdsCurrentKey(currentVersion: true, rotationStepDue: false, behind: true))
        XCTAssertFalse(CircleManager.holdsCurrentKey(currentVersion: false, rotationStepDue: false, behind: false))
        XCTAssertFalse(CircleManager.holdsCurrentKey(currentVersion: true, rotationStepDue: true, behind: false))
        XCTAssertTrue(AccessHandover.mayHandOver(heldVersion: 2, circleKeyVersion: 2, circleOpens: true,
                                                 selfIsReceiveOnly: false, isBehind: false))
        XCTAssertFalse(AccessHandover.mayHandOver(heldVersion: 2, circleKeyVersion: 2, circleOpens: true,
                                                  selfIsReceiveOnly: false, isBehind: true))
    }

    /// Through the real SDK: the owner's eject of x (v3) reaches this device
    /// spoiled, and the server lists the circle at v2. This device holds v2
    /// and seals under it by the version alone; it knows it is behind, so
    /// the gate refuses and nothing is handed over. SOS still seals under
    /// v2. The honest v3 record ends it.
    func testASpoiledEjectKeepsThisDeviceBehindWhateverTheServerLists() throws {
        let (owner, me, x) = (Party(), Party(), Party())
        let genesis = try owner.sdk.prepareRecordedCircleCreation(creatorUserId: owner.userId, circleId: circle).genesis
        let (invitedMe, invitedX) = (try invitation(by: owner, of: me), try invitation(by: owner, of: x))
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

        // This device: v2's key from the owner it confirms, then v1 and v2's records.
        _ = try me.sdk.pinMemberKeys(circleId: circle, userId: owner.userId,
                                     sharingPubkeyHex: owner.sharing, signingPubkeyHex: owner.signing)
        let first = try XCTUnwrap(v2.rotation.memberKeys.first { $0.userId == me.userId }).bundle
        try me.sdk.storeFirstCircleKey(
            circleId: circle, encryptedKey: first.encryptedCircleKey.nonce + first.encryptedCircleKey.ciphertext,
            senderPublicKey: first.ephemeralPublicKey, keyVersion: 2, senderUserId: owner.userId,
            recipientUserId: me.userId, wrapSignatureHex: first.wrapSignature,
            confirmedSenderSigningPubkeyHex: owner.signing, sealedCircleName: nil)
        let mine = [row(me, statements: [invitedMe]), row(owner, role: .owner), row(x, statements: [invitedX])]
        _ = try me.sdk.importRefreshRecords(
            circleId: circle, records: [genesis, v2.refreshRecord], keyChain: links,
            members: mine.map(\.sdkMember), rosterComplete: true, ownHead: nil, memberHeads: [])
        XCTAssertFalse(me.sdk.isBehind(circleId: circle), "caught up at v2")

        // v3's record, spoiled: one signature byte altered.
        var spoiled = v3.refreshRecord
        let flipped: Character = spoiled.signatureHex.first == "0" ? "1" : "0"
        spoiled.signatureHex = String(flipped) + spoiled.signatureHex.dropFirst()
        let report = try me.sdk.importRefreshRecords(
            circleId: circle, records: [spoiled], keyChain: links, members: mine.map(\.sdkMember),
            rosterComplete: true, ownHead: nil, memberHeads: [])
        XCTAssertFalse(report.forked)
        XCTAssertEqual(try me.sdk.getActiveVersion(circleId: circle), 2, "it seals under v2 by the version alone")
        XCTAssertTrue(me.sdk.isBehind(circleId: circle), "v3 waits here")

        // The server lists the circle at v2: the version check alone passes.
        XCTAssertTrue(CircleManager.holdsCurrentKey(localActiveVersion: 2, circleKeyVersion: 2))
        let behind = me.sdk.isBehind(circleId: circle)
        XCTAssertFalse(CircleManager.holdsCurrentKey(currentVersion: true, rotationStepDue: false, behind: behind),
                       "the gate refuses: nothing new is sealed, and the change waits")
        XCTAssertFalse(AccessHandover.mayHandOver(heldVersion: 2, circleKeyVersion: 2, circleOpens: true,
                                                  selfIsReceiveOnly: false, isBehind: behind),
                       "nothing is handed over")

        // SOS still goes out, under v2, which the owner reads.
        let sos = try me.sdk.encryptDataV2(circleId: circle, plaintext: "help", fieldTag: "device_state")
        XCTAssertEqual(try owner.sdk.decryptDataV2(circleId: circle, encryptedData: sos, fieldTag: "device_state"), "help")

        // The honest record ends it.
        let third = try XCTUnwrap(v3.rotation.memberKeys.first { $0.userId == me.userId }).bundle
        try me.sdk.storeCircleKey(
            circleId: circle, encryptedKey: third.encryptedCircleKey.nonce + third.encryptedCircleKey.ciphertext,
            senderPublicKey: third.ephemeralPublicKey, keyVersion: 3, senderUserId: owner.userId,
            recipientUserId: me.userId, wrapSignatureHex: third.wrapSignature, senderSigningPubkeyHex: owner.signing)
        _ = try me.sdk.importRefreshRecords(
            circleId: circle, records: [v3.refreshRecord], keyChain: links, members: mine.map(\.sdkMember),
            rosterComplete: true, ownHead: nil, memberHeads: [])
        XCTAssertFalse(me.sdk.isBehind(circleId: circle))
        XCTAssertEqual(try me.sdk.getActiveVersion(circleId: circle), 3)
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// The wiring: the one gate asks, both delivery callers ask, SOS never does.
    func testTheGatesAskAndSOSDoesNot() throws {
        let circles = try source("App/Managers/CircleManager.swift")
        XCTAssertTrue(circles.contains("""
                func holdsCurrentKey(for circleId: String) -> Bool {
                    Self.holdsCurrentKey(currentVersion: holdsCurrentVersion(for: circleId),
                                         rotationStepDue: rotationStepPending(circleId), behind: isBehind(circleId))
                }
            """))
        XCTAssertTrue(circles.contains(
            "        circleId != SelfKeyManager.selfCircleUuid && cryptoManager.isBehind(circleId: circleId)\n"))
        XCTAssertTrue(circles.contains("selfIsReceiveOnly: selfIsReceiveOnly(circleId), isBehind: isBehind(circleId)),"))
        XCTAssertTrue(try source("NotificationExtension/BackgroundHandover.swift").contains(
            "selfIsReceiveOnly: decided.result.selfIsReceiveOnly, isBehind: crypto.isBehind(circleId: circleId)) {"))
        // An SOS goes out under the key it holds: its send never asks. Only
        // the receiver asks, to tell "can't check" (it may be sealed under a
        // version not held here yet) from "refused".
        let sos = try source("App/Managers/SOSManager.swift")
        XCTAssertTrue(sos.contains("    private func behind(on circleId: String) -> Bool {\n"
                                   + "        CircleManager.shared.isBehind(circleId) || !CircleManager.shared.holdsCurrentVersion(for: circleId)\n"))
        XCTAssertEqual(sos.components(separatedBy: "isBehind(").count - 1, 1, "only the receiver's check asks")
        XCTAssertEqual(sos.components(separatedBy: "behind(on: ").count - 1, 1, "asked by the receiver rules' verdict alone")
        XCTAssertTrue(sos.contains("opened: entry.opened, behind: behind(on: circleId), marks: state,"))
        // The raise never asks the write gate; the raiser's re-seal and its
        // position updates ask it, primed, as every other sealing write does.
        let raiseStart = try XCTUnwrap(sos.range(of: "    private func triggerSOSOverWire("))
        let raiseEnd = try XCTUnwrap(sos.range(of: "\n    }\n", range: raiseStart.upperBound..<sos.endIndex))
        let raise = sos[raiseStart.lowerBound..<raiseEnd.upperBound]
        XCTAssertFalse(raise.contains(".shared.holdsCurrentKey("), "the raise never asks")
        XCTAssertFalse(raise.contains("requireCurrentKey("))
        XCTAssertEqual(sos.components(separatedBy: "CircleManager.shared.holdsCurrentKeyPrimed(").count - 1, 1,
                       "the re-seal alone")
        XCTAssertFalse(sos.contains("CircleManager.shared.holdsCurrentKey("), "never the unprimed gate")
        XCTAssertTrue(sos.contains("                let primed = await CircleManager.shared.holdsCurrentKeyPrimed(for: circleId)\n"))
        XCTAssertFalse(sos.contains("requireCurrentKey("))
    }

    /// The gate is only as good as its coverage: every call in the app that
    /// seals or wraps under a circle's key is in a function that asks the
    /// gate before it, or is one of the few that don't, each for its reason.
    /// A new sealing call fails here until it is one or the other.
    func testEverySealingCallIsBehindTheGateOrKnownNotToBe() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let notAsking: [String: String] = [
            "App/Managers/SOSManager.swift createRequest": "SOS goes out under the key it holds",
            "App/Managers/CircleManager.swift createCircle": "a circle this device is making",
            "App/Managers/MonitoringManager.swift seal": "under the personal key",
            "App/Managers/PlaceManager.swift createPlaceOverWire": "under the personal key",
            "App/Services/DeviceRegistrar.swift sealUnderPersonalKey": "under the personal key",
        ]
        let sealing = try NSRegularExpression(
            pattern: #"\.(encryptDataV2|encryptData|encryptLocation|wrapPlaceKey|wrapCircleKeyForMemberFull)\("#)
        let function = try NSRegularExpression(pattern: #"\bfunc (\w+)"#)
        let gate = try NSRegularExpression(pattern: #"holdsCurrentKey|requireCurrentKey|mayHandOver"#)
        var seen = Set<String>()
        for folder in ["App", "NotificationExtension"] {
            let files = FileManager.default.enumerator(at: root.appendingPathComponent(folder), includingPropertiesForKeys: nil)
            while let url = files?.nextObject() as? URL {
                guard url.pathExtension == "swift" else { continue }
                let path = String(url.path.dropFirst(root.path.count + 1))
                let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
                var name = "?"
                var body: [String] = []
                for line in lines {
                    let code = line.trimmingCharacters(in: .whitespaces).hasPrefix("//") ? "" : line
                    let range = NSRange(code.startIndex..., in: code)
                    if let match = function.firstMatch(in: code, range: range), let found = Range(match.range(at: 1), in: code) {
                        name = String(code[found])
                        body = []
                    }
                    body.append(code)
                    guard sealing.firstMatch(in: code, range: range) != nil else { continue }
                    let key = "\(path) \(name)"
                    let text = body.joined(separator: "\n")
                    if notAsking[key] != nil {
                        seen.insert(key)
                    } else {
                        XCTAssertNotNil(gate.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                                        "\(key) seals without asking the gate first")
                    }
                }
            }
        }
        XCTAssertEqual(seen, Set(notAsking.keys), "each exception still seals, or it leaves the list")
    }
}
