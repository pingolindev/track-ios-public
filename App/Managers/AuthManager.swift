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
import Combine
import LocalAuthentication
import Network
import UIKit
import os
import PingolinTrackSDK
import Sodium
import UserNotifications

/// Manages authentication state and operations
@MainActor
final class AuthManager: ObservableObject {
    static let shared = AuthManager()

    // MARK: - Published State

    @Published private(set) var isAuthenticated = false
    @Published private(set) var currentUser: User? {
        // The notification extension's handover decides with this
        // account's email, exactly as the confirmation pass here does.
        // The id in its one form, as the Keychain keeps it.
        didSet {
            ExtensionBridge.syncAccount(userId: currentUser.flatMap { CanonicalId.of($0.id) }, email: currentUser?.email,
                                        guardianManaged: currentUser?.guardianManaged == true,
                                        guardianHandoverDate: currentUser?.guardianHandoverDate)
        }
    }
    @Published private(set) var isLoading = false
    @Published private(set) var requires2FA = false
    @Published private(set) var tempToken: String?
    /// The second factors the server offered with the pending challenge
    /// (`available_methods`), nil when it did not say. TwoFactorView reads it to
    /// decide whether a code box can answer the challenge at all — see
    /// `twoFactorAcceptsCode`.
    @Published private(set) var twoFactorMethods: [String]?
    /// Why the sign-in screen is showing when the person didn't choose it
    /// (such as the key store's sync error): shown there until they sign in.
    @Published var signInNotice: String?
    /// The address the sign-in screen fills in after a session ended without
    /// the person asking (`signedOutNotAsked`), so the password is all it asks.
    @Published var signInEmail: String?

    /// The account password, held in memory ONLY between SRP step 2 answering
    /// `requires_2fa` and the second step ending (accepted, cancelled, signed
    /// out). The encryption keys are unlocked from the password, and
    /// `/auth/login/2fa` answers with nothing but tokens, so without it a
    /// two-factor sign-in would finish with no keys: every circle unreadable
    /// and nothing asking for the password again. The Note iOS app holds
    /// `pendingPassword` the same way, and the Note Android app routes the 2FA
    /// response back through the same derivation. A Swift String cannot be
    /// zeroed; it is dropped the moment the challenge ends.
    private var pendingPassword: String?
    /// The email typed for that sign-in, held with the password until the
    /// second step ends: the sign-in's guarded tidy compares it with the one
    /// saved with each other account (`SignInTidy`).
    private var pendingEmail: String?

    /// Can the pending challenge be answered with a typed code? False only when
    /// the server listed its methods and TOTP is not among them — a
    /// passkey-only account, which this app cannot sign in. An unknown list
    /// keeps the code box.
    var twoFactorAcceptsCode: Bool {
        Self.acceptsCode(availableMethods: twoFactorMethods)
    }

    /// The rule behind `twoFactorAcceptsCode`, pure for tests. An empty list is
    /// read as "not told" too: auth only sends the challenge when some method
    /// exists, so an empty one says nothing about passkeys.
    nonisolated static func acceptsCode(availableMethods: [String]?) -> Bool {
        guard let methods = availableMethods, !methods.isEmpty else { return true }
        return methods.contains { $0.lowercased() == "totp" }
    }
    /// Most recently known email-verification state. Mirrored to
    /// UserDefaults so the offline-launch path (no /auth/me roundtrip
    /// possible) can route past the EmailVerificationView gate
    /// instead of stranding the user there. Server is authoritative
    /// — every refresh from /auth/me / email/status replaces this.
    @Published private(set) var emailVerified: Bool = UserDefaults.standard.bool(forKey: "auth.emailVerifiedCached") {
        didSet { UserDefaults.standard.set(emailVerified, forKey: "auth.emailVerifiedCached") }
    }

    /// The account's approval (`RegistrationGate`): pending or rejected gets
    /// its own screen and nothing of Track's. Every /auth/me read that
    /// answers replaces it; a failed one changes nothing; sign-out clears it.
    @Published private(set) var registration: RegistrationGate.Status = RegistrationGate.current {
        didSet {
            RegistrationGate.keep(registration)
            holdTrackIfClosed()
        }
    }

    /// Auth's own answer for Track (`track_access`, `RegistrationGate`), when
    /// it serves one: it decides over the status then.
    @Published private(set) var trackAccess: Bool? = RegistrationGate.trackAccess {
        didSet {
            RegistrationGate.keep(trackAccess: trackAccess)
            holdTrackIfClosed()
        }
    }

    /// When what this device learns closes Track to the account, what already
    /// runs stops: the gates refuse new starts, and this stops the old ones.
    /// Tracking started before Track was closed to the account can live on in
    /// the background, so the gates alone are not enough. Hung off the two
    /// setters, so no /auth/me reader can skip it. Data and the session stay.
    private func holdTrackIfClosed() {
        guard !RegistrationGate.allows(registration, trackAccess: trackAccess) else { return }
        SDKLocationStreamer.shared.stop()
        SDKLocationStreamer.shared.forgetFreshPositionOwed()
        // Significant changes and visits too.
        LocationService.shared.stopTracking()
        MonitoringManager.shared.stopInactivityWatch()
    }

    /// Shown once, at the app root, after an account deletion that left the user
    /// something to do about their billing — an App Store subscription only they
    /// can cancel, or a cancellation that failed at the provider.
    ///
    /// It lives here rather than on the delete sheet because deletion logs out,
    /// and logging out replaces the entire view tree: an alert raised on that
    /// sheet would be torn down before anyone read it. Survives `logout()` by
    /// design — the account is gone, so this is the last thing we can tell them.
    @Published var postDeletionNotice: String?
    /// True while `checkExistingSession()` is in flight on app launch.
    /// RootView shows a neutral splash instead of AuthView so a stored
    /// session doesn't flash through the login screen before the
    /// session is verified.
    @Published private(set) var isCheckingSession = true

    // MARK: - Dependencies

    private let api = APIService.shared
    private let keychain = KeychainService.shared
    private let locationService = LocationService.shared
    private let cryptoManager = SDKCrypto.cryptoManager

    /// The email-verification poll, while `EmailVerificationView` is on screen
    /// in the foreground. See `startEmailVerificationPolling`.
    private var emailVerificationTask: Task<Void, Never>?

    /// The approval watch, while `UnderReviewView` is on screen in the
    /// foreground. See `startApprovalPolling`.
    private var approvalTask: Task<Void, Never>?

    /// Counts sign-outs and ended sessions, bumped as each BEGINS, before
    /// anything it awaits. A start-up that read it before them never starts
    /// tracking or the stream after them (`stillSignedIn`): the gate can't
    /// tell, since it reads allowed once a sign-out has cleared it.
    private var sessionEpoch = 0

    /// The person is ending this session themselves: their account is being
    /// deleted (`deleteAccount`). The server ends the session as it deletes,
    /// and a request in flight then comes back revoked. That is no involuntary
    /// sign-out, so nothing says one: no banner, no sign-in notice with the
    /// deleted address. The teardown still runs, so a deletion that fails
    /// after the server ended the session leaves no dead session up.
    private var sessionEndingByChoice = false

    /// Whether the session a start-up began in is still the one signed in: no
    /// sign-out or ended session began since, and the Keychain still names
    /// this account.
    private func stillSignedIn(as me: String, since epoch: Int) -> Bool {
        sessionEpoch == epoch && userId == me
    }

    private init() {
        observeSessionRevocation()
        observeKeyStoreLoadedAgain()
    }

    // MARK: - Session Revocation

