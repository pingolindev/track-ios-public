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

/// Queuing what a person just asked for, refused only because this iPhone is
/// behind in the circle. The screen then returns as if it had succeeded, and
/// the pending line shows at once where the finished thing would appear.
enum PendingChanges {
    /// Something a waiting change needs on this device isn't ready yet (e.g.
    /// the device's registration): it waits, with backoff, bounded by its age.
    struct NotReady: Error, Equatable {}

    /// Refused at once, nothing queued (item 36).
    struct TooManyWaiting: LocalizedError, Equatable {
        let circleName: String
        var errorDescription: String? { PendingChangeCopy.tooManyWaiting(circle: circleName) }
    }

    /// Queue a change for the signed-in account. `expiresAt` defaults to the
    /// kind's age limit; `subject` is the name its lines use.
    /// `addressUnchecked`: an invitation or renewal kept because its address
    /// couldn't be checked, not because this iPhone is behind.
    @MainActor
    @discardableResult
    static func queue(_ kind: PendingChange.Kind, circleId: String, inputs: PendingChange.Inputs,
                      seen: PendingChange.Seen = PendingChange.Seen(), subject: String? = nil,
                      member: String? = nil, expiresAt: Date? = nil, addressUnchecked: Bool = false,
                      now: Date = Date(), store: PendingChangeStore? = nil) throws -> PendingChange {
        let store = store ?? .shared
        guard let account = AuthManager.shared.userId?.lowercased() else {
            throw CircleManager.CircleError.keyNotCurrent
        }
        let circleName = CircleManager.shared.circles.first {
            $0.id.caseInsensitiveCompare(circleId) == .orderedSame
        }?.readableName
        var change = make(kind, account: account, circleId: circleId, inputs: inputs, seen: seen,
                          circleName: circleName, subject: subject, expiresAt: expiresAt, now: now)
        change.labels.member = member
        change.addressUnchecked = addressUnchecked ? true : nil
        change.versionAtTap = CircleManager.shared.heldVersion(for: circleId)
        switch store.queue(change, now: now) {
        case .queued(let queued), .merged(let queued):
            PendingChangeRunner.log.info("queued \(kind.rawValue, privacy: .public) \(queued.id, privacy: .public)")
            return queued
        case .tooMany:
            throw TooManyWaiting(circleName: circleName ?? "this circle")
        }
    }

    /// A signed statement's id couldn't be saved before its request: nothing
    /// went out (this fails closed).
    struct NotSaved: Error, Equatable {}

    /// Signing needs this device's signing key, which only the password puts
    /// back: the change says "Waiting for your password".
    struct NeedsPassword: Error, Equatable {}

    /// A waiting "Let them in" whose admission is stored, but whose choice
    /// couldn't be saved here: it waits, and its next run only records the
    /// choice (`.letIn`).
    struct ChoiceNotSaved: Error, Equatable {}

    /// An invitation's or a renewal's address couldn't be checked: nothing
    /// was signed or sent, and it waits as any waiting change does, bounded
    /// by its age.
    struct AddressNotChecked: Error, Equatable {}

    /// The directory named the address's account by an id in some other form
    /// than its one form (`CanonicalId`). That is no answer, as when the
    /// address couldn't be checked, never "no account".
    struct AnswerNotReadable: Error, Equatable {}

    /// Pure, for tests: whether a failed address check means it couldn't be
    /// done: the server's 503 `lookup_unavailable`, offline, a timeout (408
    /// included), a 5xx, too many requests (429, after the retries
    /// `APIService` makes), an answer whose account id isn't in its one form,
    /// no answer at all. A real answer, such as "no account", never is: it
    /// isn't a failure.
    static func addressCouldNotBeChecked(_ error: Error) -> Bool {
        if error is URLError || error is AnswerNotReadable { return true }
        guard let api = error as? APIError else { return false }
        let codes = [api.code, api.errorCode].compactMap { $0 }
        return codes.contains { code in
            ["lookup_unavailable", "network_error", "circuit_open", "server_error", "internal_error",
             "http_408", "http_429", "rate_limited", "rate_limit_exceeded"].contains(code)
                || code.hasPrefix("http_5")
        }
    }

    /// The statement a waiting change's run just signed, saved on disk
    /// BEFORE its request goes out, with whom an invitation to an account
    /// names. Throws, and nothing may go out, when it can't be, or when the
    /// change already has `PendingChangeRunner.maxSignedIds`.
    @MainActor
    static func keepSigned(_ statement: MembershipStatement, for change: PendingChange,
                           store: PendingChangeStore? = nil) throws {
        let store = store ?? .shared
        let invitation = statement.kind == .invitationToAccount
            ? statement.subjectUserId.map { PendingChange.SignedInvitation(subjectUserId: $0, expiresAt: statement.expiresAt) }
            : nil
        guard store.keepSigned(statement.statementId, invitation: invitation, changeId: change.id,
                               limit: PendingChangeRunner.maxSignedIds) else { throw NotSaved() }
    }

    /// A new change, waiting (pure, for tests).
    static func make(_ kind: PendingChange.Kind, account: String, circleId: String, inputs: PendingChange.Inputs,
                     seen: PendingChange.Seen = PendingChange.Seen(), circleName: String? = nil,
                     subject: String? = nil, expiresAt: Date? = nil, now: Date = Date()) -> PendingChange {
        PendingChange(
            id: UUID().uuidString.lowercased(), account: account.lowercased(), circleId: circleId, kind: kind,
            inputs: inputs, seen: seen, signedIds: [], createdAt: now,
            expiresAt: min(expiresAt ?? .distantFuture, now.addingTimeInterval(kind.ageLimit)),
            state: .waiting, attempts: 0, nextAttemptAt: nil, lastOutcome: nil, mayHaveGoneOut: false,
            labels: .init(circleName: circleName, subject: subject))
    }
}
