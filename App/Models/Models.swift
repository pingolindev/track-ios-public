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

// MARK: - User & Authentication

struct User: Codable, Identifiable, Equatable {
    let id: String
    let email: String
    /// Optional, and it must stay optional: `display_name` is nullable on the
    /// server and the registration form lets it be left blank, so a real
    /// account can and does carry null. Decoded as non-optional, it would make
    /// `getMe()` throw a DecodingError on every login for such an account —
    /// and because that error is neither an APIError nor a URLError it would
    /// fall through to LoginView's generic "Couldn't sign in. Please try
    /// again.", which says nothing about the cause.
    var displayName: String?
    var publicKey: String?
    let createdAt: Date
    /// Optional — the backend /auth/me response does not always
    /// include updated_at; decoding it as non-optional would make
    /// getMe fail on every real login.
    var updatedAt: Date?
    /// Server-stored wrapped keys (master + sharing private). Returned by
    /// GET /api/v1/auth/me. Used during login to derive the sharing private
    /// key for ECDH-unwrapping circle keys (mirrors the Android app + the
    /// Note iOS app). Optional because non-/me endpoints return User without
    /// the key bundle.
    var encryptedKeys: EncryptedKeysResponse?
    var kdfParams: KdfParamsResponse?
    /// Somebody else set this account up and holds its password — a guardian
    /// who created it for a young person. Returned by GET /auth/me, and read
    /// back so the app can tell the account's own user about it.
    /// Optional and defaulted false: a missing value shows no disclosure rather
    /// than accusing a guardian who is not there.
    var guardianManaged: Bool?
    /// The day the creating guardian named as the handover, "YYYY-MM-DD", or
    /// nil if they named none.
    ///
    /// Kept as the server's string and compared lexicographically against
    /// today's ISO date. Decoding it into a Date would buy nothing and
    /// introduce a timezone: a DATE has no zone, and turning it into an instant
    /// is how a prompt fires a day early in one place and a day late in another.
    var guardianHandoverDate: String?
    /// Server-confirmed email verification. Populated by GET /auth/me;
    /// AuthManager mirrors this onto its `emailVerified` Published so
    /// the launch path can route past EmailVerificationView without
    /// waiting for the 5s status poll.
    var emailVerified: Bool?
    /// Proton-style recovery address — a second email that can receive a
    /// password-reset link. From GET /auth/me's `recovery_email` /
    /// `recovery_email_verified`, mapped by the decoder's
    /// `.convertFromSnakeCase`.
    ///
    /// Both optional, and BOTH have to stay optional: the `User` built by
    /// registration, by the offline keychain rebuild and by the UI-test
    /// synthetic session knows neither, and a nil `recoveryEmailVerified` is
    /// how `RecoveryEmailStatus.resolve` tells "not asked yet" apart from
    /// "there isn't one". Appended last so the memberwise-init call sites that
    /// omit trailing optionals keep compiling.
    var recoveryEmail: String?
    var recoveryEmailVerified: Bool?
    /// GET /auth/me's `registration_status`: "approved", "pending" (an
    /// assisted-lane account an admin hasn't decided yet) or "rejected"
    /// (`RegistrationGate`). Optional and appended last, like the two
    /// above: a `User` built here knows none of it.
    var registrationStatus: String?
    /// GET /auth/me's `track_access`, when auth serves it: whether its tokens
    /// reach Track, as the auth server itself computes it (`RegistrationGate`).
    var trackAccess: Bool?
}

struct EncryptedKeysResponse: Codable, Equatable {
    let masterKey: EncryptedBlobResponse
    let sharingPrivateKey: EncryptedBlobResponse
    let signingPrivateKey: EncryptedBlobResponse?
    let sharingPublicKey: String?
    let signingPublicKey: String?
}

struct KdfParamsResponse: Codable, Equatable {
    let salt: String
    let memoryKib: Int
    let iterations: Int
    let parallelism: Int
}

struct Device: Codable, Identifiable, Equatable {
    let id: String
    let userId: String
    var name: String
    let platform: String
    var lastSeenAt: Date
    let createdAt: Date
}

struct AuthTokens: Codable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
}

// MARK: - Circles

struct Circle: Codable, Identifiable, Equatable, Hashable {
    let id: String
    var name: String
    var encryptedKey: String?
    var isOwner: Bool
    var keyRotationNeeded: Bool
    var keyVersion: Int
    let createdAt: Date
    /// Why this circle's name — and everything else sealed under its key —
    /// cannot be read on this device. nil when the name decrypted. `name` is
    /// then `Circle.lockedPlaceholderName`, and the UI explains THIS, by cause.
    var lockReason: CircleLockReason?
    /// Why `keyRotationNeeded` is set, from the server's `key_rotation_cause`
    /// (nil when not set, or from an older server). "member_removed" and
    /// "member_left" mean a departed member's key still opens new locations
    /// until the rotation lands — see `removedMemberStillHasKey`.
    var keyRotationCause: String?
    /// The version the name is sealed under, as the server lists it
    /// (`name_key_version`); nil when it doesn't say. The server's word: no
    /// rule reads it. What opened the name is `nameOpenedUnder`.
    var nameKeyVersion: Int?
    /// The circle-key version whose key opened `name` on this device; nil when
    /// it didn't open. A rotation seals the name again only from the key in
    /// use (`CircleManager.sealableName`).
    var nameOpenedUnder: Int32?

    /// A rotation is pending BECAUSE someone left or was removed: until it
    /// lands, that person's key still opens everything new.
    var removedMemberStillHasKey: Bool {
        keyRotationNeeded && (keyRotationCause == "member_removed" || keyRotationCause == "member_left")
    }

    /// The one placeholder every locked circle shows, whatever the cause.
    static let lockedPlaceholderName = "Locked circle"

    /// Nothing under this circle's key can be read here. Decisions that need
    /// the plaintext name (rotation re-seals it) test this, never the name: a
    /// test on the name could be satisfied by a user naming a circle like the
    /// placeholder.
    var isLocked: Bool { lockReason != nil }

    /// The circle's own name when this device can read it; nil while it shows
    /// the placeholder (copy then says "this circle").
    var readableName: String? {
        isLocked && name == Self.lockedPlaceholderName ? nil : name
    }

