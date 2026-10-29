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

/// Member detail screen with the safety-number (SAS) verification
/// flow. Reached from the Circles list → tap a member. Mirrors
/// the Android app's `MemberDetailFragment` and the web client's member
/// detail.
///
/// The safety number is a 60-digit symmetric hash of both participants'
/// (user_id, sharing_pubkey, signing_pubkey) tuples. Same value on both
/// sides; reading it out-of-band lets two members confirm nobody injected
/// a substituted key.
struct MemberDetailView: View {
    let circleId: String
    let userId: String

    @StateObject private var circleManager = CircleManager.shared
    @State private var safetyNumber: String?
    @State private var peerKeys: (sharing: String, signing: String)?
    @State private var error: String?
    @State private var copied = false
    @State private var showDetails = false
    /// Loaded in `.task` rather than initialised inline: `circleId`/`userId` are
    /// `let` properties on the struct, not available to a `@State` default.
    @State private var verifiedAt: Date?

    private var member: CircleMember? {
        circleManager.members[circleId]?.first { $0.userId == userId }
    }

    private var memberName: String {
        member?.displayName.isEmpty == false ? member!.displayName : "this member"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let member = member {
                    Text(member.displayName)
                        .font(.largeTitle)
                        .fontWeight(.bold)
                    Text("Role: \(member.role.rawValue.capitalized)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    // Why their position is not updating in this circle.
                    if !CanonicalId.same(member.userId, AuthManager.shared.userId),
                       let sentence = SharingStatusCopy.detailSentence(name: member.displayName, member.sharing()) {
                        Text(sentence)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("member-sharing-status")
                    }
                    // Their history isn't shown in this
                    // circle.
                    if !CanonicalId.same(member.userId, AuthManager.shared.userId), !member.sharesHistory {
                        Text(SharingStatusCopy.historyOffSentence(name: member.displayName))
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("member-history-off")
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Security code")
                        .font(.headline)

                    if let safetyNumber = safetyNumber {
                        Text("Compare these 60 digits with \(memberName) in person, or on a call you placed yourself. They should open Security details for you on their phone (Circles → the circle → your ⋯ button); the twelve groups will be the same on both phones.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        // Rendered EXACTLY as the SDK returns it. `computeSafetyNumber`
                        // already emits the locked cross-platform layout — 12 groups of
                        // 5 digits joined by single ASCII spaces — and re-grouping it
                        // here would make iOS disagree with Android and web: inserting
                        // a space every 5 CHARACTERS counts the SDK's own spaces, so the
                        // groups drift out of step ("69559  8383 0 576 95 …") and no two
                        // devices show the same thing. Leave this string untouched.
                        Text(safetyNumber)
                            .font(.system(.body, design: .monospaced))
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.systemGray6))
                            .cornerRadius(8)
                            .textSelection(.enabled)
                        Button(action: copyNumber) {
                            Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                                .font(.footnote)
                        }
                        .buttonStyle(.bordered)

                        verifiedToggle
                    } else if let error = error {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    } else {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Computing…")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let peerKeys = peerKeys {
                    Divider()
                    technicalDetails(peerKeys)
                }

                Spacer()
            }
            .padding()
        }
        .navigationTitle(member?.displayName ?? "Member")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            verifiedAt = MemberVerificationStore.verifiedAt(circleId: circleId, userId: userId)
            await loadSafetyNumber()
        }
    }

    /// Device-local "I compared this out of band" marker, persisted per
    /// (circleId, userId) via the shared `MemberVerificationStore` so the
    /// approve-key-change and logout paths can invalidate it from the same
    /// source of truth. Mirrors the Android app's `switchVerified` and the
    /// web client's "Mark as verified" button, so a user who did the
    /// comparison can record it and tell, a week later, whether they ever
    /// had.
    ///
    /// Gated on a computed safety number — like the web client, and unlike
    /// the Android app, which shows the switch even when the number failed to
    /// compute. There is nothing to have compared in that state, so offering
    /// the tick invites a marker that vouches for a value the user never saw.
    @ViewBuilder
    private var verifiedToggle: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle("Verified out of band", isOn: Binding(
                get: { verifiedAt != nil },
                set: { isOn in
                    if isOn {
                        let now = Date()
                        MemberVerificationStore.setVerified(circleId: circleId, userId: userId, at: now)
                        verifiedAt = now
                    } else {
                        MemberVerificationStore.clearVerified(circleId: circleId, userId: userId)
                        verifiedAt = nil
                    }
                }
            ))
            .font(.subheadline)

            Text(verifiedSubtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 8)
    }

    private var verifiedSubtitle: String {
        guard let verifiedAt = verifiedAt else { return "Not yet verified out of band" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "Verified \(formatter.string(from: verifiedAt))"
    }

    /// The peer's raw published keys. These are the values the OTHER person can
    /// read back on their own device under Settings → Security & Devices →
    /// Security details — the same lowercase hex on both screens, because both
    /// render the same bytes. Naming that
    /// destination is the whole point of the section: the safety number is
    /// pairwise and has no counterpart on the Encryption screen, so without this
    /// there is nothing on either screen a user can line up by eye.
    @ViewBuilder
    private func technicalDetails(_ keys: (sharing: String, signing: String)) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: { showDetails.toggle() }) {
                Label(
                    showDetails ? "Hide technical details" : "Show technical details",
                    systemImage: showDetails ? "chevron.down" : "chevron.right"
                )
                .font(.footnote)
            }
            .buttonStyle(.borderless)

            if showDetails {
                Text("\(memberName)'s technical details. On their own phone these appear under Settings → Security & Devices → Security details, character for character.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                keyRow("Encryption ID (X25519)", value: keys.sharing)
                keyRow("Signature ID (Ed25519)", value: keys.signing)
                keyRow("User ID", value: userId)
            }
        }
    }

    @ViewBuilder
    private func keyRow(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            // Same renderer as Security details (Settings), because the copy on
            // that screen promises this one shows "exactly what you see here".
            PublicKeyText(value: value, font: .caption)
        }
        .padding(.top, 8)
    }

    private func loadSafetyNumber() async {
        guard let selfUserId = AuthManager.shared.userId else {
            error = "Sign in to see the security code."
            return
        }

        // Peer keys come from the member roster, which serves BOTH keys to
        // every member of the circle. The dedicated `member-public-keys`
        // route is not an option here: the server allows it to owners and
        // admins only, so a plain member reading this screen would get 403
        // "Insufficient permissions" where a number should be.
        var keys = circleManager.cachedMemberKeys(circleId: circleId, userId: userId)
        if keys == nil {
            // Cold cache (deep link, or the roster hasn't been fetched for this
            // circle yet) — populate it, then look again.
            do {
                try await circleManager.loadMembers(for: circleId)
            } catch let api as APIError {
                error = api.plainLine
                return
            } catch {
                self.error = error.plainText
                return
            }
            keys = circleManager.cachedMemberKeys(circleId: circleId, userId: userId)
        }

        guard let keys = keys else {
            error = "The security code isn't available yet — \(memberName)'s account isn't fully set up."
            return
        }

        do {
            let number = try SDKCrypto.cryptoManager.computeSafetyNumber(
                selfUserId: selfUserId,
                peerUserId: userId,
                peerSharingPubkeyHex: keys.sharing,
                peerSigningPubkeyHex: keys.signing
            )
            self.peerKeys = keys
            self.safetyNumber = number
        } catch {
            self.error = error.plainText
        }
    }

    private func copyNumber() {
        guard let safetyNumber = safetyNumber else { return }
        // The safety number authenticates a peer's keys — keep it off
        // Universal Clipboard (local-only, no sync to other devices) and
        // expire it from the pasteboard after 60 seconds rather than
        // leaving it readable by any app indefinitely.
        UIPasteboard.general.setItems(
            [[UIPasteboard.typeAutomatic: safetyNumber]],
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
