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

import SwiftUI

/// How a raw public key is shown to someone who has been told to compare it
/// "character for character" with another device.
///
/// WHY THIS EXISTS
///   A 64-character hex string has no spaces, so SwiftUI's line breaker treats
///   it as one word and hyphenates it to make it fit. Those hyphens are not in
///   the key. On a screen whose entire job is character-by-character
///   comparison, rendering characters that are not there is the worst possible
///   defect — and which key gets a hyphen depends on the text, so it cannot be
///   reasoned about.
///
///   Grouping solves this where a line-break tweak would not: a space is a
///   break opportunity, so the layout never needs to hyphenate at all, and
///   short groups are what makes two 64-character strings actually comparable
///   by eye. The app already uses this idiom for safety numbers ("twelve
///   groups of digits"). `MyKeysView.copyAll` deliberately copies the
///   UNGROUPED value, so pasting it into anything else still yields the real
///   key.
enum PublicKeyDisplay {
    /// Characters per group. Eight keeps a 64-hex key to eight groups, and
    /// three groups fit a line at footnote size on the narrowest supported
    /// phone — so a key is three tidy lines rather than an arbitrary wrap.
    static let groupSize = 8

    /// Split into fixed-width groups separated by a single space.
    ///
    /// Anything that is not a plain run of characters is returned unchanged:
    /// a value that already contains spaces or hyphens (a UUID, say) is
    /// something a caller formatted on purpose, and regrouping it would be the
    /// same class of lie this exists to prevent.
    static func grouped(_ value: String, size: Int = groupSize) -> String {
        guard size > 0 else { return value }
        guard !value.isEmpty else { return value }
        guard !value.contains(where: { $0 == " " || $0 == "-" }) else { return value }

        var out = ""
        out.reserveCapacity(value.count + value.count / size)
        for (i, ch) in value.enumerated() {
            if i > 0 && i % size == 0 { out.append(" ") }
            out.append(ch)
        }
        return out
    }
}

/// A public key rendered for comparison: grouped, monospaced, selectable.
///
/// Both screens that show these keys use this view, because the copy on
/// Settings → Security details promises the member's Security details shows "exactly
/// what you see here". Two renderers would make that sentence false the first
/// time one of them changed.
struct PublicKeyText: View {
    let value: String?
    var font: Font.TextStyle = .footnote

    var body: some View {
        Text(value.map { PublicKeyDisplay.grouped($0) } ?? "Unavailable")
            .font(.system(font, design: .monospaced))
            .textSelection(.enabled)
            .foregroundStyle(value == nil ? .secondary : .primary)
    }
}
