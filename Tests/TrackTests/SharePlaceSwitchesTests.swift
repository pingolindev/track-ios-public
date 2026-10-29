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

import SwiftUI
import XCTest
@testable import Track

/// "Share Place" switches show the server's `shared_circles`, with this phone's
/// own shares and unshares recorded as soon as they are taken. Switches that
/// showed every circle OFF, even right after sharing, would tell anyone
/// checking who can see a place that nobody could while a whole circle could,
/// and stopping a share would take a share then an unshare.
@MainActor
final class SharePlaceSwitchesTests: XCTestCase {
    private let family = "e0000000-0000-4000-8000-0000000000c1"
    private let work = "e0000000-0000-4000-8000-0000000000c2"

    private func place(id: String = "p1", circleId: String = SelfKeyManager.selfCircleUuid,
                       shared: [String]? = nil) -> Place {
        Place(id: id, circleId: circleId, name: "Park", latitude: 37.3349, longitude: -122.009, radius: 300,
              placeType: "place", boundaryRadius: nil, alertsEnabled: false, icon: .custom, color: "#3B82F6",
              createdAt: Date(timeIntervalSince1970: 0), address: nil, notes: nil, wrappedKey: nil,
              wrappedKeyNonce: nil, wrapTargetId: SelfKeyManager.selfCircleUuid, sharedCircles: shared)
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// A switch is on for a circle the place is shared with, in any spelling
    /// of its id, and off for the others. The server omits an empty list. A
    /// place made in a circle is that circle's, on and locked.
    func testTheSwitchesShowWhoCanSeeThePlace() {
        let shared = place(shared: [family.uppercased()])
        XCTAssertTrue(SharePlaceSheet.isShared(shared, with: family))
        XCTAssertFalse(SharePlaceSheet.isShared(shared, with: work))
        XCTAssertFalse(SharePlaceSheet.belongs(shared, to: family), "a personal place belongs to no circle")
        XCTAssertFalse(SharePlaceSheet.isShared(place(), with: family), "omitted: shared nowhere")
        XCTAssertFalse(SharePlaceSheet.isShared(place(shared: []), with: family))

        let circlePlace = place(circleId: work)
        XCTAssertTrue(SharePlaceSheet.isShared(circlePlace, with: work))
        XCTAssertTrue(SharePlaceSheet.belongs(circlePlace, to: work))
        XCTAssertFalse(SharePlaceSheet.belongs(circlePlace, to: family))
        XCTAssertFalse(SharePlaceSheet.isShared(circlePlace, with: family))
    }

    /// A share or unshare taken is recorded on the place at once, once, in any
    /// spelling; the last unshare leaves no list, as the server sends none; any
    /// other place is left as it was.
    func testAShareTakenIsRecordedOnThePlaceAtOnce() {
        let shared = PlaceManager.recordingShare(place(), placeId: "p1", circleId: family, shared: true)
        XCTAssertEqual(shared.sharedCircles, [family])
        let again = PlaceManager.recordingShare(shared, placeId: "p1", circleId: family.uppercased(), shared: true)
        XCTAssertEqual(again.sharedCircles?.count, 1, "never twice")
        let both = PlaceManager.recordingShare(shared, placeId: "p1", circleId: work, shared: true)
        XCTAssertEqual(Set(both.sharedCircles ?? []), [family, work])
        let unshared = PlaceManager.recordingShare(both, placeId: "p1", circleId: family.uppercased(), shared: false)
        XCTAssertEqual(unshared.sharedCircles, [work])
        XCTAssertNil(PlaceManager.recordingShare(unshared, placeId: "p1", circleId: work, shared: false).sharedCircles)
        XCTAssertNil(PlaceManager.recordingShare(place(id: "p2"), placeId: "p1", circleId: family,
                                                 shared: true).sharedCircles, "another place")
        XCTAssertFalse(SharePlaceSheet.isShared(unshared, with: family))
        XCTAssertTrue(SharePlaceSheet.isShared(unshared, with: work))
    }

    /// Only what the server took is recorded: after the share's and the
    /// unshare's request, never for a share left waiting. The sheet's
    /// switches read the place as recorded and are named with the circle.
    func testOnlyWhatTheServerTookIsRecordedAndTheSwitchesShowIt() throws {
        let manager = try source("App/Managers/PlaceManager.swift")
        let share = try XCTUnwrap(manager.range(of: "    func sharePlaceWithCircle("))
        let queued = try XCTUnwrap(manager.range(of: "            try PendingChanges.queue(.sharePlace", range: share.upperBound..<manager.endIndex))
        let sent = try XCTUnwrap(manager.range(of: "        _ = try await api.sharePlace(", range: share.upperBound..<manager.endIndex))
        let recorded = try XCTUnwrap(manager.range(of: "        recordShare(placeId: placeId, circleId: circleId, shared: true)\n"))
        XCTAssertLessThan(queued.lowerBound, sent.lowerBound)
        XCTAssertLessThan(sent.lowerBound, recorded.lowerBound, "recorded once taken")
        XCTAssertTrue(manager.contains("""
                    _ = try await api.unsharePlace(placeId: placeId, circleId: circleId)
                    recordShare(placeId: placeId, circleId: circleId, shared: false)
            """))

        let view = try source("App/Views/Places/PlacesView.swift")
        XCTAssertTrue(view.contains("    private var current: Place { placeManager.monitoredPlace(for: place.id) ?? place }\n"))
        XCTAssertTrue(view.contains("                                isShared: Self.isShared(current, with: circle.id),\n"))
        XCTAssertTrue(view.contains("                                isOwnCircle: Self.belongs(current, to: circle.id),\n"))
        XCTAssertTrue(view.contains("            Toggle(circle.name, isOn: Binding(get: { isShared }, set: onToggle))\n"))
        XCTAssertFalse(view.contains("@State private var isOn: Bool = false"), "a switch of its own, starting off")
    }

    /// A share or unshare taken here stands over a list that doesn't show it
    /// yet (from a lagging replica, or the cache), until a list shows it, or
    /// for `takenShareHold` at most; then the list is the truth again.
    func testATakenShareStandsOverAListThatDoesntShowItYet() {
        let now = Date()
        let taken = [PlaceManager.TakenShare(placeId: "p1", circleId: family, shared: true, at: now.addingTimeInterval(-5))]
        let older = PlaceManager.keepingTakenShares([place()], taken, now: now)
        XCTAssertEqual(older.places.first?.sharedCircles, [family])
        XCTAssertEqual(older.stillTaken, taken, "kept until a list shows it")
        let caughtUp = PlaceManager.keepingTakenShares([place(shared: [family.uppercased()])], taken, now: now)
        XCTAssertEqual(caughtUp.places.first?.sharedCircles, [family.uppercased()])
        XCTAssertTrue(caughtUp.stillTaken.isEmpty, "a list that shows it, in any spelling")
        let late = PlaceManager.keepingTakenShares([place()], taken,
                                                   now: now.addingTimeInterval(PlaceManager.takenShareHold))
        XCTAssertNil(late.places.first?.sharedCircles, "past the hold, the list")
        XCTAssertTrue(late.stillTaken.isEmpty)
        let unshare = [PlaceManager.TakenShare(placeId: "p1", circleId: family, shared: false, at: now)]
        XCTAssertEqual(PlaceManager.keepingTakenShares([place(shared: [family, work])], unshare, now: now)
            .places.first?.sharedCircles, [work], "an unshare taken here stands too")
        XCTAssertTrue(PlaceManager.keepingTakenShares([place(id: "p2")], taken, now: now).stillTaken.isEmpty,
                      "a place no longer listed")

        let manager = try? source("App/Managers/PlaceManager.swift")
        XCTAssertEqual(manager?.contains("""
                    let listed = Self.keepingTakenShares(Self.withoutDuplicateIds(decoded), takenShares, now: Date())
                    takenShares = listed.stillTaken
                    let unique = listed.places
                    monitoredPlaces = unique
            """), true, "every list, live or cached, after its decode")
        XCTAssertEqual(manager?.contains(
            "        takenShares.append(TakenShare(placeId: placeId, circleId: circleId, shared: shared, at: Date()))\n"),
                       true)
        XCTAssertEqual(manager?.contains("        monitoredPlaces = []\n        takenShares = []\n"), true, "a sign-out")
    }

    /// A share kept waiting for this iPhone to catch up shows on its row as
    /// waiting, never plainly on or off; it is listed above with Cancel.
    func testAShareKeptWaitingShowsAsWaiting() throws {
        let share = PendingChanges.make(.sharePlace, account: "e0000000-0000-4000-8000-000000000001", circleId: family,
                                        inputs: .sharePlace(placeId: "p1"), circleName: "Family", subject: "Park")
        XCTAssertTrue(SharePlaceSheet.shareWaits([share], place: "p1", circle: family.uppercased()))
        XCTAssertFalse(SharePlaceSheet.shareWaits([share], place: "p1", circle: work))
        XCTAssertFalse(SharePlaceSheet.shareWaits([share], place: "p2", circle: family))

        let circle = Circle(id: family, name: "Family", isOwner: false, keyRotationNeeded: false, keyVersion: 1)
        let row = ShareCircleRow(circle: circle, isShared: false, isOwnCircle: false, isPending: false,
                                 isWaiting: true) { _ in }
        let spoken = try spokenElements(of: List { row })
        XCTAssertTrue(spoken.contains { $0.label.contains("Family") && $0.label.contains(PendingChangeCopy.tag) },
                      "spoken: \(spoken)")
        XCTAssertFalse(spoken.contains { $0.label == "Family" && !($0.value ?? "").isEmpty }, "no switch while it waits")
        let view = try source("App/Views/Places/PlacesView.swift")
        XCTAssertTrue(view.contains(
            "                                isWaiting: Self.shareWaits(waiting.changes, place: place.id, circle: circle.id)\n"))
    }

    /// VoiceOver hears which circle each switch is for (not an unnamed
    /// switch beside the circle's name), whether it is on, and that the switch
    /// of the circle a place belongs to can't be changed.
    func testEachSwitchIsNamedWithItsCircle() throws {
        let circle = Circle(id: family, name: "Family", isOwner: false, keyRotationNeeded: false, keyVersion: 1)
        for (on, locked) in [(true, false), (false, false), (true, true)] {
            let row = ShareCircleRow(circle: circle, isShared: on, isOwnCircle: locked, isPending: false) { _ in }
            let spoken = try spokenElements(of: List { row })
            let named = spoken.first { $0.label == "Family" && !($0.value ?? "").isEmpty }
            let theSwitch = try XCTUnwrap(named, "the switch itself is named, on: \(on), spoken: \(spoken)")
            XCTAssertEqual(theSwitch.traits.contains(.notEnabled), locked, "locked: \(locked)")
        }
        let view = try source("App/Views/Places/PlacesView.swift")
        XCTAssertTrue(view.contains("                .disabled(isOwnCircle)\n"))
    }

    // SwiftUI builds its accessibility tree only while an assistive technology
    // is on: the switch RuleEmailSwitchTests borrows, here keeping each
    // element's value too, which only a switch has.
    private typealias Spoken = (label: String, value: String?, traits: UIAccessibilityTraits)

    private func spokenElements(of view: some View) throws -> [Spoken] {
        typealias Getter = @convention(c) () -> Bool
        typealias Setter = @convention(c) (Bool) -> Void
        guard let lib = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW),
              let getter = dlsym(lib, "_AXSApplicationAccessibilityEnabled"),
              let setter = dlsym(lib, "_AXSApplicationAccessibilitySetEnabled") else {
            throw XCTSkip("this simulator runtime has no application accessibility switch")
        }
        let get = unsafeBitCast(getter, to: Getter.self)
        let set = unsafeBitCast(setter, to: Setter.self)
        let was = get()
        set(true)
        defer { set(was) }
        let host = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        var found: [Spoken] = []
        collect(host.view, into: &found, depth: 0)
        window.isHidden = true
        return found
    }

    private func collect(_ object: NSObject, into found: inout [Spoken], depth: Int) {
        guard depth < 30 else { return }
        if object.isAccessibilityElement, let label = object.accessibilityLabel, !label.isEmpty {
            found.append((label, object.accessibilityValue, object.accessibilityTraits))
        }
        if let elements = object.accessibilityElements as? [NSObject] {
            for element in elements { collect(element, into: &found, depth: depth + 1) }
        } else {
            let count = object.accessibilityElementCount()
            if count != NSNotFound, count > 0 {
                for index in 0..<count {
                    if let element = object.accessibilityElement(at: index) as? NSObject {
                        collect(element, into: &found, depth: depth + 1)
                    }
                }
            }
        }
        if let view = object as? UIView {
            for subview in view.subviews { collect(subview, into: &found, depth: depth + 1) }
        }
    }
}
