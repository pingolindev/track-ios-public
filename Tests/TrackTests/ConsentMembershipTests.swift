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
import CryptoKit
@testable import Track

/// Consent is a condition of membership: without consent there is no
/// membership, and not consenting to location sharing leaves the invitation
/// where it is.
///
/// Joining and creating carry the yes in their own request; declining joins
/// or creates nothing; stopping sharing is leaving the circle, with no
/// separate button for it; and there is no member-without-consent state.
@MainActor
final class ConsentMembershipTests: XCTestCase {

    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    // MARK: - The words (same on the Android app and the web)

    func testTheNoticeSaysWhatAgreeingDoes() {
        XCTAssertEqual(LocationConsentView.agreeLabel(.join), "Join and share my location")
        XCTAssertEqual(LocationConsentView.agreeLabel(.create), "Create and share my location")
    }

    func testDecliningSaysWhatItDid() throws {
        XCTAssertEqual(CirclesView.notJoinedMessage("Family"),
                       "You didn't join Family. Your invitation is still in Invitations if you change your mind.")
        XCTAssertTrue(try source("App/Views/Circles/CirclesView.swift").contains(#"Section("Invitations") {"#),
                      "the section the sentence names")
    }

    // MARK: - The notice text

    /// v1.1 ends with a paragraph AFTER the question. Only the question — the
    /// button's text — is left out; the sentence is shown, because a consent
    /// recorded against a text must be to a text the person read.
    func testTheNoticeShowsEverythingButTheQuestion() {
        let v11 = """
        version: 1.1
        effective: 2026-09-24

        # Before you share with this circle

        ## Stopping

        Pause sharing whenever you like. Or leave the circle, which
        ends it altogether.

        ## The question

        Share my location with this circle.

        Sharing your location is part of being in a circle. You can pause it any time; to stop
        sharing for good, you leave the circle.
        """
        XCTAssertEqual(NoticeBody.blocks(from: v11), [
            .heading("Stopping"),
            .paragraph("Pause sharing whenever you like. Or leave the circle, which ends it altogether."),
            .paragraph("Sharing your location is part of being in a circle. You can pause it any time; "
                       + "to stop sharing for good, you leave the circle."),
        ])
        let v10 = v11.components(separatedBy: "\n\nSharing your location")[0]
        XCTAssertEqual(NoticeBody.blocks(from: v10).last,
                       .paragraph("Pause sharing whenever you like. Or leave the circle, which ends it altogether."),
                       "v1.0: nothing after the question")
        XCTAssertEqual(NoticeBody.blocks(from: LocationConsentView.fallbackText).last,
                       .paragraph("Sharing your location is part of being in a circle. You can pause it any time; "
                                  + "to stop sharing for good, you leave the circle. As its owner, you delete it, "
                                  + "or transfer ownership and then leave."),
                       "the bundled fallback (v1.5) keeps the sentence last before the question, then an owner's ways out")
    }

    /// The bundled fallback is byte for byte the v1.5 text the server serves
    /// (1518 bytes; pinned here by SHA-256 of those bytes, as the Android
    /// app's LocationNoticeBundledTest does).
    func testTheFallbackIsTheServedTextByteForByte() {
        let digest = SHA256.hash(data: Data(LocationConsentView.fallbackText.utf8))
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, "72ff91c7529121149e6a5760584ec52e95e43e87eb6abca0fa5701c02b974193")
        XCTAssertEqual(LocationConsentView.fallbackText.utf8.count, 1518)
    }

