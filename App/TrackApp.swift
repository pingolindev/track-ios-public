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
import struct PingolinTrackSDK.Location

@main
struct TrackApp: App {
    @UIApplicationDelegateAdaptor(PushAppDelegate.self) private var pushAppDelegate
    @StateObject private var appState = AppState()
    @StateObject private var authManager = AuthManager.shared
    @StateObject private var pushManager = PushNotificationManager.shared
    @Environment(\.scenePhase) private var scenePhase
    /// Same key SettingsView's "Block Screenshots & Recording" toggle writes.
    /// Read here so that a launch re-arms the setting: an `.onChange` hook
    /// alone applies it only for the rest of the session, and a relaunch
    /// would drop it while the row still reads ON.
    @AppStorage("app.privacy.blockScreenshots") private var blockScreenshots = ScreenshotBlocker.defaultEnabled

    /// The Appearance picker in Settings writes this key, and it drives the
    /// `preferredColorScheme` below. A settings control that does not do the
    /// thing it names is worse than no control, because the user concludes the
    /// app is broken rather than the setting is missing.
    @AppStorage("theme") private var themeRaw: String = "system"

    /// nil means "follow the system", which is what SwiftUI wants for that case.
    private var preferredScheme: ColorScheme? {
        switch themeRaw {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .environmentObject(authManager)
                .preferredColorScheme(preferredScheme)
                .errorBannerOverlay()
                // Sign Up, Forgot password and the account pages open inside
                // the app, never in the Safari app (App Review, Guideline 4).
                .opensWebLinksInApp()
                // The recording half of that same toggle: the overlay that
                // blacks out content while a screen recording is active, so
                // "Hide sensitive content from screenshots and screen
                // recording" delivers both halves. Applied at the root so it
                // covers every screen, and reactive to the toggle without a
                // relaunch.
                .screenRecordingBlocker(enabled: blockScreenshots)
                .onAppear {
                    setupApp()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .background {
                        BackgroundTaskScheduler.shared.scheduleNextRefresh()
                    } else if newPhase == .active {
                        // Until it has happened (a launch before the first
                        // unlock cannot reach the keychain); a no-op after.
                        KeyDeliveryApprovals.bindRecordsToThisDevice()
                        // Every owner in the records lowercased, before a
                        // sign-in reads or clears one (a no-op once done).
                        KeyDeliveryApprovals.shared.normalizeOwners()
                        // A person's decisions that found the approvals lock
                        // taken are made now.
                        KeyDeliveryApprovals.shared.retryPending()
                        // Changes waiting for this iPhone to
                        // catch up.
                        PendingChangeRunner.shared.trigger()
                        // Re-arm the screenshot blocker on every foreground.
                        // `attach` is idempotent once the window's content
                        // layer is hosted, so this is free when already armed —
                        // and it is what recovers a launch-time arm that ran
                        // before the key window had a content sublayer.
                        ScreenshotBlocker.shared.setEnabled(blockScreenshots)
                        // Resume nudge, as in the Android app.
                        // If the last successful location send is more
                        // than 3 minutes ago, do one silent send so the
                        // user's own marker on the map reflects where
                        // they actually are now, not where they were at
                        // the last 15-min scheduled tick. Cheap when
                        // recent (no-op), helpful after a glance from
                        // a different room / car ride.
                        Task { @MainActor in
                            // Nothing below for an account not
                            // approved (yet): no position is
                            // taken, and Track, which refuses
                            // its token, is not asked.
                            guard RegistrationGate.allowsTrack else { return }
                            await nudgeOwnLocationIfStale()
                            // iOS emits `.active` for every return from Control
                            // Centre, the notification shade, the app switcher
                            // and permission prompts — several a minute when the
                            // user is busy. The fetches below are worth doing on
                            // a real return, not on each of those, so they share
                            // a once-a-minute gate (`ForegroundRefreshThrottle`).
                            // loadPlaces has its own debounce (`backgroundRefresh`).
                            let throttle = ForegroundRefreshThrottle.shared
                            // Rules may have been edited on another device while
                            // we were away; the monitor reuses its lists for up
                            // to an hour otherwise.
                            if throttle.allow("monitoring.rules") {
                                MonitoringManager.shared.noteForeground()
                            }
                            // Re-fetch pending circle invites so the
                            // Circles tab + Map banner pick up any
                            // invite that landed while we were
                            // suspended. Cheap GET; silent on
                            // failure.
                            if throttle.allow("invites") {
                                await InvitesManager.shared.refresh()
                            }
                            // Re-read the place-scoped `alerts_enabled`
                            // server flag on every foreground. loadPlaces
                            // is the SOLE server-authoritative arm/disarm
                            // (it decodes that place-scoped flag), but its
                            // only OTHER triggers are Map/Places navigation,
                            // circle-switch, and deleteAlert — so a device
                            // that is merely the TARGET (not the subscriber)
                            // of a peer's or circle-wide place alert would
                            // not arm/disarm until the user next navigated
                            // there, leaving a peer's just-added alert dead
                            // on the target indefinitely. This bounds that
                            // latency to "next foreground". Best-effort;
                            // auth-gated because an unauthenticated fetch
                            // 401s and, with a stale cache present, would
                            // post an error banner.
                            //
                            // `backgroundRefresh` debounces the repeated
                            // `.active` transitions iOS emits for Control
                            // Centre / app-switcher / permission prompts and
                            // keeps a cache-fallback silent — the user didn't
                            // ask for this load. loadPlaces re-applies the
                            // local live-alert arm at its tail, so this door
                            // gets the same arm/disarm pair PlacesView does.
                            if authManager.isAuthenticated {
                                // The personal check on the
                                // foreground cadence as well
                                // as at launch: what it finds
                                // wrong is put right while the
                                // app is in use, not at some
                                // later relaunch.
                                if throttle.allow("personal.history") {
                                    await SelfKeyManager.ensure(mayReplace: false)
                                }
                                // A circle still locked since a
                                // password reset looks for an
                                // identity restored in the
                                // portal since. The loader's
                                // own window limits it.
                                await CircleManager.shared.previousIdentitiesOnForeground()
                                // A key another member rotated
                                // to reaches this phone only
                                // with a circle load (nothing
                                // pushes it): a light one on
                                // resume, at most once a
                                // minute, BEFORE places,
                                // locations and SOS read under
                                // it.
                                if throttle.allow("circles.light") {
                                    try? await CircleManager.shared.loadCircles(light: true)
                                }
                                let circleId = CircleManager.shared.activeCircle?.id
                                    ?? SelfKeyManager.selfCircleUuid
                                try? await PlaceManager.shared.loadPlaces(
                                    for: circleId, backgroundRefresh: true)
                                // Re-sync active SOS alerts on every foreground.
                                // Their only other trigger is the Safety tab's
                                // .task, so a user who lives on the Map tab
                                // would never see an SOS marker at all — and a
                                // stale one (resolved by somebody else while we
                                // were suspended) would never clear, since this
                                // load replaces the whole set.
                                if throttle.allow("sos.active") {
                                    try? await SOSManager.shared.loadActiveAlerts()
                                }
                            }
                        }
                    }
                }
        }
    }

