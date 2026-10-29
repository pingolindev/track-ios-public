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
import MapLibre

/// One-shot configuration of MapLibre Native's tile cache, in line with
/// the Android app's MapLibre Native defaults. MapLibre's ambient
/// cache (stored under the offline-storage database) holds recently
/// fetched tiles so panning + zoom-in/out within a session reuses tiles
/// instead of fetching them again over the network. The Protomaps
/// Basemaps schema produces ~5-50 KB MVT tiles depending on zoom +
/// density; a 64 MB cache holds roughly 2-4k tiles, plenty for a
/// typical session.
///
/// Important: `setMaximumAmbientCacheSize:` must be invoked **before**
/// any `MLNMapView` style is set, otherwise MapLibre will trim against
/// the old size (50 MB default) while the new request is in flight.
enum MapCacheConfig {

    /// 128 MiB. A 256 MiB ambient cache pushes peak memory over
    /// the foreground app budget on older hardware, and iOS then
    /// kills the app between Map-tab visits (jetsam). 128 MiB
    /// is double the Android app's 64 MiB, so warm-zoom tiles
    /// survive across opens within a single session.
    static let maximumCacheBytes: UInt = 128 * 1024 * 1024

    /// Call once at app start before any map view is created.
    static func configure() {
        // ⚠️ PMTilesRangeCache caches nothing with the current tile URLs: do
        // not read its presence as "range requests are cached". It costs one
        // URLProtocol registration.
        //
        // Its `canInit` requires `url.contains(".pmtiles")` AND a Range header.
        // The map fetches https://pmtiles.pingolin.com/tiles/v4/{z}/{x}/{y}.mvt
        // — the host is `pmtiles.`, so the dot falls BEFORE and never matches —
        // and those are whole-tile GETs with no Range header anyway. Nothing on
        // this device opens planet.pmtiles: `rewriteProtomapsSource` deletes the
        // style's `url` key, so the archive is never read.
        //
        // Its rationale (MapLibre's cache.db keys by URL alone, so every range
        // request would overwrite one row) applies only to range requests. What
        // actually retains tiles is the ambient cache sized below.
        //
        // Android's PMTilesRangeCacheInterceptor has the identical `.pmtiles`
        // gate, and its client has no OkHttp cache: both platforms rely on
        // MapLibre's ambient cache, sized on both.
        PMTilesRangeCache.install()

        MLNOfflineStorage.shared.setMaximumAmbientCacheSize(maximumCacheBytes) { error in
            #if DEBUG
            if let error = error {
                print("[Track] MapLibre setMaximumAmbientCacheSize failed: \(error)")
            } else {
                print("[Track] MapLibre ambient cache cap=\(maximumCacheBytes / 1024 / 1024) MiB")
            }
            #endif
        }
    }

    /// Cache drop. **This is an erasure control**, not a debug convenience:
    /// `AuthManager.logout` calls it so account A's cached tiles — which reveal
    /// the areas they panned/zoomed over — do not survive into account B.
    ///
    /// `clearAmbientCache` erases the tile bytes. Do NOT substitute
    /// `invalidateAmbientCache`: that only marks entries stale for revalidation
    /// and leaves the data on disk, which would make this report success while
    /// erasing nothing.
    static func clear(completion: @escaping (Error?) -> Void) {
        MLNOfflineStorage.shared.clearAmbientCache(completionHandler: completion)
        PMTilesRangeCache.clear()
    }
}

// MARK: - PMTiles Range Cache

/// `MapLibreSessions` is the session MapLibre fetches with (styles,
/// sprites, glyphs, and the tiles the range cache passes on): made from
/// MapLibre's own configuration, with the compromised-key check
/// (`TrustBlocklist`). MapLibre asks from background threads; the one
/// session is made once.
final class MapLibreSessions: NSObject, MLNNetworkConfigurationDelegate {
    static let shared = MapLibreSessions()
    private let lock = NSLock()
    private var made: URLSession?

    @objc(sessionForNetworkConfiguration:)
    func session(for configuration: MLNNetworkConfiguration) -> URLSession {
        lock.lock()
        defer { lock.unlock() }
        if let made { return made }
        let session = TrustBlocklist.session(configuration: configuration.sessionConfiguration)
        made = session
        return session
    }
}

