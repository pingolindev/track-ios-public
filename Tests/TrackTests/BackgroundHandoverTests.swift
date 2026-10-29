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
import UserNotifications
import PingolinTrackSDK
@testable import Track

/// The Notification Service Extension hands a circle to the members this
/// device owes it — with the app's own rules (`AccessHandover`,
/// `MembershipConfirmation`), from the app's own record, writing no key and no
/// pin, and to the record only who left.
///
/// Everything here is real except the network and the device's stores: the
/// statements and wraps are the SDK's signatures, the "server" is a stub that
/// answers the three requests the extension makes, the key store is a spy that
/// records any write, and the app group is a scratch defaults suite.
final class BackgroundHandoverTests: XCTestCase {

    private let circleId = "c0ffee00-0000-4000-8000-0000000000aa"
    private let base = "https://track.test"
    private let now = Date()

    // MARK: - Fixtures

    /// A key store that remembers what it holds and counts every write.
    /// This device's tag (`DeviceTag`), as the app stamps its records.
    private static let deviceTag = "0f1e2d3c-device-tag-under-test"

    private final class SpyStorage: KeyStorageCallback, @unchecked Sendable {
        private let lock = NSLock()
        private var stored: StoredKeyData?
        private var writes = 0

        init(_ data: StoredKeyData? = nil) { stored = data }

        var data: StoredKeyData? { lock.lock(); defer { lock.unlock() }; return stored }
        var writeCount: Int { lock.lock(); defer { lock.unlock() }; return writes }

        func loadKeys() throws -> StoredKeyData? { data }
        func storeKeys(data: StoredKeyData) throws { lock.lock(); stored = data; writes += 1; lock.unlock() }
        func deleteKeys() throws { lock.lock(); stored = nil; writes += 1; lock.unlock() }
    }

    private static func hex(_ b64: String) -> String {
        Data(base64Encoded: b64)!.map { String(format: "%02x", $0) }.joined()
    }

    /// An account and one device of it: its keys, in an SDK whose store is a spy.
    private struct Party {
        let userId = UUID().uuidString.lowercased()
        let name: String
        let storage = SpyStorage()
        let sdk = CryptoManager()
        let sharing: String
        let signing: String
        var email: String { "\(name.lowercased())@example.com" }

        init(_ name: String) {
            self.name = name
            sdk.registerSecureStorage(storage: storage)
            sharing = BackgroundHandoverTests.hex(sdk.generateKeypair().publicKey)
            signing = BackgroundHandoverTests.hex(sdk.generateSigningKeypair().verifyingKeyB64)
        }
    }

    /// A statement `signer` signs for this circle.
    private func statement(by signer: Party, _ kind: MembershipStatementKind, about subject: Party,
                           atVersion: Int32 = 1) throws -> [String: Any] {
        let issued = Int64(now.timeIntervalSince1970)
        let signed = try signer.sdk.signMembershipStatement(statement: MembershipStatement(
            kind: kind, circleId: circleId, statementId: UUID().uuidString.lowercased(),
            signerUserId: signer.userId, issuedAt: issued,
            expiresAt: kind == .admission ? 0 : issued + 604_800, atVersion: atVersion,
            subjectUserId: kind == .invitationToEmail ? nil : subject.userId,
            subjectSharingPublicKeyHex: kind == .invitationToEmail ? nil : subject.sharing,
            subjectSigningPublicKeyHex: kind == .invitationToEmail ? nil : subject.signing,
            subjectEmail: kind == .invitationToEmail ? subject.email : nil))
        return ["statement": signed.statementHex, "signature": signed.signatureHex]
    }

    /// The stub server: the circle list, the roster, and whatever PUTs arrive.
    private final class StubServer: HandoverTransport, @unchecked Sendable {
        private let lock = NSLock()
        var responses: [String: (status: Int, body: Any)] = [:]
        private var seen: [URLRequest] = []

        var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return seen }
        var puts: [URLRequest] { requests.filter { $0.httpMethod == "PUT" } }

