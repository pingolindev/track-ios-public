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

import CoreLocation
import PingolinTrackSDK
import SwiftUI
import XCTest
@testable import Track

/// A member who shares only an approximate location is shown as an AREA, never
/// as a point.
///
/// WHY THIS IS WORTH TESTING
///   - The radius is read under the name the server sends
///     (`approximate_radius_miles`); any other name decodes silently as nil.
///     The rows below are shaped like the server's location rows and go
///     through the live decode.
///   - The area must not change size with the server's ±20 % jitter, and must
///     cover the person even at −20 %: 1.25 × the largest radius seen.
///   - Nothing finer than the area: no street address, no coordinates, no place
///     worked out from the point — and VoiceOver says it is approximate.
@MainActor
final class ApproximateMembersTests: XCTestCase {

    // MARK: - The wire

    /// `{"success":true,"data":{"locations":[…]}}` as GET
    /// /circles/{id}/locations/latest sends it: one row per member,
    /// `sharing_mode` and `approximate_radius_miles` left out when None.
    private func latest(_ rows: [String]) throws -> LatestLocationsResponse {
        try APIService.decodeResponseBody(Data("""
        {"success": true, "data": {"locations": [\(rows.joined(separator: ","))]}}
        """.utf8))
    }

    private func rowJSON(_ extra: String) -> String {
        """
        {"user_id": "e0000000-0000-4000-8000-000000000001",
         "encrypted_user_id": null, "encrypted_device_id": null, "day_bucket": 20740,
         "encrypted_payload": {"nonce": "AAAA", "ciphertext": "AAAA", "wrapped_msg_key": "AAAA",
                               "wrapped_msg_key_nonce": "AAAA"},
         "allow_alerts_on_me": true\(extra)}
        """
    }

