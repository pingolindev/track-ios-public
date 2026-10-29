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

/// Wire-contract coverage for `POST /circles/:id/members/eject-and-rotate`.
///
/// This endpoint is the ONLY way to remove another member —
/// `DELETE /members/:user_id` answers 410 Gone — so a name that does not match
/// the server is not cosmetic. Two failure modes, and the quiet one is worse:
///
///  1. `eject_user_id` / `new_key_version` / `member_wraps` are required, so a
///     wrong name there is a loud 4xx.
///  2. `encrypted_name` and `key_chain_link` are optional on the server. A
///     wrong name is DROPPED SILENTLY and the request still succeeds
///     — leaving exactly the hole this pair exists to close: the circle name and
///     everything sealed before the rotation become permanently unreadable to
///     anyone holding only the new key (the web, a fresh install, a later
///     joiner), while the phone that did the ejecting reads it fine from keys it
///     still holds locally. That asymmetry is what makes it hard to notice.
///
/// Also pins the shape difference against `/rotate-keys`: a wrap here carries
/// FLAT hex fields, not the nested blob `MemberKeyUpdateRequest` uses.
final class EjectAndRotateWireTests: XCTestCase {

    /// Mirror APIService's strategy so the test exercises the real mapping.
    private func snakeEncoder() -> JSONEncoder {
        let e = JSONEncoder(); e.keyEncodingStrategy = .convertToSnakeCase; return e
    }
    private func snakeDecoder() -> JSONDecoder {
        let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase; return d
    }

    // MARK: - Key-chain links on the circle-key bundle

    /// A rotated circle's bundle, as GET /api/v1/circles/keys serves it (values
    /// shortened): one wrap at v2 and one chain link v2→v1. The link is the
    /// ONLY route to v1 for a member the server does not wrap v1 for any more,
    /// so `CircleKeyResponse` must decode it: without it, whatever is sealed
    /// under v1 — the circle owner's display name, say — does not open, and the
    /// owner shows as "Member". Decoding it is the contract this pins.
    func testCircleKeyBundleDecodesItsKeyChain() throws {
        let raw = """
        {"circle_id":"4e4aafd9-b78a-41e6-8edd-68555cc4cd41",
         "encrypted_circle_key":{"nonce":"aa","ciphertext":"bb"},
         "ephemeral_public_key":"cc",
         "key_version":2,
         "key_chain":[{"from_version":2,"to_version":1,"encrypted_key":"fb7e0746e012","nonce":"2ec3d7f9b348"}],
         "sender_user_id":"2f93a7ad-2f76-4a3c-91e5-a235cf233b24"}
        """.data(using: .utf8)!
        let bundle = try snakeDecoder().decode(CircleKeyResponse.self, from: raw)
        XCTAssertEqual(bundle.keyVersion, 2)
        let chain = try XCTUnwrap(bundle.keyChain)
        XCTAssertEqual(chain.count, 1)
        XCTAssertEqual(chain[0], KeyChainLinkResponse(fromVersion: 2, toVersion: 1,
                                                       encryptedKey: "fb7e0746e012", nonce: "2ec3d7f9b348"))
    }

    /// A never-rotated circle and the self-key bundle carry no chain; the field
    /// must stay optional so those bundles keep decoding.
    func testCircleKeyBundleWithoutChainStillDecodes() throws {
        let raw = """
        {"circle_id":"00000000-0000-0000-0000-000000000000",
         "encrypted_circle_key":{"nonce":"aa","ciphertext":"bb"},
         "ephemeral_public_key":"cc","key_version":1}
        """.data(using: .utf8)!
        let bundle = try snakeDecoder().decode(CircleKeyResponse.self, from: raw)
        XCTAssertNil(bundle.keyChain)
    }

    /// Links import newest-first so each link's source key already exists, and
    /// a link that does not point backwards is dropped rather than handed to
    /// the SDK.
    func testKeyChainImportOrderIsNewestFirstAndBackwardsOnly() {
        let links = [
            KeyChainLinkResponse(fromVersion: 2, toVersion: 1, encryptedKey: "a", nonce: "n"),
            KeyChainLinkResponse(fromVersion: 3, toVersion: 2, encryptedKey: "b", nonce: "n"),
            KeyChainLinkResponse(fromVersion: 1, toVersion: 1, encryptedKey: "bad", nonce: "n"),
        ]
        let ordered = CircleManager.chainImportOrder(links)
        XCTAssertEqual(ordered.map { "\($0.fromVersion)>\($0.toVersion)" }, ["3>2", "2>1"])
    }

