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

/// A launch that couldn't read /auth/me keeps the session and shows the app,
/// but has no user yet (so no guardian line) and nothing of Track's can start
/// (no stream, no tracking). So /auth/me is read again until it answers
/// (`LaunchRetry`), sooner when the network comes back or the app comes to the
/// front (`LaunchRetryWait`), and the launch then finishes as an online one does
/// (`AuthManager.completeLaunch`) — not only at the next launch, however soon
/// the network came back.
@MainActor
final class OfflineLaunchTests: XCTestCase {

    private struct Definitive: Error {}

    private let user = User(id: "4c8a8a8e-5b3c-4d0a-9a1e-6f2b7c9d0e11", email: "g@example.test",
                            displayName: nil, publicKey: nil, createdAt: Date(), updatedAt: nil)

    /// A run of `LaunchRetry` whose reads answer `answers` in turn, recorded.
    private final class Run {
        var events: [String] = []
        var completed: [String] = []
        var expired = 0
        var reads = 0
    }

    private func retry(_ run: Run, answers: [Result<User, Error>], current: @escaping (Run) -> Bool = { _ in true })
        -> LaunchRetry {
        var left = answers
        return LaunchRetry(
            read: {
                run.reads += 1
                run.events.append("read")
                guard !left.isEmpty else { throw URLError(.notConnectedToInternet) }
                return try left.removeFirst().get()
            },
            // Never more than a few rounds, so a fault that loops can't hang the suite.
            isCurrent: { run.reads < 8 && current(run) },
            next: { $0 is Definitive ? .expire : .again },
            wait: { run.events.append("wait \(Int($0))") },
            complete: { run.completed.append($0.id); run.events.append("complete") },
            expire: { run.expired += 1; run.events.append("expire") }
        )
    }

    // MARK: - The read again

    /// Read after a wait, again after a longer one, until it answers; then the
    /// launch finishes, once, with what it served.
    func testAReadThatFailsIsTriedAgainUntilItAnswers() async {
        let run = Run()
        await retry(run, answers: [.failure(URLError(.notConnectedToInternet)), .failure(URLError(.timedOut)),
                                   .success(user)]).run()
        XCTAssertEqual(run.events, ["wait 5", "read", "wait 10", "read", "wait 20", "read", "complete"])
        XCTAssertEqual(run.completed, [user.id])
        XCTAssertEqual(run.expired, 0)
    }

    func testTheWaitGrowsToAMinuteAndStaysThere() {
        XCTAssertEqual((0...7).map { LaunchRetry.delay(attempt: $0) }, [5, 10, 20, 40, 60, 60, 60, 60])
        XCTAssertEqual(LaunchRetry.delay(attempt: -1), 5)
    }

    /// A definitive refusal ends the session, as the launch's own would have,
    /// and nothing finishes.
    func testADefinitiveRefusalEndsTheSessionAndNothingElse() async {
        let run = Run()
        await retry(run, answers: [.failure(Definitive()), .success(user)]).run()
        XCTAssertEqual(run.events, ["wait 5", "read", "expire"])
        XCTAssertEqual(run.completed, [])
    }

    /// A sign-out or an ended session stops it: no read after, nothing finished.
    func testASessionThatEndedStopsTheReadAgain() async {
        let run = Run()
        await retry(run, answers: [.failure(URLError(.notConnectedToInternet)), .success(user)],
                    current: { $0.reads < 1 }).run()
        XCTAssertEqual(run.events, ["wait 5", "read"])
        XCTAssertEqual(run.completed, [])
        XCTAssertEqual(run.expired, 0)
    }

    /// A session that ended during the wait is not read for at all.
    func testASessionThatEndedDuringTheWaitIsNotRead() async {
        let run = Run()
        await retry(run, answers: [.success(user)], current: { _ in false }).run()
        XCTAssertEqual(run.events, ["wait 5"])
        XCTAssertEqual(run.reads, 0)
    }

    /// An answer that arrives for a session already ended is not used.
    func testAnAnswerForASessionThatEndedIsNotUsed() async {
        let run = Run()
        await retry(run, answers: [.success(user)], current: { $0.reads == 0 }).run()
        XCTAssertEqual(run.events, ["wait 5", "read"])
        XCTAssertEqual(run.completed, [])
    }

