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
import PingolinTrackSDK
@testable import Track

/// An account's id has one form, the 36 hyphenated characters lower-cased,
/// and the app takes the server's word for an id only in it. The
/// directory's answer to an invitation must already be in it; everything
/// else the server serves is brought to it where it comes in, so the app
/// and the SDK agree on who is who; an id that is no UUID at all is
/// refused there.
@MainActor
final class CanonicalIdTests: XCTestCase {
    private let id = "67e55044-10b1-426f-9247-bb680e5fe0c8"
    private var bare: String { id.replacingOccurrences(of: "-", with: "") }
    private var spellings: [String] { [id.uppercased(), bare, bare.uppercased(), "{\(id)}", "{\(id.uppercased())}", "urn:uuid:\(id)"] }

    private func hex(fromBase64 b64: String) -> String {
        Data(base64Encoded: b64)!.map { String(format: "%02x", $0) }.joined()
    }

    private var suites: [String] = []

    override func tearDown() {
        for name in suites { UserDefaults().removePersistentDomain(forName: name) }
        super.tearDown()
    }

    // MARK: - The one form

    /// Every spelling the SDK parses is the one id; nothing else is an id.
    func testEverySpellingTheSdkParsesIsOneIdAndNothingElseIsAnId() {
        XCTAssertEqual(CanonicalId.of(id), id)
        for spelt in spellings {
            XCTAssertEqual(CanonicalId.of(spelt), id, spelt)
            XCTAssertEqual(CanonicalId.key(spelt), id, spelt)
        }
        for notAnId in ["", "evil", " \(id)", "\(id) ", "\(id)\n", "URN:UUID:\(id)", "urn:uuid:\(bare)", "{\(bare)}",
                        "{\(id)", "\(id)}", String(bare.dropLast()) + "z", String(id.dropLast()) + "z",
                        "67e5504-410b1-426f-9247-bb680e5fe0c8", "67e55044-10b1-426f-9247bb680e5fe0c8-"] {
            XCTAssertNil(CanonicalId.of(notAnId), notAnId)
        }
        XCTAssertNil(CanonicalId.of(nil))
        XCTAssertEqual(CanonicalId.key("Evil"), "evil", "compared as itself, and never equal to an account")
    }

    /// The invitation's lookup takes only the 36 hyphenated characters, in
    /// any case.
    func testTheStrictFormIsTheHyphenatedOneInAnyCase() {
        XCTAssertEqual(CanonicalId.strict(id), id)
        XCTAssertEqual(CanonicalId.strict(id.uppercased()), id)
        for spelt in [bare, "{\(id)}", "urn:uuid:\(id)", "evil", ""] {
            XCTAssertNil(CanonicalId.strict(spelt), spelt)
        }
    }

    /// The app and the SDK agree on who is who: the subject of a statement
    /// the SDK signs for any spelling is the app's one form of it, and a
    /// spelling the app refuses is one the SDK refuses too.
    func testTheSdkReadsEverySpellingAsTheAppDoes() throws {
        let sdk = CryptoManager()
        _ = sdk.generateKeypair()
        let signing = hex(fromBase64: sdk.generateSigningKeypair().verifyingKeyB64)
        let circle = "d0000000-0000-4000-8000-0000000000d1"
        let creation = try sdk.prepareCircleCreation()
        try sdk.finalizeCircleCreation(tempCircleId: creation.tempCircleId, realCircleId: circle)
        let signer = "d0000000-0000-4000-8000-0000000000d2"
        func subject(_ spelt: String) -> String? {
            (try? sdk.signInvitationToAccount(circleId: circle, signerUserId: signer, subjectUserId: spelt,
                                              subjectSharingPublicKeyHex: signing,
                                              subjectSigningPublicKeyHex: signing))?.statement.subjectUserId
        }
        for spelt in [id] + spellings {
            XCTAssertEqual(subject(spelt), id, spelt)
        }
        for notAnId in ["evil", "URN:UUID:\(id)", "{\(bare)}", " \(id)"] {
            XCTAssertNil(subject(notAnId), notAnId)
            XCTAssertNil(CanonicalId.of(notAnId), notAnId)
        }
    }

    // MARK: - The invitation

    private func lookup(_ userId: String?) -> UserPublicKeyResponse {
        UserPublicKeyResponse(email: "sam@example.com", sharingPublicKey: "aa", signingPublicKey: "bb", userId: userId)
    }

