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

/// A member's new "Paused" or "Location sharing off" shows on an iPhone within
/// one foreground tick.
///
/// WHY THIS IS WORTH TESTING
///   The status comes with the member's roster row, and the whole circle list
///   is read only every 180 s — minutes late for a status the web shows within
///   seconds. So the active circle's roster is read on every 20 s tick, for its
///   members' sharing only. That is one GET; who is in the circle, names, roles
///   and keys stay with the full load and its roster pass.
@MainActor
final class MemberSharingRefreshTests: XCTestCase {

    private let circle = "c0ffee00-0000-4000-8000-000000000001"
    private let ana = "a0000000-0000-4000-8000-00000000000a"
    private let ben = "b0000000-0000-4000-8000-00000000000b"
    private let cleo = "c1e00000-0000-4000-8000-00000000000c"

    private func row(_ userId: String, _ extra: String = "") throws -> CircleMemberResponse {
        let json = """
        {"user_id":"\(userId)","role":"member","status":"active",
         "encrypted_circle_key":{"nonce":"00","ciphertext":"00"},"ephemeral_public_key":"00",
         "can_see_history":true,"can_see_realtime":true,"joined_day_bucket":20000\(extra)}
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(CircleMemberResponse.self, from: Data(json.utf8))
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    // MARK: - The cadence

    func testEveryTickReadsTheActiveCirclesMembersAndADueListReadsThemAll() {
        XCTAssertEqual(ForegroundRefreshCadence.membersRead(circlesDue: false, activeCircleId: circle),
                       .activeCircle(circle), "between circle-list loads: the active circle's roster")
        XCTAssertEqual(ForegroundRefreshCadence.membersRead(circlesDue: true, activeCircleId: circle),
                       .everyCircle, "a due list reads every roster, the active one included")
        XCTAssertEqual(ForegroundRefreshCadence.membersRead(circlesDue: true, activeCircleId: nil), .everyCircle)
        XCTAssertEqual(ForegroundRefreshCadence.membersRead(circlesDue: false, activeCircleId: nil), .noCircle)
        // The circle list itself keeps its few minutes.
        XCTAssertEqual(ForegroundRefreshCadence.circlesInterval, 180)
    }

    func testTheLoopReadsWhatTheCadenceSays() throws {
        let tabs = try source("App/Views/MainTabView.swift")
        XCTAssertTrue(tabs.contains("""
                        switch ForegroundRefreshCadence.membersRead(
                            circlesDue: ForegroundRefreshCadence.circlesAreDue(lastRefreshAt: circlesRefreshedAt, now: now),
                            activeCircleId: circleManager.activeCircle?.id
                        ) {
                        case .everyCircle:
                            try? await circleManager.loadCircles(light: true)
                            circlesRefreshedAt = now
                        case .activeCircle(let id):
                            try? await circleManager.refreshMemberSharing(for: id)
                        case .noCircle:
                            break
                        }
        """))
        // Inside the foreground-only loop, ahead of the locations it gates.
        let loop = try XCTUnwrap(tabs.range(of: "guard scenePhase == .active else { return }"))
        let read = try XCTUnwrap(tabs.range(of: "try? await circleManager.refreshMemberSharing(for: id)"))
        let locations = try XCTUnwrap(tabs.range(of: "try? await circleManager.loadMemberLocations(for: activeId)"))
        XCTAssertLessThan(loop.lowerBound, read.lowerBound)
        XCTAssertLessThan(read.lowerBound, locations.lowerBound, "the roster's sharing first: it hides a paused member's marker")
    }

    // MARK: - The sharing-only refresh

    func testTheRowsSetEachListedMembersSharing() throws {
        let listed = [try row(ana).toModel(in: circle), try row(ben, #","location_sharing":"paused","sharing_paused_until":null"#).toModel(in: circle)]
        XCTAssertEqual(listed[0].sharing(), .on)
        let rows = [
            try row(ana, #","location_sharing":"paused","sharing_paused_until":"2030-01-01T00:00:00+00:00""#),
            try row(ben, #","location_sharing":"on","sharing_paused_until":null"#),
        ]
        let updated = CircleManager.withSharing(of: rows, on: listed)
        XCTAssertEqual(updated.map(\.userId), [ana, ben])
        XCTAssertEqual(updated[0].locationSharing, "paused")
        XCTAssertEqual(updated[0].sharingPausedUntil, ISO8601DateFormatter().date(from: "2030-01-01T00:00:00Z"))
        XCTAssertEqual(updated[1].sharing(), .on, "a resume shows as soon as it is read")
        XCTAssertNil(updated[1].sharingPausedUntil)
    }

    /// Nobody is added or dropped, and nothing else about a member changes.
    func testOnlyTheSharingOfMembersAlreadyListedChanges() throws {
        // Held under another spelling of the id: matched by its one form.
        let ana0 = CircleMember(circleId: circle, userId: ana.uppercased(), displayName: "Ana", role: .admin,
                                canSeeRealtime: true, canSeeHistory: true, canRotateKeys: true,
                                joinedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let listed = [ana0, try row(ben, #","location_sharing":"off""#).toModel(in: circle)]
        // Cleo is new to the rows and Ben is missing from them.
        let rows = [try row(ana, #","location_sharing":"off""#), try row(cleo)]
        let updated = CircleManager.withSharing(of: rows, on: listed)
        XCTAssertEqual(updated.map(\.userId), [ana.uppercased(), ben], "a join or a departure is the full load's to judge")
        // Reported above; indexing a shorter list would crash the test host.
        guard updated.count == 2 else { return }
        XCTAssertEqual(updated[0].sharing(), .off, "matched in any spelling of the id")
        XCTAssertEqual(updated[0].displayName, "Ana")
        XCTAssertEqual(updated[0].role, .admin)
        XCTAssertEqual(updated[1].sharing(), .off, "a member the rows don't name keeps what it had")
        XCTAssertEqual(CircleManager.withSharing(of: [], on: listed), listed)
    }

    /// The refresh writes only the two fields, for the account that asked, and
    /// prunes nothing on a refusal: `loadMembers` prunes a circle on a 404, and
    /// a replica answering a moment behind must not take the active circle away
    /// every 20 s.
    func testTheRefreshChangesNothingButSharing() throws {
        let manager = try source("App/Managers/CircleManager.swift")
        let start = try XCTUnwrap(manager.range(of: "    func refreshMemberSharing(for circleId: String) async throws {\n"))
        let end = try XCTUnwrap(manager.range(of: "    func loadMembers(for circleId: String) async throws {\n"))
        let body = String(manager[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("guard !CanonicalId.isPersonalSlot(circleId) else { return }"))
        XCTAssertTrue(body.contains("""
                let account = AuthManager.shared.userId
                let roster = try await api.getCircleRoster(circleId: circleId)
                // Another account signed in meanwhile: these rows are not its circle's.
                guard CanonicalId.same(AuthManager.shared.userId, account) else { return }
        """))
        XCTAssertFalse(body.contains("pruneLocalCircle"), "a refusal prunes nothing here")
        XCTAssertTrue(body.contains("if updated != listed { rosters[circleId] = updated }"), "no publish when nothing changed")
        XCTAssertTrue(body.contains("if updated != listed { members[circleId] = updated }"))
        XCTAssertTrue(body.contains("updated.locationSharing = row.locationSharing\n"))
        XCTAssertTrue(body.contains("updated.sharingPausedUntil = MemberSharingStatus.wireDate(row.sharingPausedUntil)\n"))
    }
}
