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

/// Client for the opt-in server-side geocoder — `reverse` (coordinates → label)
/// and `forward` (query → places). Counterpart to the Android app's
/// `ServerGeocoder`. Both go through the server's session-less endpoints
/// (`/api/v1/geocode/reverse`, `/api/v1/geocode/search`), authorized by ONE
/// anonymous VOPRF credit rather than the user's JWT, so no identity travels
/// alongside the coordinates or the query text.
///
/// Off by default; flipped on via Settings → Geocoding, premium only. Even when
/// on, callers should treat failures as silent fallback signals — a free/lapsed
/// account cannot mint credits and the backend returns 503 when the proxy is
/// disabled, neither of which should surface a UI error.
///
/// WHAT THE TWO PATHS DISCLOSE IS NOT THE SAME. Reverse sends truncated
/// coordinates. Forward sends **the user's search string**, which is user
/// content. That is exactly why forward is behind the same opt-in and why
/// nothing here logs the query or the response.
struct ServerGeocoder {

    /// Reverse-geocode via the backend proxy. Returns nil on any
    /// failure so the caller can fall back to the local geocoder.
    func reverse(latitude: Double, longitude: Double) async -> GeocodingResult? {
        // Truncate to 4 decimals (~11 m) up front so the anonymous path leaks no
        // more precision than the authed proxy (which truncates internally too).
        let tLat = (latitude * 10_000).rounded() / 10_000
        let tLng = (longitude * 10_000).rounded() / 10_000
        // Anonymous VOPRF credit on the session-less endpoint — no user_id next
        // to the coordinates. When the private path is unavailable (free tier,
        // no credits, token flow down) this returns nil and the caller falls
        // back to the local geocoder. There is no authenticated alternative: a
        // bearer token is never sent alongside the coordinates.
        guard let data = await GeocodeTokenManager.shared.redeemReverse(
            latitude: tLat, longitude: tLng, size: 1
        ) else {
            return nil
        }
        return Self.parsePeliasReverse(data: data, fallbackLat: tLat, fallbackLng: tLng)
    }

    /// Concrete places you can stand in. Forward search keeps ONLY these.
    ///
    /// The gateway happily answers "birmingham" with eight localities, but those
    /// are exactly the rows the on-device city index already owns — and it owns
    /// them BETTER, because it has population and the server does not. Letting
    /// them through would put an unranked "Birmingham, England" above a
    /// population-ranked "Birmingham, AL" from the city channel. Reverse keeps
    /// every layer, because naming a point legitimately falls back to its
    /// locality. Same set as the Android app's `PLACE_LAYERS`.
    private static let placeLayers: Set<String> = ["venue", "address", "street"]

