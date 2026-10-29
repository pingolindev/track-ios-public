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
import CoreLocation

struct MainTabView: View {
    // `-StartOnTab N` launch arg lets parity / screenshot harnesses pin
    // the initial tab. iOS auto-maps `-Key Value` launch args into
    // UserDefaults, so reading the int here is free. Defaults to 0
    // (Map) when not set.
    @StateObject private var tabSelection = TabSelectionState.shared
    /// A plain reference, not an observed object. This view only CALLS
    /// CircleManager, from its tasks; nothing in `body` reads its state. As
    /// a `@StateObject` it would make the root view re-evaluate on every
    /// one of the manager's publishes — around fourteen per refresh.
    private var circleManager: CircleManager { CircleManager.shared }
    @StateObject private var sosManager = SOSManager.shared
    /// Gates the refresh loop below. Read here, not inside the task, so the
    /// `.task(id:)` restarts it on every foreground/background edge.
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Honor `-StartOnTab N` ONLY when the launch arg is explicitly
        // set. UserDefaults.integer(forKey:) returns 0 for missing
        // keys, which would otherwise pin selected = 0 every time
        // MainTabView.init runs — and SwiftUI re-creates this View
        // value any time the parent (RootView) recomputes its body
        // (e.g., when a deep child writes a Published property that
        // bubbles up). Without this check, picking a new value in
        // Settings' time-interval picker would silently jump the user
        // back to the Map tab, because the picker change triggers a
        // body recompute that re-runs this init.
        if let raw = UserDefaults.standard.object(forKey: "StartOnTab") as? Int,
           (0...4).contains(raw) {
            TabSelectionState.shared.selected = raw
        }
    }

    var body: some View {
        TabView(selection: $tabSelection.selected) {
            MapView()
                .tabItem {
                    Label("Map", systemImage: "map.fill")
                }
                .tag(0)

            CirclesView()
                .tabItem {
                    Label("Circles", systemImage: "person.3.fill")
                }
                .tag(1)

            // Tab order matches the Android app: 0:Map, 1:Circles, 2:Safety,
            // 3:Places, 4:Settings. Safety sits at index 2 and Places at 3 —
            // the two are easy to swap by accident, and cross-platform
            // screenshot parity depends on the order.
            SOSView()
                .tabItem {
                    Label("Alerts", systemImage: sosManager.hasActiveAlert ? "exclamationmark.triangle.fill" : "exclamationmark.triangle")
                }
                .tag(2)
                // Only what the tab still asks of you: not your own alert, a
                // closed one or a dismissed one waiting out its undo window. A
                // badge you can't clear by acting on it is just noise.
                .badge(sosManager.badgeCount)

            PlacesView()
                .tabItem {
                    Label("Places", systemImage: "mappin.circle.fill")
                }
                .tag(3)

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
                .tag(4)
        }
        // A circle notification that settled as reaching nobody, or with no
        // answer at all, is said once, unmissably, wherever the person is in
        // the app: the card says it too, but the card can be left.
        .alert(sosManager.deliveryNotice?.title ?? "",
               isPresented: Binding(get: { sosManager.deliveryNotice != nil },
                                    set: { if !$0 { sosManager.deliveryNotice = nil } })) {
            Button("OK", role: .cancel) { sosManager.deliveryNotice = nil }
        } message: {
            Text(sosManager.deliveryNotice?.body ?? "")
        }
        .task {
            await loadInitialData()
        }
        .task(id: scenePhase == .active) {
            // Steady-state refresh while the app is foregrounded: re-fetch circles
            // + members on an interval so a peer joining/leaving a circle (and a new
            // member's location on the map) shows up WITHOUT an app relaunch. The
            // one-shot load above and the scenePhase/foreground handlers only cover
            // launch + resume; this closes the in-app staleness gap.
            //
            // KEYED ON THE SCENE PHASE, because `.task` alone is not foreground-
            // only. It is cancelled when the VIEW goes away, and the root tab view
            // never goes away on backgrounding — and this app is never suspended
            // in the background either: LocationService keeps a location request
            // running, which keeps the process resident. Unkeyed, this loop would
            // run all night: a /locations/latest GET every ~21 s plus the circles +
            // members + privacy GETs of each tick, thousands of background requests
            // a night from a phone in a pocket. Changing the id cancels this task on
            // the way to the background and starts a fresh one on the way back,
            // which returns at once unless active.
            guard scenePhase == .active else { return }
            // The initial load (above) and the previous tick count as fresh.
            var circlesRefreshedAt = Date()
            while !Task.isCancelled {
                try? await Task.sleep(
                    nanoseconds: UInt64(ForegroundRefreshCadence.locationsInterval * 1_000_000_000))
                if Task.isCancelled { break }
                // The circle list, members and privacy change rarely — a join, a
                // leave, a rename — and those arrive by push and pull-to-refresh
                // as well. Refetching them on every location tick would be 1 + 2N
                // GETs a tick (about 1,000 an hour with two circles) and a cache
                // write each time; every few minutes is plenty
                // (`ForegroundRefreshCadence`). Except the ACTIVE circle's
                // members' sharing: a member's "Paused" or "Location sharing
                // off" comes with their roster row, so that one roster is read
                // on every tick (one GET).
                //
                // The LIGHT path refreshes only the circle list + members
                // (GETs). It skips the once-per-session, login-weight steps —
                // pseudonym-backfill POSTs, the historical getCircleKeys import,
                // the keychain re-mirror, and a redundant key re-unwrap for
                // already-loaded circles — so this timer isn't a login-grade
                // pipeline (incl. per-tick server writes) every 30 s.
                let now = Date()
                switch ForegroundRefreshCadence.membersRead(
                    circlesDue: ForegroundRefreshCadence.circlesAreDue(lastRefreshAt: circlesRefreshedAt, now: now),
                    activeCircleId: circleManager.activeCircle?.id
                ) {
                case .everyCircle:
                    try? await circleManager.loadCircles(light: true)
                    circlesRefreshedAt = now
                case .activeCircle(let id):
                    try? await circleManager.refreshMemberSharing(for: id)
                case .noCircle:
                    break
                }
                // Member positions are useful only when the Map is visible.
                // Android stops its map poll in MapFragment.onStop; reading them
                // from every other tab spends radio and CPU drawing nothing.
                if ForegroundRefreshCadence.shouldLoadMemberLocations(selectedTab: tabSelection.selected),
                   let activeId = circleManager.activeCircle?.id {
                    try? await circleManager.loadMemberLocations(for: activeId)
                }
                // Personal history that could not be set up or opened is
                // tried again on the retry clock, never left to "reopen
                // Pingolin". A no-op unless a retry is due.
                await SelfKeyManager.retryIfDue()
            }
        }
    }

    private func loadInitialData() async {
        do {
            try await circleManager.loadCircles()
        } catch {
            print("Failed to load initial data: \(error)")
        }
        // Hydrate destinations at launch (android keeps them in Room, so
        // its arrival detector sees them without any screen visit). This
        // also instantiates the DestinationsManager singleton, whose
        // location subscription drives auto-arrival.
        await DestinationsManager.shared.refresh()
        // Re-derive any place-alert match hash the server flagged stale, at launch.
        //
        // A circle key rotation (what a member removal does) re-keys the hash the
        // place-alerts worker matches crossings against, so every server-hash alert
        // in that circle silently stops firing until a client re-derives it. That
        // recovery lives in refreshAllAlerts; called only from PlacesView, it would
        // run solely if the user happened to open Places, which nothing prompts
        // them to. Android heals off its background location tick
        // (BoundaryRepository -> refreshPlaceAlerts); this gives iOS the same
        // guarantee.
        //
        // Same reasoning as the destinations hydrate above, and placed after
        // loadCircles because the hashes are derived from the circle keys it loads.
        do {
            try await PlaceManager.shared.refreshAllAlerts()
        } catch {
            // Logged, never swallowed: a recovery path that fails
            // invisibly leaves a stale alert not healing, with no way
            // to see why.
            NSLog("[place-alerts] launch refresh failed: %@", String(describing: error))
        }
        // What the Notification Service Extension needs from the app (detail
        // level, API base URL), mirrored into the app group before any push
        // can arrive for it to rewrite.
        ExtensionBridge.sync()
        // The Task below starts evaluating client-only "watch a member"
        // inactivity rules — the server can't (their watcher set is E2EE),
        // so this device fires them. Mirrors the Android app's foreground
        // inactivity loop. Deferred a few seconds so its extra calls
        // (inactivity-alerts, alert-rules, locations) don't pile onto the
        // cold-start auth burst; the coalesced token refresh handles
        // concurrency, but a quieter start is still kinder to the session.
        Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            MonitoringManager.shared.startInactivityWatch()
            // Own-battery reporting, so the circle-mates who asked to be told
            // can be told. No global switch: whether a circle may see the level
            // at all is that circle's "Share Battery Level" consent, which is
            // also what gates the wake (mayShareBattery) — the same shape as
            // the Android app's MonitoringManager.
            MonitoringManager.shared.startBatteryMonitoring()
        }
    }
}

