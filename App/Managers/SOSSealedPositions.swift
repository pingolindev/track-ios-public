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

/// What THIS device last sealed as the position of each SOS it raised:
/// never the row the server serves. A re-seal (a rotation, or an update)
/// seals this record, so a position the server swapped into the row is
/// never re-sealed under the new key, and a served position that differs
/// from it is sealed back.
///
/// A position is kept AS SEALED: opened back from the blob this device
/// sealed, in the precision the SDK's packed codec gives it (degrees on the
/// 1e-7 grid, the accuracy an f32), and kept exactly. So "the served row
/// differs" compares decoded with decoded, never with the doubles this
/// device started from: those differ in the last bits, and every check
/// would re-seal until the hourly budget was gone.
///
/// Per account, durable (it outlives a restart), protected until first unlock
/// (an update can be sealed while the phone is locked), excluded from backup.
/// Removed when the alert ends and with the account's data at sign-out.
@MainActor
final class SOSSealedPositions {
    static let shared = SOSSealedPositions()

    /// One alert's record.
    struct Record: Codable, Equatable {
        var circleId: String
        /// The press (ms), kept across a restart. (An alert this device has no
        /// record of counts from its sealed raise time: `SOSManager.openedRecord`.)
        var pressAtMs: Int64
        /// A position as sealed, or nil for a marker.
        var position: Sealed?
        /// The marker sealed instead of a position.
        var marker: SOSPositionMarker?
        /// Why "unavail" was sealed, when it was for location being off.
        var locationOff: Bool = false
        /// Position updates the update rule has sealed (at most `SOSManager.maxPositionUpdates`).
        var updates: Int = 0
        /// The raise time this device sealed (`encrypted_timestamp`, ms), opened
        /// back from the blob it sealed, as the position is: what every re-seal
        /// seals, so a served raise time that differs is sealed back, never
        /// re-sealed. Nil in a record written by an earlier version, whose
        /// re-seals seal the time as it opens.
        var raisedAtMs: Int64?
    }

    /// A position as the SDK decodes the blob this device sealed, each value
    /// kept as its bits: the file gives back exactly that value, and a copy
    /// the server serves compares exactly, decoded against decoded.
    struct Sealed: Codable, Equatable {
        private var latitudeBits: Int64
        private var longitudeBits: Int64
        var takenAtMs: Int64
        private var accuracyBits: Int64?

        init(_ location: Location) {
            latitudeBits = Int64(bitPattern: location.latitude.bitPattern)
            longitudeBits = Int64(bitPattern: location.longitude.bitPattern)
            takenAtMs = location.timestamp
            accuracyBits = location.accuracy.map { Int64(bitPattern: $0.bitPattern) }
        }

        var latitude: Double { Double(bitPattern: UInt64(bitPattern: latitudeBits)) }
        var longitude: Double { Double(bitPattern: UInt64(bitPattern: longitudeBits)) }
        var accuracy: Double? { accuracyBits.map { Double(bitPattern: UInt64(bitPattern: $0)) } }

        /// The position to seal again: values the codec already holds, so it
        /// packs them to the same bytes.
        var location: Location {
            Location(latitude: latitude, longitude: longitude, altitude: nil, speed: nil, heading: nil,
                     accuracy: accuracy, timestamp: takenAtMs, batteryLevel: nil, isCharging: nil)
        }
    }

    private struct Stored: Codable {
        var owner: String
        var alerts: [String: Record]
    }

    private let directory: URL?
    private var loaded: Stored?

    /// `directory` nil = Application Support. Tests pass a scratch directory.
    init(directory: URL? = nil) {
        self.directory = directory ?? (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
    }

    private var fileURL: URL? {
        directory?.appendingPathComponent("sos-sealed-positions.json", isDirectory: false)
    }

    /// This account's records. Another account's file is never read back.
    private func stored(owner: String) -> Stored {
        if loaded == nil, let url = fileURL, let data = try? Data(contentsOf: url) {
            loaded = try? JSONDecoder().decode(Stored.self, from: data)
        }
        return loaded?.owner == owner ? loaded! : Stored(owner: owner, alerts: [:])
    }

    private func save(_ stored: Stored) {
        loaded = stored
        guard let url = fileURL else { return }
        if stored.alerts.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutableURL.setResourceValues(values)
    }

    func record(alertId: String, owner: String?) -> Record? {
        guard let owner = CanonicalId.of(owner) else { return nil }
        return stored(owner: owner).alerts[CanonicalId.key(alertId)]
    }

    /// Kept after a create or a re-seal that the server took.
    func note(_ record: Record, alertId: String, owner: String?) {
        guard let owner = CanonicalId.of(owner) else { return }
        var stored = stored(owner: owner)
        stored.alerts[CanonicalId.key(alertId)] = record
        save(stored)
    }

    /// The alert ended (closed, refused with a 404, or past its alarm age).
    func forget(alertId: String, owner: String?) {
        guard let owner = CanonicalId.of(owner) else { return }
        var stored = stored(owner: owner)
        guard stored.alerts.removeValue(forKey: CanonicalId.key(alertId)) != nil else { return }
        save(stored)
    }

    /// Past its alarm age by its press (the sealed raise time to within the
    /// moment it took to seal): the alert no longer alarms, and its record goes.
    func prune(owner: String?, nowMs: Int64, maxAgeMs: Int64) {
        guard let owner = CanonicalId.of(owner) else { return }
        var stored = stored(owner: owner)
        let kept = stored.alerts.filter { nowMs - $0.value.pressAtMs <= maxAgeMs }
        guard kept.count != stored.alerts.count else { return }
        stored.alerts = kept
        save(stored)
    }

    /// Sign-out: with the account's data.
    func clearAll() {
        loaded = nil
        if let url = fileURL { try? FileManager.default.removeItem(at: url) }
    }
}
