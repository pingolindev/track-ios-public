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

/// After signing out and in again, or on another iPhone, the asker's own open
/// help request still shows and can be closed: the account's own live alert
/// shows again, once the server says it is theirs, with its responders and its
/// close; only the device that raised it keeps it updated. Matching only an
/// alert whose sealed device id is this device's would not do: a sign-out
/// takes the device id with the keychain, and the circle would keep seeing
/// "needs attention" with no end, since only the asker may close it.
final class OwnAlertRestoreTests: XCTestCase {
    private typealias M = Track.SOSManager

    private let me = "c0000000-0000-4000-8000-00000000000c"
    private let other = "d0000000-0000-4000-8000-00000000000d"
    private let circle = "e0000000-0000-4000-8000-00000000000e"
    private let sosId = "f0000000-0000-4000-8000-00000000000f"
    private let now: Int64 = 1_727_700_000_000

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func body(_ src: String, from start: String, to end: String) throws -> String {
        let a = try XCTUnwrap(src.range(of: start), start)
        let b = try XCTUnwrap(src.range(of: end, range: a.upperBound..<src.endIndex), end)
        return String(src[a.upperBound..<b.lowerBound])
    }

    private func alert(_ id: String, by userId: String, minutesAgo: Double = 5,
                       status: SOSAlert.SOSStatus = .active) -> SOSAlert {
        SOSAlert(id: id, circleId: circle, userId: userId, status: status, latitude: 37.3349, longitude: -122.0090,
                 acknowledgedBy: [], createdAt: Date(timeIntervalSince1970: TimeInterval(now) / 1000 - minutesAgo * 60))
    }

    // MARK: - Which alert shows again

    /// The real thing: an alert this account sealed on device A, opened on
    /// device B. Not raised here, so it shows as the asker's own without its
    /// updates; opened on A it is the full restore.
    func testAnAlertRaisedOnAnotherDeviceShowsAgainWithoutItsUpdates() throws {
        let sdk = CryptoManager()
        _ = sdk.generateKeypair()
        _ = sdk.generateSigningKeypair()
        let creation = try sdk.prepareCircleCreation()
        try sdk.finalizeCircleCreation(tempCircleId: creation.tempCircleId, realCircleId: circle)
        func blob(_ e: EncryptedData) -> [String: Any] { ["nonce": e.nonce, "ciphertext": e.ciphertext] }
        let json: [String: Any] = [
            "id": sosId, "circle_id": circle, "status": "active", "day_bucket": 20_000,
            "encrypted_user_id": blob(try sdk.encryptDataV2(circleId: circle, plaintext: me, fieldTag: "user_id")),
            "encrypted_device_id": blob(try sdk.encryptDataV2(circleId: circle, plaintext: "device-A",
                                                              fieldTag: "device_id")),
            "encrypted_timestamp": blob(try sdk.encryptDataV2(circleId: circle, plaintext: String(now),
                                                              fieldTag: "timestamp")),
            "encrypted_location": blob(try sdk.encryptLocation(circleId: circle, location: Location(
                latitude: 37.3349, longitude: -122.0090, altitude: nil, speed: nil, heading: nil, accuracy: 5,
                timestamp: now, batteryLevel: nil, isCharging: nil))),
        ]
        let response = try APIService.makeWireDecoder().decode(
            SOSResponse.self, from: JSONSerialization.data(withJSONObject: json))

        let elsewhere = M.openAlert(response, myUserId: me, myDeviceId: "device-B", crypto: sdk)
        XCTAssertTrue(elsewhere.current)
        XCTAssertFalse(elsewhere.raisedHere)
        let shown = try XCTUnwrap(M.ownToRestore([elsewhere.alert], raisedHere: [], me: me.uppercased()))
        XCTAssertEqual(shown.alert.id, sosId)
        XCTAssertFalse(shown.raisedHere)
        XCTAssertFalse(shown.keepsItUpdated, "no emergency mode, no position updates, no re-seal from here")

        let here = M.openAlert(response, myUserId: me, myDeviceId: "device-A", crypto: sdk)
        XCTAssertTrue(here.raisedHere)
        let restored = try XCTUnwrap(M.ownToRestore([here.alert], raisedHere: [here.alert.id], me: me))
        XCTAssertTrue(restored.keepsItUpdated, "the device that raised it keeps it updated")
    }

