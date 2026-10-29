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
import Network
import PingolinTrackSDK

/// Smart-fallback address search — the iOS counterpart of the Android app's
/// `SmartSearch.kt` and the web client's smart search.
///
/// WHY THIS EXISTS
///   A bare `TileGeocoder.forward(...)` finds nothing for any query whose tiles
///   are not already on disk — even a perfectly ordinary "1600 pennsylvania ave,
///   washington dc" — and that failure looks like a broken app rather than a
///   missing download.
///
/// THE FLOW (the same three steps on every platform)
///   1. Run the plain forward search AND the cities-tier index against what is
///      already on disk.
///   2. If either produced hits, return them.
///   3. If both came back empty, peel a city/state hint out of the query, resolve it
///      through the cities index, load that city's address+POI shard tiles, and
///      re-search the remaining address text against the freshly loaded tiles.
///
/// SCOPE vs Android's
///   Viewport clamping (`area`), the expand-to-whole-city mode (`cityWide`), the
///   opt-in server path with its `fromServer` provenance, focus-aware city
///   ranking, and the focus-area probe with its metered-network gate are all
///   here, as is RANKING POLICY: `CityRanking.rankPlaces`
///   for venue/address rows and `rankScopedResults` inside a resolved city. No
///   distance-only sort: it would silently undo the match-quality gate, which is
///   also why the Android app has no `rankByFocus`.
///
/// The type is UI-free: callers own their state. `onProgress` fires with the city
/// being loaded so a view can say "Loading addresses for Austin, TX…" instead of
/// showing an empty list for several seconds.
@MainActor
final class SmartSearch {
    /// Where a fallback search ended up, so a view can say "Couldn't find that
    /// address in Austin, TX" rather than a bare "no results".
    struct Scope: Equatable {
        let city: String
        let admin1: String
        let countryCode: String

        var label: String {
            [city, AddressFormat.namedRegion(admin1) ?? ""].filter { !$0.isEmpty }.joined(separator: ", ")
        }

        /// Scope for an expand-to-city that could not resolve a city — rural or
        /// unincorporated, where the search covered the focus cell plus its
        /// neighbours. Reads as "In this area", which is all we can honestly claim.
        static let nearbyArea = Scope(city: "this area", admin1: "", countryCode: "")
    }

    /// What the search is doing right now, so the sheet can say so.
    ///
    /// WHY THIS IS MORE THAN A SPINNER FLAG
    ///   The fallback's slow steps are downloads — a city index (~7 MB) and then a
    ///   city's map tiles. A signal that fired only once the city had resolved,
    ///   i.e. after the city-index download had finished, would leave the slowest
    ///   step the most silent one, and a user watching an empty list could not
    ///   tell a slow download from "this address does not exist".
    enum Phase: Equatable {
        /// Fetching the city index, before any city is known.
        case downloadingCityIndex
        /// Pulling the map tiles for a city we have now resolved.
        case loadingTiles(Scope)
    }

    struct Result {
        var addresses: [GeocodingResult]
        /// City hits, only from the DIRECT path. The fallback never surfaces the
        /// city it scoped to: tapping it would drop a pin on the city centroid
        /// instead of the street address the user typed.
        var cities: [CityResult]
        /// Set when the fallback resolved a city, even if `addresses` is empty.
        var scopedTo: Scope?
        /// These rows came from the gateway's planet index, not this device's
        /// tiles. The view needs it for the EMPTY case above all: a server
        /// no-match must not be reported as "nothing on this part of the map",
        /// because the server never looked at the map. Counterpart to the
        /// Android app's `SearchOutcome.fromServer`.
        var fromServer: Bool = false
        /// A download the fallback needed did not finish in time. Distinct from
        /// "found nothing": the search never got to look, so telling the user
        /// there are no matches would be a lie.
        var timedOut: Bool = false
        /// The whole-city search left tiles of the city undownloaded because the
        /// network is metered: the sheet offers them on a tap.
        var moreToDownload: Bool = false

        static let empty = Result(addresses: [], cities: [], scopedTo: nil)
    }

    /// When the whole-city search may download what it is missing (the same
    /// rule on every platform). An unrequested download waits for an unmetered
    /// network; a tap is a request, and so is a city typed into the query
    /// (step 3 downloads it on any network, as the Android app does).
    enum Downloads: Equatable {
        case always
        case ifUnmetered
    }

    /// The slice of the world a search is confined to — the map viewport the user
    /// can actually see. Matches the Android app's `SearchArea`.
    ///
    /// WHY CLAMP AT ALL
    ///   `forward` searches every tile on disk, so a city the user looked at weeks
    ///   ago competes with the one under their thumb. Ranking (below) fixes the
    ///   ORDER; only the clamp stops a Seattle street appearing at all when the user
    ///   is staring at Manhattan and is asking about what they can see.
    struct SearchArea: Equatable {
        let south: Double
        let west: Double
        let north: Double
        let east: Double

        /// True when `(lat, lng)` falls inside the box, antimeridian included.
        func contains(lat: Double, lng: Double) -> Bool {
            if lat < south || lat > north { return false }
            // west > east means the box wraps past ±180 (e.g. a map over Fiji).
            // The inside is then the UNION of [west, 180] and [-180, east] — a
            // plain `west...east` range would test the gap and exclude everything.
            // (In Swift it would also trap: `180.0...(-179.0)` is an invalid range.)
            return west <= east ? (lng >= west && lng <= east) : (lng >= west || lng <= east)
        }

        /// Slack added to each side of the viewport, as a fraction of its half-span.
        private static let padFraction = 0.25
        /// Floor on the box's half-span. Without it, a user zoomed to a single
        /// street searching "starbucks" would be asking about ~200 m of road and get
        /// nothing; a couple of km reads as "around here".
        private static let minHalfSpanKm = 2.0
        private static let kmPerDegreeLat = 111.32

        /// Build the box for a map viewport. Inputs are the raw visible bounds;
        /// `east < west` is accepted and means the view crosses ±180.
        static func fromViewport(
            south: Double, west: Double, north: Double, east: Double
        ) -> SearchArea {
            let latCenter = (south + north) / 2
            // Normalize an antimeridian-crossing span to a positive width before
            // halving it, otherwise the centre lands on the far side of the planet.
            let lngSpan = (east - west) < 0 ? (east - west) + 360.0 : (east - west)
            let lngCenter = normalizeLng(west + lngSpan / 2)

            var latHalf = ((north - south) / 2) * (1 + padFraction)
            var lngHalf = (lngSpan / 2) * (1 + padFraction)

            // A degree of longitude narrows towards the poles; clamp the cosine so
            // a polar viewport doesn't divide by ~0 and produce an infinite box.
            let kmPerDegreeLng = max(kmPerDegreeLat * cos(latCenter * .pi / 180), 0.001)
            latHalf = max(latHalf, minHalfSpanKm / kmPerDegreeLat)
            lngHalf = max(lngHalf, minHalfSpanKm / kmPerDegreeLng)

            let southEdge = max(latCenter - latHalf, -90.0)
            let northEdge = min(latCenter + latHalf, 90.0)
            // Once the box spans every meridian, wrapping it would make west > east
            // and read as an antimeridian box that excludes the middle of the world.
            guard lngHalf < 180.0 else {
                return SearchArea(south: southEdge, west: -180.0, north: northEdge, east: 180.0)
            }
            return SearchArea(
                south: southEdge,
                west: normalizeLng(lngCenter - lngHalf),
                north: northEdge,
                east: normalizeLng(lngCenter + lngHalf)
            )
        }

        private static func normalizeLng(_ lng: Double) -> Double {
            var l = lng
            while l > 180.0 { l -= 360.0 }
            while l < -180.0 { l += 360.0 }
            return l
        }
    }

    private let geocoder: TileGeocoder
    private let cityIndex: CityIndex
    /// Asks the gateway: one spent credit per call. A seam, so a test can count
    /// what a typing session redeems.
    var askServer: (_ text: String, _ size: Int, _ focusLat: Double?, _ focusLng: Double?) async
        -> ServerGeocoder.ServedPlaces? = { text, size, focusLat, focusLng in
            await ServerGeocoder().forward(query: text, size: size, focusLat: focusLat, focusLng: focusLng)
        }
    /// The gateway may be asked at all: the Settings opt-in AND premium, read at
    /// every call. Premium is re-checked rather than trusted from the toggle: the
    /// switch is disabled for free users, but a lapsed subscription leaves the
    /// stored flag `true`, and that must not keep sending queries off-device.
    var serverAllowed: @MainActor () -> Bool = {
        UserDefaults.standard.bool(forKey: SmartSearch.useServerGeocoderKey)
            && PremiumManager.shared.effectivePremium
    }

    private static let tier1URL = "https://geocoding.pingolin.com/cities/cities-tier1.sqlite.zst"
    private static let tier2URL = "https://geocoding.pingolin.com/cities/cities-tier2.sqlite.zst"
    private static let byCountryPrefix = "https://geocoding.pingolin.com/cities/by-country/"

    /// Where the tiles live on disk: `tile_<id>.sqlite`, as the SDK writes them.
    private let storagePath: String

    /// Is the network unmetered now. A seam: a test says which.
    var isUnmetered: () async -> Bool = { await SmartSearch.unmeteredNetwork() }

    init(geocoder: TileGeocoder, storagePath: String) {
        self.geocoder = geocoder
        self.storagePath = storagePath
        self.cityIndex = CityIndex(storagePath: (storagePath as NSString)
            .appendingPathComponent("cities"))
    }

    // MARK: - Entry point

    func search(
        query: String,
        limit: Int = 8,
        focusLat: Double? = nil,
        focusLng: Double? = nil,
        /// Confines the direct path to the visible map. Nil = search everything on
        /// disk, which is what the non-map surfaces (places, destinations) want.
        area: SearchArea? = nil,
        /// Leave the viewport: resolve the city under the focus point, load its
        /// WHOLE tile set, and search that instead. The sheet runs it by itself
        /// after the map-view search, and on a tap.
        cityWide: Bool = false,
        /// Whether `cityWide` may download missing tiles now.
        downloads: Downloads = .always,
        onProgress: ((Phase?) -> Void)? = nil
    ) async -> Result {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return .empty }