        private func note(_ request: URLRequest) {
            lock.lock(); seen.append(request); lock.unlock()
        }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            note(request)
            let key = "\(request.httpMethod ?? "GET") \(request.url!.path)"
            let answer = responses[key] ?? (request.httpMethod == "PUT" ? (200, ["success": true]) : (404, ["success": false]))
            let data = try JSONSerialization.data(withJSONObject: answer.body)
            return (data, HTTPURLResponse(url: request.url!, statusCode: answer.status, httpVersion: nil, headerFields: nil)!)
        }
    }

    /// One scenario: THIS device (`device`) in a circle it holds at `held`, the
    /// circle at `keyVersion`, its record, and the roster the server lists.
    private struct Scene {
        let device: Party
        let server = StubServer()
        /// The notification row the push names (`alert_id`).
        let rowId = UUID().uuidString.lowercased()
        let suite: String
        let defaults: UserDefaults
        var token: String
        var keyStore: SpyStorage?
        var tag: String? = BackgroundHandoverTests.deviceTag
        /// The approvals lock, on a scratch file.
        let lock = AppGroupLock(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("approvals-\(UUID().uuidString).lock"))

        func environment(clock: Date) -> BackgroundHandover.Environment {
            let persisted = device.storage.data
            let store = keyStore
            let (tag, lock) = (tag, lock)
            return BackgroundHandover.Environment(
                accessToken: { token },
                keychainUserId: { device.userId },
                shared: { defaults },
                deviceTag: { tag },
                approvalsLock: { lock },
                makeCrypto: {
                    let manager = CryptoManager()
                    manager.registerSecureStorage(storage: store ?? SpyStorage(persisted))
                    return (try? manager.loadPersistedKeys()) == true ? manager : nil
                },
                transport: server,
                now: { clock })
        }
    }

    private static func token(sub: String, expires: Date) -> String {
        func b64(_ object: [String: Any]) -> String {
            try! JSONSerialization.data(withJSONObject: object).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return "\(b64(["alg": "RS256"])).\(b64(["sub": sub, "exp": Int(expires.timeIntervalSince1970)])).signature"
    }

    private var suites: [String] = []

    override func tearDown() {
        for suite in suites { UserDefaults().removePersistentDomain(forName: suite) }
        suites.removeAll()
        super.tearDown()
    }

    /// Sets the scene: `device` holds the circle at version 1 (`keyVersion` is
    /// the circle's), has pinned `pinned`, keeps `record`, and the server lists
    /// `rows`.
    private func scene(device: Party, pinned: [Party], record: CircleApprovalRecord,
                       rows: [[String: Any]], keyVersion: Int = 1, memberKeyVersion: Int = 1,
                       isOwner: Bool = false, joined: Party? = nil, deliveryNeeded: Bool = false,
                       otherCircles: [[String: Any]] = [], recorded: Bool = false) throws -> Scene {
        if recorded {
            // A circle made with its genesis record.
            _ = try device.sdk.prepareRecordedCircleCreation(creatorUserId: device.userId, circleId: circleId)
        } else {
            let creation = try device.sdk.prepareCircleCreation()
            try device.sdk.finalizeCircleCreation(tempCircleId: creation.tempCircleId, realCircleId: circleId)
        }
        for party in pinned {
            _ = try device.sdk.pinMemberKeys(circleId: circleId, userId: party.userId,
                                             sharingPubkeyHex: party.sharing, signingPubkeyHex: party.signing)
        }
        let name = try device.sdk.encryptDataV2(circleId: circleId, plaintext: "Family", fieldTag: "name")
        XCTAssertNotNil(device.storage.data, "the device's keys are on its store, as the app leaves them")

        let suite = "BackgroundHandoverTests.\(UUID().uuidString)"
        suites.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(device.userId, forKey: ExtensionBridgeKeys.accountUserId)
        defaults.set(device.email, forKey: ExtensionBridgeKeys.accountEmail)
        defaults.set(base, forKey: ExtensionBridgeKeys.apiBaseURL)
        var tagged = record
        tagged.deviceTag = tagged.deviceTag ?? Self.deviceTag
        defaults.set(try JSONEncoder().encode(tagged), forKey: ApprovalRecordStore.key(owner: device.userId, circleId: circleId))

        let scene = Scene(device: device, suite: suite, defaults: defaults,
                          token: Self.token(sub: device.userId, expires: now.addingTimeInterval(3600)))
        scene.server.responses["GET /api/v1/circles"] = (200, ["success": true, "data": [
            "items": [[
                "id": circleId, "owner_id": UUID().uuidString.lowercased(), "is_owner": isOwner,
                "encrypted_name": ["nonce": name.nonce, "ciphertext": name.ciphertext],
                "day_bucket": 20_000, "member_count": rows.count, "key_version": keyVersion,
                "member_key_version": memberKeyVersion, "delivery_needed": deliveryNeeded,
            ]] + otherCircles,
            "has_more": false,
        ]])
        scene.server.responses["GET /api/v1/circles/\(circleId)/members"] = (200, ["success": true, "data": [
            "items": rows, "has_more": false,
        ]])
        // The row the push names: this user's, for this circle, saying who joined.
        var metadata: [String: Any] = ["needs_delivery": true, "send_location": true]
        if let joined { metadata["joined_user_id"] = joined.userId }
        scene.server.responses["GET /api/v1/notifications/\(scene.rowId)"] = (200, ["success": true, "data": [
            "id": scene.rowId, "circle_id": circleId, "notification_type": "member_joined",
            "title": "New circle member", "body": "Someone joined your circle.", "metadata": metadata,
            "is_read": false, "created_at": "2026-09-24T07:00:00Z",
        ]])
        return scene
    }

    /// A roster row as the server serves it (snake_case).
    private func row(_ party: Party, role: String = "member", keyVersion: Int? = 1,
                     invitation: [String: Any]? = nil, joinedToday: Bool = false) -> [String: Any] {
        var row: [String: Any] = [
            "user_id": party.userId, "display_name": party.name, "role": role,
            "encrypted_circle_key": ["nonce": "", "ciphertext": ""], "ephemeral_public_key": "",
            "can_see_history": true, "can_see_realtime": true, "status": "active",
            "joined_day_bucket": Int(now.timeIntervalSince1970 / 86_400) - (joinedToday ? 0 : 30),
            "sharing_public_key": party.sharing, "signing_public_key": party.signing,
        ]
        if let keyVersion { row["key_version"] = keyVersion }
        if let invitation { row["invitation"] = invitation }
        return row
    }

    private func record(_ entries: [(Party, ApprovalOrigin)]) -> CircleApprovalRecord {
        var record = CircleApprovalRecord()
        for (party, origin) in entries { record.entries[party.userId] = origin }
        return record
    }

    /// The push arrives: `alert_id` is the scene's notification row, or
    /// `pushId` (an older server put the circle id there; it is never read as
    /// one).
    private func run(_ scene: Scene, pushId: String? = nil, deadline: TimeInterval = 20) async -> BackgroundHandover.Outcome {
        await BackgroundHandover.run(pushId: pushId ?? scene.rowId, deadline: now.addingTimeInterval(deadline),
                                     env: scene.environment(clock: now))
    }

    /// The PUT the extension made for `member`, as the newcomer's own SDK sees
    /// it: it must open with their key and verify under the sender's.
    private func assertTheNewcomerCanOpen(_ put: URLRequest, from device: Party, to member: Party,
                                          file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(put.url?.path, "/api/v1/circles/\(circleId)/members/\(member.userId)/access", file: file, line: line)
        XCTAssertEqual(put.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer "), true, file: file, line: line)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(put.httpBody)) as? [String: Any])
        XCTAssertEqual(body["key_version"] as? Int, 1, file: file, line: line)
        let wrap = try XCTUnwrap(body["encrypted_circle_key"] as? [String: String])
        try member.sdk.storeFirstCircleKey(
            circleId: circleId,
            encryptedKey: try XCTUnwrap(wrap["nonce"]) + XCTUnwrap(wrap["ciphertext"]),
            senderPublicKey: try XCTUnwrap(body["ephemeral_public_key"] as? String),
            keyVersion: 1, senderUserId: device.userId, recipientUserId: member.userId,
            wrapSignatureHex: try XCTUnwrap(body["wrap_signature"] as? String),
            confirmedSenderSigningPubkeyHex: device.signing, sealedCircleName: nil)
        XCTAssertTrue(member.sdk.hasCircleKey(circleId: circleId), "the newcomer opens the circle", file: file, line: line)
    }

    // MARK: - The two cases the app decides the same way

    /// A plain member's phone, with the app not running, hands a newcomer the
    /// circle from the newcomer's signed invitation (signed by a member this
    /// device confirmed, no copy yet, invitation fresh) — and writes
    /// no key, no pin and no record on the way.
    func testTheExtensionHandsANewcomerWithASignedInvitationTheCircle() async throws {
        let (me, owner, newcomer) = (Party("Maya"), Party("Omar"), Party("Nadia"))
        let invitation = try statement(by: owner, .invitationToAccount, about: newcomer)
        let stored = record([(owner, .preRound2Seed)])
        var scene = try scene(device: me, pinned: [owner], record: stored, rows: [
            row(me), row(owner, role: "owner"), row(newcomer, keyVersion: nil, invitation: invitation, joinedToday: true),
        ], joined: newcomer)
        let keyStore = SpyStorage(me.storage.data)
        scene.keyStore = keyStore
        let recordBefore = scene.defaults.data(forKey: ApprovalRecordStore.key(owner: me.userId, circleId: circleId))
        let keysBefore = Set(scene.defaults.dictionaryRepresentation().keys)

        let outcome = await run(scene)

        XCTAssertNil(outcome.stopped)
        XCTAssertEqual(outcome.circleId, circleId, "read from the row the push names")
        XCTAssertEqual(outcome.delivered, [newcomer.userId])
        XCTAssertEqual(scene.server.puts.count, 1)
        try assertTheNewcomerCanOpen(try XCTUnwrap(scene.server.puts.first), from: me, to: newcomer)
        // Read-only: no key or pin written, the record untouched.
        XCTAssertEqual(keyStore.writeCount, 0, "the extension never writes the key store")
        XCTAssertEqual(scene.defaults.data(forKey: ApprovalRecordStore.key(owner: me.userId, circleId: circleId)), recordBefore)
        XCTAssertEqual(Set(scene.defaults.dictionaryRepresentation().keys), keysBefore)
        // The banner names them.
        XCTAssertEqual(outcome.circleName, "Family")
        XCTAssertEqual(outcome.joinerName, "Nadia")
        XCTAssertEqual(MemberJoinedCopy.body(member: outcome.joinerName, circle: outcome.circleName, level: "full"),
                       "Nadia joined Family.")
    }

    /// On a circle with refresh records the extension hands over nothing,
    /// even to a newcomer the delivery rule would allow: only the records'
    /// own delivery answer, after an import of the records, hands such a
    /// circle over, and the app does that. The banner still names them.
    func testTheExtensionHandsOverNothingOnACircleWithRefreshRecords() async throws {
        let (me, owner, newcomer) = (Party("Maya"), Party("Omar"), Party("Nadia"))
        let invitation = try statement(by: owner, .invitationToAccount, about: newcomer)
        let scene = try scene(device: me, pinned: [owner], record: record([(owner, .preRound2Seed)]), rows: [
            row(me), row(owner, role: "owner"), row(newcomer, keyVersion: nil, invitation: invitation, joinedToday: true),
        ], joined: newcomer, recorded: true)
        XCTAssertTrue(me.sdk.circleHasRefreshRecords(circleId: circleId))

        let outcome = await run(scene)

        XCTAssertEqual(outcome.stopped, "a circle with refresh records: the app hands it over")
        XCTAssertTrue(outcome.delivered.isEmpty)
        XCTAssertTrue(scene.server.puts.isEmpty)
        XCTAssertEqual(outcome.joinerName, "Nadia")
    }

    /// The same newcomer, invited by someone this device cannot confirm, gets
    /// nothing — and is not named on the banner.
    func testTheExtensionRefusesANewcomerWhoseInviterIsUnconfirmed() async throws {
        let (me, owner, ghost, newcomer) = (Party("Maya"), Party("Omar"), Party("Gus"), Party("Nadia"))
        let invitation = try statement(by: ghost, .invitationToAccount, about: newcomer)
        let scene = try scene(device: me, pinned: [owner], record: record([(owner, .preRound2Seed)]), rows: [
            row(me), row(owner, role: "owner"), row(ghost, role: "admin"),
            row(newcomer, keyVersion: nil, invitation: invitation, joinedToday: true),
        ], joined: newcomer)

        let outcome = await run(scene)

        XCTAssertEqual(outcome.delivered, [])
        XCTAssertTrue(scene.server.puts.isEmpty, "nothing handed to anyone")
        XCTAssertNil(outcome.joinerName, "a member kept out is never named")
        XCTAssertEqual(MemberJoinedCopy.body(member: outcome.joinerName, circle: outcome.circleName, level: "full"),
                       "A new member joined Family.")
    }

    /// Every roster pass keeps, for a member this device's record already
    /// confirms by a statement (an approval an earlier version made, with no
    /// ids), the ids of the statements that confirm them under a current key.
    func testEveryPassKeepsTheIdsForAnEarlierBuildsApproval() throws {
        let (me, owner, member) = (Party("Maya"), Party("Omar"), Party("Nadia"))
        let invitation = try statement(by: owner, .invitationToAccount, about: member)
        let data = try JSONSerialization.data(withJSONObject: [row(me), row(owner, role: "owner"),
                                                               row(member, invitation: invitation)])
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let roster = try decoder.decode([CircleMemberResponse].self, from: data)
        let creation = try me.sdk.prepareCircleCreation()
        try me.sdk.finalizeCircleCreation(tempCircleId: creation.tempCircleId, realCircleId: circleId)
        _ = try me.sdk.pinMemberKeys(circleId: circleId, userId: owner.userId,
                                     sharingPubkeyHex: owner.sharing, signingPubkeyHex: owner.signing)
        let id = try me.sdk.parse(XCTUnwrap(invitation["statement"] as? String)).statementId

        let pass = AccessHandover.rosterPass(
            circleId: circleId, me: .own(userId: me.userId, email: me.email, crypto: me.sdk), roster: roster,
            rosterComplete: true, activeVersion: 1, stored: record([(owner, .preRound2Seed), (member, .statement)]),
            checker: me.sdk)
        XCTAssertEqual(pass.result.verdicts[member.userId], .confirmed(.statement))
        XCTAssertNil(pass.result.newlyConfirmed[member.userId], "confirmed by the record already")
        XCTAssertEqual(pass.record.statementIds[member.userId], [id])
    }

    /// The same decisions the app makes on the same roster (`AccessHandover`):
    /// the extension's targets are exactly the app's, pins aside.
    func testTheExtensionDecidesWhatTheAppDecides() throws {
        let (me, owner, newcomer, ghost, stranger) = (Party("Maya"), Party("Omar"), Party("Nadia"), Party("Gus"), Party("Sam"))
        let good = try statement(by: owner, .invitationToAccount, about: newcomer)
        let forged = try statement(by: ghost, .invitationToAccount, about: stranger)
        let rows = [row(me), row(owner, role: "owner"), row(ghost),
                    row(newcomer, keyVersion: nil, invitation: good), row(stranger, keyVersion: nil, invitation: forged)]
        let data = try JSONSerialization.data(withJSONObject: rows)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let roster = try decoder.decode([CircleMemberResponse].self, from: data)
        let creation = try me.sdk.prepareCircleCreation()
        try me.sdk.finalizeCircleCreation(tempCircleId: creation.tempCircleId, realCircleId: circleId)
        _ = try me.sdk.pinMemberKeys(circleId: circleId, userId: owner.userId,
                                     sharingPubkeyHex: owner.sharing, signingPubkeyHex: owner.signing)

        let pass = AccessHandover.rosterPass(
            circleId: circleId, me: .own(userId: me.userId, email: me.email, crypto: me.sdk), roster: roster,
            rosterComplete: true, activeVersion: 1, stored: record([(owner, .preRound2Seed)]), checker: me.sdk)
        XCTAssertEqual(pass.result.verdicts[newcomer.userId], .confirmed(.statement))
        XCTAssertEqual(pass.result.verdicts[stranger.userId], .unconfirmable)
        XCTAssertEqual(pass.record.entries[newcomer.userId], .statement, "what the app records on this roster")
        XCTAssertEqual(pass.pinActions[newcomer.userId], .pin)
        XCTAssertEqual(pass.pinActions[stranger.userId], .nothing)

        let members = roster.map {
            AccessHandover.Member(userId: $0.userId, displayName: $0.displayName ?? "Member",
                                  sharingKeyHex: $0.sharingPublicKey, signingKeyHex: $0.signingPublicKey)
        }
        func targets(_ gate: @escaping ([AccessHandover.GateMember]) -> Set<String>) -> [String] {
            AccessHandover.deliveries(
                me: me.userId, circleKeyVersion: 1, heldVersion: 1, createdHere: false, members: members,
                candidates: pass.candidates, result: pass.result, record: pass.record, now: now, pinGate: gate
            ).map(\.userId)
        }
        let readOnly = targets(AccessHandover.readOnlyPinGate(
            me: me.userId, circleId: circleId,
            pinnedSharing: { me.sdk.pinnedSharingKey(circleId: $0, userId: $1) },
            pinnedSigning: { me.sdk.pinnedSigningKey(circleId: $0, userId: $1) }))
        XCTAssertEqual(readOnly, [newcomer.userId])
        // The app's gate on the same SDK pins as it goes; it reaches the same
        // targets.
        let pinning = targets { members in
            Set(members.compactMap { m -> String? in
                guard let sharing = m.sharingPubkeyHex, let signing = m.signingPubkeyHex,
                      let result = try? me.sdk.pinMemberKeys(circleId: self.circleId, userId: m.userId,
                                                              sharingPubkeyHex: sharing, signingPubkeyHex: signing)
                else { return m.userId }
                return result.state == .newPinning || result.state == .matched ? nil : m.userId
            })
        }
        XCTAssertEqual(pinning, readOnly)
    }

    // MARK: - The read-only pin gate

    /// The extension's gate decides what the SDK's `pin_member_keys` decides —
    /// first contact, a match, a changed key, a user known from another circle,
    /// keys the SDK refuses, a stripped signing key — without pinning anything.
    func testTheReadOnlyGateAgreesWithPinMemberKeys() throws {
        let sdk = CryptoManager()
        _ = sdk.generateKeypair()
        let other = "d00d0000-0000-4000-8000-000000000001"
        let (a, b, c) = (Party("A"), Party("B"), Party("C"))
        _ = try sdk.pinMemberKeys(circleId: circleId, userId: a.userId, sharingPubkeyHex: a.sharing, signingPubkeyHex: a.signing)
        _ = try sdk.pinMemberKeys(circleId: other, userId: b.userId, sharingPubkeyHex: b.sharing, signingPubkeyHex: b.signing)
        let gate = AccessHandover.readOnlyPinGate(
            me: "me", circleId: circleId,
            pinnedSharing: { sdk.pinnedSharingKey(circleId: $0, userId: $1) },
            pinnedSigning: { sdk.pinnedSigningKey(circleId: $0, userId: $1) })
        let cases: [(String, AccessHandover.GateMember)] = [
            ("pinned, same keys", (a.userId, "A", a.sharing, a.signing)),
            ("pinned, same keys, upper case", (a.userId, "A", a.sharing.uppercased(), a.signing.uppercased())),
            ("pinned, sharing changed", (a.userId, "A", c.sharing, a.signing)),
            ("pinned, signing changed", (a.userId, "A", a.sharing, c.signing)),
            ("known from another circle", (b.userId, "B", b.sharing, b.signing)),
            ("known from another circle, changed", (b.userId, "B", c.sharing, b.signing)),
            ("first contact", (c.userId, "C", c.sharing, c.signing)),
            ("not hex", (c.userId, "C", String(repeating: "z", count: 64), c.signing)),
        ]
        for (label, member) in cases {
            let readOnly = gate([member]).contains(member.userId)
            // The SDK's answer, on a copy of the same pins, so the check itself
            // pins nothing the next case sees.
            let copy = CryptoManager()
            _ = copy.generateKeypair()
            _ = try copy.pinMemberKeys(circleId: circleId, userId: a.userId, sharingPubkeyHex: a.sharing, signingPubkeyHex: a.signing)
            _ = try copy.pinMemberKeys(circleId: other, userId: b.userId, sharingPubkeyHex: b.sharing, signingPubkeyHex: b.signing)
            let sdkBlocks: Bool
            if let result = try? copy.pinMemberKeys(circleId: circleId, userId: member.userId,
                                                     sharingPubkeyHex: member.sharingPubkeyHex!,
                                                     signingPubkeyHex: member.signingPubkeyHex!) {
                sdkBlocks = !(result.state == .newPinning || result.state == .matched)
            } else {
                sdkBlocks = true
            }
            XCTAssertEqual(readOnly, sdkBlocks, label)
        }
        // A stripped signing key: first contact passes, a changed pinned sharing key does not.
        XCTAssertTrue(gate([(c.userId, "C", c.sharing, nil)]).isEmpty)
        XCTAssertEqual(gate([(a.userId, "A", c.sharing, nil)]), [a.userId])
        XCTAssertEqual(gate([(c.userId, "C", nil, c.signing)]), [c.userId], "no sharing key, nothing to wrap to")
        // And it pinned nothing.
        XCTAssertNil(sdk.pinnedSharingKey(circleId: circleId, userId: c.userId))
    }

    // MARK: - When it does nothing

    /// A receive-only newcomer (invited by email) is handed the circle with the
    /// keys the pass would record — and the record itself stays as it was.
    func testAKind2NewcomerIsHandedTheCircleWithoutTouchingTheRecord() async throws {
        let (me, owner, newcomer) = (Party("Maya"), Party("Omar"), Party("Nadia"))
        let invitation = try statement(by: owner, .invitationToEmail, about: newcomer)
        var scene = try scene(device: me, pinned: [owner], record: record([(owner, .preRound2Seed)]), rows: [
            row(me), row(owner, role: "owner"), row(newcomer, keyVersion: nil, invitation: invitation, joinedToday: true),
        ])
        let keyStore = SpyStorage(me.storage.data)
        scene.keyStore = keyStore
        let before = scene.defaults.data(forKey: ApprovalRecordStore.key(owner: me.userId, circleId: circleId))

        let outcome = await run(scene)

        XCTAssertEqual(outcome.delivered, [newcomer.userId])
        try assertTheNewcomerCanOpen(try XCTUnwrap(scene.server.puts.first), from: me, to: newcomer)
        XCTAssertEqual(scene.defaults.data(forKey: ApprovalRecordStore.key(owner: me.userId, circleId: circleId)), before)
        XCTAssertEqual(keyStore.writeCount, 0)
    }

    /// Behind (holds version 1 of a circle at 2): it seals nothing, and
    /// the banner still names the circle.
    func testABehindDeviceHandsOverNothing() async throws {
        let (me, owner, newcomer) = (Party("Maya"), Party("Omar"), Party("Nadia"))
        let invitation = try statement(by: owner, .invitationToAccount, about: newcomer, atVersion: 2)
        let scene = try scene(device: me, pinned: [owner], record: record([(owner, .preRound2Seed)]), rows: [
            row(me), row(owner, role: "owner"), row(newcomer, keyVersion: nil, invitation: invitation, joinedToday: true),
        ], keyVersion: 2)

        let outcome = await run(scene)

        XCTAssertTrue(scene.server.puts.isEmpty)
        XCTAssertEqual(outcome.stopped, "this device does not hand over in this circle")
        XCTAssertEqual(outcome.circleName, "Family")
    }

    /// Nothing is asked without everything the app's own pass would have: a
    /// live token, this account's email, this device's tag, and its record for
    /// the circle (read once the row has said which circle).
    func testNothingIsAskedWithoutAWorkingSessionOrTheAppsRecord() async throws {
        let (me, owner) = (Party("Maya"), Party("Omar"))
        let rows = [row(me), row(owner, role: "owner")]

        var expired = try scene(device: me, pinned: [owner], record: record([(owner, .preRound2Seed)]), rows: rows)
        expired.token = Self.token(sub: me.userId, expires: now.addingTimeInterval(10))
        let outcome = await run(expired)
        XCTAssertEqual(outcome.stopped, "session token expired")
        XCTAssertTrue(expired.server.requests.isEmpty, "an expired token is never refreshed here, nor used")

        let noRecord = try scene(device: Party("Ada"), pinned: [], record: record([]), rows: rows)
        noRecord.defaults.removeObject(forKey: ApprovalRecordStore.key(owner: noRecord.device.userId, circleId: circleId))
        let second = await run(noRecord)
        XCTAssertEqual(second.stopped, "no approval record for the circle")
        XCTAssertEqual(noRecord.server.requests.map { $0.url?.path },
                       ["/api/v1/notifications/\(noRecord.rowId)", "/api/v1/circles"],
                       "no record, no tombstones: the roster is not even read")

        var untagged = try scene(device: Party("Dee"), pinned: [owner], record: record([(owner, .preRound2Seed)]), rows: rows)
        untagged.tag = nil
        let fifth = await run(untagged)
        XCTAssertEqual(fifth.stopped, "no device tag yet", "the app has not stamped this device's records yet")
        XCTAssertTrue(untagged.server.requests.isEmpty)

        let otherAccount = try scene(device: Party("Bea"), pinned: [], record: record([]), rows: rows)
        otherAccount.defaults.set(UUID().uuidString.lowercased(), forKey: ExtensionBridgeKeys.accountUserId)
        let third = await run(otherAccount)
        XCTAssertEqual(third.stopped, "the app has not run since this account signed in")
        XCTAssertTrue(otherAccount.server.requests.isEmpty)

        let noEmail = try scene(device: Party("Cy"), pinned: [], record: record([]), rows: rows)
        noEmail.defaults.removeObject(forKey: ExtensionBridgeKeys.accountEmail)
        let fourth = await run(noEmail)
        XCTAssertNotNil(fourth.stopped)
        XCTAssertTrue(noEmail.server.requests.isEmpty, "the pass needs the email the app's pass uses")
    }

    /// The account in its one canonical form: the token's word and the
    /// app's for this account, in any spelling of its id, are this
    /// account; a token naming no id at all stops everything.
    func testTheAccountIsComparedInItsOneForm() async throws {
        let (me, owner) = (Party("Maya"), Party("Omar"))
        let rows = [row(me), row(owner, role: "owner")]
        var spelt = try scene(device: me, pinned: [owner], record: record([(owner, .preRound2Seed)]), rows: rows)
        spelt.token = Self.token(sub: me.userId.uppercased(), expires: now.addingTimeInterval(3600))
        spelt.defaults.set(me.userId.replacingOccurrences(of: "-", with: ""), forKey: ExtensionBridgeKeys.accountUserId)
        let outcome = await run(spelt)
        XCTAssertNotEqual(outcome.stopped, "token is for another account")
        XCTAssertNotEqual(outcome.stopped, "the app has not run since this account signed in")
        XCTAssertFalse(spelt.server.requests.isEmpty, "the pass ran")

        var notAnId = try scene(device: Party("Bea"), pinned: [], record: record([]), rows: rows)
        notAnId.token = Self.token(sub: "evil", expires: now.addingTimeInterval(3600))
        let stopped = await run(notAnId)
        XCTAssertEqual(stopped.stopped, "token is for another account")
        XCTAssertTrue(notAnId.server.requests.isEmpty)
    }

    /// The deadline bounds every request, and nothing is sent once it has passed.
    func testTheDeadlineBoundsEveryRequest() async throws {
        let (me, owner, newcomer) = (Party("Maya"), Party("Omar"), Party("Nadia"))
        let invitation = try statement(by: owner, .invitationToAccount, about: newcomer)
        let scene = try scene(device: me, pinned: [owner], record: record([(owner, .preRound2Seed)]), rows: [
            row(me), row(owner, role: "owner"), row(newcomer, keyVersion: nil, invitation: invitation, joinedToday: true),
        ])
        _ = await run(scene, deadline: 6)
        XCTAssertFalse(scene.server.requests.isEmpty)
        for request in scene.server.requests {
            XCTAssertLessThanOrEqual(request.timeoutInterval, 5.5, "never past the run's deadline")
        }

        let late = try self.scene(device: Party("Ada"), pinned: [], record: record([]), rows: [])
        let outcome = await run(late, pushId: circleId, deadline: 0.5)
        XCTAssertEqual(outcome.stopped, "circle list unavailable")
        XCTAssertTrue(late.server.requests.isEmpty, "out of time before the first request: none is sent")
    }

    /// An older server puts the circle id in `alert_id`. It is never read
    /// as a circle: no row answers to it, and the sweep hands over wherever
    /// the server flags a delivery due — here the newcomer's circle;
    /// unflagged, nothing past the list.
    func testAnOlderServersPushIsNeverReadAsACircle() async throws {
        let (me, owner, newcomer) = (Party("Maya"), Party("Omar"), Party("Nadia"))
        let invitation = try statement(by: owner, .invitationToAccount, about: newcomer)
        let rows = [row(me), row(owner, role: "owner"), row(newcomer, keyVersion: nil, invitation: invitation, joinedToday: true)]

        let flagged = try scene(device: me, pinned: [owner], record: record([(owner, .preRound2Seed)]), rows: rows,
                                deliveryNeeded: true)
        let outcome = await run(flagged, pushId: circleId)
        XCTAssertNil(outcome.circleId, "no row named a circle")
        XCTAssertEqual(outcome.delivered, [newcomer.userId], "the delivery_needed pass found it")
        XCTAssertNil(outcome.joinerName, "only a row names who joined")
        XCTAssertEqual(flagged.server.requests.first?.url?.path, "/api/v1/notifications/\(circleId)")

        let unflagged = try scene(device: Party("Ada"), pinned: [owner], record: record([(owner, .preRound2Seed)]), rows: rows)
        let second = await run(unflagged, pushId: circleId)
        XCTAssertEqual(second.delivered, [])
        XCTAssertEqual(unflagged.server.requests.compactMap { $0.url?.path },
                       ["/api/v1/notifications/\(circleId)", "/api/v1/circles"],
                       "the circle id in alert_id led nowhere: no roster read, nothing handed over")
    }

    /// Only ids go into request paths: anything else in `alert_id`, or as the
    /// row's circle, names no circle — the sweep alone runs.
    func testOnlyIdsGoIntoRequestPaths() async throws {
        let (me, owner) = (Party("Maya"), Party("Omar"))
        let scene = try scene(device: me, pinned: [owner], record: record([(owner, .preRound2Seed)]),
                              rows: [row(me), row(owner, role: "owner")])
        let odd = await run(scene, pushId: "../circles")
        XCTAssertNil(odd.circleId)
        XCTAssertEqual(scene.server.requests.compactMap { $0.url?.path }, ["/api/v1/circles"],
                       "no row read for a non-id; the sweep's list only")

        scene.server.responses["GET /api/v1/notifications/\(scene.rowId)"] = (200, ["success": true, "data": [
            "id": scene.rowId, "circle_id": "../../auth", "notification_type": "member_joined",
            "title": "New circle member", "is_read": false, "created_at": "2026-09-24T07:00:00Z",
        ]])
        let outcome = await run(scene)
        XCTAssertNil(outcome.circleId)
        XCTAssertFalse(scene.server.requests.contains { $0.url?.path.contains("..") == true || $0.url?.path.contains("auth") == true },
                       "a row's odd circle never reaches a path")
    }

    /// A row that is not about a join names no circle: only the sweep runs.
    func testARowThatIsNotAJoinNamesNoCircle() async throws {
        let (me, owner) = (Party("Maya"), Party("Omar"))
        let scene = try scene(device: me, pinned: [owner], record: record([(owner, .preRound2Seed)]),
                              rows: [row(me), row(owner, role: "owner")])
        scene.server.responses["GET /api/v1/notifications/\(scene.rowId)"] = (200, ["success": true, "data": [
            "id": scene.rowId, "circle_id": circleId, "notification_type": "circle_invite",
            "title": "Circle Invite", "is_read": false, "created_at": "2026-09-24T07:00:00Z",
        ]])

        let outcome = await run(scene)

        XCTAssertNil(outcome.circleId)
        XCTAssertEqual(scene.server.requests.compactMap { $0.url?.path },
                       ["/api/v1/notifications/\(scene.rowId)", "/api/v1/circles"], "the row, then the sweep's list")
    }

    // MARK: - Any visible push

    /// Which run a push starts: "Notify my circle" (sos*) none at all — its
    /// banner goes first and alone; a join, its row's circle; anything else a
    /// sweep of the circles where a delivery is due.
    func testEveryVisiblePushButNotifyMyCircleStartsARun() {
        for sos in ["sos", "sos_alert", "sos_acknowledged", "sos_resolved"] {
            XCTAssertNil(BackgroundHandover.trigger(alertType: sos, alertId: UUID().uuidString), sos)
        }
        XCTAssertEqual(BackgroundHandover.trigger(alertType: "member_joined", alertId: "row-1"), .join(pushId: "row-1"))
        for other in ["place_alert_enter", "circle_invite", "quick_note", "key_rotation_required", "destination_arrival", ""] {
            XCTAssertEqual(BackgroundHandover.trigger(alertType: other, alertId: "x"), .sweep, other)
        }
        XCTAssertEqual(BackgroundHandover.trigger(alertType: "member_joined", alertId: nil), .sweep)
    }

    /// Any other push sweeps: only a circle the server flags `delivery_needed`
    /// is looked at, and there the app's rules decide who gets it — here the
    /// newcomer who asked for a fresh copy (an access request, with no
    /// notification of its own).
    func testAnyOtherPushHandsOverWhereADeliveryIsDue() async throws {
        let (me, owner, newcomer) = (Party("Maya"), Party("Omar"), Party("Nadia"))
        let invitation = try statement(by: owner, .invitationToAccount, about: newcomer)
        let quiet = UUID().uuidString.lowercased()
        let scene = try scene(device: me, pinned: [owner], record: record([(owner, .preRound2Seed)]), rows: [
            row(me), row(owner, role: "owner"), row(newcomer, keyVersion: nil, invitation: invitation, joinedToday: true),
        ], deliveryNeeded: true, otherCircles: [[
            "id": quiet, "owner_id": owner.userId, "is_owner": false,
            "encrypted_name": ["nonce": "00", "ciphertext": "00"], "day_bucket": 20_000, "member_count": 2,
            "key_version": 1, "member_key_version": 1,
        ]])

        let outcome = await BackgroundHandover.run(.sweep, deadline: now.addingTimeInterval(20), env: scene.environment(clock: now))

        XCTAssertEqual(outcome.delivered, [newcomer.userId])
        XCTAssertEqual(scene.server.requests.compactMap { $0.url?.path }, [
            "/api/v1/circles", "/api/v1/circles/\(circleId)/members",
            "/api/v1/circles/\(circleId)/members/\(newcomer.userId)/access",
        ], "the flagged circle only; the quiet one is not even read")
        XCTAssertNotNil(outcome.timings["total"])
        XCTAssertGreaterThan(outcome.peakFootprintMB, 0)
    }

    /// Nothing flagged: the circle list and nothing more.
    func testASweepWithNothingDueReadsOnlyTheCircleList() async throws {
        let (me, owner) = (Party("Maya"), Party("Omar"))
        let scene = try scene(device: me, pinned: [owner], record: record([(owner, .preRound2Seed)]),
                              rows: [row(me), row(owner, role: "owner")])
        let outcome = await BackgroundHandover.run(.sweep, deadline: now.addingTimeInterval(20), env: scene.environment(clock: now))
        XCTAssertNil(outcome.stopped)
        XCTAssertEqual(scene.server.requests.compactMap { $0.url?.path }, ["/api/v1/circles"])
    }

    // MARK: - The push picks the circle, never who

    /// The row may name anyone as the joiner: recipients still come from the
    /// roster and the rules alone. Here it names the owner (who holds a copy)
    /// while the newcomer is owed one, and then a member this device keeps out.
    func testThePushNeverChoosesWhoIsHandedTheCircle() async throws {
        let (me, owner, newcomer, ghost) = (Party("Maya"), Party("Omar"), Party("Nadia"), Party("Gus"))
        let invitation = try statement(by: owner, .invitationToAccount, about: newcomer)
        let rows = [row(me), row(owner, role: "owner"), row(ghost, keyVersion: nil),
                    row(newcomer, keyVersion: nil, invitation: invitation, joinedToday: true)]

        let namesOwner = try scene(device: me, pinned: [owner], record: record([(owner, .preRound2Seed)]),
                                   rows: rows, joined: owner)
        let first = await run(namesOwner)
        XCTAssertEqual(first.delivered, [newcomer.userId], "the owed newcomer, not whoever the row names")

        let namesGhost = try scene(device: Party("Ada"), pinned: [owner], record: record([(owner, .preRound2Seed)]),
                                   rows: rows, joined: ghost)
        let second = await run(namesGhost)
        XCTAssertFalse(second.delivered.contains(ghost.userId), "a member kept out is handed nothing, named or not")
        XCTAssertNil(second.joinerName)
    }

    // MARK: - The app's trust state, re-read and complete

    /// The upgrade moves the records into the app group, and binds them to this
    /// device (its keychain is still there), losslessly: the same roster decides
    /// the same way before and after — origins, tombstones, invitees and
    /// receive-only keys included.
    @MainActor
    func testTheMoveToTheAppGroupDecidesExactlyAsBefore() throws {
        let (me, owner, newcomer, gone, emailed) = (Party("Maya"), Party("Omar"), Party("Nadia"), Party("Gil"), Party("Eve"))
        let invitation = try statement(by: owner, .invitationToAccount, about: newcomer)
        var stored = record([(owner, .preRound2Seed), (emailed, .kind2)])
        stored.entries[me.userId] = .ownAction
        stored.receiveOnlyKeys[emailed.userId] = MemberKeyPair(sharingKeyHex: emailed.sharing, signingKeyHex: emailed.signing)
        stored.tombstones[gone.userId] = ApprovalTombstone(statementIds: ["s-old"], activeVersion: 1)
        let invitationId = try me.sdk.parseMembershipStatement(
            statementHex: XCTUnwrap(invitation["statement"] as? String)).statementId
        stored.recordInvitee(userId: newcomer.userId, statementId: invitationId,
                             expiresAt: Int64(now.timeIntervalSince1970) + 604_800)
        let oldName = "BackgroundHandoverTests.old.\(UUID().uuidString)"
        let groupName = "BackgroundHandoverTests.group.\(UUID().uuidString)"
        suites += [oldName, groupName]
        let old = try XCTUnwrap(UserDefaults(suiteName: oldName))
        old.set(try JSONEncoder().encode(stored), forKey: ApprovalRecordStore.key(owner: me.userId, circleId: circleId))

        let creation = try me.sdk.prepareCircleCreation()
        try me.sdk.finalizeCircleCreation(tempCircleId: creation.tempCircleId, realCircleId: circleId)
        _ = try me.sdk.pinMemberKeys(circleId: circleId, userId: owner.userId,
                                     sharingPubkeyHex: owner.sharing, signingPubkeyHex: owner.signing)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let roster = try decoder.decode([CircleMemberResponse].self, from: JSONSerialization.data(withJSONObject: [
            row(me), row(owner, role: "owner"), row(emailed, keyVersion: nil),
            row(newcomer, keyVersion: nil, invitation: invitation),
        ]))
        func decide(_ stored: CircleApprovalRecord) -> (AccessHandover.RosterPass, [String]) {
            let pass = AccessHandover.rosterPass(
                circleId: circleId, me: .own(userId: me.userId, email: me.email, crypto: me.sdk), roster: roster,
                rosterComplete: true, activeVersion: 1, stored: stored, checker: me.sdk)
            let targets = AccessHandover.deliveries(
                me: me.userId, circleKeyVersion: 1, heldVersion: 1, createdHere: false,
                members: roster.map { AccessHandover.Member(userId: $0.userId, displayName: "m",
                                                            sharingKeyHex: $0.sharingPublicKey, signingKeyHex: $0.signingPublicKey) },
                candidates: pass.candidates, result: pass.result, record: pass.record, now: now,
                pinGate: AccessHandover.readOnlyPinGate(
                    me: me.userId, circleId: circleId,
                    pinnedSharing: { me.sdk.pinnedSharingKey(circleId: $0, userId: $1) },
                    pinnedSigning: { me.sdk.pinnedSigningKey(circleId: $0, userId: $1) }))
            return (pass, targets.map(\.userId).sorted())
        }
        // Before: the record as a build before the move read it, from the app's
        // own defaults.
        let before = decide(try JSONDecoder().decode(CircleApprovalRecord.self, from: XCTUnwrap(
            old.data(forKey: ApprovalRecordStore.key(owner: me.userId, circleId: circleId)))))
        let moved = KeyDeliveryApprovals.movedToAppGroup(from: old, suiteName: groupName)
        XCTAssertTrue(KeyDeliveryApprovals.bindToThisDevice(moved, tag: { nil }, createTag: { Self.deviceTag },
                                                            keychainIsThisDevices: true,
                                                            lock: AppGroupLock(url: FileManager.default.temporaryDirectory
                                                                .appendingPathComponent("approvals-\(UUID().uuidString).lock"))))
        let after = decide(KeyDeliveryApprovals(defaults: moved, deviceTag: { Self.deviceTag }, lock: nil)
            .record(owner: me.userId, circleId: circleId))
        XCTAssertEqual(after.0.result, before.0.result)
        var untagged = after.0.record
        untagged.deviceTag = nil
        XCTAssertEqual(untagged, before.0.record)
        XCTAssertEqual(after.0.record.deviceTag, Self.deviceTag, "now this device's")
        XCTAssertEqual(after.1, before.1)
        XCTAssertEqual(before.1, [newcomer.userId],
                       "the invitee chosen here is owed it; a receive-only member without evidence is not, by a plain member")
        XCTAssertEqual(after.0.record.tombstones[gone.userId]?.statementIds, ["s-old"])
        XCTAssertNil(old.object(forKey: ApprovalRecordStore.key(owner: me.userId, circleId: circleId)), "one-way")
    }

    /// A record there but unreadable, or one kept for another account, decides
    /// nothing.
    func testAnUnreadableOrForeignRecordDecidesNothing() async throws {
        let (me, owner, newcomer) = (Party("Maya"), Party("Omar"), Party("Nadia"))
        let invitation = try statement(by: owner, .invitationToAccount, about: newcomer)
        let rows = [row(me), row(owner, role: "owner"), row(newcomer, keyVersion: nil, invitation: invitation)]

        let unreadable = try scene(device: me, pinned: [owner], record: record([(owner, .preRound2Seed)]), rows: rows)
        unreadable.defaults.set(Data("from a newer build".utf8), forKey: ApprovalRecordStore.key(owner: me.userId, circleId: circleId))
        let first = await run(unreadable)
        XCTAssertEqual(first.stopped, "no approval record for the circle")
        XCTAssertTrue(unreadable.server.puts.isEmpty)

        let other = Party("Ada")
        let foreign = try scene(device: other, pinned: [owner], record: record([(owner, .preRound2Seed)]), rows: rows)
        let data = foreign.defaults.data(forKey: ApprovalRecordStore.key(owner: other.userId, circleId: circleId))
        foreign.defaults.removeObject(forKey: ApprovalRecordStore.key(owner: other.userId, circleId: circleId))
        foreign.defaults.set(data, forKey: ApprovalRecordStore.key(owner: UUID().uuidString.lowercased(), circleId: circleId))
        let second = await run(foreign)
        XCTAssertEqual(second.stopped, "no approval record for the circle", "another account's record is not this one's")
        XCTAssertTrue(foreign.server.puts.isEmpty)
    }

    /// Pins that are there but do not read fail the run: the SDK would carry on
    /// with NO pins, and every member would look like first contact.
    func testUnreadablePinsFailInsteadOfReadingAsNone() throws {
        let sdk = CryptoManager()
        let storage = SpyStorage()
        sdk.registerSecureStorage(storage: storage)
        _ = sdk.generateKeypair()
        let owner = Party("Omar")
        _ = try sdk.pinMemberKeys(circleId: circleId, userId: owner.userId,
                                  sharingPubkeyHex: owner.sharing, signingPubkeyHex: owner.signing)
        let pins = try XCTUnwrap(storage.data?.pinnedKeysJson)
        XCTAssertNoThrow(try ExtensionKeyStorage.checkPins(pins), "the SDK's own pin set reads")
        XCTAssertThrowsError(try ExtensionKeyStorage.checkPins("{not json"))
        XCTAssertThrowsError(try ExtensionKeyStorage.checkPins(#"{"c:u":{"sharing_pubkey_hex":"aa"}}"#), "a pin missing its fields")
        XCTAssertNoThrow(try ExtensionKeyStorage.checkPins("{}"), "no pins at all is a readable state")
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("NotificationExtension/BackgroundHandover.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("manager.registerSecureStorage(storage: ExtensionKeyStorage())"),
                      "the extension itself reads through the strict store")
    }

    /// A member this device confirmed whose keys changed (a password reset) is
    /// not handed the circle — the pin gate blocks them, as in the app, and the
    /// question stays the app's to ask.
    func testAChangedIdentityIsNotHandedTheCircle() async throws {
        let (me, member, reset) = (Party("Maya"), Party("Rui"), Party("Rui"))
        var stored = record([(member, .statement)])
        stored.entries[me.userId] = .ownAction
        var memberRow = row(reset, keyVersion: nil)
        memberRow["user_id"] = member.userId
        let scene = try scene(device: me, pinned: [member], record: stored,
                              rows: [row(me, role: "owner"), memberRow], isOwner: true)

        let outcome = await run(scene)

        XCTAssertTrue(scene.server.puts.isEmpty, "keys other than the pin are never wrapped to")
        XCTAssertEqual(outcome.delivered, [])
    }

    /// A receive-only member the record holds without their keys (confirmed
    /// before they had any) is handed the circle with the keys the app would
    /// record on this roster — in memory only.
    func testAReceiveOnlyMembersFirstKeysCountForThisRunOnly() async throws {
        let (me, newcomer) = (Party("Maya"), Party("Nadia"))
        var stored = record([(newcomer, .ownKind2)])
        stored.entries[me.userId] = .ownAction
        let scene = try scene(device: me, pinned: [], record: stored,
                              rows: [row(me, role: "owner"), row(newcomer, keyVersion: nil, joinedToday: true)],
                              isOwner: true)
        let before = scene.defaults.data(forKey: ApprovalRecordStore.key(owner: me.userId, circleId: circleId))

        let outcome = await run(scene)

        XCTAssertEqual(outcome.delivered, [newcomer.userId])
        try assertTheNewcomerCanOpen(try XCTUnwrap(scene.server.puts.first), from: me, to: newcomer)
        XCTAssertEqual(scene.defaults.data(forKey: ApprovalRecordStore.key(owner: me.userId, circleId: circleId)), before,
                       "the app records their keys on its next roster load")
    }

    /// A device the server says holds the current version but that has not
    /// installed it yet seals nothing: exactly the current version, or
    /// nothing.
    func testADeviceHoldingAnOlderVersionSealsNothing() async throws {
        let (me, owner, newcomer) = (Party("Maya"), Party("Omar"), Party("Nadia"))
        let invitation = try statement(by: owner, .invitationToAccount, about: newcomer, atVersion: 2)
        let scene = try scene(device: me, pinned: [owner], record: record([(owner, .preRound2Seed)]), rows: [
            row(me, keyVersion: 2), row(owner, role: "owner", keyVersion: 2),
            row(newcomer, keyVersion: nil, invitation: invitation, joinedToday: true),
        ], keyVersion: 2, memberKeyVersion: 2)

        let outcome = await run(scene)

        XCTAssertEqual(outcome.circleName, "Family", "the circle opens here…")
        XCTAssertTrue(scene.server.puts.isEmpty, "…but this device holds version 1 of 2")
    }

    /// The roster pass tombstones whoever left, before it confirms anyone.
    func testTheRosterPassTombstonesTheDeparted() throws {
        let (me, owner, gone) = (Party("Maya"), Party("Omar"), Party("Gil"))
        var stored = record([(owner, .preRound2Seed), (gone, .statement)])
        stored.statementIds[gone.userId] = ["s-1"]
        let rows = [row(me), row(owner, role: "owner")]
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let roster = try decoder.decode([CircleMemberResponse].self, from: JSONSerialization.data(withJSONObject: rows))

        let complete = AccessHandover.rosterPass(
            circleId: circleId, me: .own(userId: me.userId, email: me.email, crypto: me.sdk), roster: roster,
            rosterComplete: true, activeVersion: 3, stored: stored, checker: me.sdk)
        XCTAssertNil(complete.record.entries[gone.userId])
        XCTAssertEqual(complete.record.tombstones[gone.userId], ApprovalTombstone(statementIds: ["s-1"], activeVersion: 3))

        let partial = AccessHandover.rosterPass(
            circleId: circleId, me: .own(userId: me.userId, email: me.email, crypto: me.sdk), roster: roster,
            rosterComplete: false, activeVersion: 3, stored: stored, checker: me.sdk)
        XCTAssertEqual(partial.record.entries[gone.userId], .statement, "a partial roster says nothing about who left")
    }

    /// The app's token ran out: the run goes on with a refreshed one
    /// (`ExtensionSessionRefresh`) — and without one, only the banner.
    func testAnExpiredTokenIsRefreshedBeforeTheHandover() async throws {
        let (me, owner, newcomer) = (Party("Maya"), Party("Omar"), Party("Nadia"))
        let invitation = try statement(by: owner, .invitationToAccount, about: newcomer)
        var scene = try scene(device: me, pinned: [owner], record: record([(owner, .preRound2Seed)]), rows: [
            row(me), row(owner, role: "owner"), row(newcomer, keyVersion: nil, invitation: invitation, joinedToday: true),
        ])
        scene.token = Self.token(sub: me.userId, expires: now.addingTimeInterval(-60))
        var env = scene.environment(clock: now)
        let fresh = Self.token(sub: me.userId, expires: now.addingTimeInterval(86_400))
        env.refreshedToken = { fresh }
        let outcome = await BackgroundHandover.run(pushId: scene.rowId, deadline: now.addingTimeInterval(20), env: env)
        XCTAssertTrue(outcome.refreshed)
        XCTAssertEqual(outcome.delivered, [newcomer.userId])
        XCTAssertEqual(scene.server.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer \(fresh)",
                       "every request carries the refreshed token")

        env.refreshedToken = { nil }
        let without = await BackgroundHandover.run(pushId: scene.rowId, deadline: now.addingTimeInterval(20), env: env)
        XCTAssertEqual(without.stopped, "session token expired")
    }

    // MARK: - What the extension records: who left, and only that

    /// A member this device chose leaves while only the extension is running: it
    /// records them gone. The app, restarted, and the extension's next run both
    /// refuse them when the server lists them again with no copy — the control
    /// shows the unchanged record would have handed it to them.
    func testADepartureSeenOnlyByTheExtensionIsStillRefusedAfterAnAppRestart() async throws {
        let (me, member, gone) = (Party("Maya"), Party("Omar"), Party("Gil"))
        var original = record([(member, .statement), (gone, .ownAction)])
        original.entries[me.userId] = .ownAction
        original.statementIds[gone.userId] = ["s-gil"]
        var scene = try scene(device: me, pinned: [member, gone], record: original,
                              rows: [row(me, role: "owner"), row(member)], isOwner: true)
        let keyStore = SpyStorage(me.storage.data)
        scene.keyStore = keyStore

        let first = await run(scene)

        XCTAssertNil(first.stopped)
        XCTAssertEqual(first.delivered, [])
        XCTAssertEqual(keyStore.writeCount, 0, "no key and no pin written")
        guard case .record(let kept) = ApprovalRecordStore.stored(
            in: scene.defaults, owner: me.userId, circleId: circleId, deviceTag: Self.deviceTag) else {
            return XCTFail("the record is still this device's")
        }
        XCTAssertNil(kept.entries[gone.userId], "recorded gone")
        XCTAssertEqual(kept.tombstones[gone.userId], ApprovalTombstone(statementIds: ["s-gil"], activeVersion: 1))
        var rest = kept
        rest.entries[gone.userId] = original.entries[gone.userId]
        rest.statementIds = original.statementIds
        rest.tombstones = [:]
        var expectedRest = original
        expectedRest.deviceTag = Self.deviceTag
        XCTAssertEqual(rest, expectedRest, "nothing else about the record changed")

        // The server lists them again, holding no copy.
        let readded = [row(me, role: "owner"), row(member), row(gone, keyVersion: nil)]
        scene.server.responses["GET /api/v1/circles/\(circleId)/members"] = (200, ["success": true, "data": [
            "items": readded, "has_more": false,
        ]])
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let roster = try decoder.decode([CircleMemberResponse].self, from: JSONSerialization.data(withJSONObject: readded))
        func appTargets(_ stored: CircleApprovalRecord) -> [String] {
            let pass = AccessHandover.rosterPass(
                circleId: circleId, me: .own(userId: me.userId, email: me.email, crypto: me.sdk), roster: roster,
                rosterComplete: true, activeVersion: 1, stored: stored, checker: me.sdk)
            return AccessHandover.deliveries(
                me: me.userId, circleKeyVersion: 1, heldVersion: 1,
                createdHere: AccessHandover.createdHere(stored, me: me.userId),
                members: roster.map { AccessHandover.Member(userId: $0.userId, displayName: "m",
                                                            sharingKeyHex: $0.sharingPublicKey, signingKeyHex: $0.signingPublicKey) },
                candidates: pass.candidates, result: pass.result, record: pass.record, now: now,
                pinGate: AccessHandover.readOnlyPinGate(
                    me: me.userId, circleId: circleId,
                    pinnedSharing: { me.sdk.pinnedSharingKey(circleId: $0, userId: $1) },
                    pinnedSigning: { me.sdk.pinnedSigningKey(circleId: $0, userId: $1) })
            ).map(\.userId)
        }
        XCTAssertEqual(appTargets(original), [gone.userId], "control: the record as it was would hand it to them")
        let restarted = await MainActor.run {
            KeyDeliveryApprovals(defaults: scene.defaults, deviceTag: { Self.deviceTag }, lock: scene.lock)
                .record(owner: me.userId, circleId: circleId)
        }
        XCTAssertEqual(appTargets(restarted), [], "the app, restarted, refuses them")

        let second = await run(scene)
        XCTAssertFalse(scene.server.puts.contains { $0.url?.path.contains(gone.userId) == true },
                       "and so does the extension's next run")
        XCTAssertEqual(second.delivered, [])
        XCTAssertEqual(keyStore.writeCount, 0)
    }

    /// Departures that cannot be recorded (the lock not had) hand nobody
    /// anything: the extension never acts on a decision it could not record.
    func testNothingIsHandedOverWhenADepartureCannotBeRecorded() async throws {
        let (me, owner, gone, newcomer) = (Party("Maya"), Party("Omar"), Party("Gil"), Party("Nadia"))
        let invitation = try statement(by: owner, .invitationToAccount, about: newcomer)
        let scene = try scene(device: me, pinned: [owner, gone], record: record([(owner, .preRound2Seed), (gone, .statement)]),
                              rows: [row(me), row(owner, role: "owner"),
                                     row(newcomer, keyVersion: nil, invitation: invitation, joinedToday: true)])
        let before = scene.defaults.data(forKey: ApprovalRecordStore.key(owner: me.userId, circleId: circleId))
        let taken = await AppGroupLock(url: scene.lock.url).acquire(timeout: 1)
        let holder = try XCTUnwrap(taken, "another process holds the approvals lock")
        defer { holder.release() }

        let outcome = await run(scene)

        XCTAssertEqual(outcome.stopped, "departures not recorded")
        XCTAssertTrue(scene.server.puts.isEmpty, "the newcomer waits for a run that can record the departure")
        XCTAssertEqual(scene.defaults.data(forKey: ApprovalRecordStore.key(owner: me.userId, circleId: circleId)), before)
    }

    /// A record this device did not make — restored from another phone's
    /// backup (another tag), or never stamped (no tag) — decides nothing.
    func testARecordFromAnotherDeviceDecidesNothing() async throws {
        let (me, owner, newcomer) = (Party("Maya"), Party("Omar"), Party("Nadia"))
        let invitation = try statement(by: owner, .invitationToAccount, about: newcomer)
        let rows = [row(me), row(owner, role: "owner"), row(newcomer, keyVersion: nil, invitation: invitation, joinedToday: true)]
        var elsewhere = record([(owner, .preRound2Seed)])
        elsewhere.deviceTag = "another-phones-tag"

        let restored = try scene(device: me, pinned: [owner], record: elsewhere, rows: rows)
        let first = await run(restored)
        XCTAssertEqual(first.stopped, "no approval record for the circle")
        XCTAssertTrue(restored.server.puts.isEmpty)

        let untagged = try scene(device: Party("Ada"), pinned: [owner], record: record([(owner, .preRound2Seed)]), rows: rows)
        untagged.defaults.set(try JSONEncoder().encode(record([(owner, .preRound2Seed)])),
                              forKey: ApprovalRecordStore.key(owner: untagged.device.userId, circleId: circleId))
        let second = await run(untagged)
        XCTAssertEqual(second.stopped, "no approval record for the circle")
        XCTAssertTrue(untagged.server.puts.isEmpty)

        let control = try scene(device: Party("Bo"), pinned: [owner], record: record([(owner, .preRound2Seed)]), rows: rows)
        let third = await run(control)
        XCTAssertEqual(third.delivered, [newcomer.userId], "control: this device's own record hands it over")
    }

    /// The server's word that this device's user owns or administers the
    /// circle widens nothing: a confirmed member with no copy and no fresh
    /// evidence is handed the circle only by the device whose own record
    /// says it created it.
    func testARoleTheServerListsDoesNotWidenDelivery() async throws {
        let (me, owner, member) = (Party("Maya"), Party("Omar"), Party("Rui"))
        let rows = [row(me, role: "admin"), row(owner, role: "owner"), row(member, keyVersion: nil)]

        let said = try scene(device: me, pinned: [owner, member],
                             record: record([(owner, .preRound2Seed), (member, .statement)]), rows: rows, isOwner: true)
        let first = await run(said)
        XCTAssertEqual(first.delivered, [], "admin and is_owner are the server's word")
        XCTAssertTrue(said.server.puts.isEmpty)

        let creator = Party("Ada")
        var created = record([(owner, .preRound2Seed), (member, .statement)])
        created.entries[creator.userId] = .ownAction
        let made = try scene(device: creator, pinned: [owner, member], record: created,
                             rows: [row(creator), row(owner, role: "owner"), row(member, keyVersion: nil)])
        let second = await run(made)
        XCTAssertEqual(second.delivered, [member.userId], "this device's own record says it created the circle")
    }

    // MARK: - The banner

    func testTheBannerNamesOnlyWhatTheDetailLevelAllows() {
        XCTAssertEqual(MemberJoinedCopy.body(member: "Nadia", circle: "Family", level: "full"), "Nadia joined Family.")
        XCTAssertEqual(MemberJoinedCopy.body(member: "Nadia", circle: "Family", level: nil), "Nadia joined Family.")
        XCTAssertEqual(MemberJoinedCopy.body(member: "Nadia", circle: "Family", level: "names"), "Nadia joined your circle.")
        XCTAssertNil(MemberJoinedCopy.body(member: "Nadia", circle: "Family", level: "generic"),
                     "generic keeps the server's words, which name nobody")
        XCTAssertEqual(MemberJoinedCopy.body(member: nil, circle: "Family", level: "full"), "A new member joined Family.")
        XCTAssertNil(MemberJoinedCopy.body(member: nil, circle: "Family", level: "names"))
        XCTAssertNil(MemberJoinedCopy.body(member: nil, circle: nil, level: "full"))
        XCTAssertNil(MemberJoinedCopy.body(member: "", circle: "", level: "full"))
    }

    /// Whichever finishes first — the handover or the time limit — the banner
    /// goes to iOS once.
    func testTheBannerIsHandedOverOnce() {
        var delivered: [String] = []
        let once = DeliverOnce { delivered.append($0.body) }
        let first = UNMutableNotificationContent()
        first.body = "Nadia joined Family."
        let second = UNMutableNotificationContent()
        second.body = "A new member joined your circle"
        once(first)
        once(second)
        XCTAssertEqual(delivered, ["Nadia joined Family."])
    }

    // MARK: - Read-only, by construction

    /// The body of the function declared by `signature` in `code`: from its
    /// first `{` to the brace that closes it.
    private static func body(of signature: String, in code: String) -> String? {
        guard let start = code.range(of: signature),
              let open = code[start.upperBound...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var index = open
        while index < code.endIndex {
            switch code[index] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return String(code[open...index]) }
            default: break
            }
            index = code.index(after: index)
        }
        return nil
    }

    /// Nothing the extension compiles can write a key or a pin, or add to a
    /// record: none of the SDK's writing calls, no keychain write, no defaults
    /// write — in its own files and in the app files it shares (project.yml).
    /// Two exceptions, each confined to one function: the refreshed session
    /// pair, and departures — `persistDepartures`, which does nothing to a
    /// record but `depart`, which only takes trust away
    /// (ApprovalRecordStoreTests).
    func testTheExtensionHasNoWayToWriteKeysPinsOrRecords() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let project = try String(contentsOf: root.appendingPathComponent("project.yml"), encoding: .utf8)
        let section = try XCTUnwrap(project.components(separatedBy: "  NotificationExtension:\n").dropFirst().first?
            .components(separatedBy: "\n  TrackTests:").first)
        let shared = section.components(separatedBy: "\n").compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- path: App/") else { return nil }
            return String(trimmed.dropFirst("- path: ".count))
        }
        XCTAssertTrue(shared.contains("App/Managers/AccessHandover.swift"))
        XCTAssertTrue(shared.contains("App/Managers/MembershipConfirmation.swift"))
        XCTAssertTrue(shared.contains("App/Managers/ApprovalRecord.swift"))
        let extensionDir = root.appendingPathComponent("NotificationExtension")
        let own = try FileManager.default.contentsOfDirectory(atPath: extensionDir.path)
            .filter { $0.hasSuffix(".swift") }.map { "NotificationExtension/\($0)" }
        let writes = [
            "pinMemberKeys(", "retainMemberPins(", "approveMemberKeyChange(", "storeCircleKey(", "storeFirstCircleKey(",
            "importPreviousIdentities(", "beginBulkKeyImport(", "endBulkKeyImport(", "signMembership",
            "signInvitation", "signOwnCircleKeyWrap(", "signCircleCreationWrap(", "finalizeCircleCreation(",
            "SecItemAdd", "SecItemUpdate", "SecItemDelete", "KeychainService", "KeyDeliveryApprovals",
            "MemberKeyPinner", ".set(", "removeObject(", "removePersistentDomain(",
        ]
        var sawDepartures = false
        var sawSessionPair = false
        for path in own + shared {
            let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            var code = source.components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
            // A refreshed SESSION pair over the app's two token items, in
            // the one function that saves it (ExtensionSessionRefreshTests).
            if path == "NotificationExtension/ExtensionSessionRefresh.swift" {
                let save = try XCTUnwrap(Self.body(of: "static func saveRefreshedPair(", in: code))
                XCTAssertEqual(save.components(separatedBy: "SecItemUpdate(").count - 1, 1, "one keychain write")
                XCTAssertTrue(save.contains(#"update("refresh_token", refresh)"#) && save.contains(#"update("access_token", access)"#),
                              "the two token items, nothing else")
                code = code.replacingOccurrences(of: save, with: "")
                sawSessionPair = true
            }
            // Departures, in the one function that records them: one write, of
            // the record with `depart` applied — nothing that adds trust.
            if path == "App/Managers/ApprovalRecord.swift" {
                let persist = try XCTUnwrap(Self.body(of: "static func persistDepartures(", in: code))
                XCTAssertEqual(persist.components(separatedBy: ".set(").count - 1, 1, "one defaults write")
                XCTAssertEqual(persist.components(separatedBy: "record.").count - 1, 1, "one change to the record…")
                XCTAssertTrue(persist.contains("record.depart(userId, tombstone: tombstone)"), "…a departure")
                for adds in ["approve(", "rememberReceiveOnlyKeys(", "retain(", "merged(", "entries", "invitees",
                             "recordInvitee(", "settleInvitees(", "applySeed(", "seedCandidates", "deadStatementIds",
                             "receiveOnlyKeys", "backfilled", "admissionsOwed", "deviceTag =", "removeObject("] {
                    XCTAssertFalse(persist.contains(adds), "persistDepartures must not touch \(adds)")
                }
                code = code.replacingOccurrences(of: persist, with: "")
                sawDepartures = true
            }
            for call in writes {
                XCTAssertFalse(code.contains(call), "\(path) must not call \(call)")
            }
        }
        XCTAssertTrue(sawDepartures && sawSessionPair, "both exceptions were looked at")
        // The app and the extension decide through the same function; the app's
        // pin gate is the pinner, the extension's the read-only one.
        let circles = try String(contentsOf: root.appendingPathComponent("App/Managers/CircleManager.swift"), encoding: .utf8)
        let handover = try String(contentsOf: extensionDir.appendingPathComponent("BackgroundHandover.swift"), encoding: .utf8)
        XCTAssertTrue(circles.contains("let targets = AccessHandover.deliveries("))
        XCTAssertTrue(circles.contains("pinGate: { MemberKeyPinner.shared.gateMembersForRotation(circleId: circleId, currentUserId: me, members: $0) })\n        guard !targets.isEmpty else { return }"),
                      "the app's delivery goes through the pinner")
        XCTAssertEqual(circles.components(separatedBy: "pinGate: { MemberKeyPinner.shared.gateMembersForRotation(").count - 1, 2,
                       "delivery and the rotation's gate, nothing else")
        XCTAssertTrue(circles.contains("var pass = AccessHandover.rosterPass("))
        XCTAssertTrue(handover.contains("targets = AccessHandover.deliveries("))
        XCTAssertTrue(handover.contains("pinGate: AccessHandover.readOnlyPinGate("))
        XCTAssertTrue(handover.contains("let decided = AccessHandover.rosterPass("))
        // The key store the extension reads with drops every write.
        let storage = try String(contentsOf: extensionDir.appendingPathComponent("ExtensionKeyStorage.swift"), encoding: .utf8)
        XCTAssertTrue(storage.contains("func storeKeys(data: StoredKeyData) throws {}"))
        XCTAssertTrue(storage.contains("func deleteKeys() throws {}"))
    }
}
