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

/// Circle ownership succession — the client half of the server's ownership
/// claims.
///
/// A circle has exactly one owner, and only that person can delete it, hand it
/// on, or change anybody's role. An owner who becomes unreachable freezes all
/// three permanently, and nobody can undo that from the server side either. So
/// an active admin can open a *claim*: the owner is told at once, by push, by an
/// in-app notification row and by email, and one action refuses it for good.
/// Silence for the whole window — fourteen days, stored per row so the
/// countdown cannot move under the person watching it — is what completes it.
///
/// That last sentence is why this exists on the client at all: the owner's
/// push tells them to "open Pingolin to refuse", so the app must offer the
/// refuse control.
@MainActor
final class OwnershipClaimManager: ObservableObject {
    static let shared = OwnershipClaimManager()

    /// circleId → the live claim on it. Absent means either "no claim" or "not
    /// looked yet"; `checked` is what tells those apart.
    @Published private(set) var claims: [String: OwnershipClaimResponse] = [:]

    /// Circles whose claim state has been read successfully at least once. A
    /// failed read deliberately does NOT land here, so "we could not ask" never
    /// gets rendered as "there is nothing to worry about".
    @Published private(set) var checked: Set<String> = []

    /// Circles with a claim call in flight, so a row can disable itself rather
    /// than let a second tap open or refuse twice.
    @Published private(set) var busy: Set<String> = []

    private let api = APIService.shared

    private init() {}

    // MARK: - Reads

    /// Read the live claim on one circle. Never throws: this runs on the
    /// appearance of an ordinary screen, and an offline phone must not raise an
    /// error over a circle that is perfectly fine.
    ///
    /// A failure leaves both `claims` and `checked` untouched, so the next
    /// appearance retries and the screen shows nothing rather than an assurance
    /// nobody verified.
    func refresh(circleId: String) async {
        do {
            let claim = try await api.getOwnershipClaim(circleId: circleId)
            apply(claim, to: circleId)
            checked.insert(circleId)
        } catch {
            print("[Track] ownership claim read failed for \(circleId): \(error)")
        }
    }

    /// Read several circles at once — the Circles tab, where a claim on any of
    /// them needs to be visible without opening each in turn. The notification
    /// that announces a claim can be swiped away; the list cannot.
    func refresh(circleIds: [String]) async {
        await withTaskGroup(of: Void.self) { group in
            for id in circleIds {
                group.addTask { await self.refresh(circleId: id) }
            }
        }
    }

    /// The live claim on a circle, or nil. Nil covers both "none" and "not
    /// looked yet" — for rendering they are the same, and `checked` is there
    /// for anything that needs the difference.
    func claim(for circleId: String) -> OwnershipClaimResponse? {
        guard let claim = claims[circleId], claim.isPending else { return nil }
        return claim
    }

    // MARK: - Writes

    /// The owner's veto. Permanent: a refused claim is never reopened, and the
    /// admin has to open a new one, which notifies the owner again.
    func refuse(circleId: String) async throws {
        busy.insert(circleId)
        defer { busy.remove(circleId) }
        try await api.refuseOwnershipClaim(circleId: circleId)
        // The server has already flipped the row to 'refused'; drop it locally
        // rather than re-reading, so the banner goes at once even offline-ish.
        claims.removeValue(forKey: circleId)
        checked.insert(circleId)
    }

    /// Ask to take over a circle. Admin-only server-side, and deliberately not
    /// pre-judged here — the server is the authority and its refusal is what
    /// the caller shows.
    @discardableResult
    func open(circleId: String) async throws -> OwnershipClaimResponse {
        busy.insert(circleId)
        defer { busy.remove(circleId) }
        let claim = try await api.claimOwnership(circleId: circleId)
        apply(claim, to: circleId)
        checked.insert(circleId)
        return claim
    }

    /// The claimant changing their mind, which is a different fact from the
    /// owner refusing and stays distinguishable on the server forever after.
    func withdraw(circleId: String) async throws {
        busy.insert(circleId)
        defer { busy.remove(circleId) }
        try await api.withdrawOwnershipClaim(circleId: circleId)
        claims.removeValue(forKey: circleId)
        checked.insert(circleId)
    }

