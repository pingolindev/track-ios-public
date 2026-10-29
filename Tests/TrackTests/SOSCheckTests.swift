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

/// An SOS push is checked in the notification extension before it rings.
/// Can't check → the server's own loud alert; checked and not live → the
/// quiet notice; current or sticky → the real alarm.
///
/// Real keys and sealed SOS rows; the network is a stub, the key store a copy
/// of this device's, the app group a scratch suite and the marks a scratch
/// folder.
final class SOSCheckTests: XCTestCase {
    private let circleId = "c5050000-0000-4000-8000-0000000000aa"
    private let sosId = "c5050000-0000-4000-8000-0000000000f1"
    private let base = "https://track.test"
    private let now = Date()
    private var nowMs: Int64 { Int64(now.timeIntervalSince1970 * 1000) }

    // MARK: - Fixtures

    private final class Storage: KeyStorageCallback, @unchecked Sendable {
        private let lock = NSLock()
        private var stored: StoredKeyData?
        init(_ data: StoredKeyData? = nil) { stored = data }
        var data: StoredKeyData? { lock.lock(); defer { lock.unlock() }; return stored }
        func loadKeys() throws -> StoredKeyData? { data }
        func storeKeys(data: StoredKeyData) throws { lock.lock(); stored = data; lock.unlock() }
        func deleteKeys() throws { lock.lock(); stored = nil; lock.unlock() }
    }

    private static func hex(_ b64: String) -> String {
        Data(base64Encoded: b64)!.map { String(format: "%02x", $0) }.joined()
    }

    private struct Party {
        let userId: String
        let name: String
        let storage = Storage()
        let sdk = CryptoManager()
        let sharing: String
        let signing: String

        init(_ name: String, _ userId: String) {
            self.name = name
            self.userId = userId
            sdk.registerSecureStorage(storage: storage)
            sharing = SOSCheckTests.hex(sdk.generateKeypair().publicKey)
            signing = SOSCheckTests.hex(sdk.generateSigningKeypair().verifyingKeyB64)
        }
    }

    /// The owner makes v1 and gives it to this device and to one it later
    /// leaves out; v2 goes to the owner alone; v3 to the owner and this
    /// device, which seals under v3. `fourth`: the owner rotates once more,
    /// alone (v4: this device is behind).
    private func world(fourth: Bool = false) throws -> (owner: Party, me: Party, leftOut: Party) {
        let owner = Party("Olivia", "c5050000-0000-4000-8000-00000000000a")
        let me = Party("Me", "c5050000-0000-4000-8000-00000000000b")
        let leftOut = Party("Leo", "c5050000-0000-4000-8000-00000000000c")
        func give(_ member: Party, _ bundle: MemberKeyBundle, _ version: Int32) throws {
            try member.sdk.storeCircleKey(
                circleId: circleId, encryptedKey: bundle.encryptedCircleKey.nonce + bundle.encryptedCircleKey.ciphertext,
                senderPublicKey: bundle.ephemeralPublicKey, keyVersion: version, senderUserId: owner.userId,
                recipientUserId: member.userId, wrapSignatureHex: bundle.wrapSignature,
                senderSigningPubkeyHex: owner.signing)
        }
        for member in [me, leftOut] {
            _ = try member.sdk.pinMemberKeys(circleId: circleId, userId: owner.userId,
                                             sharingPubkeyHex: owner.sharing, signingPubkeyHex: owner.signing)
        }
        let creation = try owner.sdk.prepareCircleCreation()
        try owner.sdk.finalizeCircleCreation(tempCircleId: creation.tempCircleId, realCircleId: circleId)
        for member in [me, leftOut] {
            try give(member, try owner.sdk.wrapCircleKeyForMemberFull(
                circleId: circleId, memberPublicKeyHex: member.sharing, senderUserId: owner.userId,
                recipientUserId: member.userId, recipientSigningPubkeyHex: member.signing), 1)
        }
        _ = try owner.sdk.prepareKeyRotation(
            circleId: circleId, senderUserId: owner.userId, memberUserIds: [owner.userId],
            memberPublicKeysHex: [owner.sharing], memberSigningPubkeysHex: [owner.signing],
            currentCircleNamePlaintext: "Family")
        let v3 = try owner.sdk.prepareKeyRotation(
            circleId: circleId, senderUserId: owner.userId, memberUserIds: [owner.userId, me.userId],
            memberPublicKeysHex: [owner.sharing, me.sharing], memberSigningPubkeysHex: [owner.signing, me.signing],
            currentCircleNamePlaintext: "Family")
        try give(me, try XCTUnwrap(v3.memberKeys.first { $0.userId == me.userId }).bundle, 3)
        if fourth {
            _ = try owner.sdk.prepareKeyRotation(
                circleId: circleId, senderUserId: owner.userId, memberUserIds: [owner.userId],
                memberPublicKeysHex: [owner.sharing], memberSigningPubkeysHex: [owner.signing],
                currentCircleNamePlaintext: "Family")
        }
        XCTAssertNotNil(me.storage.data, "this device's keys are on its store, as the app leaves them")
        return (owner, me, leftOut)
    }

