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
import UIKit

/// Restarts tracking in a process iOS started — or woke — in the BACKGROUND
/// for a location event, where no scene ever appears.
///
/// WHY THIS EXISTS
///   Session restore (`AuthManager.checkExistingSession`, which starts the SDK
///   streamer and `LocationService.startTracking()`) runs only from `setupApp()`
///   in RootView's `.onAppear`. A background relaunch for a region exit, a
///   significant change or a visit never shows a scene, so without this the
///   process would come up, handle the one event, and be suspended again with
///   nothing tracking: the phone would stay dark to its circle until the user
///   happened to open the app. The battery-saver sleep makes that path common,
///   because a suspended app is terminated far more often than one holding a
///   location request.
///
/// WHAT A RESUME DOES
///   The non-UI half of `checkExistingSession`, in its order, plus the one
///   thing a headless process needs that the UI normally provides:
///   1. crypto: the persisted SDK keys, reloaded only if the first load found
///      nothing (it ran before the first unlock after a reboot, when the
///      keychain could not be read), then the sharing private key. That order,
///      because importing the private key PERSISTS the in-memory key set —
///      importing first would write an empty set over the stored circle keys;
///   2. the SDK streamer, with the stored token and ids. It refreshes the token
///      on an auth refusal by itself;
///   3. `startTracking()`, which also re-evaluates the saver sleep from scratch;
///   4. then, asynchronously, the self key and device registration (both
///      short-circuit when already done) and ONE light circle load. Without
///      that load the circle still sees nothing: upload targets are the self
///      copy plus every LOADED circle whose privacy settings are LOADED
///      (`CircleManager.uploadTargets`), and nothing else loads them on a
///      headless path — MainTabView and its poll are UI, and BGAppRefresh runs
///      when iOS pleases.
///
///   `checkExistingSession` itself is deliberately NOT called. It prompts for
///   notification permission, drives the UI's signed-in state, and refreshes
///   invites and the premium badge: prompts, or work with nothing to show it.
///   It still runs, unchanged, when the user opens the app, and the two
///   restores compose in either order — `SDKLocationStreamer.start` for the
///   same device only hands over the token, and `startTracking()` is safe to
///   repeat.
///
/// WHEN
///   - At launch, when the launch options carry `.location`.
///   - On a later location event that reaches a process which has not been
///     asked to track (`LocationService.onLocationEventWhileIdle`). That is the
///     reboot case: launched before the first unlock, the tokens were
///     unreadable and nothing could start; the next region / SLC / visit event
///     wakes the suspended process with the keychain readable.
///   Only while the app is in the background. In the foreground the normal
///   restore owns the launch.
@MainActor
enum HeadlessTrackingResume {

    struct Session: Equatable {
        let accessToken: String
        let userId: String
        let deviceId: String
    }

    enum Decision: Equatable {
        /// Not woken by a location event: nothing to do here.
        case notALocationWake
        /// On screen: RootView's `.onAppear` restore owns this launch.
        case foreground
        /// Tracking has already been asked for in this process.
        case alreadyTracking
        /// No stored session: signed out, or the keychain cannot be read yet.
        case noSession
        /// Resume, with these credentials.
        case resume(Session)
        /// Nothing kept says whether this account may be tracked (an update
        /// from a version without the gate): /auth/me is being read, and the
        /// resume is tried again once it answers.
        case readingAccess
    }

    /// The whole rule. Pure, so it is testable without a keychain, a scene or
    /// Core Location.
    nonisolated static func decide(
        locationWake: Bool,
        appInBackground: Bool,
        alreadyTracking: Bool,
        accessToken: String?,
        userId: String?,
        deviceId: String?
    ) -> Decision {
        guard locationWake else { return .notALocationWake }
        guard appInBackground else { return .foreground }
        guard !alreadyTracking else { return .alreadyTracking }
        guard let accessToken, !accessToken.isEmpty,
              let userId, !userId.isEmpty,
              let deviceId, !deviceId.isEmpty else { return .noSession }
        return .resume(Session(accessToken: accessToken, userId: userId, deviceId: deviceId))
    }

    /// What `attempt` reads. Injected so a test can drive the real sequence.
    struct Environment {
        var appInBackground: @MainActor () -> Bool
        var alreadyTracking: @MainActor () -> Bool
        var storedCredentials: @MainActor () -> (accessToken: String?, userId: String?, deviceId: String?)
        /// Whether this account may be tracked, as this device knows it.
        var access: @MainActor () -> RegistrationGate.Knowledge = {
            RegistrationGate.knowledge(protectedDataAvailable: UIApplication.shared.isProtectedDataAvailable)
        }
        /// /auth/me read, then the resume tried again.
        var readAccess: @MainActor () -> Void = { HeadlessTrackingResume.readAccessThenAttempt() }
    }

    /// What a resume does, in order. Injected for the same reason.
    struct Actions {
        var restoreCrypto: @MainActor () -> Void
        var startStreamer: @MainActor (Session) -> Void
        var startTracking: @MainActor () -> Void
        var finishInBackground: @MainActor () -> Void
    }

    /// Set once a definitive session revocation has been seen in this process
    /// while it was resumed headless: every further attempt is refused until
    /// the process ends (or the user signs in again through the UI).
    private static var sessionRevokedInThisProcess = false
    /// An /auth/me read for an unread account is under way (`readAccessThenAttempt`).
    private static var readingAccess = false
    /// Whether THIS process resumed tracking headless.
    private(set) static var resumedHeadless = false
    private static var installed = false

