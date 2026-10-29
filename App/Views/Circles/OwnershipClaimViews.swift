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

/// The live ownership claim on a circle, as a section for the circle's own
/// screen.
///
/// This is the surface that has to survive a swiped-away notification. The push
/// that announces a claim says "Open Pingolin to refuse", the deadline is
/// fourteen days out, and a notification row can be deleted with one swipe — so
/// the circle itself has to keep saying it, for as long as the claim is live.
///
/// Everything actionable is a ROW. `Section(footer:)` renders only its first
/// view and does not reliably deliver taps inside one; a refuse control that
/// silently swallowed taps would be worse here than nowhere at all.
struct OwnershipClaimSection: View {
    let circle: Circle

    @StateObject private var claims = OwnershipClaimManager.shared
    @StateObject private var circleManager = CircleManager.shared
    @State private var confirmingRefuse = false
    @State private var confirmingWithdraw = false
    @State private var actionError: String?

    /// The claimant's name from the locally-loaded roster. nil is ordinary, not
    /// a failure — display names come from the auth service, and the roster may
    /// simply not be loaded on this screen yet.
    private var claimantName: String? {
        guard let claimantId = claims.claim(for: circle.id)?.claimantUserId else { return nil }
        return circleManager.members[circle.id]?
            .first { $0.userId == claimantId }?
            .displayName
    }

    private var presentation: OwnershipClaimPresentation? {
        guard let claim = claims.claim(for: circle.id) else { return nil }
        return OwnershipClaimPresentation.make(
            claim: claim,
            viewerUserId: AuthManager.shared.userId,
            viewerIsOwner: circle.isOwner,
            claimantName: claimantName
        )
    }

    var body: some View {
        // The alerts hang off the BUTTONS, not off the Section. A Section
        // wrapped in modifiers is no longer plainly a section to List's layout,
        // and the row-level pattern is the one already proven here (see
        // MemberRow's remove-and-rotate alerts).
        if let presentation = presentation {
            Section {
                OwnershipClaimRows.summary(presentation)

                if presentation.showsRefuse {
                    Button {
                        confirmingRefuse = true
                    } label: {
                        Label("Refuse this request", systemImage: "hand.raised")
                    }
                    .disabled(claims.busy.contains(circle.id))
                    .accessibilityIdentifier("refuse-ownership-claim")
                    .alert("Refuse this request?", isPresented: $confirmingRefuse) {
                        Button("Cancel", role: .cancel) {}
                        Button("Refuse") { Task { await refuse() } }
                    } message: {
                        // ONE Text: SwiftUI renders only the first view in an
                        // alert's message builder, so a second would vanish.
                        Text(
                            "You stay the owner of this circle. The request ends for good — "
                            + "an admin can ask again later, and you would be told again if they do."
                        )
                    }
                    .alert(
                        "Couldn't refuse the request",
                        isPresented: Binding(
                            get: { actionError != nil },
                            set: { if !$0 { actionError = nil } }
                        )
                    ) {
                        Button("OK", role: .cancel) { actionError = nil }
                    } message: {
                        Text(actionError ?? "")
                    }
                }

                if presentation.showsWithdraw {
                    Button {
                        confirmingWithdraw = true
                    } label: {
                        Label("Withdraw my request", systemImage: "arrow.uturn.backward")
                    }
                    .disabled(claims.busy.contains(circle.id))
                    .accessibilityIdentifier("withdraw-ownership-claim")
                    .alert("Withdraw your request?", isPresented: $confirmingWithdraw) {
                        Button("Cancel", role: .cancel) {}
                        Button("Withdraw") { Task { await withdraw() } }
                    } message: {
                        Text("The owner keeps the circle. You can ask again later.")
                    }
                    .alert(
                        "Couldn't withdraw the request",
                        isPresented: Binding(
                            get: { actionError != nil },
                            set: { if !$0 { actionError = nil } }
                        )
                    ) {
                        Button("OK", role: .cancel) { actionError = nil }
                    } message: {
                        Text(actionError ?? "")
                    }
                }
            }
        }
    }

    /// Never swallowed. A refusal that did not land leaves the countdown running
    /// against somebody who believes they stopped it — and re-reading the claim
    /// afterwards is what corrects the screen when the reason was that the
    /// world moved on (already refused, already withdrawn, already settled).
    private func refuse() async {
        do {
            try await claims.refuse(circleId: circle.id)
        } catch {
            actionError = OwnershipClaimCopy.refuseFailure(error)
            await claims.refresh(circleId: circle.id)
        }
    }

    private func withdraw() async {
        do {
            try await claims.withdraw(circleId: circle.id)
        } catch {
            actionError = OwnershipClaimCopy.withdrawFailure(error)
            await claims.refresh(circleId: circle.id)
        }
    }
}

