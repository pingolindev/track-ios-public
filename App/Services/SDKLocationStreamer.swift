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
import PingolinTrackSDK

/// Owns the SDK LocationManager — the gRPC stream into the server's ingest.
/// Starts once at login, stops on logout. Per-update calls go through
/// `send(circleId:location:)` which envelope-encrypts via SDK
/// CryptoManager and forwards to LocationManager.sendEnvelopeLocation.
///
/// Mirrors the Android wiring: AuthRepository.login -> startStreaming
/// once -> per-update sendEnvelopeLocation.
@MainActor
final class SDKLocationStreamer {
    static let shared = SDKLocationStreamer()

    private let cryptoManager = SDKCrypto.cryptoManager
    private var locationManager: LocationManager?
    private var startedDeviceId: String?
    private var startedUserId: String?
    /// Single SDK-side error sink — registered once per LocationManager.
    /// Strong-reference so UniFFI's callback handle stays valid as long
    /// as the manager does.
    private var errorSink: StreamErrorRouter?
    /// Coalesce "Unauthenticated → refresh + restart" attempts so a
    /// burst of failed sends doesn't fire N refreshes in parallel.
    private var refreshInFlight: Bool = false
    /// Guards re-registration after a settled ownership refusal: one at a time,
    /// and at most one every 5 minutes. The refusals arrive once per rejected
    /// fix, so without these a device the server keeps refusing would POST a
    /// registration per location.
    private var reregisterInFlight: Bool = false
    private var lastReregisterAt: Date?
    /// Coalesce device-not-found re-registration in the same way, and as
    /// rarely: one every 5 minutes, not one per refused fix.
    private var reregistrationInFlight: Bool = false
    private var lastRejectionReregisterAt: Date?
    /// The account a "Device not found" refusal was for, since this device was
    /// last addressable: the refused fix was lost, so ONE fresh position is
    /// owed it once the device is (`deviceBecameAddressable`). Paid once per
    /// refusal and registration, never a loop.
    private var freshPositionOwedTo: String?
    /// Owed, and the device addressable, but before the uploads' targets were
    /// known: paid when they are (`uploadTargetsLoaded`).
    private var freshPositionDueTo: String?
    /// What pays it: a fresh fix through the normal uploads
    /// (`LocationService.sendOneFreshFixAfterRefusal`). A seam: the tests count it.
    var sendFreshPosition: @MainActor () async -> Void = {
        _ = await LocationService.shared.sendOneFreshFixAfterRefusal()
    }
    /// Whether the uploads' targets are known: the circle list from the server
    /// and each circle's privacy, loaded since the sign-in. Until then an upload
    /// goes to this account alone (`CircleManager.uploadTargets` fails closed).
    /// A seam: the tests decide it.
    var uploadTargetsKnown: @MainActor () -> Bool = { CircleManager.shared.circlesLoaded }

    // MARK: Recovery state
    //
    // The SDK's upload task can end on ANY error — a network change mid-RPC, the
    // per-RPC timeout, an ingest rollout answering Unavailable, a failed re-dial
    // after Cloudflare's idle GOAWAY — not only on an auth or ownership refusal.
    // Each needs a way back: otherwise every later send fails until logout or a
    // relaunch, which on a resident process is days, with no uploads at all,
    // self copy included.

    /// What `start` was last asked to run, so a recovery can rebuild without its
    /// caller. Cleared only by `stop()` (logout), never by an internal rebuild.
    private var desiredUserId: String?
    private var desiredDeviceId: String?
    /// When the current manager was built. A send that lands on a manager that
    /// has survived a while is what proves the stream healthy again.
    private var managerStartedAt: Date?
    /// Rebuilds since the stream was last proven healthy; drives the backoff.
    private var restartAttempt: Int = 0
    /// Earliest moment the next rebuild may run. Shared by the error path and the
    /// lazy rebuild in `sendInner`, so the two cannot add up to a storm.
    private var nextRestartAllowedAt: Date = .distantPast
    /// The one scheduled rebuild, if any.
    private var restartTask: Task<Void, Never>?
    /// Battery Saver does not need idle gRPC/TLS kept alive between 15-minute
    /// sends. Android likewise avoids pre-opening the stream in that mode.
    private var idleTeardownTask: Task<Void, Never>?
    static let batterySaverIdleTeardownSeconds: TimeInterval = 30
    /// Last light circle reload asked for by a "not a member" refusal.
    private var lastMembershipReloadAt: Date?

    private init() {}

    /// Record the desired (user, device) WITHOUT opening the stream — for
    /// Battery Saver / Low Power Mode, where we deliberately do not hold an idle
    /// gRPC/TLS connection between sends. The first `send` then opens it lazily
    /// via `rebuildStream` (which reads a fresh token from the keychain), and
    /// `scheduleBatterySaverTeardown` closes it again after.
    ///
    /// `rebuildStream`/`scheduleRestart` both bail without
    /// `desiredUserId`/`desiredDeviceId`, so a bring-up path that returned early
    /// in this mode would leave every send throwing `.notRunning` and the phone
    /// uploading nothing — SOS included — for the whole session, with no recovery
    /// even after Low Power Mode is turned back off. Registering here is what
    /// keeps the lazy open reachable.
    func registerDesiredSession(userId: String, deviceId: String) {
        guard RegistrationGate.allowsTrack else {
            appendStreamerDiag("register refused: registration \(RegistrationGate.current.rawValue)")
            return
        }
        desiredUserId = userId
        desiredDeviceId = deviceId
        appendStreamerDiag(
            "registered desired session (battery saver) deviceId=\(deviceId.prefix(8)) "
            + "userId=\(userId.prefix(8)) — stream opens on the first send")
    }

