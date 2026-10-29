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
import PingolinTrackSDK
@testable import Track

/// Who may deliver the key an invitation carries (wrapped at invite time,
/// handed over by the server on accept): on a circle with records, only an
/// invitation from an owner or admin in the chain carries it, since only that
/// one counts; while the circle's records wait (not imported here, withheld,
/// forked), none does. On a circle without records, the invitation carries it
/// whatever the chain says.
final class InvitationCarriesKeyTests: XCTestCase {

    func testOnlyAnOwnersOrAdminsInvitationInTheChainCarriesTheKey() {
        typealias Manager = Track.CircleManager
        XCTAssertTrue(Manager.invitationCarriesKey(standing: .recorded, myChainRole: .owner))
        XCTAssertTrue(Manager.invitationCarriesKey(standing: .recorded, myChainRole: .admin))
        XCTAssertFalse(Manager.invitationCarriesKey(standing: .recorded, myChainRole: .member),
                       "an admin on the server's list only: the invitee waits, and the late-joiner question asks")
        XCTAssertFalse(Manager.invitationCarriesKey(standing: .recorded, myChainRole: nil))
        XCTAssertFalse(Manager.invitationCarriesKey(standing: .wait, myChainRole: .owner),
                       "records not imported here, withheld or forked")
        XCTAssertTrue(Manager.invitationCarriesKey(standing: .noRecords, myChainRole: nil), "no records: it carries the key")
    }

    /// Both invitations that carry a key ask first: a new one and a renewal.
    func testBothInvitationsThatCarryAKeyAsk() throws {
        let manager = try source("App/Managers/CircleManager.swift")
        XCTAssertTrue(manager.contains(
            "           holdsCurrentKey(for: circleId), invitationCarriesKey(circleId: circleId) {\n"))
        let renewals = try source("App/Managers/InvitationRenewals.swift")
        XCTAssertTrue(renewals.contains("""
                    if CircleManager.shared.holdsCurrentKey(for: question.circleId),
                       CircleManager.shared.invitationCarriesKey(circleId: question.circleId) {

            """))
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }
}
