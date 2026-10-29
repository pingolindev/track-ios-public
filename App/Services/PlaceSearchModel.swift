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

/// When a typed query is searched. Pure, so a test can type at it: the
/// model feeds it every edit and asks it what to do, and runs the pause itself.
///
/// Like other apps, a query is searched automatically after a short pause. A
/// settled query can spend a server credit, so: half a second after the last
/// keystroke, from three characters, and never the same query twice in a row.
/// "Pizza " and "pizza" are one query (`SmartSearch.normalised`).
struct SearchSchedule {
    /// The pause after the last keystroke before a query is searched.
    static let pause: Duration = .milliseconds(500)
    /// The shortest query searched at all.
    static let minLength = 3

    /// The query searched last, running or answered, normalised.
    private(set) var searched: String?
    /// The query waiting out its pause: normalised, and as typed.
    private(set) var waiting: (key: String, text: String)?

    enum Step: Equatable {
        /// Too short to search: show nothing, and stop any pause.
        case clear
        /// The same query as the one already waiting: let its pause run on.
        case unchanged
        /// Back to the query searched last: stop the pause, keep what is shown.
        case cancelWait
        /// A new query: start the pause again.
        case wait
    }

    static func isSearchable(_ raw: String) -> Bool {
        SmartSearch.normalised(raw).count >= minLength
    }

    mutating func typed(_ raw: String) -> Step {
        let key = SmartSearch.normalised(raw)
        guard key.count >= Self.minLength else {
            waiting = nil
            searched = nil
            return .clear
        }
        if key == waiting?.key {
            // The same query: its pause runs on, and it is searched as typed last.
            waiting = (key, raw.trimmingCharacters(in: .whitespacesAndNewlines))
            return .unchanged
        }
        if key == searched {
            waiting = nil
            return .cancelWait
        }
        waiting = (key, raw.trimmingCharacters(in: .whitespacesAndNewlines))
        return .wait
    }

    /// The pause ran out: the text to search now, if one is waiting.
    mutating func settle() -> String? {
        guard let waiting else { return nil }
        self.waiting = nil
        searched = waiting.key
        return waiting.text
    }
}

/// The place search behind the map's Search sheet: what it shows, and when it
/// asks. The view owns the field; this owns everything the field sets in
/// motion.
///
/// A settled query is searched in two steps: the map view first, which is
/// quick, and then, by itself, the whole city under the map, with no tap
/// needed. It follows `SmartSearch.Downloads`: on a metered network it
/// searches the city's tiles already on the phone, and `moreToDownload`
/// offers the rest on a tap.
@MainActor
final class PlaceSearchModel: ObservableObject {
    @Published private(set) var results: [GeocodingResult] = []
    /// City hits from the cities index (`SmartSearch.Result.cities`). They are
    /// listed as well as the addresses: without them a city-shaped query such
    /// as 'oakdale' would answer "No matches for 'oakdale' on this part of the
    /// map" although the SDK returned cities. The Android app lists them under
    /// "Other locations".
    @Published private(set) var cities: [CityResult] = []
    /// Every row whose whole name is what was typed, shown first: places, then
    /// towns (`SmartSearch.split`). Neither is in `results` or `cities` as well.
    @Published private(set) var leadingPlaces: [GeocodingResult] = []
    @Published private(set) var leadingCities: [CityResult] = []

    /// Every place found, exact names first: a list without towns (Add Place).
    var places: [GeocodingResult] { leadingPlaces + results }
    /// Anything to show at all.
    var hasRows: Bool { !leadingPlaces.isEmpty || !leadingCities.isEmpty || !results.isEmpty || !cities.isEmpty }
    /// A search is waiting out its pause or running. Separate from
    /// `loadingPhase` on purpose: a phase is only reported once the fallback
    /// reaches a named step, and everything before that — the city-index lookup,
    /// the server call, the on-disk pass — reports nothing at all. Letting the
    /// empty state render during that window means a slow search (or one that
    /// never returns) displays the "No matches for <query>" copy while still
    /// running. The Android app has no such window: its loading view is shown
    /// before the search call and hidden only after it returns.
    @Published private(set) var isSearching = false
    /// City the fallback is currently loading tiles for. Drives the progress row —
    /// the tile download takes seconds, and an empty list in the meantime reads as
    /// "nothing found" rather than "still looking".
    @Published private(set) var loadingPhase: SmartSearch.Phase?
    /// A download the search needed did not finish. Distinct from "no matches":
    /// the search never got to look, so saying there are none would be a lie.
    @Published private(set) var timedOut = false
    /// City the fallback settled on, so the empty state can name where it looked.
    @Published private(set) var scopedTo: SmartSearch.Scope?
    /// The rows came from the gateway, not this device's tiles.
    @Published private(set) var fromServer = false
    /// The whole-city step is running, by itself or from the row.
    @Published private(set) var widening = false
    /// The whole-city step left tiles of the city undownloaded on a metered
    /// network: the sheet offers them, and says it uses more data.
    @Published private(set) var moreToDownload = false