/// A URLProtocol subclass that intercepts byte-range GETs against
/// `*.pmtiles` URLs and caches the responses keyed by URL + Range header.
/// Without it, MapLibre's per-URL cache treats every range request as the
/// same resource and refetches across cold launches.
///
/// Cache directory: `Library/Caches/PMTilesRangeCache/`. iOS may
/// purge under disk pressure (that's fine — next miss refetches).
/// TTL is 7 days; PMTiles file contents are functionally immutable
/// (the etag pins the version), so longer would also be safe.
final class PMTilesRangeCache: URLProtocol {

    // Filename = sha256("url|range"). Hex-encoded so it's a valid
    // filesystem name on every platform.
    private static let cacheDir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("PMTilesRangeCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static let ttlSeconds: TimeInterval = 7 * 24 * 3600
    private static let interceptedFlag = "PMTilesRangeCacheIntercepted"

    /// URLSession used to perform the actual network fetch on cache
    /// miss. Crucially, does NOT include this protocol in its
    /// configuration — otherwise canInit() would re-trigger and we'd
    /// recurse infinitely.
    private static let networkSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return TrustBlocklist.session(configuration: config)
    }()

    private var dataTask: URLSessionDataTask?

    /// Install the protocol into MapLibre's URLSession config and
    /// register it globally. Must run before any MLNMapView is
    /// instantiated.
    static func install() {
        URLProtocol.registerClass(PMTilesRangeCache.self)
        let config = URLSessionConfiguration.default
        var protocols: [AnyClass] = config.protocolClasses ?? []
        protocols.insert(PMTilesRangeCache.self, at: 0)
        config.protocolClasses = protocols
        MLNNetworkConfiguration.sharedManager.sessionConfiguration = config
        // MapLibre's own session (styles, sprites, glyphs, and tiles the range
        // cache passes on) is one of ours too, with the compromised-key check
        // (`TrustBlocklist`). The delegate is held weakly there, so it is kept
        // here.
        MLNNetworkConfiguration.sharedManager.delegate = MapLibreSessions.shared
    }

    /// Wipe every cached range. Called from `MapCacheConfig.clear`.
    static func clear() {
        try? FileManager.default.removeItem(at: cacheDir)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    // MARK: URLProtocol overrides

    override class func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url?.absoluteString,
              url.contains(".pmtiles"),
              request.value(forHTTPHeaderField: "Range") != nil else {
            return false
        }
        // Avoid re-intercepting our own cache-miss fetches.
        if URLProtocol.property(forKey: interceptedFlag, in: request) != nil {
            return false
        }
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        guard let url = request.url?.absoluteString,
              let range = request.value(forHTTPHeaderField: "Range") else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let file = Self.fileURL(forUrl: url, range: range)

        // Cache hit?
        if let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
           let modDate = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(modDate) < Self.ttlSeconds,
           let data = try? Data(contentsOf: file) {
            serveCacheHit(data: data)
            return
        }

        // Miss — fetch over the network, persist on success.
        let mutable = (request as NSURLRequest).mutableCopy() as! NSMutableURLRequest
        URLProtocol.setProperty(true, forKey: Self.interceptedFlag, in: mutable)
        let outgoing = mutable as URLRequest
        let task = Self.networkSession.dataTask(with: outgoing) { [weak self] data, response, error in
            guard let self = self else { return }
            if let error = error {
                self.client?.urlProtocol(self, didFailWithError: error)
                return
            }
            guard let data = data, let response = response as? HTTPURLResponse else {
                self.client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            // Persist 206 Partial Content responses (and 200 fall-
            // throughs where the server ignored Range). Anything
            // else — 4xx, 5xx, redirects — pass through without
            // caching.
            if response.statusCode == 200 || response.statusCode == 206 {
                try? data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        }
        self.dataTask = task
        task.resume()
    }

    override func stopLoading() {
        dataTask?.cancel()
        dataTask = nil
    }

    // MARK: Helpers

    private func serveCacheHit(data: Data) {
        guard let url = request.url else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let headers: [String: String] = [
            "Content-Length": "\(data.count)",
            "Accept-Ranges": "bytes",
            "Cache-Control": "private, max-age=\(Int(Self.ttlSeconds))",
        ]
        let response = HTTPURLResponse(
            url: url,
            statusCode: 206,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func fileURL(forUrl url: String, range: String) -> URL {
        let composite = "\(url)|\(range)"
        let digest = SHA256.hash(data: Data(composite.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return cacheDir.appendingPathComponent(hex)
    }
}