    /// Nor is a refusal: the person who signed out meanwhile isn't told they
    /// were signed out, and nothing ends a second time.
    func testARefusalForASessionThatEndedIsNotActedOn() async {
        let run = Run()
        await retry(run, answers: [.failure(Definitive())], current: { $0.reads == 0 }).run()
        XCTAssertEqual(run.events, ["wait 5", "read"])
        XCTAssertEqual(run.expired, 0)
    }

    // MARK: - The wait

    /// A wake ends the wait in progress, and counts once.
    func testAWakeEndsTheWaitAndCountsOnce() async {
        var ticks = 0
        var waiting: LaunchRetryWait?
        waiting = LaunchRetryWait(tick: {
            ticks += 1
            if ticks == 2 { waiting?.wake() }
        }, inBackground: { false })
        await waiting?.wait(5)
        XCTAssertEqual(ticks, 2, "woken in its second second")
        await waiting?.wait(3)
        XCTAssertEqual(ticks, 5, "the next wait is whole")
    }

    /// A wake while a read is under way ends the wait after it: the read may
    /// have failed just before the network came back.
    func testAWakeDuringAReadEndsTheNextWait() async {
        var ticks = 0
        let waiting = LaunchRetryWait(tick: { ticks += 1 }, inBackground: { false })
        waiting.wake()
        await waiting.wait(60)
        XCTAssertEqual(ticks, 0)
        await waiting.wait(2)
        XCTAssertEqual(ticks, 2)
    }

    /// A wait's clock and the app's state, as the tests below drive them.
    private final class Clock {
        var ticks = 0
        var asked = 0
        var background = false
        var ended = false
        var ends = 0
    }

    private func waitDriven(by clock: Clock) -> LaunchRetryWait {
        LaunchRetryWait(tick: { clock.ticks += 1 }, inBackground: { clock.asked += 1; return clock.background })
    }

    private func settle(until done: () -> Bool = { false }) async {
        var spins = 0
        while !done(), spins < 200 {
            await Task.yield()
            spins += 1
        }
    }

    /// Nothing in the background: no tick, and the wait doesn't end there, not
    /// even for the network coming back, so nothing is read. The app coming to
    /// the front wakes it, and the read is at once.
    func testNothingCountsOrEndsInTheBackground() async {
        let clock = Clock()
        clock.background = true
        let waiting = waitDriven(by: clock)
        let waitTask = Task { await waiting.wait(5); clock.ended = true }
        await settle { clock.asked > 0 }
        await settle()
        XCTAssertGreaterThan(clock.asked, 0, "the wait is under way")
        XCTAssertEqual(clock.ticks, 0, "no tick in the background")
        XCTAssertFalse(clock.ended)
        waiting.wake()
        await settle()
        XCTAssertFalse(clock.ended, "the network back, still in the background: no read")
        clock.background = false
        waiting.wake()
        await settle { clock.ended }
        XCTAssertTrue(clock.ended, "the app in front: read at once")
        XCTAssertEqual(clock.ticks, 0)
        waitTask.cancel()
    }

    /// Sent to the background in the middle of a wait: the count stops there,
    /// and the app coming back ends it.
    func testTheBackgroundStopsTheCount() async {
        let clock = Clock()
        let waiting = LaunchRetryWait(tick: {
            clock.ticks += 1
            if clock.ticks == 2 { clock.background = true }
        }, inBackground: { clock.background })
        let waitTask = Task { await waiting.wait(5); clock.ended = true }
        await settle { clock.ticks == 2 }
        await settle()
        XCTAssertEqual(clock.ticks, 2)
        XCTAssertFalse(clock.ended)
        clock.background = false
        waiting.wake()
        await settle { clock.ended }
        XCTAssertTrue(clock.ended)
        XCTAssertEqual(clock.ticks, 2)
        waitTask.cancel()
    }

    /// A wait held in the background ends when its task is cancelled.
    func testAWaitHeldInTheBackgroundEndsOnCancel() async {
        let clock = Clock()
        clock.background = true
        let waiting = waitDriven(by: clock)
        let waitTask = Task { await waiting.wait(5); clock.ended = true }
        await settle { clock.asked > 0 }
        await settle()
        XCTAssertFalse(clock.ended)
        waitTask.cancel()
        await settle { clock.ended }
        XCTAssertTrue(clock.ended)
        XCTAssertEqual(clock.ticks, 0)
    }

