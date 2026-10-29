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

/// Every line a waiting change shows, used exactly as worded here. The item
/// numbers in the comments below number those lines. {device} is "iPhone"
/// here. Nothing here talks about keys, and nothing ever shows a server's own
/// text.
enum PendingChangeCopy {
    static let device = "iPhone"

    // MARK: - Waiting (in place, with the "Waiting to sync" tag and Cancel)

    static let tag = "Waiting to sync"

    /// Items 1–15: the pending line, by kind.
    static func waiting(_ change: PendingChange) -> String {
        let circle = circleName(change)
        let subject = change.labels.subject
        switch change.inputs {
        case .invite(let inputs) where change.addressUnchecked == true:
            // The line for an address that couldn't be checked.
            return "Waiting to sync. \(inputs.email) will be invited as soon as Pingolin can check the address."
        case .invite(let inputs):
            return "Waiting to sync. \(inputs.email) will be invited as soon as this \(device) catches up."          // 1
        case .makeAdmin:
            return "Waiting to sync. \(subject ?? "They") will be made an admin as soon as this \(device) catches up." // 2
        case .letIn:
            return "Waiting to sync. \(subject ?? "They") will be let in as soon as this \(device) catches up."      // 3
        case .renewInvitation(let inputs) where change.addressUnchecked == true:
            // The same line for a renewal.
            return "Waiting to sync. \(inputs.email)'s invitation will be renewed as soon as Pingolin can check the address."
        case .renewInvitation(let inputs):
            return "Waiting to sync. \(inputs.email)'s invitation will be renewed as soon as this \(device) catches up." // 4
        case .checkIn:
            return "Waiting to sync. Your check-in will be sent as soon as this \(device) catches up, with the time you checked in." // 5
        case .destination(let inputs):
            let name = inputs.name.flatMap { $0.isEmpty ? nil : $0 } ?? "Your destination"
            return "Waiting to sync. \(name) will be shared with \(circle) as soon as this \(device) catches up."     // 6
        case .arrived:
            return "Waiting to sync. Your arrival will be sent as soon as this \(device) catches up."               // 7
        case .sharePlace:
            return "Waiting to sync. \(subject ?? "This place") will be shared with \(circle) as soon as this \(device) catches up." // 9
        case .editPlace:
            return "Waiting to sync. Your changes to \(subject ?? "this place") will be saved as soon as this \(device) catches up." // 12
        case .memberPlaceAlert, .batteryAlert, .inactivityAlert:
            return "Waiting to sync. This alert will be set up as soon as this \(device) catches up."               // 13
        case .alertChange:
            return "Waiting to sync. Your changes to this alert will be saved as soon as this \(device) catches up." // 14
        case .renameCircle(let newName):
            return "Waiting to sync. \(circle) will be renamed to \"\(newName)\" as soon as this \(device) catches up." // 15
        }
    }

    // MARK: - A pending item's state

    static let sending = "Sending…"                        // 17
    static let cancelling = "Cancelling…"                  // 18
    static let waitingForPassword = "Waiting for your password" // 19

    // MARK: - On the circle's "Waiting to sync" notice

    /// Item 20.
    static func count(_ n: Int) -> String {
        "\(n) \(n == 1 ? "change" : "changes") waiting to go out from this \(device)"
    }

    // MARK: - Not done (one line replaces the pending item)

    /// {what}: the pending line's own subject, per kind, the same in every
    /// Track app.
    static func what(_ change: PendingChange) -> String {
        let subject = change.labels.subject
        switch change.inputs {
        case .invite(let inputs): return "\(inputs.email)'s invitation"
        case .makeAdmin: return "Making \(subject ?? "them") an admin"
        case .letIn: return "Letting \(subject ?? "them") in"
        case .renewInvitation(let inputs): return "Renewing \(inputs.email)'s invitation"
        case .checkIn: return "Your check-in"
        case .destination: return "Your destination"
        case .arrived: return "Your arrival"
        case .sharePlace: return "Sharing \(subject ?? "this place")"
        case .editPlace: return "Your changes to \(subject ?? "this place")"
        case .memberPlaceAlert, .batteryAlert, .inactivityAlert: return "This alert"
        case .alertChange: return "Your changes to this alert"
        case .renameCircle: return "Renaming \(circleName(change))"
        }
    }

    /// {what} with a lower-case first letter mid-sentence, for item 35 ("your
    /// check-in"): only this app's own leading word, never a name or an email.
    static func whatLower(_ change: PendingChange) -> String {
        let text = what(change)
        let ownWords = ["Your ", "This ", "Making ", "Letting ", "Renewing ", "Sharing ", "Renaming "]
        guard ownWords.contains(where: { text.hasPrefix($0) }) else { return text }
        return text.prefix(1).lowercased() + text.dropFirst()
    }

