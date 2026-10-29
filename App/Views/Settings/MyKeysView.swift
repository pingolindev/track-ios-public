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
import PingolinTrackSDK

/// This device's own public identity: the two public keys and the user id that
/// make up our half of a security code (a "safety number" in the SDK). Mirrors
/// the Android app's `MyKeysFragment`. Titled "Security details" — nothing a
/// person reads is named after keys.
///
/// There is deliberately no "my safety number" here, because there is no such
/// value. A safety number is computed over BOTH parties' material — see
/// `CryptoManager::compute_safety_number`, which hashes
/// `(user_id ‖ sharing_pk ‖ signing_pk)` for each side — so it only exists for
/// a pair. Two things on this screen are directly comparable, and the copy
/// below has to name both or the screen reads as a wall of hex that matches
/// nothing:
///
///   1. The keys here == the keys a peer sees for YOU under Security details →
///      Show technical details. Both are the lowercase hex of the same bytes,
///      so they agree character for character.
///   2. The security code on Security details for a member == the number THAT
///      member sees for you on the same screen of their device. That pair is
///      what you read aloud to each other; it never appears here.
///
/// Both paths are written through "Security details" because that is the only
/// label the user can actually tap — `MemberRow`'s confirmation dialog in
/// CirclesView declares `Button("Security details")`, and it is the sole route
/// to `MemberDetailView`. "Security code" and "Show technical details" are
/// headings inside that screen, so a path naming either as the entry point
/// dead-ends on a label that does not exist.
///
/// Nothing here is secret: all three values are published to the server so
/// peers can wrap circle keys for us. The value of showing them is that a
/// member who suspects a substituted key can read their own back and compare.
struct MyKeysView: View {
    @State private var copied = false

    /// `exportPublicKey()` hands back base64, while every peer key in the app
    /// (member security details, the wrap/rotation payloads) is hex — render
    /// ours in hex too so the two are actually comparable by eye.
    private var sharingPubkeyHex: String? {
        guard let b64 = try? SDKCrypto.cryptoManager.exportPublicKey(),
              let data = Data(base64Encoded: b64) else { return nil }
        return data.map { String(format: "%02x", $0) }.joined()
    }

    private var signingPubkeyHex: String? {
        try? SDKCrypto.cryptoManager.signingPublicKeyHex()
    }

    private var userId: String? {
        AuthManager.shared.userId
    }

    var body: some View {
        List {
            Section {
                Text("Other members can compare these details with what their phone shows for you, to confirm they're really talking to you.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("What matches what") {
                Text("To check a security code, open Circles → the circle → that member's ⋯ button → Security details. They should open Security details for you on their phone. The twelve groups of digits will be the same on both phones — there is no security code of your own on this page, because it is always worked out from two people at once.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("To check the details below, ask that member to open Circles → the circle → your ⋯ button → Security details → Show technical details. What they see there is exactly what you see here — the same characters in the same order. The spaces are ours, added every \(PublicKeyDisplay.groupSize) characters so the groups are easy to compare; Copy gives you the details without them.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            keyRow("Encryption ID (X25519)", value: sharingPubkeyHex)
            keyRow("Signature ID (Ed25519)", value: signingPubkeyHex)
            keyRow("User ID", value: userId)

            Section {
                Button(action: copyAll) {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .disabled(sharingPubkeyHex == nil && signingPubkeyHex == nil)
            } footer: {
                Text("Public values only. Nothing secret leaves this phone or is shown here.")
            }
        }
        .navigationTitle("Security details")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func keyRow(_ title: String, value: String?) -> some View {
        Section(title) {
            // Grouped, not raw: a 64-character hex run has no break opportunity,
            // so SwiftUI would hyphenate it and print characters that are not in
            // the key. See PublicKeyDisplay.
            PublicKeyText(value: value)
        }
    }

    private func copyAll() {
        let text = """
        Encryption ID (X25519)
        \(sharingPubkeyHex ?? "Unavailable")

        Signature ID (Ed25519)
        \(signingPubkeyHex ?? "Unavailable")

        User ID
        \(userId ?? "Unavailable")
        """
        // Public material, but still identity-bearing: keep it off Universal
        // Clipboard and expire it from the pasteboard rather than leaving it
        // readable by any app indefinitely. Mirrors MemberDetailView.copyNumber().
        UIPasteboard.general.setItems(
            [[UIPasteboard.typeAutomatic: text]],
            options: [
                .localOnly: true,
                .expirationDate: Date().addingTimeInterval(60)
            ]
        )
        copied = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            copied = false
        }
    }
}