    /// Drop everything on logout. The rows name a circle and the user id of
    /// whoever is claiming it — account-scoped identifiers that must not
    /// survive into the next account on this device.
    func reset() {
        claims.removeAll()
        checked.removeAll()
        busy.removeAll()
    }

    #if DEBUG
    /// Seed local state without a server, so the transitions this class exists
    /// for can be tested: a claim that shows, a resolved one that must NOT
    /// leave a countdown on screen, and a reset that takes both. Every path in
    /// here otherwise runs through `APIService.shared`, whose URLSession has no
    /// stub in this suite. Debug-only — Release cannot reach it.
    func seedForTesting(circleId: String, claim: OwnershipClaimResponse?) {
        apply(claim, to: circleId)
        checked.insert(circleId)
    }
    #endif

    // MARK: - Internals

    /// Store a claim, or clear the circle when the server says there is none or
    /// the row has already resolved. Keeping a resolved row would leave a
    /// countdown on screen for a claim that is over.
    private func apply(_ claim: OwnershipClaimResponse?, to circleId: String) {
        if let claim, claim.isPending {
            claims[circleId] = claim
        } else {
            claims.removeValue(forKey: circleId)
        }
    }
}

// MARK: - Failure copy

/// Turning the server's refusals into something a person can act on.
///
/// The client deliberately does not decide who may open or refuse a claim — the
/// server does, and its answer is the one that counts. But `forbidden` and
/// `not_found` carry generic strings ("Insufficient permissions"), and an
/// `APIError` rendered as `message [code]` would show the honest-but-useless
/// "Insufficient permissions [http_403]" at the exact moment someone's circle
/// is stuck. Known answers get words; everything else gets the error's plain
/// line — never the server's own sentence.
///
/// Pure and free of UI so the wording can be pinned by tests.
enum OwnershipClaimCopy {

    /// `POST /circles/:id/claim-ownership`.
    static func openFailure(_ error: Error) -> String {
        guard let api = error as? APIError else { return error.plainText }
        // The server's 409 for a claim that is already live — two admins
        // racing, or one admin who already asked. The machine code arrives
        // in both fields, so match either.
        if api.errorCode == "circle_ownership_claim_exists"
            || api.code == "circle_ownership_claim_exists" {
            // The screen re-reads the claim straight after this error
            // (`OwnershipClaimViews.open`), so there is nothing to do but look.
            return "Somebody has already asked to take over this circle. "
                + "Their request now shows on this circle."
        }
        switch api.code {
        case "http_400":
            // The server's one 400 for a claim: the caller owns the circle.
            return "You already own this circle."
        case "http_403":
            // The server requires an admin and answers "Insufficient permissions".
            return "Only an admin can ask to take over a circle — somebody the owner "
                + "already trusted to remove members. "
                + "Ask another admin, or ask the owner to make you one."
        case "http_404":
            // Deliberately vague on the server's side: "Circle not found or
            // you're not a member" is one answer for two cases so that
            // membership cannot be probed. Say both.
            return "This circle isn't there any more, or you're no longer a member of it."
        default:
            return api.plainLine
        }
    }

    /// `POST /circles/:id/claim-ownership/refuse`.
    static func refuseFailure(_ error: Error) -> String {
        guard let api = error as? APIError else { return error.plainText }
        switch api.code {
        case "http_404":
            // The server only answers 404 after confirming the caller IS the
            // owner, so "the circle is still yours" is a fact here, not a
            // reassurance — and it is the thing the person actually wants to
            // know after tapping Refuse and seeing an error.
            return "There's no longer a request to take over this circle — it may have been "
                + "withdrawn, or you may have refused it already. The circle is still yours."
        case "http_403":
            // Ownership is checked inside the UPDATE, so this means the circle
            // is not theirs at the moment they tapped.
            // Re-read straight after this error too (`refuse()`).
            return "Only the circle's owner can refuse this request. If the circle was yours, "
                + "ownership may have already changed. This screen now shows where it stands."
        default:
            return api.plainLine
        }
    }