    init(id: String, name: String, encryptedKey: String? = nil, isOwner: Bool = false,
         keyRotationNeeded: Bool = false, keyVersion: Int = 1, createdAt: Date = Date(),
         lockReason: CircleLockReason? = nil, keyRotationCause: String? = nil, nameKeyVersion: Int? = nil,
         nameOpenedUnder: Int32? = nil) {
        self.id = id
        self.name = name
        self.encryptedKey = encryptedKey
        self.isOwner = isOwner
        self.keyRotationNeeded = keyRotationNeeded
        self.keyVersion = keyVersion
        self.createdAt = createdAt
        self.lockReason = lockReason
        self.keyRotationCause = keyRotationCause
        self.nameKeyVersion = nameKeyVersion
        self.nameOpenedUnder = nameOpenedUnder
    }
}

/// Why a circle is locked on this device. Chosen from what this device
/// actually observed while installing the circle's key, so the explanation
/// names the real cause: a keyless invite, a refused wrap, the user's own
/// password reset, and "your keys never unlocked here" all look identical on
/// screen and need four different actions.
enum CircleLockReason: String, Codable, Equatable, Hashable {
    /// This device holds no account keys at all, so NO circle can be read — a
    /// sign-in that never unlocked them.
    case keysNotUnlocked
    /// The server holds no key for us in this circle yet: joined through an
    /// invite that carried none, waiting for an owner or admin to approve access.
    case awaitingKey
    /// A key was shared, but its signature did not verify against the signer
    /// this device trusts, so it was refused.
    case keyNotVerified
    /// A key was shared, but it was sealed to the keys this account had before
    /// an email password reset (the account has pre-reset data to restore).
    case sealedBeforeReset
    /// A key was shared and could not be opened, with no known reset behind it.
    case keyUnreadable
    /// This device holds a key for the circle, but an older one than its name
    /// is sealed under.
    case keyOutOfDate
    /// The circle moved to a newer key and a rotation deliberately left us out
    /// of it (`member_key_version` < `key_version`): an owner or admin has not
    /// approved our access or our changed keys yet.
    case awaitingNewerKey
    /// Nothing more specific is known.
    case keyUnavailable
}

struct CircleMember: Codable, Identifiable, Equatable {
    var id: String { "\(circleId)_\(userId)" }
    let circleId: String
    let userId: String
    var displayName: String
    var role: MemberRole
    var canSeeRealtime: Bool
    var canSeeHistory: Bool
    /// Whether THIS member may rotate the circle key. Read by
    /// CircleManager's auto-rotation sweep to decide whether this device is an
    /// eligible rotator; see `CircleManager.mayRotate`.
    var canRotateKeys: Bool
    let joinedAt: Date
    /// The version of the circle this member's stored copy opens (the roster's
    /// `key_version`); nil when the server holds none for them yet.
    var keyVersion: Int? = nil
    /// Told by the server that their app is too old to be let back in (the
    /// roster's `update_requested`). Shown as "{name} has been asked to
    /// update Pingolin".
    var updateRequested: Bool = false
    /// The roster's `location_sharing` and the end of a timed pause, read
    /// through `sharing(at:)`. nil from an older server: sharing.
    var locationSharing: String? = nil
    var sharingPausedUntil: Date? = nil
    /// The roster's `history_sharing`: "off" when their location history
    /// isn't shown to this circle. It is still kept, and all of it shows
    /// again when they turn it back on. nil from an older server: on.
    var historySharing: String? = nil

    /// Whether the circle is shown their location history (`historySharing`).
    var sharesHistory: Bool { historySharing != "off" }

    /// Confirmed, but the circle has not opened for them yet: they hold no copy,
    /// or an older one than the circle's. Shown as "{name} · Joining…".
    func isJoining(circleKeyVersion: Int) -> Bool {
        guard let keyVersion else { return true }
        return keyVersion < circleKeyVersion
    }

    enum MemberRole: String, Codable, CaseIterable {
        case owner
        case admin
        case member
    }
}

// MARK: - Privacy Settings

/// One stretch of this account NOT sharing with a circle: paused, or real time
/// off. A late point captured inside one is never sent to that circle
/// (`CirclePauseRecord`).
struct PauseInterval: Codable, Equatable {
    var start: Date
    /// When it actually ended; nil while it runs.
    var end: Date?
    /// A timed pause's planned end. Past it (and the margin), a running
    /// interval stops covering, so a phone that has not refreshed since sends
    /// again on time, as `PrivacySettings.isPaused` lets it.
    var plannedEnd: Date?

    /// The last instant it covers.
    var lastCovered: Date {
        switch (end, plannedEnd) {
        case let (end?, _): return end
        case let (nil, planned?): return planned
        case (nil, nil): return .distantFuture
        }
    }
}

/// One stretch of this account sharing APPROXIMATELY with a circle, and the
/// bubble then. A point captured inside one goes to that circle coarsened to
/// that bubble, whatever the mode when it is sent (`CirclePauseRecord`).
struct ApproximateInterval: Codable, Equatable {
    var start: Date
    /// When it actually ended; nil while it runs.
    var end: Date?
    var radiusMiles: Double
}

struct PrivacySettings: Codable, Equatable {
    let circleId: String
    /// The server's single source of truth for posture: "exact",
    /// "approximate" or "paused" (`privacy_settings.sharing_mode`). Carried
    /// verbatim rather than re-derived, because the booleans below cannot
    /// express every state the column can hold — see `isPaused`.
    var sharingMode: String
    var shareRealtime: Bool
    var shareHistory: Bool
    var shareBattery: Bool
    var bubbleEnabled: Bool
    var bubbleRadius: Double // miles, 1...25 (server rejects anything else)
    var pausedUntil: Date?
    var updatedAt: Date
    /// Opt-out consent (default true): when false, other members can't set
    /// arrival/departure alerts targeting me in this circle.
    var allowAlertsOnMe: Bool = true
    /// When false, the circle sees ONE marker for me — the device named by
    /// `primaryDeviceId`, or my most recent one when that is nil. When true,
    /// every device I have is published as its own marker
    /// (the server dedupes per device pseudonym).
    ///
    /// There is no iOS control for this; it is carried so that a choice
    /// made on web or Android survives an unrelated privacy save from here.
    var showAllDevices: Bool = false
    /// The device `showAllDevices == false` pins visibility to. nil means
    /// "whichever device reported most recently".
    var primaryDeviceId: String?
    /// While paused, the mode the pause returns to: "exact" or "approximate"
    /// (the server's `mode_before_pause`). nil when not paused, and from an
    /// older server: exact.
    var modeBeforePause: String? = nil
    /// When the bubble ends by itself, if it was given an end (web and Android
    /// can; iOS cannot). The server keeps it through a pause, and a pause
    /// returns to approximate only while it has not passed.
    var approximateUntil: Date? = nil
    /// The server's own record of this account's stretches of not sharing
    /// with the circle (`not_sharing_intervals`), by its clock: every one
    /// that has not ended or ended within the last 72 hours. nil from an
    /// older server.
    var notSharingIntervals: [PauseInterval]? = nil
    /// The server's own record of this account's stretches of sharing
    /// approximately with the circle (`approximate_intervals`), by its clock,
    /// with the bubble then: every one that has not ended or ended within the
    /// last 72 hours. nil from an older server.
    var approximateIntervals: [ApproximateInterval]? = nil

