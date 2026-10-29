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

/// Decode the payload of a JWT *without verifying* the signature. The
/// server already verified the token before minting it; we just want
/// to read server-issued metadata the client already has in its
/// token (e.g. `sid` for picking the current session id when
/// PATCH-renaming "this device"). Never trust these values for
/// security decisions.
///
/// Returns nil on any decode/JSON failure rather than throwing —
/// callers treat "couldn't read the claim" the same as "claim not
/// present" and disable the dependent UI.
///
/// Mirrors the Android app's `JwtClaims`.
enum JwtClaims {

    /// Session id (the `sid` claim), carried on the access
    /// token by the auth backend. Used for PATCH-rename of the
    /// current session when the UI needs to act on "this device"
    /// without an explicit user selection.
    static func sessionId(_ accessToken: String?) -> String? {
        readClaim(accessToken, "sid")
    }

    private static func readClaim(_ accessToken: String?, _ name: String) -> String? {
        guard let token = accessToken else { return nil }
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        guard let payload = base64UrlDecode(String(parts[1])) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return nil }
        let value = json[name] as? String
        if let value = value, !value.isEmpty { return value }
        return nil
    }

    /// JWT uses URL-safe base64 with no padding; Foundation's
    /// `Data(base64Encoded:)` is strict, so we translate `-`/`_` →
    /// `+`/`/` and pad to a multiple of 4 ourselves.
    private static func base64UrlDecode(_ str: String) -> Data? {
        var s = str
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s)
    }
}
