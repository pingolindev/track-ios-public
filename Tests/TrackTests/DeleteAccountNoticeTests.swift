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

/// Deleting the account ends the session by choice: the sign-in screen that
/// follows says nothing about an involuntary sign-out, and keeps no address.
///
/// WHY THIS IS WORTH TESTING
///   The server ends the session as it deletes, and a request still in flight
///   then comes back revoked. `handleSessionRevoked` must not take that as an
///   involuntary sign-out while the app still reads as signed in: that would
///   put "You have been signed out, and location sharing has stopped…" on the
///   sign-in screen, with the deleted account's address filled in, and nothing
///   would clear it but a sign-in.
@MainActor
final class DeleteAccountNoticeTests: XCTestCase {

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

    /// The deletion marks its session as ending by choice from the request that
    /// ends it, and its own sign-out clears any notice and address a revocation
    /// set meanwhile.
    func testADeletionSaysNothingAboutAnInvoluntarySignOut() throws {
        let auth = try source("App/Managers/AuthManager.swift")
        let delete = try body(auth, from: "    func deleteAccount(", to: "    /// What to tell somebody about their money")
        let proof = try XCTUnwrap(delete.range(of: "        let token = try await reauthenticate(password: password)\n"))
        let marked = try XCTUnwrap(delete.range(of: """
                    sessionEndingByChoice = true
                    defer { sessionEndingByChoice = false }
                    let result = try await api.deleteAccount(
            """), "by choice from the request that ends the session")
        XCTAssertLessThan(proof.lowerBound, marked.lowerBound, "a wrong password ends nothing")
        XCTAssertTrue(delete.contains("""
                    await logout(retainingTrust: false)
                    signInNotice = nil
                    signInEmail = nil
                    SignedOutNotice.clear()
                    return result
            """), "no notice, no address, no notification left")
        XCTAssertEqual(auth.components(separatedBy: "sessionEndingByChoice = true").count - 1, 1, "the deletion alone")
    }

    /// A revocation still tears the session down during a deletion (one that
    /// fails after the server ended the session leaves no dead session up);
    /// only what says "signed out" stays quiet then. Any other revocation says
    /// it.
    func testARevocationStillTearsDownAndOtherwiseSaysSo() throws {
        let auth = try source("App/Managers/AuthManager.swift")
        let revoked = try body(auth, from: "    private func handleSessionRevoked() async {", to: "    /// The session ended without the person asking")
        XCTAssertTrue(revoked.contains("        guard isAuthenticated else { return }\n"), "never stands down")
        XCTAssertTrue(revoked.contains("        if !sessionEndingByChoice { ErrorBanner.shared.postSignedOut() }\n"))
        XCTAssertTrue(revoked.contains("        expireSession()\n        signedOutNotAsked(wasSharing: sharing)\n"),
                      "the teardown, unconditional")
        let notAsked = try body(auth, from: "    private func signedOutNotAsked(wasSharing: Bool) {", to: "    // MARK: - Session Management")
        let quiet = try XCTUnwrap(notAsked.range(of: "        guard !sessionEndingByChoice else { return }\n"))
        let notice = try XCTUnwrap(notAsked.range(of: "        signInNotice = SignedOutNotice.signInText(wasSharing: wasSharing)\n"))
        XCTAssertLessThan(quiet.lowerBound, notice.lowerBound)
    }
}