    /// Whether this account's points for the circle carry its battery level:
    /// the battery switch AND "Allow alerts on me". The level's only reader
    /// is the low-battery alert about this account, which "Allow alerts on
    /// me" off rules out. The one rule the send (the streamer's
    /// `privacyApplied`) and the wake (`mayShareBattery`) ask.
    var sendsBattery: Bool { shareBattery && allowAlertsOnMe }

    /// Whether what this phone sends to the circle is coarsened to the bubble:
    /// the ONE rule every send site asks (the live stream, check-ins,
    /// destination arrivals, the SOS notice). Approximate mode — and a pause
    /// shares as the mode it returns to. A timed pause ends on this phone at
    /// its deadline, while the row it holds still says "paused" until the next
    /// refresh (in the background, up to an hour); that window must not send
    /// exact points from someone who was sharing approximately. While a pause
    /// runs nothing is sent at all (`isPaused`).
    var sharesApproximately: Bool { sharesApproximately(at: Date()) }

    func sharesApproximately(at now: Date) -> Bool {
        sharingMode == "paused" ? returnsToApproximate(at: now) : bubbleEnabled
    }

    /// The server's rule for leaving a pause (a timed expiry and
    /// `POST …/resume`): back to approximate if that was the mode before it and
    /// the bubble's own end has not passed, otherwise exact. The server's other
    /// condition, a radius on the row, always holds here: a pause keeps it.
    func returnsToApproximate(at now: Date) -> Bool {
        modeBeforePause == "approximate" && (approximateUntil.map { $0 > now } ?? true)
    }

    /// While paused, Bubble Mode shows the mode the pause returns to, by that
    /// rule as of `now`. Asked when a row is read, when the sheet opens and at
    /// Resume: the bubble's own end can pass during the pause, after the last
    /// refresh, and a toggle left on would then bring the bubble back with no
    /// end.
    mutating func alignBubbleWithPause(at now: Date) {
        if sharingMode == "paused" { bubbleEnabled = returnsToApproximate(at: now) }
    }

    /// The person switching Bubble Mode in the sheet. A bubble saved from iOS
    /// has no end (iOS sends none, and the server drops any end on that save),
    /// so the end this row came with no longer holds; keeping it would make
    /// this phone's rule end the bubble early.
    mutating func chooseBubble(_ on: Bool) {
        guard on != bubbleEnabled else { return }
        bubbleEnabled = on
        approximateUntil = nil
    }

    /// The person moving the bubble's radius in the sheet; see `chooseBubble`.
    mutating func chooseBubbleRadius(_ miles: Double) {
        guard miles != bubbleRadius else { return }
        bubbleRadius = miles
        approximateUntil = nil
    }

    /// True whenever the circle cannot see me because of a pause.
    ///
    /// A `paused` row with NO expiry is paused PERMANENTLY: the server only
    /// re-admits a paused member whose `paused_until` is set and has passed.
    /// Reading a missing timestamp as "not paused" would let every send gate
    /// stream for an indefinitely-paused user, and then write the pause away
    /// as "exact" on the next save.
    var isPaused: Bool {
        guard sharingMode == "paused" else { return false }
        return pausedUntil.map { $0 > Date() } ?? true
    }

    /// Pause sharing to this circle. `until == nil` is an indefinite pause —
    /// it stays paused until `resume()`.
    ///
    /// Mode and timestamp move together deliberately: setting `pausedUntil`
    /// alone leaves the mode saying "exact" (nothing pauses), and clearing it
    /// alone leaves the mode saying "paused" with no expiry (paused forever).
    mutating func pause(until: Date?) {
        // As the server records it: the mode the pause will return to, set
        // when a pause begins and kept when a running one is moved.
        if !isPaused { modeBeforePause = bubbleEnabled ? "approximate" : "exact" }
        sharingMode = "paused"
        pausedUntil = until
    }

    /// The sheet's copy once a Pause or Resume it sent at once has been taken:
    /// the posture as the server now holds it, `stored` (mode, pause, Bubble
    /// Mode and what a pause returns to), and the switches the person changed
    /// and hasn't saved, as they were, for Save.
    func adoptingPosture(of stored: PrivacySettings) -> PrivacySettings {
        var sheet = self
        sheet.sharingMode = stored.sharingMode
        sheet.pausedUntil = stored.pausedUntil
        sheet.modeBeforePause = stored.modeBeforePause
        sheet.approximateUntil = stored.approximateUntil
        sheet.bubbleEnabled = stored.bubbleEnabled
        sheet.bubbleRadius = stored.bubbleRadius
        return sheet
    }

    /// Resume sharing: while paused, to the mode the pause returns to as of now
    /// (`alignBubbleWithPause`); otherwise to whatever the bubble toggle says.
    mutating func resume(at now: Date = Date()) {
        alignBubbleWithPause(at: now)
        sharingMode = bubbleEnabled ? "approximate" : "exact"
        pausedUntil = nil
        modeBeforePause = nil
    }

    static func `default`(for circleId: String) -> PrivacySettings {
        PrivacySettings(
            circleId: circleId,
            sharingMode: "exact",
            shareRealtime: true,
            shareHistory: true,
            shareBattery: true,
            bubbleEnabled: false,
            // 1, not 0.5: the server's valid range is the whole miles 1...25,
            // and the request rounds to Int. Anything under 0.5 rounds to 0
            // and is rejected with "must be between 1 and 25".
            bubbleRadius: 1,
            pausedUntil: nil,
            updatedAt: Date()
        )
    }
}

