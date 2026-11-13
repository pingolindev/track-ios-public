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

/// Only auth's own refusal of a refresh ends the session: a 401 from
/// `/api/v1/auth/refresh` WITH a JSON body (`Content-Type: application/json`),
/// which is what auth sends (`{"success":false,"error":"Missing token"}`, dev
/// and prod). A 401 there that isn't JSON (an HTML page from Cloudflare or a
/// proxy) says nothing about the session and keeps it, as Note iOS does.
///
/// Through the real path: a client on a stubbed URL session, its
/// `refreshToken(refreshToken:)`, `execute`'s 401 branch, and the error it
/// throws read by `APIError.isSessionDefinitivelyExpired`, the one predicate
/// the sign-out acts on.
final class RefreshRefusalTests: XCTestCase {

    /// Answers every request with `answer`; keeps what it was asked.
    private final class Stub: URLProtocol {
        private static let lock = NSLock()
        private static var _answer: (status: Int, headers: [String: String], body: Data)?
        private static var _asked: [URLRequest] = []

        static var answer: (status: Int, headers: [String: String], body: Data)? {
            get { lock.lock(); defer { lock.unlock() }; return _answer }
            set { lock.lock(); _answer = newValue; _asked = []; lock.unlock() }
        }
        static var asked: [URLRequest] {
            lock.lock(); defer { lock.unlock() }; return _asked
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.lock.lock()
            Self._asked.append(request)
            let answer = Self._answer
            Self.lock.unlock()
            guard let answer, let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1",
                                                 headerFields: answer.headers) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: answer.body)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private static let authRefusal = #"{"success":false,"error":"Missing token"}"#

    /// What `refreshToken(refreshToken:)` throws when the refresh route
    /// answers `status` with `contentType` (none when nil) and `body`.
    private func refreshFailure(_ status: Int, _ contentType: String?, _ body: String,
                                file: StaticString = #filePath, line: UInt = #line) async -> Error? {
        Stub.answer = (status, contentType.map { ["Content-Type": $0] } ?? [:], Data(body.utf8))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Stub.self]
        let api = APIService(session: URLSession(configuration: configuration))
        do {
            _ = try await api.refreshToken(refreshToken: "a-refresh-token")
            XCTFail("a \(status) refresh must throw", file: file, line: line)
            return nil
        } catch {
            XCTAssertEqual(Stub.asked.last?.url?.path, "/api/v1/auth/refresh", file: file, line: line)
            XCTAssertEqual(Stub.asked.last?.httpMethod, "POST", file: file, line: line)
            return error
        }
    }

    /// auth's refusal, JSON with or without a charset, in any case: the
    /// session ends.
    func testAuthsJSON401EndsTheSession() async {
        for contentType in ["application/json", "application/json; charset=utf-8", "Application/JSON; charset=UTF-8"] {
            let error = await refreshFailure(401, contentType, Self.authRefusal)
            XCTAssertEqual((error as? APIError)?.code, "refresh_failed", contentType)
            XCTAssertTrue(error.map(APIError.isSessionDefinitivelyExpired) == true, contentType)
        }
    }

    /// A 401 that isn't auth's JSON: an edge's HTML page, plain text, or no
    /// content type at all. It fails like any answer without auth's envelope
    /// (`http_401`), and the session is kept.
    func testA401ThatIsNotJSONKeepsTheSession() async {
        let page = "<!DOCTYPE html><html><head><title>401 Unauthorized</title></head><body>cloudflare</body></html>"
        for (contentType, body) in [("text/html; charset=UTF-8", page), ("text/plain", "Unauthorized"),
                                    (nil, ""), (nil, Self.authRefusal)] {
            let error = await refreshFailure(401, contentType, body)
            let label = "\(contentType ?? "no content type"): \(body.prefix(20))"
            XCTAssertEqual((error as? APIError)?.code, "http_401", label)
            XCTAssertFalse(error.map(APIError.isSessionDefinitivelyExpired) ?? true, label)
        }
    }

    /// A JSON 403 from the refresh route is not auth's refusal of the session
    /// either: unchanged, it keeps the session.
    func testAJSON403KeepsTheSession() async {
        let error = await refreshFailure(403, "application/json", #"{"success":false,"error":"Forbidden"}"#)
        XCTAssertNotNil(error)
        XCTAssertNotEqual((error as? APIError)?.code, "refresh_failed")
        XCTAssertFalse(error.map(APIError.isSessionDefinitivelyExpired) ?? true)
    }

    func testWhatSaysJSON() {
        func says(_ contentType: String?) -> Bool {
            let response = HTTPURLResponse(url: URL(string: "https://api-auth.pingolindev.com/api/v1/auth/refresh")!,
                                           statusCode: 401, httpVersion: "HTTP/1.1",
                                           headerFields: contentType.map { ["Content-Type": $0] } ?? [:])!
            return APIService.saysJSON(response)
        }
        XCTAssertTrue(says("application/json"))
        XCTAssertTrue(says("application/json; charset=utf-8"))
        XCTAssertTrue(says("APPLICATION/JSON"))
        XCTAssertFalse(says("text/html; charset=UTF-8"))
        XCTAssertFalse(says("text/plain"))
        XCTAssertFalse(says(nil))
    }
}