    /// The network coming back and the app coming to the front can wake a held
    /// wait one right after the other: it is resumed once (twice would crash the
    /// app), and the wait ends once.
    func testTwoWakesTogetherEndAHeldWaitOnce() async {
        let clock = Clock()
        clock.background = true
        let waiting = waitDriven(by: clock)
        let waitTask = Task { await waiting.wait(5); clock.ends += 1 }
        await settle { clock.asked > 0 }
        await settle()
        XCTAssertEqual(clock.ends, 0)
        clock.background = false
        waiting.wake()
        waiting.wake()
        await settle { clock.ends > 0 }
        await settle()
        XCTAssertEqual(clock.ends, 1)
        XCTAssertEqual(clock.ticks, 0)
        waitTask.cancel()
    }

    /// Outside tests, "in the background" is the app's own state.
    func testTheBackgroundIsTheAppsState() throws {
        let retry = try source("App/Managers/LaunchRetry.swift")
        XCTAssertTrue(retry.contains(
            "inBackground: @escaping @MainActor () -> Bool = { UIApplication.shared.applicationState == .background }) {\n"))
        XCTAssertTrue(try source("App/Managers/AuthManager.swift").contains("        let waiting = LaunchRetryWait()\n"))
    }

    /// The network wakes it when a path turns satisfied; never on the monitor's
    /// first report, which only says how things stand.
    func testOnlyAPathThatTurnsSatisfiedWakes() {
        XCTAssertTrue(LaunchRetryWait.wakes(from: false, to: true))
        XCTAssertFalse(LaunchRetryWait.wakes(from: nil, to: true), "the first report")
        XCTAssertFalse(LaunchRetryWait.wakes(from: nil, to: false))
        XCTAssertFalse(LaunchRetryWait.wakes(from: true, to: true))
        XCTAssertFalse(LaunchRetryWait.wakes(from: true, to: false))
        XCTAssertFalse(LaunchRetryWait.wakes(from: false, to: false))
    }

    // MARK: - Wiring (source)

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func body(_ text: String, from start: String, to end: String) throws -> String {
        let from = try XCTUnwrap(text.range(of: start), start)
        let to = try XCTUnwrap(text.range(of: end, range: from.upperBound..<text.endIndex), end)
        return String(text[from.lowerBound..<to.lowerBound])
    }

    /// The launch's read finishes in `completeLaunch`; a transient failure keeps
    /// the session, shows the app, and reads again.
    func testTheLaunchFinishesInOnePlaceAndATransientFailureReadsAgain() throws {
        let auth = try source("App/Managers/AuthManager.swift")
        XCTAssertTrue(auth.contains("""
                    do {
                        let user = try await api.getMe()
                        await completeLaunch(served: user, since: epoch)
                    } catch {
            """))
        XCTAssertTrue(auth.contains("""
                            if endSessionForKeyStore() { return }
                            isAuthenticated = true
                            ErrorBanner.shared.post(error)
                            retryLaunchRead(since: epoch)
                            return
            """))
        XCTAssertEqual(auth.components(separatedBy: "completeLaunch(served: user, since: epoch)").count - 1, 2,
                       "the launch's read and the read again")
    }

    /// The read again belongs to the session the launch began in, ends it on a
    /// definitive refusal as the launch would, and finishes in `completeLaunch`.
    func testTheReadAgainIsBoundToItsSessionAndFinishesTheLaunch() throws {
        let auth = try source("App/Managers/AuthManager.swift")
        let start = try body(auth, from: "    private func retryLaunchRead(since epoch: Int) {",
                             to: "    private func startLaunchRetryWakes(")
        XCTAssertTrue(start.contains("""
                    guard launchRetryTask == nil, let me = userId else { return }
                    let waiting = LaunchRetryWait()
                    startLaunchRetryWakes(waiting)

            """))
        XCTAssertTrue(start.contains("            read: { [api = self.api] in try await api.getMe() },\n"))
        XCTAssertTrue(start.contains("            isCurrent: { [weak self] in self?.stillSignedIn(as: me, since: epoch) ?? false },\n"))
        XCTAssertTrue(start.contains("            next: { Self.isSessionDefinitivelyExpired($0) ? .expire : .again },\n"))
        XCTAssertTrue(start.contains("            wait: { await waiting.wait($0) },\n"))
        XCTAssertTrue(start.contains("            complete: { [weak self] user in await self?.completeLaunch(served: user, since: epoch) },\n"))
        XCTAssertTrue(start.contains("""
                        expire: { [weak self] in
                            self?.expireSession()
                            // Signed in with location access, it was sharing until now.
                            self?.signedOutNotAsked(wasSharing: LocationService.shared.hasLocationPermission)
                        }
            """))
        XCTAssertTrue(start.contains("            await retry.run()\n            self?.endLaunchRetry()\n"))
    }

