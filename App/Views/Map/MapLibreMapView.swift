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
import MapLibre
import CoreLocation

/// SwiftUI wrapper around `MLNMapView` that renders the same Protomaps
/// Basemaps style the Android app uses, with the vector tiles fetched
/// one at a time from pmtiles.pingolin.com (`MapTileConfig`).
/// Annotations come in through the `memberLocations` / `places` /
/// `members` arrays; tap callbacks fire on the main actor.
///
/// Style flow: fetch `pmtiles.pingolin.com/styles/{light,dark}.json`,
/// rewrite the `protomaps` source (`rewriteProtomapsSource` drops the
/// archive's `url` and sets the server-driven `tiles` template), then
/// assign as JSON. Done at view-creation time and on every dark/light
/// toggle.
struct MapLibreMapView: UIViewRepresentable {

    /// Cold-start self-centering and the "my location" recenter button
    /// open at the same zoom, so app-open matches pressing recenter and
    /// the two can't drift apart. Mirrors the Android app's shared
    /// SELF_LOCATION_ZOOM. 14 rather than 15: 15 feels claustrophobic
    /// and makes the first recenter visibly zoom out.
    static let selfLocationZoom: Double = 14

    /// How close an alert's recorded position has to be to the raiser's live
    /// position for the two to be treated as the same spot.
    ///
    /// An SOS location is where the raiser's phone last sealed it (at the press,
    /// or a precise fix within its first ten minutes), never their live
    /// position, so it and the raiser's marker are the same thing only while
    /// they haven't moved. Within this distance the standalone SOS disc would
    /// just sit on top of their avatar, so it is dropped and the avatar carries
    /// the alert. Beyond it the disc is real information the avatar doesn't
    /// have, and it stays. Matches the Android app's
    /// `SOS_MERGE_DISTANCE_METERS`.
    static let sosMergeDistanceMeters: Double = 75

