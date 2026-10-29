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

/// Wire-contract coverage for `GET /api/v1/users/me/self-key`.
///
/// This is the highest-stakes decode in the app. `SelfKeyManager.ensure()`
/// answers a `nil` bundle by GENERATING a replacement self key and POSTing it
/// to an endpoint that UPSERTs — so anything that turns into a spurious `nil`
/// silently destroys the only server copy of the key every personal location
/// row is encrypted under. `getSelfKey` therefore throws on a 500, a timeout
/// or a dropped connection instead of answering `nil` (as a `try?` would), so
/// `SelfKeyManager`'s `catch` stays reachable.
///
/// The endpoint is also the one place where a *successful* answer legitimately
/// carries `data: null`: the server answers a missing key with success and no
/// data. So the two cases must stay distinguishable in both directions: a null
/// must not throw (a first-run account would never get a key), and a failure
/// must not read as null.
final class SelfKeyEnvelopeTests: XCTestCase {

    /// Mirror APIService's strategy so the test exercises the real mapping.
    private func snakeDecoder() -> JSONDecoder {
        let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase; return d
    }

    /// The inner bundle object, exactly as `CircleKeyBundle` serializes it.
    private let bundleJSON = """
    {
      "circle_id": "00000000-0000-0000-0000-000000000000",
      "encrypted_circle_key": { "nonce": "1a2b", "ciphertext": "3c4d" },
      "ephemeral_public_key": "beef",
      "key_version": 2,
      "key_chain": [],
      "sender_user_id": null,
      "wrap_signature": null,
      "user_pseudonym": "pseud"
    }
    """

    // MARK: - The two successful shapes

    func testNullDataDecodesAsNoKeyOnFile() throws {
        let body = Data(#"{"success":true,"data":null}"#.utf8)
        let envelope = try snakeDecoder().decode(APIService.SelfKeyEnvelope.self, from: body)
        XCTAssertTrue(envelope.success)
        XCTAssertNil(envelope.data, "`data: null` is the server's 'no key on file' and must decode, not throw")
    }

    func testPresentBundleDecodesWithServerFieldNames() throws {
        let body = Data(#"{"success":true,"data":\#(bundleJSON)}"#.utf8)
        let envelope = try snakeDecoder().decode(APIService.SelfKeyEnvelope.self, from: body)
        let bundle = try XCTUnwrap(envelope.data)
        XCTAssertEqual(bundle.circleId, "00000000-0000-0000-0000-000000000000")
        XCTAssertEqual(bundle.encryptedCircleKey.nonce, "1a2b")
        XCTAssertEqual(bundle.encryptedCircleKey.ciphertext, "3c4d")
        XCTAssertEqual(bundle.ephemeralPublicKey, "beef")
        XCTAssertEqual(bundle.keyVersion, 2)
    }

    // MARK: - The trap that makes the fallback decode safe

    /// `decodeResponse` tries `APIResponse<T>` FIRST, which hands `T` the inner
    /// `data` object. If `SelfKeyEnvelope` could decode from that object it
    /// would report `data: nil` for a key that is actually present — the same
    /// data loss by another route. It can't, because `success` is required, so
    /// that attempt throws and decoding falls through to the full envelope.
    ///
    /// If someone ever makes `success` optional, this test is what fails.
    func testEnvelopeCannotDecodeFromTheInnerBundle() {
        let body = Data(bundleJSON.utf8)
        XCTAssertThrowsError(try snakeDecoder().decode(APIService.SelfKeyEnvelope.self, from: body)) { error in
            guard case DecodingError.keyNotFound(let key, _)? = error as? DecodingError else {
                return XCTFail("expected keyNotFound(success), got \(error)")
            }
            XCTAssertEqual(key.stringValue, "success")
        }
    }

    /// A truncated / non-envelope body must throw rather than read as "no key".
    func testGarbageBodyThrowsRatherThanReadingAsNoKey() {
        XCTAssertThrowsError(try snakeDecoder().decode(APIService.SelfKeyEnvelope.self, from: Data("{}".utf8)))
        XCTAssertThrowsError(try snakeDecoder().decode(APIService.SelfKeyEnvelope.self, from: Data("<html>502</html>".utf8)))
    }
}
