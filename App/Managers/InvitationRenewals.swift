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
import PingolinTrackSDK

/// "Is this really {email}?" about an invitation whose invitee reset their
/// password, and the renewal "It's them" makes.
///
/// The invitee's app reported that the invitation no longer names their account
/// as it is now (or the accept was refused as out of date — the same thing: a
/// key change). The server wakes this device. Nothing is re-signed silently:
/// - only an ACCOUNT invitation (kind 1) is ever renewed, never an address one;
/// - only the device that should ask asks: the inviter's while they are an
///   owner or admin, else the owner's — one question, never every admin;
/// - it asks only after reading the directory ITSELF (never on the report
///   alone), and only if the account's keys now differ from the original
///   statement's;
/// - at most once per statement id; "Not them" is final and withdraws it;
/// - "It's them" renews for exactly the keys the question showed. If the
///   directory has changed by then, it asks again instead of signing.
/// The renewal itself is the SDK's `renewInvitation`: it verifies the original
/// (the signer's pinned key, not expired, the facts from THIS device's record)
/// and copies its id, times, kind and user id; only the keys and version move.
@MainActor
final class InvitationRenewals: ObservableObject {
    static let shared = InvitationRenewals()

    /// One question, with everything "It's them" signs kept with it.
    struct Question: Codable, Equatable, Identifiable {
        let circleId: String
        let inviteId: String
        let email: String
        let subjectUserId: String
        let statementId: String
        let originalStatementHex: String
        let originalSignatureHex: String
        /// The keys read from the directory when the question was raised.
        let sharingKeyHex: String
        let signingKeyHex: String
        /// Their security code with the keys shown; nil when it can't be worked out.
        var number: String?

        var id: String { statementId.lowercased() }
    }

    /// Questions waiting for an answer, oldest first. Kept across launches.
    @Published private(set) var questions: [Question] = []
    /// Questions answered "It's them" while this device was behind in their
    /// circle: nothing was signed, and they are asked again once it has caught
    /// up (`next`). This process only; a relaunch asks at once.
    @Published private(set) var waitingForSync: Set<String> = []

    private let api = APIService.shared
    private var crypto: PingolinTrackSDK.CryptoManager { SDKCrypto.cryptoManager }

    private init() {
        load()
    }

    // MARK: - Who asks, and when

    /// Whether THIS device is the one to ask: the inviter's, while this
    /// account is an owner or admin in this device's own record. An invitation
    /// whose signer left or was demoted is never renewed (the SDK refuses it:
    /// the joiner gets "Let them in?" once they join), so no other device asks
    /// about it — one question, never every admin.
    nonisolated static func asksHere(me: String, signer: String, iAmOwnerOrAdmin: Bool) -> Bool {
        signer.caseInsensitiveCompare(me) == .orderedSame && iAmOwnerOrAdmin
    }

    /// Whether the directory's keys are a change from what the original bound.
    nonisolated static func keysChanged(original: MembershipStatement, sharing: String, signing: String) -> Bool {
        original.subjectSharingPublicKeyHex?.caseInsensitiveCompare(sharing) != .orderedSame
            || original.subjectSigningPublicKeyHex?.caseInsensitiveCompare(signing) != .orderedSame
    }

    /// After a circle list that says some invitation of `circleIds` waits to be
    /// renewed: look at each one this device should ask about, and ask.
    func look(circleIds: [String]) async {
        guard let me = AuthManager.shared.userId, !circleIds.isEmpty else { return }
        // The personal key's slot is no circle: nothing is renewed there.
        for circleId in circleIds where !CanonicalId.isPersonalSlot(circleId) {
            guard let invites = try? await api.pendingInvites(circleId: circleId) else { continue }
            CircleManager.shared.forgetInviteesNoLongerPending(circleId: circleId, invites: invites)
            if CircleManager.shared.rosters[circleId] == nil {
                try? await CircleManager.shared.loadMembers(for: circleId)
            }
            for invite in invites where invite.renewalRequested == true {
                await consider(invite, circleId: circleId, me: me)
            }
        }
    }