// MARK: - Locations

struct LocationData: Codable, Identifiable, Equatable {
    let id: String
    let circleId: String
    let userId: String
    let deviceId: String
    let latitude: Double
    let longitude: Double
    let altitude: Double?
    let speed: Double?
    let heading: Double?
    let accuracy: Double?
    let batteryLevel: Int?
    let timestamp: Date
    var isSynced: Bool
    let dayBucket: Int
    /// `allow_alerts_on_me` for this member in this circle, as the server
    /// reported it alongside this very fix. Carried for place-alert consent, not
    /// for display. `nil` = unknown = allowed.
    var allowAlertsOnMe: Bool? = nil
    /// Set when the server marked this member "approximate" in this circle:
    /// draw an area, never this point (`ApproximateArea`). nil = drawn as an
    /// ordinary exact point.
    var approximate: ApproximateArea? = nil
    /// The last location a member who switched real-time sharing off shared,
    /// frozen (`/latest`'s `last_known`): drawn grey with "Location sharing
    /// off", and never anything's input but the map and the card.
    var sharingOff = false

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// The same fix drawn at another point (an approximate member's, put on the
    /// senders' grid: `ApproximateAreaMemory.draw`). Everything else is kept.
    func moved(to point: CLLocationCoordinate2D) -> LocationData {
        guard point.latitude != latitude || point.longitude != longitude else { return self }
        var moved = LocationData(id: id, circleId: circleId, userId: userId, deviceId: deviceId,
                                 latitude: point.latitude, longitude: point.longitude, altitude: altitude,
                                 speed: speed, heading: heading, accuracy: accuracy, batteryLevel: batteryLevel,
                                 timestamp: timestamp, isSynced: isSynced, allowAlertsOnMe: allowAlertsOnMe,
                                 approximate: approximate)
        moved.sharingOff = sharingOff
        return moved
    }

    /// This phone's own fix as this account's entry: what the map, the roster
    /// and the member sheet show for this account.
    static func ownPosition(_ fix: CLLocation, userId: String, circleId: String, deviceId: String) -> LocationData {
        LocationData(
            circleId: circleId,
            userId: userId,
            deviceId: deviceId,
            latitude: fix.coordinate.latitude,
            longitude: fix.coordinate.longitude,
            altitude: fix.altitude == 0 ? nil : fix.altitude,
            speed: fix.speed >= 0 ? fix.speed : nil,
            heading: fix.course >= 0 ? fix.course : nil,
            accuracy: fix.horizontalAccuracy,
            batteryLevel: nil,
            timestamp: fix.timestamp
        )
    }

    init(id: String = UUID().uuidString, circleId: String, userId: String, deviceId: String,
         latitude: Double, longitude: Double, altitude: Double? = nil, speed: Double? = nil,
         heading: Double? = nil, accuracy: Double? = nil, batteryLevel: Int? = nil,
         timestamp: Date = Date(), isSynced: Bool = false, allowAlertsOnMe: Bool? = nil,
         approximate: ApproximateArea? = nil) {
        self.id = id
        self.circleId = circleId
        self.userId = userId
        self.deviceId = deviceId
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.speed = speed
        self.heading = heading
        self.accuracy = accuracy
        self.batteryLevel = batteryLevel
        self.timestamp = timestamp
        self.isSynced = isSynced
        self.dayBucket = Int(timestamp.timeIntervalSince1970 / 86400)
        self.allowAlertsOnMe = allowAlertsOnMe
        self.approximate = approximate
    }
}

struct PendingLocation: Codable, Identifiable {
    let id: String
    let circleId: String
    let encryptedPayload: String
    let timestamp: Date
    var retryCount: Int
    let createdAt: Date

    init(id: String = UUID().uuidString, circleId: String, encryptedPayload: String,
         timestamp: Date = Date(), retryCount: Int = 0, createdAt: Date = Date()) {
        self.id = id
        self.circleId = circleId
        self.encryptedPayload = encryptedPayload
        self.timestamp = timestamp
        self.retryCount = retryCount
        self.createdAt = createdAt
    }
}

// MARK: - Places

struct Place: Codable, Identifiable, Equatable {
    /// What a place is called here when its sealed name does not open
    /// (`PlaceManager.decodePlaces`). Never a name to put in a notification.
    static let unopenedName = "Encrypted Place"

    let id: String
    let circleId: String
    var name: String
    var latitude: Double
    var longitude: Double
    /// Effective ring radius in meters: `boundary_radius` when the place
    /// has a boundary attached, else the marker `radius_meters`.
    var radius: Double // meters
    /// Server place_type: "place" (marker) or "boundary" (dedicated
    /// geofence row, created by other clients — iOS always creates
    /// "place" + optional boundaryRadius).
    let placeType: String
    /// Boundary ring radius (meters) when one is attached; nil for a
    /// plain marker. Kept distinct from `radius` so geofencing can tell
    /// monitored boundaries from ordinary places.
    let boundaryRadius: Double?
    /// Server-maintained: true iff an active alert subscription targets this
    /// place. This is the sole switch for enter/leave monitoring ("an alert
    /// turns monitoring on"), as on Android; `place_type` and `boundary_radius`
    /// do not decide it.
    /// `var` (not `let`) so the creator's device can flip it true locally the
    /// instant an alert is enabled and arm its OWN geofence before the next pull
    /// re-derives it server-side.
    var alertsEnabled: Bool
    var icon: PlaceIcon
    var color: String
    let createdAt: Date
    /// Decrypted address text — populated from `encryptedAddress` on
    /// the response when present, surfaced in PlacesView rows + the
    /// place-detail sheet. Matches android's PlaceEntity.address.
    var address: String?
    /// Decrypted notes — matches android's PlaceEntity.notes.
    var notes: String?
    /// Owner-side wrap of the per-place key. Persisted on the
    /// model so PlaceManager.sharePlaceWithCircle can re-derive the
    /// place key locally (unwrap → re-wrap for the new recipient
    /// circle) without a round-trip to /api/v1/places/:id. nil on
    /// legacy circle-key-direct rows.
    var wrappedKey: String?
    var wrappedKeyNonce: String?
    /// targetId the owner-side wrap was made against. For owned
    /// places this is the self-circle UUID; for received shares it's
    /// the circle the wrap arrived through.
    var wrapTargetId: String?
    /// Circles this (personal) place has been SHARED to — the server's
    /// `shared_circles` list, carried through from `PlaceResponse` at decode —
    /// the decoder must not drop it. Empty/nil for a circle-owned place
    /// or an unshared personal place. A boundary crossing on a personal place
    /// fans out over these so the hash + encryption use each sharing circle's
    /// key — the alert is keyed to the real circle, never the self
    /// pseudo-circle. Mirrors the Android app's `PlaceEntity.sharedCircles`.
    var sharedCircles: [String]? = nil

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Only places with an active alert participate in crossing detection: the
    /// single `alerts_enabled` gate decides it, as on Android — monitoring
    /// follows the alert subscription, not the place's type/ring. The monitored
    /// radius is `radius` (= boundary_radius ?? marker radius, resolved at
    /// decode), so an alerted place rings at its boundary size. Keeping the
    /// gate narrow also stays well under iOS's 20-region cap.
    var isGeofenced: Bool {
        alertsEnabled
    }