    /// `DELETE /circles/:id/claim-ownership`.
    static func withdrawFailure(_ error: Error) -> String {
        guard let api = error as? APIError else { return error.plainText }
        switch api.code {
        case "http_404":
            return "You have no request outstanding on this circle. The owner may have "
                + "refused it, or it may have already gone through."
        default:
            return api.plainLine
        }
    }
}

// MARK: - Who may ask

/// Whether the "Ask to take over this circle" control is shown at all.
///
/// The server stays the authority — it refuses everybody but an admin — but a
/// control a plain member can tap only to be told no is a broken control, and
/// the Android app shows it to admins only too (`btnClaimOwnership`). So the
/// roster decides what is SHOWN and the server decides what is ALLOWED: an
/// admin who is not the owner, with no claim already live. A roster that has
/// not loaded yet reads as "not an admin" — the row appears once it has, which
/// is the moment the members list above it fills in.
enum OwnershipClaimAccess {
    static func canOpen(
        viewerIsOwner: Bool,
        viewerRole: CircleMember.MemberRole?,
        hasLiveClaim: Bool
    ) -> Bool {
        !viewerIsOwner && viewerRole == .admin && !hasLiveClaim
    }
}

// MARK: - Presentation

/// Everything a screen needs to say about one live claim, derived from the
/// claim, who is looking at it, and what the roster calls the claimant.
///
/// Pure and Equatable on purpose: the wording is the feature. What the owner is
/// told here is the only thing standing between them and a circle that changes
/// hands because they did not understand a notification, so the sentences are
/// pinned by tests rather than left to a view body.
struct OwnershipClaimPresentation: Equatable {
    /// Who is reading. The owner is the only one who can refuse; the claimant
    /// is the only one who can withdraw; everybody else in the circle sees it
    /// and can do neither — which is the point of the GET being readable by any
    /// active member.
    enum Viewer: Equatable {
        case owner
        case claimant
        case member
    }

    let viewer: Viewer
    let title: String
    let message: String
    /// When silence completes the claim, already parsed. nil when the server
    /// sent no usable timestamp — the wording drops the date rather than
    /// inventing one.
    let deadline: Date?
    /// The deadline written out in the device's locale and timezone, or nil
    /// alongside `deadline`.
    let deadlineText: String?
    var showsRefuse: Bool { viewer == .owner }
    var showsWithdraw: Bool { viewer == .claimant }

    /// Long date in the device's own timezone. The wire timestamp is UTC, and
    /// an owner in Auckland reading a UTC date could be a whole day out on when
    /// their circle changes hands.
    static func format(deadline: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = timeZone
        f.dateStyle = .long
        f.timeStyle = .none
        return f.string(from: deadline)
    }

