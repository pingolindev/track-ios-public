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

import XCTest
@testable import Track
import PingolinTrackSDK

/// The sheet's model runs SearchSchedule against the clock. It must never show
/// a replaced search's answer; it re-runs a query whose search was cut off when
/// the user comes back to it, and empties the list on a query too short to
/// search. The pause is shortened here; PlaceSearchScheduleTests pins it.
@MainActor
final class PlaceSearchModelTests: XCTestCase {

    /// A fake search. A map-view search is recorded in `asked` and held until the
    /// test opens its gate; a whole-city one is recorded in `wide` and answers at
    /// once with `wideAnswer`.
    private final class Fake {
        var asked: [String] = []
        var wide: [(text: String, downloads: SmartSearch.Downloads)] = []
        var wideAnswer = SmartSearch.Result(addresses: [], cities: [], scopedTo: nil)
        /// The map-view answers still to give, first first; then a row named after the query.
        var mapAnswers: [SmartSearch.Result] = []
        var gates: [String: SearchGate] = [:]
        func gate(_ text: String) -> SearchGate {
            if let gate = gates[text] { return gate }
            let gate = SearchGate()
            gates[text] = gate
            return gate
        }
    }

    /// A row for `text`, named so it is never exactly the query: a row whose whole
    /// name is the query leads the list (`leadingPlaces`), and these tests read
    /// the rows below it, `results`.
    private static func row(_ text: String) -> GeocodingResult {
        GeocodingResult(text: text, lat: 37.7666, lng: -120.8471, resultType: "address", confidence: 1.0,
                        name: "\(text) Shop", city: nil, state: nil, postcode: nil, country: nil, address: nil)
    }

    private func makeModel(_ fake: Fake) -> PlaceSearchModel {
        PlaceSearchModel(pause: .milliseconds(30)) { text, _, _, reach, _ in
            if case .wholeCity(let downloads) = reach {
                fake.wide.append((text, downloads))
                return fake.wideAnswer
            }
            fake.asked.append(text)
            await fake.gate(text).wait()
            if !fake.mapAnswers.isEmpty { return fake.mapAnswers.removeFirst() }
            return SmartSearch.Result(addresses: [Self.row(text)], cities: [], scopedTo: nil)
        }
    }

