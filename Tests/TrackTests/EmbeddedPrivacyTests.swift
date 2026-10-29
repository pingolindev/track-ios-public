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

/// Own privacy posture embedded in `GET /api/v1/circles` (`my_privacy`).
///
/// WHY THIS IS WORTH TESTING
///   The caller's OWN posture — the thing every send gate reads — comes
///   embedded per circle in `GET /circles`, so a refresh can skip one
///   `GET /privacy/circles/{id}` per circle. Three things must hold for that
///   to be safe:
///   - the embedded copy decodes, and its absence (an older backend) or null
///     (no privacy row yet) is NOT mistaken for a posture — it falls back to
///     the per-circle fetch;
///   - both paths translate the row through the SAME mapper, so a paused or
///     realtime-off circle is excluded from uploads either way;
///   - `loadCircles` actually skips the GET for circles that carried it.
final class EmbeddedPrivacyTests: XCTestCase {

    /// Circle ids are UUIDs: a list refuses any other. One per name here.
    private static let named: [String: String] = Dictionary(uniqueKeysWithValues:
        ["c1", "with", "without", "nulled", "a", "b", "open", "paused", "quiet"].map { ($0, UUID().uuidString.lowercased()) })

    private func cid(_ name: String) -> String { Self.named[name]! }

    /// The decoder APIService uses for every response body.
    private func decodeCircles(_ json: String) throws -> [CircleResponse] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode([CircleResponse].self, from: Data(json.utf8))
    }

    private func circleJSON(id: String, myPrivacy: String?) -> String {
        let privacyField = myPrivacy.map { ", \"my_privacy\": \($0)" } ?? ""
        return """
        {"id": "\(id)", "owner_id": "u1", "is_owner": false,
         "encrypted_name": {"nonce": "00", "ciphertext": "00"},
         "day_bucket": 20000, "member_count": 2, "key_version": 3\(privacyField)}
        """
    }

    /// The body `GET /api/v1/privacy/circles/{id}` returns, as the server sends it.
    private func privacyJSON(
        circleId: String,
        mode: String = "exact",
        pausedUntil: String? = nil,
        realtime: Bool = true,
        radius: Int? = nil,
        allowAlertsOnMe: Bool? = true
    ) -> String {
        let paused = pausedUntil.map { "\"\($0)\"" } ?? "null"
        let radiusField = radius.map(String.init) ?? "null"
        let allow = allowAlertsOnMe.map { $0 ? "true" : "false" } ?? "null"
        return """
        {"id": "p-\(circleId)", "circle_id": "\(circleId)", "sharing_mode": "\(mode)",
         "approximate_radius_miles": \(radiusField), "approximate_until": null,
         "paused_until": \(paused), "share_realtime": \(realtime), "share_history": true,
         "share_battery": true, "primary_device_id": null, "primary_device_pseudonym": null,
         "show_all_devices": false, "allow_alerts_on_me": \(allow),
         "created_day_bucket": 20000, "updated_day_bucket": 20001}
        """
    }

    // MARK: - Decoding

    func testTheEmbeddedRowDecodes() throws {
        let circles = try decodeCircles("[\(circleJSON(id: cid("c1"), myPrivacy: privacyJSON(circleId: cid("c1"), mode: "approximate", radius: 3)))]")
        let own = try XCTUnwrap(circles.first?.myPrivacy)
        XCTAssertEqual(own.circleId, cid("c1"))
        XCTAssertEqual(own.sharingMode, "approximate")
        XCTAssertEqual(own.approximateRadiusMiles, 3)
        XCTAssertEqual(own.updatedDayBucket, 20001)
    }

    func testAnOlderBackendWithoutTheFieldStillDecodes() throws {
        let circles = try decodeCircles("[\(circleJSON(id: cid("c1"), myPrivacy: nil))]")
        XCTAssertEqual(circles.count, 1, "the whole circle list must not fail over an optional field")
        XCTAssertNil(circles[0].myPrivacy)
    }

    func testANullRowDecodesAsAbsent() throws {
        let circles = try decodeCircles("[\(circleJSON(id: cid("c1"), myPrivacy: "null"))]")
        XCTAssertNil(circles[0].myPrivacy)
    }

    func testTheCachedListRoundTripsTheEmbeddedRow() throws {
        // CacheStore persists [CircleResponse] with a default JSONEncoder/Decoder;
        // an offline launch must restore the posture along with the circle.
        let circles = try decodeCircles("[\(circleJSON(id: cid("c1"), myPrivacy: privacyJSON(circleId: cid("c1"), mode: "paused")))]")
        let data = try JSONEncoder().encode(circles)
        let restored = try JSONDecoder().decode([CircleResponse].self, from: data)
        XCTAssertEqual(restored.first?.myPrivacy?.sharingMode, "paused")
    }

    // MARK: - The plan: embedded rows are applied, the rest are fetched

    func testEmbeddedCirclesNeedNoPrivacyGetAndTheRestStillDo() throws {
        let circles = try decodeCircles("""
        [\(circleJSON(id: cid("with"), myPrivacy: privacyJSON(circleId: cid("with")))),
         \(circleJSON(id: cid("without"), myPrivacy: nil)),
         \(circleJSON(id: cid("nulled"), myPrivacy: "null"))]
        """)
        let plan = CircleManager.privacyRefreshPlan(circleIds: ["with", "without", "nulled"].map(cid), responses: circles)
        XCTAssertEqual(Set(plan.embedded.keys), [cid("with")])
        XCTAssertEqual(plan.fetch, ["without", "nulled"].map(cid), "absent or null must fall back to the per-circle GET")
    }

    func testAnOlderBackendFetchesEveryCircle() throws {
        let circles = try decodeCircles("[\(circleJSON(id: cid("a"), myPrivacy: nil)), \(circleJSON(id: cid("b"), myPrivacy: nil))]")
        let plan = CircleManager.privacyRefreshPlan(circleIds: ["a", "b"].map(cid), responses: circles)
        XCTAssertTrue(plan.embedded.isEmpty)
        XCTAssertEqual(plan.fetch, ["a", "b"].map(cid))
    }

    func testARowForAnotherCircleIsNotTrusted() throws {
        let circles = try decodeCircles("[\(circleJSON(id: cid("c1"), myPrivacy: privacyJSON(circleId: "someone-else")))]")
        let plan = CircleManager.privacyRefreshPlan(circleIds: [cid("c1")], responses: circles)
        XCTAssertTrue(plan.embedded.isEmpty)
        XCTAssertEqual(plan.fetch, [cid("c1")])
    }

    // MARK: - Same values, same targets, either way

    func testTheEmbeddedRowMapsExactlyLikeTheFetchedOne() throws {
        // A paused row with NO expiry is a permanent pause; the radius is null
        // outside approximate mode; a missing consent flag means allowed.
        let body = privacyJSON(circleId: cid("c1"), mode: "paused", pausedUntil: nil, radius: nil, allowAlertsOnMe: nil)
        let circles = try decodeCircles("[\(circleJSON(id: cid("c1"), myPrivacy: body))]")
        let plan = CircleManager.privacyRefreshPlan(circleIds: [cid("c1")], responses: circles)
        let viaEmbedded = try XCTUnwrap(plan.embedded[cid("c1")])

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let fetched = try decoder.decode(PrivacySettingsResponse.self, from: Data(body.utf8))
        let viaGet = CircleManager.privacySettings(from: fetched)

        XCTAssertEqual(viaEmbedded, viaGet)
        XCTAssertTrue(viaEmbedded.isPaused)
        XCTAssertEqual(viaEmbedded.bubbleRadius, 1)
        XCTAssertTrue(viaEmbedded.allowAlertsOnMe)
    }

    func testUploadTargetsHonourAnEmbeddedPauseAndRealtimeOff() throws {
        let circles = try decodeCircles("""
        [\(circleJSON(id: cid("open"), myPrivacy: privacyJSON(circleId: cid("open")))),
         \(circleJSON(id: cid("paused"), myPrivacy: privacyJSON(circleId: cid("paused"), mode: "paused"))),
         \(circleJSON(id: cid("quiet"), myPrivacy: privacyJSON(circleId: cid("quiet"), realtime: false)))]
        """)
        let ids = ["open", "paused", "quiet"].map(cid)
        let plan = CircleManager.privacyRefreshPlan(circleIds: ids, responses: circles)
        let targets = CircleManager.uploadTargets(selfId: "self", circleIds: ids, privacy: plan.embedded)
        XCTAssertEqual(targets, ["self", cid("open")])
    }

    // MARK: - Wiring (source)

    private func source(_ relative: String) -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let path = root.appendingPathComponent(relative)
        guard let text = try? String(contentsOf: path, encoding: .utf8) else {
            XCTFail("could not read \(relative) at \(path.path)")
            return ""
        }
        return text
    }

    func testLoadCirclesFetchesPrivacyOnlyForCirclesThatLackedIt() {
        let manager = source("App/Managers/CircleManager.swift")
        XCTAssertTrue(manager.contains("Self.privacyRefreshPlan(circleIds: circles.map(\\.id), responses: responses)"),
                      "loadCircles consults the embedded posture")
        XCTAssertTrue(manager.contains("if privacyToFetch.contains(id) {"),
                      "the per-circle privacy GET only for the circles that lack it")
        XCTAssertTrue(manager.contains("privacySettings[circleId] = Self.privacySettings(from: response)"),
                      "the per-circle GET must share the embedded path's mapper")
    }
}
