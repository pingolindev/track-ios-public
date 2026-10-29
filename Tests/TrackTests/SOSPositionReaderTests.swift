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

/// SOS positions, the receivers: a sealed position carries its own
/// capture time and accuracy, or one of two 22-byte markers in its place, and
/// responders read it as "Sending current location", "Location unavailable",
/// "Last known location · {time}", "Location updated · {time}", or with the
/// plain labels when it was taken at the raise.
/// Rough positions are areas; updates re-resolve and move in place.
///
/// Real keys, as SOSResealTests: the owner makes v1 for itself, this device and
/// one it later leaves out; v2 goes to the owner alone; v3 to the owner and this
/// device, which seals under v3.
@MainActor
final class SOSPositionReaderTests: XCTestCase {
    private let circleId = "c5070000-0000-4000-8000-0000000000aa"
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
            sharing = SOSPositionReaderTests.hex(sdk.generateKeypair().publicKey)
            signing = SOSPositionReaderTests.hex(sdk.generateSigningKeypair().verifyingKeyB64)
        }
    }

    /// The world, and v3's bundle for this device, held back when `holdV3`
    /// (a receiver behind on keys) so a test can hand it over later.
    private func world(holdV3: Bool = false) throws -> (owner: Party, me: Party, leftOut: Party, giveV3: () throws -> Void) {
        let owner = Party("c5070000-0000-4000-8000-00000000000a")
        let me = Party("c5070000-0000-4000-8000-00000000000b")
        let leftOut = Party("c5070000-0000-4000-8000-00000000000c")
        let circleId = self.circleId
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
        let bundle = try XCTUnwrap(v3.memberKeys.first { $0.userId == me.userId }).bundle
        let giveV3 = { try give(me, bundle, 3) }
        if !holdV3 { try giveV3() }
        return (owner, me, leftOut, giveV3)
    }

    private func blob(_ e: EncryptedData) -> [String: Any] { ["nonce": e.nonce, "ciphertext": e.ciphertext] }

    private enum Sealed {
        case point(Location)
        case text(String)
    }

    /// One listed SOS: the raiser and time sealed by `sealer`, the position (or
    /// whatever stands in its place) by `positionSealer`, default the same.
    private func sos(by sealer: CryptoManager, raiser: String, position: Sealed,
                     positionSealer: CryptoManager? = nil) throws -> SOSResponse {
        let place: EncryptedData
        switch position {
        case .point(let point): place = try (positionSealer ?? sealer).encryptLocation(circleId: circleId, location: point)
        case .text(let text):
            place = try (positionSealer ?? sealer).encryptDataV2(circleId: circleId, plaintext: text, fieldTag: "location")
        }
        let row: [String: Any] = [
            "id": "c5070000-0000-4000-8000-0000000000f1", "circle_id": circleId, "status": "active", "day_bucket": 20_000,
            "encrypted_user_id": blob(try sealer.encryptDataV2(circleId: circleId, plaintext: raiser, fieldTag: "user_id")),
            "encrypted_device_id": blob(try sealer.encryptDataV2(circleId: circleId, plaintext: "device-1", fieldTag: "device_id")),
            "encrypted_timestamp": blob(try sealer.encryptDataV2(circleId: circleId, plaintext: String(raisedAt),
                                                                 fieldTag: "timestamp")),
            "encrypted_location": blob(place),
        ]
        return try APIService.makeWireDecoder().decode(SOSResponse.self, from: JSONSerialization.data(withJSONObject: row))
    }

    private func point(takenAt: Int64, accuracy: Double? = 12) -> Location {
        Location(latitude: 37.3349, longitude: -122.009, altitude: nil, speed: nil, heading: nil, accuracy: accuracy,
                 timestamp: takenAt, batteryLevel: nil, isCharging: nil)
    }

    // MARK: - The markers

    func testTheMarkersAreTheseTwentyTwoBytesAndNothingElse() {
        XCTAssertEqual(SOSPositionMarker.pending.rawValue, #"{"position":"pending"}"#)
        XCTAssertEqual(SOSPositionMarker.unavail.rawValue, #"{"position":"unavail"}"#)
        for marker in SOSPositionMarker.allCases {
            XCTAssertEqual(marker.rawValue.utf8.count, 22, "\(marker)")
            XCTAssertEqual(marker.rawValue.utf8.first, UInt8(ascii: "{"), "never the packed magic 0xB1")
            XCTAssertEqual(SOSPositionMarker.matching(marker.rawValue), marker)
        }
        for other in [#"{"position":"pending"} "#, #" {"position":"pending"}"#, #"{"position": "pending"}"#,
                      #"{"position":"Pending"}"#, #"{"unavailable":true}  "#, "", "pending"] {
            XCTAssertNil(SOSPositionMarker.matching(other), other)
        }
    }

    /// A marker opens as that marker, counts as an opened part, and its version
    /// joins `current`; the SDK's location reader refuses it.
    func testAMarkerOpensAndItsVersionCounts() throws {
        let (_, me, leftOut, _) = try world()
        let mine = try sos(by: me.sdk, raiser: me.userId, position: .text(SOSPositionMarker.pending.rawValue))
        let opened = SOSReceiverRules.open(mine, myUserId: me.userId, myDeviceId: "device-1", crypto: me.sdk)
        XCTAssertEqual(opened.marker, .pending)
        XCTAssertNil(opened.location)
        XCTAssertTrue(opened.current)
        XCTAssertFalse(opened.nothingOpened)
        XCTAssertThrowsError(try me.sdk.decryptLocationOpened(
            circleId: circleId, encryptedLocation: EncryptedData(nonce: mine.encryptedLocation.nonce,
                                                                 ciphertext: mine.encryptedLocation.ciphertext)))
        let unavail = try sos(by: me.sdk, raiser: me.userId, position: .text(SOSPositionMarker.unavail.rawValue))
        XCTAssertEqual(SOSReceiverRules.open(unavail, myUserId: nil, myDeviceId: nil, crypto: me.sdk).marker, .unavail)

        // Under a version held here but not current: not current, as a position's would be.
        let old = try sos(by: me.sdk, raiser: me.userId, position: .text(SOSPositionMarker.pending.rawValue),
                          positionSealer: leftOut.sdk)
        let behind = SOSReceiverRules.open(old, myUserId: nil, myDeviceId: nil, crypto: me.sdk)
        XCTAssertEqual(behind.marker, .pending)
        XCTAssertFalse(behind.current)

        // Only the marker opened here (the raiser and time are under a version
        // not held yet): an opened part, so it is not "nothing opened".
        let (owner2, me2, leftOut2, _) = try world(holdV3: true)
        let partly = SOSReceiverRules.open(
            try sos(by: owner2.sdk, raiser: me2.userId, position: .text(SOSPositionMarker.unavail.rawValue),
                    positionSealer: leftOut2.sdk),
            myUserId: nil, myDeviceId: nil, crypto: me2.sdk)
        XCTAssertNil(partly.raiserId)
        XCTAssertEqual(partly.marker, .unavail)
        XCTAssertFalse(partly.nothingOpened)
    }

    /// Any other text where the position would be is garbage: no
    /// position, no marker, and its version decides nothing.
    func testAnyOtherTextReadsAsGarbage() throws {
        let (_, me, leftOut, _) = try world()
        for text in [#"{"position":"pending"} "#, #"{"unavailable":true}  "#, "hello"] {
            let row = try sos(by: me.sdk, raiser: me.userId, position: .text(text), positionSealer: leftOut.sdk)
            let opened = SOSReceiverRules.open(row, myUserId: nil, myDeviceId: nil, crypto: me.sdk)
            XCTAssertNil(opened.marker, text)
            XCTAssertNil(opened.location, text)
            XCTAssertTrue(opened.current, "\(text): only the raiser and time decide")
            let alert = SOSManager.openAlert(row, myUserId: nil, myDeviceId: nil, crypto: me.sdk).alert
            XCTAssertEqual(alert.positionReading(), .unknown)
        }
    }

    /// The alert carries what opened: the position's time and accuracy, or the
    /// marker, and the sealed raise time as `createdAt`.
    func testTheAlertCarriesThePositionsTimeAndAccuracy() throws {
        let (_, me, _, _) = try world()
        let held = try sos(by: me.sdk, raiser: me.userId, position: .point(point(takenAt: raisedAt - 600_000, accuracy: 25)))
        let alert = SOSManager.openAlert(held, myUserId: nil, myDeviceId: nil, crypto: me.sdk).alert
        XCTAssertEqual(alert.positionTakenAt, Date(timeIntervalSince1970: TimeInterval(raisedAt - 600_000) / 1000))
        XCTAssertEqual(alert.positionAccuracy, 25)
        XCTAssertNil(alert.positionMarker)
        XCTAssertEqual(alert.createdAt, Date(timeIntervalSince1970: TimeInterval(raisedAt) / 1000))
        XCTAssertEqual(alert.positionReading(), .lastKnown(try XCTUnwrap(alert.positionTakenAt)))

        let pending = try sos(by: me.sdk, raiser: me.userId, position: .text(SOSPositionMarker.pending.rawValue))
        let waiting = SOSManager.openAlert(pending, myUserId: nil, myDeviceId: nil, crypto: me.sdk).alert
        XCTAssertNil(waiting.coordinate)
        XCTAssertEqual(waiting.positionMarker, .pending)
        XCTAssertFalse(waiting.isMappable, "no pin, no address, no directions")
    }

    // MARK: - What it reads as

    func testTheReadings() {
        let asked = raisedAt
        func read(_ taken: Int64?, _ marker: SOSPositionMarker? = nil, now: Int64? = nil) -> SOSReceiverRules.PositionReading {
            SOSReceiverRules.reading(takenAtMs: taken, marker: marker, askedMs: asked, nowMs: now ?? asked + 30_000)
        }
        func at(_ ms: Int64) -> Date { Date(timeIntervalSince1970: TimeInterval(ms) / 1000) }
        // A pending marker, and its fallback from the SEALED raise
        // time + 12 minutes.
        XCTAssertEqual(read(nil, .pending), .sending)
        XCTAssertEqual(read(nil, .pending, now: asked + 12 * 60_000 - 1), .sending)
        XCTAssertEqual(read(nil, .pending, now: asked + 12 * 60_000), .unavailable, "the raiser's phone died or is offline")
        // An unavailable marker.
        XCTAssertEqual(read(nil, .unavail), .unavailable)
        // A position within a minute either side of the raise reads
        // as at the raise; beyond it, as last known or updated.
        XCTAssertEqual(read(asked), .atRaise, "a raiser before the contract sealed the raise time")
        XCTAssertEqual(read(asked - 60_000), .atRaise)
        XCTAssertEqual(read(asked + 60_000), .atRaise)
        XCTAssertEqual(read(asked - 60_001), .lastKnown(at(asked - 60_001)))
        XCTAssertEqual(read(asked + 60_001), .updated(at(asked + 60_001)))
        // Nothing opened, or no raise time: unknown, except that a
        // pending marker still reads as sending.
        XCTAssertEqual(read(nil), .unknown)
        XCTAssertEqual(SOSReceiverRules.reading(takenAtMs: asked, marker: nil, askedMs: nil, nowMs: asked), .unknown)
        XCTAssertEqual(SOSReceiverRules.reading(takenAtMs: nil, marker: .pending, askedMs: nil, nowMs: asked), .sending)
    }

    /// Over 100 m, an area of that radius, shown as an approximate
    /// member's position is: no street address, coordinates or
    /// directions to its centre.
    func testRoughPositionsAreAreas() {
        XCTAssertNil(SOSReceiverRules.areaMeters(accuracy: nil))
        XCTAssertNil(SOSReceiverRules.areaMeters(accuracy: 100))
        XCTAssertEqual(SOSReceiverRules.areaMeters(accuracy: 100.5), 100.5)
        XCTAssertNil(SOSReceiverRules.areaMeters(accuracy: .nan))
        XCTAssertNil(SOSReceiverRules.areaMeters(accuracy: .infinity))
        func alert(accuracy: Double?) -> SOSAlert {
            SOSAlert(id: "a", circleId: "c", userId: "u", status: .active, latitude: 1, longitude: 2, acknowledgedBy: [],
                     createdAt: Date(), positionAccuracy: accuracy)
        }
        XCTAssertFalse(alert(accuracy: 100).hasApproximatePosition)
        XCTAssertTrue(alert(accuracy: 100.5).hasApproximatePosition)
        XCTAssertTrue(alert(accuracy: 1_609.344).hasApproximatePosition)
        XCTAssertFalse(alert(accuracy: nil).hasApproximatePosition)
        XCTAssertNotEqual(alert(accuracy: nil).positionKey,
                          SOSAlert(id: "a", circleId: "c", userId: "u", status: .active, latitude: 1, longitude: 3,
                                   acknowledgedBy: [], createdAt: Date()).positionKey,
                          "an update's new position is a new key: the address resolves again")
        XCTAssertNotEqual(alert(accuracy: 30).positionKey, alert(accuracy: 2_000).positionKey,
                          "from a point to an area on the same centre: the address goes")
        XCTAssertEqual(alert(accuracy: 30).positionKey, alert(accuracy: 60).positionKey)
    }

    /// The lines responders read.
    func testTheWords() {
        let now = Date(timeIntervalSince1970: TimeInterval(raisedAt) / 1000)
        XCTAssertEqual(SOSPositionText.line(.sending, now: now), "Sending current location")
        XCTAssertEqual(SOSPositionText.line(.unavailable, now: now), "Location unavailable")
        XCTAssertNil(SOSPositionText.line(.atRaise, now: now))
        XCTAssertNil(SOSPositionText.line(.unknown, now: now))
        XCTAssertEqual(SOSPositionText.line(.lastKnown(now.addingTimeInterval(-600)), now: now),
                       "Last known location · \(now.addingTimeInterval(-600).formatted(date: .omitted, time: .shortened))")
        XCTAssertEqual(SOSPositionText.line(.updated(now.addingTimeInterval(120)), now: now),
                       "Location updated · \(now.addingTimeInterval(120).formatted(date: .omitted, time: .shortened))")
        let yesterday = now.addingTimeInterval(-86_400)
        XCTAssertEqual(SOSPositionText.line(.lastKnown(yesterday), now: now),
                       "Last known location · \(yesterday.formatted(date: .abbreviated, time: .shortened))",
                       "the date when it isn't today")
        XCTAssertEqual(SOSPositionText.mapLabel(.lastKnown(now)), "Last known location")
        XCTAssertEqual(SOSPositionText.mapLabel(.updated(now)), "Location updated")
        XCTAssertEqual(SOSPositionText.mapLabel(.atRaise), "Sent from here")
        // An area names no spot: its size, never "here".
        XCTAssertEqual(SOSPositionText.mapLabel(.atRaise, areaMeters: 2_000), SOSPositionText.within(2_000))
        XCTAssertEqual(SOSPositionText.mapLabel(.unknown, areaMeters: 2_000), SOSPositionText.within(2_000))
        XCTAssertEqual(SOSPositionText.mapLabel(.lastKnown(now), areaMeters: 2_000), "Last known location")
        XCTAssertEqual(SOSPositionText.mapLabel(.updated(now), areaMeters: 2_000), "Location updated")
        XCTAssertTrue(SOSPositionText.within(250).hasPrefix("Within about "))
        XCTAssertEqual(SOSPositionText.noPosition, "No location available for this alert")
    }

    // MARK: - A receiver behind on keys

    /// An update re-sealed under a version this receiver doesn't hold yet
    /// opens nothing; the quiet reload asks for ONE key fetch, opens it again,
    /// and shows the new position. No sound: the reload is quiet.
    func testAReceiverBehindOnKeysGetsTheUpdateAfterOneBoundedKeyFetch() async throws {
        let (owner, me, _, giveV3) = try world(holdV3: true)
        let moved = point(takenAt: raisedAt + 90_000, accuracy: 8)
        let update = try sos(by: owner.sdk, raiser: owner.userId, position: .point(moved))
        var fetches = 0
        var tried: [String: Date] = [:]
        let open = { (row: SOSResponse) in SOSManager.openAlert(row, myUserId: me.userId, myDeviceId: nil, crypto: me.sdk) }
        XCTAssertTrue(open(update).opened.nothingOpened, "sealed under v3, which isn't here yet")
        let result = await SOSManager.openListed([update], open: open, refreshKeys: {
            fetches += 1
            try? giveV3()
        }, tried: &tried, now: Date())
        XCTAssertEqual(fetches, 1)
        let alert = try XCTUnwrap(result.first).alert
        XCTAssertEqual(alert.latitude, 37.3349)
        XCTAssertEqual(alert.positionReading(), .updated(Date(timeIntervalSince1970: TimeInterval(raisedAt + 90_000) / 1000)))
        XCTAssertTrue(try XCTUnwrap(result.first).current)
        // Bounded: not asked again within the minute.
        _ = await SOSManager.openListed([update], open: { _ in SOSManager.openAlert(update, myUserId: nil, myDeviceId: nil,
                                                                                     crypto: CryptoManager()) },
                                        refreshKeys: { fetches += 1 }, tried: &tried, now: Date())
        XCTAssertEqual(fetches, 1)
        // The reload the push makes is quiet: no sound of its own.
        let push = try source("App/Managers/PushNotificationManager.swift")
        XCTAssertTrue(push.contains("try? await SOSManager.shared.loadActiveAlerts(quiet: true)"))
        XCTAssertTrue(try source("App/Managers/SOSManager.swift").contains("if needsAttention && !quiet {"))
    }

    // MARK: - Wiring (source)

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// Addresses follow the position, the detail sheet follows the
    /// store, and no view says "It does not update."
    func testTheViewsFollowTheUpdateAndNoneSaysItNeverMoves() throws {
        let overlays = try source("App/Views/Map/SOSMapOverlays.swift")
        XCTAssertFalse(overlays.contains("It does not update"))
        XCTAssertTrue(overlays.contains("sosManager.activeAlerts.first { $0.id == alert.id } ?? alert"))
        XCTAssertTrue(overlays.contains(".task(id: live.positionKey) {"))
        let safety = try source("App/Views/Safety/SOSView.swift")
        XCTAssertTrue(safety.contains(".task(id: alert.positionKey) {"))
        XCTAssertFalse(safety.contains(".task(id: alert.id) {"), "never keyed by the id alone")
        XCTAssertTrue(safety.contains("Text(SOSPositionText.line(alert.positionReading()) ?? SOSPositionText.noPosition)"))
        XCTAssertTrue(safety.contains(".onChange(of: alert.positionKey) { frame(coordinate) }"))
        let map = try source("App/Views/Map/MapLibreMapView.swift")
        XCTAssertFalse(map.contains("never updates"))
        XCTAssertTrue(map.contains("let caption = MapLibreMapView.sosCaption(alert, now: now)"))
        XCTAssertTrue(map.contains("let title = MapLibreMapView.sosTitle(alert, now: now)"))
        XCTAssertTrue(map.contains("syncSOSAreas(sosAlerts)"))
    }

    /// An alert shown as an area has no street address, coordinates or
    /// directions anywhere, and is drawn with the area's outline and the
    /// alert's label, never a pin; on the map its disc reads out its size.
    func testAnAreaHasNoAddressCoordinatesOrDirections() throws {
        let overlays = try source("App/Views/Map/SOSMapOverlays.swift")
        let safety = try source("App/Views/Safety/SOSView.swift")
        XCTAssertTrue(safety.contains("            if let address, !alert.hasApproximatePosition {\n"))
        XCTAssertTrue(overlays.contains("                if let address, !live.hasApproximatePosition {\n"))
        XCTAssertTrue(safety.contains("                        MapPolygon(coordinates: ApproximateArea.outline(center: coordinate, radiusMeters: area))\n"))
        XCTAssertFalse(safety.contains("MapCircle("))
        let mini = try XCTUnwrap(safety.range(of: "                    if let area = alert.positionAreaMeters {\n"))
        let pin = try XCTUnwrap(safety.range(of: "                    } else {\n                        Annotation(SOSPositionText.mapLabel(",
                                             range: mini.upperBound..<safety.endIndex))
        XCTAssertFalse(safety[mini.upperBound..<pin.lowerBound].contains("Image("), "no pin at an area's centre")
        XCTAssertTrue(safety.contains("                if !alert.hasApproximatePosition {\n"
                                      + "                    Button(action: openDirections) {\n"))
        XCTAssertTrue(safety.contains("        guard let coordinate = alert.coordinate, !alert.hasApproximatePosition else { return }\n"
                                      + "        let mapItem = MKMapItem("))
        XCTAssertTrue(safety.contains("            guard let coordinate = alert.coordinate, !alert.hasApproximatePosition else { return }\n"
                                      + "            // placardAddress"))
        XCTAssertTrue(overlays.contains("            guard let coordinate = live.coordinate, !live.hasApproximatePosition else {\n"
                                        + "                addressResolved = true\n"))
        XCTAssertTrue(overlays.contains("                if let coordinate = live.coordinate, !live.hasApproximatePosition {\n"
                                        + "                    Text(String(format: \"%.5f, %.5f\""))
        XCTAssertTrue(safety.contains("Text(SOSPositionText.areaLabel(alert.positionReading(), areaMeters: area))"),
                      "its label at its centre, never \"Sent from here\"")
        // Shown on the map, an area is framed whole, never entered at street
        // zoom at its centre.
        let mapView = try source("App/Views/Map/MapView.swift")
        XCTAssertEqual(mapView.components(separatedBy: "show(alert, at: coord").count - 1, 3,
                       "the Safety row's \"Show on map\", the edge arrow and a needs-attention tap")
        XCTAssertTrue(mapView.contains("        if let area = MapLibreMapView.sosFraming(alert) {\n            flyToFit = area\n"))
        let map = try source("App/Views/Map/MapLibreMapView.swift")
        XCTAssertTrue(map.contains("        if let points = flyToFit {\n            context.coordinator.fit(points)\n"))
    }

    /// The map disc's caption gives the POSITION's age with its label, never
    /// the alert's: a fix taken two hours before a raise made three minutes
    /// ago is two hours old. An area says its size, not "here".
    func testTheMapDiscTellsThePositionsAgeAndAnAreasSize() {
        let raised = Date(timeIntervalSince1970: TimeInterval(raisedAt) / 1000)
        let now = raised.addingTimeInterval(180)
        func alert(takenAt: Date?, accuracy: Double? = 12, marker: SOSPositionMarker? = nil) -> SOSAlert {
            SOSAlert(id: "a", circleId: "c", userId: "u", status: .active, latitude: marker == nil ? 37.3349 : nil,
                     longitude: marker == nil ? -122.009 : nil, acknowledgedBy: [], createdAt: raised,
                     positionTakenAt: takenAt, positionAccuracy: accuracy, positionMarker: marker)
        }
        let lastKnown = alert(takenAt: raised.addingTimeInterval(-7_200))
        XCTAssertEqual(MapLibreMapView.sosCaption(lastKnown, now: now), "Last known location · 2h")
        XCTAssertEqual(MapLibreMapView.sosTitle(lastKnown, now: now), "Last known location")
        let updated = alert(takenAt: raised.addingTimeInterval(120))
        XCTAssertEqual(MapLibreMapView.sosCaption(updated, now: now), "Location updated · 1m")
        let atRaise = alert(takenAt: raised.addingTimeInterval(-10))
        XCTAssertEqual(MapLibreMapView.sosCaption(atRaise, now: now), "Sent from here · 3m")
        XCTAssertEqual(MapLibreMapView.sosCaption(alert(takenAt: nil), now: now), "Sent from here · 3m",
                       "a raiser before the contract: the raise time")
        // An area: its size in place of "here", read out once.
        let area = alert(takenAt: raised.addingTimeInterval(-10), accuracy: 3_000)
        XCTAssertEqual(MapLibreMapView.sosCaption(area, now: now), "\(SOSPositionText.within(3_000)) · 3m")
        XCTAssertEqual(MapLibreMapView.sosTitle(area, now: now), SOSPositionText.within(3_000))
        let oldArea = alert(takenAt: raised.addingTimeInterval(-7_200), accuracy: 3_000)
        XCTAssertEqual(MapLibreMapView.sosCaption(oldArea, now: now), "Last known location · 2h")
        XCTAssertEqual(MapLibreMapView.sosTitle(oldArea, now: now),
                       "Last known location, \(SOSPositionText.within(3_000))")
    }

    /// As the Android app and the web draw it: an area alert is its label at
    /// the area's centre ("Last known location" or "Location updated · {time}"
    /// when it says so, then "Within about {distance}"), with no disc and no
    /// pulse, and it is never merged into an avatar; a point keeps its disc.
    func testAnAreaIsItsLabelWithNoDiscOrPulse() throws {
        let raised = Date(timeIntervalSince1970: TimeInterval(raisedAt) / 1000)
        let now = raised.addingTimeInterval(180)
        func alert(takenAt: Date, accuracy: Double) -> SOSAlert {
            SOSAlert(id: "a", circleId: "c", userId: "u", status: .active, latitude: 37.3349, longitude: -122.009,
                     acknowledgedBy: [], createdAt: raised, positionTakenAt: takenAt, positionAccuracy: accuracy)
        }
        XCTAssertNil(MapLibreMapView.sosAreaLabel(alert(takenAt: raised, accuracy: 30), now: now), "a point keeps its disc")
        XCTAssertEqual(MapLibreMapView.sosAreaLabel(alert(takenAt: raised.addingTimeInterval(-7_200), accuracy: 1_609.344),
                                                    now: now),
                       "Last known location\n\(SOSPositionText.within(1_609.344))")
        let updated = raised.addingTimeInterval(120)
        XCTAssertEqual(MapLibreMapView.sosAreaLabel(alert(takenAt: updated, accuracy: 300), now: now),
                       "Location updated · \(SOSPositionText.time(updated, now: now))\n\(SOSPositionText.within(300))")
        XCTAssertEqual(MapLibreMapView.sosAreaLabel(alert(takenAt: raised.addingTimeInterval(-10), accuracy: 300), now: now),
                       SOSPositionText.within(300), "taken at the raise: its size alone")

        // The map: the label, never the disc, for an area; the label's view has
        // no disc and no pulse; an area is never merged into the raiser's avatar.
        let map = try source("App/Views/Map/MapLibreMapView.swift")
        let factory = try XCTUnwrap(map.range(of: "            if let sos = annotation as? SOSAnnotation {\n"))
        let disc = try XCTUnwrap(map.range(of: "                let id = \"sos\"\n", range: factory.upperBound..<map.endIndex))
        let area = String(map[factory.upperBound..<disc.lowerBound])
        XCTAssertTrue(area.contains("                if let text = sos.areaLabel {\n"))
        XCTAssertTrue(area.contains("as? SOSAreaLabelView)"))
        XCTAssertFalse(area.contains("SOSMarkerView"))
        XCTAssertTrue(map.contains("                    annot.areaLabel = areaLabel\n"))
        XCTAssertTrue(map.contains("                if let existing = sosAnnotations[alert.id], existing.areaLabel != areaLabel {\n"),
                      "an update between a point and an area redraws it")
        XCTAssertTrue(map.contains("                guard alert.positionAreaMeters == nil, let alertCoord = alert.coordinate,\n"),
                      "an area is never merged into an avatar")
        let views = try source("App/Views/Map/MapAnnotationViews.swift")
        let labelStart = try XCTUnwrap(views.range(of: "final class SOSAreaLabelView: MLNAnnotationView {"))
        let labelEnd = try XCTUnwrap(views.range(of: "final class SOSMarkerView: MLNAnnotationView {",
                                                 range: labelStart.upperBound..<views.endIndex))
        let labelView = String(views[labelStart.upperBound..<labelEnd.lowerBound])
        for disc in ["halo", "ulse", "ovalIn", "arcCenter", "glyph"] {
            XCTAssertFalse(labelView.contains(disc), "no disc and no pulse: \(disc)")
        }
    }

    /// An area is framed whole, its centre and its four edges; a point is
    /// not framed (the fly-to centres it).
    func testAnAreaIsFramedWhole() throws {
        let raised = Date(timeIntervalSince1970: TimeInterval(raisedAt) / 1000)
        func alert(accuracy: Double?) -> SOSAlert {
            SOSAlert(id: "a", circleId: "c", userId: "u", status: .active, latitude: 37.3349, longitude: -122.009,
                     acknowledgedBy: [], createdAt: raised, positionAccuracy: accuracy)
        }
        XCTAssertNil(MapLibreMapView.sosFraming(alert(accuracy: 30)))
        XCTAssertNil(MapLibreMapView.sosFraming(alert(accuracy: nil)))
        let framed = try XCTUnwrap(MapLibreMapView.sosFraming(alert(accuracy: 40_000)))
        XCTAssertEqual(framed.count, 5)
        let centre = CLLocation(latitude: 37.3349, longitude: -122.009)
        for edge in framed.dropFirst() {
            XCTAssertEqual(CLLocation(latitude: edge.latitude, longitude: edge.longitude).distance(from: centre),
                           40_000, accuracy: 200)
        }
    }
}
