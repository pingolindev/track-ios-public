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

/// Is this string plausibly an email address?
///
/// WHY THIS EXISTS
///   Without it, sign-in sends anything the user typed to the server, so a
///   typo like a missing "@" comes back as "Login Failed — Couldn't sign in.
///   Please try again." — the same wording as a wrong password, in a modal
///   alert, after a round trip and a rate-limit slot. The user is told to try
///   again, tries the same thing again, and burns another of the five
///   attempts the limiter allows.
///
/// DELIBERATELY PERMISSIVE
///   This is a typo catcher, not an RFC 5322 parser. Every "clever" email regex
///   ends up rejecting somebody's real address, and the server is the authority
///   on whether an account exists. It rejects only what cannot be an address:
///   no "@", nothing before or after it, whitespace inside, or a domain with no
///   dot. Anything else is the server's call.
enum EmailFormat {
    static func isPlausible(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }
        // Whitespace anywhere inside is a typo, not an address.
        guard !value.contains(where: { $0.isWhitespace }) else { return false }

        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }          // exactly one "@"
        let local = parts[0], domain = parts[1]
        guard !local.isEmpty, !domain.isEmpty else { return false }

        // A domain needs a dot with something either side: "user@localhost"
        // cannot be an account here, and it is far more often a truncated
        // paste than a real intranet address.
        guard let dot = domain.firstIndex(of: "."), dot != domain.startIndex else { return false }
        guard domain.last != "." else { return false }
        guard !domain.contains("..") else { return false }
        return true
    }
}
