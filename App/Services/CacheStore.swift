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

/// Minimal JSON-backed disk cache for opaque Codable values. Files live
/// in the app's Library/Caches directory with the strongest iOS file
/// protection class, so the contents are hardware-AES-encrypted while
/// the device is locked. Same threat-model coverage the Android app gets
/// from SQLCipher-Room when the OS keystore is hardware-backed.
///
/// Not intended as a full ORM — this is a fallback cache for read-only
/// list endpoints (circles, members, places, …) so the app can render
/// something useful when the network is down. Writes happen after each
/// successful `load*` call in the relevant manager.
actor CacheStore {
    static let shared = CacheStore()

    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private init() {
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    /// Persist `value` under `key`. Errors are swallowed and logged —
    /// this is a best-effort cache, never a hard dependency.
    func save<T: Encodable>(_ value: T, forKey key: String) {
        do {
            let data = try encoder.encode(value)
            let url = try fileURL(for: key)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            print("[Track] CacheStore.save failed for \(key): \(error)")
        }
    }

    /// Load and decode the value previously saved under `key`, or nil
    /// if missing or corrupt. Corrupt rows are deleted so retries don't
    /// trip the same decode failure forever.
    func load<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        do {
            let url = try fileURL(for: key)
            guard fileManager.fileExists(atPath: url.path) else { return nil }
            let data = try Data(contentsOf: url)
            return try decoder.decode(type, from: data)
        } catch {
            print("[Track] CacheStore.load failed for \(key): \(error)")
            try? fileManager.removeItem(at: try fileURL(for: key))
            return nil
        }
    }

    /// Drop a single entry. Used on logout for keys that referenced the
    /// previous account.
    func remove(forKey key: String) {
        if let url = try? fileURL(for: key) {
            try? fileManager.removeItem(at: url)
        }
    }

    /// Wipe every entry under our cache directory. Used on logout.
    func clearAll() {
        do {
            let dir = try cacheDirectory()
            for entry in try fileManager.contentsOfDirectory(atPath: dir.path) {
                try? fileManager.removeItem(at: dir.appendingPathComponent(entry))
            }
        } catch {
            print("[Track] CacheStore.clearAll failed: \(error)")
        }
    }

    // MARK: - Internals

    private func fileURL(for key: String) throws -> URL {
        let dir = try cacheDirectory()
        // Sanitize so a key with a slash can't escape the directory.
        let safe = key.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "..", with: "__")
        return dir.appendingPathComponent("\(safe).json")
    }

    private func cacheDirectory() throws -> URL {
        let base = try fileManager.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = base.appendingPathComponent("PingolinTrackCache", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try fileManager.createDirectory(
                at: dir,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
            )
        }
        return dir
    }
}
