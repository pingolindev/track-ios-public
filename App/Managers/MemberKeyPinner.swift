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
import PingolinTrackSDK

/// Per-member TOFU (trust-on-first-use) pin alert. Surfaced when the
/// SDK detects that a member's published (sharing, signing) keypair
/// differs from the previously-pinned one. The view layer pops a
/// one-at-a-time dialog with Approve / Block actions — mirrors
/// `CirclesFragment.showMemberKeyChangedDialog` in the Android app.
struct MemberKeyAlert: Identifiable, Equatable {
    let id: String   // "{circleId}:{userId}" — also the dialog dedup key
    let circleId: String
    let userId: String
    let displayName: String
    let state: PinState
    let previousPinnedAt: Int64
    /// The NEW keys this alert was raised for, exactly as they were observed
    /// (lowercase hex). Approve pins THESE and nothing else, and the safety
    /// number in the alert is computed from them — so what the user compared is
    /// what gets trusted. Never re-fetched from `member-public-keys`: the server
    /// serves that to owners and admins only, so for a plain member the fetch
    /// would fail and Approve would silently do Block, and for an admin it
    /// would pin whatever the server returned at that moment rather than the
    /// key the alert was about.
    let newSharingPubkeyHex: String
    /// nil in the signing-strip downgrade path (`gateMembersForRotation`), where
    /// the server stopped publishing a signing key for an already-pinned
    /// member. Such an alert cannot be approved: a pin needs both halves.
    let newSigningPubkeyHex: String?
    /// Short SHA-256 fingerprint of the NEW (changed-to) key material. Keys the
    /// block-suppression set per DISTINCT key so a later, genuinely different
    /// substitution re-raises the alert instead of being swallowed under the
    /// reused "{circleId}:{userId}" id. NOT part of the dialog dedup, which
    /// stays keyed on `id`.
    let fingerprint: String
    /// Their security code with this device's user, from the NEW keys — shown in
    /// the question so it can be checked another way first. nil when it cannot
    /// be worked out (no signing key, no own keys loaded).
    var number: String? = nil
    /// A receive-only member (an invitation to an email): their keys live in
    /// this device's approval record, never in the SDK's pins, so "It's
    /// them" updates the record instead.
    var receiveOnly: Bool = false
}

/// Why Approve did not adopt a member's new keys. Surfaced to the user, so
/// a failed approval can be told apart from Block.
enum MemberKeyApprovalError: LocalizedError, Equatable {
    /// The alert carries no signing key, so there is no complete pair to pin.
    case incompleteKeys
    /// The SDK refused or failed to record the new pin.
    case notSaved(String)

    var errorDescription: String? {
        switch self {
        case .incompleteKeys:
            return "Their account isn't fully set up again yet, so it can't be confirmed now."
        case .notSaved:
            // The SDK's reason is for the log: it talks about keys.
            return "This phone couldn't save that. Please try again."
        }
    }
}

/// Singleton funnel for member-key pins. CircleManager pins a member only
/// once this device has CONFIRMED them (`pinConfirmed`): pinning everyone the
/// server listed would let a listed ghost sign the next version of a circle
/// for every device. Divergences land in the `alerts` queue for the UI to
/// drain one by one. Approve = trust the new keys (recorded as the new
/// pin); Block = leave the OLD pin in place.
@MainActor
final class MemberKeyPinner: ObservableObject {
    static let shared = MemberKeyPinner(crypto: SDKCrypto.cryptoManager)

    /// "Is this really {name}?" is asked at most once a day per member on a
    /// device, whatever the circle and however often the member list
    /// refreshes.
    static let questionInterval: TimeInterval = 24 * 60 * 60
    private static let askedAtKey = "memberKeyQuestion.askedAt"
    private let defaults: UserDefaults

    /// One-at-a-time alert queue. RootView observes `alerts.first` and
    /// presents a sheet/alert; tapping a button calls `resolve(_:)`.
    @Published private(set) var alerts: [MemberKeyAlert] = []

