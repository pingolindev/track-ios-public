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

/// Front-end for the geocoding stack. Two sources:
///
///   - **Local**: SDK's `TileGeocoder` — fetches small (~40km²) tiles
///     on demand from `geocoding.pingolin.com` and caches locally. Works
///     offline. Default.
///   - **Server (opt-in)**: `ServerGeocoder` — proxies a Pelias query
///     through the server's `/api/v1/geocode/reverse`. Higher fidelity
///     (proper named POIs, addresses), gated on an active subscription,
///     gracefully falls back to local on 402/503/network errors.
///
/// Mirrors the Android app's two-mode geocoder. Toggle persisted in
/// `@AppStorage("geocoding.useServerSide")`; reads via UserDefaults
/// here so both Settings and the map share one source of truth.
@MainActor
final class GeocodingService: ObservableObject {
    static let shared = GeocodingService()

    private let geocoder: TileGeocoder
    private let serverGeocoder = ServerGeocoder()
    private var manifestLoaded = false
    /// Set while a bootstrap fetch is running, so a second caller does not start
    /// a second 1 MB download.
    private var manifestLoading = false
    /// Smart-fallback search (cities-tier resolve + on-demand tile load). Held here
    /// so views get it through the same singleton that owns the TileGeocoder —
    /// constructing a second one would mean a second cities database on disk.
    private(set) var smart: SmartSearch!

    private init() {
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        let storagePath = cachesDir?.appendingPathComponent("geocoding", isDirectory: true).path
            ?? NSTemporaryDirectory() + "geocoding"
        try? FileManager.default.createDirectory(
            atPath: storagePath,
            withIntermediateDirectories: true
        )
        self.geocoder = TileGeocoder.withBaseUrl(
            storagePath: storagePath,
            baseUrl: "https://geocoding.pingolin.com"
        )
        self.smart = SmartSearch(geocoder: geocoder, storagePath: storagePath)
    }

    /// Text → locations, falling back to a cities-tier resolve + tile download when
    /// nothing is cached. Prefer this over `forward` for user-typed queries: plain
    /// `forward` answers "no matches" for any place whose tiles are not already on
    /// disk, which is most places the first time someone searches for them.
    func smartSearch(
        query: String,
        limit: Int = 8,
        focusLat: Double? = nil,
        focusLng: Double? = nil,
        area: SmartSearch.SearchArea? = nil,
        cityWide: Bool = false,
        downloads: SmartSearch.Downloads = .always,
        onProgress: ((SmartSearch.Phase?) -> Void)? = nil
    ) async -> SmartSearch.Result {
        await smart.search(
            query: query, limit: limit,
            focusLat: focusLat, focusLng: focusLng,
            area: area, cityWide: cityWide, downloads: downloads,
            onProgress: onProgress
        )
    }

    /// Call once at app launch. Idempotent within a process. Failures are
    /// swallowed to keep startup non-blocking; subsequent forward/reverse calls
    /// return empty until the manifest is available.
    ///
    /// The SDK's `fetchManifest` is SYNCHRONOUS and goes to the network (the
    /// manifest is about 1 MB on the wire, 3.4 MB of JSON to parse). This class
    /// is `@MainActor`, so calling it inline would freeze the main thread for
    /// the whole download at every cold launch. It runs detached; `TileGeocoder`
    /// is `Sendable` (UniFFI objects are internally synchronised).
    func bootstrap() async {
        guard !manifestLoaded, !manifestLoading else { return }
        manifestLoading = true
        defer { manifestLoading = false }
        let geocoder = self.geocoder
        let result: Result<Bool, Error> = await Task.detached(priority: .utility) {
            Result { try geocoder.fetchManifest() }
        }.value
        switch result {
        case .success(let ok):
            manifestLoaded = ok
            #if DEBUG
            print("[Track] GeocodingService.bootstrap manifest=\(ok)")
            #endif
        case .failure(let error):
            #if DEBUG
            print("[Track] GeocodingService.bootstrap failed: \(error)")
            #endif
            _ = error
        }
    }

    /// Text → candidate locations. Empty when the manifest isn't loaded
    /// yet or no tiles around the matches are cached.
    func forward(query: String, limit: Int = 10) -> [GeocodingResult] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return geocoder.forward(query: query, limit: UInt32(limit))
    }

    /// Coordinates → nearest address. Tries the server-side geocoder
    /// first when the user opted in via Settings → Geocoding;
    /// otherwise (or on any failure) falls back to the on-device
    /// `TileGeocoder` which auto-downloads the surrounding tile.
    func reverse(latitude: Double, longitude: Double) async -> GeocodingResult? {
        if UserDefaults.standard.bool(forKey: "geocoding.useServerSide") {
            if let result = await serverGeocoder.reverse(latitude: latitude, longitude: longitude) {
                return result
            }
            // 402/503/network → silent fallback below.
        }
        // Off the main actor for the same reason as `bootstrap`: a reverse
        // lookup outside the cached tiles downloads one, synchronously.
        let geocoder = self.geocoder
        return await Task.detached(priority: .userInitiated) {
            UncheckedResult(value: geocoder.reverse(lat: latitude, lng: longitude))
        }.value.value
    }

    /// Carries the SDK's result record back from the detached lookup. The
    /// generated `GeocodingResult` is a plain value struct that UniFFI does not
    /// mark `Sendable`.
    private struct UncheckedResult: @unchecked Sendable {
        let value: GeocodingResult?
    }
}
