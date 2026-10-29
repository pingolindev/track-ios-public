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

/// A circle a WHOLE circle list doesn't have is this account's no more: it was
/// removed from it, or it was deleted. `activeAfterLoad` keeps an active circle
/// that isn't listed ("leaving and deleting move it on themselves"), so without
/// a prune it would stay the map's circle, with its members' last places, until
/// sign-out — a privacy case as much as a display one. Such a circle goes as on
/// a confirmed refusal, and what is open of it closes. Only on a whole list the
/// server gives now: never on one with more pages, nor on the saved copy.
final class UnlistedCircleIsPrunedTests: XCTestCase {

    private let a = "8b96aa7c-0000-4000-8000-0000000000a1"
    private let b = "8b96aa7c-0000-4000-8000-0000000000b2"
    private let c = "8b96aa7c-0000-4000-8000-0000000000c3"

    private func listed(_ ids: String...) -> Set<String> { Set(ids.map(CanonicalId.key)) }

    func testAWholeListWithoutACircleTheLastOneHadPrunesIt() {
        XCTAssertEqual(CircleManager.circlesGone(before: [a, b, c], listed: listed(a, c), whole: true, now: true), [b])
        XCTAssertEqual(CircleManager.circlesGone(before: [a, b], listed: listed(a, b, c), whole: true, now: true), [],
                       "a circle joined since is no reason")
        XCTAssertEqual(CircleManager.circlesGone(before: [a, b], listed: [], whole: true, now: true), [a, b],
                       "removed from every one")
    }

    /// A list with more pages (a reorder between page reads can skip a
    /// circle) and the saved copy (it says nothing of now) prune nothing,
    /// whatever they lack.
    func testAPagedOrSavedListPrunesNothing() {
        XCTAssertEqual(CircleManager.circlesGone(before: [a, b, c], listed: listed(a), whole: false, now: true), [],
                       "more pages")
        XCTAssertEqual(CircleManager.circlesGone(before: [a, b, c], listed: listed(a), whole: true, now: false), [],
                       "the saved copy")
        XCTAssertEqual(CircleManager.circlesGone(before: [a, b, c], listed: [], whole: false, now: false), [])
    }

    /// By the ids' one form: a circle still listed in another spelling stays.
    func testAnySpelling() {
        XCTAssertEqual(CircleManager.circlesGone(before: [a.uppercased()], listed: listed(a), whole: true, now: true), [])
        XCTAssertEqual(CircleManager.circlesGone(before: [b.uppercased()], listed: listed(a), whole: true, now: true),
                       [b.uppercased()], "pruned as it was held")
    }

    /// The personal history's slot is no circle, and no list has it.
    func testThePersonalSlotIsNoCircle() {
        XCTAssertEqual(CircleManager.circlesGone(before: [SelfKeyManager.selfCircleUuid, b], listed: [],
                                                 whole: true, now: true), [b])
    }

    // MARK: - The wiring

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// Judged against what the LAST LIST had, not what is held: a circle made
    /// here after a list was read is missing from it and is no gone circle.
    /// Pruned at the end of every load, and only then is this list the last
    /// one: a load that throws before its end (the keychain's refusal before
    /// the first unlock) leaves the last list as it was, so the next load
    /// still prunes what this one lacked.
    func testEveryLoadPrunesWhatTheLastListHadAndAWholeOneLacks() throws {
        let manager = try source("App/Managers/CircleManager.swift")
        XCTAssertTrue(manager.contains("""
                for circleId in Self.circlesGone(before: circlesOfLastList, listed: Set(responses.map { CanonicalId.key($0.id) }),
                                                 whole: listedWhole, now: listedNow) {
                    pruneGoneCircle(circleId)
                }
        """))
        XCTAssertEqual(manager.components(separatedBy: "circlesOfLastList = fetchedCircles.map(\\.id)").count - 1, 1)
        let load = try XCTUnwrap(manager.range(of: "    func loadCircles(light: Bool = false) async throws {\n"))
        let keychain = try XCTUnwrap(manager.range(of: "try keychain.saveCircleKey(encryptedKey, for: response.id)",
                                                   range: load.upperBound..<manager.endIndex))
        let prune = try XCTUnwrap(manager.range(of: "for circleId in Self.circlesGone(before: circlesOfLastList,",
                                                range: load.upperBound..<manager.endIndex))
        let noted = try XCTUnwrap(manager.range(of: "circlesOfLastList = fetchedCircles.map(\\.id)",
                                                range: load.upperBound..<manager.endIndex))
        XCTAssertLessThan(keychain.lowerBound, prune.lowerBound)
        XCTAssertLessThan(prune.lowerBound, noted.lowerBound, "noted after the prune, never before a throw")
        XCTAssertTrue(manager.contains("""
                circleListWhole = false
                circlesOfLastList = []
        """), "a sign-out forgets it")
    }

    /// Gone by the server's word, a WHOLE list or a refusal one confirms: what
    /// is open of it is told first, then it goes with what was kept for it.
    func testAGoneCircleIsAnnouncedThenPruned() throws {
        let manager = try source("App/Managers/CircleManager.swift")
        XCTAssertTrue(manager.contains("""
                circleGone.send(circleId)
                pruneLocalCircle(circleId: circleId)
                PendingCircleLocations.shared.discard(circleId: circleId)
        """))
        XCTAssertEqual(manager.components(separatedBy: "pruneGoneCircle(circleId)").count - 1, 2,
                       "a whole list and a confirmed refusal")
        XCTAssertEqual(manager.components(separatedBy: "circleGone.send(").count - 1, 1, "never on a leave")
    }

