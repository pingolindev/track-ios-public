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

/// After a password reset, the records an owner or admin would sign carry
/// keys the circle's chain doesn't count yet, so every key change its device
/// builds is refused ("the plan includes members not eligible here"). Its
/// own device signs and uploads its own admission of its CURRENT keys. The
/// chain counts it once the server serves it in this account's row, and on
/// another device once that device's person has confirmed those keys. No
/// record is built before it is served.
enum SelfAdmission {
    /// This account's own row under the SDK's eligibility rule (`.include`),
    /// as this device read it.
    enum OwnRow: Equatable {
        case counted
        case notCounted
        /// No answer: the circle's records not imported in this process
        /// or forked (a forked chain reads every row not eligible), no member
        /// rows, or the read threw. Never due, never counted.
        case notKnown
    }

    /// An answer only from a read that returned, on a circle imported
    /// here and not forked, with this account's row in it.
    nonisolated static func ownRow(importedNotForked: Bool, me: String,
                                   read: () throws -> [MemberEligibility]) -> OwnRow {
        guard importedNotForked, let rows = try? read(),
              let mine = rows.first(where: { CanonicalId.same($0.userId, me) }) else { return .notKnown }
        return mine.eligible ? .counted : .notCounted
    }

    /// Due exactly when its own row ANSWERED "not counted", the server lists
    /// this account as owner or admin, and this device holds the key in use
    /// (the admission carries the version it seals under, and the server takes
    /// only the circle's current one). Never on a gate that holds the rotation
    /// step (`holdsCurrentKey`): the step waits for this admission.
    nonisolated static func due(ownRow: OwnRow, listedOwnerOrAdmin: Bool, holdsKeyInUse: Bool) -> Bool {
        ownRow == .notCounted && listedOwnerOrAdmin && holdsKeyInUse
    }

    /// On a circle whose records this process imported, a key change is built
    /// only once the SDK counts this account's own row (the SDK would refuse
    /// it otherwise); no answer is no. Other circles are decided elsewhere
    /// (`rotationMode`).
    nonisolated static func keyChangesMayBuild(standing: CircleManager.RecordsStanding, ownRow: OwnRow) -> Bool {
        standing != .recorded || ownRow == .counted
    }

    /// Receive-only: the statement rule (`MembershipConfirmation`), lifted
    /// exactly when the SDK counts this account's own row; never because a
    /// statement binds its current keys.
    nonisolated static func receiveOnly(statementRule: Bool, ownRow: OwnRow) -> Bool {
        statementRule && ownRow != .counted
    }

    // MARK: - The retry rule

    enum Outcome: String, Codable, Equatable {
        /// 200: done for that key version.
        case stored
        /// 403 (not owner or admin on the server): done until the listed role
        /// or the key version changes.
        case refused
        /// Any other 4xx, a 5xx, a 429 or no answer: again after `retryAfter`.
        /// While the circle is due nothing else moves its version, so a passing
        /// failure must not end it.
        case failed
    }

    struct Attempt: Codable, Equatable {
        let keyVersion: Int
        let role: String
        let outcome: Outcome
        let at: Date
    }

    nonisolated static let retryAfter: TimeInterval = 600

    nonisolated static func mayAttempt(_ last: Attempt?, keyVersion: Int, role: String, now: Date) -> Bool {
        guard let last, last.keyVersion == keyVersion else { return true }
        switch last.outcome {
        case .stored: return false
        case .refused: return last.role != role
        case .failed: return now.timeIntervalSince(last.at) >= retryAfter
        }
    }

    /// The outcome of one upload: nil is the server's 200.
    nonisolated static func outcome(_ error: Error?) -> Outcome {
        guard let error else { return .stored }
        guard let api = error as? APIError else { return .failed }
        return api.code == "http_403" || api.code == "forbidden" ? .refused : .failed
    }

    // MARK: - Kept per account (AccountKeyedDefaults)

    nonisolated static let prefix = "selfAdmission.attempts."

    nonisolated static func attempts(owner: String, defaults: UserDefaults = .standard) -> [String: Attempt] {
        guard let data = defaults.data(forKey: prefix + owner.lowercased()),
              let all = try? JSONDecoder().decode([String: Attempt].self, from: data) else { return [:] }
        return all
    }

    nonisolated static func lastAttempt(circleId: String, owner: String, defaults: UserDefaults = .standard) -> Attempt? {
        attempts(owner: owner, defaults: defaults)[CanonicalId.key(circleId)]
    }

    nonisolated static func note(_ attempt: Attempt, circleId: String, owner: String, defaults: UserDefaults = .standard) {
        var all = attempts(owner: owner, defaults: defaults)
        all[CanonicalId.key(circleId)] = attempt
        guard let data = try? JSONEncoder().encode(all) else { return }
        defaults.set(data, forKey: prefix + owner.lowercased())
    }
}
