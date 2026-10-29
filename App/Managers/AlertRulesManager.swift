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

/// Low-battery "smart alert" rules: tell me when this member's battery drops
/// below my threshold. Mirrors the Android app's `AlertRuleRepository` and
/// the battery half of the unified Alerts UI.
///
/// Both the target and the threshold are sealed with the circle key, because
/// the server evaluates neither: it cannot read the battery level either (that
/// travels inside the location payload), so it has nothing to compare. The
/// comparison happens in MonitoringManager.evaluateBatteryAlerts, on a device
/// that holds the key.
@MainActor
final class AlertRulesManager: ObservableObject {
    static let shared = AlertRulesManager()

    @Published private(set) var rules: [AlertRuleResponse] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastError: String?

    /// Default battery threshold (%) — matches MonitoringManager + Android.
    static let defaultThreshold = 15

    private let api = APIService.shared
    private let cryptoManager = SDKCrypto.cryptoManager

    private init() {}

    /// Logout teardown for `AuthManager.logout()`: clear the decrypted
    /// low-battery rules (each carries a decrypted target member) so one
    /// account's watch-list can't linger in memory for the next on the same
    /// device. Mirrors `CircleManager.reset()`.
    func reset() {
        rules = []
        lastError = nil
        lastRefreshedAt = nil
    }

    /// Low-battery rules only — the unified Alerts list hosts these
    /// alongside inactivity alerts. (The legacy "offline" rule type is
    /// covered by inactivity alerts and not created here.)
    var batteryRules: [AlertRuleResponse] {
        rules.filter { $0.ruleType == "low_battery" }
    }

    /// The member a rule watches, decrypted with the circle key.
    ///
    /// Reads v2 first, then v1. Both exist for this field: v1 is what every
    /// Track client writes and reads (see `createBatteryRule`), and v2 is what
    /// earlier versions of this app wrote. Reading both keeps those rules from
    /// becoming orphans.
    func target(for rule: AlertRuleResponse) -> String? {
        guard let circleId = rule.circleId, let blob = rule.encryptedTargetUserId else { return nil }
        let data = EncryptedData(nonce: blob.nonce, ciphertext: blob.ciphertext)
        if let v2 = try? cryptoManager.decryptDataV2(
            circleId: circleId, encryptedData: data, fieldTag: "target_user_id"
        ) {
            return v2
        }
        return try? cryptoManager.decryptData(circleId: circleId, encryptedData: data)
    }

    /// The percentage this rule fires at.
    ///
    /// Sealed copy first: the threshold is sealed under the circle key, so the
    /// plaintext `conditions` column is empty on current rules and is read
    /// here only for rules created before the threshold was sealed. Absent
    /// both, the default rather than skipping the rule — a rule with no
    /// readable threshold would silently never fire.
    func threshold(for rule: AlertRuleResponse) -> Int {
        if let circleId = rule.circleId, let blob = rule.encryptedConditions,
           let json = try? cryptoManager.decryptData(
               circleId: circleId,
               encryptedData: EncryptedData(nonce: blob.nonce, ciphertext: blob.ciphertext)
           ),
           let data = json.data(using: .utf8),
           let parsed = try? JSONDecoder().decode(AlertRuleConditions.self, from: data),
           let threshold = parsed.threshold {
            return threshold
        }
        return rule.conditions?.threshold ?? Self.defaultThreshold
    }

    /// A rule's fields as a waiting change to it compares them: what the
    /// person saw when they changed it.
    func fields(of rule: AlertRuleResponse) -> PendingChange.AlertChangeInputs {
        .init(ruleId: rule.id, threshold: threshold(for: rule), isActive: rule.isActive,
              notifyPush: rule.notifyPush, notifyEmail: rule.notifyEmail, cooldownMinutes: rule.cooldownMinutes)
    }

