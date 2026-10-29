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

/// "Blocked people" in Settings: the words, what goes over the wire, and the
/// rules of the field.
///
/// The bodies below are shaped as the SERVER sends them, not built from this
/// app's own types: a fixture made from the app's own struct passes whatever
/// the server calls its fields.
final class BlockedPeopleTests: XCTestCase {

    private func person(_ email: String) -> BlockedPerson {
        BlockedPerson(blockedEmail: email, createdAt: nil)
    }

    // MARK: - The words

    /// The exact user-facing words, pinned: a change to them is deliberate
    /// and changes this test too.
    func testTheWordsAreTheApprovedOnes() {
        XCTAssertEqual(BlockedPeople.title, "Blocked people")
        XCTAssertEqual(BlockedPeople.description, "People you block can't invite you to a circle, even after changing their email address. They are not notified.")
        XCTAssertEqual(BlockedPeople.emailLabel, "Email address")
        XCTAssertEqual(BlockedPeople.block, "Block")
        XCTAssertEqual(BlockedPeople.unblock, "Unblock")
        XCTAssertEqual(BlockedPeople.empty, "You haven't blocked anyone.")
        // A full list.
        XCTAssertEqual(BlockedPeople.full, "Your list of blocked people is full. Unblock someone to add another.")
    }

    /// A full list is known by the server's code for it, and by nothing else:
    /// not its status, and never its words.
    func testAFullListIsKnownByItsCode() {
        XCTAssertEqual(BlockedPeople.listFullCode, "blocked_people_limit")
        XCTAssertTrue(BlockedPeople.isListFull(APIError(code: "http_409", message: "anything", errorCode: "blocked_people_limit")))
        XCTAssertFalse(BlockedPeople.isListFull(APIError(code: "http_409", message: BlockedPeople.full)))
        XCTAssertFalse(BlockedPeople.isListFull(APIError(code: "http_409", message: "x", errorCode: "invite_already_exists")))
        XCTAssertFalse(BlockedPeople.isListFull(APIError(code: "blocked_people_limit", message: "x")))
        XCTAssertFalse(BlockedPeople.isListFull(URLError(.notConnectedToInternet)))
    }

    func testWhatIsSaidOfABlockThatDidNotGoThrough() {
        let full = APIError(code: "http_409", message: "the server's own words", errorCode: "blocked_people_limit")
        XCTAssertEqual(BlockedPeople.whyNotBlocked(full), "Your list of blocked people is full. Unblock someone to add another.")
        // Anything else: the app's own line for it, and never the server's words.
        let other = APIError(code: "http_409", message: "the server's own words", errorCode: "something_else")
        XCTAssertEqual(BlockedPeople.whyNotBlocked(other), other.plainLine)
        XCTAssertFalse(BlockedPeople.whyNotBlocked(other).contains("server's own"))
        let offline = URLError(.notConnectedToInternet)
        XCTAssertEqual(BlockedPeople.whyNotBlocked(offline), (offline as Error).plainText)
    }

    func testAnUnblockButtonSaysWhomToSomeoneWhoCannotSeeItsRow() {
        XCTAssertEqual(BlockedPeople.unblockLabel(for: person("sam@example.test")), "Unblock sam@example.test")
    }

    /// The screen shows those constants and no other sentence of its own; a
    /// failure is said in the app's words (`plainText`), never the server's.
    func testTheScreenUsesThoseWordsAndTheAppsOwnForAFailure() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let screen = try String(contentsOf: root.appendingPathComponent("App/Views/Settings/BlockedPeopleView.swift"), encoding: .utf8)
        for constant in ["BlockedPeople.description", "BlockedPeople.emailLabel", "BlockedPeople.block", "BlockedPeople.unblock",
                         "BlockedPeople.empty", "BlockedPeople.title", "BlockedPeople.unblockLabel(for: person)"] {
            XCTAssertTrue(screen.contains(constant), constant)
        }
        // An unblock that fails; a block that fails says a full list in its own words.
        XCTAssertEqual(screen.components(separatedBy: "failure = error.plainText").count - 1, 1, "an unblock")
        XCTAssertEqual(screen.components(separatedBy: "failure = BlockedPeople.whyNotBlocked(error)").count - 1, 1, "a block")
        XCTAssertFalse(screen.contains(".localizedDescription"))
        XCTAssertFalse(screen.contains(".message"))
        // Tried again by itself until the list loads: nobody is asked to press "retry".
        XCTAssertTrue(screen.contains(".task { await RetryClock.untilDone { await model.load() } }"))

