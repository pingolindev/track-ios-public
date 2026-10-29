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

/// No session token and no key material in any debug log or diag file: a
/// refresh token stays usable for about a day after it is replaced, so a
/// logged one is a whole session.
final class LogRedactionTests: XCTestCase {
    private let jwt = "eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJ1c2VyIiwiZXhwIjoxfQ.c2lnbmF0dXJlLWJ5dGVz"
    private let refresh = "rt_Zq8fWm3kPq9sLx2Vb7Nc4Ty6Hj1Rd5Ge0Ua"

    /// Every token-shaped value in a scrubbed text — what the guard looks for.
    private func leaks(_ text: String) -> [String] {
        var found: [String] = []
        if text.range(of: #"eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"#, options: .regularExpression) != nil {
            found.append("jwt")
        }
        for secret in [jwt, refresh, "SRV-PROOF-9f3", "TWO-FA-77", "wrapped-master", "wrapped-sharing"] where text.contains(secret) {
            found.append(secret)
        }
        return found
    }

    func testReplyBodiesKeepNoTokens() throws {
        let bodies = [
            // SRP step 2 / login / refresh
            #"{"success":true,"data":{"access_token":"\#(jwt)","refresh_token":"\#(refresh)","server_proof":"SRV-PROOF-9f3","user":{"id":"u1"}}}"#,
            // two-factor challenge
            #"{"requires_2fa":true,"two_factor_token":"TWO-FA-77","available_methods":["totp"]}"#,
            // /auth/me: the password-wrapped keys
            #"{"success":true,"data":{"id":"u1","encrypted_keys":{"master_key":{"nonce":"n","ciphertext":"wrapped-master"},"sharing_private_key":{"nonce":"n","ciphertext":"wrapped-sharing"}}}}"#,
            // a JWT where no key says so
            #"{"note":"Bearer \#(jwt)"}"#,
        ]
        for body in bodies {
            let clean = String(decoding: LogRedaction.scrub(body: Data(body.utf8)), as: UTF8.self)
            XCTAssertEqual(leaks(clean), [], clean)
        }
        let kept = String(decoding: LogRedaction.scrub(body: Data(#"{"data":{"id":"u1","display_name":"Nadia"}}"#.utf8)), as: UTF8.self)
        XCTAssertTrue(kept.contains("Nadia") && kept.contains("u1"), "everything else stays readable")
    }

    /// A preview cut mid-body is not JSON any more; the text rules still hold.
    func testACutOffBodyKeepsNoTokensEither() {
        let body = #"{"success":true,"data":{"access_token":"\#(jwt)","refresh_token":"\#(refresh)","encrypted_keys":{"master_key":{"nonce":"n","ciphertext":"wrapped-mas"#
        let clean = LogRedaction.scrub(body)
        XCTAssertEqual(leaks(clean), [], clean)
    }

    func testCredentialHeadersWrittenAsTextAreScrubbed() {
        let text = "X-Refresh-Token: \(refresh) Authorization: Bearer \(jwt) Cookie=refresh_token=\(refresh)"
        let clean = LogRedaction.scrub(text)
        XCTAssertEqual(leaks(clean), [], clean)
    }

    /// The guard: every place that logs or writes a reply body or a free-text
    /// diagnostic goes through the scrub, and nothing logs a raw body.
    func testEveryDebugWriterScrubs() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func source(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }
        let api = try source("App/Services/APIService.swift")
        XCTAssertTrue(api.contains("let loggable = LogRedaction.scrub(body: data)"))
        XCTAssertTrue(api.contains("String(data: loggable.prefix(1200), encoding: .utf8)"))
        XCTAssertTrue(api.contains("try? loggable.write(to: url)"))
        XCTAssertFalse(api.contains("String(data: data.prefix("), "no raw body preview, in a log or in an error message")
        XCTAssertEqual(api.components(separatedBy: "String(data: LogRedaction.scrub(body: data).prefix(").count - 1, 2,
                       "the two DEBUG error messages that quote a reply")
        XCTAssertFalse(api.contains("try? data.write(to: url)"), "no raw body file")
        XCTAssertTrue(try source("App/Services/SDKLocationStreamer.swift").contains("[streamer] \\(LogRedaction.scrub(message))"))
        XCTAssertTrue(try source("App/Managers/PushNotificationManager.swift").contains("try? LogRedaction.scrub(message).write(to: url"))
        // Nothing logs a header or a token variable directly.
        let everything = try FileManager.default.subpathsOfDirectory(atPath: root.appendingPathComponent("App").path)
            .filter { $0.hasSuffix(".swift") }
            .map { try source("App/\($0)") }
            .joined(separator: "\n")
        for pattern in [#"(print|Log\.[a-z]+|log\.[a-z]+|trackDiagLog\.[a-z]+|appendStreamerDiag)\([^\n]*\\\((accessToken|refreshToken|token|tempToken|twoFactorToken)\b"#,
                        #"allHTTPHeaderFields"#] {
            XCTAssertNil(everything.range(of: pattern, options: .regularExpression), "logged token or headers: \(pattern)")
        }
    }
}