    /// One this device raised comes first; else the newest live one the
    /// account raised elsewhere.
    func testThisDevicesOwnComesFirstElseTheAccountsNewest() {
        let older = alert("a1000000-0000-4000-8000-000000000001", by: me, minutesAgo: 30)
        let newer = alert("a1000000-0000-4000-8000-000000000002", by: me, minutesAgo: 5)
        let raisedHere = alert("a1000000-0000-4000-8000-000000000003", by: me, minutesAgo: 60)
        XCTAssertEqual(M.ownToRestore([older, raisedHere, newer], raisedHere: [raisedHere.id], me: me),
                       M.OwnRestore(alert: raisedHere, raisedHere: true))
        XCTAssertEqual(M.ownToRestore([older, newer], raisedHere: [], me: me),
                       M.OwnRestore(alert: newer, raisedHere: false))
    }

    /// Someone else's, a closed one, or no account: nothing shows as the
    /// asker's own.
    func testOnlyTheAccountsOwnLiveAlertShows() {
        XCTAssertNil(M.ownToRestore([alert(sosId, by: other)], raisedHere: [], me: me))
        XCTAssertNil(M.ownToRestore([alert(sosId, by: me, status: .resolved)], raisedHere: [], me: me))
        XCTAssertNil(M.ownToRestore([alert(sosId, by: me, status: .falseAlarm)], raisedHere: [], me: me))
        XCTAssertNil(M.ownToRestore([alert(sosId, by: me)], raisedHere: [], me: nil))
        XCTAssertNil(M.ownToRestore([alert(sosId, by: "not-an-id")], raisedHere: [], me: "not-an-id"))
        XCTAssertNil(M.ownToRestore([], raisedHere: [], me: me))
    }

    // MARK: - The server's word

    private func served(id: String, status: String = "active", acknowledgedBy: [String]?) throws -> OwnSOSResponse {
        let blob: [String: Any] = ["nonce": "AAAA", "ciphertext": "AAAA"]
        var json: [String: Any] = [
            "id": id, "circle_id": circle, "status": status, "day_bucket": 20_000,
            "encrypted_user_id": blob, "encrypted_device_id": blob, "encrypted_timestamp": blob,
            "encrypted_location": blob,
        ]
        if let acknowledgedBy { json["acknowledged_by"] = acknowledgedBy }
        return try APIService.makeWireDecoder().decode(
            OwnSOSResponse.self, from: JSONSerialization.data(withJSONObject: json))
    }

    /// It shows only when the server serves the raiser's view of it (the
    /// responders, an empty list included), for that alert, while it is live.
    func testItShowsOnlyOnTheServersWordThatItIsTheCallersOwn() throws {
        XCTAssertTrue(M.ownConfirmed(try served(id: sosId, acknowledgedBy: []), alertId: sosId))
        XCTAssertTrue(M.ownConfirmed(try served(id: sosId, acknowledgedBy: [other]), alertId: sosId.uppercased()))
        XCTAssertFalse(M.ownConfirmed(try served(id: sosId, acknowledgedBy: nil), alertId: sosId),
                       "not the raiser: no responders served")
        XCTAssertFalse(M.ownConfirmed(try served(id: other, acknowledgedBy: []), alertId: sosId), "another alert")
        XCTAssertFalse(M.ownConfirmed(try served(id: sosId, status: "resolved", acknowledgedBy: []), alertId: sosId))
    }

    // MARK: - Wiring