    /// The saved place a coordinate sits inside (smallest radius wins), or
    /// nil. Client-side member-at-place occupancy — the iOS analog of
    /// the Android app's `placeContaining`. Shared by the map's
    /// annotation sync and the member detail sheet so both agree.
    static func placeContaining(latitude: Double, longitude: Double, in places: [Place]) -> Place? {
        let here = CLLocation(latitude: latitude, longitude: longitude)
        return places
            .filter { $0.radius > 0 }
            .filter { here.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude)) <= $0.radius }
            .min(by: { $0.radius < $1.radius })
    }

    /// The saved place a member's marker says they are "At", or nil. Never for
    /// an approximate member: the centre of their area is not where they are,
    /// and a place worked out from it would be finer than what they share.
    static func placeOccupied(by loc: LocationData, in places: [Place]) -> Place? {
        guard loc.approximate == nil else { return nil }
        return placeContaining(latitude: loc.latitude, longitude: loc.longitude, in: places)
    }

    /// The radius of the area to draw round a member, in metres, or nil for a
    /// pin. Your own marker is this phone's own fix and is never an area.
    static func areaMeters(for loc: LocationData, isMe: Bool) -> Double? {
        isMe ? nil : loc.approximate?.drawnMeters
    }

    /// The member annotation's title, which MapLibre reads out for the marker:
    /// the name, and for an approximate member that it is an area.
    static func markerTitle(displayName: String, isApproximate: Bool) -> String {
        isApproximate ? "\(displayName), \(ApproximateLocationCopy.spoken)" : displayName
    }

    /// An SOS disc's caption: the position's label ("Last known location",
    /// "Location updated", an area's size, else "Sent from here") and the
    /// POSITION's age, never the alert's: a fix taken two hours before a raise
    /// is two hours old, whenever the raise was.
    static func sosCaption(_ alert: SOSAlert, now: Date) -> String {
        let label = SOSPositionText.mapLabel(alert.positionReading(now: now), areaMeters: alert.positionAreaMeters)
        let ageMs = Int64(now.timeIntervalSince(alert.positionTakenAt ?? alert.createdAt) * 1000)
        return "\(label) · \(MemberMarkerView.formatRelativeAge(ageMs: ageMs))"
    }

    /// What MapLibre reads out for an SOS disc: its label, with an area's size
    /// as an approximate member's is read with "approximate location".
    static func sosTitle(_ alert: SOSAlert, now: Date) -> String {
        let label = SOSPositionText.mapLabel(alert.positionReading(now: now), areaMeters: alert.positionAreaMeters)
        guard let within = alert.positionAreaMeters.map(SOSPositionText.within), within != label else { return label }
        return "\(label), \(within)"
    }

    /// What an SOS shown as an AREA carries at its centre in place of the disc
    /// (`SOSPositionText.areaLabel`); nil for a point, which keeps the disc.
    static func sosAreaLabel(_ alert: SOSAlert, now: Date) -> String? {
        alert.positionAreaMeters.map { SOSPositionText.areaLabel(alert.positionReading(now: now), areaMeters: $0, now: now) }
    }

    /// The map's clock: moves a member's age on to `nowMs`. True when what its
    /// marker shows changed (its caption, or its grey past 15 minutes), i.e.
    /// when a view on the map has to be drawn again.
    static func moveAgeOn(_ member: MemberAnnotation, nowMs: Int64) -> Bool {
        let shownBefore = MemberMarkerView.appearance(of: member)
        member.ageMs = max(0, nowMs - member.fixTimeMs)
        return MemberMarkerView.appearance(of: member) != shownBefore
    }

    /// The map's clock for a fanned-out copy: it takes its member's age. True
    /// when what it shows changed.
    static func moveAgeOn(_ fan: FanMemberAnnotation, from member: MemberAnnotation) -> Bool {
        let shownBefore = MemberMarkerView.appearance(of: fan)
        fan.ageMs = member.ageMs
        fan.sharingOff = member.sharingOff
        return MemberMarkerView.appearance(of: fan) != shownBefore
    }

    /// The map's clock for an SOS disc: its caption's age moves on to `now`.
    /// True when the caption changed.
    static func moveCaptionOn(_ sos: SOSAnnotation, now: Date) -> Bool {
        guard let alert = sos.alert else { return false }
        let caption = sosCaption(alert, now: now)
        guard caption != sos.caption else { return false }
        sos.caption = caption
        sos.title = sosTitle(alert, now: now)
        return true
    }

    /// What showing an SOS on the map frames: an area whole, its centre and
    /// edges (as an approximate member is framed), never its centre
    /// at street zoom; nil for a point, which the fly-to centres.
    static func sosFraming(_ alert: SOSAlert) -> [CLLocationCoordinate2D]? {
        guard let coordinate = alert.coordinate, let meters = alert.positionAreaMeters else { return nil }
        return [coordinate] + ApproximateArea.extremes(center: coordinate, radiusMeters: meters)
    }

    /// What framing the camera round members has to take in: each avatar, and
    /// the edges of each approximate member's area.
    static func framingCoordinates(_ members: [MemberAnnotation]) -> [CLLocationCoordinate2D] {
        members.flatMap { member -> [CLLocationCoordinate2D] in
            guard let meters = member.approximateMeters else { return [member.coordinate] }
            return [member.coordinate] + ApproximateArea.extremes(center: member.coordinate, radiusMeters: meters)
        }
    }

    /// The room every fit leaves round what it frames: clear of the top
    /// controls and notices, and of the buttons along the bottom.
    static let fitPadding = UIEdgeInsets(top: 80, left: 40, bottom: 120, right: 40)

    /// The camera that shows every one of `coords` inside `size` less
    /// `padding`, never closer than `maxZoom`. The group is fitted rather than
    /// centred at the recenter zoom, which shows only about 1.5 km across a
    /// phone (two members 2.2 km apart would both be off screen); a close one
    /// is held at `maxZoom` rather than zoomed in on.
    ///
    /// Web Mercator, north up, as MapLibre draws it: the world is 512 points
    /// across at zoom 0, and twice that at each zoom up.
    nonisolated static func framing(
        _ coords: [CLLocationCoordinate2D], in size: CGSize, padding: UIEdgeInsets, maxZoom: Double
    ) -> (center: CLLocationCoordinate2D, zoom: Double)? {
        guard !coords.isEmpty else { return nil }
        // x from 0 at 180° W to 1 at 180° E; y from 0 at the north edge to 1 at the south.
        func x(_ longitude: Double) -> Double { (longitude + 180) / 360 }
        func y(_ latitude: Double) -> Double {
            let s = sin(min(max(latitude, -85.051_128_78), 85.051_128_78) * .pi / 180)
            return 0.5 - log((1 + s) / (1 - s)) / (4 * .pi)
        }
        let xs = coords.map { x($0.longitude) }
        let ys = coords.map { y($0.latitude) }
        let west = xs.min()!, east = xs.max()!, north = ys.min()!, south = ys.max()!
        let width = max(Double(size.width - padding.left - padding.right), 1)
        let height = max(Double(size.height - padding.top - padding.bottom), 1)
        var zoom = maxZoom
        if east > west { zoom = min(zoom, log2(width / ((east - west) * 512))) }
        if south > north { zoom = min(zoom, log2(height / ((south - north) * 512))) }
        // The group's middle goes to the middle of the padded room, which sits
        // (left - right) / 2 and (top - bottom) / 2 points off the view's.
        let world = 512 * pow(2, zoom)
        let cx = (west + east) / 2 + Double(padding.right - padding.left) / 2 / world
        let cy = (north + south) / 2 + Double(padding.bottom - padding.top) / 2 / world
        let latitude = atan(sinh((0.5 - cy) * 2 * .pi)) * 180 / .pi
        return (CLLocationCoordinate2D(latitude: latitude, longitude: cx * 360 - 180), zoom)
    }

    /// Marker label for a destination: its own name, else "<creator>'s
    /// destination" / "Your destination". Mirrors the Android app.
    static func destinationLabel(_ dest: Destination, currentUserId: String?, members: [CircleMember]) -> String {
        if let name = dest.name, !name.isEmpty { return name }
        if dest.isMine(currentUserId) { return "Your destination" }
        let who = members.first(where: { $0.userId == dest.userId })?.displayName ?? "A member"
        return "\(who)'s destination"
    }

    @Binding var recenterTrigger: Int
    @Binding var fitAllTrigger: Int
    @Binding var droppedPin: CLLocationCoordinate2D?
    /// Target the camera at the supplied coordinate when non-nil.
    /// Consumed (reset to nil) after one fly-to so subsequent map
    /// state changes don't re-fly. Wired by AddressSearch +
    /// Destinations.
    @Binding var flyToCoordinate: CLLocationCoordinate2D?
    /// Frame the camera round these points when non-nil, then clear it, as
    /// `flyToCoordinate`: an SOS shown as an area (`sosFraming`).
    @Binding var flyToFit: [CLLocationCoordinate2D]?
    var memberLocations: [LocationData]
    var places: [Place]
    var destinations: [Destination]
    var members: [CircleMember]
    /// Active SOS alerts to draw. Cross-circle by design — every other array
    /// here is scoped to the selected circle; this one is not.
    var sosAlerts: [SOSAlert]
    /// History to draw while the History sheet is up: one line per member,
    /// with a dot per fix. Empty otherwise.
    var historyTrails: [HistoryTrail] = []
    var isDarkMode: Bool
    var onPlaceTap: (Place) -> Void
    var onMapTap: (CLLocationCoordinate2D) -> Void

    func makeUIView(context: Context) -> MLNMapView {
        // Reuse the persistent MLNMapView across SwiftUI rebuilds /
        // tab switches. SwiftUI destroys the map view between
        // tab switches, so each return-to-Map would pay the full
        // cold-cache cost (about 4 s). Holding the instance in
        // MapViewHolder lets MapLibre's in-memory tile cache carry
        // over.
        if let existing = MapViewHolder.shared.mapView {
            existing.delegate = context.coordinator
            context.coordinator.mapView = existing
            // Sync the fresh Coordinator's lastIsDarkMode from the
            // holder so subsequent updateUIView() comparisons see
            // the actual applied state, not nil. Only re-apply the
            // style when the variant ACTUALLY changed.
            context.coordinator.lastIsDarkMode = MapViewHolder.shared.lastAppliedDarkMode
            if MapViewHolder.shared.lastAppliedDarkMode != isDarkMode {
                context.coordinator.applyStyle(isDarkMode: isDarkMode)
                MapViewHolder.shared.lastAppliedDarkMode = isDarkMode
            }
            // Reset the fully-rendered guard so the next firstFullyRendered
            // for this reused view is captured.
            context.coordinator.styleAssignStart = nil
            return existing
        }

        let mapView = MLNMapView(frame: .zero)
        mapView.delegate = context.coordinator
        mapView.logoView.isHidden = true
        // The attribution control STAYS VISIBLE. The basemap is OpenStreetMap
        // data, which is ODbL-licensed and requires the credit to be shown;
        // this button is what carries it. Hiding it without drawing an
        // equivalent credit elsewhere puts the app out of compliance.
        // The MapLibre logo above is a different thing — BSD-2-Clause asks for
        // attribution in the source, not on screen — so it may stay hidden.
        mapView.attributionButton.isHidden = false
        // Start with the stock MapLibre blue GPS dot suppressed.
        // syncAnnotations re-enables it only when the user has no
        // colored MemberAnnotation yet (initial decrypt, or solo with
        // no circle history) — once their member marker lands, the
        // dot stays off so we don't render two overlapping
        // self-markers. Mirrors the Android app.
        mapView.showsUserLocation = false
        mapView.userTrackingMode = .none
        mapView.compassView.isHidden = false

        // Single-tap on empty map → drop pin / reverse geocode. The
        // gesture is added directly to MLNMapView so it cooperates
        // with the built-in pan + zoom recognizers via require-fail.
        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleSingleTap(_:))
        )
        for recognizer in mapView.gestureRecognizers ?? [] where recognizer is UITapGestureRecognizer {
            tap.require(toFail: recognizer)
        }
        mapView.addGestureRecognizer(tap)

        // Seed the camera from the user's last-known position so a real cold start
        // opens centered on them (selfLocationZoom, matching the recenter button)
        // instead of the world default. The live fix refines this once
        // syncAnnotations sees the self marker. Tab returns use MapViewHolder's
        // held MLNMapView, so this only fires after process death. Mirrors the
        // Android app. Deliberately NOT an "open at last view" restore: the user's
        // own location is almost always a better starting frame than the previous
        // session's pan.
        if let seed = SelfLocationStore.load() {
            mapView.setCenter(
                CLLocationCoordinate2D(latitude: seed.latitude, longitude: seed.longitude),
                zoomLevel: MapLibreMapView.selfLocationZoom,
                animated: false
            )
            // Suppress syncAnnotations' first-time fitToAllAnnotations
            // so a late member-decryption emit doesn't reframe over
            // the self-centered view. The "snap to live self" path
            // below replaces it.
            context.coordinator.didAutoFit = true
            // The style assign below resets MapLibre's camera to the
            // style's `center`/`zoom` once it parses, so re-apply
            // the seed inside `didFinishLoading style:`.
            context.coordinator.pendingSelfSeed = seed
            // Cold-start refine: once the live self position lands
            // (CL fix or self marker), snap to it and persist.
            context.coordinator.coldStartSelfRefinePending = true
        } else {
            mapView.setCenter(
                CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
                zoomLevel: 11,
                animated: false
            )
            // First-ever launch with no self seed yet: still want to
            // recenter on the user as soon as we know where they are,
            // instead of flashing SF → fit-to-all-members.
            context.coordinator.coldStartSelfRefinePending = true
        }
        context.coordinator.mapView = mapView
        context.coordinator.applyStyle(isDarkMode: isDarkMode)
        MapViewHolder.shared.mapView = mapView
        MapViewHolder.shared.lastAppliedDarkMode = isDarkMode
        return mapView
    }

    func updateUIView(_ mapView: MLNMapView, context: Context) {
        // Refresh the Coordinator's parent reference so callbacks
        // (onMemberTap, onPlaceTap, onMapTap, flyToCoordinate
        // clearance) fire against the LIVE @State bindings instead
        // of a frozen snapshot from initial makeCoordinator().
        context.coordinator.parent = self
        // Point the fan-dismiss hook at the LIVE coordinator so a
        // control press in MapView collapses the open cluster fan-out.
        // Re-registered every pass because the Coordinator persists
        // across MapView rebuilds (held MLNMapView) — same lifetime
        // logic as the parent refresh above. Mirrors the Android app.
        MapViewHolder.shared.dismissFan = { [weak c = context.coordinator] in c?.clearFan() }
        // The map's clock, pointed at the live Coordinator the same way.
        MapViewHolder.shared.refreshAges = { [weak c = context.coordinator] in c?.refreshAges() }
        // Compare against the holder's applied state — a fresh
        // Coordinator's lastIsDarkMode would be out of sync until the
        // first apply, but the holder always reflects the real
        // styleJSON state of the persistent MLNMapView.
        if MapViewHolder.shared.lastAppliedDarkMode != isDarkMode {
            context.coordinator.applyStyle(isDarkMode: isDarkMode)
            MapViewHolder.shared.lastAppliedDarkMode = isDarkMode
        }
        context.coordinator.syncAnnotations(
            memberLocations: memberLocations,
            places: places,
            destinations: destinations,
            members: members,
            sosAlerts: sosAlerts
        )
        context.coordinator.syncHistoryTrails(historyTrails, members: members)
        // Let the camera-settle handler re-run the same sync with the same
        // inputs. Place-pin occlusion is screen-space, so its answer changes on
        // zoom/pan even when nothing in the data did — and the Coordinator has
        // no access to these SwiftUI-owned arrays on its own.
        context.coordinator.requestAnnotationResync = { [weak coordinator = context.coordinator] in
            coordinator?.syncAnnotations(
                memberLocations: memberLocations,
                places: places,
                destinations: destinations,
                members: members,
                sosAlerts: sosAlerts
            )
        }
        if context.coordinator.lastRecenterTrigger != recenterTrigger {
            context.coordinator.lastRecenterTrigger = recenterTrigger
            if let user = mapView.userLocation?.location?.coordinate {
                mapView.setCenter(user, zoomLevel: MapLibreMapView.selfLocationZoom, animated: true)
                // User explicitly chose this position; suppress the
                // first-time auto-fit below so a late member arrival
                // doesn't yank the camera back to a bounding box.
                context.coordinator.didAutoFit = true
            }
        }
        if context.coordinator.lastFitAllTrigger != fitAllTrigger {
            context.coordinator.lastFitAllTrigger = fitAllTrigger
            // "Center on everyone" frames circle members only — not places.
            context.coordinator.fitToAllAnnotations(animated: true, membersOnly: true)
            context.coordinator.didAutoFit = true
        }
        context.coordinator.syncDroppedPin(droppedPin)
        // Fly-to from Search / Destinations — one-shot, then clear the
        // binding so the same coord doesn't keep firing on later
        // updateUIView passes. As in the Android app, also
        // mark the first-time auto-fit as already consumed, so when
        // a member's decrypted location arrives a moment later the
        // syncAnnotations auto-fit branch doesn't yank the camera off
        // the picked target.
        if let target = flyToCoordinate {
            mapView.setCenter(target, zoomLevel: 14, animated: true)
            context.coordinator.didAutoFit = true
            DispatchQueue.main.async { self.flyToCoordinate = nil }
        }
        if let points = flyToFit {
            context.coordinator.fit(points)
            context.coordinator.didAutoFit = true
            DispatchQueue.main.async { self.flyToFit = nil }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, MLNMapViewDelegate {
        // Mutable parent: the surrounding MapView struct is rebuilt
        // on every SwiftUI render, and its closures capture @State
        // bindings that the new struct points to. We persist this
        // Coordinator across MapView rebuilds (via the held MLNMapView
        // in MapViewHolder), so the only way to keep the closures
        // pointing at the LIVE MapView's @State is to refresh `parent`
        // on every updateUIView. Without it, onMemberTap fires into a
        // stale `showingMemberDetail` binding and the sheet never
        // presents.
        fileprivate var parent: MapLibreMapView
        weak var mapView: MLNMapView?
        var lastIsDarkMode: Bool?
        var lastRecenterTrigger: Int = 0
        var lastFitAllTrigger: Int = 0
        private var memberAnnotations: [String: MemberAnnotation] = [:]
        /// Manual member clustering (native MapLibre clustering doesn't
        /// work in this fork — see ClusterAnnotation). `memberAnnotations`
        /// is the full DATA set of members; `applyMemberClustering()`
        /// decides which are actually ON the map vs. collapsed into a
        /// badge. `clusterAnnotations` is keyed by a stable group key
        /// (sorted member ids joined by ","), so a changed group becomes
        /// a new key and the old badge is naturally reconciled away.
        /// `shownMemberIds` tracks which member annotations are currently
        /// added to the map (a subset of memberAnnotations' keys).
        private var clusterAnnotations: [String: ClusterAnnotation] = [:]
        private var shownMemberIds: Set<String> = []
        /// Screen-space radius (pt): members whose projected points fall
        /// within this of a cluster seed collapse into one badge. ~48pt
        /// keeps the 52pt member dots from overlapping. Parity with
        /// the Android app's cluster distance.
        private let clusterThresholdPt: CGFloat = 48
        /// Above this zoom, clustering is OFF — every member shows as its
        /// own avatar, no count badges. Parity with the Android app's
        /// `clusterMaxZoom 14`: once you're zoomed in past city scale the
        /// members are spread out enough that collapsing them just hides
        /// detail. Below the cap, the screen-space grouping above applies.
        private let clusterMaxZoom: Double = 14
        /// Fan-out (spiderfy) state. `fannedClusterKey` is the group key of
        /// the currently-open fan (nil = none). `fanAnnotations` are the
        /// per-member display copies spread into the ring; `fanLines` are
        /// the connector polylines from the badge to each fanned avatar.
        /// All three are torn down together by `clearFan()` on the next
        /// camera settle or an empty-map tap. Parity with the Android app's
        /// cluster spiderfy.
        private var fannedClusterKey: String?
        private var fanAnnotations: [FanMemberAnnotation] = []
        private var fanLines: [MLNPolyline] = []
        private var placeAnnotations: [String: PlaceAnnotation] = [:]
        /// The drawn area of each approximate member, by member id. Kept apart
        /// from the avatars: an avatar folded into a cluster badge still has
        /// its area on the map.
        private var areaPolygons: [String: ApproximateAreaPolygon] = [:]
        private var destinationAnnotations: [String: DestinationAnnotation] = [:]
        private var sosAnnotations: [String: SOSAnnotation] = [:]
        /// The area drawn under an SOS whose position is that rough, by
        /// alert id.
        private var sosAreaPolygons: [String: ApproximateAreaPolygon] = [:]
        private var droppedPinAnnotation: DroppedPinAnnotation?
        private var didCenterOnUser = false
        /// True after we've auto-fit the camera at least once. The fit
        /// runs as soon as the first batch of annotations arrives so a
        /// user landing on the Map tab doesn't see an empty San
        /// Francisco view. Subsequent updates leave the camera alone.
        // fileprivate so updateUIView (defined on the outer
        // UIViewRepresentable struct) can mark it true after an
        // explicit camera move — preventing syncAnnotations' first-
        // time auto-fit from yanking the camera away once a
        // late-arriving member decryption triggers a re-sync.
        fileprivate var didAutoFit = false
        /// Wall-clock time we kicked off the style assign. Used by the
        /// MapLibre delegate callbacks below to attribute "X ms from
        /// style.assign to didFinishLoadingStyle / didFinishLoadingMap"
        /// in map-diag.log so we can isolate which phase is slow.
        fileprivate var styleAssignStart: Date?
        /// Cold-start self seed. Re-applied in `didFinishLoading style:`
        /// because MapLibre resets the camera to the style's center+zoom
        /// after parsing — otherwise the seeded view briefly appears,
        /// then the style flips back to its default before the
        /// "snap to live self" path can catch up. One-shot.
        fileprivate var pendingSelfSeed: PersistedSelfLocation?
        /// The history trails drawn now and each member's colour,
        /// kept so a new style (light or dark) draws them again.
        private var historyTrails: [HistoryTrail] = []
        private var historyColors: [String: String] = [:]
        /// Set in makeUIView on cold start. While true, syncAnnotations
        /// snaps the camera to the live self position the moment it
        /// arrives (CL fix or self marker decrypt) and persists it as
        /// the next cold-start seed. Cleared after one snap. A user
        /// gesture clears it too so we don't yank their pan away.
        fileprivate var coldStartSelfRefinePending = false
        /// Re-runs `syncAnnotations` with the inputs from the last `updateUIView`.
        /// Set there, because the Coordinator doesn't hold those arrays itself.
        /// Used by the camera-settle handler, since place-pin occlusion is a
        /// screen-space question whose answer changes without the data changing.
        fileprivate var requestAnnotationResync: (() -> Void)?

        /// `membersOnly` frames just the circle members (the "center on
        /// everyone" button) — places and destinations are excluded so the
        /// camera isn't pulled out to a far-away saved place. The cold-start
        /// auto-fit leaves it false so a solo user with only places still
        /// gets framed on first paint.
        func fitToAllAnnotations(animated: Bool, membersOnly: Bool = false) {
            guard let mapView = mapView else { return }
            if membersOnly {
                // An approximate member's whole area, not just its centre.
                let coords = MapLibreMapView.framingCoordinates(Array(memberAnnotations.values))
                // Every member on screen, and never closer than the
                // "my location" zoom: a fit of two nearby people would
                // zoom way in, so "center on everyone" stops at the
                // recenter button's zoom. Framed in the map's content
                // area, the view less its content inset, because
                // `setCenter` centres there. The app's map has no
                // inset (MapLibre gives a map the safe area only under
                // a view controller), so this is the whole view; with
                // one, a group framed in the whole view would run past
                // its room's top or foot.
                guard let framing = MapLibreMapView.framing(
                    coords, in: mapView.bounds.inset(by: mapView.contentInset).size,
                    padding: MapLibreMapView.fitPadding, maxZoom: MapLibreMapView.selfLocationZoom
                ) else { return }
                mapView.setCenter(framing.center, zoomLevel: framing.zoom, animated: animated)
                return
            }
            let coords: [CLLocationCoordinate2D] =
                MapLibreMapView.framingCoordinates(Array(memberAnnotations.values))
                + placeAnnotations.values.map { $0.coordinate }
                + destinationAnnotations.values.map { $0.coordinate }
            if let bounds = Self.bounds(for: coords) {
                mapView.setVisibleCoordinateBounds(
                    bounds,
                    edgePadding: MapLibreMapView.fitPadding,
                    animated: animated
                )
            } else if let single = coords.first {
                mapView.setCenter(single, zoomLevel: 13, animated: animated)
            }
        }

        init(parent: MapLibreMapView) {
            self.parent = parent
        }

        /// Pull the style JSON, patch its tile source
        /// (`rewriteProtomapsSource`), then hand the patched JSON to
        /// MapLibre. Done off the main thread to avoid blocking the UI
        /// on the (~262 KB) style fetch.
        func applyStyle(isDarkMode: Bool) {
            lastIsDarkMode = isDarkMode
            let variant = isDarkMode ? "dark" : "light"
            guard let styleURL = URL(string: "https://pmtiles.pingolin.com/styles/\(variant).json") else {
                return
            }
            Task.detached { [weak self] in
                guard let self = self else { return }
                let started = Date()
                Self.writeMapDiag("style.fetch.start variant=\(variant)")
                do {
                    let (data, response) = try await TrustBlocklist.shared.data(from: styleURL)
                    let fetchMs = Int(Date().timeIntervalSince(started) * 1000)
                    let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? -1
                    let patched = Self.rewriteProtomapsSource(in: data) ?? data
                    Self.writeMapDiag("style.fetch.ok variant=\(variant) status=\(httpStatus) bytes=\(data.count) fetchMs=\(fetchMs)")
                    if let styleJSON = String(data: patched, encoding: .utf8) {
                        await MainActor.run {
                            Self.writeMapDiag("style.assign variant=\(variant)")
                            self.styleAssignStart = Date()
                            self.mapView?.styleJSON = styleJSON
                        }
                    }
                } catch {
                    Self.writeMapDiag("style.fetch.fail variant=\(variant) error=\(error)")
                    #if DEBUG
                    print("[Track] MapLibre style fetch failed: \(error)")
                    #endif
                }
            }
        }

        /// Append a line to Documents/map-diag.log: a device-side
        /// trace of the map style + tile-load path (DEBUG builds
        /// only). Only style fetch + style assign are instrumented
        /// here; tile-level events come from MapLibre's own delegate
        /// callbacks.
        fileprivate static func writeMapDiag(_ message: String) {
            // DEBUG-only: this appends a timestamped map-usage trace to
            // Documents/map-diag.log, which is backup-eligible and swept only on
            // logout. In Release it must be a no-op — otherwise every map open
            // accumulates a permanent, unswept usage timeline in iCloud backups.
            #if DEBUG
            guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
            let url = docs.appendingPathComponent("map-diag.log")
            let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
            if FileManager.default.fileExists(atPath: url.path),
               let handle = try? FileHandle(forWritingTo: url) {
                try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
                try? handle.close()
            } else {
                try? line.write(to: url, atomically: false, encoding: .utf8)
            }
            #endif
        }

        /// Retarget `sources.protomaps` at the pingolin-hosted tiles. The
        /// published style.json still points at the Protomaps demo bucket;
        /// clients are expected to retarget.
        private static func rewriteProtomapsSource(in data: Data) -> Data? {
            guard var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            if var sources = root["sources"] as? [String: Any],
               var protomaps = sources["protomaps"] as? [String: Any] {
                // Individual tiles, not the archive.
                //
                // `planet.pmtiles` is 134 GB, and Cloudflare will not cache an
                // object that size — every range request comes back BYPASS, so
                // every directory walk and every tile would be an origin round
                // trip from this device (minutes to first render on a fresh
                // install), hidden afterwards only by MapLibre's own tile cache.
                //
                // The tile server serves the same archive a tile at a time, and
                // a tile is small enough to cache at the edge like the fonts and
                // sprites already do. It also collapses the read: the directory
                // walk happens once, at Cloudflare, instead of as dependent
                // round trips from every device.
                //
                // `url` MUST go. With both keys present MapLibre prefers `url`
                // and this whole change silently does nothing.
                protomaps.removeValue(forKey: "url")
                // Server-driven, falling back to a shipped
                // literal. See MapTileConfig for why the version
                // segment has to be movable from the server:
                // tiles are `immutable, max-age=31536000`, so a
                // hardcoded prefix means no purge can ever reach
                // a device's cache.
                protomaps["tiles"] = [MapTileConfig.tileTemplate]
                // Mandatory with `tiles`: reading `url` lets MapLibre take
                // these from the archive header; with `tiles` nothing tells it,
                // and the values are the header's own min/max zoom.
                protomaps["minzoom"] = 0
                protomaps["maxzoom"] = 15
                sources["protomaps"] = protomaps
                root["sources"] = sources
            }
            return try? JSONSerialization.data(withJSONObject: root)
        }

        func syncAnnotations(
            memberLocations: [LocationData],
            places: [Place],
            destinations: [Destination],
            members: [CircleMember],
            sosAlerts: [SOSAlert]
        ) {
            guard let mapView = mapView else { return }

            // `AuthManager.userId` is main-isolated; `syncAnnotations`
            // is already called from updateUIView on main, so this read
            // is safe. Explicit assumeIsolated to satisfy strict
            // concurrency.
            let currentUserId = MainActor.assumeIsolated { AuthManager.shared.userId }

            // Coalesce locations + members. On warm resume the cached
            // memberLocations rehydrate a beat before the member list
            // — if we render that frame, peer markers paint with the
            // "Member" fallback initial ("M") before settling. Skip
            // member work entirely until both flows have populated; the
            // canvas keeps whatever it last drew and re-renders cleanly
            // on the next emission. Own marker uses the AuthManager
            // fast-path below so it doesn't depend on members. Mirrors
            // the Android app. Places aren't gated — they depend on
            // PlaceManager, not the members flow.
            let hasUnnamedPeer = memberLocations.contains { $0.userId != currentUserId }
            let skipMemberRender = hasUnnamedPeer && members.isEmpty

            // Member-at-place (matching android): a member inside a
            // saved place's radius shows "At <Place>" and that place's own
            // pin is hidden, so the avatar doesn't sit on a duplicate.
            // Recomputed every sync (members + places re-emit on change);
            // independent of the member-name gate above.
            var occupiedPlaceByMember: [String: Place] = [:]
            var occupiedPlaceIds: Set<String> = []
            // Not a frozen last location: its marker says
            // "Location sharing off", never "At <Place>", so it
            // hides no pin.
            for loc in memberLocations where !loc.sharingOff {
                if let place = MapLibreMapView.placeOccupied(by: loc, in: places) {
                    occupiedPlaceByMember[loc.userId] = place
                    // Hiding the pin needs containment AND the avatar actually
                    // covering it on screen. Containment alone would erase a pin
                    // for anyone anywhere inside the radius — which runs to 2 km,
                    // so a member a kilometre away would remove a pin they were
                    // nowhere near, and zooming would never bring it back because
                    // the test would never look at the camera. Occlusion alone
                    // would hide pins under members whose sheet carries no "At
                    // <Place>" row, leaving no route back; requiring both keeps
                    // hidden pins a strict subset of has-a-row.
                    if isCovered(place: place, byMemberAt: loc, in: mapView) {
                        occupiedPlaceIds.insert(place.id)
                    }
                }
            }

            // Who is raising an SOS, and which alerts their own avatar can
            // stand in for. The raiser's marker carries the alert (SOS band +
            // pulse) instead of a separate disc being stamped over the top of
            // them — but only while the two are in the same place. An SOS
            // location is where the raiser's phone last sealed it, never their
            // live position, so once the raiser walks away from it the disc is
            // information the avatar no longer has, and it stays on the map.
            //
            // Nothing merges while the member pass is being skipped: no avatar
            // is going on the map this frame, so there is nothing for the disc
            // to be redundant with. (`memberLocations` is likewise empty when
            // the user switches the Members layer off — an SOS is not something
            // a layer toggle should be able to hide.)
            let sosMemberIds = Set(sosAlerts.map { $0.userId })
            var mergedSosIds: Set<String> = []
            for alert in sosAlerts where !skipMemberRender {
                // An area is never merged: it is no spot to stand
                // on, and its label always shows. Nor into a frozen
                // last location: it is not where they are, and the
                // alert's own position is.
                guard alert.positionAreaMeters == nil, let alertCoord = alert.coordinate,
                      let loc = memberLocations.first(where: { $0.userId == alert.userId && !$0.sharingOff })
                else { continue }
                let distance = CLLocation(latitude: alertCoord.latitude, longitude: alertCoord.longitude)
                    .distance(from: CLLocation(latitude: loc.latitude, longitude: loc.longitude))
                if distance <= MapLibreMapView.sosMergeDistanceMeters {
                    mergedSosIds.insert(alert.id)
                }
            }

            if !skipMemberRender {
                let liveMemberIds = Set(memberLocations.map { $0.userId })
                for (id, annot) in memberAnnotations where !liveMemberIds.contains(id) {
                    // A member that left: drop it from the map (if it was
                    // shown as a singleton) AND from the data dict. Any
                    // cluster it belonged to is reconciled away by
                    // applyMemberClustering() below (its group key changes).
                    mapView.removeAnnotation(annot)
                    shownMemberIds.remove(id)
                    memberAnnotations.removeValue(forKey: id)
                }
                // Show the MapLibre stock GPS dot only as a fallback when
                // the user doesn't have their own colored MemberAnnotation
                // yet (no recent send, solo with no self-circle history,
                // or first paint before member decryption finishes). The
                // moment a self-marker exists we suppress the dot so the
                // two don't overlap.
                let selfHasMarker = currentUserId.map { uid in
                    memberLocations.contains(where: { $0.userId == uid })
                } ?? false
                mapView.showsUserLocation = !selfHasMarker
                let nowMs = Int64(Date().timeIntervalSince1970 * 1_000)
                for loc in memberLocations {
                    let coord = CLLocationCoordinate2D(latitude: loc.latitude, longitude: loc.longitude)
                    // Colour comes from `MemberPalette.bubble`
                    // — the ONE place that decides it, shared
                    // with the member card and the roster row,
                    // so the same member is the same colour on
                    // all three.
                    // For the current user, prefer
                    // AuthManager's cached displayName when the
                    // circle members list doesn't have them yet
                    // (solo user with no circle, or first-render
                    // race before the members flow resolves).
                    // Mirrors the Android app — without it the
                    // own marker would briefly render with the
                    // wrong initial ("M" for "Member" / "U" for
                    // "Unknown") before the proper name landed.
                    let displayName: String = MainActor.assumeIsolated {
                        if loc.userId == currentUserId,
                           let me = AuthManager.shared.currentUser?.displayName,
                           !me.isEmpty {
                            return me
                        }
                        return members.first(where: { $0.userId == loc.userId })?.displayName ?? "Member"
                    }
                    let fixTimeMs = Int64(loc.timestamp.timeIntervalSince1970 * 1_000)
                    let ageMs = max(0, nowMs - fixTimeMs)
                    let color = MemberPalette.bubble(forUserId: loc.userId, in: members, ageMs: ageMs)
                    let isMe = loc.userId == currentUserId
                    let hasSOS = sosMemberIds.contains(loc.userId)
                    let areaMeters = MapLibreMapView.areaMeters(for: loc, isMe: isMe)
                    let title = MapLibreMapView.markerTitle(displayName: displayName, isApproximate: areaMeters != nil)
                    if let existing = memberAnnotations[loc.userId] {
                        let sosChanged = existing.hasSOS != hasSOS
                        let areaChanged = (existing.approximateMeters == nil) != (areaMeters == nil)
                        let shownBefore = MemberMarkerView.appearance(of: existing)
                        existing.coordinate = coord
                        existing.displayName = displayName
                        existing.ageMs = ageMs
                        existing.fixTimeMs = fixTimeMs
                        existing.fillColor = color
                        existing.isCurrentUser = isMe
                        existing.title = title
                        existing.atPlaceName = occupiedPlaceByMember[loc.userId]?.name
                        existing.hasSOS = hasSOS
                        existing.approximateMeters = areaMeters
                        existing.sharingOff = loc.sharingOff
                        // MapLibre only asks for a view when an annotation is
                        // ADDED, so mutating the payload of one already on the
                        // map changes nothing on screen. An SOS starting (or
                        // being resolved) while the map is open has to force the
                        // view to be rebuilt, or the avatar keeps whatever
                        // marking it had; so does a member switching to or from
                        // approximate, whose marker then says so. Only on the
                        // flip — this is not a per-tick cost.
                        if sosChanged || areaChanged, shownMemberIds.contains(loc.userId) {
                            mapView.removeAnnotation(existing)
                            mapView.addAnnotation(existing)
                        } else if MemberMarkerView.appearance(of: existing) != shownBefore,
                                  let view = mapView.view(for: existing) as? MemberMarkerView {
                            // Its age, its stale grey, its
                            // place or its name changed:
                            // the view on the map is drawn
                            // again in place. Only then,
                            // and never removed and added:
                            // a marker whose caption is
                            // unchanged is left as it is.
                            view.configure(member: existing)
                        }
                    } else {
                        let annot = MemberAnnotation()
                        annot.coordinate = coord
                        annot.title = title
                        annot.memberId = loc.userId
                        annot.displayName = displayName
                        annot.ageMs = ageMs
                        annot.fixTimeMs = fixTimeMs
                        annot.fillColor = color
                        annot.isCurrentUser = isMe
                        annot.atPlaceName = occupiedPlaceByMember[loc.userId]?.name
                        annot.hasSOS = hasSOS
                        annot.approximateMeters = areaMeters
                        annot.sharingOff = loc.sharingOff
                        // Build the DATA dict only — do NOT addAnnotation
                        // here. applyMemberClustering() (called at the end
                        // of this sync) decides whether this member is shown
                        // as an individual avatar or collapsed into a badge.
                        memberAnnotations[loc.userId] = annot
                    }
                }
                syncAreas()
            }

            let livePlaceIds = Set(places.map { $0.id })
            for (id, annot) in placeAnnotations where !livePlaceIds.contains(id) {
                mapView.removeAnnotation(annot)
                placeAnnotations.removeValue(forKey: id)
            }
            for place in places {
                if occupiedPlaceIds.contains(place.id) {
                    // Occupied by a member → hide its pin (the member's
                    // "At <Place>" carries the name). Re-added on the next
                    // sync once the member leaves the radius.
                    if let existing = placeAnnotations[place.id] {
                        mapView.removeAnnotation(existing)
                        placeAnnotations.removeValue(forKey: place.id)
                    }
                    continue
                }
                if let existing = placeAnnotations[place.id] {
                    existing.coordinate = place.coordinate
                    existing.title = place.name
                    existing.icon = place.icon.systemImage
                    existing.hexColor = place.color
                } else {
                    let annot = PlaceAnnotation()
                    annot.coordinate = place.coordinate
                    annot.title = place.name
                    annot.placeId = place.id
                    annot.icon = place.icon.systemImage
                    annot.hexColor = place.color
                    placeAnnotations[place.id] = annot
                    mapView.addAnnotation(annot)
                }
            }

            // Destinations (android updateDestinationMarkers): creator-
            // colored flag pins, reconciled by id like places. Color +
            // label resolve from the member list (creator fallback to 0).
            let liveDestIds = Set(destinations.map { $0.id })
            for (id, annot) in destinationAnnotations where !liveDestIds.contains(id) {
                mapView.removeAnnotation(annot)
                destinationAnnotations.removeValue(forKey: id)
            }
            for dest in destinations {
                let creatorIndex = members.firstIndex(where: { $0.userId == dest.userId }) ?? 0
                let color = MemberPalette.color(forIndex: creatorIndex)
                let label = MapLibreMapView.destinationLabel(dest, currentUserId: currentUserId, members: members)
                if let existing = destinationAnnotations[dest.id] {
                    existing.coordinate = dest.coordinate
                    existing.title = label
                    existing.fillColor = color
                } else {
                    let annot = DestinationAnnotation()
                    annot.coordinate = dest.coordinate
                    annot.title = label
                    annot.destinationId = dest.id
                    annot.fillColor = color
                    destinationAnnotations[dest.id] = annot
                    mapView.addAnnotation(annot)
                }
            }

            // SOS (android updateSosMarkers). Reconciled by id like places and
            // destinations, but NOT filtered to the selected circle — the
            // caller hands us every mappable alert across all of them.
            // Alerts merged into their raiser's avatar (above) get no disc of
            // their own — that overlap is exactly what the avatar marking
            // replaces. Everything else still gets one.
            let liveSosIds = Set(sosAlerts.map { $0.id }).subtracting(mergedSosIds)
            for (id, annot) in sosAnnotations where !liveSosIds.contains(id) {
                mapView.removeAnnotation(annot)
                sosAnnotations.removeValue(forKey: id)
            }
            for alert in sosAlerts where liveSosIds.contains(alert.id) {
                guard let coordinate = alert.coordinate else { continue }
                // Recomputed every pass, not just at creation: the age in the
                // caption goes stale otherwise.
                let now = Date()
                let caption = MapLibreMapView.sosCaption(alert, now: now)
                let title = MapLibreMapView.sosTitle(alert, now: now)
                // An area is its label, a point its disc. A change of either
                // (an update) is a new annotation, so the right view draws it.
                let areaLabel = MapLibreMapView.sosAreaLabel(alert, now: now)
                if let existing = sosAnnotations[alert.id], existing.areaLabel != areaLabel {
                    mapView.removeAnnotation(existing)
                    sosAnnotations.removeValue(forKey: alert.id)
                }
                if let existing = sosAnnotations[alert.id] {
                    existing.coordinate = coordinate
                    existing.alert = alert
                    existing.caption = caption
                    existing.title = title
                    (mapView.view(for: existing) as? SOSMarkerView)?.setCaption(caption)
                } else {
                    let annot = SOSAnnotation()
                    annot.coordinate = coordinate
                    annot.sosId = alert.id
                    annot.alert = alert
                    annot.caption = caption
                    annot.title = title
                    annot.areaLabel = areaLabel
                    sosAnnotations[alert.id] = annot
                    mapView.addAnnotation(annot)
                }
            }
            syncSOSAreas(sosAlerts)
            refreshSOSEdgeIndicators()

            // Cold-start "snap to live self": when we seeded the
            // camera from a stale persisted self position (or fell
            // back to SF on a first-ever launch), refine to the live
            // fix the moment we know where the user is. Mirrors
            // the Android app's GPS-snap on coldStartRecenterSelf.
            if coldStartSelfRefinePending, let liveSelf = currentSelfCoordinate(currentUserId: currentUserId, mapView: mapView) {
                mapView.setCenter(liveSelf, zoomLevel: MapLibreMapView.selfLocationZoom, animated: false)
                SelfLocationStore.save(PersistedSelfLocation(latitude: liveSelf.latitude, longitude: liveSelf.longitude))
                coldStartSelfRefinePending = false
                // The snap supersedes any pending re-apply from
                // didFinishLoading — and any first-time fit-to-all
                // would now reframe over the user.
                pendingSelfSeed = nil
                didAutoFit = true
            }

            // First time we have anything to look at and we don't
            // have a self position to center on, fit the camera so
            // markers aren't off-screen. With the snap-to-self path
            // above, this is the no-GPS fallback only.
            if !didAutoFit, !memberAnnotations.isEmpty || !placeAnnotations.isEmpty {
                fitToAllAnnotations(animated: false)
                didAutoFit = true
            }

            // Resolve the member DATA dict into what's actually drawn —
            // individual avatars vs. collapsed count badges — for the
            // current camera. Runs last so it sees this sync's final
            // member set + the (possibly just-moved) camera. Also re-run
            // on every region settle (regionDidChangeWith) so the split/
            // merge tracks zoom + pan.
            applyMemberClustering()
        }

        /// Is this place's pin covered by that member's avatar right now?
        ///
        /// Screen-space, so the answer changes with the camera — which is the
        /// point: zoom in and the two separate, so the pin comes back and can be
        /// tapped. `MemberMarkerView` draws its 52pt disc at the top of the view
        /// with the age / "At <Place>" labels below, and MapLibre centres the
        /// view on the coordinate, so the disc renders ABOVE the member's actual
        /// position — comparing raw projected points would misjudge by half the
        /// label stack.
        private func isCovered(place: Place, byMemberAt loc: LocationData, in mapView: MLNMapView) -> Bool {
            let placePoint = mapView.convert(place.coordinate, toPointTo: mapView)
            let memberPoint = mapView.convert(
                CLLocationCoordinate2D(latitude: loc.latitude, longitude: loc.longitude),
                toPointTo: mapView
            )
            let discCentre = CGPoint(
                x: memberPoint.x,
                y: memberPoint.y - MemberMarkerView.discRiseAboveAnchor
            )
            return hypot(discCentre.x - placePoint.x, discCentre.y - placePoint.y)
                <= MemberMarkerView.occlusionThreshold
        }

        /// One translucent area per approximate member, under their avatar,
        /// reconciled against the member data: added when someone becomes
        /// approximate, replaced when its centre, size or colour changes,
        /// removed when they stop or leave. Not part of clustering: a member
        /// folded into a badge keeps their area on the map.
        private func syncAreas() {
            guard let mapView = mapView else { return }
            for (id, polygon) in areaPolygons where memberAnnotations[id]?.approximateMeters == nil {
                mapView.removeAnnotation(polygon)
                areaPolygons.removeValue(forKey: id)
            }
            // The held map view outlives a Coordinator; an area a previous one
            // drew is in no dictionary here and would otherwise stay for good.
            let tracked = Set((Array(areaPolygons.values) + Array(sosAreaPolygons.values)).map(ObjectIdentifier.init))
            let orphans = (mapView.annotations ?? []).compactMap { $0 as? ApproximateAreaPolygon }
                .filter { !tracked.contains(ObjectIdentifier($0)) }
            if !orphans.isEmpty { mapView.removeAnnotations(orphans) }
            for (id, member) in memberAnnotations {
                guard let meters = member.approximateMeters else { continue }
                if let existing = areaPolygons[id] {
                    if existing.center.latitude == member.coordinate.latitude,
                       existing.center.longitude == member.coordinate.longitude,
                       existing.radiusMeters == meters,
                       existing.fillColor == member.fillColor {
                        continue
                    }
                    mapView.removeAnnotation(existing)
                }
                var outline = ApproximateArea.outline(center: member.coordinate, radiusMeters: meters)
                let polygon = ApproximateAreaPolygon(coordinates: &outline, count: UInt(outline.count))
                polygon.memberId = id
                polygon.center = member.coordinate
                polygon.radiusMeters = meters
                polygon.fillColor = member.fillColor
                areaPolygons[id] = polygon
                mapView.addAnnotation(polygon)
            }
        }

        /// An area of radius `accuracy` under each SOS whose position is that
        /// rough: a coarse fix, or a held one coarsened to the bubble it was
        /// taken under, is never a pin alone. Red; replaced when its centre or
        /// size changes, removed when the alert goes.
        private func syncSOSAreas(_ alerts: [SOSAlert]) {
            guard let mapView = mapView else { return }
            var wanted: [String: (CLLocationCoordinate2D, Double)] = [:]
            for alert in alerts {
                if let coordinate = alert.coordinate, let meters = alert.positionAreaMeters {
                    wanted[alert.id] = (coordinate, meters)
                }
            }
            for (id, polygon) in sosAreaPolygons {
                if let (center, meters) = wanted[id], polygon.center.latitude == center.latitude,
                   polygon.center.longitude == center.longitude, polygon.radiusMeters == meters {
                    wanted.removeValue(forKey: id)
                    continue
                }
                mapView.removeAnnotation(polygon)
                sosAreaPolygons.removeValue(forKey: id)
            }
            for (id, (center, meters)) in wanted {
                var outline = ApproximateArea.outline(center: center, radiusMeters: meters)
                let polygon = ApproximateAreaPolygon(coordinates: &outline, count: UInt(outline.count))
                polygon.memberId = id
                polygon.center = center
                polygon.radiusMeters = meters
                polygon.fillColor = .systemRed
                sosAreaPolygons[id] = polygon
                mapView.addAnnotation(polygon)
            }
        }

        /// Manual member clustering in SCREEN space. Native MapLibre clustering
        /// (MLNShapeSource `clusterOptions`) does NOT work in this fork — it
        /// never emits cluster features and silently drops points under the
        /// threshold — so we collapse overlapping member avatars into count
        /// badges ourselves, on top of the annotation system that renders
        /// correctly. Parity with the Android app's screen-space member
        /// clustering.
        ///
        /// Greedy seed-distance grouping: members are visited in a stable
        /// (sorted-by-id) order; each unassigned member seeds a group and
        /// pulls in every other unassigned member within `clusterThreshold`
        /// pt of the SEED's projected point. Seed-distance (not transitive)
        /// keeps grouping stable and cheap — chains can't snowball a whole
        /// row of separated members into one badge. O(n²), fine for the
        /// handful of members in a circle.
        private func applyMemberClustering() {
            guard let mapView = mapView else { return }

            // Any re-cluster runs on every camera settle (regionDidChange),
            // so it's also the dismissal point for an open fan — zooming or
            // panning collapses the spiderfy back into the badge, matching
            // the Android app. Cheap no-op when nothing is fanned.
            clearFan()

            // No members: tear down any leftover badges and bail. Members
            // already on the map are left as-is (the sync's removal pass
            // owns member teardown).
            if memberAnnotations.isEmpty {
                for (_, annot) in clusterAnnotations {
                    mapView.removeAnnotation(annot)
                }
                clusterAnnotations.removeAll()
                return
            }

            let ids = memberAnnotations.keys.sorted()

            // What we want on the map after this pass: the set of member
            // ids shown as individual avatars, and the badges keyed by
            // group key -> (centroid, count, memberIds). Above the zoom
            // cap we skip the grouping pass entirely (every member is a
            // singleton, no badges); below it we run the screen-space
            // greedy grouping. Both feed the SAME reconcile below.
            var desiredVisible: Set<String> = []
            var desiredClusters: [String: (CLLocationCoordinate2D, Int, [String])] = [:]

            // A member raising an SOS never gets folded into a badge: collapsing
            // them would take the emergency off the map with them, at exactly
            // the zoom levels where somebody is most likely to be looking for it.
            let sosIds = Set(ids.filter { memberAnnotations[$0]?.hasSOS == true })

            if mapView.zoomLevel > clusterMaxZoom {
                // Past city scale (the Android app's clusterMaxZoom 14):
                // every member shows individually, no clustering pass.
                desiredVisible = Set(ids)
            } else {
                // Project every member to a screen point once. A member off
                // the current viewport still projects to a (possibly
                // off-screen) point, which is fine — distance grouping is
                // purely relative.
                var points: [String: CGPoint] = [:]
                for id in ids {
                    if let annot = memberAnnotations[id] {
                        points[id] = mapView.convert(annot.coordinate, toPointTo: mapView)
                    }
                }

                // Greedy grouping. `assigned` guards against a member landing
                // in two groups; iteration order is the sorted `ids` so the
                // same input always produces the same groups (stable badges,
                // no flicker from reordering).
                var assigned: Set<String> = sosIds
                var groups: [[String]] = sosIds.sorted().map { [$0] }
                for seed in ids {
                    if assigned.contains(seed) { continue }
                    guard let seedPoint = points[seed] else { continue }
                    assigned.insert(seed)
                    var group = [seed]
                    for other in ids where !assigned.contains(other) {
                        guard let p = points[other] else { continue }
                        if hypot(p.x - seedPoint.x, p.y - seedPoint.y) <= clusterThresholdPt {
                            assigned.insert(other)
                            group.append(other)
                        }
                    }
                    groups.append(group)
                }

                // Singletons stay individual avatars; size >= 2 becomes a
                // badge. desiredVisible = the union of all singleton ids.
                // groupKey -> (centroid, count, memberIds). Key encodes the
                // exact membership (sorted ids joined), so any membership
                // change yields a new key — old badge removed, new one added.
                for group in groups {
                    if group.count == 1 {
                        desiredVisible.insert(group[0])
                    } else {
                        let sortedIds = group.sorted()
                        let key = sortedIds.joined(separator: ",")
                        var latSum = 0.0
                        var lngSum = 0.0
                        for id in group {
                            if let c = memberAnnotations[id]?.coordinate {
                                latSum += c.latitude
                                lngSum += c.longitude
                            }
                        }
                        let centroid = CLLocationCoordinate2D(
                            latitude: latSum / Double(group.count),
                            longitude: lngSum / Double(group.count)
                        )
                        desiredClusters[key] = (centroid, group.count, sortedIds)
                    }
                }
            }

            // Reconcile members: add those that should be visible and
            // aren't; remove those that are shown but now live inside a
            // cluster; drop any stale ids no longer in the data dict.
            for id in desiredVisible where !shownMemberIds.contains(id) {
                if let annot = memberAnnotations[id] {
                    mapView.addAnnotation(annot)
                    shownMemberIds.insert(id)
                }
            }
            // Collect-then-mutate (don't remove from `shownMemberIds` while
            // iterating it).
            let membersToHide = shownMemberIds.subtracting(desiredVisible)
            for id in membersToHide {
                if let annot = memberAnnotations[id] {
                    mapView.removeAnnotation(annot)
                }
            }
            shownMemberIds.subtract(membersToHide)

            // Reconcile clusters: create badges newly desired, drop badges
            // whose key is no longer desired (membership changed, the group
            // split back into singletons on zoom-in, or we crossed above the
            // zoom cap into the no-clustering branch where desiredClusters is
            // empty).
            for (key, value) in desiredClusters where clusterAnnotations[key] == nil {
                let annot = ClusterAnnotation()
                annot.coordinate = value.0
                annot.count = value.1
                annot.memberIds = value.2
                annot.key = key
                annot.title = ""
                clusterAnnotations[key] = annot
                mapView.addAnnotation(annot)
            }
            let clustersToRemove = clusterAnnotations.filter { desiredClusters[$0.key] == nil }
            for (key, annot) in clustersToRemove {
                mapView.removeAnnotation(annot)
                clusterAnnotations.removeValue(forKey: key)
            }
        }

        /// Fan-out (spiderfy) a tapped cluster: spread its members into a
        /// ring of `FanMemberAnnotation` display copies around the badge,
        /// with a connector line from the badge to each, so coincident
        /// avatars become individually tappable. The real `MemberAnnotation`
        /// coordinates are NOT moved — these are separate annotations — so
        /// re-clustering stays correct. The badge itself stays put at the
        /// ring center. Dismissed by `clearFan()` on the next camera settle.
        /// Parity with the Android app's cluster spiderfy.
        private func fanOutCluster(_ cluster: ClusterAnnotation) {
            guard let mapView = mapView else { return }
            // Tear down any fan already open (e.g. a different cluster) so we
            // never stack two rings.
            clearFan()

            let n = cluster.memberIds.count
            guard n >= 2 else { return }

            let center = mapView.convert(cluster.coordinate, toPointTo: mapView)
            // Ring radius in points: floored at 80pt, and grown so the
            // chord between adjacent avatars stays ~52pt even with many
            // members (radius = halfChord / sin(π/n)). Mirrors the Android
            // app's `max(90, minChord / (2·sin(π/n)))`, scaled to iOS points.
            let radius = max(80.0, 26.0 / sin(.pi / Double(n)))

            for (i, id) in cluster.memberIds.enumerated() {
                guard let source = memberAnnotations[id] else { continue }
                // Start the ring at the top (−π/2) and walk clockwise.
                let angle = 2 * .pi * Double(i) / Double(n) - .pi / 2
                let fanPoint = CGPoint(
                    x: center.x + radius * cos(angle),
                    y: center.y + radius * sin(angle)
                )
                let fanCoord = mapView.convert(fanPoint, toCoordinateFrom: mapView)

                let fan = FanMemberAnnotation()
                fan.memberId = source.memberId
                fan.displayName = source.displayName
                fan.ageMs = source.ageMs
                fan.fillColor = source.fillColor
                fan.isCurrentUser = source.isCurrentUser
                fan.atPlaceName = source.atPlaceName
                fan.hasSOS = source.hasSOS
                fan.isApproximate = source.approximateMeters != nil
                fan.sharingOff = source.sharingOff
                fan.coordinate = fanCoord
                fan.title = source.title
                mapView.addAnnotation(fan)
                fanAnnotations.append(fan)

                var line = [cluster.coordinate, fanCoord]
                let connector = MLNPolyline(coordinates: &line, count: 2)
                mapView.addAnnotation(connector)
                fanLines.append(connector)
            }

            fannedClusterKey = cluster.key
        }

        /// Dismiss the open fan: remove its avatars + connector lines from
        /// the map and clear the tracking state. No-op when no fan is open.
        /// Internal (not private) so MapViewHolder.dismissFan can drive it
        /// from MapView's overlay controls, as the Android app does.
        func clearFan() {
            guard let mapView = mapView else { return }
            for annot in fanAnnotations {
                mapView.removeAnnotation(annot)
            }
            for line in fanLines {
                mapView.removeAnnotation(line)
            }
            fanAnnotations.removeAll()
            fanLines.removeAll()
            fannedClusterKey = nil
        }

        /// The map's clock: every marker's age moves on to `now`, a member's
        /// "now" / "12m" and its grey past 15 minutes, a fanned-out copy's, and
        /// an SOS disc's caption. A pass (`syncAnnotations`) runs only when
        /// something is published, and a refresh publishes only news, so without
        /// this, in a quiet circle every age would stand where its last pass left
        /// it. Nothing is read, added or removed here, and no pass is run (each
        /// ends by closing an open fan): only a view whose text or colour changed
        /// is drawn again. MapView drives it while the app is in the foreground
        /// and the map is on screen.
        func refreshAges(now: Date = Date()) {
            guard let mapView = mapView else { return }
            let nowMs = Int64(now.timeIntervalSince1970 * 1_000)
            for member in memberAnnotations.values {
                if MapLibreMapView.moveAgeOn(member, nowMs: nowMs) {
                    (mapView.view(for: member) as? MemberMarkerView)?.configure(member: member)
                }
            }
            for fan in fanAnnotations {
                guard let member = memberAnnotations[fan.memberId] else { continue }
                if MapLibreMapView.moveAgeOn(fan, from: member) {
                    (mapView.view(for: fan) as? MemberMarkerView)?.configure(fan: fan)
                }
            }
            for sos in sosAnnotations.values {
                if MapLibreMapView.moveCaptionOn(sos, now: now) {
                    (mapView.view(for: sos) as? SOSMarkerView)?.setCaption(sos.caption)
                }
            }
        }

        /// Best-available current self position — prefers the live
        /// CoreLocation fix (fresher), falls back to the decrypted
        /// memberLocations entry. Used by the cold-start refine path
        /// in syncAnnotations.
        private func currentSelfCoordinate(currentUserId: String?, mapView: MLNMapView) -> CLLocationCoordinate2D? {
            if let cl = MainActor.assumeIsolated({ LocationService.shared.currentLocation }) {
                return cl.coordinate
            }
            guard let uid = currentUserId,
                  let annot = memberAnnotations[uid] else { return nil }
            return annot.coordinate
        }

        /// The camera round `points`, with the padding the other fits use.
        func fit(_ points: [CLLocationCoordinate2D]) {
            guard let mapView = mapView, let bounds = Self.bounds(for: points) else { return }
            mapView.setVisibleCoordinateBounds(
                bounds,
                edgePadding: MapLibreMapView.fitPadding,
                animated: true
            )
        }

        private static func bounds(for coords: [CLLocationCoordinate2D]) -> MLNCoordinateBounds? {
            guard coords.count >= 2 else { return nil }
            var minLat = coords[0].latitude
            var maxLat = coords[0].latitude
            var minLng = coords[0].longitude
            var maxLng = coords[0].longitude
            for c in coords.dropFirst() {
                minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude)
                minLng = min(minLng, c.longitude); maxLng = max(maxLng, c.longitude)
            }
            return MLNCoordinateBounds(
                sw: CLLocationCoordinate2D(latitude: minLat, longitude: minLng),
                ne: CLLocationCoordinate2D(latitude: maxLat, longitude: maxLng)
            )
        }

        // MARK: - History trails

        static let historyLinesSource = "history-trail-lines"
        static let historyPointsSource = "history-trail-points"

        /// Draws what the History sheet shows: a line per member, coloured as
        /// their marker, and a dot per fix; nothing when the sheet is down or on
        /// Live. A new answer frames the camera round it.
        func syncHistoryTrails(_ trails: [HistoryTrail], members: [CircleMember]) {
            var colors: [String: String] = [:]
            for trail in trails {
                colors[trail.userId] = MemberPalette.trail(forUserId: trail.userId, in: members).styleHex
            }
            guard trails != historyTrails || colors != historyColors else { return }
            let fresh = trails != historyTrails
            historyTrails = trails
            historyColors = colors
            drawHistoryTrails()
            if fresh, !trails.isEmpty {
                fitHistory(trails.flatMap { $0.points.map(\.coordinate) })
                didAutoFit = true
            }
        }

        /// Puts the trails into the style, adding their sources and layers the
        /// first time and after every new style (a style swap drops them).
        func drawHistoryTrails() {
            guard let style = mapView?.style else { return }
            // Nothing to draw and nothing drawn: no layers for a map whose
            // History was never opened.
            if historyTrails.isEmpty, style.source(withIdentifier: Self.historyLinesSource) == nil { return }
            let dark = lastIsDarkMode == true
            var lines: [MLNShape & MLNFeature] = []
            var points: [MLNShape & MLNFeature] = []
            for trail in historyTrails {
                let color = historyColors[trail.userId] ?? MemberPalette.stale.styleHex
                var coords = trail.points.map(\.coordinate)
                if coords.count >= 2 {
                    let line = MLNPolylineFeature(coordinates: &coords, count: UInt(coords.count))
                    line.attributes = ["color": color]
                    lines.append(line)
                }
                for point in trail.points {
                    let dot = MLNPointFeature()
                    dot.coordinate = point.coordinate
                    dot.attributes = ["color": color]
                    points.append(dot)
                }
            }
            let lineShape = MLNShapeCollectionFeature(shapes: lines)
            let pointShape = MLNShapeCollectionFeature(shapes: points)
            if let source = style.source(withIdentifier: Self.historyLinesSource) as? MLNShapeSource {
                source.shape = lineShape
            } else {
                let source = MLNShapeSource(identifier: Self.historyLinesSource, shape: lineShape, options: nil)
                style.addSource(source)
                let layer = MLNLineStyleLayer(identifier: Self.historyLinesSource + "-layer", source: source)
                layer.lineColor = NSExpression(mglJSONObject: ["to-color", ["get", "color"]])
                layer.lineWidth = NSExpression(forConstantValue: dark ? 4 : 3)
                layer.lineOpacity = NSExpression(forConstantValue: dark ? 0.95 : 0.8)
                layer.lineCap = NSExpression(forConstantValue: "round")
                layer.lineJoin = NSExpression(forConstantValue: "round")
                style.addLayer(layer)
            }
            if let source = style.source(withIdentifier: Self.historyPointsSource) as? MLNShapeSource {
                source.shape = pointShape
            } else {
                let source = MLNShapeSource(identifier: Self.historyPointsSource, shape: pointShape, options: nil)
                style.addSource(source)
                let layer = MLNCircleStyleLayer(identifier: Self.historyPointsSource + "-layer", source: source)
                layer.circleColor = NSExpression(mglJSONObject: ["to-color", ["get", "color"]])
                layer.circleRadius = NSExpression(forConstantValue: dark ? 6 : 5)
                layer.circleStrokeColor = NSExpression(forConstantValue: UIColor.white)
                layer.circleStrokeWidth = NSExpression(forConstantValue: dark ? 2.5 : 2)
                style.addLayer(layer)
            }
        }

        /// Frames a trail above the History sheet. A tight one (someone who
        /// stayed put) would zoom into the house, so under 600 m across it is
        /// zoom 14 on its middle instead, as on Android.
        private func fitHistory(_ coords: [CLLocationCoordinate2D]) {
            guard let mapView = mapView, !coords.isEmpty else { return }
            if let bounds = Self.bounds(for: coords),
               CLLocation(latitude: bounds.sw.latitude, longitude: bounds.sw.longitude)
                .distance(from: CLLocation(latitude: bounds.ne.latitude, longitude: bounds.ne.longitude)) >= 600 {
                mapView.setVisibleCoordinateBounds(
                    bounds, edgePadding: UIEdgeInsets(top: 120, left: 40, bottom: 320, right: 40), animated: true)
            } else {
                let lat = coords.map(\.latitude).reduce(0, +) / Double(coords.count)
                let lng = coords.map(\.longitude).reduce(0, +) / Double(coords.count)
                mapView.setCenter(CLLocationCoordinate2D(latitude: lat, longitude: lng), zoomLevel: 14, animated: true)
            }
        }

        func syncDroppedPin(_ coord: CLLocationCoordinate2D?) {
            guard let mapView = mapView else { return }
            if let coord = coord {
                if let existing = droppedPinAnnotation {
                    existing.coordinate = coord
                } else {
                    let annot = DroppedPinAnnotation()
                    annot.coordinate = coord
                    annot.title = "Dropped pin"
                    droppedPinAnnotation = annot
                    mapView.addAnnotation(annot)
                }
            } else if let existing = droppedPinAnnotation {
                mapView.removeAnnotation(existing)
                droppedPinAnnotation = nil
            }
        }

        /// Custom annotation views — keep MLN's reuse pool happy by
        /// keying off the annotation type, then configure with the
        /// per-annotation payload. Returning nil falls back to MLN's
        /// default red pin (used for the user-location indicator
        /// which MapLibre handles internally).
        func mapView(_ mapView: MLNMapView, viewFor annotation: MLNAnnotation) -> MLNAnnotationView? {
            if let c = annotation as? ClusterAnnotation {
                let id = "cluster"
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? ClusterMarkerView)
                    ?? ClusterMarkerView(reuseIdentifier: id)
                view.configure(count: c.count)
                return view
            }
            if let m = annotation as? MemberAnnotation {
                let id = "member"
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MemberMarkerView)
                    ?? MemberMarkerView(reuseIdentifier: id)
                view.configure(member: m)
                return view
            }
            // Fanned-out member display copy — visually identical to a real
            // member dot, so it reuses the same MemberMarkerView pool.
            if let f = annotation as? FanMemberAnnotation {
                let id = "member"
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MemberMarkerView)
                    ?? MemberMarkerView(reuseIdentifier: id)
                view.configure(fan: f)
                return view
            }
            if let p = annotation as? PlaceAnnotation {
                let id = "place"
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? PlaceMarkerView)
                    ?? PlaceMarkerView(reuseIdentifier: id)
                view.configure(
                    name: p.title ?? "Place",
                    icon: p.icon,
                    hexColor: p.hexColor,
                    isShared: p.isShared
                )
                view.setLabelHidden(mapView.zoomLevel < Self.placeLabelMinZoom)
                return view
            }
            if let d = annotation as? DestinationAnnotation {
                let id = "destination"
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? DestinationMarkerView)
                    ?? DestinationMarkerView(reuseIdentifier: id)
                view.configure(name: d.title ?? "Destination", fillColor: d.fillColor)
                view.setLabelHidden(mapView.zoomLevel < Self.placeLabelMinZoom)
                return view
            }
            if let sos = annotation as? SOSAnnotation {
                // An area: its label, no disc and no pulse.
                if let text = sos.areaLabel {
                    let id = "sos-area"
                    let view = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? SOSAreaLabelView)
                        ?? SOSAreaLabelView(reuseIdentifier: id)
                    view.setText(text)
                    return view
                }
                let id = "sos"
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? SOSMarkerView)
                    ?? SOSMarkerView(reuseIdentifier: id)
                // Set on every dequeue, not just on creation: these views come
                // back through the reuse pool and would otherwise carry the
                // previous alert's age.
                view.setCaption(sos.caption)
                return view
            }
            if annotation is DroppedPinAnnotation {
                let id = "drop"
                return (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? DroppedPinView)
                    ?? DroppedPinView(reuseIdentifier: id)
            }
            return nil
        }

        /// Center on the user the first time CoreLocation produces a
        /// valid coordinate (after onboarding grants the When-in-Use
        /// permission). Subsequent CoreLocation updates leave the
        /// camera alone so the user can pan freely.
        func mapView(_ mapView: MLNMapView, didUpdate userLocation: MLNUserLocation?) {
            guard !didCenterOnUser,
                  let coord = userLocation?.coordinate,
                  CLLocationCoordinate2DIsValid(coord),
                  abs(coord.latitude) > 0.001 || abs(coord.longitude) > 0.001 else {
                return
            }
            didCenterOnUser = true
            mapView.setCenter(coord, zoomLevel: MapLibreMapView.selfLocationZoom, animated: true)
        }

        @objc func handleSingleTap(_ gesture: UITapGestureRecognizer) {
            guard let mapView = mapView else { return }
            // A tap on empty map while a cluster fan is open dismisses the
            // fan and is consumed — don't also drop a pin / reverse-geocode.
            // Matches the Android app, where tapping away collapses the fan.
            if fannedClusterKey != nil {
                clearFan()
                return
            }
            let point = gesture.location(in: mapView)
            let coord = mapView.convert(point, toCoordinateFrom: mapView)
            parent.onMapTap(coord)
        }

        // MARK: - MLNMapViewDelegate

        func mapView(_ mapView: MLNMapView, didSelect annotation: MLNAnnotation) {
            mapView.deselectAnnotation(annotation, animated: false)
            // SOS outranks everything. Checked first so a member avatar at the
            // same coordinate — the usual case, since the raiser is a member —
            // can't swallow the tap.
            if let sosAnnot = annotation as? SOSAnnotation {
                let sosId = sosAnnot.sosId
                MainActor.assumeIsolated {
                    if let alert = SOSManager.shared.activeAlerts.first(where: { $0.id == sosId }) {
                        MapTapState.shared.selectedSOS = alert
                        MapTapState.shared.showingSOSDetail = true
                    }
                }
                return
            }
            // A raiser whose alert was merged into their avatar has no separate
            // disc to tap, so their marker has to open the SOS callout —
            // otherwise the emergency becomes unreachable from the map and the
            // tap lands on the ordinary member sheet. Covers the fanned display
            // copy too, which carries the same flag.
            var sosMemberId: String?
            if let m = annotation as? MemberAnnotation, m.hasSOS {
                sosMemberId = m.memberId
            } else if let f = annotation as? FanMemberAnnotation, f.hasSOS {
                sosMemberId = f.memberId
            }
            if let sosMemberId {
                var handled = false
                MainActor.assumeIsolated {
                    if let alert = SOSManager.shared.mappableAlerts
                        .filter({ $0.userId == sosMemberId })
                        .max(by: { $0.createdAt < $1.createdAt }) {
                        MapTapState.shared.selectedSOS = alert
                        MapTapState.shared.showingSOSDetail = true
                        handled = true
                    }
                }
                if handled { return }
            }
            // Cluster badge tap → fan its members out into a ring in place
            // (spiderfy) so coincident avatars can be tapped individually,
            // instead of zooming. Tapping the same badge again toggles the
            // fan closed; tapping a different badge swaps the fan to it. The
            // fan also dismisses on the next camera settle (applyMemberClustering
            // → clearFan). Parity with the Android app's cluster spiderfy.
            if let cluster = annotation as? ClusterAnnotation {
                if fannedClusterKey == cluster.key {
                    clearFan()
                } else {
                    fanOutCluster(cluster)
                }
                return
            }
            // Fanned member avatar tap → resolve and present the member
            // sheet exactly like a real MemberAnnotation tap (the fan copy
            // carries the same memberId/displayName).
            if let fanAnnot = annotation as? FanMemberAnnotation {
                let userId = fanAnnot.memberId
                let resolved = parent.members.first(where: { $0.userId == userId })
                    ?? MainActor.assumeIsolated { synthesizeSelfMember(userId: userId, displayName: fanAnnot.displayName) }
                if let member = resolved {
                    MainActor.assumeIsolated {
                        MapTapState.shared.selectedMember = member
                        MapTapState.shared.showingMemberDetail = true
                    }
                    return
                }
            }
            // Members: match by the userId stored on MemberAnnotation,
            // not displayName (collides between members with identical
            // names). For the current user when solo or pre-decrypt
            // — i.e. the synthesized own-marker — `parent.members` is
            // empty, so build a placeholder CircleMember on the spot
            // from AuthManager state. Matches the Android app, where
            // tapping the own marker opens the same member bottom
            // sheet as tapping any other member.
            if let memberAnnot = annotation as? MemberAnnotation {
                let userId = memberAnnot.memberId
                let resolved = parent.members.first(where: { $0.userId == userId })
                    ?? MainActor.assumeIsolated { synthesizeSelfMember(userId: userId, displayName: memberAnnot.displayName) }
                if let member = resolved {
                    // Write through the singleton ObservableObject —
                    // @State / @Binding can both drift across SwiftUI
                    // rebuilds in this code path. MapTapState.shared
                    // has stable identity, so the .sheet observer in
                    // MapView resolves to the same @Published cells
                    // we're writing to. didSelect is invoked from
                    // UIKit's main-thread delegate dispatch, so
                    // assumeIsolated is safe.
                    MainActor.assumeIsolated {
                        MapTapState.shared.selectedMember = member
                        MapTapState.shared.showingMemberDetail = true
                    }
                    return
                }
            }
            // Place tap → push to MapTapState (same singleton
            // pattern as members, so the tap never depends on
            // @State that can drift). Look up Place by the
            // annotation's placeId, not name, to sidestep
            // collisions between identically-named places.
            if let placeAnnot = annotation as? PlaceAnnotation,
               let place = parent.places.first(where: { $0.id == placeAnnot.placeId }) {
                MainActor.assumeIsolated {
                    MapTapState.shared.selectedPlace = place
                    MapTapState.shared.showingPlaceDetail = true
                }
                return
            }
        }

        // MARK: - Fan connector line and approximate area styling
        //
        // The only MLNPolyline annotations on this map are the spiderfy
        // connector lines from a cluster badge to each fanned avatar, so
        // these styling callbacks apply to all polylines unconditionally
        // (guarded on type for safety in case other polylines are added).
        // Thin neutral-gray lines that read against light + dark
        // basemaps without competing with the avatars. The only polygons are
        // approximate members' areas: their own colour, see-through, so the
        // streets under them stay readable.

        /// How opaque an approximate member's area is drawn: a faint fill, so
        /// the streets under it stay readable, inside a firmer edge.
        static let areaFillOpacity: CGFloat = 0.2
        static let areaEdgeOpacity: CGFloat = 0.7

        func mapView(_ mapView: MLNMapView, lineWidthForPolylineAnnotation annotation: MLNPolyline) -> CGFloat {
            2
        }

        func mapView(_ mapView: MLNMapView, strokeColorForShapeAnnotation annotation: MLNShape) -> UIColor {
            if let area = annotation as? ApproximateAreaPolygon {
                return area.fillColor.withAlphaComponent(Self.areaEdgeOpacity)
            }
            guard annotation is MLNPolyline else { return mapView.tintColor }
            return UIColor(white: 0.6, alpha: 0.85)
        }

        func mapView(_ mapView: MLNMapView, fillColorForPolygonAnnotation annotation: MLNPolygon) -> UIColor {
            (annotation as? ApproximateAreaPolygon)?.fillColor.withAlphaComponent(Self.areaFillOpacity)
                ?? mapView.tintColor
        }

        func mapView(_ mapView: MLNMapView, alphaForShapeAnnotation annotation: MLNShape) -> CGFloat {
            guard annotation is MLNPolyline else { return 1 }
            return 1
        }

        /// An area is only a picture: a tap inside it goes to the map (or to the
        /// avatar at its centre), not to the shape.
        func mapView(_ mapView: MLNMapView, shapeAnnotationIsEnabled annotation: MLNShape) -> Bool {
            !(annotation is ApproximateAreaPolygon)
        }

        /// Build a placeholder `CircleMember` for the current user
        /// when there's no real one in the circle members list — solo
        /// users and the first-render race window. Only valid for the
        /// own user (we have no way to synthesize another user's
        /// canonical id without a circle membership row).
        @MainActor
        private func synthesizeSelfMember(userId: String, displayName: String) -> CircleMember? {
            guard let me = AuthManager.shared.userId, me == userId else { return nil }
            let name = AuthManager.shared.currentUser?.displayName ?? (displayName.isEmpty ? "You" : displayName)
            return CircleMember(
                circleId: parent.members.first?.circleId ?? SelfKeyManager.selfCircleUuid,
                userId: userId,
                displayName: name,
                role: .owner,
                canSeeRealtime: true,
                canSeeHistory: true,
                // Display-only synthetic row for our own marker; it never enters
                // CircleManager.members, which is what the rotation sweep reads.
                // false so that if it ever did leak there it could not trigger a
                // rotation nobody asked for.
                canRotateKeys: false,
                joinedAt: Date()
            )
        }

        // Timing-instrumented phases between style assignment and the
        // map being fully rendered. Helps answer "is the style parse
        // slow, the tile fetch slow, or the tile-decode
        // slow?" — each fires once per style apply.

        private var loggedFullyRendered = false

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            if let start = styleAssignStart {
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                Self.writeMapDiag("style.didFinishLoading ms=\(ms) layers=\(style.layers.count) sources=\(style.sources.count)")
            }
            // Re-apply the cold-start self seed after the style is
            // fully parsed. MapLibre resets the camera to the style's
            // center+zoom once it loads, which otherwise erases the
            // makeUIView seed and the user sees the world default
            // for a frame. One-shot — cleared after apply so it
            // doesn't fight dark/light style swaps later in the
            // session.
            if let seed = pendingSelfSeed {
                mapView.setCenter(
                    CLLocationCoordinate2D(latitude: seed.latitude, longitude: seed.longitude),
                    zoomLevel: MapLibreMapView.selfLocationZoom,
                    animated: false
                )
                pendingSelfSeed = nil
            }
            // A new style has none of the history layers: draw them again.
            drawHistoryTrails()
        }

        func mapViewDidFinishLoadingMap(_ mapView: MLNMapView) {
            if let start = styleAssignStart {
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                Self.writeMapDiag("map.didFinishLoading ms=\(ms)")
            } else {
                Self.writeMapDiag("map.didFinishLoading (no styleAssignStart)")
            }
        }

        func mapViewDidFailLoadingMap(_ mapView: MLNMapView, withError error: Error) {
            Self.writeMapDiag("map.didFailLoading error=\(error)")
        }

        func mapViewDidFinishRenderingMap(_ mapView: MLNMapView, fullyRendered: Bool) {
            // Fires after every frame. We only care about the first
            // time the *current* viewport's tiles are fully rendered,
            // which is the user-visible "map is done loading" moment.
            guard fullyRendered, !loggedFullyRendered, let start = styleAssignStart else { return }
            loggedFullyRendered = true
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            Self.writeMapDiag("map.firstFullyRendered ms=\(ms)")
        }

        /// Zoom threshold below which place name labels are hidden,
        /// matching the Android app's `minZoom = 12f` gate.
        static let placeLabelMinZoom: Double = 12

        /// Walk every currently-rendered PlaceMarkerView and toggle
        /// its name label based on the map's current zoom. Cheap —
        /// there are typically a handful of places per circle, and
        /// `mapView.view(for:)` is a dictionary lookup.
        private func updatePlaceLabelVisibility() {
            guard let mapView = mapView else { return }
            let hidden = mapView.zoomLevel < Self.placeLabelMinZoom
            for (_, annot) in placeAnnotations {
                if let view = mapView.view(for: annot) as? PlaceMarkerView {
                    view.setLabelHidden(hidden)
                }
            }
            for (_, annot) in destinationAnnotations {
                if let view = mapView.view(for: annot) as? DestinationMarkerView {
                    view.setLabelHidden(hidden)
                }
            }
        }

        // Called after every camera move settles. The reason flag
        // distinguishes user-gesture from programmatic. We only need
        // the gesture case to cancel the cold-start "snap to live
        // self" — a user who's already panned has expressed an
        // opinion and shouldn't be yanked away. The camera view is
        // not persisted (the Android app does not either); the
        // persisted self position is updated separately by
        // SDKLocationStreamer on every successful send.
        func mapView(
            _ mapView: MLNMapView,
            regionDidChangeWith reason: MLNCameraChangeReason,
            animated: Bool
        ) {
            // Hand the settled camera to the address search sheet, which lives
            // outside this view tree and otherwise has no idea where the map is.
            // Plain assignment, not a publish — see MapViewportState.
            let bounds = mapView.visibleCoordinateBounds
            let center = mapView.centerCoordinate
            MainActor.assumeIsolated {
                MapViewportState.shared.update(
                    center: center,
                    south: bounds.sw.latitude, west: bounds.sw.longitude,
                    north: bounds.ne.latitude, east: bounds.ne.longitude
                )
            }

            updatePlaceLabelVisibility()
            // Re-cluster after the camera settles: zooming in splits badges
            // back into avatars as members separate past the screen-space
            // threshold; zooming out / panning merges them. This is the engine
            // that makes clustering track the camera.
            //
            // CRITICAL: hop off this delegate callback before mutating
            // annotations. applyMemberClustering adds/removes annotations, and
            // doing that synchronously INSIDE regionDidChange — while MapLibre
            // is still enumerating its annotations to reproject them for the
            // new camera — crashes ("mutated while enumerating"), e.g. when the
            // user zooms in past clusterMaxZoom and then taps Center-on-me: the
            // recenter's setCenter crosses the cap and re-clusters a large
            // batch (remove every avatar, add a badge) right in the callback. A
            // one-runloop async hop runs the same work after MapLibre finishes
            // the change.
            DispatchQueue.main.async { [weak self] in
                self?.applyMemberClustering()
                // Whether an avatar is covering a place's pin is a SCREEN-space
                // question, so the answer changes with the camera and nothing
                // else re-asks it — place annotations are only reconciled when
                // the place or member DATA changes. Without this, zooming in to
                // separate an avatar from the pin it sits on would leave the pin
                // hidden, which is the whole point of the screen-space rule.
                // Same async hop, for the same mutated-while-enumerating reason.
                self?.requestAnnotationResync?()
            }
            // Panning alone changes which SOS alerts are off screen.
            refreshSOSEdgeIndicators()

            let gestures: MLNCameraChangeReason = [
                .gesturePan, .gesturePinch, .gestureRotate,
                .gestureZoomIn, .gestureZoomOut,
                .gestureOneFingerZoom, .gestureTilt,
            ]
            if !reason.intersection(gestures).isEmpty {
                coldStartSelfRefinePending = false
                pendingSelfSeed = nil
            }
        }

        /// Recompute which active SOS alerts sit outside the viewport, and in
        /// what screen direction, then publish for the SwiftUI edge overlay.
        ///
        /// Direction comes from the great-circle bearing between the map centre
        /// and the alert, rotated by the camera's own heading — NOT from
        /// projecting the alert and normalising the offset. Projecting a point
        /// far outside the viewport is degenerate (behind the camera when
        /// tilted, numerically wild near the antipode); a bearing is well
        /// defined everywhere.
        func refreshSOSEdgeIndicators() {
            guard let mapView = mapView else { return }
            let alerts = MainActor.assumeIsolated { SOSManager.shared.mappableAlerts }
            guard !alerts.isEmpty else {
                MainActor.assumeIsolated {
                    if !MapTapState.shared.sosEdgeIndicators.isEmpty {
                        MapTapState.shared.sosEdgeIndicators = []
                    }
                }
                return
            }

            let center = mapView.centerCoordinate
            let cameraBearing = mapView.direction
            let viewport = mapView.bounds

            let indicators: [SOSEdgeIndicator] = alerts.compactMap { alert in
                guard let coordinate = alert.coordinate else { return nil }
                let point = mapView.convert(coordinate, toPointTo: mapView)
                if point.x.isFinite, point.y.isFinite, viewport.contains(point) { return nil }
                let bearing = Self.bearing(from: center, to: coordinate) - cameraBearing
                return SOSEdgeIndicator(sosId: alert.id, screenBearingDegrees: bearing)
            }

            MainActor.assumeIsolated {
                if MapTapState.shared.sosEdgeIndicators != indicators {
                    MapTapState.shared.sosEdgeIndicators = indicators
                }
            }
        }

        /// Initial great-circle bearing, degrees clockwise from north.
        private static func bearing(
            from: CLLocationCoordinate2D,
            to: CLLocationCoordinate2D
        ) -> Double {
            let phi1 = from.latitude * .pi / 180
            let phi2 = to.latitude * .pi / 180
            let deltaLambda = (to.longitude - from.longitude) * .pi / 180
            let y = sin(deltaLambda) * cos(phi2)
            let x = cos(phi1) * sin(phi2) - sin(phi1) * cos(phi2) * cos(deltaLambda)
            // +360 BEFORE the modulo: atan2 returns (-180, 180], so modulo
            // first would leave negatives negative and then adding 360 would
            // push a normal 45° bearing to 405°.
            return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
        }

        func mapViewDidBecomeIdle(_ mapView: MLNMapView) {
            // Map stopped issuing tile requests. Upper bound on
            // "everything that was going to load has loaded". Fires
            // many times across a session; we only log the first per
            // styleAssign cycle.
            if let start = styleAssignStart {
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                Self.writeMapDiag("map.idle ms=\(ms)")
                styleAssignStart = nil
            }
        }
    }
}