    private func setupApp() {
        // Initialize SDK logging
        #if DEBUG
        initLogging(level: .debug)
        #else
        initLogging(level: .info)
        #endif

        // What a retired store left in the Keychain (plaintext circle names
        // among it) goes at every launch: idempotent, and a no-op before the
        // first unlock, retried at the next.
        KeychainService.shared.purgeRetiredItems()
        // What earlier versions kept of each SOS in the app's own container
        // moves to the app group, where the notification extension reads it
        // too: once, and again at the next launch for what didn't read.
        SOSAlarmMarks.shared.moveIn(from: SOSAlarmMarks.earlierDirectory())

        // Restore the persisted screenshot-blocking setting. Deferred one turn
        // because `ScreenshotBlocker` needs the key window, which isn't
        // guaranteed to exist yet inside RootView's `.onAppear`; the foreground
        // re-arm above is the backstop if this one is still too early.
        Task { @MainActor in
            ScreenshotBlocker.shared.setEnabled(blockScreenshots)
        }

        // Start listening for App Store transactions that do NOT come back from a
        // purchase call: renewals, Ask-to-Buy approvals arriving hours later,
        // refunds, and purchases made on another device. Apple wants this running
        // before launch finishes, or a transaction delivered at launch is missed.
        //
        // `restore()` is NOT called here on purpose — it reports to an
        // authenticated endpoint, and at this point the session may not be
        // restored yet. Reporting into a 401 would leave every transaction
        // unfinished for no reason. It runs off `isAuthenticated` instead, below.
        Task { @MainActor in
            StoreKitManager.shared.startObservingTransactions()
        }

        // Process-launch marker in map-diag.log to correlate holderId resets
        // (from MapViewHolder) with actual process boundaries: a launch marker
        // right before a holder init means the app was killed (jetsam / user
        // force-quit / etc.), and the MLNMapView reuse strategy can't span those
        // boundaries — only on-disk caches can.
        // DEBUG-only: this diagnostic writes to backup-eligible Documents, so it
        // must never run in a Release build (parity with the coordinate-carrying
        // diag writers, which are already DEBUG-gated).
        #if DEBUG
        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let url = docs.appendingPathComponent("map-diag.log")
            let line = "\(ISO8601DateFormatter().string(from: Date())) [process] launch pid=\(ProcessInfo.processInfo.processIdentifier)\n"
            if FileManager.default.fileExists(atPath: url.path),
               let handle = try? FileHandle(forWritingTo: url) {
                try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
                try? handle.close()
            } else {
                try? line.write(to: url, atomically: false, encoding: .utf8)
            }
        }
        #endif

