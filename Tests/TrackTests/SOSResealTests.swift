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
import CoreLocation
import PingolinTrackSDK
@testable import Track

/// The raiser's re-seal, as Android's resealIfBehind: this account's own open
/// SOS, raised on this device and sealed under a key a rotation left behind,
/// goes along to the circle's current key with its ORIGINAL time, through the
/// alert's one run, sealing the position THIS DEVICE sealed (its record),
/// never one the server swapped in.
///
/// Real keys: the owner makes v1 and gives it to this device and to one it
/// later leaves out; v2 goes to the owner alone; v3 to the owner and this
/// device, which seals under v3. An SOS "raised here before the rotation" is
/// one sealed under v1 naming this account and this device.
@MainActor
final class SOSResealTests: XCTestCase {
    private let circleId = "c5060000-0000-4000-8000-0000000000aa"
    private let device = "device-1"
    private let raisedAt: Int64 = 1_727_700_000_000

    private final class Storage: KeyStorageCallback, @unchecked Sendable {
        private let lock = NSLock()
        private var stored: StoredKeyData?
        func loadKeys() throws -> StoredKeyData? { lock.lock(); defer { lock.unlock() }; return stored }
        func storeKeys(data: StoredKeyData) throws { lock.lock(); stored = data; lock.unlock() }
        func deleteKeys() throws { lock.lock(); stored = nil; lock.unlock() }
    }

    nonisolated private static func hex(_ b64: String) -> String {
        Data(base64Encoded: b64)!.map { String(format: "%02x", $0) }.joined()
    }

    private struct Party {
        let userId: String
        let storage = Storage()
        let sdk = CryptoManager()
        let sharing: String
        let signing: String

        init(_ userId: String) {
            self.userId = userId
            sdk.registerSecureStorage(storage: storage)
            sharing = SOSResealTests.hex(sdk.generateKeypair().publicKey)
            signing = SOSResealTests.hex(sdk.generateSigningKeypair().verifyingKeyB64)
        }
    }

    private func world() throws -> (owner: Party, me: Party, leftOut: Party) {
        let owner = Party("c5060000-0000-4000-8000-00000000000a")
        let me = Party("c5060000-0000-4000-8000-00000000000b")
        let leftOut = Party("c5060000-0000-4000-8000-00000000000c")
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
        return (owner, me, leftOut)
    }

    private func blob(_ e: EncryptedData) -> [String: Any] { ["nonce": e.nonce, "ciphertext": e.ciphertext] }
    private func blob(_ e: EncryptedBlobRequest) -> [String: Any] { ["nonce": e.nonce, "ciphertext": e.ciphertext] }

    private let point = Location(latitude: 52.52, longitude: 13.405, altitude: nil, speed: nil, heading: nil, accuracy: 7,
                                 timestamp: 1_727_700_000_000, batteryLevel: nil, isCharging: nil)
    private let f1 = "c5060000-0000-4000-8000-0000000000f1"

    /// One listed SOS, every part sealed by `sealer`; its position `location`,
    /// or `marker` in its place.
    private func sos(id: String, by sealer: CryptoManager, raiser: String, device: String, status: String = "active",
                     state: String? = "Please call", location: Location? = nil,
                     marker: SOSPositionMarker? = nil) throws -> SOSResponse {
        let place = try marker.map { try sealer.encryptDataV2(circleId: circleId, plaintext: $0.rawValue, fieldTag: "location") }
            ?? sealer.encryptLocation(circleId: circleId, location: location ?? point)
        var row: [String: Any] = [
            "id": id, "circle_id": circleId, "status": status, "day_bucket": 20_000,
            "encrypted_user_id": blob(try sealer.encryptDataV2(circleId: circleId, plaintext: raiser, fieldTag: "user_id")),
            "encrypted_device_id": blob(try sealer.encryptDataV2(circleId: circleId, plaintext: device, fieldTag: "device_id")),
            "encrypted_timestamp": blob(try sealer.encryptDataV2(circleId: circleId, plaintext: String(raisedAt),
                                                                 fieldTag: "timestamp")),
            "encrypted_location": blob(place),
        ]
        if let state {
            row["encrypted_device_state"] = blob(try sealer.encryptDataV2(circleId: circleId, plaintext: state,
                                                                          fieldTag: "device_state"))
        }
        return try APIService.makeWireDecoder().decode(SOSResponse.self, from: JSONSerialization.data(withJSONObject: row))
    }