    private func consider(_ invite: PendingInviteResponse, circleId: String, me: String) async {
        guard let statementHex = invite.statement, let signatureHex = invite.statementSignature,
              let email = invite.targetEmail,
              let original = try? crypto.parseMembershipStatement(statementHex: statementHex),
              original.kind == .invitationToAccount,
              original.circleId.caseInsensitiveCompare(circleId) == .orderedSame,
              let subject = original.subjectUserId else { return }
        let statementId = original.statementId.lowercased()
        guard !Self.asked(owner: me).contains(statementId),
              !questions.contains(where: { $0.id == statementId }) else { return }

        guard Self.asksHere(me: me, signer: original.signerUserId,
                            iAmOwnerOrAdmin: ownerOrAdminHere(me: me, circleId: circleId)) else { return }

        // The original is verified BEFORE anyone is asked: signed by this
        // account's own key, unexpired, its id not dead here, and this
        // device's own pending invitation of that subject. A hacked server
        // could otherwise list forged "originals" naming this account as
        // signer — each with a fresh id, so "once per id" alone would not
        // bound the questions.
        let signedByMe = (try? crypto.signingPublicKeyHex()).flatMap { own in
            try? crypto.verifyMembershipStatement(statementHex: statementHex, signatureHex: signatureHex,
                                                  signerSigningPublicKeyHex: own)
        } == true
        guard signedByMe, Self.originalHolds(
            original, record: KeyDeliveryApprovals.shared.record(owner: me, circleId: circleId),
            withdrawnHere: Self.withdrawn(owner: me), now: Date()) else {
            print("[Track] invitation renewal: refused to ask about \(statementId) — the original does not hold here")
            return
        }

        // The directory, read HERE — never the report alone.
        guard let lookup = try? await api.lookupPublicKey(email: email),
              let userId = lookup.userId, userId.caseInsensitiveCompare(subject) == .orderedSame,
              let sharing = lookup.sharingPublicKey, let signing = lookup.signingPublicKey,
              Self.keysChanged(original: original, sharing: sharing, signing: signing) else { return }

        let number = try? crypto.computeSafetyNumber(selfUserId: me, peerUserId: subject,
                                                    peerSharingPubkeyHex: sharing, peerSigningPubkeyHex: signing)
        let question = Question(circleId: circleId, inviteId: invite.id, email: email, subjectUserId: subject,
                                statementId: statementId, originalStatementHex: statementHex,
                                originalSignatureHex: signatureHex, sharingKeyHex: sharing.lowercased(),
                                signingKeyHex: signing.lowercased(), number: number)
        questions.append(question)
        Self.markAsked(statementId, owner: me)
        save()
        CircleQuestionNotifier.post(.invitee, circleId: circleId, userId: subject, name: email, circleName: nil)
    }

    // MARK: - The answers

    enum RenewalError: LocalizedError, Equatable {
        /// The directory moved on since the question: asked again, not signed.
        case askedAgain
        case notDone(String)
        /// A waiting renewal found other keys in the directory than the ones the
        /// person decided on: nothing was signed, and the runner asks again once.
        case keysChangedWaiting(MemberKeyPair)

        var errorDescription: String? {
            switch self {
            case .askedAgain: return "Their details changed again, so Pingolin is asking once more."
            case .notDone(let reason): return reason
            case .keysChangedWaiting: return "Their details keep changing, so the invitation wasn't renewed."
            }
        }
    }

    static let changedTwiceText = "Their details keep changing, so the invitation wasn't renewed."