    /// 18-icon set matched against the Android app's
    /// dialog_create_place.xml + iconHome…iconHeart Material icons.
    /// Raw values stay aligned with the Android-side string keys
    /// (hence `medical`); `custom` stays as the iOS fallback for
    /// legacy rows.
    enum PlaceIcon: String, Codable, CaseIterable {
        case home
        case work
        case school
        case gym
        case restaurant
        case coffee
        case shopping
        case medical
        case park
        case bar
        case gas_station
        case airport
        case hotel
        case parking
        case church
        case library
        case star
        case heart
        case custom

        var systemImage: String {
            switch self {
            case .home: return "house.fill"
            case .work: return "briefcase.fill"
            case .school: return "graduationcap.fill"
            case .gym: return "figure.run"
            case .restaurant: return "fork.knife"
            case .coffee: return "cup.and.saucer.fill"
            case .shopping: return "cart.fill"
            case .medical: return "cross.case.fill"
            case .park: return "leaf.fill"
            case .bar: return "wineglass.fill"
            case .gas_station: return "fuelpump.fill"
            case .airport: return "airplane"
            case .hotel: return "bed.double.fill"
            case .parking: return "parkingsign.circle.fill"
            case .church: return "building.columns.fill"
            case .library: return "books.vertical.fill"
            case .star: return "star.fill"
            case .heart: return "heart.fill"
            case .custom: return "mappin.circle.fill"
            }
        }
    }
}

struct PlaceAlert: Codable, Identifiable, Equatable {
    let id: String
    let placeId: String
    /// Resolved target/creator user id, kept for back-compat with
    /// existing readers. The editor uses `targetUserId` below.
    let userId: String
    var alertType: AlertType
    var isEnabled: Bool

    // Unified place-alert editor fields, matching android. Populated from
    // the rich PlaceAlertResponse so the bell pre-fills on edit; defaulted
    // so the legacy construction sites stay valid.
    /// nil = everyone (encrypts the "all" sentinel on the wire); else a
    /// specific circle member.
    var targetUserId: String? = nil
    var activeDays: [String]? = nil
    var activeStartTime: String? = nil
    var activeEndTime: String? = nil
    var notifyPush: Bool = true
    var notifyEmail: Bool = false
    var notifySms: Bool = false
    /// Server-owned lifecycle flags the bell editor does NOT expose. Carried on
    /// the model so an iOS edit can round-trip them through the UPDATE instead of
    /// clobbering state set on web/Android — the backend UPDATE full-replaces
    /// these columns. `isRecurring` false = a one-shot alert;
    /// `expiresAt` (RFC3339) = auto-expiry. Defaulted so legacy construction
    /// sites stay valid; `isEnabled` above already carries the server's isActive.
    var isRecurring: Bool = true
    var expiresAt: String? = nil
    /// Routing circle for the alert (CreatePlaceAlertRequest.circle_id).
    var circleId: String? = nil
    /// The TARGET has withdrawn `allow_alerts_on_me` in the circle this alert's
    /// consent is anchored to (`PlaceAlertResponse.suppressed_by_target`,
    /// computed server-side so the anchor — the place's circle, falling back to
    /// the subscription's — is resolved in ONE place rather than re-derived on
    /// each client, where the place's circle is not always to hand).
    ///
    /// The alert stays ENABLED and fully configured: withdrawal SUSPENDS it, so
    /// consent returning restores exactly what the subscriber set up. Defaulted
    /// to false so the legacy construction sites stay valid, and so a backend
    /// that does not report it reads as ALLOWED — absence permits, as at every
    /// other consent gate.
    var suppressedByTarget: Bool = false

    enum AlertType: String, Codable, CaseIterable {
        case arrival
        case departure
        case both

        var displayName: String {
            switch self {
            case .arrival: return "Arrival"
            case .departure: return "Departure"
            case .both: return "Both"
            }
        }
    }
}

// MARK: - Check-ins

struct CheckIn: Codable, Identifiable, Equatable {
    let id: String
    let circleId: String
    let userId: String
    var type: CheckInType
    var message: String?
    var latitude: Double?
    var longitude: Double?
    var placeId: String?
    let timestamp: Date
    var isSynced: Bool

    enum CheckInType: String, Codable, CaseIterable {
        case safeArrival = "safe_arrival"
        case general
        case emergencyOk = "emergency_ok"

        var displayName: String {
            switch self {
            case .safeArrival: return "Safe Arrival"
            case .general: return "Check-in"
            case .emergencyOk: return "All Clear"
            }
        }

        var icon: String {
            switch self {
            case .safeArrival: return "checkmark.circle.fill"
            case .general: return "hand.wave.fill"
            case .emergencyOk: return "checkmark.shield.fill"
            }
        }
    }
}

// MARK: - SOS Alerts

