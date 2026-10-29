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
import CryptoKit
import PingolinTrackSDK

/// One SOS as `GET /api/v1/sos/active` serves it. Here rather than with the
/// app's other wire types because the notification extension reads the same
/// list.
struct SOSResponse: Codable {
    let id: String
    let circleId: String
    let encryptedLocation: EncryptedBlobResponse
    let encryptedDeviceState: EncryptedBlobResponse?
    let status: String
    let encryptedUserId: EncryptedBlobResponse
    let encryptedDeviceId: EncryptedBlobResponse
    let dayBucket: Int
    let encryptedTimestamp: EncryptedBlobResponse
    let resolvedDayBucket: Int?
    /// Per-CALLER state. Acknowledging does not flip the shared `status` —
    /// that would remove a live emergency from every other member's list the
    /// moment any one member acknowledged. Read these, not `status`, to
    /// decide what THIS user has already done about the alert.
    /// Optional so a response from an older backend still decodes.
    let acknowledgedByMe: Bool?
    let dismissedByMe: Bool?
    /// RFC 3339 instant this caller dismissed it. Drives the 24h undo window.
    let dismissedAt: String?
    let acknowledgmentCount: Int?
}

/// The two markers an SOS may carry where its position would be: exactly
/// these UTF-8 bytes, 22 each, sealed with `encryptDataV2(…, fieldTag:
/// "location")`. "pending": no position yet, the raiser's phone is still
/// getting one; "unavail": a location can't be sent.
enum SOSPositionMarker: String, CaseIterable, Codable {
    case pending = #"{"position":"pending"}"#
    case unavail = #"{"position":"unavail"}"#

    /// The marker these bytes are, compared byte for byte; nil for any other
    /// text, which is garbage and reads as no position.
    static func matching(_ text: String) -> SOSPositionMarker? {
        allCases.first { $0.rawValue.utf8.elementsEqual(text.utf8) }
    }
}

/// The receiver rules for an SOS, in ONE place for the app's list and
/// alarm and for its notification extension's check. Compiled into the
/// app and the extension (project.yml).
enum SOSReceiverRules {
    /// MAX_SOS_ALARM_AGE: an SOS alarms for at most this long after its
    /// sealed ORIGINAL time (a re-seal carries that time, never "now"); past it
    /// it is listed quietly, and its marks go. The same constant on Android and
    /// the web.
    static let maxAlarmAgeMs: Int64 = 86_400_000

    /// What opened of one listed SOS, and under which versions.
    struct Opened {
        /// The raiser's id, when it opened.
        var raiserId: String?
        /// The sealed original time (ms), when it opened.
        var sealedTimeMs: Int64?
        var location: Location?
        /// The marker sealed where the position would be, when one opened. It
        /// counts as an opened part: its version joins `current`, as a
        /// position's does.
        var marker: SOSPositionMarker? = nil
        /// The raiser id AND the time opened, and every part that opened did
        /// so under the version this device seals the circle under.
        var current: Bool
        /// SHA-256 over the sealed fields as served (`payloadHash`).
        var payloadHash: String
        /// Its sealed device id is this device's.
        var raisedHere: Bool

        /// The raiser id and the time opened, under some version held here.
        var opened: Bool { raiserId != nil && sealedTimeMs != nil }
        /// No part of it opened here.
        var nothingOpened: Bool { raiserId == nil && sealedTimeMs == nil && location == nil && marker == nil }
    }

