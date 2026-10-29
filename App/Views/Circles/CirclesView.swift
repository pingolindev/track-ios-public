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
import UIKit

/// A circle waiting to be shown its location notice.
///
/// Identifiable so it can drive a `sheet(item:)`: the sheet needs the id to
/// record the consent against AND the name to put in the header, and presenting
/// with either missing would show a notice that does not say which circle it is
/// about.
struct PendingLocationConsent: Identifiable {
    let circleId: String
    let circleName: String
    var id: String { circleId }
}

struct CirclesView: View {
    @StateObject private var circleManager = CircleManager.shared
    @StateObject private var invitesManager = InvitesManager.shared
    @StateObject private var claimManager = OwnershipClaimManager.shared
    @State private var showingCreateCircle = false
    @State private var inviteError: String?

    /// A non-error outcome worth confirming — declining the notice, above all.
    ///
    /// Kept apart from `inviteError` because that alert is titled "Couldn't
    /// update invite", and putting a deliberate "Not now" under it tells
    /// somebody their own choice failed. That alert also covers the invite
    /// list, so the row the message says is still there would be hidden
    /// behind it.
    private struct InviteNotice: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }
    @State private var inviteNotice: InviteNotice?
    /// Locally-applied sort order. Re-derived from
    /// `CircleOrderStore` + the server-returned `circles` whenever
    /// either changes; drag-reorder mutates this in place and
    /// writes back to the store. Mirrors the Android app's
    /// `circle_sort_order` table.
    @State private var orderedCircles: [Circle] = []
    /// Drives the toolbar EditButton + the List's editMode binding.
    /// SwiftUI's `.onMove` only enables drag handles in edit mode,
    /// so users tap "Edit" to reorder and "Done" to commit. Cleaner
    /// than always-on handles which read as clutter on a list users
    /// don't reorder often.
    @State private var editMode: EditMode = .inactive
    /// The invitation whose location notice is waiting to be answered, if any.
    ///
    /// Set by Accept, read by the sheet below. Not a Bool + separate id: the
    /// sheet needs both the id and the name to show, and an `item:` sheet cannot
    /// present with either missing.
    @State private var pendingConsent: PendingLocationConsent?
    /// Resumed with the user's answer when the notice closes, so the invite path
    /// can AWAIT it and do nothing at all until it has one.
    @State private var consentAnswer: CheckedContinuation<(Bool, ShownNotice?), Never>?


    var body: some View {
        NavigationStack {
            List {
                if !invitesManager.invites.isEmpty {
                    Section("Invitations") {
                        ForEach(invitesManager.invites, id: \.id) { invite in
                            PendingInviteRow(
                                invite: invite,
                                joiningWhenRenewed: invitesManager.renewalWaits[invite.id] != nil,
                                notRenewable: invitesManager.notRenewable.contains(invite.id),
                                onAccept: { await acceptInvite(invite) },
                                onDecline: { await declineInvite(invite) }
                            )
                        }
                    }
                }

                if circleManager.circles.isEmpty && invitesManager.invites.isEmpty {
                    EmptyCirclesView(
                        onCreateCircle: { showingCreateCircle = true }
                    )
                } else if !circleManager.circles.isEmpty {
                    // Section header only appears when there's a
                    // Invitations section above — otherwise it
                    // reads as an unnecessary "Your Circles" label
                    // above the only content on the screen.
                    if invitesManager.invites.isEmpty {
                        ForEach(orderedCircles) { circle in
                            NavigationLink(destination: CircleDetailView(circle: circle)) {
                                CircleRow(circle: circle)
                            }
                            .deleteDisabled(true)
                        }
                        .onMove(perform: moveCircles)
                    } else {
                        Section("Your Circles") {
                            ForEach(orderedCircles) { circle in
                                NavigationLink(destination: CircleDetailView(circle: circle)) {
                                    CircleRow(circle: circle)
                                }
                                .deleteDisabled(true)
                            }
                            .onMove(perform: moveCircles)
                        }
                    }
                }
            }
            .navigationTitle("Circles")
            .environment(\.editMode, $editMode)
            .toolbar {
                // Show the EditButton only when there's something
                // worth ordering — a single circle would just look
                // confusing with drag handles next to it.
                if orderedCircles.count >= 2 {
                    ToolbarItem(placement: .navigationBarLeading) {
                        EditButton()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    // A plain button, not a Menu: a menu that opens to reveal
                    // a single item is worse than the item.
                    Button(action: { showingCreateCircle = true }) {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Create Circle")
                }
            }
            .task {
                orderedCircles = CircleOrderStore.apply(to: circleManager.circles, owner: AuthManager.shared.userId)
                await claimManager.refresh(circleIds: circleManager.circles.map(\.id))
            }
            .onChange(of: circleManager.circles) { _, new in
                orderedCircles = CircleOrderStore.apply(to: new, owner: AuthManager.shared.userId)
                // The list is usually empty when `.task` first runs on a cold
                // launch, so this is what actually populates the claim badges.
                Task { await claimManager.refresh(circleIds: new.map(\.id)) }
            }
            .refreshable {
                async let circles: Void = { try? await circleManager.loadCircles() }()
                async let invites: Void = invitesManager.refresh()
                _ = await (circles, invites)
                await claimManager.refresh(circleIds: circleManager.circles.map(\.id))
            }
            .sheet(isPresented: $showingCreateCircle) {
                // The notice is asked INSIDE the create sheet, before anything
                // is created: no circle without the creator's yes.
                CreateCircleSheet()
            }
            .sheet(item: $pendingConsent) { pending in
                // Only an invitation's notice lands here: the answer goes back to
                // `acceptInvite`, which is awaiting it, and nothing touches the
                // circle before it.
                LocationConsentView(
                    circleName: pending.circleName,
                    purpose: .join,
                    onFinish: { granted, shown in
                        pendingConsent = nil
                        consentAnswer?.resume(returning: (granted, shown))
                        consentAnswer = nil
                    }
                )
            }
            .alert("Couldn't update invite", isPresented: .constant(inviteError != nil)) {
                Button("OK") { inviteError = nil }
            } message: {
                Text(inviteError ?? "")
            }
            .alert(inviteNotice?.title ?? "", isPresented: .constant(inviteNotice != nil)) {
                Button("OK") { inviteNotice = nil }
            } message: {
                Text(inviteNotice?.message ?? "")
            }
        }
    }

    private func moveCircles(from source: IndexSet, to destination: Int) {
        orderedCircles.move(fromOffsets: source, toOffset: destination)
        CircleOrderStore.save(orderedCircles.map { $0.id }, owner: AuthManager.shared.userId)
    }

    /// Accept an invite — but only on the far side of the consent notice.
    ///
    /// THE NOTICE IS THE GATE, and joining IS agreeing: if you don't consent,
    /// you can't be in the circle. Nothing touches the circle until the user
    /// has answered it: no accept, no membership, no row anywhere. Decline and
    /// it is as if Accept was never pressed — the invitation is untouched and
    /// still pending, so it can be taken up later.
    ///
    /// Agreeing sends the consent WITH the accept: one request, one transaction
    /// on the server. There is no "joined, consent not recorded yet" moment for
    /// anything to go wrong in, and nothing to undo.
    private func acceptInvite(_ invite: ReceivedInviteResponse) async {
        // An invitation to an account carries no plain name and the
        // sealed one can't be read before joining, so the notice says
        // "this circle". An older server may still send a name.
        let label = invite.circleName ?? "this circle"

        // An invitation sent to another address or account goes nowhere:
        // say so before asking anything (an address invitation is never
        // renewed). One naming this account's keys from before a password
        // reset is renewed instead, so the notice is still asked: this
        // device joins by itself with that yes once it is.
        if let refusal = invitesManager.refusal(invite) {
            inviteError = refusal
            return
        }
        let (granted, shown): (Bool, ShownNotice?) = await withCheckedContinuation { cont in
            consentAnswer = cont
            pendingConsent = PendingLocationConsent(circleId: invite.circleId, circleName: label)
        }
        guard granted else {
            // Nothing happened, and nothing needs undoing. Not an error: the
            // person answered the question, and this says what their answer did.
            inviteNotice = InviteNotice(title: "Not joined", message: Self.notJoinedMessage(label))
            return
        }

        do {
            _ = try await invitesManager.accept(invite: invite, consent: shown)
        } catch InviteAcceptError.renewing(let text) {
            // What is happening, not an error: nothing more for them to do.
            inviteNotice = InviteNotice(title: "Invitation being renewed",
                                        message: text + " " + InvitesManager.joinsWhenRenewed(circle: label))
        } catch let refusal as InviteAcceptError {
            inviteError = refusal.plainText
        } catch {
            inviteError = "Accept failed: \(error.plainText)"
        }
    }

    /// What "Not now" on an invitation did. The same words as the Android
    /// app and the web client; "Invitations" is the section it stays in.
    static func notJoinedMessage(_ circle: String) -> String {
        "You didn't join \(circle). Your invitation is still in Invitations if you change your mind."
    }

    private func declineInvite(_ invite: ReceivedInviteResponse) async {
        do {
            try await invitesManager.decline(invite: invite)
        } catch {
            inviteError = "Decline failed: \(error.plainText)"
        }
    }
}

/// Pending-invite list row, with Accept and Decline buttons. An
/// invitation whose key the inviter could not pre-wrap
/// (`hasEncryptedKey` false) can be accepted too; a hint under
/// the buttons says it opens once another member's app is online.
struct PendingInviteRow: View {
    let invite: ReceivedInviteResponse
    /// This person already said yes and this device joins by itself once the
    /// invitation is renewed: no Accept to press again.
    var joiningWhenRenewed: Bool = false
    /// Nothing will renew it (its sender is no longer an owner or admin): it
    /// says so, and offers only Decline.
    var notRenewable: Bool = false
    /// Awaited, so the row knows when it is over.
    ///
    /// The row does not always disappear when its action completes:
    /// declining the location notice is an ORDINARY outcome that leaves the
    /// invite exactly where it was. A fire-and-forget action would leave the
    /// row spinning, both buttons disabled, contradicting the message that
    /// "the invite is still there if you change your mind".
    let onAccept: () async -> Void
    let onDecline: () async -> Void

    @State private var working = false

    /// An invitee can't read the sealed name before joining, and an invitation
    /// to an account carries no plain one (an older server may still send
    /// one). So say that we don't know, not that the circle has no name:
    /// "Untitled circle" would be a claim about the circle, and a false one.
    private var circleDisplayName: String {
        invite.circleName ?? "Circle invite"
    }

    private var subtitle: String {
        if let inviter = invite.inviterDisplayName, !inviter.isEmpty {
            return "Invited by \(inviter)"
        }
        return "Invited by another member"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "envelope.fill")
                    .foregroundStyle(.blue)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(circleDisplayName)
                        .fontWeight(.medium)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack(spacing: 8) {
                Button {
                    Task { working = true; await onDecline(); working = false }
                } label: {
                    Text("Decline")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(working)

                if !joiningWhenRenewed && !notRenewable {
                    Button {
                        // `working` is cleared however this ends. The row survives a
                        // declined notice, so "finished" is not the same as "gone".
                        Task { working = true; await onAccept(); working = false }
                    } label: {
                        if working {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Accept").frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    // NOT gated on hasEncryptedKey. hasEncryptedKey
                    // == false means the INVITER could not pre-wrap
                    // the circle key — exactly what happens when the
                    // invitee had no account or no published sharing
                    // key at invite time. That is the ordinary
                    // new-user path. (There are no link-style invites
                    // to open instead.)
                    //
                    // The server supports it outright: accepting such
                    // an invite marks the circle as needing a key
                    // exchange and notifies the other members, so an
                    // eligible member distributes a wrap.
                    // The Android app does not gate this either.
                    .disabled(working)
                }
            }
            // What is happening while it is renewed, never "ask them".
            if notRenewable {
                Text(InvitesManager.notRenewableText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("invite-not-renewable")
            } else if joiningWhenRenewed {
                Text(InvitesManager.joiningWhenRenewed(inviter: invite.inviterDisplayName))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("invite-joining-when-renewed")
            } else if invite.renewalRequested == true {
                Text(InvitesManager.beingRenewed(inviter: invite.inviterDisplayName))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("invite-being-renewed")
            } else if !invite.hasEncryptedKey {
                // Any member's app lets a signed invitation's
                // newcomer in, so there is nobody in particular
                // to wait for.
                Text("You can accept now. It opens as soon as another member's app is online.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Invites sent from this circle that nobody has accepted or declined yet,
/// each revocable.
///
/// This matches what the invite flow says — "Invite people by email - they
/// accept or decline, and you can revoke an invite that is still pending" —
/// and the Android app has the same list with a revoke confirmation.
///
/// Hidden entirely when the list is empty, which also covers the plain-member
/// case: GET /circles/:id/invites is owner/admin only, their fetch 403s, and
/// CircleManager leaves the array empty rather than surfacing an error over a
/// circle that is fine.
struct PendingInvitesSection: View {
    let circle: Circle
    @StateObject private var circleManager = CircleManager.shared
    @State private var confirming: PendingInviteResponse?
    @State private var revoking: Set<String> = []
    @State private var errorMessage: String?

    @ObservedObject private var pendingChanges = PendingChangeStore.shared

    private var invites: [PendingInviteResponse] {
        circleManager.pendingInvites[circle.id] ?? []
    }

    /// Invitations and renewals waiting for this iPhone to catch up: shown
    /// where the sent invitations are.
    private var waiting: Bool {
        pendingChanges.pending(circleId: circle.id).contains { $0.kind == .invite || $0.kind == .renewInvitation }
    }

    var body: some View {
        if !invites.isEmpty || waiting {
            Section("Invited (\(invites.count))") {
                PendingChangesInPlace(kinds: [.invite, .renewInvitation], circleId: circle.id)
                ForEach(invites) { invite in
                    row(invite)
                }
            }
            .alert("Revoke invite?", isPresented: .constant(confirming != nil), presenting: confirming) { invite in
                Button("Cancel", role: .cancel) { confirming = nil }
                Button("Revoke", role: .destructive) {
                    let target = invite
                    confirming = nil
                    Task { await revoke(target) }
                }
            } message: { invite in
                // Names the address, because an owner with several invites out
                // needs to know WHICH one this is before destroying it.
                Text(invite.targetEmail.map {
                    "\($0) will no longer be able to join this circle."
                } ?? "The recipient will no longer be able to join this circle.")
            }
            .alert("Couldn't revoke invite", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    @ViewBuilder
    private func row(_ invite: PendingInviteResponse) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(invite.targetEmail ?? "Invite link")
                    .font(.body)
                // Day precision on purpose: the server returns day buckets, not
                // instants, so a time here would be invented.
                Text("Expires \(invite.expiresOn.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let note = invite.keylessNote {
                    // Says why this person will not see the circle the moment
                    // they join, so it does not read as a bug later.
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if revoking.contains(invite.id) {
                ProgressView().controlSize(.small)
            } else {
                Button("Revoke") { confirming = invite }
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func revoke(_ invite: PendingInviteResponse) async {
        revoking.insert(invite.id)
        defer { revoking.remove(invite.id) }
        do {
            try await circleManager.revokeInvite(circleId: circle.id, inviteId: invite.id)
        } catch {
            errorMessage = error.plainText
        }
    }
}

struct EmptyCirclesView: View {
    let onCreateCircle: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "person.3.fill")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                Text("No Circles Yet")
                    .font(.title2)
                    .fontWeight(.semibold)

                // Says how you get IN to someone else's circle:
                // there is no "Join a Circle" button and nothing to
                // type. An invite arrives by email and then shows
                // up on this screen as a pending invite, which is
                // also why this empty state only renders when there
                // are no invites either.
                Text("Create a circle to start sharing your location with family and friends. If somebody invites you to theirs, the invitation appears here.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 12) {
                Button(action: onCreateCircle) {
                    Label("Create a Circle", systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal)
        }
        .padding()
        .listRowBackground(Color.clear)
    }
}

struct CircleRow: View {
    let circle: Circle
    @StateObject private var circleManager = CircleManager.shared
    @StateObject private var claims = OwnershipClaimManager.shared

    var memberCount: Int {
        circleManager.members[circle.id]?.count ?? 0
    }

    var body: some View {
        HStack(spacing: 12) {
            // Circle icon
            ZStack {
                SwiftUI.Circle()
                    .fill(.blue.opacity(0.2))
                    .frame(width: 50, height: 50)

                Image(systemName: "person.3.fill")
                    .foregroundStyle(.blue)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(circle.name)
                        .fontWeight(.medium)

                    if circle.isOwner {
                        Text("Owner")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.blue.opacity(0.2))
                            .foregroundStyle(.blue)
                            .cornerRadius(4)
                    }
                }

                Text("\(memberCount) member\(memberCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // Why this circle is unreadable here, by cause. Tapping the row
                // opens the circle, where the full explanation sits on top.
                LockedCircleCaption(circle: circle)

                // A new name waiting and how many changes wait
                // to go out for this circle; Cancel is in the
                // circle.
                PendingChangesCaption(circleId: circle.id)

                // Owners/admins: a removed member's key still
                // works until the re-key lands, or the key was
                // withheld from someone the server listed who
                // is not on the roster.
                CircleKeyNoticeCaption(circle: circle)

                // A live ownership claim, said out loud on the list. The owner's
                // other in-app notice is a notification row that a swipe
                // removes, and the countdown runs for a fortnight after that —
                // so the circle has to carry the warning itself.
                if claims.claim(for: circle.id) != nil {
                    Label(
                        circle.isOwner
                            ? "Someone asked to take over — tap to refuse"
                            : "Someone asked to take over this circle",
                        systemImage: "person.crop.circle.badge.exclamationmark"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("circle-row-ownership-claim")
                }
            }

            Spacer()
            // Key-rotation state intentionally NOT surfaced here.
            // CircleManager.loadCircles runs autoRotation in the
            // background after every refresh; rotation is a
            // mechanical consequence of membership changes that
            // the user has no meaningful way to act on. Parity
            // with the Android app, which has no manual rotate UI
            // for the same reason: users can't meaningfully
            // trigger a rotation.
        }
        .padding(.vertical, 4)
    }
}

struct CircleDetailView: View {
    let circle: Circle
    @StateObject private var circleManager = CircleManager.shared
    @State private var showingInvite = false
    @State private var showingSettings = false
    @State private var showingDeleteConfirm = false
    @State private var leaveError: String?
    /// Drives the push to MemberDetailView. Held here rather than in
    /// MemberRow because `navigationDestination` must not live inside a lazy
    /// container — List only builds the rows it renders, so a destination
    /// declared on a row is invisible to the stack until that row is on
    /// screen. Keyed by user id — `navigationDestination(item:)` wants a
    /// Hashable and CircleMember isn't one.
    @State private var securityDetailsUserId: String?
    /// Consent state for this circle. Nil while unknown — the section renders
    /// nothing rather than guessing, because telling somebody who IS sharing
    /// that they are not is worse than showing nothing for a moment.
    @State private var consent: LocationConsentResponse?
    // Pop back to the Circles list after a successful leave /
    // delete. NavigationStack(path:) isn't in play on this screen
    // (NavigationLink-based push), so the canonical pop signal is
    // `dismiss()` from the environment.
    @Environment(\.dismiss) private var dismiss

    var members: [CircleMember] {
        circleManager.members[circle.id] ?? []
    }

    /// The circle as the manager holds it NOW. `circle` is the value this
    /// screen was opened with, so a key that arrives while it is open would
    /// leave a stale lock explanation on screen.
    private var liveCircle: Circle {
        circleManager.circles.first(where: { $0.id == circle.id }) ?? circle
    }

    var body: some View {
        List {
            // A locked circle says why, and what to do, before anything else:
            // the rest of this screen is mostly unreadable in that state.
            LockedCircleSection(circle: liveCircle)
            // What this iPhone will do once it has caught up, with Cancel,
            // and the lines of what wasn't done.
            PendingChangesSection(circleId: circle.id)
            CircleKeyNoticeSections(circle: liveCircle)

            // Above everything else. A live claim means this circle changes
            // owner on a date unless somebody acts, and the owner's only other
            // in-app notice is a notification row one swipe from gone. It
            // renders nothing at all when there is no claim.
            OwnershipClaimSection(circle: circle)

            // Location consent, above the members list: being in a circle
            // is sharing with it. Stopping is leaving, with the circle's
            // own Leave below; the pause is in Privacy Settings. A
            // membership with no yes on record (older than the notice)
            // shows nothing — no prompt, no state.
            if let consent, Self.isSharing(consent) {
                locationConsentSection
            } else if let line = SharingStatusCopy.ownSentence(ownSharing, historyOn: ownHistoryOn) {
                // No yes on record, but off or paused all the same: the truth,
                // and what the others see, still belong at the top.
                Section {
                    ownSharingRow(line)
                } header: {
                    Text("Location sharing")
                } footer: {
                    Text(Self.membershipNote)
                }
            }

            // Members section. Tapping a row shows the member on the map;
            // security details live in the row's menu.
            Section("Members (\(members.count))") {
                // Promotions and "Let them in" answers waiting for this
                // iPhone to catch up.
                PendingChangesInPlace(kinds: [.makeAdmin, .letIn], circleId: circle.id)
                ForEach(members) { member in
                    MemberRow(
                        member: member,
                        circle: circle,
                        onSecurityDetails: { securityDetailsUserId = member.userId }
                    )
                }
            }

            // Invites this circle has sent and nobody has acted on. Renders
            // nothing for a plain member: the list endpoint is owner/admin only,
            // so their fetch 403s and leaves the array empty.
            PendingInvitesSection(circle: circle)

            // Privacy settings
            Section("Privacy Settings") {
                if let settings = circleManager.privacySettings[circle.id] {
                    PrivacySettingsRow(settings: settings)
                }
            }

            // Circle actions
            Section {
                if circle.isOwner {
                    Button(action: { showingSettings = true }) {
                        Label("Circle Settings", systemImage: "gearshape")
                    }
                }

                // Succession for a circle whose owner can no longer act. Shown
                // to admins only — the server refuses anybody else — and hidden
                // again once a claim is live.
                ClaimOwnershipRow(circle: circle)

                Button(action: { showingDeleteConfirm = true }) {
                    Label(circle.isOwner ? "Delete Circle" : "Leave Circle", systemImage: "rectangle.portrait.and.arrow.right")
                }
                .foregroundStyle(.red)
            }
        }
        .navigationTitle(circle.name)
        .task {
            // Cheap and silent: a failure leaves the section hidden rather than
            // raising an error over a circle that is perfectly fine, and the
            // next appearance retries.
            await OwnershipClaimManager.shared.refresh(circleId: circle.id)
            await circleManager.refreshPendingInvites(for: circle.id)
            await loadConsent()
            // A circle made moments ago: its privacy row (the pause controls)
            // is not in the circle list yet.
            if circleManager.privacySettings[circle.id] == nil {
                try? await circleManager.loadPrivacySettings(for: circle.id)
            }
        }
        .navigationDestination(item: $securityDetailsUserId) { userId in
            MemberDetailView(circleId: circle.id, userId: userId)
        }
        // This account is in the circle no more, by the server's word:
        // its screen closes, rather than stand empty.
        .onReceive(circleManager.circleGone) { gone in
            if CanonicalId.sameKey(gone, circle.id) { dismiss() }
        }
        .toolbar {
            // The owner and admins invite: the server refuses anyone
            // else, so a plain member is offered nothing that can only
            // fail; and on a circle with records only where the
            // invitation counts (`invitesTakeEffect`).
            if circleManager.invitesTakeEffect(circle) {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: { showingInvite = true }) {
                        Image(systemName: "person.badge.plus")
                    }
                    // Named for VoiceOver as the sheet it opens.
                    .accessibilityLabel("Invite Member")
                }
            }
        }
        .sheet(isPresented: $showingInvite, onDismiss: {
            // The invite the sheet just sent belongs in the section below, and
            // nothing else would fetch it until the screen is revisited.
            Task { await circleManager.refreshPendingInvites(for: circle.id) }
        }) {
            InviteMemberSheet(circleId: circle.id)
        }
        .sheet(isPresented: $showingSettings) {
            CircleSettingsSheet(circle: circle)
        }
        .alert(circle.isOwner ? "Delete Circle?" : "Leave Circle?", isPresented: $showingDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button(circle.isOwner ? "Delete" : "Leave", role: .destructive) {
                Task { await performLeaveOrDelete() }
            }
        } message: {
            Text(circle.isOwner ?
                 "This will permanently delete the circle and remove all members." :
                 "You will no longer be able to see or share location with this circle.")
        }
        .alert("Couldn't leave circle", isPresented: .constant(leaveError != nil)) {
            Button("OK") { leaveError = nil }
        } message: {
            Text(leaveError ?? "")
        }
    }

    // MARK: - Location consent

    /// Whether this member's yes is on record: a grant made at the notice. A
    /// `granted` + `implied` row is not one — it records that the membership is
    /// older than the notice — and neither is `none` or `withdrawn`.
    static func isSharing(_ consent: LocationConsentResponse) -> Bool {
        consent.status == "granted" && consent.mode == "presented"
    }

    /// What both forms of the "Location sharing" section say about stopping
    /// (the section has no button for it): stopping for good (withdrawing the
    /// consent, GDPR Art 7(3)) is leaving the circle. Its owner, who can't
    /// leave, deletes it, or transfers ownership and then leaves: a transfer
    /// alone keeps the former owner in as a member, still sharing. One string
    /// for every member, the same on every platform.
    static let membershipNote = "Sharing your location is part of being in this circle. "
        + "You can pause it any time; to stop sharing for good, you leave the circle. "
        + "As its owner, you delete it, or transfer ownership and then leave."

    /// Sharing, said where it applies, with no control of its own. Stopping is
    /// leaving ("If you don't consent, you can't be in the circle"), with the
    /// circle's own Leave, and the pause is in Privacy Settings. A stop-sharing
    /// button here could only ask which of the two.
    @ViewBuilder
    private var locationConsentSection: some View {
        Section {
            // Off or paused here: "You are sharing" would be untrue, and the
            // person is told what the others see instead.
            if let line = SharingStatusCopy.ownSentence(ownSharing, historyOn: ownHistoryOn) {
                ownSharingRow(line)
            } else {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "location.fill")
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("You are sharing your location with this circle")
                            .font(.callout)
                        Text("The settings below apply on top of this.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        } header: {
            Text("Location sharing")
        } footer: {
            Text(Self.membershipNote)
        }
    }

    /// This account's sharing in this circle, from its own privacy row: the
    /// rule the server applies to the roster the others read. Sharing while
    /// the row is not loaded.
    private var ownSharing: MemberSharingStatus {
        circleManager.privacySettings[circle.id].map { MemberSharingStatus(settings: $0).at(Date()) } ?? .on
    }

    /// Whether this account keeps location history for this circle, from its
    /// own privacy row. Kept while the row is not loaded.
    private var ownHistoryOn: Bool {
        circleManager.privacySettings[circle.id]?.shareHistory ?? true
    }

    private func ownSharingRow(_ line: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: ownSharing == .off ? "location.slash.fill"
                  : ownSharing == .on ? "clock.badge.xmark" : "pause.circle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(line)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("own-sharing-status")
        }
    }

    @MainActor
    private func loadConsent() async {
        // Silent on failure, leaving the section hidden. A section that said
        // "you are not sharing" because a request timed out would be telling
        // somebody their location is private when it is not.
        consent = try? await APIService.shared.locationConsent(circleId: circle.id)
    }

    @MainActor
    private func performLeaveOrDelete() async {
        do {
            if circle.isOwner {
                try await circleManager.deleteCircle(circle)
            } else {
                try await circleManager.leaveCircle(circle.id)
            }
            // Pop back to the Circles list now that the underlying
            // circle is gone from CircleManager.circles. Without
            // this the user stays on a detail screen for a circle
            // that no longer exists — header still shows the name,
            // Members section reads "Members (0)".
            dismiss()
        } catch {
            leaveError = (circle.isOwner ? "Delete failed: " : "Leave failed: ")
                + error.plainText
        }
    }

}

struct MemberRow: View {
    let member: CircleMember
    let circle: Circle
    /// Pushes MemberDetailView. Owned by CircleDetailView — see
    /// `securityDetailsUserId` there for why it can't live in this row.
    let onSecurityDetails: () -> Void

    @StateObject private var circleManager = CircleManager.shared
    /// For this account's own row: its position is this phone's fix.
    @StateObject private var locationService = LocationService.shared
    @State private var showingOptions = false
    /// Non-nil raises the failure alert. Removal re-keys the circle, so it can
    /// fail for reasons the person can act on.
    @State private var removeError: String?
    // Set alongside removeError so the alert can offer the weaker removal. Held
    // separately from the error text because the alert's buttons need the ids,
    // and because a nil here is what keeps the fallback off the first alert a
    // user ever sees.
    @State private var removeFallbackTarget: (circleId: String, userId: String)?
    // The server's sentence after a removal that skipped the rotation.
    @State private var removedWithoutRotationWarning: String?
    /// Promoting someone invited to an email asks first, with their number:
    /// it makes every member's app rely on them. The keys the number was
    /// worked out from are the ones signed, or nothing is.
    @State private var promotion: PendingPromotion?

    struct PendingPromotion {
        let keys: MemberKeyPair?
        let number: String?
    }
    @State private var roleError: String?
    /// The change `roleError` is about: the alert's title names it.
    @State private var roleErrorChange: RoleChange = .makeAdmin
    /// A hand-over waiting for the person's yes: the keys held for
    /// them at the tap, and their number for someone invited to an email, as
    /// for a promotion.
    @State private var handOverAsk: PendingPromotion?
    /// What a hand-over came to, said once.
    @State private var handOverResult: HandOverResult?

    struct HandOverResult: Equatable {
        let title: String
        let message: String
    }

    var location: LocationData? {
        // This account's is this phone's own fix, never a row: the
        // map's own marker says the same.
        if CanonicalId.same(member.userId, AuthManager.shared.userId) {
            return locationService.currentLocation.map {
                LocationData.ownPosition(
                    $0,
                    userId: member.userId,
                    circleId: circle.id,
                    deviceId: AuthManager.shared.deviceId ?? ""
                )
            }
        }
        // Not sharing here: their last position is not where they are, and
        // `sharingLine` says why instead.
        guard member.sharing() == .on else { return nil }
        // This circle's row alone: the held rows are keyed by member, and
        // another circle's would give its age here. The map's row first,
        // when it is this circle's: it is redrawn as they share now
        // (`heldFix`). Else this circle's own (`acceptedRow`): without it a
        // member of two circles would have no "Last seen" and a grey dot in
        // every circle but the last to refresh.
        return MapView.heldRow(circleManager.memberLocations[member.userId], in: circle.id)
            ?? circleManager.acceptedRow(of: member.userId, in: circle.id)
    }

    /// "Location sharing off", "Paused until 5:00 PM" or "Paused" in place of
    /// "Last seen", for anyone but this account (its own is the circle's
    /// "Location sharing" section).
    private var sharingLine: String? {
        CanonicalId.same(member.userId, AuthManager.shared.userId) ? nil : SharingStatusCopy.rowLine(member.sharing())
    }

    var isCurrentUser: Bool {
        member.userId == AuthManager.shared.userId
    }

    /// The words shared with the Android app
    /// (`member_name_asked_to_update`). Static so a test can pin them.
    static func askedToUpdate(_ name: String) -> String {
        "\(name) · Asked to update Pingolin"
    }

    /// The server told them their app is too old to be let back in.
    private var askedToUpdate: Bool { member.updateRequested && !isCurrentUser }

    /// Shown to everyone else; this device's own state is the circle's notice.
    /// Against the circle's version NOW — a refresh may have moved it.
    private var isJoining: Bool {
        let version = circleManager.circles.first(where: { $0.id == circle.id })?.keyVersion ?? circle.keyVersion
        return !isCurrentUser && member.isJoining(circleKeyVersion: version)
    }

    /// Role changes and the hand-over are the owner's, over anyone but the
    /// owner, as the server allows.
    private var canManage: Bool {
        !isCurrentUser && circle.isOwner && member.role != .owner
    }

    /// Removal is an owner's or an admin's, of anyone but the owner and
    /// themselves: eject-and-rotate and revoke-access both go by
    /// `can_rotate_keys` on the server, which the owner and admins hold.
    private var canRemove: Bool {
        !isCurrentUser && member.role != .owner && circleManager.isOwnerOrAdmin(circle)
    }

    /// A role change is offered only where it takes effect: on a circle whose
    /// records' owner is someone else (after a claim), a change made here
    /// writes no record, and every other app would go on as before, whatever
    /// this screen said.
    private var canChangeRole: Bool {
        canManage && circleManager.roleChangesTakeEffect(circle.id)
    }

    /// The role change the member menu offers. "Make Admin" is for a member
    /// only: offered to an admin, it would run the promotion again (and its
    /// question, for someone invited by email) and change nothing. An admin
    /// can be made a member again, as on the web and Android. An owner's role
    /// moves only with the circle.
    enum RoleChange: Equatable {
        case makeAdmin
        case removeAdmin
    }

    static func roleChange(for role: CircleMember.MemberRole) -> RoleChange? {
        switch role {
        case .member: return .makeAdmin
        case .admin: return .removeAdmin
        case .owner: return nil
        }
    }

    /// The failure alert's title, for the change that didn't go through.
    static func roleFailureTitle(_ change: RoleChange, name: String) -> String {
        switch change {
        case .makeAdmin: return "Couldn't make \(name) an admin"
        case .removeAdmin: return "Couldn't remove \(name) as an admin"
        }
    }

    /// Verifying a peer's keys is not an admin power, so security details are
    /// open to every member — but not for yourself: a safety number is a
    /// pairwise value and there is no pair when both halves are you.
    private var canSeeSecurity: Bool {
        !isCurrentUser
    }

    /// The question before a hand-over. For someone invited to an email it
    /// starts with their number, as a promotion's does: ownership is more
    /// than admin. Static so a test can pin the words.
    static func handOverQuestion(name: String, circle: String, number: String?,
                                 device: String = DeviceNoun.current) -> String {
        let check = number.map {
            "\(name) was invited by email, so this \(device) can't tell on its own that the account is really theirs. "
                + "If you're not sure it's them, check with \(name) another way first. Their number: \($0). "
        } ?? ""
        return check + "\(name) will have full control of \(circle): they can delete it or hand it on. "
            + "You'll stay in it as a member. This can't be undone."
    }

    static func handOverResult(_ outcome: CircleManager.HandOverOutcome, name: String, circle: String) -> HandOverResult {
        switch outcome {
        case .done:
            return HandOverResult(title: "\(name) is the owner now",
                                  message: "You're a member of \(circle), and can leave it whenever you like.")
        case .pending:
            return HandOverResult(title: "Handing \(circle) over", message: "The handover will finish on its own.")
        }
    }

    /// The question before promoting someone invited to an email. Static
    /// so a test can pin the words.
    static func promotionQuestion(name: String, number: String?, device: String = DeviceNoun.current) -> String {
        let check = number.map { " Their number: \($0)." } ?? ""
        return "\(name) was invited by email, so this \(device) can't tell on its own that the account is really theirs. As an admin, everyone's app will rely on them. If you're not sure it's them, check with \(name) another way first.\(check)"
    }

    private func promote(keys: MemberKeyPair?) {
        Task {
            do {
                try await circleManager.updateMemberRole(in: circle.id, userId: member.userId, role: .admin, keys: keys)
            } catch {
                roleErrorChange = .makeAdmin
                roleError = error.plainText
            }
        }
    }

    private func handOver(keys: MemberKeyPair?) {
        Task {
            do {
                let outcome = try await circleManager.handOver(circle.id, to: member.userId, keys: keys)
                handOverResult = Self.handOverResult(outcome, name: member.displayName, circle: circle.name)
            } catch {
                handOverResult = HandOverResult(title: "Couldn't transfer ownership to \(member.displayName)",
                                                message: error.plainText)
            }
        }
    }

    /// Back to a member, with no question first: it takes away what the
    /// others' apps rely on them for rather than adding to it. The chain's
    /// owner records the change, as for a promotion (`updateMemberRole`).
    private func demote() {
        Task {
            do {
                try await circleManager.updateMemberRole(in: circle.id, userId: member.userId, role: .member)
            } catch {
                roleErrorChange = .removeAdmin
                roleError = error.plainText
            }
        }
    }

    /// Two characters, same rule as the marker bitmap.
    private var initials: String {
        let parts = member.displayName.split(separator: " ").compactMap { $0.first }
        return String(parts.prefix(2)).uppercased()
    }

    /// Palette colour by position in this circle's roster — the index the map
    /// uses — or the stale grey once the member's last fix ages out. No fix at
    /// all counts as stale: there is no dot on the map to match.
    ///
    /// Resolved by `MemberPalette.bubble`, which is also what the map marker and
    /// the member card call, so all three agree.
    private var bubbleColor: UIColor {
        MemberPalette.bubble(
            forUserId: member.userId,
            in: circleManager.members[circle.id] ?? [],
            ageMs: location.map { Int64(Date().timeIntervalSince($0.timestamp) * 1_000) }
        )
    }

    var body: some View {
        Button(action: showOnMap) { rowContent }
            .buttonStyle(.plain)
            // The row and its menu button are otherwise only findable by the
            // member's display name, which is decrypted per-account — the UI
            // test has no way to know it in advance.
            .accessibilityIdentifier("member-row")
            .confirmationDialog("Member Options", isPresented: $showingOptions) {
                if canSeeSecurity {
                    Button("Security details") { onSecurityDetails() }
                }
                if canManage {
                    if canChangeRole {
                        switch Self.roleChange(for: member.role) {
                        case .makeAdmin?:
                            Button("Make Admin") {
                                // The keys this device holds for them, fixed now: the
                                // number is theirs, and they are what gets signed.
                                let keys = circleManager.promotionKeys(for: member.userId, in: circle.id)
                                if circleManager.isReceiveOnly(member.userId, in: circle.id) {
                                    promotion = PendingPromotion(
                                        keys: keys, number: keys.flatMap { circleManager.securityCode(for: member.userId, keys: $0) })
                                } else {
                                    promote(keys: keys)
                                }
                            }
                        case .removeAdmin?:
                            Button("Remove as Admin") { demote() }
                        case nil:
                            EmptyView()
                        }
                    }

                    Button("Transfer Ownership") {
                        // The keys this device holds for them, fixed now, as
                        // for a promotion: the record names only those.
                        let keys = circleManager.promotionKeys(for: member.userId, in: circle.id)
                        handOverAsk = PendingPromotion(
                            keys: keys,
                            number: circleManager.isReceiveOnly(member.userId, in: circle.id)
                                ? keys.flatMap { circleManager.securityCode(for: member.userId, keys: $0) } : nil)
                    }
                }
                if canRemove {
                    Button("Remove from Circle", role: .destructive) {
                        Task {
                            removeError = nil
                            // A phone that is behind in the
                            // circle removes them at once,
                            // without a new key: never
                            // queued. The circle's refresh
                            // follows from a member who
                            // holds the current version.
                            if circleManager.removesWithoutNewKey(circle.id) {
                                do {
                                    let serverLine = try await circleManager
                                        .revokeMemberAccess(from: circle.id, userId: member.userId)
                                    removedWithoutRotationWarning = PendingChangeCopy.removed(
                                        name: member.displayName, circle: circle.name, serverLine: serverLine)
                                } catch {
                                    removeError = error.plainText
                                }
                                return
                            }
                            do {
                                try await circleManager.removeMember(
                                    from: circle.id,
                                    userId: member.userId
                                )
                            } catch {
                                // NEVER swallow this. A failure means the
                                // member is still in the circle and still
                                // receiving locations, and the person who
                                // tapped Remove has every reason to believe
                                // otherwise.
                                removeError = error.plainText
                                // Offer the no-rotation removal, but only now:
                                // a rotation that CAN happen should always
                                // happen, so this is never a button beside the
                                // normal one.
                                removeFallbackTarget = (circle.id, member.userId)
                            }
                        }
                    }
                }
            }
            .alert(
                "Make \(member.displayName) an admin?",
                isPresented: Binding(
                    get: { promotion != nil },
                    set: { if !$0 { promotion = nil } }
                )
            ) {
                Button("Cancel", role: .cancel) { promotion = nil }
                Button("Make Admin") {
                    let keys = promotion?.keys
                    promotion = nil
                    promote(keys: keys)
                }
            } message: {
                Text(Self.promotionQuestion(name: member.displayName, number: promotion?.number))
            }
            .alert(
                "Transfer ownership to \(member.displayName)?",
                isPresented: Binding(
                    get: { handOverAsk != nil },
                    set: { if !$0 { handOverAsk = nil } }
                )
            ) {
                Button("Cancel", role: .cancel) { handOverAsk = nil }
                Button("Transfer") {
                    let keys = handOverAsk?.keys
                    handOverAsk = nil
                    handOver(keys: keys)
                }
            } message: {
                Text(Self.handOverQuestion(name: member.displayName, circle: circle.name, number: handOverAsk?.number))
            }
            .alert(
                handOverResult?.title ?? "",
                isPresented: Binding(
                    get: { handOverResult != nil },
                    set: { if !$0 { handOverResult = nil } }
                )
            ) {
                Button("OK", role: .cancel) { handOverResult = nil }
            } message: {
                Text(handOverResult?.message ?? "")
            }
            .alert(
                Self.roleFailureTitle(roleErrorChange, name: member.displayName),
                isPresented: Binding(
                    get: { roleError != nil },
                    set: { if !$0 { roleError = nil } }
                )
            ) {
                Button("OK", role: .cancel) { roleError = nil }
            } message: {
                Text(roleError ?? "")
            }
            .alert(
                "Couldn't remove member",
                isPresented: Binding(
                    get: { removeError != nil },
                    set: { if !$0 { removeError = nil } }
                )
            ) {
                if let target = removeFallbackTarget {
                    Button("Remove now anyway", role: .destructive) {
                        removeError = nil
                        removeFallbackTarget = nil
                        Task {
                            do {
                                removedWithoutRotationWarning = try await circleManager
                                    .revokeMemberAccess(from: target.circleId, userId: target.userId)
                                    ?? "They're out of the circle. It finishes securing itself as soon as a member's app is online."
                            } catch {
                                removeError = error.plainText
                            }
                        }
                    }
                }
                Button("OK", role: .cancel) { removeError = nil; removeFallbackTarget = nil }
            } message: {
                // ONE Text, deliberately. SwiftUI renders only the first view
                // in an alert's message builder, so splitting the reason and
                // the consequence across two would silently drop the half that
                // matters most.
                Text("\(removeError ?? "")\n\nThey are still in the circle and can still see its locations.\n\nYou can remove them now anyway: they leave the circle straight away, and it finishes securing itself as soon as a member's app is online. Anything they have already seen stays with them.")
            }
            .alert(
                "Removed — finishing up",
                isPresented: Binding(
                    get: { removedWithoutRotationWarning != nil },
                    set: { if !$0 { removedWithoutRotationWarning = nil } }
                )
            ) {
                Button("Got it", role: .cancel) { removedWithoutRotationWarning = nil }
            } message: {
                // Same one-Text rule, and the words are the server's so all
                // four clients say the same true thing.
                Text(removedWithoutRotationWarning ?? "")
            }
    }

    /// Switch to the map and point it at this member. The camera work and the
    /// callout belong to MapView — it owns the map's state and is the only
    /// place this member's position exists in the clear — so all that happens
    /// here is selecting their circle and raising the route.
    private func showOnMap() {
        if circleManager.activeCircle?.id != circle.id {
            circleManager.setActiveCircle(circle)
        }
        TabSelectionState.shared.selected = 0
        NotificationRouteState.shared.pending = .focusMember(userId: member.userId)
    }

    private var rowContent: some View {
        HStack(spacing: 12) {
            // The same bubble the map draws for this member: palette colour
            // by roster index, bold two-character initials, greyed once the
            // last fix is stale, so the row looks like the same person as
            // the dot the user was just looking at.
            //
            // White initials measure 2.68:1 on the stale grey, which fails
            // the accessibility contrast check in dark mode. `ink(on:)`
            // picks by contrast; see the table on it.
            ZStack {
                SwiftUI.Circle()
                    .fill(Color(uiColor: bubbleColor))
                    .frame(width: 44, height: 44)

                Text(initials)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Color(uiColor: MemberPalette.ink(on: bubbleColor)))
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    // "{name} · Joining…": confirmed, and the
                    // circle opens for them as soon as a
                    // member's app delivers it.
                    // "{name} · Asked to update Pingolin":
                    // what is happening, never an ask to pass
                    // it on.
                    Text(isJoining ? "\(member.displayName) · Joining…"
                         : askedToUpdate ? Self.askedToUpdate(member.displayName) : member.displayName)
                        .fontWeight(.medium)
                        .accessibilityIdentifier(isJoining ? "member-joining"
                                                 : askedToUpdate ? "member-update-requested" : "member-name")

                    if isCurrentUser {
                        Text("You")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.secondary.opacity(0.2))
                            .cornerRadius(4)
                    }

                    if member.role == .owner {
                        Image(systemName: "crown.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    } else if member.role == .admin {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                    }
                }

                // Spoken with the row, as "Last seen" is: the row is one
                // button, and its label is every text inside it.
                if let sharingLine {
                    Text(sharingLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("member-sharing-status")
                } else if let location = location {
                    Text("Last seen: \(location.timestamp.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    // This member shares only an area here (`ApproximateArea`);
                    // spoken with the row like "Last seen".
                    if location.approximate != nil {
                        Text(ApproximateLocationCopy.line)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("member-approximate")
                    }
                }

            }

            Spacer()

            // The menu only earns its place if it would open onto something.
            if canSeeSecurity || canManage || canRemove {
                Button(action: { showingOptions = true }) {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(.secondary)
                        // Without an explicit hit area the glyph's own bounds
                        // are a few points wide and most taps land on the row
                        // behind it — which now navigates to the map.
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Member options")
                .accessibilityIdentifier("member-options")
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

struct PrivacySettingsRow: View {
    let settings: PrivacySettings
    @StateObject private var circleManager = CircleManager.shared
    @State private var showingSettings = false

    private var sharing: MemberSharingStatus {
        MemberSharingStatus(settings: settings).at(Date())
    }

    var body: some View {
        Button(action: { showingSettings = true }) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    // Off or paused: the words the others see next to this
                    // person's name. A green "Sharing Location" over real-time
                    // sharing switched off would tell them the opposite of the
                    // truth.
                    if let line = SharingStatusCopy.rowLine(sharing) {
                        Label(line, systemImage: sharing == .off ? "location.slash.fill" : "pause.circle.fill")
                            .foregroundStyle(.orange)
                    } else if settings.bubbleEnabled {
                        Label("Bubble Mode Active", systemImage: "circle.dashed")
                            .foregroundStyle(.blue)
                    } else {
                        Label("Sharing Location", systemImage: "location.fill")
                            .foregroundStyle(.green)
                    }

                    HStack(spacing: 8) {
                        if settings.shareRealtime {
                            Image(systemName: "location.fill")
                        }
                        if settings.shareHistory {
                            Image(systemName: "clock.fill")
                        }
                        // What goes to the circle, not the switch alone:
                        // with "Allow alerts on me" off no level is sent.
                        if settings.sendsBattery {
                            Image(systemName: "battery.100")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $showingSettings) {
            PrivacySettingsSheet(settings: settings)
        }
    }
}

struct CreateCircleSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var circleManager = CircleManager.shared
    @State private var name = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var premiumPrompt: PremiumPrompt?
    /// The location notice, asked BEFORE anything is created: creating a circle
    /// is agreeing to share with it, and there is no circle without the yes.
    /// "Not now" creates nothing, and this sheet stays as it was.
    @State private var askingConsent = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Circle Name", text: $name)
                } footer: {
                    Text("Choose a name for your circle, like \"Family\" or \"Friends\"")
                }
            }
            .navigationTitle("Create Circle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { askingConsent = true }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isLoading)
                }
            }
            .sheet(isPresented: $askingConsent) {
                LocationConsentView(circleName: name, purpose: .create) { agreed, shown in
                    if agreed { createCircle(consent: shown) }
                }
            }
            .alert("Error", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            // Hitting the free circle limit returns a quota 402 → show the
            // upgrade explainer instead of a bare "limit reached" error.
            .sheet(item: $premiumPrompt) { PremiumPromptSheet(prompt: $0) }
        }
    }

    private func createCircle(consent: ShownNotice?) {
        isLoading = true
        Task {
            do {
                // The yes goes WITH the create: one request, one transaction.
                _ = try await circleManager.createCircle(name: name, consent: consent)
                dismiss()
            } catch {
                if let apiError = error as? APIError, let prompt = PremiumPrompt.forGate(apiError) {
                    premiumPrompt = prompt
                } else {
                    errorMessage = error.plainText
                }
            }
            isLoading = false
        }
    }
}

// There is no join-by-code screen: every invitation is an email
// invitation, accepted from the Invitations list on this screen
// (/invites/received -> /invites/{id}/accept), never by typing a code.
// The Android app and the web client work the same way.

struct InviteMemberSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var circleManager = CircleManager.shared
    let circleId: String
    @State private var email = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var premiumPrompt: PremiumPrompt?
    /// The invited account's identity changed: "Is this really {email}?".
    @State private var inviteeChange: InviteeChange?

    /// An invitation carries this phone's version of the circle, which must be
    /// the circle's: a phone that is behind says so instead.
    private var waitingToSync: Bool { !circleManager.holdsCurrentKey(for: circleId) }

    var body: some View {
        NavigationStack {
            Form {
                if waitingToSync {
                    Section {
                        Label {
                            Text(CircleLockReason.waitingToSyncBody)
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .foregroundStyle(.orange)
                        }
                        .accessibilityIdentifier("invite-waiting-to-sync")
                    } header: {
                        Text(CircleLockReason.waitingToSyncTitle)
                    }
                }
                Section {
                    TextField("Email Address", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .autocapitalization(.none)
                }

                // NO ROLE PICKER: an invitation carries no role, and the
                // server always admits the invitee as a member. As on
                // the Android app, promotion happens after the invitee
                // accepts, via the member's own row — the only path that
                // grants can_rotate_keys to anyone but the owner.

                // The circle key chain carries forward, so somebody
                // added today can decrypt what the circle recorded before they
                // arrived. The Terms already say this and add that "nothing
                // announces it in advance" — this is the announcing, shown to
                // the person doing the adding, at the moment they do it.
                //
                // Both periods are named because the client does not know which
                // tier this circle is on, and a confident wrong number would be
                // worse than an honest pair.
                //
                // Its own Section rather than a footer on the one above:
                // Section(footer:) renders only its first view, which makes it
                // a bad place to put something that must not silently vanish.
                Section {
                    Label {
                        Text("They will be able to see this circle's existing location history, not only what happens from now on — two days of it on a free circle, up to a year on a premium one.")
                            .font(.footnote)
                    } icon: {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("Invite Member")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Invite") {
                        inviteMember()
                    }
                    // Enabled while behind too: the invitation
                    // then waits and shows among the circle's
                    // changes.
                    .disabled(email.isEmpty || isLoading)
                }
            }
            .alert("Error", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .alert(
                inviteeChange.map { InviteeChange.title(email: $0.email) } ?? "",
                isPresented: Binding(
                    get: { inviteeChange != nil },
                    set: { if !$0 { inviteeChange = nil } }
                ),
                presenting: inviteeChange
            ) { change in
                Button("Not now", role: .cancel) { inviteeChange = nil }
                Button("It's them") {
                    inviteeChange = nil
                    confirmInvitee(change)
                }
            } message: { change in
                Text(InviteeChange.body(email: change.email, number: change.number))
            }
            // A full circle (free member cap) returns a quota 402 → surface
            // the upgrade explainer rather than a generic error.
            .sheet(item: $premiumPrompt) { PremiumPromptSheet(prompt: $0) }
        }
    }

    private func inviteMember() {
        isLoading = true
        Task {
            do {
                try await circleManager.inviteMember(to: circleId, email: email)
                dismiss()
            } catch CircleManager.CircleError.inviteeChanged(let change) {
                inviteeChange = change
            } catch {
                if let apiError = error as? APIError, let prompt = PremiumPrompt.forGate(apiError) {
                    premiumPrompt = prompt
                } else {
                    errorMessage = error.plainText
                }
            }
            isLoading = false
        }
    }

    /// "It's them": this phone takes their new details, then invites them.
    private func confirmInvitee(_ change: InviteeChange) {
        isLoading = true
        Task {
            do {
                try await circleManager.confirmInviteeAndInvite(change)
                dismiss()
            } catch {
                errorMessage = error.plainText
            }
            isLoading = false
        }
    }
}

struct CircleSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var circleManager = CircleManager.shared
    let circle: Circle
    @State private var name: String
    @State private var isLoading = false
    /// Why the last Save didn't rename the circle.
    @State private var saveError: String?

    init(circle: Circle) {
        self.circle = circle
        _name = State(initialValue: circle.name)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Circle Name", text: $name)
                }

                if let saveError {
                    Section {
                        Label(saveError, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }

                // No key version next to "Created": this is the sheet
                // people open to rename a circle, and a bare integer
                // nobody can act on is not what they came for. Security
                // Details is where key material belongs.
                Section {
                    LabeledContent("Created", value: circle.createdAt.formatted(date: .abbreviated, time: .omitted))
                }
            }
            .navigationTitle("Circle Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveChanges()
                    }
                    .disabled(name.isEmpty || isLoading)
                }
            }
        }
    }

    /// What the sheet says when a rename fails. The name changes only once the
    /// server has it, so the circle still has its old one.
    static func renameFailedLine(_ error: Error) -> String {
        "The name wasn't changed. \(error.plainText)"
    }

    /// The sheet closes once the rename went through, or once it waits to go
    /// out by itself (`updateCircle` queues it while this iPhone is behind, and
    /// returns). A failure keeps it open and says why (`renameFailedLine`):
    /// closing would look as if the rename had worked while the old name stayed.
    private func saveChanges() {
        isLoading = true
        saveError = nil
        Task {
            do {
                try await circleManager.updateCircle(circle, name: name)
                dismiss()
            } catch {
                saveError = Self.renameFailedLine(error)
                isLoading = false
            }
        }
    }
}

struct PrivacySettingsSheet: View {
    /// The battery switch's words. Static so a test can pin them.
    static let batteryTitle = "Allow low-battery alerts about me"
    /// The real-time and history switches' words (the same on every
    /// platform).
    static let realtimeTitle = "Share real-time location"
    static let realtimeDetail = "When it's off, Track stops sending this circle your location. "
        + "Members may still see the last location you shared, unless location history is off too."
    static let historyTitle = "Share location history"
    static let historyDetail = "When it's off, members see only where you are now. Track still keeps your history, "
        + "and turning it back on shows them all of it, including the time it was off."
    static let batteryDetail = "Sends your battery level to this circle so members can be alerted when it's low."
    /// In its place while "Allow alerts on me" is off: then
    /// nothing is sent, and "Sends your battery level…" would be false.
    static let batteryNeedsAlerts = "Turn on “Allow alerts on me” to use this."

    /// The battery switch's line, by "Allow alerts on me".
    static func batteryLine(allowAlertsOnMe: Bool) -> String {
        allowAlertsOnMe ? batteryDetail : batteryNeedsAlerts
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var circleManager = CircleManager.shared
    @State var settings: PrivacySettings
    /// What the sheet showed before the person changed anything: what was
    /// changed is what differs from it, and only that is sent, on the row the
    /// server holds by then (`CircleManager.changes`). Takes the server's
    /// posture with `settings` after a Pause or Resume.
    @State private var shown: PrivacySettings
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var pauseDuration: TimeInterval = 3600
    /// A Pause or Resume on its way: neither shows as done until the server
    /// has it.
    @State private var pauseSending = false
    /// A Pause or Resume failed, and so did the check after it: the server
    /// may hold a pause or a resume this sheet can't see. Until it is read
    /// again, the sheet says so in place of the pause it last knew, and Save
    /// waits, as on the web.
    @State private var postureUnknown = false
    /// The account this sheet was opened for: its re-reads stop at a sign-out.
    @State private var account: String?

    let pauseOptions: [(String, TimeInterval)] = [
        ("1 hour", 3600),
        ("4 hours", 14400),
        ("8 hours", 28800),
        ("24 hours", 86400)
    ]

    init(settings: PrivacySettings) {
        _settings = State(initialValue: settings)
        _shown = State(initialValue: settings)
        _account = State(initialValue: AuthManager.shared.userId)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Location Sharing") {
                    Toggle(isOn: $settings.shareRealtime) {
                        Text(Self.realtimeTitle)
                        Text(Self.realtimeDetail)
                    }
                    Toggle(isOn: $settings.shareHistory) {
                        Text(Self.historyTitle)
                        Text(Self.historyDetail)
                    }
                    // What the switch does: the level goes in
                    // this account's points for the circle,
                    // and the only thing that reads it is the
                    // low-battery alert. Nobody's screen shows
                    // a member's battery. So it goes only
                    // while "Allow alerts on me" is on too
                    // (`PrivacySettings.sendsBattery`), and
                    // until then the switch can't be used and
                    // its line says why.
                    Toggle(isOn: $settings.shareBattery) {
                        Text(Self.batteryTitle)
                        Text(Self.batteryLine(allowAlertsOnMe: settings.allowAlertsOnMe))
                    }
                    .disabled(!settings.allowAlertsOnMe)
                }

                // Consent to being alerted on lives here as a per-circle
                // opt-out, replacing the retired boundary-subscription
                // approve/deny inbox.
                Section {
                    Toggle("Allow alerts on me", isOn: $settings.allowAlertsOnMe)
                } header: {
                    Text("Alerts")
                } footer: {
                    // The server applies this consent to every
                    // watch-a-person alert kind (place, low
                    // battery, inactivity), so the copy names
                    // all three.
                    Text("When on, members of this circle can set alerts about you: arriving at or leaving a place, your battery running low, or going quiet for a while. Turn off to opt out in this circle.")
                }

                Section {
                    // While paused, the toggle and the radius show the
                    // mode Resume returns to, and stay as they are: the
                    // server holds the mode from before the pause and a
                    // paused save does not change it, so a change here
                    // would be lost without a word. Resume first.
                    //
                    // Bound through the person's own change
                    // (`chooseBubble`), not onChange: onChange would
                    // also see the re-check on opening the sheet and
                    // drop a paused row's real end.
                    Toggle("Enable Bubble Mode", isOn: Binding(
                        get: { settings.bubbleEnabled }, set: { settings.chooseBubble($0) }))
                        .disabled(settings.isPaused || postureUnknown)

                    if settings.bubbleEnabled {
                        VStack(alignment: .leading) {
                            Text("Bubble Radius: \(Int(settings.bubbleRadius.rounded())) miles")
                            // 1...25 whole miles — the server's
                            // accepted range: it rejects anything
                            // else with a 400
                            // ("approximate_radius_miles must be
                            // between 1 and 25").
                            Slider(value: Binding(get: { settings.bubbleRadius },
                                                  set: { settings.chooseBubbleRadius($0) }),
                                   in: 1...25, step: 1)
                        }
                        .disabled(settings.isPaused || postureUnknown)
                    }
                } header: {
                    Text("Bubble Mode")
                } footer: {
                    Text("Bubble mode shows you within a radius instead of your exact location")
                }

                // Pause and Resume are sent at once, as on the web and
                // Android: a pause that waited for Save would look done and
                // be dropped by Cancel or a swipe. Shown once the server has
                // it, never before.
                Section {
                    if pauseSending {
                        HStack {
                            ProgressView()
                            Text(settings.isPaused ? "Resuming…" : "Pausing…")
                        }
                    } else if postureUnknown {
                        HStack {
                            ProgressView()
                            Text(Self.postureUnknownLine)
                        }
                    } else if settings.isPaused {
                        HStack {
                            Image(systemName: "pause.circle.fill")
                                .foregroundStyle(.orange)
                            // An indefinite pause has no timestamp to print —
                            // it stays paused until Resume is tapped.
                            Text(settings.pausedUntil.map { "Paused until \($0.formatted())" }
                                 ?? "Paused until you resume")
                        }

                        Button("Resume Sharing") { resumeNow() }
                            .disabled(isLoading)
                    } else {
                        Picker("Pause for", selection: $pauseDuration) {
                            ForEach(pauseOptions, id: \.1) { option in
                                Text(option.0).tag(option.1)
                            }
                        }

                        Button("Pause Sharing") { pauseNow() }
                            .disabled(isLoading)
                    }
                } header: {
                    Text("Pause Sharing")
                } footer: {
                    Text("Pausing and resuming take effect at once.")
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            // While paused, Bubble Mode shows what the pause returns to as of
            // now: the bubble's own end may have passed since the last refresh.
            // What it showed is aligned with it, so this is no change of the
            // person's.
            .onAppear {
                let now = Date()
                settings.alignBubbleWithPause(at: now)
                shown.alignBubbleWithPause(at: now)
            }
            // A posture this sheet can't see is read again every 5 s until
            // the server answers. KEYED ON THE SCENE PHASE: `.task` alone
            // keeps running in the background in this app.
            .task(id: postureUnknown && scenePhase == .active) {
                guard postureUnknown, scenePhase == .active else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    // Signed out, or in as someone else: no longer theirs to read.
                    guard !Task.isCancelled, CanonicalId.same(AuthManager.shared.userId, account) else { break }
                    if (try? await circleManager.loadPrivacySettings(for: settings.circleId)) != nil {
                        adoptStoredPosture()
                        postureUnknown = false
                        return
                    }
                }
            }
            .navigationTitle("Privacy Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveSettings()
                    }
                    .disabled(isLoading || pauseSending || postureUnknown)
                }
            }
        }
    }

    /// Pause, sent at once: the server's row, returning to the Bubble Mode
    /// shown here (`CircleManager.pauseRequest`).
    private func pauseNow() {
        let until = Date().addingTimeInterval(pauseDuration)
        sendPause(pausing: true) { try await circleManager.pauseSharing(settings, shownFrom: shown, until: until) }
    }

    /// Resume, sent at once: the server returns to the mode held before the
    /// pause (`POST …/resume`).
    private func resumeNow() {
        sendPause(pausing: false) { try await circleManager.resumeSharing(for: settings.circleId) }
    }

    /// A Pause or Resume on its way, then the posture the server holds shown
    /// here (`adoptingPosture`), the switches not yet saved left as they are.
    /// A request that failed on its way back may have been taken all the same,
    /// so after a failure the server is asked again what it holds, and that is
    /// shown, with the reason unless the change was taken after all
    /// (`pauseFailureLine`).
    private func sendPause(pausing: Bool, _ request: @escaping () async throws -> Void) {
        pauseSending = true
        errorMessage = nil
        Task {
            defer { pauseSending = false }
            do {
                try await request()
                adoptStoredPosture()
            } catch {
                let heard = (try? await circleManager.loadPrivacySettings(for: settings.circleId)) != nil
                adoptStoredPosture()
                postureUnknown = !heard
                errorMessage = heard
                    ? Self.pauseFailureLine(error, pausing: pausing, nowPaused: settings.isPaused) : nil
            }
        }
    }

    /// Said in place of the pause when neither a Pause or Resume nor the check
    /// after it reached the server, with the web's words.
    static let postureUnknownLine = "Couldn't load your privacy settings to see whether that went through. Trying again…"

    /// What a failed Pause or Resume says once the server has been asked again:
    /// nothing when the change was taken after all, else why (for a Bubble Mode
    /// saved before a pause that failed, with what stands: `PauseNotSaved`).
    static func pauseFailureLine(_ error: Error, pausing: Bool, nowPaused: Bool) -> String? {
        guard nowPaused != pausing else { return nil }
        return (error as? APIError)?.plainLine ?? error.plainText
    }

    private func adoptStoredPosture() {
        guard let stored = circleManager.privacySettings[settings.circleId] else { return }
        let now = Date()
        settings = settings.adoptingPosture(of: stored)
        settings.alignBubbleWithPause(at: now)
        shown = shown.adoptingPosture(of: stored)
        shown.alignBubbleWithPause(at: now)
    }

    private func saveSettings() {
        isLoading = true
        errorMessage = nil
        Task {
            defer { isLoading = false }
            do {
                // Not `try?` + unconditional dismiss: these are privacy
                // controls, so a save that silently did nothing leaves the user
                // believing they are paused or blurred when the circle can still
                // see them exactly. Keep the sheet open on failure so Save can
                // be retried, and so the reason is visible.
                try await circleManager.saveChanges(settings, shownFrom: shown)
                dismiss()
            } catch let apiError as APIError {
                errorMessage = apiError.plainLine
            } catch {
                errorMessage = error.plainText
            }
        }
    }
}

#Preview {
    CirclesView()
}
