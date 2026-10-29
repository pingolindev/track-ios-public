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

/// What this phone last sealed and sent a circle: the circle's latest row, kept
/// so that after a key rotation it can seal THAT point again under the new key
/// while real-time sharing there is off and nothing new goes
/// (`LastKnownReseal`).
///
/// Written only for a send this phone made, when the stream took it
/// (`SDKLocationStreamer.send`): a live send or a check-in, never a kept point
/// (it writes no latest row), never the personal history, and never anything a
/// server served. A record whose bytes never landed matches no row, so nothing
/// is re-sealed for it.
struct OwnLastSent: Codable, Equatable {
    enum Kind: String, Codable { case live, liveness }

    var kind: Kind
    /// The payload as sealed, in the SDK's hex. A phone's envelope: `keyId` nil
    /// and both wrap fields. A re-seal (`LastKnownReseal`): `keyId`
    /// "c:<version>" and no wrap.
    var nonce: String
    var ciphertext: String
    var keyId: String?
    var wrappedKey: String?
    var wrappedKeyNonce: String?
    /// The point as sealed, after `privacyApplied`, and the time sealed with it
    /// (a check-in's is its own now).
    var latitude: Double
    var longitude: Double
    var accuracy: Double?
    var timestampMs: Int64
    /// The bubble the point was coarsened to, in miles; nil = exact.
    var coarsenedToMiles: Double?
    /// The circle-key version and this device's pseudonym, read just before the
    /// seal.
    var keyVersion: Int32
    var devicePseudonym: String
    /// The version a re-seal found no row for, or was refused for: never tried
    /// again for it.
    var triedVersion: Int32?
    /// A re-seal sent and not answered yet: what it sent. Dropped by a refusal,
    /// and by any newer send, which replaces the whole record.
    var pending: Pending?

    struct Pending: Codable, Equatable {
        var nonce: String
        var ciphertext: String
        var keyId: String
        var keyVersion: Int32
    }

    /// What a send records of itself: its envelope's bytes as the SDK returned
    /// them, the point as sealed and the envelope's own time, the bubble, and the
    /// version and device pseudonym read before the seal.
    init(sent kind: Kind, envelope: EnvelopeEncryptedLocation, wrap: KeyWrap, point: PingolinTrackSDK.Location,
         coarsenedToMiles: Double?, keyVersion: Int32, devicePseudonym: String) {
        self.kind = kind
        nonce = envelope.ciphertextNonce
        ciphertext = envelope.ciphertext
        keyId = nil
        wrappedKey = wrap.wrappedKey
        wrappedKeyNonce = wrap.wrappedKeyNonce
        latitude = point.latitude
        longitude = point.longitude
        accuracy = point.accuracy
        timestampMs = envelope.timestamp
        self.coarsenedToMiles = coarsenedToMiles
        self.keyVersion = keyVersion
        self.devicePseudonym = devicePseudonym
        triedVersion = nil
        pending = nil
    }

    /// The same record, tried for `version`.
    func tried(_ version: Int32) -> OwnLastSent {
        var tried = self
        tried.triedVersion = version
        return tried
    }

    /// The record as it is once `pending` landed: its point under the blob that
    /// was sent, `c:<version>` and no wrap, untried. Nil with nothing pending.
    func landed() -> OwnLastSent? {
        guard let pending else { return nil }
        var landed = self
        landed.nonce = pending.nonce
        landed.ciphertext = pending.ciphertext
        landed.keyId = pending.keyId
        landed.wrappedKey = nil
        landed.wrappedKeyNonce = nil
        landed.keyVersion = pending.keyVersion
        landed.triedVersion = nil
        landed.pending = nil
        return landed
    }
}

/// One file in Application Support, for the signed-in account only, written as
/// `CirclePauseRecord`'s is: protected until first unlock and kept out of
/// backups, so a plaintext point never reaches iCloud, a Finder backup or, by
/// a restore, another device. It goes with the app, which a Keychain item
/// would not.
@MainActor
final class OwnLastSentStore {
    static let shared = OwnLastSentStore()

    private struct Stored: Codable {
        var owner: String
        var circles: [String: OwnLastSent]
    }

    private let directory: URL?
    private var loaded: Stored?

    /// `directory` nil = Application Support. Tests pass a scratch directory.
    init(directory: URL? = nil) {
        self.directory = directory ?? (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
    }

    var fileURL: URL? {
        directory?.appendingPathComponent("own-last-sent.json", isDirectory: false)
    }

    /// This account's records. Another account's file is never read back: it is
    /// dropped.
    private func stored(owner: String) -> Stored {
        if loaded == nil, let url = fileURL, let data = try? Data(contentsOf: url) {
            loaded = try? JSONDecoder().decode(Stored.self, from: data)
        }
        guard let loaded, CanonicalId.sameKey(loaded.owner, owner) else { return Stored(owner: owner, circles: [:]) }
        return loaded
    }

    func record(circleId: String, owner: String) -> OwnLastSent? {
        stored(owner: owner).circles[CanonicalId.key(circleId)]
    }

    /// The circles this account holds a record for, in their one form.
    func circles(owner: String) -> [String] {
        Array(stored(owner: owner).circles.keys)
    }

    /// A send this phone made replaces the circle's record, tried mark and all:
    /// the row is new.
    func put(_ record: OwnLastSent, circleId: String, owner: String) {
        var stored = stored(owner: owner)
        stored.circles[CanonicalId.key(circleId)] = record
        save(stored)
    }

    /// The circle's record changed by a re-seal run, only while it is still the
    /// record that run read: a send meanwhile is newer, and stays.
    func update(circleId: String, owner: String, from read: OwnLastSent, to new: OwnLastSent) {
        var stored = stored(owner: owner)
        let key = CanonicalId.key(circleId)
        guard stored.circles[key] == read else { return }
        stored.circles[key] = new
        save(stored)
    }

    /// This account left or deleted the circle, or it is gone.
    func forget(circleId: String) {
        if loaded == nil, let url = fileURL, let data = try? Data(contentsOf: url) {
            loaded = try? JSONDecoder().decode(Stored.self, from: data)
        }
        guard var stored = loaded, stored.circles.removeValue(forKey: CanonicalId.key(circleId)) != nil else { return }
        save(stored)
    }

    /// Every sign-out, whatever is kept: the records hold points.
    func wipeAll() {
        loaded = nil
        if let url = fileURL { try? FileManager.default.removeItem(at: url) }
    }

    private func save(_ stored: Stored) {
        loaded = stored
        guard let url = fileURL, let data = try? JSONEncoder().encode(stored) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutableURL.setResourceValues(values)
    }
}