    func testTheServersApproximateRowsDecode() throws {
        let rows = try latest([
            rowJSON(#", "sharing_mode": "approximate", "approximate_radius_miles": 2"#),
            rowJSON(#", "sharing_mode": "approximate""#),
            rowJSON(#", "sharing_mode": "exact""#),
            rowJSON(""),
        ]).locations
        XCTAssertEqual(rows.map(\.sharingMode), ["approximate", "approximate", "exact", nil])
        XCTAssertEqual(rows.map(\.approximateRadiusMiles), [2, nil, nil, nil])

        let areas = rows.map { ApproximateArea(sharingMode: $0.sharingMode, radiusMiles: $0.approximateRadiusMiles) }
        XCTAssertEqual(areas[0], ApproximateArea(sharingMode: "approximate", radiusMiles: 2))
        XCTAssertEqual(areas[0]?.reportedMiles, 2)
        XCTAssertEqual(areas[1]?.reportedMiles, nil)
        XCTAssertNil(areas[2], "exact is a pin")
        XCTAssertNil(areas[3], "an older server's row is a pin")
    }

    /// A row with only `sharing_radius_miles` (a name the server never sends)
    /// carries no radius; the real one is `approximate_radius_miles`.
    func testTheRadiusIsReadUnderItsRealName() throws {
        let rows = try latest([
            rowJSON(#", "sharing_mode": "approximate", "sharing_radius_miles": 9"#),
            rowJSON(#", "sharing_mode": "approximate", "approximate_radius_miles": 9"#),
        ]).locations
        XCTAssertEqual(rows.map(\.approximateRadiusMiles), [nil, 9])
    }

    // MARK: - How big the area is

    func testTheAreaIsAQuarterLargerThanTheRadius() throws {
        let reported = try XCTUnwrap(ApproximateArea(sharingMode: "approximate", radiusMiles: 4))
        XCTAssertEqual(reported.drawnMiles, 5, accuracy: 1e-9)
        XCTAssertEqual(reported.drawnMeters, 5 * 1_609.344, accuracy: 1e-6)

        // No radius on the wire: the senders' own default of 1 mile.
        let unreported = try XCTUnwrap(ApproximateArea(sharingMode: "approximate", radiusMiles: nil))
        XCTAssertEqual(unreported.drawnMiles, 1.25, accuracy: 1e-9)
        // A radius that is no radius is the same as none.
        XCTAssertEqual(ApproximateArea(sharingMode: "approximate", radiusMiles: 0)?.drawnMiles, 1.25)
        XCTAssertEqual(ApproximateArea(sharingMode: "approximate", radiusMiles: -3)?.drawnMiles, 1.25)

        XCTAssertNil(ApproximateArea(sharingMode: "exact", radiusMiles: 2))
        XCTAssertNil(ApproximateArea(sharingMode: "paused", radiusMiles: 2))
        XCTAssertNil(ApproximateArea(sharingMode: nil, radiusMiles: 2))
    }

    /// The wire radius is the member's ±20 %, drawn afresh per response. The
    /// area keeps the largest seen, so it never shrinks between refreshes, and
    /// forgets it when the member stops being approximate.
    func testTheAreaKeepsTheLargestRadiusSeenUntilTheMemberStops() {
        var memory = ApproximateAreaMemory()
        let circle = "e0000000-0000-4000-8000-0000000000c1"
        let user = "e0000000-0000-4000-8000-000000000001"
        func seen(_ miles: Double?) -> Double? {
            memory.remember(ApproximateArea(sharingMode: "approximate", radiusMiles: miles),
                            circleId: circle, userId: user)?.drawnMiles
        }
        XCTAssertEqual(seen(2), 2.5)
        XCTAssertEqual(seen(3), 3.75)
        XCTAssertEqual(seen(2), 3.75, "a smaller jitter does not shrink it")
        XCTAssertEqual(seen(nil), 3.75, "nor does a row without a radius")
        // The same member in the id's other spelling is the same member.
        XCTAssertEqual(memory.remember(ApproximateArea(sharingMode: "approximate", radiusMiles: 1),
                                       circleId: circle.uppercased(), userId: user.uppercased())?.drawnMiles, 3.75)

        // Another circle has its own area.
        XCTAssertEqual(memory.remember(ApproximateArea(sharingMode: "approximate", radiusMiles: 1),
                                       circleId: "e0000000-0000-4000-8000-0000000000c2", userId: user)?.drawnMiles, 1.25)

        // Exact again: forgotten, so a later approximate spell starts afresh.
        XCTAssertNil(memory.remember(nil, circleId: circle, userId: user))
        XCTAssertEqual(seen(2), 2.5)
    }

    // MARK: - A fix already held

    private func location(_ circleId: String = "e0000000-0000-4000-8000-0000000000c1",
                          approximate: ApproximateArea? = nil) -> LocationData {
        LocationData(circleId: circleId, userId: "e0000000-0000-4000-8000-000000000001", deviceId: "d",
                     latitude: 37.3349, longitude: -122.009, timestamp: Date(timeIntervalSince1970: 1_800_000_000),
                     approximate: approximate)
    }

    /// The server re-serves a member's last fix until they send another, and
    /// the replay guard drops it. A member who switched to approximate is
    /// reported so on that old fix: it is drawn as an area from that refresh on,
    /// round its own point put on the senders' grid, at its own time.
    func testAHeldFixTakesTheSharingTheServerReportsNow() throws {
        var areas = ApproximateAreaMemory()
        let area = try XCTUnwrap(ApproximateArea(sharingMode: "approximate", radiusMiles: 2))
        let held = location()
        let updated = try XCTUnwrap(CircleManager.heldFix(held, takingPostureOf: location(approximate: area),
                                                          areas: &areas))
        XCTAssertEqual(updated.approximate, area)
        let onGrid = ApproximateArea.snapped(held.coordinate, reportedMiles: 2)
        XCTAssertEqual(updated.latitude, onGrid.latitude, accuracy: 0)
        XCTAssertEqual(updated.longitude, onGrid.longitude, accuracy: 0)
        XCTAssertNotEqual(updated.latitude, held.latitude, "the precise point is never the centre")
        XCTAssertEqual(updated.timestamp, held.timestamp, "the held fix's own time: a replay rewinds nothing")

        // Served again with another radius: nothing changes on the map.
        let other = try XCTUnwrap(ApproximateArea(sharingMode: "approximate", radiusMiles: 3))
        let again = CircleManager.heldFix(updated, takingPostureOf: location(approximate: other), areas: &areas)
        XCTAssertEqual(again?.latitude ?? updated.latitude, updated.latitude, accuracy: 0)
        XCTAssertEqual(again?.longitude ?? updated.longitude, updated.longitude, accuracy: 0)

        // And back: exact again.
        XCTAssertNil(try XCTUnwrap(CircleManager.heldFix(updated, takingPostureOf: location(), areas: &areas))
            .approximate)

        // Nothing to change, nothing held, or another circle's fix: no publish.
        var fresh = ApproximateAreaMemory()
        XCTAssertNil(CircleManager.heldFix(held, takingPostureOf: location(), areas: &fresh))
        XCTAssertNil(CircleManager.heldFix(nil, takingPostureOf: location(approximate: area), areas: &fresh))
        XCTAssertNil(CircleManager.heldFix(held, takingPostureOf: location("e0000000-0000-4000-8000-0000000000c2",
                                                                          approximate: area), areas: &fresh))
    }

    // MARK: - Never an area round a precise point

    private let circle = "e0000000-0000-4000-8000-0000000000c1"
    private let member = "e0000000-0000-4000-8000-000000000001"

    private func fix(_ latitude: Double, _ longitude: Double, at seconds: TimeInterval,
                     reported miles: Double?) -> LocationData {
        LocationData(circleId: circle, userId: member, deviceId: "d", latitude: latitude, longitude: longitude,
                     timestamp: Date(timeIntervalSince1970: seconds),
                     approximate: ApproximateArea(sharingMode: "approximate", radiusMiles: miles))
    }

    private func onSendersGrid(_ latitude: Double, miles: Int) -> Bool {
        let cells = latitude / (Double(miles) * 1_609.344 / 111_320)
        return abs(cells - cells.rounded()) < 1e-9
    }

    /// The precise fix a member sent while exact, labelled approximate after
    /// they switched — met here for the first time (a cold start never saw it
    /// as exact): drawn on the senders' grid, never at the point itself.
    func testAPrecisePointLabelledApproximateIsPutOnTheSendersGrid() {
        var areas = ApproximateAreaMemory()
        let precise = fix(37.33645, -122.01100, at: 1_800_000_000, reported: 1)
        let drawn = areas.draw(precise, circleId: circle, userId: member)
        XCTAssertTrue(onSendersGrid(drawn.latitude, miles: 1), "\(drawn.latitude)")
        XCTAssertNotEqual(drawn.latitude, precise.latitude)
        let senders = LocationCoarsener.coarsenLocation(lat: 37.33645, lng: -122.01100, radiusMeters: 1_609.344)
        XCTAssertEqual(drawn.latitude, senders.0, accuracy: 0, "the senders' own formula")
        XCTAssertEqual(drawn.longitude, senders.1, accuracy: 0)
        XCTAssertEqual(drawn.timestamp, precise.timestamp)
        XCTAssertEqual(drawn.approximate?.drawnMiles, 1.25)

        // Snapped with the radius reported with it, or 1 mile when none is.
        for miles in [4.0, nil] {
            var fresh = ApproximateAreaMemory()
            let other = fresh.draw(fix(37.33645, -122.01100, at: 1_800_000_000, reported: miles),
                                   circleId: circle, userId: member)
            let cell = (miles ?? 1) * 1_609.344
            let expected = LocationCoarsener.coarsenLocation(lat: 37.33645, lng: -122.01100, radiusMeters: cell)
            XCTAssertEqual(other.latitude, expected.0, accuracy: 0, "reported \(String(describing: miles))")
            XCTAssertEqual(other.longitude, expected.1, accuracy: 0, "reported \(String(describing: miles))")
        }
    }

    /// A point the member's phone snapped is drawn exactly as it came: for
    /// every whole mile they can set, whatever radius comes with it — the
    /// server's round(r × (1 ± 0.2)) (a member at 3 miles reported as 2), an
    /// unrelated one, or none.
    func testASenderSnappedPointIsDrawnExactlyAsItCame() {
        for set in 1...25 {
            let snapped = LocationCoarsener.coarsenLocation(
                lat: 37.33645, lng: -122.01100, radiusMeters: Double(set) * 1_609.344)
            let low = max(1, (Double(set) * 0.8).rounded()), high = min(25, (Double(set) * 1.2).rounded())
            for miles in [low, Double(set), high, 1, 25, nil] {
                var areas = ApproximateAreaMemory()
                let drawn = areas.draw(fix(snapped.0, snapped.1, at: 1_800_000_000, reported: miles),
                                       circleId: circle, userId: member)
                XCTAssertEqual(drawn.latitude, snapped.0, accuracy: 0, "set \(set), reported \(String(describing: miles))")
                XCTAssertEqual(drawn.longitude, snapped.1, accuracy: 0, "set \(set), reported \(String(describing: miles))")
            }
        }
    }

    /// The grid is recognised after the trip through the payload, which packs
    /// latitude as an i32 × 1e7 (mobile-sdk location_codec), at every whole
    /// mile and far from the equator; and a precise point is not: of a
    /// thousand spread over a degree, hardly any pass by chance.
    func testTheGridTestSurvivesThePackingAndRejectsPrecisePoints() {
        for set in ApproximateArea.senderRadii {
            for latitude in [37.33645, -33.86882, 64.14660, 0.00321] {
                let snapped = LocationCoarsener.coarsenLocation(
                    lat: latitude, lng: 10, radiusMeters: Double(set) * 1_609.344).0
                let packed = (snapped * 1e7).rounded() / 1e7
                XCTAssertTrue(ApproximateArea.isOnSendersGrid(latitude: packed), "set \(set), latitude \(latitude)")
            }
        }
        let passing = (0..<1_000).filter { ApproximateArea.isOnSendersGrid(latitude: 37 + Double($0) * 0.000_987_654_3) }
        XCTAssertLessThan(passing.count, 10, "a precise point passes only by chance")
    }

    /// Accepted: a fix snapped under an older, larger radius — the member has
    /// since reduced theirs — is drawn as it came, with the smaller area, and
    /// may lie outside it until their next fix. Still coarse: nothing finer
    /// than their earlier grid is shown.
    func testAFixSnappedUnderAnOlderLargerRadiusIsDrawnAsItCame() {
        var areas = ApproximateAreaMemory()
        let snapped = LocationCoarsener.coarsenLocation(lat: 37.33645, lng: -122.01100, radiusMeters: 10 * 1_609.344)
        let drawn = areas.draw(fix(snapped.0, snapped.1, at: 1_800_000_000, reported: 3), circleId: circle, userId: member)
        XCTAssertEqual(drawn.latitude, snapped.0, accuracy: 0)
        XCTAssertEqual(drawn.longitude, snapped.1, accuracy: 0)
        XCTAssertEqual(drawn.approximate?.drawnMiles, 3.75)
    }

    /// The same fix served again with another radius stays where it was put —
    /// nothing jumps between refreshes. A new fix is decided afresh.
    func testALaterRefreshDoesNotMoveTheSnappedPoint() {
        var areas = ApproximateAreaMemory()
        let first = areas.draw(fix(37.33645, -122.01100, at: 1_800_000_000, reported: 2), circleId: circle, userId: member)
        for miles in [1.0, 3, 4, nil] {
            let again = areas.draw(fix(37.33645, -122.01100, at: 1_800_000_000, reported: miles),
                                   circleId: circle, userId: member)
            XCTAssertEqual(again.latitude, first.latitude, accuracy: 0, "reported \(String(describing: miles))")
            XCTAssertEqual(again.longitude, first.longitude, accuracy: 0, "reported \(String(describing: miles))")
        }
        // The member's phone sends its next fix, snapped on their grid: as it came.
        let senders = LocationCoarsener.coarsenLocation(lat: 37.3401, lng: -122.0207, radiusMeters: 2 * 1_609.344)
        let next = areas.draw(fix(senders.0, senders.1, at: 1_800_000_060, reported: 2), circleId: circle, userId: member)
        XCTAssertEqual(next.latitude, senders.0, accuracy: 0)
        XCTAssertEqual(next.longitude, senders.1, accuracy: 0)
        // Exact again forgets them: a later approximate spell starts afresh.
        let exact = LocationData(circleId: circle, userId: member, deviceId: "d", latitude: 37.33645,
                                 longitude: -122.01100, timestamp: Date(timeIntervalSince1970: 1_800_000_120))
        XCTAssertEqual(areas.draw(exact, circleId: circle, userId: member), exact, "exact rows as they came")
        XCTAssertEqual(areas.draw(fix(37.33645, -122.01100, at: 1_800_000_000, reported: 1), circleId: circle,
                                  userId: member).approximate?.drawnMiles, 1.25)
    }

    // MARK: - A real row, sealed as a member's phone seals it

    private func hex(fromBase64 b64: String) -> String {
        Data(base64Encoded: b64)!.map { String(format: "%02x", $0) }.joined()
    }

    private func base64(fromHex hex: String) -> String {
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return Data(bytes).base64EncodedString()
    }

    private func blob(_ e: EncryptedData) -> [String: Any] { ["nonce": e.nonce, "ciphertext": e.ciphertext] }

    /// The owner's row in a circle this device holds the key of, with
    /// `extra` fields beside it as the server adds them; decoded the live way.
    private func decodedOwnersRow(_ extra: [String: Any]) throws -> Track.CircleManager.RowDecode {
        let circle = "e0000000-0000-4000-8000-0000000000c1"
        let ownerId = "e0000000-0000-4000-8000-000000000001"
        let meId = "e0000000-0000-4000-8000-000000000002"
        let owner = CryptoManager(), me = CryptoManager()
        let ownerSharing = hex(fromBase64: owner.generateKeypair().publicKey)
        let ownerSigning = hex(fromBase64: owner.generateSigningKeypair().verifyingKeyB64)
        let meSharing = hex(fromBase64: me.generateKeypair().publicKey)
        let meSigning = hex(fromBase64: me.generateSigningKeypair().verifyingKeyB64)
        _ = try me.pinMemberKeys(circleId: circle, userId: ownerId,
                                 sharingPubkeyHex: ownerSharing, signingPubkeyHex: ownerSigning)
        let creation = try owner.prepareCircleCreation()
        try owner.finalizeCircleCreation(tempCircleId: creation.tempCircleId, realCircleId: circle)
        let bundle = try owner.wrapCircleKeyForMemberFull(
            circleId: circle, memberPublicKeyHex: meSharing, senderUserId: ownerId,
            recipientUserId: meId, recipientSigningPubkeyHex: meSigning)
        try me.storeCircleKey(
            circleId: circle,
            encryptedKey: bundle.encryptedCircleKey.nonce + bundle.encryptedCircleKey.ciphertext,
            senderPublicKey: bundle.ephemeralPublicKey, keyVersion: 1, senderUserId: ownerId,
            recipientUserId: meId, wrapSignatureHex: bundle.wrapSignature, senderSigningPubkeyHex: ownerSigning)

        let fixTime: Int64 = 1_800_000_000_000
        let envelope = try owner.envelopeEncryptLocationBound(
            location: Location(latitude: 37.3422, longitude: -122.0047, altitude: nil, speed: nil, heading: nil,
                               accuracy: 2_000, timestamp: fixTime, batteryLevel: 50, isCharging: nil),
            targetIds: [circle], senderPseudonym: try owner.deriveUserPseudonym(circleId: circle, userId: ownerId))
        let keyWrap = try XCTUnwrap(envelope.keyWraps.first)
        var json: [String: Any] = [
            "day_bucket": 20_833,
            "encrypted_payload": [
                "nonce": base64(fromHex: envelope.ciphertextNonce),
                "ciphertext": base64(fromHex: envelope.ciphertext),
                "wrapped_msg_key": base64(fromHex: keyWrap.wrappedKey),
                "wrapped_msg_key_nonce": base64(fromHex: keyWrap.wrappedKeyNonce),
            ],
            "encrypted_user_id": blob(try owner.encryptDataV2(circleId: circle, plaintext: ownerId, fieldTag: "user_id")),
            "encrypted_timestamp": blob(try owner.encryptDataV2(circleId: circle, plaintext: String(fixTime),
                                                                fieldTag: "timestamp")),
        ]
        json.merge(extra) { _, new in new }
        let response = try APIService.makeWireDecoder().decode(
            LocationResponse.self, from: JSONSerialization.data(withJSONObject: json))
        return CircleManager.decodeRow(response, circleId: circle, me: meId, crypto: me)
    }

    func testARowMarkedApproximateCarriesItsArea() throws {
        let decoded = try decodedOwnersRow(["sharing_mode": "approximate", "approximate_radius_miles": 2])
        guard case .live(let location, _) = decoded else { return XCTFail("expected live, got \(decoded)") }
        XCTAssertEqual(location.approximate, ApproximateArea(sharingMode: "approximate", radiusMiles: 2))
        XCTAssertEqual(location.approximate?.drawnMiles, 2.5)
        // The point is the centre of the area, as the sender snapped it: never moved here.
        XCTAssertEqual(location.latitude, 37.3422, accuracy: 1e-9)
    }

    func testARowMarkedExactOrUnmarkedIsAPosition() throws {
        for extra: [String: Any] in [["sharing_mode": "exact"], [:]] {
            let decoded = try decodedOwnersRow(extra)
            guard case .live(let location, _) = decoded else { return XCTFail("expected live, got \(decoded)") }
            XCTAssertNil(location.approximate, "\(extra)")
        }
    }

    // MARK: - The map

    func testAnApproximateMemberIsAnAreaAndYouAreNever() throws {
        let area = try XCTUnwrap(ApproximateArea(sharingMode: "approximate", radiusMiles: 2))
        XCTAssertEqual(try XCTUnwrap(MapLibreMapView.areaMeters(for: location(approximate: area), isMe: false)),
                       2.5 * 1_609.344, accuracy: 1e-6)
        XCTAssertNil(MapLibreMapView.areaMeters(for: location(), isMe: false), "an exact member is a pin")
        XCTAssertNil(MapLibreMapView.areaMeters(for: location(approximate: area), isMe: true), "your own view of yourself")
    }

    func testTheAreaIsACircleOfItsRadius() {
        let centre = CLLocationCoordinate2D(latitude: 37.3422, longitude: -122.0047)
        let here = CLLocation(latitude: centre.latitude, longitude: centre.longitude)
        let radius = 2.5 * 1_609.344
        let outline = ApproximateArea.outline(center: centre, radiusMeters: radius)
        XCTAssertEqual(outline.count, 72)
        for point in outline + ApproximateArea.extremes(center: centre, radiusMeters: radius) {
            let distance = CLLocation(latitude: point.latitude, longitude: point.longitude).distance(from: here)
            XCTAssertEqual(distance, radius, accuracy: radius * 0.005)
        }
        let extremes = ApproximateArea.extremes(center: centre, radiusMeters: radius)
        XCTAssertGreaterThan(extremes[0].latitude, centre.latitude)   // north
        XCTAssertGreaterThan(extremes[1].longitude, centre.longitude) // east
        XCTAssertLessThan(extremes[2].latitude, centre.latitude)      // south
        XCTAssertLessThan(extremes[3].longitude, centre.longitude)    // west
    }

    /// "Center on everyone" frames the whole area, not just its middle.
    func testFramingTakesInTheWholeArea() {
        let exact = MemberAnnotation()
        exact.coordinate = CLLocationCoordinate2D(latitude: 37.33, longitude: -122.03)
        let approximate = MemberAnnotation()
        approximate.coordinate = CLLocationCoordinate2D(latitude: 37.3422, longitude: -122.0047)
        approximate.approximateMeters = 4_000
        let framed = MapLibreMapView.framingCoordinates([exact, approximate])
        XCTAssertEqual(framed.count, 1 + 5)
        let maxLat = framed.map(\.latitude).max() ?? 0
        XCTAssertEqual(CLLocation(latitude: maxLat, longitude: -122.0047)
                        .distance(from: CLLocation(latitude: 37.3422, longitude: -122.0047)), 4_000, accuracy: 20)
    }

    private func place(at latitude: Double, _ longitude: Double) -> Place {
        Place(id: "p", circleId: "e0000000-0000-4000-8000-0000000000c1", name: "Park", latitude: latitude,
              longitude: longitude, radius: 300, placeType: "place", boundaryRadius: 300, alertsEnabled: true,
              icon: .custom, color: "#3B82F6", createdAt: Date(timeIntervalSince1970: 0), address: nil, notes: nil,
              wrappedKey: nil, wrappedKeyNonce: nil, wrapTargetId: nil)
    }

    /// No "At <Place>" worked out from the centre of an area.
    func testNoPlaceIsWorkedOutFromAnArea() throws {
        let area = try XCTUnwrap(ApproximateArea(sharingMode: "approximate", radiusMiles: 1))
        let park = place(at: 37.3349, -122.009)
        XCTAssertEqual(MapLibreMapView.placeOccupied(by: location(), in: [park])?.id, "p")
        XCTAssertNil(MapLibreMapView.placeOccupied(by: location(approximate: area), in: [park]))
    }

    func testTheMarkerSaysItIsApproximate() {
        XCTAssertEqual(MapLibreMapView.markerTitle(displayName: "Alex", isApproximate: true),
                       "Alex, approximate location")
        XCTAssertEqual(MapLibreMapView.markerTitle(displayName: "Alex", isApproximate: false), "Alex")

        let view = MemberMarkerView(reuseIdentifier: "member")
        view.configure(displayName: "Alex", ageMs: 60_000, fillColor: MemberPalette.colors[1], isCurrentUser: false,
                       atPlaceName: "Park", hasSOS: false, isApproximate: true)
        XCTAssertEqual(view.accessibilityLabel, "Alex, approximate location, 1m")
        view.configure(displayName: "Alex", ageMs: 60_000, fillColor: MemberPalette.colors[1], isCurrentUser: false,
                       atPlaceName: "Park", hasSOS: false, isApproximate: false)
        XCTAssertEqual(view.accessibilityLabel, "Alex, At Park")
    }

    // MARK: - The card and the row

    func testTheCardShowsNothingFinerThanTheArea() throws {
        let area = try XCTUnwrap(ApproximateArea(sharingMode: "approximate", radiusMiles: 2))
        let approximate = MemberDetailSheet.PositionDetail.of(location(approximate: area))
        XCTAssertEqual(approximate.approximateLine, "Approximate location")
        XCTAssertFalse(approximate.showsAddressAndCoordinates)
        XCTAssertFalse(approximate.offersShareAsDestination)
        XCTAssertFalse(approximate.offersCopyAddress)

        let exact = MemberDetailSheet.PositionDetail.of(location())
        XCTAssertNil(exact.approximateLine)
        XCTAssertTrue(exact.showsAddressAndCoordinates)
        XCTAssertTrue(exact.offersShareAsDestination)
        XCTAssertTrue(exact.offersCopyAddress)

        XCTAssertNil(MemberDetailSheet.PositionDetail.of(nil).approximateLine)
        XCTAssertFalse(MemberDetailSheet.PositionDetail.of(nil).showsAddressAndCoordinates)

        XCTAssertEqual(MemberDetailSheet.cardDetents(hasLocation: true, hasAddress: false, hasSharingSentence: false,
                                                     isApproximate: true),
                       [.height(200), .medium])
    }

    // SwiftUI builds its accessibility tree only while an assistive technology
    // is on — see MemberRowAccessibilityTests, whose switch this borrows.
    private func spokenLabels(of view: some View) throws -> [String] {
        typealias Getter = @convention(c) () -> Bool
        typealias Setter = @convention(c) (Bool) -> Void
        guard let lib = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW),
              let getter = dlsym(lib, "_AXSApplicationAccessibilityEnabled"),
              let setter = dlsym(lib, "_AXSApplicationAccessibilitySetEnabled") else {
            throw XCTSkip("this simulator runtime has no application accessibility switch")
        }
        let get = unsafeBitCast(getter, to: Getter.self)
        let set = unsafeBitCast(setter, to: Setter.self)
        let was = get()
        set(true)
        defer { set(was) }
        let host = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        var found: [String] = []
        collect(host.view, into: &found, depth: 0)
        window.isHidden = true
        return found
    }

    private func collect(_ object: NSObject, into found: inout [String], depth: Int) {
        guard depth < 30 else { return }
        if object.isAccessibilityElement, let label = object.accessibilityLabel, !label.isEmpty {
            found.append(label)
        }
        if let elements = object.accessibilityElements as? [NSObject] {
            for element in elements { collect(element, into: &found, depth: depth + 1) }
        } else {
            let count = object.accessibilityElementCount()
            if count != NSNotFound, count > 0 {
                for index in 0..<count {
                    if let element = object.accessibilityElement(at: index) as? NSObject {
                        collect(element, into: &found, depth: depth + 1)
                    }
                }
            }
        }
        if let view = object as? UIView {
            for subview in view.subviews { collect(subview, into: &found, depth: depth + 1) }
        }
    }

    func testTheRowIsSpokenAsApproximate() throws {
        let circle = Circle(id: "e0000000-0000-4000-8000-0000000000c1", name: "Family", isOwner: false,
                            keyRotationNeeded: false, keyVersion: 1)
        let member = CircleMember(circleId: circle.id, userId: "e0000000-0000-4000-8000-000000000001",
                                  displayName: "Alex", role: .member, canSeeRealtime: true, canSeeHistory: true,
                                  canRotateKeys: false, joinedAt: Date(), keyVersion: 1)
        let area = try XCTUnwrap(ApproximateArea(sharingMode: "approximate", radiusMiles: 2))
        let manager = CircleManager.shared
        let before = manager.memberLocations
        defer { manager.setMemberLocationsForTesting(before) }
        manager.setMemberLocationsForTesting([member.userId: location(approximate: area)])

        let spoken = try spokenLabels(of: List { MemberRow(member: member, circle: circle, onSecurityDetails: {}) })
        XCTAssertTrue(spoken.contains { $0.contains("Alex") && $0.contains("Approximate location") },
                      "spoken: \(spoken)")

        manager.setMemberLocationsForTesting([member.userId: location()])
        let exact = try spokenLabels(of: List { MemberRow(member: member, circle: circle, onSecurityDetails: {}) })
        XCTAssertFalse(exact.contains { $0.contains("Approximate location") }, "spoken: \(exact)")
    }
}