    /// Forward-geocode via the anonymous gateway. Runs only when the user has
    /// opted in to the server-side geocoder.
    ///
    /// The return contract matters:
    ///   - `nil`  = the server COULD NOT answer (no credit, HTTP error,
    ///              unreachable). The caller should fall back to tiles fully.
    ///   - `[]`   = it answered and nothing matched. The planet index has spoken;
    ///              there is no point downloading tens of MB of tiles to ask the
    ///              same question again.
    /// Collapsing these two into "empty means try tiles" makes the fallback
    /// either useless or wasteful; the Android app makes the same distinction.
    func forward(
        query: String, size: Int, focusLat: Double?, focusLng: Double?
    ) async -> ServedPlaces? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nil }
        // Focus coordinates are truncated exactly like reverse coordinates: the
        // query text already leaves the device on this path, but that is no
        // reason to also hand over the user's position at full precision.
        guard let data = await GeocodeTokenManager.shared.redeemSearch(
            text: q, size: size,
            focusLat: focusLat.map { ($0 * 10_000).rounded() / 10_000 },
            focusLng: focusLng.map { ($0 * 10_000).rounded() / 10_000 }
        ) else {
            return nil
        }
        return Self.parseForward(data: data)
    }

    /// What the gateway answered for a forward search: the rows, and whether
    /// it says they are already in the order to show them in.
    struct ServedPlaces {
        var rows: [GeocodingResult]
        /// The gateway ordered these rows itself and says so. Then the list
        /// shows them AS THEY CAME: see `SmartSearch.arrange`.
        var ordered: Bool
    }

    /// A forward answer as rows plus the gateway's word on their order.
    static func parseForward(data: Data) -> ServedPlaces {
        ServedPlaces(rows: parsePeliasFeatures(data: data, placesOnly: true),
                     ordered: isOrdered(data: data))
    }

    /// Did the gateway order these rows itself?
    ///
    /// A search with a focus point is answered by the geocoder's own ranked
    /// route, which marks its reply `geocoding.ranking.version`. A reply
    /// without the mark (an older backend, a search without a focus point, the
    /// gateway falling back to its stock query) is in Pelias's order, which
    /// this app re-orders; a reply WITH it must not be, because the order
    /// carries things this app cannot see in a row: which place is a landmark,
    /// which rows matched only by allowing a typo, which are "a pharmacy"
    /// rather than called one.
    ///
    /// Any version from 1 up counts: a later version may order differently,
    /// but it is still the gateway's order.
    static func isOrdered(data: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let geocoding = json["geocoding"] as? [String: Any],
              let ranking = geocoding["ranking"] as? [String: Any],
              let version = ranking["version"] as? NSNumber else {
            return false
        }
        // A JSON `true` is an NSNumber too (and reads as 1): not a version.
        if CFGetTypeID(version as CFTypeRef) == CFBooleanGetTypeID() { return false }
        return version.doubleValue >= 1
    }

    /// Parse a Pelias FeatureCollection into rows, optionally keeping only
    /// place layers. Returns `[]` (never nil) on a malformed body — by the time
    /// we are here the server DID answer, and the caller's nil branch means
    /// something quite different.
    ///
    /// Deliberately logs nothing: any message here could carry the response body,
    /// and the response body echoes the user's query.
    static func parsePeliasFeatures(data: Data, placesOnly: Bool) -> [GeocodingResult] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = json["features"] as? [[String: Any]] else {
            return []
        }
        return features.compactMap { feature -> GeocodingResult? in
            guard let props = feature["properties"] as? [String: Any] else { return nil }
            if placesOnly {
                guard let layer = props["layer"] as? String,
                      placeLayers.contains(layer) else { return nil }
            }
            // No fallback coordinate on this path: a forward hit with no geometry
            // is not placeable, and dropping it beats dropping a pin at (0, 0).
            return row(from: feature, fallbackLat: nil, fallbackLng: nil)
        }
    }

    /// Lift ONE Pelias feature into the SDK's `GeocodingResult` shape.
    ///
    /// Shared by forward and reverse, so both render identically to a
    /// tile-cache row (the Android app has one `parseFeatures` for both too).
    ///
    /// What each rule is for:
    ///
    ///   * **`resultType` is MAPPED, not the raw Pelias layer.** A venue arrives
    ///     as `"venue"`, which is not `"poi"`, so every POI-specific behaviour
    ///     would silently switch itself off: the street line would never render
    ///     and same-address duplicates would never be collapsed. It would also
    ///     disagree with the tile geocoder, whose rows are `"poi"`/`"address"` —
    ///     and the two land in the SAME list.
    ///   * **`text` on an ADDRESS row is the street line, not the label.** Pelias
    ///     puts "715 North La Brea Avenue" in `name` and appends
    ///     ", Los Angeles, CA, USA" in `label`; using the label would print the
    ///     locality twice, because the secondary line adds it again.
    ///   * **`address` is housenumber + street, POI rows only.** Address rows
    ///     already show the street as their primary line.
    ///   * **The neighbourhood rescues a streetless venue.** Five "Pink's Hot
    ///     Dogs / Los Angeles, CA" rows are indistinguishable; Fairfax District,
    ///     Toluca Lake and Hollywood Hills are genuinely different outlets, so
    ///     show the difference. Once a row HAS a street, the street separates
    ///     them better and the line only fits one of the two.
    private static func row(
        from feature: [String: Any], fallbackLat: Double?, fallbackLng: Double?
    ) -> GeocodingResult? {
        let props = feature["properties"] as? [String: Any] ?? [:]
        func str(_ key: String) -> String? {
            guard let v = props[key] as? String,
                  !v.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return v
        }
        func joined(_ keys: String...) -> String? {
            let s = keys.compactMap { str($0) }.joined(separator: " ")
            return s.isEmpty ? nil : s
        }

        var lat = fallbackLat
        var lng = fallbackLng
        if let geometry = feature["geometry"] as? [String: Any],
           let coords = geometry["coordinates"] as? [Double], coords.count >= 2 {
            lng = coords[0]                     // GeoJSON is [lng, lat]
            lat = coords[1]
        }
        guard let lat, let lng else { return nil }

        let layer = str("layer") ?? ""
        let resultType = (layer == "address" || layer == "street") ? "address" : "poi"
        let name = str("name")
        let text = resultType == "address"
            ? (name ?? joined("housenumber", "street") ?? str("label"))
            : (str("label") ?? name)
        guard let text, !text.isEmpty else { return nil }

        let street = resultType == "poi" ? joined("housenumber", "street") : nil
        let locality = str("locality") ?? str("localadmin")
        let hood = str("neighbourhood") ?? str("borough")
        let city: String?
        if street != nil {
            city = locality ?? hood
        } else if let hood, let locality {
            city = hood.caseInsensitiveCompare(locality) == .orderedSame
                ? locality
                : "\(hood), \(locality)"
        } else {
            city = locality ?? hood
        }

        return GeocodingResult(
            text: text,
            lat: lat,
            lng: lng,
            resultType: resultType,
            confidence: (props["confidence"] as? Double) ?? 0.5,
            name: name,
            city: city,
            // Prefer the abbreviations. Pelias sends both ("California" + "CA");
            // the tile geocoder only has the short forms and both land in one
            // list, so "Manteca, California" beside "Manteca, CA" looks broken.
            state: str("region_a") ?? str("region"),
            postcode: str("postalcode"),
            country: str("country_a") ?? str("country"),
            address: street
        )
    }

    /// Parse a Pelias `/v1/reverse` FeatureCollection — first feature's
    /// `properties.label` becomes the display text; coordinates come
    /// from `geometry.coordinates` (lng, lat). On a malformed payload
    /// we fall back to the truncated input coords so the marker still
    /// places correctly, even if the label is generic.
    private static func parsePeliasReverse(data: Data, fallbackLat: Double, fallbackLng: Double) -> GeocodingResult? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = json["features"] as? [[String: Any]],
              let first = features.first else {
            return nil
        }
        // Same builder as forward — see `row`. The fallback coordinates keep a
        // feature with no geometry placeable here (unlike forward, where an
        // unplaceable hit is simply dropped): the caller asked about a point it
        // already knows, so the label is the only thing in question.
        //
        // Returning nil, rather than inventing an "Unknown location", is the
        // correct signal, and the one Android gives (`parseFeatures(...).first`):
        // the caller then falls back to the on-device tile geocoder instead of
        // rendering a placeholder as though the server had answered.
        return row(from: first, fallbackLat: fallbackLat, fallbackLng: fallbackLng)
    }
}
