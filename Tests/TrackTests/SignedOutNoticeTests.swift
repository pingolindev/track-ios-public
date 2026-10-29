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

/// A session that ends without the person asking, while Track isn't in front,
/// stops location sharing, and an in-app banner gone in 5 s is not enough to
/// say so. A notification says so when Track was sharing, and the sign-in
/// screen says why it is showing and fills in the address, as on Android
/// (`tracking_health_signed_out_*`).
final class SignedOutNoticeTests: XCTestCase {
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

    /// A notification only when Track was sharing and is in the background.
    func testItIsPostedOnlyWhenSharingAndInTheBackground() {
        XCTAssertTrue(SignedOutNotice.shouldPost(wasSharing: true, inBackground: true))
        XCTAssertFalse(SignedOutNotice.shouldPost(wasSharing: true, inBackground: false), "the sign-in screen says it")
        XCTAssertFalse(SignedOutNotice.shouldPost(wasSharing: false, inBackground: true), "nothing was being shared")
        XCTAssertFalse(SignedOutNotice.shouldPost(wasSharing: false, inBackground: false))
    }

    /// Android's words; the sign-in screen's line in two forms. Nothing about
    /// keys, and nothing the tap handler's copy sniffing would take for an
    /// invitation or a destination (it matches "invit" and "destination").
    func testTheWords() {
        XCTAssertEqual(SignedOutNotice.title, "You have been signed out of Track")
        XCTAssertEqual(SignedOutNotice.body,
                       "Location sharing has stopped. Tap to enter your password, and it starts again by itself.")
        XCTAssertEqual(SignedOutNotice.signInText(wasSharing: true),
                       "You have been signed out, and location sharing has stopped. Enter your password, and it starts again by itself.")
        XCTAssertEqual(SignedOutNotice.signInText(wasSharing: false),
                       "You have been signed out. Enter your password to sign in again.")
        for text in [SignedOutNotice.title, SignedOutNotice.body,
                     SignedOutNotice.signInText(wasSharing: true), SignedOutNotice.signInText(wasSharing: false)] {
            let lower = text.lowercased()
            XCTAssertFalse(lower.contains("key"), text)
            XCTAssertFalse(lower.contains("invit"), text)
            XCTAssertFalse(lower.contains("destination"), text)
        }
    }

    /// Both ends of a session the server ended: the revoked-session signal in a
    /// running app (sharing = tracking wanted, with location access, read
    /// before the session ends and stops it) and the definitive 401 at a
    /// launch (signed in with location access). Each still expires the
    /// session, never logs out. A sign-in clears the notice, the address and
    /// the notification; the sign-in screen fills the address in.
    func testItIsWiredToBothEndsAndClearedAtSignIn() throws {
        let auth = try source("App/Managers/AuthManager.swift")
        let revoked = try body(of: "    private func handleSessionRevoked() async {", until: "\n    }\n", in: auth)
        XCTAssertTrue(revoked.contains(
            "        let sharing = LocationService.shared.wantsTracking && LocationService.shared.hasLocationPermission\n"
            + "        expireSession()\n        signedOutNotAsked(wasSharing: sharing)"))
        XCTAssertFalse(revoked.contains("await logout()"), "the session ends, the account stays")
        let notAsked = try body(of: "    private func signedOutNotAsked(wasSharing: Bool) {", until: "\n    }\n", in: auth)
        XCTAssertTrue(notAsked.contains("signInNotice = SignedOutNotice.signInText(wasSharing: wasSharing)"))
        XCTAssertTrue(notAsked.contains("signInEmail = userId.flatMap(SignInEmails.saved(for:))"))
        XCTAssertTrue(notAsked.contains("inBackground: UIApplication.shared.applicationState == .background) {\n"
                                        + "            SignedOutNotice.post()"))
        XCTAssertTrue(auth.contains("                expireSession()\n"
                                    + "                // Signed in with location access, it was sharing until now.\n"
                                    + "                signedOutNotAsked(wasSharing: LocationService.shared.hasLocationPermission)\n"
                                    + "            } else {"), "the launch's definitive 401")
        XCTAssertEqual(auth.components(separatedBy: "signedOutNotAsked(wasSharing:").count - 1, 4,
                       "the two ends, the launch's read again (`retryLaunchRead`), and the function")
        XCTAssertTrue(auth.contains("        isAuthenticated = true\n        signInNotice = nil\n        signInEmail = nil\n"
                                    + "        SignedOutNotice.clear()\n"))

        let login = try source("App/Views/Auth/LoginView.swift")
        XCTAssertTrue(login.contains("if email.isEmpty, let saved = authManager.signInEmail { email = saved }"))
        XCTAssertTrue(login.contains("if let notice = authManager.signInNotice {"))
    }
}
