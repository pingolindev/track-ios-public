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

/// An account an admin hasn't approved gets its own screen and nothing of
/// Track's.
///
/// WHY THIS IS WORTH TESTING
///   An account still under review, or one turned down, can sign in, but
///   every Track call is refused (the auth server gives its token the
///   account service's audience alone). Unless the app reads /auth/me's
///   `registration_status`, such an account lands in an app that fails with
///   no word of why, and sign-in starts the location service anyway.
@MainActor
final class RegistrationGateTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func body(_ text: String, from start: String, to end: String) throws -> String {
        let from = try XCTUnwrap(text.range(of: start), start)
        let to = try XCTUnwrap(text.range(of: end, range: from.upperBound..<text.endIndex), end)
        return String(text[from.lowerBound..<to.lowerBound])
    }

    /// The status /auth/me served: only "approved" is approved; no field (a
    /// server that doesn't serve the status) reads as approved.
    func testOnlyApprovedIsApproved() {
        XCTAssertEqual(RegistrationGate.served("approved"), .approved)
        XCTAssertEqual(RegistrationGate.served("pending"), .pending)
        XCTAssertEqual(RegistrationGate.served("rejected"), .rejected)
        XCTAssertEqual(RegistrationGate.served("PENDING"), .pending)
        XCTAssertEqual(RegistrationGate.served("suspended"), .pending, "any other word is not approved yet")
        XCTAssertEqual(RegistrationGate.served(nil), .approved, "an older server sends none")
    }

    /// The auth server's own answer (`track_access`: a verified address and an
    /// approved account) decides when it is served; the status alone
    /// otherwise. /auth/me's `email_verified` is never read for it: it is the
    /// credential's, not the account's.
    func testAuthsOwnAnswerDecidesWhenServed() {
        XCTAssertTrue(RegistrationGate.allows(.approved, trackAccess: nil), "none served: the status rule")
        XCTAssertFalse(RegistrationGate.allows(.pending, trackAccess: nil))
        XCTAssertFalse(RegistrationGate.allows(.rejected, trackAccess: nil))
        XCTAssertFalse(RegistrationGate.allows(.approved, trackAccess: false), "auth's no: an address not verified yet")
        XCTAssertTrue(RegistrationGate.allows(.approved, trackAccess: true))
        XCTAssertFalse(RegistrationGate.allows(.pending, trackAccess: false))
    }

    /// /auth/me's `track_access` lands on `User.trackAccess`; a server that
    /// doesn't serve it leaves it nil.
    func testTrackAccessIsReadFromAuthMe() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase  // as APIService decodes
        decoder.dateDecodingStrategy = .iso8601
        func user(_ extra: String) throws -> User {
            try decoder.decode(User.self, from: Data("""
                {"id": "u1", "email": "sam@example.com", "created_at": "2026-10-19T00:00:00Z"\(extra)}
                """.utf8))
        }
        XCTAssertEqual(try user(#", "track_access": false"#).trackAccess, false)
        XCTAssertEqual(try user(#", "track_access": true"#).trackAccess, true)
        XCTAssertNil(try user("").trackAccess)
    }

    /// The gate's two keys as this device last read them, put back after a test.
    private func keepingTheGate(_ body: () throws -> Void) rethrows {
        let status = UserDefaults.standard.object(forKey: RegistrationGate.defaultsKey)
        let access = UserDefaults.standard.object(forKey: RegistrationGate.trackAccessKey)
        defer {
            for (key, value) in [(RegistrationGate.defaultsKey, status), (RegistrationGate.trackAccessKey, access)] {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        try body()
    }

    /// The one predicate, kept across launches; sign-out clears it. Nothing
    /// read (an install that predates the gate, or before the first unlock
    /// after a restart, when nothing reads at all) counts as approved.
    func testThePredicateIsKeptAndCleared() {
        keepingTheGate {
            RegistrationGate.keep(trackAccess: nil)
            RegistrationGate.keep(.pending)
            XCTAssertFalse(RegistrationGate.allowsTrack)
            RegistrationGate.keep(.rejected)
            XCTAssertFalse(RegistrationGate.allowsTrack, "a rejected account tracks nothing either")
            RegistrationGate.keep(.approved)
            XCTAssertTrue(RegistrationGate.allowsTrack)
            RegistrationGate.keep(trackAccess: false)
            XCTAssertEqual(RegistrationGate.trackAccess, false)
            XCTAssertFalse(RegistrationGate.allowsTrack, "approved, and auth says no")
            RegistrationGate.keep(trackAccess: nil)
            XCTAssertNil(RegistrationGate.trackAccess, "a later read without it: the status again")
            XCTAssertTrue(RegistrationGate.allowsTrack)
            RegistrationGate.keep(trackAccess: false)
            RegistrationGate.keep(.pending)
            RegistrationGate.clear()
            XCTAssertEqual(RegistrationGate.current, .approved, "the next account is read afresh")
            XCTAssertNil(RegistrationGate.trackAccess, "both keys")
            XCTAssertTrue(RegistrationGate.allowsTrack)
        }
    }

    /// Read at the launch and at sign-in; either way an account not approved
    /// stops before anything of Track's.
    func testTheSessionStartsNothingOfTracksUntilApproved() throws {
        let auth = try source("App/Managers/AuthManager.swift")
        XCTAssertTrue(auth.contains("""
            private func learn(_ user: User) {
                registration = RegistrationGate.served(user.registrationStatus)
                trackAccess = user.trackAccess
            }
        """), "what /auth/me served for the gate, through the setters")
        XCTAssertTrue(auth.contains("        learn(user)\n        // The store may have been read again meanwhile, after the unlock.\n"),
                      "the launch (completeLaunch)")
        XCTAssertTrue(auth.contains("        learn(user)\n\n        // Generate device ID if needed"), "the sign-in")
        XCTAssertEqual(auth.components(separatedBy: "registration = RegistrationGate.served(").count - 1, 1, "learn alone")
        XCTAssertTrue(auth.contains("""
                guard RegistrationGate.allows(registration, trackAccess: trackAccess) else { return }
                // Started meanwhile by an approval or a verified address (`unlockTrack`),
                // when this finishes a launch that couldn't read /auth/me at first.
                guard trackStartedEpoch != epoch else { return }
                await startTrackServices(me: me, since: epoch)
            }

            // MARK: - A launch that couldn't read /auth/me
        """), "the launch (completeLaunch), prompting as it always did (`prompting` true): asked at the next start when undetermined")
        let signIn = try body(auth, from: "    private func completeLogin(", to: "    /// Undo what `completeLogin` wrote")
        let gate = try XCTUnwrap(signIn.range(of: """
                guard RegistrationGate.allows(registration, trackAccess: trackAccess) else {
                    isAuthenticated = true
                    signInNotice = nil
                    signInEmail = nil
                    SignedOutNotice.clear()
                    return
                }
        """), "the sign-in")
        for trackCall in ["await SelfKeyManager.ensure()", "await DeviceRegistrar.ensure()", "await InvitesManager.shared.refresh()",
                          "SDKLocationStreamer.shared.start(", "locationService.startTracking()"] {
            let call = try XCTUnwrap(signIn.range(of: trackCall), trackCall)
            XCTAssertLessThan(gate.lowerBound, call.lowerBound, "\(trackCall) after the gate")
        }
        XCTAssertTrue(auth.contains("""
                trackAccess = nil
                registration = .approved
                RegistrationGate.clear()
        """), "sign-out")
    }

    /// An approval, or a verified address, opens Track by one path, from the
    /// /auth/me read that saw it: the watch ends first (the screen going away,
    /// which the next screen makes happen, cancels nothing), then a fresh
    /// session (Track's audience comes with a refresh), and only if this account
    /// is still the one signed in, what auth served is learned, the next screen
    /// shows, and, if Track has just opened, what was held back starts. Exactly
    /// once: a second watch finds it open. A verified address reads /auth/me
    /// again first (auth's answer may have changed with it), polling again if
    /// that read fails.
    func testApprovalAndAVerifiedAddressOpenTrackByOnePath() throws {
        let auth = try source("App/Managers/AuthManager.swift")
        let approval = try body(auth, from: "    private func checkApproval() async -> Bool {", to: "    private func unlockTrack(")
        let decided = try XCTUnwrap(approval.range(of: "        approvalTask = nil\n"), "the watch ends first")
        let approved = try XCTUnwrap(approval.range(of: """
                if status == .approved {
                    await unlockTrack(me: me, served: user) {}
                } else {
                    learn(user)
                }
        """), "approval opens; a refusal is learned")
        XCTAssertLessThan(decided.lowerBound, approved.lowerBound)
        XCTAssertEqual(approval.components(separatedBy: "approvalTask = nil").count - 1, 1)

        let verification = try body(auth, from: "    private func checkEmailVerification() async -> Bool {",
                                    to: "    // MARK: - Approval")
        let reread = try XCTUnwrap(verification.range(of: """
                        guard let me = userId, let user = try? await api.getMe(),
                              Self.sessionAccount(served: user.id, stored: me) == me, !Task.isCancelled else { return false }
        """), "auth's answer read again; a failed read polls again")
        let ended = try XCTUnwrap(verification.range(of: "                emailVerificationTask = nil\n"), "then the watch ends")
        let verified = try XCTUnwrap(verification.range(of:
            "                await unlockTrack(me: me, served: user) { emailVerified = true }\n"))
        XCTAssertLessThan(reread.lowerBound, ended.lowerBound)
        XCTAssertLessThan(ended.lowerBound, verified.lowerBound)
        XCTAssertTrue(verification.contains("            if status.emailVerified, !Task.isCancelled {\n"))

        XCTAssertTrue(auth.contains("""
            private func unlockTrack(me: String, served user: User, show: () -> Void) async {
                let epoch = sessionEpoch
                try? await api.ensureFreshAccessToken()
                // Signed out (or another account in) meanwhile: nothing starts.
                guard isAuthenticated, stillSignedIn(as: me, since: epoch) else { return }
                let wasOpen = RegistrationGate.allows(registration, trackAccess: trackAccess)
                learn(user)
                show()
                guard !wasOpen, RegistrationGate.allows(registration, trackAccess: trackAccess) else { return }
                await startTrackServices(me: me, prompting: false, since: epoch)
            }
        """), "a fresh session, still this account's; learned, shown; started only as Track opens")
    }

    /// What an approval or a verified address starts continues a sign-in, so it
    /// asks iOS for the token without the prompt, as the sign-in does: the
    /// prompt is onboarding's page. Where onboarding was done on this device by
    /// an earlier account, the next launch asks, as it does for anyone not
    /// asked yet (`prompting` true there).
    func testTheUpgradeAsksForTheTokenWithoutThePrompt() throws {
        let auth = try source("App/Managers/AuthManager.swift")
        XCTAssertTrue(auth.contains("""
                if prompting {
                    // Never waited on: this runs inside the launch's session
                    // check, and the ask returns only once the person answers,
                    // so waiting would keep a returning user who never answered
                    // on the splash, with nothing of Track's started, until they
                    // did. The prompt shows over the map instead; the token is
                    // asked once they answer.
                    Task { await PushNotificationManager.shared.requestAuthorization() }
                } else {
                    // No prompt: that stays on onboarding's page, where it is
                    // explained (the sign-in's rule).
                    PushNotificationManager.shared.requestDeviceToken()
                }
        """))
        XCTAssertTrue(auth.contains("    private func startTrackServices(me: String, prompting: Bool = true, since epoch: Int) async {\n"))
        XCTAssertEqual(auth.components(separatedBy: "await startTrackServices(me: me, prompting: false, since: epoch)").count - 1, 1,
                       "the upgrade alone")
        XCTAssertEqual(auth.components(separatedBy: "await startTrackServices(me: me, since: epoch)\n").count - 1, 1,
                       "the launch, which prompts")
    }

    /// The predicate sits inside what tracks and what streams, before anything
    /// else they do, so every caller is held (a headless relaunch, a push).
    func testTrackingAndTheStreamAskThePredicateFirst() throws {
        let location = try source("App/Services/LocationService.swift")
        XCTAssertTrue(location.contains("""
            func startTracking() {
                // Never for an account not approved (yet): it has no Track to send to
                // (its token reaches the account service alone), and nothing of it is
                // tracked. The ONE predicate, here so every caller is held: sign-in, a
                // restore, a headless relaunch, a push.
                guard RegistrationGate.allowsTrack else {
        """))
        let streamer = try source("App/Services/SDKLocationStreamer.swift")
        XCTAssertTrue(streamer.contains("""
            func start(jwtToken: String, userId: String, deviceId: String) {
                // Nothing streams for an account not approved (yet): ingest
                // refuses its token, and nothing of it is tracked.
                guard RegistrationGate.allowsTrack else {
        """))
    }

    /// What starts outside the sign-in and the launch's restore asks the same
    /// predicate: the launch's alert watch and background-location wake, the
    /// background refresh, every return to the front, and the launch's
    /// notification prompt with its App Store report. Without it each would
    /// run for any stored session: an account under review, with location
    /// allowed, would have a position taken when it came back to the front,
    /// and Track would be asked what it refuses that account.
    func testEveryOtherStartAsksThePredicate() throws {
        let push = try source("App/Managers/PushNotificationManager.swift")
        XCTAssertTrue(push.contains("""
                if RegistrationGate.allowsTrack,
                   let refresh = KeychainService.shared.getString(for: .refreshToken),
                   !refresh.isEmpty {
                    Task { @MainActor in MonitoringManager.shared.startInactivityWatch() }
        """), "the launch's alert watch")
        let location = try source("App/Services/LocationService.swift")
        let wake = try body(location, from: "    func wakeForBackgroundLocationDelivery() {", to: "    enum StoredSession: Equatable {")
        let gate = try XCTUnwrap(wake.range(of: """
                guard RegistrationGate.allowsTrack else {
                    locationManager.stopMonitoringSignificantLocationChanges()
                    locationManager.stopMonitoringVisits()
        """), "the background-location wake keeps nothing registered")
        let start = try XCTUnwrap(wake.range(of: "        locationManager.startMonitoringSignificantLocationChanges()\n"))
        XCTAssertLessThan(gate.lowerBound, start.lowerBound)
        let scheduler = try source("App/Services/BackgroundTaskScheduler.swift")
        XCTAssertTrue(scheduler.contains(
            "        guard AuthManager.shared.isAuthenticated, RegistrationGate.allowsTrack else { return }\n"),
                      "the background refresh")
        let app = try source("App/TrackApp.swift")
        XCTAssertTrue(app.contains("""
                                Task { @MainActor in
                                    // Nothing below for an account not
                                    // approved (yet): no position is
                                    // taken, and Track, which refuses
                                    // its token, is not asked.
                                    guard RegistrationGate.allowsTrack else { return }
                                    await nudgeOwnLocationIfStale()
        """), "every return to the front, the position first")
        XCTAssertTrue(app.contains("""
                    if authManager.isAuthenticated, RegistrationGate.allowsTrack {
                        Task { await pushManager.requestAuthorization() }
        """), "the launch's prompt and App Store report")
    }

    private final class Recorder {
        var calls: [String] = []
    }

    /// A background relaunch for a location event resumes nothing for an
    /// account not approved: no keys, no streamer, no tracking, no Track calls.
    func testAHeadlessResumeDoesNothingUntilApproved() {
        let recorder = Recorder()
        let environment = HeadlessTrackingResume.Environment(
            appInBackground: { true },
            alreadyTracking: { false },
            storedCredentials: { ("jwt", "user-1", "device-1") }
        )
        let actions = HeadlessTrackingResume.Actions(
            restoreCrypto: { recorder.calls.append("crypto") },
            startStreamer: { _ in recorder.calls.append("streamer") },
            startTracking: { recorder.calls.append("tracking") },
            finishInBackground: { recorder.calls.append("finish") }
        )
        keepingTheGate {
            RegistrationGate.keep(trackAccess: nil)
            for status in [RegistrationGate.Status.pending, .rejected] {
                RegistrationGate.keep(status)
                XCTAssertEqual(HeadlessTrackingResume.attempt(locationWake: true, environment: environment, actions: actions),
                               .noSession, status.rawValue)
            }
            RegistrationGate.keep(.approved)
            RegistrationGate.keep(trackAccess: false)
            XCTAssertEqual(HeadlessTrackingResume.attempt(locationWake: true, environment: environment, actions: actions),
                           .noSession, "approved, and auth says no")
            XCTAssertEqual(recorder.calls, [], "nothing resumed")
            RegistrationGate.keep(trackAccess: nil)
            XCTAssertEqual(HeadlessTrackingResume.attempt(locationWake: true, environment: environment, actions: actions),
                           .resume(.init(accessToken: "jwt", userId: "user-1", deviceId: "device-1")))
            XCTAssertEqual(recorder.calls, ["crypto", "streamer", "tracking", "finish"], "approved: all of it resumes")
        }
    }

    /// What a resume that runs before any /auth/me read knows: nothing kept is
    /// "unread" only once it could have been read (after the first unlock since
    /// a restart): never written, as after an update from a build without the
    /// gate. Before the first unlock nothing reads at all, and the resume goes
    /// ahead as allowed.
    func testWhatIsKnownTellsNeverWrittenFromUnreadable() {
        XCTAssertEqual(RegistrationGate.knowledge(status: nil, trackAccess: nil, protectedDataAvailable: true), .unread,
                       "never written: /auth/me first")
        XCTAssertEqual(RegistrationGate.knowledge(status: nil, trackAccess: nil, protectedDataAvailable: false), .allowed,
                       "before the first unlock: goes ahead as allowed")
        XCTAssertEqual(RegistrationGate.knowledge(status: "approved", trackAccess: nil, protectedDataAvailable: true), .allowed)
        XCTAssertEqual(RegistrationGate.knowledge(status: "pending", trackAccess: nil, protectedDataAvailable: true), .refused)
        XCTAssertEqual(RegistrationGate.knowledge(status: "rejected", trackAccess: nil, protectedDataAvailable: false), .refused,
                       "what reads is used")
        XCTAssertEqual(RegistrationGate.knowledge(status: "approved", trackAccess: false, protectedDataAvailable: true), .refused,
                       "auth's answer decides")
    }

    /// A background relaunch for a location event with nothing kept reads
    /// /auth/me before it resumes anything; refused, it resumes nothing; known
    /// allowed, it resumes as usual. Not a location wake: no read at all.
    func testAHeadlessResumeReadsFirstWhenNothingIsKept() {
        let recorder = Recorder()
        func environment(_ access: RegistrationGate.Knowledge) -> HeadlessTrackingResume.Environment {
            HeadlessTrackingResume.Environment(
                appInBackground: { true },
                alreadyTracking: { false },
                storedCredentials: { ("jwt", "user-1", "device-1") },
                access: { access },
                readAccess: { recorder.calls.append("read") }
            )
        }
        let actions = HeadlessTrackingResume.Actions(
            restoreCrypto: { recorder.calls.append("crypto") },
            startStreamer: { _ in recorder.calls.append("streamer") },
            startTracking: { recorder.calls.append("tracking") },
            finishInBackground: { recorder.calls.append("finish") }
        )
        XCTAssertEqual(HeadlessTrackingResume.attempt(locationWake: false, environment: environment(.unread), actions: actions),
                       .notALocationWake)
        XCTAssertEqual(recorder.calls, [], "no read for anything but a location wake")
        XCTAssertEqual(HeadlessTrackingResume.attempt(locationWake: true, environment: environment(.unread), actions: actions),
                       .readingAccess)
        XCTAssertEqual(recorder.calls, ["read"], "/auth/me first, nothing resumed")
        XCTAssertEqual(HeadlessTrackingResume.attempt(locationWake: true, environment: environment(.refused), actions: actions),
                       .noSession)
        XCTAssertEqual(recorder.calls, ["read"], "refused: nothing")
        XCTAssertEqual(HeadlessTrackingResume.attempt(locationWake: true, environment: environment(.allowed), actions: actions),
                       .resume(.init(accessToken: "jwt", userId: "user-1", deviceId: "device-1")))
        XCTAssertEqual(recorder.calls, ["read", "crypto", "streamer", "tracking", "finish"])

        let resume = try? source("App/Services/HeadlessTrackingResume.swift")
        XCTAssertTrue(resume?.contains("""
                    var access: @MainActor () -> RegistrationGate.Knowledge = {
                        RegistrationGate.knowledge(protectedDataAvailable: UIApplication.shared.isProtectedDataAvailable)
                    }
                    /// /auth/me read, then the resume tried again.
                    var readAccess: @MainActor () -> Void = { HeadlessTrackingResume.readAccessThenAttempt() }
            """) == true, "live: what this device knows; /auth/me through AuthManager")
        XCTAssertTrue(resume?.contains("""
                        guard await AuthManager.shared.readAccess() else { return }
                        attempt(locationWake: true)
            """) == true, "then the resume again")
    }

    /// When what this device learns closes Track to the account, what already
    /// runs stops: the stream, tracking (significant changes and visits with
    /// it), the alert watch. Hung off both setters, so no /auth/me reader can
    /// skip it, the headless one included. Refusing new starts is not enough:
    /// an account that was tracking when Track closed to it (after an update
    /// from a build without the gate, say) would keep tracking in the
    /// background.
    func testClosingTrackStopsWhatRuns() throws {
        let auth = try source("App/Managers/AuthManager.swift")
        XCTAssertTrue(auth.contains("""
            @Published private(set) var registration: RegistrationGate.Status = RegistrationGate.current {
                didSet {
                    RegistrationGate.keep(registration)
                    holdTrackIfClosed()
                }
            }
        """))
        XCTAssertTrue(auth.contains("""
            @Published private(set) var trackAccess: Bool? = RegistrationGate.trackAccess {
                didSet {
                    RegistrationGate.keep(trackAccess: trackAccess)
                    holdTrackIfClosed()
                }
            }
        """))
        XCTAssertTrue(auth.contains("""
            private func holdTrackIfClosed() {
                guard !RegistrationGate.allows(registration, trackAccess: trackAccess) else { return }
                SDKLocationStreamer.shared.stop()
                SDKLocationStreamer.shared.forgetFreshPositionOwed()
                // Significant changes and visits too.
                LocationService.shared.stopTracking()
                MonitoringManager.shared.stopInactivityWatch()
            }
        """))
        let stop = try source("App/Services/LocationService.swift")
        let stopTracking = try body(stop, from: "    func stopTracking() {", to: "    /// Settings changed a tracking knob")
        XCTAssertTrue(stopTracking.contains("        locationManager.stopMonitoringSignificantLocationChanges()\n"
                                            + "        locationManager.stopMonitoringVisits()\n"))
        XCTAssertTrue(auth.contains("""
            func readAccess() async -> Bool {
                guard let user = try? await api.getMe(),
                      Self.sessionAccount(served: user.id, stored: keychain.getString(for: .userId)) != nil else { return false }
                learn(user)
                return true
            }
        """), "the headless read learns through the setters too")
        XCTAssertEqual(auth.components(separatedBy: "learn(user)").count - 1, 5,
                       "every reader: the launch, the sign-in, approval (refused), the upgrade, the headless read")
    }

    /// The background-location wake tears down only what is refused. With
    /// nothing kept (an update from a build without the gate) it keeps the
    /// registrations, so the next event relaunches the app, and the headless
    /// resume reads /auth/me first: an approved account updated in the
    /// background isn't left dark.
    func testTheWakeTearsDownOnlyWhatIsRefused() throws {
        let location = try source("App/Services/LocationService.swift")
        let wake = try body(location, from: "    func wakeForBackgroundLocationDelivery() {", to: "    enum StoredSession: Equatable {")
        XCTAssertTrue(wake.contains("        guard RegistrationGate.allowsTrack else {\n"))
        XCTAssertFalse(wake.contains("knowledge("), "nothing kept is not refused")
        let saved = UserDefaults.standard.object(forKey: RegistrationGate.defaultsKey)
        let access = UserDefaults.standard.object(forKey: RegistrationGate.trackAccessKey)
        defer {
            for (key, value) in [(RegistrationGate.defaultsKey, saved), (RegistrationGate.trackAccessKey, access)] {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        RegistrationGate.clear()
        XCTAssertTrue(RegistrationGate.allowsTrack, "nothing kept: the wake keeps what is registered")
    }

    /// The app's root: the email first, then the account's approval, then the
    /// app. Never the app for an account not approved.
    func testTheRootRoutesAnAccountNotApprovedToItsScreen() throws {
        let app = try source("App/TrackApp.swift")
        let email = try XCTUnwrap(app.range(of: "                    EmailVerificationView()\n"))
        let pending = try XCTUnwrap(app.range(of: "                } else if authManager.registration == .pending {\n"))
        let underReview = try XCTUnwrap(app.range(of: "                    UnderReviewView()\n"))
        let rejected = try XCTUnwrap(app.range(of: """
                        } else if authManager.registration == .rejected {
                            NotApprovedView()
                        } else if !onboardingComplete {
        """))
        let mainTab = try XCTUnwrap(app.range(of: "                    MainTabView()\n"))
        XCTAssertLessThan(email.lowerBound, pending.lowerBound)
        XCTAssertLessThan(pending.lowerBound, underReview.lowerBound)
        XCTAssertLessThan(underReview.lowerBound, rejected.lowerBound)
        XCTAssertLessThan(rejected.lowerBound, mainTab.lowerBound)
    }

    /// The same words as on web and Android; support is the portal's
    /// public page, which needs no session.
    func testTheWords() throws {
        XCTAssertEqual(RegistrationGateCopy.underReviewTitle, "Your account is under review")
        XCTAssertEqual(RegistrationGateCopy.underReviewBody,
                       "Your account request is checked by an admin before access is granted. "
                       + "We'll email you the moment it's approved — then Track unlocks automatically.")
        XCTAssertEqual(RegistrationGateCopy.notApprovedTitle, "Your application wasn't approved")
        XCTAssertEqual(RegistrationGateCopy.notApprovedBody,
                       "This account can't be used with Track. We delete it, and your application, 30 days after the decision.")
        XCTAssertEqual(RegistrationGateCopy.signedInAs("sam@example.com"), "Signed in as sam@example.com")
        XCTAssertEqual(RegistrationGateCopy.needHelp, "Need help?")
        XCTAssertEqual(RegistrationGateCopy.contactSupport, "Contact support")
        XCTAssertEqual(AppConfiguration.shared.publicSupportURL?.path, "/public-support")
        let views = try source("App/Views/Auth/RegistrationGateViews.swift")
        XCTAssertTrue(views.contains("""
                .onAppear { authManager.startApprovalPolling() }
                .onDisappear { authManager.stopApprovalPolling() }
        """), "the watch runs while the under-review screen is in front")
        XCTAssertTrue(views.contains("Text(\"Sign Out\")"), "the app's own sign-out label")
        XCTAssertFalse(views.contains("Every privacy account request"), "the web's old line claimed every sign-up is checked")
    }
}
