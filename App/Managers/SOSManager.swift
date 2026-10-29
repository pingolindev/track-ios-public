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
import CoreLocation
import AVFoundation
import UIKit
import Combine
import OSLog
import UserNotifications
import PingolinTrackSDK

/// Manages SOS alerts
@MainActor
final class SOSManager: ObservableObject {
    static let shared = SOSManager()

    // MARK: - Published State

    @Published private(set) var activeAlerts: [SOSAlert] = []
    @Published private(set) var hasActiveAlert = false
    @Published private(set) var myActiveAlert: SOSAlert?
    /// Who is responding to this device's own alert, oldest first, by alert
    /// id (`CanonicalId.key`): only from `GET /sos/{id}`, which serves
    /// `acknowledged_by` to the raiser alone. /sos/active and every other
    /// reply are counts-only. Absent (an older server, or not asked yet): the
    /// screens show the count alone.
    @Published private(set) var responders: [String: [String]] = [:]
    /// What this device sealed as its own alert's position, for the raiser's
    /// card.
    @Published private(set) var myPosition: SOSSealedPositions.Record?
    @Published private(set) var isLoading = false
    /// Why the last attempt failed, for the UI to surface. A notification that
    /// silently does nothing is the worst possible failure mode for this
    /// feature — the user believes their circle knows. Cleared when they
    /// dismiss the message or a later attempt succeeds.
    @Published var lastTriggerError: String?

    /// How far the alert this user just raised actually got, or nil when there
    /// is nothing to report on.
    ///
    /// Exists because "the server accepted it" and "somebody's phone got it"
    /// are different facts.
    @Published var delivery: DeliveryStatus? {
        didSet { if let delivery { noteDeliveryNotice(delivery) } }
    }

    /// A circle notification of this person's that settled as reaching nobody,
    /// or whose checks ended with no answer at all: shown once as an alert
    /// wherever they are in the app (MainTabView). The card says it too, but
    /// the card can be left, and nobody may be coming.
    @Published var deliveryNotice: DeliveryNotice?

    struct DeliveryNotice: Equatable {
        let alertId: String
        let title: String
        let body: String
    }

    /// The alerts whose notice has been said, in the id's one form.
    private var saidDeliveryNotice: Set<String> = []

    /// Pure: what to say once about `status`, or nil. Only once the checks have
    /// ended (`undeliverable` is not believed before the settle window):
    /// - reached nobody (`alone`, `undeliverable`): the notice's title and the
    ///   state's own body;
    /// - no answer at all (the card's `noAnswer`): its own words, never
    ///   "didn't reach anyone";
    /// - an answer that reached someone, or was sent and waits on a device: none.
    /// Never twice.
    nonisolated static func deliveryNotice(_ status: DeliveryStatus,
                                           alreadySaid: Set<String>) -> (title: String, body: String)? {
        guard !status.stillChecking, !alreadySaid.contains(CanonicalId.key(status.alertId)) else { return nil }
        let state = status.response?.state
        if let state, let body = SOSDeliveryCopy.reachedNobodyBody(state) {
            return (SOSDeliveryCopy.reachedNobodyTitle, body)
        }
        if let state, SOSDeliveryCopy.answeredStates.contains(state) { return nil }
        return (SOSDeliveryCopy.noAnswerTitle, SOSDeliveryCopy.noAnswerBody)
    }