        if cityWide, let lat = focusLat, let lng = focusLng {
            return await cityWideSearch(q, limit: limit, focusLat: lat, focusLng: lng,
                                        downloads: downloads, onProgress: onProgress)
        }

        // Step 0 — the opt-in server path. When it answers, its answer IS the
        // answer, including an empty one: the toggle selects a SOURCE, not a
        // preference. Blending server and tile rows would make results depend on
        // which tiles a device happened to have cached, so the same query on two
        // phones in the same street would return different things.
        let cities = await searchCities(q, limit: 6, focusLat: focusLat, focusLng: focusLng)
        if let served = await serverForward(q, limit: limit, focusLat: focusLat, focusLng: focusLng) {
            // NOT clamped. These rows were fetched for THIS query against a planet
            // index and are already relevance-ranked; clamping them to the screen
            // would delete the answer — "pinks hot dogs" from Modesto returns 20
            // correct LA venues, and the clamp would drop all 20 leaving stale tile
            // junk. Android encodes the same exemption as `!direct.fromServer`.
            let anchor = await anchorPoint(focusLat: focusLat, focusLng: focusLng, query: q)
            let rows = Self.arrange(served, limit: limit, focusLat: anchor?.0,
                                    focusLng: anchor?.1, query: q)
            return Result(addresses: rows, cities: cities, scopedTo: nil, fromServer: true)
        }
        // A newer query replaced this one while the gateway was asked. Stop before
        // the tiles, which can download; any answer the gateway gave is cached.
        if Task.isCancelled { return .empty }

        // Step 1 — what is already on disk. Best-effort: an empty result is a
        // legitimate answer that step 3 is there to handle.
        let cached = await forward(q, limit: limit, focusLat: focusLat, focusLng: focusLng)

        // Clamp to the viewport. Unconditional here because everything that
        // reaches this line is a TILE row — "whatever this device happens to have
        // cached" — and the server rows that must never be clamped already
        // returned above.
        let direct = area.map { box in
            cached.filter { box.contains(lat: $0.lat, lng: $0.lng) }
        } ?? cached

        // Step 2 — note this tests the CLAMPED list, so a query whose only cached
        // hits are off-screen still falls through to the city fallback below.
        if !direct.isEmpty {
            // RANK BEFORE RETURNING. `forward` searches every tile on disk, so an
            // unqualified match from a city the user looked at weeks ago competes
            // with the one they just asked for. Unranked, "350 fifth ave, new york,
            // ny" could put "11350 5th Avenue SW, Seattle" FIRST, purely because
            // a Seattle tile is cached and its street tokenises the same.
            //
            // Anchor: the focus point if we have one, else the city the query itself
            // names. That second case is what rescues a typed "…, new york, ny" with
            // no map focus — which is exactly the comma form this whole fallback
            // exists for.
            let anchor = await anchorPoint(focusLat: focusLat, focusLng: focusLng, query: q)
            let ranked = CityRanking.rankPlaces(direct, focusLat: anchor?.0, focusLng: anchor?.1,
                                                query: q)
            // Attribute hits served from the current map area to "this area"
            // rather than leaving them unlabelled. It also keeps the label stable:
            // once the focus-area probe below warms the current-area tile, the
            // debounced re-search comes back through THIS path, and a nearest hit
            // close to the map centre must still read as the current area.
            //
            // "Every hit is on screen by construction" holds only when the clamp
            // actually ran; when it did not, let the distance test decide.
            let scope: Scope? = area != nil
                ? .nearbyArea
                : Self.currentAreaScope(ranked, focusLat: focusLat, focusLng: focusLng)
            return Result(addresses: Array(ranked.prefix(limit)), cities: cities, scopedTo: scope)
        }

        // The cities index matched but nothing addressable did. For a one-word
        // query that match is often a DISTANT same-name city ("firestone" →
        // Firestone, CO), and `buildCandidates` cannot peel a hint off a single
        // token — so probe the focused map area for a same-name POI first and
        // surface those ABOVE the city. Mirrors the Android app, including its
        // short-circuit: a query the cities index answered does not go on to
        // the address-candidate fallback.
        if !cities.isEmpty {
            if Task.isCancelled { return .empty }
            if let lat = focusLat, let lng = focusLng, await isUnmetered() {
                let probed = await withTimeout {
                    await self.probeFocusArea(q, limit: limit, focusLat: lat, focusLng: lng,
                                              area: area, onProgress: onProgress)
                }
                if let near = probed ?? nil, !near.isEmpty {
                    return Result(addresses: near, cities: cities, scopedTo: .nearbyArea)
                }
            }
            onProgress?(nil)
            return Result(addresses: [], cities: cities, scopedTo: nil)
        }

        // Step 3 — nothing cached matched. Resolve a city hint and go get its tiles.
        var triedScope: Scope?
        for candidate in Self.buildCandidates(q) {
            if Task.isCancelled { return .empty }
            // Focus-aware: the winner here decides WHICH city's tiles get
            // downloaded, so "main street, springfield" has to resolve to the
            // Springfield the user is near, not the most populous one on earth.
            guard let city = await resolveCity(candidate.hint, focusLat: focusLat,
                                               focusLng: focusLng, onProgress: onProgress)
            else { continue }
            // A positional guess has to be corroborated before we spend a tile
            // download and a header on it.
            guard Self.cityCorroborates(city, candidate) else { continue }
            let address = candidate.address
            let scope = Scope(city: city.name, admin1: city.admin1, countryCode: city.countryCode)
            onProgress?(.loadingTiles(scope))

            // The address half is the term: the shard is queried for the street
            // the user typed, so only the tiles holding it come down.
            // Budgeted: this downloads. A fetch that cannot reach the CDN sits
            // on "Operation timed out" for MINUTES, and an unbounded wait here
            // would let a stalled search masquerade as "no matches".
            let loadedOrTimeout = await withTimeout {
                await self.loadTiles(for: city, matching: address)
            }
            guard let loadedMaybe = loadedOrTimeout else {
                onProgress?(nil)
                // Report the scope we were working in — the sheet can then say
                // WHICH city's data it failed to fetch.
                return Result(addresses: [], cities: [], scopedTo: scope, timedOut: true)
            }
            guard let loaded = loadedMaybe else { continue }

            // RESTRICT TO THE CITY'S OWN CELLS. `forward` is global over every tile
            // on disk, so without this the rows under an "In <city>" header can come
            // from anywhere the device happens to have cached: a hint that
            // mis-resolves to Hohhot could list a bakery in SEATTLE under "In
            // Hohhot, 20" — the header and the rows would disagree, and the header is
            // the only thing telling the user where we looked. `cityWideSearch`
            // applies the same restriction.
            //
            // Empty is then a truthful "not in this city" rather than cross-region
            // noise. Cities with no tile set (centroid-only rows, where loadTiles
            // fell back to the cell + neighbours) keep proximity ranking unfiltered,
            // because there is no cell list to test against.
            var hits = await forward(address, limit: Self.townRows, focusLat: city.lat, focusLng: city.lng)
            var inScope = loaded.cells.map { cells in
                hits.filter { Self.inCells(cells, lat: $0.lat, lng: $0.lng) }
            } ?? hits
            // A miss in the town's own tile and the shard's or the index's:
            // the eight tiles beside the town's, nearest its point first,
            // started within `neighbourWindow` (as the Android app does). A
            // hit never loads them: each can be tens of MB. "21810 Stevens
            // Creek Boulevard, Cupertino" is in 9q9hq, beside the town's
            // 9q9hr.
            if inScope.isEmpty, let cells = loaded.cells, let town = loaded.town {
                let geocoder = self.geocoder
                let widening = Widening(tile: town, lat: city.lat, lng: city.lng)
                let widened = await withTimeout {
                    await self.offMain { Self.loadNeighbours(of: widening, geocoder: geocoder) }
                }
                if Task.isCancelled { return .empty }
                guard let around = widened else {
                    onProgress?(nil)
                    return Result(addresses: [], cities: [], scopedTo: scope, timedOut: true)
                }
                if !around.isEmpty {
                    let wider = cells.union(around)
                    hits = await forward(address, limit: Self.townRows, focusLat: city.lat, focusLng: city.lng)
                    inScope = hits.filter { Self.inCells(wider, lat: $0.lat, lng: $0.lng) }
                }
            }
            // The city-scoped path ranks differently from every other one: an
            // exact POSTCODE match wins outright, then distance from the city
            // centroid. The user who typed "hickman ca 95323" told us which of a
            // city's postcodes they meant, and that beats being nearer the
            // centroid. The Android app's `rankScopedResults` does the same.
            let scoped = Self.rankScopedResults(inScope, query: q,
                                                scopeLat: city.lat, scopeLng: city.lng)

            if !scoped.isEmpty {
                // No `cities` here on purpose — see the doc on Result.cities.
                return Result(addresses: Array(scoped.prefix(limit)), cities: [], scopedTo: scope)
            }
            // City resolved but the address is not in it. Remember the scope so the
            // view can say WHERE we looked, then KEEP GOING: a bogus early candidate
            // (the "hot" in "pinks hot dogs") must not short-circuit a later one that
            // would have resolved properly. The Android app does the same with its
            // own `triedScope`.
            if triedScope == nil { triedScope = scope }
        }

        // The focus-area probe — default the scope to the area under the map.
        //
        // Reached only when the direct search and every typed-city candidate came
        // back empty AND no typed city resolved (`triedScope == nil`), so it can
        // never override a city the user actually asked for. The server path
        // returned above, so reaching here also means the gateway was not
        // conclusive — the Android app spells that out as
        // `!direct.serverConclusive` because its server rows merge rather than
        // return early.
        //
        // This is the step that finds a POI the user can SEE but has never
        // searched for: it loads the single precision-4 cell under the map centre.
        if Task.isCancelled { return .empty }
        if let lat = focusLat, let lng = focusLng, triedScope == nil,
           await isUnmetered() {
            let probed = await withTimeout {
                await self.probeFocusArea(q, limit: limit, focusLat: lat, focusLng: lng,
                                          area: area, onProgress: onProgress)
            }
            guard let probeResult = probed else {
                onProgress?(nil)
                return Result(addresses: [], cities: [], scopedTo: .nearbyArea, timedOut: true)
            }
            // nil = the tile never loaded, so we did not look and have not earned
            // a scope; [] = we looked here and found nothing, which has.
            if let near = probeResult {
                if !near.isEmpty {
                    return Result(addresses: near, cities: [], scopedTo: .nearbyArea)
                }
                triedScope = .nearbyArea
            }
        }

