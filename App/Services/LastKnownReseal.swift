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

/// The phone's half of re-sealing a frozen last location: this account's last
/// location in a circle where its real-time sharing is off, sealed again under
/// the circle's current key after a rotation, so its members still see where
/// it was (with real time off, the user's last location is the one shown). The
/// apps draw such a row only under the current key, so without this the marker
/// goes at the next rotation. The Android app's LastKnownReseal does the same.
///
/// The point and the bytes come from this phone's own record of what it sealed
/// and sent (`OwnLastSentStore`), never from the row the server serves, which
/// may be a removed member's forgery:
/// - the served row is only FOUND, by its payload's bytes being the record's,
///   field by field and in the record's own shape;
/// - the new payload seals the record's position and time and nothing else: no
///   battery, no motion (a frozen row is never judged);
/// - the served blobs go back only as `previous_*`, exactly as served, for the
///   server's compare-and-swap.
///
/// Due only while this account's real-time sharing there is off and it isn't
/// paused (nothing is sent while paused), with the account allowed to track at
/// all (a re-seal is a send), and never finer than the circle gets now: a point
/// sealed precisely is not sealed again for a circle since switched to sharing
/// approximately, whose later members hold only the new key. Once per circle
/// and version: a newer version is tried once, whatever comes of it, and a
/// refusal is never retried. Nothing on screen says it happened.
@MainActor
final class LastKnownReseal {
    static let shared = LastKnownReseal()

    enum Outcome: Equatable { case notDue, noMatch, resealed, refused, failed }

    private let store: OwnLastSentStore
    private let crypto: CryptoManager
    private let privacyOf: @MainActor (String) -> PrivacySettings?
    private let me: @MainActor () -> String?
    private let accessOpen: @MainActor () -> Bool
    private let now: @MainActor () -> Date
    private let send: @MainActor (String, ResealLastKnownRequest) async throws -> Void
    /// Circles a run is under way for, in their one form: one at a time each.
    private var running = Set<String>()

    init(store: OwnLastSentStore = .shared,
         crypto: CryptoManager = SDKCrypto.cryptoManager,
         privacyOf: @escaping @MainActor (String) -> PrivacySettings? = { CircleManager.shared.privacySettings[$0] },
         me: @escaping @MainActor () -> String? = { AuthManager.shared.userId },
         // A re-seal is a send: signed in, the streamer's own gate, and
         // tracking wanted. Read afresh at every run.
         accessOpen: @escaping @MainActor () -> Bool = {
             AuthManager.shared.isAuthenticated && RegistrationGate.allowsTrack && LocationService.shared.wantsTracking
         },
         now: @escaping @MainActor () -> Date = { Date() },
         send: @escaping @MainActor (String, ResealLastKnownRequest) async throws -> Void = {
             _ = try await APIService.shared.resealLastKnown(circleId: $0, body: $1)
         }) {
        self.store = store
        self.crypto = crypto
        self.privacyOf = privacyOf
        self.me = me
        self.accessOpen = accessOpen
        self.now = now
        self.send = send
    }

    /// `circleId`'s, when one is due there, from `served`: the `last_known` rows
    /// a refresh of the circle just read, as served. Never throws.
    @discardableResult
    func run(circleId: String, served: [ServedFrozenBlobs]) async -> Outcome {
        let key = CanonicalId.key(circleId)
        guard !running.contains(key) else { return .notDue }
        running.insert(key)
        defer { running.remove(key) }
        do {
            return try await attempt(circleId: circleId, served: served)
        } catch {
            return .failed
        }
    }

    private func attempt(circleId: String, served: [ServedFrozenBlobs]) async throws -> Outcome {
        guard accessOpen(), let user = me(),
              var record = store.record(circleId: circleId, owner: user),
              let privacy = privacyOf(circleId) else { return .notDue }
        let at = now()
        if privacy.shareRealtime || Self.isPaused(privacy, at: at) { return .notDue }
        // A re-seal sent earlier whose answer never came (the app suspended
        // mid-request, say): served as sent, in its own `c:<version>` shape, it
        // landed, and the record takes it before anything else is judged.
        if let landed = record.landed(), served.contains(where: {
            CanonicalId.same($0.userId, user) && Self.payloadIsRecord($0.encryptedPayload, landed)
        }) {
            store.update(circleId: circleId, owner: user, from: record, to: landed)
            record = landed
        }
        let active = try crypto.getActiveVersion(circleId: circleId)
        if active <= record.keyVersion || record.triedVersion == active { return .notDue }
        // Never finer than the circle gets now. Not counted as tried, so a return
        // to exact can still re-seal it; a record that doesn't say how coarse it
        // was sealed counts as exact.
        if (record.coarsenedToMiles ?? 0) < (Self.bubbleNow(privacy, at: at) ?? 0) { return .notDue }

        guard let row = served.first(where: {
            CanonicalId.same($0.userId, user) && Self.payloadIsRecord($0.encryptedPayload, record)
        }) else {
            store.update(circleId: circleId, owner: user, from: record, to: record.tried(active))
            return .noMatch
        }

        // The record's position and time, sealed under the current key as a
        // normal send is: bound to this account, no battery, no motion.
        let point = PingolinTrackSDK.Location(
            latitude: record.latitude, longitude: record.longitude, altitude: nil, speed: nil, heading: nil,
            accuracy: record.accuracy, timestamp: record.timestampMs, batteryLevel: nil, isCharging: nil)
        let sealed = try crypto.encryptLocationBound(
            circleId: circleId, location: point,
            senderPseudonym: try crypto.deriveUserPseudonym(circleId: circleId, userId: user))
        // The time only when the row has one, and always the record's: a time
        // served beside this payload is never read or used.
        let sealedTime = try row.encryptedTimestamp.map { _ in
            try crypto.encryptTimestamp(circleId: circleId, timestampMs: record.timestampMs)
        }
        // Nothing has waited since `active` was read, so the seals above went
        // under the version this names.
        let keyId = "c:\(active)"
        let request = ResealLastKnownRequest(
            devicePseudonym: record.devicePseudonym,
            previousEncryptedPayload: row.encryptedPayload,
            previousEncryptedTimestamp: row.encryptedTimestamp,
            encryptedPayload: ResealBlob(nonce: sealed.nonce, ciphertext: sealed.ciphertext, keyId: keyId),
            encryptedTimestamp: sealedTime.map { ResealBlob(nonce: $0.nonce, ciphertext: $0.ciphertext, keyId: nil) })
        // Kept with the record BEFORE the request goes: an answer that
        // never comes (a lost 200) still leaves this phone knowing what
        // it sent, for a later run to find served.
        var sending = record
        sending.pending = OwnLastSent.Pending(nonce: sealed.nonce, ciphertext: sealed.ciphertext,
                                              keyId: keyId, keyVersion: active)
        store.update(circleId: circleId, owner: user, from: record, to: sending)
        do {
            try await send(circleId, request)
        } catch {
            guard Self.isRefusal(error) else { return .failed }
            var refused = record.tried(active)
            refused.pending = nil
            store.update(circleId: circleId, owner: user, from: sending, to: refused)
            return .refused
        }
        // What the server holds now is what was just sent: the record follows the
        // request, never the answer. The row keeps its device and pseudonym
        // there, so the record does too.
        if let resealed = sending.landed() {
            store.update(circleId: circleId, owner: user, from: sending, to: resealed)
        }
        return .resealed
    }