    /// Shown elsewhere-raised: on the server's word, as the asker's card with
    /// its poll, and nothing of this device's put into it. The full restore
    /// stays this device's own.
    func testTheRestoreElsewhereShowsAndClosesButNeverUpdates() throws {
        let manager = try source("App/Managers/SOSManager.swift")
        let restore = try body(manager, from: "        } else if let own = Self.ownToRestore(alerts, raisedHere: raisedHere, me: AuthManager.shared.userId) {",
                               to: "    /// What showing this account's own")
        let elsewhere = try body(restore, from: "            if !own.keepsItUpdated {", to: "                return\n            }")
        XCTAssertTrue(elsewhere.contains("guard let served = try? await api.getOwnSOSAlert(alertId: restored.id),"))
        XCTAssertTrue(elsewhere.contains("Self.ownConfirmed(served, alertId: restored.id), myActiveAlert == nil else { return }"))
        XCTAssertTrue(elsewhere.contains("myActiveAlert = restored\n                shownFromElsewhere = restored.id"))
        XCTAssertTrue(elsewhere.contains("startAlertPolling(alertId: restored.id, raisedAt: restored.createdAt)"))
        for never in ["setEmergencyMode", "startUpdateWatch", "updateIfDue", "runUpdate", "SOSSealedPositions",
                      "watchDelivery"] {
            XCTAssertFalse(elsewhere.contains(never), never)
        }
        let full = try body(restore, from: "                return\n            }", to: "\n    }\n")
        XCTAssertTrue(full.contains("locationService.setEmergencyMode(true)"))
        XCTAssertTrue(full.contains("updateIfDue(restored.id)"))
        // A re-seal is still only ever for an alert this device raised.
        XCTAssertTrue(manager.contains(
            "guard [\"active\", \"acknowledged\"].contains(status), opened.opened, opened.raisedHere,"))
    }

    /// The raise stays off while the alert stands: until it ends (its close,
    /// or the server says so), or, for one shown from elsewhere, until the
    /// server stops listing it at all.
    func testTheBlockLiftsWhenItEndsOrLeavesTheListing() throws {
        let manager = try source("App/Managers/SOSManager.swift")
        let load = try body(manager, from: "    func loadActiveAlerts(quiet: Bool = false) async throws {", to: "\n    }\n")
        XCTAssertTrue(load.contains("listed: Set(opened.map { CanonicalId.key($0.alert.id) }))"))
        let reconcile = try body(
            manager,
            from: "    private func reconcileMyAlert(with alerts: [SOSAlert], raisedHere: Set<String>, listed: Set<String>) async {",
            to: "        } else if let own = Self.ownToRestore(")
        XCTAssertTrue(reconcile.contains(
            "} else if CanonicalId.same(shownFromElsewhere, mine.id), !listed.contains(CanonicalId.key(mine.id)) {"))
        XCTAssertTrue(reconcile.contains("// free again. Nothing of this device's ran for it.\n                closeMyAlert(mine.id)"))
        let close = try body(manager, from: "    private func closeMyAlert(", to: "    private func pollAlertStatus(")
        XCTAssertTrue(close.contains("if CanonicalId.same(shownFromElsewhere, alertId) { shownFromElsewhere = nil }"))
        XCTAssertTrue(close.contains("            myActiveAlert = nil\n"))
    }

    /// A sign-out drops it all, and another account signing in starts from
    /// nothing: its own alerts only, by its own id.
    func testASignOutDropsTheShownAlert() throws {
        let manager = try source("App/Managers/SOSManager.swift")
        let reset = try body(manager, from: "    func reset() {", to: "\n    }\n")
        for cleared in ["myActiveAlert = nil", "shownFromElsewhere = nil", "responders = [:]", "hasActiveAlert = false",
                        "stopAlertPolling()"] {
            XCTAssertTrue(reset.contains(cleared), cleared)
        }
        XCTAssertTrue(try source("App/Managers/AuthManager.swift").contains("        SOSManager.shared.reset()\n"))
        XCTAssertTrue(manager.contains("Self.ownToRestore(alerts, raisedHere: raisedHere, me: AuthManager.shared.userId)"))
    }

    /// A second raise is off only while an alert THIS device raised stands
    /// (it already follows this phone). With only one raised elsewhere shown,
    /// the raise stays on: a fresh request follows this phone, and the old one
    /// stays open to close.
    func testASecondRaiseIsOffOnlyForAnAlertRaisedHere() throws {
        let shown = alert(sosId, by: me)
        XCTAssertTrue(M.raiseIsOff(shown: shown, shownFromElsewhere: nil), "raised here: off")
        XCTAssertFalse(M.raiseIsOff(shown: shown, shownFromElsewhere: sosId.uppercased()), "raised elsewhere: on")
        XCTAssertTrue(M.raiseIsOff(shown: shown, shownFromElsewhere: other), "another alert was the elsewhere one")
        XCTAssertFalse(M.raiseIsOff(shown: nil, shownFromElsewhere: nil))
        XCTAssertFalse(M.raiseIsOff(shown: nil, shownFromElsewhere: sosId))
        let manager = try source("App/Managers/SOSManager.swift")
        let raise = try body(manager, from: "    func triggerSOS(for circleId: String, message: String? = nil) async throws -> SOSAlert {",
                             to: "    func cancelSOS(")
        XCTAssertTrue(raise.contains("        myActiveAlert = alert\n"))
        XCTAssertTrue(raise.contains("        shownFromElsewhere = nil\n"))
    }