    /// A renewal the server found nothing to do for, by its code.
    nonisolated static func nothingToRenewText(_ error: APIError) -> String {
        if error.isServerCode("invite_not_renewable") {
            return "This invitation can't be renewed any more: you can no longer invite people to this circle."
        }
        if error.isServerCode("invite_not_found") {
            return "The invitation isn't there any more, so there was nothing to renew."
        }
        return "The invitation was answered, withdrawn or renewed meanwhile, so there was nothing to renew."
    }

    /// "It's them": renew for exactly the keys the question showed.
    ///
    /// While this iPhone is behind in the circle the answer waits: a renewal
    /// carries this device's key version (`at_version`), which the server
    /// refuses from a device that is behind, so nothing is looked up, pinned
    /// or signed until it runs. `waiting`: the waiting change being run now. A
    /// renewal keeps the original's id, so it needs no signed-id bookkeeping
    /// (`PendingChange.signedIds`).
    func itsThem(_ question: Question, waiting: PendingChange? = nil) async throws {
        guard let me = AuthManager.shared.userId, !CanonicalId.isPersonalSlot(question.circleId) else { return }
        guard CircleManager.shared.holdsCurrentKey(for: question.circleId) else {
            guard waiting == nil else { throw CircleManager.CircleError.waitingToSync }
            try keep(question, addressUnchecked: false)
            return
        }
        // A run signs with this device's signing key, which only the password
        // puts back.
        if waiting != nil, SelfKeyManager.signingKeyMissing { throw PendingChanges.NeedsPassword() }
        // If the directory has changed since the question, ask again; never sign.
        let lookup: UserPublicKeyResponse
        do {
            lookup = try await api.lookupPublicKey(email: question.email)
        } catch where PendingChanges.addressCouldNotBeChecked(error) {
            // The address couldn't be checked: the renewal is kept as a waiting
            // change, and nothing is signed or sent until the check answers.
            // Never an error line.
            if let waiting {
                PendingChangeStore.shared.update(waiting.id) { $0.addressUnchecked = true }
                throw PendingChanges.AddressNotChecked()
            }
            try keep(question, addressUnchecked: true)
            return
        }
        guard Self.stillShows(question, lookup) else {
            if waiting != nil {
                guard let sharing = lookup.sharingPublicKey, let signing = lookup.signingPublicKey,
                      lookup.userId?.caseInsensitiveCompare(question.subjectUserId) == .orderedSame else {
                    throw RenewalError.notDone(Self.changedTwiceText)
                }
                throw RenewalError.keysChangedWaiting(MemberKeyPair(sharingKeyHex: sharing.lowercased(),
                                                                    signingKeyHex: signing.lowercased()))
            }
            try reaskOrDrop(question, lookup: lookup, me: me)
        }
        // A waiting renewal for someone the circle's records show removed
        // after the person decided signs nothing (item 23,
        // `PendingChangeCopy.memberLeft`); one this device can't judge yet
        // waits. Read after the lookup, with nothing awaited before the
        // signature, so an eject taken meanwhile is seen.
        if let waiting {
            switch PendingChangeKinds.removedSinceTheTap(
                CircleManager.shared.removalCheck(userId: question.subjectUserId, circleId: question.circleId),
                change: waiting, name: question.email) {
            case .drop(let line)?: throw RenewalError.notDone(line ?? PendingChangeCopy.notDone(waiting))
            case .notYet?: throw CircleManager.CircleError.waitingToSync
            default: break
            }
        }

        let signed = try crypto.renewInvitation(
            circleId: question.circleId, renewerUserId: me,
            originalStatementHex: question.originalStatementHex,
            originalSignatureHex: question.originalSignatureHex,
            newSubjectSharingPublicKeyHex: question.sharingKeyHex,
            newSubjectSigningPublicKeyHex: question.signingKeyHex,
            facts: facts(for: question, me: me))

        // This device's user confirmed these keys: they are the invitee's here
        // now (as "It's them" does for an invite). No tombstone is touched.
        if crypto.pinnedSharingKey(circleId: question.circleId, userId: question.subjectUserId) != nil {
            try crypto.approveMemberKeyChange(circleId: question.circleId, userId: question.subjectUserId,
                                              newSharingPubkeyHex: question.sharingKeyHex,
                                              newSigningPubkeyHex: question.signingKeyHex)
        } else {
            _ = try crypto.pinMemberKeys(circleId: question.circleId, userId: question.subjectUserId,
                                         sharingPubkeyHex: question.sharingKeyHex,
                                         signingPubkeyHex: question.signingKeyHex)
        }
        MemberVerificationStore.clearVerified(circleId: question.circleId, userId: question.subjectUserId)

        // The circle's key goes only to the keys shown, and only from a device
        // that holds the current version, and on a circle with records only
        // with an owner's or admin's renewal in the chain; otherwise the
        // renewal is keyless and a member's app hands the key over when they
        // join.
        var request = RenewInvitationRequest(statement: signed.statementHex, statementSignature: signed.signatureHex)
        if CircleManager.shared.holdsCurrentKey(for: question.circleId),
           CircleManager.shared.invitationCarriesKey(circleId: question.circleId) {
            let bundle = try crypto.wrapCircleKeyForMemberFull(
                circleId: question.circleId, memberPublicKeyHex: question.sharingKeyHex,
                senderUserId: me, recipientUserId: question.subjectUserId,
                recipientSigningPubkeyHex: question.signingKeyHex)
            request.encryptedCircleKey = EncryptedBlobRequest(nonce: bundle.encryptedCircleKey.nonce,
                                                              ciphertext: bundle.encryptedCircleKey.ciphertext)
            request.ephemeralPublicKey = bundle.ephemeralPublicKey
            request.wrapSignature = bundle.wrapSignature.isEmpty ? nil : bundle.wrapSignature
        }
        do {
            _ = try await api.renewInvitation(circleId: question.circleId, inviteId: question.inviteId, request: request)
        } catch let error as APIError where waiting != nil {
            // A waiting renewal: the runner says what it means.
            throw error
        } catch let error as APIError where error.isServerCode("invite_lookup_changed") {
            // The account's keys moved after the question: look them up again,
            // and ask again (at most once per invitation). A check that can't
            // be done keeps the renewal waiting, as above.
            let fresh: UserPublicKeyResponse
            do {
                fresh = try await api.lookupPublicKey(email: question.email)
            } catch where PendingChanges.addressCouldNotBeChecked(error) {
                try keep(question, addressUnchecked: true)
                return
            }
            try reaskOrDrop(question, lookup: fresh, me: me)
        } catch let error as APIError where error.isServerCode("invite_changed", "invite_not_found",
                                                                  "invite_not_renewable") {
            // Someone else renewed, withdrew or answered it meanwhile. Said in
            // this app's own words: the server's are never shown.
            drop(question)
            throw RenewalError.notDone(Self.nothingToRenewText(error))
        }
        guard waiting == nil else { return }
        drop(question)
        CircleQuestionNotifier.answered(.invitee, circleId: question.circleId, userId: question.subjectUserId)
    }