        let settings = try String(contentsOf: root.appendingPathComponent("App/Views/Settings/SettingsView.swift"), encoding: .utf8)
        XCTAssertTrue(settings.contains("NavigationLink(destination: BlockedPeopleView()) {"))
        XCTAssertTrue(settings.contains("Text(BlockedPeople.title)"))
    }

    // MARK: - The wire

    func testTheListReadsEachAddressFromBlockedEmail() throws {
        let body = Data(#"{"success":true,"data":[{"blocked_email":"adam@example.test","created_at":"2026-10-07T13:00:00.123456Z"},{"blocked_email":"zoe+circles@example.co.uk","created_at":"2026-10-07T13:05:00Z"}]}"#.utf8)
        let people: [BlockedPerson] = try APIService.decodeResponseBody(body)
        XCTAssertEqual(people.map(\.blockedEmail), ["adam@example.test", "zoe+circles@example.co.uk"])
        XCTAssertEqual(people[0].createdAt, "2026-10-07T13:00:00.123456Z")
    }

    func testNobodyBlockedIsAnEmptyListNotAFailure() throws {
        let people: [BlockedPerson] = try APIService.decodeResponseBody(Data(#"{"success":true,"data":[]}"#.utf8))
        XCTAssertEqual(people, [])
    }

    func testARowWithoutItsTimeIsStillARow() throws {
        let body = Data(#"{"success":true,"data":[{"blocked_email":"adam@example.test"}]}"#.utf8)
        let people: [BlockedPerson] = try APIService.decodeResponseBody(body)
        XCTAssertEqual(people, [person("adam@example.test")])
    }

    func testARowWithoutItsAddressIsNotReadAsNobody() {
        let body = Data(#"{"success":true,"data":[{"email":"adam@example.test","created_at":"2026-10-07T13:00:00Z"}]}"#.utf8)
        XCTAssertThrowsError(try APIService.decodeResponseBody(body) as [BlockedPerson])
    }

    func testABlockSendsTheAddressUnderTheNameEmail() throws {
        let sent = try APIService.encodeRequestBody(BlockPersonRequest(email: "Sam+circles@Example.test"))
        XCTAssertEqual(String(decoding: sent, as: UTF8.self), #"{"email":"Sam+circles@Example.test"}"#)
    }

    /// What the server answers to a block and to an unblock that it took.
    func testTheAnswerToABlockOrAnUnblockDecodes() throws {
        let _: EmptyResponse = try APIService.decodeResponseBody(Data(#"{"success":true,"data":null}"#.utf8))
    }

    /// A full list: 409 with its code. The words are the server's and are not
    /// shown; the code is what the app goes by.
    func testAFullListIsAnErrorThatCarriesItsCode() {
        let body = Data(#"{"success":false,"error":"Your list of blocked people is full. Unblock someone to add another.","error_code":"blocked_people_limit"}"#.utf8)
        XCTAssertThrowsError(try APIService.decodeResponseBody(body) as EmptyResponse) { error in
            XCTAssertEqual((error as? APIError)?.errorCode, "blocked_people_limit")
        }
    }

    // MARK: - Where the address travels

    /// An address in a request PATH is what a proxy's access log keeps: every
    /// address a person unblocked, in the clear, for as long as the log is
    /// kept. Both requests carry it in the body, and neither path has a place
    /// for one.
    func testNeitherPathHoldsAnAddressOrAPlaceForOne() {
        XCTAssertEqual(APIService.blockPersonPath, "/api/v1/invites/block")
        XCTAssertEqual(APIService.unblockPersonPath, "/api/v1/invites/unblock")
        for path in [APIService.blockPersonPath, APIService.unblockPersonPath] {
            XCTAssertNil(path.rangeOfCharacter(from: CharacterSet(charactersIn: "@%{}?#\\")), path)
            XCTAssertFalse(path.hasSuffix("/"), path)
        }
    }

    func testAnUnblockSendsTheAddressInItsBodyWhateverItHolds() throws {
        for address in ["sam@example.test", "test-user1+tag2@example.test", "a?b#c%2Fd@example.test", "ü@example.test"] {
            let sent = try APIService.encodeRequestBody(BlockPersonRequest(email: address))
            let read = try JSONSerialization.jsonObject(with: sent) as? [String: String]
            XCTAssertEqual(read, ["email": address], address)
        }
    }

    /// The request the screen makes is the one this file tests: by its body, at that path.
    func testTheUnblockIsAPostToItsOwnPathWithTheBlocksBody() throws {
        let source = try String(contentsOfFile: Self.repoFile("App/Services/APIService.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("try await post(path: Self.unblockPersonPath, body: BlockPersonRequest(email: email))"))
        XCTAssertTrue(source.contains("try await post(path: Self.blockPersonPath, body: BlockPersonRequest(email: email))"))
        XCTAssertFalse(source.contains("/api/v1/invites/block/"), "no path continues past the route's own name")
    }

    private static func repoFile(_ relative: String) -> String {
        // …/Tests/TrackTests/BlockedPeopleTests.swift → the repository's root.
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(relative).path
    }

    // MARK: - The address to block

    func testAnAddressThatIsOneAndIsNotBlockedYetIsReady() {
        XCTAssertEqual(BlockedPeople.addressToBlock("sam@example.test", blocked: [], ownEmail: "me@example.test"), "sam@example.test")
        XCTAssertEqual(BlockedPeople.addressToBlock("  sam@example.test \n", blocked: [], ownEmail: nil), "sam@example.test", "trimmed")
    }

    func testWhatIsNotAnAddressIsNotReady() {
        for typed in ["", "   ", "sam", "sam@", "@example.test", "sam@example", "sam @example.test", "a@b@c.test"] {
            XCTAssertNil(BlockedPeople.addressToBlock(typed, blocked: [], ownEmail: nil), typed)
        }
    }

    func testOnesOwnAddressIsNotReadyInAnyCase() {
        XCTAssertNil(BlockedPeople.addressToBlock("Me@Example.test", blocked: [], ownEmail: "me@example.test"))
        XCTAssertNil(BlockedPeople.addressToBlock("me@example.test", blocked: [], ownEmail: "  ME@example.test "))
        XCTAssertEqual(BlockedPeople.addressToBlock("me2@example.test", blocked: [], ownEmail: "me@example.test"), "me2@example.test")
    }

    func testAnAddressAlreadyOnTheListIsNotReadyInAnyCase() {
        let blocked = [person("sam@example.test")]
        XCTAssertNil(BlockedPeople.addressToBlock("SAM@example.test", blocked: blocked, ownEmail: nil))
        XCTAssertEqual(BlockedPeople.addressToBlock("sam2@example.test", blocked: blocked, ownEmail: nil), "sam2@example.test")
    }

    /// A list that has not been read is not an empty one: nothing is blocked
    /// on a guess of what is already there.
    func testNothingIsReadyUntilTheListHasBeenRead() {
        XCTAssertNil(BlockedPeople.addressToBlock("sam@example.test", blocked: nil, ownEmail: nil))
    }

    func testTheListIsShownByAddressWhateverTheCase() {
        // A capital in the MIDDLE of the alphabet: ordered by code point, "Mia" would come before
        // "adam" (every capital sorts before every small letter), so the two orders differ here.
        let shown = BlockedPeople.inListOrder([person("zoe@example.test"), person("Mia@example.test"), person("adam@example.test")])
        XCTAssertEqual(shown.map(\.blockedEmail), ["adam@example.test", "Mia@example.test", "zoe@example.test"])
    }

    func testARowIsTheSamePersonWhateverTheCase() {
        XCTAssertEqual(person("Sam@Example.test").id, person("sam@example.test").id)
    }
}

/// The screen's state, with the three requests handed in.
@MainActor
final class BlockedPeopleViewModelTests: XCTestCase {

    private struct Offline: Error {}

    /// A server that keeps a list, and can be told to fail.
    private final class Server {
        var people: [String] = []
        var listFails = false
        var blockFails = false
        /// The list holds as many as it may: a block is refused with the server's code for that.
        var listIsFull = false
        var unblockFails = false
        /// The list answers as it was BEFORE the last block (a replica a moment behind).
        var listLags = false
        private var beforeLastBlock: [String] = []

        // What the calls and the test share. The calls are plain async closures,
        // so they run off the main actor while the test runs on it: these are
        // read and written under `lock`. The hold could otherwise be lost: a
        // `letTheBlockGo()` between the block's `asked.append` and its setting
        // `held` would resume nothing, the block would then wait for good, and
        // the suite would hang (a test run may have no per-test timeout).
        private let lock = NSLock()
        private var holding = false
        private var holdTaken = false
        private var released = false
        private var held: CheckedContinuation<Void, Never>?
        private var askedSoFar: [String] = []

        /// When set, the next block waits until the test lets it go (`letTheBlockGo`).
        var holdBlocks: Bool {
            get { lock.withLock { holding } }
            set { lock.withLock { holding = newValue } }
        }

        var asked: [String] { lock.withLock { askedSoFar } }

        /// A block is waiting at the hold now.
        var aBlockIsHeld: Bool { lock.withLock { held != nil } }

        /// Lets the held block go: now if it is waiting, else as soon as it gets
        /// there. Once, either way.
        func letTheBlockGo() {
            let waiting: CheckedContinuation<Void, Never>? = lock.withLock {
                defer { held = nil }
                if held == nil { released = true }
                return held
            }
            waiting?.resume()
        }

        private func ask(_ what: String) {
            lock.withLock { askedSoFar.append(what) }
        }

        /// Only ONE block waits. A second one made meanwhile (which the screen must
        /// not send) goes straight through and is seen in `asked`: held too, it
        /// would have taken the first one's place and the test would never have ended.
        private func holdIfAsked() async {
            let waits: Bool = lock.withLock {
                guard holding, !holdTaken else { return false }
                holdTaken = true
                return true
            }
            guard waits else { return }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let go: Bool = lock.withLock {
                    if released {
                        released = false
                        return true
                    }
                    held = continuation
                    return false
                }
                if go { continuation.resume() }
            }
            lock.withLock { holdTaken = false }
        }

        var calls: BlockedPeopleViewModel.Calls {
            BlockedPeopleViewModel.Calls(
                list: { [unowned self] in
                    self.ask("list")
                    if self.listFails { throw Offline() }
                    return (self.listLags ? self.beforeLastBlock : self.people).map { BlockedPerson(blockedEmail: $0, createdAt: nil) }
                },
                block: { [unowned self] email in
                    self.ask("block \(email)")
                    await self.holdIfAsked()
                    if self.blockFails { throw Offline() }
                    if self.listIsFull {
                        throw APIError(code: "http_409", message: "the server's own words", errorCode: "blocked_people_limit")
                    }
                    self.beforeLastBlock = self.people
                    self.people.append(email.lowercased())
                },
                unblock: { [unowned self] email in
                    self.ask("unblock \(email)")
                    if self.unblockFails { throw Offline() }
                    self.people.removeAll { $0 == email.lowercased() }
                }
            )
        }
    }

    private func model(_ server: Server, own: String? = "me@example.test") -> BlockedPeopleViewModel {
        BlockedPeopleViewModel(calls: server.calls, ownEmail: { own })
    }

    func testUntilTheListIsReadThereIsNoListAndNothingCanBeBlocked() async {
        let server = Server()
        server.listFails = true
        let m = model(server)
        m.typed = "sam@example.test"
        XCTAssertNil(m.people)
        XCTAssertFalse(m.canBlock)
        let loaded = await m.load()
        XCTAssertFalse(loaded, "the screen tries again by itself")
        XCTAssertNil(m.people, "a list that could not be read is not an empty one")
        XCTAssertFalse(m.canBlock)
        await m.blockTyped()
        XCTAssertEqual(server.asked, ["list"], "nothing was sent")
    }

    func testTheListIsReadAndAnAddressCanThenBeBlocked() async {
        let server = Server()
        server.people = ["zoe@example.test"]
        let m = model(server)
        let loaded = await m.load()
        XCTAssertTrue(loaded)
        XCTAssertEqual(m.people?.map(\.blockedEmail), ["zoe@example.test"])
        m.typed = " Sam@example.test "
        XCTAssertTrue(m.canBlock)
        await m.blockTyped()
        XCTAssertEqual(server.asked, ["list", "block Sam@example.test", "list"])
        XCTAssertEqual(m.people?.map(\.blockedEmail).sorted(), ["sam@example.test", "zoe@example.test"])
        XCTAssertEqual(m.typed, "", "the field is emptied once the server took it")
        XCTAssertNil(m.failure)
    }

    func testABlockThatFailsKeepsWhatWasTypedAndSaysSoInTheAppsWords() async {
        let server = Server()
        let m = model(server)
        await m.load()
        server.blockFails = true
        m.typed = "sam@example.test"
        await m.blockTyped()
        XCTAssertEqual(m.typed, "sam@example.test")
        XCTAssertEqual(m.people, [])
        XCTAssertEqual(m.failure, (Offline() as Error).plainText)
        XCTAssertFalse(m.busy)
        // The next attempt clears what was said.
        server.blockFails = false
        await m.blockTyped()
        XCTAssertNil(m.failure)
        XCTAssertEqual(m.people?.map(\.blockedEmail), ["sam@example.test"])
    }

    /// A block of one address too many is not said as a failure like any
    /// other: it says what it is, and what to do.
    func testAFullListSaysSoKeepsWhatWasTypedAndIsClearedByTheNextRequest() async {
        let server = Server()
        server.people = ["adam@example.test"]
        let m = model(server)
        await m.load()
        server.listIsFull = true
        m.typed = "sam@example.test"
        await m.blockTyped()
        XCTAssertEqual(m.failure, "Your list of blocked people is full. Unblock someone to add another.")
        XCTAssertEqual(m.typed, "sam@example.test")
        XCTAssertEqual(m.people?.map(\.blockedEmail), ["adam@example.test"])
        XCTAssertFalse(m.busy)

        // Unblocking someone makes room, and stops it being said.
        server.listIsFull = false
        await m.unblock(BlockedPerson(blockedEmail: "adam@example.test", createdAt: nil))
        XCTAssertNil(m.failure)
        await m.blockTyped()
        XCTAssertNil(m.failure)
        XCTAssertEqual(m.people?.map(\.blockedEmail), ["sam@example.test"])
    }

    /// The server took the block: the address is on the list whatever the
    /// reading that follows says.
    func testABlockTheServerTookIsOnTheListEvenWhenTheReadingAfterItFailsOrLags() async {
        let failing = Server()
        failing.people = ["zoe@example.test"]
        let m = model(failing)
        await m.load()
        failing.listFails = true
        m.typed = "sam@example.test"
        await m.blockTyped()
        XCTAssertEqual(m.people?.map(\.blockedEmail).sorted(), ["sam@example.test", "zoe@example.test"])

        let lagging = Server()
        lagging.people = ["zoe@example.test"]
        let n = model(lagging)
        await n.load()
        lagging.listLags = true
        n.typed = "Sam@example.test"
        await n.blockTyped()
        XCTAssertEqual(n.people?.map(\.blockedEmail).sorted(), ["sam@example.test", "zoe@example.test"])
    }

    func testOnesOwnAddressAndOneAlreadyBlockedAreNotSent() async {
        let server = Server()
        server.people = ["zoe@example.test"]
        let m = model(server, own: "me@example.test")
        await m.load()
        for typed in ["ME@example.test", "Zoe@Example.test", "not an address"] {
            m.typed = typed
            XCTAssertFalse(m.canBlock, typed)
            await m.blockTyped()
        }
        XCTAssertEqual(server.asked, ["list"])
    }

    /// One request at a time: while a block is on its way the button is off,
    /// and neither a second block nor an unblock is sent.
    func testWhileABlockIsOnItsWayNothingMoreIsSent() async {
        let server = Server()
        server.people = ["zoe@example.test"]
        let m = model(server)
        await m.load()
        server.holdBlocks = true
        m.typed = "sam@example.test"
        let first = Task { await m.blockTyped() }
        // Until the request has been made and is waiting: up to 5 s on a busy
        // machine. Should it never get there, the release below still lets it
        // through, so a failure here fails, and never hangs the suite.
        for _ in 0..<500 where !server.aBlockIsHeld { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(server.aBlockIsHeld, "the block is waiting at the hold")
        XCTAssertEqual(server.asked, ["list", "block sam@example.test"])
        XCTAssertTrue(m.busy)
        XCTAssertFalse(m.canBlock, "the button is off while one is on its way")

        m.typed = "kim@example.test"
        XCTAssertNotNil(m.addressReady, "it is an address that could be blocked")
        XCTAssertFalse(m.canBlock)
        await m.blockTyped()
        await m.unblock(BlockedPerson(blockedEmail: "zoe@example.test", createdAt: nil))
        XCTAssertEqual(server.asked, ["list", "block sam@example.test"], "neither was sent")
        XCTAssertEqual(m.people?.map(\.blockedEmail), ["zoe@example.test"])

        server.holdBlocks = false
        server.letTheBlockGo()
        await first.value
        XCTAssertFalse(m.busy)
        XCTAssertEqual(m.people?.map(\.blockedEmail).sorted(), ["sam@example.test", "zoe@example.test"])
        // The field was emptied when the server took the first; the next address can be sent.
        XCTAssertEqual(m.typed, "")
        m.typed = "kim@example.test"
        XCTAssertTrue(m.canBlock)
    }

    /// The stub's own race, pinned: a release that comes before the block has
    /// reached its hold still lets it through. Otherwise it would resume
    /// nothing, and the block would wait forever, hanging the suite.
    func testAReleaseBeforeTheBlockReachesItsHoldStillLetsItThrough() async {
        let server = Server()
        let m = model(server)
        await m.load()
        server.holdBlocks = true
        server.letTheBlockGo()
        m.typed = "sam@example.test"
        await m.blockTyped()
        XCTAssertEqual(server.asked, ["list", "block sam@example.test", "list"], "it went through, and the list was read again")
        XCTAssertFalse(m.busy)
        XCTAssertFalse(server.aBlockIsHeld)
        XCTAssertEqual(m.people?.map(\.blockedEmail), ["sam@example.test"])
    }

    func testAnUnblockTakesThePersonOffTheListOnceTheServerTookIt() async {
        let server = Server()
        server.people = ["sam@example.test", "zoe@example.test"]
        let m = model(server)
        await m.load()
        await m.unblock(BlockedPerson(blockedEmail: "sam@example.test", createdAt: nil))
        XCTAssertEqual(server.asked.last, "unblock sam@example.test")
        XCTAssertEqual(m.people?.map(\.blockedEmail), ["zoe@example.test"])
        XCTAssertNil(m.failure)
    }

    /// The address goes to the server exactly as the LIST gave it. (The server
    /// keeps lower case; a row it once stored otherwise is still its row.)
    func testAnUnblockSendsTheAddressAsTheListGaveIt() async {
        let server = Server()
        server.people = ["Sam@Example.test"]
        let m = model(server)
        await m.load()
        guard let listed = m.people?.first else { return XCTFail("the list was read") }
        await m.unblock(listed)
        XCTAssertEqual(server.asked.last, "unblock Sam@Example.test")
        XCTAssertEqual(m.people, [])
    }

    func testAnUnblockThatFailsLeavesThePersonOnTheListAndSaysSo() async {
        let server = Server()
        server.people = ["sam@example.test"]
        let m = model(server)
        await m.load()
        server.unblockFails = true
        await m.unblock(BlockedPerson(blockedEmail: "sam@example.test", createdAt: nil))
        XCTAssertEqual(m.people?.map(\.blockedEmail), ["sam@example.test"])
        XCTAssertEqual(m.failure, (Offline() as Error).plainText)
        XCTAssertFalse(m.busy)
    }
}
