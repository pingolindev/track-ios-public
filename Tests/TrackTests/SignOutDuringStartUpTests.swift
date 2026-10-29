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

/// A sign-out, or an ended session, during the start-up's awaits starts nothing
/// after it.
///
/// WHY THIS IS WORTH TESTING
///   The start-up's tail, the location stream and tracking, runs after its last
///   await, and nothing else holds it: the gate reads allowed once a sign-out
///   has cleared it (`RegistrationGate.clear()`), and the sign-out has already
///   stopped tracking before the tail runs. Unless the tail checks, someone who
///   signed out while the app was starting could be left tracked, signed out.
///   A check of `isAuthenticated` alone wouldn't do: a sign-out clears it only
///   after its own awaits.
@MainActor
final class SignOutDuringStartUpTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func body(_ text: String, from start: String, to end: String) throws -> String {
        let from = try XCTUnwrap(text.range(of: start), start)
        let to = try XCTUnwrap(text.range(of: end, range: from.upperBound..<text.endIndex), end)
        return String(text[from.lowerBound..<to.lowerBound])
    }

    /// Every sign-out and ended session counts itself as it begins, before
    /// anything it awaits.
    func testEverySignOutCountsItselfFirst() throws {
        let auth = try source("App/Managers/AuthManager.swift")
        XCTAssertTrue(auth.contains("    func logout(retainingTrust: Bool = true) async {\n        sessionEpoch += 1\n"))
        XCTAssertTrue(auth.contains("    func expireSession() {\n        sessionEpoch += 1\n"))
        XCTAssertEqual(auth.components(separatedBy: "sessionEpoch += 1").count - 1, 2, "nothing else counts")
        XCTAssertTrue(auth.contains("""
            private func stillSignedIn(as me: String, since epoch: Int) -> Bool {
                sessionEpoch == epoch && userId == me
            }
        """))
    }

    /// Each start-up reads the count where it begins, and asks again after its
    /// last await, before the stream and tracking: the launch's, the sign-in's,
    /// and what an approval or a verified address opens.
    func testEveryStartUpAsksAgainBeforeTheStreamAndTracking() throws {
        let auth = try source("App/Managers/AuthManager.swift")
        let launch = try body(auth, from: "    func checkExistingSession() async {", to: "        #if DEBUG")
        XCTAssertTrue(launch.contains("        let epoch = sessionEpoch\n"), "read as the launch's check begins")
        XCTAssertTrue(auth.contains("        await startTrackServices(me: me, since: epoch)\n"), "the launch's, in completeLaunch")

        let start = try body(auth, from: "    private func startTrackServices(", to: "    /// Mirrors the Android app's SessionExpiredException gate.")
        let invites = try XCTUnwrap(start.range(of: "        await InvitesManager.shared.refresh()\n"), "the last await")
        let again = try XCTUnwrap(start.range(of: "        guard stillSignedIn(as: me, since: epoch) else { return }\n"))
        let stream = try XCTUnwrap(start.range(of: "SDKLocationStreamer.shared.start("))
        let tracking = try XCTUnwrap(start.range(of: "        locationService.startTracking()\n"))
        XCTAssertLessThan(invites.lowerBound, again.lowerBound)
        XCTAssertLessThan(again.lowerBound, stream.lowerBound)
        XCTAssertLessThan(again.lowerBound, tracking.lowerBound)
        XCTAssertEqual(start.components(separatedBy: "await ").count - 1,
                       start.prefix(upTo: again.lowerBound).components(separatedBy: "await ").count - 1,
                       "no await after the check")

        let signIn = try body(auth, from: "    private func completeLogin(", to: "    /// Undo what `completeLogin` wrote")
        let read = try XCTUnwrap(signIn.range(of: "        let epoch = sessionEpoch\n"))
        let first = try XCTUnwrap(signIn.range(of: "await "), "the sign-in's first await")
        XCTAssertLessThan(read.lowerBound, first.lowerBound, "read before anything the sign-in awaits")
        let signInAgain = try XCTUnwrap(signIn.range(of: "        guard stillSignedIn(as: me, since: epoch) else { return }\n"))
        let signInStream = try XCTUnwrap(signIn.range(of: "SDKLocationStreamer.shared.start("))
        let signInTracking = try XCTUnwrap(signIn.range(of: "        locationService.startTracking()\n"))
        XCTAssertLessThan(signInAgain.lowerBound, signInStream.lowerBound)
        XCTAssertLessThan(signInAgain.lowerBound, signInTracking.lowerBound)
        XCTAssertEqual(signIn.components(separatedBy: "await ").count - 1,
                       signIn.prefix(upTo: signInAgain.lowerBound).components(separatedBy: "await ").count - 1,
                       "no await after the check")

        let unlock = try body(auth, from: "    private func unlockTrack(", to: "    // MARK: - Account Deletion")
        let unlockRead = try XCTUnwrap(unlock.range(of: "        let epoch = sessionEpoch\n"))
        let refresh = try XCTUnwrap(unlock.range(of: "        try? await api.ensureFreshAccessToken()\n"))
        XCTAssertLessThan(unlockRead.lowerBound, refresh.lowerBound, "read before the refresh")
        XCTAssertTrue(unlock.contains("        guard isAuthenticated, stillSignedIn(as: me, since: epoch) else { return }\n"))
    }
}
