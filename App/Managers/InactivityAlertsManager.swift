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
import Combine
import PingolinTrackSDK

/// Inactivity alerts: notify a circle when a target user hasn't sent a
/// location for N hours. Mirrors the Android app's
/// InactivityAlertsViewModel and InactivityAlertRepository. The
/// encrypted_target_user_id is the only E2EE field on this surface; the
/// timeout is in plaintext hours for privacy-preserving server-side
/// evaluation.
@MainActor
final class InactivityAlertsManager: ObservableObject {
    static let shared = InactivityAlertsManager()

    @Published private(set) var alerts: [InactivityAlertResponse] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastError: String?
    /// When `alerts` last came back from the server. Lets the background
    /// evaluation pass reuse a recent list instead of re-fetching every 15
    /// minutes; any refresh — the Alerts screen, a create, an edit — renews it.
    private(set) var lastRefreshedAt: Date?

    // Inactivity firings the device raised itself live in
    // `LocalInactivityStore`; the server serves no list of them.

    private let api = APIService.shared
    private let cryptoManager = SDKCrypto.cryptoManager

    private init() {}

    /// Logout teardown for `AuthManager.logout()`: clear the decrypted
    /// inactivity alerts + events (each carries a decrypted target member) so
    /// one account's watch-list can't linger in memory for the next on the
    /// same device. Mirrors `CircleManager.reset()`.
    func reset() {
        alerts = []
        lastError = nil
        lastRefreshedAt = nil
    }

