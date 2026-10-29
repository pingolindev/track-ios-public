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
import struct PingolinTrackSDK.CityResult
import struct PingolinTrackSDK.GeocodingResult

/// Ranking for city candidates — the rows the search offers when the user names a
/// place rather than an address. Port of the Android app's `CityRanking`.
///
/// WHY THE INDEX'S OWN ORDER IS NOT ENOUGH
///   `CityIndex.search` can only order by population, which is wrong in both
///   directions: it buries Delhi, IN under Delhi, CA, and it would happily put
///   Birmingham, England above Birmingham, Alabama for someone standing in Ohio.
///
/// THE RULE
///     score = log10(population)
///           - DISTANCE_WEIGHT * log10(1 + km from focus)
///           + HOME_COUNTRY_BONUS when the row is in the user's own country
///
///   With both weights at 1.0: being ten times further away costs exactly what
///   being ten times smaller costs, and being in your own country is worth a
///   tenfold population advantage. That is deliberately a rule you can hold in
///   your head — the alternative, a pile of hand-tuned thresholds, is
///   unexplainable the first time it ranks something oddly.
///
///   Prominence is not smothered: Delhi at 10.9M and 12,000 km still beats an
///   11k Delhi at 3,400 km.
enum CityRanking {

    /// Cost of distance relative to population. See the doc above.
    static let distanceWeight = 1.0
    /// Bonus for a row in the user's own country.
    static let homeCountryBonus = 1.0

    /// Sort `rows` best-first. A single row is returned untouched — there is
    /// nothing to reorder and no reason to pay for the maths.
    static func rank(
        _ rows: [CityResult],
        focusLat: Double?,
        focusLng: Double?,
        homeCountry: String? = Locale.current.region?.identifier
    ) -> [CityResult] {
        guard rows.count > 1 else { return rows }
        let home = homeCountry.flatMap { $0.isEmpty ? nil : $0 }
        return rows
            .enumerated()
            .sorted { a, b in
                let sa = score(a.element, focusLat: focusLat, focusLng: focusLng, home: home)
                let sb = score(b.element, focusLat: focusLat, focusLng: focusLng, home: home)
                // Ties keep source order, so equal-scoring rows do not jitter
                // between identical searches.
                return sa == sb ? a.offset < b.offset : sa > sb
            }
            .map(\.element)
    }

    private static func score(
        _ row: CityResult, focusLat: Double?, focusLng: Double?, home: String?
    ) -> Double {
        var score = log10(Double(max(row.population, 0)) + 1.0)
        if let focusLat, let focusLng {
            let km = SmartSearch.haversineKm((focusLat, focusLng), (row.lat, row.lng))
            score -= distanceWeight * log10(1.0 + km)
        }
        if let home, row.countryCode.caseInsensitiveCompare(home) == .orderedSame {
            score += homeCountryBonus
        }
        return score
    }

    // MARK: - Places (venues and street addresses)

    /// Worth of the name being EXACTLY what was typed rather than merely
    /// containing it, on the same log10 scale. At 0.3 an exact name outranks a
    /// longer one up to ~2× further away (10^0.3 = 2.0) and loses beyond that.
    ///
    /// Deliberately small: enough to keep "Target" above "Ulta Beauty at Target"
    /// in the same retail park, far too small to send a Modesto user to an
    /// "In-N-Out" 500 km away ahead of an "In-N-Out Burger" 69 km away — as an
    /// absolute preference would.
    static let exactNameBonus = 0.3

    /// Rank concrete places — venues and street addresses — with the same policy
    /// as `rank`, minus the prominence term.
    ///
    /// NO POPULATION TERM, AND THAT IS NOT AN OVERSIGHT. A coffee shop has no
    /// population. `confidence` cannot stand in (the gateway returns 1.00 for
    /// essentially every row) and neither can the gateway's own order: it is
    /// provably insufficient — "birmingham" (US row 2nd, 3,109 km) and "paris"
    /// (US row 2nd, 2,333 km) have identical shape but need opposite winners, and
    /// only the real population gap separates them. So prominence is left to the
    /// channel that can price it (the city index) and this ranks by the two
    /// signals that apply to a specific building.
    ///
    /// MATCH QUALITY GATES, GEOGRAPHY ORDERS — lexicographic, not blended. Sorting
    /// by distance alone is not enough: searching "pinks hot dogs" from Modesto,
    /// the nearest rows are "Mark's Hot Dogs" (80 km) and "Casper's Hot Dogs"
    /// (82 km), and a pure distance sort puts both above every actual Pink's at
    /// ~420 km. Whatever else the user wants, they did not ask for Mark's.
    ///
    /// Port of the Android app's `rankPlaces`.
    static func rankPlaces(
        _ rows: [GeocodingResult],
        focusLat: Double?,
        focusLng: Double?,
        homeCountry: String? = Locale.current.region?.identifier,
        query: String = ""
    ) -> [GeocodingResult] {
        guard rows.count > 1 else { return rows }
        let home = homeCountry.flatMap { $0.isEmpty ? nil : $0 }
        let queryTokens = normalizeTokens(query)
        let ranked = rows
            .enumerated()
            .sorted { a, b in
                // The GATE is "does the name answer the query at all", not "how
                // exactly" — an exact name and one that merely CONTAINS the query
                // both answer it, so they compete on geography. Only partial and
                // non-matches are held below.
                let ga = matchGroup(queryTokens, a.element.name ?? a.element.text)
                let gb = matchGroup(queryTokens, b.element.name ?? b.element.text)
                if ga != gb { return ga < gb }
                let sa = placeScore(a.element, focusLat: focusLat, focusLng: focusLng,
                                    home: home, queryTokens: queryTokens)
                let sb = placeScore(b.element, focusLat: focusLat, focusLng: focusLng,
                                    home: home, queryTokens: queryTokens)
                // Ties keep source order rather than jittering between identical
                // searches — Swift's sort is not stable on its own.
                return sa == sb ? a.offset < b.offset : sa > sb
            }
            .map(\.element)
        return dropSameAddressDuplicates(ranked)
    }

