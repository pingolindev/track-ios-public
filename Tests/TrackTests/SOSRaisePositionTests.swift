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

/// SOS positions, the raise: it never waits for the GPS. It seals
/// a fix taken after the press, exact; else the newest held fix, if the
/// circle's pause records say this account was sharing when it was taken
/// (else "pending"), coarsened to the bubble then; else a marker, "unavail"
/// only for a definite cause. The sealed `Location` carries the capture time
/// and the accuracy; a marker is its exact 22 bytes. What was sealed is this
/// device's record, and the raiser's card says what went out.
@MainActor
final class SOSRaisePositionTests: XCTestCase {
    private let press = Date(timeIntervalSince1970: 1_727_700_000)

    private func fix(_ secondsBeforePress: TimeInterval, accuracy: CLLocationAccuracy = 12,
                     lat: Double = 37.3349, lon: Double = -122.009) -> CLLocation {
        CLLocation(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon), altitude: 0,
                   horizontalAccuracy: accuracy, verticalAccuracy: 5,
                   timestamp: press.addingTimeInterval(-secondsBeforePress))
    }

    private func rules(awaitsRead: Bool = false, withholds: Bool = false,
                       radius: Double? = nil) -> SOSManager.HeldFixRules {
        SOSManager.HeldFixRules(awaitsRead: { _ in awaitsRead }, withholds: { _ in withholds },
                                captureRadius: { _ in radius })
    }

    private func choose(_ held: [CLLocation], _ rules: SOSManager.HeldFixRules,
                        off: Bool = false) -> SOSManager.RaisePayload {
        SOSManager.raisePayload(pressAt: press, held: held, rules: rules, locationOff: off)
    }

    private struct NotAPosition: Error {}

    /// The position chosen; a failure (never a skip) when it is a marker.
    private func position(_ payload: SOSManager.RaisePayload, line: UInt = #line) throws -> Location {
        guard case .position(let location) = payload else {
            XCTFail("not a position: \(payload)", line: line)
            throw NotAPosition()
        }
        return location
    }

    // MARK: - What the raise seals

    func testAHeldFixGoesWithItsOwnTimeAndAccuracy() throws {
        let held = try position(choose([fix(600, accuracy: 30)], rules()))
        XCTAssertEqual(held.timestamp, 1_727_700_000_000 - 600_000, "its capture time, never the raise time")
        XCTAssertEqual(held.accuracy, 30)
        XCTAssertEqual(held.latitude, 37.3349)
        XCTAssertNil(held.altitude)
        XCTAssertNil(held.speed)
        // The newest by capture time, of the two places it can be held.
        let newest = try position(choose([fix(900, lat: 1), fix(300, lat: 2)], rules()))
        XCTAssertEqual(newest.latitude, 2)
    }

    /// (a) A fix taken after the press (2 s slack) goes EXACT, whatever the
    /// circle's pause or bubble: the dialog's consent covers the exact position now.
    func testAFixAfterThePressIsExactInAPausedOrBubbledCircle() throws {
        let after = try position(choose([fix(-3)], rules(awaitsRead: true, withholds: true, radius: 5)))
        XCTAssertEqual(after.latitude, 37.3349)
        XCTAssertEqual(after.accuracy, 12, "the bubble NOW never applies")
        XCTAssertEqual(try position(choose([fix(2)], rules(withholds: true, radius: 5))).latitude, 37.3349,
                       "two seconds before counts as after")
        XCTAssertEqual(choose([fix(3)], rules(withholds: true)), .marker(.pending))
    }

    /// (b) Not used, and "pending" instead, when the record hasn't been read
    /// since the fix was taken, or says this account wasn't sharing then.
    func testAHeldFixFromAPauseOrAnUnreadStretchSealsPending() {
        XCTAssertEqual(choose([fix(600)], rules(awaitsRead: true)), .marker(.pending))
        XCTAssertEqual(choose([fix(600)], rules(withholds: true)), .marker(.pending))
        XCTAssertEqual(choose([fix(600)], rules(withholds: true), off: true), .marker(.unavail),
                       "a skipped fix with location access off: a definite cause")
    }

    /// The newest held fix decides: an older one is never looked for.
    func testAnOlderHeldFixIsNeverLookedFor() {
        var calls: [Date] = []
        let rules = SOSManager.HeldFixRules(awaitsRead: { calls.append($0); return false },
                                            withholds: { $0 > self.press.addingTimeInterval(-400) },
                                            captureRadius: { _ in nil })
        XCTAssertEqual(SOSManager.raisePayload(pressAt: press, held: [fix(900), fix(300)], rules: rules,
                                               locationOff: false), .marker(.pending))
        XCTAssertEqual(calls, [press.addingTimeInterval(-300)])
    }

    /// Taken under a bubble: coarsened to it, on the grid the live stream uses,
    /// with an accuracy of at least the bubble, so every reader draws an area.
    func testAHeldFixUnderABubbleIsCoarsenedToIt() throws {
        let coarse = try position(choose([fix(600, accuracy: 30)], rules(radius: 2)))
        let (lat, lng) = LocationCoarsener.coarsenLocation(lat: 37.3349, lng: -122.009, radiusMeters: 2 * 1_609.344)
        XCTAssertEqual(coarse.latitude, lat)
        XCTAssertEqual(coarse.longitude, lng)
        XCTAssertEqual(coarse.accuracy, 2 * 1_609.344)
        XCTAssertEqual(coarse.timestamp, 1_727_700_000_000 - 600_000)
        // Unknown bubble: the widest, 25 miles (the record answers it).
        XCTAssertEqual(try position(choose([fix(600)], rules(radius: CirclePauseRecord.unknownBubbleMiles))).accuracy,
                       25 * 1_609.344)
    }

    /// (c) Nothing held: "pending", or "unavail" for a definite cause. A fix
    /// with a negative accuracy is no position at all.
    func testNothingHeldSealsAMarker() {
        XCTAssertEqual(choose([], rules()), .marker(.pending))
        XCTAssertEqual(choose([], rules(), off: true), .marker(.unavail))
        XCTAssertEqual(choose([fix(10, accuracy: -1)], rules()), .marker(.pending))
        XCTAssertEqual(choose([fix(-1, accuracy: -1)], rules()), .marker(.pending), "even after the press")
        XCTAssertTrue(SOSManager.locationOff(.denied))
        XCTAssertTrue(SOSManager.locationOff(.restricted))
        XCTAssertFalse(SOSManager.locationOff(.notDetermined))
        XCTAssertFalse(SOSManager.locationOff(.authorizedWhenInUse))
        XCTAssertFalse(SOSManager.locationOff(.authorizedAlways))
    }

    // MARK: - The sealed body (real keys)

    private final class Storage: KeyStorageCallback, @unchecked Sendable {
        private let lock = NSLock()
        private var stored: StoredKeyData?
        func loadKeys() throws -> StoredKeyData? { lock.lock(); defer { lock.unlock() }; return stored }
        func storeKeys(data: StoredKeyData) throws { lock.lock(); stored = data; lock.unlock() }
        func deleteKeys() throws { lock.lock(); stored = nil; lock.unlock() }
    }

    private func circleCrypto() throws -> (crypto: CryptoManager, circleId: String) {
        let sdk = CryptoManager()
        sdk.registerSecureStorage(storage: Storage())
        _ = sdk.generateKeypair()
        _ = sdk.generateSigningKeypair()
        let creation = try sdk.prepareCircleCreation()
        let circleId = "c5080000-0000-4000-8000-0000000000aa"
        try sdk.finalizeCircleCreation(tempCircleId: creation.tempCircleId, realCircleId: circleId)
        return (sdk, circleId)
    }

    private func opened(_ blob: EncryptedBlobRequest, _ tag: String, _ crypto: CryptoManager,
                        _ circleId: String) throws -> String {
        try crypto.decryptDataV2(circleId: circleId, encryptedData: EncryptedData(nonce: blob.nonce,
                                                                                  ciphertext: blob.ciphertext),
                                 fieldTag: tag)
    }

    /// A position: `timestamp` is the capture time and `accuracy` is set; the
    /// sealed raise time is still when it was raised.
    func testThePositionIsSealedWithItsCaptureTime() throws {
        let (crypto, circleId) = try circleCrypto()
        let held = SOSManager.sealable(fix(600, accuracy: 30))
        let request = try SOSManager.createRequest(circleId: circleId, userId: "u", deviceId: "d",
                                                   payload: .position(held), raisedAt: press, message: nil,
                                                   crypto: crypto)
        let point = try crypto.decryptLocationOpened(
            circleId: circleId, encryptedLocation: EncryptedData(nonce: request.encryptedLocation.nonce,
                                                                 ciphertext: request.encryptedLocation.ciphertext))
        XCTAssertEqual(point.location.timestamp, 1_727_700_000_000 - 600_000)
        XCTAssertEqual(point.location.accuracy, 30)
        XCTAssertEqual(try opened(request.encryptedTimestamp, "timestamp", crypto, circleId), "1727700000000",
                       "the raise time")
        XCTAssertEqual(try opened(request.encryptedUserId, "user_id", crypto, circleId), "u")
        XCTAssertEqual(request.dayBucket, Int(press.timeIntervalSince1970 / 86_400))
        // 22 bytes packed with the accuracy, so 38 sealed, as a marker.
        XCTAssertEqual(request.encryptedLocation.ciphertext.count / 2, 38)
    }

    /// A marker: its exact bytes under the "location" field tag, which the
    /// SDK's location reader refuses and the receivers' rules read as it.
    func testAMarkerIsSealedAsItsExactBytes() throws {
        let (crypto, circleId) = try circleCrypto()
        for marker in SOSPositionMarker.allCases {
            let request = try SOSManager.createRequest(circleId: circleId, userId: "u", deviceId: "d",
                                                       payload: .marker(marker), raisedAt: press, message: nil,
                                                       crypto: crypto)
            let text = try opened(request.encryptedLocation, "location", crypto, circleId)
            XCTAssertEqual(Array(text.utf8), Array(marker.rawValue.utf8))
            XCTAssertEqual(text.utf8.count, 22)
            XCTAssertThrowsError(try crypto.decryptLocationOpened(
                circleId: circleId, encryptedLocation: EncryptedData(nonce: request.encryptedLocation.nonce,
                                                                     ciphertext: request.encryptedLocation.ciphertext)))
            XCTAssertEqual(request.encryptedLocation.ciphertext.count / 2, 38, "the same length as a position")
        }
    }

    // MARK: - The record

    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sos-sealed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private let me = "c5080000-0000-4000-8000-00000000000b"
    private let someoneElse = "c5080000-0000-4000-8000-00000000000c"
    private let alertId = "c5080000-0000-4000-8000-0000000000f1"

    /// Kept as SEALED: opened back from the blob this device sealed,
    /// in the codec's precision (the 1e-7 grid, the accuracy an f32), never
    /// the doubles that went in. A position rebuilt from it packs the same.
    func testTheRecordKeepsThePositionAsSealed() throws {
        let location = Location(latitude: 37.33490004, longitude: -122.00900006, altitude: nil, speed: nil,
                                heading: nil, accuracy: 12.3456789, timestamp: 1_727_699_400_000, batteryLevel: nil,
                                isCharging: nil)
        let (crypto, circleId) = try circleCrypto()
        let request = try SOSManager.createRequest(circleId: circleId, userId: "u", deviceId: "d",
                                                   payload: .position(location), raisedAt: press, message: nil,
                                                   crypto: crypto)
        let record = try XCTUnwrap(SOSManager.sealedRecord(request.encryptedLocation, circleId: circleId,
                                                           pressAtMs: 1_727_700_000_000, locationOff: true,
                                                           updates: 0, crypto: crypto))
        let sealed = try XCTUnwrap(record.position)
        XCTAssertNil(record.marker)
        XCTAssertFalse(record.locationOff, "only for \"unavail\"")
        XCTAssertEqual(record.pressAtMs, 1_727_700_000_000)
        XCTAssertEqual(sealed.latitude, 37.3349, "on the codec's 1e-7 grid")
        XCTAssertEqual(sealed.longitude, -122.0090001)
        XCTAssertEqual(sealed.takenAtMs, 1_727_699_400_000)
        XCTAssertEqual(sealed.accuracy, Double(Float(12.3456789)), "the f32")
        XCTAssertNotEqual(sealed.accuracy, 12.3456789, "never the double that went in")
        XCTAssertNotEqual(SOSSealedPositions.Sealed(location), sealed, "which would differ from every served copy")
        // What the SDK opens is what the record holds, exactly.
        let back = try crypto.decryptLocationOpened(
            circleId: circleId, encryptedLocation: EncryptedData(nonce: request.encryptedLocation.nonce,
                                                                 ciphertext: request.encryptedLocation.ciphertext))
        XCTAssertEqual(SOSSealedPositions.Sealed(back.location), sealed)
        // Sealed again, it opens to the same values: a re-seal of the record
        // is the record.
        let again = try crypto.encryptLocation(circleId: circleId, location: sealed.location)
        XCTAssertEqual(SOSSealedPositions.Sealed(try crypto.decryptLocationOpened(circleId: circleId,
                                                                                 encryptedLocation: again).location),
                       sealed)

        // A marker: the one its exact bytes are, with its cause.
        for (marker, off) in [(SOSPositionMarker.pending, true), (.unavail, true), (.unavail, false)] {
            let request = try SOSManager.createRequest(circleId: circleId, userId: "u", deviceId: "d",
                                                       payload: .marker(marker), raisedAt: press, message: nil,
                                                       crypto: crypto)
            let record = try XCTUnwrap(SOSManager.sealedRecord(request.encryptedLocation, circleId: circleId,
                                                               pressAtMs: 1, locationOff: off, updates: 2,
                                                               crypto: crypto))
            XCTAssertEqual(record.marker, marker)
            XCTAssertNil(record.position)
            XCTAssertEqual(record.locationOff, marker == .unavail && off)
            XCTAssertEqual(record.updates, 2)
        }
        // Anything else under the tag is no record.
        let other = try crypto.encryptDataV2(circleId: circleId, plaintext: #"{"position":"pending"} "#,
                                             fieldTag: "location")
        XCTAssertNil(SOSManager.sealedRecord(EncryptedBlobRequest(nonce: other.nonce, ciphertext: other.ciphertext),
                                             circleId: circleId, pressAtMs: 1, locationOff: false, updates: 0,
                                             crypto: crypto))
    }

    /// One served SOS whose position is `location`, as sealed.
    private func served(_ location: EncryptedData, crypto: CryptoManager, circleId: String) throws -> SOSResponse {
        func blob(_ e: EncryptedData) -> [String: Any] { ["nonce": e.nonce, "ciphertext": e.ciphertext] }
        let row: [String: Any] = [
            "id": alertId, "circle_id": circleId, "status": "active", "day_bucket": 20_000,
            "encrypted_user_id": blob(try crypto.encryptDataV2(circleId: circleId, plaintext: "u", fieldTag: "user_id")),
            "encrypted_device_id": blob(try crypto.encryptDataV2(circleId: circleId, plaintext: "d",
                                                                 fieldTag: "device_id")),
            "encrypted_timestamp": blob(try crypto.encryptDataV2(circleId: circleId, plaintext: "1727700000000",
                                                                 fieldTag: "timestamp")),
            "encrypted_location": blob(location),
        ]
        return try APIService.makeWireDecoder().decode(SOSResponse.self, from: JSONSerialization.data(withJSONObject: row))
    }

    /// The record is opened from the blob THIS DEVICE sealed,
    /// never from the create's response, which echoes what the server keeps:
    /// a server that echoes another position does not write it into the
    /// record.
    func testTheRecordIsNeverTheCreatesEcho() async throws {
        let (crypto, circleId) = try circleCrypto()
        let mine = SOSManager.sealable(fix(-5, accuracy: 9))
        let theirs = Location(latitude: 48.8584, longitude: 2.2945, altitude: nil, speed: nil, heading: nil,
                              accuracy: 9, timestamp: mine.timestamp, batteryLevel: nil, isCharging: nil)
        let echo = try served(try crypto.encryptLocation(circleId: circleId, location: theirs), crypto: crypto,
                              circleId: circleId)
        var posted: CreateSOSRequest?
        let sent = try await SOSManager.sendCreate(
            circleId: circleId, userId: "u", deviceId: "d", payload: .position(mine), raisedAt: press, message: nil,
            crypto: crypto, post: { request in posted = request; return echo })
        XCTAssertEqual(sent.response.id, alertId)
        XCTAssertEqual(sent.sealedLocation.ciphertext, posted?.encryptedLocation.ciphertext, "what it sent")
        let record = try XCTUnwrap(SOSManager.sealedRecord(sent.sealedLocation, circleId: circleId,
                                                           pressAtMs: 1, locationOff: false, updates: 0,
                                                           crypto: crypto))
        XCTAssertEqual(record.position?.latitude, 37.3349)
        XCTAssertEqual(record.position?.longitude, -122.009)
        let echoed = try XCTUnwrap(SOSManager.sealedRecord(
            EncryptedBlobRequest(nonce: echo.encryptedLocation.nonce, ciphertext: echo.encryptedLocation.ciphertext),
            circleId: circleId, pressAtMs: 1, locationOff: false, updates: 0, crypto: crypto))
        XCTAssertNotEqual(echoed.position, record.position, "the echo is another position")
    }

    /// As on Android: the record keeps the raise time this device sealed,
    /// opened back from the timestamp blob it sent, never one the create's
    /// response echoes.
    func testTheRecordKeepsTheRaiseTimeItSealed() async throws {
        let (crypto, circleId) = try circleCrypto()
        let echo = try served(try crypto.encryptDataV2(circleId: circleId, plaintext: "pending", fieldTag: "location"),
                              crypto: crypto, circleId: circleId)
        var posted: CreateSOSRequest?
        let raisedAt = press.addingTimeInterval(3)
        let sent = try await SOSManager.sendCreate(
            circleId: circleId, userId: "u", deviceId: "d", payload: .marker(.pending), raisedAt: raisedAt,
            message: nil, crypto: crypto, post: { request in posted = request; return echo })
        XCTAssertEqual(sent.sealedTime.ciphertext, posted?.encryptedTimestamp.ciphertext, "what it sent")
        let raisedAtMs = try XCTUnwrap(SOSManager.sealedTimeMs(sent.sealedTime, circleId: circleId, crypto: crypto))
        XCTAssertEqual(raisedAtMs, Int64(raisedAt.timeIntervalSince1970 * 1000))
        let echoed = EncryptedBlobRequest(nonce: echo.encryptedTimestamp.nonce, ciphertext: echo.encryptedTimestamp.ciphertext)
        XCTAssertNotEqual(SOSManager.sealedTimeMs(echoed, circleId: circleId, crypto: crypto), raisedAtMs,
                          "the echo carries another time")
        let record = try XCTUnwrap(SOSManager.sealedRecord(sent.sealedLocation, circleId: circleId, pressAtMs: 1,
                                                           locationOff: false, updates: 0, raisedAtMs: raisedAtMs,
                                                           crypto: crypto))
        XCTAssertEqual(record.raisedAtMs, raisedAtMs)
        XCTAssertNil(SOSManager.sealedTimeMs(sent.sealedLocation, circleId: circleId, crypto: crypto),
                     "only a timestamp blob opens as one")
    }

    /// The values go into the file as their bits: they come back exactly, so
    /// the record still equals a copy the server serves.
    func testTheFileGivesBackTheRecordExactly() throws {
        let directory = try scratch()
        let (crypto, circleId) = try circleCrypto()
        for accuracy in [12.3456789, 0.1, 65, 1_609.344 * 25, 4.000000476837158] {
            let location = Location(latitude: -33.86785, longitude: -122.00900006, altitude: nil, speed: nil,
                                    heading: nil, accuracy: accuracy, timestamp: 1, batteryLevel: nil, isCharging: nil)
            let request = try SOSManager.createRequest(circleId: circleId, userId: "u", deviceId: "d",
                                                       payload: .position(location), raisedAt: press, message: nil,
                                                       crypto: crypto)
            let record = try XCTUnwrap(SOSManager.sealedRecord(request.encryptedLocation, circleId: circleId,
                                                               pressAtMs: 1, locationOff: false, updates: 0,
                                                               crypto: crypto))
            SOSSealedPositions(directory: directory).note(record, alertId: alertId, owner: me)
            let read = SOSSealedPositions(directory: directory).record(alertId: alertId, owner: me)
            XCTAssertEqual(read, record)
            XCTAssertEqual(read?.position?.accuracy, Double(Float(accuracy)))
            XCTAssertEqual(read?.position?.longitude, -122.0090001)
        }
    }

    func testTheRecordIsDurablePerAccountAndForgotten() throws {
        let directory = try scratch()
        let store = SOSSealedPositions(directory: directory)
        let record = SOSSealedPositions.Record(circleId: "c", pressAtMs: 1_727_700_000_000, position: nil,
                                              marker: .pending)
        XCTAssertNil(store.record(alertId: alertId, owner: me))
        store.note(record, alertId: alertId, owner: me)
        XCTAssertEqual(store.record(alertId: alertId.uppercased(), owner: me.uppercased()), record)
        XCTAssertEqual(SOSSealedPositions(directory: directory).record(alertId: alertId, owner: me), record,
                       "it survives a restart")
        XCTAssertNil(SOSSealedPositions(directory: directory).record(alertId: alertId, owner: someoneElse),
                     "never another account's")
        store.forget(alertId: alertId, owner: me)
        XCTAssertNil(SOSSealedPositions(directory: directory).record(alertId: alertId, owner: me))
        store.note(record, alertId: alertId, owner: me)
        store.clearAll()
        XCTAssertNil(SOSSealedPositions(directory: directory).record(alertId: alertId, owner: me))
    }

    // MARK: - The raiser's card

    func testTheRaisersCardSaysWhatWentOut() {
        func line(_ payload: SOSManager.RaisePayload, updates: Int = 0) -> String? {
            let record: SOSSealedPositions.Record
            switch payload {
            case .position(let location):
                record = .init(circleId: "c", pressAtMs: 1, position: .init(location), marker: nil, updates: updates)
            case .marker(let marker):
                record = .init(circleId: "c", pressAtMs: 1, position: nil, marker: marker, updates: updates)
            }
            return SOSManager.raiserLine(record, raisedAt: press, now: press)
        }
        XCTAssertEqual(line(.marker(.pending)), "Sending your current location")
        XCTAssertEqual(line(.marker(.unavail)), "Sent without your location")
        let old = SOSManager.sealable(fix(600))
        XCTAssertEqual(line(.position(old)),
                       "Sent with your location from \(press.addingTimeInterval(-600).formatted(date: .omitted, time: .shortened))")
        XCTAssertNil(line(.position(SOSManager.sealable(fix(30)))), "taken within a minute of the press")
        let added = SOSManager.sealable(fix(-120))
        XCTAssertEqual(line(.position(added), updates: 1),
                       "Your location was added at \(press.addingTimeInterval(120).formatted(date: .omitted, time: .shortened))")
        XCTAssertNil(SOSManager.raiserLine(nil, raisedAt: press))
    }

    // MARK: - Wiring (source)

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// The precise fix starts at the press and the raise never waits for it;
    /// the dialog reads the circle's privacy again; the record is kept,
    /// forgotten when the alert ends, and cleared at sign-out.
    func testTheRaiseNeverWaitsForTheFix() throws {
        let manager = try source("App/Managers/SOSManager.swift")
        let from = try XCTUnwrap(manager.range(of: "    func triggerSOS(for circleId: String, message: String? = nil)"))
        let to = try XCTUnwrap(manager.range(of: "    func cancelSOS(", range: from.upperBound..<manager.endIndex))
        let raise = String(manager[from.upperBound..<to.lowerBound])
        XCTAssertFalse(raise.contains("requestSingleLocation"), "no location wait, and no location throw")
        let started = try XCTUnwrap(raise.range(of: "let preciseFix = Task { @MainActor [locationService] in\n"
            + "            await locationService.requestFreshFix(timeout: Self.preciseFixTimeout, after: pressAt)\n"))
        let chosen = try XCTUnwrap(raise.range(of: "let payload = Self.raisePayload("))
        let sent = try XCTUnwrap(raise.range(of: "let (alert, sealedLocation, sealedTime) = try await triggerSOSOverWire("))
        XCTAssertLessThan(started.upperBound, chosen.lowerBound)
        XCTAssertLessThan(chosen.upperBound, sent.lowerBound)
        XCTAssertEqual(raise.components(separatedBy: "preciseFix.value").count - 1, 1)
        XCTAssertTrue(raise.contains("        Task { @MainActor [weak self, locationService] in\n"
                                     + "            guard let fix = await preciseFix.value else { return }\n"
                                     + "            locationService.adoptSentFix(fix)\n"
                                     + "            self?.offer(fix, alertId: alert.id, pressAt: pressAt)\n"),
                      "awaited only off the raise; the alert's first F when it lands")
        XCTAssertTrue(raise.contains("        startUpdateWatch(alertId: alert.id, circleId: circleId, pressAt: pressAt, "
                                     + "raisedAt: alert.createdAt)\n"))
        XCTAssertTrue(raise.contains("held: [locationService.currentLocation, locationService.osCachedLocation].compactMap { $0 },"))
        XCTAssertTrue(raise.contains("let sealed = Self.sealedRecord(sealedLocation, circleId: circleId, pressAtMs: Self.ms(pressAt),"),
                      "the record is what this device sealed, opened back (REV 2.1)")
        XCTAssertTrue(raise.contains("raisedAtMs: Self.sealedTimeMs(sealedTime, circleId: circleId, crypto: cryptoManager),"),
                      "and the raise time it sealed, opened back")
        XCTAssertTrue(raise.contains("if let sealed { SOSSealedPositions.shared.note(sealed, alertId: alert.id, owner: owner) }"))
        XCTAssertTrue(manager.contains("        SOSSealedPositions.shared.forget(alertId: alertId, owner: AuthManager.shared.userId)\n"))
        XCTAssertTrue(try source("App/Managers/AuthManager.swift").contains("        SOSSealedPositions.shared.clearAll()\n"))
        let view = try source("App/Views/Safety/SOSView.swift")
        XCTAssertTrue(view.contains("Task { try? await circleManager.loadPrivacySettings(for: circleId) }"))
        // The raiser's card says what went out, and "unavail" for a definite
        // cause adds the app's location-off guidance and its settings link.
        XCTAssertTrue(view.contains("if let line = SOSManager.raiserLine(sosManager.myPosition, raisedAt: alert.createdAt) {"))
        XCTAssertTrue(view.contains("if sosManager.myPosition?.locationOff == true, sosManager.myPosition?.marker == .unavail {"))
        XCTAssertTrue(view.contains("Text(LocationService.shared.authorizationStatus == .restricted\n"
                                    + "                         ? LocationOffCopy.restricted : LocationOffCopy.denied)"))
        let map = try source("App/Views/Map/MapView.swift")
        XCTAssertTrue(map.contains("                    LocationOffCopy.denied,\n"), "the app's own words, one copy")
        XCTAssertTrue(map.contains("                    LocationOffCopy.restricted,\n"))
        XCTAssertEqual(LocationOffCopy.denied, "Track can't share your location until you allow it in Settings.")
        XCTAssertEqual(LocationOffCopy.restricted,
                       "Parental controls or device management is blocking location access.")
    }
}
