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

/// The re-seal's wiring (source): what records a send, when a re-seal runs, what
/// the viewer keeps across a rotation, and what goes with a circle and at
/// sign-out (as the Android app's LastKnownResealWiringTest).
final class LastKnownResealWiringTests: XCTestCase {

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

    /// A live send or a check-in records what the stream took, after it took
    /// it; a kept point and the past history never do.
    func testOnlyASendTheStreamTookIsRecorded() throws {
        let streamer = try source("App/Services/SDKLocationStreamer.swift")
        let send = try body(streamer, from: "    func send(circleId: String, location: PingolinTrackSDK.Location, kind: SendKind, capturedAt: Date? = nil) throws {",
                            to: "    private var keptDrain: Task<Void, Never>?")
        XCTAssertTrue(send.contains("""
                    let sent = try sendInner(circleId: circleId, location: location, kind: kind, capturedAt: capturedAt)
                    // The circle's latest row is now what this phone just sealed:
                    // kept for a re-seal after a rotation while real-time sharing
                    // there is off. Writing it never fails the send.
                    if let sent, let owner = AuthManager.shared.userId {
                        OwnLastSentStore.shared.put(sent, circleId: circleId, owner: owner)
                    }
        """))
        XCTAssertEqual(streamer.components(separatedBy: "OwnLastSentStore.shared.").count - 1, 1, "one writer")
        let past = try body(streamer, from: "    func sendPastHistory(circleId: String, location: PingolinTrackSDK.Location) throws {",
                            to: "    func send(circleId: String, location: PingolinTrackSDK.Location, kind: SendKind, capturedAt: Date? = nil) throws {")
        XCTAssertFalse(past.contains("OwnLastSent"))
        let drain = try body(streamer, from: "    func drainKeptLocations() {", to: "    private func sendInner(")
        XCTAssertFalse(drain.contains("OwnLastSent"))
    }

    /// The version and device pseudonym are read BEFORE the seal, and the
    /// record is made only after the stream took the send.
    func testTheVersionAndPseudonymAreReadBeforeTheSeal() throws {
        let streamer = try source("App/Services/SDKLocationStreamer.swift")
        let inner = try body(streamer, from: "    private func sendInner(", to: "    static func recordKind(")
        let version = try XCTUnwrap(inner.range(of: "let version = try? cryptoManager.getActiveVersion(circleId: circleId),"))
        let pseudonym = try XCTUnwrap(inner.range(
            of: "let devicePseudonym = try? cryptoManager.deriveDevicePseudonym(circleId: circleId, deviceId: deviceId) {"))
        let seal = try XCTUnwrap(inner.range(of: "return try cryptoManager.envelopeEncryptLocationBound("))
        let handed = try XCTUnwrap(inner.range(of: "throw SendError.transportFailed(underlying: error)"))
        let record = try XCTUnwrap(inner.range(of: "return OwnLastSent(sent: recordKind, envelope: envelope, wrap: wrap, point: location,"))
        XCTAssertLessThan(version.upperBound, seal.lowerBound)
        XCTAssertLessThan(pseudonym.upperBound, seal.lowerBound)
        XCTAssertLessThan(handed.upperBound, record.lowerBound)
        XCTAssertTrue(inner.contains("let recordKind = Self.recordKind(kind, circleId: circleId)"))
        XCTAssertTrue(inner.contains("                           coarsenedToMiles: applied.coarsenedToMiles,\n"))
        XCTAssertTrue(inner.contains("        let applied = privacyAppliedWithBubble(location, circleId: circleId, capturedAt: taken)\n"
                                     + "        let location = applied.location\n"), "the point as sealed")
    }

