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

/// What actually goes over the wire when a place is created.
///
/// ONE RADIUS, IN `radius_meters`
///   The server's create request takes the place's radius as `radius_meters`
///   — a place has ONE geofence radius, so a place's radius IS its alert
///   geofence — and has no `boundary_radius` or `place_type` field. Unknown
///   fields are dropped without complaint and the request still answers 200,
///   so a radius sent under another name, with a placeholder in
///   `radius_meters`, silently creates every place at the placeholder,
///   whatever the user picked: a deliberate user decision discarded with no
///   error on either side.
///
/// WHY THESE ASSERT ON THE REQUEST BODY
///   The local model can be right while the wire is wrong: `createPlace`
///   returns a `Place` holding the radius the user picked whatever it sent,
///   so a test reading the returned object proves nothing about the request.
///   The claim that matters is about the bytes, so the bytes are what is
///   asserted: `encodeRequestBody` is the same encoder `post` puts in
///   `URLRequest.httpBody`.
final class CreatePlaceWireTests: XCTestCase {

    private func blob(_ tag: String) -> EncryptedBlobRequest {
        EncryptedBlobRequest(nonce: "aa\(tag)", ciphertext: "bb\(tag)")
    }

    /// Build the request `createPlace` builds, and hand back the decoded JSON
    /// of a real `URLRequest.httpBody`.
    private func wireBody(radius: Double) throws -> [String: Any] {
        let request = CreatePlaceRequest(
            circleId: nil,
            encryptedName: blob("name"),
            encryptedAddress: nil,
            encryptedLocation: blob("loc"),
            radiusMeters: PlaceManager.wireRadius(for: radius),
            icon: "home",
            color: "#4CAF50",
            encryptedUserId: blob("user"),
            encryptedNotes: nil,
            wrappedKey: "cafe",
            wrappedKeyNonce: "f00d"
        )

        var urlRequest = URLRequest(url: URL(string: "https://api.invalid/api/v1/places")!)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = try APIService.encodeRequestBody(request)

        let body = try XCTUnwrap(urlRequest.httpBody, "the POST must carry a body")
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any],
            "body must be a JSON object"
        )
    }

    // MARK: - The chosen radius

    /// The whole contract in one assertion: the number the user chose has to
    /// be the number in `radius_meters`.
    func testTheChosenRadiusIsWhatIsSent() throws {
        let json = try wireBody(radius: 2_000)

        XCTAssertEqual(
            json["radius_meters"] as? Int, 2_000,
            "the user picked 2000 m; anything else is their choice being discarded"
        )
    }

    /// Stated separately because 100 is not an arbitrary wrong answer: it
    /// is the hard-coded placeholder a broken request would carry.
    func testTheRadiusIsNotTheHardCodedPlaceholder() throws {
        let json = try wireBody(radius: 5_000)

        XCTAssertNotEqual(
            json["radius_meters"] as? Int, 100,
            "100 is the placeholder that would swallow every chosen radius"
        )
    }

    /// The mechanism. These two keys are what would make the loss silent: the
    /// server has neither, it discards unknown fields without complaint, and
    /// a 200 comes back. A request that carries them can hide a value in one
    /// of them.
    func testTheRequestCarriesNoFieldTheServerWillDiscard() throws {
        let json = try wireBody(radius: 2_000)

        XCTAssertNil(
            json["boundary_radius"],
            "the server has no such field; serde drops it and the value vanishes"
        )
        XCTAssertNil(
            json["place_type"],
            "place and boundary were collapsed; the server has no place_type"
        )
    }

    /// And the radius must not be reachable under any other key — a rename
    /// would reintroduce a silently-dropped field.
    func testTheRadiusAppearsUnderTheServersOwnKey() throws {
        let json = try wireBody(radius: 3_100)

        XCTAssertNotNil(json["radius_meters"], "server reads radius_meters; got keys \(json.keys.sorted())")
        let elsewhere = json.filter { $0.key != "radius_meters" && ($0.value as? Int) == 3_100 }
        XCTAssertTrue(elsewhere.isEmpty, "radius also sent under \(elsewhere.keys.sorted())")
    }

    // MARK: - The guards

    /// MapView passes `addBoundary ? radiusMeters : 0`, so a create with no
    /// alert area asked for arrives here as 0. The server's floor is 50, so a
    /// literal 0 would 400 the entire create — the user would be told saving
    /// failed, with no mention of a radius.
    func testNoAlertAreaChosenStillProducesAValidRadius() throws {
        let json = try wireBody(radius: 0)
        let sent = try XCTUnwrap(json["radius_meters"] as? Int)

        XCTAssertGreaterThanOrEqual(sent, 50, "0 would be refused by the DB CHECK")
        XCTAssertEqual(sent, Int(PlaceRadius.range.lowerBound),
                       "falls back to the range floor — the value that was stored anyway")
    }

    /// The server answers 400 outside `(50, 25000)` on both create and update.
    /// Clamp rather than send something to be refused: this is a public
    /// entry point, and the sliders are not the only possible caller.
    func testAnOutOfBandRadiusIsClampedNotRefused() {
        XCTAssertEqual(PlaceManager.wireRadius(for: 40), 50, "below the DB floor")
        XCTAssertEqual(PlaceManager.wireRadius(for: 90_000), 25_000, "above the DB ceiling")
        XCTAssertEqual(PlaceManager.wireRadius(for: -12), Int(PlaceRadius.range.lowerBound),
                       "negative is not a size; treat it as unset")
    }

    /// `radius_meters` is `i32` server-side and the model carries a Double, so
    /// the conversion has to round rather than truncate — and NaN must not
    /// reach `Int(_:)`, which traps.
    func testTheRadiusIsRoundedAndNonFiniteIsSurvivable() {
        XCTAssertEqual(PlaceManager.wireRadius(for: 149.6), 150)
        XCTAssertEqual(PlaceManager.wireRadius(for: 149.4), 149)
        XCTAssertEqual(PlaceManager.wireRadius(for: .nan), Int(PlaceRadius.range.lowerBound))
        XCTAssertEqual(PlaceManager.wireRadius(for: .infinity), Int(PlaceRadius.range.lowerBound),
                       "infinity is not a size either")
    }

    /// Every value the sliders can produce must survive the trip unchanged —
    /// no clamping, no rounding drift, at either end of the shared range.
    func testEveryValueTheSlidersCanProduceIsSentVerbatim() throws {
        var meters = PlaceRadius.range.lowerBound
        while meters <= PlaceRadius.range.upperBound {
            let json = try wireBody(radius: meters)
            XCTAssertEqual(json["radius_meters"] as? Int, Int(meters),
                           "\(meters) m did not survive the wire")
            meters += PlaceRadius.step
        }
    }
}