        // Set the maximum size of MapLibre's ambient tile cache (128 MiB,
        // see MapCacheConfig) before any map view loads. Pinning it
        // explicitly keeps it independent of the 50 MB default of MapLibre
        // Native iOS.
        MapCacheConfig.configure()

        // Pick up the server's tile URL template, so the version segment in the
        // tile path can be moved without an app release. Tiles are served
        // `immutable, max-age=31536000`, so without this a device's cached tiles
        // are unreachable by any CDN purge for up to a year — see MapTileConfig.
        //
        // Detached and failure-tolerant: the map renders from the stored value
        // (or the shipped fallback) regardless of whether this ever completes,
        // so it is never on the launch path. `/api/config` is public, so it
        // needs no session and works before sign-in.
        Task.detached(priority: .utility) {
            await MapTileConfig.refresh(apiBaseURL: AppConfiguration.shared.apiBaseURL)
        }

        // Pre-warm the map STYLE, and the TLS connection to
        // pmtiles.pingolin.com along with it.
        //
        // Not the PMTiles archive: `rewriteProtomapsSource` deletes the
        // style's `url` key, so nothing on this device opens the archive
        // or reads a PMTiles header; and Cloudflare will not cache a
        // 134 GB object, so a range request for it would be an origin
        // round trip on every cold launch, discarded. The Android app does
        // not fetch it either.
        //
        // The style is the right target: `applyStyle` fetches this exact URL
        // with `TrustBlocklist.shared`, so a warmed response lands in the same
        // `URLCache.shared` it reads, and it is edge-cacheable
        // (max-age=86400). It is also ~262 KB and on the critical path to
        // first paint, so this is the fetch worth moving off it.
        //
        // Sprites are deliberately NOT warmed here, unlike Android. Android can
        // warm them because `HttpRequestUtil.setOkHttpClient` hands MapLibre the
        // app's own client, so one cache serves both. On iOS,
        // `PMTilesRangeCache.install()` gives MapLibre a fresh
        // URLSessionConfiguration, so a sprite warmed into URLCache.shared is
        // not the cache MapLibre reads — it would be pure waste.
        let prewarmVariant = UITraitCollection.current.userInterfaceStyle == .dark ? "dark" : "light"
        Task.detached(priority: .utility) {
            guard let url = URL(string: "https://pmtiles.pingolin.com/styles/\(prewarmVariant).json") else { return }
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            _ = try? await TrustBlocklist.shared.data(for: request)
        }