        // Nothing resolved to anything containing the address. Report the last scope
        // we actually looked in, so the empty state can name it.
        return Result(addresses: [], cities: triedScope == nil ? cities : [], scopedTo: triedScope)
    }

    /// Probe the focused map area for anything matching `q`.
    ///
    /// Loads the single precision-4 tile under the focus point and searches it,
    /// dropping any trailing comma hint first. Returns:
    ///   - `nil`  — nothing was searched: the coordinates map to no tile in the
    ///              manifest, the manifest is not loaded, or the fetch failed
    ///              (`ensure_tile_for_coords_loaded` is `Ok(false)` only for the
    ///              first case and `Err` for the others — it is idempotent and
    ///              still reports true for an already-resident tile); and
    ///   - a list — the proximity-ranked local hits, possibly empty.
    ///
    /// The nil-vs-empty distinction is the point: only "looked and found nothing"
    /// earns the scope-aware empty state. Same contract as the Android app's
    /// `probeFocusAreaForPoi`.
    ///
    /// `area` clamps the hits exactly as the direct path is clamped — a
    /// precision-4 tile is ~39×19.5 km, so without it this "current area" probe
    /// would happily return something 30 km off the side of the screen.
    private func probeFocusArea(
        _ q: String, limit: Int, focusLat: Double, focusLng: Double,
        area: SearchArea?, onProgress: ((Phase?) -> Void)?
    ) async -> [GeocodingResult]? {
        onProgress?(.loadingTiles(.nearbyArea))
        let geocoder = self.geocoder
        let loaded = await offMain {
            (try? geocoder.ensureTileForCoordsLoaded(lat: focusLat, lng: focusLng)) ?? false
        }
        onProgress?(nil)
        guard loaded else { return nil }
        // Same peeling as `cityWideSearch`: the city half is a hint, not something
        // to match against street text.
        let head = q.prefix { !Self.isComma($0) }.trimmingCharacters(in: .whitespaces)
        let local = head.isEmpty ? q : head
        let near = await forward(local, limit: limit * 3, focusLat: focusLat, focusLng: focusLng)
        let onScreen = area.map { box in
            near.filter { box.contains(lat: $0.lat, lng: $0.lng) }
        } ?? near
        return Array(
            CityRanking.rankPlaces(onScreen, focusLat: focusLat, focusLng: focusLng, query: local)
                .prefix(limit)
        )
    }

    /// Radius around the map centre treated as "the current area". A precision-4
    /// geocoding tile is ~39×19.5 km, so this comfortably covers the tile/city the
    /// user is looking at while still excluding hits from a genuinely different
    /// cached region. Same value as the Android app's `IN_AREA_RADIUS_KM`.
    private static let inAreaRadiusKm = 40.0

    /// "In this area", but only if the best row is actually in it. Used by the
    /// direct path when the rows were NOT viewport-clamped — server rows skip the
    /// clamp deliberately, and labelling those by `area != nil` alone would put a
    /// store hundreds of miles away under an "In this area" heading.
    private static func currentAreaScope(
        _ rows: [GeocodingResult], focusLat: Double?, focusLng: Double?
    ) -> Scope? {
        guard let lat = focusLat, let lng = focusLng, let nearest = rows.first else { return nil }
        return haversineKm((nearest.lat, nearest.lng), (lat, lng)) <= inAreaRadiusKm
            ? .nearbyArea
            : nil
    }

    /// Is the current network safe for a large opportunistic download?
    ///
    /// GATE ON THIS, NOT ON NOTHING. The probe above pulls the whole cell under
    /// the map centre, which is tens of MB in a dense metro, and the user did not
    /// ask for a specific city — they typed a word. The Android app gates exactly
    /// this one download on the same check (it passes `isActiveNetworkMetered` as
    /// `allowMeteredTileLoad`), while a city the user TYPED still downloads on
    /// any network. This mirrors that split.
    ///
    /// Fails closed: an unknown path means no probe. Through `isUnmetered`.
    nonisolated static func unmeteredNetwork() async -> Bool {
        /// The handler can fire more than once; a continuation may be resumed
        /// exactly once. `NWPathMonitor` serialises handler calls onto the queue
        /// below, so this plain flag is only ever touched from one thread.
        final class Once: @unchecked Sendable {
            var fired = false
        }
        let decided: Bool? = await race(.seconds(2)) {
            await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                let monitor = NWPathMonitor()
                let once = Once()
                monitor.pathUpdateHandler = { path in
                    guard !once.fired else { return }
                    once.fired = true
                    monitor.cancel()
                    cont.resume(
                        returning: path.status == .satisfied
                            && !path.isExpensive
                            && !path.isConstrained
                    )
                }
                monitor.start(queue: DispatchQueue(label: "com.pingolin.track.pathprobe"))
            }
        }
        return decided ?? false
    }

    // MARK: - Server path

    /// Shortest query that may leave the device. Below this the local tiles still
    /// answer, so short input is not dead — just free. Two characters would spend
    /// a credit and a round trip on "in", and the debounce does not help a slow
    /// typist who pauses after "i" and again after "in". Same value as the
    /// Android app's `MIN_SERVER_QUERY_LEN`.
    static let minServerQueryLength = 3

    /// UserDefaults key behind Settings → Geocoding. Read directly rather than
    /// through `@AppStorage` because this type is deliberately UI-free.
    static let useServerGeocoderKey = "geocoding.useServerSide"

    /// The rows of a server answer in the order the list shows them, cut to
    /// `limit`.
    ///
    /// When the gateway ordered them itself (`ServedPlaces.ordered`) that order
    /// is final and this does nothing but cut: the gateway knows what a row
    /// cannot say — that "Tour Eiffel" answers "eiffel tower" through its
    /// English name, that it is a landmark, that a row was only reached by
    /// allowing a typo.
    ///
    /// Without the mark the rows are in Pelias's own order, and
    /// `CityRanking.rankPlaces` applies.
    ///
    /// `nonisolated`: it touches no state, and the tests call it off the actor.
    nonisolated static func arrange(
        _ served: ServerGeocoder.ServedPlaces, limit: Int,
        focusLat: Double?, focusLng: Double?, query: String
    ) -> [GeocodingResult] {
        let rows = served.ordered
            ? served.rows
            : CityRanking.rankPlaces(served.rows, focusLat: focusLat, focusLng: focusLng,
                                     query: query)
        return Array(rows.prefix(limit))
    }

    /// Ask the gateway, or `nil` to mean "did not / could not ask" — which is the
    /// caller's signal to use tiles. An EMPTY array is a real answer and is
    /// returned as such. Internal for tests; `search` is the caller.
    ///
    /// ONE REQUEST PER QUERY. A query the gateway answered within
    /// `serverCacheTTL` is answered from the cache, and one it is answering now
    /// is waited for, not asked again. The ask runs in a task of its own, so a
    /// search a newer keystroke cancels does not cut off the answer it paid
    /// for: the answer is cached for the next search that asks.
    func serverForward(
        _ q: String, limit: Int, focusLat: Double?, focusLng: Double?
    ) async -> ServerGeocoder.ServedPlaces? {
        let text = q.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard serverAllowed(), text.count >= Self.minServerQueryLength else { return nil }
        let key = Self.searchCacheKey(query: text, limit: limit,
                                      focusLat: focusLat, focusLng: focusLng)
        if let hit = cachedServerRows(key) { return hit }
        if let asking = serverAsks[key] { return await asking.value }
        let ask = askServer
        let asking = Task { () -> ServerGeocoder.ServedPlaces? in
            let served = await ask(text, limit, focusLat, focusLng)
            // Only a real ANSWER is cached. `nil` means the gateway could not answer
            // (no credit, HTTP error, unreachable) and must stay retryable; an empty
            // array is authoritative and worth remembering.
            if let served { self.store(served, for: key) }
            self.serverAsks[key] = nil
            return served
        }
        serverAsks[key] = asking
        return await asking.value
    }

    /// The gateway asks in flight, by `searchCacheKey`.
    private var serverAsks: [String: Task<ServerGeocoder.ServedPlaces?, Never>] = [:]

    // MARK: - Server response cache

    /// How long a server answer stays good. Same window as the Android
    /// app's `SEARCH_CACHE_TTL_MS`.
    static let serverCacheTTL: TimeInterval = 5 * 60

    /// WHY CACHE AT ALL: every server search spends one anonymous VOPRF credit,
    /// and the pool is finite. Asking the gateway again for a query it has just
    /// answered burns a credit per repeat and — because the gateway's
    /// autocomplete does not return a byte-identical set every time — would make
    /// two runs of the SAME query answerable differently. The Android app
    /// memoises the same way.
    private struct CachedRows {
        /// The answer as it arrived, with the gateway's word on its order: a
        /// cached answer is arranged exactly like a fresh one.
        let served: ServerGeocoder.ServedPlaces
        let at: Date
    }
    private var serverCache: [String: CachedRows] = [:]
    /// Bound, so a long typing session cannot grow this without limit. Android
    /// uses an access-ordered LinkedHashMap for the same reason.
    private static let serverCacheMax = 16

    /// `query|limit|lat|lng`, the query `normalised`, coordinates at 3 decimals.
    ///
    /// ~100 m: fine enough that a real pan misses the cache, coarse enough that
    /// the camera drifting a few metres does not. Identical to Android's
    /// `searchCacheKey`.
    static func searchCacheKey(
        query: String, limit: Int, focusLat: Double?, focusLng: Double?
    ) -> String {
        func coord(_ d: Double?) -> String { d.map { String(format: "%.3f", $0) } ?? "-" }
        return "\(normalised(query))|\(limit)|\(coord(focusLat))|\(coord(focusLng))"
    }

    /// One spelling per query: lower case, single spaces, nothing at either end.
    /// "Pinks  Hot Dogs " and "pinks hot dogs" are one question, with one answer
    /// and one credit.
    nonisolated static func normalised(_ query: String) -> String {
        query.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private func cachedServerRows(_ key: String) -> ServerGeocoder.ServedPlaces? {
        guard let hit = serverCache[key] else { return nil }
        guard Date().timeIntervalSince(hit.at) <= Self.serverCacheTTL else {
            serverCache.removeValue(forKey: key)
            return nil
        }
        return hit.served
    }

    private func store(_ served: ServerGeocoder.ServedPlaces, for key: String) {
        if serverCache.count >= Self.serverCacheMax,
           let oldest = serverCache.min(by: { $0.value.at < $1.value.at })?.key {
            serverCache.removeValue(forKey: oldest)
        }
        serverCache[key] = CachedRows(served: served, at: Date())
    }

    // MARK: - Expand to whole city

    /// Resolve the city at `(focusLat, focusLng)` and load its entire tile set, then
    /// search across them. Matches the Android app's `cityWideSearch`.
    ///
    /// Precise path = reverse-geocode the centre → city name → cities-tier `tileIds`
    /// (the cells the city occupies). Fallback when no city resolves (rural /
    /// unincorporated) = the focus cell + 8 neighbours, which over-covers any
    /// locality.
    ///
    /// EVERY SDK CALL HERE GOES THROUGH `offMain`, AND EVERY DOWNLOAD THROUGH
    /// `withTimeout`. The reverse lookup, the city index, and a loop over the
    /// city's WHOLE tile set are each synchronous and each fetch what is missing:
    /// called directly, a search in a city whose tiles are not on the phone would
    /// hold the main thread until the last tile arrived. Nothing could draw
    /// meanwhile, this search's own progress row included, and a stalled fetch
    /// would hold it for minutes. `offMain` explains why.
    ///
    /// IT MAY NOT ALWAYS DOWNLOAD. The sheet runs this by itself after the
    /// map-view search, and then the city's tiles are a download nobody asked
    /// for: tens of MB a cell in a dense metro. With `.ifUnmetered` they wait for
    /// an unmetered network. On a metered one the search covers the city's tiles
    /// already on the phone, fetches nothing (not the city index either), and says
    /// what it left in `moreToDownload`, which the sheet offers on a tap.
    private func cityWideSearch(
        _ q: String,
        limit: Int,
        focusLat: Double,
        focusLng: Double,
        downloads: Downloads,
        onProgress: ((Phase?) -> Void)?
    ) async -> Result {
        var scope: Scope?
        /// The city's own cells (`inCells`), used to keep results inside the city.
        var scopeTiles: Set<String>?
        /// Where a miss widens to: the eight tiles beside the town's own.
        var widening: Widening?
        let geocoder = self.geocoder
        let cityIndex = self.cityIndex

        var unmetered = true
        if downloads == .ifUnmetered { unmetered = await isUnmetered() }
        let mayDownload = Self.mayDownload(downloads, unmetered: unmetered)
        var onDisk = Set<String>()
        var moreToDownload = false
        if !mayDownload {
            let storagePath = self.storagePath
            onDisk = await offMain { Self.tilesOnDisk(in: storagePath) }
            // The reverse lookup below fetches the cell under the map when it is not
            // on the phone, and without it there is no city to search.
            guard Self.cellOnDisk(Self.geohash4(lat: focusLat, lng: focusLng), in: onDisk) else {
                return Result(addresses: [], cities: [], scopedTo: nil, moreToDownload: true)
            }
        }

        // nil = the budget ran out; .some(nil) = the lookup answered with no city.
        let reversed = await withTimeout {
            await self.offMain { geocoder.reverse(lat: focusLat, lng: focusLng)?.city }
        }
        // A search a newer query replaced stops at each step: nobody is reading it.
        if Task.isCancelled { return .empty }
        guard let reversedCity = reversed else {
            onProgress?(nil)
            return Result(addresses: [], cities: [], scopedTo: nil, timedOut: true)
        }

        if let cityName = reversedCity?.trimmingCharacters(in: .whitespaces), !cityName.isEmpty {
            if mayDownload { await ensureCityTiers(for: cityName, onProgress: onProgress) }
            let top = await offMain { cityIndex.search(query: cityName, limit: 3).first }
            if Task.isCancelled { return .empty }
            if let top {
                let resolved = Scope(city: top.name, admin1: top.admin1,
                                     countryCode: top.countryCode)
                let tileIds = top.tileIds
                // The town's own tile is the city's too, the scoped path's
                // rule: the index's tileIds leave out a SPLIT cell, so the
                // whole of Cupertino would lack its own 9q9h, and a town
                // with no index tiles is scoped by its own tile alone
                // (`cityCells`). The eight beside it come below, on a miss.
                let town = (lat: top.lat, lng: top.lng, storedTileId: top.tileId)
                if mayDownload {
                    onProgress?(.loadingTiles(resolved))
                    let loaded = await withTimeout {
                        await self.offMain { Self.loadEveryTile(tileIds, town: town, geocoder: geocoder) }
                    }
                    if Task.isCancelled { return .empty }
                    guard let townTile = loaded else {
                        onProgress?(nil)
                        return Result(addresses: [], cities: [], scopedTo: resolved, timedOut: true)
                    }
                    if let cells = Self.cityCells(tileIds: tileIds, townTile: townTile) {
                        scope = resolved
                        scopeTiles = cells
                        widening = townTile.map { Widening(tile: $0, lat: town.lat, lng: town.lng) }
                    }
                } else {
                    let onPhone = Self.townTilesOnPhone(lat: town.lat, lng: town.lng,
                                                        storedTileId: town.storedTileId, onDisk: onDisk)
                    if let cells = Self.cityCells(tileIds: tileIds, townTile: onPhone.tile) {
                        scope = resolved
                        scopeTiles = cells
                        widening = onPhone.tile.map {
                            Widening(tile: $0, lat: town.lat, lng: town.lng, onPhone: onPhone.beside)
                        }
                    }
                    moreToDownload = !Self.missingCells(tileIds, onDisk: onDisk).isEmpty || onPhone.missing
                }
            }
        }

        if scope == nil {
            // No city: the cell under the focus and its eight neighbours, with no
            // cell list to keep the results inside. On a metered network they are
            // the tap's to fetch.
            guard mayDownload else {
                return Result(addresses: [], cities: [], scopedTo: nil, moreToDownload: true)
            }
            let nearby = Scope.nearbyArea
            scope = nearby
            onProgress?(.loadingTiles(nearby))
            let loaded = await withTimeout {
                await self.offMain { Self.loadCellAndNeighbours(focusLat, focusLng, geocoder: geocoder) }
            }
            if Task.isCancelled { return .empty }
            if loaded == nil {
                onProgress?(nil)
                return Result(addresses: [], cities: [], scopedTo: nearby, timedOut: true)
            }
        }

        // Drop a (possibly mistyped) trailing city hint for the local search. Exactly
        // Kotlin's `q.substringBefore(",").trim().ifBlank { q }` — note `prefix(while:)`
        // rather than `split`, which omits empty subsequences and would silently take
        // the text AFTER the comma for a query starting with one. An IME's comma is
        // one too (`isComma`).
        let head = q.prefix { !Self.isComma($0) }.trimmingCharacters(in: .whitespaces)
        let local = head.isEmpty ? q : head
        var hits = await forward(local, limit: Self.townRows, focusLat: focusLat, focusLng: focusLng)

        // `forward` is global over EVERY loaded tile, so a "whole city" search would
        // otherwise surface same-name hits from unrelated regions that happen to be
        // loaded for other map markers (e.g. circle members in another state) under
        // this city's header. Restrict to the city's own cells: a hit is in-city iff
        // one of them (the city's tileIds and the town's own tile) is a prefix of its
        // geohash (`inCells`).
        // Empty is then a truthful "nothing in this city" rather than cross-region
        // noise. The rural neighbour fallback has no tile set, so it keeps proximity
        // ranking unfiltered.
        var inScope = scopeTiles.map { tiles in
            hits.filter { Self.inCells(tiles, lat: $0.lat, lng: $0.lng) }
        } ?? hits
        // A miss in the town's own tile and the index's: the eight beside it, as the
        // scoped path widens. On a metered network, the ones on the phone, so
        // nothing is fetched and the rows are already here.
        if inScope.isEmpty, let tiles = scopeTiles, let widening {
            var around = widening.onPhone ?? []
            if widening.onPhone == nil {
                let widened = await withTimeout {
                    await self.offMain { Self.loadNeighbours(of: widening, geocoder: geocoder) }
                }
                if Task.isCancelled { return .empty }
                guard let loaded = widened else {
                    onProgress?(nil)
                    return Result(addresses: [], cities: [], scopedTo: scope, timedOut: true)
                }
                around = loaded
                if !around.isEmpty {
                    hits = await forward(local, limit: Self.townRows, focusLat: focusLat, focusLng: focusLng)
                }
            }
            let wider = tiles.union(around)
            inScope = hits.filter { Self.inCells(wider, lat: $0.lat, lng: $0.lng) }
        }

        onProgress?(nil)
        let ranked = CityRanking.rankPlaces(inScope, focusLat: focusLat, focusLng: focusLng,
                                            query: local)
        // No `cities` — same reason as the fallback path: tapping the city would
        // drop a pin on its centroid rather than the address the user typed.
        return Result(addresses: Array(ranked.prefix(limit)), cities: [], scopedTo: scope,
                      moreToDownload: moreToDownload)
    }

    /// The rows that lead the list (the same rule on every platform): every row
    /// whose whole name is what was typed, places in their order, then towns in
    /// their rank, ahead of everything that only starts with it. So "Hamburg"
    /// searched over San Francisco lists every Hamburg (DE, NY, PA…) first, not
    /// the places that merely START with it on the phone's tiles ("Hamburger
    /// Mary's"), and a café named "Berlin" leads Berlin, DE, which both lead the
    /// "Berliner…" places. Whole tokens, any case or spacing; a town's ASCII name
    /// counts as its name. The rest keeps its order.
    nonisolated static func split(
        addresses: [GeocodingResult], cities: [CityResult], query: String
    ) -> (leadingPlaces: [GeocodingResult], places: [GeocodingResult],
          leadingCities: [CityResult], cities: [CityResult]) {
        let tokens = CityRanking.normalizeTokens(query)
        func exactPlace(_ row: GeocodingResult) -> Bool {
            CityRanking.isExactName(tokens, row.name ?? row.text)
        }
        func exactCity(_ city: CityResult) -> Bool {
            CityRanking.isExactName(tokens, city.name) || CityRanking.isExactName(tokens, city.asciiName)
        }
        return (addresses.filter(exactPlace), addresses.filter { !exactPlace($0) },
                cities.filter(exactCity), cities.filter { !exactCity($0) })
    }

    /// An unrequested download waits for an unmetered network; a requested one
    /// (a tap, a typed city) does not.
    nonisolated static func mayDownload(_ downloads: Downloads, unmetered: Bool) -> Bool {
        downloads == .always || unmetered
    }

    /// The tile ids on disk under `storagePath`: `tile_<id>.sqlite`, the SDK's own
    /// layout (`TileGeocoder::cached_tile_count` counts the same files).
    nonisolated static func tilesOnDisk(in storagePath: String) -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: storagePath)) ?? []
        return Set(names.compactMap { name -> String? in
            guard name.hasPrefix("tile_"), name.hasSuffix(".sqlite") else { return nil }
            return String(name.dropFirst("tile_".count).dropLast(".sqlite".count))
        })
    }

    /// Cell `id` is on the phone: its own tile, or a tile it was split into. The
    /// manifest cuts a dense metro's cells to precision 5 (`tile_<id><c>.sqlite`).
    nonisolated static func cellOnDisk(_ id: String, in onDisk: Set<String>) -> Bool {
        onDisk.contains(id) || onDisk.contains { $0.count == id.count + 1 && $0.hasPrefix(id) }
    }

    /// The cells of `ids` with nothing on the phone.
    nonisolated static func missingCells(_ ids: [String], onDisk: Set<String>) -> [String] {
        ids.filter { !cellOnDisk($0, in: onDisk) }
    }

    /// Does the whole-city search follow `first` by itself? Not after the
    /// gateway's rows (a planet-wide answer), a city the query named (the user
    /// chose where to look), or a download that timed out; and not without a map
    /// to search around.
    nonisolated static func widens(after first: Result, hasFocus: Bool) -> Bool {
        hasFocus && !first.fromServer && !first.timedOut
            && (first.scopedTo == nil || first.scopedTo == .nearbyArea)
    }

    /// The map-view answer and the whole-city one as one list: every row once,
    /// ranked again around the focus, the first search's cities kept. The city
    /// heads the list only when the wider search added rows (or timed out, so
    /// the sheet can say which city it could not fetch).
    nonisolated static func widened(
        _ first: Result, by wide: Result, limit: Int,
        focusLat: Double, focusLng: Double, query: String
    ) -> Result {
        func key(_ row: GeocodingResult) -> String {
            "\(row.text)|\(Int((row.lat * 100_000).rounded()))|\(Int((row.lng * 100_000).rounded()))"
        }
        var seen = Set<String>()
        let rows = (first.addresses + wide.addresses).filter { seen.insert(key($0)).inserted }
        let added = rows.count > first.addresses.count
        var out = first
        if added {
            out.addresses = Array(CityRanking.rankPlaces(rows, focusLat: focusLat, focusLng: focusLng,
                                                         query: query).prefix(limit))
        }
        if added || wide.timedOut { out.scopedTo = wide.scopedTo ?? first.scopedTo }
        out.timedOut = first.timedOut || wide.timedOut
        out.moreToDownload = wide.moreToDownload
        return out
    }

    /// The whole tile set of a city, with the town's own tile first
    /// (`cityTiles`); returns the town's tile, if it loaded. Blocking: only ever
    /// called through `offMain`.
    private nonisolated static func loadEveryTile(
        _ tileIds: [String], town: (lat: Double, lng: Double, storedTileId: String), geocoder: TileGeocoder
    ) -> String? {
        cityTiles(tileIds, storedTileId: town.storedTileId, lat: town.lat, lng: town.lng,
                  load: { Self.loadTile($0, geocoder: geocoder) })
    }

    /// The eight tiles beside a town's own tile (`loadNeighbourTiles`), the
    /// window starting now. Blocking, like `loadEveryTile`.
    private nonisolated static func loadNeighbours(of widening: Widening, geocoder: TileGeocoder) -> Set<String> {
        loadNeighbourTiles(of: widening.tile, nearLat: widening.lat, nearLng: widening.lng,
                           load: { Self.loadTile($0, geocoder: geocoder) }, started: Date())
    }

    /// The cell under the focus and its eight neighbours. Blocking, like `loadEveryTile`.
    private nonisolated static func loadCellAndNeighbours(
        _ lat: Double, _ lng: Double, geocoder: TileGeocoder
    ) -> Bool {
        _ = try? geocoder.ensureTileAndNeighborsLoaded(lat: lat, lng: lng)
        return true
    }

    private static let geohashBase32 = Array("0123456789bcdefghjkmnpqrstuvwxyz")

    /// Encode `(lat, lng)` to a precision-4 geohash — the on-device tile
    /// granularity. Used to test whether a result falls inside a scope's tile set.
    ///
    /// `nonisolated`: pure arithmetic, and the view layer calls it off the actor.
    nonisolated static func geohash4(lat: Double, lng: Double) -> String {
        geohash(lat: lat, lng: lng, precision: 4)
    }

    /// Encode `(lat, lng)` to a geohash of `precision` characters. The manifest
    /// holds tiles at 3, 4 and 5 (`manifestTile`).
    nonisolated static func geohash(lat: Double, lng: Double, precision: Int) -> String {
        var latMin = -90.0, latMax = 90.0
        var lngMin = -180.0, lngMax = 180.0
        var out = ""
        var even = true
        var bit = 0
        var ch = 0
        while out.count < precision {
            if even {
                let mid = (lngMin + lngMax) / 2
                if lng >= mid { ch |= 1 << (4 - bit); lngMin = mid } else { lngMax = mid }
            } else {
                let mid = (latMin + latMax) / 2
                if lat >= mid { ch |= 1 << (4 - bit); latMin = mid } else { latMax = mid }
            }
            even.toggle()
            if bit < 4 {
                bit += 1
            } else {
                out.append(Self.geohashBase32[ch])
                bit = 0
                ch = 0
            }
        }
        return out
    }

    /// The cell a geohash names: its centre and its size in degrees. Nil for a
    /// character outside the alphabet.
    nonisolated static func geohashBox(_ hash: String)
        -> (centreLat: Double, centreLng: Double, height: Double, width: Double)? {
        var latMin = -90.0, latMax = 90.0
        var lngMin = -180.0, lngMax = 180.0
        var even = true
        for character in hash {
            guard let value = Self.geohashBase32.firstIndex(of: character) else { return nil }
            for bit in stride(from: 4, through: 0, by: -1) {
                let set = (value >> bit) & 1 == 1
                if even {
                    let mid = (lngMin + lngMax) / 2
                    if set { lngMin = mid } else { lngMax = mid }
                } else {
                    let mid = (latMin + latMax) / 2
                    if set { latMin = mid } else { latMax = mid }
                }
                even.toggle()
            }
        }
        return ((latMin + latMax) / 2, (lngMin + lngMax) / 2, latMax - latMin, lngMax - lngMin)
    }

    // MARK: - A town's own cells

    /// The manifest's tile at `(lat, lng)`, in the SDK's `resolve_tile_id` order:
    /// the base precision 4, else the precision-5 child a dense cell was split
    /// into, else the precision-3 parent a sparse region was merged into. `has`
    /// answers for one id; in the app it loads the tile, and an id the manifest
    /// doesn't have is a soft miss (`ensureTileLoadedById`).
    nonisolated static func manifestTile(lat: Double, lng: Double, has: (String) -> Bool) -> String? {
        for precision in [4, 5, 3] {
            let id = geohash(lat: lat, lng: lng, precision: precision)
            if has(id) { return id }
        }
        return nil
    }

    /// The town's own tile: the manifest's at the town's point, so a split or a
    /// rebuild since the cities index was made is followed, else the index's
    /// stored `tileId`.
    nonisolated static func townTile(lat: Double, lng: Double, storedTileId: String,
                                     has: (String) -> Bool) -> String? {
        manifestTile(lat: lat, lng: lng, has: has) ?? (storedTileId.isEmpty ? nil : storedTileId)
    }

    /// The eight cells beside `tile`, at its own precision, each resolved through
    /// the manifest from its centre: a neighbour split into children gives the
    /// child covering that centre, and one merged into its parent gives the
    /// parent. Nearest `(nearLat, nearLng)`
    /// first, by their centres, so `has` is asked for the likeliest first; each
    /// once, never `tile` itself.
    nonisolated static func neighbourTiles(of tile: String, nearLat: Double, nearLng: Double,
                                           has: (String) -> Bool) -> [String] {
        guard let box = geohashBox(tile) else { return [] }
        var centres: [(lat: Double, lng: Double)] = []
        for dLat in [-1.0, 0, 1] {
            for dLng in [-1.0, 0, 1] where dLat != 0 || dLng != 0 {
                let lat = box.centreLat + dLat * box.height
                guard lat > -90, lat < 90 else { continue }
                var lng = box.centreLng + dLng * box.width
                if lng > 180 { lng -= 360 } else if lng < -180 { lng += 360 }
                centres.append((lat, lng))
            }
        }
        let nearestFirst = centres.enumerated().sorted { a, b in
            let da = haversineKm((nearLat, nearLng), (a.element.lat, a.element.lng))
            let db = haversineKm((nearLat, nearLng), (b.element.lat, b.element.lng))
            return da != db ? da < db : a.offset < b.offset
        }
        var out: [String] = []
        for centre in nearestFirst.map(\.element) {
            if let id = manifestTile(lat: centre.lat, lng: centre.lng, has: has), id != tile, !out.contains(id) {
                out.append(id)
            }
        }
        return out
    }

    /// Whether a row lies in one of `cells`, tile ids of 3, 4 or 5 characters:
    /// one of them is a prefix of the row's own precision-5 geohash. Equality with
    /// its precision-4 geohash never matched a split cell's precision-5 tile.
    nonisolated static func inCells(_ cells: Set<String>, lat: Double, lng: Double) -> Bool {
        let own = geohash(lat: lat, lng: lng, precision: 5)
        return cells.contains { !$0.isEmpty && own.hasPrefix($0) }
    }

    /// How long a miss may spend starting the eight tiles beside the town's own
    /// (`loadNeighbourTiles`): 10 s of the widening step's 20 s
    /// `downloadTimeout`, as in the Android app. A deliberate difference from
    /// the web client, which bounds the same eight by bytes (16 MB): the SDK
    /// tells the phone no tile's size before it is fetched. One started in the
    /// window runs to its end.
    nonisolated static let neighbourWindow: TimeInterval = 10

    /// Where a city's search widens on a miss: the eight tiles beside the
    /// town's own `tile`, nearest its point first. `onPhone`, on a metered
    /// network: the ones already on the phone, so nothing is fetched.
    struct Widening: Sendable {
        let tile: String
        let lat: Double
        let lng: Double
        var onPhone: Set<String>? = nil
    }

    /// The rows a town's search asks `forward` for, after a comma or for the
    /// whole city (counterparts: the web client's AREA_ROWS, the Android app's
    /// TOWN_ROWS). The SDK
    /// keeps the most confident rows over every loaded tile, in a HashMap's
    /// tile order, before the town's filter runs here, so a small multiple of
    /// `limit` (such as `limit * 3`, 24) would let a chain's stores in other
    /// loaded tiles cut the town's own match. The sheet still shows `limit`.
    nonisolated static let townRows = 100

    /// A whole city's cells: the index's tileIds and the town's own tile. Nil
    /// when there are none, so the search falls back to the area under the map;
    /// a town with no index tiles is scoped by its own tile.
    nonisolated static func cityCells(tileIds: [String], townTile: String?) -> Set<String>? {
        let cells = Set(tileIds + [townTile].compactMap { $0 })
        return cells.isEmpty ? nil : cells
    }

    /// Loads one tile by id, blocking: false for an id the manifest doesn't have
    /// (a soft miss) or a load that failed.
    nonisolated static func loadTile(_ id: String, geocoder: TileGeocoder) -> Bool {
        (try? geocoder.ensureTileLoadedById(tileId: id)) == true
    }

    /// The town's own tile, loaded: the manifest's at the town's point, else the
    /// index's stored id when that loads, never asked for twice. Nil when neither
    /// loads.
    nonisolated static func loadTownTile(lat: Double, lng: Double, storedTileId: String,
                                         load: (String) -> Bool) -> String? {
        var tried = Set<String>()
        if let tile = manifestTile(lat: lat, lng: lng, has: { tried.insert($0); return load($0) }) {
            return tile
        }
        guard !storedTileId.isEmpty, !tried.contains(storedTileId), load(storedTileId) else { return nil }
        return storedTileId
    }

    /// The eight tiles beside the town's own `tile`, loaded: nearest the town's
    /// point first (`neighbourTiles`), each started only while `neighbourWindow`
    /// lasts from `started`. The ids that loaded.
    nonisolated static func loadNeighbourTiles(of tile: String, nearLat: Double, nearLng: Double,
                                               load: (String) -> Bool, started: Date,
                                               now: () -> Date = { Date() }) -> Set<String> {
        Set(neighbourTiles(of: tile, nearLat: nearLat, nearLng: nearLng) { id in
            now().timeIntervalSince(started) < neighbourWindow && load(id)
        })
    }

    /// What a city-scoped search keeps its rows to, loading as it goes: the
    /// town's own tile; then the shard's tiles for the term, with the index's
    /// tileIds, else the index's tileIds, when any of them loads. `town`: the
    /// town's tile, if it loaded, for a miss to widen around. Never the tiles
    /// beside it: a hit doesn't pay for them. Nil when nothing loaded, so the
    /// caller falls back to the centroid's cells and never takes "nothing
    /// loaded" for "not in this town". `shardTiles` is nil for a city without a
    /// shard; `load` loads one tile, blocking.
    nonisolated static func scopedCells(
        shardTiles: (() -> [String])?, tileIds: [String], storedTileId: String,
        lat: Double, lng: Double, load: (String) -> Bool
    ) -> (cells: Set<String>, town: String?)? {
        let town = loadTownTile(lat: lat, lng: lng, storedTileId: storedTileId, load: load)
        var indexed: Set<String>?
        if let shardTiles {
            let loaded = Set(shardTiles().filter(load))
            if !loaded.isEmpty {
                // Union with tileIds: the shard is per-city, so its tiles are
                // in-city by construction even when the pipeline's tileIds
                // list does not happen to contain them. Filtering against
                // tileIds alone would throw away the very rows we just fetched.
                indexed = loaded.union(tileIds)
            }
        }
        if indexed == nil, !tileIds.isEmpty, !tileIds.filter(load).isEmpty {
            indexed = Set(tileIds)
        }
        guard town != nil || indexed != nil else { return nil }
        return ((indexed ?? []).union([town].compactMap { $0 }), town)
    }

    /// A whole city's tiles: the town's own tile first, then every tile of the
    /// index's set. Returns the town's tile, if it loaded; `load` loads one tile,
    /// blocking.
    nonisolated static func cityTiles(_ tileIds: [String], storedTileId: String, lat: Double, lng: Double,
                                      load: (String) -> Bool) -> String? {
        let town = loadTownTile(lat: lat, lng: lng, storedTileId: storedTileId, load: load)
        for tileId in tileIds { _ = load(tileId) }
        return town
    }

    /// The town's own tile and the eight beside it as far as the phone has them,
    /// for a whole-city search on a metered network: nothing is fetched there,
    /// so nothing is loaded either, since a load fetches a stale copy or a
    /// missing POI tile. The tiles on disk stand in for the manifest.
    /// `tile`: the town's, on the phone or not (`townTile`); `missing`: it isn't
    /// on the phone, a tap's to fetch.
    nonisolated static func townTilesOnPhone(lat: Double, lng: Double, storedTileId: String,
                                             onDisk: Set<String>) -> (tile: String?, beside: Set<String>, missing: Bool) {
        let onPhone: (String) -> Bool = { onDisk.contains($0) }
        guard let tile = townTile(lat: lat, lng: lng, storedTileId: storedTileId, has: onPhone) else {
            return (nil, [], false)
        }
        return (tile, Set(neighbourTiles(of: tile, nearLat: lat, nearLng: lng, has: onPhone)),
                !cellOnDisk(tile, in: onDisk))
    }

    // MARK: - Candidate building

    /// One attempt at "resolve this city, download its tiles, search the rest".
    struct Candidate: Equatable {
        let hint: String
        let address: String
        /// This hint is a POSITIONAL GUESS, not something the user marked as a
        /// place. See `buildCandidates` — it is the second-to-last token of a
        /// whitespace query, taken on the theory that the shape is
        /// "<street> <city> <state>". When that theory is wrong the token is just
        /// a word from the middle of the query, and resolving it anyway could
        /// head "pinks hot dogs" with "In Hohhot, 20".
        ///
        /// Weak candidates must clear a higher bar before they are accepted —
        /// see `cityCorroborates`.
        let isPositionalGuess: Bool
    }

    /// The comma between a place and its town: ",", or what a Japanese or Chinese
    /// IME types there, "、" (U+3001), "，" (U+FF0C), or the halfwidth "､" (U+FF64).
    /// "東京タワー、東京" is "Tokyo Tower, Tokyo". Nothing else: "。" and a
    /// full-width space stay what they are.
    nonisolated static func isComma(_ c: Character) -> Bool {
        c == "," || c == "、" || c == "，" || c == "､"
    }

    /// Build the candidates the fallback tries, in order.
    ///
    /// Mirrors `buildSmartCandidates` in the Android app's SmartSearch.kt — kept
    /// deliberately identical so the platforms answer the same query the same
    /// way. Pure string handling, hence `static` and unit-testable without an SDK.
    ///
    /// Comma form is most-specific first ("hickman ca 95323") then the bare city, so
    /// a query that misses on a state-coded hint can still resolve. Trailing
    /// postcodes are stripped for a second attempt because a postcode matches NO
    /// cities-tier column — name, ascii_name, alt_names, admin1, country_code — so
    /// the full hint can never satisfy it, and without the stripped variant the bare
    /// "<city>" step loses on population sort (plain "Hickman" picks KY over CA).
    static func buildCandidates(_ query: String) -> [Candidate] {
        var out: [Candidate] = []

        func push(_ hint: String, _ address: String, positionalGuess: Bool = false) {
            let h = hint.trimmingCharacters(in: .whitespaces)
            let a = address.trimmingCharacters(in: .whitespaces)
            guard !h.isEmpty, !a.isEmpty else { return }
            guard !out.contains(where: { $0.hint == h && $0.address == a }) else { return }
            out.append(Candidate(hint: h, address: a, isPositionalGuess: positionalGuess))
        }

        func stripTrailingPostcode(_ hint: String) -> String {
            var tokens = hint.split(whereSeparator: \.isWhitespace).map(String.init)
            while let last = tokens.last, isPostcodeShaped(last) {
                tokens.removeLast()
            }
            return tokens.joined(separator: " ")
        }

        if query.contains(where: isComma) {
            let parts = query.split(whereSeparator: isComma)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if parts.count >= 2 {
                let address = parts[0]
                if parts.count >= 3 {
                    let fullHint = parts.dropFirst().joined(separator: " ")
                    push(fullHint, address)
                    push(stripTrailingPostcode(fullHint), address)
                }
                push(parts[1], address)
            }
        } else {
            let tokens = query.split(whereSeparator: \.isWhitespace).map(String.init)
            if tokens.count >= 3 {
                let addr = tokens.dropLast(2).joined(separator: " ")
                let fullHint = tokens.suffix(2).joined(separator: " ")
                push(fullHint, addr)
                push(stripTrailingPostcode(fullHint), addr)
                // The only positional guess we make. Everything else is either
                // comma-delimited by the user or sits in the trailing
                // "<thing> <city>" position.
                push(tokens[tokens.count - 2], addr, positionalGuess: true)
            } else if tokens.count == 2 {
                push(tokens[1], tokens[0])
            }
        }
        return out
    }

    /// US ZIP / ZIP+4 and similar all-digit trailing tokens.
    static func isPostcodeShaped(_ token: String) -> Bool {
        let parts = token.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard let head = parts.first, head.count >= 3,
              head.allSatisfy(\.isNumber) else { return false }
        if parts.count == 2 {
            return !parts[1].isEmpty && parts[1].allSatisfy(\.isNumber)
        }
        return true
    }

    // MARK: - Pieces

    /// Run a blocking SDK call OFF the main actor.
    ///
    /// THIS IS LOAD-BEARING. `SmartSearch` is `@MainActor`, and the SDK entry
    /// points below are synchronous — they open SQLite files and, when a tier or
    /// tile is missing, DOWNLOAD it. Called directly, a multi-megabyte fetch
    /// would run on the main thread, so:
    ///
    ///   * the search would not return while it was in flight,
    ///   * the view would keep its previous (empty) state, and the empty-state
    ///     copy interpolates the LIVE query — so a stalled search would render
    ///     as "No matches for … on this part of the map", a confident lie, and
    ///   * no spinner could appear, because SwiftUI cannot draw on a blocked
    ///     main thread.
    ///
    /// `TileGeocoder` and `CityIndex` are `@unchecked Sendable` in the generated
    /// bindings, so they can be captured here; nothing else crosses.
    private nonisolated func offMain<T: Sendable>(
        _ work: @escaping @Sendable () -> T
    ) async -> T {
        await Task.detached(priority: .userInitiated) { work() }.value
    }

    /// Budget for one download-bearing step of the fallback.
    ///
    /// A stuck fetch must degrade to a truthful message rather than an indefinite
    /// spinner: a fetch that cannot reach the CDN can sit on
    /// `nw_read_request_report … Operation timed out` for minutes.
    static let downloadTimeout: Duration = .seconds(20)

    /// Race `work` against the clock. `nil` means the budget expired — the caller
    /// must NOT treat that as "found nothing".
    private nonisolated func withTimeout<T: Sendable>(
        _ budget: Duration = SmartSearch.downloadTimeout,
        _ work: @escaping @Sendable () async -> T
    ) async -> T? {
        await Self.race(budget, work)
    }

    /// The race behind `withTimeout`: the work's answer if it comes within
    /// `budget`, else nil. A cancelled caller gets nil at once.
    ///
    /// THE WORK IS NOT A CHILD TASK. A task group returns only after every
    /// child has ended, cancelled or not, and the work here is a blocking SDK
    /// download behind `offMain`, which no cancellation reaches: in a group the
    /// budget would change what the sheet says at the end, never how long it
    /// waits. Here whichever finishes first answers. A download that loses
    /// keeps going and still lands on disk for the next search.
    nonisolated static func race<T: Sendable>(
        _ budget: Duration,
        _ work: @escaping @Sendable () async -> T
    ) async -> T? {
        let first = FirstAnswer<T?>()
        let timer = Task {
            try? await Task.sleep(for: budget)
            first.answer(nil)
        }
        Task {
            let value = await work()
            timer.cancel()
            first.answer(value)
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { first.wait($0) }
        } onCancel: {
            timer.cancel()
            first.answer(nil)
        }
    }


    private func forward(
        _ query: String, limit: Int, focusLat: Double?, focusLng: Double?
    ) async -> [GeocodingResult] {
        // Off the main actor: this opens every cached tile from disk before it
        // searches, which is not free even when nothing is downloaded.
        let geocoder = self.geocoder
        return await offMain {
        // forwardNear orders each tile by distance from the focus point, so
        // the nearest rows arrive first instead of in whatever order the tile
        // happened to yield.
        // Neither call is throwing in the generated bindings, so no `try?` here —
        // an empty array IS the miss, and step 3 exists to handle it.
            if focusLat != nil, focusLng != nil {
                return geocoder.forwardNear(
                    query: query, limit: UInt32(limit), focusLat: focusLat, focusLng: focusLng
                )
            }
            return geocoder.forward(query: query, limit: UInt32(limit))
        }
    }

    /// The city rows the user is shown — over-fetched, then ranked.
    ///
    /// BOTH HALVES MATTER. `CityIndex::search` can only order by population, so
    /// asking it for exactly `limit` truncates on the one signal the ranker is
    /// about to overrule: the nearby, smaller, same-country city the user meant
    /// would be dropped before scoring ever runs. Without the ranking, "oakdale"
    /// from Modesto would lead with Oakdale, MN (1532 mi, 28k) in raw population
    /// order instead of Oakdale, CA (12 mi, 22k). `resolveCity` over-fetches and
    /// ranks the same way. Same shape as the Android app's
    /// `GeocodingRepository.searchCities`.
    private func searchCities(
        _ query: String, limit: Int, focusLat: Double?, focusLng: Double?
    ) async -> [CityResult] {
        await ensureCityTiers(for: query)
        let cityIndex = self.cityIndex
        let fetch = max(UInt32(limit * 5), Self.cityFetchCount)
        let rows = await offMain { cityIndex.search(query: query, limit: fetch) }
        return Array(
            CityRanking.rank(rows, focusLat: focusLat, focusLng: focusLng).prefix(limit)
        )
    }

    /// Resolve a hint to one city.
    ///
    /// NOT by population. The index can only order that way, and taking its top
    /// row could put **Ulanhot, Inner Mongolia** in front of a device sitting in
    /// California. `CityRanking` blends population with distance from the focus
    /// point and a home-country bonus, as the Android app does.
    ///
    /// `fetchCount` is deliberately larger than the number we need: re-ranking can
    /// only reorder what the index handed back, so asking for 5 and re-ranking 5
    /// still lets a population-heavy foreign row crowd out the local one before
    /// scoring ever runs. Android fetches `max(limit * 5, 25)` for the same reason.
    private func resolveCity(
        _ hint: String, focusLat: Double? = nil, focusLng: Double? = nil,
        onProgress: ((Phase?) -> Void)? = nil
    ) async -> CityResult? {
        await ensureCityTiers(for: hint, onProgress: onProgress)
        let cityIndex = self.cityIndex
        let ranked = { (rows: [CityResult]) in
            CityRanking.rank(rows, focusLat: focusLat, focusLng: focusLng).first
        }
        let fetch = Self.cityFetchCount
        if let hit = ranked(await offMain { cityIndex.search(query: hint, limit: fetch) }) {
            return hit
        }
        // Tier 1 is the ~7 MB "cities that matter" set. A miss there is not proof
        // the place does not exist — smaller towns live in tier 2 (~5 MB). Only pay
        // for it once tier 1 has actually failed, which is the same escalation
        // the Android app uses.
        guard !(await offMain { cityIndex.isTier2Loaded() }) else { return nil }
        let tier2URL = Self.tier2URL
        _ = await offMain { try? cityIndex.ensureTier2(url: tier2URL) }
        return ranked(await offMain { cityIndex.search(query: hint, limit: fetch) })
    }

    /// How many candidates to pull before re-ranking. Matches Android's
    /// `MIN_CITY_FETCH`.
    private static let cityFetchCount: UInt32 = 25

    /// Does `city` actually justify the hint that produced it?
    ///
    /// Only positional guesses are questioned. A hint the user comma-delimited
    /// ("350 5th ave, nyc") or one in the trailing "<thing> <city>" slot
    /// ("starbucks nyc") is taken at face value — those are real, common inputs
    /// that resolve through `alt_names` and would break under any stricter rule.
    ///
    /// THE BAR FOR A GUESS: the city's own name must BE the hint. Not start with
    /// it, not contain it.
    ///
    /// A prefix test is not enough: "pinks hot dogs" makes the guess "hot", and
    /// "hot" is a legitimate prefix of the real city **Hot Springs** — so
    /// corroborating against the index alone can never reject it. Nothing in the
    /// cities data can tell you "hot" is a hot dog rather than a town; the only
    /// usable signal is that a bare one-word city hint should NAME a city
    /// outright.
    ///
    /// Against the tier-1 index this rejects "hot" and "dogs" and keeps
    /// springfield, austin, modesto, delhi and ely, which is the whole point of
    /// the bare-hint rescue ("1 main st springfield illinois" — the full state
    /// NAME does not index, only the code does, so the bare step is the only
    /// thing that resolves it).
    static func cityCorroborates(_ city: CityResult, _ candidate: Candidate) -> Bool {
        guard candidate.isPositionalGuess else { return true }
        let hint = candidate.hint.trimmingCharacters(in: .whitespaces)
        return city.name.caseInsensitiveCompare(hint) == .orderedSame
            || city.asciiName.caseInsensitiveCompare(hint) == .orderedSame
    }

    /// Load the cities database lazily, cheapest tier first.
    ///
    /// The per-country file (~500 KB–2 MB) covers "user searches their own country",
    /// which is most searches, without the ~7 MB tier-1 download. But it must NOT be
    /// the only thing consulted for a city-shaped query: a US device searching
    /// "delhi" would match Delhi, CA and never reach Delhi, IN. So a 1–2 token query
    /// also pays for tier 1 and lets the candidates compete on population — the same
    /// rule as the Android app.
    /// `onProgress` fires ONLY when something actually has to be fetched, so the
    /// sheet stays quiet on the common warm path and speaks up on the slow one.
    /// This is the slowest step, so it reports its own progress rather than
    /// leaving the first signal for after the city has resolved.
    private func ensureCityTiers(
        for query: String, onProgress: ((Phase?) -> Void)? = nil
    ) async {
        let cityIndex = self.cityIndex
        let country = Locale.current.region?.identifier ?? ""
        if country.count == 2, !(await offMain { cityIndex.isCountryTierLoaded() }) {
            onProgress?(.downloadingCityIndex)
            let url = Self.byCountryPrefix + country.lowercased() + ".sqlite.zst"
            _ = await offMain { try? cityIndex.ensureCountryTier(url: url) }
        }
        let tokens = query.split(whereSeparator: \.isWhitespace)
        let cityShaped = tokens.count <= 2
        if cityShaped, !(await offMain { cityIndex.isTier1Loaded() }) {
            onProgress?(.downloadingCityIndex)
            let url = Self.tier1URL
            _ = await offMain { try? cityIndex.ensureTier1(url: url) }
        }
    }

    /// Where to measure "near" from: an explicit focus point wins, otherwise the
    /// city the query itself names. Returns nil when neither is available, in which
    /// case ranking is skipped and the geocoder's own order stands.
    private func anchorPoint(
        focusLat: Double?, focusLng: Double?, query: String
    ) async -> (Double, Double)? {
        if let lat = focusLat, let lng = focusLng { return (lat, lng) }
        // Only the hint half is a city; reuse the same peeling the fallback uses so
        // the two paths agree on what "the city in this query" means.
        for candidate in Self.buildCandidates(query) {
            // No focus by definition — this IS the path that runs when there is
            // none, so ranking falls back to population + home country.
            guard let c = await resolveCity(candidate.hint) else { continue }
            // Same bar as the fallback. An anchor derived from a bad guess is
            // worse than no anchor: it would silently sort every result by its
            // distance from a city the user never mentioned.
            guard Self.cityCorroborates(c, candidate) else { continue }
            return (c.lat, c.lng)
        }
        return nil
    }

    /// Rank results inside a city we deliberately scoped to. Two signals:
    ///   1. An exact POSTCODE match wins regardless of distance — a user who
    ///      typed "hickman ca 95323" told us which of the city's postcodes they
    ///      meant, and that beats being nearer the centroid.
    ///   2. Distance from the scope centroid, so addresses near the resolved city
    ///      outrank tile-edge outliers.
    ///
    /// Deliberately NOT `rankPlaces`: inside one city every row is roughly
    /// equidistant and the query's address half ("267 pinkston avenue") is street
    /// text, not a venue name, so the match-group gate has nothing to bite on.
    /// Mirrors the Android app's `rankScopedResults`.
    private static func rankScopedResults(
        _ rows: [GeocodingResult], query: String, scopeLat: Double, scopeLng: Double
    ) -> [GeocodingResult] {
        let queryPostcode = extractPostcode(query)
        return rows
            .enumerated()
            .sorted { a, b in
                let pa = queryPostcode != nil && a.element.postcode == queryPostcode
                let pb = queryPostcode != nil && b.element.postcode == queryPostcode
                if pa != pb { return pa }
                let da = haversineKm((scopeLat, scopeLng), (a.element.lat, a.element.lng))
                let db = haversineKm((scopeLat, scopeLng), (b.element.lat, b.element.lng))
                // Ties keep source order, so equal-distance rows do not jitter
                // between identical searches.
                return da == db ? a.offset < b.offset : da < db
            }
            .map(\.element)
    }

    /// The first postcode-shaped token in the query, if any. Reuses the same
    /// shape test `buildCandidates` uses to strip a trailing postcode, so the two
    /// agree on what a postcode looks like.
    private static func extractPostcode(_ query: String) -> String? {
        query
            .split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .map(String.init)
            .first(where: isPostcodeShaped)
    }

    /// Great-circle distance in km. Used for ORDERING and for the distance shown
    /// on each row, so the small-angle error that matters for navigation is
    /// irrelevant — nothing here is a route.
    ///
    /// `nonisolated`: pure arithmetic, and AddressSearchView calls it off the actor.
    nonisolated static func haversineKm(_ a: (Double, Double), _ b: (Double, Double)) -> Double {
        let r = 6371.0
        let dLat = (b.0 - a.0) * .pi / 180
        let dLon = (b.1 - a.1) * .pi / 180
        let lat1 = a.0 * .pi / 180
        let lat2 = b.0 * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2)
            + sin(dLon / 2) * sin(dLon / 2) * cos(lat1) * cos(lat2)
        return 2 * r * asin(min(1, sqrt(h)))
    }

    /// What a tile load produced. `cells` is the set the caller may treat as
    /// "inside this city"; `nil` means tiles were loaded but their cell list is
    /// not known (the neighbours blunderbuss), so results must NOT be filtered.
    struct LoadedTiles {
        let cells: Set<String>?
        /// The town's own tile, loaded, for a miss to widen around; nil
        /// for the centroid's cells.
        var town: String? = nil
    }

    /// Pull down the tiles a resolved city occupies, preferring the ones that
    /// actually contain `term`.
    ///
    /// ALWAYS THE TOWN'S OWN TILE: the tile the manifest has at the town's point,
    /// else the index's stored `tileId`. It is in scope too, and on a miss the
    /// caller widens to the eight beside it. Then:
    ///
    /// THREE STRATEGIES, IN PRIORITY ORDER — the same order the Android app uses:
    ///
    ///   1. **The per-city addr+POI shard**, queried for `term`. Surgical: it
    ///      returns only the tiles holding that street or POI.
    ///   2. **`tileIds`** — the set the build pipeline computed for the city's
    ///      extent. Correct but blunt; a big city is many tiles. It leaves out a
    ///      SPLIT cell, which is why the town's own tile is loaded as well.
    ///   3. **Centroid + 8 geohash neighbours** — legacy last resort, for rows
    ///      that carry only a centroid, reached only when nothing above loaded
    ///      (`scopedCells` answers nil).
    ///
    /// WHY STEP 1 MATTERS
    ///   `tileIds` alone does not bring down the address data: with a cold tile
    ///   cache, "350 fifth ave, new york, ny" would find no address even though a
    ///   POI in the very same cells is found. A device that has the tiles cached
    ///   already hides this completely.
    ///
    ///   The shard is also cheaper, not just more correct: it is one file keyed by
    ///   geoname_id, and it narrows a city to the handful of tiles holding the
    ///   street instead of every tile the city touches.
    ///
    /// `hasShard` gates the attempt so small cities without OA coverage do not pay
    /// a CDN round-trip for a guaranteed 404. The SDK already treats "no shard",
    /// "404", "no rows" and "I/O failure" identically — all return an empty list —
    /// so an empty result here just falls through to step 2.
    private func loadTiles(for city: CityResult, matching term: String) async -> LoadedTiles? {
        // Every branch below can DOWNLOAD, so the whole thing runs off the main
        // actor. `city` is copied into plain values first — CityResult is not
        // Sendable, and only these fields are needed across the boundary.
        let geocoder = self.geocoder
        let geonameId = city.geonameId
        let hasShard = city.hasShard
        let tileIds = city.tileIds
        let storedTileId = city.tileId
        let lat = city.lat
        let lng = city.lng
        return await offMain {
            Self.loadTilesBlocking(geocoder: geocoder, geonameId: geonameId,
                                   hasShard: hasShard, tileIds: tileIds, storedTileId: storedTileId,
                                   lat: lat, lng: lng, term: term)
        }
    }

    /// The blocking half of `loadTiles`, kept `nonisolated static` so it cannot
    /// accidentally touch the main actor.
    private nonisolated static func loadTilesBlocking(
        geocoder: TileGeocoder, geonameId: Int64, hasShard: Bool,
        tileIds: [String], storedTileId: String, lat: Double, lng: Double, term: String
    ) -> LoadedTiles? {
        // The town's own tile, always (the caller widens to the eight beside it
        // on a miss). The cities index's tileIds leave out a SPLIT cell:
        // Cupertino's are '9q95,9q9m' while its own cell 9q9h is split into
        // 9q9h0…9q9hz, and San Francisco's have no 9q8y child. Without it
        // "anything, San Francisco" would never search downtown, and "1 Infinite
        // Loop, Cupertino", which the address data labels San Jose and so is not
        // in Cupertino's shard, would find nothing.
        let shardTiles: (() -> [String])? = hasShard && !term.isEmpty
            ? { geocoder.lookupCityShardTiles(geonameId: geonameId, term: term) }
            : nil
        if let first = Self.scopedCells(shardTiles: shardTiles, tileIds: tileIds, storedTileId: storedTileId,
                                        lat: lat, lng: lng, load: { Self.loadTile($0, geocoder: geocoder) }) {
            return LoadedTiles(cells: first.cells, town: first.town)
        }
        // Returns the COUNT of tiles loaded, not a Bool — treat >0 as success.
        let loaded = (try? geocoder.ensureTileAndNeighborsLoaded(
            lat: lat, lng: lng
        )) ?? 0
        // Cells unknown: this path loads whatever surrounds the centroid, which is
        // not the city's cell list, so the caller must not filter on it.
        return loaded > 0 ? LoadedTiles(cells: nil) : nil
    }
}

/// One answer out of several, delivered once: the first `answer` resumes the
/// waiter and every later one is dropped. An answer that arrives before anyone
/// waits is kept for the waiter. `SmartSearch.race` needs both: its timer, its
/// work and a cancellation each answer, in any order.
final class FirstAnswer<T>: @unchecked Sendable {
    private enum State {
        case open
        case waiting(CheckedContinuation<T, Never>)
        case answered(T)
        case done
    }

    private let lock = NSLock()
    private var state = State.open

    func wait(_ continuation: CheckedContinuation<T, Never>) {
        lock.lock()
        if case .answered(let value) = state {
            state = .done
            lock.unlock()
            continuation.resume(returning: value)
            return
        }
        state = .waiting(continuation)
        lock.unlock()
    }

    func answer(_ value: T) {
        lock.lock()
        switch state {
        case .open:
            state = .answered(value)
            lock.unlock()
        case .waiting(let continuation):
            state = .done
            lock.unlock()
            continuation.resume(returning: value)
        case .answered, .done:
            lock.unlock()
        }
    }
}