    /// The network coming back and the app coming to the front wake the wait;
    /// both end with the read again.
    func testTheNetworkComingBackOrTheAppInFrontWakesTheWait() throws {
        let auth = try source("App/Managers/AuthManager.swift")
        let wakes = try body(auth, from: "    private func startLaunchRetryWakes(_ waiting: LaunchRetryWait) {",
                             to: "    private func endLaunchRetry() {")
        XCTAssertTrue(wakes.contains("""
                        let satisfied = path.status == .satisfied
                        defer { last.satisfied = satisfied }
                        guard LaunchRetryWait.wakes(from: last.satisfied, to: satisfied) else { return }
                        Task { @MainActor in waiting.wake() }
            """))
        XCTAssertTrue(wakes.contains("""
                        forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
                    ) { _ in
                        Task { @MainActor in waiting.wake() }
            """))
        let end = try body(auth, from: "    private func endLaunchRetry() {", to: "    /// Everything of Track's a restored session starts")
        XCTAssertTrue(end.contains("launchRetryTask = nil"))
        XCTAssertTrue(end.contains("launchRetryPath?.cancel()"))
        XCTAssertTrue(end.contains("NotificationCenter.default.removeObserver(observer)"))
    }

    /// What the late finish must still do, as an online launch does: the
    /// sharing key back in the SDK before anything of Track's starts, and this
    /// device registered before the stream (ingest refuses a device it doesn't
    /// know: `DeviceRegistrar`).
    func testTheLateFinishRestoresTheSharingKeyAndRegistersTheDevice() throws {
        let auth = try source("App/Managers/AuthManager.swift")
        let complete = try body(auth, from: "    private func completeLaunch(served user: User, since epoch: Int) async {",
                                to: "    // MARK: - A launch that couldn't read /auth/me")
        let key = try XCTUnwrap(complete.range(of: """
                    if let sharingPriv = keychain.getString(for: .sharingPrivateKey) {
                        do {
                            try cryptoManager.importPrivateKey(privateKeyBase64: sharingPriv)
            """))
        let start = try XCTUnwrap(complete.range(of: "        await startTrackServices(me: me, since: epoch)\n"))
        XCTAssertLessThan(key.upperBound, start.lowerBound)
        let services = try body(auth, from: "    private func startTrackServices(me: String, prompting: Bool = true, since epoch: Int) async {",
                                to: "    /// Mirrors the Android app's SessionExpiredException gate.")
        let registered = try XCTUnwrap(services.range(of: "        await SelfKeyManager.ensure()\n        await DeviceRegistrar.ensure()\n"))
        let stream = try XCTUnwrap(services.range(of: "            SDKLocationStreamer.shared.start(\n"))
        XCTAssertLessThan(registered.upperBound, stream.lowerBound)
    }

    /// Track starts once a session: a launch finished late doesn't start it
    /// again after an approval or a verified address did (`unlockTrack`), which
    /// can happen first while the read again waits.
    func testTrackStartsOnceASession() throws {
        let auth = try source("App/Managers/AuthManager.swift")
        XCTAssertTrue(auth.contains("""
                    guard RegistrationGate.allows(registration, trackAccess: trackAccess) else { return }
                    // Started meanwhile by an approval or a verified address (`unlockTrack`),
                    // when this finishes a launch that couldn't read /auth/me at first.
                    guard trackStartedEpoch != epoch else { return }
                    await startTrackServices(me: me, since: epoch)
                }
            """))
        XCTAssertTrue(auth.contains("""
                private func startTrackServices(me: String, prompting: Bool = true, since epoch: Int) async {
                    trackStartedEpoch = epoch

            """))
        XCTAssertEqual(auth.components(separatedBy: "trackStartedEpoch = ").count - 1, 1, "set where it starts, only")
    }

    /// The map observes the account, so the guardian line follows it.
    func testTheMapObservesTheAccount() throws {
        let map = try source("App/Views/Map/MapView.swift")
        XCTAssertTrue(map.contains("    @StateObject private var authManager = AuthManager.shared\n"))
        XCTAssertTrue(map.contains("            if authManager.guardian.managed {\n"))
        XCTAssertTrue(map.contains("        guard let named = authManager.guardian.handoverDate,\n"))
    }
}
