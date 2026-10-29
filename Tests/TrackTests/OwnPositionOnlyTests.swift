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
import CoreLocation
import PingolinTrackSDK
@testable import Track

/// A server row naming this account is never this account's marker or
/// place-alert input. Its position on screen is this phone's own fix, and its
/// alerts come from this phone's own fixes alone.
final class OwnPositionOnlyTests: XCTestCase {

    private let me = "d0000000-0000-4000-8000-000000000001"
    private let other = "d0000000-0000-4000-8000-000000000002"
    private let circle = "d0000000-0000-4000-8000-0000000000c1"

    /// Every spelling of this account's id the SDK parses.
    private var spellingsOfMe: [String] {
        [me, me.uppercased(), me.replacingOccurrences(of: "-", with: ""), "{\(me)}", "urn:uuid:\(me)"]
    }

    // MARK: - One id, any spelling

    func testSameIsOneUUIDWhateverTheSpelling() {
        for spelling in spellingsOfMe {
            XCTAssertTrue(CanonicalId.same(spelling, me), spelling)
            XCTAssertTrue(CanonicalId.same(me, spelling), spelling)
        }
        XCTAssertFalse(CanonicalId.same(me, other))
        XCTAssertFalse(CanonicalId.same("self", "self"), "an id that is no UUID is nobody's")
        XCTAssertFalse(CanonicalId.same(nil, nil))
        XCTAssertFalse(CanonicalId.same(me, nil))
        XCTAssertFalse(CanonicalId.same(nil, me))
    }

    // MARK: - Whose a row is, plain or sealed

    private func sealed(_ crypto: CryptoManager, _ text: String) throws -> [String: Any] {
        let e = try crypto.encryptDataV2(circleId: circle, plaintext: text, fieldTag: "user_id")
        return ["nonce": e.nonce, "ciphertext": e.ciphertext]
    }

    private func row(plain: String? = nil, sealed: [String: Any]? = nil) throws -> LocationResponse {
        var json: [String: Any] = [
            "day_bucket": 20_000,
            "encrypted_payload": ["nonce": "00", "ciphertext": "00"],
        ]
        if let plain { json["user_id"] = plain }
        if let sealed { json["encrypted_user_id"] = sealed }
        return try APIService.makeWireDecoder().decode(
            LocationResponse.self, from: JSONSerialization.data(withJSONObject: json)
        )
    }

    private func circleKeyHolder() throws -> CryptoManager {
        let crypto = CryptoManager()
        _ = crypto.generateKeypair()
        let creation = try crypto.prepareCircleCreation()
        try crypto.finalizeCircleCreation(tempCircleId: creation.tempCircleId, realCircleId: circle)
        return crypto
    }

    func testARowNamingThisAccountPlainOrSealedIsNeverRead() throws {
        let crypto = try circleKeyHolder()
        for spelling in spellingsOfMe {
            XCTAssertEqual(CircleManager.owner(of: try row(plain: spelling), circleId: circle, me: me, crypto: crypto),
                           .me, "plain \(spelling)")
            XCTAssertEqual(CircleManager.owner(of: try row(sealed: try sealed(crypto, spelling)), circleId: circle,
                                               me: me, crypto: crypto),
                           .me, "sealed \(spelling)")
        }
        // Another member, either way, as the row names them, with the version a
        // sealed id opened under.
        XCTAssertEqual(CircleManager.owner(of: try row(plain: other), circleId: circle, me: me, crypto: crypto),
                       .member(other, sealedUnder: nil))
        XCTAssertEqual(CircleManager.owner(of: try row(sealed: try sealed(crypto, other)), circleId: circle,
                                           me: me, crypto: crypto),
                       .member(other, sealedUnder: 1))
    }

