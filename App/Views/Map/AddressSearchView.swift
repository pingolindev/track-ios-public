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

import SwiftUI
import CoreLocation
import struct PingolinTrackSDK.CityResult
import struct PingolinTrackSDK.GeocodingResult

/// Sheet for typing an address / POI query and routing through the
/// geocoder. Mirrors the Android app's `fabSearchAddress` flow — the
/// user picks a result, the sheet dismisses, and the caller flies the
/// map camera to the chosen coordinate.
///
/// The forward query goes through `SmartSearch`, which answers from the
/// on-device `TileGeocoder` by default and from the anonymous Pelias
/// gateway when the user has opted in (Settings → Geocoding, premium).
struct AddressSearchView: View {
    let onPick: (GeocodingResult) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query: String = ""
    /// Everything the field sets in motion: the pause, the search, what it
    /// found.
    @StateObject private var search = PlaceSearchModel()
    @FocusState private var queryFocused: Bool

    /// The query field, at the TOP of the sheet and focused the moment it opens.
    ///
    /// Not `.searchable`: that puts an empty, unfocused system search bar at the
    /// BOTTOM of a full-height sheet with the title stranded at the top and a
    /// screen of white between them, so the sheet opens looking broken and asks
    /// for a tap before it accepts a character. `.searchable` cannot be focused
    /// on this app's deployment target either: `searchFocused(_:)` needs iOS
    /// 17.1 and the target is 17.0.
    ///
    /// An explicit field avoids all of it and is what the Android app does: its
    /// query field is the first control in the search dialog and takes focus
    /// when the dialog opens. Placement is ours rather than the system's, so it
    /// cannot move when the platform changes where search bars live.
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Address, place or city", text: $query)
                .focused($queryFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                // The keyboard's action key reads "search", matching Android's
                // `imeOptions="actionSearch"`. Typing already runs the query, so
                // submitting only needs to put the keyboard away.
                .submitLabel(.search)
                .onSubmit { queryFocused = false }
                .accessibilityIdentifier("map-search-field")
            if !query.isEmpty {
                Button {
                    query = ""
                    queryFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
        .padding(.horizontal)
        .padding(.top, 8)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchField

                // Idle guidance: a sheet that opens completely blank
                // reads as a failed search rather than an empty one. It
                // does not name the map view: the whole city is searched
                // on its own, so the viewport clamp drops nothing
                // unsaid.
                if !SearchSchedule.isSearchable(query) {
                    Text("Type to search.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.top, 12)
                }

                // The rest of the city on a metered network: the
                // whole-city search ran by itself over the tiles on the
                // phone, and this fetches the others. ABOVE the list
                // rather than after it, so it survives a full screen of
                // results: inside the List it would not, since SwiftUI's
                // List is lazy, and with 11 rows and the keyboard up the
                // control would never be realised, let alone reachable.
                // Android has the same ordering for the same reason —
                // tvMapSearchExpand is a fixed row and rvMapSearchResults
                // takes 0dp with layout_weight=1 beneath it. With no rows
                // it sits under the empty state instead.
                if Self.offersMoreData(moreToDownload: search.moreToDownload, isSearching: search.isSearching,
                                       query: query),
                   search.hasRows {
                    moreDataRow
                    Divider()
                }

                List {
                    // Every row whose whole name is what was typed
                    // comes first, places then towns: "Hamburg" over
                    // San Francisco is every Hamburg, not the
                    // "Hamburger…" places that only start with it.
                    if !search.leadingPlaces.isEmpty || !search.leadingCities.isEmpty {
                        Section {
                            ForEach(Array(search.leadingPlaces.enumerated()), id: \.offset) { _, result in
                                placeRow(result)
                            }
                            ForEach(Array(search.leadingCities.enumerated()), id: \.offset) { _, city in
                                cityRow(city)
                            }
                        }
                    }

                    // Header names WHERE these rows came from — "In New York City, NY".
                    // Without it a scoped result set reads as a plain global search, and
                    // the user cannot tell that a missing address was looked for in the
                    // right city. Mirrors the Android app's cachedSectionTitle.
                    Section(header: scopeHeader) {
                        ForEach(Array(search.results.enumerated()), id: \.offset) { _, result in
                            placeRow(result)
                        }
                    }

                    // Cities the index matched, below the addresses. Same section
                    // title and same ordering as Android's adapter.
                    if !search.cities.isEmpty {
                        Section(header: Text("Other locations")) {
                            ForEach(Array(search.cities.enumerated()), id: \.offset) { _, city in
                                cityRow(city)
                            }
                        }
                    }

                    // Anything in flight gets a spinner, named as specifically as we
                    // can name it. Without this the list sits empty and looks like a
                    // failed search.
                    if search.isSearching {
                        Section {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text(Self.progressText(for: search.loadingPhase, cityWide: search.widening))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    if !search.hasRows && SearchSchedule.isSearchable(query)
                        && !search.isSearching {
                        Section {
                            Text(Self.emptyText(timedOut: search.timedOut, scopedTo: search.scopedTo,
                                                moreToDownload: search.moreToDownload))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            if Self.offersMoreData(moreToDownload: search.moreToDownload,
                                                   isSearching: search.isSearching, query: query) {
                                moreDataRow
                            }
                        }
                    }

                }
                .listStyle(.plain)
                }
                .onChange(of: query) { _, newValue in
                    search.queryChanged(newValue)
                }
                .onAppear {
                    // Snapshot the camera once. Nil when the map has not laid out yet,
                    // which the search treats as "no focus" — never (0, 0), which is in
                    // the Gulf of Guinea and would clamp every result away.
                    if let c = MapViewportState.shared.center {
                        search.focus = (c.latitude, c.longitude)
                    }
                    search.area = MapViewportState.shared.area
                    search.watchNetwork()
                }
                .onDisappear { search.stopWatchingNetwork() }
                .task {
                    // Focus AFTER the sheet's presentation animation rather than in
                    // `onAppear`: a field that becomes first responder while the sheet
                    // is still animating up loses it again on some presentations, and
                    // the keyboard then never appears. One runloop hop is enough.
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    queryFocused = true
                }
                .navigationTitle("Search")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    /// What to say while the search is running. Naming the city once we know it
    /// is the difference between "something is happening" and "it is downloading
    /// Oakdale" — and the city-index phase is the easiest one to leave silent,
    /// because it finishes before any progress would otherwise be reported.
    ///
    /// A nil phase is the ordinary start of every search, before the fallback has
    /// reached a named step. Wording matches the Android app's so the two
    /// platforms describe the same work the same way.
    ///
    /// `String(localized:)`, so the String Catalog extracts these lines: a
    /// `Text` built from a plain String is never translated.
    static func progressText(for phase: SmartSearch.Phase?, cityWide: Bool) -> String {
        switch phase {
        case .none:
            return cityWide ? String(localized: "Searching beyond the map view…") : String(localized: "Searching…")
        case .downloadingCityIndex:
            return String(localized: "Downloading place names…")
        case .loadingTiles(let scope):
            return String(localized: "Loading addresses for \(scope.label)…")
        }
    }

    /// "In New York City, NY" when a scope was resolved, else "Cached areas" —
    /// these rows came from whatever tiles this device happens to hold, and
    /// saying so is what distinguishes them from the "Other locations" below.
    /// Same two titles as Android's `cachedSectionTitle ?: "Cached areas"`.
    @ViewBuilder private var scopeHeader: some View {
        if !search.results.isEmpty {
            Text(search.scopedTo.map { "In \($0.label)" } ?? "Cached areas")
        }
    }

    /// One place row: its name, then "New York, NY 10118 · 5385 mi". A tap drops
    /// the pin on it.
    private func placeRow(_ result: GeocodingResult) -> some View {
        Button {
            onPick(result)
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                let primary = result.name ?? result.text
                Text(primary)
                    .font(.body)
                    .foregroundStyle(.primary)
                let secondary = AddressFormat.secondaryLine(result, primary: primary)
                let away = distanceLabel(for: result)
                if !secondary.isEmpty || away != nil {
                    // One line, "·"-separated, same as Android:
                    // "New York, NY 10118 · 5385 mi".
                    Text([secondary.isEmpty ? nil : secondary, away]
                        .compactMap { $0 }
                        .joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// One city row: its name, then "CA · 12 mi · 22k people". A tap drops the pin
    /// on the city.
    private func cityRow(_ city: CityResult) -> some View {
        Button {
            onPick(Self.asResult(city))
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(city.name)
                    .font(.body)
                    .foregroundStyle(.primary)
                let line = citySecondary(city)
                if !line.isEmpty {
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// "CA · 12 mi · 22k people" — field for field as in Android's
    /// `bindCity`, including dropping the
    /// user's own country code, which is noise on every domestic result.
    private func citySecondary(_ city: CityResult) -> String {
        var parts: [String] = []
        let adminCountry = [
            AddressFormat.namedRegion(city.admin1),
            (!city.countryCode.isEmpty && !AddressFormat.isHomeCountryCode(city.countryCode))
                ? city.countryCode : nil,
        ].compactMap { $0 }.joined(separator: ", ")
        if !adminCountry.isEmpty { parts.append(adminCountry) }
        if let focus = search.focus {
            parts.append(AddressFormat.distance(
                km: SmartSearch.haversineKm((focus.lat, focus.lng), (city.lat, city.lng))))
        }
        if city.population > 0 { parts.append(Self.population(city.population)) }
        return parts.joined(separator: " · ")
    }

    /// Compact population: 1.3M people, 22k people, 832 people. Matches
    /// Android's `formatPopulation` tier for tier.
    private static func population(_ pop: Int64) -> String {
        if pop >= 1_000_000 { return String(format: "%.1fM people", Double(pop) / 1_000_000) }
        if pop >= 1_000 { return String(format: "%.0fk people", Double(pop) / 1_000) }
        return "\(pop) people"
    }

    /// A city as something the map can accept. The caller drops a pin and flies
    /// to it, so the centroid IS the answer here — the same thing Android's
    /// `deliverCity` hands to `onLocationPicked`, label included.
    private static func asResult(_ city: CityResult) -> GeocodingResult {
        let label = [
            city.name,
            AddressFormat.namedRegion(city.admin1),
            city.countryCode.isEmpty ? nil : city.countryCode,
        ].compactMap { $0 }.joined(separator: ", ")
        return GeocodingResult(
            text: label,
            lat: city.lat,
            lng: city.lng,
            resultType: "city",
            confidence: 1.0,
            name: city.name,
            city: city.name,
            state: AddressFormat.namedRegion(city.admin1),
            postcode: nil,
            country: city.countryCode.isEmpty ? nil : city.countryCode,
            address: nil
        )
    }

    /// Distance from the map centre — NOT from the user. Android measures from the
    /// same focus point (`MapAddressSearchSheet` passes `focusLat/focusLng` straight
    /// into the adapter), and it is the honest reading here: this row is "x from what
    /// you are looking at", which is what makes two branches of the same chain
    /// distinguishable.
    private func distanceLabel(for r: GeocodingResult) -> String? {
        guard let focus = search.focus else { return nil }
        let km = SmartSearch.haversineKm((focus.lat, focus.lng), (r.lat, r.lng))
        return AddressFormat.distance(km: km)
    }

    /// The rest of the city, fetched on a tap: offered only when the whole-city
    /// search left tiles behind on a metered network, and not while a search
    /// runs. Never over the gateway's rows, which never leave anything behind.
    static func offersMoreData(moreToDownload: Bool, isSearching: Bool, query: String) -> Bool {
        moreToDownload && !isSearching && SearchSchedule.isSearchable(query)
    }

    /// What an empty list says. A download that did not finish says so, and asks
    /// nothing: the search runs again by itself on the next typing pause and when
    /// the network comes back (PlaceSearchModel). A city the query named: that
    /// the address is not in it. A metered network with the city half fetched:
    /// that nothing is found YET, with the row under it. Anything else: that
    /// nothing is found. Localized for the String Catalog, as `progressText`.
    static func emptyText(timedOut: Bool, scopedTo: SmartSearch.Scope?, moreToDownload: Bool) -> String {
        if timedOut {
            return scopedTo.map { String(localized: "Couldn't download map data for \($0.label).") }
                ?? String(localized: "Couldn't download map data.")
        }
        if let scope = scopedTo, scope != .nearbyArea {
            return String(localized:
                "Couldn't find that address in \(scope.label). Try a different street or pick a spot on the map.")
        }
        return moreToDownload ? String(localized: "No places found yet") : String(localized: "No places found")
    }

    /// "Search beyond the map view (uses more data) →": "more data" rather than
    /// "mobile data", because a phone's hotspot is metered Wi-Fi.
    private var moreDataRow: some View {
        Button {
            search.searchMore(query)
        } label: {
            Text("Search beyond the map view (uses more data) →")
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
    }
}
