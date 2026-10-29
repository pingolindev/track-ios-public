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

/// The sharing switches on iOS, the viewer's side and the words:
/// - A member who switched real-time sharing off and kept history on shows at
///   the last location they shared, frozen and labelled, from `/latest`'s
///   `last_known`; nothing judges it.
/// - Inactivity says nothing about a member who is paused or has real-time off
///   in the circle.
/// - A member whose history isn't shown keeps only their newest position on
///   this phone, one with both off none; levelled on every roster.
/// - The words, the same on all three apps.
@MainActor
final class SharingSwitchesViewerTests: XCTestCase {

    private let circle = "33333333-3333-3333-3333-333333333333"
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

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

    private func member(_ id: String, sharing: String? = nil, history: String? = nil) -> CircleMember {
        CircleMember(circleId: circle, userId: id, displayName: "m", role: .member, canSeeRealtime: true,
                     canSeeHistory: true, canRotateKeys: false, joinedAt: now,
                     locationSharing: sharing, sharingPausedUntil: nil, historySharing: history)
    }

    private func row(_ id: String, frozen: Bool = false, lat: Double = 37.3349) -> LocationData {
        var row = LocationData(circleId: circle, userId: id, deviceId: "d", latitude: lat, longitude: -122.009,
                               timestamp: now)
        row.sharingOff = frozen
        return row
    }

    // MARK: - The frozen last location