    /// "{circleId}:{userId}:{fingerprint}" keys the exact (member, KEY) the
    /// user explicitly BLOCKED this session (see `suppressionKey`). A blocked
    /// key-change stays un-adopted (custody unchanged — approve() is still
    /// required to trust the new keys), but it must NOT re-raise its alert on
    /// every member refresh: with the 20s foreground poll that's a fresh nag each
    /// tick. Including the key fingerprint means a genuinely DIFFERENT later key
    /// (a distinct fingerprint) still resurfaces even before an app restart.
    /// In-memory only — cleared on app restart and on logout (reset()).
    private var suppressedAlertKeys: Set<String> = []

    private let crypto: PingolinTrackSDK.CryptoManager

    /// `shared` uses the app's persisted SDK instance. Tests pass a fresh,
    /// storage-less `CryptoManager` so they exercise the real pin logic without
    /// touching this device's keychain.
    init(crypto: PingolinTrackSDK.CryptoManager, defaults: UserDefaults = .standard) {
        self.crypto = crypto
        self.defaults = defaults
    }

    /// What happens instead of a question about a member whose app is too old
    /// to be confirmed. Tests record it instead.
    var askToUpdate: (_ circleId: String, _ userId: String) -> Void = { circleId, userId in
        Task { await CircleManager.shared.askMemberToUpdate(circleId: circleId, userId: userId) }
    }

    /// Drop the queued key-change alerts on logout. Each `MemberKeyAlert`
    /// carries a decrypted member `displayName`, and RootView presents
    /// `alerts.first` as a sheet — an undrained alert from the signed-out
    /// account would otherwise pop for the next account on this device. The
    /// SDK pins themselves are wiped separately by `cryptoManager.clearAllKeys()`.
    /// The once-a-day record goes too: it names the signed-out account's members.
    func reset() {
        alerts.removeAll()
        suppressedAlertKeys.removeAll()
        defaults.removeObject(forKey: Self.askedAtKey)
    }

    /// Suppression-set key for a change alert: the per-member id PLUS the new
    /// key's fingerprint, so blocking key-vN suppresses ONLY vN — a later,
    /// genuinely different key-vN+1 carries a different fingerprint and
    /// re-raises. The dialog dedup stays keyed on `alert.id` alone.
    private func suppressionKey(for alert: MemberKeyAlert) -> String {
        "\(alert.id):\(alert.fingerprint)"
    }