    /// "It's them", kept as a waiting renewal until it can run: while this
    /// iPhone is behind, or when the address couldn't be checked. The
    /// question is answered; nothing is looked up, pinned or signed now. Its
    /// age limit is the invitation's own expiry.
    private func keep(_ question: Question, addressUnchecked: Bool) throws {
        let original = try? crypto.parseMembershipStatement(statementHex: question.originalStatementHex)
        try PendingChanges.queue(
            .renewInvitation, circleId: question.circleId,
            inputs: .renewInvitation(.init(inviteId: question.inviteId, statementId: question.statementId,
                                           inviteeUserId: question.subjectUserId, email: question.email)),
            seen: .init(keys: MemberKeyPair(sharingKeyHex: question.sharingKeyHex,
                                            signingKeyHex: question.signingKeyHex)),
            subject: question.email,
            expiresAt: original.map { Date(timeIntervalSince1970: TimeInterval($0.expiresAt)) },
            addressUnchecked: addressUnchecked)
        drop(question)
        CircleQuestionNotifier.answered(.invitee, circleId: question.circleId, userId: question.subjectUserId)
    }

    /// A waiting renewal runs: its invitation as the server lists it now,
    /// verified as the question's was (signed by this account's own key,
    /// unexpired, its id not dead here, this device's own pending
    /// invitation), then "It's them" for exactly the keys decided on.
    func renewWaiting(_ change: PendingChange) async throws {
        guard case .renewInvitation(let inputs) = change.inputs, let keys = change.seen.keys else { return }
        guard let question = try await waitingQuestion(change, inputs: inputs, keys: keys) else {
            throw RenewalError.notDone(PendingChangeCopy.invitationEnded(email: inputs.email))
        }
        try await itsThem(question, waiting: change)
    }

