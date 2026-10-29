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

/// A failed GET /privacy/circles/{id} stands for the server's default posture, exact and sharing, only when
/// it is the server's own "no row yet": a 404 whose envelope carries the bare `"error"` string "Privacy
/// settings not found for this circle", which APIService labels `http_404`. APIService labels a 404 with no
/// JSON body `http_404` too, so taking any 404 as "no row" would let a proxy answering for a restarting
/// server seed EXACT, real time and battery on, for a person sharing approximately or with battery off — and
/// check-ins would go precise until the next full load (the Android app's `NO_PRIVACY_ROW` draws the same
/// line).
///
/// Any other 404 is thrown: nothing is seeded or recorded, so the send gates hold back, and the presence
/// posture is unknown, so a crossing waits rather than goes.
@MainActor
final class OnlyTheServersNoRowIsADefaultTests: XCTestCase {

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

    /// The server's answer word for word, decoded by APIService's own wire decoder, with the status
    /// APIService then puts on it (`testTheStatusIsPutOnAsAPIServiceDoes` holds that step to
    /// APIService's own lines).
    private func serversNoRow() throws -> APIError {
        let data = Data(#"{"success":false,"error":"Privacy settings not found for this circle"}"#.utf8)
        let error = try XCTUnwrap(try APIService.makeWireDecoder().decode(APIResponse<EmptyResponse>.self, from: data).error)
        XCTAssertEqual(error.code, "server_error", "the envelope's own label, before the status")
        return APIError(code: "http_404", message: error.message, errorCode: error.errorCode, quota: error.quota)
    }

    /// The step `serversNoRow` takes by hand is APIService's own: a failed request's body is decoded as an
    /// envelope by the wire decoder, and its `server_error` takes the status, keeping the server's words as the
    /// message. Were that to change, the server's real no-row answer would stop standing for its default, and
    /// sends to a circle with no row would wait for a full load.
    func testTheStatusIsPutOnAsAPIServiceDoes() throws {
        let api = try source("App/Services/APIService.swift")
        XCTAssertTrue(api.contains("        self.decoder = Self.makeWireDecoder()\n"))
        let failed = try body(api, from: "            guard (200...299).contains(httpResponse.statusCode) else {\n",
                              to: "            await CircuitBreaker.shared.record(success: circuitKey)\n")
        let decode = try XCTUnwrap(failed.range(of: """
                        if let apiResponse = try? decoder.decode(APIResponse<EmptyResponse>.self, from: data),
                           let error = apiResponse.error {
        """))
        XCTAssertNotNil(failed.range(of: #"""
                            if error.code == "server_error" {
                                throw APIError(
                                    code: "http_\(httpResponse.statusCode)",
                                    message: error.message,
        """#, range: decode.upperBound..<failed.endIndex))
    }

    func testTheServersOwnNoRowAnswerStandsForItsDefault() throws {
        XCTAssertTrue(CircleManager.isServersNoPrivacyRow(try serversNoRow()))
        XCTAssertTrue(CircleManager.isServersNoPrivacyRow(APIError(code: "not_found", message: CircleManager.noPrivacyRow)),
                      "the same words under a not-found code of the server's own")
    }

    /// What APIService throws for a 404 whose body isn't the server's JSON: "Request failed" in a release
    /// build, with the body's start after it in a debug one.
    func testAnIngress404IsNoAnswerAboutThePosture() {
        for message in ["Request failed", "Request failed: 404 page not found", "Request failed: "] {
            XCTAssertFalse(CircleManager.isServersNoPrivacyRow(APIError(code: "http_404", message: message)), message)
        }
    }

    func testAnotherNotFoundIsNoAnswerAboutThePosture() {
        for message in ["Circle not found", "Not found", "Privacy settings not found",
                        "privacy settings not found for this circle", ""] {
            XCTAssertFalse(CircleManager.isServersNoPrivacyRow(APIError(code: "http_404", message: message)), message)
            XCTAssertFalse(CircleManager.isServersNoPrivacyRow(APIError(code: "not_found", message: message)), message)
        }
        // The server's words on anything but a not-found aren't its no-row answer either.
        for code in ["server_error", "http_500", "http_403", "network_error"] {
            XCTAssertFalse(CircleManager.isServersNoPrivacyRow(APIError(code: code, message: CircleManager.noPrivacyRow)),
                           code)
        }
        XCTAssertFalse(CircleManager.isServersNoPrivacyRow(URLError(.notConnectedToInternet)))
    }

    /// Only that answer is seeded and recorded: the seed and its CirclePauseRecord observation sit inside its
    /// test, and anything else is thrown before either.
    func testOnlyThatAnswerIsSeededOrRecorded() throws {
        let circles = try source("App/Managers/CircleManager.swift")
        let fetch = try body(circles, from: "    func loadPrivacySettings(for circleId: String) async throws {",
                             to: "    /// The one translation from the server's privacy row")
        XCTAssertTrue(fetch.contains("""
                    if Self.isServersNoPrivacyRow(error) {
                        privacySettings[circleId] = .default(for: circleId)
                        CirclePauseRecord.shared.observe(.default(for: circleId), at: Date(), owner: AuthManager.shared.userId)
                        return
                    }
                    throw error
                }
        """))
        XCTAssertEqual(fetch.components(separatedBy: ".default(for: circleId)").count - 1, 2, "the seed and its record only")
        XCTAssertFalse(fetch.contains("isCircleNotFound"))
    }

    /// Nothing seeded is a posture not known: the send gates hold back, and a crossing waits.
    func testNothingSeededHoldsTheSendsBack() throws {
        let unseen = UUID().uuidString.lowercased()
        XCTAssertNil(CircleManager.shared.privacySettings[unseen])
        XCTAssertFalse(CircleManager.shared.mayStreamRealtime(to: unseen))
        guard case .none = CheckInManager.privacyNow(circleId: unseen) else {
            return XCTFail("a check-in sends no position to a circle whose posture isn't known")
        }
        let circles = try source("App/Managers/CircleManager.swift")
        let posture = try body(circles, from: "    func presencePosture(for circleId: String) async -> PresencePosture {",
                               to: "        guard privacySettings[circleId] != nil else { return .unknown }")
        let load = try XCTUnwrap(posture.range(of: "                try await loadPrivacySettings(for: circleId)\n"
                                               + "            } catch {\n"))
        let unknown = try XCTUnwrap(posture.range(of: "                return .unknown\n"))
        XCTAssertLessThan(load.upperBound, unknown.lowerBound)
    }
}