    /// The directory's answer names the invitee in the 36 hyphenated
    /// characters, or it is no answer: another spelling of the same UUID,
    /// which would miss this device's pins for them, included.
    func testTheInvitationTakesTheDirectorysAnswerOnlyInTheOneForm() {
        XCTAssertEqual(CircleManager.canonicalLookup(lookup(id.uppercased()))?.userId, id)
        XCTAssertEqual(CircleManager.canonicalLookup(lookup(id))?.userId, id)
        let noAccount = CircleManager.canonicalLookup(lookup(nil))
        XCTAssertNotNil(noAccount, "no account stays no account")
        XCTAssertNil(noAccount?.userId)
        for spelt in [bare, "{\(id)}", "urn:uuid:\(id)", "evil"] {
            XCTAssertNil(CircleManager.canonicalLookup(lookup(spelt)), spelt)
        }
        XCTAssertTrue(PendingChanges.addressCouldNotBeChecked(PendingChanges.AnswerNotReadable()),
                      "no answer: kept waiting, never an invitation to the address, never unsigned")
    }

    /// Whom "It's them" confirmed is compared in the one form, the live
    /// answer's and a waiting invitation's alike.
    func testTheConfirmedInviteeIsTakenInTheOneForm() throws {
        let circle = "d0000000-0000-4000-8000-0000000000d3"
        let live = InviteeChange(circleId: circle, email: "sam@example.com", userId: id.uppercased(),
                                 sharingKeyHex: "aa", signingKeyHex: "bb", number: nil)
        XCTAssertEqual(CircleManager.confirmedInvitee(live: live, waiting: nil)?.userId, id)
        var waiting = PendingChanges.make(.invite, account: UUID().uuidString.lowercased(), circleId: circle,
                                          inputs: .invite(.init(email: "sam@example.com", confirmedUserId: bare)))
        waiting.seen.keys = MemberKeyPair(sharingKeyHex: "aa", signingKeyHex: "bb")
        XCTAssertEqual(CircleManager.confirmedInvitee(live: nil, waiting: waiting)?.userId, id)
        waiting.inputs = .invite(.init(email: "sam@example.com", confirmedUserId: "evil"))
        let confirmed = try XCTUnwrap(CircleManager.confirmedInvitee(live: nil, waiting: waiting))
        XCTAssertFalse(CircleManager.lookupShows(confirmed, lookup(id)), "no id is never the directory's account")
    }

    // MARK: - The verified mark

    /// One mark, whatever spelling set, read or cleared it: a key change
    /// clears a mark set under another case.
    func testAVerifiedMarkIsOneMarkWhateverTheSpelling() {
        let circle = UUID().uuidString.lowercased()
        let member = UUID().uuidString.lowercased()
        defer { MemberVerificationStore.clearVerified(circleId: circle, userId: member) }
        MemberVerificationStore.setVerified(circleId: circle.uppercased(), userId: member.uppercased())
        XCTAssertNotNil(MemberVerificationStore.verifiedAt(circleId: circle, userId: member))
        XCTAssertNotNil(MemberVerificationStore.verifiedAt(
            circleId: circle, userId: member.replacingOccurrences(of: "-", with: "")))
        MemberVerificationStore.clearVerified(circleId: circle, userId: member)
        XCTAssertNil(MemberVerificationStore.verifiedAt(circleId: circle.uppercased(), userId: member.uppercased()))
    }

    // MARK: - The account