    /// The question a waiting renewal answers, rebuilt from its invitation as
    /// the server lists it now; nil when that invitation is no longer pending,
    /// or its original no longer holds here. Throws when the list can't be read.
    func waitingQuestion(_ change: PendingChange, inputs: PendingChange.RenewalInputs,
                         keys: MemberKeyPair) async throws -> Question? {
        guard let me = AuthManager.shared.userId else { return nil }
        let invites = try await api.pendingInvites(circleId: change.circleId)
        guard let invite = invites.first(where: { $0.id == inputs.inviteId }),
              let statementHex = invite.statement, let signatureHex = invite.statementSignature,
              let original = try? crypto.parseMembershipStatement(statementHex: statementHex),
              original.kind == .invitationToAccount,
              original.statementId.lowercased() == inputs.statementId.lowercased(),
              original.circleId.caseInsensitiveCompare(change.circleId) == .orderedSame,
              original.subjectUserId?.caseInsensitiveCompare(inputs.inviteeUserId) == .orderedSame else { return nil }
        let signedByMe = (try? crypto.signingPublicKeyHex()).flatMap { own in
            try? crypto.verifyMembershipStatement(statementHex: statementHex, signatureHex: signatureHex,
                                                  signerSigningPublicKeyHex: own)
        } == true
        guard signedByMe, Self.originalHolds(
            original, record: KeyDeliveryApprovals.shared.record(owner: me, circleId: change.circleId),
            withdrawnHere: Self.withdrawn(owner: me), now: Date()) else { return nil }
        return Question(circleId: change.circleId, inviteId: inputs.inviteId, email: inputs.email,
                        subjectUserId: inputs.inviteeUserId, statementId: inputs.statementId.lowercased(),
                        originalStatementHex: statementHex, originalSignatureHex: signatureHex,
                        sharingKeyHex: keys.sharingKeyHex, signingKeyHex: keys.signingKeyHex, number: nil)
    }

    /// Whether the directory still shows the keys the question was about.
    nonisolated static func stillShows(_ question: Question, _ lookup: UserPublicKeyResponse) -> Bool {
        lookup.userId?.caseInsensitiveCompare(question.subjectUserId) == .orderedSame
            && lookup.sharingPublicKey?.caseInsensitiveCompare(question.sharingKeyHex) == .orderedSame
            && lookup.signingPublicKey?.caseInsensitiveCompare(question.signingKeyHex) == .orderedSame
    }