    func testLastKnownIsReadFromLatest() throws {
        let json = """
        {"locations": [], "last_known": [
          {"day_bucket": 20000, "encrypted_payload": {"nonce": "n", "ciphertext": "c"}}
        ]}
        """
        let answer = try APIService.makeWireDecoder().decode(LatestLocationsResponse.self, from: Data(json.utf8))
        XCTAssertEqual(answer.lastKnown?.count, 1)
        let older = try APIService.makeWireDecoder().decode(LatestLocationsResponse.self,
                                                            from: Data(#"{"locations": []}"#.utf8))
        XCTAssertNil(older.lastKnown, "omitted when empty, and by an older server")
    }

    /// A frozen row is drawn in place of any row held for that member; a
    /// paused member is drawn nowhere (a pause wins).
    func testTheMapDrawsTheFrozenRowInPlaceOfAHeldOne() {
        let (a, b, c) = ("aaaaaaaa-0000-4000-8000-000000000001", "bbbbbbbb-0000-4000-8000-000000000002",
                         "cccccccc-0000-4000-8000-000000000003")
        let held = [row(a, lat: 1), row(b, lat: 2)]
        let frozen = [row(a.uppercased(), frozen: true, lat: 3), row(c, frozen: true, lat: 4)]
        let drawn = MapView.withFrozen(held, frozen: frozen, roster: [member(a, sharing: "off"), member(b),
                                                                      member(c, sharing: "off")], now: now)
        XCTAssertEqual(Set(drawn.map { "\(CanonicalId.key($0.userId))@\($0.latitude)" }),
                       ["\(a)@3.0", "\(b)@2.0", "\(c)@4.0"])
        XCTAssertTrue(drawn.filter { CanonicalId.same($0.userId, a) }.allSatisfy(\.sharingOff))
        let paused = MapView.withFrozen(held, frozen: frozen, roster: [member(a, sharing: "paused"), member(b),
                                                                       member(c, sharing: "off")], now: now)
        XCTAssertFalse(paused.contains { $0.sharingOff && CanonicalId.same($0.userId, a) }, "paused: not drawn frozen")
    }

    /// A member with real-time off in circle A and on in B: on B's map, B's
    /// live row is drawn, never A's frozen one, and nobody's frozen row from
    /// another circle. The stores are keyed by member.
    func testOnlyTheActiveCirclesFrozenRowsAreDrawn() throws {
        let other = "44444444-4444-4444-4444-444444444444"
        let x = "aaaaaaaa-0000-4000-8000-000000000001"
        let liveInB = row(x, lat: 5)
        var frozenInA = LocationData(circleId: other, userId: x, deviceId: "d", latitude: 6, longitude: -122.009,
                                     timestamp: now)
        frozenInA.sharingOff = true
        let drawn = MapView.withFrozen(MapView.inCircle([liveInB], circle),
                                       frozen: MapView.inCircle([frozenInA], circle), roster: [member(x)], now: now)
        XCTAssertEqual(drawn.map(\.latitude), [5])
        XCTAssertFalse(drawn.contains(where: \.sharingOff))
        XCTAssertEqual(MapView.inCircle([frozenInA], other.uppercased()).count, 1, "the circle in any spelling")
        XCTAssertTrue(MapView.inCircle([frozenInA], nil).isEmpty, "no circle on the map: none")
        let map = try source("App/Views/Map/MapView.swift")
        XCTAssertTrue(map.contains(
            "frozen: Self.inCircle(circleManager.frozenLocations.values, circleManager.activeCircle?.id),"))
    }

    func testTheFrozenMarkerIsGreyAndSaysSo() {
        let colour = MemberPalette.colors[1]
        let frozen = MemberMarkerView.appearance(displayName: "Ana Bell", ageMs: 60_000, fillColor: colour,
                                                 atPlaceName: "Home", isApproximate: false, sharingOff: true)
        XCTAssertEqual(frozen.caption, "Location sharing off", "not an age, nor At <Place>")
        XCTAssertEqual(frozen.fill, MemberPalette.stale)
        let live = MemberMarkerView.appearance(displayName: "Ana Bell", ageMs: 60_000, fillColor: colour,
                                               atPlaceName: nil, isApproximate: false)
        XCTAssertEqual(live.fill, colour)
        XCTAssertNotEqual(live.caption, frozen.caption)
    }

    /// Opened and published apart from the live rows, and never judged: not
    /// in `refreshedUserIds`, not the replay guard's, not place alerts'.
    func testTheFrozenRowsAreNeverJudged() throws {
        let manager = try source("App/Managers/CircleManager.swift")
        let load = try body(manager, from: "    func loadMemberLocations(for circleId: String, surfaceFailures: Bool = true)",
                            to: "    private func setupLocationSync() {")
        XCTAssertTrue(load.contains("""
                        switch Self.decodeRow(response, circleId: circleId, me: myUserId, crypto: crypto) {
                        case .live(var location, _):
                            location.sharingOff = true
                            frozen[location.userId] = location
                        case .history(let userId):
                            frozenStale.insert(userId)
                        case .mine, .nobody, .keyMissing, .unopened:
                            break
                        }
        """))
        XCTAssertTrue(load.contains("refreshedUserIds: Set(fresh.keys).union(decoded.heardFrom),"))
        XCTAssertFalse(load.contains("decoded.frozen.keys"))
        XCTAssertEqual(load.components(separatedBy: "accepted.append(").count - 1, 1, "live rows alone feed place alerts")
        XCTAssertTrue(load.contains("var frozenNow = frozenLocations.filter { _, loc in loc.circleId != circleId }"),
                      "replaced, never appended")
        let map = try source("App/Views/Map/MapLibreMapView.swift")
        XCTAssertTrue(map.contains("for loc in memberLocations where !loc.sharingOff {"), "no At <Place>, no hidden pin")
        XCTAssertTrue(map.contains("memberLocations.first(where: { $0.userId == alert.userId && !$0.sharingOff })"),
                      "no SOS merged into it")
    }

    /// Their card shows the frozen location's time and address under the
    /// sentence that says why; never "At <Place>", never a destination handed
    /// on; never for a pause.
    func testTheCardShowsTheFrozenLocationUnderTheSentence() throws {
        let frozen = MemberDetailSheet.PositionDetail.of(row("a", frozen: true))
        XCTAssertTrue(frozen.showsAddressAndCoordinates)
        XCTAssertFalse(frozen.offersShareAsDestination)
        XCTAssertTrue(frozen.offersCopyAddress)
        XCTAssertTrue(MemberDetailSheet.PositionDetail.of(row("a")).offersShareAsDestination, "control: live")
        XCTAssertEqual(MemberDetailSheet.cardDetents(hasLocation: true, hasAddress: true, hasSharingSentence: true),
                       [.height(360), .medium])
        XCTAssertEqual(MemberDetailSheet.cardDetents(hasLocation: true, hasAddress: false, hasSharingSentence: true),
                       [.height(320), .medium])
        let map = try source("App/Views/Map/MapView.swift")
        XCTAssertTrue(map.contains("""
                if let frozen = circleManager.frozenLocations[member.userId],
                   CanonicalId.sameKey(frozen.circleId, circleManager.activeCircle?.id), !pausedNow {
                    return frozen
                }
        """))
        XCTAssertTrue(map.contains("guard let location = location, !location.sharingOff else { return nil }"))
        XCTAssertTrue(map.contains("""
                                    .accessibilityIdentifier("member-sharing-status")
                            }
                            // Under the sentence, for real-time off:
                            // when the frozen last location was
                            // shared.
                            if let location = location {
        """))
        XCTAssertTrue(map.contains("} else if sharingSentence == nil {\n                        Text(\"No recent location\")"))
    }

    // MARK: - Inactivity

    func testInactivitySaysNothingAboutAMemberNotSharing() throws {
        let monitoring = try source("App/Managers/MonitoringManager.swift")
        XCTAssertTrue(monitoring.contains("""
                            let sharing = member.sharing(at: now)
                            if sharing != .on {
                                store.noteNotSharing(circleId: circleId, userId: member.userId, status: sharing, now: now)
                                continue
                            }
                            store.noteSharing(circleId: circleId, userId: member.userId, now: now)
                            // Tier 2 (per member): judge only members THIS refresh
        """))
        XCTAssertEqual(AlertEditorView.notWhileNotSharing,
                       "Doesn't go off while they've paused or turned off location sharing in this circle.")
        let editor = try source("App/Views/Alerts/AlertsView.swift")
        XCTAssertTrue(editor.contains("""
                        } footer: {
                            if watchesOthers {
                                Text(Self.notWhileNotSharing)
                            }
                        }
        """), "under the timeout, for a rule about others")
        XCTAssertTrue(editor.contains("if case .editInactivity(let rule) = mode { return !rule.isSelfAlert }"))
    }

    // MARK: - History off, seen by others

    func testHistoryOffIsReadFromTheRoster() throws {
        XCTAssertTrue(member("a").sharesHistory, "absent: an older server")
        XCTAssertTrue(member("a", history: "on").sharesHistory)
        XCTAssertFalse(member("a", history: "off").sharesHistory)
        let manager = try source("App/Managers/CircleManager.swift")
        XCTAssertTrue(manager.contains("                historySharing: response.historySharing\n"))
        let converters = try source("App/Services/APIService+Converters.swift")
        XCTAssertTrue(converters.contains("            historySharing: historySharing\n"))
    }

    /// The card says why there's no history in place of View History; the
    /// details screen says it; the sheet draws no trail of theirs.
    func testHistoryOffIsSaidAndNotDrawn() throws {
        let (a, b) = ("aaaaaaaa-0000-4000-8000-000000000001", "bbbbbbbb-0000-4000-8000-000000000002")
        let trails = [HistoryTrail(userId: a, points: []), HistoryTrail(userId: b.uppercased(), points: [])]
        XCTAssertEqual(MapView.trailsShown(trails, roster: [member(a), member(b, history: "off")]).map(\.userId), [a])
        XCTAssertEqual(MapView.trailsShown(trails, roster: []).count, 2)
        let map = try source("App/Views/Map/MapView.swift")
        XCTAssertTrue(map.contains("historyTrails: showingHistory ? Self.trailsShown(history.trails, roster: memberList) : [],"))
        XCTAssertTrue(map.contains("return live.sharesHistory ? nil : SharingStatusCopy.historyOffSentence(name: live.displayName)"))
        let card = try body(map, from: "                    if let historyOffSentence {", to: "                    } else {")
        XCTAssertFalse(card.contains("View History"))
        let details = try source("App/Views/Circles/MemberDetailView.swift")
        XCTAssertTrue(details.contains("Text(SharingStatusCopy.historyOffSentence(name: member.displayName))"))
    }

    // MARK: - Visibility only

    /// The history switch is about what the circle is shown, not what is
    /// captured: nothing this phone sends depends on it. A circle with
    /// history off still gets every live point and every late one.
    func testNothingSentDependsOnTheHistorySwitch() throws {
        func row(history: Bool, realtime: Bool = true, paused: Bool = false) -> PrivacySettings {
            var settings = PrivacySettings(circleId: circle, sharingMode: paused ? "paused" : "exact",
                                           shareRealtime: realtime, shareHistory: history, shareBattery: true,
                                           bubbleEnabled: false, bubbleRadius: 1, pausedUntil: nil, updatedAt: now)
            settings.allowAlertsOnMe = true
            return settings
        }
        let me = SelfKeyManager.selfCircleUuid
        XCTAssertEqual(CircleManager.uploadTargets(selfId: me, circleIds: [circle], privacy: [circle: row(history: false)]),
                       [me, circle], "history off: sent all the same")
        XCTAssertEqual(CircleManager.uploadTargets(selfId: me, circleIds: [circle], privacy: [circle: row(history: true)]),
                       [me, circle])
        XCTAssertEqual(CircleManager.uploadTargets(selfId: me, circleIds: [circle],
                                                   privacy: [circle: row(history: true, realtime: false)]), [me],
                       "control: real-time off is what stops a send")
        for path in ["App/Services/SDKLocationStreamer.swift", "App/Services/LocationService.swift",
                     "App/Services/CirclePauseRecord.swift", "App/Services/PendingCircleLocations.swift",
                     "App/Managers/CheckInManager.swift", "App/Managers/DestinationsManager.swift",
                     "App/Managers/PlaceManager.swift", "App/Managers/SOSManager.swift"] {
            let text = try source(path)
            for name in ["shareHistory", "sharesHistory", "historySharing", "historyOff"] {
                XCTAssertFalse(text.contains(name), "\(path) reads \(name)")
            }
        }
        let manager = try source("App/Managers/CircleManager.swift")
        let gate = try body(manager, from: "    nonisolated static func uploadTargets(",
                            to: "    private func syncLocation(")
        XCTAssertFalse(gate.contains("shareHistory"))
    }

    /// When the roster shows someone's history again, the open sheet reads it
    /// again: the server brings all of it back, the time it was off too.
    func testTheHistoryIsReadAgainWhenItIsShownAgain() throws {
        XCTAssertTrue(MapView.historyReturned(before: ["a", "b"], after: ["b"]))
        XCTAssertFalse(MapView.historyReturned(before: ["b"], after: ["a", "b"]), "one more off: no read needed")
        XCTAssertFalse(MapView.historyReturned(before: [], after: []))
        let map = try source("App/Views/Map/MapView.swift")
        XCTAssertTrue(map.contains("""
                    .onChange(of: historyOffMembers) { before, after in
                        if showingHistory, Self.historyReturned(before: before, after: after) {
                            Task { await history.refreshIfNeeded() }
                        }
                    }
        """))
    }

    // MARK: - What this phone keeps

    func testOnlyTheNewestPositionsAddressIsKept() async {
        let store = MemberAddressStore(reverse: { lat, _ in "near \(lat)" })
        let (a, b) = ("aaaaaaaa-0000-4000-8000-000000000001", "bbbbbbbb-0000-4000-8000-000000000002")
        for lat in [1.0, 2.0, 3.0] { await store.resolve(userId: a, latitude: lat, longitude: 4) }
        await store.resolve(userId: b, latitude: 1, longitude: 4)
        store.keepOnly(userId: a, keeping: (latitude: 3, longitude: 4))
        XCTAssertNil(store.address(userId: a, latitude: 1, longitude: 4))
        XCTAssertNil(store.address(userId: a, latitude: 2, longitude: 4))
        XCTAssertEqual(store.address(userId: a, latitude: 3, longitude: 4), "near 3.0")
        XCTAssertEqual(store.address(userId: b, latitude: 1, longitude: 4), "near 1.0", "nobody else's")
        store.keepOnly(userId: a, keeping: nil)
        XCTAssertNil(store.address(userId: a, latitude: 3, longitude: 4), "drawn nowhere: none")
    }

    func testAForgottenAreaStartsAgain() {
        var memory = ApproximateAreaMemory()
        var wide = row("a")
        wide.approximate = ApproximateArea(sharingMode: "approximate", radiusMiles: 5)
        _ = memory.draw(wide, circleId: circle, userId: "a")
        var narrow = row("a")
        narrow.approximate = ApproximateArea(sharingMode: "approximate", radiusMiles: 1)
        XCTAssertEqual(memory.draw(narrow, circleId: circle, userId: "a").approximate?.drawnMiles, 6.25,
                       "never smaller while remembered")
        memory.forget(circleId: circle, userId: "a")
        XCTAssertEqual(memory.draw(narrow, circleId: circle, userId: "a").approximate?.drawnMiles, 1.25)
    }

    /// Levelled on EVERY roster read, so an update also clears what an older
    /// build kept.
    func testThePurgeRunsOnEveryRoster() throws {
        let manager = try source("App/Managers/CircleManager.swift")
        XCTAssertTrue(manager.contains("""
                frozenLocations = frozenLocations.filter { _, loc in
                    loc.circleId != circleId || shown.contains(loc.userId)
                }
                purgeForSharing(circleId: circleId)
        """))
        let purge = try body(manager, from: "    private func purgeForSharing(circleId: String, now: Date = Date()) {",
                             to: "    /// Drop a circle from local state")
        XCTAssertTrue(purge.contains("where !member.sharesHistory && !CanonicalId.same(member.userId, me) {"))
        XCTAssertTrue(purge.contains("let drawnNowhere = member.sharing(at: now) == .off"))
        XCTAssertTrue(purge.contains("if locations[member.userId]?.circleId == circleId { locations.removeValue(forKey: member.userId) }"))
        XCTAssertTrue(purge.contains("approximateAreas.forget(circleId: circleId, userId: member.userId)"))
        XCTAssertTrue(purge.contains("MemberAddressStore.shared.keepOnly(userId: member.userId,"))
        // A viewer's history comes only from the server's read.
        let history = try source("App/Views/Map/HistoryView.swift")
        XCTAssertEqual(history.components(separatedBy: "self.api.getLocationHistory(").count - 1, 1)
        XCTAssertFalse(history.contains("CacheStore"))
    }

    // MARK: - The words

    func testTheOwnScreenSaysBothSwitches() {
        XCTAssertNil(SharingStatusCopy.ownSentence(.on, now: now))
        XCTAssertEqual(SharingStatusCopy.ownSentence(.on, historyOn: false, now: now),
                       "Location history is off in this circle. Members see only where you are now. "
                       + "Track still keeps your history, and they'll see all of it if you turn it back on.")
        XCTAssertEqual(SharingStatusCopy.ownSentence(.off, now: now),
                       "Location sharing is off in this circle. Members see your history up to then and may still see the last location you shared, with “Location sharing off” next to your name.")
        XCTAssertEqual(SharingStatusCopy.ownSentence(.off, historyOn: false, now: now),
                       "Location sharing and location history are off in this circle. Members see “Location sharing off” next to your name, and none of your locations.")
        XCTAssertEqual(SharingStatusCopy.ownSentence(.paused(until: nil), historyOn: false, now: now),
                       "Paused. Members see this next to your name.", "a pause says the pause")
        XCTAssertEqual(SharingStatusCopy.historyOffSentence(name: "Ana"),
                       "Ana doesn't share their location history in this circle.")
    }

    func testTheSwitchesSayWhatTheyDo() throws {
        XCTAssertEqual(PrivacySettingsSheet.realtimeTitle, "Share real-time location")
        XCTAssertEqual(PrivacySettingsSheet.realtimeDetail,
                       "When it's off, Track stops sending this circle your location. "
                       + "Members may still see the last location you shared, unless location history is off too.")
        XCTAssertEqual(PrivacySettingsSheet.historyTitle, "Share location history")
        XCTAssertEqual(PrivacySettingsSheet.historyDetail,
                       "When it's off, members see only where you are now. Track still keeps your history, "
                       + "and turning it back on shows them all of it, including the time it was off.")
        let circles = try source("App/Views/Circles/CirclesView.swift")
        XCTAssertTrue(circles.contains("""
                            Toggle(isOn: $settings.shareRealtime) {
                                Text(Self.realtimeTitle)
                                Text(Self.realtimeDetail)
                            }
                            Toggle(isOn: $settings.shareHistory) {
                                Text(Self.historyTitle)
                                Text(Self.historyDetail)
                            }
        """))
        XCTAssertFalse(circles.contains("Share Real-time Location"))
        XCTAssertFalse(circles.contains("Share Location History"))
        XCTAssertEqual(circles.components(separatedBy: "SharingStatusCopy.ownSentence(ownSharing, historyOn: ownHistoryOn)").count - 1, 2)
    }
}