        // Launch-time location/auth state dump, to compare a
        // "marker is N hours old" symptom with what the system
        // actually reports. Single line per cold launch.
        #if DEBUG
        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let url = docs.appendingPathComponent("send-location-diag.log")
            let status = LocationService.shared.authorizationStatus.rawValue
            let bgPerm = LocationService.shared.hasBackgroundPermission
            let perm = LocationService.shared.hasLocationPermission
            let tracking = LocationService.shared.isTracking
            let cur = LocationService.shared.currentLocation
            let curStamp = cur.map { ISO8601DateFormatter().string(from: $0.timestamp) } ?? "nil"
            let line = "\(ISO8601DateFormatter().string(from: Date())) [launch] "
                + "auth=\(status) bgPerm=\(bgPerm) perm=\(perm) tracking=\(tracking) "
                + "currentLocationTs=\(curStamp)\n"
            if FileManager.default.fileExists(atPath: url.path),
               let handle = try? FileHandle(forWritingTo: url) {
                try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
                try? handle.close()
            } else {
                try? line.write(to: url, atomically: false, encoding: .utf8)
            }
        }
        #endif

        Task {
            await authManager.checkExistingSession()
            // Ask for notification permission once we know there's
            // an account on this device. Authorization status
            // persists across launches, so a re-prompt is a no-op
            // for users who already decided. Not for an account not
            // approved (yet): its device can't register with Track,
            // and approval asks iOS for the token (`unlockTrack`).
            // Never waited on: the App Store report and the geocoder
            // below don't wait for the person's answer.
            if authManager.isAuthenticated, RegistrationGate.allowsTrack {
                Task { await pushManager.requestAuthorization() }
                // Now that there is a session to report against, re-report
                // anything the App Store still considers current. This is what
                // makes a reinstall or a new device work, and it is also the
                // retry path: a transaction we failed to report is deliberately
                // left unfinished, so StoreKit hands it back here.
                await StoreKitManager.shared.restore()
            }
            // Geocoding manifest fetch is cheap (single GET to the
            // pingolin.com CDN) and unblocks forward/reverse lookups
            // for the Places search bar. Doesn't require an authed
            // session.
            await GeocodingService.shared.bootstrap()
        }
    }

    /// Resume-time own-marker refresh. Mirrors the Android app.
    /// Reads SDKLocationStreamer.lastSuccessfulSendMs; if it's older
    /// than 3 minutes, fetch a fresh CLLocation and silently send it
    /// so the user's own marker on the map reflects where they
    /// actually are now. Rate-limited by SDKLocationStreamer.sendNow
    /// (15 s window), so a flurry of foregrounds can't spam uploads.
    @MainActor
    private func nudgeOwnLocationIfStale() async {
        let staleThresholdMs: Int64 = 3 * 60 * 1000
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let lastMs = SDKLocationStreamer.lastSuccessfulSendMs
        // `lastSuccessfulSendMs` is a static — it resets to 0
        // on every process restart, so a `lastMs > 0` gate
        // would block the nudge on cold launch even when the
        // most recent successful send was hours ago, leaving
        // the user's own marker stale until Core Location
        // delivered a fix or the user tapped Send Location.
        // Treat lastMs == 0 as "nothing fresh in this process,
        // definitely nudge" — SDKLocationStreamer.sendNow has
        // its own 15s rate-limit that catches spam regardless.
        guard lastMs == 0 || nowMs - lastMs > staleThresholdMs else { return }
        guard authManager.isAuthenticated else { return }
        let locationService = LocationService.shared
        guard locationService.hasLocationPermission else { return }
        let circleId = CircleManager.shared.activeCircle?.id ?? SelfKeyManager.selfCircleUuid
        // Respect the per-circle privacy gate (pause / realtime-off); a
        // foreground nudge must not push an exact fix to a paused circle.
        // Prime-on-miss so a cold-foreground nudge isn't fail-closed before the
        // circle's privacy GET has landed.
        guard await CircleManager.shared.mayStreamRealtimePrimed(to: circleId) else { return }
        do {
            let cl = try await locationService.requestSingleLocation()
            // Also what the liveness check-in re-sends, when newer (`adoptSentFix`).
            locationService.adoptSentFix(cl)
            // With the battery level: this becomes the newest
            // point a watcher's low-battery rule judges.
            let loc = PingolinTrackSDK.Location.forSend(cl)
            // Silent path — no toast, no UI noise. The user-facing
            // "Location sent" toast belongs to the FAB tap flow.
            _ = SDKLocationStreamer.shared.sendNow(circleId: circleId, location: loc)
        } catch {
            #if DEBUG
            print("[Track] resume nudge failed: \(error)")
            #endif
        }
    }
}