/// Singleton holder so the MLNMapView outlives SwiftUI rebuilds of
/// MapLibreMapView. Without this the map view is recreated on every
/// tab switch, MapLibre's in-memory tile cache is thrown out, and
/// the user pays the cold-cache cost on every return to Map.
@MainActor
final class MapViewHolder {
    static let shared = MapViewHolder()
    var mapView: MLNMapView?
    var lastAppliedDarkMode: Bool?
    /// Closure that collapses any open cluster fan-out, pointed at the
    /// live Coordinator's `clearFan()` and refreshed on every
    /// updateUIView. MapView's overlay controls call this at the start
    /// of their actions so a non-camera-moving control press (which
    /// wouldn't otherwise trigger the camera-settle teardown) still
    /// dismisses the fan before opening a sheet. Parity with the
    /// Android app, which collapses the cluster fan-out on any map tap
    /// or control press.
    var dismissFan: (() -> Void)?
    /// The map's clock: the live Coordinator's `refreshAges()`, refreshed
    /// on every updateUIView like `dismissFan`. MapView calls it while the
    /// app is in the foreground and the map is on screen.
    var refreshAges: (() -> Void)?
    private init() {}

    /// Logout teardown for `AuthManager.logout()`: drop the retained
    /// MLNMapView so account A's annotations can't render for account B.
    ///
    /// The held map view survives every SwiftUI rebuild, but the Coordinator
    /// that owns the reconcile dictionaries (`memberAnnotations`,
    /// `placeAnnotations`, `destinationAnnotations`, `shownMemberIds`) does
    /// NOT — a re-login hands the SAME map view to a FRESH Coordinator whose
    /// dictionaries start empty. Every removal in `syncAnnotations` is driven
    /// by those dictionaries ("a member that left", "a place that left"), so
    /// annotations the new Coordinator has no record of are unreachable: A's
    /// MemberAnnotations (decrypted display name + coordinates) and
    /// PlaceAnnotations would stay on B's map for the life of the process.
    /// The sibling managers' `reset()` calls clear the DATA; this clears the
    /// rendered copy. Parity with the Android app's `map_view` prefs wipe.
    func reset() {
        // Strip the annotations before dropping the reference: the fresh
        // makeUIView builds a new MLNMapView, but until ARC reclaims this one
        // it still holds the decrypted names + coordinates in its annotation
        // array. Belt-and-braces so nothing survives even if a stale
        // Coordinator briefly outlives the logout.
        if let mapView, let annotations = mapView.annotations {
            mapView.removeAnnotations(annotations)
        }
        mapView = nil
        lastAppliedDarkMode = nil
        // The closure captures the outgoing Coordinator; a stale MapView
        // control press must not drive a dead account's map.
        dismissFan = nil
        refreshAges = nil
    }
}