    /// Open one listed SOS with the version each part opened under. Pure apart
    /// from the SDK reads. The device id is read with any key, for "raised
    /// here" only.
    static func open(_ response: SOSResponse, myUserId: String?, myDeviceId: String?,
                     crypto: CryptoManager) -> Opened {
        let circleId = response.circleId
        var versions: [Int32] = []
        func opened(_ blob: EncryptedBlobResponse, _ fieldTag: String) -> String? {
            guard let text = try? crypto.decryptDataV2Opened(
                circleId: circleId,
                encryptedData: EncryptedData(nonce: blob.nonce, ciphertext: blob.ciphertext),
                fieldTag: fieldTag
            ) else { return nil }
            versions.append(text.keyVersion)
            return text.text
        }
        let raiser = opened(response.encryptedUserId, "user_id")
        let sealedTimeMs = opened(response.encryptedTimestamp, "timestamp").flatMap { Int64($0) }
        let location: Location? = {
            guard let point = try? crypto.decryptLocationOpened(
                circleId: circleId,
                encryptedLocation: EncryptedData(
                    nonce: response.encryptedLocation.nonce,
                    ciphertext: response.encryptedLocation.ciphertext
                )
            ) else { return nil }
            versions.append(point.keyVersion)
            return point.location
        }()
        // No position: one of the two markers, byte for byte. Any other text
        // is garbage and reads as no position, and its version counts for
        // nothing.
        let marker: SOSPositionMarker? = location != nil ? nil : {
            guard let text = try? crypto.decryptDataV2Opened(
                circleId: circleId,
                encryptedData: EncryptedData(
                    nonce: response.encryptedLocation.nonce,
                    ciphertext: response.encryptedLocation.ciphertext
                ),
                fieldTag: "location"
            ), let marker = SOSPositionMarker.matching(text.text) else { return nil }
            versions.append(text.keyVersion)
            return marker
        }()
        let raisedHere: Bool = {
            guard CanonicalId.same(raiser, myUserId), let myDeviceId else { return false }
            return (try? crypto.decryptDataV2(
                circleId: circleId,
                encryptedData: EncryptedData(
                    nonce: response.encryptedDeviceId.nonce,
                    ciphertext: response.encryptedDeviceId.ciphertext
                ),
                fieldTag: "device_id"
            )) == myDeviceId
        }()
        let current = raiser != nil && sealedTimeMs != nil
            && versions.allSatisfy { crypto.isCurrentKeyVersion(circleId: circleId, keyVersion: $0) }
        return Opened(raiserId: raiser, sealedTimeMs: sealedTimeMs, location: location, marker: marker,
                      current: current, payloadHash: payloadHash(response), raisedHere: raisedHere)
    }

    // MARK: - What the position reads as

    /// How a responder reads an SOS's position, from what opened and the
    /// sealed raise time ("asked"). The time label comes from the position's
    /// own time (`Location.timestamp`), which older raisers' apps set to the
    /// raise time: theirs read as `atRaise`.
    enum PositionReading: Equatable {
        /// No position or marker opened, or no raise time to judge by
        /// ("No location available for this alert").
        case unknown
        /// "Sending current location": the raiser's phone is still getting one.
        case sending
        /// "Location unavailable": it can't be sent; also a "pending" marker
        /// past `pendingFallbackMs` (the raiser's phone died or stayed offline).
        case unavailable
        /// Taken within `atRaiseMs` of the raise: no extra line.
        case atRaise
        /// "Last known location · {time}": taken before the raise.
        case lastKnown(Date)
        /// "Location updated · {time}": taken after the raise.
        case updated(Date)
    }

    /// The fallback of a "pending" marker to "unavailable", from the SEALED
    /// raise time: the raiser's 10-minute window plus a 2-minute margin. This
    /// device's clock against the raiser's sealed time, so a skewed clock
    /// moves it by the skew; display only.
    static let pendingFallbackMs: Int64 = 12 * 60_000
    /// A position taken within this of the raise was taken "at" it.
    static let atRaiseMs: Int64 = 60_000