    /// Decide, and resume when the decision says so. `nil` means the live
    /// environment and actions (a default argument cannot name them: it is
    /// evaluated outside the main actor).
    @discardableResult
    static func attempt(
        locationWake: Bool,
        environment: Environment? = nil,
        actions: Actions? = nil
    ) -> Decision {
        guard !sessionRevokedInThisProcess else { return .noSession }
        let environment = environment ?? .live
        let actions = actions ?? .live
        let stored = environment.storedCredentials()
        let decision = decide(
            locationWake: locationWake,
            appInBackground: environment.appInBackground(),
            alreadyTracking: environment.alreadyTracking(),
            accessToken: stored.accessToken,
            userId: stored.userId,
            deviceId: stored.deviceId
        )
        guard case .resume(let session) = decision else { return decision }
        // No Track session for an account not approved (yet): its
        // token reaches the account service alone, and nothing of it
        // is tracked. With nothing kept to say (an update from a
        // version without the gate), /auth/me first, then this again.
        switch environment.access() {
        case .refused:
            return .noSession
        case .unread:
            environment.readAccess()
            return .readingAccess
        case .allowed:
            break
        }
        actions.restoreCrypto()
        actions.startStreamer(session)
        actions.startTracking()
        actions.finishInBackground()
        return decision
    }

    /// Wire it up. Call once, from `didFinishLaunching`.
    static func install(launchedForLocation: Bool) {
        guard !installed else { return }
        installed = true
        LocationService.shared.onLocationEventWhileIdle = {
            _ = HeadlessTrackingResume.attempt(locationWake: true)
        }
        _ = NotificationCenter.default.addObserver(forName: .sessionRevoked, object: nil, queue: .main) { _ in
            Task { @MainActor in HeadlessTrackingResume.sessionWasRevoked() }
        }
        if launchedForLocation {
            attempt(locationWake: true)
        }
    }

    /// `AuthManager` acts on a revocation only while the UI is signed in
    /// (`isAuthenticated`), which a headless resume never sets. Without this, a
    /// phone resumed in the background on a session the server has ended would
    /// keep polling the GPS for uploads that can never succeed, until the user
    /// opened the app — where `checkExistingSession` finds the dead session and
    /// expires it properly.
    private static func sessionWasRevoked() {
        guard resumedHeadless, !AuthManager.shared.isAuthenticated else { return }
        resumedHeadless = false
        sessionRevokedInThisProcess = true
        SDKLocationStreamer.shared.stop()
        SDKLocationStreamer.shared.forgetFreshPositionOwed()
        LocationService.shared.stopTracking()
    }

    fileprivate static func markResumed() {
        resumedHeadless = true
    }

    /// The account's access read from /auth/me (`AuthManager.readAccess`,
    /// whose setters stop anything running if it may not be tracked), then the
    /// resume tried again with it kept. One read at a time; one that fails
    /// leaves it unread, and the next location event asks again.
    fileprivate static func readAccessThenAttempt() {
        guard !readingAccess else { return }
        readingAccess = true
        Task { @MainActor in
            defer { readingAccess = false }
            guard await AuthManager.shared.readAccess() else { return }
            attempt(locationWake: true)
        }
    }
}

extension HeadlessTrackingResume.Environment {
    @MainActor static var live: Self {
        Self(
            appInBackground: { UIApplication.shared.applicationState == .background },
            alreadyTracking: { LocationService.shared.wantsTracking },
            storedCredentials: {
                let keychain = KeychainService.shared
                return (
                    keychain.getString(for: .accessToken),
                    keychain.getString(for: .userId),
                    keychain.getString(for: .deviceId)
                )
            }
        )
    }
}

extension HeadlessTrackingResume.Actions {
    @MainActor static var live: Self {
        Self(
            restoreCrypto: {
                let crypto = SDKCrypto.cryptoManager
                // Every signed-in session has a self key, so a missing one means
                // the one-time load of the persisted keys found nothing.
                guard !crypto.hasCircleKey(circleId: SelfKeyManager.selfCircleUuid) else { return }
                _ = try? crypto.loadPersistedKeys()
                // After the load, never before: importing persists the key set.
                if let sharingPriv = KeychainService.shared.getString(for: .sharingPrivateKey),
                   !sharingPriv.isEmpty {
                    try? crypto.importPrivateKey(privateKeyBase64: sharingPriv)
                }
            },
            startStreamer: { session in
                // Battery Saver / Low Power Mode: register the session
                // but open the stream lazily on the first send. Dropping
                // the session instead would leave a background relaunch
                // under Low Power Mode uploading nothing until a
                // non-saver launch.
                if LocationService.shared.isBatterySaverActive {
                    SDKLocationStreamer.shared.registerDesiredSession(
                        userId: session.userId,
                        deviceId: session.deviceId
                    )
                } else {
                    SDKLocationStreamer.shared.start(
                        jwtToken: session.accessToken,
                        userId: session.userId,
                        deviceId: session.deviceId
                    )
                }
            },
            startTracking: {
                HeadlessTrackingResume.markResumed()
                LocationService.shared.startTracking()
            },
            finishInBackground: {
                // The process is resident from here on — `startTracking()` holds a
                // background location request — so this does not race a
                // suspension, including a token refresh a 401 below may trigger.
                Task { @MainActor in
                    // A background pass never mints over a stored copy.
                    await SelfKeyManager.ensure(mayReplace: false)
                    await DeviceRegistrar.ensure()
                    try? await CircleManager.shared.loadCircles(light: true)
                }
            }
        )
    }
}
