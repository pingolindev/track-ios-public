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

/// One waiting change, where the finished thing would appear: the "Waiting
/// to sync" tag, its line, and Cancel. Cancel takes it away at once, with
/// no confirmation; one that is going out now can't be cancelled.
struct PendingChangeRow: View {
    let change: PendingChange

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            row
            switch change.state {
            case .needsPerson(.keysChanged):
                PendingQuestion(change: change)
            case .needsPerson(.password):
                // Asked in place: once typed, the change carries on.
                PasswordUnlockForm()
            default:
                EmptyView()
            }
        }
    }

    private var row: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(PendingChangeCopy.tag)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                Text(Self.line(for: change))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if change.isSending {
                Text(PendingChangeCopy.sending)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if change.state != .cancelling {
                Button("Cancel") { PendingChangeRunner.shared.cancel(change.id) }
                    .buttonStyle(.borderless)
                    .font(.footnote)
                    .accessibilityIdentifier("pending-change-cancel")
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("pending-change-\(change.kind.rawValue)")
    }

    /// What the row says: its waiting line, or the state it is in.
    static func line(for change: PendingChange) -> String {
        switch change.state {
        case .cancelling: return PendingChangeCopy.cancelling
        case .needsPerson(.password): return PendingChangeCopy.waitingForPassword
        default: return PendingChangeCopy.waiting(change)
        }
    }
}

/// The one question a waiting change asks again, with the number for
/// exactly the keys it shows: the yes carries on with those keys; "Not now"
/// drops it silently, since the person decided. The same words as the live
/// questions ("Is this really {email}?", "Let {name} into {circle}?").
struct PendingQuestion: View {
    let change: PendingChange

    var body: some View {
        let words = Self.words(for: change)
        VStack(alignment: .leading, spacing: 6) {
            Text(words.title)
                .font(.callout.weight(.semibold))
            Text(words.body)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button(words.yes) { Task { await PendingChangeRunner.shared.answer(change.id, yes: true) } }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("pending-question-yes")
                Button("Not now") { Task { await PendingChangeRunner.shared.answer(change.id, yes: false) } }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("pending-question-no")
            }
        }
        .accessibilityIdentifier("pending-question")
    }

    /// Title, body and the yes, per kind; their number for the keys shown.
    static func words(for change: PendingChange) -> (title: String, body: String, yes: String) {
        let keys = change.seen.keys
        func number(_ subject: String?) -> String? {
            guard let me = AuthManager.shared.userId, let subject, let keys else { return nil }
            return try? SDKCrypto.cryptoManager.computeSafetyNumber(
                selfUserId: me, peerUserId: subject, peerSharingPubkeyHex: keys.sharingKeyHex,
                peerSigningPubkeyHex: keys.signingKeyHex)
        }
        switch change.inputs {
        case .invite(let inputs):
            return (InviteeChange.title(email: inputs.email),
                    InviteeChange.body(email: inputs.email, number: number(change.seen.subjectUserId)), "It's them")
        case .renewInvitation(let inputs):
            return (InviteeChange.title(email: inputs.email),
                    InviteeChange.body(email: inputs.email, number: number(inputs.inviteeUserId)), "It's them")
        case .letIn(let inputs):
            let request = KeyDeliveryRequest(
                circleId: change.circleId, circleName: PendingChangeCopy.circleName(change), userId: inputs.memberId,
                displayName: change.labels.subject ?? "They", email: nil,
                reason: inputs.lateJoiner.map { .lateJoiner($0) } ?? .unconfirmedInviter,
                sharingKeyHex: keys?.sharingKeyHex, signingKeyHex: keys?.signingKeyHex,
                number: number(inputs.memberId))
            return (KeyDeliveryApprovals.title(for: request), KeyDeliveryApprovals.question(for: request), "Let them in")
        default:
            return (PendingChangeCopy.waiting(change), "", "Continue")
        }
    }
}

/// A dropped change's one line, until it has been seen.
struct DroppedNoticeRow: View {
    let notice: DroppedNotice

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(notice.line)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("pending-change-notice")
    }
}

/// The circle's waiting changes, under its "Waiting to sync" notice, with the
/// count and Cancel on each; and the lines of the ones that
/// weren't done, cleared once they have been seen.
struct PendingChangesSection: View {
    let circleId: String
    @ObservedObject private var store = PendingChangeStore.shared

    var body: some View {
        let pending = store.pending(circleId: circleId)
        let notices = store.notices(circleId: circleId)
        if !pending.isEmpty || !notices.isEmpty {
            Section {
                ForEach(notices) { DroppedNoticeRow(notice: $0) }
                ForEach(pending) { PendingChangeRow(change: $0) }
            } header: {
                if !pending.isEmpty {
                    Text(PendingChangeCopy.count(pending.count))
                        .accessibilityIdentifier("pending-change-count")
                }
            }
            .onDisappear { store.noticesSeen(circleId: circleId) }
        }
    }
}

/// Waiting changes of some kinds, in place in another list (check-ins,
/// destinations, alerts…). `matching` narrows them further (e.g. one
/// destination's arrival).
struct PendingChangesInPlace: View {
    let kinds: Set<PendingChange.Kind>
    var circleId: String?
    var matching: (PendingChange) -> Bool = { _ in true }
    @ObservedObject private var store = PendingChangeStore.shared

    var body: some View {
        ForEach(store.changes.filter { change in
            change.isPending && kinds.contains(change.kind)
                && (circleId.map { change.circleId.caseInsensitiveCompare($0) == .orderedSame } ?? true)
                && matching(change)
        }) { change in
            PendingChangeRow(change: change)
        }
    }
}

/// On the circle's row in the list: a new name that waits, and the
/// number of changes waiting to go out for the circle.
struct PendingChangesCaption: View {
    let circleId: String
    @ObservedObject private var store = PendingChangeStore.shared

    var body: some View {
        let pending = store.pending(circleId: circleId)
        if !pending.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(pending.filter { $0.kind == .renameCircle }) { change in
                    Text(PendingChangeCopy.waiting(change))
                }
                Label(PendingChangeCopy.count(pending.count), systemImage: "arrow.triangle.2.circlepath")
            }
            .font(.caption)
            .foregroundStyle(.orange)
            .accessibilityIdentifier("circle-row-pending-changes")
        }
    }
}