    private func blob(_ e: EncryptedData) -> [String: Any] { ["nonce": e.nonce, "ciphertext": e.ciphertext] }

    /// One listed SOS, every part sealed by `by` (raised `ageMs` ago).
    private func sos(by sealer: CryptoManager, raiser: String, status: String = "active",
                     ageMs: Int64 = 60_000) throws -> [String: Any] {
        [
            "id": sosId, "circle_id": circleId, "status": status, "day_bucket": 20_000,
            "encrypted_user_id": blob(try sealer.encryptDataV2(circleId: circleId, plaintext: raiser, fieldTag: "user_id")),
            "encrypted_device_id": blob(try sealer.encryptDataV2(circleId: circleId, plaintext: "device-1",
                                                                 fieldTag: "device_id")),
            "encrypted_timestamp": blob(try sealer.encryptDataV2(circleId: circleId, plaintext: String(nowMs - ageMs),
                                                                 fieldTag: "timestamp")),
            "encrypted_location": blob(try sealer.encryptLocation(circleId: circleId, location: Location(
                latitude: 52.5, longitude: 13.4, altitude: nil, speed: nil, heading: nil, accuracy: 5,
                timestamp: nowMs - ageMs, batteryLevel: nil, isCharging: nil))),
        ]
    }

    private final class StubServer: HandoverTransport, @unchecked Sendable {
        private let lock = NSLock()
        var responses: [String: [(status: Int, body: Any)]] = [:]
        var raw: [String: Data] = [:]
        var offline = false
        private var seen: [String] = []
        var requests: [String] { lock.lock(); defer { lock.unlock() }; return seen }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let key = "\(request.httpMethod ?? "GET") \(request.url!.path)"
            lock.lock()
            seen.append(key)
            let queued = responses[key]
            if var queued, queued.count > 1 { queued.removeFirst(); responses[key] = queued }
            lock.unlock()
            if offline { throw URLError(.notConnectedToInternet) }
            func reply(_ status: Int, _ data: Data) -> (Data, HTTPURLResponse) {
                (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
            if let data = raw[key] { return reply(200, data) }
            let answer = queued?.first ?? (404, ["success": false])
            return reply(answer.status, try JSONSerialization.data(withJSONObject: answer.body))
        }
    }

