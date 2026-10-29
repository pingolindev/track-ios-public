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

/// A destination is this account's only when the id sealed by its creator
/// AND the server's own creator field (`user_id`) both name this account.
/// Any member can seal any id; the server alone can say anything. Neither
/// half alone makes it this account's list entry, its to cancel, arrive at
/// or delete, "Your destination" on the map, or its AUTOMATIC arrival.
@MainActor
final class DestinationOwnershipTests: XCTestCase {

    private let me = "b1000000-0000-4000-8000-000000000001"
    private let other = "b1000000-0000-4000-8000-000000000002"

    private func destination(_ id: String = "d-1", sealed: String, creator: String?,
                             status: Destination.Status = .active) -> Destination {
        Destination(id: id, circleId: "b1000000-0000-4000-8000-0000000000c1", userId: sealed, name: "Home",
                    latitude: 52.5, longitude: 13.4, status: status, notifyArrival: true,
                    estimatedArrivalAt: nil, startedAt: Date(), arrivedAt: nil, creatorId: creator)
    }

    func testMineNeedsBothHalvesInAnySpelling() {
        XCTAssertTrue(destination(sealed: me, creator: me).isMine(me))
        XCTAssertTrue(destination(sealed: me.uppercased(), creator: me.replacingOccurrences(of: "-", with: "")).isMine(me))
        XCTAssertTrue(destination(sealed: me, creator: me).isMine(me.uppercased()))
        XCTAssertFalse(destination(sealed: me, creator: other).isMine(me), "sealed as me by a member")
        XCTAssertFalse(destination(sealed: other, creator: me).isMine(me), "the server alone")
        XCTAssertFalse(destination(sealed: me, creator: nil).isMine(me), "no creator field: fail closed")
        XCTAssertFalse(destination(sealed: other, creator: other).isMine(me))
        XCTAssertFalse(destination(sealed: me, creator: me).isMine(nil))
        XCTAssertFalse(destination(sealed: "self", creator: "self").isMine("self"), "no UUID is anyone")
    }

    func testTheAnswerCarriesTheServersCreator() throws {
        func decode(_ userId: String?) throws -> DestinationResponse {
            var json: [String: Any] = [
                "id": "d-1", "circle_id": "c", "encrypted_user_id": ["nonce": "00", "ciphertext": "00"],
                "encrypted_destination": ["nonce": "00", "ciphertext": "00"], "notify_arrival": true,
                "status": "active", "started_day_bucket": 20_000, "created_day_bucket": 20_000,
                "updated_day_bucket": 20_000,
            ]
            if let userId { json["user_id"] = userId }
            return try APIService.makeWireDecoder().decode(
                DestinationResponse.self, from: JSONSerialization.data(withJSONObject: json))
        }
        XCTAssertEqual(try decode(me).userId, me)
        XCTAssertNil(try decode(nil).userId, "an older server still decodes")
    }

    /// Only this account's own live destinations are ever reported by
    /// themselves.
    func testTheAutomaticArrivalTakesOnlyThisAccountsOwn() {
        let all = [
            destination("mine", sealed: me, creator: me),
            destination("sealed-as-me", sealed: me, creator: other),
            destination("server-says-me", sealed: other, creator: me),
            destination("theirs", sealed: other, creator: other),
            destination("mine-over", sealed: me, creator: me, status: .arrived),
        ]
        XCTAssertEqual(DestinationsManager.ownLive(in: all, me: me).map(\.id), ["mine"])
        XCTAssertEqual(DestinationsManager.ownLive(in: all, me: nil).map(\.id), [])
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// The seven places that decide it, one rule.
    func testEverySiteAsksTheOneRule() throws {
        let manager = try source("App/Managers/DestinationsManager.swift")
        XCTAssertTrue(manager.contains("return destinations.filter { $0.isMine(userId) }"), "the list")
        XCTAssertTrue(manager.contains("let mine = Self.ownLive(in: destinations, me: userId)"), "the automatic arrival")
        XCTAssertTrue(manager.contains("guard destination.isMine(AuthManager.shared.userId) else {\n"
                                       + "            throw APIError(code: \"not_owner\", message: \"You can only cancel your own destinations\")"))
        XCTAssertTrue(manager.contains("guard destination.isMine(userId) else {\n"
                                       + "            throw APIError(code: \"not_owner\", message: \"You can only report arrival for your own destinations\")"))
        XCTAssertTrue(manager.contains("guard destination.isMine(AuthManager.shared.userId) else {\n"
                                       + "            throw APIError(code: \"not_owner\", message: \"You can only delete your own destinations\")"))
        XCTAssertFalse(manager.contains("destination.userId == "))
        XCTAssertFalse(manager.contains("$0.userId == userId"))
        // Both decoders carry the server's creator.
        XCTAssertEqual(manager.components(separatedBy: "creatorId: response.userId").count - 1, 2)
        let view = try source("App/Views/Destinations/DestinationsView.swift")
        XCTAssertTrue(view.contains("row.isMine(AuthManager.shared.userId)"))
        let map = try source("App/Views/Map/MapLibreMapView.swift")
        XCTAssertTrue(map.contains("if dest.isMine(currentUserId) { return \"Your destination\" }"))
    }
}