    /// Item 21.
    static func tooOld(_ change: PendingChange) -> String {
        "\(what(change)) wasn't done: this \(device) took too long to catch up."
    }

    /// Item 22.
    static func alreadyMember(email: String, circle: String) -> String { "\(email) is already in \(circle)." }
    static func alreadyInvited(email: String, circle: String) -> String {
        "\(email) already has an invitation to \(circle)."
    }
    static func alreadyLetIn(name: String) -> String { "\(name) was already let in." }
    static func alreadyShared(place: String, circle: String) -> String { "\(place) is already shared with \(circle)." }

    /// Item 23.
    static func memberLeft(_ change: PendingChange, name: String) -> String {
        "\(what(change)) wasn't done: \(name) is no longer in \(circleName(change))."
    }

    /// Item 24.
    static func invitationEnded(email: String) -> String {
        "\(email)'s invitation wasn't renewed: it was withdrawn or ran out."
    }

    /// Item 25: {thing} is "{place}", "the destination" or "the alert".
    static func deleted(_ change: PendingChange, thing: String) -> String {
        "\(what(change)) wasn't done: \(thing) was deleted."
    }

    /// Item 26.
    static func placeChangedElsewhere(place: String) -> String {
        "Your changes to \(place) weren't saved: it was changed on another device in the meantime."
    }
    /// Item 26's form for a change to an alert.
    static let alertChangedElsewhere =
        "Your change to this alert wasn't saved: it was changed on another device in the meantime."
    static func renamedElsewhere(circle: String, to name: String) -> String {
        "\(circle) wasn't renamed: it was renamed to \"\(name)\" in the meantime."
    }

    /// Item 27.
    static func notOwnerOrAdmin(_ change: PendingChange) -> String {
        "\(what(change)) wasn't done: you're no longer an owner or admin of \(circleName(change))."
    }

    /// Item 28.
    static func limitReached(_ change: PendingChange, limit: Int, things: String) -> String {
        "\(what(change)) wasn't done: \(circleName(change)) has reached its limit of \(limit) \(things) on the free plan."
    }

    /// Item 29.
    static func circleGone(_ change: PendingChange) -> String {
        "\(what(change)) wasn't done: \(circleName(change)) no longer exists."
    }

    /// Item 30.
    static func detailsKeepChangingInvite(email: String) -> String {
        "Their details keep changing, so \(email) wasn't invited."
    }
    static func detailsKeepChangingAdmin(name: String) -> String {
        "Their details keep changing, so \(name) wasn't made an admin."
    }
    static func detailsKeepChangingLetIn(name: String) -> String {
        "Their details keep changing, so \(name) wasn't let in."
    }
    /// The renewal's line: the same text as
    /// `InvitationRenewals.changedTwiceText`.
    static let detailsKeepChangingRenewal = "Their details keep changing, so the invitation wasn't renewed."

    /// Item 32: any other refusal, never the server's own text.
    static func notDone(_ change: PendingChange) -> String { "\(what(change)) wasn't done." }

    /// The server's cap on invitation e-mails (`invite_limit_reached`).
    static func inviteLimitReached(_ change: PendingChange) -> String {
        "\(what(change)) wasn't done. \(APIError.inviteLimitText)"
    }

    // MARK: - Cancel after a lost answer

    /// Item 34.
    static func alreadyWentOut(_ change: PendingChange) -> String {
        "\(what(change)) had already gone out, so it couldn't be cancelled."
    }

    /// Item 35.
    static func mayHaveGoneOut(_ change: PendingChange) -> String {
        "Cancelled, but \(whatLower(change)) may already have gone out. If it did, it shows as usual."
    }

    // MARK: - Refused at once, sign-out, removal

    /// Item 36.
    static func tooManyWaiting(circle: String) -> String {
        "Not done: 20 changes are already waiting to go out for \(circle) from this \(device)."
    }

    /// Item 37.
    static func signOutLine(_ n: Int) -> String {
        "\(n) \(n == 1 ? "change" : "changes") waiting to sync on this \(device) won't be made."
    }

    /// Item 38, followed by the server's existing line, unchanged.
    static func removed(name: String, circle: String, serverLine: String?) -> String {
        let first = "\(name) was removed from \(circle)."
        guard let serverLine, !serverLine.isEmpty else { return first }
        return first + " " + serverLine
    }

    static func circleName(_ change: PendingChange) -> String {
        change.labels.circleName.flatMap { $0.isEmpty ? nil : $0 } ?? "this circle"
    }
}