    private func sampleRequest(
        encryptedName: EncryptedBlobRequest? = EncryptedBlobRequest(nonce: "1a", ciphertext: "2b"),
        keyChainLink: KeyChainLinkRequest? = KeyChainLinkRequest(
            fromVersion: 2, toVersion: 3, encryptedKey: "aa", nonce: "bb"
        )
    ) -> EjectAndRotateRequest {
        EjectAndRotateRequest(
            ejectUserId: "11111111-1111-1111-1111-111111111111",
            newKeyVersion: 3,
            memberWraps: [
                EjectMemberWrapRequest(
                    userId: "22222222-2222-2222-2222-222222222222",
                    encryptedCircleKey: "cafe",
                    circleKeyNonce: "beef",
                    ephemeralPublicKey: "f00d",
                    wrapSignature: "5197"
                )
            ],
            encryptedName: encryptedName,
            keyChainLink: keyChainLink
        )
    }

    func testRequiredFieldsSerializeWithServerNames() throws {
        let json = String(data: try snakeEncoder().encode(sampleRequest()), encoding: .utf8)!
        XCTAssertTrue(json.contains("\"eject_user_id\":\"11111111-1111-1111-1111-111111111111\""),
                      "must serialize eject_user_id; got \(json)")
        XCTAssertTrue(json.contains("\"new_key_version\":3"),
                      "must serialize new_key_version; got \(json)")
        XCTAssertTrue(json.contains("\"member_wraps\""),
                      "must serialize member_wraps; got \(json)")
    }

    /// The silent pair. If either name drifts the server accepts the request and
    /// drops the field, so only an explicit assertion catches it.
    func testOptionalPairSerializesWithServerNames() throws {
        let json = String(data: try snakeEncoder().encode(sampleRequest()), encoding: .utf8)!
        XCTAssertTrue(json.contains("\"encrypted_name\""),
                      "encrypted_name is serde(default) on the server — a wrong name is dropped silently; got \(json)")
        XCTAssertTrue(json.contains("\"key_chain_link\""),
                      "key_chain_link is serde(default) on the server — a wrong name is dropped silently; got \(json)")
        XCTAssertTrue(json.contains("\"from_version\":2"), "chain link must carry from_version; got \(json)")
        XCTAssertTrue(json.contains("\"to_version\":3"), "chain link must carry to_version; got \(json)")
        XCTAssertTrue(json.contains("\"encrypted_key\":\"aa\""), "chain link must carry encrypted_key; got \(json)")
    }

    /// A wrap is flat here — `encrypted_circle_key` and `circle_key_nonce` side
    /// by side — unlike `/rotate-keys`, where the same material goes inside a
    /// nested `encrypted_circle_key` object. Sending the nested shape would fail
    /// the server's hex decode.
    func testMemberWrapIsFlatHexNotANestedBlob() throws {
        let json = String(data: try snakeEncoder().encode(sampleRequest()), encoding: .utf8)!
        XCTAssertTrue(json.contains("\"encrypted_circle_key\":\"cafe\""),
                      "encrypted_circle_key must be a flat hex string; got \(json)")
        XCTAssertTrue(json.contains("\"circle_key_nonce\":\"beef\""),
                      "circle_key_nonce must be a sibling of encrypted_circle_key; got \(json)")
        XCTAssertTrue(json.contains("\"ephemeral_public_key\":\"f00d\""),
                      "must serialize ephemeral_public_key; got \(json)")
        XCTAssertTrue(json.contains("\"wrap_signature\":\"5197\""),
                      "must serialize wrap_signature; got \(json)")
        XCTAssertFalse(json.contains("\"encrypted_circle_key\":{"),
                       "wrap must NOT nest the blob the way /rotate-keys does; got \(json)")
    }

    /// An unsigned wrap omits the signature rather than sending an empty string:
    /// the recipient's strict-verify path treats "" as a malformed signature, not
    /// as absence.
    func testUnsignedWrapOmitsTheSignature() throws {
        let req = EjectAndRotateRequest(
            ejectUserId: "11111111-1111-1111-1111-111111111111",
            newKeyVersion: 3,
            memberWraps: [
                EjectMemberWrapRequest(
                    userId: "22222222-2222-2222-2222-222222222222",
                    encryptedCircleKey: "cafe",
                    circleKeyNonce: "beef",
                    ephemeralPublicKey: "f00d",
                    wrapSignature: nil
                )
            ],
            encryptedName: nil,
            keyChainLink: nil
        )
        let json = String(data: try snakeEncoder().encode(req), encoding: .utf8)!
        XCTAssertFalse(json.contains("\"wrap_signature\":\"\""),
                       "an unsigned wrap must omit wrap_signature, not send an empty string; got \(json)")
    }

    func testResponseDecodesServerShape() throws {
        let json = "{\"new_key_version\":4,\"ejected_user_id\":\"11111111-1111-1111-1111-111111111111\"}"
        let resp = try snakeDecoder().decode(EjectAndRotateResponse.self, from: Data(json.utf8))
        XCTAssertEqual(resp.newKeyVersion, 4)
        XCTAssertEqual(resp.ejectedUserId, "11111111-1111-1111-1111-111111111111")
    }
}
