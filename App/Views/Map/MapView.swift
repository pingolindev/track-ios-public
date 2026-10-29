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
import struct PingolinTrackSDK.Location
import struct PingolinTrackSDK.GeocodingResult

struct MapView: View {
    @StateObject private var circleManager = CircleManager.shared
    @StateObject private var locationService = LocationService.shared
    @StateObject private var placeManager = PlaceManager.shared
    /// Observed, not just read: the account (`currentUser`) can arrive after
    /// the map is up, when the launch couldn't read /auth/me at first and reads
    /// it again (`AuthManager.retryLaunchRead`), and the guardian line follows.
    @StateObject private var authManager = AuthManager.shared
    @StateObject private var destinationsManager = DestinationsManager.shared
    @StateObject private var invitesManager = InvitesManager.shared
    // Drives the top-right notification bell's unread badge.
    @StateObject private var notificationsManager = NotificationsManager.shared
    @StateObject private var hiddenDestinations = HiddenDestinationsStore.shared
    @State private var recenterTrigger: Int = 0
    @State private var fitAllTrigger: Int = 0
    // Member-tap state lives on a singleton ObservableObject instead
    // of @State or @Binding: the writer (MLNMapViewDelegate inside the
    // persistent MapViewHolder Coordinator) would bind to a stale
    // @State backing across SwiftUI rebuilds, writing to a
    // property-wrapper instance that has drifted from the live storage
    // SwiftUI observes for the .sheet modifier. A singleton
    // ObservableObject has stable identity; both writer and reader
    // resolve to the same @Published cell regardless of view-tree
    // churn.
    @StateObject private var mapTapState = MapTapState.shared
    @StateObject private var sosManager = SOSManager.shared
    /// Last verdict on the personal (self-tracking) key, for the banner below
    /// the permission warning. Settings renders the same notice; this is the
    /// copy a user who never opens Settings will actually see.
    @StateObject private var selfKeyStatus = SelfKeyStatus.shared
    @ObservedObject private var keyStoreRecovery = KeyStoreRecovery.shared
    /// Notification-tap deep links (PushAppDelegate writes, we present).
    @StateObject private var notificationRoute = NotificationRouteState.shared
    @State private var showingCheckIn = false
    /// The circle the check-in sheet opened for: the map's when tapped, and
    /// where its check-in goes, whatever the map shows by the time it is sent.
    @State private var checkInCircleId: String?
    @State private var showingNotifications = false
    /// DestinationsView list sheet (deep-link target). Distinct from
    /// `showingDestinations`, which presents the map's destination
    /// PICKER (MapDestinationPicker).
    @State private var showingDestinationsList = false
    /// Circle whose ownership claim a notification tap asked to open. Non-nil
    /// presents the screen with the owner's refuse control on it.
    @State private var ownershipClaimTarget: OwnershipClaimTarget?
    /// Circle a notification tap asked to open on its own screen: the
    /// claimant's "your request was refused".
    @State private var circleTarget: CircleScreenTarget?
    @State private var sendingLocation = false
    @State private var sendToast: String?
    @State private var sendToastToken: Int = 0
    /// A toast's words held back while a sheet closes (`showSendToast`), said
    /// once it has gone (`announceHeldToast`).
    @State private var heldToastAnnouncement: String?
    /// Debounced gate for the "couldn't reach server" pill. A single
    /// failed poll sets lastLocationRefreshFailedAt immediately, but
    /// app-resume often drops + re-establishes the connection within a
    /// second — flashing the alarming red pill. Only flip this true after
    /// the failure has persisted FAILURE_PILL_GRACE, and clear it the
    /// instant a refresh succeeds. Mirrors the Android app.
    @State private var showOfflinePill = false
    @StateObject private var tabSelection = TabSelectionState.shared
    /// Tap-to-place state. When non-nil the user tapped the map at this
    /// coordinate; we drop a temporary marker, reverse-geocode the
    /// point, and show a card with Add-to-Places / Share / Copy.
    @State private var droppedPin: CLLocationCoordinate2D?
    /// Reverse-geocode / search result for the dropped pin. Holds the
    /// structured fields (street text, city/state/country, optional
    /// POI name) so the placard can render them like the Android
    /// app's `cardTappedLocation` — full address on top, locality on
    /// the second line, coordinates underneath.
    @State private var droppedPinResult: GeocodingResult?
    /// Loading flag — true while reverse geocoding is in flight; the
    /// placard renders "Looking up address…" until it clears.
    @State private var droppedPinLoading: Bool = false
    @State private var fabStackExpanded = false
    @State private var showingSearch = false
    @State private var showingDestinations = false
    @State private var showingHistory = false
    /// One for the map's life, so the map sees its trails; `open` points it
    /// at a circle, and at one member or everyone.
    @StateObject private var history = HistoryViewModel()
    /// Coordinate handed to CreatePlaceFromMapSheet / ShareDestinationSheet
    /// when the user picks the corresponding action on the dropped-pin card.
    /// Tracking the coordinate alongside the bool means a re-tap of the
    /// same coordinate still presents the sheet (vs comparing against
    /// the previous identity).
    @State private var placeSheetCoordinate: CLLocationCoordinate2D?
    @State private var destinationSheetCoordinate: CLLocationCoordinate2D?
    /// Neutral premium notice shown when a free user attempts to share
    /// a destination (see presentShareDestination).
    @State private var showingDestinationPremiumNotice = false
    @State private var flyToCoordinate: CLLocationCoordinate2D?
    /// An SOS shown as an area is framed whole (`MapLibreMapView.sosFraming`).
    @State private var flyToFit: [CLLocationCoordinate2D]?
    @State private var shareSheetItem: ShareSheetItem?
    @State private var layersExpanded = false
    @AppStorage("map.layer.members") private var showMembers = true
    @AppStorage("map.layer.places") private var showPlaces = true
    @AppStorage("map.layer.sharedPlaces") private var showSharedPlaces = true
    @AppStorage("map.layer.destinations") private var showDestinations = true
    @AppStorage("map.layer.boundaries") private var showBoundaries = true
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase

    /// Full explanation behind the standing guardian line. The line is the
    /// hook; the consequences need more room than a line and are too important
    /// to be reachable only from Settings.
    @State private var showGuardianDetail = false

    /// Whether the day the guardian named has arrived.
    ///
    /// Compared here rather than on the server on purpose: the prompt has to
    /// reach the account's own user, and a guardian-held account's email is the
    /// guardian's, so anything mailed reaches the watcher instead. Nil or
    /// malformed reads as not due, which errs toward saying nothing rather than
    /// announcing a handover on a date we cannot substantiate.
    private var handoverDue: Bool {
        guard let named = authManager.guardian.handoverDate,
              named.count >= 10 else { return false }
        let today = ISO8601DateFormatter.string(
            from: Date(), timeZone: .current, formatOptions: [.withFullDate]
        )
        return String(named.prefix(10)) <= today
    }

    private var effectiveDarkMode: Bool { colorScheme == .dark }

    /// Where the map goes to show an SOS: a point at street zoom, an area
    /// framed whole, never entered at its centre.
    private func show(_ alert: SOSAlert, at coordinate: CLLocationCoordinate2D) {
        if let area = MapLibreMapView.sosFraming(alert) {
            flyToFit = area
        } else {
            flyToCoordinate = coordinate
        }
    }

    // Extracted from body so the 14-modifier chain below applies to an
    // opaque `some View` instead of re-inferring the whole ZStack each
    // time — keeps the Swift type-checker under budget on this large view.
    private var mapStack: some View {
            ZStack {
                // Protomaps tiles via MapLibre Native iOS. Same
                // visual style as the Android app. Annotations are routed
                // through MLNMapView, gestures handled natively.
                MapLibreMapView(
                    recenterTrigger: $recenterTrigger,
                    fitAllTrigger: $fitAllTrigger,
                    droppedPin: $droppedPin,
                    flyToCoordinate: $flyToCoordinate,
                    flyToFit: $flyToFit,
                    memberLocations: showMembers ? effectiveMemberLocations : [],
                    places: visiblePlaces,
                    destinations: showDestinations ? destinationMarkers : [],
                    members: memberList,
                    // Gated on the setting HERE, not just where the cache is
                    // filled: the member-tap sheet resolves addresses whether or
                    // not the setting is on (a tap is its own request), so
                    // handing the raw cache over would put an address on a
                    // marker the user asked not to see one on.
                    // Cross-circle and NOT gated by a layer toggle: an active
                    // SOS is not something the user can switch off alongside
                    // places or destinations.
                    sosAlerts: sosManager.mappableAlerts,
                    historyTrails: showingHistory ? Self.trailsShown(history.trails, roster: memberList) : [],
                    isDarkMode: effectiveDarkMode,
                    onPlaceTap: { _ in },
                    onMapTap: handleMapTap
                )
                // Nav bar is hidden, so let the map fill behind the
                // top safe-area too (the overlay VStack still respects
                // the status-bar inset for its content, so the circle
                // chip + refresh pill don't slide under the notch).
                .ignoresSafeArea()

                // Edge arrows for off-screen SOS alerts. Above the map, below
                // the control overlays so it can never cover a button; it only
                // takes touches that land on an arrow.
                SOSEdgeIndicatorOverlay(
                    indicators: mapTapState.sosEdgeIndicators,
                    onTap: { sosId in
                        guard let alert = sosManager.activeAlerts.first(where: { $0.id == sosId }),
                              let coordinate = alert.coordinate else { return }
                        // Fly there AND open the callout, so the arrow is a
                        // route to the emergency rather than just a hint.
                        show(alert, at: coordinate)
                        mapTapState.selectedSOS = alert
                        mapTapState.showingSOSDetail = true
                    }
                )
                .ignoresSafeArea()

                // Overlay controls — layout mirrors the Android app:
                // top-left circle selector, top-right notification bell
                // (always-visible with an unread badge, as on Android),
                // left-side stack of map controls (center on
                // all, recenter, toggle layers), right-side FAB stack
                // (search, quick check-in, send location now).
                VStack {
                    HStack(alignment: .top) {
                        CircleSelectorButton()
                        Spacer()
                        notificationBellButton()
                    }
                    .padding()

                    Spacer()

                    HStack(alignment: .bottom) {
                        // Left control stack — camera controls grouped
                        // together (center-on-all, recenter-on-me,
                        // toggle layers). Matches Android's
                        // mapControlsLeft semantics; the recenter
                        // affordance lives here too,
                        // leaving the right FAB stack for actions
                        // only.
                        //
                        // Labels render alongside while the (+) FAB
                        // stack is expanded — mirrors the Android app's
                        // "open menu = every reachable button tells you
                        // what it does" rule.
                        VStack(alignment: .leading, spacing: 12) {
                            // Icon semantics:
                            //   person.3.fill — group of people for
                            //     "all members" (unambiguous since it
                            //     literally shows people).
                            //   scope — crosshair for "recenter on me";
                            //     reads as locking the camera onto a
                            //     single target, paired with the group
                            //     glyph above so the two centering
                            //     actions don't collide visually.
                            labeledRow(label: "Center on all", showLabel: fabStackExpanded, anchor: .trailing) {
                                mapControlButton(systemImage: "person.3.fill", label: "Center on all members", action: centerOnAll)
                            }
                            labeledRow(label: "Recenter on me", showLabel: fabStackExpanded, anchor: .trailing) {
                                mapControlButton(systemImage: "scope", label: "Recenter on me", action: recenterMap)
                            }
                            labeledRow(label: "Layers", showLabel: fabStackExpanded, anchor: .trailing) {
                                // Collapse any open cluster fan-out first — a
                                // non-camera-moving control press wouldn't
                                // otherwise dismiss it. Mirrors the Android app.
                                mapControlButton(systemImage: "square.3.layers.3d", label: "Toggle layers", action: { MapViewHolder.shared.dismissFan?(); layersExpanded.toggle() })
                            }
                        }

                        Spacer()

                        // Right FAB stack — actions, in ONE visual
                        // hierarchy, taken from the Android app rather
                        // than invented:
                        //
                        //   fabSendLocation  mini, colorPrimary ← accent
                        //   fabQuickCheckIn  mini, colorSurfaceVariant
                        //   fabSearch        mini, colorSurfaceVariant
                        //   fabExpand (⋮)    mini, colorSurfaceVariant
                        //   fabHistory       mini, colorSurfaceVariant
                        //   fabDestinations  mini, colorSurfaceVariant
                        //   fabTracking      normal, colorPrimary
                        //                    (gone unless tracking is
                        //                    running — a status
                        //                    indicator, not a resting
                        //                    control)
                        //
                        // So in the resting state there is exactly one
                        // tinted control, Send location, and everything
                        // else is a neutral disc: `.prominent` for send,
                        // `.neutral` for the rest, which is the same
                        // white disc the left column uses. One thing on
                        // the map is loud, and it is the action that
                        // changes what the circle sees.
                        //
                        // Order is Android's too, including its divider
                        // rule: the expandable rows fan out ABOVE the
                        // overflow button, the persistent ones sit BELOW
                        // it. That also puts Send location at the
                        // bottom, in the easiest place to reach
                        // one-handed.
                        //
                        // The glyph is `ellipsis`, not `plus`. "+"
                        // promises adding something and the menu adds
                        // nothing: it holds History and Destinations,
                        // both of which are places to go. Android calls
                        // the same button ic_more_vert. iOS uses the
                        // horizontal ellipsis because that is the
                        // platform's overflow idiom.
                        //
                        // Labels render to the left of every FAB while
                        // the menu is expanded — Android parity. The
                        // overflow FAB itself is intentionally unlabeled
                        // (its icon morphs ⋯↔× so any static label would
                        // lie).
                        VStack(alignment: .trailing, spacing: 12) {
                            if fabStackExpanded {
                                labeledRow(label: "Destinations", showLabel: true, anchor: .leading) {
                                    fab(systemImage: "flag.fill", accessibilityLabel: "Destinations", role: .neutral, action: {
                                        MapViewHolder.shared.dismissFan?()
                                        fabStackExpanded = false
                                        showingDestinations = true
                                    })
                                }
                                labeledRow(label: "History", showLabel: true, anchor: .leading) {
                                    // Collapse the cluster fan before opening a
                                    // sheet.
                                    fab(systemImage: "clock.arrow.circlepath", accessibilityLabel: "History", role: .neutral, action: {
                                        MapViewHolder.shared.dismissFan?()
                                        fabStackExpanded = false
                                        openHistory()
                                    })
                                }
                            }
                            // The divider between the two groups.
                            fab(
                                systemImage: fabStackExpanded ? "xmark" : "ellipsis",
                                accessibilityLabel: fabStackExpanded ? "Close actions" : "More actions",
                                role: .neutral,
                                action: { MapViewHolder.shared.dismissFan?(); fabStackExpanded.toggle() }
                            )
                            labeledRow(label: "Search", showLabel: fabStackExpanded, anchor: .leading) {
                                fab(systemImage: "magnifyingglass", accessibilityLabel: "Search", role: .neutral, action: { MapViewHolder.shared.dismissFan?(); showingSearch = true })
                            }
                            labeledRow(label: "Check in", showLabel: fabStackExpanded, anchor: .leading) {
                                fab(systemImage: "hand.wave.fill", accessibilityLabel: "Check in", role: .neutral, action: { MapViewHolder.shared.dismissFan?(); checkInCircleId = circleManager.activeCircle?.id; showingCheckIn = true })
                            }
                            labeledRow(label: "Send location", showLabel: fabStackExpanded, anchor: .leading) {
                                fab(systemImage: "paperplane.fill", accessibilityLabel: "Send location", role: .prominent, disabled: sendingLocation, action: sendLocationNow)
                            }
                        }
                    }
                    .padding()
                }

                // Layer-toggle chip card (top-right, Android-parity).
                // Expanded by Toggle Layers; tap the same button, any chip, or
                // anywhere outside the card to collapse.
                if layersExpanded {
                    // Outside-tap catcher. Without it the
                    // card would survive Search, Check In,
                    // the member card and a long-press,
                    // sitting over the map through every one
                    // of them, and the only way back would be
                    // the same FAB again. Clear, not dimmed:
                    // this is a lightweight chip card, not a
                    // modal, and dimming the map would
                    // overstate it.
                    Color.clear
                        .contentShape(Rectangle())
                        .ignoresSafeArea()
                        .onTapGesture { layersExpanded = false }
                        .accessibilityHidden(true)

                    VStack {
                        HStack {
                            Spacer()
                            layerChipsCard
                                .padding(.top, 64)
                                .padding(.trailing, 12)
                        }
                        Spacer()
                    }
                    .transition(.opacity)
                }

                // The map's notices, in ONE column under the top
                // controls (`topNotices`): the guardian line first,
                // then the place card, the banners, the refresh pill
                // and the toast. Notices at fixed offsets of their
                // own would overlap when two show together; in one
                // stack nothing covers anything, and the guardian
                // line is never pushed off.
                topNotices

            }
    }