    /// Map camera as of when the sheet opened. Captured ONCE rather than read per
    /// search: the map cannot move while a modal sheet is up, and re-reading would
    /// make two runs of the same query answerable differently. Nil when the map
    /// has not laid out yet, which the search treats as "no focus" — never (0, 0),
    /// which is in the Gulf of Guinea and would clamp every result away.
    @Published var focus: (lat: Double, lng: Double)?
    @Published var area: SmartSearch.SearchArea?

    /// Rows one answer holds. The same cap as the Android app's sheet, so the
    /// two platforms return the same rows for the same query.
    static let rowLimit = 8

    /// How far one search reaches.
    enum Reach: Equatable {
        /// The map view, and a city the query names.
        case mapView
        /// The whole city under the map, downloading what is missing as allowed.
        case wholeCity(SmartSearch.Downloads)
    }

    /// How a query is searched. A seam: the sheet uses SmartSearch through
    /// GeocodingService, and a test a fake it can hold and count.
    typealias Search = @MainActor (
        _ text: String, _ focus: (lat: Double, lng: Double)?, _ area: SmartSearch.SearchArea?,
        _ reach: Reach, _ onProgress: @escaping (SmartSearch.Phase?) -> Void
    ) async -> SmartSearch.Result

    private let search: Search
    private let pauseLength: Duration

    init(pause: Duration = SearchSchedule.pause, search: Search? = nil) {
        self.pauseLength = pause
        self.search = search ?? { text, focus, area, reach, onProgress in
            var cityWide = false
            var downloads = SmartSearch.Downloads.always
            if case .wholeCity(let allowed) = reach {
                cityWide = true
                downloads = allowed
            }
            return await GeocodingService.shared.smartSearch(
                query: text,
                limit: PlaceSearchModel.rowLimit,
                focusLat: focus?.lat,
                focusLng: focus?.lng,
                // The whole city is the search leaving the viewport, so it runs
                // unclamped — passing the area here would undo the whole point.
                area: cityWide ? nil : area,
                cityWide: cityWide,
                downloads: downloads,
                onProgress: onProgress
            )
        }
    }

    private var schedule = SearchSchedule()
    /// The pause in progress, until the next keystroke or a tap ends it.
    private var pause: Task<Void, Never>?
    /// The search in progress. A keystroke that starts a new pause cancels it,
    /// which stops its tile work; a redemption it already sent finishes on its
    /// own and is cached (`GeocodeTokenManager.spend`, `SmartSearch.serverForward`).
    private var running: Task<Void, Never>?
    /// The query whose search ran to its end, both steps, normalised.
    private var finished: String?
    /// The map-view answer for the query on screen: the whole-city answers are
    /// added to it, the row's too.
    private var mapViewAnswer: (key: String, result: SmartSearch.Result)?
    /// The text of the search started last, as typed.
    private var lastText: String?
    /// That search was the row's tap, which downloads on any network: a retry
    /// repeats the tap, so the person does not decide twice.
    private var lastWasTap = false
    /// Watches the network while the sheet is up, to re-run a search whose
    /// download did not finish once it is back.
    private var pathMonitor: NWPathMonitor?
    private var pathWasSatisfied: Bool?

