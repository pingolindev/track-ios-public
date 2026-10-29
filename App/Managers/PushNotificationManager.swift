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
import UserNotifications
import CoreLocation
import PingolinTrackSDK

/// Owns the iOS push-notification lifecycle: prompt for authorization,
/// register for APNs, capture the device token, ship it to the backend
/// alongside an encrypted device-name + device-type. Mirrors the Android
/// app's PushNotificationManager + DeviceRepository.registerDevice flow.
///
/// The device is keyed by a deterministic UUID stored in keychain — passing
/// the same id back on subsequent launches keeps registration idempotent
/// and lets the backend dedupe.
@MainActor
final class PushNotificationManager: NSObject, ObservableObject {
    static let shared = PushNotificationManager()

    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    @Published private(set) var lastError: String?

    private let api = APIService.shared
    private let keychain = KeychainService.shared
    private let cryptoManager = SDKCrypto.cryptoManager

    /// Cache of the last APNs token we POSTed to the server. Lets us
    /// skip the round-trip when iOS hands us the same token after a
    /// re-launch (typical case). Cleared on logout via `reset()`.
    private static let lastPushedTokenKey = "push.last_token"

    /// How iOS is asked for this device's APNs token. A seam: the tests count
    /// the asks.
    var askForToken: () -> Void = { UIApplication.shared.registerForRemoteNotifications() }
    /// When a refusal of this device last asked for the token
    /// (`requestDeviceTokenAfterRefusal`).
    private var lastRefusalTokenAskAt: Date?

    override private init() { super.init() }

    /// Ask the user for notification permission (called from app launch
    /// or first-login). On grant, kicks off `UIApplication.registerForRemoteNotifications`
    /// which lands in `didRegisterForRemoteNotificationsWithDeviceToken`
    /// on AppDelegate, which calls back into `register(deviceToken:)`.
    func requestAuthorization() async {
        let center = UNUserNotificationCenter.current()
        do {
            _ = try await center.requestAuthorization(options: [.alert, .badge, .sound])
            let settings = await center.notificationSettings()
            authorizationStatus = settings.authorizationStatus
        } catch {
            lastError = "Notifications request failed: \(error.plainText)"
        }
        // ALWAYS register for remote notifications — even if the user
        // declined alerts. The APNs *device token* is delivered to
        // didRegisterForRemoteNotificationsWithDeviceToken regardless of
        // alert/badge/sound permission (that permission only governs showing
        // notifications). The token is REQUIRED beyond pushes: the server
        // validates device ownership on every location send against the
        // device's registration, and that row is only written when the device
        // registers WITH a token (register(deviceToken:)). Gating this on
        // `granted` would leave a user who declined notifications with NO token
        // → no registration row → the server rejecting every location send
        // ("Device not found or not owned by user") and the user silently
        // sharing no location. Android doesn't hit this because its FCM token
        // is obtained independent of notification permission.
        askForToken()
    }

    /// Ask iOS for this device's APNs token, with no prompt: the token comes
    /// whatever the alert permission says (see `requestAuthorization`). It
    /// lands in `register(deviceToken:)`, whose token-carrying POST is what
    /// writes the device registration the server's ingest, needs-attention and
    /// check-ins require.
    ///
    /// A fresh sign-in asks here (`AuthManager.completeLogin`): otherwise
    /// nothing in that session would ask unless the person tapped "Allow
    /// Notifications" on onboarding's optional page, and a new account would
    /// share no location until the app was relaunched.
    func requestDeviceToken() {
        Self.appendPushDiag("asking iOS for the APNs token (no prompt)")
        askForToken()
    }

    /// The same after the server refused this device ("Device not found or not
    /// owned by user"): a token-less re-registration can never create the row
    /// it is missing. At most once per `refusalTokenAskCooldown`, so a phone
    /// that gets no token doesn't ask on every refused fix. True when it asked.
    @discardableResult
    func requestDeviceTokenAfterRefusal(now: Date = Date()) -> Bool {
        guard Self.refusalTokenAskIsDue(last: lastRefusalTokenAskAt, now: now) else { return false }
        lastRefusalTokenAskAt = now
        requestDeviceToken()
        return true
    }

    static let refusalTokenAskCooldown: TimeInterval = 5 * 60

    nonisolated static func refusalTokenAskIsDue(last: Date?, now: Date) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= refusalTokenAskCooldown
    }

    /// Hand-off from the AppDelegate when APNs returns a token. Hex-
    /// encodes the bytes (the server stores tokens as hex strings) and
    /// registers the device WITH it (see below).
    ///
    /// This path must NOT fork on `CircleManager.activeCircle` —
    /// encrypting device-name/type under an active circle key and
    /// bailing when there isn't one would lock invitees out of push
    /// entirely: you can't receive an invite push until you've
    /// joined a circle, but you join a circle by accepting an
    /// invite. The device registration uses the self-circle key
    /// instead (which every authenticated user has after
    /// `SelfKeyManager.ensure`), which side-steps the chicken-and-egg.
    func register(deviceToken: Data) async {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        // NOTE: deliberately NOT short-circuiting when the token is unchanged.
        // This POST is the only thing that (re)writes the device's registration
        // row, and the server validates EVERY location send against that row.
        // If the server loses the row — e.g. a long offline gap / session break —
        // an unchanged-token early return would leave it missing for good, so the
        // device's location would be silently rejected ("Device not found or not
        // owned by user") with no way to recover. Re-registering on each token
        // delivery (i.e. each launch, since registerForRemoteNotifications always
        // runs) keeps the row present. createDevice upserts by device-id, so it's
        // a cheap idempotent refresh, not a duplicate.
        guard keychain.getString(for: .deviceId) != nil else {
            print("[Track] push register deferred: no deviceId yet")
            return
        }
        // Register the device WITH the APNs token in one POST. This is
        // the only path that registers the token: the server records it
        // only when the create carries a token, and the dedicated PUT
        // /devices/:id/push-token 404s when no registration exists (it
        // only updates), so a token-less create + that PUT never
        // persists the token. createDevice upserts by device-id, so
        // this also refreshes an existing registration, including one
        // made without a token. Mirrors the Android app (its
        // registration POST carries the push token).
        Self.appendPushDiag("apns token received len=\(hex.count) — registering device WITH token")
        let registered = await DeviceRegistrar.ensure(pushToken: hex, pushType: "apns")
        Self.appendPushDiag("device register WITH token result=\(registered)")
        if registered {
            // Cache only on success so a failed attempt retries on the
            // next launch (register fires each launch via
            // requestAuthorization → registerForRemoteNotifications).
            try? keychain.saveSDKData(hex, for: Self.lastPushedTokenKey)
            lastError = nil
            // The row exists now: a stream the server ended while it didn't
            // comes back (the refusal's own handler can't bring it back: a
            // token-less re-registration doesn't make the device addressable).
            SDKLocationStreamer.shared.deviceBecameAddressable()
        } else {
            lastError = "Push registration failed"
            print("[Track] push registration deferred/failed: DeviceRegistrar.ensure(pushToken:) returned false")
        }
    }

    /// Called when APNs registration fails (no certificate, no network,
    /// etc.). We keep it best-effort — the inbox screen still works
    /// without push.
    func registrationFailed(_ error: Error) {
        lastError = "APNs registration failed: \(error.plainText)"
        Self.appendPushDiag("apns registration FAILED: \(error.localizedDescription)")
    }

    /// Append a line to Documents/push-diag.log so APNs token delivery /
    /// failure is pullable via devicectl (the failure path otherwise only
    /// sets an in-memory error).
    static func appendPushDiag(_ message: String) {
        // DEBUG-only: append-only push-usage trace to Documents/push-diag.log,
        // backup-eligible and swept on logout. Must be a no-op in Release so it
        // doesn't accumulate a permanent unswept launch timeline in backups.
        #if DEBUG
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = docs.appendingPathComponent("push-diag.log")
        let line = "\(ISO8601DateFormatter().string(from: Date())) [push] \(message)\n"
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

    /// Called on logout so a re-login under a different account doesn't
    /// inherit the previous account's push registration on the server.
    /// The main `.deviceId` slot is cleared by AuthManager.logout
    /// alongside the rest of the keychain, so we just need to drop
    /// the last-pushed-token cache so the next account's APNs token
    /// gets re-POSTed.
    func reset() {
        keychain.deleteSDKData(for: Self.lastPushedTokenKey)
        lastRefusalTokenAskAt = nil
    }
}