struct SOSAlert: Codable, Identifiable, Equatable {
    let id: String
    let circleId: String
    let userId: String
    var status: SOSStatus
    /// Optional because the location is E2EE and may not decrypt (a key we
    /// don't hold). Optional rather than defaulting to 0 on failure: a 0/0
    /// fallback puts the marker in the Gulf of Guinea instead of admitting
    /// we don't know.
    let latitude: Double?
    let longitude: Double?
    var acknowledgedBy: [String]
    let createdAt: Date
    var resolvedAt: Date?
    /// Per-VIEWER: has this user acknowledged? Server-side that's a row in
    /// sos_alert_acknowledgments, not a change to `status`.
    var acknowledgedByMe: Bool = false
    /// Per-VIEWER: has this user dismissed? Private — hides it for them and
    /// tells no one, closes nothing.
    var dismissedByMe: Bool = false
    /// When this viewer dismissed it. Drives the Safety screen's grace period:
    /// the row lingers, greyed and counting down, so a mistaken dismissal of a
    /// live emergency can be undone. The map hides it immediately regardless.
    var dismissedAt: Date? = nil
    /// How many members acknowledged. Count only; identities aren't disclosed.
    var acknowledgmentCount: Int = 0
    /// Whether it may alarm this viewer: false for one listed quietly, past
    /// `SOSManager.maxAlarmAgeMs` by its sealed original time or closed.
    /// Never pinned then either.
    var alarms: Bool = true
    /// When the position was taken (`Location.timestamp`) and how accurate it
    /// is in metres, when one opened. Older raisers' apps sealed the raise
    /// time and no accuracy.
    var positionTakenAt: Date? = nil
    var positionAccuracy: Double? = nil
    /// The marker sealed where a position would be, when one opened.
    var positionMarker: SOSPositionMarker? = nil

    /// What the position reads as to a responder at `now`.
    func positionReading(now: Date = Date()) -> SOSReceiverRules.PositionReading {
        SOSReceiverRules.reading(
            takenAtMs: coordinate == nil ? nil : positionTakenAt.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) },
            marker: positionMarker,
            askedMs: Int64((createdAt.timeIntervalSince1970 * 1000).rounded()),
            nowMs: Int64((now.timeIntervalSince1970 * 1000).rounded()))
    }

    /// The radius of the area drawn instead of a pin, or nil.
    var positionAreaMeters: Double? { SOSReceiverRules.areaMeters(accuracy: positionAccuracy) }

    /// A position shown as an area: a rough fix, or a held one coarsened to
    /// the bubble it was taken under. Shown as an approximate member is, the
    /// same on all three apps: the area and the alert's label or icon, never
    /// a street address, coordinates or directions to its centre.
    var hasApproximatePosition: Bool { positionAreaMeters != nil }

    /// The alert with its position: what an address or a camera follows, so
    /// an update resolves again (keyed by id, latitude and longitude), and
    /// one from a point to an area drops the address even where the centre
    /// stays put.
    var positionKey: String {
        "\(id)|\(latitude.map { String($0) } ?? "-")|\(longitude.map { String($0) } ?? "-")"
            + (hasApproximatePosition ? "|area" : "")
    }

    /// Coordinate, when the location decrypted.
    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// What to SHOW this viewer. An alert they acknowledged is still `active`
    /// on the wire — it is "acknowledged" only from where they're standing.
    var effectiveStatus: SOSStatus {
        status.isLive && acknowledgedByMe ? .acknowledged : status
    }

    /// Should the MAP draw this? Live, not handled by this viewer, and
    /// somewhere to actually put it. No grace period here — dismissing is
    /// meant to clear the marker at once; the Safety row is where the undo
    /// lives.
    var isMappable: Bool {
        status.isLive && alarms && !dismissedByMe && !acknowledgedByMe && coordinate != nil
    }

    /// How long a dismissed alert lingers on the Safety screen before it goes.
    static let dismissGrace: TimeInterval = 24 * 60 * 60

    /// When the row will drop off, or nil if it isn't dismissed.
    var dismissExpiry: Date? {
        guard dismissedByMe, let dismissedAt else { return nil }
        return dismissedAt.addingTimeInterval(Self.dismissGrace)
    }

    /// Still within the undo window? A dismissal with no recorded timestamp
    /// has no honest expiry, so it counts as already past — it stays hidden,
    /// which is what the user asked for.
    func isWithinDismissGrace(now: Date = Date()) -> Bool {
        guard let expiry = dismissExpiry else { return false }
        return expiry > now
    }

    enum SOSStatus: String, Codable, CaseIterable {
        case active
        case acknowledged
        case resolved
        case falseAlarm = "false_alarm"
        /// A status this build does not recognise. Deliberately inert on both
        /// axes — see `isLive` and `isClosed`, and `from(_:)` for why it exists
        /// at all.
        case unknown

        var displayName: String {
            switch self {
            case .active: return "Active"
            case .acknowledged: return "Acknowledged"
            case .resolved: return "Resolved"
            case .falseAlarm: return "False Alarm"
            case .unknown: return "Unknown status"
            }
        }

        var color: String {
            switch self {
            case .active: return "red"
            case .acknowledged: return "orange"
            case .resolved: return "green"
            case .falseAlarm: return "gray"
            case .unknown: return "gray"
            }
        }

        /// A LIVE emergency. This alone draws the map marker (`isMappable`),
        /// fills the red "Active Alerts" section, and sounds the alarm. Nothing
        /// else may — least of all a status we cannot read.
        var isLive: Bool { self == .active }

        /// Definitively CLOSED server-side. These are the only two statuses the
        /// server writes as an ending: resolving writes `'resolved'` and marking
        /// a false alarm writes `'false_alarm'`, each only for an alert that is
        /// still `'active'` or `'acknowledged'`.
        ///
        /// `.unknown` is deliberately NOT closed, which is what keeps the
        /// raiser's status poll running. Failing closed means refusing to act
        /// on what we cannot read — in BOTH directions: never promote an
        /// unreadable status to a live emergency, and never quietly retire the
        /// raiser's own alert (and its Resolve / False alarm controls) on the
        /// strength of one.
        var isClosed: Bool { self == .resolved || self == .falseAlarm }

        /// Decode a wire status, mapping anything unrecognised to `.unknown`.
        ///
        /// Never `.active`: a status this build cannot read must not become a
        /// live emergency — a red banner, a map marker, and the alarm sound,
        /// about somebody who is fine.
        ///
        /// The enum covers every status the server writes: `'active'`,
        /// `'resolved'`, `'false_alarm'`, plus `'acknowledged'` on older rows.
        /// Nothing on the server's side limits the status to these values, so
        /// any string may arrive here.
        static func from(_ raw: String) -> SOSStatus {
            SOSStatus(rawValue: raw) ?? .unknown
        }
    }
}

// MARK: - Geocoding