    // MARK: - The rules

    /// Paused at `now`: `CirclePauseRecord.shares`' rule (a pause past its
    /// `paused_until` has lapsed; one with none runs until resumed).
    nonisolated static func isPaused(_ privacy: PrivacySettings, at now: Date) -> Bool {
        privacy.sharingMode == "paused" && (privacy.pausedUntil.map { $0 > now } ?? true)
    }

    /// How coarse a point taken now goes to the circle, in miles; nil = exact.
    /// `SDKLocationStreamer.privacyApplied`'s own rule.
    nonisolated static func bubbleNow(_ privacy: PrivacySettings, at now: Date) -> Double? {
        privacy.sharesApproximately(at: now) ? (privacy.bubbleRadius > 0 ? privacy.bubbleRadius : 1.0) : nil
    }

    /// Whether a served payload is `record`'s: byte for byte in every field it
    /// carries, and in the record's own shape:
    /// - a phone's envelope: its wrap for this circle, both fields, and no key
    ///   named (`key_id` absent or empty);
    /// - a re-seal: no wrap field at all, and the very `c:<version>` it named.
    /// Anything else is no match. Bytes are compared as bytes, whichever alphabet
    /// each side is in: the SDK hands this phone lowercase hex, and /latest
    /// serves a streamed row in base64 and a re-sealed one as it was sent.
    nonisolated static func payloadIsRecord(_ served: AnyCodableValue, _ record: OwnLastSent) -> Bool {
        guard case .object(let fields) = served else { return false }
        func text(_ name: String) -> String? {
            if case .string(let value)? = fields[name] { return value }
            return nil
        }
        func absent(_ name: String) -> Bool {
            switch fields[name] {
            case nil, .null?: return true
            default: return false
            }
        }
        guard sameBytes(text("nonce"), record.nonce), sameBytes(text("ciphertext"), record.ciphertext) else {
            return false
        }
        if let wrappedKey = record.wrappedKey, let wrappedKeyNonce = record.wrappedKeyNonce {
            return sameBytes(text("wrapped_msg_key"), wrappedKey)
                && sameBytes(text("wrapped_msg_key_nonce"), wrappedKeyNonce)
                && (absent("key_id") || text("key_id") == "")
        }
        guard record.wrappedKey == nil, record.wrappedKeyNonce == nil,
              let keyId = record.keyId, keyId.hasPrefix("c:") else { return false }
        return absent("wrapped_msg_key") && absent("wrapped_msg_key_nonce") && text("key_id") == keyId
    }

    /// Whether two blob fields hold the same bytes, read as hex or as standard
    /// base64. Never as text, so one alphabet's spelling never reads as another
    /// row.
    nonisolated static func sameBytes(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return false }
        let left = decodings(a)
        return decodings(b).contains { right in left.contains(right) }
    }

    nonisolated static func decodings(_ text: String) -> [Data] {
        var all: [Data] = []
        if let hex = hexBytes(text) { all.append(hex) }
        if let base64 = Data(base64Encoded: text), !base64.isEmpty { all.append(base64) }
        return all
    }

    nonisolated static func hexBytes(_ text: String) -> Data? {
        let digits = Array(text.utf8)
        guard !digits.isEmpty, digits.count % 2 == 0 else { return nil }
        var bytes = Data(capacity: digits.count / 2)
        var index = 0
        while index < digits.count {
            guard let high = hexValue(digits[index]), let low = hexValue(digits[index + 1]) else { return nil }
            bytes.append(high << 4 | low)
            index += 2
        }
        return bytes
    }

    private nonisolated static func hexValue(_ digit: UInt8) -> UInt8? {
        switch digit {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return digit - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return digit - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return digit - UInt8(ascii: "A") + 10
        default: return nil
        }
    }

    /// The route's one refusal, a 404 whatever the reason: final for the version.
    /// Anything else (no network, a 5xx, a 429) leaves the record as it was, for
    /// the next refresh.
    nonisolated static func isRefusal(_ error: Error) -> Bool {
        guard let api = error as? APIError else { return false }
        return api.code == "http_404" || api.code == "not_found"
    }
}