    func start(jwtToken: String, userId: String, deviceId: String) {
        // Nothing streams for an account not approved (yet): ingest
        // refuses its token, and nothing of it is tracked.
        guard RegistrationGate.allowsTrack else {
            appendStreamerDiag("start refused: registration \(RegistrationGate.current.rawValue)")
            return
        }
        desiredUserId = userId
        desiredDeviceId = deviceId
        if locationManager != nil, startedDeviceId == deviceId {
            // Already running for this device: the caller is holding a
            // token at least as fresh as the stream's, so hand it over.
            // The SDK reads the token per RPC; without this a re-login on
            // the same device would leave the stream on the OLD token
            // until it expired and was refused.
            locationManager?.updateToken(jwtToken: jwtToken)
            appendStreamerDiag("start no-op already running deviceId=\(deviceId.prefix(8)) (token updated)")
            return
        }
        appendStreamerDiag("start beginning deviceId=\(deviceId.prefix(8)) userId=\(userId.prefix(8))")

        let cfg = AppConfiguration.shared
        let environment: PingolinTrackSDK.Environment
        switch cfg.environment {
        case .production: environment = .production
        case .development: environment = .development
        case .local:      environment = .local
        }
        let config = SdkConfig(
            authEndpoint: cfg.authBaseURL,
            ingestEndpoint: cfg.ingestURL,
            apiEndpoint: cfg.apiBaseURL,
            environment: environment
        )
        // Default privacy config matching Rust PrivacyConfig::default():
        // 5-min timestamp buckets, jitter on, batching off. Constructed
        // explicitly because UniFFI doesn't surface a Default-trait
        // factory.
        let privacy = PrivacyConfig(
            enableTimestampBucketing: true,
            timestampBucketSeconds: 300,
            addTimestampJitter: true,
            enableBatchUploads: false,
            batchSize: 10,
            maxBatchDelaySeconds: 30,
            enableBatchPadding: false,
            paddedBatchSize: 10
        )

        let manager = LocationManager(
            config: config,
            jwtToken: jwtToken,
            userId: userId,
            cryptoManager: cryptoManager,
            privacyConfig: privacy
        )
        // Hook the SDK error callback BEFORE startStreaming. Without
        // this, an Unauthenticated error after JWT expiry leaves the
        // stream in a wedged "reconnect with stale token" loop —
        // mirrors the Android app's LocationStreamErrorCallback.
        let sink = StreamErrorRouter()
        manager.setErrorCallback(callback: sink)
        do {
            try manager.startStreaming(deviceId: deviceId)
            locationManager = manager
            startedDeviceId = deviceId
            startedUserId = userId
            errorSink = sink
            managerStartedAt = Date()
            appendStreamerDiag("start ok")
        } catch {
            appendStreamerDiag("start FAILED \(error)")
            print("[Track] LocationManager.startStreaming failed: \(error)")
            // The intent is recorded above, so a later recovery can try again
            // instead of leaving this session with no stream until relaunch.
            scheduleRestart(reason: "startStreaming threw")
        }
    }

    /// Tear down on logout. Subsequent send(...) calls become no-ops
    /// until start() runs again.
    func stop() {
        teardown()
        idleTeardownTask?.cancel()
        idleTeardownTask = nil
        keptDrain?.cancel()
        keptDrain = nil
        desiredUserId = nil
        desiredDeviceId = nil
        restartTask?.cancel()
        restartTask = nil
        restartAttempt = 0
        nextRestartAllowedAt = .distantPast
        lastMembershipReloadAt = nil
    }

    /// Close an already-open stream soon after Battery Saver is enabled. A send
    /// in flight gets a short drain window; later sends open it lazily again.
    func enterBatterySaver() {
        scheduleBatterySaverTeardown(after: 15)
    }