    /// A resumed session is its account only when /auth/me and the Keychain
    /// name the same one; otherwise it is invalid, and ends.
    func testASessionIsItsAccountOnlyWhenMeAndTheKeychainNameIt() {
        XCTAssertEqual(AuthManager.sessionAccount(served: id, stored: id), id)
        XCTAssertEqual(AuthManager.sessionAccount(served: id.uppercased(), stored: id), id)
        XCTAssertEqual(AuthManager.sessionAccount(served: bare, stored: id.uppercased()), id)
        XCTAssertNil(AuthManager.sessionAccount(served: UUID().uuidString, stored: id), "another account")
        XCTAssertNil(AuthManager.sessionAccount(served: "evil", stored: id))
        XCTAssertNil(AuthManager.sessionAccount(served: id, stored: nil))
        XCTAssertNil(AuthManager.sessionAccount(served: id, stored: "uitest-user"))
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// The wiring: the sign-in takes /auth/me's id in the one form before it
    /// purges, saves or wipes anything, and fails with nothing done when it
    /// isn't an id; a launch whose /auth/me names another account ends the
    /// session before anything reads it; the account reads back in the one
    /// form; the extension compares it so.
    func testTheAccountIsTakenInTheOneFormWhereItComesIn() throws {
        let auth = try source("App/Managers/AuthManager.swift")
        let login = try XCTUnwrap(auth.range(of: "    private func completeLogin("))
        let loginEnd = try XCTUnwrap(auth[login.upperBound...].range(of: "    /// Undo what `completeLogin` wrote"))
        let body = auth[login.upperBound..<loginEnd.lowerBound]
        let guarded = try XCTUnwrap(body.range(of: """
                    let user = try await api.getMe()
                    // The account's id in its one form: the purge below, the Keychain
                    // and every per-account store key by it. /auth/me naming the account
                    // any other way is no answer: the sign-in fails, and nothing is
                    // purged, wiped or saved.
                    guard let me = CanonicalId.of(user.id) else {
                        Self.authLog.error("sign-in: /auth/me named the account by an id that isn't a UUID")
                        withdrawIncompleteSignIn()
                        throw AuthError.unexpectedResponse
                    }

            """))
        for step in ["if let prior = priorUserId, CanonicalId.of(prior) != me {", "try keychain.save(me, for: .userId)",
                     "SignInTidy.run(signedIn: me, typedEmail: typedEmail)", "RetainedMemberPins.restore(owner: me"] {
            let at = try XCTUnwrap(body.range(of: step), step)
            XCTAssertLessThan(guarded.upperBound, at.lowerBound, step)
        }
        XCTAssertEqual(body.components(separatedBy: "user.id").count, 2, "the served id is read once, into the one form")

        let launch = try XCTUnwrap(auth.range(of: "    func checkExistingSession() async {"))
        let launchBody = auth[launch.upperBound...].prefix(9_000)
        XCTAssertTrue(launchBody.contains("""
                        let user = try await api.getMe()
                        await completeLaunch(served: user, since: epoch)
            """), "the launch's read, finished in completeLaunch (as the read again after an offline launch is)")
        let complete = try XCTUnwrap(auth.range(of: "    private func completeLaunch(served user: User, since epoch: Int) async {"))
        let launchBody2 = auth[complete.upperBound...].prefix(9_000)
        let ended = try XCTUnwrap(launchBody2.range(of: """
                    // /auth/me naming another account than the Keychain's, or naming
                    // it in any form but its one form, is an invalid session. It
                    // ends as an expired one does, which keeps this account's
                    // stores: no switch purge and no tidy of anybody's data runs on
                    // a launch.
                    guard let me = Self.sessionAccount(served: user.id, stored: keychain.getString(for: .userId)) else {
                        Self.authLog.error("launch: /auth/me named another account than this device's: the session ends")
                        expireSession()
                        return
                    }
                    currentUser = user

            """))
        XCTAssertFalse(launchBody2[ended.upperBound...].prefix(6_000).contains("user.id"), "after the check, only its id")
        XCTAssertTrue(auth.contains("        keychain.getString(for: .userId).map { CanonicalId.of($0) ?? $0 }\n"))
        XCTAssertTrue(auth.contains("        let outgoingUserId = userId\n"))

        let handover = try source("NotificationExtension/BackgroundHandover.swift")
        XCTAssertTrue(handover.contains(
            "guard let me = env.keychainUserId().flatMap({ CanonicalId.of($0) }), CanonicalId.of(claims.subject) == me else {"))
        XCTAssertTrue(handover.contains("              CanonicalId.of(bridged) == me,\n"))
    }

    // MARK: - Where the server's ids come in

    private func memberRow(_ userId: String, sharing: String = "aa", signing: String = "bb") -> [String: Any] {
        ["user_id": userId, "display_name": "m", "role": "member", "status": "active",
         "encrypted_circle_key": ["nonce": "", "ciphertext": ""], "ephemeral_public_key": "",
         "can_see_history": true, "can_see_realtime": true, "joined_day_bucket": 20_000,
         "sharing_public_key": sharing, "signing_public_key": signing]
    }

    private func envelope(_ data: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["success": true, "data": data])
    }