    /// Said once, unmissably: an alert if Track is in front, else a local
    /// notification.
    private func noteDeliveryNotice(_ status: DeliveryStatus) {
        guard let notice = Self.deliveryNotice(status, alreadySaid: saidDeliveryNotice) else { return }
        saidDeliveryNotice.insert(CanonicalId.key(status.alertId))
        if UIApplication.shared.applicationState == .active {
            deliveryNotice = DeliveryNotice(alertId: status.alertId, title: notice.title, body: notice.body)
        } else {
            let content = UNMutableNotificationContent()
            content.title = notice.title
            content.body = notice.body
            content.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(
                identifier: "delivery-notice-\(CanonicalId.key(status.alertId))", content: content, trigger: nil))
        }
    }

    /// What the raiser is shown while, and after, we find out.
    struct DeliveryStatus {
        let alertId: String
        /// Nil until the first successful poll answers.
        var response: SOSDeliveryResponse?
        /// False once polling has stopped, whether or not it learned anything.
        var stillChecking: Bool
    }

    /// How often to re-ask the server how far the alert got.
    private static let deliveryPollInterval: Duration = .seconds(3)
    /// Stop polling after this long. Past it, a device that has not confirmed
    /// is almost certainly off or unreachable rather than slow.
    private static let deliveryPollWindow: Duration = .seconds(60)
    /// How long before "undeliverable" is believed. Matches the server's
    /// confirmation grace window; below it, a bad verdict is more likely to be a
    /// dispatch still in progress than a real one.
    private static let deliverySettleWindow: Duration = .seconds(30)

    private var deliveryTask: Task<Void, Never>?

    // MARK: - Dependencies

    private let api = APIService.shared
    private let cryptoManager = SDKCrypto.cryptoManager
    private let locationService = LocationService.shared
    private var audioPlayer: AVAudioPlayer?
    /// The SOSes whose alarm this process rang: "rings once" holds even when
    /// the marks can't be read or written (`settleShownNotices`).
    private var rangHere = Set<String>()
    /// When each SOS (`CanonicalId.key`) was last re-sealed from here, for the
    /// hourly cap (`resealOwn`).
    private var reseals: [String: [Date]] = [:]
    /// The held key version per circle (`CanonicalId.key`) the last look after
    /// a circle load saw (`resealAfterKeyChange`).
    private var resealSeen: [String: Int] = [:]
    /// When a listed SOS (`CanonicalId.key`) that opened nothing last asked for
    /// a key refresh (`openListed`): at most once a minute each.
    private var keyRefreshTried: [String: Date] = [:]
    /// The runs of this device's own alerts, one at a time per alert.
    private let updateRuns = SerialRuns<UpdateOutcome>()
    /// The fixes taken after each own alert's press (`CanonicalId.key`).
    private var afterPress: [String: AfterPress] = [:]
    /// The circle each own alert was raised in by a press in this process
    /// (`CanonicalId.key`): with its record's, the only circle its runs
    /// seal into.
    private var pressCircles: [String: String] = [:]
    /// Own alerts a run found served in another circle, logged once each.
    private var relabelNoted: Set<String> = []
    /// When each own alert's update first waited for a rotation, and
    /// the timer that asks again.
    private var rotationDeferredSince: [String: Date] = [:]
    private var rotationRechecks: [String: Timer] = [:]
    /// The own open alert shown that another device, or this one before a
    /// sign-out, raised: shown and closable here, never updated from here,
    /// and gone when the server stops listing it.
    @Published private(set) var shownFromElsewhere: String?

    /// Whether the raise is off: while an alert this device raised stands,
    /// which this phone already keeps updated. Not for one shown from
    /// elsewhere: it can't follow this phone, so a person still in danger
    /// raises a fresh one that does, and the old one stays open to close.
    /// Android's button never waits on an open alert.
    var raiseIsOff: Bool { Self.raiseIsOff(shown: myActiveAlert, shownFromElsewhere: shownFromElsewhere) }

    /// Pure: `raiseIsOff`.
    nonisolated static func raiseIsOff(shown: SOSAlert?, shownFromElsewhere: String?) -> Bool {
        guard let shown else { return false }
        return !CanonicalId.same(shownFromElsewhere, shown.id)
    }
    /// The own open alert being kept updated (`startUpdateWatch`), and what
    /// watches for it.
    private var watchedAlertId: String?
    private var watchSinks: Set<AnyCancellable> = []
    private var windowEndTimer: Timer?
    private var keyCheckTimer: Timer?
    /// The key version last listed for the watched alert's circle.
    private var keyCheckSeen: Int?

    /// The raiser's status poll: a ONE-SHOT timer re-armed after every poll,
    /// so its cadence can follow `statusPollDelay` as the alert ages, the app
    /// comes and goes, and somebody acknowledges.
    private var alertPollingTimer: Timer?
    /// The alert being polled, and when it was raised (the backoff's clock).
    private var alertPollAlertId: String?
    private var alertPollStartedAt: Date?
    /// Somebody has acknowledged the alert: the poll drops to a slow closure
    /// check (`statusPollAcknowledgedSeconds`).
    private var alertAcknowledged = false
    /// Whether the raiser is looking at the app. The fast poll runs only then.
    private var appIsActive = true
    private var lifecycleObservers: [NSObjectProtocol] = []

    private init() {
        appIsActive = UIApplication.shared.applicationState == .active
        for (name, active) in [(UIApplication.didBecomeActiveNotification, true),
                               (UIApplication.willResignActiveNotification, false)] {
            let token = NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.appActivityChanged(active: active) }
            }
            lifecycleObservers.append(token)
        }
    }

    private func appActivityChanged(active: Bool) {
        appIsActive = active
        // Re-arm at the cadence the new state allows: back to the fast poll
        // when the raiser returns, down to the background floor when they leave.
        if alertPollAlertId != nil { scheduleNextAlertPoll() }
    }

    // MARK: - SOS Operations

    func triggerSOS(for circleId: String, message: String? = nil) async throws -> SOSAlert {
        isLoading = true
        defer { isLoading = false }

        // The press is the commitment: the precise fix starts now, in
        // parallel, and nothing waits for it. The raise seals what this phone
        // holds now and goes at once; a location problem never stops it.
        let pressAt = Date()
        let preciseFix = Task { @MainActor [locationService] in
            await locationService.requestFreshFix(timeout: Self.preciseFixTimeout, after: pressAt)
        }
        let owner = AuthManager.shared.userId
        let record = CirclePauseRecord.shared
        let payload = Self.raisePayload(
            pressAt: pressAt,
            held: [locationService.currentLocation, locationService.osCachedLocation].compactMap { $0 },
            rules: HeldFixRules(
                awaitsRead: { record.awaitsRead(circleId: circleId, capturedAt: $0, owner: owner) },
                withholds: { record.withholds(circleId: circleId, capturedAt: $0, owner: owner) },
                captureRadius: { record.captureRadius(circleId: circleId, capturedAt: $0, owner: owner) }),
            locationOff: Self.locationOff(locationService.authorizationStatus))

        let (alert, sealedLocation, sealedTime) = try await triggerSOSOverWire(circleId: circleId, payload: payload,
                                                                               message: message)

        myActiveAlert = alert
        // One shown from elsewhere stops being the one shown: this one follows
        // this phone. The old one shows again, to close, once this one ends.
        shownFromElsewhere = nil
        hasActiveAlert = true
        activeAlerts.append(alert)
        // What this device sealed, opened back from the blobs it sealed:
        // what a later re-seal seals (the position and the raise time), and
        // what the raiser's card says went out.
        let sealed = Self.sealedRecord(sealedLocation, circleId: circleId, pressAtMs: Self.ms(pressAt),
                                       locationOff: Self.locationOff(locationService.authorizationStatus),
                                       updates: 0,
                                       raisedAtMs: Self.sealedTimeMs(sealedTime, circleId: circleId, crypto: cryptoManager),
                                       crypto: cryptoManager)
        if let sealed { SOSSealedPositions.shared.note(sealed, alertId: alert.id, owner: owner) }
        myPosition = sealed
        // From here the alert is kept updated, and the precise fix is its
        // first after-press fix when it lands; it also feeds the normal
        // stream, where its gates decide. Only ever in the circle chosen here.
        pressCircles[CanonicalId.key(alert.id)] = circleId
        startUpdateWatch(alertId: alert.id, circleId: circleId, pressAt: pressAt, raisedAt: alert.createdAt)
        Task { @MainActor [weak self, locationService] in
            guard let fix = await preciseFix.value else { return }
            locationService.adoptSentFix(fix)
            self?.offer(fix, alertId: alert.id, pressAt: pressAt)
        }

        // High-frequency location updates for as long as the emergency lasts:
        // the moving cadence at Best accuracy whatever Battery Saver, the
        // battery tier or motion say. A bare `startTracking()` would re-apply
        // the NORMAL profile — a still phone would keep its five-minute poll
        // through its own emergency, and one in Battery Saver its fifteen.
        locationService.setEmergencyMode(true)
        if !locationService.isTracking {
            locationService.startTracking()
        }

        // Watch for acknowledgments and for somebody else closing it.
        startAlertPolling(alertId: alert.id)

        return alert
    }

    func cancelSOS(_ alert: SOSAlert, reason: SOSAlert.SOSStatus = SOSAlert.SOSStatus.falseAlarm) async throws {
        isLoading = true
        defer { isLoading = false }

        // There are TWO endpoints, not one. The resolve route always records
        // "resolved" and reads no body, so a `resolution: "false_alarm"`
        // posted there would be discarded: the raiser's phone would show
        // "False Alarm" while every other member — and the row itself —
        // recorded a genuine emergency that had been resolved. `false-alarm`
        // is its own route and is the only thing that writes that status.
        //
        // The response is server-blind, so the cached model is still mutated
        // from the inputs we already have.
        if reason == .falseAlarm {
            _ = try await api.markSOSFalseAlarm(alertId: alert.id)
        } else {
            _ = try await api.resolveSOS(alertId: alert.id, resolution: reason.rawValue)
        }
        if let index = activeAlerts.firstIndex(where: { $0.id == alert.id }) {
            var copy = activeAlerts[index]
            copy.status = reason
            copy.resolvedAt = Date()
            activeAlerts[index] = copy
        }

        if myActiveAlert?.id == alert.id {
            closeMyAlert(alert.id)
        }
    }

    func resolveSOS(_ alert: SOSAlert) async throws {
        try await cancelSOS(alert, reason: SOSAlert.SOSStatus.resolved)
    }

    func acknowledgeSOS(_ alert: SOSAlert) async throws {
        isLoading = true
        defer { isLoading = false }

        let response = try await api.acknowledgeSOS(alertId: alert.id)
        // Record the acknowledgement as a fact about THIS viewer. Do NOT set
        // `status = .acknowledged`: acknowledging is not the emergency ending,
        // and treating it as one hides a live alert from everybody else. The
        // alert stays active until it's resolved.
        if let userId = AuthManager.shared.userId,
           let index = activeAlerts.firstIndex(where: { $0.id == alert.id }) {
            var copy = activeAlerts[index]
            copy.acknowledgedByMe = true
            copy.acknowledgmentCount = response.acknowledgmentCount ?? (copy.acknowledgmentCount + 1)
            if !copy.acknowledgedBy.contains(userId) {
                copy.acknowledgedBy.append(userId)
            }
            activeAlerts[index] = copy
        }

        // Stop alarm sound if playing
        stopAlarmSound()
    }

    // MARK: - The raise's position

    /// How long the precise fix asked for at the press may take.
    nonisolated static let preciseFixTimeout: TimeInterval = 60
    /// A fix taken this little before the press counts as after it: Core
    /// Location's first delivery is often the fix it took just before
    /// (`FreshFixRequest.freshnessSlack`).
    nonisolated static let afterPressSlack: TimeInterval = 2

    /// What a raise seals as, or in place of, its position.
    enum RaisePayload: Equatable {
        /// Exact, or coarsened to the bubble it was taken under.
        case position(Location)
        case marker(SOSPositionMarker)
    }

    /// What the alert's circle allowed a held fix taken at a given time, by
    /// this account's record of when it was not sharing (`CirclePauseRecord`).
    struct HeldFixRules {
        /// No row of the circle read from the server since then: unknown.
        var awaitsRead: (Date) -> Bool
        /// Inside a stretch of not sharing with the circle.
        var withholds: (Date) -> Bool
        /// The widest bubble in force then, in miles; nil when exact.
        var captureRadius: (Date) -> Double?
    }

    /// Chosen when sealing:
    /// - (a) a fix taken after the press, EXACT, whatever the circle's pause or
    ///   bubble: the confirm dialog's consent covers the current exact position;
    /// - (b) otherwise the newest held fix by capture time, unless the circle's
    ///   record hasn't been read since it was taken or says this account wasn't
    ///   sharing then, and coarsened to the bubble in force when it was taken.
    ///   An older held fix is never looked for: the newest decides;
    /// - (c) otherwise a marker: "unavail" for a definite cause (location access
    ///   off), "pending" else, a held fix (b) skipped included.
    /// Never a fix with a negative accuracy: Core Location's "invalid".
    static func raisePayload(pressAt: Date, held: [CLLocation], rules: HeldFixRules,
                             locationOff: Bool) -> RaisePayload {
        let marker: RaisePayload = .marker(locationOff ? .unavail : .pending)
        guard let newest = held.filter({ $0.horizontalAccuracy >= 0 }).max(by: { $0.timestamp < $1.timestamp })
        else { return marker }
        let taken = newest.timestamp
        if taken >= pressAt.addingTimeInterval(-afterPressSlack) { return .position(sealable(newest)) }
        if rules.awaitsRead(taken) || rules.withholds(taken) { return marker }
        guard let miles = rules.captureRadius(taken) else { return .position(sealable(newest)) }
        return .position(coarsened(newest, miles: miles))
    }

    /// A fix as sealed: its capture time and accuracy, nothing else.
    nonisolated static func sealable(_ fix: CLLocation) -> Location {
        Location(latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude, altitude: nil, speed: nil,
                 heading: nil, accuracy: fix.horizontalAccuracy, timestamp: Self.ms(fix.timestamp),
                 batteryLevel: nil, isCharging: nil)
    }

    /// A held fix taken under a bubble of `miles`: snapped to the grid the live
    /// stream uses for it, with an accuracy of at least the bubble, so every
    /// reader draws an area.
    nonisolated static func coarsened(_ fix: CLLocation, miles: Double) -> Location {
        let meters = miles * 1_609.344
        let (lat, lng) = LocationCoarsener.coarsenLocation(lat: fix.coordinate.latitude, lng: fix.coordinate.longitude,
                                                           radiusMeters: meters)
        return Location(latitude: lat, longitude: lng, altitude: nil, speed: nil, heading: nil,
                        accuracy: max(fix.horizontalAccuracy, meters), timestamp: Self.ms(fix.timestamp),
                        batteryLevel: nil, isCharging: nil)
    }

    /// A definite reason no location can be sent: access denied (or Location
    /// Services off, which Core Location reports the same way) or restricted.
    nonisolated static func locationOff(_ status: CLAuthorizationStatus) -> Bool {
        status == .denied || status == .restricted
    }

    nonisolated static func ms(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }

    /// This device's record of what it just sealed, opened back from the
    /// blob it sealed: a position as the SDK decodes it, in the codec's
    /// precision, never the values that went in; or the marker its exact
    /// bytes are. `locationOff` is kept only for "unavail". Nil when the
    /// blob doesn't open here, which one this device just sealed does.
    nonisolated static func sealedRecord(_ blob: EncryptedBlobRequest, circleId: String, pressAtMs: Int64,
                                         locationOff: Bool, updates: Int, raisedAtMs: Int64? = nil,
                                         crypto: CryptoManager) -> SOSSealedPositions.Record? {
        let data = EncryptedData(nonce: blob.nonce, ciphertext: blob.ciphertext)
        if let point = try? crypto.decryptLocationOpened(circleId: circleId, encryptedLocation: data) {
            return .init(circleId: circleId, pressAtMs: pressAtMs, position: .init(point.location), marker: nil,
                         updates: updates, raisedAtMs: raisedAtMs)
        }
        guard let text = try? crypto.decryptDataV2(circleId: circleId, encryptedData: data, fieldTag: "location"),
              let marker = SOSPositionMarker.matching(text) else { return nil }
        return .init(circleId: circleId, pressAtMs: pressAtMs, position: nil, marker: marker,
                     locationOff: marker == .unavail && locationOff, updates: updates, raisedAtMs: raisedAtMs)
    }

    /// The raise time in a timestamp blob this device sealed, opened back
    /// (ms): what the record keeps (`raisedAtMs`). Nil when it doesn't open.
    nonisolated static func sealedTimeMs(_ blob: EncryptedBlobRequest, circleId: String,
                                         crypto: CryptoManager) -> Int64? {
        let data = EncryptedData(nonce: blob.nonce, ciphertext: blob.ciphertext)
        return (try? crypto.decryptDataV2(circleId: circleId, encryptedData: data, fieldTag: "timestamp"))
            .flatMap { Int64($0) }
    }

    /// The raiser's own card, on what went out; nil when the position was
    /// taken at the press, which says nothing new.
    nonisolated static func raiserLine(_ record: SOSSealedPositions.Record?, raisedAt: Date,
                                       now: Date = Date()) -> String? {
        guard let record else { return nil }
        switch record.marker {
        case .pending?: return "Sending your current location"
        case .unavail?: return "Sent without your location"
        case nil: break
        }
        guard let position = record.position else { return nil }
        let taken = Date(timeIntervalSince1970: TimeInterval(position.takenAtMs) / 1000)
        if record.updates > 0 { return "Your location was added at \(SOSPositionText.time(taken, now: now))" }
        if taken < raisedAt.addingTimeInterval(-60) {
            return "Sent with your location from \(SOSPositionText.time(taken, now: now))"
        }
        return nil
    }

    // MARK: - Alert Loading

    /// MAX_SOS_ALARM_AGE (`SOSReceiverRules`), the same on Android and the web.
    nonisolated static let maxAlarmAgeMs = SOSReceiverRules.maxAlarmAgeMs

    /// One listed SOS, opened: what the shared rules opened
    /// (`SOSReceiverRules.open`) and the alert this app shows of it.
    struct OpenedSOS {
        var alert: SOSAlert
        var opened: SOSReceiverRules.Opened
        var current: Bool { opened.current }
        var sealedTimeMs: Int64? { opened.sealedTimeMs }
        var payloadHash: String { opened.payloadHash }
        var raisedHere: Bool { opened.raisedHere }
    }

    /// Open one listed SOS with the version each part opened under
    /// (`SOSReceiverRules.open`), into the alert this app shows.
    nonisolated static func openAlert(
        _ response: SOSResponse, myUserId: String?, myDeviceId: String?, crypto: CryptoManager
    ) -> OpenedSOS {
        let opened = SOSReceiverRules.open(response, myUserId: myUserId, myDeviceId: myDeviceId, crypto: crypto)
        // Prefer the ENCRYPTED precise timestamp; the day bucket is only a
        // coarse fallback: read alone, every alert would claim it was
        // triggered at midnight UTC — useless for the one question a
        // responder actually asks.
        let createdAt = opened.sealedTimeMs.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
            ?? Date(timeIntervalSince1970: TimeInterval(response.dayBucket) * 86_400)
        let alert = SOSAlert(
            id: response.id,
            circleId: response.circleId,
            userId: opened.raiserId ?? "",
            status: SOSAlert.SOSStatus.from(response.status),
            latitude: opened.location?.latitude,
            longitude: opened.location?.longitude,
            acknowledgedBy: [],
            createdAt: createdAt,
            resolvedAt: response.resolvedDayBucket.map { Date(timeIntervalSince1970: TimeInterval($0) * 86_400) },
            acknowledgedByMe: response.acknowledgedByMe ?? false,
            dismissedByMe: response.dismissedByMe ?? false,
            dismissedAt: Self.parseInstant(response.dismissedAt),
            acknowledgmentCount: response.acknowledgmentCount ?? 0,
            // The position's own time and accuracy, or the marker sealed in its
            // place.
            positionTakenAt: opened.location.map { Date(timeIntervalSince1970: TimeInterval($0.timestamp) / 1000) },
            positionAccuracy: opened.location?.accuracy,
            positionMarker: opened.marker
        )
        return OpenedSOS(alert: alert, opened: opened)
    }

    /// Every listed SOS opened with this phone's keys. One that is live and
    /// opened NOTHING may be sealed under a key this phone hasn't fetched yet:
    /// another member rotated, and nothing brought the new key (no push, no
    /// circle load since). Then `refreshKeys` runs ONCE (a light circle load
    /// installs a newer own wrap and runs the key fetch and the records import)
    /// and every SOS is opened again. At most once a minute per SOS (`tried`),
    /// so a row that never opens can't spin.
    static func openListed(_ responses: [SOSResponse], open: (SOSResponse) -> OpenedSOS,
                           refreshKeys: () async -> Void, tried: inout [String: Date],
                           now: Date) async -> [OpenedSOS] {
        let opened = responses.map(open)
        let asking = opened.compactMap { entry -> String? in
            let key = CanonicalId.key(entry.alert.id)
            guard entry.alert.status.isLive, entry.opened.nothingOpened else { return nil }
            if let last = tried[key], now.timeIntervalSince(last) < 60 { return nil }
            return key
        }
        guard !asking.isEmpty else { return opened }
        for key in asking { tried[key] = now }
        await refreshKeys()
        return responses.map(open)
    }

    /// The exact payload a "seen current" mark is bound to (`SOSReceiverRules.payloadHash`).
    nonisolated static func payloadHash(_ response: SOSResponse) -> String {
        SOSReceiverRules.payloadHash(response)
    }

    /// What this phone's marks say of one SOS, as read now: unreadable stays
    /// unreadable (it can't tell "ended" or "sticky" then), no file is no
    /// mark.
    nonisolated static func marksState(_ read: StoredFile<[String: SOSAlarmMarks.Mark]>, circleId: String,
                                       sosId: String, hash: String) -> SOSReceiverRules.Marks {
        switch read {
        case .missing:
            return .read(ended: false, seenCurrent: false)
        case .loaded(let marks):
            let mark = marks[SOSAlarmMarks.key(circleId: circleId, sosId: sosId)]
            return .read(ended: mark?.ended == true, seenCurrent: mark?.seenCurrent.contains(hash) == true)
        case .unreadable:
            return .unreadable
        }
    }

    /// Whether this device's roster for the circle shows the raiser; nil while
    /// the roster isn't loaded.
    private func rosterShows(_ userId: String, circleId: String) -> Bool? {
        let key = CanonicalId.of(circleId) ?? circleId
        guard let members = CircleManager.shared.members[key] else { return nil }
        return members.contains { CanonicalId.same($0.userId, userId) }
    }

    /// Whether this phone may lack the key version a circle's SOS is sealed
    /// under: behind by its own knowledge, or holding less than the version
    /// the circle is at.
    private func behind(on circleId: String) -> Bool {
        CircleManager.shared.isBehind(circleId) || !CircleManager.shared.holdsCurrentVersion(for: circleId)
    }

    /// Load every active SOS the user can see, across ALL their circles.
    ///
    /// Deliberately NOT filtered to one circle. A per-circle guard
    /// (`guard response.circleId == circleId else { return nil }`) means an
    /// emergency in any circle other than the one currently selected simply
    /// does not exist as far as this device is concerned. An SOS permeates
    /// beyond circles.
    ///
    /// Assigning the whole array also reconciles: an alert somebody else
    /// resolved drops out of the server's list and therefore out of ours.
    ///
    /// What each alert shows follows the receiver rules
    /// (`SOSReceiverRules.verdict`). One this phone can't check (a key not
    /// held yet, marks that don't read) rings, when it opened enough to show.
    /// Then the SOS notices already shown are settled (`SOSNotices`).
    /// `quiet`: a refresh the server pushed ("sos_refresh") — no sound of its
    /// own.
    func loadActiveAlerts(quiet: Bool = false) async throws {
        // This account's own open SOS that a key change left behind goes along
        // to the current key first, so this load judges the re-sealed row.
        let responses = await resealOwn(try await api.getActiveSOSAlerts())
        let myUserId = AuthManager.shared.userId
        let myDeviceId = AuthManager.shared.deviceId
        var tried = keyRefreshTried
        let opened = await Self.openListed(
            responses, open: { Self.openAlert($0, myUserId: myUserId, myDeviceId: myDeviceId, crypto: cryptoManager) },
            refreshKeys: { try? await CircleManager.shared.loadCircles(light: true) }, tried: &tried, now: Date())
        keyRefreshTried = tried
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let marks = SOSAlarmMarks.shared
        var alerts: [SOSAlert] = []
        var verdicts: [String: SOSReceiverRules.Verdict] = [:]
        for entry in opened {
            let (circleId, sosId) = (entry.alert.circleId, entry.alert.id)
            let at = entry.sealedTimeMs ?? now
            let raiserShown = rosterShows(entry.alert.userId, circleId: circleId)
            var state = SOSReceiverRules.Marks.read(ended: false, seenCurrent: false)
            if let myUserId {
                if entry.alert.status.isClosed {
                    marks.noteEnded(account: myUserId, circleId: circleId, sosId: sosId, at: at)
                } else if entry.current {
                    marks.noteSeenCurrent(account: myUserId, circleId: circleId, sosId: sosId,
                                          hash: entry.payloadHash, at: at)
                }
                state = Self.marksState(marks.read(account: myUserId), circleId: circleId, sosId: sosId,
                                        hash: entry.payloadHash)
                // Stickiness ends, one-way, once the raiser is off the roster.
                if !entry.current, case .read(_, true) = state, raiserShown == false {
                    marks.noteEnded(account: myUserId, circleId: circleId, sosId: sosId, at: at)
                    state = Self.marksState(marks.read(account: myUserId), circleId: circleId, sosId: sosId,
                                            hash: entry.payloadHash)
                }
            }
            let verdict = SOSReceiverRules.verdict(
                live: entry.alert.status.isLive, opened: entry.opened, behind: behind(on: circleId), marks: state,
                raiserShown: raiserShown, now: now)
            verdicts[CanonicalId.key(sosId)] = verdict
            switch verdict {
            case .hidden:
                continue
            case .quiet:
                var alert = entry.alert
                alert.alarms = false
                alerts.append(alert)
            case .alarming:
                alerts.append(entry.alert)
            case .cantCheck:
                if entry.opened.opened { alerts.append(entry.alert) }
            }
        }
        if let myUserId {
            marks.prune(account: myUserId, now: now, maxAgeMs: Self.maxAlarmAgeMs)
            // Past its alarm age, an own alert's record goes too.
            SOSSealedPositions.shared.prune(owner: myUserId, nowMs: now, maxAgeMs: Self.maxAlarmAgeMs)
        }
        activeAlerts = alerts
        // For restoring `myActiveAlert` (see `reconcileMyAlert`): one THIS device
        // raised after a process restart, else one this account raised
        // elsewhere. Current ones only, so an SOS sealed under a key a removed
        // member holds can't start emergency mode here, or show as the asker's.
        let currentAlerts = opened.filter(\.current)
        await reconcileMyAlert(with: currentAlerts.map(\.alert),
                               raisedHere: Set(currentAlerts.filter(\.raisedHere).map(\.alert.id)),
                               listed: Set(opened.map { CanonicalId.key($0.alert.id) }))

        // Alarm only for alerts this user hasn't handled — an alert they
        // acknowledged or dismissed must not keep sounding — and that may
        // alarm at all. A pushed refresh makes no sound of its own.
        let needsAttention = alerts.contains { alert in
            alert.alarms && alert.status.isLive && !alert.acknowledgedByMe && !alert.dismissedByMe
        }
        if needsAttention && !quiet {
            playAlarmSound()
        }
        if let myUserId {
            await settleShownNotices(opened: opened, verdicts: verdicts, quiet: quiet, account: myUserId, now: now)
        }
    }

    /// The raiser's name on an SOS alarm: the name this app shows for them, only
    /// when their sealed name OPENED here (`CircleManager.openedNames`). Never
    /// the plaintext name the server sends for older clients, nor the "Member"
    /// placeholder: the server could choose those for a genuine alarm. Pure,
    /// for tests.
    nonisolated static func openedName(of raiser: String, in members: [CircleMember]?, opened: Set<String>?) -> String? {
        guard opened?.contains(CanonicalId.key(raiser)) == true else { return nil }
        return members?.first { CanonicalId.same($0.userId, raiser) }?.displayName
    }

    /// The SOS notices already shown, settled by this load (`SOSNotices`): the
    /// names are the ones that opened here, at the user's detail level. An SOS
    /// that alarms rings once on this phone: its "rang" mark (and this
    /// process's memory of it) or this person's acknowledgement or dismissal
    /// keeps any later post silent. Only a quiet refresh posts the alarm of an
    /// SOS that shows nothing here. `account`: whose load this was; nothing is
    /// posted or marked once another account (or none) is signed in.
    private func settleShownNotices(opened: [OpenedSOS], verdicts: [String: SOSReceiverRules.Verdict],
                                    quiet: Bool, account me: String, now: Int64) async {
        let center = UNUserNotificationCenter.current()
        let delivered = await center.deliveredNotifications().compactMap(SOSNotices.delivered)
        guard !delivered.isEmpty || verdicts.values.contains(.alarming) else { return }
        guard CanonicalId.same(AuthManager.shared.userId, me) else { return }
        let stored: [String: SOSAlarmMarks.Mark]
        if case .loaded(let marks) = SOSAlarmMarks.shared.read(account: me) { stored = marks } else { stored = [:] }
        var names: [String: (name: String?, circle: String?)] = [:]
        var marked: [String: (circleId: String, at: Int64)] = [:]
        var rang = rangHere
        for entry in opened where verdicts[CanonicalId.key(entry.alert.id)] == .alarming {
            let key = CanonicalId.key(entry.alert.id)
            let circleKey = CanonicalId.of(entry.alert.circleId) ?? entry.alert.circleId
            let raiser = Self.openedName(of: entry.alert.userId, in: CircleManager.shared.members[circleKey],
                                         opened: CircleManager.shared.openedNames[circleKey])
            let circle = CircleManager.shared.circles.first { CanonicalId.same($0.id, entry.alert.circleId) }?.readableName
            names[key] = (raiser, circle)
            marked[key] = (entry.alert.circleId, entry.sealedTimeMs ?? now)
            if stored[SOSAlarmMarks.key(circleId: entry.alert.circleId, sosId: key)]?.rang == true
                || entry.alert.acknowledgedByMe || entry.alert.dismissedByMe {
                rang.insert(key)
            }
        }
        let plan = SOSNotices.plan(delivered: delivered, verdicts: verdicts, names: names,
                                   level: UserSettings.shared.notificationDetailLevel.rawValue, rang: rang,
                                   newPosts: quiet)
        if !plan.remove.isEmpty { center.removeDeliveredNotifications(withIdentifiers: plan.remove) }
        await SOSNotices.post(plan, add: { request in
            // Signed out or switched mid-load: refused, so nothing is posted
            // or marked for the account that left.
            guard CanonicalId.same(AuthManager.shared.userId, me) else { throw CancellationError() }
            try await center.add(request)
        }, rang: { post in
            let key = CanonicalId.key(post.alertId)
            rangHere.insert(key)
            if let target = marked[key] {
                SOSAlarmMarks.shared.noteRang(account: me, circleId: target.circleId, sosId: key, at: target.at)
            }
        })
    }

    // MARK: - The raiser's re-seal and position updates

    /// At most this many re-seals of one SOS from this phone per hour, as
    /// Android's MAX_RESEALS_PER_HOUR (the server keeps its own limit). Position
    /// updates and the re-seals after a key change share it.
    nonisolated static let maxResealsPerHour = 10
    /// The update rule's bounds — an alert is not a live trail: at most three
    /// updates, within ten minutes of the press.
    nonisolated static let maxPositionUpdates = 3
    nonisolated static let updateWindow: TimeInterval = 10 * 60
    /// A position this precise needs no better one
    /// (`updateDue`'s (c)).
    nonisolated static let preciseMeters: Double = 100
    /// A held position taken this long before the press gives way to a fix
    /// taken after it (`updateDue`'s (b)).
    nonisolated static let staleBeforePress: TimeInterval = 60
    /// An update waits for the rotation its circle is flagged for,
    /// asking again this often, at most this long after it first waited.
    nonisolated static let rotationRecheck: TimeInterval = 30
    nonisolated static let rotationDeferLimit: TimeInterval = 2 * 60
    /// How often the key check runs while this device's alert is open.
    nonisolated static let keyCheckInterval: TimeInterval = 60

    /// The fixes taken after the press, which `updateDue` reads, always sealed
    /// exact: the newest, and the newest within `preciseMeters`.
    struct AfterPress {
        private(set) var newest: CLLocation?
        private(set) var precise: CLLocation?

        /// Kept when taken at or after the press (within `afterPressSlack`) with
        /// an accuracy, and newer than the one kept.
        mutating func offer(_ fix: CLLocation, pressAt: Date) {
            guard fix.horizontalAccuracy >= 0,
                  fix.timestamp >= pressAt.addingTimeInterval(-SOSManager.afterPressSlack) else { return }
            if fix.timestamp > (newest?.timestamp ?? .distantPast) { newest = fix }
            if fix.horizontalAccuracy <= SOSManager.preciseMeters, fix.timestamp > (precise?.timestamp ?? .distantPast) {
                precise = fix
            }
        }

        /// The fix that `updateDue`'s (a) and (b) seal: the precise
        /// one when there is one.
        var best: CLLocation? { precise ?? newest }
    }

    /// The update rule, pure: the update this device seals for its own alert,
    /// or nil. `c` is the position the alert carries as this device last
    /// sealed it (its record; without one, what opened); `fixes` what was
    /// taken after the press; `locationOff` a definite cause now. Within
    /// `updateWindow` of the press, and at most `maxPositionUpdates`:
    /// - (a) a marker, and a fix taken after the press;
    /// - (b) a position taken over a minute before the press, and such a fix;
    /// - (c) a position worse than 100 m (a coarsened held one is), and a fix
    ///   within 100 m taken after it;
    /// - (d) "pending", and a definite cause: "unavail";
    /// - (e) at the window's end, still "pending": "unavail".
    /// A fix goes exact.
    nonisolated static func updateDue(_ c: SOSSealedPositions.Record, fixes: AfterPress, locationOff: Bool,
                                      now: Date) -> RaisePayload? {
        guard c.updates < maxPositionUpdates else { return nil }
        let windowEnd = Date(timeIntervalSince1970: TimeInterval(c.pressAtMs) / 1000 + updateWindow)
        guard now < windowEnd else { return c.marker == .pending ? .marker(.unavail) : nil }
        if c.marker != nil, let fix = fixes.best { return .position(sealable(fix)) }
        if let position = c.position {
            if position.takenAtMs < c.pressAtMs - Int64(staleBeforePress * 1000), let fix = fixes.best {
                return .position(sealable(fix))
            }
            if position.accuracy.map({ $0 > preciseMeters }) ?? true, let fix = fixes.precise,
               ms(fix.timestamp) > position.takenAtMs {
                return .position(sealable(fix))
            }
        }
        return c.marker == .pending && locationOff ? .marker(.unavail) : nil
    }

    /// What sealing `c` again seals: the same marker, or the same position
    /// (values the codec already holds, so it packs them the same).
    nonisolated static func payload(of c: SOSSealedPositions.Record) -> RaisePayload? {
        if let marker = c.marker { return .marker(marker) }
        return c.position.map { .position($0.location) }
    }

    /// `c` (see `updateDue`) for an alert this device has no record of (a
    /// reinstall, or one raised by an earlier version of the app): what
    /// opened, its window counted from the sealed raise time.
    nonisolated static func openedRecord(_ opened: SOSReceiverRules.Opened,
                                         circleId: String) -> SOSSealedPositions.Record? {
        guard let sealedTimeMs = opened.sealedTimeMs else { return nil }
        if let location = opened.location {
            return .init(circleId: circleId, pressAtMs: sealedTimeMs, position: .init(location), marker: nil)
        }
        return opened.marker.map { .init(circleId: circleId, pressAtMs: sealedTimeMs, position: nil, marker: $0) }
    }

    /// Whether the server serves the alert's position as `record` holds it:
    /// decoded against decoded, exactly, a marker byte for byte. Never the
    /// ciphertexts, which a new nonce changes at every seal.
    nonisolated static func serves(_ record: SOSSealedPositions.Record, _ opened: SOSReceiverRules.Opened) -> Bool {
        if let marker = record.marker { return opened.location == nil && opened.marker == marker }
        guard let position = record.position, let served = opened.location else { return false }
        return SOSSealedPositions.Sealed(served) == position
    }

    /// Whether the server serves the raise time `record` holds, the one this
    /// device sealed; true for a record that holds none.
    nonisolated static func servesTime(_ record: SOSSealedPositions.Record, _ opened: SOSReceiverRules.Opened) -> Bool {
        record.raisedAtMs.map { $0 == opened.sealedTimeMs } ?? true
    }

    /// What one run seals for one of this device's own alerts (`resealChoice`).
    struct ResealChoice {
        var payload: RaisePayload
        /// An update by the update rule (`updateDue`), counted in
        /// `maxPositionUpdates`.
        var update: Bool
        /// C: the position the alert carries as this device last sealed it.
        var current: SOSSealedPositions.Record
    }

    /// The re-seal choice, pure: for an open alert this account raised ON THIS
    /// DEVICE (its other devices leave it to this one), whose raiser id and
    /// sealed time opened here, nil when nothing is due. Due when the update
    /// rule has an update, when the alert isn't current (sealed under a key the
    /// circle moved from), or when what the server serves differs from this
    /// device's record. It seals the update, else the record, else (no record)
    /// what opened: never what the server serves in place of the record, and
    /// never a stand-in position.
    ///
    /// Only for the circle this device raised the alert in, as it knows it:
    /// its record's, else this process's press (`pressCircleId`). Served in
    /// another circle (a check-in this phone sealed there opens as "raised
    /// here" under that circle's key), nothing. With neither, no update: at
    /// most what opened, into the circle it opened in.
    nonisolated static func resealChoice(opened: SOSReceiverRules.Opened, status: String, circleId: String,
                                         record: SOSSealedPositions.Record?, pressCircleId: String?,
                                         fixes: AfterPress, locationOff: Bool, now: Date) -> ResealChoice? {
        let own = record?.circleId ?? pressCircleId
        if let own, !CanonicalId.same(own, circleId) { return nil }
        guard ["active", "acknowledged"].contains(status), opened.opened, opened.raisedHere,
              let c = record ?? openedRecord(opened, circleId: circleId) else { return nil }
        let update = own == nil ? nil : updateDue(c, fixes: fixes, locationOff: locationOff, now: now)
        guard let payload = update ?? payload(of: c) else { return nil }
        let differs = record.map { !serves($0, opened) || !servesTime($0, opened) } ?? false
        guard update != nil || !opened.current || differs else { return nil }
        return ResealChoice(payload: payload, update: update != nil, current: c)
    }

    /// The re-seal's body: the create's sealed fields again (`createRequest`),
    /// under the key this phone seals the circle under now: the same raiser and
    /// device, `payload` for the position (this device's record, or an update;
    /// never what the server serves), the ORIGINAL time (never now, so a
    /// re-seal never extends its 24 h), and the device state when it opens,
    /// else none. Sealed into `circleId`, the circle this device raised the
    /// alert in, never the one the response names. The time is `raisedAtMs`,
    /// the one this device sealed (its record's), else as it opened. Nil when a
    /// part it needs didn't open, or without the write gate.
    nonisolated static func resealRequest(for response: SOSResponse, into circleId: String,
                                          opened: SOSReceiverRules.Opened, payload: RaisePayload,
                                          raisedAtMs: Int64? = nil, deviceId: String,
                                          holdsCurrentKey: Bool, crypto: CryptoManager) throws -> ResealSOSRequest? {
        guard holdsCurrentKey, let raiser = opened.raiserId,
              let sealedTimeMs = raisedAtMs ?? opened.sealedTimeMs else { return nil }
        let sealed = { (text: String, fieldTag: String) throws -> EncryptedBlobRequest in
            let blob = try crypto.encryptDataV2(circleId: circleId, plaintext: text, fieldTag: fieldTag)
            return EncryptedBlobRequest(nonce: blob.nonce, ciphertext: blob.ciphertext)
        }
        let state = response.encryptedDeviceState.flatMap { blob in
            try? crypto.decryptDataV2(circleId: circleId, encryptedData: EncryptedData(nonce: blob.nonce, ciphertext: blob.ciphertext),
                                      fieldTag: "device_state")
        }
        let point: EncryptedBlobRequest
        switch payload {
        case .position(let location):
            let blob = try crypto.encryptLocation(circleId: circleId, location: location)
            point = EncryptedBlobRequest(nonce: blob.nonce, ciphertext: blob.ciphertext)
        case .marker(let marker):
            point = try sealed(marker.rawValue, "location")
        }
        return ResealSOSRequest(
            encryptedLocation: point,
            encryptedDeviceState: try state.map { try sealed($0, "device_state") },
            encryptedUserId: try sealed(raiser, "user_id"),
            encryptedDeviceId: try sealed(deviceId, "device_id"),
            encryptedTimestamp: try sealed(String(sealedTimeMs), "timestamp"))
    }

    /// What one run reads and does, as closures, so tests stand in for the
    /// server, the keys, the store and the clock.
    struct UpdateWorld {
        var me: String?
        var deviceId: String?
        var crypto: CryptoManager
        var now: () -> Date
        /// This device's record of the alert, and keeping or dropping it.
        var record: () -> SOSSealedPositions.Record?
        var keep: (SOSSealedPositions.Record) -> Void
        var forget: () -> Void
        /// The fixes taken after the press, and whether a definite
        /// cause holds now.
        var fixes: () -> AfterPress
        var locationOff: () -> Bool
        /// GET /sos/{id}, which reads the primary.
        var get: () async throws -> SOSResponse
        /// One bounded circle and key read.
        var refreshKeys: (String) async -> Void
        /// Then whether this phone seals the circle under its current key: the
        /// primed form, never on a circle list this process didn't load.
        var holdsCurrentKey: (String) async -> Bool
        /// The circle is flagged `key_rotation_needed`; when this
        /// alert's update first waited for it.
        var rotationNeeded: (String) -> Bool
        var deferredSince: () -> Date?
        var noteDeferral: (Date?) -> Void
        /// The hourly cap (`maxResealsPerHour`).
        var resealsLastHour: () -> Int
        var noteReseal: () -> Void
        /// PUT /sos/{id}/reseal.
        var put: (ResealSOSRequest) async throws -> SOSResponse
        /// The circle this process's press raised the alert in, if it did.
        var pressCircleId: () -> String? = { nil }
        /// The alert was served in another circle (logged once, no ids).
        var noteRelabelled: () -> Void = {}
    }

    /// How one run ended.
    enum UpdateOutcome {
        /// Nothing due: current, serving the record, and no update.
        case unchanged
        /// Re-sealed; what the server serves now.
        case resealed(SOSResponse)
        /// Closed, or refused with a 404 (closed, or its raiser left): its
        /// record is gone.
        case ended
        /// Waiting for the circle's rotation; asked again in
        /// `rotationRecheck`.
        case deferred
        /// Not sealed now (the key, the cap, a 429, an error); a later trigger
        /// asks again. Nothing is shown.
        case notNow(String)

        /// For the log: what happened, never what was sealed.
        var label: String {
            switch self {
            case .unchanged: return "unchanged"
            case .resealed: return "re-sealed"
            case .ended: return "ended"
            case .deferred: return "waiting for a rotation"
            case .notNow(let why): return "not now (\(why))"
            }
        }
    }

    /// One run of the update for one of this device's own alerts: GET it and
    /// open it; choose (`resealChoice`); before sealing anything, one bounded
    /// circle and key read, a wait while the circle is about to rotate, and
    /// the current key; then PUT, and keep the record of what THIS DEVICE
    /// sealed, opened from the blob it sealed, never from the response's
    /// echo. A 404 or a 429 stops it quietly. One at a time per alert
    /// (`runUpdate`). It seals only into the circle this device raised the
    /// alert in, and a record only ever names that circle: never one the
    /// server named.
    static func updateRun(world: UpdateWorld) async -> UpdateOutcome {
        guard let deviceId = world.deviceId else { return .notNow("no device id") }
        let response: SOSResponse
        do {
            response = try await world.get()
        } catch let error as APIError where error.code == "http_404" {
            world.forget()
            return .ended
        } catch {
            return .notNow("not read")
        }
        guard ["active", "acknowledged"].contains(response.status) else {
            world.forget()
            return .ended
        }
        let circleId = response.circleId
        let record = world.record()
        let pressCircleId = world.pressCircleId()
        let own = record?.circleId ?? pressCircleId
        let opened = SOSReceiverRules.open(response, myUserId: world.me, myDeviceId: deviceId, crypto: world.crypto)
        // An update that is waiting for a rotation is judged as of its first
        // wait, so the window ending during the wait never turns the fix it
        // waits with into `updateDue`'s (e) "unavail". A wait older than its
        // bound is over.
        let now = world.now()
        let waiting = world.deferredSince().flatMap {
            now.timeIntervalSince($0) <= rotationDeferLimit + rotationRecheck ? $0 : nil
        }
        guard let choice = resealChoice(opened: opened, status: response.status, circleId: circleId,
                                        record: record, pressCircleId: pressCircleId, fixes: world.fixes(),
                                        locationOff: world.locationOff(), now: waiting ?? now)
        else {
            // Served in another circle than it was raised in. Nothing.
            if let own, !CanonicalId.same(own, circleId) { world.noteRelabelled() }
            return .unchanged
        }
        // Its own circle; with neither a record nor a press, the one it
        // opened in.
        let into = own ?? circleId
        // One bounded circle and key read before sealing anything.
        await world.refreshKeys(into)
        // An update waits while the circle is flagged for a rotation,
        // so the rotation (and this alert's re-seal under the new key) goes
        // first; at most two minutes from its first wait, then it goes under
        // the key held. Each update gets its own wait.
        if choice.update, world.rotationNeeded(into), now.timeIntervalSince(waiting ?? now) < rotationDeferLimit {
            world.noteDeferral(waiting ?? now)
            return .deferred
        }
        world.noteDeferral(nil)
        let holdsCurrentKey = await world.holdsCurrentKey(into)
        guard holdsCurrentKey else { return .notNow("key not current") }
        guard world.resealsLastHour() < maxResealsPerHour else { return .notNow("hourly cap") }
        guard let request = try? resealRequest(for: response, into: into, opened: opened, payload: choice.payload,
                                               raisedAtMs: choice.current.raisedAtMs, deviceId: deviceId,
                                               holdsCurrentKey: holdsCurrentKey, crypto: world.crypto)
        else { return .notNow("not sealed") }
        world.noteReseal()
        let served: SOSResponse
        do {
            served = try await world.put(request)
        } catch let error as APIError where error.code == "http_404" {
            world.forget()
            return .ended
        } catch let error as APIError where ["http_429", "rate_limited"].contains(error.code) {
            return .notNow("429")
        } catch {
            return .notNow("not taken")
        }
        let c = choice.current
        // The record names its own circle; with neither a record nor a press,
        // none is written: the only circle known is the one the server named.
        if let own, let sealed = sealedRecord(request.encryptedLocation, circleId: own, pressAtMs: c.pressAtMs,
                                              locationOff: choice.update ? world.locationOff() : c.locationOff,
                                              updates: c.updates + (choice.update ? 1 : 0),
                                              raisedAtMs: sealedTimeMs(request.encryptedTimestamp, circleId: own,
                                                                       crypto: world.crypto),
                                              crypto: world.crypto) {
            world.keep(sealed)
        }
        return .resealed(served)
    }

    /// One pass over listed SOSes: each of this device's own that a run is due
    /// for (`resealChoice`, on the listed copy) goes through its run, which
    /// reads it afresh; what the server then serves replaces it. Pure apart
    /// from its closures, for tests.
    static func resealPass(
        _ responses: [SOSResponse], me: String?, deviceId: String?, crypto: CryptoManager,
        record: (String) -> SOSSealedPositions.Record?, pressCircle: (String) -> String?,
        fixes: (String) -> AfterPress, locationOff: Bool, now: Date,
        run: (String) async -> UpdateOutcome?
    ) async -> [SOSResponse] {
        guard let deviceId else { return responses }
        var out = responses
        for (index, response) in responses.enumerated() {
            let opened = SOSReceiverRules.open(response, myUserId: me, myDeviceId: deviceId, crypto: crypto)
            guard resealChoice(opened: opened, status: response.status, circleId: response.circleId,
                               record: record(response.id), pressCircleId: pressCircle(response.id),
                               fixes: fixes(response.id), locationOff: locationOff, now: now) != nil
            else { continue }
            if case .resealed(let served)? = await run(response.id) { out[index] = served }
        }
        return out
    }

    /// Pure: the re-seal's gate. Only for a circle in a list this process
    /// loaded from the server (`circlesLoaded`, `listedCircleIds`) and shown
    /// here (`circles`), so that the write gate compares the version held with
    /// the one listed: for a circle it hasn't loaded, the write gate passes.
    /// Then the write gate itself.
    nonisolated static func resealGate(circlesLoaded: Bool, listed: Set<String>, shown: Set<String>, circleId: String,
                                       holdsCurrentKey: () -> Bool) -> Bool {
        circlesLoaded && listed.contains(circleId.lowercased()) && shown.contains(circleId.lowercased())
            && holdsCurrentKey()
    }

    /// A run of `updateRun` for one of this device's own alerts, after every
    /// run of it already asked for (`SerialRuns`). One that waits for a
    /// rotation asks again in `rotationRecheck`.
    @discardableResult
    func runUpdate(_ alertId: String) -> Task<UpdateOutcome?, Never> {
        updateRuns.run(CanonicalId.key(alertId)) { [weak self] in
            guard let self else { return .notNow("gone") }
            let outcome = await Self.updateRun(world: self.updateWorld(alertId))
            print("[Track] SOS \(alertId): position run \(outcome.label)")
            self.after(outcome, alertId: alertId)
            return outcome
        }
    }

    /// The `UpdateWorld` on this phone, for one of its own alerts.
    private func updateWorld(_ alertId: String) -> UpdateWorld {
        let owner = AuthManager.shared.userId
        let key = CanonicalId.key(alertId)
        let store = SOSSealedPositions.shared
        return UpdateWorld(
            me: owner, deviceId: AuthManager.shared.deviceId, crypto: cryptoManager, now: { Date() },
            record: { store.record(alertId: alertId, owner: owner) },
            keep: { [weak self] record in
                // Never into the file of whoever signed in since.
                guard CanonicalId.same(AuthManager.shared.userId, owner) else { return }
                store.note(record, alertId: alertId, owner: owner)
                self?.show(record, alertId: alertId)
            },
            forget: { store.forget(alertId: alertId, owner: owner) },
            fixes: { [weak self] in self?.afterPress[key] ?? AfterPress() },
            locationOff: { [locationService] in Self.locationOff(locationService.authorizationStatus) },
            get: { [api] in try await api.getSOSAlert(alertId: alertId) },
            refreshKeys: { _ in try? await CircleManager.shared.loadCircles(light: true) },
            holdsCurrentKey: { circleId in
                // Primed, so after a restart nothing is sealed before a
                // circle list this process loaded lists the circle.
                let primed = await CircleManager.shared.holdsCurrentKeyPrimed(for: circleId)
                return Self.resealGate(circlesLoaded: CircleManager.shared.circlesLoaded,
                                       listed: CircleManager.shared.listedCircleIds,
                                       shown: Set(CircleManager.shared.circles.map { $0.id.lowercased() }),
                                       circleId: circleId, holdsCurrentKey: { primed })
            },
            rotationNeeded: { circleId in
                CircleManager.shared.circles.first { CanonicalId.same($0.id, circleId) }?.keyRotationNeeded == true
            },
            deferredSince: { [weak self] in self?.rotationDeferredSince[key] },
            noteDeferral: { [weak self] since in self?.rotationDeferredSince[key] = since },
            resealsLastHour: { [weak self] in self?.resealsLastHour(key) ?? 0 },
            noteReseal: { [weak self] in self?.noteReseal(key) },
            put: { [api] request in try await api.resealSOS(alertId: alertId, request: request) },
            pressCircleId: { [weak self] in self?.pressCircles[key] },
            noteRelabelled: { [weak self] in
                guard let self, self.relabelNoted.insert(key).inserted else { return }
                print("[Track] SOS: an own alert was served in another circle than it was raised in; nothing sealed")
            })
    }

    private func resealsLastHour(_ key: String) -> Int {
        (reseals[key] ?? []).filter { Date().timeIntervalSince($0) < 3_600 }.count
    }

    private func noteReseal(_ key: String) {
        reseals[key] = (reseals[key] ?? []).filter { Date().timeIntervalSince($0) < 3_600 } + [Date()]
    }

    /// What follows a run: a wait for a rotation asks again; an ended alert
    /// is watched no more.
    private func after(_ outcome: UpdateOutcome, alertId: String) {
        let key = CanonicalId.key(alertId)
        switch outcome {
        case .deferred:
            rotationRechecks[key]?.invalidate()
            rotationRechecks[key] = Timer.scheduledTimer(withTimeInterval: Self.rotationRecheck,
                                                         repeats: false) { [weak self] _ in
                Task { @MainActor in self?.runUpdate(alertId) }
            }
        case .ended:
            if CanonicalId.same(watchedAlertId, alertId) { stopUpdateWatch() }
            afterPress[key] = nil
            pressCircles[key] = nil
            rotationDeferredSince[key] = nil
        case .unchanged, .resealed, .notNow:
            break
        }
    }

    /// This device's own alert shows what it last sealed: the raiser's card,
    /// and the alert's own position after an update.
    private func show(_ record: SOSSealedPositions.Record, alertId: String) {
        guard let mine = myActiveAlert, CanonicalId.same(mine.id, alertId) else { return }
        myPosition = record
        let shown = Self.showing(record, in: mine)
        myActiveAlert = shown
        if let index = activeAlerts.firstIndex(where: { $0.id == mine.id }) {
            activeAlerts[index] = Self.showing(record, in: activeAlerts[index])
        }
    }

    /// `alert` at the position `record` holds.
    nonisolated static func showing(_ record: SOSSealedPositions.Record, in alert: SOSAlert) -> SOSAlert {
        SOSAlert(id: alert.id, circleId: alert.circleId, userId: alert.userId, status: alert.status,
                 latitude: record.position?.latitude, longitude: record.position?.longitude,
                 acknowledgedBy: alert.acknowledgedBy, createdAt: alert.createdAt, resolvedAt: alert.resolvedAt,
                 acknowledgedByMe: alert.acknowledgedByMe, dismissedByMe: alert.dismissedByMe,
                 dismissedAt: alert.dismissedAt, acknowledgmentCount: alert.acknowledgmentCount, alarms: alert.alarms,
                 positionTakenAt: record.position.map { Date(timeIntervalSince1970: TimeInterval($0.takenAtMs) / 1000) },
                 positionAccuracy: record.position?.accuracy, positionMarker: record.marker)
    }

    /// `resealPass` with this phone's account, device, keys, records and runs.
    private func resealOwn(_ responses: [SOSResponse]) async -> [SOSResponse] {
        let owner = AuthManager.shared.userId
        return await Self.resealPass(
            responses, me: owner, deviceId: AuthManager.shared.deviceId, crypto: cryptoManager,
            record: { SOSSealedPositions.shared.record(alertId: $0, owner: owner) },
            pressCircle: { [pressCircles] in pressCircles[CanonicalId.key($0)] },
            fixes: { [afterPress] in afterPress[CanonicalId.key($0)] ?? AfterPress() },
            locationOff: Self.locationOff(locationService.authorizationStatus), now: Date(),
            run: { [weak self] id in await self?.runUpdate(id).value ?? nil })
    }

    /// Pure: the circles (`CanonicalId.key`) whose held key version differs
    /// from the one last seen, and what is seen now. A circle seen for the first
    /// time counts as moved.
    nonisolated static func movedCircles(held: [(circleId: String, version: Int?)],
                                         seen: [String: Int]) -> (moved: Set<String>, seen: [String: Int]) {
        var moved = Set<String>()
        var seen = seen
        for (circleId, version) in held {
            guard let version else { continue }
            let key = CanonicalId.key(circleId)
            if seen[key] != version { moved.insert(key) }
            seen[key] = version
        }
        return (moved, seen)
    }

    /// After a circle load (`CircleManager.loadCircles`): this account's own
    /// open SOS in the circles whose held key version moved since the last look
    /// (a rotation this device landed, as every rotation path ends in a load,
    /// or a key import) is re-sealed, through its run. Cheap when nothing
    /// moved; nothing is shown until the next SOS load.
    func resealAfterKeyChange() {
        // Not before a list loaded from the server: an unloaded circle can't
        // be judged, and the first load's look (every circle "moved") follows.
        guard CircleManager.shared.circlesLoaded else { return }
        let circles = CircleManager.shared.circles
        let look = Self.movedCircles(held: circles.map { ($0.id, CircleManager.shared.heldVersion(for: $0.id)) },
                                     seen: resealSeen)
        resealSeen = look.seen
        guard !look.moved.isEmpty else { return }
        Task {
            guard let listed = try? await api.getActiveSOSAlerts() else { return }
            _ = await resealOwn(listed.filter { look.moved.contains(CanonicalId.key($0.circleId)) })
        }
    }

    // MARK: - Keeping this device's own alert updated

    /// Keep this device's own open alert updated, from its raise or its restore
    /// until it closes: every fix this phone takes from the press on (emergency
    /// mode's Best polls, and the precise fix when it lands) is offered as an
    /// after-press fix; location access going off may be `updateDue`'s (d); the
    /// window's end is (e); and every `keyCheckInterval`, for the whole alert,
    /// the key check. Emergency mode's polls keep the process running for the
    /// timers.
    private func startUpdateWatch(alertId: String, circleId: String, pressAt: Date, raisedAt: Date) {
        stopUpdateWatch()
        watchedAlertId = alertId
        let key = CanonicalId.key(alertId)
        if afterPress[key] == nil { afterPress[key] = AfterPress() }
        locationService.locationUpdates
            .receive(on: DispatchQueue.main)
            .sink { [weak self] fix in
                Task { @MainActor in self?.offer(fix, alertId: alertId, pressAt: pressAt) }
            }
            .store(in: &watchSinks)
        locationService.$authorizationStatus
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.updateIfDue(alertId) }
            }
            .store(in: &watchSinks)
        let windowEnd = pressAt.addingTimeInterval(Self.updateWindow)
        if windowEnd > Date() {
            windowEndTimer = Timer.scheduledTimer(withTimeInterval: windowEnd.timeIntervalSinceNow + 1,
                                                  repeats: false) { [weak self] _ in
                Task { @MainActor in self?.updateIfDue(alertId) }
            }
        }
        keyCheckTimer = Timer.scheduledTimer(withTimeInterval: Self.keyCheckInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkKey(alertId: alertId, circleId: circleId, raisedAt: raisedAt) }
        }
    }

    private func stopUpdateWatch() {
        watchedAlertId = nil
        watchSinks.removeAll()
        windowEndTimer?.invalidate()
        windowEndTimer = nil
        keyCheckTimer?.invalidate()
        keyCheckTimer = nil
        keyCheckSeen = nil
    }

    /// A fix this phone took, offered as the watched alert's
    /// after-press fix.
    private func offer(_ fix: CLLocation, alertId: String, pressAt: Date) {
        guard CanonicalId.same(watchedAlertId, alertId) else { return }
        afterPress[CanonicalId.key(alertId), default: AfterPress()].offer(fix, pressAt: pressAt)
        updateIfDue(alertId)
    }

    /// A run, when the update rule has something to seal for the watched alert
    /// by its record; without one (a reinstall, or an alert an earlier version
    /// of the app raised), within its window, or after it while it still shows
    /// "pending" (`updateDue`'s (e)).
    private func updateIfDue(_ alertId: String) {
        guard CanonicalId.same(watchedAlertId, alertId) else { return }
        if let record = SOSSealedPositions.shared.record(alertId: alertId, owner: AuthManager.shared.userId) {
            guard Self.updateDue(record, fixes: afterPress[CanonicalId.key(alertId)] ?? AfterPress(),
                                 locationOff: Self.locationOff(locationService.authorizationStatus),
                                 now: Date()) != nil else { return }
        } else {
            guard let mine = myActiveAlert, CanonicalId.same(mine.id, alertId),
                  Date() < mine.createdAt.addingTimeInterval(Self.updateWindow) || mine.positionMarker == .pending
            else { return }
        }
        runUpdate(alertId)
    }

    /// Every `keyCheckInterval` while this device's own alert is open (all of
    /// it, not only the update window): a light read of the circle's listed
    /// key version; only when that moved, the key fetch (a light circle load)
    /// and a run. Past the alarm age by its sealed time, its record goes and
    /// the check stops.
    private func checkKey(alertId: String, circleId: String, raisedAt: Date) async {
        guard CanonicalId.same(watchedAlertId, alertId) else { return }
        guard Date().timeIntervalSince(raisedAt) * 1000 <= Double(Self.maxAlarmAgeMs) else {
            SOSSealedPositions.shared.forget(alertId: alertId, owner: AuthManager.shared.userId)
            stopUpdateWatch()
            return
        }
        guard let listed = try? await api.getCircleList().circles.first(where: { CanonicalId.same($0.id, circleId) }),
              Self.keyMoved(listed: listed.keyVersion, seen: keyCheckSeen,
                            held: CircleManager.shared.heldVersion(for: circleId))
        else { return }
        keyCheckSeen = listed.keyVersion
        try? await CircleManager.shared.loadCircles(light: true)
        runUpdate(alertId)
    }

    /// Pure: whether the listed key version moved from the one last
    /// seen, or, before any, from the one held.
    nonisolated static func keyMoved(listed: Int, seen: Int?, held: Int?) -> Bool {
        listed != (seen ?? held)
    }

    /// Alerts the MAP should draw: live, not handled by this viewer, and with
    /// coordinates that decrypted. Cross-circle by design.
    var mappableAlerts: [SOSAlert] {
        activeAlerts.filter { $0.isMappable }
    }

    /// A circle this account is in no more (`CircleManager.circleGone`): its
    /// members' alerts, positions and all, leave the map and the list now, not
    /// at the next load, which no longer serves them.
    func forgetCircle(_ circleId: String) {
        let kept = activeAlerts.withoutCircle(circleId) { $0.circleId }
        if kept.count != activeAlerts.count { activeAlerts = kept }
    }

    /// RFC 3339 → Date. nil when absent or unparseable.
    private nonisolated static func parseInstant(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFractional.date(from: raw) { return d }
        return ISO8601DateFormatter().date(from: raw)
    }

    /// What the Safety LIST shows. Dismissing hides an alert here — the viewer
    /// said "stop showing me this" — but acknowledging does not, so a responder
    /// who acknowledged still has the way back to the location. Matches the
    /// Android app's `SosAlertDao.observeActive` (`dismissedByMe = 0`).
    var visibleAlerts: [SOSAlert] {
        // A dismissed alert lingers for its grace window so a mistaken tap can
        // be undone — it is already off the map, and this row is the only way
        // back. Live alerts sort first.
        activeAlerts
            .filter { !$0.dismissedByMe || $0.isWithinDismissGrace() }
            .sorted { a, b in
                if a.dismissedByMe != b.dismissedByMe { return !a.dismissedByMe }
                return a.createdAt > b.createdAt
            }
    }

    /// The Alerts tab's badge: what that tab still asks of this person, other
    /// people's live alerts they haven't dismissed. Their own alert is on its
    /// own card; a closed one asks nothing (a close updates its row here until
    /// the next load); a dismissed one is only waiting out its undo window.
    var badgeCount: Int { Self.badgeCount(activeAlerts, me: AuthManager.shared.userId) }

    nonisolated static func badgeCount(_ alerts: [SOSAlert], me: String?) -> Int {
        othersLive(alerts, me: me).filter { !$0.dismissedByMe }.count
    }

    /// Other people's live alerts: the Alerts tab's "Active Alerts", and so its
    /// badge. Whose alert it is, is the canonical compare.
    nonisolated static func othersLive(_ alerts: [SOSAlert], me: String?) -> [SOSAlert] {
        alerts.filter { !CanonicalId.same($0.userId, me) && $0.status.isLive }
    }

    /// Hide an alert for THIS user only. Private: no other member is told, the
    /// alert stays active for them, and nothing is closed. Distinct from
    /// `acknowledgeSOS` (an outward "I'm responding") and from `resolveSOS`
    /// (closes it for the whole circle, raiser/admin only).
    func dismissSOS(_ alert: SOSAlert) async throws {
        let response = try await api.dismissSOS(alertId: alert.id)
        if let index = activeAlerts.firstIndex(where: { $0.id == alert.id }) {
            activeAlerts[index].dismissedByMe = true
            activeAlerts[index].dismissedAt = Self.parseInstant(response.dismissedAt) ?? Date()
        }
        stopAlarmSound()
    }

    /// Undo a dismissal inside the grace window. Clears the flag, which restores
    /// the Safety row to normal AND puts the marker back on the map — both are
    /// derived from dismissedByMe, so one call restores both surfaces.
    func undismissSOS(_ alert: SOSAlert) async throws {
        _ = try await api.undismissSOS(alertId: alert.id)
        if let index = activeAlerts.firstIndex(where: { $0.id == alert.id }) {
            activeAlerts[index].dismissedByMe = false
            activeAlerts[index].dismissedAt = nil
        }
    }

    // MARK: - Polling

    /// The raiser's status poll is fast only while the alert is fresh AND the
    /// raiser is looking, and backs off (a fixed 5 s timer would be 720 GETs an
    /// hour, in the background too, for as long as an emergency stays open):
    static let statusPollFastSeconds: TimeInterval = 5
    static let statusPollMediumSeconds: TimeInterval = 30
    static let statusPollSlowSeconds: TimeInterval = 120
    /// The first minute polls fast; up to ten minutes at the medium cadence.
    static let statusPollFastWindow: TimeInterval = 60
    static let statusPollMediumWindow: TimeInterval = 10 * 60
    /// Never faster than this while the app is in the background.
    static let statusPollBackgroundFloorSeconds: TimeInterval = 120
    /// Once somebody has acknowledged, the fast poll's job is done — the raiser
    /// knows help is aware, and later acknowledgments arrive by push. What is
    /// left is a slow CLOSURE check: if the alert is resolved elsewhere and
    /// that push is lost, this is what switches the phone out of emergency
    /// mode's 20 s Best-accuracy polls instead of leaving them running.
    static let statusPollAcknowledgedSeconds: TimeInterval = 15 * 60

    /// When the next status poll is due. Pure so the schedule is testable.
    nonisolated static func statusPollDelay(
        elapsed: TimeInterval,
        appActive: Bool,
        acknowledged: Bool
    ) -> TimeInterval {
        if acknowledged { return statusPollAcknowledgedSeconds }
        let base: TimeInterval
        if elapsed < statusPollFastWindow {
            base = statusPollFastSeconds
        } else if elapsed < statusPollMediumWindow {
            base = statusPollMediumSeconds
        } else {
            base = statusPollSlowSeconds
        }
        return appActive ? base : max(base, statusPollBackgroundFloorSeconds)
    }

    /// The responders `GET /sos/{id}` served for `alertId`, kept only for this
    /// device's own alert (`mine`): each once, in its one form, in the
    /// server's order (oldest first); an entry that is no id is dropped. nil:
    /// not served (an older server, or not the raiser), or not ours.
    nonisolated static func servedResponders(_ own: OwnSOSResponse, alertId: String, mine: String?) -> [String]? {
        guard CanonicalId.same(alertId, mine), CanonicalId.same(own.alert.id, alertId),
              let served = own.acknowledgedBy else { return nil }
        var seen = Set<String>()
        return served.compactMap { CanonicalId.of($0) }.filter { seen.insert($0).inserted }
    }

    /// The asker's line for who is responding to `alert`, named as every
    /// named surface names: a member this device shows whose sealed name
    /// opened here (`openedName`), else "Someone". nil when it isn't this
    /// device's own alert, nobody is responding, or the list wasn't served:
    /// the screens then show the count alone.
    func respondingLine(for alert: SOSAlert) -> String? {
        let circles = CircleManager.shared
        return Self.respondingLine(for: alert, mine: myActiveAlert?.id, responders: responders,
                                   me: AuthManager.shared.userId, members: circles.members,
                                   opened: circles.openedNames)
    }

    /// `respondingLine(for:)` from what this device holds: its own alert's id
    /// (`mine`), the served responders, and the roster and opened names as
    /// `CircleManager` keeps them (by circle id in its one form).
    nonisolated static func respondingLine(for alert: SOSAlert, mine: String?, responders: [String: [String]],
                                           me: String?, members: [String: [CircleMember]],
                                           opened: [String: Set<String>]) -> String? {
        guard CanonicalId.same(alert.id, mine), let circleId = CanonicalId.circle(alert.circleId) else { return nil }
        return NamedNotificationCopy.responding(responders[CanonicalId.key(alert.id)], me: me) {
            openedName(of: $0, in: members[circleId], opened: opened[circleId])
        }
    }

    /// Somebody has acknowledged. Acknowledging records a per-viewer fact and
    /// bumps a count, and only older rows say so in the shared `status`, so
    /// both are read.
    nonisolated static func isAcknowledged(
        status: SOSAlert.SOSStatus,
        acknowledgmentCount: Int?
    ) -> Bool {
        status == .acknowledged || (acknowledgmentCount ?? 0) > 0
    }

    private func startAlertPolling(alertId: String, raisedAt: Date = Date()) {
        stopAlertPolling()
        alertPollAlertId = alertId
        alertPollStartedAt = raisedAt
        scheduleNextAlertPoll()
    }

    private func scheduleNextAlertPoll() {
        alertPollingTimer?.invalidate()
        alertPollingTimer = nil
        guard let alertId = alertPollAlertId, let raisedAt = alertPollStartedAt else { return }
        let delay = Self.statusPollDelay(
            elapsed: Date().timeIntervalSince(raisedAt),
            appActive: appIsActive,
            acknowledged: alertAcknowledged
        )
        let timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in await self?.runAlertPoll(alertId: alertId) }
        }
        timer.tolerance = delay * 0.1
        alertPollingTimer = timer
    }

    private func runAlertPoll(alertId: String) async {
        guard alertPollAlertId == alertId else { return }
        await pollAlertStatus(alertId: alertId)
        // Still the alert being watched (a close would have cleared it)?
        if alertPollAlertId == alertId { scheduleNextAlertPoll() }
    }

    private func stopAlertPolling() {
        alertPollingTimer?.invalidate()
        alertPollingTimer = nil
        alertPollAlertId = nil
        alertPollStartedAt = nil
        alertAcknowledged = false
    }

    /// The raiser's alert is over: stop watching it and leave emergency mode.
    /// What this device sealed for it goes too.
    private func closeMyAlert(_ alertId: String) {
        if alertPollAlertId == alertId { stopAlertPolling() }
        // Its "Did it get through?" ends with it.
        if let delivery, CanonicalId.same(delivery.alertId, alertId) { clearDelivery() }
        if let deliveryNotice, CanonicalId.same(deliveryNotice.alertId, alertId) { self.deliveryNotice = nil }
        responders[CanonicalId.key(alertId)] = nil
        SOSSealedPositions.shared.forget(alertId: alertId, owner: AuthManager.shared.userId)
        if CanonicalId.same(watchedAlertId, alertId) { stopUpdateWatch() }
        afterPress[CanonicalId.key(alertId)] = nil
        pressCircles[CanonicalId.key(alertId)] = nil
        rotationDeferredSince[CanonicalId.key(alertId)] = nil
        rotationRechecks.removeValue(forKey: CanonicalId.key(alertId))?.invalidate()
        if CanonicalId.same(shownFromElsewhere, alertId) { shownFromElsewhere = nil }
        if myActiveAlert?.id == alertId {
            myActiveAlert = nil
            myPosition = nil
            hasActiveAlert = false
        }
        if myActiveAlert == nil {
            locationService.setEmergencyMode(false)
        }
    }

    private func pollAlertStatus(alertId: String) async {
        do {
            // GET /api/v1/sos/:id returns a server-blind SOSResponse — the
            // wire shape matches /sos/active, and to the raiser it also says
            // who is responding (`OwnSOSResponse`). We already hold the
            // decrypted SOSAlert locally; this poll is only interested in the
            // status transition, the acknowledgment count and the responders,
            // so translate those and mutate the cached model in-place rather
            // than re-decrypting every field.
            let own = try await api.getOwnSOSAlert(alertId: alertId)
            let response = own.alert
            let newStatus = SOSAlert.SOSStatus.from(response.status)
            let resolvedAt = response.resolvedDayBucket
                .map { Date(timeIntervalSince1970: TimeInterval($0) * 86_400) }

            if let index = activeAlerts.firstIndex(where: { $0.id == alertId }) {
                activeAlerts[index].status = newStatus
                activeAlerts[index].resolvedAt = resolvedAt
                if let count = response.acknowledgmentCount {
                    activeAlerts[index].acknowledgmentCount = count
                }
            }

            if myActiveAlert?.id == alertId {
                myActiveAlert?.status = newStatus
                myActiveAlert?.resolvedAt = resolvedAt
                // The raiser's card reads this count, and nothing else
                // writes it: without this, "N acknowledged" would never
                // appear on the one screen that most needs it.
                if let count = response.acknowledgmentCount {
                    myActiveAlert?.acknowledgmentCount = count
                }
                // Who is responding: served here, to the raiser alone.
                if let served = Self.servedResponders(own, alertId: alertId, mine: myActiveAlert?.id) {
                    responders[CanonicalId.key(alertId)] = served
                }
            }

            // Check if alert was resolved externally
            if newStatus.isClosed {
                closeMyAlert(alertId)
            } else if Self.isAcknowledged(status: newStatus, acknowledgmentCount: response.acknowledgmentCount) {
                alertAcknowledged = true
            }
        } catch {
            print("Failed to poll alert status: \(error)")
        }
    }

    /// Keep the raiser's own alert in step with the server's active list —
    /// the ack and resolve pushes land here, via `loadActiveAlerts`.
    ///
    /// - Present: copy the status and count across; closed → close it; newly
    ///   acknowledged → the slow closure check.
    /// - Absent: the server lists only live alerts, so it was most likely
    ///   closed elsewhere. Ask about it directly before retiring it, so a
    ///   momentary gap in the list cannot end an emergency.
    /// - No `myActiveAlert` but a live alert this DEVICE raised: the process
    ///   restarted mid-emergency and lost it. Restore it, emergency mode and
    ///   the poll included.
    /// - Else one this ACCOUNT raised on another device, or on this one before
    ///   a sign-out: shown with its poll and its close once the server says it
    ///   is the caller's own, and nothing more (`OwnRestore`).
    private func reconcileMyAlert(with alerts: [SOSAlert], raisedHere: Set<String>, listed: Set<String>) async {
        if let mine = myActiveAlert {
            if let fresh = alerts.first(where: { $0.id == mine.id }) {
                myActiveAlert?.status = fresh.status
                myActiveAlert?.acknowledgmentCount = max(mine.acknowledgmentCount, fresh.acknowledgmentCount)
                if fresh.status.isClosed {
                    closeMyAlert(mine.id)
                } else if alertPollAlertId == mine.id, !alertAcknowledged,
                          Self.isAcknowledged(status: fresh.status, acknowledgmentCount: fresh.acknowledgmentCount) {
                    alertAcknowledged = true
                    scheduleNextAlertPoll()
                }
                // Someone new is responding: who, the alert itself says (GET
                // /sos/{id}, the raiser's alone), never this list. Once anyone
                // has, the poll is down to a slow closure check.
                if !fresh.status.isClosed, fresh.acknowledgmentCount > mine.acknowledgmentCount {
                    await pollAlertStatus(alertId: mine.id)
                }
            } else if CanonicalId.same(shownFromElsewhere, mine.id), !listed.contains(CanonicalId.key(mine.id)) {
                // Shown from elsewhere and no longer listed at all: it ended,
                // or is no longer its circle's. The card goes, and the raise is
                // free again. Nothing of this device's ran for it.
                closeMyAlert(mine.id)
            } else if let response = try? await api.getSOSAlert(alertId: mine.id),
                      SOSAlert.SOSStatus.from(response.status).isClosed {
                closeMyAlert(mine.id)
            }
        } else if let own = Self.ownToRestore(alerts, raisedHere: raisedHere, me: AuthManager.shared.userId) {
            let restored = own.alert
            if !own.keepsItUpdated {
                // Raised by this account, not by this device: the asker's card
                // with its responders and its close. The raise stays on
                // (`raiseIsOff`): this phone can't keep it updated, so a fresh
                // press makes one that does. Nothing of this device's goes into
                // it: no emergency mode, no position updates, no re-seal
                // (`resealChoice` takes `raisedHere` alerts alone).
                guard let served = try? await api.getOwnSOSAlert(alertId: restored.id),
                      Self.ownConfirmed(served, alertId: restored.id), myActiveAlert == nil else { return }
                myActiveAlert = restored
                shownFromElsewhere = restored.id
                myPosition = nil
                hasActiveAlert = true
                responders[CanonicalId.key(restored.id)] = Self.servedResponders(served, alertId: restored.id,
                                                                                 mine: restored.id)
                startAlertPolling(alertId: restored.id, raisedAt: restored.createdAt)
                if Self.isAcknowledged(status: restored.status, acknowledgmentCount: restored.acknowledgmentCount) {
                    alertAcknowledged = true
                    scheduleNextAlertPoll()
                }
                return
            }
            myActiveAlert = restored
            let record = SOSSealedPositions.shared.record(alertId: restored.id, owner: AuthManager.shared.userId)
            myPosition = record
            hasActiveAlert = true
            locationService.setEmergencyMode(true)
            startAlertPolling(alertId: restored.id, raisedAt: restored.createdAt)
            if Self.isAcknowledged(status: restored.status, acknowledgmentCount: restored.acknowledgmentCount) {
                alertAcknowledged = true
                scheduleNextAlertPoll()
            }
            // Its updates go on, the window counted from the press this
            // device recorded, else the sealed raise time. Every run waits for
            // the primed key state first.
            let pressAt = record.map { Date(timeIntervalSince1970: TimeInterval($0.pressAtMs) / 1000) }
                ?? restored.createdAt
            startUpdateWatch(alertId: restored.id, circleId: restored.circleId, pressAt: pressAt,
                             raisedAt: restored.createdAt)
            updateIfDue(restored.id)
        }
    }

    /// What showing this account's own open alert again does, decided apart
    /// from doing it.
    struct OwnRestore: Equatable {
        let alert: SOSAlert
        /// Its sealed device id is this device's.
        let raisedHere: Bool
        /// Emergency mode, its position updates and its re-seals: only
        /// for the device that raised it, which alone holds what it sealed.
        /// One that didn't never seals anything into it.
        var keepsItUpdated: Bool { raisedHere }
    }

    /// Pure: the account's own open alert to show again when none is shown.
    /// One this device raised comes first (a restart lost it). Else the newest
    /// live one the account raised anywhere: on another device, or on this one
    /// before a sign-out, which takes the device id with the keychain, so it
    /// would be shown nowhere and could be closed nowhere. "Raised by this
    /// account" is the sealed raiser id; the server's word comes too before one
    /// raised elsewhere shows (`ownConfirmed`).
    nonisolated static func ownToRestore(_ alerts: [SOSAlert], raisedHere: Set<String>, me: String?) -> OwnRestore? {
        let live = alerts.filter { $0.status.isLive }
        if let here = live.first(where: { raisedHere.contains($0.id) }) {
            return OwnRestore(alert: here, raisedHere: true)
        }
        guard let mine = live.filter({ CanonicalId.same($0.userId, me) }).max(by: { $0.createdAt < $1.createdAt })
        else { return nil }
        return OwnRestore(alert: mine, raisedHere: false)
    }

    /// Pure: the server's word that `alertId` is the caller's own, live alert.
    /// `GET /sos/{id}` serves who is responding to the raiser alone
    /// (`acknowledged_by`, absent for anyone else), and any member holding the
    /// circle key could seal an alert under this account's id.
    nonisolated static func ownConfirmed(_ own: OwnSOSResponse, alertId: String) -> Bool {
        CanonicalId.same(own.alert.id, alertId) && own.acknowledgedBy != nil
            && SOSAlert.SOSStatus.from(own.alert.status).isLive
    }

    // MARK: - Audio

    private func playAlarmSound() {
        guard let soundURL = Bundle.main.url(forResource: "sos_alarm", withExtension: "mp3") else {
            // Fall back to system sound
            AudioServicesPlaySystemSound(SystemSoundID(1005))
            return
        }

        do {
            audioPlayer = try AVAudioPlayer(contentsOf: soundURL)
            audioPlayer?.numberOfLoops = -1 // Loop indefinitely
            audioPlayer?.play()
        } catch {
            print("Failed to play alarm sound: \(error)")
        }
    }

    private func stopAlarmSound() {
        audioPlayer?.stop()
        audioPlayer = nil
    }

    // MARK: - Quick SOS

    func quickTriggerSOS() async {
        guard let activeCircle = CircleManager.shared.activeCircle else {
            // Silently returning here would mean tapping the button with no
            // active circle did nothing at all, with no explanation.
            lastTriggerError = "No active circle — join or create one before notifying anyone."
            return
        }

        do {
            let alert = try await triggerSOS(for: activeCircle.id)
            lastTriggerError = nil
            // Start asking whether it actually landed. The server storing the
            // alert says nothing about that on its own.
            watchDelivery(alertId: alert.id)
        } catch {
            // Shown in the app's words; the server's stay in the log. A
            // bare `print` would be invisible to the user and to any log
            // collector: the SOS would appear to send and simply never
            // arrive.
            lastTriggerError = error.plainText
            let logged = (error as? APIError).map { "\($0.code): \($0.message)" } ?? error.localizedDescription
            Self.log.error("SOS trigger failed: \(logged, privacy: .public)")
        }
    }

    // MARK: - Delivery

    /// Poll until the answer can no longer improve. `partial` and
    /// `no_confirmation` keep polling because a late confirmation genuinely
    /// arrives — a phone that was asleep can confirm tens of seconds in — while
    /// `confirmed` and `alone` are final on sight. `undeliverable` is NOT
    /// accepted as final until `deliverySettleWindow` has passed: the first
    /// poll happens immediately, and a server that reports it in the first
    /// moments after sending, before its dispatch record is written, would
    /// tell the raiser nobody had been reached about a notification still in
    /// flight.
    func watchDelivery(alertId: String) {
        deliveryTask?.cancel()
        delivery = DeliveryStatus(alertId: alertId, response: nil, stillChecking: true)

        deliveryTask = Task { [weak self] in
            guard let self else { return }
            let deadline = ContinuousClock.now + Self.deliveryPollWindow
            let settleAt = ContinuousClock.now + Self.deliverySettleWindow

            while !Task.isCancelled {
                if let result = try? await self.api.getSOSDelivery(alertId: alertId) {
                    let settled = ContinuousClock.now >= settleAt
                    let terminal = result.state == "confirmed"
                        || (result.state == "undeliverable" && settled)
                        || result.state == "alone"
                    await MainActor.run {
                        self.delivery = DeliveryStatus(
                            alertId: alertId,
                            response: result,
                            stillChecking: !terminal
                        )
                    }
                    if terminal { return }
                }

                if ContinuousClock.now >= deadline {
                    await MainActor.run {
                        self.delivery?.stillChecking = false
                    }
                    return
                }
                try? await Task.sleep(for: Self.deliveryPollInterval)
            }
        }
    }

    /// Forget the delivery answer and stop polling: the alert ended, or a
    /// sign-out.
    func clearDelivery() {
        deliveryTask?.cancel()
        deliveryTask = nil
        delivery = nil
    }

    /// Tell the server a push for [alertId] reached this device.
    ///
    /// Best-effort and deliberately silent: nothing the user does depends on
    /// it, and the notification must not be disturbed because a bookkeeping
    /// call failed. If it does not land the raiser sees "no confirmation"
    /// rather than "confirmed" — pessimistic, which is the right direction.
    func reportReceipt(alertId: String) async {
        do {
            try await api.reportSOSReceipt(alertId: alertId)
        } catch {
            Self.log.debug("SOS receipt for \(alertId, privacy: .public) not reported")
        }
    }

    private static let log = Logger(subsystem: "com.pingolin.track", category: "SOS")

    // MARK: - Reset

    /// Clear all decrypted SOS state and tear down the polling timer + alarm
    /// on logout. `activeAlerts` / `myActiveAlert` hold DECRYPTED SOS
    /// coordinates + member ids, and the `alertPollingTimer` would
    /// otherwise keep firing against the signed-out session. Called from
    /// AuthManager.logout alongside the other managers. Leaves emergency
    /// mode too: a signed-out phone has no emergency to report.
    func reset() {
        activeAlerts = []
        myActiveAlert = nil
        shownFromElsewhere = nil
        myPosition = nil
        responders = [:]
        hasActiveAlert = false
        rangHere = []
        reseals = [:]
        resealSeen = [:]
        keyRefreshTried = [:]
        updateRuns.reset()
        stopUpdateWatch()
        afterPress = [:]
        pressCircles = [:]
        relabelNoted = []
        rotationDeferredSince = [:]
        rotationRechecks.values.forEach { $0.invalidate() }
        rotationRechecks = [:]
        stopAlertPolling()
        clearDelivery()
        deliveryNotice = nil
        saidDeliveryNotice = []
        stopAlarmSound()
        locationService.setEmergencyMode(false)
    }


    /// Build the E2EE CreateSOSRequest, POST it, and assemble a SOSAlert.
    /// Mirrors the Android app's SOSRepository: encrypt user_id, device_id,
    /// timestamp, location, and (optional) device-state with the circle key,
    /// stamp the day_bucket. The cleartext we just sent is kept locally so
    /// the UI doesn't need a decrypt round-trip to render its own alert.
    private func triggerSOSOverWire(
        circleId: String,
        payload: RaisePayload,
        message: String?
    ) async throws -> (alert: SOSAlert, sealedLocation: EncryptedBlobRequest, sealedTime: EncryptedBlobRequest) {
        guard let userId = AuthManager.shared.userId else {
            throw APIError(code: "unauthorized", message: "No user id available")
        }
        let deviceId = AuthManager.shared.deviceId ?? "unknown"
        let now = Date()
        // Deliberately NOT gated on `CircleManager.holdsCurrentKey(for:)`, unlike
        // every other thing this app seals for a circle. On a device a rotation
        // left behind, the key it still holds is also held by the rest of the
        // circle (the key chain keeps old versions readable), so an SOS sealed
        // under it reaches the family — and, with the server's help, the member
        // that rotation removed — who could read that key already. Holding it
        // back would reach nobody, and an SOS that reaches nobody is the worse
        // outcome.
        let (response, sealedLocation, sealedTime) = try await Self.sendCreate(
            circleId: circleId, userId: userId, deviceId: deviceId, payload: payload, raisedAt: now, message: message,
            crypto: cryptoManager, post: { [api] request in try await api.triggerSOS(circleId: circleId, request: request) })

        let position: Location? = { if case .position(let location) = payload { return location }; return nil }()
        let marker: SOSPositionMarker? = { if case .marker(let marker) = payload { return marker }; return nil }()
        let alert = SOSAlert(
            id: response.id,
            circleId: response.circleId,
            userId: userId,
            status: SOSAlert.SOSStatus.from(response.status),
            latitude: position?.latitude,
            longitude: position?.longitude,
            acknowledgedBy: [],
            createdAt: now,
            resolvedAt: nil,
            positionTakenAt: position.map { Date(timeIntervalSince1970: TimeInterval($0.timestamp) / 1000) },
            positionAccuracy: position?.accuracy,
            positionMarker: marker
        )
        return (alert, sealedLocation, sealedTime)
    }

    /// The create, sent: its body (`createRequest`) through `post`, and the
    /// location blob THIS DEVICE sealed in it, which its record is opened
    /// from. Never the response's `encrypted_location`: that is what the
    /// server keeps, served like any read, and a server that echoes another
    /// position must not write it into the record.
    static func sendCreate(circleId: String, userId: String, deviceId: String, payload: RaisePayload, raisedAt: Date,
                           message: String?, crypto: CryptoManager,
                           post: (CreateSOSRequest) async throws -> SOSResponse) async throws
        -> (response: SOSResponse, sealedLocation: EncryptedBlobRequest, sealedTime: EncryptedBlobRequest) {
        let request = try createRequest(circleId: circleId, userId: userId, deviceId: deviceId, payload: payload,
                                        raisedAt: raisedAt, message: message, crypto: crypto)
        return (try await post(request), request.encryptedLocation, request.encryptedTimestamp)
    }

    /// The create's body: user id, device id, the raise time and any message
    /// sealed as usual, and the position as chosen (`raisePayload`): a
    /// `Location` whose `timestamp` is its CAPTURE time and whose accuracy is
    /// set, or a marker's exact bytes under the "location" field tag
    /// (`SOSPositionMarker`). The raise time (`encrypted_timestamp`) is when it
    /// was raised.
    static func createRequest(circleId: String, userId: String, deviceId: String, payload: RaisePayload,
                              raisedAt now: Date, message: String?, crypto cryptoManager: CryptoManager) throws
        -> CreateSOSRequest {
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let dayBucket = Int(now.timeIntervalSince1970 / 86_400)

        // Sealed under the key held, never gated: `triggerSOSOverWire` says why.
        let encUser = try cryptoManager.encryptDataV2(circleId: circleId, plaintext: userId, fieldTag: "user_id")
        let encDevice = try cryptoManager.encryptDataV2(circleId: circleId, plaintext: deviceId, fieldTag: "device_id")
        let encTimestamp = try cryptoManager.encryptDataV2(circleId: circleId, plaintext: String(nowMs), fieldTag: "timestamp")

        let encLoc: EncryptedData
        switch payload {
        case .position(let location):
            encLoc = try cryptoManager.encryptLocation(circleId: circleId, location: location)
        case .marker(let marker):
            encLoc = try cryptoManager.encryptDataV2(circleId: circleId, plaintext: marker.rawValue, fieldTag: "location")
        }

        // Optional device state — encrypt the message if the caller supplied
        // one (matches Android, which stuffs the SOS message into the
        // device-state slot).
        var encDeviceState: EncryptedBlobRequest? = nil
        if let msg = message {
            let blob = try cryptoManager.encryptDataV2(circleId: circleId, plaintext: msg, fieldTag: "device_state")
            encDeviceState = EncryptedBlobRequest(nonce: blob.nonce, ciphertext: blob.ciphertext)
        }

        return CreateSOSRequest(
            deviceId: deviceId,
            circleId: circleId,
            encryptedLocation: EncryptedBlobRequest(nonce: encLoc.nonce, ciphertext: encLoc.ciphertext),
            encryptedDeviceState: encDeviceState,
            encryptedUserId: EncryptedBlobRequest(nonce: encUser.nonce, ciphertext: encUser.ciphertext),
            encryptedDeviceId: EncryptedBlobRequest(nonce: encDevice.nonce, ciphertext: encDevice.ciphertext),
            dayBucket: dayBucket,
            encryptedTimestamp: EncryptedBlobRequest(nonce: encTimestamp.nonce, ciphertext: encTimestamp.ciphertext)
        )
    }
}

// AudioToolbox import for system sounds
import AudioToolbox