    /// The row once the server took a re-seal: its sealed fields swapped.
    private func applying(_ request: ResealSOSRequest, to row: SOSResponse) throws -> SOSResponse {
        var json: [String: Any] = [
            "id": row.id, "circle_id": row.circleId, "status": row.status, "day_bucket": row.dayBucket,
            "encrypted_user_id": blob(request.encryptedUserId), "encrypted_device_id": blob(request.encryptedDeviceId),
            "encrypted_timestamp": blob(request.encryptedTimestamp), "encrypted_location": blob(request.encryptedLocation),
        ]
        if let state = request.encryptedDeviceState { json["encrypted_device_state"] = blob(state) }
        return try APIService.makeWireDecoder().decode(SOSResponse.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func opened(_ response: SOSResponse, by party: Party, device: String? = "device-1") -> SOSReceiverRules.Opened {
        SOSReceiverRules.open(response, myUserId: party.userId, myDeviceId: device, crypto: party.sdk)
    }

    /// What `party` opens as the position: a `Location`, or the marker.
    private func position(_ response: SOSResponse, by party: Party) -> SOSManager.RaisePayload? {
        let opened = opened(response, by: party)
        if let location = opened.location { return .position(location) }
        return opened.marker.map { .marker($0) }
    }

    /// The record this device keeps after sealing `location` itself.
    private func record(of location: Location, by party: Party) throws -> SOSSealedPositions.Record {
        let blob = try party.sdk.encryptLocation(circleId: circleId, location: location)
        return try XCTUnwrap(SOSManager.sealedRecord(EncryptedBlobRequest(nonce: blob.nonce, ciphertext: blob.ciphertext),
                                                     circleId: circleId, pressAtMs: raisedAt, locationOff: false,
                                                     updates: 0, crypto: party.sdk))
    }

    /// The server's one row, and what was PUT to it.
    private final class Server {
        var served: SOSResponse
        var puts: [ResealSOSRequest] = []
        init(_ served: SOSResponse) { self.served = served }
    }

    /// This device's record of the alert.
    private final class Kept {
        var record: SOSSealedPositions.Record?
        var forgotten = false
        init(_ record: SOSSealedPositions.Record?) { self.record = record }
    }

    /// One run's world: `me` on this device; the key held, the cap free, no
    /// fixes and no rotation flag unless a test says otherwise.
    private func runWorld(_ server: Server, _ kept: Kept, me: Party) -> SOSManager.UpdateWorld {
        SOSManager.UpdateWorld(
            me: me.userId, deviceId: device, crypto: me.sdk,
            now: { Date(timeIntervalSince1970: 1_727_700_030) },
            record: { kept.record }, keep: { kept.record = $0 },
            forget: { kept.record = nil; kept.forgotten = true },
            fixes: { SOSManager.AfterPress() }, locationOff: { false },
            get: { server.served },
            refreshKeys: { _ in }, holdsCurrentKey: { _ in true },
            rotationNeeded: { _ in false }, deferredSince: { nil }, noteDeferral: { _ in },
            resealsLastHour: { 0 }, noteReseal: {},
            put: { [unowned self] request in
                server.puts.append(request)
                server.served = try self.applying(request, to: server.served)
                return server.served
            })
    }

    // MARK: - The choice

    /// The choice: this account's own open alert, raised on this device, with
    /// its raiser and time opened; due when it isn't current (or differs from
    /// the record, or has an update); it seals what this device sealed, never
    /// a stand-in.
    func testTheChoiceIsEveryConditionAtOnce() throws {
        let (_, me, leftOut) = try world()
        let mine = opened(try sos(id: f1, by: leftOut.sdk, raiser: me.userId, device: device), by: me)
        XCTAssertFalse(mine.current)
        XCTAssertTrue(mine.raisedHere)
        func choice(_ opened: SOSReceiverRules.Opened, _ status: String = "active",
                    record: SOSSealedPositions.Record? = nil) -> SOSManager.ResealChoice? {
            SOSManager.resealChoice(opened: opened, status: status, circleId: circleId, record: record,
                                    pressCircleId: nil, fixes: SOSManager.AfterPress(), locationOff: false,
                                    now: Date(timeIntervalSince1970: 1_727_700_030))
        }
        // Behind, with no record: the position as it opened, never a new fix.
        let due = try XCTUnwrap(choice(mine))
        XCTAssertEqual(due.payload, .position(point))
        XCTAssertFalse(due.update)
        XCTAssertNotNil(choice(mine, "acknowledged"))
        XCTAssertNil(choice(mine, "resolved"), "closed")
        XCTAssertNil(choice(mine, "false_alarm"))
        var current = mine
        current.current = true
        XCTAssertNil(choice(current), "current, with no record to differ from")
        var elsewhere = mine
        elsewhere.raisedHere = false
        XCTAssertNil(choice(elsewhere), "raised on another device, or by someone else")
        var noRaiser = mine
        noRaiser.raiserId = nil
        XCTAssertNil(choice(noRaiser))
        var noTime = mine
        noTime.sealedTimeMs = nil
        XCTAssertNil(choice(noTime))
        var nothing = mine
        nothing.location = nil
        XCTAssertNil(choice(nothing), "nothing it can seal: never a stand-in position")
        // A marker alert goes along to the new key too.
        var marker = nothing
        marker.marker = .pending
        XCTAssertEqual(choice(marker)?.payload, .marker(.pending))
        // With a record: the record, whatever the row opened as.
        let mineToo = try record(of: Location(latitude: 52.6, longitude: 13.5, altitude: nil, speed: nil, heading: nil,
                                              accuracy: 9, timestamp: raisedAt, batteryLevel: nil, isCharging: nil),
                                 by: me)
        XCTAssertEqual(choice(mine, record: mineToo)?.payload, SOSManager.payload(of: mineToo))
        XCTAssertNotNil(choice(current, record: mineToo), "current, but serving another position: back to the record")
        XCTAssertNil(choice(current, record: try record(of: point, by: me)), "current, and serving the record")
    }

    // MARK: - Only into the circle it was raised in

    /// Nothing is chosen for an alert served in another circle than the
    /// one this device raised it in, as it knows it: its record's, else this
    /// process's press, compared canonically. With neither, no update: at most
    /// what opened. The pass runs nothing for it either.
    func testOnlyTheCircleItWasRaisedInIsChosen() async throws {
        let (_, me, leftOut) = try world()
        let work = "c5060000-0000-4000-8000-0000000000bb"
        let now = Date(timeIntervalSince1970: 1_727_700_030)
        let behind = try sos(id: f1, by: leftOut.sdk, raiser: me.userId, device: device)
        func choice(_ row: SOSResponse, record: SOSSealedPositions.Record? = nil, press: String? = nil,
                    fixes: SOSManager.AfterPress = .init()) -> SOSManager.ResealChoice? {
            SOSManager.resealChoice(opened: opened(row, by: me), status: "active", circleId: circleId, record: record,
                                    pressCircleId: press, fixes: fixes, locationOff: false, now: now)
        }
        let family = try record(of: point, by: me)
        var elsewhere = family
        elsewhere.circleId = work
        XCTAssertNotNil(choice(behind, record: family), "its own circle: the catch-up")
        XCTAssertNil(choice(behind, record: elsewhere), "raised in Work, served in Family: nothing")
        XCTAssertNil(choice(behind, record: elsewhere, press: circleId), "the record first")
        var spelled = family
        spelled.circleId = circleId.uppercased()
        XCTAssertNotNil(choice(behind, record: spelled), "compared canonically")
        XCTAssertNotNil(choice(behind, press: circleId.uppercased()))
        XCTAssertNil(choice(behind, press: work), "with no record, this process's press says the same")

        // With neither, a fix after the press seals no update:
        // only what opened goes along.
        let pending = try sos(id: f1, by: leftOut.sdk, raiser: me.userId, device: device, marker: .pending)
        var fixes = SOSManager.AfterPress()
        let pressAt = Date(timeIntervalSince1970: TimeInterval(raisedAt) / 1000)
        fixes.offer(CLLocation(coordinate: CLLocationCoordinate2D(latitude: 52.52, longitude: 13.405), altitude: 0,
                               horizontalAccuracy: 6, verticalAccuracy: 5, timestamp: pressAt.addingTimeInterval(20)),
                    pressAt: pressAt)
        XCTAssertEqual(choice(pending, press: circleId, fixes: fixes)?.update, true, "a press here: the update")
        let neither = try XCTUnwrap(choice(pending, fixes: fixes))
        XCTAssertFalse(neither.update)
        XCTAssertEqual(neither.payload, .marker(.pending), "what opened, never the fix")

        // The pass runs nothing served in another circle than its record's.
        var runs: [String] = []
        _ = await SOSManager.resealPass(
            [behind], me: me.userId, deviceId: device, crypto: me.sdk, record: { _ in elsewhere },
            pressCircle: { _ in nil }, fixes: { _ in SOSManager.AfterPress() }, locationOff: false, now: now,
            run: { id in runs.append(id); return nil })
        XCTAssertTrue(runs.isEmpty)
        _ = await SOSManager.resealPass(
            [behind], me: me.userId, deviceId: device, crypto: me.sdk, record: { _ in nil },
            pressCircle: { _ in work }, fixes: { _ in SOSManager.AfterPress() }, locationOff: false, now: now,
            run: { id in runs.append(id); return nil })
        XCTAssertTrue(runs.isEmpty)
        _ = await SOSManager.resealPass(
            [behind], me: me.userId, deviceId: device, crypto: me.sdk, record: { _ in family },
            pressCircle: { _ in nil }, fixes: { _ in SOSManager.AfterPress() }, locationOff: false, now: now,
            run: { id in runs.append(id); return nil })
        XCTAssertEqual(runs, [behind.id], "the control: its own circle runs")

        // Every entry point (the refresh pass, a key check, a rotation import,
        // the update driver) seals only through the alert's run, and the run
        // only past this choice.
        let manager = try source("App/Managers/SOSManager.swift")
        XCTAssertEqual(manager.components(separatedBy: "Self.updateRun(world:").count - 1, 1)
        XCTAssertEqual(manager.components(separatedBy: "resealRequest(for:").count - 1, 1, "asked by the run alone")
        XCTAssertEqual(manager.components(separatedBy: "api.resealSOS(").count - 1, 1, "the one PUT: the run's")
        XCTAssertEqual(manager.components(separatedBy: "resealChoice(opened:").count - 1, 3,
                       "defined, and asked by the run and the pass")
    }

    // MARK: - The request

    /// The re-seal carries the same raiser, device and state, the ORIGINAL
    /// time and the position it is given, every part under v3, the key this
    /// device seals under, which the owner opens as current.
    func testTheResealCarriesTheOriginalUnderTheCurrentKey() throws {
        let (owner, me, leftOut) = try world()
        let old = try sos(id: f1, by: leftOut.sdk, raiser: me.userId, device: device)
        let request = try XCTUnwrap(try SOSManager.resealRequest(for: old, into: circleId, opened: opened(old, by: me),
                                                                payload: .position(point), deviceId: device,
                                                                holdsCurrentKey: true, crypto: me.sdk))
        func open(_ blob: EncryptedBlobRequest, _ tag: String) throws -> OpenedText {
            try owner.sdk.decryptDataV2Opened(circleId: circleId, encryptedData: EncryptedData(nonce: blob.nonce,
                                                                                               ciphertext: blob.ciphertext),
                                              fieldTag: tag)
        }
        let user = try open(request.encryptedUserId, "user_id")
        XCTAssertEqual(user.text, me.userId)
        XCTAssertEqual(user.keyVersion, 3)
        XCTAssertEqual(try open(request.encryptedDeviceId, "device_id").text, device)
        let time = try open(request.encryptedTimestamp, "timestamp")
        XCTAssertEqual(time.text, String(raisedAt), "the ORIGINAL time, never now")
        XCTAssertEqual(time.keyVersion, 3)
        XCTAssertEqual(try open(XCTUnwrap(request.encryptedDeviceState), "device_state").text, "Please call")
        let place = try owner.sdk.decryptLocationOpened(
            circleId: circleId, encryptedLocation: EncryptedData(nonce: request.encryptedLocation.nonce,
                                                                 ciphertext: request.encryptedLocation.ciphertext))
        XCTAssertEqual(place.location, point)
        XCTAssertEqual(place.keyVersion, 3)
        XCTAssertTrue(owner.sdk.isCurrentKeyVersion(circleId: circleId, keyVersion: 3))

        XCTAssertNil(try SOSManager.resealRequest(for: old, into: circleId, opened: opened(old, by: me), payload: .position(point),
                                                  deviceId: device, holdsCurrentKey: false, crypto: me.sdk),
                     "never past the write gate")

        // A marker, as its exact bytes under the "location" tag.
        let marked = try XCTUnwrap(try SOSManager.resealRequest(for: old, into: circleId, opened: opened(old, by: me),
                                                               payload: .marker(.pending), deviceId: device,
                                                               holdsCurrentKey: true, crypto: me.sdk))
        let text = try open(marked.encryptedLocation, "location")
        XCTAssertEqual(Array(text.text.utf8), Array(SOSPositionMarker.pending.rawValue.utf8))
        XCTAssertEqual(text.keyVersion, 3)

        // No device state: none sent, so none is stored.
        let bare = try sos(id: "c5060000-0000-4000-8000-0000000000f2", by: leftOut.sdk, raiser: me.userId, device: device,
                           state: nil)
        let bareRequest = try XCTUnwrap(try SOSManager.resealRequest(for: bare, into: circleId, opened: opened(bare, by: me),
                                                                    payload: .position(point), deviceId: device,
                                                                    holdsCurrentKey: true, crypto: me.sdk))
        XCTAssertNil(bareRequest.encryptedDeviceState)
        let wire = try XCTUnwrap(JSONSerialization.jsonObject(
            with: APIService.makeWireEncoder().encode(bareRequest)) as? [String: Any])
        XCTAssertEqual(Set(wire.keys), ["encrypted_location", "encrypted_user_id", "encrypted_device_id",
                                        "encrypted_timestamp"])
    }

    // MARK: - The run

    /// A row a rotation left behind goes along to v3 with what opened when
    /// this device has no record (a reinstall, or an alert raised by a
    /// version that kept none) and no press here. No record is written: the
    /// only circle it knows is the one the server named.
    func testWithNoRecordTheOpenedPositionGoesAlong() async throws {
        let (owner, me, leftOut) = try world()
        let server = Server(try sos(id: f1, by: leftOut.sdk, raiser: me.userId, device: device))
        let kept = Kept(nil)
        guard case .resealed(let served) = await SOSManager.updateRun(world: runWorld(server, kept, me: me)) else {
            return XCTFail("not re-sealed")
        }
        XCTAssertEqual(server.puts.count, 1)
        XCTAssertEqual(position(served, by: owner), .position(point))
        XCTAssertTrue(opened(served, by: owner).current)
        XCTAssertNil(kept.record, "never a record naming a circle the server named")
    }

    /// A rotation re-seals what THIS DEVICE sealed, never a position the
    /// server swapped into the row: the swapped one is never made current.
    func testARotationResealsTheRecordNotTheServedRow() async throws {
        let (owner, me, leftOut) = try world()
        let mine = try record(of: point, by: me)
        let swapped = Location(latitude: 48.8584, longitude: 2.2945, altitude: nil, speed: nil, heading: nil, accuracy: 5,
                               timestamp: raisedAt, batteryLevel: nil, isCharging: nil)
        let server = Server(try sos(id: f1, by: leftOut.sdk, raiser: me.userId, device: device, location: swapped))
        let kept = Kept(mine)
        guard case .resealed = await SOSManager.updateRun(world: runWorld(server, kept, me: me)) else {
            return XCTFail("not re-sealed")
        }
        XCTAssertEqual(position(server.served, by: owner), .position(point), "the record, under v3")
        XCTAssertTrue(opened(server.served, by: owner).current)
        var sealed = mine
        sealed.raisedAtMs = raisedAt
        XCTAssertEqual(kept.record, sealed, "the record, now with the raise time it sealed")
    }

    /// An alert that carries a marker goes along to the new key as well.
    func testAMarkerAlertIsResealedOnRotation() async throws {
        let (owner, me, leftOut) = try world()
        let server = Server(try sos(id: f1, by: leftOut.sdk, raiser: me.userId, device: device, marker: .pending))
        let kept = Kept(SOSSealedPositions.Record(circleId: circleId, pressAtMs: raisedAt, position: nil, marker: .pending))
        guard case .resealed = await SOSManager.updateRun(world: runWorld(server, kept, me: me)) else {
            return XCTFail("not re-sealed")
        }
        XCTAssertEqual(position(server.served, by: owner), .marker(.pending))
        XCTAssertTrue(opened(server.served, by: owner).current)
    }

    /// A 404 (closed, or its raiser left) ends it and its record goes; a 429
    /// (the server's ten an hour) and the phone's own cap stop it quietly.
    func testA404EndsItAndTheCapsStopIt() async throws {
        let (_, me, leftOut) = try world()
        let row = try sos(id: f1, by: leftOut.sdk, raiser: me.userId, device: device)
        let mine = try record(of: point, by: me)

        var kept = Kept(mine)
        var env = runWorld(Server(row), kept, me: me)
        env.get = { throw APIError(code: "http_404", message: "Alert not found or access denied") }
        guard case .ended = await SOSManager.updateRun(world: env) else { return XCTFail("a 404 on the GET") }
        XCTAssertTrue(kept.forgotten)

        kept = Kept(mine)
        env = runWorld(Server(row), kept, me: me)
        var noted = 0
        env.noteReseal = { noted += 1 }
        env.put = { _ in throw APIError(code: "http_404", message: "Alert not found or access denied") }
        guard case .ended = await SOSManager.updateRun(world: env) else { return XCTFail("a 404 on the PUT") }
        XCTAssertTrue(kept.forgotten)
        XCTAssertEqual(noted, 1, "counted before the request")

        kept = Kept(mine)
        env = runWorld(Server(row), kept, me: me)
        env.put = { _ in throw APIError(code: "rate_limited", message: "Too many requests; please try again later.") }
        guard case .notNow = await SOSManager.updateRun(world: env) else { return XCTFail("a 429") }
        XCTAssertEqual(kept.record, mine)
        XCTAssertFalse(kept.forgotten)

        let closed = Server(try sos(id: f1, by: leftOut.sdk, raiser: me.userId, device: device, status: "resolved"))
        kept = Kept(mine)
        guard case .ended = await SOSManager.updateRun(world: runWorld(closed, kept, me: me)) else {
            return XCTFail("closed")
        }
        XCTAssertTrue(kept.forgotten)
        XCTAssertTrue(closed.puts.isEmpty)

        // The cap, the key in use, no device: nothing asked.
        for (holds, last, deviceId) in [(true, 10, device), (false, 0, device), (true, 0, nil)] as [(Bool, Int, String?)] {
            let server = Server(row)
            var env = runWorld(server, Kept(mine), me: me)
            env.holdsCurrentKey = { _ in holds }
            env.resealsLastHour = { last }
            env.deviceId = deviceId
            _ = await SOSManager.updateRun(world: env)
            XCTAssertTrue(server.puts.isEmpty, "holds \(holds), \(last) this hour, device \(deviceId ?? "none")")
        }
    }

    /// The pass over a load's list: each of this device's own that a run is
    /// due for goes through its run, and what it then serves replaces it.
    func testThePassRunsWhatIsDueAndKeepsTheRest() async throws {
        let (owner, me, leftOut) = try world()
        let due = try sos(id: f1, by: leftOut.sdk, raiser: me.userId, device: device)
        let current = try sos(id: "c5060000-0000-4000-8000-0000000000f2", by: me.sdk, raiser: me.userId, device: device)
        let otherDevice = try sos(id: "c5060000-0000-4000-8000-0000000000f3", by: leftOut.sdk, raiser: me.userId,
                                  device: "device-2")
        let someoneElse = try sos(id: "c5060000-0000-4000-8000-0000000000f4", by: leftOut.sdk, raiser: owner.userId,
                                  device: device)
        let closed = try sos(id: "c5060000-0000-4000-8000-0000000000f5", by: leftOut.sdk, raiser: me.userId, device: device,
                             status: "resolved")
        let answer = try sos(id: due.id, by: me.sdk, raiser: me.userId, device: device)
        var runs: [String] = []
        let out = await SOSManager.resealPass(
            [due, current, otherDevice, someoneElse, closed], me: me.userId, deviceId: device, crypto: me.sdk,
            record: { _ in nil }, pressCircle: { _ in nil }, fixes: { _ in SOSManager.AfterPress() },
            locationOff: false, now: Date(timeIntervalSince1970: 1_727_700_030),
            run: { id in runs.append(id); return .resealed(answer) })
        XCTAssertEqual(runs, [due.id], "only this account's own, open, behind SOS raised here")
        XCTAssertEqual(out.map(\.id), [due, current, otherDevice, someoneElse, closed].map(\.id))
        XCTAssertEqual(out[0].encryptedTimestamp, answer.encryptedTimestamp, "the server's answer replaces it")
        XCTAssertEqual(out[1].encryptedTimestamp, current.encryptedTimestamp)
        XCTAssertTrue(opened(out[0], by: me).current)

        // A run that ended, or took nothing: the row stays as listed.
        for outcome in [SOSManager.UpdateOutcome.ended, .notNow("429"), .deferred] {
            let kept = await SOSManager.resealPass(
                [due], me: me.userId, deviceId: device, crypto: me.sdk, record: { _ in nil },
                pressCircle: { _ in nil }, fixes: { _ in SOSManager.AfterPress() }, locationOff: false,
                now: Date(timeIntervalSince1970: 1_727_700_030), run: { _ in outcome })
            XCTAssertEqual(kept[0].encryptedTimestamp, due.encryptedTimestamp)
        }
        // No device: nothing asked.
        var asked = false
        _ = await SOSManager.resealPass(
            [due], me: me.userId, deviceId: nil, crypto: me.sdk, record: { _ in nil },
            pressCircle: { _ in nil }, fixes: { _ in SOSManager.AfterPress() }, locationOff: false,
            now: Date(timeIntervalSince1970: 1_727_700_030), run: { _ in asked = true; return nil })
        XCTAssertFalse(asked)
    }

    /// Before this process loaded the circle list, the write gate passes a
    /// circle it hasn't seen; the re-seal waits for a list that loaded and lists
    /// the circle, as after a restart that restores emergency mode: nothing is
    /// PUT.
    func testNothingIsResealedBeforeTheCircleListLoaded() async throws {
        let (_, me, leftOut) = try world()
        let row = try sos(id: f1, by: leftOut.sdk, raiser: me.userId, device: device)
        let key = circleId.lowercased()
        func gate(_ loaded: Bool, _ listed: Set<String>, _ shown: Set<String>, _ holds: Bool, _ id: String? = nil) -> Bool {
            SOSManager.resealGate(circlesLoaded: loaded, listed: listed, shown: shown, circleId: id ?? circleId,
                                  holdsCurrentKey: { holds })
        }
        XCTAssertFalse(gate(false, [key], [key], true), "no list loaded in this process")
        XCTAssertFalse(gate(true, [], [key], true), "not in the list the server gave")
        XCTAssertFalse(gate(true, [key], [], true), "not shown here (a 404 pruned it)")
        XCTAssertFalse(gate(true, [key], [key], false), "the write gate")
        XCTAssertTrue(gate(true, [key], [key], true, circleId.uppercased()))

        var server = Server(row)
        var env = runWorld(server, Kept(nil), me: me)
        env.holdsCurrentKey = { id in gate(false, [], [], true, id) }
        _ = await SOSManager.updateRun(world: env)
        XCTAssertTrue(server.puts.isEmpty, "nothing PUT before the list loaded")
        // After the load, the same SOS is re-sealed.
        server = Server(row)
        env = runWorld(server, Kept(nil), me: me)
        env.holdsCurrentKey = { id in gate(true, [key], [key], true, id) }
        _ = await SOSManager.updateRun(world: env)
        XCTAssertEqual(server.puts.count, 1, "re-sealed once the list loaded")
    }

    // MARK: - When

    func testAMovedCircleIsOneWhoseHeldVersionChanged() {
        let a = "c5060000-0000-4000-8000-0000000000a1", b = "c5060000-0000-4000-8000-0000000000a2"
        let first = SOSManager.movedCircles(held: [(a.uppercased(), 3), (b, nil)], seen: [:])
        XCTAssertEqual(first.moved, [a], "seen for the first time; one with no key held is skipped")
        XCTAssertEqual(first.seen, [a: 3])
        let same = SOSManager.movedCircles(held: [(a, 3)], seen: first.seen)
        XCTAssertEqual(same.moved, [])
        let rotated = SOSManager.movedCircles(held: [(a, 4), (b, 1)], seen: same.seen)
        XCTAssertEqual(rotated.moved, [a, b])
        XCTAssertEqual(rotated.seen, [a: 4, b: 1])
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// Every SOS load re-seals first and judges what it re-sealed; every circle
    /// load looks for a moved key; the request goes where the server takes it.
    func testTheResealIsWired() throws {
        let manager = try source("App/Managers/SOSManager.swift")
        let reseal = try XCTUnwrap(manager.range(of: "        let responses = await resealOwn(try await api.getActiveSOSAlerts())\n"))
        let open = try XCTUnwrap(manager.range(of: "        let opened = await Self.openListed(\n"))
        XCTAssertLessThan(reseal.upperBound, open.lowerBound)
        XCTAssertTrue(manager.contains(
            "            holdsCurrentKey: { circleId in\n"
            + "                // Primed, so after a restart nothing is sealed before a\n"
            + "                // circle list this process loaded lists the circle.\n"
            + "                let primed = await CircleManager.shared.holdsCurrentKeyPrimed(for: circleId)\n"
            + "                return Self.resealGate(circlesLoaded: CircleManager.shared.circlesLoaded,\n"
            + "                                       listed: CircleManager.shared.listedCircleIds,\n"
            + "                                       shown: Set(CircleManager.shared.circles.map { $0.id.lowercased() }),\n"
            + "                                       circleId: circleId, holdsCurrentKey: { primed })\n"),
                      "a loaded, listed circle, then the primed write gate every sealing write asks")
        XCTAssertTrue(manager.contains("            refreshKeys: { _ in try? await CircleManager.shared.loadCircles(light: true) },\n"),
                      "one bounded circle and key read")
        XCTAssertTrue(manager.contains("    func resealAfterKeyChange() {\n"
                                       + "        // Not before a list loaded from the server: an unloaded circle can't\n"
                                       + "        // be judged, and the first load's look (every circle \"moved\") follows.\n"
                                       + "        guard CircleManager.shared.circlesLoaded else { return }\n"))
        XCTAssertTrue(manager.contains("            put: { [api] request in try await api.resealSOS(alertId: alertId, request: request) },\n"))
        // The circle the press chose, for every run and the pass.
        XCTAssertTrue(manager.contains("        pressCircles[CanonicalId.key(alert.id)] = circleId\n"
                                       + "        startUpdateWatch(alertId: alert.id, circleId: circleId, pressAt: pressAt, "))
        XCTAssertEqual(manager.components(separatedBy: "pressCircles[CanonicalId.key(").count - 1, 3,
                       "set at the raise, dropped at the close; and the pass reads it")
        XCTAssertTrue(manager.contains("            pressCircleId: { [weak self] in self?.pressCircles[key] },\n"))
        XCTAssertTrue(manager.contains("            pressCircle: { [pressCircles] in pressCircles[CanonicalId.key($0)] },\n"))
        XCTAssertTrue(manager.contains("            get: { [api] in try await api.getSOSAlert(alertId: alertId) },\n"))
        XCTAssertTrue(manager.contains("            run: { [weak self] id in await self?.runUpdate(id).value ?? nil })\n"),
                      "every re-seal goes through the alert's one run at a time")
        XCTAssertTrue(manager.contains("            _ = await resealOwn(listed.filter { look.moved.contains(CanonicalId.key($0.circleId)) })\n"))
        XCTAssertTrue(manager.contains("        reseals = [:]\n        resealSeen = [:]\n"), "forgotten at a sign-out")
        XCTAssertTrue(try source("App/Managers/CircleManager.swift").contains(
            "        PendingChangeRunner.shared.trigger()\n"
            + "        // This account's own open SOS in a circle whose key moved here (a\n"
            + "        // rotation this device landed, or a key import) goes along to the new\n"
            + "        // key. Cheap when nothing moved.\n"
            + "        SOSManager.shared.resealAfterKeyChange()\n    }\n"))
        XCTAssertTrue(try source("App/Services/APIService.swift").contains(
            "        return try await put(path: \"/api/v1/sos/\\(alertId)/reseal\", body: request)\n"))
    }
}
