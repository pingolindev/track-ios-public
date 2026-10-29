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

import XCTest
@testable import Track

/// Invitation renewal, on the invitee's side.
///
/// An invitation that does not name this account as it is now — the local check
/// that it names this account, or the accept's 409 `invite_out_of_date`, both a
/// change of this account's keys — does not end on "Ask {inviter} to invite you
/// again.": the server is told (or already knows) and wakes who can renew it;
/// once it names this account, this device joins by itself with the yes the
/// person already gave: once per distinct statement, so neither side can be
/// made to loop.
final class InvitationRenewalTests: XCTestCase {

    private func invite(statement: String?, renewal: Bool = false) throws -> ReceivedInviteResponse {
        var json: [String: Any] = [
            "id": "11111111-1111-4111-8111-111111111111", "circle_id": "22222222-2222-4222-8222-222222222222",
            "invited_by": "33333333-3333-4333-8333-333333333333", "invite_type": "email",
            "created_day_bucket": 20_000, "expires_day_bucket": 20_007, "has_encrypted_key": false,
            "inviter_display_name": "Ana",
        ]
        if let statement { json["statement"] = statement }
        if renewal { json["renewal_requested"] = true }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ReceivedInviteResponse.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func wait(tried: String?, reported: Bool = true) -> InvitesManager.RenewalWait {
        InvitesManager.RenewalWait(inviteId: "11111111-1111-4111-8111-111111111111",
                                   circleId: "22222222-2222-4222-8222-222222222222",
                                   noticeVersion: "1.1", triedStatement: tried, reported: reported)
    }

    func testTheRosterOfInvitationsSaysWhichAreBeingRenewed() throws {
        XCTAssertEqual(try invite(statement: "aa", renewal: true).renewalRequested, true)
        XCTAssertNil(try invite(statement: "aa").renewalRequested, "absent when false")
    }

    /// What one refresh does about one invitation this person already said yes to.
    func testEachRefreshTakesOneStep() throws {
        let tried = InvitesManager.statementHash("AABB")
        XCTAssertEqual(InvitesManager.renewalStep(wait(tried: tried), invite: nil), .forget,
                       "withdrawn, declined elsewhere or expired")
        XCTAssertEqual(InvitesManager.renewalStep(wait(tried: tried), invite: try invite(statement: "aabb")), .wait,
                       "not renewed yet (the hash ignores case)")
        XCTAssertEqual(InvitesManager.renewalStep(wait(tried: tried, reported: false), invite: try invite(statement: "aabb")),
                       .reportAgain, "a report that never reached the server goes again")
        XCTAssertEqual(InvitesManager.renewalStep(wait(tried: tried), invite: try invite(statement: "ccdd")), .tryJoin,
                       "renewed: join with the yes already given")
        XCTAssertEqual(InvitesManager.renewalStep(wait(tried: nil), invite: try invite(statement: nil)), .wait,
                       "an unsigned invitation refused by the server waits for a signed one")
        XCTAssertEqual(InvitesManager.renewalStep(wait(tried: nil), invite: try invite(statement: "aabb")), .tryJoin)
    }

    /// The join made by itself carries the yes the person gave at the notice —
    /// joining IS agreeing — and the yes is taken from the accept.
    func testTheJoinMadeByItselfCarriesTheYesGiven() throws {
        XCTAssertEqual(InvitesManager.consent(of: wait(tried: nil))?.version, "1.1")
        var none = wait(tried: nil)
        none.noticeVersion = nil
        XCTAssertNil(InvitesManager.consent(of: none))
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let manager = try String(contentsOf: root.appendingPathComponent("App/Managers/InvitesManager.swift"),
                                 encoding: .utf8)
        let join = try XCTUnwrap(manager.range(of: "private func joinRenewedInvitations() async {"))
        XCTAssertNotNil(manager.range(of: "consent: Self.consent(of: wait),", range: join.upperBound..<manager.endIndex))
        XCTAssertTrue(manager.contains("wait.noticeVersion = consent?.version ?? wait.noticeVersion"))
    }

    /// A try counts once the server has answered; only no answer at all lets the
    /// same statement be tried again.
    func testOnlyNoAnswerLetsTheSameStatementBeTriedAgain() {
        XCTAssertTrue(InvitesManager.nothingAnswered(URLError(.notConnectedToInternet)))
        XCTAssertTrue(InvitesManager.nothingAnswered(APIError(code: "http_503", message: "x")))
        XCTAssertTrue(InvitesManager.nothingAnswered(APIError(code: "circuit_open", message: "x")))
        XCTAssertFalse(InvitesManager.nothingAnswered(APIError(code: "http_400", message: "x")))
        XCTAssertFalse(InvitesManager.nothingAnswered(APIError(code: "invite_out_of_date", message: "x")))
    }

    /// The report or the accept answered `invite_not_renewable` (its sender is
    /// not an owner or admin any more) — one line, no "being renewed", no wait,
    /// no Accept. The same text on Android and the web; a demoted sender is
    /// still in the circle, so it doesn't say they left.
    func testAnInvitationNobodyCanRenewSaysSo() throws {
        XCTAssertEqual(InvitesManager.notRenewableText,
                       "This invitation can't be used any more: the person who sent it can no longer invite people to this circle.")
        XCTAssertFalse(InvitesManager.notRenewableText.contains("no longer in the circle"))
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let manager = try String(contentsOf: root.appendingPathComponent("App/Managers/InvitesManager.swift"), encoding: .utf8)
        let branches = manager.components(separatedBy: "catch let error as APIError where error.isServerCode(\"invite_not_renewable\") {")
            .dropFirst().map { $0.prefix(400) }
        XCTAssertEqual(branches.count, 2, "the report and the accept")
        let fromReport = try XCTUnwrap(branches.first { $0.contains("renewalWaits[inviteId] = nil") })
        XCTAssertTrue(fromReport.contains("notRenewable.insert(inviteId)"))
        let fromAccept = try XCTUnwrap(branches.first { $0.contains("renewalWaits[invite.id] = nil") })
        XCTAssertTrue(fromAccept.contains("notRenewable.insert(invite.id)"))
        XCTAssertTrue(fromAccept.contains("throw InviteAcceptError.refused(Self.notRenewableText)"))
        XCTAssertFalse(fromAccept.contains("waitForRenewal"), "no wait kept")
        XCTAssertTrue(manager.contains("guard !notRenewable.contains(invite.id) else { return }"), "no wait kept")
        XCTAssertTrue(manager.contains("if notRenewable.contains(invite.id) { throw InviteAcceptError.refused(Self.notRenewableText) }"))
        let circles = try String(contentsOf: root.appendingPathComponent("App/Views/Circles/CirclesView.swift"), encoding: .utf8)
        XCTAssertTrue(circles.contains("if !joiningWhenRenewed && !notRenewable {"), "no Accept")
        XCTAssertTrue(circles.contains("Text(InvitesManager.notRenewableText)"))
    }

    func testTheWordsSayWhatHappens() {
        XCTAssertEqual(InvitesManager.beingRenewed(inviter: "Ana"),
                       "This invitation is being renewed. It will work as soon as Ana confirms it's you.")
        XCTAssertEqual(InvitesManager.joinsWhenRenewed(circle: "Family"),
                       "You'll join Family then, with nothing more to do.")
        XCTAssertEqual(InvitesManager.joiningWhenRenewed(inviter: "Ana"), "Joining as soon as Ana confirms it's you.")
        XCTAssertEqual(InvitesManager.beingRenewed(inviter: nil),
                       "This invitation is being renewed. It will work as soon as the circle confirms it's you.",
                       "the Android app's invite_renewing_unknown")
        for text in [InvitesManager.beingRenewed(inviter: "Ana"), InvitesManager.joiningWhenRenewed(inviter: nil)] {
            XCTAssertFalse(text.localizedCaseInsensitiveContains("ask"), text)
            XCTAssertFalse(text.localizedCaseInsensitiveContains("again"), text)
        }
    }

    /// The wiring: the notice is asked first (the join needs that yes), both
    /// refusals wait for the renewal, and the silent wake looks at invitations.
    func testTheRenewalIsWiredEndToEnd() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func source(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }
        let manager = try source("App/Managers/InvitesManager.swift")
        XCTAssertEqual(manager.components(separatedBy:
            "throw InviteAcceptError.renewing(Self.beingRenewed(inviter: invite.inviterDisplayName))").count - 1, 2,
            "the local mismatch and the server's out-of-date both wait for the renewal")
        XCTAssertTrue(manager.contains("await joinRenewedInvitations()"), "every refresh looks")
        XCTAssertFalse(manager.contains("to invite you again"))
        let circles = try source("App/Views/Circles/CirclesView.swift")
        // Only what goes nowhere is refused before the notice; a renewal asks it.
        let refusal = try XCTUnwrap(circles.range(of: "if let refusal = invitesManager.refusal(invite) {"))
        let notice = try XCTUnwrap(circles.range(of: "pendingConsent = PendingLocationConsent("))
        XCTAssertLessThan(refusal.lowerBound, notice.lowerBound)
        XCTAssertTrue(circles.contains("catch InviteAcceptError.renewing(let text)"))
        // What goes nowhere is never reported or waited for.
        let goesNowhere = try XCTUnwrap(manager.range(of: "case let other?:"))
        let block = manager[goesNowhere.upperBound...].prefix(260)
        XCTAssertTrue(block.contains("renewalWaits[invite.id] = nil"))
        XCTAssertFalse(block.contains("report("))
        let push = try source("App/Managers/PushNotificationManager.swift")
        XCTAssertTrue(push.contains("""
                    if InvitesManager.shared.waitsForRenewal {
                        await InvitesManager.shared.refresh()
                    }
"""))
        // A stale lookup is redone and signed again once, inside the
        // inviter's own invite action, and nowhere else.
        let circleManager = try source("App/Managers/CircleManager.swift")
        XCTAssertTrue(circleManager.contains(
            "catch let error as APIError where error.isServerCode(\"invite_lookup_changed\") && !lookupRetried {"))
        XCTAssertEqual(circleManager.components(separatedBy: "invite_lookup_changed").count - 1, 1)
        XCTAssertTrue(circleManager.contains("try await inviteMember(to: circleId, email: email, lookupRetried: true, confirmed: confirmed,\n                                   waiting: waiting)"))
        let api = try source("App/Services/APIService.swift")
        XCTAssertTrue(api.contains("post(path: \"/api/v1/invites/\\(inviteId)/mismatch\", body: EmptyBody())"))
    }