/// Global app state
@MainActor
class AppState: ObservableObject {
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var showError = false

    func showError(_ message: String) {
        errorMessage = message
        showError = true
    }
}

/// Root view that switches between auth and main content
struct RootView: View {
    @EnvironmentObject var authManager: AuthManager
    @Environment(\.scenePhase) private var scenePhase
    @State private var showBiometricLock = false
    /// App Lock: whether Track has been in front in this process yet, and
    /// whether it went to the background since it last was.
    @State private var launched = false
    @State private var wentToBackground = false
    @AppStorage("onboarding.complete") private var onboardingComplete = false

    var body: some View {
        Group {
            if authManager.isCheckingSession {
                // Neutral splash while we resolve whether the user has
                // a stored session. Without this gate, app launch
                // flashes LoginView → EmailVerificationView → Map as
                // each Published flips in turn.
                ZStack {
                    Color(.systemBackground).ignoresSafeArea()
                    ProgressView()
                }
            } else if authManager.isAuthenticated {
                // No "save your recovery key" step here:
                // registration (and the key it mints) happens
                // in the account portal, which shows the key
                // on its own page.
                if !authManager.emailVerified {
                    // Mandatory email verification — no skip
                    // path. The Android flow exposes "Skip for
                    // now"; iOS does not, because an unverified
                    // account half-stuck on a device causes
                    // more confusion than it solves.
                    EmailVerificationView()
                } else if authManager.registration == .pending {
                    // An account an admin hasn't decided yet,
                    // or turned down: its screen, never the
                    // app. Track refuses its token anyway, and
                    // nothing of it is tracked
                    // (`RegistrationGate`).
                    UnderReviewView()
                } else if authManager.registration == .rejected {
                    NotApprovedView()
                } else if !onboardingComplete {
                    OnboardingView()
                } else if showBiometricLock {
                    BiometricLockView(onUnlock: { showBiometricLock = false })
                } else {
                    MainTabView()
                }
            } else {
                AuthView()
            }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            appLockSees(phase)
        }
        // Signed out, or a session that didn't come back at launch: nothing to
        // lock, and the next sign-in is its own proof.
        .onChange(of: authManager.isAuthenticated) { _, signedIn in
            if !signedIn { showBiometricLock = false }
        }
        .onChange(of: authManager.isCheckingSession) { _, checking in
            if !checking && !authManager.isAuthenticated { showBiometricLock = false }
        }
        // Raised at the ROOT, not on the delete sheet: deleting logs out, which
        // swaps this whole tree for AuthView and would take any sheet-level alert
        // with it. The account no longer exists, so there is no second chance to
        // say that Apple is still charging them.
        .alert(
            "Account deleted",
            isPresented: Binding(
                get: { authManager.postDeletionNotice != nil },
                set: { if !$0 { authManager.postDeletionNotice = nil } }
            )
        ) {
            Button("OK", role: .cancel) { authManager.postDeletionNotice = nil }
        } message: {
            Text(authManager.postDeletionNotice ?? "")
        }
        .animation(.easeInOut, value: authManager.isCheckingSession)
        .animation(.easeInOut, value: authManager.isAuthenticated)
        .animation(.easeInOut, value: authManager.emailVerified)
        .animation(.easeInOut, value: authManager.registration)
        .animation(.easeInOut, value: onboardingComplete)
        // "Is this really {name}?" — one at a time, raised by
        // `MemberKeyPinner` when a confirmed member's keys changed.
        // "It's them" re-pins under the new keys on THIS device; "Not
        // now" keeps the old pin. At most once a day per member.
        .modifier(MemberKeyAlertHost())
        // "Let {name} into {circle}?" — owner/admin devices only,
        // about a member with no statement or one whose signer this
        // device can't confirm. Waits for the question above.
        .modifier(KeyDeliveryPromptHost())
        // "Is this really {email}?" about an invitation whose invitee
        // reset their password: renewed only after "It's them".
        .modifier(InvitationRenewalQuestionHost())
        // While the lock shows, the three questions above present
        // nothing, and one already up goes: they sit above the lock,
        // and whoever holds a locked phone must not read them or
        // answer them. They wait in their queues for the unlock.
        .environment(\.appLocked, showBiometricLock)
        .onChange(of: showBiometricLock) { _, locked in
            if locked { InAppSafari.closeForLock() }
        }
    }

