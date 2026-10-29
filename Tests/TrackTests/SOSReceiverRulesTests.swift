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

/// SOS on iOS, the receivers. An SOS sealed under a key version this device
/// doesn't seal under never alarms on arrival (history: not listed, no pin,
/// no alarm). One seen here while its key was current stays sticky across a
/// later rotation, until it is seen ended, its raiser leaves this device's
/// roster, or it is older than MAX_SOS_ALARM_AGE by its sealed original time
/// (then listed quietly). The marks are per account, one-way, bound to the
/// exact payloads seen, and an unreadable store is "not seen".
private extension JSONEncoder {
    static var snakeCase: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }
}

@MainActor
final class SOSReceiverRulesTests: XCTestCase {

    private typealias M = Track.SOSManager

    func testTheAlarmAgeIsOneDay() {
        XCTAssertEqual(M.maxAlarmAgeMs, 86_400_000, "MAX_SOS_ALARM_AGE, the same on Android and the web")
    }

    // MARK: - The decision

    private let now: Int64 = 1_727_700_000_000

    private func opened(current: Bool, age: Int64 = 60_000, status: SOSAlert.SOSStatus = .active,
                        hash: String = "h1") -> M.OpenedSOS {
        M.OpenedSOS(
            alert: SOSAlert(id: "sos-1", circleId: "c", userId: "u", status: status, latitude: 1, longitude: 2,
                            acknowledgedBy: [], createdAt: Date(timeIntervalSince1970: TimeInterval(now - age) / 1000)),
            opened: SOSReceiverRules.Opened(raiserId: "u", sealedTimeMs: now - age, location: nil, current: current,
                                            payloadHash: hash, raisedHere: false))
    }

    private func showing(_ o: M.OpenedSOS, ended: Bool = false, seen: Bool = false, shown: Bool? = true)
        -> SOSReceiverRules.Verdict {
        SOSReceiverRules.verdict(live: o.alert.status.isLive, opened: o.opened, behind: false,
                                 marks: .read(ended: ended, seenCurrent: seen), raiserShown: shown, now: now)
    }

    func testTheReceiverRules() {
        let day = M.maxAlarmAgeMs
        // Current on arrival: alarming, until a day old by its sealed time.
        XCTAssertEqual(showing(opened(current: true)), .alarming)
        XCTAssertEqual(showing(opened(current: true, age: day + 1)), .quiet)
        XCTAssertEqual(showing(opened(current: true, age: day)), .alarming, "a day exactly still alarms")
        // History (not current, never seen current here): hidden at ANY age,
        // never re-listed by the age rule.
        XCTAssertEqual(showing(opened(current: false)), .hidden)
        XCTAssertEqual(showing(opened(current: false, age: day + 1)), .hidden)
        // Sticky: this payload seen current, its raiser still on the roster
        // (or the roster not loaded yet: no decision).
        XCTAssertEqual(showing(opened(current: false), seen: true, shown: true), .alarming)
        XCTAssertEqual(showing(opened(current: false), seen: true, shown: nil), .alarming)
        XCTAssertEqual(showing(opened(current: false), seen: true, shown: false), .hidden)
        XCTAssertEqual(showing(opened(current: false, age: day + 1), seen: true), .quiet)
        // Seen ended here and listed live again: never alarms, whatever else.
        XCTAssertEqual(showing(opened(current: true), ended: true), .hidden)
        XCTAssertEqual(showing(opened(current: false), ended: true, seen: true), .hidden)
        // Closed: listed quietly (the lists leave it out).
        XCTAssertEqual(showing(opened(current: true, status: .resolved)), .quiet)
        XCTAssertEqual(showing(opened(current: false, status: .falseAlarm)), .quiet)
    }

    // MARK: - The marks

    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sos-marks-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private let account = "a0000000-0000-4000-8000-000000000001"
    private let other = "a0000000-0000-4000-8000-000000000002"
    private let circle = "a0000000-0000-4000-8000-0000000000c1"
    private let sosId = "a0000000-0000-4000-8000-0000000000f1"