/// Persisted across launches by `SelfLocationStore`. Captures the
/// user's last-known location so a real cold start can open the map
/// centered on them (at `selfLocationZoom`) instead of flashing the
/// world default while the style + members fetch. Tab switches
/// don't need this — `MapViewHolder` keeps the live MLNMapView and
/// its camera state across SwiftUI rebuilds — but process death
/// wipes that. Updated by `SDKLocationStreamer` on every successful
/// send and by the cold-start refine in `syncAnnotations` once a
/// live fix lands. Mirrors the Android app, and is deliberately not
/// an "open at last view" restore.
struct PersistedSelfLocation: Codable {
    let latitude: Double
    let longitude: Double
}

enum SelfLocationStore {
    /// Legacy store: older builds kept the self coordinate in the standard
    /// UserDefaults (Library/Preferences plist), which is iCloud/iTunes
    /// backup-eligible and not device-bound — so the user's latest GPS fix
    /// would be recoverable from a backup. Read once for migration into the
    /// protected file below, then purged.
    private static let legacyDefaultsKey = "map.selfLocation"

    /// Protected on-disk store: a small JSON blob under Application
    /// Support, written with data protection and excluded from backup.
    /// Uses `.completeFileProtectionUntilFirstUserAuthentication`
    /// (AfterFirstUnlock) rather than the stricter `.completeFileProtection`
    /// because `SDKLocationStreamer.send` re-saves on every successful
    /// send — including background sends while the device is locked
    /// (App/Info.plist `UIBackgroundModes` → `location`) — and those
    /// writes must not throw. This matches the class the app already
    /// uses for its sensitive keychain items
    /// (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`).
    private static var fileURL: URL? {
        guard let dir = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        return dir.appendingPathComponent("map-self-location.json", isDirectory: false)
    }