    private func snakeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    /// The member list: a row naming an account in any spelling names it in
    /// the one form, and a row naming nobody is dropped; the rest are read.
    func testTheMemberListNamesEachAccountInTheOneFormAndDropsARowNamingNobody() throws {
        let other = UUID().uuidString.lowercased()
        let rows = spellings.map { memberRow($0) } + [memberRow(other), memberRow("evil")]
        let page: Paginated<CircleMemberResponse> = try APIService.decodeResponseBody(
            try envelope(["items": rows, "has_more": false]))
        XCTAssertEqual(page.items.map(\.userId), Array(repeating: id, count: spellings.count) + [other])
        XCTAssertEqual(page.hasMore, false)

        // The extension reads the same list its own way, to the same effect.
        let extensionPage = try snakeDecoder().decode(Page<CircleMemberResponse>.self, from: JSONSerialization.data(
            withJSONObject: ["items": rows, "has_more": true]))
        XCTAssertEqual(extensionPage.items.map(\.userId), Array(repeating: id, count: spellings.count) + [other])
        XCTAssertEqual(extensionPage.hasMore, true)

        // A single row naming nobody is refused whole.
        XCTAssertThrowsError(try snakeDecoder().decode(CircleMemberResponse.self, from: JSONSerialization.data(
            withJSONObject: memberRow("evil")))) { XCTAssertTrue($0 is CanonicalId.NotAnId) }
    }

    /// The members' keys a rotation wraps to, the same way.
    func testTheMembersKeysNameEachAccountInTheOneFormAndDropARowNamingNobody() throws {
        let rows: [[String: Any]] = (spellings + ["evil"]).map {
            ["user_id": $0, "sharing_public_key": "aa", "signing_public_key": "bb", "key_version": 1]
        }
        let keys: ServedEntries<MemberPublicKeyResponse> = try APIService.decodeResponseBody(try envelope(rows))
        XCTAssertEqual(keys.items.map(\.userId), Array(repeating: id, count: spellings.count))
        // Only a row naming nobody is dropped: any other fault fails the list.
        XCTAssertThrowsError(try APIService.decodeResponseBody(try envelope([["user_id": id]]))
                             as ServedEntries<MemberPublicKeyResponse>)
        let api = try source("App/Services/APIService.swift")
        XCTAssertTrue(api.contains(
            "let list: ServedEntries<MemberPublicKeyResponse> = try await get(path: \"/api/v1/circles/\\(circleId)/member-public-keys\")"))
    }

    /// Whoever signed a copy, and whom it is for, the same way: absent is
    /// absent, and an id that is no UUID refuses the copy (never read as
    /// absent, which can mean "this account's own").
    func testACopysSenderAndRecipientAreInTheOneForm() throws {
        func bundle(_ fields: [String: Any]) throws -> CircleKeyBundleResponse {
            var json: [String: Any] = ["circle_id": "00000000-0000-0000-0000-000000000000",
                                       "encrypted_circle_key": ["nonce": "1a", "ciphertext": "2b"],
                                       "ephemeral_public_key": "beef", "key_version": 2]
            json.merge(fields) { _, new in new }
            return try snakeDecoder().decode(CircleKeyBundleResponse.self, from: JSONSerialization.data(withJSONObject: json))
        }
        let spelt = try bundle(["sender_user_id": bare, "recipient_user_id": id.uppercased()])
        XCTAssertEqual(spelt.senderUserId, id)
        XCTAssertEqual(spelt.recipientUserId, id)
        XCTAssertNil(try bundle([:]).senderUserId)
        XCTAssertNil(try bundle(["sender_user_id": NSNull()]).senderUserId)
        XCTAssertThrowsError(try bundle(["sender_user_id": "evil"])) { XCTAssertTrue($0 is CanonicalId.NotAnId) }
        XCTAssertThrowsError(try bundle(["recipient_user_id": "evil"])) { XCTAssertTrue($0 is CanonicalId.NotAnId) }

        let key = try snakeDecoder().decode(CircleKeyResponse.self, from: JSONSerialization.data(withJSONObject: [
            "circle_id": "c", "encrypted_circle_key": ["nonce": "1a", "ciphertext": "2b"],
            "ephemeral_public_key": "beef", "key_version": 2, "sender_user_id": "{\(id)}"]))
        XCTAssertEqual(key.senderUserId, id)

        let circle: CircleResponse = try APIService.decodeResponseBody(Data("""
        {"success":true,"data":{"id":"11111111-1111-4111-8111-111111111111","owner_id":"u1","is_owner":false,
         "encrypted_name":{"nonce":"00","ciphertext":"00"},"day_bucket":20000,"member_count":2,
         "key_version":2,"member_key_version":2,"sender_user_id":"urn:uuid:\(id)"}}
        """.utf8))
        XCTAssertEqual(circle.senderUserId, id)

        var row = memberRow(UUID().uuidString)
        row["wrap_signer_user_id"] = id.uppercased()
        XCTAssertEqual(try snakeDecoder().decode(CircleMemberResponse.self, from: JSONSerialization.data(
            withJSONObject: row)).wrapSignerUserId, id)
    }