/// Bridges UIKit's APNs callbacks into PushNotificationManager so the
/// SwiftUI app target doesn't need a full UIApplicationDelegate.
final class PushAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Register BG task handlers as early as possible — iOS requires
        // this to happen before applicationDidFinishLaunching returns.
        BackgroundTaskScheduler.shared.registerHandlers()

        // The approval records are this device's, before anything reads them.
        KeyDeliveryApprovals.bindRecordsToThisDevice()

        // Debug-only: what is sitting in the tray right now, and whether this app
        // is even allowed to put things there.
        //
        // A push that shows a banner but does not wake the app looks, from the
        // server, exactly like a push that did neither — both are a 200 from APNs
        // and silence afterwards. Reading the tray back on the next launch is the
        // only way to tell those apart without standing in front of the phone, and
        // they have opposite causes: the first is background delivery being
        // withheld (Background App Refresh off, budget), the second is the push
        // shape or the token. No-op in release builds.
        #if DEBUG
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            let delivered = await center.deliveredNotifications()
            let tray = delivered.map { note -> String in
                let info = note.request.content.userInfo
                let t = (info["type"] as? String) ?? (info["alert_type"] as? String) ?? "?"
                return "\(t)@\(note.date.timeIntervalSince1970)"
            }
            Self.writeNotifDiag(
                "launch.tray auth=\(settings.authorizationStatus.rawValue) "
                    + "alert=\(settings.alertSetting.rawValue) "
                    + "count=\(delivered.count) [\(tray.joined(separator: ","))]"
            )
        }
        #endif

        // Eager wake for background location delivery. iOS hands us a
        // brief window before suspension when it relaunches the
        // process for an SLC or Visit event (the `.location` launch
        // option signals exactly this case, but we wake
        // unconditionally — the calls are no-ops without Always
        // permission, and the user-initiated tracking flow will
        // re-bind the same state idempotently anyway). The keychain
        // rehydrate gives the SDK its X25519 private key back so any
        // send fired off the queued event can envelope-encrypt; same
        // pattern as `checkExistingSession` but earlier on the launch
        // path. Touching `CircleManager.shared` instantiates the
        // singleton so its `locationUpdates` subscription is live
        // before the queued CL event lands.
        if let sharingPriv = KeychainService.shared.getString(for: .sharingPrivateKey),
           !sharingPriv.isEmpty {
            try? SDKCrypto.cryptoManager.importPrivateKey(privateKeyBase64: sharingPriv)
        }
        _ = CircleManager.shared
        // Instantiate PlaceManager on the launch path too: a
        // geofence enter/exit can RELAUNCH a killed app, and only PlaceManager's
        // init installs the region-enter/exit subscribers + hydrates the
        // monitored set from the ciphertext cache. Without touching it here, the
        // relaunching crossing lands with no subscriber and no `places` and is
        // dropped until a UI-driven load runs.
        _ = PlaceManager.shared
        LocationService.shared.wakeForBackgroundLocationDelivery()
        EnergyMetrics.shared.start() // MetricKit energy reports (dev builds only; see EnergyMetrics)

        // Resume TRACKING on a background location relaunch. The session
        // restore that starts the streamer and `startTracking()` runs from
        // RootView's `.onAppear`, and a relaunch for a region exit, a
        // significant change or a visit never shows a scene — so without
        // this the phone would stay dark to its circle until the user opened
        // the app. This is the headless half of that restore; it also listens
        // for a later location event reaching a process that is not tracking
        // (a relaunch before the first unlock after a reboot, when the tokens
        // were unreadable). See HeadlessTrackingResume for what it does and
        // what it leaves to the UI.
        HeadlessTrackingResume.install(launchedForLocation: launchOptions?[.location] != nil)

        // Arm the client-side alert-evaluation loop HERE as well as from
        // MainTabView, because on this path MainTabView may never exist.
        //
        // MainTabView arms it inside a `Task` with a 5 s sleep, in a view body
        // (MainTabView.swift). A geofence or significant-location event can
        // relaunch a killed app straight into THIS function — which is why
        // PlaceManager is instantiated two lines up — and never present that view,
        // so the loop that evaluates inactivity, circle-self, battery and place
        // alerts would never start. The relaunching crossing would be handled by
        // the region subscribers, and then nothing would evaluate again until the
        // user opened the app.
        //
        // `startInactivityWatch()` is idempotent (`guard !watchStarted`), so the
        // MainTabView call remains the foreground path and this one is a no-op when
        // the UI got there first.
        //
        // Gated on a refresh token rather than `AuthManager.isAuthenticated`: that
        // flag starts false and is only set by `checkExistingSession`, which runs
        // from the root view's `onAppear` — i.e. exactly the path that does not
        // happen here. A keychain probe is the only session signal available this
        // early, and without a gate the first pass 401-loops through the token
        // authenticator, which `BackgroundTaskScheduler` already documents as worth
        // avoiding. And only for an approved account: Track refuses any other's
        // token.
        if RegistrationGate.allowsTrack,
           let refresh = KeychainService.shared.getString(for: .refreshToken),
           !refresh.isEmpty {
            Task { @MainActor in MonitoringManager.shared.startInactivityWatch() }
        }

        // Route notification taps to the right tab. Without this
        // delegate set, tapping a local circle-invite banner just
        // foregrounds the app on whatever tab was last active —
        // typically Map — and the user has to navigate to Circles
        // themselves to find the Accept button.
        UNUserNotificationCenter.current().delegate = self

        return true
    }

    /// Foreground presentation. By default iOS does NOT show banners
    /// for notifications that arrive while the app is foregrounded;
    /// returning `.banner + .sound` here makes the invite alert
    /// visible regardless of app state so the user can tap it.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    /// User tapped (or swiped action on) a delivered notification.
    /// Routes by the notification's request identifier prefix:
    ///
    ///   * `circle_invite_…` — local notification we post when a
    ///     `circle_invite` silent push arrives, OR when the server
    ///     pushed an alert-style invite. Either way, the right
    ///     destination is the Circles tab, where the
    ///     PendingInviteRow shows Accept / Decline.
    ///
    /// Falls through to no-op on unknown identifiers so future
    /// notification kinds (member_joined etc.) can be added without
    /// disturbing the existing routes.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let identifier = response.notification.request.identifier
        let content = response.notification.request.content
        let userInfo = content.userInfo
        let kind = (userInfo["type"] as? String)
            ?? (userInfo["aps"] as? [String: Any]).flatMap { $0["type"] as? String }
        // Server pushes carry alert_type as a top-level userInfo key (the push
        // relay forwards it on APNs, as on FCM) — it drives precise
        // destination routing below.
        let alertType = userInfo["alert_type"] as? String
        // These are not on the push: destination_id and arrived_user_id are
        // stable identifiers, one of them for a person, and everything on the
        // payload is handed to Apple. They are read back out of the stored
        // notification row instead — see resolveRoutingIds — over this app's own
        // authenticated connection. Still read here so a push sent by an older
        // server keeps routing precisely with no round-trip.
        let pushDestinationId = userInfo["destination_id"] as? String
        let pushArrivedUserId = userInfo["arrived_user_id"] as? String
        let correlationId = userInfo["alert_id"] as? String
        let category = content.categoryIdentifier
        let title = content.title
        let body = content.body
        // Some servers signal the kind via `aps.category` (so iOS
        // can show pre-defined action buttons) instead of a
        // top-level `type` field. Mirror our match across both.
        let isInviteIdentifier = identifier.hasPrefix("circle_invite_")
        let isInviteKind = kind == "circle_invite" || kind == "invite"
        let isInviteCategory = category == "CIRCLE_INVITE" || category.lowercased().contains("invite")
        // Title/body sniff for server-sent alert pushes that carry
        // no type / category: such bare APNs alerts (type=nil,
        // category=empty) can never match on identifier prefix, kind
        // or category alone. Falling back to a copy-text match
        // ("Invite" in title, "invited" in body) recovers routing
        // for those payloads.
        let titleLower = title.lowercased()
        let bodyLower = body.lowercased()
        let isInviteCopy = titleLower.contains("invit")
            || bodyLower.contains("invited")
            || bodyLower.contains("invite")
        let isInvite = isInviteIdentifier || isInviteKind || isInviteCategory || isInviteCopy

        // Destination notifications: our local self-arrival post
        // (stable `self-arrival-…` identifier), a typed payload, or a
        // bare server alert recognised by its generic copy ("Destination
        // Update" is what the push relay's APNs path titles every
        // destination tickle). Tap lands on the in-app notifications
        // list — the personalised record lives there. Mirrors the
        // Android app (AlertHandler navigate_to=notifications).
        // Checked BEFORE the invite paths so the pending-invite
        // fallback below can't claim a destination tap.
        let isDestinationIdentifier = identifier.hasPrefix("self-arrival-")
        let isDestinationKind = kind == "destination_arrival" || kind == "destination_shared"
            || alertType == "destination_arrival" || alertType == "destination_shared"
        let isDestinationCopy = titleLower.contains("destination")
            || titleLower == "arrived"
            || titleLower == "you've arrived!"
        let isDestination = isDestinationIdentifier || isDestinationKind
            || (!isInvite && isDestinationCopy)
        Self.writeNotifDiag(
            "tap id=\(identifier) type=\(kind ?? "nil") category=\(category) "
            + "title=\(title.prefix(40)) body=\(body.prefix(60)) routed=\(isInvite || isDestination)"
        )

        // One of the two questions only a person can answer, posted by this app
        // (`CircleQuestionNotifier`): open Circles and ask it — the day's limit
        // must not hide the very question the tap came for.
        // An invitation's question is kept by InvitationRenewals and shown at
        // the top of the app: the tap only opens Circles.
        if alertType == CircleQuestionNotifier.alertType,
           userInfo["question"] as? String == CircleQuestion.invitee.rawValue {
            Task { @MainActor in
                TabSelectionState.shared.selected = 1
                completionHandler()
            }
            return
        }
        if alertType == CircleQuestionNotifier.alertType,
           let circleId = userInfo["circle_id"] as? String, let memberId = userInfo["member_id"] as? String {
            Task { @MainActor in
                MemberKeyPinner.shared.askAgainNow(userId: memberId)
                try? await Task.sleep(nanoseconds: 200_000_000)
                TabSelectionState.shared.selected = 1
                try? await CircleManager.shared.loadMembers(for: circleId)
                completionHandler()
            }
            return
        }

        // Somebody has asked to take over a circle. Checked ahead of every
        // other branch below: the body ends "Open Pingolin to refuse", the
        // circle transfers to them on silence fourteen days later, and every
        // other branch would land this tap somewhere with no refuse control
        // on it — including the pending-invite fallback at the bottom, which
        // claims unrouted taps outright. Matched on `alert_type`, which the
        // push relay forwards on APNs.
        //
        // The circle does not have to be ON the push — see resolveCircleId. The
        // match is on `alert_type` alone, so a claim push whose circle cannot
        // be named is still claimed by this branch instead of falling through
        // to the invite fallback, which is the outcome this branch exists to
        // prevent.
        //
        // The claimant's "your request was refused" shares the branch for its
        // circle: its alert_id is the claim, which its row repeats. It opens
        // the circle itself, not the claim's screen, which is the owner's.
        if let takeover = Self.takeoverTap(alertType: alertType, kind: kind) {
            Task { @MainActor in
                // A push from an older server that still carries the id wins
                // — same precedence the destination branch below uses. The
                // row is consulted only when the payload cannot answer, which
                // with the current server is every time.
                let pushCircleId = userInfo["circle_id"] as? String
                let claimCircleId = Self.claimCircleId(
                    fromPush: pushCircleId,
                    orRow: pushCircleId?.isEmpty == false
                        ? nil
                        : await Self.resolveCircleId(correlationId: correlationId)
                )
                // Same cold-launch settling delay as the invite path: an
                // extremely early tap can otherwise be raced by MainTabView's
                // first render initialising the binding.
                try? await Task.sleep(nanoseconds: 200_000_000)
                TabSelectionState.shared.selected = 0
                if let claimCircleId {
                    switch takeover {
                    case .claimScreen:
                        NotificationRouteState.shared.pending = .ownershipClaim(circleId: claimCircleId)
                        Self.writeNotifDiag("tap routed→ownership claim \(claimCircleId.prefix(8))")
                    case .circle:
                        NotificationRouteState.shared.pending = .circle(circleId: claimCircleId)
                        Self.writeNotifDiag("tap routed→circle (takeover refused) \(claimCircleId.prefix(8))")
                    }
                } else {
                    // Neither the push nor the row could name the circle —
                    // offline, or the row has already aged off the first page.
                    // The notifications list is the one fallback that still
                    // reaches the refuse control: its `circle_ownership_claim`
                    // row reads `circleId` off the row and opens the same
                    // sheet. One extra tap, rather than nowhere.
                    NotificationRouteState.shared.pending = .notifications
                    Self.writeNotifDiag("tap routed→Notifications (claim, circle unresolved)")
                }
                completionHandler()
            }
            return
        }

        // "<name> needs attention", or one of its follow-ups: the tap opens the
        // alert, as tapping its row on the Alerts tab does. Otherwise it would
        // reach the fallback at the bottom, which leaves the person on whatever
        // tab is open, or moves them to Circles when an invitation is pending.
        // Matched on the kind alone, ahead of the copy sniffs: the banner's
        // title is a person's name, which can hold any word.
        let tapKind = Self.pushKind(from: userInfo)
        if let tapKind, SOSAlarmCopy.newAlertTypes.contains(tapKind) || SOSAlarmCopy.followUpTypes.contains(tapKind) {
            let sosId = (userInfo["sos_id"] as? String) ?? correlationId
            Task { @MainActor in
                await Self.openAlert(kind: tapKind, sosId: sosId)
                completionHandler()
            }
            return
        }

        if isDestination {
            Task { @MainActor in
                // Refresh so the list + map are current when we resolve
                // (the push carries only ids, no decrypted content).
                await DestinationsManager.shared.refresh()
                await NotificationsManager.shared.refresh()
                // Read the routing ids back out of THIS event's stored row. They
                // are not on the push — see resolveRoutingIds — and a push from
                // an older server that still carries them wins.
                let resolved = await Self.resolveRoutingIds(correlationId: correlationId)
                // Same cold-launch settling delay as the invite path.
                try? await Task.sleep(nanoseconds: 200_000_000)
                TabSelectionState.shared.selected = 0

                if isDestinationIdentifier {
                    // Our own local "You've arrived!" — the personalised
                    // record lives in the notifications list. Mirrors
                    // the Android app (self-arrival stays on the list).
                    NotificationRouteState.shared.pending = .notifications
                    Self.writeNotifDiag("tap routed→Notifications (self-arrival)")
                } else if alertType == "destination_arrival", let uid = pushArrivedUserId ?? resolved.arrivedUserId {
                    // Someone else arrived → focus their member marker (labeled
                    // "At <Place>"). The Android app zooms to the destination; iOS
                    // focuses the member, the more useful target once they're there.
                    NotificationRouteState.shared.pending = .focusMember(userId: uid)
                    Self.writeNotifDiag("tap routed→focus member \(uid.prefix(8))")
                } else if alertType == "destination_shared",
                          let did = pushDestinationId ?? resolved.destinationId,
                          let dest = DestinationsManager.shared.destinations.first(where: { $0.id == did }) {
                    // A shared destination → zoom the map to its pin.
                    NotificationRouteState.shared.pending = .focusCoordinate(dest.coordinate)
                    Self.writeNotifDiag("tap routed→zoom destination \(did.prefix(8))")
                } else {
                    // A push without resolvable ids (copy-sniffed) → the
                    // notifications list.
                    NotificationRouteState.shared.pending = .notifications
                    Self.writeNotifDiag("tap routed→Notifications (no ids)")
                }
                completionHandler()
            }
            return
        }

        if isInvite {
            Task { @MainActor in
                // Make sure the invite list is fresh in case the
                // tap happened on a stale local notification (e.g.,
                // the inviter declined a different one in the
                // meantime). Then jump to the Circles tab.
                await InvitesManager.shared.refresh()
                // Tiny dispatch delay so the cold-launch SwiftUI
                // hierarchy has fully bound TabSelectionState
                // before we write to it — without this, an
                // extremely-early tap (~100ms after didFinishLaunch)
                // could be raced by MainTabView's first render
                // initialising the binding with the @AppStorage
                // value before our write lands.
                try? await Task.sleep(nanoseconds: 200_000_000)
                TabSelectionState.shared.selected = 1
                Self.writeNotifDiag("tap routed→Circles tab")
                completionHandler()
            }
            return
        }

        // Last-resort fallback: an unrouted notification tap when
        // there's exactly one obvious pending action. If the
        // InvitesManager has pending invites and nothing else
        // claims the tap, it's almost certainly an invite push
        // the server didn't tag for us. Refresh first so we
        // don't route based on stale state.
        //
        // The refresh itself is keychain-gated (not flag-gated)
        // so it works on a cold-launch tap that fires before
        // checkExistingSession flips AuthManager.isAuthenticated.
        // We also retry the refresh briefly when it returns empty
        // on the very first attempt — the cold-launch race can
        // mean the keychain rehydrate is mid-flight when we land
        // here.
        Task { @MainActor in
            await InvitesManager.shared.refresh()
            var attempts = 1
            while InvitesManager.shared.invites.isEmpty && attempts < 5 {
                try? await Task.sleep(nanoseconds: 300_000_000)
                await InvitesManager.shared.refresh()
                attempts += 1
            }
            Self.writeNotifDiag(
                "fallback after=\(attempts) invites=\(InvitesManager.shared.invites.count)"
            )
            if !InvitesManager.shared.invites.isEmpty {
                try? await Task.sleep(nanoseconds: 200_000_000)
                TabSelectionState.shared.selected = 1
                Self.writeNotifDiag("tap routed→Circles tab (fallback: pending invites exist)")
            }
            completionHandler()
        }
    }

    /// Where a tap on an alert's notification lands.
    enum AlertTapTarget: Equatable {
        /// The map, flown to the alert with its detail open.
        case map(alertId: String)
        /// The Alerts tab.
        case alertsTab
    }

    /// Pure: what tapping the alert's row on the Alerts tab does. Someone else's
    /// live alert, listed here with a position, opens on the map. Anything else
    /// opens the Alerts tab, where alerts and their state are: one not listed
    /// (yet), one with no position, your own, and the follow-ups ("… is
    /// responding", "… closed the alert"). nil: not a notification about an alert.
    static func alertTapTarget(kind: String?, alertId: String?, listed: [SOSAlert], me: String?) -> AlertTapTarget? {
        guard let kind else { return nil }
        if SOSAlarmCopy.followUpTypes.contains(kind) { return .alertsTab }
        guard SOSAlarmCopy.newAlertTypes.contains(kind) else { return nil }
        guard let alert = listed.first(where: { CanonicalId.same($0.id, alertId) }), alert.status.isLive,
              !CanonicalId.same(alert.userId, me), alert.coordinate != nil else { return .alertsTab }
        return .map(alertId: alert.id)
    }

    /// Opens what an alert's notification is about (`alertTapTarget`). A tap can
    /// launch the app, so the launch's session check answers first, and nothing
    /// opens without a session: the sign-in screen is what shows then, and no
    /// route is left waiting for whoever signs in next. An alert that isn't
    /// listed yet is loaded once.
    @MainActor
    static func openAlert(kind: String, sosId: String?) async {
        var waited = 0
        while AuthManager.shared.isCheckingSession && waited < 40 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            waited += 1
        }
        guard !AuthManager.shared.isCheckingSession, AuthManager.shared.isAuthenticated else {
            writeNotifDiag("tap alert: no session")
            return
        }
        let sos = SOSManager.shared
        var target = alertTapTarget(kind: kind, alertId: sosId, listed: sos.visibleAlerts, me: AuthManager.shared.userId)
        if target == .alertsTab, SOSAlarmCopy.newAlertTypes.contains(kind) {
            try? await sos.loadActiveAlerts()
            target = alertTapTarget(kind: kind, alertId: sosId, listed: sos.visibleAlerts, me: AuthManager.shared.userId)
        }
        // Same cold-launch settling delay as the invite path.
        try? await Task.sleep(nanoseconds: 200_000_000)
        switch target {
        case .map(let alertId)?:
            TabSelectionState.shared.selected = 0
            NotificationRouteState.shared.pending = .focusAlert(alertId: alertId)
            writeNotifDiag("tap routed→alert on the map")
        case .alertsTab?:
            TabSelectionState.shared.selected = 2
            writeNotifDiag("tap routed→Alerts tab")
        case nil:
            break
        }
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { @MainActor in
            await PushNotificationManager.shared.register(deviceToken: deviceToken)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        Task { @MainActor in
            PushNotificationManager.shared.registrationFailed(error)
        }
    }
    /// The routing ids for a tap, resolved from the stored notification row.
    ///
    /// The push deliberately carries neither `destination_id` nor
    /// `arrived_user_id`: both are stable identifiers — one of them for a
    /// person — and everything on a payload is handed to Apple. What it does
    /// carry is `alert_id`, a value minted per EVENT, which the matching row
    /// repeats in `metadata.event_id`. So the ids come back over this app's own
    /// authenticated connection, and the relay only ever sees something that
    /// identifies one thing that happened rather than a lasting thing.
    ///
    /// Exact match on that correlation id, never "the newest destination row": two
    /// arrivals landing together would make a guess route to the wrong one, and a
    /// tap that opens the wrong place is worse than a tap that opens the list.
    ///
    /// Returns nils when the row cannot be found — offline, or already read and
    /// paged out — and the caller falls back to the notifications list.
    @MainActor
    static func resolveRoutingIds(correlationId: String?) async -> (destinationId: String?, arrivedUserId: String?) {
        guard let correlationId, !correlationId.isEmpty else { return (nil, nil) }
        await NotificationsManager.shared.refresh()
        let ids = Self.routingIds(
            from: NotificationsManager.shared.notifications,
            correlationId: correlationId
        )
        if ids.destinationId == nil && ids.arrivedUserId == nil {
            Self.writeNotifDiag("tap resolve miss correlation=\(correlationId.prefix(8))")
        }
        return ids
    }

    /// The matching half of [resolveRoutingIds], without the network.
    ///
    /// Pure so the rule that matters can be tested: the row is chosen by an EXACT
    /// correlation match, never by recency. Two destination events landing together
    /// is the ordinary case this has to survive, and picking the newest would open
    /// the wrong place — worse than opening the list.
    static func routingIds(
        from rows: [NotificationResponse],
        correlationId: String
    ) -> (destinationId: String?, arrivedUserId: String?) {
        let row = rows.first { row in
            if case .string(let eventId)? = row.metadata?["event_id"] {
                return eventId == correlationId
            }
            return false
        }
        guard let row else { return (nil, nil) }
        var destinationId: String?
        var arrivedUserId: String?
        if case .string(let v)? = row.metadata?["destination_id"] { destinationId = v }
        if case .string(let v)? = row.metadata?["arrived_user_id"] { arrivedUserId = v }
        return (destinationId, arrivedUserId)
    }

    /// Which circle a `circle_ownership_claim` tap should open.
    ///
    /// The payload first, so a push from a server that still forwards
    /// `circle_id` routes with no round-trip; the row is what keeps the tap
    /// working when the push carries none.
    ///
    /// An empty string is not a value: an empty `circle_id` taken as present
    /// would not merely fail to route — it would drop the tap through to the
    /// pending-invite fallback at the bottom, which claims unrouted taps
    /// outright. Normalising here keeps that decision in one testable place.
    ///
    /// Pure and `static` for the same reason as its neighbours: the failure it
    /// guards against is invisible from the server and silent on the client.
    static func claimCircleId(fromPush pushValue: String?, orRow rowValue: String?) -> String? {
        for candidate in [pushValue, rowValue] {
            if let candidate, !candidate.isEmpty { return candidate }
        }
        return nil
    }

    /// What a tap on a takeover push opens once its circle is known.
    enum TakeoverTap: Equatable {
        /// The claim: that circle's ownership screen, where the owner's refuse
        /// control is.
        case claimScreen
        /// The claimant's "your request was refused": the circle itself.
        case circle
    }

    /// The takeover pushes, by `alert_type` (what the push relay forwards),
    /// else `type`; nil for any other push.
    static func takeoverTap(alertType: String?, kind: String?) -> TakeoverTap? {
        for type in [alertType, kind] {
            switch type {
            case "circle_ownership_claim"?: return .claimScreen
            case "circle_ownership_refused"?: return .circle
            default: continue
            }
        }
        return nil
    }

    /// The circle a stored notification names, resolved from the row instead of
    /// the push.
    ///
    /// A circle id on a push is handed to the relay beside the device token. It
    /// is stable for the life of the circle AND shared across several device
    /// tokens, so what a relay would get is not a per-object handle but a
    /// household — the same reason `destination_id`, `arrived_user_id` and
    /// `route_id` stay off the push: a stable id recurring in a relay's logs
    /// beside a device token reconstructs a routine. Resolving it from the row
    /// lets the `circle_ownership_claim` deep link work without it. The Android
    /// app does the same: `NotificationTickleFetcher` reads `notif.circleId` off
    /// the fetched row and puts it INTO the alert data.
    ///
    /// Same mechanism as [resolveRoutingIds]: correlate on `alert_id`, minted
    /// per EVENT, and fetch the lasting id over this app's own authenticated
    /// connection. Returns nil when the row cannot be found — offline, or aged
    /// off the first page — and the caller falls back to the notifications
    /// list.
    @MainActor
    static func resolveCircleId(correlationId: String?) async -> String? {
        guard let correlationId, !correlationId.isEmpty else { return nil }
        await NotificationsManager.shared.refresh()
        let resolved = Self.circleId(
            from: NotificationsManager.shared.notifications,
            correlationId: correlationId
        )
        if resolved == nil {
            Self.writeNotifDiag("tap circle resolve miss correlation=\(correlationId.prefix(8))")
        }
        return resolved
    }

    /// The matching half of [resolveCircleId], without the network.
    ///
    /// Pure so the rule that matters can be tested: EXACT correlation, never
    /// "the newest claim". An owner with two circles under claim at once is
    /// unusual but not impossible, and guessing would open the refuse control
    /// for the wrong circle — which is worse than opening the list, because the
    /// owner would refuse a claim they were not asked about and leave the real
    /// one running.
    ///
    /// Three correlation keys because different families stamp `alert_id`
    /// differently and only the row knows which: a claim push sends the
    /// `claim_id` the row repeats in `metadata.claim_id` (the server writes
    /// both), destinations use `metadata.event_id`, and a row id is accepted
    /// last for anything that pushes its own notification id. Ids are UUIDs,
    /// so testing three keys costs nothing and mismatching one of them is a
    /// silent routing failure.
    static func circleId(from rows: [NotificationResponse], correlationId: String) -> String? {
        let row = rows.first { row in
            if case .string(let claimId)? = row.metadata?["claim_id"], claimId == correlationId {
                return true
            }
            if case .string(let eventId)? = row.metadata?["event_id"], eventId == correlationId {
                return true
            }
            return row.id == correlationId
        }
        guard let circleId = row?.circleId, !circleId.isEmpty else { return nil }
        return circleId
    }

    /// Which family a push belongs to.
    ///
    /// `alert_type` is the fallback that makes the dispatch reachable at all.
    /// The push relay forwards an explicit allowlist of keys to APNs and `type`
    /// is NOT on it — it is an FCM-side dispatch key that never crosses to
    /// Apple. So `userInfo["type"]` is always nil on a real device, and without
    /// `alert_type` every case would fall through to `default` and nothing
    /// typed would run: no tickle refresh, no wake_location, no member_joined.
    /// `type` stays first so an FCM-shaped payload keeps working unchanged.
    ///
    /// Pure, and `static`, so the resolution order can be tested without a device —
    /// the failure it guards against is invisible from the server and silent on the
    /// client.
    static func pushKind(from userInfo: [AnyHashable: Any]) -> String? {
        (userInfo["type"] as? String)
            ?? (userInfo["aps"] as? [String: Any]).flatMap { $0["type"] as? String }
            ?? (userInfo["alert_type"] as? String)
    }

    /// The families whose banner only this device can improve on, so a push in one
    /// of them asks the app to wake and evaluate. All three emitted forms: the
    /// directional pair the server sends as pushes, plus the bare `place_alert` the
    /// stored notification row carries. Must stay in step with the push relay's
    /// wake rule, which decides whether the wake is even sent.
    static let placeCrossingKinds: Set<String> = [
        "place_alert", "place_alert_enter", "place_alert_exit",
    ]


    /// Silent-push entry point. Routes by `type`:
    ///
    ///  - `wake_location` — the server's stale-device task sends
    ///    `apns-push-type: background` + `aps.content-available: 1` +
    ///    `{type: "wake_location"}` whenever this device's last-seen
    ///    time drifts past its threshold. We grab a fresh fix and
    ///    send it.
    ///
    ///  - `member_joined` — fired to every existing circle member when
    ///    an invitee accepts. The new member has no wrapped circle
    ///    key yet, so an eligible rotator (owner / anyone with
    ///    `can_rotate_keys`) needs to rotate. Without this branch the
    ///    invitee stays stuck on "Circle (key unavailable)" until the
    ///    owner manually opens Circles and refreshes. Mirrors
    ///    the Android app's AlertHandler.handleMemberJoined.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        // `alert_type` is the fallback that makes this switch reachable at all.
        //
        // The push relay forwards an explicit allowlist of keys to APNs and `type`
        // is NOT on it — it is an FCM-side dispatch key that never crosses to
        // Apple. So `userInfo["type"]` is always nil here, and without
        // `alert_type` every case would fall through to `default` and nothing
        // below would run on a real device: no tickle refresh, no wake_location,
        // no member_joined. `alert_type` IS forwarded, carries the same value, and
        // is already what NotificationService and the foreground path key on.
        // PlaceAlertEvaluator uses this same fallback.
        //
        // `type` stays first so an FCM-shaped payload keeps working unchanged.
        let kind = Self.pushKind(from: userInfo)
        switch kind {
        case "alerts_check":
            // Client-evaluated alerts. Emptier than a tickle: a tickle means a
            // notification is waiting to be fetched, this means only "look at
            // your own data". Nothing has been decided — the server holds no
            // threshold and no decrypted target — so the evaluation runs here
            // and shows the user nothing unless one of THIS device's rules
            // matches. Being woken and finding nothing is the ordinary case.
            //
            // One pass, with the rule lists re-fetched first: the monitor reuses
            // them for up to an hour in the background, and this push is the
            // server telling us something changed. The pass also shares each
            // circle's location fetch across the three evaluators.
            //
            // The same silent push also says a circle may need this device: a
            // member asked for a fresh copy, a member owed the circle was
            // admitted, a newcomer is still waiting — or this device was just
            // handed the circle. The light refresh takes a delivered copy and
            // delivers what this device may.
            Task { @MainActor in
                if AuthManager.shared.isAuthenticated {
                    try? await CircleManager.shared.loadCircles(light: true)
                    // The wake also means "your invitation was renewed" — an
                    // invitation this person already said yes to is joined now,
                    // by itself.
                    if InvitesManager.shared.waitsForRenewal {
                        await InvitesManager.shared.refresh()
                    }
                    // Or "another of your devices can't use your personal copy".
                    // A device that holds the key looks now — adopt, flag or
                    // republish by the SDK's verdict. It never mints: only a
                    // held key is checked.
                    if let me = AuthManager.shared.userId,
                       SDKCrypto.cryptoManager.hasCircleKey(circleId: SelfKeyManager.selfCircleUuid) {
                        await SelfKeyManager.checkServerCopy(userId: me, force: true)
                    }
                }
                await MonitoringManager.shared.evaluateForAlertsCheck()
                completionHandler(.newData)
            }
        case "identities_check":
            // The account restored an identity from before a password reset in
            // the portal. Only the type is read: the re-check is the ordinary
            // signed-in fetch and SDK import, it only adds, and at most one runs
            // every 3 minutes however many of these arrive.
            Task { @MainActor in
                await CircleManager.shared.recheckPreviousIdentities()
                completionHandler(.newData)
            }
        case "privacy_check":
            // This account's privacy for some circle changed: here, on another
            // device, or a timed pause that ended. It names nothing (a circle id
            // would tell APNs which circle was paused, and when). One light
            // circle load refreshes every circle's row, so the send gates and the
            // record of when this account was not sharing (`CirclePauseRecord`)
            // have it now, not at the next refresh. Silent: nothing is shown.
            // Answered within the wake's budget.
            Self.answer(completionHandler) { await Self.refreshPrivacy() }
        case "privacy_resumed":
            // A timed pause of this account's ended. iOS has shown the server's
            // own words already ("Location Sharing Resumed"); the app refreshes
            // the rows at once, and the bell, which holds the same notice.
            Self.answer(completionHandler) {
                await Self.refreshPrivacy()
                await NotificationsManager.shared.refresh()
            }
        case "wake_location":
            // No background task is scheduled here: a processing task that
            // does no work only buys a system wake. The in-line send below
            // is the path.
            Task { @MainActor in
                let result = await Self.handleWakeLocation()
                completionHandler(result)
            }
        case "member_joined":
            let circleId = (userInfo["circle_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            Task { @MainActor in
                let result = await Self.handleMemberJoined(circleId: circleId)
                completionHandler(result)
            }
        case "circle_invite", "invite":
            // An invite push is an alert AND a wake. The alert is on
            // screen already — the server's generic copy, or the names
            // if the Notification Service Extension's fetch succeeded.
            // Here the app, which can refresh its session, fetches the
            // pending invite and quietly upgrades a still-generic
            // banner; for a silent push it posts the banner itself.
            Task { @MainActor in
                await InvitesManager.shared.refresh()
                await Self.postLocalInviteNotification(userInfo: userInfo)
                completionHandler(.newData)
            }
        case "sos_refresh":
            // The server re-sealed an open SOS under a new key (its raiser's
            // device did, after a rotation). Data-only and quiet: refetch and let
            // the receiver rules decide; no receipt (no new alert), and no sound
            // of its own.
            Task { @MainActor in
                try? await SOSManager.shared.loadActiveAlerts(quiet: true)
                completionHandler(.newData)
            }
        case "sos_alert", "sos", "sos_acknowledged", "sos_resolved":
            // Pull the alert itself in BEFORE the user can tap anything, so
            // the map marker and list entry already exist when they arrive.
            // The ack/resolve types come through here too, because reloading
            // is also what clears an alert somebody else has closed.
            //
            // Only a NEW alert reports a receipt: an ack or resolve push is a
            // different notification about the same alert, and confirming on it
            // would credit the original with a delivery it may never have had.
            let isNewAlert = kind == "sos_alert" || kind == "sos"
            let sosId = (userInfo["sos_id"] as? String)
                ?? (userInfo["alert_id"] as? String)
            Task { @MainActor in
                // Tell the server the push landed, so the person who sent it
                // can be told whether anyone got it. Fired here — on the push
                // path — and nowhere else: reporting a receipt after learning
                // about an alert by polling would confirm a notification that
                // never arrived.
                if isNewAlert, let sosId, !sosId.isEmpty {
                    await SOSManager.shared.reportReceipt(alertId: sosId)
                }
                try? await SOSManager.shared.loadActiveAlerts()
                await NotificationsManager.shared.refresh()
                completionHandler(.newData)
            }
        case let k? where Self.placeCrossingKinds.contains(k):
            // The banner iOS is already showing carries the SERVER's copy — "A
            // family member arrived at a saved location" — because the place name
            // and the member's display name are E2EE and it holds neither. Only
            // this device can name them, and only by evaluating the crossing
            // against locations it decrypts itself.
            //
            // So the push is not the notification here, it is the trigger: refresh
            // the circle it names, which runs the subscriber-side evaluator through
            // CircleManager.loadMemberLocations, and let THAT replace the delivered
            // banner with "Sam arrived at Home". PlaceAlertEvaluator reuses the
            // identifier the system reports as delivered, so the generic copy is
            // upgraded in place rather than joined by a second notification.
            //
            // Reachable because the push carries content-available alongside its
            // alert; without it this family would fall to `default`, which
            // refreshes the bell and never touches member locations.
            //
            // Failing to reproduce the crossing costs nothing: the server's banner
            // is already on screen and simply stays as it is. That is the safe
            // direction, and the reason this does no work to suppress it.
            let circleId = (userInfo["circle_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            Task { @MainActor in
                // Debug-only breadcrumb, and the only way to tell "the wake never
                // fired" apart from "it fired and found nothing to say" — which are
                // indistinguishable from outside and have opposite fixes. Records
                // what the tray already holds too, since a delivered place alert is
                // what this wake exists to REPLACE. No-op in release builds.
                #if DEBUG
                let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
                let tray = delivered.map { note -> String in
                    let info = note.request.content.userInfo
                    let t = (info["type"] as? String) ?? (info["alert_type"] as? String) ?? "?"
                    return "\(note.request.identifier):\(t)"
                }
                Self.writeNotifDiag(
                    "place.wake kind=\(kind ?? "?") circle=\(circleId ?? "none") tray=[\(tray.joined(separator: ","))]"
                )
                #endif
                if let circleId {
                    // surfaceFailures: false — see loadMemberLocations. This runs
                    // off-screen for a circle the PAYLOAD names, so a failure here
                    // must not leave "Couldn't reach server" sitting on the user's
                    // map: a push carrying an unknown circle id would paint the
                    // pill, and it would stay until a later refresh cleared it.
                    try? await CircleManager.shared.loadMemberLocations(
                        for: circleId,
                        surfaceFailures: false
                    )
                }
                // The bell list still has to catch up either way — the row exists
                // server-side whether or not local evaluation could name it.
                await NotificationsManager.shared.refresh()
                completionHandler(.newData)
            }
        case "destination_shared", "destination_arrival", "tickle":
            // Refresh BEFORE the user can tap anything so the map /
            // list / bell are current — the push transport is
            // content-free by design. `tickle` is the generic "new
            // bell content" signal the server sends for every
            // alert family; refreshing the bell list also
            // personalises any new destination rows. Mirrors the
            // Android app's TrackFirebaseMessagingService
            // destination-tickle path. What each kind refreshes is
            // `refreshPlan(for:)`: a tickle names no family, so it still
            // refreshes all three, while a named destination push does not
            // also reload SOS.
            Task { @MainActor in
                await Self.runRefreshPlan(Self.refreshPlan(for: kind))
                completionHandler(.newData)
            }
        case .none:
            // No type of any kind — nothing to act on, but tell the OS we
            // processed it so it stays willing to wake us later.
            completionHandler(.noData)
        default:
            // Some alert family with no typed branch above. `kind` resolves
            // from `alert_type`, so these arrive under their own name
            // rather than as the generic "tickle", and the generic refresh
            // has to live here or a place alert / SOS / low battery would
            // wake the app and leave the bell stale — which is what the
            // tickle case is for. Unlike a tickle, the family IS known
            // here, so the refresh is narrowed to it (`refreshPlan(for:)`):
            // a check-in or low-battery push refreshes the bell, not
            // destinations and SOS as well.
            Task { @MainActor in
                await Self.runRefreshPlan(Self.refreshPlan(for: kind))
                completionHandler(.newData)
            }
        }
    }

    /// A privacy change somewhere (`privacy_check`, `privacy_resumed`): one
    /// light circle load refreshes every circle's row (`my_privacy`), which
    /// is all the send gates read, inside the wake's background time. A switch
    /// to approximate then sends one fresh, coarsened fix.
    @MainActor
    static func refreshPrivacy() async {
        guard AuthManager.shared.isAuthenticated else { return }
        let before = CircleManager.shared.privacySettings
        try? await CircleManager.shared.loadCircles(light: true)
        await CircleManager.shared.sendFreshFixIfNewlyApproximate(before: before)
    }

    /// How long a privacy wake runs before its push is answered. iOS gives a
    /// background push about 30 s, and an answer after that costs the app
    /// later wakes; the light refresh (each request up to the API's 30 s) and a
    /// fresh fix (up to 15 s) can take longer, and go on while iOS lets them.
    nonisolated static let wakeBudget: TimeInterval = 25

    /// Runs `work` and answers the push once: when it is done, or at `budget`,
    /// whichever comes first.
    static func answer(_ completionHandler: @escaping (UIBackgroundFetchResult) -> Void,
                       within budget: TimeInterval = wakeBudget, after work: @escaping @MainActor () async -> Void) {
        let once = AnswerOnce(completionHandler)
        Task { @MainActor in
            await work()
            once.answer(.newData)
        }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(budget * 1_000_000_000))
            once.answer(.newData)
        }
    }

    /// A push's completion handler, called at most once, whichever task asks.
    final class AnswerOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var handler: ((UIBackgroundFetchResult) -> Void)?

        init(_ handler: @escaping (UIBackgroundFetchResult) -> Void) { self.handler = handler }

        func answer(_ result: UIBackgroundFetchResult) {
            lock.lock()
            let handler = self.handler
            self.handler = nil
            lock.unlock()
            handler?(result)
        }
    }

    /// What a push asks the app to re-fetch.
    struct RefreshPlan: OptionSet, Equatable {
        let rawValue: Int
        static let destinations = RefreshPlan(rawValue: 1 << 0)
        static let bell = RefreshPlan(rawValue: 1 << 1)
        static let sos = RefreshPlan(rawValue: 1 << 2)
    }

    /// The refreshes a content-free push of `kind` warrants, rather than every
    /// push refreshing destinations, the bell and SOS — three GETs and two
    /// cache writes — whatever it was about. The bell is always refreshed:
    /// every family writes a notification row. Destinations only for the
    /// destination families, SOS only for SOS-shaped ones. The generic
    /// `tickle` (and an unnamed push) says nothing about its family, so it still
    /// gets everything — including SOS, because the backend sends a tickle for
    /// every family and a tickle-only transport delivers no typed SOS push.
    nonisolated static func refreshPlan(for kind: String?) -> RefreshPlan {
        guard let kind, kind != "tickle" else { return [.destinations, .bell, .sos] }
        if kind.hasPrefix("destination") { return [.destinations, .bell] }
        // `emergency` is an SOS family on the server (the push relay sends it at
        // high priority with the other SOS kinds) that has no typed case above.
        if kind.hasPrefix("sos") || kind == "emergency" { return [.bell, .sos] }
        return [.bell]
    }

    @MainActor
    private static func runRefreshPlan(_ plan: RefreshPlan) async {
        if plan.contains(.destinations) { await DestinationsManager.shared.refresh() }
        if plan.contains(.bell) { await NotificationsManager.shared.refresh() }
        if plan.contains(.sos) { try? await SOSManager.shared.loadActiveAlerts() }
    }

    /// One-shot foreground-style fetch + envelope send. Runs
    /// inside the background-push grace window (~25s of wall
    /// clock); returns a UIBackgroundFetchResult so the OS can
    /// keep its push-budget bookkeeping accurate.
    @MainActor
    /// Take one fix and stream it to `circleId`, honouring that circle's
    /// privacy posture.
    ///
    /// Shared by `wake_location` and `member_joined` so the privacy gate and the
    /// CLLocation → SDK mapping exist once, and the two can never disagree about
    /// whether a paused circle gets a fix.
    ///
    /// `tag` only names the caller in the log line.
    private static func sendCurrentLocation(to circleId: String, tag: String) async -> UIBackgroundFetchResult {
        // Respect the per-circle privacy gate (pause / realtime-off) that
        // syncLocation enforces. Without it a background wake uploads an exact
        // fix to a circle the user paused, which becomes visible to members
        // once the pause ends.
        // Prime-on-miss: on a cold wake the loadCircles fan-out may not have
        // populated this circle's privacy setting yet — without priming the gate
        // fails closed and the wake location is silently dropped.
        guard await CircleManager.shared.mayStreamRealtimePrimed(to: circleId) else { return .noData }

        do {
            let location = try await wakeFix()
            // Also what the liveness check-in re-sends, when newer (`adoptSentFix`).
            LocationService.shared.adoptSentFix(location)
            // The one builder for a single send, battery level included, shared
            // with "Send location" and the refresh at coming to the front, so no
            // copy can leave the level out.
            let sdkLocation = PingolinTrackSDK.Location.forSend(location)
            try? SDKLocationStreamer.shared.send(circleId: circleId, location: sdkLocation)
            return .newData
        } catch {
            print("[Track] \(tag): location/send failed: \(error)")
            // Report .failed so iOS knows the in-line attempt did not produce
            // data this time. The resident poller and the next wake are the
            // retry; there is no background task behind this.
            return .failed
        }
    }

    /// The fix a wake sends: the one the poller already holds when it is fresh
    /// and good enough, otherwise a new one.
    ///
    /// A resident app has usually taken a fix within the last few minutes;
    /// ignoring it would start a fresh Best-accuracy request — up to ten
    /// seconds of GPS for a position the app already had.
    @MainActor
    private static func wakeFix() async throws -> CLLocation {
        let saver = UserSettings.shared.batterySaverEnabled
        let accepted = (saver ? LocationService.TrackingConfig.batterySaver
                              : LocationService.TrackingConfig.highAccuracy).acceptedAccuracy
        if let cached = LocationService.shared.currentLocation,
           isReusableWakeFix(cached, acceptedAccuracy: accepted, now: Date()) {
            return cached
        }
        return try await LocationService.shared.requestSingleLocation()
    }

    /// How old a held fix may be and still answer a wake.
    nonisolated static var wakeFixMaxAge: TimeInterval { 120 }

    nonisolated static func isReusableWakeFix(
        _ fix: CLLocation, acceptedAccuracy: CLLocationAccuracy, now: Date
    ) -> Bool {
        guard fix.horizontalAccuracy >= 0, fix.horizontalAccuracy <= acceptedAccuracy else { return false }
        let age = now.timeIntervalSince(fix.timestamp)
        return age >= 0 && age <= wakeFixMaxAge
    }

    private static func handleWakeLocation() async -> UIBackgroundFetchResult {
        guard AuthManager.shared.isAuthenticated else { return .noData }

        // Evaluate place alerts on this wake too, and BEFORE the activeCircle
        // guard below — the fetch is per place-alert circle and does not care which
        // circle the UI happens to be showing.
        //
        // This is what covers the watcher who shares no location of their own: no
        // background residency means no 900 s timer and no locationUpdates sink, so
        // between app opens nothing evaluates a place alert about somebody else. And
        // such a watcher is exactly who this push already reaches, because the
        // server picks its targets by stale `last_seen_at` and a non-uploader is
        // permanently stale. No new push, no new server knowledge.
        //
        // The cold-launch case is covered separately, by arming the evaluation loop
        // in `didFinishLaunchingWithOptions` — deliberately, because the
        // `isAuthenticated` guard above is false until `checkExistingSession` runs,
        // and that happens from the root view's `onAppear`, which a headless wake
        // never reaches.
        await MonitoringManager.shared.refreshPlaceAlertsOnWake()

        guard let circle = CircleManager.shared.activeCircle else { return .noData }
        return await sendCurrentLocation(to: circle.id, tag: "wake_location handler")
    }

    /// Post a user-visible local notification when a silent
    /// circle-invite push lands. iOS doesn't surface
    /// `content-available` pushes as banners; without this the user
    /// sees the invite only after they open the app (Circles tab or
    /// Map banner).
    ///
    /// Two guards against duplicate notifications:
    ///
    ///  1. If the originating push already carried `aps.alert`,
    ///     iOS is showing its own banner — posting a second local
    ///     notification would just stack on top.
    ///  2. We embed a stable invite_id from the push payload in
    ///     the local notification's identifier when available, so
    ///     a retried push for the same invite replaces the
    ///     previous local notification instead of stacking.
    ///     Falls back to a UUID when invite_id is missing.
    ///
    /// Also stamps userInfo with `type: "circle_invite"` + the
    /// passthrough fields so the tap handler can route the same
    /// way regardless of whether the user tapped our local
    /// notification or the server's alert push directly.
    @MainActor
    private static func postLocalInviteNotification(userInfo: [AnyHashable: Any]) async {
        let content = UNMutableNotificationContent()
        // The push never carries names (they must not cross the relay); the
        // caller has just refreshed InvitesManager, so the pending invite for
        // this push's circle is what names the banner — the same source the
        // Notification Service Extension fetches for a server-shown alert.
        // Push-supplied fields still win when the push does carry them.
        let circleId = (userInfo["circle_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (userInfo["alert_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let pending = InvitesManager.shared.invites.map {
            InviteNotificationCopy.PendingInvite(
                id: $0.id, circleId: $0.circleId,
                circleName: $0.circleName, inviterDisplayName: $0.inviterDisplayName)
        }
        let picked = InviteNotificationCopy.pick(from: pending, circleId: circleId)
        let inviter = (userInfo["inviter_display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? picked?.inviterDisplayName
        let circleName = (userInfo["circle_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? picked?.circleName
        content.title = InviteNotificationCopy.title
        content.body = InviteNotificationCopy.body(
            inviter: inviter, circle: circleName,
            level: UserSettings.shared.notificationDetailLevel.rawValue)
        content.sound = .default
        var passthrough: [AnyHashable: Any] = ["type": "circle_invite"]
        if let inviteId = (userInfo["invite_id"] as? String) ?? picked?.id {
            passthrough["invite_id"] = inviteId
        }
        if let circleId = userInfo["circle_id"] {
            passthrough["circle_id"] = circleId
        }
        content.userInfo = passthrough

        // Stable identifier per invite when we have one — same
        // identifier replaces the previous notification rather
        // than appending a new row.
        let identifier: String
        if let inviteId = userInfo["invite_id"] as? String, !inviteId.isEmpty {
            identifier = "circle_invite_\(inviteId)"
        } else {
            identifier = "circle_invite_\(UUID().uuidString)"
        }
        let center = UNUserNotificationCenter.current()
        if hasAlertPayload(userInfo: userInfo) {
            // The server's banner is already on screen. If the extension
            // named it, leave it alone. If it is still the generic copy —
            // the extension's session token had expired — swap it for the
            // named version SILENTLY: no sound, passive interruption, so
            // nobody is buzzed twice for one invite; the lock-screen entry
            // simply reads correctly from then on.
            let delivered = await center.deliveredNotifications()
            let stale = delivered.filter { note in
                let info = note.request.content.userInfo
                let kind = (info["alert_type"] as? String) ?? (info["type"] as? String)
                guard kind == "circle_invite" else { return false }
                if let circleId, let alertId = info["alert_id"] as? String,
                   !alertId.isEmpty, alertId != circleId {
                    return false
                }
                return InviteNotificationCopy.isGeneric(body: note.request.content.body)
                    && note.request.content.body != content.body
            }
            guard !stale.isEmpty else {
                Self.writeNotifDiag("post.skip server banner already named id=\(identifier)")
                return
            }
            center.removeDeliveredNotifications(withIdentifiers: stale.map { $0.request.identifier })
            content.sound = nil
            content.interruptionLevel = .passive
            Self.writeNotifDiag("post.upgrade replaced \(stale.count) generic banner(s) id=\(identifier)")
        } else {
            Self.writeNotifDiag("post id=\(identifier)")
        }
        do {
            try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
        } catch {
            print("[Track] postLocalInviteNotification add() failed: \(error)")
        }
    }

    /// True when the APNs payload has any `aps.alert` content that
    /// iOS will surface as a banner on its own — alert dict with
    /// title/body/loc-key, or a string-style alert. Used to suppress
    /// our duplicate local notification.
    @MainActor
    private static func hasAlertPayload(userInfo: [AnyHashable: Any]) -> Bool {
        guard let aps = userInfo["aps"] as? [String: Any] else { return false }
        if let alertDict = aps["alert"] as? [String: Any] {
            return alertDict["title"] != nil
                || alertDict["body"] != nil
                || alertDict["loc-key"] != nil
        }
        return aps["alert"] is String
    }

    /// Append a single line to Documents/notif-diag-<nanos>.txt so
    /// the next log pull captures the notification tap path.
    /// Cheap, write-once-per-event; keeps the launch-time logging
    /// budget tiny.
    fileprivate static func writeNotifDiag(_ message: String) {
        // Debug builds only: some messages carry member/place names, and
        // Documents/ is backed up. No-op in release.
        #if DEBUG
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let stamp = UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
        let url = docs.appendingPathComponent("notif-diag-\(stamp).txt")
        try? LogRedaction.scrub(message).write(to: url, atomically: true, encoding: .utf8)
        #endif
    }

    /// React to a `member_joined` silent push, which the server fans out to
    /// every member when an invitee accepts. Refresh the circle list: each
    /// circle's member load confirms the newcomer from their signed invitation
    /// and hands them the circle through `PUT …/access` when this device may —
    /// a join causes no rotation. The wrap is made client-side in the SDK; the
    /// server only sees the sealed copy.
    @MainActor
    private static func handleMemberJoined(circleId: String?) async -> UIBackgroundFetchResult {
        guard AuthManager.shared.isAuthenticated else { return .noData }
        do {
            // The LIGHT load is all a join needs: the circle list (with the
            // `key_rotation_needed` flag the auto-rotation sweep acts on — the
            // sweep runs on both paths) and every circle's members and privacy.
            // The full load also does the historical key import, a pseudonym-backfill
            // POST per circle and a re-store of every key, none of which a
            // stranger joining changes.
            try await CircleManager.shared.loadCircles(light: true)
            print("[Track] member_joined handler: refreshed circles\(circleId.map { " (trigger: \($0))" } ?? "")")
        } catch {
            print("[Track] member_joined handler: loadCircles failed: \(error)")
            return .failed
        }

        // Then send a fix, so the new member sees a live marker instead of an
        // empty map until whenever this device next reports. The Android app does
        // the same (AlertHandler.handleMemberJoined, `send_location`).
        //
        // The circle id does NOT arrive in the push: the relay forwards only
        // [alert_type, alert_id, encrypted_occurred_at, occurred_at_nonce], and
        // `circle_id` stays off it because it is stable and shared across a
        // household's device tokens. So it is read from the notification ROW over
        // our own authenticated connection, which is what Android does too
        // (NotificationTickleFetcher puts `notif.circleId` into its alert data).
        // `circleId` above is only a hint from an FCM-shaped payload and is nil
        // on a real device.
        // Spelled out rather than `circleId ?? (await …)`: `??` takes an
        // autoclosure, which cannot be async.
        let target: String?
        if let circleId {
            target = circleId
        } else {
            target = await newestMemberJoinedCircleId()
        }
        guard let target else {
            print("[Track] member_joined handler: no circle id available, skipping location")
            return .newData
        }
        _ = await sendCurrentLocation(to: target, tag: "member_joined handler")
        return .newData
    }

    /// The circle of the most recent `member_joined` notification row.
    ///
    /// Only rows whose metadata says `send_location` — the server sets it on
    /// exactly this notification type, and reading it rather than assuming keeps
    /// this honest if that ever stops being unconditional.
    private static func newestMemberJoinedCircleId() async -> String? {
        do {
            let page = try await APIService.shared.listNotifications(limit: 20)
            let row = page.notifications.first { row in
                guard row.notificationType == "member_joined" else { return false }
                guard case .bool(true)? = row.metadata?["send_location"] else { return false }
                return row.circleId?.isEmpty == false
            }
            return row?.circleId
        } catch {
            print("[Track] member_joined handler: notification lookup failed: \(error)")
            return nil
        }
    }
}
