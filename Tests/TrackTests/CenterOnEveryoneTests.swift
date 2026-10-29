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

import CoreLocation
import UIKit
import XCTest
@testable import Track

/// "Center on everyone" shows every member, and never zooms in closer than the "my location" zoom. Centring
/// on the group's middle at that zoom is not enough: zoom 14 shows about 1.5 km across a phone, so two
/// members 2.2 km apart would both be off screen.
///
/// Each case is checked as the map would show it: every member put on a 390 x 844 point phone (Web Mercator,
/// MapLibre's 512-point world at zoom 0), inside the room the fit leaves (`fitPadding`).
@MainActor
final class CenterOnEveryoneTests: XCTestCase {

    private let phone = CGSize(width: 390, height: 844)
    private let applePark = CLLocationCoordinate2D(latitude: 37.3349, longitude: -122.0090)

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

    /// Where `coordinate` lands, in points from the phone's top left, with the map centred on `center` at `zoom`; the
    /// centre lands at `at`, the phone's middle unless a content inset moves it.
    private func onScreen(_ coordinate: CLLocationCoordinate2D, center: CLLocationCoordinate2D, zoom: Double,
                          at: CGPoint? = nil) -> CGPoint {
        let world = 512 * pow(2, zoom)
        func mercator(_ c: CLLocationCoordinate2D) -> (x: Double, y: Double) {
            let s = sin(c.latitude * .pi / 180)
            return ((c.longitude + 180) / 360 * world, (0.5 - log((1 + s) / (1 - s)) / (4 * .pi)) * world)
        }
        let p = mercator(coordinate), c = mercator(center)
        let middle = at ?? CGPoint(x: phone.width / 2, y: phone.height / 2)
        return CGPoint(x: Double(middle.x) + p.x - c.x, y: Double(middle.y) + p.y - c.y)
    }

    private func framing(_ members: [CLLocationCoordinate2D]) throws -> (center: CLLocationCoordinate2D, zoom: Double) {
        try XCTUnwrap(MapLibreMapView.framing(members, in: phone, padding: MapLibreMapView.fitPadding,
                                              maxZoom: MapLibreMapView.selfLocationZoom))
    }

    /// Every one of `members` inside the padded room, at no closer than the recenter zoom.
    private func assertAllShown(_ members: [CLLocationCoordinate2D], by framing: (center: CLLocationCoordinate2D, zoom: Double),
                                file: StaticString = #filePath, line: UInt = #line) {
        let pad = MapLibreMapView.fitPadding
        let room = CGRect(x: pad.left, y: pad.top, width: phone.width - pad.left - pad.right,
                          height: phone.height - pad.top - pad.bottom).insetBy(dx: -0.5, dy: -0.5)
        for member in members {
            let point = onScreen(member, center: framing.center, zoom: framing.zoom)
            XCTAssertTrue(room.contains(point), "\(member.latitude), \(member.longitude) lands at \(point)", file: file, line: line)
        }
        XCTAssertLessThanOrEqual(framing.zoom, MapLibreMapView.selfLocationZoom, file: file, line: line)
    }