    /// `takenAtMs`: the opened position's own time, nil when no position
    /// opened.
    static func reading(takenAtMs: Int64?, marker: SOSPositionMarker?, askedMs: Int64?,
                        nowMs: Int64) -> PositionReading {
        switch marker {
        case .unavail?:
            return .unavailable
        case .pending?:
            guard let askedMs else { return .sending }
            return nowMs - askedMs >= pendingFallbackMs ? .unavailable : .sending
        case nil:
            break
        }
        guard let takenAtMs, let askedMs else { return .unknown }
        let takenAt = Date(timeIntervalSince1970: TimeInterval(takenAtMs) / 1000)
        if takenAtMs < askedMs - atRaiseMs { return .lastKnown(takenAt) }
        if takenAtMs > askedMs + atRaiseMs { return .updated(takenAt) }
        return .atRaise
    }

    /// A position whose accuracy is over this is drawn as an AREA of that
    /// radius, never a pin: a coarse fix, or a held one coarsened to the
    /// bubble it was taken under.
    static let areaAboveMeters: Double = 100

    /// The radius in metres of the area drawn instead of a pin, or nil.
    static func areaMeters(accuracy: Double?) -> Double? {
        guard let accuracy, accuracy.isFinite, accuracy > areaAboveMeters else { return nil }
        return accuracy
    }

    /// SHA-256 over the sealed fields as served (user id, location, time,
    /// device id; each nonce then ciphertext, length-prefixed), in hex: the
    /// exact payload a "seen current" mark is bound to.
    static func payloadHash(_ response: SOSResponse) -> String {
        var bytes = Data()
        for blob in [response.encryptedUserId, response.encryptedLocation,
                     response.encryptedTimestamp, response.encryptedDeviceId] {
            for part in [blob.nonce, blob.ciphertext] {
                let data = Data(part.utf8)
                var length = UInt32(data.count).bigEndian
                bytes.append(Data(bytes: &length, count: 4))
                bytes.append(data)
            }
        }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    /// A LIVE emergency: exactly "active" (`SOSAlert.SOSStatus.isLive`); a
    /// status this build can't read never is.
    static func isLive(_ status: String) -> Bool { status == "active" }

    /// What this device's marks say of one SOS.
    enum Marks: Equatable {
        case read(ended: Bool, seenCurrent: Bool)
        /// The marks are there and can't be read: "ended" and "sticky" are unknown.
        case unreadable
    }

    /// What one SOS comes to on this phone.
    enum Verdict: Equatable {
        /// What decides can't be known here: it may be sealed under a key
        /// version this phone doesn't hold yet, or it depends on marks that
        /// can't be read. The phone rings, as it would with no rules at all.
        case cantCheck
        /// Listed, pinned, alarming: current, or sticky.
        case alarming
        /// Listed only, no alarm: closed, or past MAX_SOS_ALARM_AGE.
        case quiet
        /// Not listed: history, ended, its raiser off the roster, or sealed
        /// under nothing held here.
        case hidden
    }

    /// The receiver rules, in this order: closed → quiet; ended here → hidden;
    /// not current: nothing of it opened while this phone is behind on the
    /// circle (it may be sealed under a version not held here yet) → can't
    /// check, not opened otherwise → hidden, its raiser off this phone's roster
    /// → hidden, not seen current here (not sticky) → hidden; past
    /// MAX_SOS_ALARM_AGE → quiet; marks that can't be read for one that isn't
    /// current → can't check (they decide it); else alarming. `raiserShown`
    /// nil: the roster isn't loaded, no decision.
    static func verdict(live: Bool, opened: Opened, behind: Bool, marks: Marks, raiserShown: Bool?,
                        now: Int64) -> Verdict {
        if !live { return .quiet }
        if case .read(let ended, _) = marks, ended { return .hidden }
        if !opened.current {
            guard opened.opened else { return behind && opened.nothingOpened ? .cantCheck : .hidden }
            if raiserShown == false { return .hidden }
            if case .read(_, let seenCurrent) = marks, !seenCurrent { return .hidden }
        }
        if let sealed = opened.sealedTimeMs, now - sealed > maxAlarmAgeMs { return .quiet }
        if !opened.current, marks == .unreadable { return .cantCheck }
        return .alarming
    }
}