    /// A refresh of a circle runs its re-seal from the rows it read, as served,
    /// off its own path; the viewer's grace sits in the frozen merge.
    func testARefreshRunsTheReSealAndTheGrace() throws {
        let circles = try source("App/Managers/CircleManager.swift")
        let load = try body(circles, from: "    func loadMemberLocations(for circleId: String, surfaceFailures: Bool = true)",
                            to: "    private func setupLocationSync() {")
        XCTAssertTrue(load.contains("        let servedFrozen = wrapper.lastKnownServed ?? []\n"
                                    + "        Task { await LastKnownReseal.shared.run(circleId: circleId, served: servedFrozen) }\n"))
        XCTAssertEqual(circles.components(separatedBy: "LastKnownReseal.shared.run(").count - 1, 1)
        XCTAssertTrue(load.contains("""
                let carried = frozenGrace.carried(
                    circleId: circleId,
                    versionKnown: (try? cryptoManager.getActiveVersion(circleId: circleId)) != nil,
                    now: Date(),
                    previous: frozenLocations.filter { _, loc in loc.circleId == circleId },
                    current: drawnFrozen,
                    staleServed: decoded.frozenStale.filter { isShown($0, in: circleId) })
                for (userId, row) in carried { frozenNow[userId] = row }
                if frozenNow != frozenLocations { frozenLocations = frozenNow }
        """))
        XCTAssertTrue(load.contains("            drawnFrozen.insert(userId)\n"))
        let api = try source("App/Services/APIService.swift")
        XCTAssertTrue(api.contains("lastKnownServed = try? container.decodeIfPresent([ServedFrozenBlobs].self, forKey: .lastKnown)"))
        XCTAssertTrue(api.contains("try await post(path: \"/api/v1/circles/\\(circleId)/locations/last-known/reseal\", body: body)"))
        let blob = try body(api, from: "struct ResealBlob: Encodable, Equatable {", to: "\n}\n")
        XCTAssertFalse(blob.contains("wrapped"), "sealed straight under the circle key: no wrap")
    }

    /// A re-seal is a send: signed in, the streamer's own gate
    /// (`RegistrationGate.allowsTrack`), and tracking wanted, read afresh
    /// at every run.
    func testTheAccessGateIsTheStreamersOwn() throws {
        let reseal = try source("App/Services/LastKnownReseal.swift")
        XCTAssertTrue(reseal.contains(
            "AuthManager.shared.isAuthenticated && RegistrationGate.allowsTrack && LocationService.shared.wantsTracking"))
        let attempt = try body(reseal, from: "    private func attempt(", to: "    // MARK: - The rules")
        XCTAssertTrue(attempt.hasPrefix("    private func attempt(circleId: String, served: [ServedFrozenBlobs]) async throws -> Outcome {\n"
                                        + "        guard accessOpen(), let user = me(),\n"), "first, at every run")
    }

    /// What this phone last sent goes at every sign-out (it holds a point), and
    /// with the circle wherever what was kept for it goes; the grace goes with
    /// the circle's frozen rows and at sign-out.
    func testTheRecordAndTheGraceGoWithTheCircleAndAtSignOut() throws {
        let auth = try source("App/Managers/AuthManager.swift")
        let purge = try body(auth, from: "    private func purgeAccountData() async {", to: "\n    }\n")
        XCTAssertTrue(purge.contains("        OwnLastSentStore.shared.wipeAll()\n"), "every sign-out, whatever is kept")
        let circles = try source("App/Managers/CircleManager.swift")
        XCTAssertEqual(circles.components(separatedBy: "OwnLastSentStore.shared.forget(circleId:").count - 1, 4,
                       "a delete, a leave, a circle gone by the server's word, and a whole list without the circle")
        let gone = try body(circles, from: "    private func pruneGoneCircle(_ circleId: String) {", to: "\n    }\n")
        XCTAssertTrue(gone.hasSuffix("        Task { await DestinationsManager.shared.forgetCircle(circleId) }\n"
                                     + "        // And what this phone last sent there, kept for a re-seal: it holds a\n"
                                     + "        // point.\n"
                                     + "        OwnLastSentStore.shared.forget(circleId: circleId)"),
                      "a confirmed refusal and a whole list without it both prune through here")
        XCTAssertEqual(circles.components(separatedBy: "PendingCircleLocations.shared.discard(circleId:").count - 1, 4)
        let delete = try body(circles, from: "    func deleteCircle(_ circle: Circle) async throws {", to: "\n    }\n")
        XCTAssertTrue(delete.contains("        OwnLastSentStore.shared.forget(circleId: circle.id)\n"))
        let leave = try body(circles, from: "    func leaveCircle(_ circleId: String) async throws {", to: "\n    }\n")
        XCTAssertTrue(leave.contains("        OwnLastSentStore.shared.forget(circleId: circleId)"))
        let prune = try body(circles, from: "    private func pruneLocalCircle(circleId: String) {", to: "\n    }\n")
        XCTAssertTrue(prune.contains("        frozenLocations = frozenLocations.filter { _, loc in loc.circleId != circleId }\n"
                                     + "        frozenGrace.forget(circleId: circleId)\n"))
        XCTAssertTrue(circles.contains("        frozenLocations = [:]\n        frozenGrace.clear()\n"))
    }
}
