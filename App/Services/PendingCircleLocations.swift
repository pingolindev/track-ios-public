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

/// Locations kept on this device for circles it is waiting to sync, so that
/// what the app says — "Awaiting sync for circle settings from another
/// member. Locations will be queued until synced." — is true.
///
/// A device that does not hold a circle's current version seals nothing new
/// for it: the key it still holds is one a removed member has too. So each
/// point is kept here with the circle's privacy already applied, as a live
/// send would apply it — a paused circle is never a send target, so it keeps
/// nothing; approximate sharing keeps only the coarse cell; a withheld
/// battery level stays withheld — for at most 48 hours, oldest dropped
/// first. Liveness check-ins are never kept: they say "here now".
///
/// A late point is kept here too while it waits for a row read from the server
/// since it was taken, which says whether this account was sharing with the
/// circle then (`CirclePauseRecord.awaitsRead`); the drain sends it after
/// that, or drops it if the account was not.
///
/// Once the device holds the current version they drain oldest first as
/// `history_only` (`SDKLocationStreamer.drainKeptLocations`), one a second: the
/// server files them in history alone — never the member's latest position, no
/// live fan-out, no alerts — whatever their order, within 48 hours of the fix.
///
/// Plaintext on disk, like the self-location seed: Application Support,
/// protected until first unlock (background sends write it while the phone is
/// locked), excluded from backup. Per account; emptied at sign-out and when the
/// circle goes.
@MainActor
final class PendingCircleLocations {
    static let shared = PendingCircleLocations()

    /// The same cap on all three clients.
    static let maxAge: TimeInterval = 48 * 60 * 60
    /// A bound on the file whatever the send rate.
    static let maxPerCircle = 5_000

    /// One kept fix — the fields of `PingolinTrackSDK.Location`.
    struct Point: Codable, Equatable {
        let latitude: Double
        let longitude: Double
        let altitude: Double?
        let speed: Double?
        let heading: Double?
        let accuracy: Double?
        /// Milliseconds since the epoch: when the fix was taken, which is what
        /// the history row carries.
        let timestamp: Int64
        let batteryLevel: UInt8?
        let isCharging: Bool?

        init(_ location: PingolinTrackSDK.Location) {
            latitude = location.latitude
            longitude = location.longitude
            altitude = location.altitude
            speed = location.speed
            heading = location.heading
            accuracy = location.accuracy
            timestamp = location.timestamp
            batteryLevel = location.batteryLevel
            isCharging = location.isCharging
        }

        var location: PingolinTrackSDK.Location {
            PingolinTrackSDK.Location(
                latitude: latitude, longitude: longitude, altitude: altitude, speed: speed,
                heading: heading, accuracy: accuracy, timestamp: timestamp,
                batteryLevel: batteryLevel, isCharging: isCharging)
        }
    }

    private struct Stored: Codable {
        var owner: String
        var circles: [String: [Point]]
    }

    private let directory: URL?
    private var loaded: Stored?

    /// `directory` nil = Application Support. Tests pass a scratch directory.
    init(directory: URL? = nil) {
        self.directory = directory ?? (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
    }

    private var fileURL: URL? {
        directory?.appendingPathComponent("pending-circle-locations.json", isDirectory: false)
    }

    /// This account's points, pruned to the cap. Another account's file is
    /// never read back: it is dropped.
    private func stored(owner: String, now: Date) -> Stored {
        if loaded == nil, let url = fileURL, let data = try? Data(contentsOf: url) {
            loaded = try? JSONDecoder().decode(Stored.self, from: data)
        }
        var stored = loaded?.owner == owner ? loaded! : Stored(owner: owner, circles: [:])
        let oldest = Int64((now.timeIntervalSince1970 - Self.maxAge) * 1000)
        for (circleId, points) in stored.circles {
            let kept = points.filter { $0.timestamp >= oldest }.suffix(Self.maxPerCircle)
            stored.circles[circleId] = kept.isEmpty ? nil : Array(kept)
        }
        return stored
    }

    private func save(_ stored: Stored) {
        loaded = stored
        guard let url = fileURL else { return }
        if stored.circles.isEmpty {
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

    /// Keep one fix for a circle this device cannot send to yet. `location` has
    /// the circle's privacy applied already.
    func keep(_ location: PingolinTrackSDK.Location, circleId: String, owner: String, now: Date = Date()) {
        var stored = stored(owner: owner, now: now)
        var points = stored.circles[circleId] ?? []
        points.append(Point(location))
        points.sort { $0.timestamp < $1.timestamp }
        let oldest = Int64((now.timeIntervalSince1970 - Self.maxAge) * 1000)
        stored.circles[circleId] = Array(points.filter { $0.timestamp >= oldest }.suffix(Self.maxPerCircle))
        save(stored)
    }

    /// What is kept for a circle, oldest first.
    func points(circleId: String, owner: String, now: Date = Date()) -> [Point] {
        stored(owner: owner, now: now).circles[circleId] ?? []
    }

    /// The circles something is kept for.
    func circlesWithPoints(owner: String, now: Date = Date()) -> [String] {
        Array(stored(owner: owner, now: now).circles.keys)
    }

    /// The first `count` points went out.
    func sent(_ count: Int, circleId: String, owner: String, now: Date = Date()) {
        guard count > 0 else { return }
        var stored = stored(owner: owner, now: now)
        let rest = Array((stored.circles[circleId] ?? []).dropFirst(count))
        stored.circles[circleId] = rest.isEmpty ? nil : rest
        save(stored)
    }

    /// The circle is gone from this device (left, deleted, removed).
    func discard(circleId: String) {
        guard var stored = loaded ?? fileURL.flatMap({ try? Data(contentsOf: $0) })
            .flatMap({ try? JSONDecoder().decode(Stored.self, from: $0) }) else { return }
        guard stored.circles.removeValue(forKey: circleId) != nil else { return }
        save(stored)
    }

    /// Sign-out: a signed-out device keeps no location.
    func clearAll() {
        loaded = nil
        if let url = fileURL { try? FileManager.default.removeItem(at: url) }
    }
}
