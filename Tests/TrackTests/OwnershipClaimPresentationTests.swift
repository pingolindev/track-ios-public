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

/// What each person in a circle is told about a live ownership claim, and which
/// control they get.
///
/// The wording is the feature. A claim completes on SILENCE — fourteen days of
/// it — so the only thing between an owner and a circle that is no longer
/// theirs is a sentence they read and understood in time. These tests pin that
/// sentence, and pin who can act on it: only the owner may refuse, only the
/// claimant may withdraw, and everybody else in the circle can see it and do
/// neither, which is the whole point of the server making the GET readable by
/// any active member.
final class OwnershipClaimPresentationTests: XCTestCase {

    private let utc = TimeZone(identifier: "UTC")!
    private let locale = Locale(identifier: "en_US_POSIX")

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = utc
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 9, _ min: Int = 0, zone: TimeZone? = nil) -> Date {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone ?? utc
        return c.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }

    private func claim(
        status: String? = "pending",
        claimantUserId: String? = "claimant-1",
        resolvesAt: String? = nil
    ) -> OwnershipClaimResponse {
        OwnershipClaimResponse(
            claimId: "claim-1",
            circleId: "circle-1",
            claimantUserId: claimantUserId,
            status: status,
            requestedAt: iso(date(2026, 8, 23)),
            resolvesAt: resolvesAt ?? iso(date(2026, 9, 6))
        )
    }

    private func make(
        _ claim: OwnershipClaimResponse,
        viewerUserId: String?,
        viewerIsOwner: Bool,
        claimantName: String? = nil,
        now: Date? = nil
    ) -> OwnershipClaimPresentation? {
        OwnershipClaimPresentation.make(
            claim: claim,
            viewerUserId: viewerUserId,
            viewerIsOwner: viewerIsOwner,
            claimantName: claimantName,
            now: now ?? date(2026, 8, 23),
            locale: locale,
            timeZone: utc,
            calendar: calendar
        )
    }

    // MARK: - Who gets which control

    /// The safety-critical half: the owner gets a push reading "Open
    /// Pingolin to refuse", so the app must have the refuse control, and
    /// only the owner gets it.
    func testTheOwnerGetsRefuseAndOnlyRefuse() throws {
        let p = try XCTUnwrap(make(claim(), viewerUserId: "owner-1", viewerIsOwner: true))
        XCTAssertEqual(p.viewer, .owner)
        XCTAssertTrue(p.showsRefuse)
        XCTAssertFalse(p.showsWithdraw, "the owner cannot withdraw a request they did not make")
    }

    func testTheClaimantGetsWithdrawAndOnlyWithdraw() throws {
        let p = try XCTUnwrap(make(claim(), viewerUserId: "claimant-1", viewerIsOwner: false))
        XCTAssertEqual(p.viewer, .claimant)
        XCTAssertTrue(p.showsWithdraw)
        XCTAssertFalse(p.showsRefuse, "refusing is the owner's veto; `refuse_ownership_claim` 403s anyone else")
    }

    /// Any active member can read the claim on purpose: a circle changing hands
    /// is not a private negotiation between two people, because everybody in it
    /// is about to have a different person able to delete it. They get the
    /// facts and no buttons.
    func testEveryOtherMemberSeesItAndCanDoNeither() throws {
        let p = try XCTUnwrap(make(claim(), viewerUserId: "bystander-1", viewerIsOwner: false))
        XCTAssertEqual(p.viewer, .member)
        XCTAssertFalse(p.showsRefuse)
        XCTAssertFalse(p.showsWithdraw)
        XCTAssertFalse(p.message.isEmpty, "seeing it is the point — silence here recreates the secret")
    }

    /// A viewer with no known user id — the keychain read can come back nil —
    /// is a bystander, never mistaken for the claimant.
    func testAnUnknownViewerIsABystanderNotTheClaimant() throws {
        let p = try XCTUnwrap(make(claim(), viewerUserId: nil, viewerIsOwner: false))
        XCTAssertEqual(p.viewer, .member)
    }

    /// The server forbids claiming from yourself, so this cannot happen — but
    /// if ownership ever moved underneath a live claim, the refuse control has
    /// to follow ownership rather than the older fact.
    func testOwnershipWinsOverHavingOpenedTheClaim() throws {
        let p = try XCTUnwrap(make(claim(claimantUserId: "me"), viewerUserId: "me", viewerIsOwner: true))
        XCTAssertEqual(p.viewer, .owner)
        XCTAssertTrue(p.showsRefuse)
    }

    /// Only 'pending' is live. A resolved row must leave nothing on screen —
    /// a countdown for a claim that is over is worse than no countdown.
    func testAResolvedClaimShowsNothingAtAll() {
        for status in ["completed", "refused", "withdrawn", "void"] {
            XCTAssertNil(
                make(claim(status: status), viewerUserId: "owner-1", viewerIsOwner: true),
                "\(status) is over and must not render"
            )
        }
    }

    // MARK: - What the owner is told

    /// Four things, and the sentence is worthless without any of them: what is
    /// being taken, by whom, when, and what refusing does.
    func testTheOwnerMessageAnswersAllFourQuestions() throws {
        let p = try XCTUnwrap(
            make(claim(), viewerUserId: "owner-1", viewerIsOwner: true, claimantName: "Sam Rivera")
        )

        // Who.
        XCTAssertTrue(p.message.contains("Sam Rivera"), "name the person if the roster knows them: \(p.message)")
        // What is being taken — ownership, spelled out, because most owners
        // have never had to think about what owning a circle actually confers.
        XCTAssertTrue(p.message.contains("delete it"), p.message)
        XCTAssertTrue(p.message.contains("who is an admin"), p.message)
        // When.
        let expected = OwnershipClaimPresentation.format(
            deadline: date(2026, 9, 6), locale: locale, timeZone: utc
        )
        XCTAssertTrue(p.message.contains(expected), "the deadline must be a real date: \(p.message)")
        XCTAssertEqual(p.deadlineText, expected)
        // What refusing does.
        XCTAssertTrue(p.message.lowercased().contains("refusing"), p.message)
        XCTAssertTrue(p.message.contains("permanently"), "a refused claim is never reopened: \(p.message)")
    }

    /// The claim removes nobody and changes nothing about visibility — an owner
    /// deciding under time pressure should not have to guess at that.
    func testTheOwnerMessageSaysWhatDoesNotChange() throws {
        let p = try XCTUnwrap(make(claim(), viewerUserId: "owner-1", viewerIsOwner: true))
        XCTAssertTrue(p.message.contains("Nobody leaves the circle"), p.message)
    }

    /// What SURVIVES a transfer. The server makes the outgoing owner an admin
    /// who may still rotate keys, on purpose — they are unreachable, not
    /// untrusted — so the owner keeps member removal, and loses only deleting
    /// the circle and handing it on. Saying so is the difference between a
    /// fair decision and a scared one (in plain words, without mentioning
    /// keys).
    func testTheOwnerIsToldTheyWouldKeepAdmin() throws {
        let p = try XCTUnwrap(make(claim(), viewerUserId: "owner-1", viewerIsOwner: true))

        XCTAssertTrue(p.message.contains("stay an admin"), p.message)
        XCTAssertTrue(p.message.contains("remove members"), p.message)
        XCTAssertNil(p.message.range(of: "key", options: .caseInsensitive), "no key talk: \(p.message)")
    }

    /// The obvious wording is FALSE — the server never demotes the outgoing
    /// owner. It is also false in the direction that makes the consequence
    /// sound worse than it is, which on a fourteen-day deadline is the wrong
    /// way to be wrong.
    func testTheOwnerIsNeverToldTheyBecomeAnOrdinaryMember() throws {
        let p = try XCTUnwrap(make(claim(), viewerUserId: "owner-1", viewerIsOwner: true))

        for wrong in ["ordinary member", "plain member", "just a member", "only a member",
                      "demote", "lose admin", "no longer an admin"] {
            XCTAssertFalse(
                p.message.lowercased().contains(wrong),
                "\(wrong) contradicts the server, which sets role='admin' on the outgoing owner: \(p.message)"
            )
        }
    }

    /// The consequence does not depend on the timing, so it must not live
    /// inside the deadline branch — a claim whose timestamp failed to parse
    /// still has to say what a transfer would cost.
    func testWhatSurvivesIsSaidEvenWithNoDeadline() throws {
        let noDeadline = OwnershipClaimResponse(
            claimId: "claim-1", circleId: "circle-1", claimantUserId: "claimant-1",
            status: "pending", requestedAt: nil, resolvesAt: nil
        )
        let p = try XCTUnwrap(make(noDeadline, viewerUserId: "owner-1", viewerIsOwner: true))
        XCTAssertTrue(p.message.contains("stay an admin"), p.message)
    }

    /// Display names come from the auth service, which answers a failure with
    /// an empty user list — so a nil name is ordinary, not exceptional.
    func testAnUnknownClaimantStillReadsAsASentence() throws {
        for name in [nil, "", "   "] as [String?] {
            let p = try XCTUnwrap(
                make(claim(), viewerUserId: "owner-1", viewerIsOwner: true, claimantName: name)
            )
            XCTAssertTrue(
                p.message.hasPrefix("An admin in this circle has asked"),
                "a missing name must not leave a gap mid-sentence: \(p.message)"
            )
        }
    }

    /// A named claimant is set off by commas so the sentence still parses:
    /// "Sam Rivera, an admin in this circle, has asked…".
    func testANamedClaimantIsIntroducedAsAnAdmin() throws {
        let p = try XCTUnwrap(
            make(claim(), viewerUserId: "owner-1", viewerIsOwner: true, claimantName: "Sam Rivera")
        )
        XCTAssertTrue(p.message.hasPrefix("Sam Rivera, an admin in this circle, has asked"), p.message)
    }

    // MARK: - The deadline

    /// The urgency, in the unit people think in. "in 14 days" is what makes the
    /// date mean something to somebody reading it in a hurry.
    func testTheOwnerMessageCountsTheDaysLeft() throws {
        let p = try XCTUnwrap(make(claim(), viewerUserId: "owner-1", viewerIsOwner: true))
        XCTAssertTrue(p.message.contains("in 14 days"), p.message)
    }

    func testTheLastDayReadsAsTodayAndTheDayBeforeAsTomorrow() throws {
        let today = try XCTUnwrap(
            make(claim(resolvesAt: iso(date(2026, 8, 23, 23))),
                 viewerUserId: "owner-1", viewerIsOwner: true, now: date(2026, 8, 23, 1))
        )
        XCTAssertTrue(today.message.contains("— today."), today.message)

        let tomorrow = try XCTUnwrap(
            make(claim(resolvesAt: iso(date(2026, 8, 24, 1))),
                 viewerUserId: "owner-1", viewerIsOwner: true, now: date(2026, 8, 23, 23))
        )
        XCTAssertTrue(tomorrow.message.contains("— tomorrow."), tomorrow.message)
    }

    /// A deadline already past — the server settles claims on a schedule, so
    /// there is a window where the row is still pending and the date is behind
    /// us. Never a negative count.
    func testAnElapsedDeadlineNeverCountsBackwards() {
        XCTAssertEqual(
            OwnershipClaimPresentation.daysRemaining(
                until: date(2026, 8, 20), from: date(2026, 8, 23), calendar: calendar
            ),
            0
        )
    }

    func testDaysAreCountedInWholeLocalDays() {
        // 23:00 to 01:00 the next morning is two hours and one day.
        XCTAssertEqual(
            OwnershipClaimPresentation.daysRemaining(
                until: date(2026, 8, 24, 1), from: date(2026, 8, 23, 23), calendar: calendar
            ),
            1,
            "an hours-based count would read '0 days' for most of the final day"
        )
    }

    /// The wire value is UTC. An owner far enough west reads a date one day
    /// earlier than the UTC one, and that is the date their circle actually
    /// changes hands from where they are standing.
    func testTheDeadlineIsWrittenInTheDeviceTimezone() throws {
        let justAfterUTCMidnight = date(2026, 9, 6, 1)
        let losAngeles = TimeZone(identifier: "America/Los_Angeles")!

        let inUTC = OwnershipClaimPresentation.format(
            deadline: justAfterUTCMidnight, locale: locale, timeZone: utc
        )
        let inLA = OwnershipClaimPresentation.format(
            deadline: justAfterUTCMidnight, locale: locale, timeZone: losAngeles
        )
        XCTAssertNotEqual(inUTC, inLA, "the same instant is a different calendar day in the two zones")
        XCTAssertTrue(inUTC.contains("September 6"), inUTC)
        XCTAssertTrue(inLA.contains("September 5"), inLA)
    }

    /// A claim with no usable deadline still has to render, and still has to
    /// carry the refuse control. Dropping the screen over a missing timestamp
    /// is how a circle transfers in silence.
    func testAMissingDeadlineCostsTheDateAndNothingElse() throws {
        let noDeadline = OwnershipClaimResponse(
            claimId: "claim-1",
            circleId: "circle-1",
            claimantUserId: "claimant-1",
            status: "pending",
            requestedAt: nil,
            resolvesAt: nil
        )
        let p = try XCTUnwrap(make(noDeadline, viewerUserId: "owner-1", viewerIsOwner: true))

        XCTAssertNil(p.deadline)
        XCTAssertNil(p.deadlineText)
        XCTAssertTrue(p.showsRefuse, "the control is the point; the date is the detail")
        XCTAssertTrue(
            p.message.contains("when the request runs out"),
            "say that a clock exists even when the date is missing: \(p.message)"
        )
        XCTAssertFalse(p.message.contains("nil"), p.message)
    }

    // MARK: - The other two audiences

    func testTheClaimantIsToldTheOwnerCanRefuse() throws {
        let p = try XCTUnwrap(make(claim(), viewerUserId: "claimant-1", viewerIsOwner: false))
        XCTAssertTrue(p.message.contains("can refuse"), p.message)
        XCTAssertTrue(p.message.contains("withdraw"), p.message)
        XCTAssertEqual(p.title, "You asked to take over this circle")
    }

    func testABystanderIsToldWhoAskedAndWhen() throws {
        let p = try XCTUnwrap(
            make(claim(), viewerUserId: "bystander-1", viewerIsOwner: false, claimantName: "Sam Rivera")
        )
        XCTAssertTrue(p.message.contains("Sam Rivera"), p.message)
        let expected = OwnershipClaimPresentation.format(
            deadline: date(2026, 9, 6), locale: locale, timeZone: utc
        )
        XCTAssertTrue(p.message.contains(expected), p.message)
    }

    /// Each audience gets its own headline. The owner's has to read as
    /// something aimed at them, not as circle news.
    func testTheTitlesAreDistinct() throws {
        let owner = try XCTUnwrap(make(claim(), viewerUserId: "owner-1", viewerIsOwner: true))
        let claimant = try XCTUnwrap(make(claim(), viewerUserId: "claimant-1", viewerIsOwner: false))
        let member = try XCTUnwrap(make(claim(), viewerUserId: "other", viewerIsOwner: false))

        XCTAssertEqual(owner.title, "Someone asked to take over this circle")
        XCTAssertNotEqual(owner.title, claimant.title)
        XCTAssertNotEqual(owner.title, member.title)
    }

    // MARK: - Who may ask

    /// The control is for admins who are not the owner, and for nobody else:
    /// the server refuses everyone else, and the Android app hides it the
    /// same way.
    func testOnlyAnAdminWhoIsNotTheOwnerMayAsk() {
        XCTAssertTrue(OwnershipClaimAccess.canOpen(viewerIsOwner: false, viewerRole: .admin, hasLiveClaim: false))
        XCTAssertFalse(OwnershipClaimAccess.canOpen(viewerIsOwner: false, viewerRole: .member, hasLiveClaim: false))
        XCTAssertFalse(OwnershipClaimAccess.canOpen(viewerIsOwner: true, viewerRole: .owner, hasLiveClaim: false))
    }

    /// An owner is the owner whatever the cached roster calls them.
    func testTheOwnerNeverSeesItEvenIfTheRosterCallsThemAdmin() {
        XCTAssertFalse(OwnershipClaimAccess.canOpen(viewerIsOwner: true, viewerRole: .admin, hasLiveClaim: false))
    }

    /// A roster that has not loaded is "not an admin", not "maybe".
    func testAnUnloadedRosterHidesIt() {
        XCTAssertFalse(OwnershipClaimAccess.canOpen(viewerIsOwner: false, viewerRole: nil, hasLiveClaim: false))
    }

    /// One claim at a time: while one is live, the section above is the story.
    func testALiveClaimHidesItEvenFromAnAdmin() {
        XCTAssertFalse(OwnershipClaimAccess.canOpen(viewerIsOwner: false, viewerRole: .admin, hasLiveClaim: true))
    }
}
