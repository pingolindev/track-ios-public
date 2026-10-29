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

/// A waiting change that would sign for a member ends with
/// `PendingChangeCopy.memberLeft` when the chain's last word about them is a
/// counting removal at a version above the one this device had accepted when
/// the person decided.
final class RemovedSinceTheTapTests: XCTestCase {
    private let me = "0f0f0f0f-1111-2222-3333-444455556666"
    private let member = "1a1a1a1a-2222-3333-4444-555566667777"

    private func letIn(questionKind: String = "reset", tappedAt version: Int?) -> PendingChange {
        var change = PendingChanges.make(.letIn, account: me, circleId: "c1",
                                         inputs: .letIn(.init(memberId: member, questionKind: questionKind)),
                                         circleName: "Family", subject: "Nadia")
        change.versionAtTap = version
        return change
    }

    private func check(_ check: PendingChangeKinds.RemovalCheck, _ change: PendingChange) -> PendingRecheck? {
        PendingChangeKinds.removedSinceTheTap(check, change: change, name: "Nadia")
    }

    func testARemovalAfterTheTapEndsItWithMemberLeft() {
        let change = letIn(tappedAt: 4)
        XCTAssertEqual(check(.lastWord(removedAt: 5), change),
                       .drop(line: "Letting Nadia in wasn't done: Nadia is no longer in Family."))
    }

    /// A removal this device had accepted when the person tapped: the tap is a
    /// decision about someone already out, and its statement counts.
    func testARemovalAtOrBeforeTheTapLeavesItToRun() {
        XCTAssertNil(check(.lastWord(removedAt: 4), letIn(tappedAt: 4)))
        XCTAssertNil(check(.lastWord(removedAt: 2), letIn(tappedAt: 4)))
    }

    func testNoCountingRemovalOrNoRecordsChangesNothing() {
        XCTAssertNil(check(.lastWord(removedAt: nil), letIn(tappedAt: 1)))
        XCTAssertNil(check(.noRecords, letIn(tappedAt: nil)), "a circle with no records: nothing changes")
    }

    /// Records that can't be read here now: never a signature on a guess.
    func testAnUnreadableChainMakesItWait() {
        XCTAssertEqual(check(.unknown, letIn(tappedAt: 9)), .notYet)
    }

    /// No version kept at the tap, or an owed admission from before waiting
    /// changes kept one: any counting removal ends it.
    func testWithoutADecisionVersionAnyCountingRemovalEndsIt() {
        XCTAssertEqual(check(.lastWord(removedAt: 1), letIn(tappedAt: nil)),
                       .drop(line: "Letting Nadia in wasn't done: Nadia is no longer in Family."))
        XCTAssertNotNil(check(.lastWord(removedAt: 3), letIn(questionKind: "owed", tappedAt: 9)))
    }
}
