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

/// The API session keeps no cookies.
///
/// The auth server answers sign-in and refresh with `Set-Cookie:
/// auth_token=<JWT>` and a 30-day `refresh_token` for the web portal. The
/// default URLSession would store them under Library/Cookies, which device
/// backups include — a bearer credential outside the `…ThisDeviceOnly` Keychain
/// item that exists so a backup restored to another phone cannot carry it. The
/// app authenticates with a bearer header and `X-Refresh-Token`, so it needs no
/// jar (the Android app has none either).
final class AuthCookieJarTests: XCTestCase {

    func testTheAPISessionStoresAndSendsNoCookies() {
        let configuration = APIService.makeSessionConfiguration()
        XCTAssertNil(configuration.httpCookieStorage, "no jar to store a Set-Cookie in")
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
        XCTAssertNil(configuration.urlCache, "no response cache to write auth replies and bearer headers into")
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 30)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 60)
    }

    /// Earlier builds' cookies are purged — only those two names.
    func testStoredAuthCookiesArePurgedAndNothingElse() throws {
        let storage = HTTPCookieStorage.shared
        // Lower case: HTTPCookie lower-cases its domain, so a mixed-case one is
        // never found again and every absence below would hold vacuously.
        let domain = "cookie-test-\(UUID().uuidString.prefix(8).lowercased()).pingolindev.invalid"
        func cookie(_ name: String) throws -> HTTPCookie {
            try XCTUnwrap(HTTPCookie(properties: [
                .domain: domain, .path: "/", .name: name, .value: "test-value",
                .secure: "TRUE", .expires: Date().addingTimeInterval(3600),
            ]))
        }
        func namesInJar() -> Set<String> {
            Set((storage.cookies ?? []).filter { $0.domain == domain || $0.domain == "." + domain }.map(\.name))
        }
        let unrelated = try cookie("__cf_bm")
        storage.setCookie(try cookie("refresh_token"))
        storage.setCookie(try cookie("auth_token"))
        storage.setCookie(unrelated)
        defer { storage.deleteCookie(unrelated) }
        XCTAssertEqual(namesInJar(), ["refresh_token", "auth_token", "__cf_bm"],
                       "the fixture must be in the jar, or nothing below proves anything")

        XCTAssertGreaterThanOrEqual(APIService.purgeStoredAuthCookies(from: storage), 2)

        XCTAssertEqual(namesInJar(), ["__cf_bm"], "only the auth cookies go")
    }

    /// What earlier builds cached is emptied once per install — not on every
    /// launch, because the map shares the cache.
    func testTheSharedResponseCacheIsEmptiedOnce() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("url-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = URLCache(memoryCapacity: 1 << 20, diskCapacity: 1 << 22, directory: dir)
        let suite = "AuthCookieJarTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let request = URLRequest(url: try XCTUnwrap(URL(string: "https://api-auth.pingolindev.invalid/api/v1/auth/me")))
        let response = try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200,
                                                     httpVersion: "HTTP/1.1", headerFields: nil))
        cache.storeCachedResponse(CachedURLResponse(response: response, data: Data("{}".utf8)), for: request)
        XCTAssertNotNil(cache.cachedResponse(for: request), "the fixture must be in the cache, or nothing below proves anything")

        XCTAssertTrue(APIService.purgeCachedResponsesOnce(cache: cache, defaults: defaults))
        XCTAssertNil(cache.cachedResponse(for: request))

        cache.storeCachedResponse(CachedURLResponse(response: response, data: Data("{}".utf8)), for: request)
        XCTAssertFalse(APIService.purgeCachedResponsesOnce(cache: cache, defaults: defaults), "once per install")
        XCTAssertNotNil(cache.cachedResponse(for: request), "a later launch leaves the map's cache alone")
    }

    /// Every request that carries a credential goes through a session with no
    /// response cache and no cookies: never `URLSession.shared`, whose cache
    /// keeps each request with its Authorization header. Checked across the app
    /// and the notification extension, so a new call site cannot slip back.
    func testNoCredentialTravelsThroughTheSharedSession() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var checked = 0
        for dir in ["App", "NotificationExtension"] {
            let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root.appendingPathComponent(dir),
                                                                          includingPropertiesForKeys: nil))
            for case let file as URL in enumerator where file.pathExtension == "swift" {
                let src = try String(contentsOf: file, encoding: .utf8)
                guard src.contains("forHTTPHeaderField: \"Authorization\")") else { continue }
                checked += 1
                XCTAssertFalse(src.contains("URLSession.shared"),
                               "\(file.lastPathComponent) sends a credential through URLSession.shared")
            }
        }
        XCTAssertGreaterThanOrEqual(checked, 3, "APIService, EnergyMetrics and the invite banner all send a token")
        let banner = try String(contentsOf: root.appendingPathComponent("NotificationExtension/InviteBannerRewriter.swift"),
                                encoding: .utf8)
        XCTAssertTrue(banner.contains("configuration.urlCache = nil"))
        XCTAssertTrue(banner.contains("URLCache.shared.removeAllCachedResponses()"), "and what earlier builds cached goes")
        let energy = try String(contentsOf: root.appendingPathComponent("App/Services/EnergyMetrics.swift"), encoding: .utf8)
        XCTAssertTrue(energy.contains("TrustBlocklist.session(configuration: APIService.makeSessionConfiguration())"))
    }
}