    func testSeenCurrentKeepsEveryPayloadOneWay() throws {
        let directory = try scratch()
        let marks = SOSAlarmMarks(directory: directory)
        XCTAssertNil(marks.mark(account: account, circleId: circle, sosId: sosId))
        XCTAssertTrue(marks.noteSeenCurrent(account: account, circleId: circle, sosId: sosId, hash: "A", at: now))
        XCTAssertTrue(marks.noteSeenCurrent(account: account, circleId: circle, sosId: sosId, hash: "B", at: now))
        XCTAssertTrue(marks.noteSeenCurrent(account: account, circleId: circle, sosId: sosId, hash: "A", at: now))
        XCTAssertEqual(marks.mark(account: account, circleId: circle, sosId: sosId)?.seenCurrent, ["A", "B"])
        // In any spelling of the ids.
        XCTAssertEqual(marks.mark(account: account.uppercased(), circleId: circle.uppercased(),
                                  sosId: sosId.replacingOccurrences(of: "-", with: ""))?.seenCurrent, ["A", "B"])
        // Kept on disk: a new store reads it.
        let again = SOSAlarmMarks(directory: directory)
        XCTAssertEqual(again.mark(account: account, circleId: circle, sosId: sosId)?.seenCurrent, ["A", "B"])
        // Capped, oldest first out.
        for n in 0..<SOSAlarmMarks.maxHashesPerAlert {
            marks.noteSeenCurrent(account: account, circleId: circle, sosId: sosId, hash: "h\(n)", at: now)
        }
        let kept = try XCTUnwrap(marks.mark(account: account, circleId: circle, sosId: sosId)?.seenCurrent)
        XCTAssertEqual(kept.count, SOSAlarmMarks.maxHashesPerAlert)
        XCTAssertFalse(kept.contains("A"))
        XCTAssertEqual(kept.last, "h\(SOSAlarmMarks.maxHashesPerAlert - 1)")
    }

    /// Seen as A → re-sealed as B while current → another rotation → B still
    /// alarms.
    func testAResealedSOSStaysStickyAcrossTheNextRotation() throws {
        let marks = SOSAlarmMarks(directory: try scratch())
        marks.noteSeenCurrent(account: account, circleId: circle, sosId: sosId, hash: "A", at: now)
        marks.noteSeenCurrent(account: account, circleId: circle, sosId: sosId, hash: "B", at: now)
        let mark = marks.mark(account: account, circleId: circle, sosId: sosId)
        let resealedB = opened(current: false, hash: "B")
        XCTAssertEqual(showing(resealedB, seen: mark?.seenCurrent.contains(resealedB.payloadHash) == true), .alarming)
        // Another payload under the same id was never seen: nothing.
        let other = opened(current: false, hash: "C")
        XCTAssertEqual(showing(other, seen: mark?.seenCurrent.contains(other.payloadHash) == true), .hidden)
    }

    func testEndedIsOneWay() throws {
        let marks = SOSAlarmMarks(directory: try scratch())
        marks.noteSeenCurrent(account: account, circleId: circle, sosId: sosId, hash: "A", at: now)
        XCTAssertTrue(marks.noteEnded(account: account, circleId: circle, sosId: sosId, at: now))
        marks.noteSeenCurrent(account: account, circleId: circle, sosId: sosId, hash: "B", at: now)
        XCTAssertEqual(marks.mark(account: account, circleId: circle, sosId: sosId)?.ended, true)
    }

    func testAnUnreadableStoreIsNotSeenAndNeverWrittenOver() throws {
        let directory = try scratch()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("\(account).json")
        try Data("not json".utf8).write(to: file)
        let marks = SOSAlarmMarks(directory: directory)
        XCTAssertNil(marks.mark(account: account, circleId: circle, sosId: sosId), "unreadable: not seen")
        XCTAssertFalse(marks.noteSeenCurrent(account: account, circleId: circle, sosId: sosId, hash: "A", at: now))
        XCTAssertFalse(marks.noteEnded(account: account, circleId: circle, sosId: sosId, at: now))
        marks.prune(account: account, now: now, maxAgeMs: M.maxAlarmAgeMs)
        XCTAssertEqual(try Data(contentsOf: file), Data("not json".utf8), "never written over")
    }