    static func load() -> PersistedSelfLocation? {
        // One-time migration off the legacy plaintext UserDefaults key so
        // no self coordinate is left behind in the backup-eligible plist.
        if let legacy = UserDefaults.standard.data(forKey: legacyDefaultsKey) {
            UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
            if let position = try? JSONDecoder().decode(PersistedSelfLocation.self, from: legacy) {
                save(position)
                return position
            }
        }
        guard let url = fileURL,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PersistedSelfLocation.self, from: data)
    }

    static func save(_ position: PersistedSelfLocation) {
        // `SDKLocationStreamer.send` calls this once per TARGET, so
        // without the throttle every fix would write the same coordinate
        // N+1 times (self plus each circle), each an atomic file write
        // plus an attribute write — up to ~540 an hour while moving. A
        // seed for the next cold start needs none of that precision.
        let now = Date()
        guard lastSave.claimWrite(position, now: now) else { return }
        guard let url = fileURL,
              let data = try? JSONEncoder().encode(position) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutableURL.setResourceValues(values)
    }

    /// Skip a write that would change nothing worth keeping: within
    /// `skipWithinMeters` of the last saved position AND less than
    /// `skipWithinSeconds` after it.
    static let skipWithinMeters: CLLocationDistance = 10
    static let skipWithinSeconds: TimeInterval = 60

    static func shouldWrite(
        _ position: PersistedSelfLocation,
        lastSaved: PersistedSelfLocation?,
        lastSavedAt: Date?,
        now: Date
    ) -> Bool {
        guard let lastSaved, let lastSavedAt else { return true }
        if now.timeIntervalSince(lastSavedAt) >= skipWithinSeconds { return true }
        let moved = CLLocation(latitude: position.latitude, longitude: position.longitude)
            .distance(from: CLLocation(latitude: lastSaved.latitude, longitude: lastSaved.longitude))
        return moved >= skipWithinMeters
    }

    /// The last position written, in memory only. Locked because saves come
    /// from the send path and the map's cold-start refine.
    private final class LastSave: @unchecked Sendable {
        private let lock = NSLock()
        private var position: PersistedSelfLocation?
        private var at: Date?

        /// True — and the position recorded — when this save should write.
        func claimWrite(_ newPosition: PersistedSelfLocation, now: Date) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard SelfLocationStore.shouldWrite(newPosition, lastSaved: position, lastSavedAt: at, now: now) else {
                return false
            }
            position = newPosition
            at = now
            return true
        }

        func reset() {
            lock.lock(); defer { lock.unlock() }
            position = nil
            at = nil
        }
    }

    private static let lastSave = LastSave()

    /// Purge the persisted self coordinate (and any lingering legacy plist
    /// key). Called from AuthManager.logout() so a signed-out device keeps
    /// no location fix at rest.
    static func clear() {
        lastSave.reset()
        UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
        if let url = fileURL {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
