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

/// SOS position updates: the raising device re-seals its own alert with a
/// fix taken after the press (always exact), at most three times within ten
/// minutes of the press, one run at a time per alert, from its own record
/// of what it sealed; it reads the circle's keys before sealing and waits
/// a bounded time for a rotation the circle is flagged for.
@MainActor
final class SOSPositionUpdateTests: XCTestCase {
    private let circleId = "c5090000-0000-4000-8000-0000000000aa"
    private let alertId = "c5090000-0000-4000-8000-0000000000f1"
    private let me = "c5090000-0000-4000-8000-00000000000b"
    private let device = "device-1"
    private let pressMs: Int64 = 1_727_700_000_000
    private var press: Date { Date(timeIntervalSince1970: TimeInterval(pressMs) / 1000) }

    private func at(_ secondsAfterPress: TimeInterval) -> Date { press.addingTimeInterval(secondsAfterPress) }

    private func fix(_ secondsAfterPress: TimeInterval, accuracy: CLLocationAccuracy = 8,
                     lat: Double = 37.3349, lon: Double = -122.009) -> CLLocation {
        CLLocation(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon), altitude: 0,
                   horizontalAccuracy: accuracy, verticalAccuracy: 5, timestamp: at(secondsAfterPress))
    }

    private func fixes(_ list: CLLocation...) -> SOSManager.AfterPress {
        var fixes = SOSManager.AfterPress()
        for fix in list { fixes.offer(fix, pressAt: press) }
        return fixes
    }

    private func held(_ secondsAfterPress: TimeInterval, accuracy: Double = 12) -> Location {
        Location(latitude: 37.33, longitude: -122.0, altitude: nil, speed: nil, heading: nil, accuracy: accuracy,
                 timestamp: pressMs + Int64(secondsAfterPress * 1000), batteryLevel: nil, isCharging: nil)
    }

    private func record(_ position: Location? = nil, marker: SOSPositionMarker? = nil,
                        updates: Int = 0) -> SOSSealedPositions.Record {
        .init(circleId: circleId, pressAtMs: pressMs, position: position.map { .init($0) }, marker: marker,
              updates: updates)
    }

    private func due(_ c: SOSSealedPositions.Record, _ fixes: SOSManager.AfterPress = .init(), off: Bool = false,
                     at seconds: TimeInterval = 30) -> SOSManager.RaisePayload? {
        SOSManager.updateDue(c, fixes: fixes, locationOff: off, now: at(seconds))
    }

    // MARK: - Fixes after the press

    /// A fix counts if it was taken at or after the press (2 s slack)
    /// and has an accuracy: the newest, and the newest within 100 m,
    /// which (a) and (b) prefer.
    func testAFixCountsFromThePress() {
        XCTAssertNil(fixes(fix(-3)).newest, "taken before the press")
        XCTAssertNotNil(fixes(fix(-2)).newest, "the slack")
        XCTAssertNil(fixes(fix(5, accuracy: -1)).newest, "no position")
        let two = fixes(fix(10, accuracy: 30), fix(20, accuracy: 500))
        XCTAssertEqual(two.newest?.timestamp, at(20))
        XCTAssertEqual(two.precise?.timestamp, at(10))
        XCTAssertEqual(two.best?.timestamp, at(10), "the precise one")
        XCTAssertEqual(fixes(fix(20, accuracy: 500)).best?.timestamp, at(20), "else the newest")
        XCTAssertEqual(fixes(fix(20), fix(10)).newest?.timestamp, at(20), "an older one never replaces it")
        XCTAssertEqual(fixes(fix(10, accuracy: 100)).precise?.timestamp, at(10), "100 m is within 100 m")
    }

    // MARK: - When an update is due

    /// (a): a marker gives way to the first fix after the press, exact.
    func testAMarkerTakesTheFirstFixAfterThePress() {
        XCTAssertEqual(due(record(marker: .pending), fixes(fix(20, accuracy: 900))),
                       .position(SOSManager.sealable(fix(20, accuracy: 900))))
        XCTAssertEqual(due(record(marker: .unavail), fixes(fix(20))), .position(SOSManager.sealable(fix(20))))
        XCTAssertNil(due(record(marker: .pending)), "no fix yet: nothing (the raise said \"pending\")")
        XCTAssertEqual(due(record(marker: .pending), fixes(fix(10, accuracy: 40), fix(20, accuracy: 900))),
                       .position(SOSManager.sealable(fix(10, accuracy: 40))), "the precise one")
    }

    /// (b): a held position taken over a minute before the press gives way to
    /// a fix taken after it.
    func testALastKnownPositionGivesWayToAFixAfterThePress() {
        XCTAssertEqual(due(record(held(-61)), fixes(fix(20, accuracy: 900))),
                       .position(SOSManager.sealable(fix(20, accuracy: 900))))
        XCTAssertNil(due(record(held(-60)), fixes(fix(20, accuracy: 900))), "a minute old is not \"last known\"")
        XCTAssertNil(due(record(held(-600))), "no fix after the press")
    }

    /// (c): a position worse than 100 m (a held one coarsened to its bubble
    /// is) gives way only to a fix within 100 m taken after it.
    func testARoughPositionGivesWayOnlyToANewerPreciseFix() {
        let rough = record(held(10, accuracy: 1_500))
        XCTAssertEqual(due(rough, fixes(fix(20, accuracy: 40))), .position(SOSManager.sealable(fix(20, accuracy: 40))))
        XCTAssertNil(due(rough, fixes(fix(20, accuracy: 400))), "not within 100 m")
        XCTAssertNil(due(rough, fixes(fix(5, accuracy: 40))), "older than the position it would replace")
        XCTAssertEqual(due(record(held(10, accuracy: 100.5)), fixes(fix(20, accuracy: 100))),
                       .position(SOSManager.sealable(fix(20, accuracy: 100))))
        XCTAssertNil(due(record(held(10, accuracy: 100)), fixes(fix(20, accuracy: 5))), "100 m needs nothing better")
        let bubble = record(held(-30, accuracy: 2 * 1_609.344))
        XCTAssertEqual(due(bubble, fixes(fix(20, accuracy: 9))), .position(SOSManager.sealable(fix(20, accuracy: 9))),
                       "a coarsened held fix")
        var noAccuracy = held(10)
        noAccuracy.accuracy = nil
        XCTAssertEqual(due(record(noAccuracy), fixes(fix(20))), .position(SOSManager.sealable(fix(20))),
                       "an older raiser's position, of no stated accuracy")
    }

    /// The fix goes EXACT: never coarsened to the bubble a held fix was taken
    /// under, whatever the circle.
    func testTheFixGoesExact() throws {
        guard case .position(let sealed)? = due(record(held(-30, accuracy: 25 * 1_609.344)),
                                                fixes(fix(20, accuracy: 6, lat: 37.33491234, lon: -122.00912345)))
        else { return XCTFail("no update") }
        XCTAssertEqual(sealed.latitude, 37.33491234)
        XCTAssertEqual(sealed.longitude, -122.00912345)
        XCTAssertEqual(sealed.accuracy, 6)
        XCTAssertEqual(sealed.timestamp, pressMs + 20_000, "its own capture time")
    }

    /// (d): "pending" and a definite cause: "unavail". (e): still "pending"
    /// when the ten minutes end: "unavail".
    func testUnavailForADefiniteCauseAndAtTheWindowsEnd() {
        XCTAssertEqual(due(record(marker: .pending), off: true), .marker(.unavail))
        XCTAssertNil(due(record(marker: .unavail), off: true), "said already")
        XCTAssertNil(due(record(held(-600)), off: true), "a position stays")
        XCTAssertEqual(due(record(marker: .pending), fixes(fix(20)), off: true), .position(SOSManager.sealable(fix(20))),
                       "a fix taken before access went off is a position")
        XCTAssertEqual(due(record(marker: .pending), at: 600), .marker(.unavail), "(e)")
        XCTAssertEqual(due(record(marker: .pending), at: 3_600), .marker(.unavail), "(e) for a phone that slept through it")
        XCTAssertNil(due(record(marker: .pending), at: 599.9), "not yet")
        XCTAssertNil(due(record(marker: .unavail), at: 600))
    }

    /// Ten minutes from the press and three updates: then nothing more (no
    /// following).
    func testTheWindowAndTheCount() {
        let last = record(held(-600))
        XCTAssertNotNil(due(last, fixes(fix(590)), at: 599))
        XCTAssertNil(due(last, fixes(fix(590)), at: 600), "the window ended")
        XCTAssertNil(due(last, fixes(fix(700)), at: 900))
        XCTAssertEqual(due(record(marker: .pending), fixes(fix(700)), at: 900), .marker(.unavail),
                       "after the window, (e) alone: never the fix")
        XCTAssertNil(due(record(marker: .pending, updates: 3), fixes(fix(20))), "three updates")
        XCTAssertNotNil(due(record(marker: .pending, updates: 2), fixes(fix(20))))
        XCTAssertEqual(SOSManager.maxPositionUpdates, 3)
        XCTAssertEqual(SOSManager.updateWindow, 600)
    }

    // MARK: - Runs (real keys)

    private final class Storage: KeyStorageCallback, @unchecked Sendable {
        private let lock = NSLock()
        private var stored: StoredKeyData?
        func loadKeys() throws -> StoredKeyData? { lock.lock(); defer { lock.unlock() }; return stored }
        func storeKeys(data: StoredKeyData) throws { lock.lock(); stored = data; lock.unlock() }
        func deleteKeys() throws { lock.lock(); stored = nil; lock.unlock() }
    }

    private func crypto() throws -> CryptoManager {
        let sdk = CryptoManager()
        sdk.registerSecureStorage(storage: Storage())
        _ = sdk.generateKeypair()
        _ = sdk.generateSigningKeypair()
        let creation = try sdk.prepareCircleCreation()
        try sdk.finalizeCircleCreation(tempCircleId: creation.tempCircleId, realCircleId: circleId)
        return sdk
    }

    private func blob(_ e: EncryptedBlobRequest) -> [String: Any] { ["nonce": e.nonce, "ciphertext": e.ciphertext] }

    /// The row the server keeps for this device's alert, raised at the press
    /// (or with another raise time this phone sealed).
    private func raised(_ payload: SOSManager.RaisePayload, crypto: CryptoManager, at raisedAt: Date? = nil) throws
        -> (row: SOSResponse, record: SOSSealedPositions.Record) {
        let request = try SOSManager.createRequest(circleId: circleId, userId: me, deviceId: device, payload: payload,
                                                   raisedAt: raisedAt ?? press, message: nil, crypto: crypto)
        let row: [String: Any] = [
            "id": alertId, "circle_id": circleId, "status": "active", "day_bucket": request.dayBucket,
            "encrypted_user_id": blob(request.encryptedUserId), "encrypted_device_id": blob(request.encryptedDeviceId),
            "encrypted_timestamp": blob(request.encryptedTimestamp), "encrypted_location": blob(request.encryptedLocation),
        ]
        let response = try APIService.makeWireDecoder().decode(SOSResponse.self,
                                                               from: JSONSerialization.data(withJSONObject: row))
        let record = try XCTUnwrap(SOSManager.sealedRecord(request.encryptedLocation, circleId: circleId,
                                                           pressAtMs: pressMs, locationOff: false, updates: 0,
                                                           crypto: crypto))
        return (response, record)
    }

    /// The row once the server took a re-seal.
    private func applying(_ request: ResealSOSRequest, to row: SOSResponse) throws -> SOSResponse {
        let json: [String: Any] = [
            "id": row.id, "circle_id": row.circleId, "status": row.status, "day_bucket": row.dayBucket,
            "encrypted_user_id": blob(request.encryptedUserId), "encrypted_device_id": blob(request.encryptedDeviceId),
            "encrypted_timestamp": blob(request.encryptedTimestamp), "encrypted_location": blob(request.encryptedLocation),
        ]
        return try APIService.makeWireDecoder().decode(SOSResponse.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private final class Server {
        var served: SOSResponse
        var puts: [ResealSOSRequest] = []
        init(_ served: SOSResponse) { self.served = served }
    }

    private final class Kept {
        var record: SOSSealedPositions.Record?
        init(_ record: SOSSealedPositions.Record?) { self.record = record }
    }

    private func runWorld(_ server: Server, _ kept: Kept, crypto: CryptoManager, now: Date,
                       fixes: SOSManager.AfterPress = .init()) -> SOSManager.UpdateWorld {
        SOSManager.UpdateWorld(
            me: me, deviceId: device, crypto: crypto, now: { now },
            record: { kept.record }, keep: { kept.record = $0 }, forget: { kept.record = nil },
            fixes: { fixes }, locationOff: { false },
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

    /// What the row opens as, to this device.
    private func opened(_ row: SOSResponse, crypto: CryptoManager) -> SOSReceiverRules.Opened {
        SOSReceiverRules.open(row, myUserId: me, myDeviceId: device, crypto: crypto)
    }

    /// An update: the fix goes out exact with its own time and accuracy, the
    /// ORIGINAL raise time, and the record is what was sealed, one update on.
    func testAnUpdateIsSealedAndRecorded() async throws {
        let sdk = try crypto()
        let (row, record) = try raised(.marker(.pending), crypto: sdk)
        let server = Server(row)
        let kept = Kept(record)
        let f = fix(25, accuracy: 6.123456789, lat: 37.33490004, lon: -122.00900006)
        guard case .resealed = await SOSManager.updateRun(world: runWorld(server, kept, crypto: sdk, now: at(30),
                                                                         fixes: fixes(f)))
        else { return XCTFail("no update") }
        let served = opened(server.served, crypto: sdk)
        XCTAssertTrue(served.current)
        XCTAssertEqual(served.sealedTimeMs, pressMs, "the original raise time")
        XCTAssertEqual(served.location?.timestamp, pressMs + 25_000)
        XCTAssertEqual(served.location?.accuracy, Double(Float(6.123456789)))
        XCTAssertEqual(served.location?.latitude, 37.3349)
        XCTAssertEqual(kept.record?.updates, 1)
        XCTAssertNil(kept.record?.marker)
        XCTAssertEqual(kept.record?.position, served.location.map { SOSSealedPositions.Sealed($0) },
                       "the decoded copy of what was sealed")
        XCTAssertEqual(kept.record?.raisedAtMs, pressMs, "and the raise time it sealed")
        XCTAssertEqual(SOSManager.raiserLine(kept.record, raisedAt: press, now: at(30)),
                       "Your location was added at \(SOSPositionText.time(at(25), now: at(30)))")
    }

    /// The row as a server could serve it in ANOTHER of this account's
    /// circles: every part sealed by this phone under that circle's key with
    /// the same field tags, as one of its check-ins there carries, so it opens
    /// as "raised here" under that circle.
    private func relabelled(into other: String, crypto: CryptoManager) throws -> SOSResponse {
        let request = try SOSManager.createRequest(circleId: other, userId: me, deviceId: device,
                                                   payload: .position(held(-7_200)), raisedAt: press, message: nil,
                                                   crypto: crypto)
        let row: [String: Any] = [
            "id": alertId, "circle_id": other, "status": "active", "day_bucket": request.dayBucket,
            "encrypted_user_id": blob(request.encryptedUserId), "encrypted_device_id": blob(request.encryptedDeviceId),
            "encrypted_timestamp": blob(request.encryptedTimestamp), "encrypted_location": blob(request.encryptedLocation),
        ]
        return try APIService.makeWireDecoder().decode(SOSResponse.self, from: JSONSerialization.data(withJSONObject: row))
    }

    private final class Count {
        var value = 0
    }

    /// This device seals its alert only into the circle it raised it in.
    /// Served as another of this account's circles, where it opens as raised
    /// here, a run seals nothing into it, for a catch-up and for a due update
    /// alike: no PUT, the record as it was, and no record from a press here
    /// either. Served in its own circle, the same runs go ahead.
    func testARelabelledAlertGetsNothing() async throws {
        let sdk = try crypto()
        let work = "c5090000-0000-4000-8000-0000000000bb"
        let creation = try sdk.prepareCircleCreation()
        try sdk.finalizeCircleCreation(tempCircleId: creation.tempCircleId, realCircleId: work)
        let elsewhere = try relabelled(into: work, crypto: sdk)
        let opensHere = opened(elsewhere, crypto: sdk)
        XCTAssertTrue(opensHere.opened && opensHere.raisedHere && opensHere.current,
                      "it opens as raised here, under Work's current key")
        let (_, exact) = try raised(.position(held(0, accuracy: 6)), crypto: sdk)
        let (familyRow, pending) = try raised(.marker(.pending), crypto: sdk)
        // A re-seal goes into the circle it is given, never the row's.
        let request = try XCTUnwrap(try SOSManager.resealRequest(for: elsewhere, into: circleId, opened: opensHere,
                                                                 payload: .marker(.pending), deviceId: device,
                                                                 holdsCurrentKey: true, crypto: sdk))
        let raiser = EncryptedData(nonce: request.encryptedUserId.nonce, ciphertext: request.encryptedUserId.ciphertext)
        XCTAssertEqual(try? sdk.decryptDataV2(circleId: circleId, encryptedData: raiser, fieldTag: "user_id"), me)
        XCTAssertNil(try? sdk.decryptDataV2(circleId: work, encryptedData: raiser, fieldTag: "user_id"),
                     "never under Work's key")

        func run(_ row: SOSResponse, _ kept: Kept, press: String? = nil, fixes: SOSManager.AfterPress = .init(),
                 noted: Count = Count()) async -> (SOSManager.UpdateOutcome, Server) {
            let server = Server(row)
            var env = runWorld(server, kept, crypto: sdk, now: at(30), fixes: fixes)
            env.pressCircleId = { press }
            env.noteRelabelled = { noted.value += 1 }
            return (await SOSManager.updateRun(world: env), server)
        }
        // A catch-up: Work doesn't serve the record's exact position.
        let noted = Count()
        var kept = Kept(exact)
        var (outcome, server) = await run(elsewhere, kept, noted: noted)
        guard case .unchanged = outcome else { return XCTFail("a catch-up into Work: \(outcome.label)") }
        XCTAssertTrue(server.puts.isEmpty)
        XCTAssertEqual(kept.record, exact)
        XCTAssertEqual(noted.value, 1, "noted")
        // A due update: a marker record and a fix after the press.
        kept = Kept(pending)
        (outcome, server) = await run(elsewhere, kept, press: circleId, fixes: fixes(fix(20)))
        guard case .unchanged = outcome else { return XCTFail("an update into Work: \(outcome.label)") }
        XCTAssertTrue(server.puts.isEmpty)
        XCTAssertEqual(kept.record, pending)
        // No record: this process's press says the same.
        kept = Kept(nil)
        (outcome, server) = await run(elsewhere, kept, press: circleId, fixes: fixes(fix(20)))
        guard case .unchanged = outcome else { return XCTFail("a press's update into Work: \(outcome.label)") }
        XCTAssertTrue(server.puts.isEmpty)
        XCTAssertNil(kept.record)
        // Neither: no update, and no record naming the circle the server named.
        (outcome, server) = await run(familyRow, kept, fixes: fixes(fix(20)))
        guard case .unchanged = outcome else { return XCTFail("an update with neither: \(outcome.label)") }
        XCTAssertTrue(server.puts.isEmpty)
        XCTAssertNil(kept.record)

        // The control: served in its own circle, the update goes, and the
        // record names that circle.
        kept = Kept(pending)
        (outcome, server) = await run(familyRow, kept, fixes: fixes(fix(20)))
        guard case .resealed = outcome else { return XCTFail("its own circle: \(outcome.label)") }
        XCTAssertEqual(server.puts.count, 1)
        XCTAssertEqual(kept.record?.circleId, circleId)
        XCTAssertEqual(kept.record?.updates, 1)
        kept = Kept(nil)
        (outcome, server) = await run(familyRow, kept, press: circleId, fixes: fixes(fix(20)))
        guard case .resealed = outcome else { return XCTFail("a press here, its own circle: \(outcome.label)") }
        XCTAssertEqual(server.puts.count, 1)
        XCTAssertEqual(kept.record?.circleId, circleId, "the press's circle")
    }

    /// As on Android: a re-seal seals the raise time this device sealed, its
    /// record's, never the served one. A served time that differs (another
    /// time this phone sealed, swapped in) is a catch-up, sealed back, and then
    /// nothing more. A record written without the time seals the time as it
    /// opens, and is never re-sealed for it.
    func testASwappedRaiseTimeIsSealedBack() async throws {
        let sdk = try crypto()
        let (_, record) = try raised(.marker(.pending), crypto: sdk)
        var mine = record
        mine.raisedAtMs = pressMs
        let later = pressMs + 7_200_000
        let (swapped, _) = try raised(.marker(.pending), crypto: sdk,
                                      at: Date(timeIntervalSince1970: TimeInterval(later) / 1000))
        let served = opened(swapped, crypto: sdk)
        XCTAssertTrue(served.current)
        XCTAssertEqual(served.sealedTimeMs, later)
        XCTAssertTrue(SOSManager.serves(mine, served), "the position is as recorded: only the time differs")

        let server = Server(swapped)
        let kept = Kept(mine)
        guard case .resealed = await SOSManager.updateRun(world: runWorld(server, kept, crypto: sdk, now: at(30)))
        else { return XCTFail("the swapped time was not sealed back") }
        XCTAssertEqual(server.puts.count, 1)
        XCTAssertEqual(opened(server.served, crypto: sdk).sealedTimeMs, pressMs, "this device's raise time")
        XCTAssertEqual(kept.record?.raisedAtMs, pressMs)
        XCTAssertEqual(kept.record?.marker, .pending)
        XCTAssertEqual(kept.record?.updates, 0, "a catch-up, not an update")
        guard case .unchanged = await SOSManager.updateRun(world: runWorld(server, kept, crypto: sdk, now: at(40)))
        else { return XCTFail("sealed again") }
        XCTAssertEqual(server.puts.count, 1)

        // A record written without the time: no catch-up for the time.
        let oldServer = Server(swapped)
        guard case .unchanged = await SOSManager.updateRun(world: runWorld(oldServer, Kept(record), crypto: sdk,
                                                                           now: at(30)))
        else { return XCTFail("an old record re-sealed for the time") }
        XCTAssertTrue(oldServer.puts.isEmpty)
        // Its update, though, carries the time as it opens.
        let updated = Server(swapped)
        let oldKept = Kept(record)
        guard case .resealed = await SOSManager.updateRun(world: runWorld(updated, oldKept, crypto: sdk, now: at(30),
                                                                          fixes: fixes(fix(20))))
        else { return XCTFail("no update") }
        XCTAssertEqual(opened(updated.served, crypto: sdk).sealedTimeMs, later)
        XCTAssertEqual(oldKept.record?.raisedAtMs, later, "kept as sealed from here")
    }

    /// Once updated, the served copy of the record's own position is never
    /// re-sealed, however often it is checked: the record is the decoded copy
    /// of what was sealed (the fix's doubles are on no 1e-7 grid and its
    /// accuracy is no f32), compared exactly.
    func testAnUpdatedRecordIsNeverResealedAgain() async throws {
        let sdk = try crypto()
        let (row, record) = try raised(.marker(.pending), crypto: sdk)
        let server = Server(row)
        let kept = Kept(record)
        let f = fix(25, accuracy: 6.123456789, lat: 37.33490004, lon: -122.00900006)
        _ = await SOSManager.updateRun(world: runWorld(server, kept, crypto: sdk, now: at(30), fixes: fixes(f)))
        XCTAssertEqual(server.puts.count, 1)
        for minute in 1...60 {
            let outcome = await SOSManager.updateRun(world: runWorld(server, kept, crypto: sdk,
                                                                  now: at(30 + TimeInterval(minute) * 60),
                                                                  fixes: fixes(f)))
            guard case .unchanged = outcome else { return XCTFail("minute \(minute): \(outcome)") }
        }
        XCTAssertEqual(server.puts.count, 1, "the hourly budget stays for a rotation")
    }

    /// A reseal response that echoes ANOTHER position leaves the record as
    /// this device sealed it, and the next run seals it back.
    func testADifferentEchoLeavesTheRecordAsSealed() async throws {
        let sdk = try crypto()
        let (row, record) = try raised(.marker(.pending), crypto: sdk)
        let (swapped, _) = try raised(.position(SOSManager.sealable(fix(26, lat: 48.8584, lon: 2.2945))), crypto: sdk)
        let server = Server(row)
        let kept = Kept(record)
        let f = fix(25)
        var hostile = runWorld(server, kept, crypto: sdk, now: at(30), fixes: fixes(f))
        hostile.put = { request in
            server.puts.append(request)
            server.served = swapped
            return swapped
        }
        _ = await SOSManager.updateRun(world: hostile)
        XCTAssertEqual(kept.record?.position?.latitude, 37.3349, "what this device sealed, not the echo")
        XCTAssertEqual(kept.record?.updates, 1)
        // The next run finds the swap and seals the record back (not an update).
        guard case .resealed = await SOSManager.updateRun(world: runWorld(server, kept, crypto: sdk, now: at(40),
                                                                         fixes: fixes(f)))
        else { return XCTFail("not sealed back") }
        XCTAssertEqual(opened(server.served, crypto: sdk).location?.latitude, 37.3349)
        XCTAssertEqual(kept.record?.updates, 1)
    }

    /// An update goes over a row that differs from the record: the newer fix,
    /// never the served position, nor the record it would replace.
    func testAnUpdateGoesOverADifferingServedRow() async throws {
        let sdk = try crypto()
        let (_, record) = try raised(.position(held(-600)), crypto: sdk)
        let (swapped, _) = try raised(.position(SOSManager.sealable(fix(-900, lat: 48.8584, lon: 2.2945))),
                                      crypto: sdk)
        let server = Server(swapped)
        let kept = Kept(record)
        _ = await SOSManager.updateRun(world: runWorld(server, kept, crypto: sdk, now: at(30), fixes: fixes(fix(25))))
        XCTAssertEqual(server.puts.count, 1)
        XCTAssertEqual(opened(server.served, crypto: sdk).location?.timestamp, pressMs + 25_000, "the fix")
        XCTAssertEqual(kept.record?.updates, 1)
    }

    /// (d) and (e) go out as "unavail"; (d) keeps its cause for the raiser's
    /// card.
    func testUnavailGoesOutForADefiniteCauseAndAtTheWindowsEnd() async throws {
        let sdk = try crypto()
        let (row, record) = try raised(.marker(.pending), crypto: sdk)
        var server = Server(row)
        var kept = Kept(record)
        var off = runWorld(server, kept, crypto: sdk, now: at(30))
        off.locationOff = { true }
        _ = await SOSManager.updateRun(world: off)
        XCTAssertEqual(opened(server.served, crypto: sdk).marker, .unavail)
        XCTAssertEqual(kept.record?.marker, .unavail)
        XCTAssertEqual(kept.record?.locationOff, true)
        XCTAssertEqual(kept.record?.updates, 1)

        server = Server(row)
        kept = Kept(record)
        _ = await SOSManager.updateRun(world: runWorld(server, kept, crypto: sdk, now: at(601)))
        XCTAssertEqual(opened(server.served, crypto: sdk).marker, .unavail, "(e): never left \"pending\"")
        XCTAssertEqual(kept.record?.locationOff, false)
        XCTAssertEqual(SOSManager.raiserLine(kept.record, raisedAt: press), "Sent without your location")
    }

    /// The circle and its keys are read before anything is sealed, and the
    /// key gate is asked after that read.
    func testTheKeysAreReadBeforeAnythingIsSealed() async throws {
        let sdk = try crypto()
        let (row, record) = try raised(.marker(.pending), crypto: sdk)
        let server = Server(row)
        var log: [String] = []
        var run = runWorld(server, Kept(record), crypto: sdk, now: at(30), fixes: fixes(fix(25)))
        run.refreshKeys = { id in log.append("read \(id)") }
        run.holdsCurrentKey = { _ in log.append("gate"); return log.contains("read \(self.circleId)") }
        let put = run.put
        run.put = { request in log.append("put"); return try await put(request) }
        _ = await SOSManager.updateRun(world: run)
        XCTAssertEqual(log, ["read \(circleId)", "gate", "put"])

        // Nothing due: no read at all.
        log = []
        var idle = runWorld(server, Kept(SOSManager.sealedRecord(
            EncryptedBlobRequest(nonce: server.served.encryptedLocation.nonce,
                                 ciphertext: server.served.encryptedLocation.ciphertext),
            circleId: circleId, pressAtMs: pressMs, locationOff: false, updates: 1, crypto: sdk)),
                         crypto: sdk, now: at(40))
        idle.refreshKeys = { _ in log.append("read") }
        guard case .unchanged = await SOSManager.updateRun(world: idle) else { return XCTFail("nothing was due") }
        XCTAssertEqual(log, [])
    }

    /// Under `key_rotation_needed` the update waits, asked again, and goes
    /// after two minutes from its first wait anyway; a re-seal of the record
    /// alone does not wait.
    func testAnUpdateWaitsForARotationAtMostTwoMinutes() async throws {
        let sdk = try crypto()
        let (row, record) = try raised(.marker(.pending), crypto: sdk)
        let server = Server(row)
        let kept = Kept(record)
        var since: Date?
        func run(_ seconds: TimeInterval, flagged: Bool = true) async -> SOSManager.UpdateOutcome {
            var world = runWorld(server, kept, crypto: sdk, now: at(seconds), fixes: fixes(fix(25)))
            world.rotationNeeded = { _ in flagged }
            world.deferredSince = { since }
            world.noteDeferral = { since = $0 }
            return await SOSManager.updateRun(world: world)
        }
        guard case .deferred = await run(30) else { return XCTFail("no wait") }
        XCTAssertEqual(since, at(30))
        guard case .deferred = await run(60) else { return XCTFail("asked again") }
        guard case .deferred = await run(149) else { return XCTFail("within two minutes") }
        XCTAssertEqual(since, at(30), "from the first wait")
        XCTAssertTrue(server.puts.isEmpty)
        guard case .resealed = await run(150) else { return XCTFail("two minutes: it goes anyway") }
        XCTAssertEqual(server.puts.count, 1)
        XCTAssertEqual(SOSManager.rotationDeferLimit, 120)
        XCTAssertLessThanOrEqual(SOSManager.rotationRecheck, 30)

        // Unflagged: at once, and the wait is forgotten.
        let fresh = Server(row)
        since = at(10)
        var unflagged = runWorld(fresh, Kept(record), crypto: sdk, now: at(30), fixes: fixes(fix(25)))
        unflagged.deferredSince = { since }
        unflagged.noteDeferral = { since = $0 }
        guard case .resealed = await SOSManager.updateRun(world: unflagged) else { return XCTFail("not at once") }
        XCTAssertNil(since)

        // A re-seal of the record (here, the row differs from it) does not wait.
        let (swapped, _) = try raised(.marker(.unavail), crypto: sdk)
        let differs = Server(swapped)
        var rotation = runWorld(differs, Kept(record), crypto: sdk, now: at(30))
        rotation.rotationNeeded = { _ in true }
        guard case .resealed = await SOSManager.updateRun(world: rotation) else { return XCTFail("waited") }
        XCTAssertEqual(opened(differs.served, crypto: sdk).marker, .pending)
    }

    /// At the window's end: an update that waits for a rotation from before
    /// the ten minutes end goes out as the fix it waited with, never as (e)'s
    /// "unavail"; and a later update gets a wait of its own.
    func testAnUpdateWaitingAcrossTheWindowsEndStaysTheFix() async throws {
        let sdk = try crypto()
        let (row, record) = try raised(.marker(.pending), crypto: sdk)
        let server = Server(row)
        let kept = Kept(record)
        var since: Date?
        func run(_ seconds: TimeInterval) async -> SOSManager.UpdateOutcome {
            var world = runWorld(server, kept, crypto: sdk, now: at(seconds), fixes: fixes(fix(585)))
            world.rotationNeeded = { _ in true }
            world.deferredSince = { since }
            world.noteDeferral = { since = $0 }
            return await SOSManager.updateRun(world: world)
        }
        guard case .deferred = await run(590) else { return XCTFail("no wait") }
        guard case .deferred = await run(620) else { return XCTFail("still waiting past the window's end") }
        guard case .resealed = await run(710) else { return XCTFail("two minutes: it goes") }
        XCTAssertEqual(opened(server.served, crypto: sdk).location?.timestamp, pressMs + 585_000,
                       "the fix, not \"unavail\"")
        XCTAssertNil(since, "the wait is over")
        // A wait long past its bound is over: the update is judged now (past
        // the window, that is (e)), and it waits on its own.
        since = at(100)
        let late = Server(row)
        func lateRun(_ seconds: TimeInterval) async -> SOSManager.UpdateOutcome {
            var world = runWorld(late, Kept(record), crypto: sdk, now: at(seconds), fixes: fixes(fix(585)))
            world.rotationNeeded = { _ in true }
            world.deferredSince = { since }
            world.noteDeferral = { since = $0 }
            return await SOSManager.updateRun(world: world)
        }
        guard case .deferred = await lateRun(900) else { return XCTFail("its own wait") }
        XCTAssertEqual(since, at(900))
        guard case .resealed = await lateRun(1_020) else { return XCTFail("two minutes: it goes") }
        XCTAssertEqual(opened(late.served, crypto: sdk).marker, .unavail, "(e), as without a wait")
    }

    /// One run at a time per alert, so a re-seal never reverts an update.
    /// Here the update's PUT is taken by the server but its answer is late; a
    /// run asked for meanwhile (past the window: no update of its own) starts
    /// only after it, finds the update served and recorded, and seals nothing.
    func testRunsSerializeAndAResealNeverRevertsAnUpdate() async throws {
        let sdk = try crypto()
        let (row, record) = try raised(.position(held(-600)), crypto: sdk)
        let server = Server(row)
        let kept = Kept(record)
        let runs = SerialRuns<SOSManager.UpdateOutcome>()
        let late = Gate()
        var log: [String] = []
        var update = runWorld(server, kept, crypto: sdk, now: at(599), fixes: fixes(fix(590)))
        update.put = { [unowned self] request in
            server.puts.append(request)
            server.served = try self.applying(request, to: server.served)
            log.append("update taken")
            await late.wait()
            log.append("update answered")
            return server.served
        }
        var second = runWorld(server, kept, crypto: sdk, now: at(605))
        second.get = { log.append("second reads"); return server.served }
        let first = runs.run(alertId) { await SOSManager.updateRun(world: update) }
        guard await spin(until: { log.contains("update taken") }) else {
            late.open()
            return XCTFail("the update was never sent: \(log)")
        }
        let then = runs.run(alertId) { await SOSManager.updateRun(world: second) }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(log, ["update taken"], "the second waits")
        late.open()
        _ = await first.value
        guard case .unchanged? = await then.value else { return XCTFail("the second sealed something") }
        XCTAssertEqual(log, ["update taken", "update answered", "second reads"])
        XCTAssertEqual(server.puts.count, 1)
        XCTAssertEqual(opened(server.served, crypto: sdk).location?.timestamp, pressMs + 590_000, "still the update")
    }

    /// A run asked for while another of the same alert waits to start joins
    /// it (it reads everything afresh when it starts); one asked for while
    /// another runs waits for it.
    func testAWaitingRunIsJoinedNotRepeated() async {
        let runs = SerialRuns<Int>()
        let hold = Gate()
        var started = 0
        let first = runs.run("a") { started += 1; await hold.wait(); return 1 }
        let early = runs.run("a") { started += 1; return 0 }
        guard await spin(until: { started > 0 }) else {
            hold.open()
            return XCTFail("the first run never started")
        }
        let second = runs.run("a") { started += 1; return 2 }
        let third = runs.run("a") { started += 1; return 3 }
        let otherValue = await runs.run("b") { 4 }.value
        XCTAssertEqual(otherValue, 4, "another alert's run doesn't wait")
        XCTAssertEqual(started, 1)
        hold.open()
        let values = [await first.value, await early.value, await second.value, await third.value]
        XCTAssertEqual(values, [1, 1, 2, 2], "each joined the one waiting to start")
        XCTAssertEqual(started, 2)
        let afterValue = await runs.run("a") { 5 }.value
        XCTAssertEqual(afterValue, 5)
        // Sign-out: a run not started yet never starts.
        let late = Gate()
        var running = false
        let busy = runs.run("c") { running = true; await late.wait(); return 6 }
        guard await spin(until: { running }) else {
            late.open()
            return XCTFail("the run never started")
        }
        let queued = runs.run("c") { started += 1; return 7 }
        runs.reset()
        late.open()
        let results = [await busy.value, await queued.value]
        XCTAssertEqual(results, [6, nil])
        XCTAssertEqual(started, 2, "the queued run never started")
    }

    /// The key check fetches the key and runs only when the listed version
    /// moved: from the one held at first, then from the one last seen.
    func testTheKeyCheckRunsOnlyWhenTheVersionMoved() {
        XCTAssertFalse(SOSManager.keyMoved(listed: 3, seen: nil, held: 3))
        XCTAssertTrue(SOSManager.keyMoved(listed: 4, seen: nil, held: 3))
        XCTAssertFalse(SOSManager.keyMoved(listed: 4, seen: 4, held: 3), "seen: not again while it can't be fetched")
        XCTAssertTrue(SOSManager.keyMoved(listed: 5, seen: 4, held: 4))
        XCTAssertTrue(SOSManager.keyMoved(listed: 1, seen: nil, held: nil))
        XCTAssertEqual(SOSManager.keyCheckInterval, 60)
    }

    /// Yields until `done`, a bounded number of times: a test waiting on the
    /// code fails, instead of hanging, when the code never gets there.
    private func spin(until done: () -> Bool, limit: Int = 10_000) async -> Bool {
        var spins = 0
        while !done(), spins < limit {
            spins += 1
            await Task.yield()
        }
        return done()
    }

    // MARK: - Wiring (source)

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func body(_ src: String, from start: String, to end: String) throws -> String {
        let a = try XCTUnwrap(src.range(of: start), start)
        let b = try XCTUnwrap(src.range(of: end, range: a.upperBound..<src.endIndex), end)
        return String(src[a.lowerBound..<b.lowerBound])
    }

    /// What keeps the alert updated: every fix taken, location access, the
    /// window's end and the key check for the whole alert; from the raise and
    /// a restore (which waits for the primed keys); stopped at the close and
    /// at sign-out.
    func testTheUpdatesAreWired() throws {
        let manager = try source("App/Managers/SOSManager.swift")
        let watch = try body(manager, from: "    private func startUpdateWatch(", to: "    private func stopUpdateWatch() {")
        XCTAssertTrue(watch.contains("        locationService.locationUpdates\n"))
        XCTAssertTrue(watch.contains("Task { @MainActor in self?.offer(fix, alertId: alertId, pressAt: pressAt) }"))
        XCTAssertTrue(watch.contains("        locationService.$authorizationStatus\n"))
        XCTAssertTrue(watch.contains("let windowEnd = pressAt.addingTimeInterval(Self.updateWindow)"))
        XCTAssertTrue(watch.contains("keyCheckTimer = Timer.scheduledTimer(withTimeInterval: Self.keyCheckInterval, repeats: true)"))
        XCTAssertTrue(watch.contains("await self?.checkKey(alertId: alertId, circleId: circleId, raisedAt: raisedAt)"))
        let check = try body(manager, from: "    private func checkKey(", to: "    nonisolated static func keyMoved(")
        XCTAssertFalse(check.contains("updateWindow"), "the key check runs for the whole alert")
        XCTAssertTrue(check.contains("guard Date().timeIntervalSince(raisedAt) * 1000 <= Double(Self.maxAlarmAgeMs) else {"))
        XCTAssertTrue(check.contains("try? await CircleManager.shared.loadCircles(light: true)\n        runUpdate(alertId)\n"))
        let offer = try body(manager, from: "    private func offer(", to: "    private func updateIfDue(")
        XCTAssertTrue(offer.contains(".offer(fix, pressAt: pressAt)\n        updateIfDue(alertId)\n"))
        let restore = try body(manager, from: "        } else if let own = Self.ownToRestore(", to: "    /// What showing this account's own")
        XCTAssertTrue(restore.contains("            startUpdateWatch(alertId: restored.id, circleId: restored.circleId, pressAt: pressAt,\n"))
        XCTAssertTrue(restore.contains("            updateIfDue(restored.id)\n"))
        let close = try body(manager, from: "    private func closeMyAlert(", to: "    private func pollAlertStatus(")
        XCTAssertTrue(close.contains("        if CanonicalId.same(watchedAlertId, alertId) { stopUpdateWatch() }\n"))
        let reset = try body(manager, from: "    func reset() {", to: "    /// Build the E2EE CreateSOSRequest")
        XCTAssertTrue(reset.contains("        updateRuns.reset()\n        stopUpdateWatch()\n"))
        // Every run goes through the alert's one serialized operation.
        XCTAssertEqual(manager.components(separatedBy: "Self.updateRun(world:").count - 1, 1)
        XCTAssertTrue(manager.contains("        updateRuns.run(CanonicalId.key(alertId)) { [weak self] in\n"))
        // The record goes past the alarm age, as the marks do.
        XCTAssertTrue(manager.contains(
            "            SOSSealedPositions.shared.prune(owner: myUserId, nowMs: now, maxAgeMs: Self.maxAlarmAgeMs)\n"))
    }

    /// The record goes once its alert is past the alarm age.
    func testTheRecordGoesPastTheAlarmAge() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sos-prune-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = SOSSealedPositions(directory: directory)
        store.note(record(marker: .pending), alertId: alertId, owner: me)
        store.prune(owner: me, nowMs: pressMs + SOSManager.maxAlarmAgeMs, maxAgeMs: SOSManager.maxAlarmAgeMs)
        XCTAssertNotNil(SOSSealedPositions(directory: directory).record(alertId: alertId, owner: me))
        store.prune(owner: me, nowMs: pressMs + SOSManager.maxAlarmAgeMs + 1, maxAgeMs: SOSManager.maxAlarmAgeMs)
        XCTAssertNil(SOSSealedPositions(directory: directory).record(alertId: alertId, owner: me))
    }
}

/// Holds whoever waits on it until it is opened.
@MainActor
private final class Gate {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        isOpen = true
        waiting.forEach { $0.resume() }
        waiting = []
    }
}