    func testMarksArePerAccountAndNeverAdopted() throws {
        let directory = try scratch()
        let marks = SOSAlarmMarks(directory: directory)
        marks.noteSeenCurrent(account: account, circleId: circle, sosId: sosId, hash: "A", at: now)
        XCTAssertNil(marks.mark(account: other, circleId: circle, sosId: sosId), "another account's are not mine")
        marks.noteSeenCurrent(account: other, circleId: circle, sosId: sosId, hash: "B", at: now)

        XCTAssertEqual(marks.accounts(), [account, other])
        marks.forget(account: account.uppercased())
        let fresh = SOSAlarmMarks(directory: directory)
        XCTAssertNil(fresh.mark(account: account, circleId: circle, sosId: sosId), "gone by the guarded tidy")
        XCTAssertEqual(fresh.mark(account: other, circleId: circle, sosId: sosId)?.seenCurrent, ["B"])

        fresh.wipeAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path), "an erasure")
        XCTAssertNil(fresh.mark(account: other, circleId: circle, sosId: sosId))
    }

    func testMarksGoOnlyPastTheAlarmAge() throws {
        let marks = SOSAlarmMarks(directory: try scratch())
        let (young, old) = ("a0000000-0000-4000-8000-0000000000f2", "a0000000-0000-4000-8000-0000000000f3")
        marks.noteEnded(account: account, circleId: circle, sosId: young, at: now - M.maxAlarmAgeMs)
        marks.noteEnded(account: account, circleId: circle, sosId: old, at: now - M.maxAlarmAgeMs - 1)
        marks.prune(account: account, now: now, maxAgeMs: M.maxAlarmAgeMs)
        XCTAssertNotNil(marks.mark(account: account, circleId: circle, sosId: young))
        XCTAssertNil(marks.mark(account: account, circleId: circle, sosId: old))
    }

    // MARK: - Opening with versions (the real SDK)

    private struct Party {
        let id: String
        let sdk = CryptoManager()
        let sharing: String
        let signing: String

        init(_ id: String) {
            self.id = id
            sharing = Self.hex(sdk.generateKeypair().publicKey)
            signing = Self.hex(sdk.generateSigningKeypair().verifyingKeyB64)
        }

        static func hex(_ b64: String) -> String {
            Data(base64Encoded: b64)!.map { String(format: "%02x", $0) }.joined()
        }
    }

    /// The owner makes v1 and gives it to this device and to one it later
    /// leaves out; v2 without either; v3 with this device (seals under v3).
    private func world() throws -> (owner: Party, me: Party, leftOut: Party) {
        let owner = Party("a0000000-0000-4000-8000-00000000000a")
        let me = Party(account), leftOut = Party("a0000000-0000-4000-8000-00000000000b")
        func give(_ member: Party, _ bundle: MemberKeyBundle, _ version: Int32) throws {
            try member.sdk.storeCircleKey(
                circleId: circle, encryptedKey: bundle.encryptedCircleKey.nonce + bundle.encryptedCircleKey.ciphertext,
                senderPublicKey: bundle.ephemeralPublicKey, keyVersion: version, senderUserId: owner.id,
                recipientUserId: member.id, wrapSignatureHex: bundle.wrapSignature, senderSigningPubkeyHex: owner.signing)
        }
        for member in [me, leftOut] {
            _ = try member.sdk.pinMemberKeys(circleId: circle, userId: owner.id,
                                             sharingPubkeyHex: owner.sharing, signingPubkeyHex: owner.signing)
        }
        let creation = try owner.sdk.prepareCircleCreation()
        try owner.sdk.finalizeCircleCreation(tempCircleId: creation.tempCircleId, realCircleId: circle)
        for member in [me, leftOut] {
            try give(member, try owner.sdk.wrapCircleKeyForMemberFull(
                circleId: circle, memberPublicKeyHex: member.sharing, senderUserId: owner.id,
                recipientUserId: member.id, recipientSigningPubkeyHex: member.signing), 1)
        }
        _ = try owner.sdk.prepareKeyRotation(
            circleId: circle, senderUserId: owner.id, memberUserIds: [owner.id], memberPublicKeysHex: [owner.sharing],
            memberSigningPubkeysHex: [owner.signing], currentCircleNamePlaintext: "Family")
        let v3 = try owner.sdk.prepareKeyRotation(
            circleId: circle, senderUserId: owner.id, memberUserIds: [owner.id, me.id],
            memberPublicKeysHex: [owner.sharing, me.sharing], memberSigningPubkeysHex: [owner.signing, me.signing],
            currentCircleNamePlaintext: "Family")
        try give(me, try XCTUnwrap(v3.memberKeys.first { $0.userId == me.id }).bundle, 3)
        return (owner, me, leftOut)
    }

    private func blob(_ e: EncryptedData) -> [String: Any] { ["nonce": e.nonce, "ciphertext": e.ciphertext] }

    private func sos(raiser: String, device: String = "device-1", idBy: CryptoManager, timeBy: CryptoManager,
                     placeBy: CryptoManager, deviceBy: CryptoManager, time: String? = nil) throws -> SOSResponse {
        let json: [String: Any] = [
            "id": sosId, "circle_id": circle, "status": "active", "day_bucket": 20_000,
            "encrypted_user_id": blob(try idBy.encryptDataV2(circleId: circle, plaintext: raiser, fieldTag: "user_id")),
            "encrypted_device_id": blob(try deviceBy.encryptDataV2(circleId: circle, plaintext: device, fieldTag: "device_id")),
            "encrypted_timestamp": blob(try timeBy.encryptDataV2(circleId: circle, plaintext: time ?? String(now),
                                                                 fieldTag: "timestamp")),
            "encrypted_location": blob(try placeBy.encryptLocation(circleId: circle, location: Location(
                latitude: 52.5, longitude: 13.4, altitude: nil, speed: nil, heading: nil, accuracy: 5,
                timestamp: now, batteryLevel: nil, isCharging: nil))),
        ]
        return try APIService.makeWireDecoder().decode(SOSResponse.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testAnSOSIsCurrentOnlyWhenItsIdAndTimeOpenUnderTheKeyInUse() throws {
        let (owner, me, leftOut) = try world()
        let o = owner.sdk, l = leftOut.sdk
        let current = M.openAlert(try sos(raiser: owner.id, idBy: o, timeBy: o, placeBy: o, deviceBy: o),
                                  myUserId: me.id, myDeviceId: "mine", crypto: me.sdk)
        XCTAssertTrue(current.current)
        XCTAssertEqual(current.alert.userId, owner.id)
        XCTAssertEqual(current.sealedTimeMs, now)
        XCTAssertEqual(current.alert.latitude, 52.5)
        XCTAssertFalse(current.raisedHere)

        // Any part under v1 (held by the one left out) makes it history.
        for (what, response) in [
            ("raiser id", try sos(raiser: owner.id, idBy: l, timeBy: o, placeBy: o, deviceBy: o)),
            ("time", try sos(raiser: owner.id, idBy: o, timeBy: l, placeBy: o, deviceBy: o)),
            ("position", try sos(raiser: owner.id, idBy: o, timeBy: o, placeBy: l, deviceBy: o)),
        ] {
            XCTAssertFalse(M.openAlert(response, myUserId: me.id, myDeviceId: "mine", crypto: me.sdk).current, what)
        }
        // The time must open: no age, no alarm.
        let timeless = M.openAlert(try sos(raiser: owner.id, idBy: o, timeBy: o, placeBy: o, deviceBy: o, time: "soon"),
                                   myUserId: me.id, myDeviceId: "mine", crypto: me.sdk)
        XCTAssertNil(timeless.sealedTimeMs)
        XCTAssertFalse(timeless.current)
    }

    func testTheHashIsTheExactPayloadAndRaisedHereIsThisDevice() throws {
        let (owner, me, _) = try world()
        let o = owner.sdk
        let first = try sos(raiser: owner.id, idBy: o, timeBy: o, placeBy: o, deviceBy: o)
        let resealed = try sos(raiser: owner.id, idBy: o, timeBy: o, placeBy: o, deviceBy: o)
        XCTAssertEqual(M.payloadHash(first), M.payloadHash(first))
        XCTAssertNotEqual(M.payloadHash(first), M.payloadHash(resealed), "fresh nonces: another payload")
        // Each sealed field is in it on its own: one changed, another hash.
        let json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder.snakeCase.encode(first)) as? [String: Any])
        for field in ["encrypted_user_id", "encrypted_location", "encrypted_timestamp", "encrypted_device_id"] {
            for part in ["nonce", "ciphertext"] {
                var changed = json
                var sealed = try XCTUnwrap(changed[field] as? [String: Any])
                sealed[part] = "00" + ((sealed[part] as? String) ?? "")
                changed[field] = sealed
                let other = try APIService.makeWireDecoder().decode(
                    SOSResponse.self, from: JSONSerialization.data(withJSONObject: changed))
                XCTAssertNotEqual(M.payloadHash(other), M.payloadHash(first), "\(field) \(part)")
            }
        }

        let mine = try sos(raiser: me.id, device: "this-device", idBy: me.sdk, timeBy: me.sdk, placeBy: me.sdk,
                           deviceBy: me.sdk)
        XCTAssertTrue(M.openAlert(mine, myUserId: me.id.uppercased(), myDeviceId: "this-device", crypto: me.sdk).raisedHere)
        XCTAssertFalse(M.openAlert(mine, myUserId: me.id, myDeviceId: "another-device", crypto: me.sdk).raisedHere)
    }

    // MARK: - Wiring

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

    func testTheRulesAreWiredIn() throws {
        let manager = try source("App/Managers/SOSManager.swift")
        let load = try body(manager, from: "    func loadActiveAlerts(quiet: Bool = false) async throws {",
                            to: "    /// Alerts the MAP should draw")
        XCTAssertTrue(load.contains("Self.openAlert($0, myUserId: myUserId, myDeviceId: myDeviceId, crypto: cryptoManager)"))
        XCTAssertTrue(load.contains("let verdict = SOSReceiverRules.verdict(\n"
                                    + "                live: entry.alert.status.isLive, opened: entry.opened, behind: behind(on: circleId), marks: state,\n"))
        XCTAssertTrue(load.contains("            case .hidden:\n                continue\n"))
        XCTAssertTrue(load.contains("                alert.alarms = false\n"))
        XCTAssertTrue(load.contains("} else if entry.current {\n                    marks.noteSeenCurrent("))
        XCTAssertTrue(load.contains("if entry.alert.status.isClosed {\n                    marks.noteEnded("))
        XCTAssertTrue(load.contains("if !entry.current, case .read(_, true) = state, raiserShown == false {"))
        XCTAssertTrue(load.contains("marks.prune(account: myUserId, now: now, maxAgeMs: Self.maxAlarmAgeMs)"))
        XCTAssertTrue(load.contains("let currentAlerts = opened.filter(\\.current)"))
        XCTAssertTrue(load.contains("alert.alarms && alert.status.isLive && !alert.acknowledgedByMe && !alert.dismissedByMe"))
        XCTAssertTrue(load.contains("if needsAttention && !quiet {"))
        let models = try source("App/Models/Models.swift")
        XCTAssertTrue(models.contains("status.isLive && alarms && !dismissedByMe && !acknowledgedByMe && coordinate != nil"))

        let push = try source("App/Managers/PushNotificationManager.swift")
        let refresh = try body(push, from: "        case \"sos_refresh\":\n", to: "        case \"sos_alert\", \"sos\"")
        XCTAssertTrue(refresh.contains("try? await SOSManager.shared.loadActiveAlerts(quiet: true)"))
        XCTAssertFalse(refresh.contains("reportReceipt"), "no receipt: no new alert")

        // Kept across a sign-out: only the guarded tidy (`SignInTidy`) or an
        // erasure takes them.
        let auth = try source("App/Managers/AuthManager.swift")
        XCTAssertFalse(auth.contains("SOSAlarmMarks.shared.wipe(except:"))
        let purge = try body(auth, from: "    private func purgeAccountData() async {", to: "\n    }\n")
        XCTAssertFalse(purge.contains("SOSAlarmMarks.shared."), "not at a sign-out")
        XCTAssertTrue(auth.contains("                RefreshLedger.shared.wipeAll()\n                SOSAlarmMarks.shared.wipeAll()\n"),
                      "at an erasure (`!retainingTrust`)")
        XCTAssertEqual(auth.components(separatedBy: "SOSAlarmMarks.shared.wipeAll()").count - 1, 1)
        let tidy = try source("App/Services/SignInEmails.swift")
        XCTAssertTrue(tidy.contains("            ledger.forget(account: account)\n            marks.forget(account: account)\n"))
        XCTAssertTrue(tidy.contains(".union(marks.accounts())"))
    }
}