    /// Watch the refresh authority for a definitive server rejection and sign
    /// out when one arrives.
    ///
    /// This has to be its own always-on observer. Wiring
    /// `isSessionDefinitivelyExpired` → `logout()` into `checkExistingSession`
    /// alone is not enough, because that path runs only at LAUNCH: a session
    /// revoked while the app is already running (device revoked from the
    /// Security page, password change, admin revoke, or eviction by the
    /// 10-session cap) then reaches no logout at all — every API call 401s →
    /// refresh → denied → banner, on repeat, and only a force-quit clears it.
    /// The app keeps looking signed-in the whole time while nothing reaches the
    /// backend, and for a location-safety app the silent part is the dangerous
    /// part.
    private func observeSessionRevocation() {
        Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .sessionRevoked) {
                await self?.handleSessionRevoked()
            }
        }
    }

    /// The load after the unlock (`SDKCrypto`) is judged as the launch's is,
    /// for a signed-in session. A launch still checking judges it itself,
    /// before it signs in (`checkExistingSession`).
    private func observeKeyStoreLoadedAgain() {
        Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: SDKCrypto.keysLoadedAgain) {
                await self?.keyStoreLoadedAgain()
            }
        }
    }

    private func keyStoreLoadedAgain() {
        guard isAuthenticated else { return }
        endSessionForKeyStore()
    }

    /// The SDK's key store (`KeyStoreRecovery`): one that doesn't decode ends
    /// the session, and the sign-in screen says "Sync error. Please sign in
    /// again." — the sign-in clears it. A seed or entries that didn't read
    /// raise the banner instead: the app still works. True when the session
    /// ended.
    @discardableResult
    private func endSessionForKeyStore() -> Bool {
        guard KeyStoreRecovery.shared.check() == .signOut else { return false }
        signInNotice = KeyStoreRecovery.syncErrorText
        expireSession()
        return true
    }

    private func handleSessionRevoked() async {
        // Trailing refresh callers can each post one of these. The `for await`
        // loop hands them over serially and `logout()` clears the flag, so the
        // first pass does the work and the rest fall out here. Skipping when
        // already signed out also keeps the launch path (which runs its own
        // gate at `checkExistingSession`) from logging out twice.
        guard isAuthenticated else { return }
        // The teardown below always runs; what says "signed out" doesn't for a
        // session the person is ending themselves.
        if !sessionEndingByChoice { ErrorBanner.shared.postSignedOut() }
        // NOT logout(): the server ended the SESSION, not the account. Signing
        // back in as the same user restores the app instead of re-importing it.
        let sharing = LocationService.shared.wantsTracking && LocationService.shared.hasLocationPermission
        expireSession()
        signedOutNotAsked(wasSharing: sharing)
    }

    /// The session ended without the person asking. The sign-in screen says
    /// why it is showing and fills in the address, and when Track was sharing
    /// and isn't in front, a notification says sharing stopped
    /// (`SignedOutNotice`): the banner alone is gone in 5 s, unseen in the
    /// background.
    private func signedOutNotAsked(wasSharing: Bool) {
        // Not for a session the person is ending themselves.
        guard !sessionEndingByChoice else { return }
        signInNotice = SignedOutNotice.signInText(wasSharing: wasSharing)
        signInEmail = userId.flatMap(SignInEmails.saved(for:))
        if SignedOutNotice.shouldPost(wasSharing: wasSharing,
                                      inBackground: UIApplication.shared.applicationState == .background) {
            SignedOutNotice.post()
        }
    }

    // MARK: - Session Management

    /// What the Keychain says about a stored session at launch.
    enum SessionAtLaunch: Equatable {
        case stored
        /// Nothing stored: signed out.
        case signedOut
        /// The Keychain can't be read yet: not known, and never shown as signed out.
        case notKnownYet
    }

    /// Pure: a session needs both its token and its account. Either one
    /// definitely not stored is signed out; otherwise a read that got no
    /// answer leaves it not known yet.
    nonisolated static func sessionAtLaunch(token: KeychainService.Read, userId: KeychainService.Read) -> SessionAtLaunch {
        switch (token, userId) {
        case (.notFound, _), (_, .notFound):
            return .signedOut
        case (.unavailable, _), (_, .unavailable):
            return .notKnownYet
        case (.value(let token), .value(let userId)):
            return String(data: token, encoding: .utf8) != nil && String(data: userId, encoding: .utf8) != nil
                ? .stored : .signedOut
        }
    }

    /// Pure, for tests: the account a resumed session is, when /auth/me and
    /// the Keychain name the same one, each in its one form; nil otherwise,
    /// and the session is invalid.
    nonisolated static func sessionAccount(served: String, stored: String?) -> String? {
        guard let served = CanonicalId.of(served), let stored = CanonicalId.of(stored), served == stored else {
            return nil
        }
        return served
    }

    private var sessionCheckObserver: NSObjectProtocol?
    /// Re-checks made while the device was already unlocked (`checksAgain`).
    private var unlockedRechecks = 0
    nonisolated static let unlockedRecheckLimit = 10

    /// Pure: whether a stored session the Keychain didn't answer is checked
    /// again. Before the first unlock, always: the unlock answers it. On a
    /// device unlocked all along, `unlockedRecheckLimit` times, a second apart;
    /// then the sign-in screen shows, with nothing deleted.
    nonisolated static func checksAgain(unlocked: Bool, unlockedRechecks: Int) -> Bool {
        !unlocked || unlockedRechecks < unlockedRecheckLimit
    }

    /// The launch check once the Keychain can be read (the first unlock), and
    /// a second from now if the device is already unlocked.
    private func checkSessionAgainWhenReadable() {
        guard sessionCheckObserver == nil else { return }
        sessionCheckObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.checkSessionAgain() }
        }
        if UIApplication.shared.isProtectedDataAvailable {
            Task {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await checkSessionAgain()
            }
        }
    }

    private func checkSessionAgain() async {
        guard let observer = sessionCheckObserver else { return }
        NotificationCenter.default.removeObserver(observer)
        sessionCheckObserver = nil
        await checkExistingSession()
    }

    func checkExistingSession() async {
        // FIRST STATEMENT on purpose: every exit from this function must clear
        // the flag, including the DEBUG UI-test bypass below, which `return`s
        // early. Declared after the #endif instead, the synthetic-session path
        // leaves `isCheckingSession` true forever — TrackApp gates a splash on
        // it, so the app sits on a ProgressView and MainTabView never renders.
        // Every shell UI test then fails on "Tab bar should render", which reads
        // as broken UI rather than a stuck launch. The one exit that keeps it is
        // a Keychain that can't be read yet (`answered`): no answer is not
        // "signed out", and the check runs again once it can be read.
        var answered = true
        defer { if answered { isCheckingSession = false } }
        let epoch = sessionEpoch
        #if DEBUG
        // Deterministic state for UI tests: -UITestCleanState 1
        // zeroes the keychain slots + UserDefaults flags this
        // manager consults, so tests never inherit a session
        // from a prior run.
        if ProcessInfo.processInfo.arguments.contains("-UITestCleanState") {
            keychain.delete(key: .accessToken)
            keychain.delete(key: .refreshToken)
            keychain.delete(key: .userId)
            keychain.delete(key: .deviceId)
            // Pin onboarding to "done" so tests targeting the
            // login screen or MainTabView don't have to drive the
            // consent walkthrough first — unless the test says
            // otherwise with -UITestForceOnboarding.
            // FirstRunLocationTests needs that: the location
            // permission prompt only appears on a genuine first
            // run, so a case about what happens when it is
            // answered cannot start past the walkthrough.
            //
            // The same flag is honoured on the synthetic-session
            // path below; that one returns early with a fake
            // user, so it cannot be used where a REAL login is
            // what has to start location tracking.
            UserDefaults.standard.set(
                !ProcessInfo.processInfo.arguments.contains("-UITestForceOnboarding"),
                forKey: "onboarding.complete")
        }
        // XCUITest escape hatch: when launched with
        // -UITestSyntheticSession, skip the real existing-session path
        // and inject a synthetic user so MainTabView renders for the
        // shell tests. Wrapped in `#if DEBUG` so Release builds cannot
        // carry the bypass. API calls will fail (no real JWT) — UI
        // tests using this flag should focus on the view surface and
        // tolerate empty / error-banner states.
        if ProcessInfo.processInfo.arguments.contains("-UITestSyntheticSession") {
            applySyntheticUITestSession()
            // Subsequent flag override: when driving the onboarding
            // walkthrough, flip the completion bit back off after
            // applySyntheticUITestSession set it to true.
            if ProcessInfo.processInfo.arguments.contains("-UITestForceOnboarding") {
                UserDefaults.standard.set(false, forKey: "onboarding.complete")
            }
            return
        }
        #endif

        // Earlier builds' global keys (the circles' order, the questions'
        // marks, the active circle's id), once the Keychain has said who is
        // signed in: theirs become that account's; with nobody, they go.
        switch keychain.read(.userId) {
        case .value(let data): AccountKeyedDefaults.migrateGlobals(signedIn: String(data: data, encoding: .utf8))
        case .notFound: AccountKeyedDefaults.migrateGlobals(signedIn: nil)
        case .unavailable: break
        }

        // A Keychain that can't be read yet (before the first unlock after a
        // restart: a background launch) is no answer, never "signed out" (the
        // Note iOS app makes the same split): the check waits for it.
        switch Self.sessionAtLaunch(token: keychain.read(.accessToken), userId: keychain.read(.userId)) {
        case .signedOut:
            isAuthenticated = false
            return
        case .notKnownYet:
            // Unlocked all along, and still no answer after the
            // re-checks: the sign-in screen, with nothing deleted (a
            // relaunch reads it again). Waiting on an unlock that
            // already happened would keep the splash up for good.
            let unlocked = UIApplication.shared.isProtectedDataAvailable
            guard Self.checksAgain(unlocked: unlocked, unlockedRechecks: unlockedRechecks) else {
                isAuthenticated = false
                return
            }
            if unlocked { unlockedRechecks += 1 }
            answered = false
            checkSessionAgainWhenReadable()
            return
        case .stored:
            break
        }
        // The SDK's key store as the launch found it: one that
        // doesn't decode ends the session, with the sync error.
        if endSessionForKeyStore() { return }

        // Proactively refresh ONCE up front when the stored access token is
        // already expired — the common case on a cold reopen. Without this,
        // getMe() below AND the ~10 concurrent data-load calls that fire the
        // moment MainTabView appears ALL 401 on the dead token and each tries
        // to refresh: a storm the coalescing and grace window cannot fully
        // absorb, because every rotation invalidates the prior access token
        // (session), so the retries 401 → the "decode failed" banner. One
        // awaited refresh here means the token is already fresh before any of
        // those calls run, so they never 401. Best-effort: if the refresh
        // token is genuinely dead this throws, and we fall through to getMe()
        // which surfaces the real (logged-out) state.
        if !accessTokenValid(forAtLeast: 60) {
            try? await api.ensureFreshAccessToken()
        }

        do {
            let user = try await api.getMe()
            await completeLaunch(served: user, since: epoch)
        } catch {
            // Only force-logout when the session is DEFINITIVELY
            // gone: a 401 from /auth/refresh (the endpoint resolves
            // the session by refresh-token hash, so 401 ==
            // genuinely revoked / expired / replayed → APIError
            // code "refresh_failed"). EVERY other failure — 5xx,
            // 429, circuit-open, network drop, timeout, decode — is
            // transient: the server session is presumably still
            // valid, so keep it and let the next request /
            // heartbeat retry.
            //
            // Force-logging-out on a transient failure wipes the
            // local refresh token and, with no stored password,
            // leaves the device dark until a manual re-login.
            // Sparing only raw URLErrors is not enough: a 5xx or
            // circuit-open on the refresh would still end an
            // otherwise-valid session.
            if Self.isSessionDefinitivelyExpired(error) {
                // NOT logout(). This branch is already narrowed to a
                // DEFINITIVE 401 from /auth/refresh, but definitive
                // means the session is gone — not that the person
                // asked to sign out, and not that their keys and
                // caches should be destroyed. The Android app makes
                // the same split.
                expireSession()
                // Signed in with location access, it was sharing until now.
                signedOutNotAsked(wasSharing: LocationService.shared.hasLocationPermission)
            } else {
                #if DEBUG
                print("[Track] checkExistingSession: keeping session, transient failure (\(error))")
                #endif
                // Trust the stored token and proceed in offline
                // mode: downstream UI (Map, History) renders against
                // whatever's already cached. currentUser stays nil
                // and nothing of Track's starts until /auth/me
                // answers, which is read again until it does
                // (`retryLaunchRead`); then the launch finishes as an
                // online one.
                if endSessionForKeyStore() { return }
                isAuthenticated = true
                ErrorBanner.shared.post(error)
                retryLaunchRead(since: epoch)
                return
            }
        }
    }

    /// What a launch does once /auth/me has answered for the stored session:
    /// the launch's own read (`checkExistingSession`), or the read again after a
    /// launch that couldn't make it (`retryLaunchRead`). One function, so the
    /// two can't drift apart.
    private func completeLaunch(served user: User, since epoch: Int) async {
        // /auth/me naming another account than the Keychain's, or naming
        // it in any form but its one form, is an invalid session. It
        // ends as an expired one does, which keeps this account's
        // stores: no switch purge and no tidy of anybody's data runs on
        // a launch.
        guard let me = Self.sessionAccount(served: user.id, stored: keychain.getString(for: .userId)) else {
            Self.authLog.error("launch: /auth/me named another account than this device's: the session ends")
            expireSession()
            return
        }
        currentUser = user
        // Pre-populate emailVerified from /auth/me so the launch
        // path can skip EmailVerificationView immediately when the
        // user has already verified — without waiting for the
        // background 5s status poll.
        if let verified = user.emailVerified {
            emailVerified = verified
        }
        learn(user)
        // The store may have been read again meanwhile, after the unlock.
        if endSessionForKeyStore() { return }
        isAuthenticated = true
        #if DEBUG
        // -UITestForgetAccountKeys: this device forgets the account's keys
        // and keeps the session — the state `.keysNotUnlocked` and
        // `.noAccountKeys` describe — so a UI test can drive the password
        // asked in place. The pins are kept the way a sign-out keeps them,
        // for the unlock to bring back.
        if ProcessInfo.processInfo.arguments.contains("-UITestForgetAccountKeys") {
            RetainedMemberPins.retain(owner: me, crypto: cryptoManager)
            OwedWipe.clear(cryptoManager)
            keychain.delete(key: .sharingPrivateKey)
            keychain.delete(key: .masterKey)
        }
        #endif
        // Restore the SDK's X25519 sharing private key from the
        // iOS keychain before anything that needs ECDH-unwrap. The
        // SDK keeps key state in a process-local HashMap (no
        // persistent storage callback is registered on iOS), so a
        // returning-user launch starts with no key in memory. The
        // login path (deriveAndImportSharingKey) writes the
        // derived key into the keychain — we just rehydrate it
        // here so SelfKeyManager.ensure() / CircleManager.loadCircles
        // can decrypt the server-stored wraps. Without this, every
        // process restart loses access to the self-key, every
        // personal place fails to unwrap, and the user sees
        // their own places vanish from the map.
        if let sharingPriv = keychain.getString(for: .sharingPrivateKey) {
            do {
                try cryptoManager.importPrivateKey(privateKeyBase64: sharingPriv)
            } catch {
                print("[Track] checkExistingSession: importPrivateKey failed: \(error)")
            }
        }
        // An account not approved (yet) gets its screen and nothing of
        // Track's: its token reaches the account service alone
        // (`RegistrationGate.allows`, the auth server's own answer when it
        // serves one).
        guard RegistrationGate.allows(registration, trackAccess: trackAccess) else { return }
        // Started meanwhile by an approval or a verified address (`unlockTrack`),
        // when this finishes a launch that couldn't read /auth/me at first.
        guard trackStartedEpoch != epoch else { return }
        await startTrackServices(me: me, since: epoch)
    }

    // MARK: - A launch that couldn't read /auth/me

    /// The read again after a launch that couldn't make it (`LaunchRetry`).
    private var launchRetryTask: Task<Void, Never>?
    private var launchRetryPath: NWPathMonitor?
    private var launchRetryActive: NSObjectProtocol?
    /// The session (`sessionEpoch`) Track's start-up last began in: a launch
    /// finished late (`retryLaunchRead`) starts nothing an approval or a verified
    /// address (`unlockTrack`) started meanwhile.
    private var trackStartedEpoch: Int?

    /// After a launch whose /auth/me failed transiently: read it again until it
    /// answers, then finish the launch (`completeLaunch`), so the user is set
    /// (the guardian line) and Track starts (the stream, tracking) without a
    /// relaunch. Bound to the session the launch began in: a sign-out or an
    /// ended session stops it, and a definitive refusal ends the session as the
    /// launch's own would have.
    private func retryLaunchRead(since epoch: Int) {
        guard launchRetryTask == nil, let me = userId else { return }
        let waiting = LaunchRetryWait()
        startLaunchRetryWakes(waiting)
        let retry = LaunchRetry(
            read: { [api = self.api] in try await api.getMe() },
            isCurrent: { [weak self] in self?.stillSignedIn(as: me, since: epoch) ?? false },
            next: { Self.isSessionDefinitivelyExpired($0) ? .expire : .again },
            wait: { await waiting.wait($0) },
            complete: { [weak self] user in await self?.completeLaunch(served: user, since: epoch) },
            expire: { [weak self] in
                self?.expireSession()
                // Signed in with location access, it was sharing until now.
                self?.signedOutNotAsked(wasSharing: LocationService.shared.hasLocationPermission)
            }
        )
        launchRetryTask = Task { [weak self] in
            await retry.run()
            self?.endLaunchRetry()
        }
    }

    /// The network coming back (a path that turns satisfied) and the app coming
    /// to the front each end the wait in progress.
    private func startLaunchRetryWakes(_ waiting: LaunchRetryWait) {
        final class LastPath: @unchecked Sendable {
            /// Touched only on the monitor's own serial queue.
            var satisfied: Bool?
        }
        let last = LastPath()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            let satisfied = path.status == .satisfied
            defer { last.satisfied = satisfied }
            guard LaunchRetryWait.wakes(from: last.satisfied, to: satisfied) else { return }
            Task { @MainActor in waiting.wake() }
        }
        monitor.start(queue: DispatchQueue(label: "com.pingolin.track.launchretry"))
        launchRetryPath = monitor
        launchRetryActive = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in waiting.wake() }
        }
    }

    private func endLaunchRetry() {
        launchRetryTask = nil
        launchRetryPath?.cancel()
        launchRetryPath = nil
        if let observer = launchRetryActive {
            NotificationCenter.default.removeObserver(observer)
        }
        launchRetryActive = nil
    }

    /// Everything of Track's a restored session starts, in order: the self
    /// key, this device's registration, push, the invitations, the plan, the
    /// location stream and tracking. Only for an approved account: the launch
    /// above, and what an approval or a verified address opens
    /// (`unlockTrack`). That one continues a sign-in, so it asks iOS for the
    /// token without the prompt, as the sign-in does (`prompting` false).
    private func startTrackServices(me: String, prompting: Bool = true, since epoch: Int) async {
        trackStartedEpoch = epoch
        // Order matters: private-key restore → self-key load →
        // device registration → streamer start. The device-
        // registration POST seals device-name/type with the
        // self-key when it is there, and the streamer sends gRPC
        // messages tagged with the deviceId, which the server
        // checks against this device's push-token registration.
        // That registration exists only once it carried the APNs
        // token (`register(deviceToken:)`, after the
        // requestAuthorization below); until then the server
        // refuses every send.
        await SelfKeyManager.ensure()
        await DeviceRegistrar.ensure()
        // Register for remote notifications on THIS login, not just at
        // launch. TrackApp only calls requestAuthorization() during
        // setupApp, gated on being already authenticated — so without
        // this, a fresh install that signs in during this session would
        // not register until the next relaunch. No APNs token means no
        // push-token registration on the server, which is not merely
        // "no pushes":
        //   - the server refuses an SOS without it ("Device not
        //     found"), and
        //   - it rejects location sends the same way (see the
        //     comment above).
        // A first-time user could then neither raise an SOS nor share
        // their location until they restarted the app. Idempotent:
        // authorization status persists, so this is a no-op re-prompt for
        // anyone who already decided, and the token upload short-circuits
        // when it matches the last one pushed.
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
        // Pull pending received invites so the Circles tab + Map
        // banner can surface them without waiting for a /circles
        // refresh or a push-driven nudge. Solo invitees would
        // otherwise see an empty Circles tab and have no path to
        // discover the inviter waiting for them.
        await InvitesManager.shared.refresh()
        // Pull the effective premium entitlement (own subscription
        // OR circle-derived) so the Settings tier badge + geocoder
        // gate render correctly without waiting for the user to
        // navigate to Settings. Cached locally, so this only
        // changes the badge for users whose entitlement actually
        // shifted since the last launch.
        Task { await PremiumManager.shared.refresh() }
        // Signed out, or the session ended, during the awaits above: nothing
        // starts (the gate itself reads allowed after a sign-out).
        guard stillSignedIn(as: me, since: epoch) else { return }
        if let deviceId = keychain.getString(for: .deviceId),
           let accessToken = keychain.getString(for: .accessToken) {
            // Battery Saver / Low Power Mode: register the session but
            // let the first send open the stream lazily, rather than
            // holding an idle one. Still REGISTER it — skipping it
            // would leave the streamer with no desired (user, device),
            // so no send could ever bring it up and the phone would
            // stay dark for the whole session.
            if LocationService.shared.isBatterySaverActive {
                SDKLocationStreamer.shared.registerDesiredSession(userId: me, deviceId: deviceId)
            } else {
                SDKLocationStreamer.shared.start(
                    jwtToken: accessToken,
                    userId: me,
                    deviceId: deviceId
                )
            }
        }
        // Kick off background CLLocationManager tracking so the
        // distance + time-interval pumps in LocationService start
        // delivering points to CircleManager.syncLocation. Without
        // this the only way a location reaches the backend on a
        // returning-user launch is a manual Send-Location tap.
        //
        // Called UNCONDITIONALLY, not gated on
        // `hasLocationPermission`: a first-run user's prompt is
        // still unanswered at this point, and a gate here would
        // never record the intent to track, so the grant that
        // follows would restart nothing and the session would run
        // with no location at all. startTracking() defers itself,
        // and the authorization handler picks it up.
        locationService.startTracking()
    }

    /// Mirrors the Android app's SessionExpiredException gate. The
    /// predicate itself lives on `APIError` so this launch gate and the
    /// running-app gate in the refresh authority can't drift apart.
    private static func isSessionDefinitivelyExpired(_ error: Error) -> Bool {
        APIError.isSessionDefinitivelyExpired(error)
    }

    /// Best-effort, offline check of the access token's `exp` claim — used
    /// ONLY to decide whether a *background* refresh is safe to run. The
    /// refresh token is single-use and rotates on every `/auth/refresh`; if a
    /// background task lets an expired access token trigger that rotation and
    /// iOS suspends the app before the new token is persisted, the next launch
    /// presents a consumed token and the user is logged out. So background
    /// work only proceeds when the access token is still valid for `margin`
    /// seconds — i.e. it can complete its reads WITHOUT rotating. Foreground
    /// refreshes are unaffected; they can rotate safely because they aren't
    /// facing imminent suspension. Returns false when the token is missing or
    /// unparseable: background refresh is best-effort, so "don't know" means
    /// "skip and let the next foreground load handle it" rather than risk a
    /// background rotation.
    func accessTokenValid(forAtLeast margin: TimeInterval) -> Bool {
        guard let token = keychain.getString(for: .accessToken), !token.isEmpty,
              let exp = Self.jwtExpiry(token) else {
            return false
        }
        return Date(timeIntervalSince1970: exp) > Date().addingTimeInterval(margin)
    }

    /// Pure extraction of a JWT's `exp` claim (seconds since 1970), or nil if
    /// the token isn't a well-formed JWT with a numeric `exp`. Split out from
    /// `accessTokenValid(forAtLeast:)` so the parsing — base64url padding,
    /// missing/garbage segments, non-numeric `exp` — is unit-testable without
    /// keychain state. `nonisolated` so tests (and any caller) can invoke it
    /// off the main actor; it touches no instance state.
    nonisolated static func jwtExpiry(_ token: String) -> TimeInterval? {
        let segments = token.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        var b64 = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // base64url drops padding; restore it so Data(base64Encoded:) accepts it.
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = (json["exp"] as? NSNumber)?.doubleValue else {
            return nil
        }
        return exp
    }

    #if DEBUG
    private func applySyntheticUITestSession() {
        let fakeUserId = "uitest-user"
        let fakeToken = "uitest-access-token"
        let fakeDeviceId = "uitest-device"

        try? keychain.save(fakeToken, for: .accessToken)
        try? keychain.save(fakeUserId, for: .userId)
        try? keychain.save(fakeDeviceId, for: .deviceId)

        // Skip the onboarding walkthrough for shell tests so MainTabView
        // is the first thing the test sees.
        UserDefaults.standard.set(true, forKey: "onboarding.complete")

        // TrackApp gates on `!emailVerified` BEFORE it reaches MainTabView, and
        // nothing else sets it under this bypass — the /auth/me that normally
        // would cannot succeed with a synthetic token. Without this, the shell
        // tests land on EmailVerificationView and every "tab bar should render"
        // assertion fails, describing the symptom rather than the cause. A
        // synthetic session has to satisfy EVERY gate between authenticated and
        // the tab bar, not just the first one.
        emailVerified = true

        let now = Date()
        currentUser = User(
            id: fakeUserId,
            email: "uitest@example.test",
            displayName: "UI Test",
            publicKey: nil,
            createdAt: now,
            updatedAt: now
        )
        isAuthenticated = true
    }

    /// Post-login hook for UI tests: drain any pending received-invites
    /// via the API and accept each.
    ///
    /// This is a convenience for tests, NOT a stand-in for missing UI.
    /// Accepting an invite is fully wired in production: the Circles screen
    /// renders `PendingInviteRow` with Accept/Decline, going through
    /// `InvitesManager.accept(invite:consent:)` / `.decline(invite:)`, with a
    /// "Couldn't update invite" alert on failure. This bypass exists so a
    /// cross-platform test can reach a joined-circle state without driving
    /// that UI.
    ///
    /// Uses the SDK to wrap/unwrap the incoming circle key so the
    /// caller ends up with the decrypted key persisted in the same
    /// keychain slot CircleManager.loadCircles would normally
    /// populate. After we return, CircleManager.loadCircles refetch
    /// will see the newly-accepted circle.
    private func autoAcceptPendingInvitesForUITests(userId: String) async {
        do {
            let invites = try await api.receivedInvites()
            // Joining is agreeing: the test stands in for a person who
            // said yes at the notice, so the yes goes with each accept.
            let notice = try? await api.locationConsentNotice()
            let agreed = notice.map { ShownNotice(version: $0.version) }
            var lastAcceptedCircleId: String?
            for invite in invites {
                // Link-style invites (hasEncryptedKey=false) need
                // the client to wrap the circle key for itself
                // after the server hands it the plaintext key via
                // an out-of-band link. Email-style invites come
                // pre-wrapped, which is the Android-initiated flow
                // these tests use — skip the link case.
                guard invite.hasEncryptedKey else { continue }
                if (try? await api.acceptInvite(
                    inviteId: invite.id,
                    encryptedCircleKey: nil,
                    ephemeralPublicKey: nil,
                    locationConsent: LocationConsentGrant(agreed)
                )) != nil {
                    // Server returns null data on accept — the new
                    // circle id comes from the invite row itself.
                    lastAcceptedCircleId = invite.circleId
                }
            }
            // Force a circles refresh so the UI picks up the newly
            // accepted circle. Swallow errors — a failing reload is
            // caught downstream by the assertion that checks the
            // circles list.
            try? await CircleManager.shared.loadCircles()
            // Pin the newly-accepted circle as active so
            // cross-platform SOS + location tests target it
            // deterministically instead of whichever circle
            // UserDefaults.activeCircleId happens to point at
            // from a prior run.
            if let acceptedId = lastAcceptedCircleId,
               let circle = CircleManager.shared.circles.first(where: { $0.id == acceptedId }) {
                CircleManager.shared.setActiveCircle(circle)
            }
        } catch {
            print("[Track] autoAcceptPendingInvitesForUITests failed: \(error)")
        }
    }
    #endif

    // MARK: - Registration

    // THERE IS NONE, DELIBERATELY. Accounts are created on the account
    // portal (`AppConfiguration.registerURL`), which the login screen links
    // out to; the app only ever signs in.
    //
    // The portal's flow is the one that implements the assisted lane,
    // guardian-managed signups, email verification and recovery-key
    // reissue, and one registration flow means one set of registration
    // crypto to get right. Password reset and two-factor live there for
    // the same reason.

    // MARK: - Login

    func login(email: String, password: String) async throws {
        isLoading = true
        defer { isLoading = false }

        // SRP Step 1 - Get salt, bcrypt_salt (Proton preprocessing), and server public B
        let step1 = try await api.srpStep1(email: email)

        // SRP Step 2 - Compute client public A and proof M1 via mobile-sdk.
        let proof = try srpComputeLoginProof(
            email: email,
            password: password,
            saltB64: step1.salt,
            bcryptSalt: step1.bcryptSalt ?? "",
            serverPublicB64: step1.serverPublic
        )

        let step2 = try await api.srpStep2(
            sessionId: step1.sessionId,
            clientPublic: proof.clientPublic,
            clientProof: proof.clientProof
        )
        // The server proves it knows this account's verifier (M2) before
        // anything in its reply is used — no token stored, no key opened, no
        // second step started.
        guard Self.serverProofHolds(step2.serverProof, for: proof) else { throw AuthError.serverNotVerified }

        // A two-factor token with no access token IS the challenge, whether
        // or not the flag decoded: `requires_2fa` can fail to decode on the
        // iOS 26 runtime (see SRPStep2Response), which would skip this
        // branch.
        if step2.requires2fa == true || (step2.accessToken == nil && step2.twoFactorToken != nil) {
            // 2FA enrolled — stash the exchange token for the
            // /2fa/verify call that comes next. No access token
            // yet. The password is kept too: the keys are unlocked
            // from it after the code is accepted (see
            // `pendingPassword`).
            self.pendingPassword = password
            self.pendingEmail = email
            self.twoFactorMethods = step2.availableMethods
            self.tempToken = step2.twoFactorToken
            self.requires2FA = true
        } else if let accessToken = step2.accessToken {
            // Server's success branch returns a refresh token
            // alongside the access JWT. Persist both so
            // /auth/refresh can rotate them via
            // X-Refresh-Token. Older servers omit the field; fall
            // back to the empty-string sentinel which
            // APIService.refreshToken drops onto the legacy JWT
            // path the next time we refresh.
            try await completeLogin(
                accessToken: accessToken,
                refreshToken: step2.refreshToken ?? "",
                password: password,
                keys: step2.keysToOpen,
                typedEmail: email
            )
        } else {
            // Neither a session nor a challenge. Returning quietly here
            // would leave the user on the login screen with a spinner
            // that stops and nothing said at all.
            Self.authLog.error("sign-in: SRP step 2 answered with neither an access token nor a two-factor challenge")
            throw AuthError.unexpectedResponse
        }
    }

    func verify2FA(code: String) async throws {
        guard let tempToken = tempToken, let password = pendingPassword else {
            throw AuthError.noTempToken
        }

        isLoading = true
        defer { isLoading = false }

        // A wrong code throws here and leaves the challenge (token and password)
        // in place, so the user can type the code again on the same attempt.
        // An attempt that is over or has ended is dropped: the sheet's OK then
        // goes back to the password.
        let response: TwoFactorLoginResponse
        do {
            response = try await api.verify2FA(twoFactorToken: tempToken, code: code)
        } catch {
            guard let refusal = Self.twoFactorRefusal(error) else { throw error }
            if refusal == .twoFactorAttemptOver || refusal == .twoFactorAttemptEnded {
                self.tempToken = nil
                self.pendingPassword = nil
                self.pendingEmail = nil
            }
            throw refusal
        }

        // Accepted. The token is single-use, so this challenge is over whatever
        // happens next: drop it and the password before anything else can fail.
        // `requires2FA` stays true until the sign-in completes, so a key-unlock
        // failure below is reported on the 2FA sheet (whose OK then calls
        // `cancelTwoFactor()`) rather than vanishing with it.
        let typedEmail = pendingEmail
        self.tempToken = nil
        self.pendingPassword = nil
        self.pendingEmail = nil

        // The same key derivation as a password-only sign-in: without it, a
        // two-factor sign-in would finish with no keys.
        // verify2FA's login response carries a refresh token; default to the
        // empty sentinel (same as the SRP step-2 path) if the server omitted it.
        try await completeLogin(accessToken: response.accessToken, refreshToken: response.refreshToken ?? "",
                                password: password, keys: response.keysToOpen, typedEmail: typedEmail)

        self.requires2FA = false
        self.twoFactorMethods = nil
    }

    /// The two-step sign-in's refusals, by the auth server's reply: a wrong
    /// code (401) and a code already used (400 `totp_replay`) are typed again
    /// on the same attempt; too many wrong codes (429 `rate_limited`, the
    /// attempt's fifth or the account's limit) and an attempt that has ended
    /// (any other 400: expired, or already used) mean signing in again.
    /// Anything else is said as any other failure.
    nonisolated static func twoFactorRefusal(_ error: Error) -> AuthError? {
        guard let api = error as? APIError else { return nil }
        switch api.code {
        case "http_401": return .wrongTwoFactorCode
        case "http_429": return .twoFactorAttemptOver
        case "http_400": return api.errorCode == "totp_replay" ? .twoFactorCodeJustUsed : .twoFactorAttemptEnded
        default: return nil
        }
    }

    /// Abandon a pending second step and return to the password screen.
    ///
    /// Clears only the challenge, never `logout()`, which wipes the keychain
    /// and every cache: nothing is signed in yet at this point, and a device
    /// whose session merely EXPIRED (`expireSession()`) still holds the
    /// account's keys and caches on purpose. Cancelling a code prompt must
    /// not destroy them.
    func cancelTwoFactor() {
        requires2FA = false
        tempToken = nil
        pendingPassword = nil
        pendingEmail = nil
        twoFactorMethods = nil
    }

    /// `POST /auth/logout`, given a few seconds: a sign-out never waits on a
    /// network that is not there. Unanswered, the session stays until it idles
    /// out, and the server keeps one push row per token.
    private func endServerSession() async {
        // Named by its refresh token too, so an expired access token
        // doesn't leave the session alive (it never expires by itself).
        let refreshToken = keychain.getString(for: .refreshToken)
        guard keychain.getString(for: .accessToken) != nil || refreshToken != nil else { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { _ = try? await APIService.shared.logout(refreshToken: refreshToken) }
            group.addTask { try? await Task.sleep(nanoseconds: 4_000_000_000) }
            await group.next()
            group.cancelAll()
        }
    }

    /// `keys`: what the sign-in's own reply carries (SRP step 2, or the 2FA
    /// step) — the keys of the credential that proved. /auth/me is read only
    /// for who the user is, never for keys.
    /// `typedEmail`: the email its person typed for this sign-in (nil: none
    /// was), for the guarded tidy (`SignInTidy`).
    private func completeLogin(accessToken: String, refreshToken: String, password: String,
                               keys signInKeys: SignInKeys?, typedEmail: String?) async throws {
        let epoch = sessionEpoch
        // Before anything this sign-in writes to the keychain: with no device
        // tag yet, the approval records here are no longer this device's to
        // adopt (`KeyDeliveryApprovals.noteSignInStarting`).
        KeyDeliveryApprovals.noteSignInStarting()

        // Read BEFORE the incoming tokens land, because `.userId` is only
        // rewritten once `getMe()` answers and this is the last moment the
        // OUTGOING account is still identifiable.
        let priorUserId = keychain.getString(for: .userId)

        try keychain.save(accessToken, for: .accessToken)
        try keychain.save(refreshToken, for: .refreshToken)

        let user = try await api.getMe()
        // The account's id in its one form: the purge below, the Keychain
        // and every per-account store key by it. /auth/me naming the account
        // any other way is no answer: the sign-in fails, and nothing is
        // purged, wiped or saved.
        guard let me = CanonicalId.of(user.id) else {
            Self.authLog.error("sign-in: /auth/me named the account by an id that isn't a UUID")
            withdrawIncompleteSignIn()
            throw AuthError.unexpectedResponse
        }

        // Account-switch purge, and the load-bearing half of `expireSession()`.
        //
        // A session expiry deliberately KEEPS this device's key material and
        // caches so the SAME user can sign back in and find their app intact.
        // That is exactly what makes a DIFFERENT user signing in here dangerous:
        // account A's master key, circle-key mirror, cached places, member
        // addresses and SAS markers are all still present. Purge them BEFORE
        // installing B — otherwise B decrypts under A's keys and sees A's data.
        //
        // Skipped after a normal `logout()`, which already purged and cleared
        // `.userId`, so `priorUserId` is nil. Skipped for a same-user re-login,
        // which is the whole point. Compared in the one form: a prior id that
        // isn't one is another account's.
        if let prior = priorUserId, CanonicalId.of(prior) != me {
            // The outgoing account's pins first, as its sign-out
            // keeps them: whether they go is the guarded tidy's to
            // say once this sign-in has succeeded (`SignInTidy`). A
            // server naming some other account here never makes
            // this device forget them.
            if let outgoing = CanonicalId.of(prior), KeyStoreRecovery.pinsExportable(cryptoManager.keyStoreStatus()) {
                RetainedMemberPins.retain(owner: outgoing, crypto: cryptoManager)
            }
            await purgeAccountData()
            deleteOutgoingKeyMaterial()
        }

        currentUser = user
        try keychain.save(me, for: .userId)
        // Pre-populate emailVerified from /auth/me so the post-login
        // route doesn't briefly flash the EmailVerificationView while
        // the 5s status poll catches up. Mirrors the same step in
        // `checkExistingSession`.
        if let verified = user.emailVerified {
            emailVerified = verified
        }
        learn(user)

        // Generate device ID if needed (must happen before
        // DeviceRegistrar.ensure() reads it).
        if keychain.getString(for: .deviceId) == nil {
            let deviceId = UUID().uuidString
            try keychain.save(deviceId, for: .deviceId)
        }

        // Derive the sharing private key from the password + server-
        // stored wrapped keys FIRST, before anything that needs the
        // SDK to ECDH-unwrap. Byte-identical to the Android app and
        // Note iOS:
        //   derivedKey  = Argon2id(password, kdf_salt, kdf_params)
        //   masterKey   = secretbox.open(encrypted_master_key, derivedKey)
        //   sharingPriv = secretbox.open(encrypted_sharing_private_key, masterKey)
        // Order matters: running SelfKeyManager.ensure() BEFORE this
        // fails silently, because storeCircleKey needs the private key
        // for the ECDH unwrap — leaving personal places undecryptable
        // for the rest of the session.
        //
        // A failure here FAILS THE SIGN-IN, as it does on the Android app
        // (AuthRepository: "Could not unlock your encrypted keys"): signed
        // in with no keys, every circle would be unreadable, nothing
        // sharable, and no message anywhere. The tokens saved above are
        // withdrawn, so the next launch does not resume a half-signed-in
        // state either.
        //
        // The keys come from the sign-in's own reply, like both Android
        // apps: the credential that proved is the one whose keys these
        // are. /auth/me's copy opens only for whichever credential last set it,
        // and serves a password-wrapped key to any session holder. A reply
        // with no keys signs in without them; the password is then asked for in
        // place.
        // The SDK's key store, before any key of this sign-in goes in
        // (`KeyStoreRecovery`): an owed wipe is paid, a store that doesn't
        // decode is cleared (the import writes it whole), entries that didn't
        // read go. One the platform couldn't read is never cleared: the
        // sign-in stops.
        if KeyStoreRecovery.shared.beforeSignInImport() == .stop {
            Self.authLog.error("sign-in: the key store could not be read; nothing was cleared")
            withdrawIncompleteSignIn()
            throw AuthError.keysUnavailable
        }
        if let signInKeys {
            do {
                try await deriveAndImportSharingKey(password: password, keys: signInKeys.keys, kdf: signInKeys.kdf)
            } catch {
                Self.authLog.error(
                    "sign-in: could not unlock the account's encryption keys: \(String(describing: error), privacy: .public)"
                )
                withdrawIncompleteSignIn()
                throw AuthError.keysUnavailable
            }
        }

        // This account's pins from its last sign-out, back in before any
        // circle key or roster is touched — both trust the pins. Needs the
        // signing key, which the derivation above imported.
        let restoredPins = RetainedMemberPins.restore(owner: me, crypto: cryptoManager)
        if restoredPins > 0 {
            RetainedMemberPins.log.info("restored \(restoredPins, privacy: .public) member pin record(s) from the last sign-out")
        }

        // The sign-in has succeeded: nothing below fails it. Only now does
        // another account's data go, so a sign-in that fails deletes nothing.
        // What holds against the server (the removals an account still owes
        // a record for, its approvals with their tombstones and dead ids, its
        // retained pins) goes only when the email typed now differs from the
        // one saved with that account (`SignInTidy`); its marks and
        // account-keyed settings always go. What a retired store left in the
        // Keychain goes for every account.
        KeychainService.shared.purgeRetiredItems()
        SignInTidy.run(signedIn: me, typedEmail: typedEmail)
        AccountKeyedDefaults.wipe(except: me)
        MemberVerificationStore.adopt(owner: me)

        // An account not approved (yet) is signed in to its screen and nothing
        // of Track's: its token reaches the account service alone
        // (`RegistrationGate.allows`, the auth server's own answer when it
        // serves one). The approval or the verified address that screen sees
        // starts the rest.
        guard RegistrationGate.allows(registration, trackAccess: trackAccess) else {
            isAuthenticated = true
            signInNotice = nil
            signInEmail = nil
            SignedOutNotice.clear()
            return
        }

        // Personal self-tracking key bootstrap — mirrors the Android
        // app's LocationRepository.ensurePersonalKeyExists.
        // Pulls (or mints + publishes) the wrap stored under the
        // nil-UUID pseudo-circle so own-user history is decryptable
        // regardless of whether the user has joined a circle yet.
        // Awaited (not detached): DeviceRegistrar below seals the
        // device-name/type fields with it when it is there.
        await SelfKeyManager.ensure()

        // Register this device with the server. Idempotent (flagged in
        // UserDefaults per userId × deviceId). Token-less, this writes no
        // row yet: the device-ownership check of ingest, needs-attention and
        // check-ins passes once the token-carrying registration asked for
        // below has run.
        await DeviceRegistrar.ensure()

        // Push tokens are session-scoped on the server, so a fresh
        // session must re-send the APNs token. Clear the
        // last-pushed-token cache so the next register() re-POSTs it
        // under the new session rather than short-circuiting on the old
        // value. Mirrors the Android app clearing pushTokenSynced on
        // login.
        PushNotificationManager.shared.reset()
        // And ask iOS for the token now, without a prompt (the prompt stays
        // on onboarding's page, where it is explained). It lands in
        // `register(deviceToken:)`, which registers the device WITH it. Until
        // then the server refuses this device's locations, needs-attention and
        // check-ins ("Device not found"), and nothing else in this session
        // asks for it: without this, a new account would share nothing until
        // a relaunch.
        PushNotificationManager.shared.requestDeviceToken()

        // Surface any pending circle invites in the freshly-logged-in
        // session. Parity with checkExistingSession.
        await InvitesManager.shared.refresh()
        Task { await PremiumManager.shared.refresh() }

        isAuthenticated = true
        signInNotice = nil
        signInEmail = nil
        SignedOutNotice.clear()
        // A seed the import replaced, entries dropped above: the banner goes.
        _ = KeyStoreRecovery.shared.check()

        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-UITestAutoAcceptInvites") {
            await autoAcceptPendingInvitesForUITests(userId: me)
        }
        #endif

        // The session ended during the awaits above: nothing starts.
        guard stillSignedIn(as: me, since: epoch) else { return }

        // Bring up the gRPC location stream once we have a confirmed
        // (jwt, userId, deviceId) triple. Idempotent — startStreaming
        // is a no-op if it's already running for this device.
        if let deviceId = keychain.getString(for: .deviceId) {
            // See checkExistingSession: register in Battery Saver so the first
            // send opens the stream lazily; never skip it, or the phone cannot
            // upload at all for the session.
            if LocationService.shared.isBatterySaverActive {
                SDKLocationStreamer.shared.registerDesiredSession(userId: me, deviceId: deviceId)
            } else {
                SDKLocationStreamer.shared.start(
                    jwtToken: accessToken,
                    userId: me,
                    deviceId: deviceId
                )
            }
        }
        // Start the distance + time-interval CLLocationManager pumps.
        // See checkExistingSession for the parallel call on the
        // returning-user path.
        //
        // Unconditional, and this is the call site that matters most: a
        // fresh sign-in is exactly when the location prompt has not been
        // answered yet. A `hasLocationPermission` guard here would skip it,
        // and nothing else would recover: SettingsView requests the
        // permission but never starts tracking.
        locationService.startTracking()
    }

    /// Undo what `completeLogin` wrote before the keys failed to unlock: the
    /// session tokens and the in-memory user. Deliberately NOT `logout()` —
    /// that also destroys the key material and caches a same-user device keeps
    /// across an expired session. The server-side session is left to expire;
    /// with its refresh token gone nothing on this device can use it.
    private func withdrawIncompleteSignIn() {
        keychain.delete(key: .accessToken)
        keychain.delete(key: .refreshToken)
        keychain.delete(key: .tokenExpiry)
        currentUser = nil
        isAuthenticated = false
    }

    /// The password, asked for right where this device found it has no
    /// account keys (a locked circle, the personal-history notice) — never
    /// "sign out, then sign in again". Opens the account's keys here exactly
    /// as a sign-in does (`deriveAndImportSharingKey`), then reloads what
    /// needs them.
    ///
    /// Through the auth server's re-auth exchange on THIS session, not a
    /// sign-in. A second SRP login would open a second session (at the cap it
    /// evicts another of the person's devices), ask a 2FA account for its code
    /// again, and orphan this session's push rows. Re-auth proves the password
    /// to the server — its rate limit, the current email as the SRP identity —
    /// and hands back what THAT credential's password opens, the same shapes as
    /// the login reply. Nothing is signed out and nothing on this device is lost.
    ///
    /// Throws APIError `invalid_credentials` for a wrong password; the form
    /// says so. Without a connection the network error is thrown and the form
    /// tries again by itself. A handshake that went stale between the two
    /// steps (`reauth_session_expired`) is started again once, saying nothing.
    func unlockWithPassword(_ password: String) async throws {
        // The session's own account: re-auth identifies the user from the
        // session, so the keys it hands back are never another account's.
        guard isAuthenticated, let me = userId else { throw AuthError.noUserId }
        let step2: ReauthStep2Response
        do {
            step2 = try await reauthExchange(password)
        } catch let error as APIError where error.code == "reauth_session_expired" {
            step2 = try await reauthExchange(password)
        }
        guard let keys = step2.keysToOpen, let kdf = step2.kdfParams else { throw AuthError.keysUnavailable }
        try await deriveAndImportSharingKey(password: password, keys: keys, kdf: kdf)
        Self.authLog.info("unlocked in place: the account's keys are back on this device")
        // Asked once. If even the password did not bring the signing key back
        // (a blob that will not open), it is not asked for again this session.
        SelfKeyManager.passwordDidNotRestoreSigningKey = (try? cryptoManager.signingPublicKeyHex()) == nil
        if SelfKeyManager.passwordDidNotRestoreSigningKey {
            Self.authLog.error("unlocked in place, but the signing key did not open; not asking again this session")
        }
        // As a sign-in does once the keys are in: this account's kept
        // pins, if any, before a circle key or roster is touched.
        MemberVerificationStore.adopt(owner: me)
        RetainedMemberPins.restore(owner: me, crypto: cryptoManager)
        // What a sign-in does next with the keys; each is best effort and
        // retries on its own clock.
        await SelfKeyManager.ensure()
        await DeviceRegistrar.ensure()
        try? await CircleManager.shared.loadCircles()
    }

    /// Re-auth steps 1 and 2 with the password, on this session.
    private func reauthExchange(_ password: String) async throws -> ReauthStep2Response {
        let step1 = try await api.reauthStep1()
        let email: String
        if let current = step1.email {
            email = current
        } else if let cached = currentUser?.email {
            email = cached
        } else {
            email = try await api.getMe().email
        }
        let proof = try srpComputeLoginProof(
            email: email,
            password: password,
            saltB64: step1.salt,
            bcryptSalt: step1.bcryptSalt ?? "",
            serverPublicB64: step1.serverPublic
        )
        let step2 = try await api.reauthStep2(
            sessionId: step1.sessionId,
            clientPublic: proof.clientPublic,
            clientProof: proof.clientProof
        )
        // As at sign-in: nothing in the reply is used unless M2 holds.
        guard Self.serverProofHolds(step2.serverProof, for: proof) else { throw AuthError.serverNotVerified }
        return step2
    }

    /// The server's proof M2 must be exactly H(A | M1 | S) for THIS attempt,
    /// in the SDK client's own encoding (minimal). Missing, wrong, or not
    /// checkable (this device's own values malformed: a bug, logged): the
    /// attempt stops, with nothing from the reply used, and fails as a
    /// sign-in or re-auth that didn't work — never as a wrong password,
    /// since the password may be right.
    static func serverProofHolds(_ serverProof: String?, for proof: SrpLoginProof) -> Bool {
        guard let serverProof, !serverProof.isEmpty else {
            authLog.error("sign-in: the server sent no proof; nothing from its reply is used")
            return false
        }
        do {
            let holds = try srpVerifyServerProof(
                clientPublicB64: proof.clientPublic, clientProofB64: proof.clientProof,
                sessionKeyB64: proof.sessionKey, serverProofB64: serverProof, encoding: .minimal)
            if !holds { authLog.error("sign-in: the server's proof does not hold; nothing from its reply is used") }
            return holds
        } catch {
            authLog.error("sign-in: the server's proof could not be checked: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    // MARK: - Vault Key Derivation

    /// Sign-in diagnostics that must survive a release build (`print` does
    /// not reach the unified log there). Error descriptions only — never a
    /// key, a password or a token.
    static let authLog = Logger(subsystem: "com.pingolin.track", category: "Auth")

    private static let sodium = Sodium()

    /// Open the account's key vault with the password: Argon2id(password) opens
    /// the master key, which opens the X25519 sharing private key. Pure over the
    /// SDK — no keychain, no network, no actor state — so this step can be
    /// exercised by a test with a real vault and a wrong password.
    ///
    /// Synchronous and slow (Argon2id is memory-hard); callers keep it off the
    /// main actor.
    nonisolated static func unlockVault(
        crypto: PingolinTrackSDK.CryptoManager,
        password: String,
        keys: EncryptedKeysResponse,
        kdf: KdfParamsResponse
    ) throws -> (masterKeyB64: String, sharingPrivateKeyB64: String) {
        // All vault decryption flows through the SDK to match android,
        // eliminating swift-sodium from the iOS crypto surface. Same primitives
        // + params under the hood, single implementation across platforms.
        let kdfParams = KdfParams(
            salt: kdf.salt,
            memoryKib: UInt32(kdf.memoryKib),
            iterations: UInt32(kdf.iterations),
            parallelism: UInt32(kdf.parallelism)
        )
        let masterKeyB64: String
        do {
            masterKeyB64 = try crypto.decryptWithPassword(
                encryptedData: EncryptedData(
                    nonce: keys.masterKey.nonce,
                    ciphertext: keys.masterKey.ciphertext
                ),
                password: password,
                kdfParams: kdfParams
            )
        } catch {
            throw VaultDerivationError.masterKeyOpen
        }
        do {
            let sharingPrivateKeyB64 = try crypto.decryptWithKey(
                encryptedData: EncryptedData(
                    nonce: keys.sharingPrivateKey.nonce,
                    ciphertext: keys.sharingPrivateKey.ciphertext
                ),
                keyBase64: masterKeyB64
            )
            return (masterKeyB64, sharingPrivateKeyB64)
        } catch {
            throw VaultDerivationError.sharingKeyOpen
        }
    }

    private func deriveAndImportSharingKey(
        password: String,
        keys: EncryptedKeysResponse,
        kdf: KdfParamsResponse
    ) async throws {
        // PERF: the Argon2id KDF (memMib-scale, hundreds of ms) is a
        // synchronous FFI call — hop it off the main actor so login doesn't
        // freeze the UI. The keychain writes + SDK imports below stay on
        // MainActor.
        let crypto = cryptoManager
        let (masterKeyB64, sharingPrivateKeyB64) = try await Task.detached(priority: .userInitiated) {
            try Self.unlockVault(crypto: crypto, password: password, keys: keys, kdf: kdf)
        }.value

        try keychain.save(masterKeyB64, for: .masterKey)
        try keychain.save(sharingPrivateKeyB64, for: .sharingPrivateKey)

        // Hand the private key to the SDK so storeCircleKey can do the X25519
        // ECDH-unwrap. The Android app does this implicitly through
        // KeyStorageCallback; iOS keeps it explicit.
        try cryptoManager.importPrivateKey(privateKeyBase64: sharingPrivateKeyB64)

        // The account's public key is the one its private key derives, never
        // the one the reply serves: that is only compared, and a difference
        // logged.
        let derivedSharing = try cryptoManager.exportPublicKey()
        if let served = keys.sharingPublicKey, !Self.samePublicKey(served, derivedSharing) {
            Self.authLog.error("sign-in: the server's sharing_public_key is not the key this account's private key derives; using the derived one")
        }
        try keychain.save(derivedSharing, for: .sharingPublicKey)

        // The signing key is NOT fatal to the sign-in, matching the Android app:
        // without it this device's wraps go out unsigned, which peers already
        // handle, while refusing the sign-in would lock out an account over a
        // damaged signing blob. Logged rather than hidden, because it does
        // weaken what this device can prove.
        if let signingBlob = keys.signingPrivateKey {
            do {
                try await importSigningKey(
                    signingBlob: signingBlob,
                    serverSigningPublicKey: keys.signingPublicKey,
                    masterKeyBase64: masterKeyB64,
                    sharingPrivateKeyBase64: sharingPrivateKeyB64
                )
            } catch {
                Self.authLog.error(
                    "sign-in: signing key not imported, wraps from this device will be unsigned: \(String(describing: error), privacy: .public)"
                )
            }
        }
    }

    private func importSigningKey(
        signingBlob: EncryptedBlobResponse,
        serverSigningPublicKey: String?,
        masterKeyBase64: String,
        sharingPrivateKeyBase64: String
    ) async throws {
        let signingPrivateKeyB64: String
        do {
            signingPrivateKeyB64 = try cryptoManager.decryptWithKey(
                encryptedData: EncryptedData(
                    nonce: signingBlob.nonce,
                    ciphertext: signingBlob.ciphertext
                ),
                keyBase64: masterKeyBase64
            )
        } catch {
            throw VaultDerivationError.signingKeyOpen
        }
        try cryptoManager.importSigningPrivateKey(secretSeedB64: signingPrivateKeyB64)

        // Nothing here ever replaces the account's signing key. The
        // legacy shape — the X25519 sharing private key used as the
        // signing seed — is decided from the keys just opened, never
        // from the server's unauthenticated `signing_public_key`, and
        // is only logged and counted, never migrated. A genuine key
        // the server's record disagrees with is kept and used.
        let verdict = Self.signingKeyVerdict(
            signingPrivateKey: Data(base64Encoded: signingPrivateKeyB64) ?? Data(),
            sharingPrivateKey: Data(base64Encoded: sharingPrivateKeyBase64) ?? Data(),
            derivedVerifyingKeyHex: try? cryptoManager.signingPublicKeyHex(),
            serverVerifyingKeyHex: serverSigningPublicKey.flatMap(Self.normalizeToHex)
        )
        switch verdict {
        case .matches:
            return
        case .serverDisagrees:
            Self.authLog.error(
                "sign-in: the server's signing_public_key is not this account's own key; keeping the key that opened, not rotating on the server's word"
            )
            return
        case .legacy:
            let seen = Self.countLegacySigningKey(userId: userId)
            Self.authLog.error(
                "sign-in: this account's signing key has the pre-fix shape (seen \(seen, privacy: .public) time(s) on this device); it is kept, never replaced here"
            )
        }
    }

    /// How often this device has opened a legacy-shape signing key for the
    /// account (logged and counted, never rotated). Kept per account.
    nonisolated static func countLegacySigningKey(userId: String?, defaults: UserDefaults = .standard) -> Int {
        let key = "signingKey.legacyShapeSeen.\((userId ?? "unknown").lowercased())"
        let seen = defaults.integer(forKey: key) + 1
        defaults.set(seen, forKey: key)
        return seen
    }

    enum SigningKeyVerdict: Equatable {
        /// The opened seed IS the sharing private key: the legacy shape.
        /// Logged and counted, never rotated.
        case legacy
        /// A real key, and the server's record agrees (or has none). Nothing to do.
        case matches
        /// A real key the server's record does not match. The record is wrong,
        /// not the key: keep it, and never rotate on the server's word.
        case serverDisagrees
    }

    /// Pure, for tests; the same rule as the account portal applies. A fully
    /// hostile server serving the sharing key's own blob in the signing slot
    /// (both are sealed under the master key) makes a real key look legacy:
    /// since a legacy key is never migrated, that gains it nothing.
    nonisolated static func signingKeyVerdict(
        signingPrivateKey: Data,
        sharingPrivateKey: Data,
        derivedVerifyingKeyHex: String?,
        serverVerifyingKeyHex: String?
    ) -> SigningKeyVerdict {
        // The 32-byte seed, whether held as the seed or as libsodium's 64-byte
        // seed‖verifying key (portal registrations).
        let seed = signingPrivateKey.count == 64 ? signingPrivateKey.prefix(32) : signingPrivateKey
        if !seed.isEmpty, constantTimeEqual(seed, sharingPrivateKey) { return .legacy }
        guard let server = serverVerifyingKeyHex?.lowercased(),
              let derived = derivedVerifyingKeyHex?.lowercased() else { return .matches }
        return server == derived ? .matches : .serverDisagrees
    }

    /// Same length and bytes, in time that does not depend on where they differ.
    nonisolated static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(a, b) { diff |= x ^ y }
        return diff == 0
    }

    /// Whether two public keys, each as hex or base64, are the same bytes.
    nonisolated static func samePublicKey(_ a: String, _ b: String) -> Bool {
        func bytes(_ value: String) -> Data? {
            if value.count % 2 == 0, !value.isEmpty, value.allSatisfy(\.isHexDigit) {
                var data = Data()
                var index = value.startIndex
                while index < value.endIndex {
                    let next = value.index(index, offsetBy: 2)
                    guard let byte = UInt8(value[index..<next], radix: 16) else { return nil }
                    data.append(byte)
                    index = next
                }
                return data
            }
            return Data(base64Encoded: value)
        }
        guard let x = bytes(a), let y = bytes(b), !x.isEmpty else { return false }
        return x == y
    }

    /// The server emits `signing_public_key` as either base64 or hex
    /// depending on legacy storage path. Normalize to lowercase hex
    /// for comparison with `signingPublicKeyHex()`.
    private static func normalizeToHex(_ value: String) -> String? {
        if value.allSatisfy({ $0.isHexDigit }) {
            return value
        }
        if let bytes = Self.sodium.utils.base642bin(value, variant: .ORIGINAL) {
            return bytes.map { String(format: "%02x", $0) }.joined()
        }
        return nil
    }

    enum VaultDerivationError: LocalizedError {
        case invalidKdfSalt, argon2Failed, masterKeyOpen, sharingKeyOpen
        case signingKeyOpen
        case base64EncodeFailed

        var errorDescription: String? {
            switch self {
            case .invalidKdfSalt: return "kdf_salt not valid base64"
            case .argon2Failed: return "Argon2id KDF failed"
            case .masterKeyOpen: return "Failed to decrypt master key (wrong password?)"
            case .sharingKeyOpen: return "Failed to decrypt sharing private key"
            case .signingKeyOpen: return "Failed to decrypt signing private key"
            case .base64EncodeFailed: return "Sharing key base64 encoding failed"
            }
        }
    }

    // MARK: - Email Verification

    /// Poll `/auth/email/status` while the verification screen is visible.
    ///
    /// Checks at once, then backs off: 5, 10, 20 s, then every 30 s. The view
    /// stops it on disappear and on backgrounding, and restarts it (with an
    /// immediate check) on return: tracking can keep a restored session's
    /// process resident whether or not the address is verified (unless the
    /// auth server serves `track_access`: `RegistrationGate`), and a poll that
    /// never stopped would run all night for an unverified user with Always
    /// location.
    func startEmailVerificationPolling() {
        emailVerificationTask?.cancel()
        emailVerificationTask = Task { @MainActor [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                guard let self else { return }
                if await self.checkEmailVerification() { return }
                let delay = Self.emailVerificationPollDelay(afterAttempts: attempt)
                attempt += 1
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    /// Stop polling: the screen went away or the app went to the background.
    func stopEmailVerificationPolling() {
        emailVerificationTask?.cancel()
        emailVerificationTask = nil
    }

    /// Wait after the Nth check: 5, 10, 20, then 30 s.
    nonisolated static func emailVerificationPollDelay(afterAttempts attempts: Int) -> TimeInterval {
        let exponent = Double(min(max(attempts, 0), 8))
        return min(5 * pow(2, exponent), 30)
    }

    /// One status check. True once the address is verified (polling ends).
    /// Verified, what the auth server serves for Track may have changed with
    /// it (`track_access`): /auth/me is read again before the screen moves on
    /// (a failed read polls again), and Track opens by the approval's path if
    /// it has just opened. An account under review gets that screen next
    /// instead.
    private func checkEmailVerification() async -> Bool {
        do {
            let status = try await api.getEmailVerificationStatus()
            if status.emailVerified, !Task.isCancelled {
                guard let me = userId, let user = try? await api.getMe(),
                      Self.sessionAccount(served: user.id, stored: me) == me, !Task.isCancelled else { return false }
                // The watch ends here: the screen going away (which the next
                // screen makes happen) cancels nothing below.
                emailVerificationTask = nil
                await unlockTrack(me: me, served: user) { emailVerified = true }
                return true
            }
        } catch {
            // Ignore errors during polling
        }
        return false
    }

    func resendVerificationEmail() async throws {
        _ = try await api.resendVerificationEmail()
    }

    // MARK: - Approval

    /// The under-review screen's watch: /auth/me read again while it is in
    /// front, at once and then backing off as the email check does (5, 10, 20,
    /// then every 30 s). Approved: a fresh session first (auth gives a token
    /// Track's audience only at a refresh), then everything of Track's the
    /// sign-in held back, and the app. Turned down: the not-approved screen. A
    /// read that fails changes nothing.
    func startApprovalPolling() {
        approvalTask?.cancel()
        approvalTask = Task { @MainActor [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                guard let self else { return }
                if await self.checkApproval() { return }
                let delay = Self.emailVerificationPollDelay(afterAttempts: attempt)
                attempt += 1
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    /// Stop watching: the screen went away or the app went to the background.
    func stopApprovalPolling() {
        approvalTask?.cancel()
        approvalTask = nil
    }

    /// One read. True once the account is decided (the watch ends).
    private func checkApproval() async -> Bool {
        guard registration == .pending,
              let user = try? await api.getMe(),
              let me = Self.sessionAccount(served: user.id, stored: keychain.getString(for: .userId)) else { return false }
        let status = RegistrationGate.served(user.registrationStatus)
        guard status != .pending, !Task.isCancelled else { return false }
        // Decided: the watch ends here, so nothing stops what follows. Showing
        // the app takes the under-review screen away, and its `onDisappear`
        // stops the watch: a cancel then would cut Track's start-up short.
        approvalTask = nil
        if status == .approved {
            await unlockTrack(me: me, served: user) {}
        } else {
            learn(user)
        }
        return true
    }

    /// What an approval or a verified address opens, from the /auth/me read
    /// that saw it (`user`). The token held may reach the account service
    /// alone, so a fresh session first (auth gives Track's audience only at a
    /// refresh). Then, if this account is still the one signed in, what auth
    /// served is learned and `show` moves the screen on; and if Track has just
    /// opened to this account, everything of Track's the sign-in or the launch
    /// held back starts. Exactly once: a second watch, which the screen starts
    /// on coming back to the front, finds Track open already. The caller's
    /// watch has ended, so the screen going away cancels none of it.
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

    /// What /auth/me served for the gate (`RegistrationGate`), through the
    /// setters: the status, and auth's own answer when it serves one.
    private func learn(_ user: User) {
        registration = RegistrationGate.served(user.registrationStatus)
        trackAccess = user.trackAccess
    }

    /// For a headless relaunch with nothing kept to say whether this account
    /// may be tracked (`RegistrationGate.Knowledge.unread`: an update from a
    /// build without the gate): /auth/me read, and learned through the setters,
    /// which stop anything running if it may not. True when it answered for the
    /// account the Keychain names.
    func readAccess() async -> Bool {
        guard let user = try? await api.getMe(),
              Self.sessionAccount(served: user.id, stored: keychain.getString(for: .userId)) != nil else { return false }
        learn(user)
        return true
    }

    // MARK: - Account Deletion

    /// Zero-knowledge SRP step-up. Proves possession of the password to
    /// the server WITHOUT transmitting it, returning a short-lived
    /// `reauth_token` for a sensitive action (currently account delete).
    /// Mirrors the login handshake — srpStep1 → srpComputeLoginProof →
    /// srpStep2 — but against the authenticated /auth/reauth/srp/*
    /// endpoints, which identify the user from the session rather than
    /// an emailed identity. A wrong password fails proof verification
    /// server-side and throws (401), the same failure surface as login.
    func reauthenticate(password: String) async throws -> String {
        // The same exchange as the password asked in place, M2 checked.
        // SRP binds the proof to the account's identity string, so the email
        // must be the one the server's verifier was derived with: step 1 says
        // which (the current one, even after an email change).
        try await reauthExchange(password).reauthToken
    }

    /// Permanently delete the current account. Proves the password via a
    /// zero-knowledge SRP step-up (reauthenticate) and calls the auth server's
    /// DELETE /api/v1/auth/me endpoint with the resulting short-lived
    /// token — the raw password never leaves the device — plus the
    /// per-circle (circleId, userPseudonym) pairs the SDK can derive from
    /// the keys we hold. After a successful delete, runs the same cleanup
    /// logout() does so the caller doesn't end up in a half-signed-out UI.
    /// Delete the account, returning what happened to the user's billing.
    ///
    /// The caller must show `billingNeedsAttention` BEFORE it dismisses. Once
    /// this returns, the account no longer exists and there is no screen left to
    /// carry the instruction — an App Store subscription keeps charging until the
    /// customer cancels it themselves, and only they can.
    @discardableResult
    /// - Parameter forfeitCreditBalance: the user's answer to the server's
    ///   refusal when the account still holds bought credit. Never true on a
    ///   first attempt — destroying somebody's money takes a deliberate act.
    func deleteAccount(
        password: String,
        forfeitCreditBalance: Bool = false
    ) async throws -> DeleteAccountResponse {
        guard let userId = userId else {
            throw AuthError.noUserId
        }
        let pseudonyms = (try? cryptoManager.collectDeletionPseudonyms(userId: userId)) ?? []
        let request: [DeletionPseudonymRequest] = pseudonyms.map {
            DeletionPseudonymRequest(circleId: $0.circleId, userPseudonym: $0.userPseudonym)
        }
        let token = try await reauthenticate(password: password)
        // From here the server ends the session as it deletes.
        sessionEndingByChoice = true
        defer { sessionEndingByChoice = false }
        let result = try await api.deleteAccount(
            reauthToken: token,
            pseudonyms: request,
            forfeitCreditBalance: forfeitCreditBalance
        )

        // Publish BEFORE the logout that replaces the view tree, so the root has
        // it to show. Deliberately not cleared by `logout()` — this outlives the
        // session on purpose, because the session is the thing that just ended.
        postDeletionNotice = Self.deletionNotice(
            billingNeedsAttention: result.billingNeedsAttention,
            appStoreRemaining: result.appStoreSubscriptionsRemaining,
            cancellationsFailed: result.subscriptionCancellationsFailed,
            dataErasure: result.dataErasure
        )

        // The account is gone: nothing of it is kept for a "next sign-in", nor
        // any notice of an involuntary sign-out set meanwhile, nor its address.
        await logout(retainingTrust: false)
        signInNotice = nil
        signInEmail = nil
        SignedOutNotice.clear()
        return result
    }

    /// What to tell somebody about their money after their account is gone.
    ///
    /// The two counts are INDEPENDENT and can both be non-zero: subscriptions
    /// are unique per (user, product), so one person can hold a Track
    /// subscription bought through the App Store and a Note one billed by
    /// Paddle. If the Paddle cancellation then fails, the server reports
    /// `appStoreSubscriptionsRemaining = 1` AND
    /// `subscriptionCancellationsFailed = 1`.
    ///
    /// Both parts are reported: naming only the App Store would leave
    /// somebody who cancels with Apple believing they are done while the
    /// other provider goes on billing them — with no account left to find
    /// out from.
    ///
    /// `static` so it can be exercised without standing up a live delete.
    nonisolated static func billingNotice(appStoreRemaining: Int, cancellationsFailed: Int) -> String {
        var parts: [String] = []

        if appStoreRemaining == 1 {
            parts.append("Your App Store subscription is still running. Apple will keep charging you until you cancel it yourself: open Settings, tap your name, then Subscriptions.")
        } else if appStoreRemaining > 1 {
            parts.append("Your \(appStoreRemaining) App Store subscriptions are still running. Apple will keep charging you until you cancel them yourself: open Settings, tap your name, then Subscriptions.")
        }

        if cancellationsFailed > 0 {
            if appStoreRemaining > 0 {
                // Say plainly that this is a DIFFERENT subscription, or it reads
                // as a restatement of the Apple one and gets ignored.
                parts.append("Separately, we could not cancel a subscription that is not billed through the App Store, so you may still be charged for that one too. Write to help@support.pingolin.com and we will stop it.")
            } else {
                parts.append("We could not cancel your subscription, so you may still be charged. Write to help@support.pingolin.com and we will stop it.")
            }
        }

        // Unreachable while billingNeedsAttention is (remaining > 0 || failed >
        // 0), but if the server ever widens that flag, say something rather
        // than showing a bare "Your account is deleted, but".
        if parts.isEmpty {
            return "Your account is deleted. Your subscription may need attention — write to help@support.pingolin.com and we will check it."
        }
        return "Your account is deleted.\n\n" + parts.joined(separator: "\n\n")
    }

    /// What to say about the erasure of the location and note data.
    ///
    /// `nil` when there is nothing to say. A queued erasure is not a failure —
    /// the outboxes retry until it goes through — but somebody who asked to be
    /// erased is entitled to know it has not finished yet.
    nonisolated static func erasureNotice(dataErasure: String) -> String? {
        switch dataErasure {
        case "queued":
            return "Your locations and notes could not be erased at that moment — one of the services was unreachable. The erasure is recorded and will be retried until it goes through. If you want to know that it has, write to privacy@mail.pingolin.com."
        case "failed":
            return "We could not record the erasure of your locations and notes, so it may not have happened. Write to privacy@mail.pingolin.com and we will complete it."
        default:
            // "completed" and "not_applicable" — nothing outstanding.
            return nil
        }
    }

    /// Everything the person still needs to know after their account is gone:
    /// money first, then data. Either half may be absent.
    ///
    /// Returns nil when nothing is outstanding, so the caller does not gate on
    /// `billingNeedsAttention` alone: an erasure that queued while the billing
    /// was clean still needs a notice.
    nonisolated static func deletionNotice(
        billingNeedsAttention: Bool,
        appStoreRemaining: Int,
        cancellationsFailed: Int,
        dataErasure: String
    ) -> String? {
        var parts: [String] = []
        if billingNeedsAttention {
            parts.append(billingNotice(appStoreRemaining: appStoreRemaining,
                                       cancellationsFailed: cancellationsFailed))
        }
        if let e = erasureNotice(dataErasure: dataErasure) {
            parts.append(e)
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    // MARK: - Logout

    /// DELIBERATE sign-out, or an account that no longer exists. Destroys
    /// everything: session, key material, caches, the lot.
    ///
    /// This is NOT what a server-rejected refresh should run — see
    /// `expireSession()`: after a rotation race with a session the server
    /// still considers live, it would turn a recoverable outage into a
    /// re-import, with the device dark meanwhile.
    ///
    /// - Parameter retainingTrust: keep this account's member-key pins and the
    ///   "verified" marks that vouch for them, for its next sign-in on this
    ///   device. False for a deleted account, which keeps nothing.
    func logout(retainingTrust: Bool = true) async {
        sessionEpoch += 1
        stopEmailVerificationPolling()
        stopApprovalPolling()

        // End the session on the server while there is still a token to end it
        // with: its push rows go with it. A deleted account's are gone already.
        if retainingTrust { await endServerSession() }

        // Drop the device-registered flag so the next login re-runs
        // POST /devices. Otherwise re-login under the same user
        // could skip registration after a server-side device wipe.
        let outgoingUserId = userId
        if let userId = outgoingUserId {
            DeviceRegistrar.reset(userId: userId)
        }

        // Export the pins BEFORE purgeAccountData's clearAllKeys() wipes
        // them. Without this every sign-out would reopen trust-on-first-use
        // for every member of every circle, and every safety number the user
        // had compared would stop counting. The "verified" marks stay only if
        // their pins did; a mark vouching for a pin that is gone would vouch
        // for whatever key the next sign-in trusts afresh.
        if retainingTrust, let userId = outgoingUserId,
           KeyStoreRecovery.pinsExportable(cryptoManager.keyStoreStatus()),
           RetainedMemberPins.retain(owner: userId, crypto: cryptoManager) {
            // kept: pins exported, marks stay
        } else {
            MemberVerificationStore.clearAll()
            if !retainingTrust {
                RetainedMemberPins.deleteAll(except: nil)
                KeyDeliveryApprovals.shared.clearAll(exceptOwner: nil)
                RefreshLedger.shared.wipeAll()
                SOSAlarmMarks.shared.wipeAll()
                AccountKeyedDefaults.wipe(except: nil)
                SignInEmails.deleteAll()
            }
        }

        await purgeAccountData()

        // Wipe ALL keychain key material — tokens, the master key, the X25519
        // sharing private key, and the anonymous geocode-token pool — not just a
        // hand-picked few. Deleting only the tokens + legacy pre-SDK keys leaves
        // .masterKey / .sharingPrivateKey / .sharingPublicKey / .geocodeTokenPool
        // (and the circle-key mirror) at rest, inheritable by the next account on
        // this device. deleteAll() is a blanket service wipe.
        keychain.deleteAll()

        currentUser = nil
        isAuthenticated = false
        requires2FA = false
        tempToken = nil
        pendingPassword = nil
        pendingEmail = nil
        twoFactorMethods = nil
        emailVerified = false
        // The next account is read afresh.
        trackAccess = nil
        registration = .approved
        RegistrationGate.clear()
        KeyStoreRecovery.shared.signedOut()
    }

    /// Everything `logout()` destroys EXCEPT the session tokens and the
    /// keychain-wide wipe — so it is also safe to run from `completeLogin()`
    /// after the INCOMING account's tokens are already saved.
    ///
    /// Factored out so the two paths cannot drift. A hand-copied subset in
    /// `login()` is exactly how an account switch ends up leaving the previous
    /// user's keys behind.
    private func purgeAccountData() async {

        SDKLocationStreamer.shared.stop()
        SDKLocationStreamer.shared.forgetFreshPositionOwed()
        // Stop the OS location pipeline too — continuous GPS updates,
        // significant-location changes, and visit monitoring. Without this a
        // signed-out device keeps waking on background location events.
        // stopTracking() sets isTracking=false so
        // locationManagerDidChangeAuthorization won't re-arm it.
        LocationService.shared.stopTracking()
        // Purge the at-rest self coordinate (map-self-location.json under
        // Application Support) so a signed-out device retains no location
        // fix. Sits alongside the keychain/CacheStore wipes above.
        SelfLocationStore.clear()
        // ...and none of the fixes kept for circles that were waiting to sync.
        PendingCircleLocations.shared.clearAll()
        // A delete the platform refuses leaves a wipe owed.
        OwedWipe.clear(cryptoManager)
        // With the fixes kept for circles, the record of when they could not
        // go.
        CirclePauseRecord.shared.clearAll()
        // And what this phone last sent each circle, kept for a re-seal after a
        // rotation: it holds a point, so it goes at every sign-out, whatever
        // else is kept.
        OwnLastSentStore.shared.wipeAll()
        // What this device sealed as its own SOSes' positions.
        SOSSealedPositions.shared.clearAll()
        AttestationManager.shared.reset()
        PushNotificationManager.shared.reset()
        InvitesManager.shared.reset()
        InvitationRenewals.shared.reset()
        PremiumManager.shared.reset()
        CircleManager.shared.reset()
        MemberKeyPinner.shared.reset()
        // Queued "Give access?" questions name the signed-out account's circle
        // members. The approvals themselves are per account and survive a
        // same-account sign-out; another account signing in drops them.
        KeyDeliveryApprovals.shared.reset()
        SelfKeyManager.reset()
        // Device-local SAS "verified out of band" markers are NOT wiped here.
        // They vouch for the SDK pins, which a same-account sign-out keeps
        // (`logout()` exports them first); a DIFFERENT account signing in
        // wipes both (`completeLogin` → `MemberVerificationStore.adopt`,
        // `RetainedMemberPins.restore`). `logout()` clears them itself when the
        // pins could not be kept.
        // Hidden destinations are a per-account preference keyed by destination
        // id. Those ids mean nothing in the next user's circles, and a stale
        // hide could silently blank one of theirs on a collision.
        HiddenDestinationsStore.shared.clear()
        // Sibling singletons that each hold decrypted, account-scoped PII in
        // @Published arrays (places+coordinates, destinations, notification
        // inbox, check-ins, alert watch-lists). Without these, account A's
        // decrypted data would linger in memory (and, for places, as OS
        // geofences) for account B after a switch on the same device.
        PlaceManager.shared.reset()
        DestinationsManager.shared.reset()
        NotificationsManager.shared.reset()
        CheckInManager.shared.reset()
        AlertRulesManager.shared.reset()
        InactivityAlertsManager.shared.reset()
        // Ownership claims name a circle and the user id of whoever is claiming
        // it. Left behind, account B would see a countdown on a circle that is
        // not theirs — and, worse, a Refuse control keyed to it.
        OwnershipClaimManager.shared.reset()
        // SOS holds decrypted alert coordinates + member ids in @Published
        // state and spins a 5s poll timer; battery/inactivity monitoring holds
        // per-circle debounce state behind timers; LocalInactivityStore holds
        // decrypted (plaintext memberName) firing rows that
        // NotificationsManager.mergeLocal would otherwise re-surface into the
        // next account's bell. Reset/clear all three on logout.
        SOSManager.shared.reset()
        MonitoringManager.shared.reset()
        LocalInactivityStore.shared.clear()
        // Same reason: the battery events carry decrypted member names, so
        // account A's must not survive into account B's bell.
        LocalBatteryStore.shared.clear()
        // Queued own-crossings, for a sharper reason than the stores above: these
        // are queued to be SENT. A crossing left behind by account A would be
        // replayed under account B's session — reporting A's movement to B's
        // circles, under B's keys — which is a disclosure rather than a stale row.
        await PendingCrossingStore.shared.clear()
        await PendingRegionEventStore.shared.clear()
        // Changes a person made while this iPhone was behind: queued to be SENT
        // as this account. Never across accounts; kept across a session
        // expiry, which does not come through here.
        PendingChangeStore.shared.wipeAll()
        // The backfill's signed ids go with them. The removals and role
        // changes the chain doesn't carry yet stay with this account for
        // its next sign-in here, as its member pins do; another account
        // signing in, or an erasure, takes them.
        BackfillLedger.shared.wipeAll()
        RefreshLedger.shared.signedOut()
        // What this device saw of each SOS (`SOSAlarmMarks`) stays too: an
        // "ended" mark is an obligation never to alarm again. Only the
        // guarded tidy or an erasure takes it.
        // Reverse-geocoded street addresses for members' live positions — the
        // same class of decrypted, account-scoped PII as the rows above, and
        // keyed by user id, so account B would otherwise inherit a dictionary
        // naming where account A's circle was standing.
        MemberAddressStore.shared.reset()
        // The RENDERED copy of the data the managers above just dropped. The
        // MLNMapView is deliberately held across SwiftUI rebuilds, so without
        // this account A's member + place annotations (decrypted names and
        // coordinates) are handed to account B's fresh Coordinator, whose empty
        // reconcile dictionaries can never remove them.
        MapViewHolder.shared.reset()
        // The CACHED TILES themselves, which `MapViewHolder.reset()` does not touch — it
        // drops annotations and the map view, not the bytes MapLibre stored. Those tiles
        // reveal which geographic areas account A panned/zoomed over, the same class of
        // leak as MemberAddressStore above. `MapCacheConfig.clear` empties MapLibre's
        // 128 MiB ambient cache (where the tiles actually are) and the PMTilesRangeCache
        // dir, so account B inherits neither.
        MapCacheConfig.clear { error in
            if let error = error {
                // Loud on failure: this is an erasure control, and a silent
                // failure would leave account A's tiles behind unnoticed.
                print("[Track] SECURITY: map tile cache clear FAILED on logout: \(error)")
            }
        }

        // Purge decrypted content the OS is still holding in Notification Center:
        // delivered banners (location-arrival, circle invites) and pending
        // requests carry plaintext member/circle names. Without this they survive
        // an account switch and leak the previous user's data to the next.
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        Task { await CacheStore.shared.clearAll() }
        // Sweep leftover diagnostic dumps on logout so a signed-out device keeps
        // none of the previous session's data. In DEBUG these carry token-bearing
        // HTTP bodies (diag-*.json) and plaintext lat/lng + auth state
        // (send-location-diag.log). map-diag.log / push-diag.log are metadata-only
        // usage timelines whose writers are DEBUG-gated; earlier builds wrote them
        // in Release too, so this sweep also runs in Release to clean up anything
        // already on disk. Deleting a nonexistent file is free.
        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
           let entries = try? FileManager.default.contentsOfDirectory(
               at: docs, includingPropertiesForKeys: nil) {
            // The .txt families are DEBUG-only diag dumps (some carry decrypted
            // lat/lng + member/place names) written by CircleManager / PlaceManager
            // / PushNotificationManager / AuthManager under distinct name prefixes;
            // sweep them by prefix so a dev-device logout leaves none behind.
            let txtDiagPrefixes = [
                // "location-decrypt-" also matches the "-ok-" variant. The rest
                // are the remaining diag families: circle-keys / locations-fetch
                // / places-fetch / notif-diag / register-step, plus
                // location-replay-guard and place-decrypt — the last carries a
                // decrypted place lat/lng JSON prefix (PlaceManager.diag).
                "location-decrypt-", "locations-fetch-", "places-fetch-",
                "notif-diag-", "register-step-", "circle-keys-",
                "location-replay-guard-", "place-decrypt-",
            ]
            for entry in entries where
                (entry.lastPathComponent.hasPrefix("diag-") && entry.pathExtension == "json")
                || entry.lastPathComponent == "send-location-diag.log"
                || entry.lastPathComponent == "map-diag.log"
                || entry.lastPathComponent == "push-diag.log"
                || (entry.pathExtension == "txt"
                    && txtDiagPrefixes.contains(where: { entry.lastPathComponent.hasPrefix($0) })) {
                try? FileManager.default.removeItem(at: entry)
            }
        }
        // NOTE: `onboarding.complete` deliberately NOT cleared. It's a
        // one-time-per-device walkthrough (permission explainers,
        // welcome screens), not per-session state. Wiping it on
        // logout would force re-login users back through every
        // permission screen even though iOS has already granted the
        // underlying system permissions. Onboarding is a UX intro,
        // not an account boundary.

    }

    /// The OUTGOING account's key slots, for the switch path only.
    ///
    /// `logout()` uses `deleteAll()` instead. This list is explicit because
    /// `completeLogin()` has already saved the INCOMING account's
    /// accessToken / refreshToken / tokenExpiry / userId by the time it runs,
    /// and a blanket wipe would delete those and sign the new user straight
    /// back out.
    private func deleteOutgoingKeyMaterial() {
        for key in [KeychainService.Key.privateKey, .publicKey, .recoveryKey,
                    .masterKey, .sharingPrivateKey, .sharingPublicKey,
                    .geocodeTokenPool, .geocodeKeyId, .geocodePublicKey,
                    .deviceId] {
            keychain.delete(key: key)
        }
    }

    /// Session-EXPIRY teardown: the server definitively rejected our refresh
    /// (a 401 from /auth/refresh, which resolves the session by refresh-token
    /// hash). The tokens are dead — but this is NOT the user asking to sign
    /// out, so their account must survive it.
    ///
    /// Keeps the key material, the circle-key mirror, cached places and
    /// members, SAS verification markers and the geocode pool. Signing back in
    /// as the SAME user restores the app rather than re-importing it.
    ///
    /// Mirrors the Android app's `clearCredentialsOnly` and the Note iOS app's
    /// `expireSession()`. The location pipeline still stops: a device with no
    /// session must not keep waking on location events, and `isAuthenticated`
    /// going false is what stands every revival path down.
    ///
    /// A DIFFERENT user signing in afterwards is handled by `completeLogin()`,
    /// which purges this account before installing theirs.
    func expireSession() {
        sessionEpoch += 1
        stopEmailVerificationPolling()
        stopApprovalPolling()

        keychain.delete(key: .accessToken)
        keychain.delete(key: .refreshToken)
        keychain.delete(key: .tokenExpiry)

        SDKLocationStreamer.shared.stop()
        SDKLocationStreamer.shared.forgetFreshPositionOwed()
        LocationService.shared.stopTracking()

        currentUser = nil
        isAuthenticated = false
        requires2FA = false
        tempToken = nil
        pendingPassword = nil
        pendingEmail = nil
        twoFactorMethods = nil
        KeyStoreRecovery.shared.signedOut()
    }


    // MARK: - Biometric Authentication

    /// App Lock's way in: Face ID or Touch ID, and the device passcode when
    /// those fail, are locked out or aren't set up, as the setting's row says
    /// ("Face ID, Touch ID or your device passcode"). With biometrics only,
    /// someone whose Face ID stopped working would have no way back into
    /// Track. A device with no passcode at all can't lock anything here: it
    /// opens.
    func authenticateForAppLock() async throws -> Bool {
        let context = LAContext()
        var error: NSError?

        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            if Self.noDevicePasscode(error) { return true }
            throw error ?? AuthError.biometricNotAvailable
        }

        return try await context.evaluatePolicy(
            .deviceOwnerAuthentication,
            localizedReason: "Authenticate to access Track"
        )
    }

    /// Proof that the device's owner is the one making App Lock weaker (App Lock
    /// off, "Require on Launch" off, Auto-Lock later or "Never"), asked as the
    /// lock itself asks: Face ID or Touch ID, or the device passcode, with
    /// `reason` in the system sheet. Anyone holding an unlocked Track could
    /// otherwise switch the lock off. A device with no passcode can't lock
    /// anything, so there is nothing to keep: yes. A cancel or a failure: no.
    func proveForAppLockChange(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return Self.noDevicePasscode(error)
        }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }

    /// Pure: the device has no passcode set (`LAError.passcodeNotSet`).
    nonisolated static func noDevicePasscode(_ error: NSError?) -> Bool {
        guard let error else { return false }
        return error.domain == LAError.errorDomain && error.code == LAError.Code.passcodeNotSet.rawValue
    }

    // MARK: - Profile

    func updateDisplayName(_ name: String) async throws {
        let response = try await api.updateProfile(displayName: name)
        // The response carries the new name and NOTHING else, so the rest of
        // the user is kept from what we already hold. Decoding a whole `User`
        // from this route would make the call throw.
        guard var user = currentUser else { return }
        user.displayName = response.displayName ?? name
        currentUser = user
    }

    // MARK: - Accessors

    /// This account's guardian, for the map's standing line: whether one
    /// holds it, and the handover day they named.
    struct GuardianStatus: Equatable {
        let managed: Bool
        let handoverDate: String?

        static let notManaged = GuardianStatus(managed: false, handoverDate: nil)
    }

    /// /auth/me's answer when this process has one, else what the app last
    /// mirrored for this same account (`ExtensionBridge.syncAccount`), else not
    /// managed. A launch whose /auth/me hasn't answered shows the map, and with
    /// Always location the headless resume is already sharing then, so the line
    /// can't wait for /auth/me.
    var guardian: GuardianStatus {
        Self.guardian(served: currentUser, userId: userId, mirrored: ExtensionBridge.mirroredGuardian())
    }

    nonisolated static func guardian(served: User?, userId: String?,
                                     mirrored: ExtensionBridge.MirroredGuardian) -> GuardianStatus {
        if let served {
            return GuardianStatus(managed: served.guardianManaged == true, handoverDate: served.guardianHandoverDate)
        }
        guard CanonicalId.same(mirrored.userId, userId) else { return .notManaged }
        return GuardianStatus(managed: mirrored.managed, handoverDate: mirrored.handoverDate)
    }

    /// The signed-in account's id, in its one form: an id stored in another
    /// spelling (earlier versions kept it as /auth/me served it) is
    /// canonicalized here; one that isn't a UUID stays as it is (a UI test's
    /// synthetic session).
    var userId: String? {
        keychain.getString(for: .userId).map { CanonicalId.of($0) ?? $0 }
    }

    var deviceId: String? {
        keychain.getString(for: .deviceId)
    }

    // MARK: - Errors

    enum AuthError: LocalizedError {
        case noTempToken
        case biometricNotAvailable
        case invalidCredentials
        case noUserId
        /// The password was accepted but the account's encryption keys could
        /// not be unlocked from it, so the sign-in was withdrawn. See
        /// `completeLogin`.
        case keysUnavailable
        /// SRP step 2 returned neither a session nor a two-factor challenge, or
        /// /auth/me named the account by an id that isn't a UUID.
        case unexpectedResponse
        /// The server's proof M2 did not hold (or was missing): nothing from its
        /// reply was used. Not "wrong password": it may be right.
        case serverNotVerified
        /// The two-step code was wrong; the attempt takes another.
        case wrongTwoFactorCode
        /// The two-step code was used a moment ago; the attempt takes the next
        /// one.
        case twoFactorCodeJustUsed
        /// Too many wrong two-step codes: the attempt is over.
        case twoFactorAttemptOver
        /// The two-step attempt has ended: it expired, or was already used.
        case twoFactorAttemptEnded

        var errorDescription: String? {
            switch self {
            case .noTempToken:
                return "No temporary token for 2FA"
            case .biometricNotAvailable:
                return "Biometric authentication not available"
            case .invalidCredentials:
                return "Invalid email or password"
            case .noUserId:
                return "No user id available"
            case .keysUnavailable:
                // Says what happened (the password was right), what it would
                // have meant, and that nothing was left half-done — the one
                // question a person has after "Couldn't sign in".
                return "Your password was accepted, but this phone couldn't open your account's data, so you haven't been signed in — your circles would have been unreadable. Please try again. If it keeps happening, sign in to your account on the web to check it."
            case .unexpectedResponse, .serverNotVerified:
                return "Couldn't sign in. Please try again."
            case .wrongTwoFactorCode:
                return "That code isn't right. Please try again."
            case .twoFactorCodeJustUsed:
                return "That code was just used. Wait for the next one and try again."
            case .twoFactorAttemptOver:
                return "Too many wrong codes. Please wait a while, then sign in again."
            case .twoFactorAttemptEnded:
                return "That sign-in has ended. Please sign in again."
            }
        }
    }
}