    /// Every edit of the field.
    func queryChanged(_ raw: String) {
        switch schedule.typed(raw) {
        case .clear:
            pause?.cancel()
            running?.cancel()
            running = nil
            finished = nil
            mapViewAnswer = nil
            lastText = nil
            timedOut = false
            leadingPlaces = []
            leadingCities = []
            isSearching = false
            widening = false
            moreToDownload = false
            loadingPhase = nil
            results = []
            cities = []
        case .unchanged:
            break
        case .cancelWait:
            pause?.cancel()
            if finished == SmartSearch.normalised(raw) {
                // Its answer is on screen already.
                isSearching = false
                loadingPhase = nil
            } else if running == nil {
                // Its search was replaced before it answered. Run it again at once:
                // the gateway's answer, paid for, is cached or still coming.
                start(raw.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        case .wait:
            pause?.cancel()
            running?.cancel()
            running = nil
            widening = false
            // The row is for the query on screen, not the one being typed.
            moreToDownload = false
            // Spinner up BEFORE the pause rather than after it: the window this
            // closes is precisely the one where the PREVIOUS search's empty state
            // was still on screen, captioned with the query the user is typing now.
            isSearching = true
            loadingPhase = nil
            scopedTo = nil
            timedOut = false
            pause = Task { [weak self] in
                try? await Task.sleep(for: self?.pauseLength ?? SearchSchedule.pause)
                guard !Task.isCancelled, let self, let text = self.schedule.settle() else { return }
                self.start(text)
            }
        }
    }

    /// The row on a metered network: the whole city, downloads and all. A tap is
    /// a request, so it does not wait for an unmetered network.
    func searchMore(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = mapViewAnswer, first.key == SmartSearch.normalised(text), let focus else { return }
        pause?.cancel()
        running?.cancel()
        lastText = text
        lastWasTap = true
        moreToDownload = false
        isSearching = true
        widening = true
        loadingPhase = nil
        timedOut = false
        let area = self.area
        let search = self.search
        running = Task { [weak self] in
            let wide = await search(text, focus, area, .wholeCity(.always)) { phase in
                if !Task.isCancelled { self?.loadingPhase = phase }
            }
            guard !Task.isCancelled, let self else { return }
            self.show(SmartSearch.widened(first.result, by: wide, limit: Self.rowLimit,
                                          focusLat: focus.lat, focusLng: focus.lng, query: text), for: text)
            self.finish(first.key)
        }
    }

    private func start(_ text: String) {
        running?.cancel()
        lastText = text
        lastWasTap = false
        let focus = self.focus
        let area = self.area
        let search = self.search
        let key = SmartSearch.normalised(text)
        running = Task { [weak self] in
            // A search a newer one replaced must not speak over it.
            let first = await search(text, focus, area, .mapView) { phase in
                if !Task.isCancelled { self?.loadingPhase = phase }
            }
            guard !Task.isCancelled, let self else { return }
            self.mapViewAnswer = (key, first)
            self.show(first, for: text)
            guard let focus, SmartSearch.widens(after: first, hasFocus: true) else {
                self.finish(key)
                return
            }
            self.widening = true
            self.loadingPhase = nil
            let wide = await search(text, focus, area, .wholeCity(.ifUnmetered)) { phase in
                if !Task.isCancelled { self.loadingPhase = phase }
            }
            guard !Task.isCancelled else { return }
            self.show(SmartSearch.widened(first, by: wide, limit: Self.rowLimit,
                                          focusLat: focus.lat, focusLng: focus.lng, query: text), for: text)
            self.finish(key)
        }
    }

    private func show(_ outcome: SmartSearch.Result, for text: String) {
        timedOut = outcome.timedOut
        scopedTo = outcome.scopedTo
        fromServer = outcome.fromServer
        moreToDownload = outcome.moreToDownload
        let split = SmartSearch.split(addresses: outcome.addresses, cities: outcome.cities, query: text)
        leadingPlaces = split.leadingPlaces
        leadingCities = split.leadingCities
        results = split.places
        cities = split.cities
    }

    private func finish(_ key: String) {
        running = nil
        // A download that did not finish is no answer: the same query,
        // typed again, runs again, and so does the network's return.
        finished = timedOut ? nil : key
        isSearching = false
        widening = false
        loadingPhase = nil
    }

    // MARK: - The network's return

    /// The app retries a search whose download did not finish, rather than
    /// asking the person to (the web client re-runs on `online`). The sheet
    /// starts this on appearing and stops it on going.
    func watchNetwork() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in self?.pathChanged(satisfied: satisfied) }
        }
        monitor.start(queue: DispatchQueue(label: "com.pingolin.track.placesearch.path"))
        pathMonitor = monitor
    }

    func stopWatchingNetwork() {
        pathMonitor?.cancel()
        pathMonitor = nil
        pathWasSatisfied = nil
    }

    /// A report from the monitor. Only a return counts: its first report is how
    /// the network is now, not a change.
    func pathChanged(satisfied: Bool) {
        defer { pathWasSatisfied = satisfied }
        guard satisfied, pathWasSatisfied == false else { return }
        networkReturned()
    }

    /// The network is back: a search on screen whose download did not finish
    /// runs again, both steps.
    func networkReturned() {
        guard timedOut, !isSearching, let text = lastText, SearchSchedule.isSearchable(text) else { return }
        if lastWasTap {
            searchMore(text)
            return
        }
        isSearching = true
        timedOut = false
        loadingPhase = nil
        start(text)
    }
}