    /// A fresh raise beside one shown from elsewhere: the fresh one is the
    /// card while it stands; once it ends, the next load brings the old one
    /// back as the card, with its "False Alarm" and "I'm Safe".
    func testTheOldAlertComesBackOnceTheFreshOneEnds() throws {
        let old = SOSAlert(id: "a2000000-0000-4000-8000-000000000001", circleId: circle, userId: me, status: .active,
                           latitude: 37.3349, longitude: -122.0090, acknowledgedBy: [],
                           createdAt: Date().addingTimeInterval(-2 * 3_600))
        let fresh = SOSAlert(id: "a2000000-0000-4000-8000-000000000002", circleId: circle, userId: me, status: .active,
                             latitude: 37.3349, longitude: -122.0090, acknowledgedBy: [],
                             createdAt: Date().addingTimeInterval(-5 * 60))
        XCTAssertEqual(M.ownToRestore([old, fresh], raisedHere: [fresh.id], me: me),
                       M.OwnRestore(alert: fresh, raisedHere: true), "while the fresh one stands")
        // Ended: the server lists active alerts only, so the next load lists the old one alone.
        XCTAssertEqual(M.ownToRestore([old], raisedHere: [], me: me), M.OwnRestore(alert: old, raisedHere: false))
        var ended = fresh
        ended.status = .resolved
        XCTAssertEqual(M.ownToRestore([old, ended], raisedHere: [fresh.id], me: me),
                       M.OwnRestore(alert: old, raisedHere: false), "even while the ended one is still listed")

        // The restore runs whenever no own alert is shown, which the fresh
        // one's end leaves; the card it fills has both closes.
        let manager = try source("App/Managers/SOSManager.swift")
        XCTAssertTrue(manager.contains("""
                private func reconcileMyAlert(with alerts: [SOSAlert], raisedHere: Set<String>, listed: Set<String>) async {
                    if let mine = myActiveAlert {
            """))
        XCTAssertTrue(manager.contains(
            "        } else if let own = Self.ownToRestore(alerts, raisedHere: raisedHere, me: AuthManager.shared.userId) {"))
        let close = try body(manager, from: "    private func closeMyAlert(", to: "    private func pollAlertStatus(")
        XCTAssertTrue(close.contains("            myActiveAlert = nil\n"))
        let view = try source("App/Views/Safety/SOSView.swift")
        for control in ["Text(\"False Alarm\")", "Text(\"I'm Safe\")",
                        "try await sosManager.cancelSOS(alert, reason: .falseAlarm)", "try await sosManager.resolveSOS(alert)"] {
            XCTAssertTrue(view.contains(control), control)
        }
    }

    /// The card and the close go by `myActiveAlert`, which the restore sets,
    /// and the raise by `raiseIsOff`: the card shows, and its close closes it
    /// here. The server lets the asker close it from any device: its resolve
    /// checks the account, never the device.
    func testTheCardTheRaiseAndTheCloseFollowTheRestoredAlert() throws {
        let view = try source("App/Views/Safety/SOSView.swift")
        XCTAssertTrue(view.contains("if let myAlert = sosManager.myActiveAlert {\n                        ActiveSOSCard(alert: myAlert)"))
        XCTAssertTrue(view.contains(".disabled(sosManager.raiseIsOff)"))
        let manager = try source("App/Managers/SOSManager.swift")
        let cancel = try body(manager, from: "    func cancelSOS(", to: "    func resolveSOS(")
        XCTAssertTrue(cancel.contains("_ = try await api.markSOSFalseAlarm(alertId: alert.id)"))
        XCTAssertTrue(cancel.contains("_ = try await api.resolveSOS(alertId: alert.id, resolution: reason.rawValue)"))
        XCTAssertTrue(cancel.contains("if myActiveAlert?.id == alert.id {\n            closeMyAlert(alert.id)"))
    }
}
