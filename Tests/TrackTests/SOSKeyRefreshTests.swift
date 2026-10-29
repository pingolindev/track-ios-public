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

/// An SOS sealed under a key another member just rotated to opens NOTHING on a
/// phone that hasn't fetched that key, and nothing else would fetch it: no push,
/// no circle load on open. So the SOS load asks for one light circle load first
/// (`openListed`), and every resume loads the circles first, at most once a
/// minute. The two-device test with real keys is RefreshRecordsChainTests'
/// `testAnSOSUnderAKeyNotYetFetchedOpensAfterOneLoadAndRingsOnce`.
@MainActor
final class SOSKeyRefreshTests: XCTestCase {
    private let circleId = "c7070000-0000-4000-8000-0000000000aa"

    private func blob() -> [String: Any] { ["nonce": "00", "ciphertext": "00"] }

    /// A listed SOS whose sealed parts open under no key here.
    private func sealed(id: String, status: String = "active") throws -> SOSResponse {
        let row: [String: Any] = [
            "id": id, "circle_id": circleId, "status": status, "day_bucket": 20_000,
            "encrypted_user_id": blob(), "encrypted_device_id": blob(), "encrypted_timestamp": blob(),
            "encrypted_location": blob(),
        ]
        return try APIService.makeWireDecoder().decode(SOSResponse.self, from: JSONSerialization.data(withJSONObject: row))
    }

    private func open(_ response: SOSResponse) -> SOSManager.OpenedSOS {
        SOSManager.openAlert(response, myUserId: nil, myDeviceId: nil, crypto: CryptoManager())
    }

    /// One that opens: what `open` gives once the key is here.
    private func openedStub(_ response: SOSResponse) -> SOSManager.OpenedSOS {
        var entry = open(response)
        entry.opened = SOSReceiverRules.Opened(raiserId: "c7070000-0000-4000-8000-0000000000b1", sealedTimeMs: 1,
                                               location: nil, current: true, payloadHash: "", raisedHere: false)
        return entry
    }

    /// A live SOS that never opens asks for ONE load, then not again for a
    /// minute; one that isn't live, or that opens, never asks.
    func testAnSOSThatNeverOpensLoadsOncePerMinute() async throws {
        let never = try sealed(id: "c7070000-0000-4000-8000-0000000000f1")
        var loads = 0
        var tried: [String: Date] = [:]
        let start = Date()
        func pass(_ responses: [SOSResponse], at offset: TimeInterval,
                  open: (SOSResponse) -> SOSManager.OpenedSOS) async -> [SOSManager.OpenedSOS] {
            await SOSManager.openListed(responses, open: open, refreshKeys: { loads += 1 }, tried: &tried,
                                        now: start.addingTimeInterval(offset))
        }
        _ = await pass([never], at: 0, open: open)
        XCTAssertEqual(loads, 1, "one load for it")
        XCTAssertEqual(tried[CanonicalId.key(never.id)], start)
        _ = await pass([never], at: 30, open: open)
        XCTAssertEqual(loads, 1, "not again within the minute")
        _ = await pass([try sealed(id: never.id.uppercased())], at: 45, open: open)
        XCTAssertEqual(loads, 1, "the same SOS spelt in capitals is the same one")
        _ = await pass([never], at: 61, open: open)
        XCTAssertEqual(loads, 2, "a minute later, once more")

        tried = [:]
        loads = 0
        _ = await pass([try sealed(id: "c7070000-0000-4000-8000-0000000000f2", status: "resolved"),
                        try sealed(id: "c7070000-0000-4000-8000-0000000000f3", status: "acknowledged")],
                       at: 0, open: open)
        XCTAssertEqual(loads, 0, "a closed SOS asks for nothing")
        _ = await pass([try sealed(id: "c7070000-0000-4000-8000-0000000000f4")], at: 0, open: openedStub)
        XCTAssertEqual(loads, 0, "one that opens asks for nothing")
        XCTAssertTrue(tried.isEmpty)
    }

    /// After the load, every SOS is opened AGAIN: what `open` gives then is
    /// what the load judges, not the first opening.
    func testTheLoadIsFollowedByASecondOpening() async throws {
        let response = try sealed(id: "c7070000-0000-4000-8000-0000000000f5")
        var keyHere = false
        var tried: [String: Date] = [:]
        let result = await SOSManager.openListed(
            [response], open: { keyHere ? self.openedStub($0) : self.open($0) }, refreshKeys: { keyHere = true },
            tried: &tried, now: Date())
        XCTAssertEqual(result.map(\.opened.current), [true], "opened again after the load")
        XCTAssertEqual(result.map(\.opened.opened), [true])
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func body(of start: String, until end: String, in text: String) throws -> Substring {
        let from = try XCTUnwrap(text.range(of: start), start)
        let to = try XCTUnwrap(text[from.upperBound...].range(of: end), end)
        return text[from.upperBound..<to.lowerBound]
    }

    /// The SOS load asks through `openListed`, with a light circle load as its
    /// refresh; the minute's memory goes at sign-out.
    func testTheSOSLoadAsksForKeysThroughOpenListed() throws {
        let sos = try source("App/Managers/SOSManager.swift")
        let load = try body(of: "    func loadActiveAlerts(quiet: Bool = false) async throws {", until: "\n    }\n", in: sos)
        XCTAssertTrue(load.contains(
            "        var tried = keyRefreshTried\n"
            + "        let opened = await Self.openListed(\n"
            + "            responses, open: { Self.openAlert($0, myUserId: myUserId, myDeviceId: myDeviceId, crypto: cryptoManager) },\n"
            + "            refreshKeys: { try? await CircleManager.shared.loadCircles(light: true) }, tried: &tried, now: Date())\n"
            + "        keyRefreshTried = tried\n"))
        XCTAssertFalse(load.contains("let opened = responses.map"), "never the first opening alone")
        let reset = try body(of: "    func reset() {", until: "\n    }\n", in: sos)
        XCTAssertTrue(reset.contains("        keyRefreshTried = [:]\n"))
    }

    /// On resume, a light circle load at most once a minute (the handler's
    /// throttle), BEFORE the places and the SOS loads that read under its keys.
    func testOnResumeTheCirclesLoadBeforePlacesAndSOS() throws {
        let app = try source("App/TrackApp.swift")
        let handler = try body(of: "                            if authManager.isAuthenticated {",
                               until: "                        }\n                    }", in: app)
        let gated = try XCTUnwrap(handler.range(of:
            "                                if throttle.allow(\"circles.light\") {\n"
            + "                                    try? await CircleManager.shared.loadCircles(light: true)\n"
            + "                                }\n"), "the resume load, behind the throttle")
        let places = try XCTUnwrap(handler.range(of: "try? await PlaceManager.shared.loadPlaces("))
        let sosLoad = try XCTUnwrap(handler.range(of: "try? await SOSManager.shared.loadActiveAlerts()"))
        XCTAssertLessThan(gated.upperBound, places.lowerBound, "before the places")
        XCTAssertLessThan(gated.upperBound, sosLoad.lowerBound, "before the SOS")
        XCTAssertEqual(app.components(separatedBy: "loadCircles(light: true)").count - 1, 1, "only there in the app's door")
        XCTAssertEqual(ForegroundRefreshThrottle.minimumInterval, 60)
    }
}
