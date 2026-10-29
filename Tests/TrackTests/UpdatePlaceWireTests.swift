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

/// What goes over the wire when an existing place is edited.
///
/// WHY THIS EXISTS SEPARATELY FROM CreatePlaceWireTests
///   This is the route by which a place actually gets RESIZED, so the radius
///   must go out under the server's own key, `radius_meters`, and nowhere else.
///   A field the server doesn't read is where a value gets hidden: even an
///   inert one (always nil, so the synthesized encoder omits it) is one
///   `?? fallback` away from carrying the user's radius. The server reads the
///   same request shape on this route as on create and has no such field, so
///   anything put there would be dropped, answered 200, and lost.
///
/// These assert on `URLRequest.httpBody` for the same reason the create tests
/// do: the local `Place` is not evidence about what the server was told.
final class UpdatePlaceWireTests: XCTestCase {

    private func blob(_ tag: String) -> EncryptedBlobRequest {
        EncryptedBlobRequest(nonce: "aa\(tag)", ciphertext: "bb\(tag)")
    }

    /// Build the request `updatePlace` builds, and hand back the decoded JSON
    /// of a real `URLRequest.httpBody`.
    private func wireBody(radius: Double) throws -> [String: Any] {
        let request = UpdatePlaceRequest(
            encryptedName: blob("name"),
            encryptedAddress: nil,
            encryptedLocation: blob("loc"),
            radiusMeters: PlaceManager.wireRadius(for: radius),
            icon: "home",
            color: "#4CAF50",
            encryptedNotes: nil
        )

        var urlRequest = URLRequest(url: URL(string: "https://api.invalid/api/v1/places/abc")!)
        urlRequest.httpMethod = "PUT"
        urlRequest.httpBody = try APIService.encodeRequestBody(request)

        let body = try XCTUnwrap(urlRequest.httpBody, "the PUT must carry a body")
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any],
            "body must be a JSON object"
        )
    }

    /// The update body carries neither `boundary_radius` nor `place_type`.
    /// Neither field exists server-side, so either one would be a place a
    /// radius can be hidden and silently discarded.
    func testTheUpdateCarriesNoFieldTheServerWillDiscard() throws {
        let json = try wireBody(radius: 2_000)

        XCTAssertNil(
            json["boundary_radius"],
            "the resize route must not carry a field serde will drop"
        )
        XCTAssertNil(
            json["place_type"],
            "place and boundary were collapsed; the server has no place_type"
        )
    }

    /// An edited radius has to arrive under the key the server reads.
    func testTheEditedRadiusIsWhatIsSent() throws {
        let json = try wireBody(radius: 2_000)

        XCTAssertEqual(json["radius_meters"] as? Int, 2_000)
    }

    /// And nowhere else. A rename would put the value into a field the
    /// server ignores, and the user's chosen radius would be lost on resize.
    func testTheRadiusAppearsOnlyUnderTheServersOwnKey() throws {
        let json = try wireBody(radius: 3_100)

        XCTAssertNotNil(json["radius_meters"], "server reads radius_meters; got keys \(json.keys.sorted())")
        let elsewhere = json.filter { $0.key != "radius_meters" && ($0.value as? Int) == 3_100 }
        XCTAssertTrue(elsewhere.isEmpty, "radius also sent under \(elsewhere.keys.sorted())")
    }

    /// `editableRange(for:)` deliberately admits a place larger than the slider
    /// range so opening the editor cannot shrink it. That only helps if saving
    /// then carries the large value through — a clamp here would undo on Save
    /// exactly what the stretched range protected on open.
    func testAnOversizePlaceSurvivesBeingSaved() throws {
        let json = try wireBody(radius: 12_000)

        XCTAssertEqual(
            json["radius_meters"] as? Int, 12_000,
            "a 12 km place must not be shrunk by saving an unrelated edit"
        )
    }

    /// The server applies the same `(50, 25000)` check on update as on create,
    /// so the same guard applies: clamp rather than send something to be
    /// refused. A 400 here reads to the user as "saving failed" with no mention
    /// of a radius — and the sheet stays open on an edit that cannot succeed.
    func testAnOutOfBandRadiusIsClampedRatherThanRefused() throws {
        XCTAssertEqual(try wireBody(radius: 40)["radius_meters"] as? Int, 50)
        XCTAssertEqual(try wireBody(radius: 90_000)["radius_meters"] as? Int, 25_000)
    }
}