    /// Whether the list came back from the server just now, whole: what a
    /// waiting change needs before it reads a rule as deleted.
    @discardableResult
    func refresh() async -> Bool {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            rules = try await api.listAlertRules()
            lastError = nil
            lastRefreshedAt = Date()
            return true
        } catch {
            lastError = "Failed to load alert rules: \(error.plainText)"
            return false
        }
    }

    /// When `rules` last came back from the server; see
    /// `InactivityAlertsManager.lastRefreshedAt`. Renewed by every refresh,
    /// including the ones create/update/delete run.
    private(set) var lastRefreshedAt: Date?

    /// Refresh only when the list is older than `maxAge` (or was invalidated).
    func refreshIfStale(maxAge: TimeInterval, now: Date = Date()) async {
        guard InactivityAlertsManager.isStale(lastRefreshedAt: lastRefreshedAt, maxAge: maxAge, now: now) else { return }
        await refresh()
    }

    /// Forget when the list was fetched, so the next `refreshIfStale` fetches.
    func invalidate() {
        lastRefreshedAt = nil
    }

    /// Create a low-battery rule. Target and threshold both sealed with the
    /// circle key; the server learns only that a rule of this type exists in
    /// this circle, which is what it needs to pick who to wake.
    ///
    /// While this iPhone is behind in the circle the rule waits and nil comes
    /// back. `waiting`: the waiting change being run now.
    @discardableResult
    func createBatteryRule(
        circleId: String,
        targetUserId: String,
        threshold: Int,
        notifyPush: Bool = true,
        notifyEmail: Bool = false,
        cooldownMinutes: Int = 60,
        waiting: PendingChange? = nil
    ) async throws -> AlertRuleResponse? {
        // Nothing new is sealed under a key the circle has moved past.
        do {
            try CircleManager.shared.requireCurrentKey(for: circleId)
        } catch CircleManager.CircleError.keyNotCurrent where waiting == nil {
            try PendingChanges.queue(
                .batteryAlert, circleId: circleId,
                inputs: .batteryAlert(.init(targetUserId: targetUserId, threshold: threshold, notifyPush: notifyPush,
                                            notifyEmail: notifyEmail, cooldownMinutes: cooldownMinutes)),
                member: CircleManager.shared.members[circleId]?.first { $0.userId == targetUserId }?.displayName)
            return nil
        }
        // v1, matching the other Track clients, which write and read
        // v1 for this field. A v2 blob would be undecryptable there,
        // and since the watcher's own device is what fires the rule,
        // a rule watched from one of them would never fire.
        let encTarget = try cryptoManager.encryptData(circleId: circleId, plaintext: targetUserId)
        // The threshold, sealed, rather than in the plaintext
        // `conditions` field, where the server could read a number it
        // has no use for: nothing there evaluates it, the comparison
        // happens on the watching device. v1, matching the other Track
        // clients, which write and read v1 for this blob.
        let conditionsJson = String(
            data: (try? JSONEncoder().encode(AlertRuleConditions(threshold: threshold))) ?? Data(),
            encoding: .utf8
        ) ?? "{}"
        let encConditions = try cryptoManager.encryptData(circleId: circleId, plaintext: conditionsJson)

        let request = CreateAlertRuleRequest(
            circleId: circleId,
            targetUserId: targetUserId,
            ruleType: "low_battery",
            // Empty: the column is NOT NULL and the value is not the server's.
            conditions: AlertRuleConditions(threshold: nil),
            notifyPush: notifyPush,
            notifyEmail: notifyEmail,
            notifySms: false,
            cooldownMinutes: cooldownMinutes,
            encryptedConditions: EncryptedBlobRequest(
                nonce: encConditions.nonce,
                ciphertext: encConditions.ciphertext
            ),
            encryptedTargetUserId: EncryptedBlobRequest(
                nonce: encTarget.nonce,
                ciphertext: encTarget.ciphertext
            ),
            dayBucket: Int(Date().timeIntervalSince1970 / 86_400),
            clientRequestId: waiting?.requestId()
        )
        let newId = try await api.createAlertRule(request: request)
        await refresh()
        return rules.first(where: { $0.id == newId })
    }

    /// Partial update — pass only what changed. Used for the active toggle,
    /// notify prefs, cooldown, and editing the battery threshold.
    ///
    /// A new threshold waits while this iPhone is behind in the rule's circle,
    /// with only the changed fields. `waiting`: the waiting change being run
    /// now.
    func updateRule(
        _ rule: AlertRuleResponse,
        isActive: Bool? = nil,
        threshold: Int? = nil,
        notifyPush: Bool? = nil,
        notifyEmail: Bool? = nil,
        cooldownMinutes: Int? = nil,
        waiting: PendingChange? = nil
    ) async throws {
        // An edited threshold has to be sealed the same way a created one is, or
        // the first edit puts it back in the clear.
        var encryptedConditions: EncryptedBlobRequest?
        if let threshold, let circleId = rule.circleId {
            // A threshold is sealed only under the circle's current key.
            do {
                try CircleManager.shared.requireCurrentKey(for: circleId)
            } catch CircleManager.CircleError.keyNotCurrent where waiting == nil {
                // The whole edit waits, with only the fields that changed.
                try PendingChanges.queue(.alertChange, circleId: circleId, inputs: .alertChange(.init(
                    ruleId: rule.id,
                    threshold: threshold,
                    isActive: isActive.flatMap { $0 == rule.isActive ? nil : $0 },
                    notifyPush: notifyPush.flatMap { $0 == rule.notifyPush ? nil : $0 },
                    notifyEmail: notifyEmail.flatMap { $0 == rule.notifyEmail ? nil : $0 },
                    cooldownMinutes: cooldownMinutes.flatMap { $0 == rule.cooldownMinutes ? nil : $0 })),
                    // The rule as the person saw it: one
                    // changed on another device meanwhile
                    // is never overwritten.
                    seen: .init(rule: fields(of: rule)))
                return
            }
            let json = String(
                data: (try? JSONEncoder().encode(AlertRuleConditions(threshold: threshold))) ?? Data(),
                encoding: .utf8
            ) ?? "{}"
            if let blob = try? cryptoManager.encryptData(circleId: circleId, plaintext: json) {
                encryptedConditions = EncryptedBlobRequest(
                    nonce: blob.nonce, ciphertext: blob.ciphertext
                )
            }
        }

        let request = UpdateAlertRuleRequest(
            isActive: isActive,
            notifyPush: notifyPush,
            notifyEmail: notifyEmail,
            notifySms: nil,
            cooldownMinutes: cooldownMinutes,
            encryptedConditions: encryptedConditions,
            // Only when sealing failed: an unsealed threshold beats an edit that
            // silently keeps the old one.
            conditions: encryptedConditions == nil
                ? threshold.map { AlertRuleConditions(threshold: $0) }
                : AlertRuleConditions(threshold: nil)
        )
        _ = try await api.updateAlertRule(ruleId: rule.id, request: request)
        await refresh()
    }

    func deleteRule(_ rule: AlertRuleResponse) async throws {
        _ = try await api.deleteAlertRule(ruleId: rule.id)
        rules.removeAll { $0.id == rule.id }
    }
}