    /// Who joined, as the extension reads its notification row.
    func testWhoJoinedIsInTheOneForm() throws {
        func row(_ joined: Any) throws -> NotificationRow {
            try snakeDecoder().decode(NotificationRow.self, from: JSONSerialization.data(withJSONObject: [
                "circle_id": "c", "notification_type": "member_joined", "metadata": ["joined_user_id": joined]]))
        }
        XCTAssertEqual(try row(bare).metadata?.joinedUserId, id)
        XCTAssertNil(try row(NSNull()).metadata?.joinedUserId)
        XCTAssertThrowsError(try row("evil")) { XCTAssertTrue($0 is CanonicalId.NotAnId) }
    }

    /// The server lists THIS account under another spelling, with its own
    /// keys. It is still this account: the rotation gate never pins it,
    /// and the rotation wraps its copy to its own key, which another
    /// device of the account opens. Through the real SDK.
    func testAListSpellingThisAccountAnyWayPinsNothingAndTheRotationWrapsToItsOwnKey() throws {
        let circle = "d0000000-0000-4000-8000-0000000000c9"
        let meId = id
        let me = CryptoManager()
        let pair = me.generateKeypair()
        let seed = me.generateSigningKeypair()
        let meSigning = hex(fromBase64: seed.verifyingKeyB64)
        let server = CryptoManager()
        let serverSharing = hex(fromBase64: server.generateKeypair().publicKey)
        let serverSigning = hex(fromBase64: server.generateSigningKeypair().verifyingKeyB64)
        let creation = try me.prepareCircleCreation()
        try me.finalizeCircleCreation(tempCircleId: creation.tempCircleId, realCircleId: circle)
        // Another device of this account: the same two keys.
        let sameAccount = CryptoManager()
        try sameAccount.importPrivateKey(privateKeyBase64: pair.privateKey)
        try sameAccount.importSigningPrivateKey(secretSeedB64: seed.secretSeedB64)
        let name = "CanonicalIdTests.\(UUID().uuidString)"
        suites.append(name)
        let pinner = MemberKeyPinner(crypto: me, defaults: UserDefaults(suiteName: name)!)

        for spelt in spellings {
            let served: ServedEntries<MemberPublicKeyResponse> = try APIService.decodeResponseBody(try envelope([
                ["user_id": spelt, "sharing_public_key": serverSharing, "signing_public_key": serverSigning,
                 "key_version": 1]]))
            let row = try XCTUnwrap(served.items.first, spelt)
            XCTAssertEqual(row.userId, meId, spelt)

            XCTAssertEqual(pinner.gateMembersForRotation(
                circleId: circle, currentUserId: meId,
                members: [(userId: row.userId, displayName: "Me", sharingPubkeyHex: row.sharingPublicKey,
                           signingPubkeyHex: row.signingPublicKey)]), [], spelt)
            XCTAssertNil(me.pinnedSharingKey(circleId: circle, userId: meId), "no pin for this account: \(spelt)")
            XCTAssertNil(me.pinnedSharingKey(circleId: circle, userId: spelt), "none under the spelling: \(spelt)")

            let rotation = try me.prepareKeyRotation(
                circleId: circle, senderUserId: meId, memberUserIds: [row.userId],
                memberPublicKeysHex: [row.sharingPublicKey], memberSigningPubkeysHex: [row.signingPublicKey ?? ""],
                currentCircleNamePlaintext: "Family")
            let mine = try XCTUnwrap(rotation.memberKeys.first, spelt).bundle
            XCTAssertNoThrow(try sameAccount.storeCircleKey(
                circleId: circle,
                encryptedKey: mine.encryptedCircleKey.nonce + mine.encryptedCircleKey.ciphertext,
                senderPublicKey: mine.ephemeralPublicKey,
                keyVersion: rotation.newKeyVersion,
                senderUserId: meId,
                recipientUserId: meId,
                wrapSignatureHex: mine.wrapSignature,
                senderSigningPubkeyHex: meSigning), "wrapped to this account's own key: \(spelt)")
        }
    }
}