    func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            alerts = try await api.listInactivityAlerts()
            lastError = nil
            lastRefreshedAt = Date()
        } catch {
            lastError = "Failed to load inactivity alerts: \(error.plainText)"
        }
    }

    /// Refresh only when the list is older than `maxAge` (or was invalidated).
    func refreshIfStale(maxAge: TimeInterval, now: Date = Date()) async {
        guard Self.isStale(lastRefreshedAt: lastRefreshedAt, maxAge: maxAge, now: now) else { return }
        await refresh()
    }

    /// Forget when the list was fetched, so the next `refreshIfStale` goes to
    /// the server — for an `alerts_check` push or a return to the foreground.
    func invalidate() {
        lastRefreshedAt = nil
    }

    nonisolated static func isStale(lastRefreshedAt: Date?, maxAge: TimeInterval, now: Date) -> Bool {
        guard let last = lastRefreshedAt else { return true }
        return now.timeIntervalSince(last) >= maxAge
    }

    /// Whom an inactivity alert watches. All three create SERVER-evaluated
    /// rows (encrypted_conditions never set, client_only=false); the watched
    /// user is identified to the server only by their per-circle pseudonym
    /// (target_user_pseudonym).
    /// - `selfUser`: alert the circle if MY device goes quiet.
    /// - `everyone` / `members`: fan out to one server-eval row per watched
    ///   member (self excluded), so MonitoringManager never client-fires
    ///   these.
    enum Target {
        case selfUser
        case everyone
        case members([String])
    }

    /// Create inactivity alert(s). Every rule is SERVER-evaluated: the target
    /// user id is E2EE in encrypted_target_user_id AND the watched user's
    /// per-circle pseudonym rides in target_user_pseudonym so the server's
    /// cron can attribute location rows and fire without decryption.
    /// encrypted_conditions is never set (client_only stays false), so the
    /// client-eval path (MonitoringManager) does not pick these up.
    /// `everyone`/`members` create one server-eval row per watched member.
    ///
    /// While this iPhone is behind in the circle the alert waits and nil
    /// comes back. `waiting`: the waiting change being run now; each row it
    /// creates carries its own request id.
    @discardableResult
    func createAlert(
        circleId: String,
        target: Target,
        timeoutMinutes: Int,
        notifyPush: Bool = true,
        notifyEmail: Bool = false,
        cooldownMinutes: Int = 60,
        notifyOnReturn: Bool = false,
        waiting: PendingChange? = nil
    ) async throws -> InactivityAlertResponse? {
        // Nothing new is sealed under a key the circle has moved past.
        do {
            try CircleManager.shared.requireCurrentKey(for: circleId)
        } catch CircleManager.CircleError.keyNotCurrent where waiting == nil {
            let memberIds: [String]?
            switch target {
            case .selfUser, .everyone: memberIds = nil
            case .members(let ids): memberIds = ids
            }
            try PendingChanges.queue(
                .inactivityAlert, circleId: circleId,
                inputs: .inactivityAlert(.init(
                    memberIds: memberIds, everyone: { if case .everyone = target { return true } else { return false } }(),
                    timeoutMinutes: timeoutMinutes, notifyPush: notifyPush, notifyEmail: notifyEmail,
                    cooldownMinutes: cooldownMinutes, notifyOnReturn: notifyOnReturn)),
                member: memberIds?.first.flatMap { id in
                    CircleManager.shared.members[circleId]?.first { $0.userId == id }?.displayName
                })
            return nil
        }
        let selfId = AuthManager.shared.userId

        // Inactivity alerts are a single SERVER-evaluated path. Every rule
        // watches exactly ONE user, identified to the server only by their
        // per-circle pseudonym (target_user_pseudonym); encrypted_conditions
        // is never set, so client_only stays false and the server's cron owns
        // evaluation. `everyone`/`members` fan out to one server-eval row per
        // watched member (self excluded), and MonitoringManager's
        // `encryptedConditions != nil` filter keeps them from firing twice.
        let watchedUserIds: [String]
        let isSelfAlert: Bool
        switch target {
        case .selfUser:
            guard let me = selfId else {
                throw APIError(code: "unauthorized", message: "No user id available")
            }
            watchedUserIds = [me]
            isSelfAlert = true
        case .everyone:
            // Expand to every OTHER member of the circle — mirrors
            // AlertsView.otherMembers and MonitoringManager's watched filter.
            let members = CircleManager.shared.members[circleId] ?? []
            watchedUserIds = members.map { $0.userId }.filter { $0 != selfId }
            isSelfAlert = false
        case .members(let ids):
            watchedUserIds = ids.filter { $0 != selfId }
            isSelfAlert = false
        }

        guard !watchedUserIds.isEmpty else {
            throw APIError(code: "no_members_to_watch",
                           message: "No members to watch for inactivity")
        }

        let dayBucket = Int(Date().timeIntervalSince1970 / 86_400)

        // Idempotency: this loop creates one row per watched member. A mid-loop
        // throw (network) would leave partial rows AND abort before refresh(),
        // so a retry would re-create the rows already inserted (0..<k) and
        // duplicate them. Instead, skip any member this circle already has an
        // active NON-self rule for — matched by decrypting
        // encrypted_target_user_id (the v1 self-round-trip field, same as
        // watchSpec reads) — and continue past a per-member failure instead of
        // throwing mid-loop, so the batch always completes and refresh() always
        // runs before any error is surfaced. (Self-alerts are excluded: `me` is
        // never in watchedUserIds for the fan-out, and a user may keep more than
        // one self-rule per circle.)
        let alreadyWatched: Set<String> = Set(
            alerts
                .filter { $0.circleId == circleId && $0.isActive && !$0.isSelfAlert }
                .compactMap { existing in
                    try? cryptoManager.decryptData(
                        circleId: existing.circleId,
                        encryptedData: EncryptedData(
                            nonce: existing.encryptedTargetUserId.nonce,
                            ciphertext: existing.encryptedTargetUserId.ciphertext
                        )
                    )
                }
        )

        var lastCreatedId: String?
        var pendingError: Error?
        for userId in watchedUserIds where !alreadyWatched.contains(userId) {
            do {
                let encTarget = try cryptoManager.encryptData(circleId: circleId, plaintext: userId)
                // Per-circle pseudonym so the SERVER can attribute this user's
                // location rows and evaluate the rule without learning the raw
                // id (encrypted_target_user_id stays the E2EE round-trip field).
                let pseudonym = try cryptoManager.deriveUserPseudonym(circleId: circleId, userId: userId)
                let request = CreateInactivityAlertRequest(
                    circleId: circleId,
                    targetUserId: userId,
                    encryptedTargetUserId: EncryptedBlobRequest(
                        nonce: encTarget.nonce,
                        ciphertext: encTarget.ciphertext
                    ),
                    timeoutMinutes: timeoutMinutes,
                    isSelfAlert: isSelfAlert,
                    notifyPush: notifyPush,
                    notifyEmail: notifyEmail,
                    cooldownMinutes: cooldownMinutes,
                    // No watcher is set in encrypted_conditions, so the
                    // server evaluates every rule: client_only stays false and
                    // MonitoringManager's `encryptedConditions != nil` filter
                    // drops it (no client-side double-fire).
                    encryptedConditions: nil,
                    clientOnly: false,
                    targetUserPseudonym: pseudonym,
                    // Days since epoch — REQUIRED by the backend (matches the
                    // place-alert / SOS day-bucket convention).
                    dayBucket: dayBucket,
                    notifyOnReturn: notifyOnReturn,
                    clientRequestId: waiting?.requestId(for: userId)
                )
                // Create returns only the new id; re-fetch below for the full row.
                lastCreatedId = try await api.createInactivityAlert(request: request)
            } catch {
                // Keep going: rows created so far stay, and refresh() below
                // reflects them so a retry skips them via `alreadyWatched`.
                pendingError = error
            }
        }
        await refresh()
        // Surface a failure only after refresh() has recorded any rows this call
        // did create, so a retry skips them instead of duplicating.
        if let pendingError {
            throw pendingError
        }
        return alerts.first(where: { $0.id == lastCreatedId })
    }

    /// The raw decrypted watcher spec from encrypted_conditions: "all"
    /// (everyone) or a comma-joined id list. nil = no watcher set (self /
    /// legacy server-evaluated) OR the ciphertext couldn't be decrypted —
    /// callers MUST treat nil-with-conditions as "can't tell, skip" rather
    /// than guessing everyone, to avoid a false alarm on a key gap.
    func watchSpec(for alert: InactivityAlertResponse) -> String? {
        guard let blob = alert.encryptedConditions else {
            // No watcher spec means the rule watches exactly one member: the
            // encrypted target, which decrypts with the same circle key. It must
            // not return nil for such a rule: the server applies no threshold
            // and does not resolve the watched member — it only notices that
            // somebody went quiet and wakes us — so if this returns nil for an
            // ordinary rule, nothing anywhere fires it.
            return try? cryptoManager.decryptData(
                circleId: alert.circleId,
                encryptedData: EncryptedData(
                    nonce: alert.encryptedTargetUserId.nonce,
                    ciphertext: alert.encryptedTargetUserId.ciphertext
                )
            )
        }
        // `conditions` is v1 (empty AAD) on every client: the writer here uses
        // encryptData, and the Android app (InactivityAlertRepository) and the
        // web client both write and read v1. Reading it as v2 would leave a
        // client unable to decrypt its OWN watcher spec, silently skipping
        // non-self inactivity alerts. Match the v1 writer.
        return try? cryptoManager.decryptData(
            circleId: alert.circleId,
            encryptedData: EncryptedData(nonce: blob.nonce, ciphertext: blob.ciphertext)
        )
    }

    /// Partial update — pass only what changed (active toggle, timeout,
    /// notify prefs, cooldown). Used by the unified Alerts editor's
    /// tap-to-edit. Re-fetches for the updated row.
    func updateAlert(
        _ alert: InactivityAlertResponse,
        isActive: Bool? = nil,
        timeoutMinutes: Int? = nil,
        notifyPush: Bool? = nil,
        notifyEmail: Bool? = nil,
        cooldownMinutes: Int? = nil,
        notifyOnReturn: Bool? = nil
    ) async throws {
        let request = UpdateInactivityAlertRequest(
            timeoutMinutes: timeoutMinutes,
            isActive: isActive,
            notifyPush: notifyPush,
            notifyEmail: notifyEmail,
            cooldownMinutes: cooldownMinutes,
            encryptedConditions: nil,
            notifyOnReturn: notifyOnReturn
        )
        _ = try await api.updateInactivityAlert(alertId: alert.id, request: request)
        await refresh()
    }

    func deleteAlert(_ alert: InactivityAlertResponse) async throws {
        _ = try await api.deleteInactivityAlert(alertId: alert.id)
        alerts.removeAll { $0.id == alert.id }
    }
}
