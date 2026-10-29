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

/// The export never writes this device's key store. The circle keys an export
/// carries are wraps with no signer, the server's word; they open in a key
/// store of the export's own, and a row only such a key opened is written with
/// `"key_unverified": true` (the field the web app writes too), for every
/// restore to leave out. The real SDK on every side: this device, a member who
/// wraps a circle's key for it, and someone holding a key of their own under a
/// circle this device already has.
final class DataExportKeysTests: XCTestCase {

    private let me = "c0000000-0000-4000-8000-000000000001"
    private let memberId = "c0000000-0000-4000-8000-000000000002"
    private let relayId = "c0000000-0000-4000-8000-0000000000ff"
    /// A circle this device holds.
    private let held = "c0000000-0000-4000-8000-0000000000a1"
    /// A circle this device holds no key for: only the file's wrap opens it.
    private let notHeld = "c0000000-0000-4000-8000-0000000000b2"
    private let personal = "00000000-0000-0000-0000-000000000000"

    private struct World {
        let live: CryptoManager
        /// This account's private key as the Keychain holds it (base64 text).
        let privateKey: String
        /// Holds `notHeld`, and wraps its key for this account.
        let member: CryptoManager
        /// Holds a key of its own under `held`'s id.
        let relay: CryptoManager
    }

    private func world() throws -> World {
        let live = CryptoManager()
        let identity = live.generateKeypair()
        _ = live.generateSigningKeypair()
        let own = try live.prepareCircleCreation()
        try live.finalizeCircleCreation(tempCircleId: own.tempCircleId, realCircleId: personal)
        let circle = try live.prepareCircleCreation()
        try live.finalizeCircleCreation(tempCircleId: circle.tempCircleId, realCircleId: held)

        let member = CryptoManager()
        _ = member.generateKeypair()
        _ = member.generateSigningKeypair()
        let theirs = try member.prepareCircleCreation()
        try member.finalizeCircleCreation(tempCircleId: theirs.tempCircleId, realCircleId: notHeld)

        let relay = CryptoManager()
        _ = relay.generateKeypair()
        _ = relay.generateSigningKeypair()
        let planted = try relay.prepareCircleCreation()
        try relay.finalizeCircleCreation(tempCircleId: planted.tempCircleId, realCircleId: held)

        return World(live: live, privateKey: identity.privateKey, member: member, relay: relay)
    }

    // MARK: - Sealing, as the server serves it

    private func hex(fromBase64 b64: String) -> String {
        Data(base64Encoded: b64)!.map { String(format: "%02x", $0) }.joined()
    }

    private func blob(_ e: EncryptedData) -> [String: Any] {
        ["nonce": e.nonce, "ciphertext": e.ciphertext]
    }

    private func sealed(_ by: CryptoManager, _ circleId: String, _ text: String, _ tag: String) throws -> [String: Any] {
        blob(try by.encryptDataV2(circleId: circleId, plaintext: text, fieldTag: tag))
    }

    private func sealedPoint(_ by: CryptoManager, _ circleId: String, _ latitude: Double) throws -> [String: Any] {
        blob(try by.encryptLocation(circleId: circleId, location: Location(
            latitude: latitude, longitude: 13.4, altitude: nil, speed: nil, heading: nil,
            accuracy: 5, timestamp: 1_727_600_000_000, batteryLevel: nil, isCharging: nil
        )))
    }

    /// A circle row, with `from`'s wrap of its key for this account when given.
    private func circleRow(
        _ id: String, name: [String: Any], wrapFrom: (CryptoManager, String, circle: String)? = nil, to w: World
    ) throws -> [String: Any] {
        var row: [String: Any] = ["circle_id": id, "encrypted_name": name, "role": "member", "key_version": 1]
        if let wrap = wrapFrom {
            let bundle = try wrap.0.wrapCircleKeyForMemberFull(
                circleId: wrap.circle,
                memberPublicKeyHex: hex(fromBase64: try w.live.exportPublicKey()),
                senderUserId: wrap.1,
                recipientUserId: me,
                recipientSigningPubkeyHex: try w.live.signingPublicKeyHex()
            )
            row["encrypted_circle_key"] = blob(bundle.encryptedCircleKey)
            row["ephemeral_public_key"] = bundle.ephemeralPublicKey
        }
        return row
    }