struct GeocodingRegion: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let country: String
    let countryCode: String
    let sizeBytes: Int64
    var isDownloaded: Bool
    var downloadProgress: Double?
}

struct GeocodedAddress: Codable, Equatable {
    let formattedAddress: String
    let city: String?
    let state: String?
    let country: String?
    let postalCode: String?
}

// MARK: - API Response Wrappers

struct APIResponse<T: Decodable>: Decodable {
    let success: Bool
    let data: T?
    let error: APIError?

    private enum CodingKeys: String, CodingKey {
        case success, data, error, errorCode, quota
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.success = (try? c.decode(Bool.self, forKey: .success)) ?? false
        self.data = try c.decodeIfPresent(T.self, forKey: .data)
        // The subscription-gate 402 rides `error_code` + `quota` at the
        // envelope's top level, beside the human `error` string. Pull them
        // out and fold them into the APIError the caller catches so the UI
        // can react to a premium/quota limit rather than showing an opaque
        // failure.
        let gateCode = try? c.decodeIfPresent(String.self, forKey: .errorCode)
        let gateQuota = try? c.decodeIfPresent(QuotaError.self, forKey: .quota)
        // Auth API returns errors as a bare string (`"error": "message"`);
        // track API uses the structured `{code, message}` shape. Accept
        // both transparently so UI code can rely on a single APIError.
        if let structured = try? c.decodeIfPresent(APIError.self, forKey: .error) {
            self.error = APIError(code: structured.code, message: structured.message,
                                  errorCode: gateCode ?? structured.errorCode,
                                  quota: gateQuota ?? structured.quota)
        } else if let message = try? c.decodeIfPresent(String.self, forKey: .error), !message.isEmpty {
            self.error = APIError(code: gateCode ?? "server_error", message: message,
                                  errorCode: gateCode, quota: gateQuota)
        } else if gateCode != nil || gateQuota != nil {
            // A gate with no human-readable string (defensive).
            self.error = APIError(code: gateCode ?? "server_error", message: "Request failed",
                                  errorCode: gateCode, quota: gateQuota)
        } else {
            self.error = nil
        }
    }
}

struct Paginated<T: Decodable>: Decodable {
    let items: [T]
    let hasMore: Bool?
    let nextCursor: String?
}

extension Paginated {
    private enum CodingKeys: String, CodingKey {
        case items, hasMore, nextCursor
    }

    /// An item naming an account by no id at all is dropped, the rest read
    /// (`ServedEntries`).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decode(ServedEntries<T>.self, forKey: .items).items
        hasMore = try container.decodeIfPresent(Bool.self, forKey: .hasMore)
        nextCursor = try container.decodeIfPresent(String.self, forKey: .nextCursor)
    }
}

struct APIError: Codable, LocalizedError {
    let code: String
    let message: String
    /// Backend `error_code` on a structured failure. Present on the new
    /// quota-gated 402s (e.g. `quota_places_exceeded`,
    /// `premium_required_destinations`); nil for transport / legacy
    /// errors. Callers switch on this to decide whether to surface the
    /// premium prompt instead of a plain error alert.
    let errorCode: String?
    /// Structured quota envelope carried alongside a gated 402 (resource
    /// + current/limit counts + tier). nil for non-quota errors; lets a
    /// prompt say "2 of 2 places used".
    let quota: QuotaError?
    /// A 429's Retry-After, in seconds, when the reply had one.
    var retryAfter: TimeInterval? = nil

    init(code: String, message: String, errorCode: String? = nil, quota: QuotaError? = nil) {
        self.code = code
        self.message = message
        self.errorCode = errorCode
        self.quota = quota
    }

    /// What `.localizedDescription` shows: `plainLine`, never `message`.
    ///
    /// No server `error`/`message` text ever reaches the screen. It can carry
    /// key talk ("at_version is not this circle's current key version"), or
    /// whatever a compromised server wants a person to read. `message` is for
    /// logs.
    var errorDescription: String? { plainLine }

    /// What a person is told about this failure, by its code. A caller with
    /// something better to say about a code it knows says that instead.
    var plainLine: String {
        let codes = [errorCode, code].compactMap { $0 }
        if let line = codes.lazy.compactMap({ Self.lines[$0] }).first { return line }
        if isPremiumGate { return Self.planLimitText }
        if codes.contains(where: { $0 == "http_429" || $0.hasPrefix("rate_") }) { return Self.tooManyText }
        if codes.contains(where: { $0.hasPrefix("http_5") || $0.hasPrefix("server_") }) { return Self.troubleText }
        if codes.contains(where: { $0 == "http_403" || $0.hasPrefix("auth_not_") || $0 == "auth_insufficient_permissions" }) {
            return Self.notAllowedText
        }
        if codes.contains(where: { $0 == "http_404" || $0.hasSuffix("_not_found") }) { return Self.goneText }
        return Self.failedText
    }

    static let failedText = "That didn't work. Please try again."
    static let unreachableText = "Pingolin couldn't be reached. Check your connection and try again."
    static let troubleText = "Pingolin is having trouble just now. Please try again in a moment."
    static let tooManyText = "Too many tries just now. Please wait a moment and try again."
    static let notAllowedText = "You don't have permission to do that."
    static let goneText = "That isn't there any more."
    static let planLimitText = "That's beyond what your plan includes."
    /// The server's cap on invitation e-mails. No calendar words: it
    /// is the last 24 hours, not a day.
    static let inviteLimitText = "Too many invitations in the last 24 hours. Try again later."
    /// 429s that name a cap, not throttling: said at once, never waited out
    /// (`APIService`'s 429 path, `PendingChangeRunner.classify`).
    static let capsNotWaitedOut: Set<String> = ["invite_limit_reached"]

    /// The failures this app raises itself, and refusals of the server's that
    /// have a line of their own, in this app's words.
    private static let lines: [String: String] = [
        "network_error": unreachableText,
        "circuit_open": "Pingolin is paused for a moment while it recovers. Please try again shortly.",
        "rate_limited": tooManyText,
        "missing_circle_key": "This circle isn't open on this phone yet.",
        "missing_self_key": "Your personal places aren't open on this phone yet.",
        "not_owner": "You can only change your own destinations.",
        "legacy_place": "This place can't be shared from this phone.",
        "missing_place": "That place isn't on this phone yet. Please try again.",
        "no_members_to_watch": "There's nobody else in this circle to watch yet.",
        // An invitation that already stands: the server says so
        // with these codes, and they are said in Android's words
        // (CircleRepository.inviteRefusal), not as a failure to try again.
        "invite_already_exists": "They already have an invitation to this circle.",
        "circle_already_member": "They're already in this circle.",
        "invite_limit_reached": inviteLimitText,
    ]