    /// The directory moved between the question and the answer: asked again at
    /// most ONCE per invitation, else dropped. Always throws — nothing is
    /// signed on this answer.
    private func reaskOrDrop(_ question: Question, lookup: UserPublicKeyResponse, me: String) throws -> Never {
        drop(question)
        guard !Self.reasked(owner: me).contains(question.id) else {
            print("[Track] invitation renewal: \(question.id) changed again after being asked twice — dropped")
            throw RenewalError.notDone(Self.changedTwiceText)
        }
        Self.markReasked(question.id, owner: me)
        if let sharing = lookup.sharingPublicKey, let signing = lookup.signingPublicKey,
           lookup.userId?.caseInsensitiveCompare(question.subjectUserId) == .orderedSame {
            let number = try? crypto.computeSafetyNumber(selfUserId: me, peerUserId: question.subjectUserId,
                                                        peerSharingPubkeyHex: sharing, peerSigningPubkeyHex: signing)
            questions.append(Question(circleId: question.circleId, inviteId: question.inviteId,
                                      email: question.email, subjectUserId: question.subjectUserId,
                                      statementId: question.statementId,
                                      originalStatementHex: question.originalStatementHex,
                                      originalSignatureHex: question.originalSignatureHex,
                                      sharingKeyHex: sharing.lowercased(), signingKeyHex: signing.lowercased(),
                                      number: number))
            save()
        }
        throw RenewalError.askedAgain
    }

    /// "Not them": final. The invitation is withdrawn and its id is dead here.
    func notThem(_ question: Question) async throws {
        do {
            _ = try await api.revokeInvite(circleId: question.circleId, inviteId: question.inviteId)
        } catch let error as APIError where error.isServerCode("invite_not_found") || error.code == "http_404" {
            // Gone already.
        }
        if let me = AuthManager.shared.userId {
            Self.markWithdrawn(question.statementId, owner: me)
            // Dead here too: a server that lists them with it again gets nothing.
            KeyDeliveryApprovals.shared.withdrawInvitation(owner: me, circleId: question.circleId,
                                                           statementId: question.statementId)
            // A re-invite that cleared a removal: the removal is noted again.
            RefreshLedger.shared.invitationWithdrawn(account: me, circleId: question.circleId,
                                                     statementId: question.statementId)
        }
        drop(question)
        CircleQuestionNotifier.answered(.invitee, circleId: question.circleId, userId: question.subjectUserId)
    }

    /// Whether this account is an owner or admin, for the renewal facts. A
    /// kind-3 admission proves "admitted", not "admin" (it has no role byte),
    /// so: created here (the only proof of owner a device has), else the circle
    /// list's role. The server's word, but here it can only let this device ask
    /// its own person about its own invitation, and the honest server's renewal
    /// checks the role.
    private func ownerOrAdminHere(me: String, circleId: String) -> Bool {
        let record = KeyDeliveryApprovals.shared.record(owner: me, circleId: circleId)
        let isOwner = CircleManager.shared.circles.first { $0.id == circleId }?.isOwner == true
        let role = CircleManager.shared.rosters[circleId]?
            .first { $0.userId.caseInsensitiveCompare(me) == .orderedSame }?.role
        return Self.ownerOrAdmin(createdHere: AccessHandover.createdHere(record, me: me),
                                 ownerInList: isOwner, role: role)
    }

    nonisolated static func ownerOrAdmin(createdHere: Bool, ownerInList: Bool,
                                         role: CircleMember.MemberRole?) -> Bool {
        createdHere || ownerInList || role == .owner || role == .admin
    }

    /// Pure, for tests: whether the original still holds on this device, before
    /// anyone is asked — unexpired, its id not dead here (a tombstone carries
    /// it, or it was withdrawn from here), and this device's own PENDING
    /// invitation of its subject (the invitee record, not the absence of a
    /// tombstone — someone who left and was invited again can be renewed). (Its
    /// signature is checked against this account's own key beside it.)
    nonisolated static func originalHolds(_ original: MembershipStatement, record: CircleApprovalRecord,
                                          withdrawnHere: Set<String>, now: Date) -> Bool {
        let id = original.statementId.lowercased()
        let at = Int64(now.timeIntervalSince1970)
        let tombstonedIds = Set(record.tombstones.values.flatMap(\.statementIds).map { $0.lowercased() })
        let pendingHere = original.subjectUserId.map { subject in
            record.holdsPendingInvitation(subject: subject, statementId: id, now: at)
        } ?? false
        return original.expiresAt > at
            && !tombstonedIds.contains(id) && !withdrawnHere.contains(id) && pendingHere
    }