    /// The circle's own screen closes, wherever it is shown; on the map, the
    /// member's card and the history close when it was the map's circle.
    func testWhatIsOpenOfItCloses() throws {
        let circles = try source("App/Views/Circles/CirclesView.swift")
        XCTAssertTrue(circles.contains("""
                .onReceive(circleManager.circleGone) { gone in
                    if CanonicalId.sameKey(gone, circle.id) { dismiss() }
                }
        """))
        let map = try source("App/Views/Map/MapView.swift")
        XCTAssertTrue(map.contains("""
                    .onReceive(circleManager.circleGone) { gone in
                        var closed = false
                        if mapTapState.showingPlaceDetail, let place = mapTapState.selectedPlace,
                           CanonicalId.sameKey(place.circleId, gone) {
                            mapTapState.showingPlaceDetail = false
                            closed = true
                        }
                        if mapTapState.showingSOSDetail, let alert = mapTapState.selectedSOS,
                           CanonicalId.sameKey(alert.circleId, gone) {
                            mapTapState.showingSOSDetail = false
                            closed = true
                        }
                        if showingDestinationsList || showingDestinations,
                           destinationsManager.destinations.contains(where: { CanonicalId.sameKey($0.circleId, gone) }) {
                            showingDestinationsList = false
                            showingDestinations = false
                            closed = true
                        }
                        if showingCheckIn, CanonicalId.sameKey(gone, checkInCircleId) {
                            showingCheckIn = false
                            closed = true
                        }
                        if CanonicalId.sameKey(gone, circleManager.activeCircle?.id),
                           mapTapState.showingMemberDetail || showingHistory {
                            mapTapState.showingMemberDetail = false
                            showingHistory = false
                            closed = true
                        }
                        if closed { showSendToast("This circle isn't on this device any more.", afterDismissal: true) }
                    }
        """), "its place, alert and destinations sheets and a check-in opened for it; the card and history when it was the map's; and why")
    }

    /// A check-in goes to the circle its sheet opened for, or nowhere, never to
    /// the circle the map shows when it is sent: after a prune that is the next
    /// circle. The sheet also closes on the prune.
    func testACheckInGoesToTheCircleItOpenedFor() throws {
        let map = try source("App/Views/Map/MapView.swift")
        XCTAssertTrue(map.contains(
            "checkInCircleId = circleManager.activeCircle?.id; showingCheckIn = true })"), "taken when tapped")
        XCTAssertTrue(map.contains("                QuickCheckInSheet(circleId: checkInCircleId)\n"))
        let sheet = try XCTUnwrap(map.range(of: "struct QuickCheckInSheet: View {\n"))
        let send = try XCTUnwrap(map.range(of: "    private func sendCheckIn(_ type: CheckIn.CheckInType) {\n",
                                           range: sheet.upperBound..<map.endIndex))
        let end = try XCTUnwrap(map.range(of: "\n    }\n", range: send.upperBound..<map.endIndex))
        let body = String(map[send.upperBound..<end.lowerBound])
        XCTAssertTrue(body.hasPrefix("        guard let circleId else { return }\n"))
        XCTAssertFalse(body.contains("activeCircle"), "never the map's circle as it is when sent")
    }

    /// What closes says why in the circle screen's own words: no new copy.
    func testWhatClosesSaysWhyInTheCircleScreensWords() throws {
        let claim = try source("App/Views/Circles/OwnershipClaimViews.swift")
        XCTAssertTrue(claim.contains("Text(\"This circle isn't on this device any more.\")"))
        let map = try source("App/Views/Map/MapView.swift")
        XCTAssertEqual(map.components(separatedBy: "showSendToast(\"This circle isn't on this device any more.\", afterDismissal: true)").count - 1, 1)
    }

    /// Its members' alerts and destinations are drawn across circles, so they
    /// go with it at once, and the destinations' saved copy too, or a refresh
    /// that failed would bring them back.
    func testItsAlertsAndDestinationsGoWithIt() throws {
        let items = [(a, 1), (b, 2), (a.uppercased(), 3), (c, 4)]
        XCTAssertEqual(items.withoutCircle(a) { $0.0 }.map { $0.1 }, [2, 4], "every other circle's, any spelling")
        XCTAssertEqual(items.withoutCircle(SelfKeyManager.selfCircleUuid) { $0.0 }.count, 4)
        let manager = try source("App/Managers/CircleManager.swift")
        XCTAssertTrue(manager.contains("""
                PendingCircleLocations.shared.discard(circleId: circleId)
                // Its alerts and destinations are drawn across circles: they go too.
                SOSManager.shared.forgetCircle(circleId)
                Task { await DestinationsManager.shared.forgetCircle(circleId) }
        """))
        let sos = try source("App/Managers/SOSManager.swift")
        XCTAssertTrue(sos.contains("""
                let kept = activeAlerts.withoutCircle(circleId) { $0.circleId }
                if kept.count != activeAlerts.count { activeAlerts = kept }
        """))
        let destinations = try source("App/Managers/DestinationsManager.swift")
        XCTAssertTrue(destinations.contains("""
                let kept = destinations.withoutCircle(circleId) { $0.circleId }
                if kept.count != destinations.count { destinations = kept }
                if let saved: [DestinationResponse] = await CacheStore.shared.load([DestinationResponse].self, forKey: Self.cacheKey) {
                    let keptRows = saved.withoutCircle(circleId) { $0.circleId }
                    if keptRows.count != saved.count { await CacheStore.shared.save(keptRows, forKey: Self.cacheKey) }
                }
        """))
        XCTAssertTrue(destinations.contains("        let cacheKey = Self.cacheKey\n"), "one saved copy")
    }
}