    /// Whole days left, floored at zero. Counted in LOCAL calendar days, the
    /// unit the sentence is written in — an hours-based count reads "0 days"
    /// for most of the final day.
    static func daysRemaining(until deadline: Date, from now: Date, calendar: Calendar = .current) -> Int {
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: now),
            to: calendar.startOfDay(for: deadline)
        ).day ?? 0
        return max(0, days)
    }

    /// Build the presentation, or nil when there is nothing live to show.
    ///
    /// - Parameters:
    ///   - claim: the row from `GET /circles/:id/claim-ownership`.
    ///   - viewerUserId: the reader's own user id, for spotting their own claim.
    ///   - viewerIsOwner: the server's `is_owner` for this circle. Authoritative,
    ///     and checked FIRST — the refuse button has to follow ownership, not a
    ///     roster role the client happens to have cached.
    ///   - claimantName: the claimant's display name from the roster, when the
    ///     roster has been loaded and holds one. nil is expected, not an error:
    ///     display names come from the auth service, which answers a failure
    ///     with an empty user list.
    static func make(
        claim: OwnershipClaimResponse,
        viewerUserId: String?,
        viewerIsOwner: Bool,
        claimantName: String?,
        now: Date = Date(),
        locale: Locale = .current,
        timeZone: TimeZone = .current,
        calendar: Calendar = .current
    ) -> OwnershipClaimPresentation? {
        guard claim.isPending else { return nil }

        let viewer: Viewer
        if viewerIsOwner {
            viewer = .owner
        } else if let me = viewerUserId, let them = claim.claimantUserId, me == them {
            viewer = .claimant
        } else {
            viewer = .member
        }

        let deadline = claim.deadline
        let deadlineText = deadline.map { format(deadline: $0, locale: locale, timeZone: timeZone) }
        // A blank display name is what an unresolved roster entry looks like,
        // and "" reads as a missing word mid-sentence rather than as a name.
        let name = claimantName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let who = (name?.isEmpty == false) ? name! : nil

        switch viewer {
        case .owner:
            return OwnershipClaimPresentation(
                viewer: .owner,
                title: "Someone asked to take over this circle",
                message: ownerMessage(who: who, deadlineText: deadlineText, deadline: deadline, now: now, calendar: calendar),
                deadline: deadline,
                deadlineText: deadlineText
            )
        case .claimant:
            return OwnershipClaimPresentation(
                viewer: .claimant,
                title: "You asked to take over this circle",
                message: claimantMessage(deadlineText: deadlineText),
                deadline: deadline,
                deadlineText: deadlineText
            )
        case .member:
            return OwnershipClaimPresentation(
                viewer: .member,
                title: "This circle may change owner",
                message: memberMessage(who: who, deadlineText: deadlineText),
                deadline: deadline,
                deadlineText: deadlineText
            )
        }
    }

    /// The sentence the whole feature exists for. It has to say four things:
    /// what is being taken, by whom, when, and what refusing does. It also has
    /// to say what ownership actually IS, because most owners have never had to
    /// think about it — and the answer ("delete it, hand it on, decide who is an
    /// admin") is the only way to judge whether losing it matters.
    private static func ownerMessage(
        who: String?,
        deadlineText: String?,
        deadline: Date?,
        now: Date,
        calendar: Calendar
    ) -> String {
        let asker = who.map { "\($0), an admin in this circle," } ?? "An admin in this circle"
        var s = "\(asker) has asked to become its owner. "
        s += "Owning a circle is what lets you delete it, hand it to somebody else, "
        s += "and decide who is an admin.\n\n"
        if let deadlineText, let deadline {
            let days = daysRemaining(until: deadline, from: now, calendar: calendar)
            let left: String
            switch days {
            case 0: left = "today"
            case 1: left = "tomorrow"
            default: left = "in \(days) days"
            }
            s += "If you do nothing, ownership passes to them on \(deadlineText) — \(left). "
        } else {
            s += "If you do nothing, ownership passes to them when the request runs out. "
        }
        // What SURVIVES the transfer, said out loud. The obvious wording — "you
        // would become an ordinary member" — is false: the server's settlement
        // moves the outgoing owner to admin with can_rotate_keys, deliberately
        // ("they are unreachable, not untrusted"). Getting this wrong overstates
        // the loss, and overstating it on a fourteen-day deadline is the wrong
        // direction to be wrong in.
        s += "You would stay an admin, so you could still remove members — but deleting "
        s += "the circle and handing it on would no longer be yours to do.\n\n"
        s += "Refusing keeps the circle yours and ends this request permanently. "
        s += "Nobody leaves the circle either way, and nothing changes about what anyone can see."
        return s
    }

    private static func claimantMessage(deadlineText: String?) -> String {
        var s = "The owner has been told and can refuse at any time. "
        if let deadlineText {
            s += "If they do nothing, you become the owner on \(deadlineText). "
        } else {
            s += "If they do nothing, you become the owner when the request runs out. "
        }
        s += "You can withdraw the request until then."
        return s
    }

    private static func memberMessage(who: String?, deadlineText: String?) -> String {
        let asker = who.map { "\($0), an admin in this circle," } ?? "An admin in this circle"
        var s = "\(asker) has asked to become its owner. The owner has been told and can refuse. "
        if let deadlineText {
            s += "If they do nothing, this circle has a new owner on \(deadlineText)."
        } else {
            s += "If they do nothing, this circle gets a new owner when the request runs out."
        }
        return s
    }
}
