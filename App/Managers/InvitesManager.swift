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
import CryptoKit
import UserNotifications
import PingolinTrackSDK

/// Pending received-invites state. Mirrors the Android app's
/// `InvitesViewModel` — fetches `/api/v1/invites/received`, surfaces
/// the list to the UI, and routes accept/decline back through the
/// existing APIService endpoints.
///
/// Refresh triggers:
///   * Post-auth (AuthManager.checkExistingSession + completeLogin)
///   * Scene foreground (TrackApp.scenePhase == .active)
///   * Silent `circle_invite` push (PushAppDelegate.didReceiveRemoteNotification)
///
/// On accept we POST `/invites/{id}/accept` and then refetch
/// CircleManager.circles so the new circle (and its
/// freshly-wrapped circle key) shows up in the Circles tab + map.
@MainActor
final class InvitesManager: ObservableObject {
    static let shared = InvitesManager()

    @Published private(set) var invites: [ReceivedInviteResponse] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastError: String?
    /// Invitations this person already said yes to that did not name this
    /// account as it is now, by invite id. Kept on this device for the
    /// account that said yes.
    @Published private(set) var renewalWaits: [String: RenewalWait] = [:] {
        didSet { Self.saveRenewalWaits(renewalWaits, owner: AuthManager.shared.userId) }
    }

    private let api = APIService.shared

    private init() {
        renewalWaits = Self.loadRenewalWaits(owner: AuthManager.shared.userId)
        notRenewable = Set(UserDefaults.standard.stringArray(forKey: Self.notRenewableKey) ?? [])
    }

