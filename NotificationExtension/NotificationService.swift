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
import UserNotifications
import PingolinTrackSDK
#if TRACK_TESTS
// The unit tests compile this file too, and reach the rules it shares with the
// app (`AccessHandover` and the rest) through the app module.
@testable import Track
#endif

/// Rewrites incoming APNs alerts before iOS displays them.
///
/// Four jobs: append a short local date + time to place and destination
/// alerts — "Tap to view · 7/28, 7:25 PM" — matching what the app already does
/// for the notifications it posts itself (`NotificationStamp` /
/// `PlaceAlertEvaluator.postNotification`); put the inviter's and circle's
/// names on a circle-invite banner at the user's detail level
/// (`InviteBannerRewriter`), fetched over the app's own connection; name who
/// checked in, who arrived where, or who is responding to a request to be
/// checked on, the same way (`NamedBanner`); and, on a
/// "New Circle Member" banner, hand the circle to whoever this device owes it
/// before showing who joined (`BackgroundHandover`).
///
/// Why an extension is needed at all: those server-sent alerts are displayed by
/// iOS directly, without the app process running, so nothing in the app can
/// touch their copy. A Notification Service Extension is the only hook.
///
/// It runs because the server sets `mutable-content: 1` whenever the push
/// carries data, and reads `sent_at`, a top-level custom key the server adds
/// to the same pushes.
///
/// The body itself stays whatever the server sent — deliberately
/// privacy-generic, because the server cannot decrypt E2EE content. This adds
/// only a timestamp, formatted here because only the device knows the user's
/// timezone and locale.
final class NotificationService: UNNotificationServiceExtension {

    /// Hands the banner to iOS exactly once: whichever gets there first, the
    /// work below or `serviceExtensionTimeWillExpire`.
    private var deliver: DeliverOnce?
    private var bestAttempt: UNMutableNotificationContent?

    /// How long the background handover may take before the banner is shown
    /// anyway. iOS allows a service extension about 30 seconds.
    static let handoverBudget: TimeInterval = 20

    /// Alert types that get a stamp. Place and destination only: an SOS banner
    /// should carry nothing but the emergency. Values match the alert types
    /// the server sends and the web client's service worker stamps.
    private static let stampedAlertTypes: Set<String> = [
        "place_alert",
        "place_alert_enter",
        "place_alert_exit",
        "place_arrival",
        "place_departure",
        "boundary_enter",
        "boundary_exit",
        "destination_shared",
        "destination_arrival",
        "route_arrival",
    ]

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        let deliver = DeliverOnce(contentHandler)
        self.deliver = deliver
        let mutable = request.content.mutableCopy() as? UNMutableNotificationContent
        bestAttempt = mutable

        guard let content = mutable else {
            deliver(request.content)
            return
        }

        let userInfo = content.userInfo
        let alertType = userInfo["alert_type"] as? String ?? ""
        // A new "Notify my circle" alert is checked before it rings,
        // and nothing else runs for it. The server's own banner stays the best
        // attempt: a phone that can't check (out of time, or this extension
        // cut short) rings with the server's alert.
        if SOSAlarmCopy.newAlertTypes.contains(alertType) {
            let level = UserDefaults(suiteName: ExtensionBridgeKeys.suite)?.string(forKey: ExtensionBridgeKeys.detailLevel)
            let original = content.copy() as? UNNotificationContent ?? content
            Task {
                let verdict = await SOSCheck.run(
                    alertId: userInfo["alert_id"] as? String, level: level,
                    deadline: Date().addingTimeInterval(SOSCheck.budget), env: .live, marks: .shared)
                if deliver(Self.sosBanner(for: original, verdict: verdict, level: level)) {
                    SOSCheck.noteRang(verdict, marks: .shared)
                }
            }
            return
        }
        // Its follow-ups never ring. Who is responding, and who closed
        // it, are named as the inbox names them; short of that, the
        // server's words.
        if SOSAlarmCopy.followUpTypes.contains(alertType) {
            content.sound = nil
            let level = UserDefaults(suiteName: ExtensionBridgeKeys.suite)?.string(forKey: ExtensionBridgeKeys.detailLevel)
            let alertId = userInfo["alert_id"] as? String
            let original = content.copy() as? UNNotificationContent ?? content
            Task {
                let banner = (original.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
                if let named = await NamedBanner.followUp(
                    alertType: alertType, alertId: alertId, level: level,
                    deadline: Date().addingTimeInterval(NamedBanner.budget), env: .live) {
                    banner.title = named.title
                    if let body = named.body { banner.body = body }
                }
                deliver(banner)
            }
            return
        }
        guard let trigger = BackgroundHandover.trigger(alertType: alertType, alertId: userInfo["alert_id"] as? String) else {
            deliver(content)
            return
        }
        // The invite's event type is named straight away, so even a timeout
        // shows it (`serviceExtensionTimeWillExpire` hands back the best attempt).
        if alertType == "circle_invite" { content.title = InviteNotificationCopy.title }

        // Every other visible push also hands the circle to whoever this device
        // owes it: a join names its circle through its notification row;
        // any other push sweeps the circles where the server says a delivery is
        // due — an access request or a phone that fell behind needs no new
        // notification of its own. The banner's own words (invite names, the
        // stamp) are worked out alongside, and the banner goes when both are
        // done — or when time runs out — once.
        let deadline = Date().addingTimeInterval(Self.handoverBudget)
        let level = UserDefaults(suiteName: ExtensionBridgeKeys.suite)?.string(forKey: ExtensionBridgeKeys.detailLevel)
        let original = content.copy() as? UNNotificationContent ?? content
        Task {
            async let handover = BackgroundHandover.run(trigger, deadline: deadline, env: .live)
            let banner = await Self.banner(for: original, alertType: alertType, userInfo: userInfo, level: level)
            let outcome = await handover
            if alertType == "member_joined",
               let body = MemberJoinedCopy.body(member: outcome.joinerName, circle: outcome.circleName, level: level) {
                banner.body = body
            }
            deliver(banner)
        }
    }