    /// The sentence ends at "anywhere." (no "we can't read it."), and the
    /// notice never talks about keys.
    func testTheNoticeSaysEncryptedOnYourPhoneAndNoKeyTalk() {
        let text = LocationConsentView.fallbackText
        XCTAssertTrue(text.hasPrefix("version: 1.5\neffective: 2026-10-20\n"))
        XCTAssertTrue(text.contains("Your position is encrypted on your phone before it goes anywhere.\nTravelling alongside"))
        XCTAssertNil(text.range(of: #"can.t\s+read it"#, options: [.regularExpression]),
                     "\"we can't read it.\" is gone")
        XCTAssertFalse(text.contains("sealed with this circle's key"))
        XCTAssertNil(text.range(of: #"\bkeys?\b"#, options: [.regularExpression, .caseInsensitive]),
                     "no key talk anywhere in the notice")
    }

    // MARK: - Behaviour

    /// Only a yes given at the notice is sharing. A membership older than the
    /// notice (`implied`), one never asked (`none`) and a withdrawn one are not
    /// — and none of them is shown a state or a prompt.
    func testOnlyARecordedYesIsSharing() throws {
        func consent(_ status: String, _ mode: String?) throws -> LocationConsentResponse {
            var object: [String: Any] = ["circle_id": "c1", "status": status, "notice_outdated": false]
            if let mode { object["mode"] = mode }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(LocationConsentResponse.self, from: JSONSerialization.data(withJSONObject: object))
        }
        XCTAssertTrue(CircleDetailView.isSharing(try consent("granted", "presented")))
        XCTAssertFalse(CircleDetailView.isSharing(try consent("granted", "implied")))
        XCTAssertFalse(CircleDetailView.isSharing(try consent("none", nil)))
        XCTAssertFalse(CircleDetailView.isSharing(try consent("withdrawn", "presented")))
    }

    /// A yes given against an older notice is still a yes, and nothing asks it
    /// again: the server's `notice_outdated` is decoded and acted on nowhere,
    /// and the notice is put in front of a person at a join and at a create
    /// only, never for a membership that exists.
    func testAYesGivenAgainstAnOlderNoticeIsNeverAskedAgain() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let older = try decoder.decode(LocationConsentResponse.self, from: JSONSerialization.data(withJSONObject: [
            "circle_id": "c1", "status": "granted", "mode": "presented", "notice_version": "1.4",
            "notice_outdated": true,
        ] as [String: Any]))
        XCTAssertTrue(older.noticeOutdated)
        XCTAssertTrue(CircleDetailView.isSharing(older), "a v1.4 yes is still sharing under v1.5")

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let files = FileManager.default.enumerator(at: root.appendingPathComponent("App"), includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        XCTAssertFalse(files.isEmpty)
        var readers: [String: Int] = [:]
        var asks: [String: Int] = [:]
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let read = text.components(separatedBy: "noticeOutdated").count - 1
            if read > 0 { readers[file.lastPathComponent] = read }
            let ask = text.components(separatedBy: "LocationConsentView(").count - 1
            if ask > 0 { asks[file.lastPathComponent] = ask }
        }
        XCTAssertEqual(readers, ["APIService.swift": 1], "only its declaration: nothing acts on an outdated notice")
        XCTAssertEqual(asks, ["CirclesView.swift": 2], "the notice is asked at a join and at a create, nowhere else")
    }

    /// The yes travels WITH the join and with the create — one request, one
    /// transaction — naming the notice that was on screen.
    func testTheYesGoesWithTheJoinAndTheCreate() throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let shown = ShownNotice(version: "1.1")
        let accept = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(AcceptInviteRequest(
            encryptedCircleKey: nil, ephemeralPublicKey: nil, locationConsent: LocationConsentGrant(shown)))) as? [String: Any])
        let consent = try XCTUnwrap(accept["location_consent"] as? [String: String])
        XCTAssertEqual(consent, ["client_notice_version": "1.1", "surface": "ios"])

        let create = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(CreateCircleRequest(
            encryptedName: EncryptedBlobRequest(nonce: "n", ciphertext: "c"),
            encryptedCircleKey: EncryptedBlobRequest(nonce: "n", ciphertext: "c"),
            ephemeralPublicKey: "e", locationConsent: LocationConsentGrant(shown)))) as? [String: Any])
        XCTAssertEqual(create["location_consent"] as? [String: String],
                       ["client_notice_version": "1.1", "surface": "ios"])
    }

    /// A yes names the notice that was on screen: the fetched one, or, when
    /// the fetch failed and the bundled text was shown, that text's own
    /// version from its front matter, so the record says which text was read
    /// even then. Nothing to name only while loading, when the yes is
    /// disabled.
    func testAYesNamesTheNoticeOnScreenFetchedOrBundled() throws {
        let fetched = LocationConsentNoticeResponse(version: "1.6", digest: "d", text: "t")
        XCTAssertEqual(LocationConsentView.shown(fetched: fetched, loadFailed: false), ShownNotice(version: "1.6"))
        XCTAssertEqual(LocationConsentView.shown(fetched: nil, loadFailed: true), ShownNotice(version: "1.5"),
                       "the bundled text, by its own front matter")
        XCTAssertNil(LocationConsentView.shown(fetched: nil, loadFailed: false), "still loading")
        // Read from the text itself, so a new fallback brings its version with it.
        let version = try XCTUnwrap(LocationConsentView.frontMatterVersion(of: LocationConsentView.fallbackText))
        XCTAssertTrue(LocationConsentView.fallbackText.hasPrefix("version: \(version)\n"))
        XCTAssertNil(LocationConsentView.frontMatterVersion(of: "# Heading\n\nversion: 9\n"), "only the front matter counts")
        // And it is what the join or the create sends beside the server's own stamp.
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let grant = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(
            LocationConsentGrant(LocationConsentView.shown(fetched: nil, loadFailed: true)))) as? [String: String])
        XCTAssertEqual(grant, ["client_notice_version": "1.5", "surface": "ios"])
    }

    /// Nothing joins and nothing is created without the yes, and nothing is
    /// undone afterwards: there is no accept-then-grant, no leave-on-failure.
    func testNothingJoinsOrIsCreatedWithoutTheYes() throws {
        let circles = try source("App/Views/Circles/CirclesView.swift")
        let gate = try XCTUnwrap(circles.range(of: "guard granted else {"))
        let accept = try XCTUnwrap(circles.range(of: "_ = try await invitesManager.accept(invite: invite, consent: shown)"))
        XCTAssertLessThan(gate.lowerBound, accept.lowerBound, "the accept is on the far side of the yes")
        XCTAssertFalse(circles.contains("grantLocationConsent"), "no grant after the fact")
        XCTAssertFalse(circles.contains("try await circleManager.leaveCircle(circleId)"), "nothing to undo")
        XCTAssertTrue(circles.contains("if agreed { createCircle(consent: shown) }"),
                      "a circle is created only on the creator's yes; \"Not now\" creates nothing")
        XCTAssertEqual(circles.components(separatedBy: "createCircle(consent:").count - 1, 2,
                       "the call in the yes branch, and the function itself")
        XCTAssertEqual(circles.components(separatedBy: "circleManager.createCircle(").count - 1, 1,
                       "one way to create a circle, and it carries the yes")
        let manager = try source("App/Managers/CircleManager.swift")
        XCTAssertTrue(manager.contains("locationConsent: LocationConsentGrant(consent)"))
        let invites = try source("App/Managers/InvitesManager.swift")
        XCTAssertTrue(invites.contains("locationConsent: LocationConsentGrant(consent)"))
    }

    /// There is no "Stop sharing my location" button: its question could only
    /// lead to Leave or to the pause, which the screen has anyway. None of its
    /// question, its words or the withdrawal only it sent remain (the server
    /// keeps that route, for older builds). What sharing means here, the pause
    /// controls, and Leave / Delete stay.
    func testThereIsNoStopSharingButton() throws {
        let circles = try source("App/Views/Circles/CirclesView.swift")
        for gone in ["Stop sharing my location", "Stop sharing with", "Stopping sharing means leaving",
                     "Pause instead", "StopSharingCopy", "confirmingStop", "showingPause", "openPause",
                     "consentError", "stopSharingAndLeave"] {
            XCTAssertFalse(circles.contains(gone), "still there: \(gone)")
        }
        let detail = try XCTUnwrap(circles.range(of: "struct CircleDetailView: View {"))
        let rows = try XCTUnwrap(circles.range(of: "struct MemberRow: View {", range: detail.upperBound..<circles.endIndex))
        XCTAssertFalse(circles[detail.upperBound..<rows.lowerBound].contains(".confirmationDialog("),
                       "the circle's screen asks nothing of its own")
        XCTAssertFalse(try source("App/Managers/CircleManager.swift").contains("stopSharingAndLeave"))
        XCTAssertFalse(try source("App/Services/APIService.swift").contains("withdrawLocationConsent"),
                       "nothing sends the withdrawal now")

        // Kept: the section, saying what sharing is here, with no control of its own.
        XCTAssertTrue(circles.contains("            if let consent, Self.isSharing(consent) {\n                locationConsentSection\n"))
        let start = try XCTUnwrap(circles.range(of: "    private var locationConsentSection: some View {\n"))
        let end = try XCTUnwrap(circles.range(of: "    /// This account's sharing in this circle", range: start.upperBound..<circles.endIndex))
        let section = String(circles[start.upperBound..<end.lowerBound])
        XCTAssertTrue(section.contains(#"Text("You are sharing your location with this circle")"#))
        XCTAssertTrue(section.contains(#"Text("The settings below apply on top of this.")"#))
        XCTAssertTrue(section.contains("ownSharingRow(line)"))
        XCTAssertTrue(section.contains(#"Text("Location sharing")"#))
        XCTAssertFalse(section.contains("Button"), "the section has no control")
        // Kept: the pause controls, and Leave / Delete.
        XCTAssertTrue(circles.contains("            Section(\"Privacy Settings\") {\n"
                                       + "                if let settings = circleManager.privacySettings[circle.id] {\n"
                                       + "                    PrivacySettingsRow(settings: settings)\n"))
        XCTAssertTrue(circles.contains(#"Label(circle.isOwner ? "Delete Circle" : "Leave Circle", systemImage: "rectangle.portrait.and.arrow.right")"#))
        XCTAssertTrue(circles.contains("                try await circleManager.leaveCircle(circle.id)\n"))
        XCTAssertTrue(circles.contains("                try await circleManager.deleteCircle(circle)\n"))
    }

    /// With no such button, both forms of the "Location sharing" section say
    /// how to stop for good (withdrawing the consent, GDPR Art 7(3)): these
    /// exact words, one string for every member, under the own-status line or
    /// the "settings below" line.
    func testTheSectionSaysHowToStopForGood() throws {
        XCTAssertEqual(CircleDetailView.membershipNote,
                       "Sharing your location is part of being in this circle. You can pause it any time; "
                       + "to stop sharing for good, you leave the circle. As its owner, you delete it, or "
                       + "transfer ownership and then leave.")
        let circles = try source("App/Views/Circles/CirclesView.swift")
        XCTAssertTrue(circles.contains("                    ownSharingRow(line)\n"
                                       + "                } header: {\n"
                                       + "                    Text(\"Location sharing\")\n"
                                       + "                } footer: {\n"
                                       + "                    Text(Self.membershipNote)\n"),
                      "the section for a membership with no yes on record, off or paused")
        let start = try XCTUnwrap(circles.range(of: "    private var locationConsentSection: some View {\n"))
        let end = try XCTUnwrap(circles.range(of: "    /// This account's sharing in this circle", range: start.upperBound..<circles.endIndex))
        let section = String(circles[start.upperBound..<end.lowerBound])
        XCTAssertTrue(section.contains("        } header: {\n            Text(\"Location sharing\")\n"
                                       + "        } footer: {\n            Text(Self.membershipNote)\n        }\n"),
                      "the section for a yes on record")
        XCTAssertTrue(section.contains("ownSharingRow(line)"), "the own-status line stays")
        XCTAssertTrue(section.contains(#"Text("The settings below apply on top of this.")"#), "so does the settings line")
        XCTAssertEqual(circles.components(separatedBy: "Text(Self.membershipNote)").count - 1, 2)
    }

    /// No member-without-consent state, and no prompt for memberships older
    /// than the notice.
    func testThereIsNoMemberWithoutConsentState() throws {
        let circles = try source("App/Views/Circles/CirclesView.swift")
        for gone in ["You are a member and can see everyone else", "Nothing of yours is being sent",
                     "Review and start sharing", "needs your answer", "You joined before we started asking",
                     "Nothing is being sent yet", "You are not sharing your location with this circle"] {
            XCTAssertFalse(circles.contains(gone), "still there: \(gone)")
        }
        let notice = try source("App/Views/Circles/LocationConsentView.swift")
        XCTAssertFalse(notice.contains("grantLocationConsent"), "the notice records nothing by itself")
    }
}