    /// Best-effort fetch. Silently leaves the cached list intact on
    /// network / auth errors — callers shouldn't have to gate UI on
    /// connectivity, and the next foreground / push will retry.
    ///
    /// Gated on the presence of an access token rather than the
    /// AuthManager.isAuthenticated flag. The flag only flips true
    /// after checkExistingSession completes on cold launch, which
    /// can race with notification-tap delegate callbacks — gating
    /// on the keychain slot lets the tap handler kick off the
    /// fetch before /auth/me has come back, so the fallback route
    /// to Circles can fire on a cold-launched tap.
    func refresh() async {
        guard KeychainService.shared.getString(for: .accessToken) != nil else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            invites = try await api.receivedInvites()
            lastError = nil
            // No pending invites server-side means any
            // already-delivered invite banners in the iOS tray are
            // stale (server's APNs retries pile up across pushes
            // and don't share identifiers — iOS can't dedupe). Wipe
            // them so the tray reflects current state.
            if invites.isEmpty {
                Self.clearDeliveredInviteNotifications()
            }
            await joinRenewedInvitations()
        } catch {
            #if DEBUG
            print("[Track] InvitesManager.refresh failed: \(error)")
            #endif
        }
    }

    /// Accept a pre-wrapped (email-style) invite. The inviter
    /// already wrapped the circle key under our X25519 sharing public
    /// key, so the server just needs to flip our membership row to
    /// active — no client-side key wrap. After accept, refetch
    /// CircleManager so the new circle (+ its freshly-loaded
    /// per-version circle key) lands in `circles` / `members`.
    ///
    /// `hasEncryptedKey == false` is accepted too, and is NOT a link invite
    /// (the server offers no way to create one). It means the inviter could
    /// not pre-wrap the circle key, because the invitee had no published
    /// sharing key when the invite was sent — the ordinary case for someone
    /// who signed up afterwards. The server handles it: it records
    /// `needs_key_exchange`, flags the circle for rotation and tells the other
    /// members, so a member with `can_rotate_keys` distributes a wrap. Until
    /// that lands the circle name shows as undecryptable, which the row's
    /// caption explains, so Accept stays enabled for these users.
    @discardableResult
    /// `consent`: the location notice they agreed to. Joining IS agreeing, so it
    /// goes with the accept, in one request.
    ///
    /// An invitation that does not name this account as it is now, or one the
    /// server refuses as out of date — both a change of this account's keys —
    /// does not send the person off for a new invitation. The server is told
    /// (or already knows) and wakes who can renew it; after "Is this really
    /// {email}?" on their phone it names this account, and this device joins by
    /// itself with the yes given here (`joinRenewedInvitations`). Throws
    /// `.renewing` meanwhile.
    ///
    /// `waitForKey`: poll for the circle's key after joining (a person waiting
    /// on screen); a join made by itself in the background does not.
    func accept(invite: ReceivedInviteResponse, consent: ShownNotice?, waitForKey: Bool = true) async throws -> Circle? {
        // No invitation is to the personal key's slot; the list refuses one
        // first.
        guard !CanonicalId.isPersonalSlot(invite.circleId) else {
            throw InviteAcceptError.refused(Self.cannotBeUsedText)
        }
        switch mismatch(invite) {
        case .outdatedKeys?:
            await waitForRenewal(invite, consent: consent, alreadyKnown: false)
            if notRenewable.contains(invite.id) { throw InviteAcceptError.refused(Self.notRenewableText) }
            throw InviteAcceptError.renewing(Self.beingRenewed(inviter: invite.inviterDisplayName))
        case let other?:
            // Goes nowhere: no report, no wait (an honest server never sends one).
            renewalWaits[invite.id] = nil
            throw InviteAcceptError.refused(Self.refusal(for: other) ?? "")
        case nil:
            break
        }
        do {
            _ = try await api.acceptInvite(
                inviteId: invite.id,
                encryptedCircleKey: nil,
                ephemeralPublicKey: nil,
                locationConsent: LocationConsentGrant(consent)
            )
        } catch let error as APIError where error.isServerCode("invite_out_of_date") {
            // The invitation bound this account's keys from before a change
            // (a password reset). The server keeps it pending, marks it and
            // wakes who can renew it — for an account invitation only: nothing
            // else is ever renewed, so anything else is not waited for.
            guard let me = AuthManager.shared.userId,
                  MembershipConfirmation.isAccountInvitation(
                      statementHex: invite.statement, circleId: invite.circleId, userId: me,
                      checker: SDKCrypto.cryptoManager) else {
                renewalWaits[invite.id] = nil
                throw InviteAcceptError.refused(Self.cannotBeUsedText)
            }
            await waitForRenewal(invite, consent: consent, alreadyKnown: true)
            throw InviteAcceptError.renewing(Self.beingRenewed(inviter: invite.inviterDisplayName))
        } catch let error as APIError where error.isServerCode("invite_not_renewable") {
            // Out of date, and its sender can no longer invite people to this
            // circle: nothing will renew it, so nothing is waited for.
            renewalWaits[invite.id] = nil
            notRenewable.insert(invite.id)
            throw InviteAcceptError.refused(Self.notRenewableText)
        }
        renewalWaits[invite.id] = nil
        invites.removeAll { $0.id == invite.id }
        try? await CircleManager.shared.loadCircles()
        guard waitForKey else { return CircleManager.shared.circles.first { $0.id == invite.circleId } }

        // POLL until the circle key shows up, rather than trusting one refetch.
        //
        // The arrival time is unbounded, so any fixed delay silently drops the key
        // on the floor whenever the rotation is slower than the guess. A single
        // loadCircles() would leave a circle whose wrap is not installable at that
        // instant rendered locked — the converter's fallback for a missing key —
        // with nothing retrying, until something unrelated triggers a refresh.
        // Same schedule as the Android app's CircleRepository.acceptInvite: 30s
        // deadline, 500ms doubling to 4s.
        let crypto = SDKCrypto.cryptoManager
        if !invite.circleId.isEmpty, !crypto.hasCircleKey(circleId: invite.circleId) {
            let deadline = Date().addingTimeInterval(30)
            var waitMs: UInt64 = 500
            while Date() < deadline, !crypto.hasCircleKey(circleId: invite.circleId) {
                try? await Task.sleep(nanoseconds: waitMs * 1_000_000)
                try? await CircleManager.shared.loadCircles()
                waitMs = min(waitMs * 2, 4_000)
            }
            if !crypto.hasCircleKey(circleId: invite.circleId) {
                // Logged, not thrown. The join succeeded and the circle is real;
                // refusing it here would be worse than showing it unnamed, and
                // the key can still arrive later.
                print("[Track] acceptInvite: key for \(invite.circleId) did not arrive within 30s; "
                      + "circle will render locked until it does")
            }
        }

        // This account's name, sealed for the circle it just joined (nothing
        // until its key is here: the roster-load backfill sends it then).
        if !invite.circleId.isEmpty {
            Task { await CircleManager.shared.sealOwnName(circleId: invite.circleId) }
        }

        if invites.isEmpty {
            Self.clearDeliveredInviteNotifications()
        }
        // Server's accept response is `{"success": true, "data": null}` —
        // it doesn't echo a CircleResponse. Look the new circle up by
        // the invite's circleId after the loadCircles refetch.
        return CircleManager.shared.circles.first { $0.id == invite.circleId }
    }

    /// Why the invitation does not name this account as it is now, or nil
    /// when it does. An unsigned one cannot be checked here and is left to
    /// the server.
    func mismatch(_ invite: ReceivedInviteResponse) -> MembershipConfirmation.InvitationMismatch? {
        guard let me = AuthManager.shared.userId else { return nil }
        return MembershipConfirmation.invitationMismatch(
            statementHex: invite.statement, circleId: invite.circleId,
            me: CircleManager.shared.ownIdentity(userId: me), checker: SDKCrypto.cryptoManager)
    }

    /// The one line for an invitation that goes nowhere, said before anything
    /// is asked: sent to another address (never renewed) or another account.
    /// nil when it names this account, or is being renewed.
    func refusal(_ invite: ReceivedInviteResponse) -> String? {
        Self.refusal(for: mismatch(invite))
    }

    nonisolated static func refusal(for mismatch: MembershipConfirmation.InvitationMismatch?) -> String? {
        switch mismatch {
        case .otherAddress?: return "This invitation was sent to a different address."
        case .otherAccount?: return "This invitation was sent to a different account."
        case .outdatedKeys?, nil: return nil
        }
    }

    // MARK: - Renewal

    /// An invitation this person said yes to ("Join and share my location")
    /// that did not name this account as it is now.
    struct RenewalWait: Codable, Equatable {
        let inviteId: String
        let circleId: String
        /// The notice they agreed to: the consent that goes with the join.
        var noticeVersion: String?
        /// SHA-256 of the statement last tried. A renewal is a different one,
        /// and each distinct statement is tried once.
        var triedStatement: String?
        /// The server knows it waits: reported, or refused by the accept itself.
        var reported: Bool
    }

    /// What is happening, never "ask them". The same words as the Android app
    /// (`invite_renewing`, `…_unknown`). Static so a test can pin the words.
    nonisolated static func beingRenewed(inviter: String?) -> String {
        "This invitation is being renewed. It will work as soon as \(inviter ?? "the circle") confirms it's you."
    }

    /// Said once, after the person agreed to join an invitation being renewed.
    nonisolated static func joinsWhenRenewed(circle: String) -> String {
        "You'll join \(circle) then, with nothing more to do."
    }

    /// The invitation's line while this device waits to join by itself.
    nonisolated static func joiningWhenRenewed(inviter: String?) -> String {
        "Joining as soon as \(inviter ?? "the circle") confirms it's you."
    }

    nonisolated static func statementHash(_ statement: String?) -> String? {
        statement.map { SHA256.hash(data: Data($0.lowercased().utf8)).map { String(format: "%02x", $0) }.joined() }
    }

    /// Record the yes and make sure the server knows this invitation waits.
    private func waitForRenewal(_ invite: ReceivedInviteResponse, consent: ShownNotice?, alreadyKnown: Bool) async {
        var wait = renewalWaits[invite.id]
            ?? RenewalWait(inviteId: invite.id, circleId: invite.circleId, noticeVersion: nil,
                           triedStatement: nil, reported: false)
        wait.noticeVersion = consent?.version ?? wait.noticeVersion
        if wait.triedStatement != Self.statementHash(invite.statement) {
            wait.triedStatement = Self.statementHash(invite.statement)
            wait.reported = false
        }
        if alreadyKnown { wait.reported = true }
        if !wait.reported { wait.reported = await report(invite.id) }
        // Nothing will renew it: no wait is kept (report() said why).
        guard !notRenewable.contains(invite.id) else { return }
        renewalWaits[invite.id] = wait
    }

    /// Tell the server this invitation does not name this account. True once it
    /// has answered; false leaves it to the next refresh.
    private func report(_ inviteId: String) async -> Bool {
        do {
            try await api.reportInviteMismatch(inviteId: inviteId)
            return true
        } catch let error as APIError where error.isServerCode("invite_not_renewable") {
            // Its sender is no longer an owner or admin (or it can never be
            // renewed): nothing will renew it. Said once, no waiting.
            renewalWaits[inviteId] = nil
            notRenewable.insert(inviteId)
            return true
        } catch let error as APIError where error.isServerCode("invite_not_found") {
            renewalWaits[inviteId] = nil
            return true
        } catch {
            print("[Track] invite mismatch report failed (\(error)) — sent again at the next refresh")
            return false
        }
    }

    /// Invitations nothing will renew (the server said `invite_not_renewable`):
    /// they say so, and wait for nothing. Kept for the signed-in account.
    @Published private(set) var notRenewable: Set<String> = [] {
        didSet { UserDefaults.standard.set(Array(notRenewable), forKey: Self.notRenewableKey) }
    }
    private static let notRenewableKey = "invites.notRenewable"

    /// The server's word on an invitation whose sender is no longer an owner or
    /// admin; the same text on Android and the web. A demoted sender is still
    /// in the circle, so it doesn't say they left.
    nonisolated static let notRenewableText =
        "This invitation can't be used any more: the person who sent it can no longer invite people to this circle."

    /// Out of date, and not an account invitation, so nothing renews it: in
    /// this app's words, not the server's.
    nonisolated static let cannotBeUsedText = "This invitation can't be used any more."

    /// After every refresh: an invitation this person already said yes to is
    /// joined by itself once it names this account — once per distinct
    /// statement, with the yes they gave. One that is gone (withdrawn, declined
    /// elsewhere, expired) is forgotten.
    private func joinRenewedInvitations() async {
        for (id, var wait) in renewalWaits {
            let invite = invites.first { $0.id == id }
            switch Self.renewalStep(wait, invite: invite) {
            case .forget:
                renewalWaits[id] = nil
            case .wait:
                continue
            case .reportAgain:
                wait.reported = await report(id)
                if renewalWaits[id] != nil { renewalWaits[id] = wait }
            case .tryJoin:
                guard let invite else { continue }
                // Once per distinct statement: marked before the try, and
                // unmarked only when nothing answered (offline, the server
                // unavailable), so neither side can be made to loop.
                let previous = wait.triedStatement
                wait.triedStatement = Self.statementHash(invite.statement)
                wait.reported = true
                renewalWaits[id] = wait
                do {
                    _ = try await accept(invite: invite,
                                         consent: Self.consent(of: wait),
                                         waitForKey: false)
                    print("[Track] joined circle \(invite.circleId) by itself once its invitation was renewed")
                } catch InviteAcceptError.renewing {
                    // Renewed, and still not this account as it is now: waiting again.
                } catch InviteAcceptError.refused {
                    // No longer one this account can join; accept() forgot the wait.
                } catch {
                    if Self.nothingAnswered(error), var again = renewalWaits[id] {
                        again.triedStatement = previous
                        renewalWaits[id] = again
                    }
                    print("[Track] join after renewal failed (\(error))")
                }
            }
        }
    }

    /// The yes the person gave, sent again with the join made by itself: the
    /// join IS the consent, so it goes with it.
    nonisolated static func consent(of wait: RenewalWait) -> ShownNotice? {
        wait.noticeVersion.map { ShownNotice(version: $0) }
    }

    enum RenewalStep: Equatable {
        /// The invitation is gone: withdrawn, declined elsewhere, expired.
        case forget
        /// Not renewed yet, and the server knows.
        case wait
        /// Not renewed yet, and the report never reached the server.
        case reportAgain
        /// A different statement than the one tried: accept with the yes given.
        case tryJoin
    }

    /// Pure, for tests: what one refresh does about one wait.
    nonisolated static func renewalStep(_ wait: RenewalWait, invite: ReceivedInviteResponse?) -> RenewalStep {
        guard let invite else { return .forget }
        if statementHash(invite.statement) == wait.triedStatement {
            return wait.reported ? .wait : .reportAgain
        }
        return .tryJoin
    }

    /// No answer came back, so the try does not count.
    nonisolated static func nothingAnswered(_ error: Error) -> Bool {
        RetryClock.nothingAnswered(error)
    }

    /// Whether a background wake has an invitation to look at.
    var waitsForRenewal: Bool { !renewalWaits.isEmpty }

    private static let renewalWaitsKey = "invites.renewalWaits"

    private struct StoredRenewalWaits: Codable {
        let owner: String
        let waits: [String: RenewalWait]
    }

    private static func loadRenewalWaits(owner: String?) -> [String: RenewalWait] {
        guard let owner, let data = UserDefaults.standard.data(forKey: renewalWaitsKey),
              let stored = try? JSONDecoder().decode(StoredRenewalWaits.self, from: data),
              stored.owner.caseInsensitiveCompare(owner) == .orderedSame else { return [:] }
        return stored.waits
    }

    private static func saveRenewalWaits(_ waits: [String: RenewalWait], owner: String?) {
        guard let owner, !waits.isEmpty,
              let data = try? JSONEncoder().encode(StoredRenewalWaits(owner: owner, waits: waits)) else {
            UserDefaults.standard.removeObject(forKey: renewalWaitsKey)
            return
        }
        UserDefaults.standard.set(data, forKey: renewalWaitsKey)
    }

    func decline(invite: ReceivedInviteResponse) async throws {
        _ = try await api.declineInvite(inviteId: invite.id)
        invites.removeAll { $0.id == invite.id }
        if invites.isEmpty {
            Self.clearDeliveredInviteNotifications()
        }
    }

    /// Sweep iOS's delivered-notification tray for anything that
    /// looks invite-shaped and remove it. Called when our pending-
    /// invite list goes empty (either by accept/decline or by a
    /// refresh that no longer sees the invite server-side).
    ///
    /// Matching is intentionally generous because the server's
    /// alert pushes don't carry `type` or `invite_id`: we accept
    /// any of (a) our own `circle_invite_…` identifier prefix,
    /// (b) title or body that mentions invitation, or (c) the
    /// server's bare "Notification" / "Tap to view" copy — which
    /// is what /api/v1/invites pushes look like. False-positive
    /// risk is low; the server sends no other generic-copy pushes
    /// to iOS users.
    private static func clearDeliveredInviteNotifications() {
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { delivered in
            let toRemove: [String] = delivered.compactMap { notification in
                let identifier = notification.request.identifier
                let content = notification.request.content
                let title = content.title.lowercased()
                let body = content.body.lowercased()
                let isInvite = identifier.hasPrefix("circle_invite_")
                    || title.contains("invit")
                    || body.contains("invited")
                    || body.contains("invite")
                    || (title == "notification" && body == "tap to view")
                return isInvite ? identifier : nil
            }
            if !toRemove.isEmpty {
                center.removeDeliveredNotifications(withIdentifiers: toRemove)
            }
        }
    }

    /// Wipe local state on logout so a re-login under a different
    /// account doesn't render the previous account's pending list.
    func reset() {
        invites = []
        lastError = nil
        // A yes given on this device is not carried across a sign-out.
        renewalWaits = [:]
        notRenewable = []
    }

}

/// An invitation this device did not accept (yet), with the words to show.
enum InviteAcceptError: LocalizedError, Equatable {
    /// Sent to another address or account: it goes nowhere, and nothing is
    /// asked of anybody.
    case refused(String)
    /// It names this account's keys from before a password reset and is being
    /// renewed; this device joins by itself once it is. Not an error to show.
    case renewing(String)

    var errorDescription: String? {
        switch self {
        case .refused(let message), .renewing(let message): return message
        }
    }
}
