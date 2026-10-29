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

/// WHICH requests are allowed to say what device this is.
///
/// WHY THE LOGIN SAYS IT
///   The request that CREATES a session is unauthenticated by definition. With
///   an anonymous User-Agent on it, the auth server has nothing to name the
///   device from and stores every iOS session as "Unknown Device" — and that is
///   the list a user reads in the account portal to spot a session that is not
///   theirs.
///
/// WHY NOTHING ELSE DOES
///   The anonymous UA is not an oversight, it is a feature. Geocode-token
///   redemption (in `APIService`) is deliberately sent with no Authorization so
///   the geocoder cannot tie a lookup to an account; a device-labeled UA plus
///   the source IP would hand back exactly the link that design removes. So the
///   device may identify itself to the login endpoint it is already handing a
///   password to, and to nothing else.
///
///   That makes the SCOPE the feature. A test that only checked "login sends
///   the device UA" would still pass on the day someone adds `identifyDevice:
///   true` to the geocode call and quietly undoes the privacy property. Both
///   directions are pinned below.
///
/// WHERE THE SERVER READS IT
///   The auth server takes the UA off the SRP STEP 1 request and keeps it with
///   the SRP session; step 2 creates the session and names the device from
///   that stored string — NOT from step 2's own headers. The two-factor branch
///   carries the same string through. So step 1 is the load-bearing half and
///   it covers the 2FA path too.
final class LoginUserAgentScopeTests: XCTestCase {

    private let deviceUA = "Track/9.9.9 (iPhone17,1; iOS 18.4) urlsession"
    private let anonymousUA = "Track/9.9.9 urlsession"

    private func userAgent(auth: Bool, identifyDevice: Bool) -> String? {
        var request = URLRequest(url: URL(string: "https://auth.example/api/v1/x")!)
        APIService.applyUserAgent(
            to: &request,
            auth: auth,
            identifyDevice: identifyDevice,
            deviceUA: deviceUA,
            anonymousUA: anonymousUA
        )
        return request.value(forHTTPHeaderField: "User-Agent")
    }

    // MARK: - The header the login pair actually sends

    func testLoginPairSendsTheDeviceUserAgent() {
        XCTAssertEqual(
            userAgent(auth: false, identifyDevice: true), deviceUA,
            """
            The SRP login pair is unauthenticated and must still name the device, \
            otherwise the session it creates is stored as "Unknown Device".
            """
        )
    }

    func testEveryOtherUnauthenticatedRequestStaysAnonymous() {
        XCTAssertEqual(
            userAgent(auth: false, identifyDevice: false), anonymousUA,
            """
            An unauthenticated request that is not the login pair must not be \
            attributable to this handset. Geocode-token redemption is the one \
            that matters: UA + source IP would re-link the "anonymous" lookup.
            """
        )
    }

    func testAuthenticatedRequestsAreUnchanged() {
        XCTAssertEqual(userAgent(auth: true, identifyDevice: false), deviceUA)
        XCTAssertEqual(userAgent(auth: true, identifyDevice: true), deviceUA)
    }

    /// The anonymous string must be anonymous in the specific way the SERVER
    /// reads it. The server takes the model out of the `(...)` comment, so
    /// "no parenthesised comment" is the actual property, not "a different
    /// string".
    func testTheTwoRealUserAgentsDifferWhereTheServerLooks() {
        let config = AppConfiguration.shared
        XCTAssertTrue(
            config.userAgent.contains("(") && config.userAgent.contains(")"),
            "the device UA must carry a `(model; iOS x)` comment: \(config.userAgent)"
        )
        XCTAssertFalse(
            config.anonymousUserAgent.contains("("),
            """
            the anonymous UA must carry NO parenthesised comment, or it names the \
            device anyway: \(config.anonymousUserAgent)
            """
        )
        // Both stay non-browser: the auth server treats a User-Agent without
        // "Mozilla" as a native client, and that decides the access-token TTL.
        // A UA change that reads as a browser would silently hand native clients
        // the long browser-shaped token.
        XCTAssertFalse(config.userAgent.contains("Mozilla"))
        XCTAssertFalse(config.anonymousUserAgent.contains("Mozilla"))
    }

