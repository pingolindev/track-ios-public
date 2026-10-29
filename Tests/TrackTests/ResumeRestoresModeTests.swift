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

import PingolinTrackSDK
import XCTest
@testable import Track

/// A pause ends in the mode held before it.
///
/// WHY THIS IS WORTH TESTING
///   - It is easy for every way out of a pause to land on "exact": a refresh
///     during a pause reads `sharing_mode: "paused"`, which says nothing about
///     Bubble Mode, and a Resume built from that sends exact. The server says
///     what the pause returns to (`mode_before_pause`). An older server does
///     not, and that must change nothing.
///   - A timed pause ends on the phone at its deadline, before the next refresh
///     (in the background, up to an hour). The phone sends again in that window,
///     so what it sends must take the mode the pause returns to — proven here on
///     the stream's own coarsening — and every send site must ask that one rule.
///   - Resume is the server's call (`POST …/resume`), with no PUT fallback.
final class ResumeRestoresModeTests: XCTestCase {

    private let circle = UUID().uuidString.lowercased()
    private let future = Date().addingTimeInterval(3600)
    private let past = Date().addingTimeInterval(-60)

    /// The server's form (chrono `to_rfc3339()`): "+00:00", no fraction on a whole second.
    private func rfc3339(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date).replacingOccurrences(of: "Z", with: "+00:00")
    }

    /// The row GET /api/v1/privacy/circles/{id} — and POST …/resume — answers
    /// with, as the server writes it. `extra` adds `mode_before_pause`, or not.
    private func rowJSON(mode: String, pausedUntil: Date? = nil, radius: Int? = nil,
                         approximateUntil: Date? = nil, extra: String = "") -> String {
        let paused = pausedUntil.map { "\"\(rfc3339($0))\"" } ?? "null"
        let bubbleEnd = approximateUntil.map { "\"\(rfc3339($0))\"" } ?? "null"
        let radiusField = radius.map(String.init) ?? "null"
        return """
        {"id": "\(UUID().uuidString.lowercased())", "circle_id": "\(circle)", "sharing_mode": "\(mode)",
         "approximate_radius_miles": \(radiusField), "approximate_until": \(bubbleEnd), "paused_until": \(paused),
         "share_realtime": true, "share_history": true, "share_battery": true,
         "primary_device_id": null, "primary_device_pseudonym": null, "show_all_devices": false,
         "allow_alerts_on_me": true, "created_day_bucket": 20000, "updated_day_bucket": 20010\(extra)}
        """
    }

    /// Through the app's live decoder, envelope and all.
    private func row(_ json: String) throws -> PrivacySettingsResponse {
        try APIService.decodeResponseBody(Data(#"{"success": true, "data": \#(json)}"#.utf8))
    }

    private func settings(_ json: String) throws -> PrivacySettings {
        CircleManager.privacySettings(from: try row(json))
    }

    private let approximate = #", "mode_before_pause": "approximate""#

    // MARK: - The field

    func testTheRowDecodesWithAndWithoutTheField() throws {
        XCTAssertEqual(try row(rowJSON(mode: "paused", pausedUntil: future, radius: 3, extra: approximate)).modeBeforePause,
                       "approximate")
        XCTAssertEqual(try row(rowJSON(mode: "paused", extra: #", "mode_before_pause": "exact""#)).modeBeforePause, "exact")
        XCTAssertNil(try row(rowJSON(mode: "exact", extra: #", "mode_before_pause": null"#)).modeBeforePause)
        XCTAssertNil(try row(rowJSON(mode: "paused", pausedUntil: future)).modeBeforePause, "an older server")
    }

    // MARK: - A refresh during a pause

    func testARefreshDuringAPauseKeepsBubbleModeAndItsRadius() throws {
        let s = try settings(rowJSON(mode: "paused", pausedUntil: future, radius: 3, extra: approximate))
        XCTAssertTrue(s.isPaused)
        XCTAssertTrue(s.bubbleEnabled, "the sheet shows what Resume brings back")
        XCTAssertEqual(s.bubbleRadius, 3)
        XCTAssertEqual(s.modeBeforePause, "approximate")
    }

    /// The same row embedded in GET /circles (`my_privacy`) maps the same way:
    /// the circles refresh is the one that runs during a pause.
    func testTheEmbeddedRowDuringAPauseKeepsBubbleMode() throws {
        let body = """
        [{"id": "\(circle)", "owner_id": "u1", "is_owner": false,
          "encrypted_name": {"nonce": "00", "ciphertext": "00"}, "day_bucket": 20000, "member_count": 2,
          "key_version": 3, "my_privacy": \(rowJSON(mode: "paused", pausedUntil: future, radius: 3, extra: approximate))}]
        """
        let circles = try APIService.makeWireDecoder().decode([CircleResponse].self, from: Data(body.utf8))
        let plan = CircleManager.privacyRefreshPlan(circleIds: [circle], responses: circles)
        let s = try XCTUnwrap(plan.embedded[circle])
        XCTAssertTrue(s.isPaused)
        XCTAssertTrue(s.bubbleEnabled)
        XCTAssertEqual(s.bubbleRadius, 3)
    }

    func testAnOlderServerOrAnExactPauseStillResumesExact() throws {
        for extra in ["", #", "mode_before_pause": "exact""#, #", "mode_before_pause": null"#] {
            var s = try settings(rowJSON(mode: "paused", pausedUntil: future, extra: extra))
            XCTAssertFalse(s.bubbleEnabled, extra)
            s.resume()
            XCTAssertEqual(s.sharingMode, "exact", extra)
        }
    }

    // MARK: - Resume

    /// The sheet's Resume, then Save: the mode it sends is the one held before
    /// the pause (the server applies an explicit mode as sent).
    func testTheSheetsResumeSendsTheModeHeldBeforeThePause() throws {
        var s = try settings(rowJSON(mode: "paused", pausedUntil: future, radius: 3, extra: approximate))
        s.resume()
        XCTAssertEqual(s.sharingMode, "approximate")
        XCTAssertEqual(s.bubbleRadius, 3)
        XCTAssertNil(s.pausedUntil)
        XCTAssertNil(s.modeBeforePause)
        XCTAssertFalse(s.isPaused)
    }

    /// `POST …/resume` answers with the row as the server restored it, and
    /// that answer is what this phone keeps.
    func testTheResumeAnswerIsStoredAsTheServerRestoredIt() throws {
        let s = try settings(rowJSON(mode: "approximate", radius: 3, extra: #", "mode_before_pause": null"#))
        XCTAssertFalse(s.isPaused)
        XCTAssertTrue(s.bubbleEnabled)
        XCTAssertTrue(s.sharesApproximately)
        XCTAssertEqual(s.bubbleRadius, 3)
    }

    func testResumeAsksTheServerWithNoPutFallback() throws {
        let manager = try source("App/Managers/CircleManager.swift")
        let start = try XCTUnwrap(manager.range(of: "    func resumeSharing(for circleId: String) async throws {\n"))
        let end = try XCTUnwrap(manager.range(of: "\n    }\n", range: start.upperBound..<manager.endIndex))
        let body = String(manager[start.upperBound..<end.lowerBound])
        XCTAssertEqual(body, """
                    try await privacyWrite(circleId) { owner in
                        try self.checkStillSignedIn(as: owner)
                        let response = try await self.api.resumePrivacySharing(circleId: circleId)
                        guard CanonicalId.same(AuthManager.shared.userId, owner) else { return }
                        self.privacySettings[circleId] = Self.privacySettings(from: response)
                        CirclePauseRecord.shared.observe(Self.privacySettings(from: response), at: Date(), exact: true,
                                                         owner: AuthManager.shared.userId)
                    }.value
            """, "one privacy write at a time (PrivacyOneWriteTests)")
        let api = try source("App/Services/APIService.swift")
        XCTAssertTrue(api.contains(
            #"return try await post(path: "/api/v1/privacy/circles/\(circleId)/resume", body: EmptyBody())"#))
    }

    // MARK: - A timed pause that has ended on this phone

    func testAnEndedPauseSharesAsTheModeItReturnsTo() throws {
        let ended = try settings(rowJSON(mode: "paused", pausedUntil: past, radius: 3, extra: approximate))
        XCTAssertFalse(ended.isPaused, "it sends again at its deadline")
        XCTAssertTrue(ended.sharesApproximately, "and never exact from someone who was approximate")
        XCTAssertFalse(try settings(rowJSON(mode: "paused", pausedUntil: past, extra: #", "mode_before_pause": "exact""#))
            .sharesApproximately)
        XCTAssertFalse(try settings(rowJSON(mode: "paused", pausedUntil: past)).sharesApproximately, "an older server")
    }

    /// A pause made on this phone records the mode it returns to, as the
    /// server does, and moving a running pause keeps it.
    func testAPauseMadeHereRecordsTheModeItReturnsTo() throws {
        var s = try settings(rowJSON(mode: "approximate", radius: 2))
        s.pause(until: future)
        XCTAssertEqual(s.modeBeforePause, "approximate")
        XCTAssertTrue(s.sharesApproximately)
        s.bubbleEnabled = false
        s.pause(until: future.addingTimeInterval(3600))
        XCTAssertEqual(s.modeBeforePause, "approximate", "moving a running pause keeps it")
        s.pausedUntil = past
        XCTAssertTrue(s.sharesApproximately, "ended here: still the mode it returns to")

        var exact = PrivacySettings.default(for: circle)
        exact.pause(until: future)
        XCTAssertEqual(exact.modeBeforePause, "exact")
        exact.pausedUntil = past
        XCTAssertFalse(exact.sharesApproximately)
    }

    // MARK: - What a send carries once a timed pause has ended here

    private let fix = PingolinTrackSDK.Location(
        latitude: 37.33490, longitude: -122.00900, altitude: 30, speed: 1.5, heading: 90, accuracy: 5,
        timestamp: 1_760_400_000_000, batteryLevel: 80, isCharging: false)

    /// The row this phone holds once a timed pause has ended, before any
    /// refresh: still "paused", its deadline passed, the 1-mile radius kept.
    private func endedPause(_ extra: String, approximateUntil: Date? = nil) throws -> PrivacySettings {
        try settings(rowJSON(mode: "paused", pausedUntil: past, radius: 1, approximateUntil: approximateUntil,
                             extra: extra))
    }

    /// What the live stream seals for the circle (and keeps for it), given that row.
    @MainActor
    private func sent(_ row: PrivacySettings) -> PingolinTrackSDK.Location {
        SDKLocationStreamer.privacyApplied(fix, circleId: circle, privacy: row).location
    }

    @MainActor
    func testASendAfterAnApproximatePauseEndedIsCoarsened() throws {
        let cell = 1609.344
        let (lat, lng) = LocationCoarsener.coarsenLocation(lat: fix.latitude, lng: fix.longitude, radiusMeters: cell)
        for row in [try endedPause(approximate), try endedPause(approximate, approximateUntil: future)] {
            XCTAssertFalse(row.isPaused, "the deadline has passed: the phone sends again")
            let out = sent(row)
            XCTAssertEqual(out.latitude, lat)
            XCTAssertEqual(out.longitude, lng)
            XCTAssertNotEqual(out.latitude, fix.latitude, "not the exact fix")
            XCTAssertNil(out.speed)
            XCTAssertNil(out.heading)
            XCTAssertNil(out.altitude)
            XCTAssertEqual(out.accuracy, cell)
        }
    }

    @MainActor
    func testASendAfterAPauseEndedIsExactWhenThePauseReturnsToExact() throws {
        let rows = [
            try endedPause(#", "mode_before_pause": "exact""#),
            try endedPause(""),                                      // an older server
            try endedPause(approximate, approximateUntil: past),    // the bubble's own end has passed
        ]
        for row in rows {
            XCTAssertFalse(row.isPaused)
            XCTAssertEqual(sent(row), fix)
        }
    }

    // MARK: - Bubble Mode changed and a pause, in one save

    /// The body each request sends, through the app's wire encoder.
    private func body(_ step: PrivacySettings) throws -> [String: Any] {
        let request = CircleManager.privacyRequest(for: step).request
        let data = try APIService.makeWireEncoder().encode(request)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private struct Saved {
        var sent: [PrivacySettings] = []
        /// What this phone kept, in order.
        var stored: [PrivacySettings] = []
        /// How many copies were kept by the time each step went out.
        var storedBeforeStep: [Int] = []
    }

    /// Saved as the sheet does: what the server last confirmed, and the visit's
    /// edits. `failing`: the step (1-based) whose request fails.
    @MainActor
    private func save(_ edited: PrivacySettings, confirmed: PrivacySettings,
                      failing: Int? = nil, into saved: inout Saved) async throws {
        var log = Saved()
        defer { saved = log }
        try await CircleManager.savePrivacy(
            edited, confirmed: confirmed,
            put: { step in
                log.storedBeforeStep.append(log.stored.count)
                log.sent.append(step)
                if log.sent.count == failing { throw APIError(code: "http_503", message: "") }
                return CircleManager.storedCopy(after: step)
            },
            store: { log.stored.append($0) })
    }

    @MainActor
    private func save(_ edited: PrivacySettings, confirmed: PrivacySettings) async throws -> [PrivacySettings] {
        var saved = Saved()
        try await save(edited, confirmed: confirmed, into: &saved)
        return saved.sent
    }

    @MainActor
    func testBubbleSwitchedOnAndAPauseSaveTheBubbleFirst() async throws {
        let confirmed = PrivacySettings.default(for: circle)          // the server's row: exact
        var edited = confirmed
        edited.bubbleEnabled = true
        edited.bubbleRadius = 2
        edited.pause(until: future)
        let sent = try await save(edited, confirmed: confirmed)
        XCTAssertEqual(sent.count, 2, "the mode, then the pause")
        guard sent.count == 2 else { return }
        let first = try body(sent[0])
        XCTAssertEqual(first["sharing_mode"] as? String, "approximate")
        XCTAssertEqual(first["approximate_radius_miles"] as? Int, 2)
        XCTAssertNil(first["paused_until"] as? String)
        let second = try body(sent[1])
        XCTAssertEqual(second["sharing_mode"] as? String, "paused")
        XCTAssertNotNil(second["paused_until"] as? String)
    }

    @MainActor
    func testBubbleSwitchedOffOrResizedAndAPauseSaveThatFirst() async throws {
        let confirmed = try settings(rowJSON(mode: "approximate", radius: 2))
        var off = confirmed
        off.bubbleEnabled = false
        off.pause(until: future)
        let offSent = try await save(off, confirmed: confirmed)
        XCTAssertEqual(try offSent.map { try body($0)["sharing_mode"] as? String }, ["exact", "paused"])

        var resized = confirmed
        resized.bubbleRadius = 5
        resized.pause(until: future)
        let resizedSent = try await save(resized, confirmed: confirmed)
        XCTAssertEqual(try resizedSent.map { try body($0)["sharing_mode"] as? String }, ["approximate", "paused"])
        XCTAssertEqual(try body(resizedSent[0])["approximate_radius_miles"] as? Int, 5)
    }

    @MainActor
    func testAPauseAloneIsOneRequest() async throws {
        for confirmed in [PrivacySettings.default(for: circle), try settings(rowJSON(mode: "approximate", radius: 2)),
                          try settings(rowJSON(mode: "paused", pausedUntil: future, radius: 2, extra: approximate))] {
            var edited = confirmed
            edited.pause(until: future.addingTimeInterval(3600))
            let sent = try await save(edited, confirmed: confirmed)
            XCTAssertEqual(try sent.map { try body($0)["sharing_mode"] as? String }, ["paused"], confirmed.sharingMode)
        }
    }

    /// The mode was saved and the pause was not: the person is told what stands.
    @MainActor
    func testWhenThePauseFailsAfterTheBubbleSaysWhatStands() async throws {
        let confirmed = PrivacySettings.default(for: circle)
        var edited = confirmed
        edited.bubbleEnabled = true
        edited.pause(until: future)
        var failed = Saved()
        do {
            try await save(edited, confirmed: confirmed, failing: 2, into: &failed)
            XCTFail("the failed pause must not pass for a save")
        } catch let error as Track.CircleManager.PauseNotSaved {
            XCTAssertTrue(error.approximate)
            XCTAssertTrue(error.plainText.contains(
                "Bubble Mode is on, but the pause wasn't saved: this circle sees your approximate location now."))
            XCTAssertTrue(error.plainText.hasSuffix("Tap Pause Sharing to try again."),
                          "a pause is sent by its own button")
        }
        // What stands is kept: the mode just saved, unpaused.
        XCTAssertEqual(failed.stored.map(\.sharingMode), ["approximate"])
        // The first request failing is just that failure: nothing else is
        // tried, and nothing is kept.
        var saved = Saved()
        do {
            try await save(edited, confirmed: confirmed, failing: 1, into: &saved)
            XCTFail("expected the failure")
        } catch is Track.CircleManager.PauseNotSaved {
            XCTFail("nothing was saved, so nothing stands")
        } catch {}
        XCTAssertEqual(saved.sent.count, 1)
        XCTAssertTrue(saved.stored.isEmpty)
    }

    // MARK: - Pause and Resume at once

    /// Pause sends the row the server holds, paused, with the Bubble Mode the
    /// person chose in the sheet, which is what the pause returns to. Never the
    /// sheet's other switches: a change not saved is not sent by Pause, and
    /// waits for Save.
    func testPauseSendsTheServersRowWithTheBubbleModeChosenHere() throws {
        let confirmed = PrivacySettings.default(for: circle)          // the server's row: exact, all shared
        var edited = confirmed
        edited.shareHistory = false                                   // changes not saved
        edited.allowAlertsOnMe = false
        edited.chooseBubble(true)
        edited.chooseBubbleRadius(3)
        let request = CircleManager.pauseRequest(on: confirmed, edited: edited, shown: confirmed, until: future)
        XCTAssertTrue(request.isPaused)
        XCTAssertEqual(request.pausedUntil, future)
        XCTAssertEqual(request.modeBeforePause, "approximate", "returns to the Bubble Mode chosen")
        XCTAssertTrue(request.bubbleEnabled)
        XCTAssertEqual(request.bubbleRadius, 3)
        XCTAssertTrue(request.shareHistory, "a switch not saved is not sent by Pause")
        XCTAssertTrue(request.allowAlertsOnMe)

        var exactEdited = confirmed
        exactEdited.shareBattery = false
        let exact = CircleManager.pauseRequest(on: confirmed, edited: exactEdited, shown: confirmed, until: nil)
        XCTAssertTrue(exact.isPaused, "an indefinite pause")
        XCTAssertNil(exact.pausedUntil)
        XCTAssertEqual(exact.modeBeforePause, "exact")
        XCTAssertTrue(exact.shareBattery)
    }

    /// Bubble Mode switched on here over an exact row: the pause saves that mode
    /// first, then the pause, as `savePrivacy` does for any pause with a Bubble
    /// change.
    @MainActor
    func testAPauseWithBubbleModeChosenHereSavesThatModeFirst() async throws {
        let confirmed = PrivacySettings.default(for: circle)
        var edited = confirmed
        edited.chooseBubble(true)
        edited.chooseBubbleRadius(2)
        let sent = try await save(CircleManager.pauseRequest(on: confirmed, edited: edited, shown: confirmed,
                                                             until: future), confirmed: confirmed)
        XCTAssertEqual(try sent.map { try body($0)["sharing_mode"] as? String }, ["approximate", "paused"])
        XCTAssertEqual(try body(sent[0])["approximate_radius_miles"] as? Int, 2)
        let untouched = CircleManager.pauseRequest(on: confirmed, edited: confirmed, shown: confirmed, until: future)
        let alone = try await save(untouched, confirmed: confirmed)
        XCTAssertEqual(try alone.map { try body($0)["sharing_mode"] as? String }, ["paused"], "a pause alone is one request")
    }

    /// Once the server has a Pause or Resume, the sheet shows the posture it
    /// holds, and keeps the switches changed and not yet saved, for Save: a
    /// later Save neither undoes the pause nor drops those changes.
    func testThePostureTheServerHoldsIsWhatTheSheetShowsAfterwards() throws {
        let stored = try settings(rowJSON(mode: "paused", pausedUntil: future, radius: 4, extra: approximate))
        var sheet = PrivacySettings.default(for: circle)
        sheet.shareRealtime = false
        sheet.shareBattery = false
        sheet.allowAlertsOnMe = false
        let shown = sheet.adoptingPosture(of: stored)
        XCTAssertTrue(shown.isPaused)
        XCTAssertEqual(shown.sharingMode, "paused")
        XCTAssertEqual(shown.pausedUntil, stored.pausedUntil)
        XCTAssertEqual(shown.modeBeforePause, "approximate")
        XCTAssertEqual(shown.bubbleRadius, 4)
        XCTAssertEqual(shown.bubbleEnabled, stored.bubbleEnabled)
        XCTAssertFalse(shown.shareRealtime, "the changes not saved stay for Save")
        XCTAssertFalse(shown.shareBattery)
        XCTAssertFalse(shown.allowAlertsOnMe)
        XCTAssertTrue(shown.shareHistory)
        // A Save from there sends the pause the server holds, not exact.
        XCTAssertEqual(CircleManager.privacyRequest(for: shown).sharingMode, "paused")
        // And after a Resume, the mode the server restored.
        let resumed = try settings(rowJSON(mode: "approximate", radius: 4, extra: #", "mode_before_pause": null"#))
        let back = shown.adoptingPosture(of: resumed)
        XCTAssertFalse(back.isPaused)
        XCTAssertNil(back.pausedUntil)
        XCTAssertTrue(back.bubbleEnabled)
        XCTAssertEqual(CircleManager.privacyRequest(for: back).sharingMode, "approximate")
        XCTAssertFalse(back.shareRealtime)
    }

    /// The sheet: Pause and Resume each send at once, through the manager, and
    /// the sheet never pauses or resumes its own copy; nothing shows as paused
    /// until the server has it; Save waits while one is on its way.
    func testPauseAndResumeAreSentAtOnceAndShownOnceTaken() throws {
        let view = try source("App/Views/Circles/CirclesView.swift")
        let start = try XCTUnwrap(view.range(of: "struct PrivacySettingsSheet: View {"))
        let sheet = String(view[start.upperBound...])
        XCTAssertTrue(sheet.contains("Button(\"Pause Sharing\") { pauseNow() }"))
        XCTAssertTrue(sheet.contains("Button(\"Resume Sharing\") { resumeNow() }"))
        XCTAssertFalse(sheet.contains("settings.pause("), "the sheet never pauses its own copy")
        XCTAssertFalse(sheet.contains("settings.resume("))
        XCTAssertTrue(sheet.contains(
            "sendPause(pausing: true) { try await circleManager.pauseSharing(settings, shownFrom: shown, until: until) }"))
        XCTAssertTrue(sheet.contains(
            "sendPause(pausing: false) { try await circleManager.resumeSharing(for: settings.circleId) }"))
        XCTAssertTrue(sheet.contains("                try await request()\n                adoptStoredPosture()\n"))
        XCTAssertTrue(sheet.contains("        settings = settings.adoptingPosture(of: stored)\n"))
        let sending = try XCTUnwrap(sheet.range(of: "                    if pauseSending {\n"))
        let paused = try XCTUnwrap(sheet.range(of: "                    } else if settings.isPaused {\n"))
        XCTAssertLessThan(sending.lowerBound, paused.lowerBound, "on its way: never shown as paused")
        XCTAssertTrue(sheet.contains("                    .disabled(isLoading || pauseSending || postureUnknown)\n"))
        XCTAssertTrue(sheet.contains("Text(\"Pausing and resuming take effect at once.\")"))
        let manager = try source("App/Managers/CircleManager.swift")
        XCTAssertTrue(manager.contains(
            "                Self.pauseRequest(on: latest, edited: edited, shown: shown, until: until), for: owner)\n"))
    }

    /// A Pause or Resume that failed on its way back may have been taken all
    /// the same. The server is asked again and its posture shown; why it
    /// failed is said only when the change was not taken.
    func testAFailedPauseOrResumeShowsWhatTheServerHoldsAndSaysWhyOnlyIfNotTaken() throws {
        let lost = APIError(code: "network", message: "The request timed out.")
        XCTAssertNil(PrivacySettingsSheet.pauseFailureLine(lost, pausing: true, nowPaused: true), "paused after all")
        XCTAssertNil(PrivacySettingsSheet.pauseFailureLine(lost, pausing: false, nowPaused: false), "resumed after all")
        XCTAssertEqual(PrivacySettingsSheet.pauseFailureLine(lost, pausing: true, nowPaused: false), lost.plainLine)
        XCTAssertEqual(PrivacySettingsSheet.pauseFailureLine(lost, pausing: false, nowPaused: true), lost.plainLine)
        let notSaved = CircleManager.PauseNotSaved(approximate: true, reason: lost)
        XCTAssertEqual(PrivacySettingsSheet.pauseFailureLine(notSaved, pausing: true, nowPaused: false),
                       notSaved.plainText, "what stands")
        XCTAssertNil(PrivacySettingsSheet.pauseFailureLine(notSaved, pausing: true, nowPaused: true))

        let view = try source("App/Views/Circles/CirclesView.swift")
        let start = try XCTUnwrap(view.range(of: "struct PrivacySettingsSheet: View {"))
        let sheet = String(view[start.upperBound...])
        XCTAssertTrue(sheet.contains("""
                            } catch {
                                let heard = (try? await circleManager.loadPrivacySettings(for: settings.circleId)) != nil
                                adoptStoredPosture()
                                postureUnknown = !heard
                                errorMessage = heard
                                    ? Self.pauseFailureLine(error, pausing: pausing, nowPaused: settings.isPaused) : nil
                            }
                """), "asked again, then shown, then said")
    }

    /// A Pause or Resume that failed, with the check after it failing too,
    /// leaves the sheet unable to tell what the server holds. It never shows
    /// the pause it last knew as current and Save waits, as on the web, while
    /// the server is asked again every 5 s, in the foreground only, until it
    /// answers.
    func testAPostureThatCantBeReadIsSaidSoAndSaveWaits() throws {
        XCTAssertEqual(PrivacySettingsSheet.postureUnknownLine,
                       "Couldn't load your privacy settings to see whether that went through. Trying again…")
        XCTAssertFalse(PrivacySettingsSheet.postureUnknownLine.localizedCaseInsensitiveContains("key"))
        let view = try source("App/Views/Circles/CirclesView.swift")
        let start = try XCTUnwrap(view.range(of: "struct PrivacySettingsSheet: View {"))
        let sheet = String(view[start.upperBound...])
        let sending = try XCTUnwrap(sheet.range(of: "                    if pauseSending {\n"))
        let unknown = try XCTUnwrap(sheet.range(of: "                    } else if postureUnknown {\n"))
        let paused = try XCTUnwrap(sheet.range(of: "                    } else if settings.isPaused {\n"))
        XCTAssertLessThan(sending.lowerBound, unknown.lowerBound)
        XCTAssertLessThan(unknown.lowerBound, paused.lowerBound, "never the pause it last knew, as current")
        XCTAssertTrue(sheet.contains("                            Text(Self.postureUnknownLine)\n"))
        XCTAssertTrue(sheet.contains("                    .disabled(isLoading || pauseSending || postureUnknown)\n"),
                      "Save waits")
        XCTAssertEqual(sheet.components(separatedBy: ".disabled(settings.isPaused || postureUnknown)\n").count - 1, 2,
                       "and so does Bubble Mode")

        let sleep = try XCTUnwrap(sheet.range(of: "try? await Task.sleep(nanoseconds: 5_000_000_000)"))
        let before = String(sheet[..<sleep.lowerBound])
        let task = try XCTUnwrap(before.range(of: ".task(", options: .backwards))
        XCTAssertTrue(String(before[task.lowerBound...]).hasPrefix(
            ".task(id: postureUnknown && scenePhase == .active) {\n"
            + "                guard postureUnknown, scenePhase == .active else { return }\n"), "foreground only")
        XCTAssertTrue(sheet.contains("""
                                    if (try? await circleManager.loadPrivacySettings(for: settings.circleId)) != nil {
                                        adoptStoredPosture()
                                        postureUnknown = false
                                        return
                                    }
                """), "until the server answers")
        // And never past a sign-out: only for the account the sheet was opened for.
        XCTAssertTrue(sheet.contains(
            "                    guard !Task.isCancelled, CanonicalId.same(AuthManager.shared.userId, account) else { break }\n"))
        XCTAssertTrue(sheet.contains("        _account = State(initialValue: AuthManager.shared.userId)\n"))
    }

    // MARK: - A bubble saved from iOS has no end

    /// Scenario 1: a bubble with an end (18:00, set by another client)
    /// resized and paused in one save. Step 1 drops the end on the server, so
    /// the pause kept here has none, and a send after the pause, past the old
    /// end, is coarse, as the server's resume is approximate.
    @MainActor
    func testABubbleWithAnEndResizedAndPausedKeepsNoEnd() async throws {
        let oldEnd = Date().addingTimeInterval(1800)
        let confirmed = try settings(rowJSON(mode: "approximate", radius: 2, approximateUntil: oldEnd))
        XCTAssertNotNil(confirmed.approximateUntil)
        for byTheSheet in [true, false] {
            var edited = confirmed
            if byTheSheet {
                edited.chooseBubbleRadius(5)             // the slider
                XCTAssertNil(edited.approximateUntil, "the person's change drops the end")
            } else {
                edited.bubbleRadius = 5                 // any other way: step 1 still drops it
            }
            edited.pause(until: future)
            var saved = Saved()
            try await save(edited, confirmed: confirmed, into: &saved)
            XCTAssertEqual(try saved.sent.map { try body($0)["sharing_mode"] as? String }, ["approximate", "paused"])
            let kept = try XCTUnwrap(saved.stored.last)
            XCTAssertEqual(saved.stored.count, 1, "only the outcome is kept")
            XCTAssertNil(kept.approximateUntil, "as the server now holds it")
            XCTAssertNil(saved.sent[1].approximateUntil, "the pause step goes with no end")
            var ended = kept
            ended.pausedUntil = oldEnd.addingTimeInterval(3600)         // the pause ended, an hour past the old end
            XCTAssertTrue(ended.sharesApproximately(at: oldEnd.addingTimeInterval(3601)), "coarse, never exact")
            XCTAssertNotNil(SDKLocationStreamer.privacyApplied(fix, circleId: circle, privacy: ended,
                                                               now: oldEnd.addingTimeInterval(3601)).coarsenedToMiles,
                            "the stream coarsens it")
        }
    }

    /// Scenario 2: an EXACT row still carrying a stale, PAST bubble end (the
    /// server's resume to exact leaves it). Bubble Mode on + Pause + Save is two
    /// requests, and the bubble is kept: the person's change dropped the end.
    @MainActor
    func testAStalePastEndDoesNotSwallowABubbleSwitchedOnWithAPause() async throws {
        let confirmed = try settings(rowJSON(mode: "exact", approximateUntil: past))
        var edited = confirmed
        edited.chooseBubble(true)
        edited.chooseBubbleRadius(3)
        edited.pause(until: future)
        var saved = Saved()
        try await save(edited, confirmed: confirmed, into: &saved)
        XCTAssertEqual(try saved.sent.map { try body($0)["sharing_mode"] as? String }, ["approximate", "paused"])
        XCTAssertEqual(try body(saved.sent[0])["approximate_radius_miles"] as? Int, 3)
        let kept = try XCTUnwrap(saved.stored.last)
        XCTAssertTrue(kept.returnsToApproximate(at: future.addingTimeInterval(60)), "the pause returns to the bubble")
    }

    /// Resume, a change and a Pause in one visit, from a running pause: while
    /// the pause step is on its way this phone still holds the paused row, so
    /// it sends nothing in between. Only the outcome is kept.
    @MainActor
    func testNothingIsKeptBetweenTheModeAndThePause() async throws {
        let confirmed = try settings(rowJSON(mode: "paused", pausedUntil: future, radius: 2, extra: approximate))
        var edited = confirmed
        edited.resume()
        edited.chooseBubbleRadius(4)
        edited.pause(until: future.addingTimeInterval(3600))
        var saved = Saved()
        try await save(edited, confirmed: confirmed, into: &saved)
        XCTAssertEqual(try saved.sent.map { try body($0)["sharing_mode"] as? String }, ["approximate", "paused"])
        XCTAssertEqual(saved.storedBeforeStep, [0, 0], "nothing kept before the pause step went out")
        XCTAssertEqual(saved.stored.map(\.sharingMode), ["paused"])
    }

    /// The re-check on opening the sheet is not a change: a paused row's real
    /// end stays, and choosing what is already chosen drops nothing.
    func testOnlyThePersonsOwnChangeDropsTheEnd() throws {
        let end = future
        var s = try settings(rowJSON(mode: "paused", pausedUntil: future, radius: 2, approximateUntil: end,
                                     extra: approximate))
        s.alignBubbleWithPause(at: Date())
        s.chooseBubble(s.bubbleEnabled)
        s.chooseBubbleRadius(s.bubbleRadius)
        XCTAssertEqual(s.approximateUntil, try settings(rowJSON(mode: "paused", pausedUntil: future, radius: 2,
                                                                approximateUntil: end, extra: approximate)).approximateUntil)
        XCTAssertNotNil(s.approximateUntil)
    }

    // MARK: - The bubble's own end passing during the pause

    func testResumeAfterTheBubblesEndPassedDuringThePauseIsExact() throws {
        let read = Date()
        // Read while the bubble still had a minute to run; resumed after it ended.
        var s = CircleManager.privacySettings(
            from: try row(rowJSON(mode: "paused", pausedUntil: future, radius: 2,
                                  approximateUntil: read.addingTimeInterval(60), extra: approximate)),
            now: read)
        XCTAssertTrue(s.bubbleEnabled, "as read, the bubble had not ended")
        s.resume(at: read.addingTimeInterval(120))
        XCTAssertEqual(s.sharingMode, "exact")
        XCTAssertEqual(CircleManager.privacyRequest(for: s).sharingMode, "exact", "and that is what Save sends")
    }

    // MARK: - The wiring

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// Every place that coarsens what is sent asks the one rule; none derives
    /// it again from the toggle, the mode or the field.
    func testEverySendSiteAsksTheOneRule() throws {
        for path in ["App/Services/SDKLocationStreamer.swift", "App/Managers/CheckInManager.swift",
                     "App/Managers/DestinationsManager.swift", "App/Views/Safety/SOSView.swift"] {
            let text = try source(path)
            XCTAssertTrue(text.contains(".sharesApproximately"), path)
            for derived in ["bubbleEnabled", "modeBeforePause", #"sharingMode == "approximate""#] {
                XCTAssertFalse(text.contains(derived), "\(path) reads \(derived)")
            }
        }
    }

    /// While paused, the sheet shows the mode Resume returns to and does not
    /// let it change: a paused save leaves the server's mode as it was.
    /// The toggle is re-asked where it can be stale: when a row is read, when
    /// the sheet opens, at Resume; and every save goes through the two-step plan.
    func testTheToggleIsAskedAgainWhereItCanBeStale() throws {
        let manager = try source("App/Managers/CircleManager.swift")
        XCTAssertTrue(manager.contains("        settings.alignBubbleWithPause(at: now)\n        return settings\n"))
        XCTAssertTrue(manager.contains(
            "        try await Self.savePrivacy(\n            settings, confirmed: privacySettings[settings.circleId],\n"))
        let sheet = try source("App/Views/Circles/CirclesView.swift")
        XCTAssertTrue(sheet.contains(
            "                settings.alignBubbleWithPause(at: now)\n                shown.alignBubbleWithPause(at: now)\n"))
        let model = try source("App/Models/Models.swift")
        XCTAssertTrue(model.contains("    mutating func resume(at now: Date = Date()) {\n        alignBubbleWithPause(at: now)\n"))
    }

    func testThePausedSheetDoesNotOfferAChangeThatWouldBeLost() throws {
        let sheet = try source("App/Views/Circles/CirclesView.swift")
        XCTAssertTrue(sheet.contains("Toggle(\"Enable Bubble Mode\", isOn: Binding(\n"
                                     + "                        get: { settings.bubbleEnabled }, set: { settings.chooseBubble($0) }))\n"
                                     + "                        .disabled(settings.isPaused || postureUnknown)\n"))
        XCTAssertTrue(sheet.contains("set: { settings.chooseBubbleRadius($0) }),\n"
                                     + "                                   in: 1...25, step: 1)\n"
                                     + "                        }\n"
                                     + "                        .disabled(settings.isPaused || postureUnknown)\n"))
    }
}
