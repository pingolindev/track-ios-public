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
/// the Android app's `MyKeysFragment`. Titled "Security details"; nothing a
/// person reads is named after keys.
///
/// There is no "my security code" here: a code is computed over BOTH parties'
/// values (`CryptoManager::compute_safety_number`), so it only exists for a
/// pair and lives on the member's screen (`MemberDetailView`). The values here
/// are the ones a member sees for this account under Show technical details
/// there.
///
/// The copy is one line on purpose: text about security
/// numbers is minimal; those who care know what to do with them. Nothing here
/// is secret: all three values are published to the server.
struct MyKeysView: View {
    @State private var copied = false

    /// `exportPublicKey()` hands back base64, while every peer key in the app
    /// (member security details, the wrap/rotation payloads) is hex; render
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
                Text("These are the public values other members see for you.")
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