/// How often the foreground loop re-fetches each kind of data.
enum ForegroundRefreshCadence {
    /// Member locations: every tick while the Map tab is selected. This matches
    /// the Android app's 30-second map poll and makes a peer's marker move
    /// without spending a request while another tab is on screen.
    static let locationsInterval: TimeInterval = 30
    /// Map is tab 0 in both clients.
    static let mapTabIndex = 0
    static func shouldLoadMemberLocations(selectedTab: Int) -> Bool {
        selectedTab == mapTabIndex
    }
    /// Circles, every circle's members and privacy: a few minutes. The active
    /// circle's members' sharing is read on every tick in between
    /// (`membersRead`).
    static let circlesInterval: TimeInterval = 180

    /// A few seconds of slack, so a tick landing a hair early is not pushed a
    /// whole extra tick later.
    static func circlesAreDue(lastRefreshAt: Date?, now: Date) -> Bool {
        guard let last = lastRefreshAt else { return true }
        return now.timeIntervalSince(last) >= circlesInterval - 5
    }

    /// Whose members a tick reads. A member's "Paused" or "Location
    /// sharing off" comes with their roster row; the web and Android show it
    /// within 30 s, and with members read only on the circles cadence an
    /// iPhone would show it up to three minutes late. So the active circle's
    /// roster is read on every tick for its members' sharing
    /// (`refreshMemberSharing`), and a due circle list (which reads every
    /// circle's members in full) stands in for it.
    enum MembersRead: Equatable {
        case everyCircle
        case activeCircle(String)
        case noCircle
    }

