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

/// A wrong two-step code doesn't throw away the sign-in.
///
/// The auth server keeps the attempt after a wrong code (five tries), ends it on the
/// fifth, and refuses one that expired or was already used. The app says which, by
/// the reply: a wrong code (401) and a code used a moment ago (400 `totp_replay`)
/// are typed again on the same sheet; too many wrong codes (429) and an ended
/// attempt (any other 400) go back to the password. The two-step route is never
/// retried or refreshed: a retry sends the same code again and spends another try,
/// and its 401 is a wrong code, not a dead token. APIService's URLSession is not
/// injectable, so the wiring is asserted on the source, as TwoFactorKeyUnlockTests
/// does; the live half is
/// AuthIntegrationTests.testAWrongTwoStepCodeIsTypedAgainOnTheSameAttempt.
final class TwoFactorRefusalTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func testTheRefusalsAreReadByStatusAndCode() {
        XCTAssertEqual(AuthManager.twoFactorRefusal(APIError(code: "http_401", message: "")), .wrongTwoFactorCode)
        XCTAssertEqual(AuthManager.twoFactorRefusal(APIError(code: "http_400", message: "", errorCode: "totp_replay")),
                       .twoFactorCodeJustUsed)
        XCTAssertEqual(AuthManager.twoFactorRefusal(APIError(code: "http_429", message: "", errorCode: "rate_limited")),
                       .twoFactorAttemptOver)
        XCTAssertEqual(AuthManager.twoFactorRefusal(APIError(code: "http_429", message: "")), .twoFactorAttemptOver)
        XCTAssertEqual(AuthManager.twoFactorRefusal(APIError(code: "http_400", message: "")), .twoFactorAttemptEnded)
        XCTAssertEqual(AuthManager.twoFactorRefusal(APIError(code: "http_400", message: "", errorCode: "other")),
                       .twoFactorAttemptEnded)
        for other in ["http_503", "http_500", "network_error", "circuit_open", "rate_limited", "unauthorized"] {
            XCTAssertNil(AuthManager.twoFactorRefusal(APIError(code: other, message: "")), other)
        }
        XCTAssertNil(AuthManager.twoFactorRefusal(URLError(.timedOut)))
    }

    func testTheWording() {
        let lines: [(AuthManager.AuthError, String)] = [
            (.wrongTwoFactorCode, "That code isn't right. Please try again."),
            (.twoFactorCodeJustUsed, "That code was just used. Wait for the next one and try again."),
            (.twoFactorAttemptOver, "Too many wrong codes. Please wait a while, then sign in again."),
            (.twoFactorAttemptEnded, "That sign-in has ended. Please sign in again."),
        ]
        for (error, line) in lines {
            XCTAssertEqual(error.errorDescription, line)
            XCTAssertEqual((error as Error).plainText, line, "what the sheet shows")
        }
    }

    /// The route answers by status and the auth server's
    /// code, before the 429 wait-and-retry and the 401
    /// refresh-and-retry.
    func testTheTwoStepRouteIsNeverRetriedOrRefreshed() throws {
        XCTAssertEqual(APIService.twoFactorLoginPath, "/api/v1/auth/login/2fa")
        let api = try source("App/Services/APIService.swift")
        XCTAssertTrue(api.contains("return try await post(path: Self.twoFactorLoginPath, body: body, auth: false, baseURL: config.authBaseURL)"))
        let start = try XCTUnwrap(api.range(of: "private func execute<T: Decodable>(_ request: URLRequest) async throws -> T {"))
        let body = api[start.upperBound...]
        let twoStep = try XCTUnwrap(body.range(of: """
            if path == Self.twoFactorLoginPath, !(200...299).contains(httpResponse.statusCode) {
        """))
        let refused = try XCTUnwrap(body.range(of: "throw APIError(code: \"http_\\(httpResponse.statusCode)\", message: \"Two-step sign-in refused\",\n                               errorCode: serverCode)"))
        XCTAssertTrue(body.contains("let serverCode = (try? decoder.decode(APIResponse<EmptyResponse>.self, from: data))?.error?.errorCode"),
                      "auth's code rides along: 400 totp_replay keeps the attempt")
        let retry429 = try XCTUnwrap(body.range(of: "if httpResponse.statusCode == 429 {"))
        let refresh401 = try XCTUnwrap(body.range(of: "if httpResponse.statusCode == 401 {"))
        XCTAssertLessThan(twoStep.lowerBound, refused.lowerBound)
        XCTAssertLessThan(refused.lowerBound, retry429.lowerBound)
        XCTAssertLessThan(retry429.lowerBound, refresh401.lowerBound)
    }

    /// A wrong or just-used code keeps the challenge; an attempt that is over or
    /// has ended drops it, so the sheet's OK goes back to the password.
    func testOnlyAnAttemptThatIsOverOrEndedIsDropped() throws {
        let auth = try source("App/Managers/AuthManager.swift")
        XCTAssertTrue(auth.contains("""
                    guard let refusal = Self.twoFactorRefusal(error) else { throw error }
                    if refusal == .twoFactorAttemptOver || refusal == .twoFactorAttemptEnded {
                        self.tempToken = nil
                        self.pendingPassword = nil
                        self.pendingEmail = nil
                    }
                    throw refusal
        """))
        let sheet = try source("App/Views/Auth/TwoFactorView.swift")
        XCTAssertTrue(sheet.contains("""
                            if authManager.tempToken == nil {
        """))
        XCTAssertTrue(sheet.contains("errorMessage = error.plainText"))
    }
}