    private func placeRow(_ id: String, _ circleId: String?, by: CryptoManager, sealedAs: String, name: String) throws -> [String: Any] {
        [
            "id": id,
            "circle_id": circleId ?? NSNull(),
            "encrypted_name": try sealed(by, sealedAs, name, "name"),
            "encrypted_location": try sealedPoint(by, sealedAs, 52.5),
            "radius_meters": 100,
            "created_day_bucket": 20_000,
        ]
    }

    private func checkInRow(_ id: String, _ circleId: String?, by: CryptoManager, sealedAs: String) throws -> [String: Any] {
        [
            "id": id,
            "circle_id": circleId ?? NSNull(),
            "check_in_type": "general",
            "encrypted_message": try sealed(by, sealedAs, "hello from \(id)", "message"),
            "encrypted_location": try sealedPoint(by, sealedAs, 52.6),
            "created_day_bucket": 20_000,
        ]
    }

    private func locationRow(_ rowKey: String, _ circleId: String, by: CryptoManager, sealedAs: String) throws -> [String: Any] {
        [
            "device_id": "d-1",
            "circle_id": circleId,
            "day_bucket": 20_000,
            "encrypted_timestamp": try sealed(by, sealedAs, "1727600000000", "timestamp"),
            "encrypted_payload": try sealedPoint(by, sealedAs, 52.7),
            "key_id": "",
            "inserted_at_ms": 1_727_600_000_123,
            "row_key": rowKey,
        ]
    }

    private func page(
        circles: [[String: Any]], places: [[String: Any]] = [],
        checkIns: [[String: Any]] = [], locations: [[String: Any]] = []
    ) throws -> DataExportResponse {
        let json: [String: Any] = [
            "metadata": [
                "user_id": me, "exported_day_bucket": 20_000, "start_day_bucket": 19_970,
                "end_day_bucket": 20_000, "format_version": "1.8", "location_count": locations.count,
            ],
            "circles": circles, "places": places, "check_ins": checkIns, "locations": locations,
        ]
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(DataExportResponse.self, from: JSONSerialization.data(withJSONObject: json))
    }

    // MARK: - The export, run for real

    private struct Written {
        let json: [String: Any]
        let text: String

        func rows(_ section: String) -> [[String: Any]] { json[section] as? [[String: Any]] ?? [] }

        func row(_ section: String, _ key: String, _ value: String) -> [String: Any]? {
            rows(section).first { $0[key] as? String == value }
        }
    }

    /// Counts the private key's reads.
    private final class KeyReads { var count = 0 }