    static func membersRead(circlesDue: Bool, activeCircleId: String?) -> MembersRead {
        if circlesDue { return .everyCircle }
        if let activeCircleId { return .activeCircle(activeCircleId) }
        return .noCircle
    }
}

/// Cross-tab navigation state. PlacesView writes
/// `selected = 0` to jump back to the map; the bound TabView in
/// MainTabView reacts. Singleton has stable identity so writes from
/// any view in the tree resolve to the same @Published cell — same
/// pattern as MapTapState. iOS Map index is 0; this is set from the
/// `-StartOnTab` launch arg in init() and otherwise stays at 0.
@MainActor
final class TabSelectionState: ObservableObject {
    static let shared = TabSelectionState()
    @Published var selected: Int = 0
    private init() {}
}

/// Notification deep-link state — the iOS analog of the Android app's
/// `navigate_to` intent extras. PushAppDelegate writes a route
/// when a destination notification is tapped; MapView observes and
/// presents the matching sheet over the map. Consumers nil it out after
/// presenting so a later tab return doesn't re-trigger.
///
/// Also used in-app wherever a screen outside the map wants the map pointed
/// somewhere — tapping a member in the circles list raises `.focusMember`.
/// The mechanism is the same either way, so it stays one route rather than
/// two parallel ones.
@MainActor
final class NotificationRouteState: ObservableObject {
    static let shared = NotificationRouteState()
    enum Route {
        case notifications
        case destinations
        /// Zoom the map to a shared destination's coordinate (a
        /// "destination shared" tap), resolved client-side from the id on
        /// the push. Mirrors the Android app.
        case focusCoordinate(CLLocationCoordinate2D)
        /// Focus a member's marker + open their detail — raised by a "member
        /// arrived" notification tap (the marker then reads "At <Place>") and
        /// by tapping a member row in a circle.
        case focusMember(userId: String)
        /// Somebody has asked to take over a circle. Opens the screen with the
        /// owner's refuse control on it. The push says "Open Pingolin to
        /// refuse" and the circle transfers on silence, so this tap has to land
        /// somewhere the owner can actually act rather than on a list.
        case ownershipClaim(circleId: String)
        /// A circle on its own screen: raised by a tap on the claimant's "your
        /// request was refused". Not the claim's screen: that is the owner's,
        /// and the request is over.
        case circle(circleId: String)
        /// Fly to an alert and open its detail, as its row on the Alerts tab
        /// does: raised by a tap on "<name> needs attention". The id
        /// alone: the map looks the alert up in what it lists when it shows it.
        case focusAlert(alertId: String)
    }
    @Published var pending: Route?
    private init() {}
}

#Preview {
    MainTabView()
}