    /// The map's notices, top down, in one column under the top controls
    /// (see `mapStack`): the guardian line, which states a standing condition
    /// and so comes first and never moves; the place card, which the person
    /// just asked for with a tap on the map; the invitation, a call to act from
    /// someone else; the permission, personal-key and key-store banners; then
    /// the refresh pill and the toast, which come and go, last, so neither
    /// moves a banner when it does.
    private var topNotices: some View {
        VStack(spacing: 8) {
            // Room for the top row, laid out as it is: the circle selector's
            // own frame, hidden, with the row's top and side padding and a
            // bell-wide gap, so it wraps as the real one does. Never less than
            // 56, so with the spacing the column starts at 64 (the Android
            // app's 72dp margin, where the pill sits), and 8
            // pt under the selector when the text size makes it taller: two
            // lines and more ("Select" / "Circle"), where the line, a Button,
            // would sit over its lower part and take its taps. In the same
            // layout pass as everything else; nothing is measured.
            ZStack(alignment: .top) {
                Color.clear.frame(height: 56)
                HStack(alignment: .top) {
                    CircleSelectorButton()
                    Spacer()
                    Color.clear.frame(width: 44, height: 0)
                }
                .padding([.top, .horizontal])
            }
            .hidden()
            .accessibilityHidden(true)

            // Standing disclosure for an account somebody else set up
            // and still holds the password to.
            //
            // Sits with the map chrome rather than in Settings, because the
            // person who needs it is the one who does not already suspect and
            // will never open a settings screen to find out. Not dismissible:
            // it states a permanent condition, and anything with a close
            // control teaches people to close it. Neutral colours on purpose —
            // a guardian is usually not a threat and this is a supported
            // arrangement, so it states the consequence and lets the reader
            // draw the conclusion.
            if authManager.guardian.managed {
                guardianLine
            }

            // Place-info card (slides down) when a map tap drops a pin. Mirrors
            // Android's cardPlaceInfo with the same three actions. It lives in
            // this column: placed 8 pt from the top on its own, it would cover
            // the top controls and, being taller than the gap, the column's
            // top.
            if let pin = droppedPin {
                placeInfoCard(coordinate: pin)
                    .padding(.horizontal)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            // Pending circle invites. Highest-priority banner since it's a
            // time-sensitive call-to-action from another user. Tap → switches
            // to the Circles tab where Accept / Decline live (a one-tap accept
            // on the Map would bypass the inviter's display name + circle name
            // context).
            if let invite = invitesManager.invites.first {
                pendingInviteBanner(invite: invite, extra: invitesManager.invites.count - 1)
                    .padding(.horizontal)
                    .transition(.opacity)
            }

            // Permission-warning banner. Surfaces when the user's location
            // authorization is in a state that breaks continuous tracking
            // (anything other than Always — SLC / Visit / background updates
            // silently no-op otherwise). The Settings tab has the same banner;
            // duplicating it here means a user who only opens the Map tab
            // still discovers the gap. One tap either re-fires the iOS native
            // prompt (when one is still available) or deep-links to Settings.
            if let warning = locationPermissionWarning {
                locationPermissionBanner(warning: warning)
                    .padding(.horizontal)
                    .transition(.opacity)
            }

            // Personal-key failure. Same argument as the permission banner
            // above, and the same resolution: Settings carries this notice
            // too, and duplicating it here is the only way a user who lives on
            // the Map tab finds out that personal history and personal places
            // are unreadable and that personal tracking is not recording.
            // Nothing else on screen says so — the symptom is an absence.
            //
            // Errors only (`deservesTopLevelSurface`). A failed lookup clears
            // itself on the next launch and a banner for it would just teach
            // people to ignore this spot.
            if let notice = selfKeyStatus.notice,
               selfKeyStatus.health.deservesTopLevelSurface {
                selfKeyBanner(notice: notice)
                    .padding(.horizontal)
                    .transition(.opacity)
            }

            // The key store's sync error (`KeyStoreRecovery`): a seed or
            // entries that didn't read. The app still works, so a banner
            // and no sign-out; the tap opens Settings, where Sign Out is.
            if keyStoreRecovery.showsSyncBanner {
                syncErrorBanner
                    .padding(.horizontal)
                    .transition(.opacity)
            }

            // Refresh-status pill — "Updating…" while a location fetch is in
            // flight, "Couldn't reach server" after a network failure. Hidden
            // when steady so success isn't celebrated; absence of the pill IS
            // the success signal. Mirrors the Android app's cardRefreshStatus
            // so cached markers don't look authoritative on a spotty
            // connection.
            if let pill = refreshPillState {
                refreshPill(state: pill)
                    .padding(.horizontal)
                    .transition(.opacity)
            }

            // Send-location toast — auto-dismissing capsule so the user always
            // knows whether the paperplane tap actually did something (success
            // / rate-limit / error). Without this, a no-op tap is
            // indistinguishable from a real send.
            if let toast = sendToast {
                sendToastCapsule(toast)
            }

            Spacer()
        }
        // Hung from its top at every text size. A stack taller than the screen
        // (the largest sizes, every notice up) would be centred, which lifts
        // the line, and the map's controls with it, up the screen. What doesn't
        // fit runs off the bottom, toast first.
        .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
    }

    /// The standing guardian line: the consequence in one line, and a tap for
    /// the full explanation (`showGuardianDetail`). Its words are in the label
    /// colour, black or white, in both states: neutral, and readable. In a
    /// Button the hierarchical styles are the tint's, accent blue: `.secondary`
    /// would measure 1.94:1 in light and 1.73:1 in dark, and the accent itself
    /// is under 4.5:1 here.
    private var guardianLine: some View {
        Button {
            showGuardianDetail = true
        } label: {
            Text(handoverDue
                 ? "This account should now be yours"
                 : "Location and history visible to guardian")
                .font(.caption)
                .fontWeight(handoverDue ? .medium : .regular)
                .foregroundStyle(Color.primary)
                // Never cut short. At the largest text sizes, with every notice
                // up, the stack would squeeze its texts, and the disclosure
                // would read "Location and histor…". What doesn't fit runs off
                // the bottom instead (the column hangs from its top).
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(.regularMaterial, in: Capsule())
        }
        // Above the rest of the column: what slides in below it (the place card,
        // the toast, both `.move(edge: .top)`) passes under the line, not over it.
        .zIndex(1)
    }

    // The map's modifier chain (.animation ×6, .task ×2, .toolbar, .sheet ×10,
    // .onReceive, .shareSheet, .onChange, .task) is too long for the Swift
    // type-checker as one expression. Split into three generic passes so
    // each is checked independently. Behavior is identical to one chain.
    private func mapChromeA<V: View>(_ base: V) -> some View {
        base
            .animation(.easeInOut(duration: 0.18), value: sendToast)
            .animation(.easeInOut(duration: 0.15), value: layersExpanded)
            // 150ms matches the FAB-row fade duration on Android.
            .animation(.easeInOut(duration: 0.15), value: fabStackExpanded)
            .animation(.easeInOut(duration: 0.2), value: droppedPin?.latitude)
            .animation(.easeInOut(duration: 0.18), value: circleManager.isRefreshingLocations)
            .animation(.easeInOut(duration: 0.18), value: showOfflinePill)
            // Debounce the offline pill. Keyed on the *failed-state Bool*
            // (not the timestamp) so repeated failures don't restart the
            // grace wait; the task restarts only when the state flips
            // failed<->ok. A success (-> nil) hides the pill instantly; a
            // failure shows it only if it survives the grace window — so a
            // brief app-resume reconnect blip stays silent.
            .task(id: circleManager.lastLocationRefreshFailedAt != nil) {
                if circleManager.lastLocationRefreshFailedAt == nil {
                    showOfflinePill = false
                    return
                }
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if !Task.isCancelled && circleManager.lastLocationRefreshFailedAt != nil {
                    showOfflinePill = true
                }
            }
            // The map's clock: markers' ages ("now", "12m"), their grey
            // past 15 minutes and an SOS disc's caption move on with the
            // time, not only when a position comes in. At once on
            // showing, then every 30 s. KEYED ON THE SCENE PHASE like
            // MainTabView's loop, because `.task` alone keeps running in
            // the background in this app; cancelled too when the map
            // leaves the screen.
            .task(id: scenePhase == .active && tabSelection.selected == ForegroundRefreshCadence.mapTabIndex) {
                guard scenePhase == .active,
                      tabSelection.selected == ForegroundRefreshCadence.mapTabIndex else { return }
                while !Task.isCancelled {
                    MapViewHolder.shared.refreshAges?()
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                }
            }
            // The Android map screen is fullscreen: the active
            // circle's name lives in the floating cardCircleSwitcher
            // (top-right), not a toolbar. iOS surfaces the
            // same name via CircleSelectorButton at the top-left, so
            // a SwiftUI nav bar would duplicate it and add an
            // opaque dark background. The toolbar is hidden
            // entirely; the map gets the full screen.
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $mapTapState.showingMemberDetail, onDismiss: announceHeldToast) {
                if let member = mapTapState.selectedMember {
                    MemberDetailSheet(
                        member: member,
                        onViewHistory: {
                            // That member's history alone,
                            // not the circle's.
                            let circleId = circleManager.activeCircle?.id ?? SelfKeyManager.selfCircleUuid
                            history.open(circleId: circleId, memberId: member.userId, memberName: member.displayName)
                            showingHistory = true
                        },
                        onShareDestination: { coord, addressLine in
                            // Reuse the dropped-pin → share-destination
                            // pipeline so the sheet's pre-fill matches
                            // the other entry points (Search,
                            // Destinations). Synthesize a
                            // GeocodingResult from the address line we
                            // already have so droppedPinDisplayName /
                            // addressHint render the same.
                            droppedPin = coord
                            droppedPinResult = GeocodingResult(
                                text: addressLine ?? "",
                                lat: coord.latitude,
                                lng: coord.longitude,
                                resultType: "address",
                                confidence: 1.0,
                                name: nil,
                                city: nil,
                                state: nil,
                                postcode: nil,
                                country: nil,
                                address: addressLine
                            )
                            droppedPinLoading = false
                            presentShareDestination(coordinate: coord)
                        },
                        onOpenPlace: { place in
                            // Close this sheet before opening the next: the two
                            // are separate `.sheet` modifiers on the same view,
                            // and presenting one while the other is still up is
                            // a no-op on iOS. The hop lets the dismissal land
                            // first.
                            mapTapState.showingMemberDetail = false
                            DispatchQueue.main.async {
                                mapTapState.selectedPlace = place
                                mapTapState.showingPlaceDetail = true
                            }
                        }
                    )
                }
            }
            .sheet(isPresented: $mapTapState.showingPlaceDetail, onDismiss: announceHeldToast) {
                if let place = mapTapState.selectedPlace {
                    PlaceDetailSheet(
                        place: place,
                        onShareDestination: { coord, address in
                            // Reuse the dropped-pin → share-destination
                            // pipeline so a tapped place can be re-
                            // broadcast to a circle. Same plumbing the
                            // member-tap "Share as Destination" path
                            // uses.
                            droppedPin = coord
                            droppedPinResult = GeocodingResult(
                                text: address ?? "",
                                lat: coord.latitude,
                                lng: coord.longitude,
                                resultType: "address",
                                confidence: 1.0,
                                name: nil,
                                city: nil,
                                state: nil,
                                postcode: nil,
                                country: nil,
                                address: address
                            )
                            droppedPinLoading = false
                            presentShareDestination(coordinate: coord)
                        }
                    )
                }
            }
            .alert(handoverDue ? "This account is yours now" : "This account was set up by a guardian", isPresented: $showGuardianDetail) {
                Button("OK", role: .cancel) {}
            } message: {
                Text((handoverDue ? "The day your guardian named as the handover has passed, so this account is yours now. They cannot hand it over themselves and we will not do it silently - write to help@support.pingolin.com and we will walk you through taking it over, including the recovery key and any passkey that would otherwise keep working.\n\n" : "") + "Whoever set this account up knows its password, and the password is what decrypts your data - so they can see where you are now, everywhere you have been for as long as this circle keeps history, and they can set alerts telling them when you arrive somewhere or leave.\n\nNothing tells you when they look. There is no notification, no record you can read, and no way for us to show you one - checking a map leaves no trace.\n\nWhen you turn 18 the account becomes yours and their responsibility for it ends. Changing the password alone does not remove their access, because a recovery key or a passkey they registered keeps working. Section 6 of the Terms has the steps.\n\nIf asking them is not safe, do not ask. You can write to abuse@mail.pingolin.com instead - a minor may report an account held by a guardian, and so may an adult about one a guardian set up for them.")
            }
            .alert("Premium feature", isPresented: $showingDestinationPremiumNotice) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Sharing destinations with your circle is a premium feature.")
            }
    }

    private func mapChromeB<V: View>(_ base: V) -> some View {
        base
            .sheet(isPresented: $showingCheckIn, onDismiss: announceHeldToast) {
                QuickCheckInSheet(circleId: checkInCircleId)
            }
            .sheet(isPresented: $showingNotifications) {
                NavigationStack {
                    NotificationsView(showsDoneButton: true)
                }
            }
            .sheet(isPresented: $showingDestinationsList, onDismiss: announceHeldToast) {
                NavigationStack {
                    DestinationsView()
                }
            }
            // Notification-tap deep links — the iOS analog of
            // the Android app's MainActivity navigate_to handling.
            // PushAppDelegate has already switched to the Map tab
            // before writing the route.
            .onReceive(notificationRoute.$pending) { route in
                guard let route = route else { return }
                notificationRoute.pending = nil
                switch route {
                case .notifications: showingNotifications = true
                case .destinations: showingDestinationsList = true
                case .focusCoordinate(let coord): flyToCoordinate = coord
                case .focusMember(let userId): focusMember(userId: userId)
                case .ownershipClaim(let circleId):
                    ownershipClaimTarget = OwnershipClaimTarget(id: circleId)
                case .circle(let circleId):
                    circleTarget = CircleScreenTarget(id: circleId)
                case .focusAlert(let alertId):
                    if let alert = sosManager.activeAlerts.first(where: { CanonicalId.same($0.id, alertId) }),
                       let coord = alert.coordinate {
                        show(alert, at: coord)
                        mapTapState.selectedSOS = alert
                        mapTapState.showingSOSDetail = true
                    } else {
                        // It ended, or lost its position, between the tap and
                        // the map showing (behind App Lock, say): the Alerts
                        // tab, where its state is, rather than a bare map.
                        TabSelectionState.shared.selected = 2
                    }
                }
            }
            .sheet(item: $ownershipClaimTarget) { target in
                NavigationStack {
                    OwnershipClaimScreen(circleId: target.id)
                }
            }
            .sheet(item: $circleTarget) { target in
                NavigationStack {
                    NotifiedCircleScreen(circleId: target.id)
                }
            }
            .sheet(isPresented: $showingSearch) {
                AddressSearchView { result in
                    // Drop a pin at the searched location and reuse
                    // the picked GeocodingResult directly — the user
                    // just chose this label, so there's no point
                    // re-reverse-geocoding the coordinate.
                    let coord = CLLocationCoordinate2D(latitude: result.lat, longitude: result.lng)
                    droppedPin = coord
                    droppedPinResult = result
                    droppedPinLoading = false
                    flyToCoordinate = coord
                }
            }
            .sheet(isPresented: $showingDestinations, onDismiss: announceHeldToast) {
                MapDestinationPicker { coord in
                    droppedPin = coord
                    droppedPinResult = nil
                    droppedPinLoading = true
                    Task {
                        let result = await GeocodingService.shared.reverse(
                            latitude: coord.latitude,
                            longitude: coord.longitude
                        )
                        droppedPinResult = result
                        droppedPinLoading = false
                    }
                    flyToCoordinate = coord
                }
            }
    }

    private func mapChromeC<V: View>(_ base: V) -> some View {
        base
            // Someone's history is shown again: the open sheet reads it
            // again, rather than keep an answer read while it was off.
            .onChange(of: historyOffMembers) { before, after in
                if showingHistory, Self.historyReturned(before: before, after: after) {
                    Task { await history.refreshIfNeeded() }
                }
            }
            .sheet(isPresented: $showingHistory, onDismiss: announceHeldToast) {
                HistorySheet(viewModel: history)
            }
            // A circle this account is in no more: what the map has open of
            // it closes, and says why in the circle screen's words, as this
            // account no longer gets that circle's updates. Wherever the map
            // is: a place's or an alert's sheet of it, the destinations lists
            // while they show any of its, and a check-in opened for it. When
            // it was the map's circle, also the member's card and the
            // history, as the map moves on.
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
            .sheet(item: Binding(
                get: { placeSheetCoordinate.map(CoordinateID.init) },
                set: { placeSheetCoordinate = $0?.coordinate }
            )) { id in
                CreatePlaceFromMapSheet(
                    coordinate: id.coordinate,
                    addressHint: droppedPinResult?.text,
                    onCreated: {
                        placeSheetCoordinate = nil
                        showSendToast("Place added")
                        dismissDroppedPin()
                    }
                )
            }
            .sheet(item: Binding(
                get: { destinationSheetCoordinate.map(CoordinateID.init) },
                set: { destinationSheetCoordinate = $0?.coordinate }
            )) { id in
                ShareDestinationSheet(
                    coordinate: id.coordinate,
                    initialName: droppedPinDisplayName ?? "",
                    addressHint: droppedPinResult?.text,
                    onShared: {
                        destinationSheetCoordinate = nil
                        showSendToast("Destination shared")
                        dismissDroppedPin()
                    }
                )
            }
            .shareSheet(item: $shareSheetItem)
            .sheet(isPresented: $mapTapState.showingSOSDetail, onDismiss: announceHeldToast) {
                if let alert = mapTapState.selectedSOS {
                    SOSDetailSheet(
                        alert: alert,
                        memberName: memberList.first(where: { $0.userId == alert.userId })?.displayName,
                        onDismissAlert: {
                            Task { try? await sosManager.dismissSOS(alert) }
                        }
                    )
                    .presentationDetents([.medium])
                }
            }
            .onChange(of: mapTapState.pendingFocusSOS) { _, focus in
                // Safety screen handed off an alert to show. Fly to it AND open
                // the callout — unlike the place hand-off, where the marker tap
                // is the affordance, the point of tapping an SOS row is to see
                // the emergency's detail immediately.
                guard let alert = focus, let coord = alert.coordinate else { return }
                show(alert, at: coord)
                mapTapState.selectedSOS = alert
                mapTapState.showingSOSDetail = true
                DispatchQueue.main.async { mapTapState.pendingFocusSOS = nil }
            }
            .onChange(of: mapTapState.pendingFocusPlace) { _, focus in
                // PlacesView "tap a row" handed off a place to fly
                // to. Just move the camera — the marker tap is the
                // affordance for opening details. Clear the signal
                // so a subsequent tap of the same row fires again.
                guard let place = focus else { return }
                let coord = CLLocationCoordinate2D(
                    latitude: place.latitude,
                    longitude: place.longitude
                )
                flyToCoordinate = coord
                DispatchQueue.main.async { mapTapState.pendingFocusPlace = nil }
            }
            // Keyed on the active circle id so this RE-RUNS when the active
            // circle resolves. On a cold start loadCircles() assigns it once
            // the list's current keys are installed, so a plain `.task`
            // would run first with activeCircle == nil: the member-location
            // fetch would be skipped and never retried, leaving the map with
            // NO member markers even on a perfectly healthy session.
            // `.task(id:)` fires again on the nil → id transition (and on
            // any circle switch), reloading member locations for the
            // now-resolved circle.
            .task(id: circleManager.activeCircle?.id) {
                // Parallelize the two map-paint fetches — the Android app
                // does the same on the Kotlin side.
                // loadMemberLocations + loadPlaces have no
                // inter-dependency, so running them concurrently
                // halves first-paint latency on cold caches.
                // Members only exist on real circles; places
                // exist on both real circles (own + shared) AND
                // under the self-circle for solo users. Fall
                // back to the self-circle id when no active
                // circle so solo users still see their personal
                // places on the map.
                let placesCircleId = circleManager.activeCircle?.id ?? SelfKeyManager.selfCircleUuid
                async let places: () = placeManager.loadPlaces(for: placesCircleId)
                // Cheap unread-count GET so the bell badge is current on
                // open (full list fetch is deferred to the sheet).
                async let unread: () = notificationsManager.refreshUnreadCount()
                if let activeId = circleManager.activeCircle?.id {
                    // Typed rather than `()`: loadMemberLocations returns a
                    // MemberLocationRefresh for the alert evaluators. This call
                    // site only wants the side effect of populating the map, so
                    // it discards it — but an `async let` binding carries an
                    // explicit type and cannot ignore one the way a plain call can.
                    async let members: CircleManager.MemberLocationRefresh =
                        circleManager.loadMemberLocations(for: activeId)
                    _ = try? await members
                }
                _ = try? await places
                await unread
            }
    }

    var body: some View {
        NavigationStack {
            mapChromeC(mapChromeB(mapChromeA(mapStack)))
        }
    }

    private var memberList: [CircleMember] {
        guard let circleId = circleManager.activeCircle?.id else { return [] }
        return circleManager.members[circleId] ?? []
    }

    /// `memberLocations` plus this account's own marker, taken from this
    /// phone alone. Solo users (no active circle, or active circle whose
    /// members haven't decrypted yet) otherwise have an empty
    /// `memberLocations` and fall through to MapLibre's stock blue GPS dot —
    /// visually inconsistent with the colored MemberMarkerView every other member
    /// gets. Mirrors the Android app, which always renders the own marker from
    /// the session's last known location.
    private var effectiveMemberLocations: [LocationData] {
        Self.withOwnPosition(
            Self.withFrozen(
                Self.withoutMembersNotSharing(
                    Self.inCircle(circleManager.memberLocations.values, circleManager.activeCircle?.id), roster: memberList),
                frozen: Self.inCircle(circleManager.frozenLocations.values, circleManager.activeCircle?.id),
                roster: memberList),
            me: AuthManager.shared.userId,
            own: locationService.currentLocation,
            circleId: circleManager.activeCircle?.id ?? SelfKeyManager.selfCircleUuid,
            deviceId: AuthManager.shared.deviceId ?? ""
        )
    }

    /// This account's marker is this phone's own fix and nothing else: any row
    /// naming this account, in any spelling, is dropped, and `own`
    /// (`LocationService.currentLocation`) is added when there is one. Before
    /// the first fix there is no colored marker; MapLibre's stock dot shows
    /// this phone's position meanwhile (`showsUserLocation`).
    static func withOwnPosition(
        _ locations: [LocationData], me: String?, own: CLLocation?, circleId: String, deviceId: String
    ) -> [LocationData] {
        var locs = locations.filter { !CanonicalId.same($0.userId, me) }
        if let me, let own {
            locs.append(LocationData.ownPosition(own, userId: me, circleId: circleId, deviceId: deviceId))
        }
        return locs
    }

    /// No marker for a member whose sharing is off or paused in the active
    /// circle (`MemberSharingStatus.showsMarker`): the position this phone last
    /// had for them is not where they are, and their row and card say why. The
    /// cached position stays put, so they come back the moment the roster says
    /// they share again.
    static func withoutMembersNotSharing(
        _ locations: [LocationData], roster: [CircleMember], now: Date = Date()
    ) -> [LocationData] {
        let hidden = Set(roster.filter { !$0.sharing(at: now).showsMarker }.map { CanonicalId.key($0.userId) })
        guard !hidden.isEmpty else { return locations }
        return locations.filter { !hidden.contains(CanonicalId.key($0.userId)) }
    }

    /// The rows of the circle on the map, and no other. The held rows are
    /// keyed by member, and a circle switch keeps the last circle's: drawn on
    /// the new one's map, someone only in the last circle would show as a grey
    /// "Member" until sign-out. The frozen rows too: a member who switched
    /// real-time off in one circle may share live in another.
    static func inCircle<Rows: Sequence>(_ rows: Rows, _ circleId: String?) -> [LocationData]
    where Rows.Element == LocationData {
        rows.filter { CanonicalId.sameKey($0.circleId, circleId) }
    }

    /// One held row, when it is the circle on the map's.
    static func heldRow(_ row: LocationData?, in circleId: String?) -> LocationData? {
        row.flatMap { CanonicalId.sameKey($0.circleId, circleId) ? $0 : nil }
    }

    /// Whether someone's history is shown to the circle again: the server's
    /// read brings all of it back, the time it was off too.
    static func historyReturned(before: Set<String>, after: Set<String>) -> Bool {
        !before.subtracting(after).isEmpty
    }

    /// Members of the circle on the map whose history it isn't shown.
    private var historyOffMembers: Set<String> {
        Set(memberList.filter { !$0.sharesHistory }.map { CanonicalId.key($0.userId) })
    }

    /// The trails the History sheet draws, without anyone whose history the
    /// roster now says this circle isn't shown: an answer read before they
    /// turned it off is not drawn on.
    static func trailsShown(_ trails: [HistoryTrail], roster: [CircleMember]) -> [HistoryTrail] {
        let hidden = Set(roster.filter { !$0.sharesHistory }.map { CanonicalId.key($0.userId) })
        guard !hidden.isEmpty else { return trails }
        return trails.filter { !hidden.contains(CanonicalId.key($0.userId)) }
    }

    /// The last location a member who switched real-time sharing off shared,
    /// frozen and drawn as such (`LocationData.sharingOff`), in place of any
    /// row this phone held for them. Never for one the roster shows paused: a
    /// pause wins, and they are drawn nowhere.
    static func withFrozen(
        _ locations: [LocationData], frozen: [LocationData], roster: [CircleMember], now: Date = Date()
    ) -> [LocationData] {
        let paused = Set(roster.filter {
            if case .paused = $0.sharing(at: now) { return true }
            return false
        }.map { CanonicalId.key($0.userId) })
        let shown = frozen.filter { !paused.contains(CanonicalId.key($0.userId)) }
        guard !shown.isEmpty else { return locations }
        let frozenIds = Set(shown.map { CanonicalId.key($0.userId) })
        return locations.filter { !frozenIds.contains(CanonicalId.key($0.userId)) } + shown
    }

    private var visiblePlaces: [Place] {
        let activeId = circleManager.activeCircle?.id
        return placeManager.places.filter { place in
            // Personal (self-circle): show under "Places" — always
            // visible regardless of which circle is active. Solo
            // users only ever have these.
            if place.circleId == SelfKeyManager.selfCircleUuid {
                return showPlaces
            }
            // Place owned by / shared into the active circle: show
            // under "Shared Places".
            if let active = activeId, place.circleId == active {
                return showSharedPlaces
            }
            // Anything else (place visible via a different circle):
            // show under "Places".
            return showPlaces
        }
    }

    /// Active destinations to plot, scoped to the active circle (matches
    /// android's "destinations for the current circle"). Color-by-creator
    /// is resolved in syncAnnotations from the member list.
    ///
    /// A PURE FILTER: no `hiddenDestinations.prune` here. A view-body
    /// evaluation must not mutate an `@Published` store, and
    /// `destinationsManager` is empty until its first `refresh()`, so a
    /// prune here would run against an empty live list — destructive on
    /// one — and hidden destinations would come back on every launch. The
    /// prune happens in `DestinationsManager.refresh()`, against the raw
    /// server ids, where a complete list is actually in hand.
    private var destinationMarkers: [Destination] {
        let activeId = circleManager.activeCircle?.id ?? SelfKeyManager.selfCircleUuid
        return destinationsManager.activeDestinations.filter {
            $0.circleId == activeId && !hiddenDestinations.isHidden($0.id)
        }
    }

    /// Zoom to a member's last-known location and open their detail sheet
    /// (which shows "At <Place>" if they're at one). Driven by an arrival-
    /// notification tap — iOS focuses the member rather than the bare
    /// destination coordinate — and by tapping a member in the circles list.
    ///
    /// Both the roster and `memberLocations` are scoped to the active circle
    /// and reload asynchronously, so a tap that comes from another circle
    /// arrives here before there is anything to point at. Waiting for a bounded
    /// spell is the difference between "focuses the member" and "does nothing
    /// at all"; after that we use whatever half we did get.
    private func focusMember(userId: String) {
        Task { @MainActor in
            // This account's position is this phone's own fix:
            // there is no row of it to wait for.
            let isMe = CanonicalId.same(userId, AuthManager.shared.userId)
            for _ in 0..<Self.focusMemberPollAttempts {
                if isMe || Self.heldRow(circleManager.memberLocations[userId], in: circleManager.activeCircle?.id) != nil,
                   memberList.contains(where: { $0.userId == userId }) {
                    break
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            if isMe {
                if let own = locationService.currentLocation { flyToCoordinate = own.coordinate }
            } else if let loc = Self.heldRow(circleManager.memberLocations[userId], in: circleManager.activeCircle?.id) {
                // Not to the old position of someone not sharing: the sheet
                // below says why there is no marker.
                if !Self.withoutMembersNotSharing([loc], roster: memberList).isEmpty {
                    flyToCoordinate = loc.coordinate
                }
            }
            if let member = memberList.first(where: { $0.userId == userId }) {
                MapTapState.shared.selectedMember = member
                MapTapState.shared.showingMemberDetail = true
            }
        }
    }

    /// 8 × 250ms — the same order of patience as the Android
    /// app's MEMBER_FOCUS_TIMEOUT_MS.
    private static let focusMemberPollAttempts = 8

    /// The toast as it shows in the map's column of notices (`topNotices`).
    private func sendToastCapsule(_ toast: String) -> some View {
        Text(toast)
            .font(.subheadline)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
            .transition(.move(edge: .top).combined(with: .opacity))
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private var layerChipsCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            layerChip("Members", isOn: $showMembers)
            layerChip("Places", isOn: $showPlaces)
            layerChip("Shared Places", isOn: $showSharedPlaces)
            layerChip("Destinations", isOn: $showDestinations)
            // "Alert areas": a boundary is just a place's enter/leave
            // alert region.
            layerChip("Alert areas", isOn: $showBoundaries)
        }
        .padding(12)
        .background(.ultraThinMaterial)
        .cornerRadius(12)
        .shadow(radius: 4)
    }

    @ViewBuilder
    private func layerChip(_ label: String, isOn: Binding<Bool>) -> some View {
        Button(action: { isOn.wrappedValue.toggle() }) {
            HStack(spacing: 6) {
                Image(systemName: isOn.wrappedValue ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isOn.wrappedValue ? .blue : .secondary)
                Text(label)
                    .font(.footnote)
                    .foregroundStyle(.primary)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func placeInfoCard(coordinate: CLLocationCoordinate2D) -> some View {
        // Primary = POI name OR first comma-segment of `text` (the
        // street/POI line). Pelias's `text` already embeds locality
        // (e.g. "900 East 11th Street, Austin, TX, USA"), so using
        // it as-is and ALSO showing structured city/state/country
        // below duplicates the locality. Take only the head segment
        // for the title; the secondary line below is the canonical
        // locality breakdown.
        let primary: String = {
            if droppedPinLoading { return "Looking up address…" }
            guard let r = droppedPinResult else { return "Unknown location" }
            if let name = r.name, !name.isEmpty { return name }
            let head = r.text.split(separator: ",").first.map {
                String($0).trimmingCharacters(in: .whitespaces)
            }
            return head ?? r.text
        }()
        // Secondary = "City, State, Country" from structured fields.
        // Falls back to the tail of `text` past the first comma for
        // geocoders that don't surface structured locality (e.g. the
        // offline tile geocoder).
        let secondary: String? = {
            guard let r = droppedPinResult else { return nil }
            var parts: [String] = []
            if let c = r.city, !c.isEmpty { parts.append(c) }
            if let s = r.state, !s.isEmpty { parts.append(s) }
            if let co = r.country, !co.isEmpty { parts.append(co) }
            if !parts.isEmpty { return parts.joined(separator: ", ") }
            let segments = r.text.split(separator: ",").map {
                String($0).trimmingCharacters(in: .whitespaces)
            }
            return segments.count >= 2 ? segments.dropFirst().joined(separator: ", ") : nil
        }()

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "mappin.and.ellipse")
                    .foregroundStyle(.blue)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(primary)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .lineLimit(2)
                    if let secondary = secondary {
                        Text(secondary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Text(String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
                Spacer()
                Button(action: dismissDroppedPin) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Button("Add to Places") { addDroppedPinToPlaces(coordinate: coordinate) }
                        .buttonStyle(.bordered)
                    // There is no separate "Add boundary" entry: a boundary is just
                    // a place with a geofence area, set via the create-place sheet's
                    // area toggle.
                }
                HStack(spacing: 8) {
                    Button("Create Destination") { shareDroppedPin(coordinate: coordinate) }
                        .buttonStyle(.bordered)
                    Button("Copy Address") { copyAddress() }
                        .buttonStyle(.bordered)
                        // No address yet (or none found) means nothing honest to
                        // copy. Disabled beats a button that silently hands over
                        // a lat/lng pair the label never promised.
                        .disabled(droppedPinResult?.text.isEmpty ?? true)
                }
            }
            .controlSize(.small)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(.ultraThinMaterial)
        .cornerRadius(12)
        .shadow(radius: 4)
    }

    private func dismissDroppedPin() {
        droppedPin = nil
        droppedPinResult = nil
        droppedPinLoading = false
    }

    private func handleMapTap(coordinate: CLLocationCoordinate2D) {
        droppedPin = coordinate
        droppedPinResult = nil
        droppedPinLoading = true
        // GeocodingService.reverse routes to either the server proxy
        // (Pelias) or the on-device TileGeocoder depending on the
        // Settings → Geocoding toggle.
        Task {
            let result = await GeocodingService.shared.reverse(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude
            )
            droppedPinResult = result
            droppedPinLoading = false
        }
    }

    private func addDroppedPinToPlaces(coordinate: CLLocationCoordinate2D) {
        // Present a sheet for name + icon + color + circle picker.
        // Mirrors the Android app's showCreatePlaceFromMapDialog; a
        // bare "just call createPlace" path would silently no-op
        // for solo users (no active circle) and give them no
        // affordance to customize.
        placeSheetCoordinate = coordinate
    }

    private func shareDroppedPin(coordinate: CLLocationCoordinate2D) {
        // Present a sheet for circle picker + name + notify toggle.
        // Mirrors the Android app's showShareDestinationDialog.
        // "Share Destination" broadcasts through the circle by
        // creating a server-side Destination; it does not share a
        // maps URL out-of-band (as a UIActivityViewController
        // would).
        presentShareDestination(coordinate: coordinate)
    }

    /// Single gate for every share-destination entry point (dropped pin,
    /// member detail, place detail). Destinations are a premium feature —
    /// the server rejects create for free circles — so stop the flow here
    /// instead of walking the user through the whole sheet only to fail
    /// at Share. The notice is neutral and CTA-free: App Store
    /// anti-steering rules forbid directing to an external purchase flow —
    /// the same reasoning behind the Android gate.
    private func presentShareDestination(coordinate: CLLocationCoordinate2D) {
        guard PremiumManager.shared.effectivePremium else {
            showingDestinationPremiumNotice = true
            // Self-heal a stale-false gate: the cached flag seeds from
            // UserDefaults (false on a fresh login) and only the login
            // path refreshes it, so a genuinely-premium user who lands
            // here before that lands gets wrongly blocked. Kick a refresh
            // so the NEXT attempt is correct. refresh() preserves a
            // cached Premium on an inconclusive/offline result, so this
            // can never downgrade. Mirrors the Android app.
            Task { await PremiumManager.shared.refresh() }
            return
        }
        destinationSheetCoordinate = coordinate
    }

    /// Short human-readable label for the dropped pin — used as the
    /// "Add to Places" default name and the Share-Destination title.
    /// Prefers a POI name; falls back to the first segment of the
    /// full address text.
    private var droppedPinDisplayName: String? {
        guard let r = droppedPinResult else { return nil }
        if let name = r.name, !name.isEmpty { return name }
        return r.text.split(separator: ",").first.map(String.init)
    }

    private func copyAddress() {
        // An address, not a lat/lng pair: it is what a person can paste into a
        // message or a taxi app, and it is what the button says it is.
        guard let address = droppedPinResult?.text, !address.isEmpty else { return }
        // Still a decrypted location → local-only, off Universal
        // Clipboard, expiring after 60s. An address is no less
        // sensitive than the coordinates it came from.
        UIPasteboard.general.setItems(
            [[UIPasteboard.typeAutomatic: address]],
            options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(60)]
        )
    }

    private func recenterMap() {
        // Camera move already collapses the fan transitively; dismiss
        // up front anyway so every control behaves identically
        // (the Android app does the same for btnRecenterOnMe).
        MapViewHolder.shared.dismissFan?()
        // MapLibreMapView watches `recenterTrigger`; bumping it asks the
        // wrapper to fly the camera back to the user's live CoreLocation.
        recenterTrigger &+= 1
    }

    private func centerOnAll() {
        // As with recenter, the resulting camera move would collapse the
        // fan on its own; call up front for uniformity (the Android app
        // does the same for btnCenterOnAll).
        MapViewHolder.shared.dismissFan?()
        fitAllTrigger &+= 1
    }

    private func openHistory() {
        // Fall back to the nil-UUID self circle when the user hasn't
        // joined a circle yet — same approach as the Android app's
        // "Just Me" mode (LocationRepository.SELF_CIRCLE_UUID).
        // Their own self-tracking history is stored under the nil
        // pseudo-circle on the server and decrypts with the self key
        // SelfKeyManager bootstrapped at login.
        let circleId = circleManager.activeCircle?.id ?? SelfKeyManager.selfCircleUuid
        history.open(circleId: circleId, memberId: nil, memberName: nil)
        showingHistory = true
    }


    private func sendLocationNow() {
        // Collapse any open cluster fan-out — this control doesn't move
        // the camera, so it wouldn't otherwise dismiss (the Android app
        // does the same for fabSendLocation).
        MapViewHolder.shared.dismissFan?()
        // Solo users (no circle joined yet) fall back to the nil-UUID
        // self-tracking pseudo-circle. Mirrors the Android app's
        // MapViewModel.sendLocationNow self-tracking branch — the app
        // is useful with one user tracking themselves, no circle
        // required.
        let circleId = circleManager.activeCircle?.id ?? SelfKeyManager.selfCircleUuid
        let isSelf = circleId == SelfKeyManager.selfCircleUuid
        Self.writeSendDiag("tap circleId=\(circleId.prefix(8)) isSelf=\(isSelf)")
        // Respect the per-circle privacy gate before uploading a manual
        // exact fix. This "Send Location Now" path is a send route
        // outside the background gate: a paused / realtime-off circle
        // (or one whose settings haven't loaded yet — mayStreamRealtime
        // fails CLOSED) must not receive a fix its members could
        // decrypt. Self stays exempt (mayStreamRealtime returns true for
        // the self pseudo-circle).
        guard circleManager.mayStreamRealtime(to: circleId) else {
            Self.writeSendDiag("send blocked by privacy gate circleId=\(circleId.prefix(8))")
            showSendToast("This circle is paused or not sharing realtime location")
            return
        }
        sendingLocation = true
        Task {
            defer { Task { @MainActor in sendingLocation = false } }
            do {
                Self.writeSendDiag("requesting single location")
                let cl = try await locationService.requestSingleLocation()
                Self.writeSendDiag("got location lat=\(cl.coordinate.latitude) lng=\(cl.coordinate.longitude)")
                // Also what the liveness check-in re-sends, when newer (`adoptSentFix`).
                locationService.adoptSentFix(cl)
                // With the battery level: this becomes the
                // newest point a watcher's low-battery rule
                // judges.
                let loc = PingolinTrackSDK.Location.forSend(cl)
                let result = SDKLocationStreamer.shared.sendNow(circleId: circleId, location: loc)
                Self.writeSendDiag("sendNow result=\(result)")
                switch result {
                case .success:
                    showSendToast(isSelf ? "Location saved" : "Location sent")
                case .rateLimited(let waitSeconds):
                    showSendToast("Wait \(waitSeconds)s before sending again")
                case .failed(let message):
                    showSendToast(message)
                }
            } catch {
                Self.writeSendDiag("threw \(error)")
                showSendToast("Couldn't read your location: \(error.plainText)")
            }
        }
    }

    /// Append a line to Documents/send-location-diag.log: a
    /// device-side trace of the Send-Location flow, for diagnosing a
    /// toast that vanishes or never appears. Each line carries a
    /// wall-clock timestamp for ordering. Cheap; only fires on the
    /// user-initiated tap path.
    // Debug builds only: "got location" lines carry full-precision lat/lng
    // and Documents/ is backed up. No-op in release.
    private static func writeSendDiag(_ message: String) {
        #if DEBUG
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return
        }
        let url = docs.appendingPathComponent("send-location-diag.log")
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(stamp) \(message)\n"
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

    /// Show a transient capsule toast at the top of the map. Auto-
    /// dismisses after ~2.5s. The `sendToastToken` guard prevents a
    /// stale dismissal from clearing a newer toast.
    @MainActor
    /// - Parameter afterDismissal: a sheet is closing as this shows. VoiceOver
    ///   can cut off what is said while the screen changes, so the words are
    ///   said once the sheet has gone: its `onDismiss` (`announceHeldToast`),
    ///   the dismissal's own end, not a guessed delay.
    private func showSendToast(_ message: String, afterDismissal: Bool = false) {
        sendToastToken &+= 1
        let token = sendToastToken
        sendToast = message
        // Said to VoiceOver too: the toast is a bare Text, gone in 2.5 s,
        // so someone who can't see it would hear a sheet close, or a send
        // end, and never why.
        if afterDismissal {
            heldToastAnnouncement = message
        } else {
            AccessibilityNotification.Announcement(message).post()
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if sendToastToken == token {
                sendToast = nil
                // No dismissal came in the toast's time: said now rather than
                // never.
                announceHeldToast()
            }
        }
    }

    /// The words a closing sheet held back (`showSendToast`), said once: from
    /// that sheet's `onDismiss`, or at the toast's end if none came.
    private func announceHeldToast() {
        guard let message = heldToastAnnouncement else { return }
        heldToastAnnouncement = nil
        AccessibilityNotification.Announcement(message).post()
    }

    /// One of three states the top refresh-status pill can be in.
    private enum RefreshPillState { case updating, offline }

    /// Resolve the pill's current state from CircleManager. Nil hides
    /// the pill — that's the steady-state "everything's fine" signal
    /// (we don't celebrate success).
    private var refreshPillState: RefreshPillState? {
        if circleManager.isRefreshingLocations { return .updating }
        if showOfflinePill { return .offline }
        return nil
    }

    /// Permission-state taxonomy for the top-of-map warning banner.
    /// `.authorizedAlways` is the only good state for background
    /// continuity; everything else breaks SLC / Visit / background
    /// updates and we want the user to know on the screen they live
    /// on rather than discovering it under Settings.
    /// Shared with SettingsView through `LocationPermissionWarning.resolve`, so
    /// the two surfaces cannot name different problems for one state.
    private var locationPermissionWarning: LocationPermissionWarning? {
        LocationPermissionWarning.resolve(
            status: locationService.authorizationStatus,
            hasReducedAccuracy: locationService.hasReducedAccuracy
        )
    }

    @ViewBuilder
    private func locationPermissionBanner(warning: LocationPermissionWarning) -> some View {
        let (title, body, buttonLabel): (String, String, String) = {
            switch warning {
            case .notDetermined:
                return (
                    "Location is off",
                    "Track needs your location to share with circles.",
                    "Allow Location"
                )
            case .whenInUse:
                return (
                    "Background tracking is off",
                    "Track only updates while the app is open. Enable Always so your circles see your location during drives, walks, and stops.",
                    // iOS shows the Always prompt at most once. After that this
                    // tap deep-links to Settings, and onboarding already spends
                    // the one prompt for every user who finishes it — so the
                    // label reads "Open Settings" once the prompt is spent,
                    // rather than promising something the tap cannot do.
                    alwaysPromptAvailable ? "Enable Background Tracking" : "Open Settings"
                )
            case .denied:
                return (
                    "Location is denied",
                    LocationOffCopy.denied,
                    "Open Settings"
                )
            case .restricted:
                return (
                    "Location is restricted",
                    LocationOffCopy.restricted,
                    "Open Settings"
                )
            case .reducedAccuracy:
                return (
                    "Your circle can't see you",
                    "Precise Location is off, so iOS only tells Track roughly which area you are in — too coarse to put you on the map.",
                    // Same two-pronged handler, so the same honesty about the
                    // label: once declined, iOS suppresses the prompt and this
                    // is a trip to Settings.
                    precisePromptAvailable ? "Turn On Precise Location" : "Open Settings"
                )
            }
        }()
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "location.slash.fill")
                .foregroundStyle(.orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.footnote)
                    .fontWeight(.semibold)
                    .fixedSize(horizontal: false, vertical: true)
                Text(body)
                    .font(.caption)
                    .foregroundStyle(Color.a11ySecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Button(buttonLabel) {
                    handleLocationPermissionTap(warning: warning)
                }
                .font(.footnote)
                .buttonStyle(.borderedProminent)
                .tint(Color.a11yAccent)
                .controlSize(.small)
                .fixedSize(horizontal: true, vertical: true)
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        // Opaque: the audit measures rendered pixels over whatever the map
        // happens to be showing, so a translucent material cannot guarantee
        // the documented text contrast.
        .background(Color(uiColor: .systemBackground))
        .cornerRadius(10)
        .shadow(radius: 2)
    }

    /// The personal-key notice, in the shape of the permission banner beside
    /// it.
    ///
    /// Title and detail come from `SelfKeyHealth.notice`, the same value
    /// SettingsView renders, so the two surfaces cannot drift into saying
    /// different things about one state — the distinction that earns its keep
    /// there ("only another device can fix this" vs "sign in again") is
    /// worthless if the Map paraphrases it. Clipped to three lines because the
    /// full instruction is a paragraph and this sits over a map; the tap opens
    /// Settings, where it is shown whole.
    private func selfKeyBanner(notice: SelfKeyNotice) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: notice.severity == .error
                  ? "exclamationmark.triangle.fill"
                  : "exclamationmark.circle")
                .foregroundStyle(notice.severity == .error ? Color.red : Color.orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text(notice.title)
                    .font(.footnote)
                    .fontWeight(.semibold)
                Text(notice.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(.ultraThinMaterial)
        .cornerRadius(10)
        .shadow(radius: 2)
        .contentShape(Rectangle())
        .onTapGesture { TabSelectionState.shared.selected = 4 }
        .accessibilityIdentifier("self-key-map-banner")
        .accessibilityHint("Opens Settings, where the full explanation is shown")
    }

    /// The sync error's banner, in the shape of the personal-key banner above.
    private var syncErrorBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.red)
                .font(.title3)
            Text(KeyStoreRecovery.syncErrorText)
                .font(.footnote)
                .fontWeight(.semibold)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(.ultraThinMaterial)
        .cornerRadius(10)
        .shadow(radius: 2)
        .contentShape(Rectangle())
        .onTapGesture { TabSelectionState.shared.selected = 4 }
        .accessibilityIdentifier("sync-error-map-banner")
    }

    /// Whether the native Always prompt is still available. Mirrors the gate in
    /// `handleLocationPermissionTap` so the label and the action cannot drift.
    private var alwaysPromptAvailable: Bool {
        !UserDefaults.standard.bool(forKey: LocationService.alwaysPromptAttemptedKey)
    }

    /// Same, for the temporary-full-accuracy prompt.
    private var precisePromptAvailable: Bool {
        !UserDefaults.standard.bool(forKey: LocationService.precisePromptAttemptedKey)
    }

    /// Two-pronged tap handler: native iOS prompt the first time
    /// (one-shot per fresh install), Settings deep-link afterward.
    /// Mirrors the Settings tab's `upgradeToAlwaysLocation` so both
    /// banners stay in sync on the `location.alwaysPromptAttempted`
    /// gate. `.denied`/`.restricted` go straight to Settings since
    /// the native prompt can't reopen those.
    private func handleLocationPermissionTap(warning: LocationPermissionWarning) {
        switch warning {
        case .notDetermined:
            locationService.requestAuthorization()
        case .whenInUse:
            if UserDefaults.standard.bool(forKey: LocationService.alwaysPromptAttemptedKey) {
                openAppSettings()
            } else {
                // The flag is written by LocationService, and only when the
                // status it asked from could raise the dialog — same rule as
                // the precise prompt beside it.
                locationService.requestAlwaysAuthorization()
            }
        case .denied, .restricted:
            openAppSettings()
        case .reducedAccuracy:
            // Same gate as the Settings banner: the temporary-accuracy prompt
            // once, then Settings, because iOS suppresses a repeat prompt
            // after a decline. The flag is set by LocationService on the
            // decline itself, not here — a temporary grant expires, and the
            // next lapse deserves the same one-tap path.
            if UserDefaults.standard.bool(forKey: LocationService.precisePromptAttemptedKey) {
                openAppSettings()
            } else {
                locationService.requestTemporaryFullAccuracy()
            }
        }
    }

    private func openAppSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    @ViewBuilder
    private func pendingInviteBanner(invite: ReceivedInviteResponse, extra: Int) -> some View {
        let circleName = invite.circleName ?? "a circle"
        let inviter = invite.inviterDisplayName.flatMap { $0.isEmpty ? nil : $0 }
        let primary: String = {
            if let name = inviter {
                return "\(name) invited you to \(circleName)"
            }
            return "You've been invited to \(circleName)"
        }()
        let secondary: String = {
            if extra > 0 {
                return "Tap to review (\(extra + 1) pending)"
            }
            return "Tap to accept or decline"
        }()
        Button {
            // Cross-tab handoff — same singleton-write pattern as
            // PlacesView's "tap a row to focus on the marker". The
            // Circles tab owns the Accept / Decline buttons; we
            // just signal the navigation here.
            TabSelectionState.shared.selected = 1
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "envelope.badge.fill")
                    .foregroundStyle(.blue)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(primary)
                        .font(.footnote)
                        .fontWeight(.semibold)
                        .multilineTextAlignment(.leading)
                    Text(secondary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
                    .font(.caption)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(.ultraThinMaterial)
            .cornerRadius(10)
            .shadow(radius: 2)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func refreshPill(state: RefreshPillState) -> some View {
        HStack(spacing: 8) {
            switch state {
            case .updating:
                ProgressView().controlSize(.small)
                Text("Updating…")
                    .font(.footnote)
                    .foregroundStyle(.primary)
            case .offline:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                // The words in the label colour, as "Updating…" is: orange text
                // measured 2.15:1 in light. The triangle keeps the warning colour.
                Text("Couldn't reach server — showing last known")
                    .font(.footnote)
                    .foregroundStyle(.primary)
            }
            Spacer()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(.ultraThinMaterial)
        .cornerRadius(10)
        .shadow(radius: 2)
    }

    /// Anchor decides which side the label sits on:
    /// `.leading` puts the label *to the left* of the supplied
    /// content (used for the right FAB stack — column is anchored
    /// to the trailing edge, so labels grow leftward into the map),
    /// `.trailing` puts it *to the right* (left control card —
    /// labels grow rightward).
    private enum LabelAnchor { case leading, trailing }

    /// Wraps a map-action button with a fade-in/-out text label that
    /// only appears while `showLabel` is true. Mirrors
    /// the Android app — opening the (+) menu names every
    /// reachable button so first-time users aren't guessing what each
    /// icon does. Uses the standard ultra-thin material pill style
    /// of the existing FAB/control-card affordances.
    @ViewBuilder
    private func labeledRow<Content: View>(
        label: String,
        showLabel: Bool,
        anchor: LabelAnchor,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 8) {
            if anchor == .leading && showLabel { fabLabelPill(label) }
            content()
            if anchor == .trailing && showLabel { fabLabelPill(label) }
        }
    }

    private func fabLabelPill(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .fontWeight(.medium)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .shadow(radius: 1)
            .transition(.opacity)
    }

    /// How loud a floating control is. TWO values on purpose: the map gets one
    /// prominent control and everything else is quiet. A third tier would just
    /// flatten the column back into a row of equals.
    ///
    /// `.neutral` is deliberately identical to the left-hand camera controls'
    /// look, so the two columns read as one design language. It is a fixed
    /// white rather than a material or a semantic colour because it sits on a
    /// map whose own colours change with the style and the appearance, and a
    /// white disc with a blue glyph is legible over every one of them.
    /// (The Android app uses a theme-aware `colorSurfaceVariant` here; that is
    /// the one place these two look different in dark mode.)
    enum FabRole {
        case prominent
        case neutral

        var diameter: CGFloat { self == .prominent ? 50 : 44 }
        var fill: Color { self == .prominent ? .blue : .white }
        var foreground: Color { self == .prominent ? .white : .blue }
    }

    @ViewBuilder
    private func mapControlButton(systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        // Same builder as the right column's quiet controls: one definition of
        // "a map control", so the two columns cannot drift apart.
        fab(systemImage: systemImage, accessibilityLabel: label, role: .neutral, action: action)
    }

    /// Always-visible inbox affordance in the top-right corner, with a
    /// live unread badge bound to NotificationsManager.unreadCount.
    /// Mirrors the Android app's notification bell (a one-tap, badged
    /// FAB) instead of burying the inbox two taps deep in the (+) menu.
    @ViewBuilder
    private func notificationBellButton() -> some View {
        let count = notificationsManager.unreadCount
        Button {
            // Collapse any open cluster fan-out before the inbox sheet
            // covers it (the bell counts as a control on the Android app
            // too).
            MapViewHolder.shared.dismissFan?()
            showingNotifications = true
        } label: {
            Image(systemName: "bell.fill")
                .font(.body)
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.blue)
                .clipShape(SwiftUI.Circle())
                .shadow(radius: 3)
                .overlay(alignment: .topTrailing) {
                    if count > 0 {
                        Text(count > 9 ? "9+" : "\(count)")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .frame(minWidth: 18, minHeight: 18)
                            .background(.red, in: Capsule())
                            .offset(x: 5, y: -4)
                    }
                }
        }
        .accessibilityLabel(count > 0 ? "Notifications, \(count) unread" : "Notifications")
    }

    @ViewBuilder
    /// `accessibilityLabel` is REQUIRED, and deliberately has no default.
    ///
    /// A Button whose only content is `Image(systemName:)` takes its
    /// accessibility label from the SF Symbol name, so VoiceOver would announce
    /// these as "hand.wave.fill", "paperplane.fill", "clock.arrow.circlepath" —
    /// the literal asset names, read aloud. Making the parameter mandatory is
    /// what stops a new FAB from shipping without one. `labeledRow` around each
    /// call site already carries the human name, but only renders it while the
    /// stack is expanded, so it cannot serve as the label.
    private func fab(
        systemImage: String,
        accessibilityLabel: String,
        role: FabRole = .prominent,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(role == .prominent ? .title3 : .body)
                .foregroundStyle(role.foreground)
                .frame(width: role.diameter, height: role.diameter)
                .background(role.fill)
                .clipShape(SwiftUI.Circle())
                .shadow(radius: role == .prominent ? 4 : 3)
                .opacity(disabled ? 0.5 : 1.0)
        }
        .disabled(disabled)
        .accessibilityLabel(accessibilityLabel)
    }
}