    /// What THIS device's record says (sdk `InvitationRenewalFacts`).
    private func facts(for question: Question, me: String) -> InvitationRenewalFacts {
        let original = try? crypto.parseMembershipStatement(statementHex: question.originalStatementHex)
        return Self.facts(record: KeyDeliveryApprovals.shared.record(owner: me, circleId: question.circleId),
                          signer: original?.signerUserId ?? "", me: me,
                          iAmOwnerOrAdmin: ownerOrAdminHere(me: me, circleId: question.circleId),
                          subject: question.subjectUserId, statementId: question.statementId,
                          withdrawnHere: Self.withdrawn(owner: me), now: Date())
    }

    /// Pure, for tests: the facts from a record, describing the circle NOW.
    /// - the original signer is an owner or admin now: only this account's own
    ///   invitations are renewed here, so it is whether this account still is;
    /// - the renewer (this account) is an owner or admin in this record;
    /// - the subject is NOT this device's pending invitee under this very
    ///   invitation (the renewal reads the invitee record — pending, unexpired,
    ///   not dead — instead of the tombstone);
    /// - the id is dead here: carried by a tombstone, withdrawn from here.
    nonisolated static func facts(record: CircleApprovalRecord, signer: String, me: String,
                                  iAmOwnerOrAdmin: Bool, subject: String, statementId: String,
                                  withdrawnHere: Set<String>, now: Date) -> InvitationRenewalFacts {
        let id = statementId.lowercased()
        let tombstonedIds = Set(record.tombstones.values.flatMap(\.statementIds).map { $0.lowercased() })
        return InvitationRenewalFacts(
            originalSignerIsOwnerOrAdminNow: signer.caseInsensitiveCompare(me) == .orderedSame && iAmOwnerOrAdmin,
            renewerIsOwnerOrAdmin: iAmOwnerOrAdmin,
            subjectDepartedOrTombstoned: !record.holdsPendingInvitation(
                subject: subject, statementId: id, now: Int64(now.timeIntervalSince1970)),
            invitationWithdrawnOrDead: tombstonedIds.contains(id) || record.deadStatementIds.contains(id)
                || withdrawnHere.contains(id))
    }

    /// The question to show now: the first one that is not waiting for its
    /// circle to catch up, or whose circle has (`caughtUp`).
    nonisolated static func next(_ questions: [Question], waitingForSync: Set<String>,
                                 caughtUp: (String) -> Bool) -> Question? {
        questions.first { !waitingForSync.contains($0.id) || caughtUp($0.circleId) }
    }

    // MARK: - Kept on this device

    private func drop(_ question: Question) {
        questions.removeAll { $0.id == question.id }
        waitingForSync.remove(question.id)
        save()
    }

    private static let questionsKey = "invitationRenewals.questions"
    nonisolated private static func askedKey(_ owner: String) -> String { "invitationRenewals.asked.\(owner.lowercased())" }
    nonisolated private static func withdrawnKey(_ owner: String) -> String { "invitationRenewals.withdrawn.\(owner.lowercased())" }

    private struct Stored: Codable {
        let owner: String
        let questions: [Question]
    }

    private func load() {
        guard let owner = AuthManager.shared.userId,
              let data = UserDefaults.standard.data(forKey: Self.questionsKey),
              let stored = try? JSONDecoder().decode(Stored.self, from: data),
              stored.owner.caseInsensitiveCompare(owner) == .orderedSame else { return }
        questions = stored.questions
    }

    private func save() {
        guard let owner = AuthManager.shared.userId, !questions.isEmpty,
              let data = try? JSONEncoder().encode(Stored(owner: owner, questions: questions)) else {
            UserDefaults.standard.removeObject(forKey: Self.questionsKey)
            return
        }
        UserDefaults.standard.set(data, forKey: Self.questionsKey)
    }

