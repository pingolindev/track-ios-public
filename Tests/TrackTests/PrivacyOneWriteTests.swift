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
@testable import Track

/// A privacy write is never built from a stale copy. Every privacy PUT is the
/// whole row, so a Save built from the sheet's copy, taken when it opened,
/// would undo a pause made on the web while the sheet was open, and Pause
/// would send the Bubble Mode the sheet showed even when it had changed
/// elsewhere; two quick switches could turn real-time sharing back on. Each
/// write sends only what the person changed, on the row the server holds
/// then, read again first, and a circle's writes go one at a time.
@MainActor
final class PrivacyOneWriteTests: XCTestCase {
    private let circle = UUID().uuidString.lowercased()
    private let future = Date().addingTimeInterval(3600)

    private func rfc3339(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date).replacingOccurrences(of: "Z", with: "+00:00")
    }

    /// A row as GET /api/v1/privacy/circles/{id} answers it, through the app's
    /// live decoder.
    private func row(mode: String, pausedUntil: Date? = nil, radius: Int? = nil, history: Bool = true,
                     extra: String = "") throws -> PrivacySettings {
        let paused = pausedUntil.map { "\"\(rfc3339($0))\"" } ?? "null"
        let radiusField = radius.map(String.init) ?? "null"
        let json = """
        {"id": "\(UUID().uuidString.lowercased())", "circle_id": "\(circle)", "sharing_mode": "\(mode)",
         "approximate_radius_miles": \(radiusField), "approximate_until": null, "paused_until": \(paused),
         "share_realtime": true, "share_history": \(history), "share_battery": true,
         "primary_device_id": null, "primary_device_pseudonym": null, "show_all_devices": false,
         "allow_alerts_on_me": true, "created_day_bucket": 20000, "updated_day_bucket": 20010\(extra)}
        """
        let response: PrivacySettingsResponse = try APIService.decodeResponseBody(
            Data(#"{"success": true, "data": \#(json)}"#.utf8))
        return CircleManager.privacySettings(from: response)
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// Save sends the switches the person changed, on the row as it is now:
    /// one changed elsewhere meanwhile keeps that change.
    func testASaveSendsThePersonsChangesOnTheRowAsItIsNow() throws {
        let shown = try row(mode: "exact")

        // Real-time off here, history off elsewhere.
        var edited = shown
        edited.shareRealtime = false
        let both = CircleManager.changes(edited, from: shown, onto: try row(mode: "exact", history: false))
        XCTAssertFalse(both.shareRealtime)
        XCTAssertFalse(both.shareHistory, "the change made elsewhere stands")

        // Paused on the web while the sheet was open: a Save here keeps it.
        var battery = shown
        battery.shareBattery = false
        let pausedThere = try row(mode: "paused", pausedUntil: future, extra: #", "mode_before_pause": "exact""#)
        let keepsPause = CircleManager.changes(battery, from: shown, onto: pausedThere)
        XCTAssertTrue(keepsPause.isPaused)
        XCTAssertEqual(CircleManager.privacyRequest(for: keepsPause).sharingMode, "paused")
        XCTAssertFalse(keepsPause.shareBattery)

        // Bubble Mode switched on elsewhere and not touched here: it stays on.
        let bubbleThere = try row(mode: "approximate", radius: 2)
        let keepsBubble = CircleManager.changes(battery, from: shown, onto: bubbleThere)
        XCTAssertEqual(CircleManager.privacyRequest(for: keepsBubble).sharingMode, "approximate")
        XCTAssertEqual(CircleManager.privacyRequest(for: keepsBubble).approximateRadius, 2)

        // Switched on here: sent.
        var bubbleHere = shown
        bubbleHere.chooseBubble(true)
        bubbleHere.chooseBubbleRadius(4)
        let sent = CircleManager.changes(bubbleHere, from: shown, onto: try row(mode: "exact"))
        XCTAssertEqual(CircleManager.privacyRequest(for: sent).sharingMode, "approximate")
        XCTAssertEqual(CircleManager.privacyRequest(for: sent).approximateRadius, 4)

        // Nothing changed here: the row as it is.
        XCTAssertEqual(CircleManager.changes(shown, from: shown, onto: pausedThere), pausedThere)
    }

    /// Pause returns to the Bubble Mode the person chose here, else to the
    /// row's own: never to a Bubble Mode the sheet showed that has since
    /// changed elsewhere. On a row paused meanwhile, a choice made here is what
    /// that pause returns to, saved first.
    func testAPauseReturnsToTheBubbleModeChosenHereElseTheRows() async throws {
        let shown = try row(mode: "exact")
        let bubbleThere = try row(mode: "approximate", radius: 2)
        let untouched = CircleManager.pauseRequest(on: bubbleThere, edited: shown, shown: shown, until: future)
        XCTAssertEqual(untouched.modeBeforePause, "approximate", "the row's, not the exact the sheet showed")
        XCTAssertEqual(untouched.bubbleRadius, 2)

        var exactHere = try row(mode: "approximate", radius: 2)
        let shownApproximate = exactHere
        exactHere.chooseBubble(false)
        let chosen = CircleManager.pauseRequest(on: bubbleThere, edited: exactHere, shown: shownApproximate,
                                                until: future)
        XCTAssertEqual(chosen.modeBeforePause, "exact")

        var bubbleHere = shown
        bubbleHere.chooseBubble(true)
        bubbleHere.chooseBubbleRadius(3)
        let pausedThere = try row(mode: "paused", pausedUntil: future, extra: #", "mode_before_pause": "exact""#)
        let onPaused = CircleManager.changes(bubbleHere, from: shown, onto: pausedThere)
        XCTAssertEqual(onPaused.modeBeforePause, "approximate", "the choice made here is what the pause returns to")
        var sent: [String] = []
        try await CircleManager.savePrivacy(
            onPaused, confirmed: pausedThere,
            put: { step in
                sent.append(CircleManager.privacyRequest(for: step).sharingMode)
                return CircleManager.storedCopy(after: step)
            },
            store: { _ in })
        XCTAssertEqual(sent, ["approximate", "paused"], "the mode first, then the pause, which stands")
    }

    /// A circle's privacy writes go one at a time: the second starts after the
    /// first has ended, even when the first failed.
    func testACirclesPrivacyWritesGoOneAtATime() async throws {
        var log: [String] = []
        let first = CircleManager.shared.privacyWrite(circle) { _ in
            log.append("first starts")
            try await Task.sleep(nanoseconds: 50_000_000)
            log.append("first ends")
            throw APIError(code: "http_503", message: "")
        }
        let second = CircleManager.shared.privacyWrite(circle.uppercased()) { _ in
            log.append("second starts")
            log.append("second ends")
        }
        _ = await first.result
        try await second.value
        XCTAssertEqual(log, ["first starts", "first ends", "second starts", "second ends"],
                       "the same circle in any spelling")
    }

    /// A write goes out only for the account it was made for: the same
    /// account in any spelling, never another one or nobody (a write still
    /// waiting when one person signs out and another signs in).
    func testAWriteGoesOutOnlyForTheAccountItWasMadeFor() {
        let me = "e0000000-0000-4000-8000-000000000001"
        let them = "e0000000-0000-4000-8000-000000000002"
        XCTAssertNoThrow(try CircleManager.stillSignedIn(as: me, now: me))
        XCTAssertNoThrow(try CircleManager.stillSignedIn(as: me, now: me.uppercased()))
        XCTAssertThrowsError(try CircleManager.stillSignedIn(as: me, now: them))
        XCTAssertThrowsError(try CircleManager.stillSignedIn(as: me, now: nil), "signed out")
        XCTAssertThrowsError(try CircleManager.stillSignedIn(as: nil, now: nil), "made for nobody")
    }

    /// A write cancelled while it waits (as a sign-out cancels them all)
    /// never runs.
    func testACancelledWriteNeverRuns() async {
        var ran: [String] = []
        let first = CircleManager.shared.privacyWrite(circle) { _ in
            try await Task.sleep(nanoseconds: 50_000_000)
            ran.append("first")
        }
        let second = CircleManager.shared.privacyWrite(circle) { _ in ran.append("second") }
        second.cancel()
        _ = await first.result
        _ = await second.result
        XCTAssertEqual(ran, ["first"])
    }

    /// Every privacy write goes through the queue and is built on a row read
    /// again; the sheet sends what was changed from what it showed, and keeps
    /// what it showed in step with the server.
    func testEveryPrivacyWriteIsQueuedAndBuiltOnARowReadAgain() throws {
        let manager = try source("App/Managers/CircleManager.swift")
        XCTAssertTrue(manager.contains("""
                    try await privacyWrite(edited.circleId) { owner in
                        let latest = try await self.latestPrivacyRow(edited.circleId, for: owner)
                        try await self.updatePrivacySettings(Self.changes(edited, from: shown, onto: latest), for: owner)
                    }.value
            """), "Save")
        XCTAssertTrue(manager.contains("""
                    try await privacyWrite(edited.circleId) { owner in
                        let latest = try await self.latestPrivacyRow(edited.circleId, for: owner)
                        try await self.updatePrivacySettings(
                            Self.pauseRequest(on: latest, edited: edited, shown: shown, until: until), for: owner)
                    }.value
            """), "Pause")
        XCTAssertTrue(manager.contains("""
                    try await privacyWrite(circleId) { owner in
                        try self.checkStillSignedIn(as: owner)
                        let response = try await self.api.resumePrivacySharing(circleId: circleId)
                        guard CanonicalId.same(AuthManager.shared.userId, owner) else { return }
            """), "Resume: sent and kept only for its account")
        XCTAssertTrue(manager.contains("""
                    try checkStillSignedIn(as: owner)
                    try await loadPrivacySettings(for: circleId)
                    guard let latest = privacySettings[circleId] else { throw PauseNotSent() }
            """), "read again, for its account")
        XCTAssertTrue(manager.contains("""
                        put: { step in
                            try self.checkStillSignedIn(as: owner)
                            return try await self.sendPrivacySettings(step)
                        },
                        store: {
                            guard CanonicalId.same(AuthManager.shared.userId, owner) else { return }
            """), "each PUT, right before it goes; nothing kept for another account")

        // Made for the account signed in when queued; a cancelled one never runs.
        let queue = try XCTUnwrap(manager.range(of: "    func privacyWrite(_ circleId: String,\n"))
        let owner = try XCTUnwrap(manager.range(of: "        let owner = AuthManager.shared.userId\n",
                                                range: queue.upperBound..<manager.endIndex))
        let task = try XCTUnwrap(manager.range(of: "        let task = Task { @MainActor in\n",
                                               range: queue.upperBound..<manager.endIndex))
        XCTAssertLessThan(owner.lowerBound, task.lowerBound, "captured when queued, not when sent")
        XCTAssertTrue(manager.contains(
            "            _ = await before?.result\n            try Task.checkCancellation()\n            try await write(owner)\n"))
        XCTAssertTrue(manager.contains("""
                    for task in privacyWriteTasks.values { task.cancel() }
                    privacyWriteTasks = [:]
                    privacyWriteTail = [:]
            """), "a sign-out ends every write queued or on its way")

        let view = try source("App/Views/Circles/CirclesView.swift")
        XCTAssertTrue(view.contains("                try await circleManager.saveChanges(settings, shownFrom: shown)\n"))
        XCTAssertFalse(view.contains("circleManager.updatePrivacySettings("), "no write of the sheet's whole copy")
        XCTAssertTrue(view.contains("        shown = shown.adoptingPosture(of: stored)\n        shown.alignBubbleWithPause(at: now)\n"))
    }
}