    private func scheduleBatterySaverTeardown(after delay: TimeInterval = batterySaverIdleTeardownSeconds) {
        guard LocationService.shared.isBatterySaverActive else { return }
        idleTeardownTask?.cancel()
        idleTeardownTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(delay, 0) * 1_000_000_000))
            guard let self, !Task.isCancelled, LocationService.shared.isBatterySaverActive else { return }
            if self.locationManager != nil {
                self.appendStreamerDiag("battery saver: idle stream closed")
                self.teardown()
            }
            self.idleTeardownTask = nil
        }
    }

    /// Release the running manager without forgetting what should be running.
    private func teardown() {
        // The SDK manages the lifetime via Drop on the Rust side;
        // releasing the handle here shuts down the stream.
        locationManager = nil
        startedDeviceId = nil
        startedUserId = nil
        errorSink = nil
        managerStartedAt = nil
    }

    /// Hand a refreshed access token to the running stream.
    ///
    /// The SDK reads the token per RPC (`update_token` in the mobile SDK), so
    /// this keeps an open stream authenticated across a refresh; without it the
    /// stream keeps the token it was built with, dies at expiry, and drops that
    /// upload. Called by the one refresh authority
    /// (`APIService.performTokenRefresh`) and by `start` when already running.
    func updateToken(_ token: String) {
        guard !token.isEmpty else { return }
        locationManager?.updateToken(jwtToken: token)
    }

    // MARK: - Stream recovery

    /// What an `on_stream_error` message asks of this layer.
    enum StreamErrorKind: Equatable {
        /// Settled: the server cannot match this device to this user.
        case ownershipLost
        /// Settled: the token was refused. Refresh, then rebuild.
        case auth
        /// Everything else — transport, timeout, a server restart. The upload
        /// task may be gone, so the stream is rebuilt with backoff.
        case other
    }

    nonisolated static func classifyStreamError(_ message: String) -> StreamErrorKind {
        let lower = message.lowercased()
        if lower.contains("device not found") || lower.contains("not owned by user") {
            return .ownershipLost
        }
        if lower.contains("unauthenticated")
            || lower.contains("invalid or expired token")
            || lower.contains("invalid token")
            || lower.contains("token expired") {
            return .auth
        }
        return .other
    }

    /// Wait before the Nth rebuild since the stream was last healthy: 2 s,
    /// doubling, capped at five minutes.
    nonisolated static func restartDelay(attempt: Int) -> TimeInterval {
        let exponent = Double(min(max(attempt, 0), 16))
        return min(2 * pow(2, exponent), 300)
    }

    /// How long a manager has to survive before a successful send on it resets
    /// the backoff. A send only proves the message was QUEUED; a stream that
    /// connects and then dies can queue happily for a few seconds first.
    static let healthyStreamAge: TimeInterval = 60

    /// Make sure a rebuild will happen, no sooner than the backoff allows.
    private func scheduleRestart(reason: String) {
        guard desiredUserId != nil, desiredDeviceId != nil else { return }
        guard restartTask == nil else { return }
        let now = Date()
        let wait = max(Self.restartDelay(attempt: restartAttempt),
                       nextRestartAllowedAt.timeIntervalSince(now))
        appendStreamerDiag("restart scheduled in \(Int(wait))s (\(reason)) attempt=\(restartAttempt)")
        restartTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(wait, 0) * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.restartTask = nil
            // A lazy rebuild may already have brought it back while we waited.
            if self.locationManager?.isStreaming() == true,
               self.startedDeviceId == self.desiredDeviceId {
                return
            }
            self.rebuildStream(reason: reason)
        }
    }

    /// Tear down and rebuild the stream for the current session, now.
    /// Returns whether a manager is running afterwards.
    @discardableResult
    private func rebuildStream(reason: String) -> Bool {
        guard let userId = desiredUserId, let deviceId = desiredDeviceId else { return false }
        guard let access = KeychainService.shared.getString(for: .accessToken), !access.isEmpty else {
            appendStreamerDiag("rebuild skipped (\(reason)): no access token")
            return false
        }
        restartAttempt += 1
        nextRestartAllowedAt = Date().addingTimeInterval(Self.restartDelay(attempt: restartAttempt))
        appendStreamerDiag("rebuild (\(reason)) attempt=\(restartAttempt)")
        // The stream was lost: what this phone missed meanwhile is read
        // before a check-in or the kept points go.
        CirclePauseRecord.shared.noteOffline()
        teardown()
        start(jwtToken: access, userId: userId, deviceId: deviceId)
        return locationManager != nil
    }

    /// Called on every queued send: once a manager has lived long enough to be
    /// trusted, the next failure starts the backoff from the bottom again.
    private func noteSendQueued() {
        guard let started = managerStartedAt,
              Date().timeIntervalSince(started) >= Self.healthyStreamAge else { return }
        restartAttempt = 0
        nextRestartAllowedAt = .distantPast
    }

    /// At most one re-registration per 5 minutes for a "Device not found"
    /// refusal of a fix, as for the stream error's.
    nonisolated static func reregisterIsDue(last: Date?, now: Date) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= 300
    }

    /// The server refused this device ("Device not found or not owned by
    /// user"): one fresh position is owed `account` once it is addressable.
    func noteDeviceRefused(account: String?) {
        guard let account = CanonicalId.of(account) else { return }
        freshPositionOwedTo = account
    }

    /// The device was just registered WITH a push token, so the row ingest
    /// checks exists now (`PushNotificationManager.register(deviceToken:)`). A
    /// stream the server ended while it didn't (a settled ownership refusal) is
    /// rebuilt now, not at the next send's backoff. And if the server refused
    /// a fix of this account's meanwhile, that fix was lost: one fresh position
    /// goes now, or once the circles' privacy has loaded if it hasn't yet,
    /// instead of the circle first seeing this person at the next scheduled
    /// send.
    func deviceBecameAddressable() {
        deviceBecameAddressable(account: AuthManager.shared.userId)
    }

    /// `deviceBecameAddressable()`, for the account signed in now.
    func deviceBecameAddressable(account: String?) {
        if desiredUserId != nil, desiredDeviceId != nil,
           locationManager?.isStreaming() != true, restartTask == nil {
            appendStreamerDiag("device registered with a push token: rebuilding the stream")
            rebuildStream(reason: "device registered with a push token")
        }
        guard let owed = freshPositionOwedTo else { return }
        freshPositionOwedTo = nil
        // Owed to whoever was refused: nobody else, after a sign-out or a switch.
        guard CanonicalId.same(owed, account) else { return }
        // On a first sign-in the token can land before the circles' privacy
        // has, and the position would then reach this account alone: the very
        // case this is for. It waits for them.
        guard uploadTargetsKnown() else {
            freshPositionDueTo = owed
            appendStreamerDiag("device addressable after a refusal: the fresh position waits for the circles")
            return
        }
        payFreshPosition()
    }

    /// The circle list and every circle's privacy just loaded
    /// (`CircleManager.loadCircles`): a fresh position that waited for them goes
    /// now, to whoever it was owed and nobody else. A circle whose privacy did
    /// not load is still left out by the uploads (fail closed).
    func uploadTargetsLoaded(account: String?) {
        guard let due = freshPositionDueTo else { return }
        freshPositionDueTo = nil
        guard CanonicalId.same(due, account) else { return }
        payFreshPosition()
    }

    /// A session ended (a sign-out or a switch, an expired session, a revoked
    /// headless one): a fresh position still owed or waiting goes with it. The
    /// account check keeps any other account from being paid; without this the
    /// same account signing back in, in this process, would have the old one
    /// paid. Not in `stop()`: the ownership refusal's own rebuild runs `stop()`
    /// and `start()` while the position is owed.
    func forgetFreshPositionOwed() {
        freshPositionOwedTo = nil
        freshPositionDueTo = nil
    }

    private func payFreshPosition() {
        appendStreamerDiag("device addressable after a refusal: one fresh position")
        let send = sendFreshPosition
        Task { @MainActor in await send() }
    }

    /// The server's per-location membership refusal. Lower-cased input.
    nonisolated static func isMembershipRefusal(_ lowercasedError: String) -> Bool {
        lowercasedError.contains("not a member of this circle")
    }

    /// At most one refusal-driven circle reload per half hour: every target in
    /// every burst can be refused, and one reload answers all of them.
    nonisolated static var membershipReloadInterval: TimeInterval { 30 * 60 }

    nonisolated static func membershipReloadIsDue(last: Date?, now: Date) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= membershipReloadInterval
    }

    // MARK: - Stream-error handling

    /// Called from `StreamErrorRouter` when the SDK reports a stream error.
    ///
    /// Three outcomes, by `classifyStreamError`:
    ///  - an ownership refusal re-registers the device, then rebuilds;
    ///  - an auth refusal refreshes the token, then rebuilds (the SDK still ends
    ///    its upload task on Unauthenticated, so a token update alone would
    ///    leave nothing to use it);
    ///  - anything else rebuilds with backoff. The SDK may or may not have kept
    ///    its task alive — it can end the task on ANY failed RPC — so the
    ///    rebuild checks before it tears anything down.
    /// Mirrors the Android app's onStreamError → refreshTokenForStream →
    /// stopStreaming → scheduleReconnect chain.
    fileprivate func handleStreamError(_ message: String) {
        appendStreamerDiag("onStreamError \(message)")
        let kind = Self.classifyStreamError(message)

        // A SETTLED refusal: the server cannot match this device_id to this
        // user, so every send is rejected and will go on being rejected. The
        // SDK delivers it here deliberately — its StreamErrorCallback doc names
        // this case and says the device needs re-registration — and
        // the Android app acts on it the same way (mark the device
        // unregistered, re-register, restart).
        //
        // Without this, only re-registering on each app launch
        // (PushNotificationManager.register) would recover the device, so one
        // that streams in the background without being opened would have its
        // location silently never stored, indefinitely.
        if kind == .ownershipLost {
            noteDeviceRefused(account: startedUserId)
            guard !reregisterInFlight else {
                appendStreamerDiag("onStreamError re-registration already in flight, ignoring")
                return
            }
            // A cooldown as well as an in-flight guard: if
            // re-registration keeps failing, the refusals keep arriving
            // and this would otherwise POST once per rejected fix.
            if let last = lastReregisterAt, Date().timeIntervalSince(last) < 300 {
                appendStreamerDiag("onStreamError re-registered <5m ago, backing off")
                return
            }
            reregisterInFlight = true
            lastReregisterAt = Date()
            let userId = startedUserId
            let deviceId = startedDeviceId
            // Only a POST that carries the APNs token creates the row the
            // server is missing, so ask iOS for it: it lands in
            // `register(deviceToken:)`, which brings the stream back
            // (`deviceBecameAddressable`). The token-less re-POST below can't.
            PushNotificationManager.shared.requestDeviceTokenAfterRefusal()
            Task { @MainActor in
                defer { self.reregisterInFlight = false }
                DeviceRegistrar.invalidate()
                let ok = await DeviceRegistrar.ensure()
                self.appendStreamerDiag("device re-registration after ownership refusal: \(ok)")
                guard ok, let userId, let deviceId,
                      let access = KeychainService.shared.getString(for: .accessToken),
                      !access.isEmpty else { return }
                // Rebuild the stream so the next fix goes out against the
                // registration that now exists.
                self.stop()
                self.start(jwtToken: access, userId: userId, deviceId: deviceId)
            }
            return
        }

        guard kind == .auth else {
            // Not a refusal of this device or this token — a transport
            // failure, a timeout, a server restart. Dropping it here
            // would leave a dead stream in place for hours (see the
            // recovery state above). The rebuild waits out the backoff
            // and skips itself if the SDK kept the stream alive after
            // all.
            scheduleRestart(reason: "stream error")
            return
        }
        guard !refreshInFlight else {
            appendStreamerDiag("onStreamError refresh already in flight, ignoring")
            return
        }
        guard let userId = startedUserId,
              let deviceId = startedDeviceId else {
            appendStreamerDiag("onStreamError no userId/deviceId — refusing refresh")
            return
        }
        refreshInFlight = true
        Task { @MainActor in
            defer { self.refreshInFlight = false }
            await self.refreshTokenAndRestart(userId: userId, deviceId: deviceId)
        }
    }

    private func refreshTokenAndRestart(userId: String, deviceId: String) async {
        let keychain = KeychainService.shared
        do {
            // Route through APIService's ONE coalesced refresh authority
            // rather than calling the raw `refreshToken(...)` endpoint here.
            // The refresh token is single-use and rotates on every call, so a
            // streamer-private refresh racing the REST layer's refresh rotates
            // the token against it and desyncs the session → forced logout.
            // `ensureFreshAccessToken` coalesces with any in-flight REST
            // refresh, honors the post-refresh grace window, and persists the
            // rotated pair under a background-task assertion. The fresh access
            // token is then read back from the keychain.
            try await APIService.shared.ensureFreshAccessToken()
            guard let access = keychain.getString(for: .accessToken), !access.isEmpty else {
                appendStreamerDiag("refresh OK but no access token in keychain — stream will retry")
                return
            }
            appendStreamerDiag("refresh OK — tearing down + restarting stream with new JWT")
            // The SDK reads the token per RPC, so `updateToken` is what keeps a
            // LIVE stream authenticated (the refresh authority calls it on every
            // rotation). But an Unauthenticated refusal still ends the SDK's
            // upload task, so there is no live stream here to hand it to:
            // rebuild with the fresh token.
            updateToken(access)
            stop()
            start(jwtToken: access, userId: userId, deviceId: deviceId)
        } catch {
            appendStreamerDiag("refresh FAILED \(error) — stream will retry with stale token")
            print("[Track] SDKLocationStreamer refresh failed: \(error)")
        }
    }

    /// Called from `StreamErrorRouter` when the server rejects a
    /// specific location with "Device not found / not owned by user".
    /// Mirrors the Android `pendingReregistration` path: clear the
    /// idempotency flag, re-POST /api/v1/devices, then restart the
    /// stream. Common after a push-token swap deactivates the row.
    fileprivate func handleLocationRejected(deviceId: String, error: String) {
        appendStreamerDiag("onLocationRejected device=\(deviceId.prefix(8)) error=\(error)")
        let lower = error.lowercased()
        // A per-circle membership refusal ("Not a member of this circle", from
        // ingest's membership check): this device is still targeting a circle
        // it left or that was deleted. The target list comes from the last
        // successful GET /circles, which a resident background process may not
        // have repeated for hours — so refresh it, lightly and rarely. The ack
        // names no circle, so there is nothing narrower to drop.
        if Self.isMembershipRefusal(lower) {
            let now = Date()
            if Self.membershipReloadIsDue(last: lastMembershipReloadAt, now: now) {
                lastMembershipReloadAt = now
                appendStreamerDiag("membership refusal → light circle reload")
                Task { @MainActor in try? await CircleManager.shared.loadCircles(light: true) }
            }
            return
        }
        let needsReregister = lower.contains("device not found")
            || lower.contains("not owned by user")
        guard needsReregister else { return }
        noteDeviceRefused(account: startedUserId)
        guard !reregistrationInFlight else { return }
        guard let userId = startedUserId else { return }
        // Once per rejected fix would mean a token-less POST for every
        // refused fix on a fresh sign-in, none of which can help.
        let now = Date()
        guard Self.reregisterIsDue(last: lastRejectionReregisterAt, now: now) else {
            appendStreamerDiag("onLocationRejected re-registered <5m ago, backing off")
            return
        }
        lastRejectionReregisterAt = now
        reregistrationInFlight = true
        // As for the stream error: only a token-carrying POST creates the row.
        PushNotificationManager.shared.requestDeviceTokenAfterRefusal()
        Task { @MainActor in
            defer { self.reregistrationInFlight = false }
            // Force DeviceRegistrar to re-POST by clearing its flag,
            // then ensure(). On success, rebuild the stream so the
            // server-side ownership check passes on the next send.
            DeviceRegistrar.reset(userId: userId)
            let ok = await DeviceRegistrar.ensure()
            guard ok else {
                appendStreamerDiag("re-registration failed; stream will keep failing until next attempt")
                return
            }
            guard let access = KeychainService.shared.getString(for: .accessToken) else {
                return
            }
            stop()
            start(jwtToken: access, userId: userId, deviceId: deviceId)
        }
    }

    /// Which table the server files the row under.
    ///
    /// One flag on the wire each: the server stores a liveness row in the
    /// latest-position table alone and writes no history; a kept point
    /// (`history_only`) goes to history alone — no latest position, no live
    /// fan-out, no alerts — checked against its own per-circle mark, so a
    /// device live elsewhere can still send it. Every other check and side
    /// effect — device-ownership validation, the day bucket, the
    /// classification of a refusal — is identical, which is why they all
    /// share `sendInner`.
    enum SendKind {
        case history
        case liveness
        /// A point sent late, to history alone: a fix kept while the circle was
        /// waiting to sync, or a past one (`sendPastHistory`).
        case keptHistory
    }

    /// Send a fresh location update to the given circle. Encrypts the
    /// payload with a one-shot msg_key, wraps the msg_key for the
    /// circle key, and ships the bundle to the server's ingest
    /// stream. Throws when the stream isn't running, the user isn't
    /// logged in, encryption fails, or the gRPC send fails.
    /// Background callers that don't care use `try?`.
    func send(circleId: String, location: PingolinTrackSDK.Location) throws {
        try send(circleId: circleId, location: location, kind: .history)
    }

    /// A check-in from a device that is alive but has not moved far enough for
    /// its position to be worth keeping. Same encryption, same targets, same
    /// bookkeeping on success as an ordinary send: a check-in really does
    /// refresh the server's latest position, so the "is my own marker stale"
    /// clock and the map's cold-start seed should both move with it.
    /// `capturedAt` is when its fix was taken, which a check-in's payload does
    /// not say (it carries now): what was not shared, or was shared only
    /// approximately, then stays so.
    func sendLiveness(circleId: String, location: PingolinTrackSDK.Location, capturedAt: Date? = nil) throws {
        try send(circleId: circleId, location: location, kind: .liveness, capturedAt: capturedAt)
    }

    /// A true past position that is not the latest (LocationService
    /// `.pastHistory`: a fix or a visit older than the one held), filed in
    /// history alone, as the kept points are (`history_only`): never anyone's
    /// latest position, no live fan-out, no alerts, and none of a live send's
    /// bookkeeping (no "last shared", no self-marker seed). A circle waiting to
    /// sync keeps it, as a live send's fix is kept.
    func sendPastHistory(circleId: String, location: PingolinTrackSDK.Location) throws {
        do {
            try sendInner(circleId: circleId, location: location, kind: .keptHistory)
            appendStreamerDiag("send ok kind=pastHistory circle=\(circleId.prefix(8))")
        } catch {
            switch error {
            case SendError.keyNotCurrent, SendError.waitingForSharingRecord:
                if let owner = AuthManager.shared.userId {
                    PendingCircleLocations.shared.keep(
                        privacyApplied(location, circleId: circleId), circleId: circleId, owner: owner)
                }
            default:
                break
            }
            appendStreamerDiag("send FAILED kind=pastHistory circle=\(circleId.prefix(8)) error=\(error)")
            throw error
        }
    }

    func send(circleId: String, location: PingolinTrackSDK.Location, kind: SendKind, capturedAt: Date? = nil) throws {
        // A personal send adopts first when a check at most 5 minutes
        // old said to — and is never skipped or held: a device whose
        // copy no longer matches keeps sending, or a server could stop
        // personal tracking at will.
        if circleId == SelfKeyManager.selfCircleUuid {
            SelfKeyManager.adoptPending()
        }
        // Anything kept while a circle was waiting to sync drains behind
        // this, as history only, at its own pace.
        drainKeptLocations()
        do {
            let sent = try sendInner(circleId: circleId, location: location, kind: kind, capturedAt: capturedAt)
            // The circle's latest row is now what this phone just sealed:
            // kept for a re-seal after a rotation while real-time sharing
            // there is off. Writing it never fails the send.
            if let sent, let owner = AuthManager.shared.userId {
                OwnLastSentStore.shared.put(sent, circleId: circleId, owner: owner)
            }
            Self.onSendSucceeded()
            noteSendQueued()
            Self.lastSendLocationMs = Int64(Date().timeIntervalSince1970 * 1000)
            // Update the persisted "open to my location" seed for the
            // next cold start. The Map view reads this in makeUIView
            // to center on the user instantly instead of flashing the
            // world default. Mirrors the Android app's persistSelfLoc
            // on every successful send.
            SelfLocationStore.save(PersistedSelfLocation(
                latitude: location.latitude,
                longitude: location.longitude
            ))
            appendStreamerDiag(
                "send ok kind=\(kind) circle=\(circleId.prefix(8)) "
                + "lat=\(String(format: "%.5f", location.latitude)) "
                + "lng=\(String(format: "%.5f", location.longitude))"
            )
        } catch {
            // Waiting to sync: keep the fix for this circle, with its
            // privacy applied now, as a live send would. Not a check-in
            // — "here now" would be false later.
            if case SendError.keyNotCurrent = error, kind == .history,
               let owner = AuthManager.shared.userId {
                PendingCircleLocations.shared.keep(
                    privacyApplied(location, circleId: circleId), circleId: circleId, owner: owner)
                appendStreamerDiag("send kept for later circle=\(circleId.prefix(8)) (waiting to sync)")
            }
            switch error {
            case SendError.encryptionFailed:
                // The one failure a circle-key reload can fix.
                Self.onSendFailed(error: error)
            case SendError.transportFailed, SendError.notRunning:
                // The stream, not the keys: a key reload cannot
                // fix these, and would only re-fetch circles every
                // five minutes while nothing is sent. Rebuild the
                // stream instead, with backoff. Offline: what this
                // phone missed meanwhile is read before a check-in
                // or the kept points go.
                CirclePauseRecord.shared.noteOffline()
                scheduleRestart(reason: "send failed: \(error)")
            default:
                break
            }
            appendStreamerDiag("send FAILED kind=\(kind) circle=\(circleId.prefix(8)) error=\(error)")
            throw error
        }
    }

    /// The drain of fixes kept while circles were waiting to sync,
    /// sent as `history_only` once this device holds a circle's current version:
    /// sealed under the key held now, each with its own time, and nothing a live
    /// send does besides — no "last shared", no self-marker seed. The server files
    /// them in history alone, never as anyone's latest position, and their order
    /// does not matter to it, so they need not wait for, or precede, a live send.
    /// PACED: the server's per-user ingest limit — 120 a minute, and nothing per
    /// second — is shared with live sends, so one point a second (half of it),
    /// oldest circle first. Each is handed to the SDK, which keeps a refused one
    /// for up to 48 hours and then reports it lost: nothing retries forever.
    /// A hand-off that fails stops the drain and keeps the rest for the next
    /// trigger — a live send, or a circle refresh. Only for circles the list has
    /// loaded: an unloaded circle is not judged current.
    private var keptDrain: Task<Void, Never>?
    nonisolated static let keptPointSpacing: UInt64 = 1_000_000_000

    func drainKeptLocations() {
        guard keptDrain == nil, let owner = AuthManager.shared.userId else { return }
        // After an offline stretch, one light refresh first: it
        // releases the kept points that wait for a read, and drains
        // again.
        if PendingCircleLocations.shared.circlesWithPoints(owner: owner).contains(where: {
            CirclePauseRecord.shared.unreadSinceOffline(circleId: $0, owner: owner)
        }) {
            Task { await PrivacyReadAfterOffline.shared.refresh() }
        }
        guard nextKeptPoint(owner: owner) != nil else { return }
        keptDrain = Task { @MainActor [weak self] in
            var sent = 0
            var withheld = 0
            while !Task.isCancelled, let self, let next = self.nextKeptPoint(owner: owner) {
                do {
                    try self.sendInner(circleId: next.circleId, location: next.point.location, kind: .keptHistory)
                } catch SendError.notSharingWhenTaken {
                    // Taken while this account was not
                    // sharing with the circle: it never
                    // goes there, and the rest still do.
                    PendingCircleLocations.shared.sent(1, circleId: next.circleId, owner: owner)
                    withheld += 1
                    continue
                } catch {
                    self.appendStreamerDiag("kept-location drain stopped after \(sent): \(error)")
                    break
                }
                PendingCircleLocations.shared.sent(1, circleId: next.circleId, owner: owner)
                sent += 1
                try? await Task.sleep(nanoseconds: Self.keptPointSpacing)
            }
            if sent > 0 { self?.appendStreamerDiag("sent \(sent) kept location(s) as history") }
            if withheld > 0 { self?.appendStreamerDiag("withheld \(withheld) kept location(s) taken while not sharing") }
            self?.keptDrain = nil
        }
    }

    /// The oldest kept point of the first circle that can take it now.
    private func nextKeptPoint(owner: String) -> (circleId: String, point: PendingCircleLocations.Point)? {
        let circles = CircleManager.shared
        for circleId in PendingCircleLocations.shared.circlesWithPoints(owner: owner).sorted()
        where circleId != SelfKeyManager.selfCircleUuid
            && circles.circles.contains(where: { $0.id == circleId })
            && circles.holdsCurrentKey(for: circleId) {
            // Not before a row read since it was taken:
            // the next refresh brings one, and kicks the
            // drain again.
            if let point = PendingCircleLocations.shared.points(circleId: circleId, owner: owner).first,
               !CirclePauseRecord.shared.awaitsRead(
                   circleId: circleId, capturedAt: Date(timeIntervalSince1970: TimeInterval(point.timestamp) / 1000),
                   owner: owner) {
                return (circleId, point)
            }
        }
        return nil
    }

    /// What it sealed and handed the stream, for a send that leaves the circle's
    /// latest row (`recordKind`), when the version and device pseudonym could be
    /// read; nil otherwise.
    @discardableResult
    private func sendInner(
        circleId: String,
        location: PingolinTrackSDK.Location,
        kind: SendKind,
        capturedAt: Date? = nil
    ) throws -> OwnLastSent? {
        guard let userId = AuthManager.shared.userId else {
            throw SendError.notSignedIn
        }
        // When the fix was taken: the payload's own time, but a check-in's.
        let taken = capturedAt ?? Date(timeIntervalSince1970: TimeInterval(location.timestamp) / 1000)
        // A point that waited goes only once a row read from the server
        // since it was taken says whether this account was sharing then:
        // a pause set and ended on another device while this one was
        // offline is in the server's spans alone. Kept until then, not
        // dropped for what that read will tell.
        let waiting = kind == .keptHistory
            && CirclePauseRecord.shared.awaitsRead(circleId: circleId, capturedAt: taken, owner: userId)
        // Never a point taken while this account was not sharing with
        // the circle, by its own time: the map's Send location, a
        // wake's fix, a kept point. Before anything else, so nothing
        // is kept for it.
        if CirclePauseRecord.shared.withholds(circleId: circleId, capturedAt: taken, owner: userId, waiting: waiting) {
            throw SendError.notSharingWhenTaken
        }
        if waiting {
            throw SendError.waitingForSharingRecord
        }
        // Never seal a location under a key the circle has moved past —
        // after a rotation that left this device pending, the member it
        // removed holds exactly the key we still have
        // (`holdsCurrentKey(for:)`). Checked before anything else so a
        // refusal costs no stream work. The one exception is an active
        // SOS, for the reason SOSManager gives: the rest of the circle
        // can read the old key too, and an emergency that reaches nobody
        // is the worse outcome.
        guard CircleManager.shared.holdsCurrentKey(for: circleId)
                || LocationService.shared.emergencyMode else {
            throw SendError.keyNotCurrent
        }
        // A stream the SDK has given up on reports `isStreaming() == false`
        // (the SDK can end the upload task on any failed RPC, or on a failed
        // connect with no callback at all). Rebuild it here, inside the backoff,
        // rather than queueing into a channel nobody reads. Outside the backoff
        // this throws, and the scheduled rebuild picks it up.
        if locationManager?.isStreaming() != true {
            if Date() >= nextRestartAllowedAt, restartTask == nil {
                rebuildStream(reason: "send found the stream down")
            } else {
                scheduleRestart(reason: "send found the stream down")
            }
        }
        guard let manager = locationManager,
              let deviceId = startedDeviceId else {
            throw SendError.notRunning
        }
        let applied = privacyAppliedWithBubble(location, circleId: circleId, capturedAt: taken)
        let location = applied.location
        // Bind the sender's pseudonym (derived from own user_id — the
        // same id a reader resolves for us from encrypted_user_id) into
        // the payload AEAD, so a server relabel fails the tag. Fall back
        // to the legacy unbound envelope if the derivation ever fails
        // (never bind to an empty pseudonym, which would make every
        // reader drop the row).
        //
        // The SELF circle stays LEGACY (unbound): it is single-user so
        // sender attribution is moot, and the other clients read self
        // rows only via the unbound path (the web client and the Android
        // app both exempt self), so binding self here would make those
        // readers drop iPhone solo rows. Only member circles get
        // sender-bound.
        let senderPseudonym: String? = (circleId == SelfKeyManager.selfCircleUuid)
            ? nil
            : (try? cryptoManager.deriveUserPseudonym(circleId: circleId, userId: userId))
        if senderPseudonym == nil && circleId != SelfKeyManager.selfCircleUuid {
            appendStreamerDiag("send UNBOUND (pseudonym derive failed) circle=\(circleId.prefix(8))")
        }
        // The version this seal goes under and this device's pseudonym,
        // read just BEFORE it: a rotation landing in between then names
        // an older version, so a re-seal is tried and refused, never
        // skipped. Nothing is recorded when either can't be read.
        let recordKind = Self.recordKind(kind, circleId: circleId)
        var sealedUnder: (keyVersion: Int32, devicePseudonym: String)?
        if recordKind != nil,
           let version = try? cryptoManager.getActiveVersion(circleId: circleId),
           let devicePseudonym = try? cryptoManager.deriveDevicePseudonym(circleId: circleId, deviceId: deviceId) {
            sealedUnder = (version, devicePseudonym)
        }
        // 1. Generate the envelope: one ciphertext + per-target
        //    wrapped msg_key. Single target = one entry in
        //    key_wraps; pull the (hex_key, hex_nonce) pair from it.
        let envelope = try {
            do {
                if let senderPseudonym {
                    return try cryptoManager.envelopeEncryptLocationBound(
                        location: location,
                        targetIds: [circleId],
                        senderPseudonym: senderPseudonym
                    )
                }
                return try cryptoManager.envelopeEncryptLocationV2(
                    location: location,
                    targetIds: [circleId]
                )
            } catch {
                throw SendError.encryptionFailed(underlying: error)
            }
        }()
        guard let wrap = envelope.keyWraps.first else {
            throw SendError.encryptionFailed(underlying: nil)
        }
        // 2. Bundle into the EncryptedLocation shape sendEnvelopeLocation
        //    wants — ciphertext + nonce + timestamp + user/device id.
        let encrypted = EncryptedLocation(
            location: EncryptedData(
                nonce: envelope.ciphertextNonce,
                ciphertext: envelope.ciphertext
            ),
            timestamp: envelope.timestamp,
            userId: userId,
            deviceId: deviceId
        )
        // 3. Hand to the gRPC stream. Both arms take the ENVELOPE variant,
        //    because this app takes only the envelope path for a real
        //    send — a liveness refresh on the plain `sendLivenessRefresh` could
        //    not be produced here at all, since nothing on iOS holds the
        //    circle-key ciphertext and key id that call wants.
        do {
            switch kind {
            case .history:
                try manager.sendEnvelopeLocation(
                    deviceId: deviceId,
                    circleId: circleId,
                    encryptedLocation: encrypted,
                    wrappedMsgKeyHex: wrap.wrappedKey,
                    wrappedMsgKeyNonceHex: wrap.wrappedKeyNonce
                )
            case .liveness:
                try manager.sendEnvelopeLivenessRefresh(
                    deviceId: deviceId,
                    circleId: circleId,
                    encryptedLocation: encrypted,
                    wrappedMsgKeyHex: wrap.wrappedKey,
                    wrappedMsgKeyNonceHex: wrap.wrappedKeyNonce
                )
            case .keptHistory:
                try manager.sendEnvelopeHistoryLocation(
                    deviceId: deviceId,
                    circleId: circleId,
                    encryptedLocation: encrypted,
                    wrappedMsgKeyHex: wrap.wrappedKey,
                    wrappedMsgKeyNonceHex: wrap.wrappedKeyNonce
                )
            }
            scheduleBatterySaverTeardown()
        } catch {
            throw SendError.transportFailed(underlying: error)
        }
        guard let recordKind, let sealedUnder else { return nil }
        return OwnLastSent(sent: recordKind, envelope: envelope, wrap: wrap, point: location,
                           coarsenedToMiles: applied.coarsenedToMiles,
                           keyVersion: sealedUnder.keyVersion, devicePseudonym: sealedUnder.devicePseudonym)
    }

    /// What a send of `kind` records of itself: only one that leaves the
    /// circle's latest row, a live send or a check-in. Never a kept point,
    /// which goes to history alone, and never the personal history, whose
    /// rows nobody else is shown.
    static func recordKind(_ kind: SendKind, circleId: String) -> OwnLastSent.Kind? {
        guard circleId != SelfKeyManager.selfCircleUuid else { return nil }
        switch kind {
        case .history: return .live
        case .liveness: return .liveness
        case .keptHistory: return nil
        }
    }

    /// The circle's privacy, applied to a fix before it is sealed for that
    /// circle — or kept for it: approximate sharing snaps it to the grid
    /// cell and drops the motion fields; a withheld battery level is removed.
    private func privacyApplied(_ location: PingolinTrackSDK.Location, circleId: String,
                                capturedAt: Date? = nil) -> PingolinTrackSDK.Location {
        privacyAppliedWithBubble(location, circleId: circleId, capturedAt: capturedAt).location
    }

    /// `privacyApplied`, with the bubble the point went to (nil = exact): what a
    /// send records of it.
    private func privacyAppliedWithBubble(_ location: PingolinTrackSDK.Location, circleId: String,
                                          capturedAt: Date? = nil)
        -> (location: PingolinTrackSDK.Location, coarsenedToMiles: Double?) {
        let taken = capturedAt ?? Date(timeIntervalSince1970: TimeInterval(location.timestamp) / 1000)
        let applied = Self.privacyApplied(
            location, circleId: circleId, privacy: CircleManager.shared.privacySettings[circleId],
            captureRadiusMiles: CirclePauseRecord.shared.captureRadius(
                circleId: circleId, capturedAt: taken, owner: AuthManager.shared.userId))
        if let radiusMiles = applied.coarsenedToMiles {
            appendStreamerDiag(
                "send coarsened bubble=\(String(format: "%.2f", radiusMiles))mi circle=\(circleId.prefix(8))"
            )
        }
        if applied.batteryWithheld {
            appendStreamerDiag("send battery withheld circle=\(circleId.prefix(8))")
        }
        return (applied.location, applied.coarsenedToMiles)
    }

    /// `privacyApplied` given the row this phone holds for the circle rather than
    /// reading it, so a test can see exactly what a send would carry.
    /// `captureRadiusMiles`: the bubble in force when the fix was taken
    /// (`CirclePauseRecord.captureRadius`), which still holds for it after a
    /// switch to exact; the larger bubble wins.
    static func privacyApplied(
        _ location: PingolinTrackSDK.Location, circleId: String, privacy: PrivacySettings?, now: Date = Date(),
        captureRadiusMiles: Double? = nil
    ) -> (location: PingolinTrackSDK.Location, coarsenedToMiles: Double?, batteryWithheld: Bool) {
        // Bubble ("approximate") sharing: coarsen the coordinates to a
        // deterministic snap-to-grid BEFORE encryption so this circle's
        // members — and the server — only ever see the grid cell, never the
        // exact fix. Done per-circle: the same physical location is snapped
        // independently for each approximate circle. The SELF circle and exact
        // mode are never coarsened (self stays exact because its marker is
        // rendered device-locally), and nothing is sent while a pause runs; a
        // pause that has ended on this phone shares as the mode it returns to
        // (`PrivacySettings.sharesApproximately`). Defaults to a 1-mile cell
        // when the stored radius is unset/zero. Mirrors the Android app's
        // sender-side coarsening. Note the un-coarsened `location` the caller
        // passed still seeds SelfLocationStore back in `send(...)`, so the
        // user's own marker is unaffected.
        var location = location
        var coarsenedToMiles: Double?
        var batteryWithheld = false
        let bubbleNow: Double? = privacy.flatMap {
            $0.sharesApproximately(at: now) ? ($0.bubbleRadius > 0 ? $0.bubbleRadius : 1.0) : nil
        }
        if circleId != SelfKeyManager.selfCircleUuid,
           let radiusMiles = [bubbleNow, captureRadiusMiles].compactMap({ $0 }).max() {
            let cellMeters = radiusMiles * 1609.344
            let (coarseLat, coarseLng) = LocationCoarsener.coarsenLocation(
                lat: location.latitude,
                lng: location.longitude,
                radiusMeters: cellMeters
            )
            // Strip the motion/precision fields on the coarsened branch. With
            // the fix already snapped to a grid cell, verbatim speed/heading/
            // altitude plus the true accuracy would let a member dead-reckon
            // within the cell and recover a finer position than the bubble is
            // meant to reveal. Null the motion fields (unknown) and floor
            // accuracy to at least the cell size so it never advertises
            // sub-cell precision. The exact (non-bubble) branch is untouched.
            location = PingolinTrackSDK.Location(
                latitude: coarseLat,
                longitude: coarseLng,
                altitude: nil,
                speed: nil,
                heading: nil,
                accuracy: max(location.accuracy ?? cellMeters, cellMeters),
                timestamp: location.timestamp,
                batteryLevel: location.batteryLevel,
                isCharging: location.isCharging
            )
            coarsenedToMiles = radiusMiles
        }
        // Battery sharing, honoured on the sender for the same reason the
        // coarsening above is: the battery level travels INSIDE the encrypted
        // payload, so the server cannot strip it for a circle that has switched
        // it off — it cannot read it. A level left in the plaintext before
        // sealing is shared with that circle whatever the setting says. The SELF
        // circle keeps its battery (the user's own history), and an unknown
        // posture keeps the default TRUE, matching the server's default rather
        // than inventing a stricter one. And only while "Allow alerts on me" is
        // on there too: the level's only reader is the low-battery alert about
        // this account.
        if circleId != SelfKeyManager.selfCircleUuid,
           let privacy,
           !privacy.sendsBattery,
           location.batteryLevel != nil {
            location = PingolinTrackSDK.Location(
                latitude: location.latitude,
                longitude: location.longitude,
                altitude: location.altitude,
                speed: location.speed,
                heading: location.heading,
                accuracy: location.accuracy,
                timestamp: location.timestamp,
                batteryLevel: nil,
                isCharging: false
            )
            batteryWithheld = true
        }
        return (location, coarsenedToMiles, batteryWithheld)
    }

    // MARK: - Self-heal on persistent send failure

    /// Track end-to-end send failures and, after a threshold, re-pull
    /// the circle keys from the server. Mirrors the Android app:
    /// an inconsistent local key state (e.g. after the cryptoManager
    /// was reseeded post-relogin while the streamer kept its handle to
    /// the old keys) would otherwise leave the background tracker
    /// silently failing every tick until the user opened the app and
    /// CircleManager.loadCircles repaired the state. With the heal in
    /// place, the streamer recovers without user action.
    private static var consecutiveSendFailures: Int = 0
    private static var lastKeyHealAttemptMs: Int64 = 0
    /// Heals since the last successful send; picks the next cooldown.
    private static var keyHealAttempts: Int = 0
    private static let keyHealThreshold = 3

    /// Cooldown before the next key heal: 5, then 15, then 60 minutes. A heal
    /// that did not work the first time is unlikely to work on a five-minute
    /// cadence, and each one is a round of circle GETs.
    nonisolated static func keyHealCooldownMs(afterAttempts attempts: Int) -> Int64 {
        switch attempts {
        case ..<1: return 5 * 60_000
        case 1: return 15 * 60_000
        default: return 60 * 60_000
        }
    }

    private static func onSendSucceeded() {
        consecutiveSendFailures = 0
        keyHealAttempts = 0
    }

    /// Only ever reached with `SendError.encryptionFailed`: see the switch in
    /// `send`. Transport and not-running failures go to the stream rebuild.
    private static func onSendFailed(error: Error) {
        consecutiveSendFailures += 1
        guard consecutiveSendFailures >= keyHealThreshold else { return }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        guard now - lastKeyHealAttemptMs >= keyHealCooldownMs(afterAttempts: keyHealAttempts) else { return }
        lastKeyHealAttemptMs = now
        keyHealAttempts += 1
        #if DEBUG
        print("[Track] send chain failed \(consecutiveSendFailures)× — refreshing circle keys (last err: \(error))")
        #endif
        Task { @MainActor in
            // The light load is enough for what this heals: it installs any
            // circle key the SDK is missing (or one the server has rotated past
            // us) without the backfill POSTs and historical import of a full
            // login-grade load. Don't reset the counter here — let the next
            // successful send do it so we get an unambiguous "recovery worked"
            // signal.
            try? await CircleManager.shared.loadCircles(light: true)
        }
    }

    enum SendError: LocalizedError {
        case notRunning
        case notSignedIn
        case encryptionFailed(underlying: Error?)
        case transportFailed(underlying: Error)
        /// The circle's newer key has not reached this device, so nothing
        /// is sealed for it. Not a stream fault and not fixed by a reload:
        /// no restart, no key-refresh.
        case keyNotCurrent
        /// Taken while this account was not sharing with the circle
        /// (`CirclePauseRecord`): never sent there, never kept for it.
        case notSharingWhenTaken
        /// A point that waited, before a row read from the server since it was
        /// taken (`CirclePauseRecord.awaitsRead`): kept for later.
        case waitingForSharingRecord
        var errorDescription: String? {
            switch self {
            case .notRunning:       return "Location stream isn't running yet"
            case .notSignedIn:      return "Not signed in"
            case .encryptionFailed: return "Couldn't encrypt your location"
            case .transportFailed:  return "Couldn't reach the server"
            case .keyNotCurrent:    return "This circle is waiting to sync, so your location is queued for it until then"
            case .notSharingWhenTaken:
                return "Not sent: you weren't sharing your location with this circle when it was taken"
            case .waitingForSharingRecord:
                return "Kept for this circle until the app has checked your sharing since it was taken"
            }
        }
    }

    /// User-triggered single send, with a 15-second cooldown shared
    /// across MapView re-creations. Matches the Android app's
    /// `MapViewModel.sendLocationNow` rate-limit + result-state model.
    /// Caller passes the circle id (or `SelfKeyManager.selfCircleUuid`
    /// when soloing) and renders the returned result to the user.
    fileprivate static var lastSendLocationMs: Int64 = 0
    static let rateLimitMs: Int64 = 15_000
    /// Most recent successful send timestamp (ms since epoch).
    /// Exposed so the foreground resume nudge can decide whether the
    /// user's own marker is stale (>3 min) and worth refreshing.
    static var lastSuccessfulSendMs: Int64 { lastSendLocationMs }

    enum SendNowResult {
        case success
        case rateLimited(waitSeconds: Int)
        case failed(message: String)
    }

    func sendNow(circleId: String, location: PingolinTrackSDK.Location) -> SendNowResult {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let elapsed = now - Self.lastSendLocationMs
        if elapsed < Self.rateLimitMs {
            let wait = Int((Self.rateLimitMs - elapsed) / 1000) + 1
            return .rateLimited(waitSeconds: wait)
        }
        // Diagnose: is the gRPC stream actually connected, or are we
        // shipping into a dead local channel? `start_streaming` flips
        // is_streaming=true *immediately*; the actual TLS / handshake
        // happens async, and a failed connection silently flips it
        // back to false while leaving the tx channel intact. Without
        // this check `tx.try_send` returns Ok and we'd claim
        // "Location saved" while the message rots in a buffer with no
        // reader.
        let streamingBefore = locationManager?.isStreaming() ?? false
        appendStreamerDiag("sendNow start circle=\(circleId.prefix(8)) streamingBefore=\(streamingBefore)")
        do {
            try send(circleId: circleId, location: location)
            let streamingAfter = locationManager?.isStreaming() ?? false
            appendStreamerDiag("sendNow ok streamingAfter=\(streamingAfter)")
            if !streamingAfter {
                return .failed(message: "Send queued but gRPC stream is down")
            }
            Self.lastSendLocationMs = now
            return .success
        } catch {
            appendStreamerDiag("sendNow throw \(error)")
            return .failed(message: error.plainText)
        }
    }

    fileprivate func appendStreamerDiag(_ message: String) {
        Self.appendStreamerDiagStatic(message)
    }

    /// Debug builds only: the "send ok" line carries plaintext lat/lng and
    /// Documents/ is backed up. No-op in release so no GPS diagnostics are
    /// ever persisted to disk.
    fileprivate static func appendStreamerDiagStatic(_ message: String) {
        #if DEBUG
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = docs.appendingPathComponent("send-location-diag.log")
        let line = "\(ISO8601DateFormatter().string(from: Date())) [streamer] \(LogRedaction.scrub(message))\n"
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
}

/// UniFFI callback bridge. Rust invokes these on the SDK's runtime
/// thread; both methods hop straight to the MainActor since
/// SDKLocationStreamer's reaction touches Keychain + restarts the
/// LocationManager. Mirrors the Android app's
/// LocationStreamErrorCallback inner class.
fileprivate final class StreamErrorRouter: StreamErrorCallback, @unchecked Sendable {
    func onLocationRejected(deviceId: String, error: String) {
        Task { @MainActor in
            SDKLocationStreamer.shared.handleLocationRejected(deviceId: deviceId, error: error)
        }
    }

    func onStreamError(error: String) {
        Task { @MainActor in
            SDKLocationStreamer.shared.handleStreamError(error)
        }
    }
}
