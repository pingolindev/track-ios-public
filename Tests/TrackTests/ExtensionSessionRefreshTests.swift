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

/// The extension's session refresh: refresh only holding the app's lock, read
/// the stored pair again under it, save the new pair before using it — and
/// never use one that could not be saved.
final class ExtensionSessionRefreshTests: XCTestCase {
    private let now = Date()
    private let base = "https://auth.test"

    private static func jwt(expires: Date) -> String {
        func b64(_ object: [String: Any]) -> String {
            try! JSONSerialization.data(withJSONObject: object).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return "\(b64(["alg": "RS256"])).\(b64(["sub": "u", "exp": Int(expires.timeIntervalSince1970)])).sig"
    }

    /// The stored pair; `onSecondRead` stands in for the other process.
    private final class Store {
        var pair: (access: String?, refresh: String?)
        var reads = 0
        var onSecondRead: (() -> Void)?
        var writes: [(String, String?)] = []
        var writeSucceeds = true

        init(access: String?, refresh: String?) { pair = (access, refresh) }

        var tokenStore: ExtensionSessionRefresh.TokenStore {
            ExtensionSessionRefresh.TokenStore(
                read: { [unowned self] in
                    self.reads += 1
                    if self.reads == 2 { self.onSecondRead?() }
                    return self.pair
                },
                write: { [unowned self] access, refresh in
                    self.writes.append((access, refresh))
                    if self.writeSucceeds { self.pair = (access, refresh ?? self.pair.refresh) }
                    return self.writeSucceeds
                })
        }
    }

    private final class Auth: HandoverTransport, @unchecked Sendable {
        var requests: [URLRequest] = []
        var answer: (Int, String) = (200, #"{"access_token":"NEW-ACCESS","refresh_token":"NEW-REFRESH"}"#)
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            requests.append(request)
            return (Data(answer.1.utf8), HTTPURLResponse(url: request.url!, statusCode: answer.0, httpVersion: nil, headerFields: nil)!)
        }
    }

    private func lock() -> AppGroupLock {
        AppGroupLock(url: FileManager.default.temporaryDirectory.appendingPathComponent("refresh-lock-\(UUID().uuidString)"))
    }

    private func token(_ store: Store, _ auth: Auth, enabled: Bool = true, lock: AppGroupLock? = nil,
                       wait: TimeInterval = 1) async -> String? {
        await ExtensionSessionRefresh.token(now: now, margin: 30, authBase: base, lock: lock ?? self.lock(),
                                            transport: auth, store: store.tokenStore, enabled: enabled, wait: wait)
    }

    func testAStoredTokenThatWorksIsUsedAsItIs() async {
        let valid = Self.jwt(expires: now.addingTimeInterval(3600))
        let (store, auth) = (Store(access: valid, refresh: "R1"), Auth())
        let got = await token(store, auth)
        XCTAssertEqual(got, valid)
        XCTAssertTrue(auth.requests.isEmpty)
    }

    /// On by default; switched off, an expired token is neither refreshed
    /// nor used.
    func testRefreshingIsOnByDefaultAndOffMeansNothing() async {
        XCTAssertTrue(ExtensionSessionRefresh.enabled, "on by default")
        let (store, auth) = (Store(access: Self.jwt(expires: now), refresh: "R1"), Auth())
        let got = await token(store, auth, enabled: false)
        XCTAssertNil(got)
        XCTAssertTrue(auth.requests.isEmpty, "switched off: an expired token is not refreshed here, nor used")
    }

    func testAnExpiredTokenIsRefreshedAndSavedBeforeUse() async throws {
        let (store, auth) = (Store(access: Self.jwt(expires: now), refresh: "R1"), Auth())
        let got = await token(store, auth)
        XCTAssertEqual(got, "NEW-ACCESS")
        let request = try XCTUnwrap(auth.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://auth.test/api/v1/auth/refresh")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Refresh-Token"), "R1")
        XCTAssertEqual(store.writes.first?.0, "NEW-ACCESS")
        XCTAssertEqual(store.writes.first?.1, "NEW-REFRESH")
    }

    /// The app refreshed while this waited for the lock: its pair is used, and
    /// no second refresh retires it.
    func testTheAppsRefreshIsUsedInsteadOfASecondOne() async {
        let (store, auth) = (Store(access: Self.jwt(expires: now), refresh: "R1"), Auth())
        store.onSecondRead = { store.pair = ("APP-ACCESS", "APP-REFRESH") }
        let got = await token(store, auth)
        XCTAssertEqual(got, "APP-ACCESS")
        XCTAssertTrue(auth.requests.isEmpty)
        XCTAssertTrue(store.writes.isEmpty)
    }

    func testALockHeldElsewhereMeansNoRefresh() async throws {
        let shared = lock()
        let appHeld = await AppGroupLock(url: shared.url).acquire(timeout: 1)
        let app = try XCTUnwrap(appHeld)
        defer { app.release() }
        let (store, auth) = (Store(access: Self.jwt(expires: now), refresh: "R1"), Auth())
        let got = await token(store, auth, lock: shared, wait: 0.3)
        XCTAssertNil(got)
        XCTAssertTrue(auth.requests.isEmpty)
    }

    func testAPairThatCannotBeSavedIsNeverUsed() async {
        let (store, auth) = (Store(access: Self.jwt(expires: now), refresh: "R1"), Auth())
        store.writeSucceeds = false
        let got = await token(store, auth)
        XCTAssertNil(got, "the server keeps the old token good until the new pair is first used, so an unsaved pair is never used")
    }

    func testTheRefreshAnswerReadsWithOrWithoutTheEnvelope() {
        XCTAssertEqual(ExtensionSessionRefresh.RefreshedPair.decode(Data(#"{"success":true,"data":{"access_token":"A","refresh_token":"R"}}"#.utf8)),
                       .init(accessToken: "A", refreshToken: "R"))
        XCTAssertEqual(ExtensionSessionRefresh.RefreshedPair.decode(Data(#"{"access_token":"A"}"#.utf8)),
                       .init(accessToken: "A", refreshToken: nil))
        XCTAssertNil(ExtensionSessionRefresh.RefreshedPair.decode(Data(#"{"access_token":""}"#.utf8)))
    }

    /// The extension's only keychain writes: an UPDATE of the app's two session
    /// items, here and nowhere else.
    func testTheOnlyKeychainWritesAreTheSessionItems() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("NotificationExtension/ExtensionSessionRefresh.swift"), encoding: .utf8)
        XCTAssertEqual(source.components(separatedBy: "SecItemUpdate(").count - 1, 1)
        XCTAssertFalse(source.contains("SecItemAdd(") || source.contains("SecItemDelete("), "never creates or deletes a session")
        XCTAssertTrue(source.contains(#"update("refresh_token", refresh)"#) && source.contains(#"update("access_token", access)"#))
    }
}