    /// Whether the server's machine-readable reason (or, without one, the
    /// "http_<status>" label) is one of `codes`. The envelope decoder puts a
    /// server `error_code` in `code` or `errorCode` depending on the shape.
    func isServerCode(_ codes: String...) -> Bool {
        codes.contains(code) || errorCode.map { codes.contains($0) } == true
    }

    /// True when this failure is a subscription gate — either a hard count
    /// limit or a premium-only feature. Drives whether a caller presents the
    /// premium prompt vs. a generic error. Fails safe: a nil `errorCode`
    /// without a quota object is treated as an ordinary error.
    var isPremiumGate: Bool {
        if quota != nil { return true }
        guard let errorCode else { return false }
        return errorCode.hasPrefix("quota_") || errorCode.hasPrefix("premium_required")
    }

    /// The server refused `POST /users/me/self-key` because it already holds a
    /// self key with data under it (error code `key_self_key_in_use`, on a
    /// 409).
    ///
    /// Worth its own name because it is the one self-key failure that is not a
    /// failure: it PROVES the real key still exists server-side and can be
    /// re-published, which is the whole recovery. Collapsed into a generic
    /// error that fact is gone, and the user gets advice for this device when
    /// the remedy is on another one.
    ///
    /// Checks both fields: the track API sends its human message as a bare
    /// `"error"` string, so `APIResponse`'s decoder lifts the envelope's
    /// top-level `error_code` into `code` AND `errorCode`. A structured
    /// `{code, message}` body would set only the latter.
    var isSelfKeyInUse: Bool {
        errorCode == "key_self_key_in_use" || code == "key_self_key_in_use"
    }

    /// True ONLY when the server has definitively rejected the session: a 401
    /// from `/auth/refresh`, surfaced as code `refresh_failed`. That endpoint
    /// resolves the session by refresh-token hash and ignores the JWT
    /// signature, so a 401 there means revoked / expired / replayed — never
    /// transient.
    ///
    /// Everything else (5xx / 429 / circuit-open / network / timeout / decode)
    /// MUST NOT trigger logout: doing so wipes the refresh token and, with no
    /// stored password, leaves the device dark until a manual re-login.
    ///
    /// Single definition on purpose. AuthManager's launch gate and the refresh
    /// authority's running-app gate both read it, and two copies of a
    /// security-relevant predicate is exactly the pair that drifts apart.
    static func isSessionDefinitivelyExpired(_ error: Error) -> Bool {
        (error as? APIError)?.code == "refresh_failed"
    }
}

/// Structured quota context attached to a gated 402.
/// `isCountLimit` distinguishes a hard count cap — where
/// `current`/`limit` are meaningful — from a boolean feature gate,
/// where both are 0. snake_case JSON (`is_count_limit`) maps via the
/// decoder's `.convertFromSnakeCase`.
struct QuotaError: Codable, Equatable {
    let resource: String
    let isCountLimit: Bool
    let current: Int
    let limit: Int
    let tier: String
}

struct EncryptedPayload: Codable {
    let nonce: String
    let ciphertext: String

    var combined: String { "\(nonce):\(ciphertext)" }

    init(nonce: String, ciphertext: String) {
        self.nonce = nonce
        self.ciphertext = ciphertext
    }

    init?(combined: String) {
        let parts = combined.split(separator: ":")
        guard parts.count == 2 else { return nil }
        self.nonce = String(parts[0])
        self.ciphertext = String(parts[1])
    }
}

// MARK: - Destinations

/// Travel intention surfaced to a circle. The server is blind to the
/// coordinate, ETA and creator id — only day buckets and notify flags
/// flow through plaintext. Mirrors the Android app's DestinationEntity.
struct Destination: Codable, Identifiable, Equatable {
    let id: String
    let circleId: String
    let userId: String
    var name: String?
    var latitude: Double
    var longitude: Double
    var status: Status
    var notifyArrival: Bool
    var estimatedArrivalAt: Date?
    let startedAt: Date
    var arrivedAt: Date?
    /// The creator as the server records it (`DestinationResponse.userId`);
    /// `userId` is the one sealed by the creator. nil: the server didn't say.
    var creatorId: String? = nil

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// This account's own destination: the sealed id AND the server's creator
    /// both name it, in any spelling. Any member can seal any id, and the
    /// server alone can say anything; neither half alone makes a destination
    /// this account's list entry, its to cancel, arrive at or delete, or its
    /// automatic arrival.
    func isMine(_ me: String?) -> Bool {
        CanonicalId.same(userId, me) && CanonicalId.same(creatorId, me)
    }

    enum Status: String, Codable, CaseIterable {
        case active
        case arrived
        case cancelled
        /// Written server-side once a destination has gone stale. The list
        /// endpoint keeps returning expired rows for seven days, so clients
        /// see them and must render them as over.
        case expired
        /// A status this build does not recognise — a newer server, or one
        /// added after this app shipped. See `from(_:)` for why it exists.
        case unknown

        var displayName: String {
            switch self {
            case .active: return "On the way"
            case .arrived: return "Arrived"
            case .cancelled: return "Cancelled"
            case .expired: return "Expired"
            case .unknown: return "No longer active"
            }
        }

        /// The one status that is LIVE: it alone grants a map marker,
        /// auto-arrival eligibility, and the Cancel/Arrived swipe actions.
        /// Every other status — recognised or not — is terminal and inert.
        var isLive: Bool { self == .active }

        /// Decode a wire status, mapping anything unrecognised to `.unknown`.
        ///
        /// Deliberately never falls back to `.active`. `.active` is the one
        /// value a fallback must not pick: coercing to it fails OPEN — the row
        /// goes live on every circle member's map and offers buttons the
        /// server refuses — where anything else fails closed, inert and filed
        /// under Past.
        ///
        /// Without this, a status the enum has no case for (`expired`, say)
        /// would be filed under "Active", drawn on the map and labelled "On
        /// the way".
        static func from(_ raw: String) -> Status {
            Status(rawValue: raw) ?? .unknown
        }
    }
}