    private static func token(sub: String, expires: Date = Date().addingTimeInterval(3600)) -> String {
        func b64(_ object: [String: Any]) -> String {
            try! JSONSerialization.data(withJSONObject: object).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return "\(b64(["alg": "RS256"])).\(b64(["sub": sub, "exp": Int(expires.timeIntervalSince1970)])).signature"
    }

    private var suites: [String] = []
    private var folders: [URL] = []

    override func tearDown() {
        for suite in suites { UserDefaults().removePersistentDomain(forName: suite) }
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
        super.tearDown()
    }

    private struct Scene {
        let me: Party
        let server = StubServer()
        let defaults: UserDefaults
        let marks: SOSAlarmMarks
        let marksFolder: URL
        var token: String?
        var refreshed: String?
        var keysReadable = true
        /// The key store holds an entry that doesn't read (`entriesUnreadable`).
        var unreadableEntry = false
        let lock = AppGroupLock(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("approvals-\(UUID().uuidString).lock"))

        func environment(clock: Date) -> BackgroundHandover.Environment {
            var persisted = me.storage.data
            if unreadableEntry, var data = persisted,
               var json = (try? JSONSerialization.jsonObject(with: Data(data.circleKeysJson.utf8))) as? [String: Any] {
                json["c1c1c1c1-0000-4000-8000-000000000001"] = ["9": "AAAA"]
                data.circleKeysJson = String(decoding: try! JSONSerialization.data(withJSONObject: json), as: UTF8.self)
                persisted = data
            }
            let (token, refreshed, readable, lock) = (token, refreshed, keysReadable, lock)
            return BackgroundHandover.Environment(
                accessToken: { token },
                refreshedToken: { refreshed },
                keychainUserId: { me.userId },
                shared: { defaults },
                deviceTag: { "device-tag" },
                approvalsLock: { lock },
                makeCrypto: {
                    guard readable else { return nil }
                    let manager = CryptoManager()
                    manager.registerSecureStorage(storage: Storage(persisted))
                    return (try? manager.loadPersistedKeys()) == true ? manager : nil
                },
                transport: server,
                now: { clock })
        }
    }

    /// This device, the server listing `listed`, the circle at `keyVersion`.
    private func scene(_ me: Party, listed: [[String: Any]], keyVersion: Int = 3,
                       record: CircleApprovalRecord? = nil, roster: [[String: Any]] = []) throws -> Scene {
        let suite = "SOSCheckTests.\(UUID().uuidString)"
        suites.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(me.userId, forKey: ExtensionBridgeKeys.accountUserId)
        defaults.set("me@example.com", forKey: ExtensionBridgeKeys.accountEmail)
        defaults.set(base, forKey: ExtensionBridgeKeys.apiBaseURL)
        if var record {
            record.deviceTag = "device-tag"
            defaults.set(try JSONEncoder().encode(record), forKey: ApprovalRecordStore.key(owner: me.userId, circleId: circleId))
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sos-check-\(UUID().uuidString)")
        folders.append(folder)
        let scene = Scene(me: me, defaults: defaults, marks: SOSAlarmMarks(directory: folder), marksFolder: folder,
                          token: Self.token(sub: me.userId))
        scene.server.responses["GET /api/v1/sos/active"] = [(200, ["success": true, "data": listed])]
        let name = try me.sdk.encryptDataV2(circleId: circleId, plaintext: "Family", fieldTag: "name")
        scene.server.responses["GET /api/v1/circles"] = [(200, ["success": true, "data": [
            "items": [[
                "id": circleId, "owner_id": "c5050000-0000-4000-8000-00000000000a", "is_owner": false,
                "encrypted_name": ["nonce": name.nonce, "ciphertext": name.ciphertext],
                "day_bucket": 20_000, "member_count": 2, "key_version": keyVersion,
            ]], "has_more": false,
        ]])]
        scene.server.responses["GET /api/v1/circles/\(circleId)/members"] = [(200, ["success": true, "data": [
            "items": roster, "has_more": false,
        ]])]
        return scene
    }

    private func check(_ scene: Scene, level: String? = nil, alertId: String? = nil,
                       budget: TimeInterval = SOSCheck.budget) async -> SOSCheck.Verdict {
        await SOSCheck.run(alertId: alertId ?? sosId, level: level, deadline: now.addingTimeInterval(budget),
                           env: scene.environment(clock: now), marks: scene.marks)
    }

    private func rings(_ scene: Scene, level: String? = nil, alertId: String? = nil,
                       budget: TimeInterval = SOSCheck.budget, _ why: String,
                       file: StaticString = #filePath, line: UInt = #line) async {
        let verdict = await check(scene, level: level, alertId: alertId, budget: budget)
        guard case .cantCheck = verdict else { return XCTFail("\(why): \(verdict)", file: file, line: line) }
    }

    private func quiet(_ scene: Scene, level: String? = nil, _ why: String,
                       file: StaticString = #filePath, line: UInt = #line) async {
        let verdict = await check(scene, level: level)
        guard case .refused = verdict else { return XCTFail("\(why): \(verdict)", file: file, line: line) }
    }

    private func alarms(_ scene: Scene, level: String?, name: String?, circle: String?, rings: Bool = true,
                        _ why: String = "", file: StaticString = #filePath, line: UInt = #line) async {
        let verdict = await check(scene, level: level)
        guard case .alarm(let alarm) = verdict else { return XCTFail("\(why): \(verdict)", file: file, line: line) }
        XCTAssertEqual(alarm.name, name, why, file: file, line: line)
        XCTAssertEqual(alarm.circle, circle, why, file: file, line: line)
        XCTAssertEqual(alarm.rings, rings, why, file: file, line: line)
        XCTAssertEqual([alarm.account, alarm.circleId, alarm.sosId], [scene.me.userId, circleId, sosId], why,
                       file: file, line: line)
    }

    // MARK: - Can't check → the server's own alert rings

    func testWhatCantBeCheckedRings() async throws {
        let (owner, me, _) = try world()
        let current = try sos(by: owner.sdk, raiser: owner.userId)

        var noToken = try scene(me, listed: [current])
        noToken.token = nil
        await rings(noToken, "no token")

        var anotherAccount = try scene(me, listed: [current])
        anotherAccount.token = Self.token(sub: owner.userId)
        await rings(anotherAccount, "a token for another account")

        var expired = try scene(me, listed: [current])
        expired.token = Self.token(sub: me.userId, expires: now.addingTimeInterval(-60))
        await rings(expired, "the session ran out, and no refresh")
        XCTAssertEqual(expired.server.requests, [], "nothing asked with a token that ran out")
        expired.refreshed = Self.token(sub: me.userId)
        await alarms(expired, level: "generic", name: nil, circle: nil, "refreshed, then checked")

        var noKeys = try scene(me, listed: [current])
        noKeys.keysReadable = false
        await rings(noKeys, "keys unreadable (before the first unlock)")

        let unreadableMarks = try scene(me, listed: [current])
        try FileManager.default.createDirectory(at: unreadableMarks.marksFolder, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: unreadableMarks.marksFolder.appendingPathComponent("\(me.userId).json"))
        await rings(unreadableMarks, "marks unreadable")

        let offline = try scene(me, listed: [current])
        offline.server.offline = true
        await rings(offline, "no network")

        for status in [500, 503, 429] {
            let failing = try scene(me, listed: [current])
            failing.server.responses["GET /api/v1/sos/active"] = [(status, ["success": false])]
            await rings(failing, "\(status)")
        }

        let unauthorized = try scene(me, listed: [current])
        unauthorized.server.responses["GET /api/v1/sos/active"] = [(401, ["success": false])]
        await rings(unauthorized, "401, no refresh")
        var twice = try scene(me, listed: [current])
        twice.refreshed = Self.token(sub: me.userId)
        twice.server.responses["GET /api/v1/sos/active"] = [(403, ["success": false]), (401, ["success": false])]
        await rings(twice, "403, then 401 after one refresh")
        XCTAssertEqual(twice.server.requests.filter { $0 == "GET /api/v1/sos/active" }.count, 2)

        let routed = try scene(me, listed: [current])
        routed.server.responses["GET /api/v1/sos/active"] = [(404, ["success": false])]
        await rings(routed, "a 404 on the list: the route never answers one, so it says nothing of the SOS")

        var badStore = try scene(me, listed: [current])
        badStore.unreadableEntry = true
        await rings(badStore, "a key store entry that doesn't read")
        XCTAssertEqual(badStore.server.requests, [], "nothing asked")

        var switched = try scene(me, listed: [current])
        switched.refreshed = Self.token(sub: owner.userId)
        switched.server.responses["GET /api/v1/sos/active"]?.insert((401, ["success": false]), at: 0)
        await rings(switched, "the refresh names another account")
        XCTAssertEqual(switched.server.requests, ["GET /api/v1/sos/active"], "its list is never asked for")

        let garbled = try scene(me, listed: [current])
        garbled.server.raw["GET /api/v1/sos/active"] = Data(#"{"success": true, "data": [{"id": 5}]}"#.utf8)
        await rings(garbled, "a 200 that doesn't decode")

        let late = try scene(me, listed: [current])
        await rings(late, budget: 0.5, "out of time")

        let noId = try scene(me, listed: [current])
        await rings(noId, alertId: "not-an-id", "no alert id")
    }

    /// One refresh, then the list: checked.
    func testOneRefreshThenTheCheck() async throws {
        let (owner, me, _) = try world()
        var scene = try scene(me, listed: [try sos(by: owner.sdk, raiser: owner.userId)])
        scene.refreshed = Self.token(sub: me.userId)
        scene.server.responses["GET /api/v1/sos/active"]?.insert((401, ["success": false]), at: 0)
        await alarms(scene, level: "generic", name: nil, circle: nil)
    }

    /// Sealed under a version this phone doesn't hold yet (the circle is at
    /// v4): it can't tell, and rings. With nothing opened and the circle list
    /// not answering, the same.
    func testBehindRings() async throws {
        let (owner, me, _) = try world(fourth: true)
        let newer = try sos(by: owner.sdk, raiser: owner.userId)
        let behind = try scene(me, listed: [newer], keyVersion: 4)
        await rings(behind, "the circle at v4, this phone at v3")
        let silent = try scene(me, listed: [newer], keyVersion: 4)
        silent.server.responses["GET /api/v1/circles"] = [(500, ["success": false])]
        await rings(silent, "the circle list not answering")
        // Not behind (the circle at v3): sealed under nothing held here is nobody's.
        let nobodys = try scene(me, listed: [newer], keyVersion: 3)
        await quiet(nobodys, "sealed under nothing held, and not behind")
    }

    // MARK: - Checked, not live → the quiet notice

    func testCheckedAndNotLiveIsRefused() async throws {
        let (owner, me, leftOut) = try world()
        let missing = try scene(me, listed: [])
        await quiet(missing, "not listed")
        let closed = try scene(me, listed: [try sos(by: owner.sdk, raiser: owner.userId, status: "resolved")])
        await quiet(closed, "closed")
        let history = try scene(me, listed: [try sos(by: leftOut.sdk, raiser: owner.userId)])
        await quiet(history, "history: under v1, never seen current here")
        let old = try scene(me, listed: [try sos(by: owner.sdk, raiser: owner.userId, ageMs: 86_400_001)])
        await quiet(old, "past 24 h")
        let ended = try scene(me, listed: [try sos(by: owner.sdk, raiser: owner.userId)])
        ended.marks.noteEnded(account: me.userId, circleId: circleId, sosId: sosId, at: nowMs)
        await quiet(ended, "seen ended here")
        for refused in [missing, closed, history, old] {
            XCTAssertNil(refused.marks.mark(account: me.userId, circleId: circleId, sosId: sosId),
                         "the check writes nothing for one it refuses")
        }
    }

    // MARK: - Checked, current or sticky → the real alarm

    private func hash(_ row: [String: Any]) throws -> String {
        SOSReceiverRules.payloadHash(try APIService.makeWireDecoder().decode(
            SOSResponse.self, from: JSONSerialization.data(withJSONObject: row)))
    }

    func testCurrentOrStickyAlarms() async throws {
        let (owner, me, leftOut) = try world()
        let row = try sos(by: owner.sdk, raiser: owner.userId)
        let current = try scene(me, listed: [row])
        await alarms(current, level: "generic", name: nil, circle: nil)
        XCTAssertEqual(current.server.requests, ["GET /api/v1/sos/active"], "nothing else asked at the generic level")
        // Noted seen current here: sticky across a rotation the app hasn't seen.
        XCTAssertEqual(current.marks.mark(account: me.userId, circleId: circleId, sosId: sosId)?.seenCurrent,
                       [try hash(row)])

        // Full: the circle's name, opened here; no record, so no raiser named.
        let full = try scene(me, listed: [try sos(by: owner.sdk, raiser: owner.userId)])
        await alarms(full, level: "full", name: nil, circle: "Family")

        // Sticky: under v1, but this exact payload was seen current here.
        let old = try sos(by: leftOut.sdk, raiser: owner.userId)
        let sticky = try scene(me, listed: [old])
        sticky.marks.noteSeenCurrent(account: me.userId, circleId: circleId, sosId: sosId, hash: try hash(old), at: nowMs)
        await alarms(sticky, level: "generic", name: nil, circle: nil)
        XCTAssertEqual(sticky.marks.mark(account: me.userId, circleId: circleId, sosId: sosId)?.seenCurrent,
                       [try hash(old)], "only a current one is noted")
    }

    /// A roster row; the plaintext `display_name` older clients send always,
    /// the sealed one when `sealedName` is given.
    private func rosterRow(_ party: Party, role: String = "member", sealedName: EncryptedData? = nil) -> [String: Any] {
        var row: [String: Any] = [
            "user_id": party.userId, "display_name": party.name, "role": role,
            "encrypted_circle_key": ["nonce": "", "ciphertext": ""], "ephemeral_public_key": "",
            "can_see_history": true, "can_see_realtime": true, "status": "active",
            "joined_day_bucket": Int(now.timeIntervalSince1970 / 86_400) - 30, "key_version": 3,
            "sharing_public_key": party.sharing, "signing_public_key": party.signing,
        ]
        if let sealedName { row["encrypted_display_name"] = blob(sealedName) }
        return row
    }

    /// The raiser is named only when the app's own roster pass shows them and
    /// their sealed name opens here, never by the plaintext name the server
    /// sends for older clients; a sticky SOS whose raiser a complete roster
    /// doesn't list any more is refused.
    func testTheRaiserIsNamedOnlyWhenShown() async throws {
        let (owner, me, leftOut) = try world()
        var record = CircleApprovalRecord()
        record.entries[owner.userId] = .ownAction
        let sealed = try owner.sdk.encryptDataV2(circleId: circleId, plaintext: "Olivia", fieldTag: "display_name")
        let shown = try scene(me, listed: [try sos(by: owner.sdk, raiser: owner.userId)], record: record,
                              roster: [rosterRow(owner, role: "owner", sealedName: sealed), rosterRow(me)])
        await alarms(shown, level: "full", name: "Olivia", circle: "Family")

        let plaintextOnly = try scene(me, listed: [try sos(by: owner.sdk, raiser: owner.userId)], record: record,
                                      roster: [rosterRow(owner, role: "owner"), rosterRow(me)])
        await alarms(plaintextOnly, level: "full", name: nil, circle: "Family", "the plaintext name: never")
        let stranger = Party("Stranger", "c5050000-0000-4000-8000-00000000000d")
        let strangers = try stranger.sdk.prepareCircleCreation()
        try stranger.sdk.finalizeCircleCreation(tempCircleId: strangers.tempCircleId, realCircleId: circleId)
        let unopened = try scene(me, listed: [try sos(by: owner.sdk, raiser: owner.userId)], record: record,
                                 roster: [rosterRow(owner, role: "owner", sealedName: try stranger.sdk.encryptDataV2(
                                     circleId: circleId, plaintext: "Olivia", fieldTag: "display_name")), rosterRow(me)])
        await alarms(unopened, level: "names", name: nil, circle: nil, "a sealed name that doesn't open: no name")
        let unconfirmed = try scene(me, listed: [try sos(by: owner.sdk, raiser: owner.userId)],
                                    record: CircleApprovalRecord(),
                                    roster: [rosterRow(owner, role: "owner"), rosterRow(me)])
        await alarms(unconfirmed, level: "names", name: nil, circle: nil, "not confirmed here: no name")

        let old = try sos(by: leftOut.sdk, raiser: owner.userId)
        let gone = try scene(me, listed: [old], record: record, roster: [rosterRow(me)])
        gone.marks.noteSeenCurrent(account: me.userId, circleId: circleId, sosId: sosId, hash: try hash(old), at: nowMs)
        await quiet(gone, level: "generic", "the raiser off a complete roster")
    }

    // MARK: - The banners

    private func original() -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Alert"
        content.body = "Tap to view details"
        content.sound = .default
        content.userInfo = ["alert_type": "sos", "alert_id": sosId]
        return content
    }

    func testTheBannerForEachVerdict() {
        let server = original()
        let rings = NotificationService.sosBanner(for: server, verdict: .cantCheck("offline"), level: nil)
        XCTAssertTrue(rings === server, "the server's own banner, exactly as it came")
        XCTAssertEqual(rings.title, "Alert")
        XCTAssertEqual(rings.body, "Tap to view details")
        XCTAssertEqual(rings.sound, .default, "the server's own alert, ringing as it came")
        XCTAssertNil(rings.userInfo[SOSAlarmCopy.noticeKey])

        let quiet = NotificationService.sosBanner(for: original(), verdict: .refused("history"), level: nil)
        XCTAssertEqual(quiet.title, "Someone may need help.")
        XCTAssertEqual(quiet.body, "Open Track to check.")
        XCTAssertNil(quiet.sound, "no sound")
        XCTAssertEqual(quiet.interruptionLevel, .active)
        XCTAssertEqual(quiet.userInfo[SOSAlarmCopy.noticeKey] as? String, "quiet")
        XCTAssertEqual(quiet.userInfo["alert_id"] as? String, sosId)

        let olivia = SOSCheck.Alarm(name: "Olivia", circle: "Family", rings: true, account: "c5050000-0000-4000-8000-00000000000b",
                                    circleId: circleId, sosId: sosId, at: nowMs)
        let alarm = NotificationService.sosBanner(for: original(), verdict: .alarm(olivia), level: "full")
        XCTAssertEqual(alarm.title, "Olivia needs attention")
        XCTAssertEqual(alarm.body, "Asked their circle to check on them in Family")
        XCTAssertEqual(alarm.sound, .default)
        XCTAssertEqual(alarm.userInfo[SOSAlarmCopy.noticeKey] as? String, "alarm")

        var rung = olivia
        rung.rings = false
        let silent = NotificationService.sosBanner(for: original(), verdict: .alarm(rung), level: "full")
        XCTAssertEqual(silent.title, "Olivia needs attention")
        XCTAssertNil(silent.sound, "rung on this phone already: shown silently")
        XCTAssertEqual(silent.userInfo[SOSAlarmCopy.noticeKey] as? String, "alarm")
    }

    /// The alarm rings once per SOS on this phone: it is noted "rang" only
    /// once it is shown, and the next check of it shows it silently and notes
    /// nothing more.
    func testTheAlarmRingsOnce() async throws {
        let (owner, me, _) = try world()
        let scene = try scene(me, listed: [try sos(by: owner.sdk, raiser: owner.userId)])
        let first = await check(scene, level: "generic")
        guard case .alarm(let alarm) = first else { return XCTFail("\(first)") }
        XCTAssertTrue(alarm.rings)
        XCTAssertEqual(scene.marks.mark(account: me.userId, circleId: circleId, sosId: sosId)?.rang, false,
                       "nothing noted before it is shown")
        XCTAssertTrue(SOSCheck.noteRang(first, marks: scene.marks))
        XCTAssertEqual(scene.marks.mark(account: me.userId, circleId: circleId, sosId: sosId)?.rang, true)

        await alarms(scene, level: "generic", name: nil, circle: nil, rings: false, "rung already")
        let again = await check(scene, level: "generic")
        XCTAssertFalse(SOSCheck.noteRang(again, marks: scene.marks), "a silent alarm notes nothing")
        XCTAssertFalse(SOSCheck.noteRang(.refused("history"), marks: scene.marks))
        XCTAssertFalse(SOSCheck.noteRang(.cantCheck("offline"), marks: scene.marks))
        XCTAssertNil(NotificationService.sosBanner(for: original(), verdict: again, level: "generic").sound)
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// A new SOS goes to its check before anything else, the server's banner
    /// staying the best attempt; its follow-ups go out silent, named as the
    /// inbox names them.
    func testTheExtensionIsWired() throws {
        let service = try source("NotificationExtension/NotificationService.swift")
        let sos = try XCTUnwrap(service.range(of: "        if SOSAlarmCopy.newAlertTypes.contains(alertType) {\n"))
        let handover = try XCTUnwrap(service.range(of: "guard let trigger = BackgroundHandover.trigger("))
        XCTAssertLessThan(sos.upperBound, handover.lowerBound)
        XCTAssertTrue(service.contains("""
                        let verdict = await SOSCheck.run(
                            alertId: userInfo["alert_id"] as? String, level: level,
                            deadline: Date().addingTimeInterval(SOSCheck.budget), env: .live, marks: .shared)
                        if deliver(Self.sosBanner(for: original, verdict: verdict, level: level)) {
                            SOSCheck.noteRang(verdict, marks: .shared)
                        }
        """), "noted \"rang\" after the banner is handed over, and only when it was this one")
        // The banner handed over is the first one; a later one (after the time
        // ran out) is dropped, and says so.
        var shown: [String] = []
        let once = DeliverOnce { shown.append($0.title) }
        let first = UNMutableNotificationContent()
        first.title = "first"
        XCTAssertTrue(once(first))
        XCTAssertFalse(once(original()))
        XCTAssertEqual(shown, ["first"])
        // The follow-ups: silent before anything is fetched (the best attempt
        // too), then named as the inbox names them.
        XCTAssertTrue(service.contains("""
                if SOSAlarmCopy.followUpTypes.contains(alertType) {
                    content.sound = nil
                    let level = UserDefaults(suiteName: ExtensionBridgeKeys.suite)?.string(forKey: ExtensionBridgeKeys.detailLevel)
                    let alertId = userInfo["alert_id"] as? String
                    let original = content.copy() as? UNNotificationContent ?? content
        """))
        XCTAssertTrue(service.contains("""
                        if let named = await NamedBanner.followUp(
                            alertType: alertType, alertId: alertId, level: level,
                            deadline: Date().addingTimeInterval(NamedBanner.budget), env: .live) {
                            banner.title = named.title
                            if let body = named.body { banner.body = body }
                        }
                        deliver(banner)
                    }
                    return
                }
        """))
        XCTAssertEqual(service.components(separatedBy: "bestAttempt = ").count - 1, 1, "set once, to the original")
        XCTAssertEqual(SOSCheck.budget, 10)
    }
}
