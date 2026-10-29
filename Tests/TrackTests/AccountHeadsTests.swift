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

/// How a device publishes its account head: after each import it publishes
/// its accepted head when its own served head is missing, doesn't verify
/// under the CURRENT key, or is older; never while forked; an own head that
/// verifies but names another chain is this account's devices diverging, a
/// fork (the SDK compares it); at most one PUT per circle per import. Real
/// devices, with the PUT counted.
@MainActor
final class AccountHeadsTests: XCTestCase {
    private let me = UUID().uuidString.lowercased()
    private let circle = UUID().uuidString.lowercased()
    private var puts: [(circleId: String, head: String, signature: String)] = []

    private func device() -> CryptoManager {
        let sdk = CryptoManager()
        _ = sdk.generateKeypair()
        _ = sdk.generateSigningKeypair()
        return sdk
    }

    /// Another device of the same account: the same identity keys.
    private func sameAccount(as keys: (KeyPair, SigningKeyPair)) throws -> CryptoManager {
        let sdk = CryptoManager()
        try sdk.importPrivateKey(privateKeyBase64: keys.0.privateKey)
        try sdk.importSigningPrivateKey(secretSeedB64: keys.1.secretSeedB64)
        return sdk
    }

    private func served(_ sdk: CryptoManager) throws -> ServedCircleHead {
        let head = try sdk.signCircleHead(circleId: circle, userId: me)
        return ServedCircleHead(userId: me, head: head.headHex, signature: head.signatureHex)
    }

    private func publish(_ sdk: CryptoManager, served: [ServedCircleHead]) async {
        await AccountHeads.publishIfNeeded(circleId: circle, me: me, served: served, crypto: sdk) { circleId, head, signature in
            self.puts.append((circleId, head, signature))
        }
    }

    /// The version the one head published names, verified under this device's key.
    private func publishedVersion(_ sdk: CryptoManager) throws -> Int32 {
        XCTAssertEqual(puts.count, 1, "at most one PUT per circle per import")
        let put = try XCTUnwrap(puts.first)
        XCTAssertEqual(put.circleId, circle)
        return try XCTUnwrap(try sdk.verifyCircleHead(headHex: put.head, signatureHex: put.signature,
                                                      signerSigningPublicKeyHex: sdk.signingPublicKeyHex())).version
    }

    /// A circle this device made, with its genesis imported back in this
    /// process (the head it accepted: v1).
    private func accepted(_ sdk: CryptoManager) throws -> SignedRefreshRecord {
        let genesis = try sdk.prepareRecordedCircleCreation(creatorUserId: me, circleId: circle).genesis
        _ = try sdk.importRefreshRecords(circleId: circle, records: [genesis], keyChain: [], members: [],
                                         rosterComplete: true, ownHead: nil, memberHeads: [])
        XCTAssertEqual(sdk.refreshHeadVersions()[circle], 1)
        return genesis
    }

    /// A reset: the served head was signed by the account's key before the
    /// reset, so it doesn't verify under the current one, and one import
    /// publishes the same version again.
    func testAfterAResetOneImportPublishesTheSameVersion() async throws {
        let now = device()
        _ = try accepted(now)
        let before = device()   // the account's key before the reset
        _ = try before.prepareRecordedCircleCreation(creatorUserId: me, circleId: circle)
        let old = try served(before)
        XCTAssertNil(AccountHeads.ownHead(circleId: circle, me: me, served: [old], crypto: now), "the old key's")
        await publish(now, served: [old])
        XCTAssertEqual(try publishedVersion(now), 1, "the same version, re-signed")
    }

    /// A server that withholds this account's head doesn't turn
    /// publishing off.
    func testAWithheldOwnHeadIsPublished() async throws {
        let sdk = device()
        _ = try accepted(sdk)
        await publish(sdk, served: [])
        XCTAssertEqual(try publishedVersion(sdk), 1)
    }