    /// Waits (up to 2 s) for `condition`, yielding to the model's tasks.
    private func until(_ condition: () -> Bool, _ what: String) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), what)
    }

    func testAReplacedSearchsAnswerIsNeverShown() async {
        let fake = Fake()
        let model = makeModel(fake)
        model.queryChanged("pizza")
        await until({ fake.asked == ["pizza"] }, "pizza is searched after the pause")
        model.queryChanged("pizzas")
        await fake.gate("pizza").open()
        try? await Task.sleep(for: .milliseconds(10))
        XCTAssertTrue(model.results.isEmpty, "pizza's answer arrived after 'pizzas' was typed: not shown")
        XCTAssertTrue(model.isSearching)
        await until({ fake.asked == ["pizza", "pizzas"] }, "pizzas is searched after its pause")
        await fake.gate("pizzas").open()
        await until({ model.results.first?.text == "pizzas" }, "pizzas' answer is shown")
        XCTAssertFalse(model.isSearching)
    }

    func testASearchCutOffBeforeItAnsweredRunsAgainWhenItsQueryComesBack() async {
        let fake = Fake()
        let model = makeModel(fake)
        model.queryChanged("pizza")
        await until({ fake.asked == ["pizza"] }, "pizza is searched")
        model.queryChanged("pizzas")   // cuts pizza's search off
        model.queryChanged("pizza")    // back before pizzas' pause ran out
        await until({ fake.asked == ["pizza", "pizza"] }, "pizza runs again at once, with no pause")
        await fake.gate("pizza").open()
        await until({ model.results.first?.text == "pizza" }, "and its answer is shown")
        XCTAssertFalse(model.isSearching)
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(fake.asked, ["pizza", "pizza"], "pizzas never settled")
    }

    func testBackToTheQueryOnScreenSearchesNothing() async {
        let fake = Fake()
        let model = makeModel(fake)
        await fake.gate("pizza").open()
        model.queryChanged("pizza")
        await until({ model.results.first?.text == "pizza" }, "pizza's answer is shown")
        model.queryChanged("pizza ")
        model.queryChanged("Pizza")
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(fake.asked, ["pizza"])
        XCTAssertFalse(model.isSearching)
    }

    func testAQueryTooShortEmptiesTheList() async {
        let fake = Fake()
        let model = makeModel(fake)
        await fake.gate("pizza").open()
        model.queryChanged("pizza")
        await until({ !model.results.isEmpty }, "pizza's answer is shown")
        model.queryChanged("pi")
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertFalse(model.isSearching)
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(fake.asked, ["pizza"], "two characters are never searched")
    }

    // MARK: - The whole city, by itself

    func testTheWholeCityFollowsTheMapViewSearchByItself() async {
        let fake = Fake()
        fake.wideAnswer = SmartSearch.Result(addresses: [Self.row("pizza across town")], cities: [], scopedTo: nil)
        let model = makeModel(fake)
        model.focus = (37.7666, -120.8471)
        await fake.gate("pizza").open()
        model.queryChanged("pizza")
        await until({ model.results.count == 2 }, "the map view's row and the city's")
        XCTAssertEqual(fake.wide.map { $0.text }, ["pizza"])
        XCTAssertEqual(fake.wide.first?.downloads, .ifUnmetered, "unasked, so it waits for an unmetered network")
        XCTAssertFalse(model.isSearching)
        XCTAssertFalse(model.moreToDownload)
    }

    func testOnAMeteredNetworkTheRowOffersTheRestAndATapFetchesIt() async {
        let fake = Fake()
        fake.wideAnswer = SmartSearch.Result(addresses: [], cities: [], scopedTo: nil, moreToDownload: true)
        let model = makeModel(fake)
        model.focus = (37.7666, -120.8471)
        await fake.gate("pizza").open()
        model.queryChanged("pizza")
        await until({ model.moreToDownload }, "the city's missing tiles are offered")
        XCTAssertFalse(model.isSearching)

        fake.wideAnswer = SmartSearch.Result(addresses: [Self.row("pizza across town")], cities: [], scopedTo: nil)
        model.searchMore("pizza")
        await until({ model.results.count == 2 }, "the tap's rows are added to the map view's")
        XCTAssertEqual(fake.wide.map { $0.downloads }, [.ifUnmetered, .always], "a tap is a request")
        XCTAssertFalse(model.moreToDownload)
        XCTAssertEqual(fake.asked, ["pizza"], "the map view is not searched again")
    }

    func testANewPauseTakesTheRowAway() async {
        let fake = Fake()
        fake.wideAnswer = SmartSearch.Result(addresses: [], cities: [], scopedTo: nil, moreToDownload: true)
        let model = makeModel(fake)
        model.focus = (37.7666, -120.8471)
        await fake.gate("pizza").open()
        model.queryChanged("pizza")
        await until({ model.moreToDownload }, "offered for pizza")
        model.queryChanged("pizzas")
        XCTAssertFalse(model.moreToDownload, "the row was pizza's, not the query being typed")
        model.searchMore("pizzas")
        XCTAssertEqual(fake.wide.count, 1, "and a tap for a query not searched yet does nothing")
        await fake.gate("pizzas").open()
    }

    func testNoWholeCityWithoutAMap() async {
        let fake = Fake()
        let model = makeModel(fake)
        await fake.gate("pizza").open()
        model.queryChanged("pizza")
        await until({ !model.results.isEmpty }, "pizza's answer")
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(fake.wide.isEmpty, "there is no city under a map that has not laid out")
    }

    // MARK: - The exact rows first

    func testTheExactRowsLeadAndAreNotListedTwice() async {
        let fake = Fake()
        let hamburg = CityResult(geonameId: 2_911_298, name: "Hamburg", asciiName: "Hamburg", countryCode: "DE",
                                 admin1: "04", population: 1_845_229, lat: 53.5507, lng: 9.9930, tileId: "",
                                 tileIds: [], hasShard: false)
        let marys = GeocodingResult(text: "Hamburger Mary's, 1582 Folsom St", lat: 37.77, lng: -122.413,
                                    resultType: "venue", confidence: 1.0, name: "Hamburger Mary's",
                                    city: nil, state: nil, postcode: nil, country: nil, address: nil)
        fake.mapAnswers = [SmartSearch.Result(addresses: [marys], cities: [hamburg], scopedTo: nil)]
        let model = makeModel(fake)
        await fake.gate("hamburg").open()
        model.queryChanged("hamburg")
        await until({ !model.leadingCities.isEmpty }, "Hamburg leads")
        XCTAssertEqual(model.leadingCities.map(\.countryCode), ["DE"])
        XCTAssertTrue(model.cities.isEmpty, "and is not listed again under Other locations")
        XCTAssertEqual(model.results.first?.name, "Hamburger Mary's", "the places stay, below it")
        XCTAssertEqual(model.places.map(\.name), ["Hamburger Mary's"], "a list without towns has every place")
        XCTAssertTrue(model.hasRows)
    }

    /// Add Place lists `places`: a place named exactly as typed leads the list
    /// there too, instead of dropping out of it.
    func testAnExactPlaceStaysInAddPlacesList() async {
        let fake = Fake()
        let marys = GeocodingResult(text: "Hamburger Mary's, 1582 Folsom St", lat: 37.77, lng: -122.413,
                                    resultType: "venue", confidence: 1.0, name: "Hamburger Mary's",
                                    city: nil, state: nil, postcode: nil, country: nil, address: nil)
        let haven = GeocodingResult(text: "Hamburger Haven, 800 Clement St", lat: 37.78, lng: -122.46,
                                    resultType: "venue", confidence: 1.0, name: "Hamburger Haven",
                                    city: nil, state: nil, postcode: nil, country: nil, address: nil)
        fake.mapAnswers = [SmartSearch.Result(addresses: [haven, marys], cities: [], scopedTo: nil)]
        let model = makeModel(fake)
        await fake.gate("Hamburger Mary's").open()
        model.queryChanged("Hamburger Mary's")
        await until({ !model.leadingPlaces.isEmpty }, "the exact place leads")
        XCTAssertEqual(model.places.map(\.name), ["Hamburger Mary's", "Hamburger Haven"],
                       "exact first, and nothing dropped")
    }

    // MARK: - A download that did not finish

    private var stalled: SmartSearch.Result {
        SmartSearch.Result(addresses: [], cities: [], scopedTo: nil, timedOut: true)
    }

    func testTheNetworksReturnRunsAStalledSearchAgain() async {
        let fake = Fake()
        fake.mapAnswers = [stalled]
        let model = makeModel(fake)
        await fake.gate("pizza").open()
        model.queryChanged("pizza")
        await until({ model.timedOut && !model.isSearching }, "the download did not finish")
        model.pathChanged(satisfied: true)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(fake.asked, ["pizza"], "the monitor's first report is the network as it is, not its return")
        model.pathChanged(satisfied: false)
        model.pathChanged(satisfied: true)
        await until({ fake.asked == ["pizza", "pizza"] }, "back online: the search runs again by itself")
        await until({ model.results.first?.text == "pizza" }, "and its answer is shown")
        XCTAssertFalse(model.timedOut)
    }

    func testTheSameQueryTypedAgainRunsAStalledSearchAgain() async {
        let fake = Fake()
        fake.mapAnswers = [stalled]
        let model = makeModel(fake)
        await fake.gate("pizza").open()
        model.queryChanged("pizza")
        await until({ model.timedOut && !model.isSearching }, "the download did not finish")
        model.queryChanged("pizza ")
        await until({ fake.asked == ["pizza", "pizza"] }, "a stalled search is no answer: the next pause runs it again")
        await until({ model.results.first?.text == "pizza" }, "and its answer is shown")
    }

    /// A tapped "uses more data" search that stalled is retried as the tap it
    /// was: the person decided once.
    func testTheNetworksReturnRepeatsAStalledTapAsATap() async {
        let fake = Fake()
        fake.wideAnswer = SmartSearch.Result(addresses: [], cities: [], scopedTo: nil, moreToDownload: true)
        let model = makeModel(fake)
        model.focus = (37.7666, -120.8471)
        await fake.gate("pizza").open()
        model.queryChanged("pizza")
        await until({ model.moreToDownload }, "the row is offered")
        fake.wideAnswer = stalled
        model.searchMore("pizza")
        await until({ model.timedOut && !model.isSearching }, "the tapped download did not finish")
        fake.wideAnswer = SmartSearch.Result(addresses: [Self.row("pizza across town")], cities: [], scopedTo: nil)
        model.pathChanged(satisfied: false)
        model.pathChanged(satisfied: true)
        await until({ model.results.count == 2 }, "back online: the tap runs again, and its rows are added")
        XCTAssertEqual(fake.wide.map { $0.downloads }, [.ifUnmetered, .always, .always],
                       "the retry downloads like the tap it repeats")
        XCTAssertEqual(fake.asked, ["pizza"], "the map view is not searched again")
    }

    func testTheNetworksReturnLeavesAnAnsweredSearchAlone() async {
        let fake = Fake()
        let model = makeModel(fake)
        await fake.gate("pizza").open()
        model.queryChanged("pizza")
        await until({ !model.results.isEmpty }, "pizza's answer")
        model.pathChanged(satisfied: false)
        model.pathChanged(satisfied: true)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(fake.asked, ["pizza"])
    }
}
