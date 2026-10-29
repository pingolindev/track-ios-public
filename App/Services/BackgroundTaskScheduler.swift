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

import Foundation
import BackgroundTasks
import UIKit

/// Centralizes BGTaskScheduler registration + scheduling. The one identifier
/// published in Info.plist's BGTaskSchedulerPermittedIdentifiers is
/// `com.pingolin.track.refresh` — a short BGAppRefreshTask that reloads
/// circles, member locations and the notifications inbox so a cold app launch
/// finds fresh data instead of having to wait for the first network round-trip.
///
/// `registerHandlers` also cancels any request an earlier version left pending
/// under the retired `com.pingolin.track.location-sync` identifier.
///
/// iOS gives the system free rein to decide *when* (or whether) to fire
/// these — typically after ~24h of moderate usage on a charging /
/// connected device. Best-effort, always.
final class BackgroundTaskScheduler {
    static let shared = BackgroundTaskScheduler()

    static let refreshTaskId = "com.pingolin.track.refresh"
    /// The retired processing task's identifier, kept only to cancel it.
    static let retiredLocationSyncTaskId = "com.pingolin.track.location-sync"

    private init() {}

    /// Must run before applicationDidFinishLaunching returns. Hooked
    /// via PushAppDelegate.application(_:didFinishLaunchingWithOptions:).
    func registerHandlers() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.refreshTaskId,
            using: nil
        ) { task in
            self.handleAppRefresh(task: task as! BGAppRefreshTask)
        }
        // Registration is deliberately NOT kept for the retired identifier: it is
        // gone from BGTaskSchedulerPermittedIdentifiers, and registering an
        // identifier missing from that list crashes at launch. Cancelling a
        // request left pending by an earlier version is harmless either way.
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.retiredLocationSyncTaskId)
    }

    /// Schedule the next refresh roughly an hour out. iOS will likely
    /// fire it later than that, but anything sooner gets coalesced.
    /// Safe to call repeatedly — submit() replaces any prior pending
    /// request for the same identifier.
    func scheduleNextRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskId)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Common reason: BGTaskScheduler is unavailable in the
            // simulator (BGTaskScheduler.Error.unavailable). Ignore in
            // that case so dev launches don't spam the console.
            print("[Track] scheduleNextRefresh failed: \(error)")
        }
    }

    // MARK: - Handlers

    private func handleAppRefresh(task: BGAppRefreshTask) {
        // Re-arm immediately so we keep getting woken up.
        scheduleNextRefresh()

        // Spin up an async refresh; cancel-on-expiry so we honor iOS's
        // wall-clock budget (typically 30s for BGAppRefreshTask).
        let refreshTask = Task {
            await refreshCriticalState()
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = {
            refreshTask.cancel()
            task.setTaskCompleted(success: false)
        }
    }

    @MainActor
    private func refreshCriticalState() async {
        // Skip when no session — refresh would just 401-loop through
        // the token authenticator and burn the BG budget. An account not
        // approved (yet) has no Track session either.
        guard AuthManager.shared.isAuthenticated, RegistrationGate.allowsTrack else { return }
        // Never let a background refresh ROTATE the single-use refresh token.
        // This task fires long after backgrounding, so the access token is
        // usually already expired; the first authed call below would 401 and
        // trigger a rotation right as iOS is about to suspend us. An
        // interrupted rotation leaves a consumed token in the keychain and
        // logs the user out on next launch ("logged out when I close the
        // app"). Only pre-warm when the access token is still valid long
        // enough to finish WITHOUT refreshing; otherwise skip and let the next
        // foreground refresh (which can rotate safely) load the data. The
        // pre-warm is best-effort — skipping it just means one network
        // round-trip on the next launch, which the foreground path does anyway.
        guard AuthManager.shared.accessTokenValid(forAtLeast: 120) else {
            print("[Track] background refresh skipped: access token too close to expiry to refresh without rotating")
            return
        }
        do {
            // Light: the circle list, members and privacy, plus any key a new or
            // rotated circle needs. The full login-grade load's extras — a
            // pseudonym-backfill POST per circle, the historical key import, a
            // re-store of every key — are not what a background pre-warm is for,
            // and this runs about hourly for as long as the app is installed.
            try await CircleManager.shared.loadCircles(light: true)
            if let circle = CircleManager.shared.activeCircle {
                try? await CircleManager.shared.loadMemberLocations(for: circle.id)
            }
            await NotificationsManager.shared.refreshUnreadCount()
            // Replay anything the three silent-drop paths deferred. This is the
            // only scheduled wake iOS gives us, so without it a crossing queued
            // during a background relaunch waits for the user to open the app.
            await PlaceManager.shared.drainDeferredCrossings()
            // Changes a person made while this iPhone was behind,
            // for circles it now holds the current version of.
            // Awaited: this task ends when this function returns.
            await PendingChangeRunner.shared.run(background: true)
        } catch {
            print("[Track] background refresh failed: \(error)")
        }
    }
}
