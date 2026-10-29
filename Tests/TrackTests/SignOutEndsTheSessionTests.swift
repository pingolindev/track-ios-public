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

/// A sign-out ends its session even when the access token has expired. POST
/// /auth/logout names the session by its refresh token in the body (the auth
/// server finds it by the current or a just-retired token), with the Bearer
/// when there is one: inside the few-second cap, with no refresh first and
/// none on a 401, and before anything is wiped.
final class SignOutEndsTheSessionTests: XCTestCase {

    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    func testTheBodyNamesTheRefreshToken() throws {
        let named = try APIService.encodeRequestBody(LogoutRequest(refreshToken: "r-token"))
        XCTAssertEqual(try JSONSerialization.jsonObject(with: named) as? [String: String],
                       ["refresh_token": "r-token"])
        let none = try APIService.encodeRequestBody(LogoutRequest(refreshToken: nil))
        XCTAssertEqual(String(data: none, encoding: .utf8), "{}")
    }

    func testASignOutIsNeverRefreshed() throws {
        XCTAssertTrue(APIService.neverRefreshed(path: "/api/v1/auth/logout"))
        XCTAssertFalse(APIService.neverRefreshed(path: "/api/v1/auth/me"))
        XCTAssertFalse(APIService.neverRefreshed(path: nil))
        let api = try source("App/Services/APIService.swift")
        let branch = try XCTUnwrap(api.range(of: "if httpResponse.statusCode == 401 {"))
        let rest = branch.upperBound..<api.endIndex
        let never = try XCTUnwrap(api.range(of: "if Self.neverRefreshed(path: request.url?.path) {", range: rest))
        let refresh = try XCTUnwrap(api.range(of: "try await refreshTokenIfNeeded()", range: rest))
        XCTAssertLessThan(never.lowerBound, refresh.lowerBound, "refused before any refresh")
        XCTAssertTrue(api.contains("""
                try await post(path: Self.logoutPath, body: LogoutRequest(refreshToken: refreshToken),
                               auth: keychain.getString(for: .accessToken) != nil, baseURL: config.authBaseURL)
        """), "the Bearer only when there is one")
    }

    /// The sign-out reads the refresh token and sends it inside the 4 s cap,
    /// before the purge and the keychain wipe.
    func testTheSignOutSendsItFirstAndWithinTheCap() throws {
        let auth = try source("App/Managers/AuthManager.swift")
        let end = try XCTUnwrap(auth.range(of: "private func endServerSession() async {"))
        let body = auth[end.upperBound...].prefix(900)
        XCTAssertTrue(body.contains("let refreshToken = keychain.getString(for: .refreshToken)"))
        XCTAssertTrue(body.contains(
            "guard keychain.getString(for: .accessToken) != nil || refreshToken != nil else { return }"))
        XCTAssertTrue(body.contains("_ = try? await APIService.shared.logout(refreshToken: refreshToken)"))
        XCTAssertTrue(body.contains("try? await Task.sleep(nanoseconds: 4_000_000_000)"))
        XCTAssertFalse(body.contains("refreshTokenIfNeeded"), "no refresh first")
        let logout = try XCTUnwrap(auth.range(of: "func logout(retainingTrust: Bool = true) async {"))
        let rest = auth[logout.upperBound...]
        let ends = try XCTUnwrap(rest.range(of: "if retainingTrust { await endServerSession() }"))
        let purge = try XCTUnwrap(rest.range(of: "await purgeAccountData()"))
        let wipe = try XCTUnwrap(rest.range(of: "keychain.deleteAll()"))
        XCTAssertLessThan(ends.lowerBound, purge.lowerBound)
        XCTAssertLessThan(ends.lowerBound, wipe.lowerBound)
    }
}