    /// `meters` east of `coordinate`.
    private func east(of coordinate: CLLocationCoordinate2D, _ meters: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: coordinate.latitude,
                               longitude: coordinate.longitude + meters / (111_320 * cos(coordinate.latitude * .pi / 180)))
    }

    /// Two members 100 m apart: both shown, at the recenter zoom rather than zoomed in on.
    func testACloseGroupIsHeldAtTheRecenterZoom() throws {
        let members = [applePark, east(of: applePark, 100)]
        let framed = try framing(members)
        assertAllShown(members, by: framed)
        XCTAssertEqual(framed.zoom, MapLibreMapView.selfLocationZoom)
    }

    /// Two members 2.2 km apart east to west: the recenter zoom at their middle would show neither; the fit shows
    /// both, and is no wider than it needs to be.
    func testTwoMembers2Point2KilometresApartAreBothShown() throws {
        let members = [applePark, east(of: applePark, 2_200)]
        let framed = try framing(members)
        assertAllShown(members, by: framed)
        XCTAssertLessThan(framed.zoom, MapLibreMapView.selfLocationZoom)
        let pad = MapLibreMapView.fitPadding
        let span = onScreen(members[1], center: framed.center, zoom: framed.zoom).x
            - onScreen(members[0], center: framed.center, zoom: framed.zoom).x
        XCTAssertEqual(Double(span), Double(phone.width - pad.left - pad.right), accuracy: 1, "fitted, not zoomed out further")
        // Their middle at the recenter zoom alone would leave both off screen.
        let middle = CLLocationCoordinate2D(latitude: applePark.latitude,
                                            longitude: (members[0].longitude + members[1].longitude) / 2)
        XCTAssertLessThan(onScreen(members[0], center: middle, zoom: MapLibreMapView.selfLocationZoom).x, 0)
        XCTAssertGreaterThan(onScreen(members[1], center: middle, zoom: MapLibreMapView.selfLocationZoom).x, phone.width)
    }

    /// A group spread north to south down the Peninsula, from San Francisco to Santa Cruz: every member shown,
    /// the height the tighter fit, so the padding's offset between top and bottom counts.
    func testASpreadGroupIsAllShown() throws {
        let members = [CLLocationCoordinate2D(latitude: 37.7793, longitude: -122.4193),   // San Francisco
                       CLLocationCoordinate2D(latitude: 37.4636, longitude: -122.4286),   // Half Moon Bay
                       applePark,
                       CLLocationCoordinate2D(latitude: 36.9741, longitude: -122.0308)]   // Santa Cruz
        let framed = try framing(members)
        assertAllShown(members, by: framed)
        XCTAssertLessThan(framed.zoom, 10)
        let north = onScreen(members[0], center: framed.center, zoom: framed.zoom).y
        let south = onScreen(members[3], center: framed.center, zoom: framed.zoom).y
        XCTAssertEqual(Double(north), Double(MapLibreMapView.fitPadding.top), accuracy: 1, "fitted top to bottom")
        XCTAssertEqual(Double(south), Double(phone.height - MapLibreMapView.fitPadding.bottom), accuracy: 1)
    }

    /// In the map's content area, where `setCenter` centres: the view less its content inset. The app's map has
    /// none; this is the case of one, the safe area that a map under a view controller gets (62 pt above and 34
    /// below on a 402 x 874 phone). A group fitted top to bottom then lands on the padded room's top and foot,
    /// 142 and 720. Framed in the whole view, its zoom would come from 674 pt of height instead of 578, and the
    /// southern member would land at 768, past the foot.
    func testANorthSouthGroupIsFittedInTheContentArea() throws {
        let screen = CGSize(width: 402, height: 874)
        let inset = UIEdgeInsets(top: 62, left: 0, bottom: 34, right: 0)
        let content = CGRect(origin: .zero, size: screen).inset(by: inset)
        let room = content.inset(by: MapLibreMapView.fitPadding)
        let members = [CLLocationCoordinate2D(latitude: 37.7793, longitude: -122.4193),   // San Francisco
                       CLLocationCoordinate2D(latitude: 37.4636, longitude: -122.4286),   // Half Moon Bay
                       applePark,
                       CLLocationCoordinate2D(latitude: 36.9741, longitude: -122.0308)]   // Santa Cruz
        let middle = CGPoint(x: content.midX, y: content.midY)
        let framed = try XCTUnwrap(MapLibreMapView.framing(members, in: content.size, padding: MapLibreMapView.fitPadding,
                                                           maxZoom: MapLibreMapView.selfLocationZoom))
        let north = onScreen(members[0], center: framed.center, zoom: framed.zoom, at: middle).y
        let south = onScreen(members[3], center: framed.center, zoom: framed.zoom, at: middle).y
        XCTAssertEqual(Double(north), Double(room.minY), accuracy: 1, "on the room's top, 142")
        XCTAssertEqual(Double(south), Double(room.maxY), accuracy: 1, "on the room's foot, 720")
        // The whole view: past the foot.
        let whole = try XCTUnwrap(MapLibreMapView.framing(members, in: screen, padding: MapLibreMapView.fitPadding,
                                                          maxZoom: MapLibreMapView.selfLocationZoom))
        XCTAssertEqual(Double(onScreen(members[3], center: whole.center, zoom: whole.zoom, at: middle).y), 768, accuracy: 1)
    }

    /// The button frames this way: every member, capped at the recenter zoom, with the fits' padding, in the
    /// map's content area (where `setCenter` centres); there is no 1.5 km rule.
    func testTheButtonFramesThisWay() throws {
        let map = try source("App/Views/Map/MapLibreMapView.swift")
        let fit = try body(map, from: "        func fitToAllAnnotations(animated: Bool, membersOnly: Bool = false) {",
                           to: "        init(parent: MapLibreMapView) {")
        XCTAssertTrue(fit.contains("""
                        guard let framing = MapLibreMapView.framing(
                            coords, in: mapView.bounds.inset(by: mapView.contentInset).size,
                            padding: MapLibreMapView.fitPadding, maxZoom: MapLibreMapView.selfLocationZoom
                        ) else { return }
                        mapView.setCenter(framing.center, zoomLevel: framing.zoom, animated: animated)
        """))
        XCTAssertFalse(fit.contains("maxMeters"))
    }
}