struct CurrentUserMarker: View {
    var body: some View {
        ZStack {
            SwiftUI.Circle()
                .fill(.blue.opacity(0.3))
                .frame(width: 50, height: 50)

            SwiftUI.Circle()
                .fill(.blue)
                .frame(width: 20, height: 20)

            SwiftUI.Circle()
                .stroke(.white, lineWidth: 3)
                .frame(width: 20, height: 20)
        }
    }
}

struct PlaceMarker: View {
    let place: Place

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: place.icon.systemImage)
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Color(place.color))
                .clipShape(SwiftUI.Circle())
                .shadow(radius: 2)

            Text(place.name)
                .font(.caption2)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(.white)
                .cornerRadius(4)
                .shadow(radius: 1)
        }
    }
}

struct CircleSelectorButton: View {
    @StateObject private var circleManager = CircleManager.shared
    @State private var showingPicker = false

    var body: some View {
        // Dismiss any open cluster fan-out before opening the circle
        // picker (cardCircleSelector is a control on the Android app
        // too).
        Button(action: { MapViewHolder.shared.dismissFan?(); showingPicker = true }) {
            HStack {
                Image(systemName: "person.3.fill")
                Text(circleManager.activeCircle?.name ?? "Select Circle")
                Image(systemName: "chevron.down")
            }
            // As tall as the label it holds. At the larger text sizes the name
            // wraps, and a frame of one line's height would let the label draw
            // past it, so nothing laid out under it could know where it ends
            // (the map's column of notices starts under this frame).
            .fixedSize(horizontal: false, vertical: true)
            // The system accent over the THINNEST material, floating on a
            // map: the backdrop is whatever the map happens to be showing,
            // so the contrast of this label is not a property of the app
            // at all. The accessibility audit reports it as "Contrast
            // nearly passed" on the circle name — the same "nearly"
            // A11yColors exists for, where the stock accent measures
            // 4.02:1 against 4.5.
            //
            // Both halves are needed. a11yLink replaces the system accent
            // with a colour whose ratio we know; regularMaterial gives it a
            // backdrop close to the system background those ratios were
            // computed against, instead of an arbitrary photograph.
            .foregroundStyle(Color.a11yLink)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial)
            .cornerRadius(20)
        }
        .sheet(isPresented: $showingPicker) {
            CirclePickerSheet()
        }
    }
}