    /// Short SHA-256 fingerprint of the changed-to key material. Mirrors the
    /// hex-digest idiom in `MapCacheConfig.fileURL`. `signing` is nil in the
    /// signing-strip downgrade path, so it's folded in optionally.
    static func keyFingerprint(sharing: String, signing: String?) -> String {
        let digest = SHA256.hash(data: Data("\(sharing)|\(signing ?? "")".utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(16))
    }

    /// Queue a key-change alert for the UI unless the user BLOCKED this exact
    /// (circle, member, key) earlier this session (see `suppressedAlertKeys`) —
    /// the 20s poll's member refresh would otherwise re-nag every tick — or was
    /// asked about this member within the last day. Dedups within the queue by
    /// `id` (one dialog per member at a time). Custody is unaffected: callers
    /// still add a blocked member to their `blocked` set and the SDK still
    /// refuses the un-approved key.
    private func raiseAlert(_ alert: MemberKeyAlert, now: Date = Date()) {
        // Without a signing key nobody can confirm them — "It's them" could
        // only fail — so nobody is asked. Their app is too old; the server
        // tells THEM to update, and the roster then says so to everyone.
        // They stay out meanwhile (the callers keep them blocked).
        guard alert.newSigningPubkeyHex?.isEmpty == false else {
            askToUpdate(alert.circleId, alert.userId)
            return
        }
        guard !suppressedAlertKeys.contains(suppressionKey(for: alert)),
              !alerts.contains(where: { $0.id == alert.id || $0.userId == alert.userId }) else { return }
        var asked = defaults.dictionary(forKey: Self.askedAtKey) as? [String: Double] ?? [:]
        let member = alert.userId.lowercased()
        if let last = asked[member], now.timeIntervalSince1970 - last < Self.questionInterval { return }
        asked = asked.filter { now.timeIntervalSince1970 - $0.value < Self.questionInterval }
        asked[member] = now.timeIntervalSince1970
        defaults.set(asked, forKey: Self.askedAtKey)
        var alert = alert
        if alert.number == nil { alert.number = number(for: alert) }
        alerts.append(alert)
        // Not only when someone happens to open the app.
        CircleQuestionNotifier.post(.reset, circleId: alert.circleId, userId: alert.userId,
                                    name: alert.displayName, circleName: nil)
    }

    /// A tap on the question's notification opens the app to ask it: the day's
    /// limit must not hide the very question the tap came for.
    func askAgainNow(userId: String) {
        forgetAsked(userId)
    }

    /// An answer that did not take is asked again at the next refresh, not a
    /// day later — the failure message promises that.
    private func forgetAsked(_ userId: String) {
        var asked = defaults.dictionary(forKey: Self.askedAtKey) as? [String: Double] ?? [:]
        asked.removeValue(forKey: userId.lowercased())
        defaults.set(asked, forKey: Self.askedAtKey)
    }

    /// The security code for the keys an alert is about, as the SDK formats it.
    private func number(for alert: MemberKeyAlert) -> String? {
        guard let me = AuthManager.shared.userId, let signing = alert.newSigningPubkeyHex else { return nil }
        return try? crypto.computeSafetyNumber(
            selfUserId: me, peerUserId: alert.userId,
            peerSharingPubkeyHex: alert.newSharingPubkeyHex, peerSigningPubkeyHex: signing)
    }

    /// The keys this device pinned for a member — the circle's pin, else their
    /// identity pin. Read-only: never records anything.
    func pinnedKeys(circleId: String, userId: String) -> (sharing: String?, signing: String?) {
        (crypto.pinnedSharingKey(circleId: circleId, userId: userId),
         crypto.pinnedSigningKey(circleId: circleId, userId: userId))
    }

    /// Pin a member this device has CONFIRMED: the first pin for them, or a
    /// match. Pins that differ are not touched — their identity changed, so
    /// "Is this really {name}?" is asked instead. Never call this for anyone
    /// unconfirmed or receive-only.
    func pinConfirmed(
        circleId: String,
        userId: String,
        displayName: String,
        sharingPubkeyHex: String,
        signingPubkeyHex: String?
    ) {
        // Without a signing key the SDK can't pin a complete pair — skip
        // pinning rather than record a half-pin that'd never compare equal.
        guard let signing = signingPubkeyHex, !signing.isEmpty else { return }
        do {
            let result = try crypto.pinMemberKeys(
                circleId: circleId,
                userId: userId,
                sharingPubkeyHex: sharingPubkeyHex,
                signingPubkeyHex: signing
            )
            switch result.state {
            case .newPinning, .matched:
                return
            case .changedSharing, .changedSigning, .changedBoth:
                raiseAlert(MemberKeyAlert(
                    id: "\(circleId):\(userId)",
                    circleId: circleId,
                    userId: userId,
                    displayName: displayName,
                    state: result.state,
                    previousPinnedAt: result.previousPinnedAt,
                    newSharingPubkeyHex: sharingPubkeyHex.lowercased(),
                    newSigningPubkeyHex: signing.lowercased(),
                    fingerprint: Self.keyFingerprint(sharing: sharingPubkeyHex, signing: signing)
                ))
            }
        } catch {
            #if DEBUG
            print("[Track] pinMemberKeys(\(circleId), \(userId)) failed: \(error)")
            #endif
        }
    }

    /// Ask "Is this really {name}?" about keys that differ from what this device
    /// holds for a member — without pinning anything: a subject conflict (a
    /// statement binds their new keys, this device pinned the old ones) or a
    /// receive-only member whose keys changed. `known` is what this device
    /// holds; the question is skipped when the keys are the same.
    func askAboutChangedKeys(
        circleId: String,
        userId: String,
        displayName: String,
        known: (sharing: String?, signing: String?),
        sharingPubkeyHex: String,
        signingPubkeyHex: String?,
        receiveOnly: Bool = false
    ) {
        let sharingChanged = known.sharing.map { $0.caseInsensitiveCompare(sharingPubkeyHex) != .orderedSame } ?? true
        let signingChanged = known.signing.map { signing in
            signingPubkeyHex.map { $0.caseInsensitiveCompare(signing) != .orderedSame } ?? true
        } ?? true
        let state: PinState
        switch (sharingChanged, signingChanged) {
        case (false, false): return
        case (true, false): state = .changedSharing
        case (false, true): state = .changedSigning
        case (true, true): state = .changedBoth
        }
        raiseAlert(MemberKeyAlert(
            id: "\(circleId):\(userId)",
            circleId: circleId,
            userId: userId,
            displayName: displayName,
            state: state,
            previousPinnedAt: 0,
            newSharingPubkeyHex: sharingPubkeyHex.lowercased(),
            newSigningPubkeyHex: signingPubkeyHex?.lowercased(),
            fingerprint: Self.keyFingerprint(sharing: sharingPubkeyHex, signing: signingPubkeyHex),
            receiveOnly: receiveOnly
        ))
    }

    /// SEND-SIDE TOFU gate, run BEFORE a circle-key rotation wraps the fresh
    /// key to each member's SERVER-SUPPLIED sharing key. Without it, a
    /// compromised/blind server that substitutes a member's sharing key in
    /// `memberPublicKeys` would get the new circle key wrapped to an
    /// attacker-held key and could decrypt every post-rotation location for the
    /// circle. Mirrors the receive-side `pin(...)` check and the web client's
    /// `gateMembersForRotation`.
    ///
    /// Returns the set of BLOCKED userIds; the caller leaves them pending. A
    /// Changed* pin also surfaces the existing MemberKeyAlert.
    ///
    /// It PINS a member it has not pinned before, so the caller passes only
    /// members this device has confirmed and who are not receive-only; anyone
    /// else is pending before it gets here.
    ///
    /// A member with only a sharing key (signing not yet server-migrated) is
    /// allowed as genuine first-contact TOFU (as on the web and Android); a
    /// stripped-signing downgrade on an already-pinned member is caught below
    /// by comparing the pinned sharing key.
    func gateMembersForRotation(
        circleId: String,
        currentUserId: String?,
        members: [(userId: String, displayName: String, sharingPubkeyHex: String?, signingPubkeyHex: String?)]
    ) -> Set<String> {
        var blocked = Set<String>()
        for m in members {
            if m.userId == currentUserId { continue } // never gate self
            guard let sharing = m.sharingPubkeyHex, sharing.count == 64 else {
                #if DEBUG
                print("[Track] rotation gate: \(m.userId) has no usable sharing key — blocking")
                #endif
                blocked.insert(m.userId)
                continue
            }
            guard let signing = m.signingPubkeyHex, signing.count == 64 else {
                // Signing not migrated yet: first-contact TOFU allowed — UNLESS
                // this member is ALREADY pinned. A blind/compromised server can
                // STRIP the signing key from a pinned member to force them back
                // into this "not migrated" branch, then swap their sharing key so
                // the rotated circle key gets wrapped to an attacker-held key.
                // Compare the still-pinned sharing key to the server-supplied one
                // and block on mismatch — this is the signing-strip downgrade.
                if let pinnedSharing = crypto.pinnedSharingKey(circleId: circleId, userId: m.userId),
                   pinnedSharing.caseInsensitiveCompare(sharing) != .orderedSame {
                    let alert = MemberKeyAlert(
                        id: "\(circleId):\(m.userId)",
                        circleId: circleId,
                        userId: m.userId,
                        displayName: m.displayName,
                        state: .changedSharing,
                        previousPinnedAt: 0,
                        newSharingPubkeyHex: sharing.lowercased(),
                        newSigningPubkeyHex: nil,
                        fingerprint: Self.keyFingerprint(sharing: sharing, signing: nil)
                    )
                    raiseAlert(alert)
                    blocked.insert(m.userId)
                }
                // Genuine first contact (no pin yet) → TOFU-allowed.
                continue
            }
            do {
                let result = try crypto.pinMemberKeys(
                    circleId: circleId,
                    userId: m.userId,
                    sharingPubkeyHex: sharing,
                    signingPubkeyHex: signing
                )
                switch result.state {
                case .newPinning, .matched:
                    continue
                case .changedSharing, .changedSigning, .changedBoth:
                    let alert = MemberKeyAlert(
                        id: "\(circleId):\(m.userId)",
                        circleId: circleId,
                        userId: m.userId,
                        displayName: m.displayName,
                        state: result.state,
                        previousPinnedAt: result.previousPinnedAt,
                        newSharingPubkeyHex: sharing.lowercased(),
                        newSigningPubkeyHex: signing.lowercased(),
                        fingerprint: Self.keyFingerprint(sharing: sharing, signing: signing)
                    )
                    raiseAlert(alert)
                    blocked.insert(m.userId)
                }
            } catch {
                #if DEBUG
                print("[Track] rotation gate: pinMemberKeys(\(m.userId)) failed: \(error) — blocking")
                #endif
                blocked.insert(m.userId)
            }
        }
        return blocked
    }

    /// A question answered without the SDK: a receive-only member's new keys
    /// go into the approval record instead of a pin.
    func dismiss(_ alert: MemberKeyAlert) {
        alerts.removeAll { $0.id == alert.id }
        CircleQuestionNotifier.answered(.reset, circleId: alert.circleId, userId: alert.userId)
    }

    /// Approve = re-pin under exactly the keys the alert was raised for, so
    /// subsequent fetches no longer alert.
    ///
    /// Reads nothing from the network: the keys travel on the alert (see
    /// `MemberKeyAlert.newSharingPubkeyHex`). THROWS instead of degrading to
    /// Block — a failed approval that looks like a successful one would leave
    /// a plain member refusing every later wrap from someone they had approved.
    /// On failure the alert is dropped from the queue WITHOUT being suppressed,
    /// so the next roster refresh asks again.
    func approve(_ alert: MemberKeyAlert) throws {
        guard let signing = alert.newSigningPubkeyHex, !signing.isEmpty else {
            alerts.removeAll { $0.id == alert.id }
            forgetAsked(alert.userId)
            throw MemberKeyApprovalError.incompleteKeys
        }
        // Must call the PURPOSE-BUILT approve, not `pinMemberKeys`: once a member
        // is pinned, `pinMemberKeys` detects the divergence and deliberately
        // LEAVES the existing pin untouched (returning `.changed*`), so calling it
        // on Approve is a no-op — the member stays stuck "key unavailable" and
        // the alert re-raises on the next refresh. `approveMemberKeyChange`
        // overwrites the pin with the user-confirmed pair.
        do {
            try crypto.approveMemberKeyChange(
                circleId: alert.circleId,
                userId: alert.userId,
                newSharingPubkeyHex: alert.newSharingPubkeyHex,
                newSigningPubkeyHex: signing
            )
        } catch {
            alerts.removeAll { $0.id == alert.id }
            forgetAsked(alert.userId)
            print("[Track] member key approval not saved: \(error)")
            throw MemberKeyApprovalError.notSaved(String(describing: error))
        }
        // The pin is now overwritten with the NEW keys, so any prior "verified
        // out of band" marker no longer applies — drop it so the SAS toggle
        // can't keep vouching for a key the user never actually compared.
        // Mirrors the Android app's `CircleRepository.approveMemberKeyChange`.
        MemberVerificationStore.clearVerified(circleId: alert.circleId, userId: alert.userId)
        // If this member's THIS-key change was BLOCKED earlier this session,
        // adopting the new keys clears that suppression entry. (Suppression is
        // per-key, so a genuinely DIFFERENT future change already re-nags on its
        // own fingerprint regardless.)
        suppressedAlertKeys.remove(suppressionKey(for: alert))
        alerts.removeAll { $0.id == alert.id }
        CircleQuestionNotifier.answered(.reset, circleId: alert.circleId, userId: alert.userId)
    }

    /// Block = leave the OLD pin canonical so the SDK keeps refusing
    /// to encrypt/decrypt against the new keys until the user re-
    /// verifies out-of-band. We dismiss the alert AND suppress it for the
    /// session so the 20s poll's member refresh doesn't re-nag every tick;
    /// an app restart (suppression is in-memory) or a genuinely different later
    /// key resurfaces it. Custody is unchanged — approve() is still required to
    /// adopt the new keys.
    func block(_ alert: MemberKeyAlert) {
        suppressedAlertKeys.insert(suppressionKey(for: alert))
        alerts.removeAll { $0.id == alert.id }
        CircleQuestionNotifier.answered(.reset, circleId: alert.circleId, userId: alert.userId)
    }
}