    /// A new SOS as its check found it: can't check → the server's own banner,
    /// ringing; checked and not live → the quiet notice; current or
    /// sticky → the real alarm (`SOSAlarmCopy`), silent when this phone has
    /// rung it already. The notices carry their kind (`SOSAlarmCopy.noticeKey`),
    /// so the app can replace or remove them.
    static func sosBanner(for original: UNNotificationContent, verdict: SOSCheck.Verdict,
                          level: String?) -> UNNotificationContent {
        let content = (original.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        var info = content.userInfo
        switch verdict {
        case .cantCheck(let why):
            SOSCheck.log.info("SOS: can't check (\(why, privacy: .public)): the server's alert rings")
            return original
        case .refused(let why):
            SOSCheck.log.info("SOS: checked, not live here (\(why, privacy: .public)): the quiet notice")
            content.title = SOSAlarmCopy.quietTitle
            content.body = SOSAlarmCopy.quietBody
            content.sound = nil
            info[SOSAlarmCopy.noticeKey] = SOSAlarmCopy.quietNotice
        case .alarm(let alarm):
            SOSCheck.log.info("SOS: checked, current or sticky: the alarm\(alarm.rings ? "" : ", rung already", privacy: .public)")
            let words = SOSAlarmCopy.alarm(name: alarm.name, circle: alarm.circle, level: level)
            content.title = words.title
            content.body = words.body
            content.sound = alarm.rings ? .default : nil
            info[SOSAlarmCopy.noticeKey] = SOSAlarmCopy.alarmNotice
        }
        content.subtitle = ""
        content.interruptionLevel = .active
        content.userInfo = info
        return content
    }

    /// The banner's own rewrite, apart from any handover: an invite's names, a
    /// check-in's or a crossing's names, a place or destination alert's stamp,
    /// or the server's words as they are.
    static func banner(for original: UNNotificationContent, alertType: String,
                       userInfo: [AnyHashable: Any], level: String? = nil,
                       env: BackgroundHandover.Environment = .live) async -> UNMutableNotificationContent {
        let content = (original.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        // Invites: the names come from the pending invite, fetched over the
        // app's own connection — the relay saw only the generic copy. An invite
        // push's `alert_id` is its notification ROW, which names the circle;
        // an older server put the circle id there.
        if alertType == "circle_invite" {
            return await InviteBannerRewriter.rewritten(
                content, circleId: userInfo["circle_id"] as? String, pushId: userInfo["alert_id"] as? String)
        }
        // Check-ins and crossings: who and where, from the notification row the
        // push names (`notification_id`), opened here. The row also gives the
        // circle, which no push carries, so the stamp below can open
        // the sealed crossing time.
        var circleId = userInfo["circle_id"] as? String
        if NamedBanner.handles(alertType),
           let named = await NamedBanner.run(
               alertType: alertType, notificationId: userInfo["notification_id"] as? String, level: level,
               deadline: Date().addingTimeInterval(NamedBanner.budget), env: env) {
            content.title = named.title
            if let body = named.body { content.body = body }
            circleId = named.circleId
        }
        guard stampedAlertTypes.contains(alertType) else { return content }

        // Prefer the time the event ACTUALLY happened over the dispatch time.
        //
        // `sent_at` is when the server dispatched the push, which is wrong by
        // however long the reporting device was offline — a crossing reported
        // late would read as if it had just happened. The reporting client
        // seals the real time with the circle key and the server forwards it
        // without being able to read it; we open it here.
        //
        // Best-effort on purpose: no blob, no keys (before first unlock), a
        // rotated key or any decrypt failure all fall back to `sent_at`. A
        // missing stamp must never cost the user the notification.
        let stamp = sealedOccurredAt(from: userInfo, circleId: circleId)
            ?? (userInfo["sent_at"] as? String).flatMap(parseRFC3339)
            ?? Date()
        content.body = "\(content.body) · \(shortStamp(stamp))"
        return content
    }

    /// iOS gives the extension a few seconds; if it expires, something must
    /// still be handed back. Delivering the unstamped original beats
    /// delivering nothing — a dropped notification is far worse than a
    /// missing timestamp.
    override func serviceExtensionTimeWillExpire() {
        if let deliver, let bestAttempt {
            deliver(bestAttempt)
        }
    }

    // MARK: - Sealed event time

    /// One CryptoManager for the extension's short life, wired to the SAME
    /// Keychain items the app's SDK persisted (readable because the extension
    /// declares the app's keychain-access-group — see
    /// NotificationExtension.entitlements).
    ///
    /// Built lazily so an extension invocation that never needs it — any alert
    /// type without a sealed time — pays nothing. Extensions run under a tight
    /// memory limit, and loading the SDK plus the key material is the expensive
    /// part of this file.
    private static let cryptoManager: CryptoManager? = {
        // Nothing while a wipe of the key store is owed (`OwedWipe`).
        guard UserDefaults(suiteName: ExtensionBridgeKeys.suite)?
            .bool(forKey: ExtensionBridgeKeys.keyStoreWipeOwed) != true else { return nil }
        let manager = CryptoManager()
        manager.registerSecureStorage(storage: ExtensionKeyStorage())
        do {
            _ = try manager.loadPersistedKeys()
            return manager
        } catch {
            // Before first unlock, or no keys yet. Caller falls back to sent_at.
            return nil
        }
    }()

    /// Decrypted `encrypted_occurred_at`, or nil if it cannot be opened.
    /// `circleId`: the push's, from an older server, or the named row's.
    private static func sealedOccurredAt(from userInfo: [AnyHashable: Any], circleId: String?) -> Date? {
        guard let circleId, !circleId.isEmpty,
              let ciphertext = userInfo["encrypted_occurred_at"] as? String, !ciphertext.isEmpty,
              let nonce = userInfo["occurred_at_nonce"] as? String, !nonce.isEmpty,
              let manager = cryptoManager
        else { return nil }

        // Field tag must match every sender — the Android app's BoundaryRepository,
        // this app's PlaceManager / DestinationsManager. It is AAD-bound, so a
        // mismatch fails rather than yielding a wrong time (pinned by
        // mobile-sdk's occurred_at_seal_round_trips_and_is_bound_to_its_field_tag).
        guard let plain = try? manager.decryptDataV2(
            circleId: circleId,
            encryptedData: EncryptedData(nonce: nonce, ciphertext: ciphertext),
            fieldTag: "occurred_at"
        ) else { return nil }

        // Epoch millis as a decimal string. Reject anything else rather than
        // stamping a nonsense date.
        guard let ms = Int64(plain.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
    }

    // MARK: - Formatting

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("Md")
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    /// Duplicated from the app's `NotificationStamp` rather than shared: an
    /// extension is a separate binary, and pulling Configuration.swift in would
    /// drag UserSettings and the rest of the app's object graph across the
    /// boundary for two DateFormatters.
    static func shortStamp(_ date: Date) -> String {
        "\(dateFormatter.string(from: date)), \(timeFormatter.string(from: date))"
    }

    static func parseRFC3339(_ raw: String) -> Date? {
        // Try fractional seconds first: chrono's to_rfc3339 emits them.
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: raw) { return d }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}

/// A content handler that runs once: the first banner handed to it goes to iOS,
/// any later one is dropped. The handover finishing and the time running out
/// can race.
final class DeliverOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((UNNotificationContent) -> Void)?

    init(_ handler: @escaping (UNNotificationContent) -> Void) {
        self.handler = handler
    }

    /// True when this content is the one handed to iOS (the first).
    @discardableResult
    func callAsFunction(_ content: UNNotificationContent) -> Bool {
        lock.lock()
        let handler = self.handler
        self.handler = nil
        lock.unlock()
        handler?(content)
        return handler != nil
    }
}