    /// A waiting renewal: someone the circle's records show removed after the
    /// person decided gets nothing signed, and one this device can't judge
    /// yet waits. The check reads the chain after the directory lookup, with
    /// nothing awaited between it and the signature, so an eject taken during
    /// the lookup is seen.
    func testAWaitingRenewalChecksTheChainRightBeforeItSigns() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let renewals = try String(contentsOf: root.appendingPathComponent("App/Managers/InvitationRenewals.swift"),
                                  encoding: .utf8)
        let lookup = try XCTUnwrap(renewals.range(of: "lookup = try await api.lookupPublicKey(email: question.email)"))
        let check = try XCTUnwrap(renewals.range(of: """
                    if let waiting {
                        switch PendingChangeKinds.removedSinceTheTap(
                            CircleManager.shared.removalCheck(userId: question.subjectUserId, circleId: question.circleId),
                            change: waiting, name: question.email) {
                        case .drop(let line)?: throw RenewalError.notDone(line ?? PendingChangeCopy.notDone(waiting))
                        case .notYet?: throw CircleManager.CircleError.waitingToSync
                        default: break
                        }
                    }
            """))
        let signs = try XCTUnwrap(renewals.range(of: "let signed = try crypto.renewInvitation("))
        XCTAssertLessThan(lookup.upperBound, check.lowerBound)
        XCTAssertLessThan(check.upperBound, signs.lowerBound)
        XCTAssertFalse(renewals[check.upperBound..<signs.lowerBound].contains("await"), "nothing awaited in between")
    }
}