    nonisolated static func asked(owner: String) -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: askedKey(owner)) ?? [])
    }

    nonisolated static func markAsked(_ statementId: String, owner: String) {
        var ids = asked(owner: owner)
        ids.insert(statementId.lowercased())
        UserDefaults.standard.set(Array(ids), forKey: askedKey(owner))
    }

    nonisolated private static func reaskedKey(_ owner: String) -> String { "invitationRenewals.reasked.\(owner.lowercased())" }

    nonisolated static func reasked(owner: String) -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: reaskedKey(owner)) ?? [])
    }

    nonisolated static func markReasked(_ statementId: String, owner: String) {
        var ids = reasked(owner: owner)
        ids.insert(statementId.lowercased())
        UserDefaults.standard.set(Array(ids), forKey: reaskedKey(owner))
    }

    nonisolated static func withdrawn(owner: String) -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: withdrawnKey(owner)) ?? [])
    }

    nonisolated static func markWithdrawn(_ statementId: String, owner: String) {
        var ids = withdrawn(owner: owner)
        ids.insert(statementId.lowercased())
        UserDefaults.standard.set(Array(ids), forKey: withdrawnKey(owner))
    }

    /// Sign-out: the questions belong to the account that was asked.
    func reset() {
        questions = []
        waitingForSync = []
        UserDefaults.standard.removeObject(forKey: Self.questionsKey)
    }
}

import SwiftUI

/// Presents `InvitationRenewals.questions.first` at the app root, after the
/// member questions (those go first): "Is this really {email}?" with their
/// number, [It's them] renews for exactly the keys shown, [Not them] withdraws
/// the invitation for good.
struct InvitationRenewalQuestionHost: ViewModifier {
    @StateObject private var renewals = InvitationRenewals.shared
    @StateObject private var pinner = MemberKeyPinner.shared
    /// Observed so a question waiting for its circle to catch up comes back
    /// when it has.
    @StateObject private var circles = CircleManager.shared
    @State private var answering: String?
    @State private var outcome: String?
    /// Nothing over App Lock: the question waits for the unlock.
    @SwiftUI.Environment(\.appLocked) private var appLocked

    private var current: InvitationRenewals.Question? {
        guard pinner.alerts.isEmpty, answering == nil, outcome == nil else { return nil }
        return InvitationRenewals.next(renewals.questions, waitingForSync: renewals.waitingForSync,
                                       caughtUp: { circles.holdsCurrentKey(for: $0) })
    }

    func body(content: Content) -> some View {
        content
            .alert(
                current.map { InviteeChange.title(email: $0.email) } ?? "",
                isPresented: Binding(get: { !appLocked && current != nil }, set: { _ in }),
                presenting: current
            ) { question in
                Button("Not them", role: .destructive) { answer(question, itsThem: false) }
                Button("It's them") { answer(question, itsThem: true) }
            } message: { question in
                Text(InviteeChange.body(email: question.email, number: question.number))
            }
            .alert(
                "Invitation not renewed",
                isPresented: Binding(get: { !appLocked && outcome != nil }, set: { if !$0 && !appLocked { outcome = nil } }),
                presenting: outcome
            ) { _ in
                Button("OK", role: .cancel) { outcome = nil }
            } message: { text in
                Text(text)
            }
    }

    private func answer(_ question: InvitationRenewals.Question, itsThem: Bool) {
        answering = question.id
        Task { @MainActor in
            defer { answering = nil }
            do {
                if itsThem {
                    try await renewals.itsThem(question)
                } else {
                    try await renewals.notThem(question)
                }
            } catch InvitationRenewals.RenewalError.askedAgain {
                // The next question on the queue is the same invitation, with
                // the details as they are now.
            } catch {
                outcome = error.plainText
            }
        }
    }
}