struct CirclePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var circleManager = CircleManager.shared
    @State private var showingCreateCircle = false

    var body: some View {
        NavigationStack {
            List(circleManager.circles) { circle in
                Button(action: {
                    circleManager.setActiveCircle(circle)
                    dismiss()
                }) {
                    HStack {
                        Text(circle.name)
                        Spacer()
                        if circle.id == circleManager.activeCircle?.id {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.blue)
                        }
                    }
                }
            }
            .navigationTitle("Select Circle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    // The Circles tab's create action, in the same place and
                    // with the same label, so it reads as the one affordance it
                    // is. It presents CreateCircleSheet exactly as that tab
                    // does — including the quota 402 -> upgrade explainer the
                    // sheet already handles.
                    //
                    // This sheet deliberately stays OPEN behind it. Creating a
                    // circle does not make it active (createCircle appends to
                    // `circles` and leaves `activeCircle` alone, on the tab as
                    // here), so the picker is exactly where the user needs to
                    // be next: the new circle is in the list below, one tap
                    // from selected.
                    Button(action: { showingCreateCircle = true }) {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Create Circle")
                }
            }
            .sheet(isPresented: $showingCreateCircle) {
                CreateCircleSheet()
            }
        }
        .presentationDetents([.medium])
    }
}

struct MemberDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    let member: CircleMember
    /// Caller-provided handler for "View History" — typically opens
    /// HistorySheet for the active circle (or self-circle). Owning
    /// view does the routing because HistorySheet is presented from
    /// MapView's own state.
    let onViewHistory: () -> Void
    /// Caller-provided handler for "Share as Destination". Receives
    /// the coordinate + best-known address line; the owning view
    /// kicks off the ShareDestinationSheet against the active circle.
    let onShareDestination: (CLLocationCoordinate2D, String?) -> Void
    /// Caller-provided handler for "At &lt;Place&gt;" — opens that place's own
    /// sheet. Routed through the owner for the same reason as the two above:
    /// PlaceDetailSheet is presented from MapView's state, not from here.
    let onOpenPlace: (Place) -> Void
    @StateObject private var circleManager = CircleManager.shared
    @StateObject private var locationService = LocationService.shared
    @StateObject private var placeManager = PlaceManager.shared
    @State private var address: String?
    @State private var didCopy = false
    /// Shared with the map's live-marker addresses. Going through the store
    /// rather than straight to GeocodingService means a member whose address
    /// the background sweep already resolved renders it on the FIRST frame of
    /// this sheet instead of after a round trip — and a tap on a member the
    /// sweep hasn't reached seeds the cache for the marker.
    private let addressStore = MemberAddressStore.shared

    var location: LocationData? {
        // This account's is this phone's own fix, never a row: the
        // same source as the map's own marker, so the sheet shows the
        // same state.
        if CanonicalId.same(member.userId, AuthManager.shared.userId) {
            return locationService.currentLocation.map {
                LocationData.ownPosition(
                    $0,
                    userId: member.userId,
                    circleId: SelfKeyManager.selfCircleUuid,
                    deviceId: AuthManager.shared.deviceId ?? ""
                )
            }
        }
        // Real-time sharing off: the last location they shared, frozen,
        // with its time and address under the sentence that says why.
        if let frozen = circleManager.frozenLocations[member.userId],
           CanonicalId.sameKey(frozen.circleId, circleManager.activeCircle?.id), !pausedNow {
            return frozen
        }
        // Otherwise not sharing here: no position, no address, and
        // `sharingSentence` says why.
        guard sharingSentence == nil else { return nil }
        return MapView.heldRow(circleManager.memberLocations[member.userId], in: circleManager.activeCircle?.id)
    }

    /// Paused, by the active circle's roster as it is NOW: a pause wins over a
    /// frozen last location.
    private var pausedNow: Bool {
        let roster = circleManager.activeCircle.flatMap { circleManager.members[$0.id] } ?? []
        let live = roster.first { CanonicalId.same($0.userId, member.userId) } ?? member
        if case .paused = live.sharing() { return true }
        return false
    }

    /// "{name} turned off location sharing in this circle." or why they are
    /// paused, from the active circle's roster as it is NOW — `member` is the
    /// value captured at the tap. Never for this account.
    private var sharingSentence: String? {
        guard !CanonicalId.same(member.userId, AuthManager.shared.userId) else { return nil }
        let roster = circleManager.activeCircle.flatMap { circleManager.members[$0.id] } ?? []
        let live = roster.first { CanonicalId.same($0.userId, member.userId) } ?? member
        return SharingStatusCopy.detailSentence(name: live.displayName, live.sharing())
    }

    /// "{name} doesn't share their location history in this circle.", in
    /// place of View History, from the active circle's roster as it is NOW.
    /// Never for this account.
    private var historyOffSentence: String? {
        guard !CanonicalId.same(member.userId, AuthManager.shared.userId) else { return nil }
        let roster = circleManager.activeCircle.flatMap { circleManager.members[$0.id] } ?? []
        let live = roster.first { CanonicalId.same($0.userId, member.userId) } ?? member
        return live.sharesHistory ? nil : SharingStatusCopy.historyOffSentence(name: live.displayName)
    }

    /// The saved place the member is currently inside, if any — the same
    /// occupancy check the map marker uses for its "At <Place>" label.
    private var atPlace: Place? {
        // Never for a frozen last location: it is not where they are.
        guard let location = location, !location.sharingOff else { return nil }
        return MapLibreMapView.placeOccupied(by: location, in: placeManager.places)
    }

    /// What the card may say about where a member is. For one who shares only
    /// an area (`ApproximateArea`): "Approximate location" and nothing finer —
    /// no street address, no coordinates, nothing to copy or hand on as a
    /// destination, and no geocoding of the point in the first place.
    struct PositionDetail: Equatable {
        let approximateLine: String?
        let showsAddressAndCoordinates: Bool
        let offersShareAsDestination: Bool
        let offersCopyAddress: Bool

        static func of(_ location: LocationData?) -> PositionDetail {
            let approximate = location?.approximate != nil
            let exact = location != nil && !approximate
            // A frozen last location is read, not acted on: no
            // destination handed on to where they no longer are.
            let frozen = location?.sharingOff == true
            return PositionDetail(approximateLine: approximate ? ApproximateLocationCopy.line : nil,
                                  showsAddressAndCoordinates: exact,
                                  offersShareAsDestination: exact && !frozen,
                                  offersCopyAddress: exact)
        }
    }

    private var detail: PositionDetail { .of(location) }

    /// The bubble the user just tapped, resolved by the SAME function the marker
    /// uses so the two cannot disagree: a lookup of its own (another roster, its
    /// own fallback slot, no stale grey) could open a green card over a purple
    /// dot, or a full-colour card for a member the map shows as grey.
    private var uiFillColor: UIColor {
        let circleId = circleManager.activeCircle?.id ?? SelfKeyManager.selfCircleUuid
        let ageMs = location.map { Int64(Date().timeIntervalSince($0.timestamp) * 1_000) }
        return MemberPalette.bubble(
            forUserId: member.userId,
            in: circleManager.members[circleId] ?? [],
            ageMs: ageMs
        )
    }

    private var fillColor: Color { Color(uiColor: uiFillColor) }

    var body: some View {
        // Compact bottom-sheet-style layout: no NavigationStack, no
        // toolbar — content stacks tight against the top of the
        // sheet and a close-X sits in the corner. Mirrors android's
        // BottomSheetDialog shape (snug to content, not half the
        // screen). presentationDetents pin the sheet to its own
        // intrinsic height instead of the system .medium / .large
        // catalog, so trailing whitespace below the buttons doesn't
        // make the sheet look empty.
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    SwiftUI.Circle()
                        .fill(fillColor)
                        .frame(width: 56, height: 56)
                    SwiftUI.Circle()
                        .stroke(Color.white, lineWidth: 2.5)
                        .frame(width: 56, height: 56)
                    Text(initials(member.displayName))
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Color(uiColor: MemberPalette.ink(on: uiFillColor)))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(member.displayName)
                        .font(.headline)
                    if let sharingSentence {
                        Text(sharingSentence)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("member-sharing-status")
                    }
                    // Under the sentence, for real-time off:
                    // when the frozen last location was
                    // shared.
                    if let location = location {
                        Text("Last seen \(location.timestamp.formatted(.relative(presentation: .named)))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let approximateLine = detail.approximateLine {
                            Text(approximateLine)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("member-approximate")
                        }
                        // "At <Place>", and a way INTO that place. When a member
                        // stands on a place their avatar can be covering its
                        // pin — syncAnnotations removes it in exactly that case
                        // — so this is the guaranteed route to the place's own
                        // sheet. Driven by containment, not by whether a pin was
                        // actually hidden: containment is a superset, so every
                        // hidden pin has a row here, which is what makes this a
                        // guarantee rather than a usually.
                        if let place = atPlace {
                            Button {
                                onOpenPlace(place)
                            } label: {
                                HStack(spacing: 4) {
                                    Label("At \(place.name)", systemImage: place.icon.systemImage)
                                    Image(systemName: "chevron.right")
                                        .font(.caption2)
                                }
                                .font(.caption)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.tint)
                        }
                    } else if sharingSentence == nil {
                        Text("No recent location")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            if let location = location {
                if detail.showsAddressAndCoordinates {
                    if let address = address {
                        Text(address)
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text(String(format: "%.5f, %.5f", location.latitude, location.longitude))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }

                VStack(spacing: 8) {
                    // Their history isn't shown in this
                    // circle: there is nothing to open, and
                    // this says why.
                    if let historyOffSentence {
                        Text(historyOffSentence)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("member-history-off")
                    } else {
                        Button {
                            dismiss()
                            DispatchQueue.main.async { onViewHistory() }
                        } label: {
                            Label("View History", systemImage: "clock.arrow.circlepath")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                    }

                    if detail.offersShareAsDestination {
                        Button {
                            let coord = CLLocationCoordinate2D(
                                latitude: location.latitude,
                                longitude: location.longitude
                            )
                            let line = address
                            dismiss()
                            DispatchQueue.main.async { onShareDestination(coord, line) }
                        } label: {
                            Label("Share as Destination", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                    }

                    if detail.offersCopyAddress {
                        Button {
                            // Address only — no coordinates on
                            // a second line, which would make
                            // "Copy" a coordinate button in
                            // disguise. An address is the
                            // paste-able currency here.
                            guard let text = address, !text.isEmpty else { return }
                            // local-only + 60s expiry: decrypted location off Universal Clipboard.
                            UIPasteboard.general.setItems(
                                [[UIPasteboard.typeAutomatic: text]],
                                options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(60)]
                            )
                            withAnimation { didCopy = true }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                                withAnimation { didCopy = false }
                            }
                        } label: {
                            Label(didCopy ? "Copied" : "Copy Address",
                                  systemImage: didCopy ? "checkmark" : "doc.on.doc")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                        .disabled(address?.isEmpty ?? true)
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .presentationDetents(Self.cardDetents(
            hasLocation: location != nil, hasAddress: address != nil, hasSharingSentence: sharingSentence != nil,
            isApproximate: detail.approximateLine != nil))
        .presentationDragIndicator(.visible)
        .task {
            // An approximate member's point is never looked up: its street
            // address is exactly what they chose not to share.
            guard let loc = location, detail.showsAddressAndCoordinates else { return }
            // Cache hit paints before the sheet's first frame; a miss resolves
            // and caches. This is the ONLY thing that geocodes a member's
            // position — a tap is itself the request for their address, and
            // nothing sweeps them in the background. Same shape as the
            // Android app's resolveMemberAddress and the web client's member
            // click.
            address = addressStore.address(
                userId: member.userId, latitude: loc.latitude, longitude: loc.longitude
            )
            if address == nil {
                address = await addressStore.resolve(
                    userId: member.userId, latitude: loc.latitude, longitude: loc.longitude
                )
            }
        }
    }

    /// The card's heights, snug to its content. A member who is not sharing
    /// has a sentence where "No recent location" takes one line, and it is the
    /// card's whole point: at the largest text sizes it outgrows 160 pt, so the
    /// card can also be dragged up to half the screen. With several detents a
    /// sheet opens at the smallest, so it still opens at 160. An approximate
    /// member's card has no address, coordinates or share and copy buttons,
    /// only "View History": it opens at 200, and can also be dragged up for
    /// the largest text sizes.
    static func cardDetents(hasLocation: Bool, hasAddress: Bool, hasSharingSentence: Bool,
                            isApproximate: Bool = false) -> Set<PresentationDetent> {
        guard hasLocation else { return hasSharingSentence ? [.height(160), .medium] : [.height(140)] }
        // A frozen last location: the sentence above its time, so
        // taller, and it can grow for the largest text sizes.
        if hasSharingSentence { return [.height((isApproximate ? 200 : hasAddress ? 320 : 280) + 40), .medium] }
        if isApproximate { return [.height(200), .medium] }
        return [.height(hasAddress ? 320 : 280)]
    }

    /// 2-character initials, matching the on-map marker.
    private func initials(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "?" }
        let parts = trimmed.split { $0.isWhitespace }
        if parts.count >= 2,
           let a = parts.first?.first,
           let b = parts.dropFirst().first?.first {
            return String([a, b]).uppercased()
        }
        return String(trimmed.prefix(1)).uppercased()
    }
}

struct QuickCheckInSheet: View {
    /// The circle it opened for: the check-in goes there or nowhere, never
    /// to the circle the map shows when it is sent. After a circle is pruned
    /// that is the next one, and the person meant this one.
    let circleId: String?
    @Environment(\.dismiss) private var dismiss
    @StateObject private var checkInManager = CheckInManager.shared
    @State private var isLoading = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button(action: { sendCheckIn(.safeArrival) }) {
                        Label("Safe Arrival", systemImage: "checkmark.circle.fill")
                    }

                    Button(action: { sendCheckIn(.general) }) {
                        Label("General Check-in", systemImage: "hand.wave.fill")
                    }
                }
            }
            .navigationTitle("Check In")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func sendCheckIn(_ type: CheckIn.CheckInType) {
        guard let circleId else { return }
        isLoading = true
        Task {
            do {
                _ = try await checkInManager.checkIn(circleId: circleId, type: type)
                dismiss()
            } catch {
                print("Failed to check in: \(error)")
            }
            isLoading = false
        }
    }
}

#Preview {
    MapView()
}

// MARK: - Map Action Sheets

/// Identifiable wrapper for CLLocationCoordinate2D so the dropped-pin
/// action sheets can present via `.sheet(item:)`. Identity is the
/// rounded lat/lng pair — re-tapping the exact same coordinate gets a
/// fresh sheet because we always reassign before presenting.
private struct CoordinateID: Identifiable {
    let coordinate: CLLocationCoordinate2D
    var id: String {
        String(format: "%.6f,%.6f", coordinate.latitude, coordinate.longitude)
    }
}

/// New-Place sheet launched from the dropped-pin card. Mirrors
/// the Android app's showCreatePlaceFromMapDialog: name + icon +
/// color + optional boundary radius + circle picker (with a
/// "Personal" option backed by the self-circle UUID for solo users).
struct CreatePlaceFromMapSheet: View {
    let coordinate: CLLocationCoordinate2D
    /// Reverse-geocoded address shown read-only above the Label
    /// field. Label starts blank so the user names the place
    /// themselves (matches the Android app's tvAddress +
    /// etPlaceName pair where the address is informational and the
    /// label is the user-typed name).
    let addressHint: String?
    let onCreated: () -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var circleManager = CircleManager.shared
    @StateObject private var placeManager = PlaceManager.shared

    @State private var name: String = ""
    @State private var notes: String = ""
    @State private var icon: Place.PlaceIcon = .home
    @State private var colorHex: String = "#3B82F6"
    @State private var addBoundary: Bool = false
    /// Range and default live in `PlaceRadius`, shared with the two sliders
    /// in PlacesView, so every slider offers the same range. See PlaceRadius
    /// for why it is 100...5000.
    @State private var radiusMeters: Double = PlaceRadius.defaultMeters
    @State private var selectedCircleId: String = SelfKeyManager.selfCircleUuid
    @State private var error: String?
    @State private var isCreating: Bool = false
    @State private var premiumPrompt: PremiumPrompt?

    private let palette: [String] = [
        "#F44336", "#E91E63", "#9C27B0", "#3B82F6",
        "#009688", "#4CAF50", "#FF9800"
    ]

    init(coordinate: CLLocationCoordinate2D, addressHint: String?, onCreated: @escaping () -> Void) {
        self.coordinate = coordinate
        self.addressHint = addressHint
        self.onCreated = onCreated
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Label", text: $name)
                } header: {
                    // Address is rendered inside the Label section's
                    // header so it looks like printed context, not
                    // an editable form row. textCase(nil) overrides
                    // SwiftUI's default all-caps section-header
                    // transform; foregroundStyle(.primary) drops the
                    // muted secondary tint so the address is readable
                    // at a glance. textSelection(.enabled) lets users
                    // copy the address from a long-press.
                    if let address = addressHint?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !address.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "mappin.and.ellipse")
                                    .foregroundStyle(.blue)
                                Text(address)
                                    .font(.subheadline)
                                    .foregroundStyle(.primary)
                                    .textSelection(.enabled)
                                Spacer(minLength: 0)
                            }
                            Text("Label")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .textCase(nil)
                        .padding(.bottom, 4)
                    } else {
                        Text("Label")
                    }
                } footer: {
                    Text("Give this place a name (e.g., Home, Work, Gym).")
                }

                Section {
                    // SwiftUI 16+ TextField with axis: .vertical
                    // grows in place up to the line cap; matches the
                    // android multiline notes field shape.
                    TextField("Optional", text: $notes, axis: .vertical)
                        .lineLimit(2...4)
                } header: {
                    Text("Notes")
                }

                Section("Icon") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                        // `.custom` is the read-side fallback for
                        // unknown icon strings — it never makes
                        // sense as a user-selectable choice, so
                        // omit it from the picker. Mirrors android's
                        // iconHome…iconHeart palette (no "custom"
                        // tile there).
                        ForEach(Place.PlaceIcon.allCases.filter { $0 != .custom }, id: \.self) { option in
                            Button { icon = option } label: {
                                Image(systemName: option.systemImage)
                                    .font(.title3)
                                    .frame(width: 40, height: 40)
                                    .foregroundStyle(icon == option ? Color.white : Color.primary)
                                    .background(icon == option ? Color.accentColor : Color(.secondarySystemBackground))
                                    .clipShape(SwiftUI.Circle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Color") {
                    HStack(spacing: 12) {
                        ForEach(palette, id: \.self) { hex in
                            SwiftUI.Circle()
                                .fill(Color(hex: hex))
                                .frame(width: 32, height: 32)
                                .overlay(
                                    SwiftUI.Circle()
                                        .stroke(hex == colorHex ? Color.primary : .clear, lineWidth: 2)
                                )
                                .onTapGesture { colorHex = hex }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Section {
                    // Disable the toggle entirely when the user has
                    // no circles — area alerts have nowhere to
                    // fire to. Mirrors the Android app.
                    Toggle("Add an area for enter/leave alerts", isOn: $addBoundary)
                        .disabled(circleManager.circles.isEmpty)
                    if circleManager.circles.isEmpty {
                        Button {
                            // Not a dead end: dismiss and jump to the
                            // Circles tab (index 1) so the user can
                            // create one. Mirrors the Android app's
                            // "Create a circle →" CTA.
                            dismiss()
                            TabSelectionState.shared.selected = 1
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Join or create a circle to enable boundaries — alerts need somewhere to fire.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("Create a circle →")
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.blue)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                    if addBoundary {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                // "Alert area", matching the Android app.
                                Text("Alert area")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(formattedRadius)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.blue)
                            }
                            Slider(value: $radiusMeters, in: PlaceRadius.range, step: PlaceRadius.step)
                            HStack {
                                // Derived, not typed twice
                                // — the end labels are the
                                // range, and a hardcoded
                                // "5 km" under a slider
                                // that doesn't end there
                                // would be worse than no
                                // label.
                                Text(PlaceRadius.formatted(PlaceRadius.range.lowerBound))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(PlaceRadius.formatted(PlaceRadius.range.upperBound))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Text("Get notified when someone enters or leaves this area.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.top, 4)
                        }
                        // Alerts are not set at create time —
                        // the place's bell is the single alert
                        // editor (mirrors android). Point the
                        // user there.
                        Text("After saving, tap the place's bell to choose who's alerted on arrival or departure.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                    }
                }

                Section {
                    Picker("Visibility", selection: $selectedCircleId) {
                        Text("Just me").tag(SelfKeyManager.selfCircleUuid)
                        ForEach(circleManager.circles, id: \.id) { c in
                            Text(c.name).tag(c.id)
                        }
                    }
                } header: {
                    Text("Visibility")
                } footer: {
                    // Match the Android app's mental model:
                    // places are owned by the user. "Just me"
                    // keeps it personal; picking a circle
                    // makes it visible to that circle's
                    // members. (This picker offers one
                    // circle; the Android app's chip group can
                    // pick several.)
                    Text("Just me keeps this place private. Choosing a circle makes it visible to that circle's members.")
                }

                if let error = error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("New Place")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isCreating ? "Saving…" : "Save") { Task { await create() } }
                        .disabled(isCreating || trimmedName.isEmpty)
                }
            }
            .onAppear {
                // Default to "Just me" — the user-owned model
                // explicitly says places are personal until shared.
                // The user can still pick an active circle to make it
                // visible to that circle's members.
                selectedCircleId = SelfKeyManager.selfCircleUuid
            }
            // Free place-limit 402 → upgrade explainer; other failures stay
            // in the inline error Section above.
            .sheet(item: $premiumPrompt) { PremiumPromptSheet(prompt: $0) }
        }
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var formattedRadius: String { PlaceRadius.formatted(radiusMeters) }
    @MainActor
    private func create() async {
        isCreating = true
        defer { isCreating = false }
        do {
            let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            let place = try await placeManager.createPlace(
                name: trimmedName,
                coordinate: coordinate,
                radius: addBoundary ? radiusMeters : 0,
                icon: icon,
                color: colorHex,
                notes: trimmedNotes.isEmpty ? nil : trimmedNotes,
                address: addressHint?.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            // Visibility picker chose a real circle → post-create
            // wrap the place key for that circle. Mirrors android's
            // pending-shares drain after createPersonalPlace.
            if selectedCircleId != SelfKeyManager.selfCircleUuid {
                try? await placeManager.sharePlaceWithCircle(
                    placeId: place.id,
                    circleId: selectedCircleId
                )
            }
            // Alerts are not created here — the place's bell is
            // the single alert editor. Create the place
            // (+ optional boundary geofence) only.
            onCreated()
            dismiss()
        } catch {
            if let apiError = error as? APIError, let prompt = PremiumPrompt.forGate(apiError) {
                premiumPrompt = prompt
            } else {
                self.error = error.plainText
            }
        }
    }
}

/// Share-Destination sheet launched from the dropped-pin card.
/// Mirrors the Android app's showShareDestinationDialog: requires a
/// real circle (destinations are a broadcast-to-members feature, so
/// solo users get a clear error), pre-fills the destination name
/// from the reverse-geocoded address, and offers a notify-on-arrival
/// toggle. NOT the system share sheet — that would just hand a maps
/// URL to a third-party app, which is the wrong primitive here.
struct ShareDestinationSheet: View {
    let coordinate: CLLocationCoordinate2D
    let initialName: String
    let addressHint: String?
    let onShared: () -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var circleManager = CircleManager.shared
    @StateObject private var destinationsManager = DestinationsManager.shared

    @State private var name: String = ""
    @State private var selectedCircleId: String = ""
    @State private var notifyArrival: Bool = true
    @State private var error: String?
    @State private var isSharing: Bool = false
    @State private var premiumPrompt: PremiumPrompt?

    init(coordinate: CLLocationCoordinate2D, initialName: String, addressHint: String?, onShared: @escaping () -> Void) {
        self.coordinate = coordinate
        self.initialName = initialName
        self.addressHint = addressHint
        self.onShared = onShared
        self._name = State(initialValue: initialName)
    }

    var body: some View {
        NavigationStack {
            Form {
                if circleManager.circles.isEmpty {
                    Section {
                        Label("Join or create a circle first to share destinations with members.",
                              systemImage: "person.2.slash")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("Share with circle") {
                        Picker("Circle", selection: $selectedCircleId) {
                            ForEach(circleManager.circles, id: \.id) { c in
                                Text(c.name).tag(c.id)
                            }
                        }
                    }
                    Section("Destination name") {
                        TextField("Optional", text: $name)
                    }
                    Section {
                        Toggle("Notify circle on arrival", isOn: $notifyArrival)
                    }
                    if let hint = addressHint {
                        Section("Location") {
                            Text(hint)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if let error = error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Share Destination")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                if !circleManager.circles.isEmpty {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(isSharing ? "Sharing…" : "Share") { Task { await share() } }
                            .disabled(isSharing || selectedCircleId.isEmpty)
                    }
                }
            }
            .onAppear {
                if let active = circleManager.activeCircle?.id {
                    selectedCircleId = active
                } else if let first = circleManager.circles.first?.id {
                    selectedCircleId = first
                }
            }
            // Destinations are a premium feature — a server gate returns a
            // premium_required_destinations 402 that opens the explainer.
            .sheet(item: $premiumPrompt) { PremiumPromptSheet(prompt: $0) }
        }
    }

    @MainActor
    private func share() async {
        isSharing = true
        defer { isSharing = false }
        do {
            _ = try await destinationsManager.createDestination(
                circleId: selectedCircleId,
                name: name.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                coordinate: coordinate,
                eta: nil,
                notifyArrival: notifyArrival
            )
            onShared()
            dismiss()
        } catch {
            if let apiError = error as? APIError, let prompt = PremiumPrompt.forGate(apiError) {
                premiumPrompt = prompt
            } else {
                self.error = error.plainText
            }
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { self = .gray; return }
        let r = Double((v & 0xFF0000) >> 16) / 255
        let g = Double((v & 0x00FF00) >> 8) / 255
        let b = Double(v & 0x0000FF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

/// Compact bottom sheet for a tapped place marker. Mirrors
/// the Android app's `showPlaceBottomSheet`:
/// icon + name + shared badge + shared-with attribution + address +
/// coords, followed by edit / share / copy / delete actions. Edit
/// and Delete are hidden for received shares (`wrapTargetId != self`).
struct PlaceDetailSheet: View {
    let place: Place
    let onShareDestination: (CLLocationCoordinate2D, String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var placeManager = PlaceManager.shared
    @StateObject private var circleManager = CircleManager.shared
    @State private var address: String?
    @State private var didCopy = false
    @State private var showingDeleteConfirm = false
    @State private var showingEdit = false
    @State private var showingAlertEditor = false

    /// True when this row is a place a different user shared with
    /// us. Owner-side wrap targets the self-circle UUID; share-side
    /// wraps come through some other circle id.
    private var isReceivedShare: Bool {
        guard let target = place.wrapTargetId else { return false }
        return target != SelfKeyManager.selfCircleUuid
    }

    private var sharedWith: String? {
        guard isReceivedShare, let target = place.wrapTargetId else { return nil }
        return circleManager.circles.first(where: { $0.id == target })?.name
    }

    private var fillColor: Color { Color(hex: place.color) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    SwiftUI.Circle()
                        .fill(fillColor)
                        .frame(width: 56, height: 56)
                    Image(systemName: place.icon.systemImage)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(place.name)
                            .font(.headline)
                        // BOUNDARY badge omitted — the Android app gates
                        // it on placeType == "boundary" (a distinct
                        // row type), not on whether a boundary radius
                        // happens to be set. iOS doesn't create
                        // placeType="boundary" rows, so the badge
                        // would always be misleading. SHARED stays
                        // since it maps to a real wire distinction.
                        if isReceivedShare {
                            Text("SHARED")
                                .font(.caption2.bold())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.orange.opacity(0.15), in: Capsule())
                                .foregroundStyle(.orange)
                        }
                    }
                    if let sharedWith = sharedWith {
                        Text("Shared via \(sharedWith)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            if let address = address {
                Text(address)
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(String(format: "%.5f, %.5f", place.latitude, place.longitude))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)

            VStack(spacing: 8) {
                // Alerts — FIRST, and shown for received shares as well as
                // own places. Edit and Delete are both hidden for a share,
                // so without this a member who tapped a place someone had
                // shared with them would be left with only "Share as
                // Destination" and "Copy Address" — nothing that sets an
                // alert. The Places list bell is offered on shares too (the
                // per-place key lets a recipient hold their own alert), and
                // the web app's map popup has the same action.
                //
                // Opens the SAME PlaceAlertEditorSheet the list bell opens —
                // it is already share-aware, so nothing about the editor
                // changes here.
                Button { showingAlertEditor = true } label: {
                    Label("Alerts", systemImage: "bell")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)

                if !isReceivedShare {
                    Button { showingEdit = true } label: {
                        Label("Edit Place", systemImage: "pencil")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                }
                Button {
                    let coord = CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude)
                    let line = address ?? place.name
                    dismiss()
                    DispatchQueue.main.async { onShareDestination(coord, line) }
                } label: {
                    Label("Share as Destination", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                Button {
                    // Address only, name as the fallback label — no coordinates.
                    // The button says "Copy Address", so a lat/lng second line
                    // would be wrong. Matches the Android app's
                    // `place.address ?: place.name`.
                    let text = address?.nilIfEmpty ?? place.name
                    // local-only + 60s expiry: decrypted place/location off Universal Clipboard.
                    UIPasteboard.general.setItems(
                        [[UIPasteboard.typeAutomatic: text]],
                        options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(60)]
                    )
                    withAnimation { didCopy = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                        withAnimation { didCopy = false }
                    }
                } label: {
                    Label(didCopy ? "Copied" : "Copy Address",
                          systemImage: didCopy ? "checkmark" : "doc.on.doc")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                if !isReceivedShare {
                    Button(role: .destructive) {
                        showingDeleteConfirm = true
                    } label: {
                        Label("Delete Place", systemImage: "trash")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .presentationDetents([.height(isReceivedShare ? 385 : 505)])
        .presentationDragIndicator(.visible)
        .task {
            let r = await GeocodingService.shared.reverse(
                latitude: place.latitude,
                longitude: place.longitude
            )
            // One line under the place name, so the locality comes off the
            // structured fields rather than out of whatever `text` happened to
            // carry — see AddressFormat.placardAddress.
            address = r.flatMap { AddressFormat.placardAddress($0, withPOIName: true) }
        }
        .alert("Delete \"\(place.name)\"?", isPresented: $showingDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task {
                    try? await placeManager.deletePlace(place)
                    dismiss()
                }
            }
        }
        .sheet(isPresented: $showingEdit) {
            EditPlaceSheet(place: place)
        }
        .sheet(isPresented: $showingAlertEditor) {
            PlaceAlertEditorSheet(place: place)
        }
    }
}

/// Shared observable state for map taps. Lives outside SwiftUI's
/// @State backing so the writer (MLNMapView delegate inside the
/// persistent Coordinator) and the reader (MapView's `.sheet`
/// modifier) always resolve to the same @Published cells, regardless
/// of view-tree rebuilds or Coordinator persistence across tab
/// switches.
@MainActor
final class MapTapState: ObservableObject {
    static let shared = MapTapState()
    @Published var selectedMember: CircleMember?
    @Published var showingMemberDetail: Bool = false
    @Published var selectedPlace: Place?
    @Published var showingPlaceDetail: Bool = false
    /// Set by PlacesView's "tap a place row" handler. MapView's
    /// .onChange consumes it: switches camera to the coord, presents
    /// the place detail sheet, then clears. Same singleton pattern
    /// the member-tap path uses so cross-tab writes resolve to the
    /// MapView .onReceive without view-tree drift.
    @Published var pendingFocusPlace: Place?
    /// SOS marker tap → detail sheet.
    @Published var selectedSOS: SOSAlert?
    @Published var showingSOSDetail: Bool = false
    /// Set by the Safety screen's "tap an alert row" handler; MapView consumes
    /// it exactly like `pendingFocusPlace` — fly the camera there, open the
    /// detail sheet, clear. No circle switch is needed: SOS markers render
    /// regardless of which circle the map is filtered to.
    @Published var pendingFocusSOS: SOSAlert?
    /// Off-screen SOS arrows, recomputed by the map Coordinator on every
    /// camera settle.
    @Published var sosEdgeIndicators: [SOSEdgeIndicator] = []
    private init() {}
}

/// One off-screen SOS: which alert, and the SCREEN direction to it (geographic
/// bearing already corrected for camera rotation).
struct SOSEdgeIndicator: Equatable, Identifiable {
    let sosId: String
    let screenBearingDegrees: Double
    var id: String { sosId }
}

/// The app's words for location access that is off: the map's banner, and the
/// raiser's SOS card when "Sent without your location" was for that reason.
enum LocationOffCopy {
    static let denied = "Track can't share your location until you allow it in Settings."
    static let restricted = "Parental controls or device management is blocking location access."
}