    // MARK: - The scope itself

    /// `identifyDevice: true` may appear at exactly two call sites. This fails
    /// if a third request ever opts in — which is the failure that would matter,
    /// because it is silent at runtime and only visible as a lost privacy
    /// property.
    func testOnlyTheTwoLoginCallSitesOptIn() throws {
        let source = try Self.apiServiceSource()
        // Comment lines are excluded: the doc comments at those call sites quote
        // the flag on purpose, and counting prose as an opt-in would make this
        // assertion fail for a documentation edit.
        let optIns = Self.codeLines(of: source)
            .filter { $0.contains("identifyDevice: true") }
            .count
        XCTAssertEqual(
            optIns, 2,
            """
            expected `identifyDevice: true` at exactly 2 call sites (srpStep1, \
            srpStep2), found \(optIns). If you added a third, that request now \
            names this device on an unauthenticated call — check it is not one \
            of the geocode-token paths before changing this number.
            """
        )

        for name in ["srpStep1", "srpStep2"] {
            let body = try Self.body(ofFunc: name, in: source)
            XCTAssertTrue(
                body.contains("identifyDevice: true"),
                "\(name) must opt in, or the session it creates is named \"Unknown Device\""
            )
        }
    }

    /// The requests that must NOT opt in, named individually so a failure says
    /// which privacy property broke rather than just moving a count.
    /// Registration happens in the account portal, so the unauthenticated
    /// requests in this file are 2FA completion, the App Attest pair, and the
    /// geocode-token redemptions.
    func testTheAnonymousRequestsDidNotOptIn() throws {
        let source = try Self.apiServiceSource()
        let anonymous = [
            // Named from the stored step-1 UA, so opting in would change
            // nothing and only widen exposure.
            "verify2FA",
            // Sent before there is a session; a device label here would name
            // the handset to auth on a request that carries no password.
            "getAttestationChallenge", "verifyAppleAttestation",
            // The anonymous branch exists for these: UA + source IP would
            // re-link a lookup the missing Authorization was meant to unlink.
            "geocodeTokenKey", "geocodeRedeemReverse", "geocodeRedeemSearch",
        ]
        for name in anonymous {
            let body = try Self.body(ofFunc: name, in: source)
            XCTAssertFalse(
                body.contains("identifyDevice"),
                "\(name) must stay anonymous: only the SRP login pair may name this device"
            )
        }
        // Backstop for a geocode path added later under another name: no
        // opt-in appears anywhere near the word.
        for line in Self.codeLines(of: source) where line.contains("identifyDevice: true") {
            XCTAssertFalse(line.lowercased().contains("geocode"))
        }
    }

    // MARK: - Reading the source

    /// `#filePath` is this file's absolute path at compile time and the tests
    /// build and run from the same checkout, so the app source is two directories
    /// up. Unreadable is a FAILURE, never a skip: a tripwire that opts itself out
    /// is worse than no tripwire.
    static func apiServiceSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/TrackTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
        let url = root.appendingPathComponent("App/Services/APIService.swift")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw NSError(
                domain: "LoginUserAgentScopeTests", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "could not read \(url.path)"]
            )
        }
        return text
    }

    /// Source lines with `//` and `///` lines dropped, so prose that quotes a
    /// flag is never mistaken for a call site.
    static func codeLines(of source: String) -> [String] {
        source.components(separatedBy: "\n").filter {
            !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//")
        }
    }

    /// The source of one member function, its declaration line excluded so the
    /// doc comment above it does not get matched. Ends at the first `\n    }`,
    /// the closing brace of a member at this indent level.
    static func body(ofFunc name: String, in source: String) throws -> String {
        let start = try XCTUnwrap(
            source.range(of: "func \(name)("),
            "no `func \(name)(` in APIService.swift — was it renamed?"
        )
        let rest = source[start.upperBound...]
        let end = try XCTUnwrap(rest.range(of: "\n    }"), "could not find the end of \(name)")
        return String(rest[..<end.lowerBound])
    }
}
