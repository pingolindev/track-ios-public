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

/// What debug logging may show of a reply or a message: never a session token
/// and never key material.
///
/// DEBUG builds log each reply's body (`TrackDiag`) and write it to
/// Documents/diag-*.json, and both end up in xcodebuild output, in the unified
/// log and in pulled containers. A PREVIOUS refresh token can stay usable until
/// the next refresh (about a day), so a refresh token in a log is a whole
/// session; the password-wrapped keys `/auth/me` returns are the account's keys
/// to anyone who learns the password. Everything that writes a body or a
/// free-text diagnostic goes through `scrub`.
enum LogRedaction {
    /// A JSON key whose value never reaches a log: any key containing one of
    /// these, in any case.
    static let secretKeyFragments = [
        "token", "secret", "password", "proof", "private_key", "master_key",
        "recovery_key", "encrypted_keys", "session_key", "authorization", "cookie",
    ]

    static let redacted = "<redacted>"

    static func isSecret(key: String) -> Bool {
        let lower = key.lowercased()
        return secretKeyFragments.contains { lower.contains($0) }
    }

    /// A reply body as it may be logged or written: JSON with every secret
    /// value replaced; anything else through the text rules.
    static func scrub(body data: Data) -> Data {
        if let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
           let clean = try? JSONSerialization.data(withJSONObject: scrubbed(object),
                                                   options: [.fragmentsAllowed, .sortedKeys]) {
            return clean
        }
        return Data(scrub(String(decoding: data, as: UTF8.self)).utf8)
    }

    /// Free text as it may be logged: secret JSON values, JWTs and credential
    /// headers replaced — for text that is not (or no longer) whole JSON.
    static func scrub(_ text: String) -> String {
        var out = text
        // "some_token": "value"  →  "some_token":"<redacted>"
        out = replace(#""([^"]*(?:token|secret|password|proof|private_key|master_key|recovery_key|session_key|authorization|cookie)[^"]*)"\s*:\s*"[^"]*""#,
                      in: out, with: "\"$1\":\"\(redacted)\"")
        // "encrypted_keys": { … — the rest of a cut-off body cannot be walked.
        out = replace(#""encrypted_keys"\s*:[\s\S]*$"#, in: out, with: "\"encrypted_keys\":\"\(redacted)\"")
        // Any JWT, anywhere.
        out = replace(#"eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"#, in: out, with: redacted)
        // Credential headers written as text.
        out = replace(#"(?i)\b(x-refresh-token|authorization|cookie)\b\s*[:=]\s*(?:bearer\s+)?[^\s,;]+"#,
                      in: out, with: "$1: \(redacted)")
        return out
    }

    private static func scrubbed(_ object: Any) -> Any {
        if let dictionary = object as? [String: Any] {
            var clean: [String: Any] = [:]
            for (key, value) in dictionary {
                clean[key] = isSecret(key: key) ? redacted : scrubbed(value)
            }
            return clean
        }
        if let array = object as? [Any] {
            return array.map(scrubbed)
        }
        if let string = object as? String {
            return scrub(string)
        }
        return object
    }

    private static func replace(_ pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        return regex.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
}