    /// An own head older than the one accepted here: published.
    func testAStaleOwnHeadIsPublished() async throws {
        let sdk = CryptoManager()
        let sharing = Data(base64Encoded: sdk.generateKeypair().publicKey)!.map { String(format: "%02x", $0) }.joined()
        _ = sdk.generateSigningKeypair()
        // This account, as the app lists it to the SDK: its own keys, confirmed.
        let mine = RecordMember(userId: me, sharingPublicKeyHex: sharing, signingPublicKeyHex: try sdk.signingPublicKeyHex(),
                                confirmed: true, listed: true, listedRole: .owner, statements: [],
                                personConfirmedKeys: false, serverSaysKeyless: false)
        _ = try accepted(sdk)
        let atOne = try served(sdk)
        await publish(sdk, served: [atOne])
        XCTAssertTrue(puts.isEmpty, "the served head is this one")
        let v2 = try sdk.prepareRecordedRotation(
            circleId: circle, senderUserId: me, kind: .rotation,
            planned: [PlannedEntry(userId: me, state: .included, role: nil)], members: [mine], rosterComplete: true,
            currentCircleNamePlaintext: "Family")
        _ = try sdk.importRefreshRecords(circleId: circle, records: [v2.refreshRecord],
                                         keyChain: [try XCTUnwrap(v2.rotation.keyChainLink)], members: [mine],
                                         rosterComplete: true, ownHead: nil, memberHeads: [])
        XCTAssertEqual(sdk.refreshHeadVersions()[circle], 2)
        await publish(sdk, served: [atOne])
        XCTAssertEqual(try publishedVersion(sdk), 2)
    }

    /// This account's own head, verifying under its CURRENT key but naming
    /// another chain at a version this device holds: its devices diverged. The
    /// import reports a fork, and nothing is published over it, then or later.
    func testADivergentOwnHeadIsAForkAndNothingIsPublished() async throws {
        let first = CryptoManager()
        let identity = (first.generateKeypair(), first.generateSigningKeypair())
        let genesis = try accepted(first)
        // The same account's other device holds another chain for this circle.
        let other = try sameAccount(as: identity)
        _ = try other.prepareRecordedCircleCreation(creatorUserId: me, circleId: circle)
        let divergent = try served(other)
        XCTAssertNotNil(AccountHeads.ownHead(circleId: circle, me: me, served: [divergent], crypto: first),
                        "it verifies under the current key")
        let report = try first.importRefreshRecords(
            circleId: circle, records: [genesis], keyChain: [], members: [], rosterComplete: true,
            ownHead: SignedCircleHead(headHex: divergent.head, signatureHex: divergent.signature), memberHeads: [])
        XCTAssertTrue(report.forked)
        XCTAssertEqual(first.refreshHeadVersions()[circle], 0, "forked: the whole chain is asked for")
        await publish(first, served: [divergent])
        XCTAssertTrue(puts.isEmpty, "never PUT over a divergence")
        await publish(first, served: [])
        XCTAssertTrue(puts.isEmpty, "nothing while forked, even with no head served")
    }

    /// The one "not yet" answer (`AccountHeads.headNotYet`): the record at the
    /// head isn't known here in full (a store an older SDK wrote), so nothing
    /// is published and nothing is wrong; the import that serves it again
    /// publishes. Any other refusal is a failure.
    func testAHeadWhoseRecordIsNotKnownInFullYetWaits() throws {
        XCTAssertTrue(AccountHeads.headNotYet(.InvalidInput(
            message: "Invalid input: the head's record isn't known here in full yet: import this circle's records first")))
        XCTAssertFalse(AccountHeads.headNotYet(.InvalidInput(message: "Invalid input: circle_id is not a UUID")))
        XCTAssertFalse(AccountHeads.headNotYet(.KeyNotFound(message: "no record of this circle is accepted here")))
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let heads = try String(contentsOf: root.appendingPathComponent("App/Managers/AccountHeads.swift"), encoding: .utf8)
        XCTAssertTrue(heads.contains("        } catch let error as MobileError where headNotYet(error) {\n"))
    }

    /// The head this device publishes is the SDK's, in format 2 (its first
    /// byte). An own head served in a format this build doesn't read is
    /// ignored, as if none were served, and this device publishes its own.
    func testTheHeadPublishedIsFormat2AndAnUnknownFormatIsIgnored() async throws {
        let sdk = device()
        _ = try accepted(sdk)
        let signed = try served(sdk)
        XCTAssertTrue(signed.head.hasPrefix("02"), "format 2")
        let unknown = ServedCircleHead(userId: me, head: "03" + signed.head.dropFirst(2), signature: signed.signature)
        XCTAssertNil(AccountHeads.ownHead(circleId: circle, me: me, served: [unknown], crypto: sdk), "not read: ignored")
        await publish(sdk, served: [unknown])
        XCTAssertEqual(try publishedVersion(sdk), 1)
        XCTAssertTrue(try XCTUnwrap(puts.first).head.hasPrefix("02"), "published in format 2")
    }
}
