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
import SwiftUI

/// Reverse-geocoded addresses for circle members' positions, so the member
/// sheet can read "1500 McHenry Avenue, Modesto" instead of only a coloured
/// dot and an age.
///
/// One entry point: ``resolve(userId:latitude:longitude:)``, the on-demand
/// lookup behind an explicit member tap. Nothing geocodes a member in the
/// background — a tap is itself the request for the address, and markers
/// never carry an address line. Same shape as the Android app's
/// `MapViewModel.resolveMemberAddress` and the web client's member click
/// handler.
///
/// There is deliberately no precondition check before geocoding: a check of
/// whether local tiles are on disk would block the server geocoder when no
/// tiles are downloaded. ``GeocodingService/reverse(latitude:longitude:)``
/// already tries the server and falls back to tiles on its own, so calling
/// it is the whole precondition.
@MainActor
final class MemberAddressStore: ObservableObject {
    static let shared = MemberAddressStore()

    /// Coordinate → address text, keyed by ``cacheKey(userId:latitude:longitude:)``.
    /// Published so an open sheet re-renders the moment a lookup lands.
    @Published private(set) var addresses: [String: String] = [:]

    /// Keys with a lookup in flight. Check-then-act over this and
    /// `addresses` is atomic by virtue of the main actor — the same
    /// guarantee android buys with `synchronized(memberAddressCache)`.
    /// Without it a member who moves 2 m mid-lookup gets a second
    /// request for a key the first one is already fetching.
    private var inFlight: Set<String> = []

    /// `@MainActor` because the only real implementation is
    /// `GeocodingService`, which is itself main-isolated — stating it here
    /// rather than hopping per call keeps the isolation honest.
    private let reverse: @MainActor (Double, Double) async -> String?

    /// - Parameter reverse: coordinate → address text. Injectable so the
    ///   behaviour can be tested without a `TileGeocoder` on disk or a
    ///   server round trip.
    init(
        // placardAddress, not `text`: the city and state have to come off the
        // structured fields or whether they appear depends on which geocoder
        // answered — the tile geocoder bakes them into `text`, ServerGeocoder
        // does not. One line on a member callout, so the POI name rides along.
        reverse: @escaping @MainActor (Double, Double) async -> String? = { lat, lng in
            guard let r = await GeocodingService.shared.reverse(latitude: lat, longitude: lng)
            else { return nil }
            return AddressFormat.placardAddress(r, withPOIName: true)
        }
    ) {
        self.reverse = reverse
    }

    /// Cache key: user plus coordinates rounded to 5 decimal places
    /// (~1 m). A stationary phone still reports a fix that wanders by a
    /// few metres, and keying on the raw double would mint a fresh entry
    /// — and a fresh geocode — on every one of those. Byte-for-byte the
    /// shape android and web both use, so the three stay comparable.
    nonisolated static func cacheKey(userId: String, latitude: Double, longitude: Double) -> String {
        String(format: "%@-%.5f-%.5f", userId, latitude, longitude)
    }

    func address(userId: String, latitude: Double, longitude: Double) -> String? {
        addresses[Self.cacheKey(userId: userId, latitude: latitude, longitude: longitude)]
    }

    /// Cached address if present, otherwise reverse-geocode and cache.
    /// Returns nil when the lookup found nothing. The caller is a tap.
    @discardableResult
    func resolve(userId: String, latitude: Double, longitude: Double) async -> String? {
        let key = Self.cacheKey(userId: userId, latitude: latitude, longitude: longitude)
        if let cached = addresses[key] { return cached }
        guard !inFlight.contains(key) else { return nil }
        inFlight.insert(key)
        defer { inFlight.remove(key) }

        guard let text = await reverse(latitude, longitude), !text.isEmpty else { return nil }
        addresses[key] = text
        return text
    }

    /// The address of where someone was is a past position too. For a member
    /// whose history the circle isn't shown, only their newest position's
    /// address is kept (`keeping`); none, for one drawn nowhere.
    func keepOnly(userId: String, keeping point: (latitude: Double, longitude: Double)?) {
        let kept = point.map { Self.cacheKey(userId: userId, latitude: $0.latitude, longitude: $0.longitude) }
        let dropped = addresses.keys.filter { $0.hasPrefix("\(userId)-") && $0 != kept }
        guard !dropped.isEmpty else { return }
        for key in dropped { addresses.removeValue(forKey: key) }
    }

    func reset() {
        addresses.removeAll()
        inFlight.removeAll()
    }
}