    private static func placeScore(
        _ row: GeocodingResult, focusLat: Double?, focusLng: Double?,
        home: String?, queryTokens: [String]
    ) -> Double {
        var score = 0.0
        if let focusLat, let focusLng {
            let km = SmartSearch.haversineKm((focusLat, focusLng), (row.lat, row.lng))
            score -= distanceWeight * log10(1.0 + km)
        }
        // The geocoder labels rows alpha-3 ("USA") while the device region is
        // alpha-2 ("US"). Android resolves its own alpha-3 to compare; Foundation
        // has no such API, so this goes through the ICU region-name comparison in
        // AddressFormat, which normalises BOTH forms and refuses to collide on
        // unknown codes. A naive prefix test would count every Chinese row as home
        // for a Swiss user ("CHN".hasPrefix("CH")).
        if let home, let cc = row.country, !cc.isEmpty,
           AddressFormat.isHomeCountryCode(cc, home: home) {
            score += homeCountryBonus
        }
        if isExactName(queryTokens, row.name ?? row.text) {
            score += exactNameBonus
        }
        return score
    }

    /// Collapse POI rows naming the same place at the same street address.
    ///
    /// The source really does carry duplicates — "pinks hot dogs" returns two
    /// records for "201 Universal City Plaza". A row that shows its street drops
    /// the neighbourhood, so nothing else tells the pair apart and they would
    /// render as two identical lines.
    ///
    /// Runs AFTER the sort, so the survivor is the best-ranked one rather than
    /// whichever the source listed first. Deliberately narrow: same name AND same
    /// non-blank street. Rows with no street are never collapsed — there the
    /// address is not evidence of sameness, and two genuinely different outlets in
    /// one city would both have a blank street.
    private static func dropSameAddressDuplicates(
        _ rows: [GeocodingResult]
    ) -> [GeocodingResult] {
        guard rows.count > 1 else { return rows }
        var seen = Set<String>()
        return rows.filter { row in
            guard row.resultType == "poi",
                  let street = nonBlankLower(row.address),
                  let name = nonBlankLower(row.name)
            else { return true }
            return seen.insert("\(name)|\(street)").inserted
        }
    }

    private static func nonBlankLower(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespaces).lowercased(), !t.isEmpty
        else { return nil }
        return t
    }

    // MARK: - Token matching

    /// Split to comparable tokens. Apostrophes are DELETED rather than turned
    /// into separators, so "Pink's" becomes `pinks` and matches a user who typed
    /// "pinks" — split on the apostrophe instead and it becomes `pink` + `s`,
    /// which matches nothing and silently drops the exact hit to the bottom tier.
    static func normalizeTokens(_ s: String) -> [String] {
        String(
            s.lowercased()
                .replacingOccurrences(of: "'", with: "")
                .replacingOccurrences(of: "\u{2019}", with: "")
                .map { $0.isLetter || $0.isNumber ? $0 : " " }
        )
        .split(separator: " ")
        .map(String.init)
    }

    /// How well a row's name answers the query. Lower is better:
    ///   0 — the name IS the query ("pinks hot dogs" → "Pink's Hot Dogs")
    ///   1 — the name contains every query token
    ///   2 — it contains some of them
    ///   3 — none, or nothing to compare
    ///
    /// With an empty query every row lands in the same tier, so ranking degrades
    /// to pure geography rather than to an arbitrary order.
    static func matchTier(_ queryTokens: [String], _ name: String?) -> Int {
        guard !queryTokens.isEmpty else { return 0 }
        let nameTokens = normalizeTokens(name ?? "")
        if nameTokens.isEmpty { return 3 }
        if nameTokens == queryTokens { return 0 }
        let nameSet = Set(nameTokens)
        let hits = queryTokens.filter { nameSet.contains($0) }.count
        if hits == queryTokens.count { return 1 }
        return hits > 0 ? 2 : 3
    }

    /// Coarser than `matchTier`, and the coarseness is the point: tiers 0 and 1
    /// both mean "the name contains everything the user typed", so they belong in
    /// ONE group that competes on distance.
    ///
    /// Keeping them apart would let an exact name beat a fuller one at any
    /// distance: "in n out" from Modesto would rank an "In-N-Out" in Crane,
    /// Missouri — 2,419 km — above every "In-N-Out Burger" in California,
    /// including one 69 km away, because the shorter name equals the query.
    static func matchGroup(_ queryTokens: [String], _ name: String?) -> Int {
        switch matchTier(queryTokens, name) {
        case 0, 1: return 0     // the name answers the query in full
        case 2: return 1        // partial
        default: return 2       // no overlap
        }
    }

    /// True when the name is exactly what was typed, no extra words.
    static func isExactName(_ queryTokens: [String], _ name: String?) -> Bool {
        !queryTokens.isEmpty && normalizeTokens(name ?? "") == queryTokens
    }
}