/// The wording rows shared by the circle screen and the standalone screen the
/// notification opens, so the two can never drift into saying different things
/// about the same claim.
///
/// A `@ViewBuilder` function rather than a `View` struct on purpose. A custom
/// View whose body is two views is ONE list row; a builder's tuple is flattened
/// by the enclosing `Section`, which is what makes the deadline its own
/// scannable row instead of a line buried in a paragraph.
enum OwnershipClaimRows {
    @ViewBuilder
    static func summary(_ presentation: OwnershipClaimPresentation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle.badge.exclamationmark")
                    .foregroundStyle(presentation.viewer == .owner ? Color.orange : Color.secondary)
                Text(presentation.title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
            }
            Text(presentation.message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("ownership-claim-summary")

        if let deadlineText = presentation.deadlineText {
            // Rendered in the device's own timezone. The wire value is UTC, and
            // an owner far enough east or west could otherwise read a date a
            // whole day off from when their circle actually changes hands.
            LabeledContent("Ownership passes on", value: deadlineText)
                .accessibilityIdentifier("ownership-claim-deadline")
        }
    }
}

/// The row that lets an admin open a claim, plus the confirmation that explains
/// what opening one does.
///
/// Shown to admins who are not the owner, and to nobody else — the rule the
/// Android app applies and the one the server enforces (it allows admins
/// only, so anybody else who could tap this would only ever be refused). The
/// role is read from the roster the circle screen loads on appear; until it
/// has loaded the row stays hidden rather than guessing.
/// `OwnershipClaimAccess.canOpen` is the rule, pinned by tests.
struct ClaimOwnershipRow: View {
    let circle: Circle

    @StateObject private var claims = OwnershipClaimManager.shared
    @StateObject private var circleManager = CircleManager.shared
    @State private var confirming = false
    @State private var errorMessage: String?

    /// Our own row in the loaded roster, if it has loaded.
    private var viewerRole: CircleMember.MemberRole? {
        guard let me = AuthManager.shared.userId else { return nil }
        return circleManager.members[circle.id]?.first { $0.userId == me }?.role
    }

    var body: some View {
        if OwnershipClaimAccess.canOpen(
            viewerIsOwner: circle.isOwner,
            viewerRole: viewerRole,
            hasLiveClaim: claims.claim(for: circle.id) != nil
        ) {
            Button {
                confirming = true
            } label: {
                Label("Ask to take over this circle", systemImage: "person.crop.circle.badge.questionmark")
            }
            .disabled(claims.busy.contains(circle.id))
            .accessibilityIdentifier("open-ownership-claim")
            .alert("Ask to take over this circle?", isPresented: $confirming) {
                Button("Cancel", role: .cancel) {}
                Button("Ask") { Task { await open() } }
            } message: {
                Text(
                    "This is for a circle whose owner can no longer act — only they can "
                    + "delete it, hand it on, or change who is an admin.\n\n"
                    + "The owner is told straight away and can refuse with one tap. "
                    + "If they do nothing for two weeks, you become the owner. "
                    + "You can withdraw the request at any time before that."
                )
            }
            .alert(
                "Couldn't ask to take over",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func open() async {
        do {
            try await claims.open(circleId: circle.id)
        } catch {
            errorMessage = OwnershipClaimCopy.openFailure(error)
            // A 409 means somebody else's claim is already live. Re-read so the
            // banner appears instead of leaving the person who just asked with
            // nothing but an error about a request they cannot see.
            await claims.refresh(circleId: circle.id)
        }
    }
}

/// Standalone screen for the `circle_ownership_claim` notification.
///
/// The notification tap has to land somewhere the owner can act, and it cannot
/// rely on the circle already being on screen — so this screen loads what it
/// needs itself: the circle, the roster (for the claimant's name), and the
/// claim.
struct OwnershipClaimScreen: View {
    let circleId: String

    @StateObject private var claims = OwnershipClaimManager.shared
    @StateObject private var circleManager = CircleManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var isLoading = true

    private var circle: Circle? {
        circleManager.circles.first { $0.id == circleId }
    }

    var body: some View {
        List {
            if let circle = circle {
                if claims.claim(for: circleId) != nil {
                    OwnershipClaimSection(circle: circle)
                } else if !isLoading {
                    // A claim can be refused, withdrawn or settled between the
                    // push landing and the tap. Say only what can honestly be
                    // told from here, which is that it is over.
                    Section {
                        Text("There is no longer a request to take over this circle.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Circle") {
                    LabeledContent("Name", value: circle.name)
                    NavigationLink("Open this circle") {
                        CircleDetailView(circle: circle)
                    }
                }
            } else if !isLoading {
                Section {
                    Text("This circle isn't on this device any more.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
        }
        .navigationTitle("Circle ownership")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
        .task {
            // The circle list may be cold on a launch straight from a push.
            if circleManager.circles.isEmpty {
                try? await circleManager.loadCircles()
            }
            // The roster is what turns a claimant user id into a name. Best
            // effort: the sentence reads "An admin in this circle" without it.
            if circleManager.members[circleId] == nil {
                try? await circleManager.loadMembers(for: circleId)
            }
            await claims.refresh(circleId: circleId)
            isLoading = false
        }
        .refreshable {
            await claims.refresh(circleId: circleId)
        }
    }
}

/// A circle's own screen, for a notification about it: the claimant's "your
/// request was refused", from the push or the bell row. The tap can launch
/// the app, so the circle list is loaded when it is cold.
struct NotifiedCircleScreen: View {
    let circleId: String

    @StateObject private var circleManager = CircleManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var isLoading = true

    var body: some View {
        Group {
            if let circle = Self.circle(circleId, in: circleManager.circles) {
                CircleDetailView(circle: circle)
            } else if isLoading {
                ProgressView()
            } else {
                Text("This circle isn't on this device any more.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding()
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
        }
        .task {
            if circleManager.circles.isEmpty {
                try? await circleManager.loadCircles()
            }
            isLoading = false
        }
    }

    /// The circle a notification names, in any spelling of its id.
    static func circle(_ circleId: String, in circles: [Circle]) -> Circle? {
        circles.first { CanonicalId.sameKey($0.id, circleId) }
    }
}