    private func export(
        _ w: World, _ page: DataExportResponse, privateKey: (() -> Data?)? = nil
    ) async throws -> Written {
        let key = w.privateKey
        let service = DataExportService(
            crypto: w.live,
            privateKey: privateKey ?? { () -> Data? in Data(key.utf8) },
            fetchPage: { _, _, _, _, _ in page }
        )
        let built = try await service.buildBackup(generatedAt: "2026-09-30T00:00:00Z")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: built.data) as? [String: Any])
        return Written(json: json, text: String(decoding: built.data, as: UTF8.self))
    }

    /// `true` as JSON's boolean: what web's restore compares with `=== true`.
    private func isTrue(_ value: Any?, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let number = value as? NSNumber else {
            return XCTFail("\(what): no key_unverified", file: file, line: line)
        }
        XCTAssertEqual(CFGetTypeID(number), CFBooleanGetTypeID(), "\(what): a JSON boolean", file: file, line: line)
        XCTAssertEqual(number.boolValue, true, what, file: file, line: line)
    }

    // MARK: - The live store is never written

    func testTheExportNeverWritesThisDevicesKeyStore() async throws {
        let w = try world()
        let written = try await export(w, try page(circles: [
            try circleRow(held, name: try sealed(w.live, held, "Family", "name"), to: w),
            try circleRow(notHeld, name: try sealed(w.member, notHeld, "Hiking", "name"),
                          wrapFrom: (w.member, memberId, circle: notHeld), to: w),
        ]))

        // The wrap did open (the file has the circle), but not here.
        XCTAssertEqual(written.row("circles", "circle_id", notHeld)?["name"] as? String, "Hiking")
        XCTAssertFalse(w.live.hasCircleKey(circleId: notHeld), "the export's key never reaches this device's store")
        XCTAssertEqual(try w.live.getActiveVersion(circleId: held), 1)
    }

    // MARK: - What only the file's key opened says so

    func testEveryRowOnlyTheFilesKeyOpenedSaysSoAndNoOtherDoes() async throws {
        let w = try world()
        let written = try await export(w, try page(
            circles: [
                try circleRow(held, name: try sealed(w.live, held, "Family", "name"), to: w),
                try circleRow(notHeld, name: try sealed(w.member, notHeld, "Hiking", "name"),
                              wrapFrom: (w.member, memberId, circle: notHeld), to: w),
            ],
            places: [
                try placeRow("p-held", held, by: w.live, sealedAs: held, name: "School"),
                try placeRow("p-file", notHeld, by: w.member, sealedAs: notHeld, name: "Trailhead"),
                try placeRow("p-mine", nil, by: w.live, sealedAs: personal, name: "Home"),
            ],
            checkIns: [
                try checkInRow("k-held", held, by: w.live, sealedAs: held),
                try checkInRow("k-file", notHeld, by: w.member, sealedAs: notHeld),
                try checkInRow("k-mine", nil, by: w.live, sealedAs: personal),
            ],
            locations: [
                try locationRow("r-held", held, by: w.live, sealedAs: held),
                try locationRow("r-file", notHeld, by: w.member, sealedAs: notHeld),
                try locationRow("r-mine", personal, by: w.live, sealedAs: personal),
            ]
        ))

        // Opened by the file's key alone: all four kinds say so, as a boolean.
        let circle = try XCTUnwrap(written.row("circles", "circle_id", notHeld))
        XCTAssertEqual(circle["name"] as? String, "Hiking")
        isTrue(circle["key_unverified"], "circle")
        let place = try XCTUnwrap(written.row("places", "id", "p-file"))
        XCTAssertEqual(place["name"] as? String, "Trailhead")
        isTrue(place["key_unverified"], "place")
        let checkIn = try XCTUnwrap(written.row("check_ins", "id", "k-file"))
        XCTAssertEqual(checkIn["message"] as? String, "hello from k-file")
        isTrue(checkIn["key_unverified"], "check-in")
        let location = try XCTUnwrap(written.row("locations", "row_key", "r-file"))
        XCTAssertNotNil(location["location"])
        isTrue(location["key_unverified"], "location")

        // Exactly the field the web client's restore reads on a place.
        XCTAssertEqual(written.text.components(separatedBy: "\"key_unverified\" : true").count - 1, 4)

        // Read with this device's keys, a circle's or the personal one: unmarked.
        for (section, key, value) in [
            ("circles", "circle_id", held), ("places", "id", "p-held"), ("places", "id", "p-mine"),
            ("check_ins", "id", "k-held"), ("check_ins", "id", "k-mine"),
            ("locations", "row_key", "r-held"), ("locations", "row_key", "r-mine"),
        ] {
            let row = try XCTUnwrap(written.row(section, key, value), "\(section) \(value) is exported")
            XCTAssertNil(row["key_unverified"], "\(section) \(value)")
        }
        XCTAssertEqual(written.row("places", "id", "p-mine")?["name"] as? String, "Home")
        XCTAssertEqual(written.row("check_ins", "id", "k-mine")?["message"] as? String, "hello from k-mine")
    }

    // MARK: - A circle held here reads only this device's key, in any spelling

    func testAHeldCircleReadsOnlyThisDevicesKeyWhateverTheSpelling() async throws {
        let w = try world()
        let upper = held.uppercased()
        let hex32 = held.replacingOccurrences(of: "-", with: "")
        let braced = "{\(held)}"
        let written = try await export(w, try page(
            circles: [
                // Named in capitals, carrying someone else's key for it.
                try circleRow(upper, name: try sealed(w.live, held, "Family", "name"),
                              wrapFrom: (w.relay, relayId, circle: held), to: w),
            ],
            places: [
                try placeRow("p-real", hex32, by: w.live, sealedAs: held, name: "School"),
                try placeRow("p-planted", braced, by: w.relay, sealedAs: held, name: "Planted"),
            ],
            checkIns: [
                try checkInRow("k-planted", upper, by: w.relay, sealedAs: held),
            ],
            locations: [
                try locationRow("r-planted", hex32, by: w.relay, sealedAs: held),
            ]
        ))

        let circle = try XCTUnwrap(written.row("circles", "circle_id", held), "written under its one form")
        XCTAssertEqual(circle["name"] as? String, "Family")
        XCTAssertNil(circle["key_unverified"])
        XCTAssertEqual(written.rows("circles").count, 1)

        let place = try XCTUnwrap(written.row("places", "id", "p-real"))
        XCTAssertEqual(place["name"] as? String, "School")
        XCTAssertNil(place["key_unverified"])
        XCTAssertNil(written.row("places", "id", "p-planted"), "the planted key opens nothing")
        XCTAssertNil(written.row("locations", "row_key", "r-planted"))
        // A check-in is written whatever opens; the planted text does not.
        let checkIn = try XCTUnwrap(written.row("check_ins", "id", "k-planted"))
        XCTAssertNil(checkIn["message"])
        XCTAssertNil(checkIn["location"])
        XCTAssertNil(checkIn["key_unverified"])
        XCTAssertFalse(written.text.contains("key_unverified"))

        // This device's key for it is untouched.
        XCTAssertEqual(try w.live.getActiveVersion(circleId: held), 1)
        XCTAssertEqual(try w.live.decryptDataV2(
            circleId: held,
            encryptedData: w.live.encryptDataV2(circleId: held, plaintext: "still mine", fieldTag: "name"),
            fieldTag: "name"
        ), "still mine")
    }

    // MARK: - The personal key's slot is never a circle

    func testNoCircleRowNamingThePersonalKeysSlotIsWritten() async throws {
        let w = try world()
        let spellings = [
            personal, "00000000000000000000000000000000", "{\(personal)}", "urn:uuid:\(personal)", "self",
        ]
        // Its name is readable under this device's personal key, but a row
        // naming the personal slot must not be read with that key or written
        // as a circle.
        let rows = try spellings.map {
            try circleRow($0, name: try sealed(w.live, personal, "Me", "name"),
                          wrapFrom: (w.member, memberId, circle: notHeld), to: w)
        }
        let written = try await export(w, try page(circles: rows))

        XCTAssertEqual(written.rows("circles").count, 0)
        XCTAssertFalse(w.live.hasCircleKey(circleId: notHeld))
        XCTAssertEqual(try w.live.decryptDataV2(
            circleId: personal,
            encryptedData: w.live.encryptDataV2(circleId: personal, plaintext: "mine", fieldTag: "name"),
            fieldTag: "name"
        ), "mine")
    }

    // MARK: - This account's private key

    func testWithoutThePrivateKeyTheFilesCirclesAreLeftOut() async throws {
        let w = try world()
        let reads = KeyReads()
        let written = try await export(w, try page(
            circles: [
                try circleRow(held, name: try sealed(w.live, held, "Family", "name"), to: w),
                try circleRow(notHeld, name: try sealed(w.member, notHeld, "Hiking", "name"),
                              wrapFrom: (w.member, memberId, circle: notHeld), to: w),
            ],
            places: [try placeRow("p-file", notHeld, by: w.member, sealedAs: notHeld, name: "Trailhead")]
        ), privateKey: { reads.count += 1; return nil })

        XCTAssertEqual(reads.count, 1)
        XCTAssertNil(written.row("circles", "circle_id", notHeld))
        XCTAssertNil(written.row("places", "id", "p-file"))
        XCTAssertEqual(written.row("circles", "circle_id", held)?["name"] as? String, "Family")
        XCTAssertFalse(w.live.hasCircleKey(circleId: notHeld))
    }

    func testThePrivateKeyIsReadOnlyForAWrapThisDeviceCannotReadWithoutIt() async throws {
        let w = try world()
        let reads = KeyReads()
        let key = w.privateKey
        _ = try await export(w, try page(circles: [
            // Held here: its wrap is not opened.
            try circleRow(held, name: try sealed(w.live, held, "Family", "name"),
                          wrapFrom: (w.relay, relayId, circle: held), to: w),
            // No wrap to open.
            try circleRow(notHeld, name: try sealed(w.member, notHeld, "Hiking", "name"), to: w),
            // Never a circle.
            try circleRow(personal, name: try sealed(w.live, personal, "Me", "name"),
                          wrapFrom: (w.member, memberId, circle: notHeld), to: w),
        ]), privateKey: { reads.count += 1; return Data(key.utf8) })
        XCTAssertEqual(reads.count, 0)
    }

    // MARK: - The export's key store (source)

    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    private func body(_ src: String, from start: String, to end: String) throws -> String {
        let a = try XCTUnwrap(src.range(of: start), start)
        let b = try XCTUnwrap(src.range(of: end, range: a.upperBound..<src.endIndex), end)
        return String(src[a.lowerBound..<b.lowerBound])
    }

    /// The export's key store is a local of buildBackup, never a property or
    /// a static, never given storage, never loaded.
    func testTheExportsKeyStoreIsALocalOfTheExportAndNeverGivenStorage() throws {
        let src = try source("App/Services/DataExportService.swift")
        XCTAssertEqual(src.components(separatedBy: "CryptoManager()").count - 1, 1, "one key store of the export's own")
        let build = try body(src, from: "func buildBackup(", to: "// MARK: - Paging")
        XCTAssertTrue(build.contains("        let fileKeys = CryptoManager()\n"))
        for never in ["registerSecureStorage", "loadPersistedKeys", "restoreState", "importPreviousIdentities",
                      "clearAllKeys(", "static let fileKeys", "static var fileKeys", "var fileKeys"] {
            XCTAssertFalse(src.contains(never), never)
        }
    }

    /// Nothing is stored anywhere but the export's own store.
    func testOnlyTheExportsOwnStoreIsWritten() throws {
        let src = try source("App/Services/DataExportService.swift")
        let stores = src.components(separatedBy: "storeCircleKey(").count - 1
        XCTAssertEqual(stores, 1)
        XCTAssertEqual(src.components(separatedBy: "try? file.storeCircleKey(").count - 1, 1)
    }

    /// The private key's bytes are wiped once read, and never logged.
    func testThePrivateKeyBytesAreWipedAndNeverLogged() throws {
        let src = try source("App/Services/DataExportService.swift")
        let load = try body(src, from: "private static func loadPrivateKey(", to: "\n        }\n")
        XCTAssertTrue(load.contains("guard var bytes = read() else { return false }\n            defer { bytes.resetBytes(in: 0..<bytes.count) }\n"))
        XCTAssertTrue(load.contains("file.importPrivateKey("))
        XCTAssertFalse(load.contains("print("))
        XCTAssertFalse(load.contains("Logger"))
    }
}