    /// App Lock. Going to the background from the front records the time,
    /// and "Immediately" locks then, so the app switcher's picture is the
    /// lock. On the way back from the background, and the first time Track
    /// comes to the front in this process, it asks `AppLockRule` at the first
    /// phase that isn't background (inactive comes first), before anything
    /// shows: at a launch the session check's splash is still up. A return
    /// from Control Centre, a banner or the Face ID prompt itself (inactive,
    /// never background) asks nothing. A process launched in the background (a
    /// location or push wake) records nothing: the person's last use is still
    /// the time that counts.
    private func appLockSees(_ phase: ScenePhase) {
        switch phase {
        case .background:
            guard launched else { return }
            UserSettings.shared.updateLastActiveTime()
            wentToBackground = true
            lockIfDue(launching: false)
        case .inactive, .active:
            let launching = !launched
            launched = true
            guard launching || wentToBackground else { return }
            wentToBackground = false
            lockIfDue(launching: launching)
        @unknown default:
            break
        }
    }

    private func lockIfDue(launching: Bool) {
        // Signed out, nothing to lock; at launch the session may still be being
        // read, and one that doesn't come back clears the lock (above).
        guard authManager.isAuthenticated || authManager.isCheckingSession else { return }
        let settings = UserSettings.shared
        if AppLockRule.locks(enabled: settings.biometricEnabled, requireOnLaunch: settings.requireAuthOnLaunch,
                             autoLock: settings.autoLockTimeout, launching: launching,
                             backgroundedAt: settings.lastActiveTime, now: Date()) {
            showBiometricLock = true
        }
    }
}

/// App Lock: true while the lock shows (`RootView`). What RootView
/// presents above every screen reads it and presents nothing then.
private struct AppLockedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var appLocked: Bool {
        get { self[AppLockedKey.self] }
        set { self[AppLockedKey.self] = newValue }
    }
}

/// App Lock (Settings → App Lock & Privacy → App Lock): whether Track locks as
/// it comes to the front. Off, it never does. "Require on Launch" locks every
/// launch. Otherwise Auto-Lock's choice counts from the last time Track went to
/// the background, from this process or an earlier one: "Immediately" (0),
/// 1, 5 or 15 minutes, or "Never" (`never`). No record of that time, or a clock
/// set back past it, locks: how long it was away isn't known. Pure, for tests.
enum AppLockRule {
    static let never = -1

    static func locks(enabled: Bool, requireOnLaunch: Bool, autoLock: Int, launching: Bool,
                      backgroundedAt: Date?, now: Date) -> Bool {
        guard enabled else { return false }
        if launching && requireOnLaunch { return true }
        guard autoLock >= 0 else { return false }
        guard let backgroundedAt, now >= backgroundedAt else { return true }
        return now.timeIntervalSince(backgroundedAt) >= TimeInterval(autoLock)
    }

    /// Whether Auto-Lock's `new` choice locks later than `old` ("Never" latest
    /// of all): a weaker lock, which the device's owner has to prove first
    /// (`SecuritySettingsView`). An earlier one, or the same, asks nothing.
    static func locksLater(_ new: Int, than old: Int) -> Bool {
        if old == never { return false }
        if new == never { return true }
        return new > old
    }
}

/// A once-per-interval gate for the refreshes the foreground handler runs.
///
/// Per key, so an invites refresh does not starve the SOS one. MainActor state,
/// because the scene-phase handler that consults it runs there.
@MainActor
final class ForegroundRefreshThrottle {
    static let shared = ForegroundRefreshThrottle()

    /// The shortest gap between two refreshes of one kind.
    nonisolated static var minimumInterval: TimeInterval { 60 }

    private var lastRun: [String: Date] = [:]

    private init() {}

    /// True, and the key is stamped, when `key` last ran long enough ago.
    func allow(_ key: String, now: Date = Date()) -> Bool {
        guard Self.isDue(last: lastRun[key], now: now, interval: Self.minimumInterval) else { return false }
        lastRun[key] = now
        return true
    }

    nonisolated static func isDue(last: Date?, now: Date, interval: TimeInterval) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= interval
    }
}