    /// An id that is no UUID is nobody's, never "some other member".
    func testARowNamingNoAccountIsNobodys() throws {
        let crypto = try circleKeyHolder()
        let stranger = try circleKeyHolder()  // a key of its own under the same circle id
        let cases: [(String, LocationResponse)] = [
            ("plain non-UUID", try row(plain: "self")),
            ("plain empty", try row(plain: "")),
            ("sealed non-UUID", try row(sealed: try sealed(crypto, "not-a-uuid"))),
            ("sealed under another key", try row(sealed: try sealed(stranger, other))),
            ("no id at all", try row()),
        ]
        for (what, response) in cases {
            XCTAssertEqual(CircleManager.owner(of: response, circleId: circle, me: me, crypto: crypto), .nobody, what)
        }
    }

    // MARK: - The decode loop (it calls the API, so its wiring)

    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    private func body(_ src: String, from start: String, to end: String) throws -> String {
        let a = try XCTUnwrap(src.range(of: start), start)
        let b = try XCTUnwrap(src.range(of: end, range: a.upperBound..<src.endIndex), end)
        return String(src[a.lowerBound..<b.lowerBound])
    }

    func testTheDecodeDropsMyRowBeforeOpeningItAndCountsNothing() throws {
        let circles = try source("App/Managers/CircleManager.swift")
        // Whose a row is comes first, before either payload opens (the row
        // decoder is the one reader).
        let decode = try body(circles, from: "    nonisolated static func decodeRow(",
                              to: "    /// What one refresh of a circle's locations actually produced.")
        let owner = try XCTUnwrap(decode.range(of: "switch owner(of: response, circleId: circleId, me: me, crypto: crypto) {"))
        for payload in ["EnvelopeDecoding.decryptSessionLocationBound(", "EnvelopeDecoding.decryptDirectLocationBound(",
                        "EnvelopeDecoding.decryptLocationBound("] {
            let open = try XCTUnwrap(decode.range(of: payload), payload)
            XCTAssertLessThan(owner.upperBound, open.lowerBound, "whose it is, before \(payload)")
        }
        XCTAssertTrue(decode.contains("        case .me:\n            return .mine\n"))
        XCTAssertTrue(decode.contains("        case .nobody:\n            return .nobody\n"))
        // Mine: dropped and counted as nothing. Nobody's: counted as a failure.
        let load = try body(circles, from: "    func loadMemberLocations(for circleId: String,",
                            to: "    private func setupLocationSync() {")
        XCTAssertTrue(load.contains("switch Self.decodeRow(response, circleId: circleId, me: myUserId, crypto: crypto) {"))
        let mine = try body(load, from: "                case .mine:\n", to: "                case .nobody, .unopened:\n")
        XCTAssertTrue(mine.hasSuffix("                    continue\n"))
        XCTAssertFalse(mine.contains("+= 1"))
        XCTAssertTrue(load.contains("                case .nobody, .unopened:\n"
                                    + "                    // The row exists and we cannot say whose it is, or it would\n"
                                    + "                    // not open — a decrypt failure, not an absence.\n"
                                    + "                    decryptFailed += 1\n"))
        // No row of mine reaches the publish loop, so it has no self case left:
        // past its definition, `myUserId` is only ever the decoder's `me:`, which
        // drops my row (the re-sealed last-known rows are decoded the same way).
        XCTAssertEqual(load.components(separatedBy: "myUserId").count - 1,
                       load.components(separatedBy: "me: myUserId").count - 1 + 1)
        // And every decode site is given it: one given `me: nil` would hand on the
        // server's copy of me as someone else's row.
        XCTAssertEqual(load.components(separatedBy: "Self.decodeRow(").count - 1,
                       load.components(separatedBy: "Self.decodeRow(response, circleId: circleId, me: myUserId, crypto: crypto)").count - 1)
        XCTAssertTrue(load.contains("            guard isShown(userId, in: circleId) else { continue }\n"))
        XCTAssertTrue(load.contains("            let incomingAuthTs: Int64? = authTs[userId]\n"))
    }

    // MARK: - The evaluator

    private func location(_ userId: String, latitude: Double = 52.5) -> LocationData {
        LocationData(circleId: circle, userId: userId, deviceId: "d", latitude: latitude, longitude: 13.4,
                     timestamp: Date(timeIntervalSince1970: 1_727_600_000))
    }

