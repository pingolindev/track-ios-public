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

import Foundation
import PingolinTrackSDK

/// Decoder helpers for the wrapped-msg-key envelope the backend uses for
/// locations and places. Server stores nonce/ciphertext/wrapped_msg_key as
/// base64; SDK.unwrapAndDecryptLocation / unwrapAndDecryptPlace want hex.
enum EnvelopeDecoding {

    /// Pull the per-message key out from under the circle key and decrypt
    /// the location ciphertext with it. Returns nil when any of the four
    /// envelope fields is missing or malformed.
    static func decryptLocation(
        circleId: String,
        payload: EncryptedPayloadResponse,
        crypto: CryptoManager
    ) -> Location? {
        guard let wrappedKey = payload.wrappedMsgKey?.base64ToHex(),
              let wrappedNonce = payload.wrappedMsgKeyNonce?.base64ToHex(),
              let cipherHex = payload.ciphertext.base64ToHex(),
              let nonceHex = payload.nonce.base64ToHex() else {
            return nil
        }
        // _v2 tries the location domain + per-target wrap AADs, then falls
        // back to v1 (empty AAD) for rows sealed before v2.
        return try? crypto.unwrapAndDecryptLocationV2(
            targetId: circleId,
            wrappedKey: wrappedKey,
            wrappedKeyNonce: wrappedNonce,
            ciphertext: cipherHex,
            ciphertextNonce: nonceHex
        )
    }

    /// Sender-bound variant of `decryptLocation`: pass the row's resolved
    /// (E2EE) `userId`; the SDK re-derives the claimed pseudonym PER held
    /// circle-key version internally, so a server relabel fails the payload tag
    /// AND a row sealed under a now-superseded key version still verifies after a
    /// circle-key rotation. The SDK tries the v3 sender-bound AAD
    /// first (⇒ `senderVerified = true`) then falls back to the legacy v2/v1
    /// payload AAD (⇒ `senderVerified = false`); a v3 ciphertext read with the
    /// wrong user fails both and returns nil (dropped, never plaintext).
    /// The msg_key unwrap is identical to `decryptLocation` (target-bound).
    static func decryptLocationBound(
        circleId: String,
        payload: EncryptedPayloadResponse,
        userId: String,
        crypto: CryptoManager
    ) -> BoundLocation? {
        guard let wrappedKey = payload.wrappedMsgKey?.base64ToHex(),
              let wrappedNonce = payload.wrappedMsgKeyNonce?.base64ToHex(),
              let cipherHex = payload.ciphertext.base64ToHex(),
              let nonceHex = payload.nonce.base64ToHex() else {
            return nil
        }
        return try? crypto.unwrapAndDecryptLocationBoundForUser(
            targetId: circleId,
            wrappedKey: wrappedKey,
            wrappedKeyNonce: wrappedNonce,
            ciphertext: cipherHex,
            ciphertextNonce: nonceHex,
            userId: userId
        )
    }

    /// Session-key variant, sender-bound. A session-key row (`key_id` "s:{uuid}",
    /// e.g. the Android app's manual "send now" via
    /// `encryptLocationWithSessionKeyBound`) seals its ciphertext DIRECTLY under
    /// the circle's active SESSION key — there is no per-message wrapped msg_key
    /// to unwrap. The SDK resolves the key by `keyId`, tries the v3 sender-bound
    /// AAD for `userId` (re-derived PER held circle-key version, so a row sealed
    /// under a now-superseded version still verifies after a rotation) then falls
    /// back to the legacy empty-AAD (v1) decrypt under the SAME resolved key
    /// (⇒ `senderVerified = false`); total failure returns nil — dropped, never
    /// surfaced as plaintext. Caller must have imported the peer session key
    /// first (`APIService.fetchSessionKey`). Unlike the envelope helpers the
    /// nonce/ciphertext are passed through RAW (the session reader decodes
    /// base64/hex flexibly) — NOT hex-converted. Mirrors the Android app's
    /// session-key branch in `LocationRepository`.
    static func decryptSessionLocationBound(
        circleId: String,
        payload: EncryptedPayloadResponse,
        keyId: String,
        userId: String,
        crypto: CryptoManager
    ) -> BoundLocation? {
        return try? crypto.decryptLocationWithSessionKeyBoundForUser(
            circleId: circleId,
            encryptedLocation: EncryptedData(nonce: payload.nonce, ciphertext: payload.ciphertext),
            keyId: keyId,
            userId: userId
        )
    }

    /// Circle-key variant: a row with NO wrapped msg_key, its ciphertext sealed
    /// straight under a circle key. A frozen last location re-sealed after a
    /// rotation (`key_id` "c:<version>") is one, and so is the Android app's send
    /// when its session key fails (`key_id` ""). Read as the web app and
    /// the Android app's direct branch read it: the v3 sender-bound AAD for
    /// `userId` under each held circle-key version, then the legacy v2/v1 read
    /// (⇒ `senderVerified = false`), as the envelope reader falls back; total
    /// failure returns nil. `keyVersion` is the version whose key opened it,
    /// never the one the `key_id` names. Like the session reader, the
    /// nonce/ciphertext go in RAW: the SDK reads hex or base64.
    static func decryptDirectLocationBound(
        circleId: String,
        payload: EncryptedPayloadResponse,
        userId: String,
        crypto: CryptoManager
    ) -> BoundLocation? {
        return try? crypto.decryptLocationBoundForUser(
            circleId: circleId,
            encryptedLocation: EncryptedData(nonce: payload.nonce, ciphertext: payload.ciphertext),
            userId: userId
        )
    }

    /// Same as `decryptLocation` but for the place location envelope. The
    /// SDK helper returns the JSON-encoded location string; callers parse
    /// out lat/lng themselves.
    static func decryptPlaceLocation(
        circleId: String,
        payload: EncryptedPayloadResponse,
        crypto: CryptoManager
    ) -> String? {
        guard let wrappedKey = payload.wrappedMsgKey?.base64ToHex(),
              let wrappedNonce = payload.wrappedMsgKeyNonce?.base64ToHex(),
              let cipherHex = payload.ciphertext.base64ToHex(),
              let nonceHex = payload.nonce.base64ToHex() else {
            return nil
        }
        return try? crypto.unwrapAndDecryptPlace(
            targetId: circleId,
            wrappedKey: wrappedKey,
            wrappedKeyNonce: wrappedNonce,
            ciphertext: cipherHex,
            ciphertextNonce: nonceHex
        )
    }
}

extension String {
    /// Hex-encode the bytes parsed from this string interpreted as base64.
    /// Returns nil when the input isn't valid base64.
    fileprivate func base64ToHex() -> String? {
        guard let data = Data(base64Encoded: self) else { return nil }
        return data.map { String(format: "%02x", $0) }.joined()
    }
}

/// Lightweight Codable counterpart to PingolinTrackSDK.Location so the place
/// decode path (which returns a JSON string from the SDK) can pull out the
/// fields it actually needs without depending on the Rust binding's struct.
struct LocationJSON: Decodable {
    let latitude: Double
    let longitude: Double
    let altitude: Double?
    let speed: Double?
    let heading: Double?
    let accuracy: Double?
    let timestamp: Int64?
    let batteryLevel: Double?
    let isCharging: Bool?

    static func parse(_ json: String) -> LocationJSON? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(LocationJSON.self, from: data)
    }
}
