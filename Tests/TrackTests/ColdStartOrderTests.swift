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

/// A cold start shows the active circle's members without waiting for the work
/// only older data needs, and with no position stored on the phone.
///
/// WHY THIS IS WORTH TESTING
///   The map's first members-and-positions fetch is keyed on the active circle
///   (MapView's `.task(id: circleManager.activeCircle?.id)`), so the full load
///   picks the active circle as soon as the list's current keys are installed —
///   not at its very end, after the historical key import, the own-wrap signing
///   and the pseudonym-backfill POSTs — and the backfill POSTs go out together,
///   not one after another. Nothing is cached: the positions come from the
///   server. The identities recovered from before a password reset are in
///   before the early roster pass.
@MainActor
final class ColdStartOrderTests: XCTestCase {

    private func manager() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("App/Managers/CircleManager.swift"), encoding: .utf8)
    }

    /// The load, from `func loadCircles(light:)` to the next function.
    private func load() throws -> String {
        let text = try manager()
        let start = try XCTUnwrap(text.range(of: "    func loadCircles(light: Bool = false) async throws {\n"))
        let end = try XCTUnwrap(text.range(of: "\n    /// Whether this process has loaded the circle list from the server", range: start.upperBound..<text.endIndex))
        return String(text[start.lowerBound..<end.lowerBound])
    }

    func testTheActiveCircleIsPickedAsSoonAsTheListsKeysAreIn() throws {
        let body = try load()
        let installed = try XCTUnwrap(body.range(of: "        circles = fetchedCircles\n"))
        let picked = try XCTUnwrap(body.range(of: """
                var pickedEarly = false
                if activeCircle == nil, let first = Self.activeAfterLoad(nil, loaded: circles) {
                    setActiveCircle(first)
                    pickedEarly = true
        """), "picked at once")
        XCTAssertTrue(body.contains("""
                    await identitiesLoaded(identitiesLoad)
                    _ = try? await loadMembers(for: first.id)
                }
        """), "its members read at once, so the first markers come with their names")
        let historical = try XCTUnwrap(body.range(of: "let allKeys = try await api.getCircleKeys()"))
        let signing = try XCTUnwrap(body.range(of: "await signOwnUnsignedWraps(responses,"))
        let backfill = try XCTUnwrap(body.range(of: "api.backfillPseudonyms("))
        let lastCopy = try XCTUnwrap(body.range(of: "if let active = Self.activeAfterLoad(activeCircle, loaded: circles), active != activeCircle {"))
        XCTAssertLessThan(installed.lowerBound, picked.lowerBound, "with the current keys installed")
        XCTAssertLessThan(picked.lowerBound, historical.lowerBound)
        XCTAssertLessThan(picked.lowerBound, signing.lowerBound)
        XCTAssertLessThan(picked.lowerBound, backfill.lowerBound)
        XCTAssertLessThan(backfill.lowerBound, lastCopy.lowerBound, "and the loaded copy is still taken at the end")
    }

    /// The early roster pass is not display-only: it stores approvals and pins,
    /// retires the pins of everyone it can't confirm and can ask an owner or
    /// admin about them, and it confirms members against the identities
    /// recovered from before a password reset, which the SDK keeps for no
    /// launch. So they are loaded first, asked for alongside the list so it
    /// costs nothing, and never twice at once.
    func testTheRecoveredIdentitiesAreInBeforeTheEarlyRosterPass() throws {
        let body = try load()
        let started = try XCTUnwrap(body.range(of:
            "        let identitiesLoad: Task<Int, Never>? = light ? nil : Task { await self.previousIdentityLoader.ensureLoaded() }\n"))
        let list = try XCTUnwrap(body.range(of: "            let list = try await api.getCircleList()\n"))
        XCTAssertLessThan(started.lowerBound, list.lowerBound, "asked for alongside the list")
        let awaited = try XCTUnwrap(body.range(of: "            await identitiesLoaded(identitiesLoad)\n"))
        let earlyPass = try XCTUnwrap(body.range(of: "            _ = try? await loadMembers(for: first.id)\n"))
        XCTAssertLessThan(awaited.lowerBound, earlyPass.lowerBound, "in before the early pass")
        let historical = try XCTUnwrap(body.range(of: "let allKeys = try await api.getCircleKeys()"))
        let again = try XCTUnwrap(body.range(of: "                await identitiesLoaded(identitiesLoad)\n"))
        XCTAssertLessThan(again.lowerBound, historical.lowerBound, "and before the historical import")
        XCTAssertEqual(body.components(separatedBy: "previousIdentityLoader.ensureLoaded()").count - 1, 1,
                       "the load asks once, through the task started with the list")
        let text = try manager()
        XCTAssertTrue(text.contains("""
            private func identitiesLoaded(_ started: Task<Int, Never>?) async {
                if let started {
                    _ = await started.value
                } else {
                    await previousIdentityLoader.ensureLoaded()
                }
            }
        """), "the started load awaited, never a second ask beside it")
    }

    /// The early circle's positions are read once more after the members
    /// fan-out, which comes after the historical key import: a point sealed
    /// under a version from before a rotation opens at once, not at the next
    /// tick. Only on the load that picked it early.
    func testTheEarlyCirclesPositionsAreReadAgainOnceEveryKeyIsIn() throws {
        let body = try load()
        let historical = try XCTUnwrap(body.range(of: "let allKeys = try await api.getCircleKeys()"))
        let fanOut = try XCTUnwrap(body.range(of: "                    _ = try? await self.loadMembers(for: id)\n"))
        let again = try XCTUnwrap(body.range(of: """
                if pickedEarly, let activeId = activeCircle?.id {
                    _ = try? await loadMemberLocations(for: activeId)
                }
        """))
        XCTAssertLessThan(historical.lowerBound, fanOut.lowerBound)
        XCTAssertLessThan(fanOut.lowerBound, again.lowerBound)
        XCTAssertEqual(body.components(separatedBy: "pickedEarly = true").count - 1, 1)
    }

    func testTheBackfillPostsGoOutTogether() throws {
        let body = try load()
        XCTAssertTrue(body.contains("""
                    await withTaskGroup(of: Void.self) { group in
                        for backfill in backfills {
                            group.addTask {
                                do {
                                    _ = try await api.backfillPseudonyms(circleId: backfill.circleId, pseudonyms: backfill.pseudonyms)
        """))
        XCTAssertEqual(body.components(separatedBy: "api.backfillPseudonyms(").count - 1, 1)
        XCTAssertTrue(body.contains("        if !light, let userId = AuthManager.shared.userId {\n"), "full loads only")
    }

    /// No position is kept on the phone for the next start.
    func testNoPositionIsCached() throws {
        let text = try manager()
        XCTAssertFalse(text.contains("CacheStore.shared.save(memberLocations"))
        XCTAssertFalse(text.contains("forKey: \"member.locations"))
    }
}