    func testTheEvaluatorTakesNoRowNamingThisAccount() {
        let rows = spellingsOfMe.map { location($0) } + [location(other)]
        XCTAssertEqual(PlaceAlertEvaluator.memberObservations(rows, me: me).map(\.userId), [other])
        XCTAssertEqual(PlaceAlertEvaluator.memberObservations(rows, me: me.uppercased()).map(\.userId), [other])
        XCTAssertTrue(PlaceAlertEvaluator.memberObservations(rows, me: nil).isEmpty, "no account, nothing evaluated")
    }

    func testTheEvaluatorsServerEntryGoesThroughTheFilter() throws {
        let evaluator = try source("App/Domain/PlaceAlerts/PlaceAlertEvaluator.swift")
        XCTAssertTrue(evaluator.contains("    func evaluate(locations: [LocationData]) async {\n"
                                         + "        await evaluate(Self.memberObservations(locations, me: AuthManager.shared.userId))\n"
                                         + "    }\n"))
    }

    // MARK: - This account's marker is this phone's position

    private let fixTime = Date(timeIntervalSince1970: 1_727_600_123)

    private var fix: CLLocation {
        CLLocation(coordinate: CLLocationCoordinate2D(latitude: 48.1, longitude: 11.5), altitude: 0,
                   horizontalAccuracy: 7, verticalAccuracy: -1, timestamp: fixTime)
    }

    func testMyMarkerIsThisPhonesPositionAndNoRow() {
        let rows = spellingsOfMe.map { location($0, latitude: 1) } + [location(other)]

        let shown = MapView.withOwnPosition(rows, me: me, own: fix, circleId: circle, deviceId: "d")
        XCTAssertEqual(shown.filter { $0.userId == other }.count, 1)
        let mine = shown.filter { CanonicalId.same($0.userId, me) }
        XCTAssertEqual(mine.count, 1, "one marker for this account")
        XCTAssertEqual(mine.first?.userId, me)
        XCTAssertEqual(mine.first?.latitude, 48.1)
        XCTAssertEqual(mine.first?.timestamp, fixTime, "the fix's own time, so its age shows")
        XCTAssertEqual(mine.first?.accuracy, 7)

        let none = MapView.withOwnPosition(rows, me: me, own: nil, circleId: circle, deviceId: "d")
        XCTAssertEqual(none.map(\.userId), [other], "no position here: no marker, and never a row's")
    }

    func testEveryReaderOfMyPositionAsksThisPhone() throws {
        let map = try source("App/Views/Map/MapView.swift")
        XCTAssertTrue(map.contains("            own: locationService.currentLocation,\n"))
        let sheet = try body(map, from: "    var location: LocationData? {\n", to: "    /// The saved place the member is currently inside")
        XCTAssertTrue(sheet.hasPrefix("    var location: LocationData? {\n"
                                      + "        // This account's is this phone's own fix, never a row: the\n"))
        XCTAssertTrue(sheet.contains("        if CanonicalId.same(member.userId, AuthManager.shared.userId) {\n"
                                     + "            return locationService.currentLocation.map {\n"))
        let focus = try body(map, from: "    private func focusMember(userId: String) {", to: "    /// 8 × 250ms")
        XCTAssertTrue(focus.contains("            if isMe {\n"
                                     + "                if let own = locationService.currentLocation { flyToCoordinate = own.coordinate }\n"
                                     + "            } else if let loc = Self.heldRow(circleManager.memberLocations[userId], in: circleManager.activeCircle?.id) {\n"))

        let roster = try source("App/Views/Circles/CirclesView.swift")
        let row = try body(roster, from: "    var location: LocationData? {\n", to: "    var isCurrentUser: Bool {")
        XCTAssertTrue(row.hasPrefix("    var location: LocationData? {\n"
                                    + "        // This account's is this phone's own fix, never a row: the\n"))
        XCTAssertTrue(row.contains("        if CanonicalId.same(member.userId, AuthManager.shared.userId) {\n"
                                   + "            return locationService.currentLocation.map {\n"))
    }
}
