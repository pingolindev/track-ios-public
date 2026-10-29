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

/// How the app wires the SDK's refresh records. The records' own rules are
/// the SDK's, tested there; here is what the app sends, when, and what it
/// does with the answers.
final class RefreshRecordsWiringTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    // MARK: - Heads

    private func device() -> CryptoManager {
        let sdk = CryptoManager()
        _ = sdk.generateKeypair()
        _ = sdk.generateSigningKeypair()
        return sdk
    }

    /// A head is published when the server serves none of this account's, or
    /// one older than the head accepted here; and again after a password
    /// reset, since one signed by the old key doesn't verify under the new.
    @MainActor
    func testAHeadIsPublishedWhenMissingOlderOrSignedByAnOldKey() throws {
        let me = UUID().uuidString.lowercased()
        let circle = UUID().uuidString.lowercased()
        let sdk = device()
        _ = try sdk.prepareRecordedCircleCreation(creatorUserId: me, circleId: circle)
        XCTAssertEqual(sdk.refreshHeadVersions()[circle], 1,
                       "the creator's own genesis is accepted as it is made (mobile-sdk acd32ca: a new circle's creator may rotate at once)")
        let signed = try sdk.signCircleHead(circleId: circle, userId: me)
        let served = ServedCircleHead(userId: me, head: signed.headHex, signature: signed.signatureHex)
        let own = try XCTUnwrap(AccountHeads.ownHead(circleId: circle, me: me, served: [served], crypto: sdk))
        XCTAssertEqual(own.version, 1)
        XCTAssertFalse(AccountHeads.mustPublish(accepted: 1, own: own), "the served head is this one")
        XCTAssertTrue(AccountHeads.mustPublish(accepted: 2, own: own), "older than the head accepted")
        XCTAssertTrue(AccountHeads.mustPublish(accepted: 1, own: nil), "none served")
        XCTAssertFalse(AccountHeads.mustPublish(accepted: 0, own: nil), "nothing accepted yet")
        // After a reset the account signs with a new key: the old head
        // doesn't verify any more, so it is published again.
        let afterReset = device()
        XCTAssertNil(AccountHeads.ownHead(circleId: circle, me: me, served: [served], crypto: afterReset))
        // Another account's head, or this account's for another circle, is not its own.
        XCTAssertNil(AccountHeads.ownHead(circleId: circle, me: UUID().uuidString.lowercased(), served: [served], crypto: sdk))
        XCTAssertNil(AccountHeads.ownHead(circleId: UUID().uuidString.lowercased(), me: me, served: [served], crypto: sdk))
        let tampered = ServedCircleHead(userId: me, head: signed.headHex, signature: String(repeating: "00", count: 64))
        XCTAssertNil(AccountHeads.ownHead(circleId: circle, me: me, served: [tampered], crypto: sdk))
    }

    // MARK: - Leaving

    /// A circle this account left or deleted, as the server confirmed, goes
    /// from the SDK with its secret; a roster's 404 or 403 never costs the keys.
    /// A circle that had records keeps only a mark of that: re-joined, it waits
    /// for its records whatever the server serves, and nothing the server says
    /// removes the mark.
    func testOnlyAnOwnLeaveOrDeleteForgetsTheCirclesKeys() throws {
        let sdk = CryptoManager()
        _ = sdk.generateKeypair()
        _ = sdk.generateSigningKeypair()
        let circle = UUID().uuidString.lowercased()
        _ = try sdk.prepareRecordedCircleCreation(creatorUserId: UUID().uuidString.lowercased(), circleId: circle)
        XCTAssertTrue(sdk.forgetCircle(circleId: circle))
        XCTAssertFalse(sdk.hasCircleKey(circleId: circle))
        XCTAssertTrue(sdk.circleHasRefreshRecords(circleId: circle), "latched: it had records")
        XCTAssertEqual(sdk.refreshHeadVersions()[circle] ?? 0, 0, "the mark alone: no head, no record")
        XCTAssertFalse(sdk.forgetCircle(circleId: circle), "nothing left to forget")
        XCTAssertTrue(sdk.circleHasRefreshRecords(circleId: circle), "the mark stays")

        let circles = try source("App/Managers/CircleManager.swift")
        for (function, after) in [("    func leaveCircle(_ circleId: String) async throws {", "_ = try await api.leaveCircle(circleId: circleId)"),
                                  ("    func deleteCircle(_ circle: Circle) async throws {", "_ = try await api.deleteCircle(circleId: circle.id)")] {
            let start = try XCTUnwrap(circles.range(of: function), function)
            let body = circles[start.upperBound...].prefix(1_200)
            let confirmed = try XCTUnwrap(body.range(of: after), function)
            let forget = try XCTUnwrap(body.range(of: "forgetCircleKeys("), function)
            XCTAssertLessThan(confirmed.lowerBound, forget.lowerBound, "\(function): only once the server confirmed")
        }
        let prune = try XCTUnwrap(circles.range(of: "    private func pruneLocalCircle(circleId: String) {"))
        XCTAssertFalse(circles[prune.upperBound...].prefix(1_800).contains("forgetCircle"), "a 404 is not gone")
        XCTAssertEqual(circles.components(separatedBy: "cryptoManager.forgetCircle(").count - 1, 1)
    }

    // MARK: - New circles

    /// A new circle is made under the id the server reserved, with its genesis
    /// record signed by its creator: the SDK then counts it as recorded, and a
    /// creation the server refused is dropped again, leaving nothing here.
    func testANewCircleIsMadeWithItsGenesisUnderTheReservedId() throws {
        let sdk = CryptoManager()
        _ = sdk.generateKeypair()
        _ = sdk.generateSigningKeypair()
        let me = UUID().uuidString.lowercased()
        let reserved = UUID().uuidString.lowercased()
        let recorded = try sdk.prepareRecordedCircleCreation(creatorUserId: me, circleId: reserved)
        XCTAssertEqual(recorded.circleId, reserved)
        XCTAssertEqual(recorded.creation.tempCircleId, reserved, "made under the reserved id: nothing to finalize")
        XCTAssertFalse(recorded.genesis.recordHex.isEmpty)
        XCTAssertTrue(sdk.circleHasRefreshRecords(circleId: reserved))
        XCTAssertEqual(try sdk.getActiveVersion(circleId: reserved), 1)
        XCTAssertTrue(sdk.discardCircleCreation(circleId: reserved))
        XCTAssertFalse(sdk.hasCircleKey(circleId: reserved))
        XCTAssertFalse(sdk.circleHasRefreshRecords(circleId: reserved))
        // Never under an id this device already knows, or the nil UUID.
        let again = UUID().uuidString.lowercased()
        _ = try sdk.prepareRecordedCircleCreation(creatorUserId: me, circleId: again)
        XCTAssertThrowsError(try sdk.prepareRecordedCircleCreation(creatorUserId: me, circleId: again))
        XCTAssertThrowsError(try sdk.prepareRecordedCircleCreation(creatorUserId: me,
                                                                    circleId: SelfKeyManager.selfCircleUuid))
    }

    /// Dropped again only on the server's refusal. No answer keeps it: the
    /// server may have made the circle, and dropping its only key would lose it.
    func testACreationIsDroppedOnlyWhenTheServerRefusedIt() {
        for refused in [APIError(code: "http_400", message: ""), APIError(code: "http_403", message: ""),
                        APIError(code: "http_402", message: "", errorCode: "quota_circles_exceeded"),
                        APIError(code: "rate_limited", message: ""), CircleManager.CircleError.noCircleKey] as [Error] {
            XCTAssertTrue(CircleManager.creationWasRefused(refused), "\(refused)")
        }
        for noAnswer in [URLError(.timedOut), URLError(.notConnectedToInternet), APIError(code: "http_503", message: ""),
                         APIError(code: "http_500", message: ""), APIError(code: "network_error", message: ""),
                         APIError(code: "circuit_open", message: ""), APIError(code: "http_408", message: "")] as [Error] {
            XCTAssertFalse(CircleManager.creationWasRefused(noAnswer), "\(noAnswer)")
        }
    }

    /// The wiring: reserve, then prepare under that id, then create with the
    /// genesis; a refusal discards; a circle under another id is refused.
    func testCreateCircleReservesSignsTheGenesisAndSendsItTogether() throws {
        let circles = try source("App/Managers/CircleManager.swift")
        let create = try XCTUnwrap(circles.range(of: "    func createCircle(name: String, consent: ShownNotice?) async throws -> Circle {"))
        let body = circles[create.upperBound...].prefix(4_000)
        let reserve = try XCTUnwrap(body.range(of: "let reserved = try await api.reserveCircleId()"))
        let prepare = try XCTUnwrap(body.range(of: "let recorded = try cryptoManager.prepareRecordedCircleCreation(creatorUserId: creator,\n                                                                      circleId: reserved.circleId)"))
        let send = try XCTUnwrap(body.range(of: "circleId: recorded.circleId,\n                genesis: RefreshRecordWire(record: recorded.genesis.recordHex, signature: recorded.genesis.signatureHex)"))
        XCTAssertLessThan(reserve.lowerBound, prepare.lowerBound)
        XCTAssertLessThan(prepare.lowerBound, send.lowerBound)
        XCTAssertTrue(body.contains("if Self.creationWasRefused(error) { _ = cryptoManager.discardCircleCreation(circleId: recorded.circleId) }"))
        XCTAssertTrue(body.contains("guard response.id.caseInsensitiveCompare(recorded.circleId) == .orderedSame else {"))
        XCTAssertFalse(body.contains("prepareCircleCreation()"), "never an unrecorded circle")
        XCTAssertFalse(body.contains("finalizeCircleCreation("))
        let api = try source("App/Services/APIService.swift")
        XCTAssertTrue(api.contains("return try await post(path: \"/api/v1/circles/reserve-id\", body: EmptyBody())"))
    }
}
