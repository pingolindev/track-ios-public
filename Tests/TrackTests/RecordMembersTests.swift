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

/// The member list iOS gives the SDK's refresh-record calls: the keys
/// come from the roster the pass judged; a member with no published keys
/// goes with none.
final class RecordMembersTests: XCTestCase {
    private let me = "0F0F0F0F-1111-2222-3333-444455556666"
    private let mine = MemberKeyPair(sharingKeyHex: "aa", signingKeyHex: "ab")
    private let pinnedKeys = MemberKeyPair(sharingKeyHex: "p1", signingKeyHex: "p2")
    private let recordKeys = MemberKeyPair(sharingKeyHex: "r1", signingKeyHex: "r2")
    private let statement = SignedStatementRecord(statementHex: "5151", signatureHex: "5252")

    private func candidate(_ id: String, sharing: String? = "l1", signing: String? = "l2",
                           keyVersion: Int? = 3) -> MembershipCandidate {
        MembershipCandidate(userId: id, sharingKeyHex: sharing, signingKeyHex: signing, invitation: statement,
                            admissions: [statement], keyVersion: keyVersion, accessRequested: false)
    }

    private func rows(_ candidates: [MembershipCandidate], verdicts: [String: MembershipVerdict],
                      complete: Bool = true, pinned: [String: MemberKeyPair] = [:],
                      receiveOnly: [String: MemberKeyPair] = [:], chosen: Set<String> = []) -> [String: RecordMemberRow] {
        let got = RecordMembers.rows(
            me: me, myKeys: mine,
            candidates: Dictionary(candidates.map { ($0.userId, $0) }, uniquingKeysWith: { a, _ in a }),
            roles: Dictionary(candidates.map { ($0.userId, CircleRole.member) }, uniquingKeysWith: { a, _ in a }),
            complete: complete, verdicts: verdicts, receiveOnlyKeys: receiveOnly,
            pinned: { pinned[$0] }, chosen: { chosen.contains($0) })
        return Dictionary(got.map { ($0.userId, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// A confirmed member goes with the pins; a receive-only one with the
    /// approval record's keys; one confirmed in this very pass and not pinned
    /// yet, and one not confirmed, with the roster's (the same roster).
    func testEachMembersKeysComeFromThePinsTheRecordOrTheRoster() {
        let got = rows(
            [candidate("pinned"), candidate("receiveOnly"), candidate("fresh"), candidate("stranger")],
            verdicts: ["pinned": .confirmed(.statement), "receiveOnly": .confirmed(.kind2),
                       "fresh": .confirmed(.ownAction), "stranger": .unconfirmable],
            pinned: ["pinned": pinnedKeys], receiveOnly: ["receiveOnly": recordKeys])
        XCTAssertEqual(got["pinned"]?.keys, pinnedKeys)
        XCTAssertEqual(got["pinned"]?.confirmed, true)
        XCTAssertEqual(got["receiveOnly"]?.keys, recordKeys)
        XCTAssertEqual(got["receiveOnly"]?.confirmed, true)
        XCTAssertEqual(got["fresh"]?.keys, MemberKeyPair(sharingKeyHex: "l1", signingKeyHex: "l2"))
        XCTAssertEqual(got["fresh"]?.confirmed, true)
        XCTAssertEqual(got["stranger"]?.keys, MemberKeyPair(sharingKeyHex: "l1", signingKeyHex: "l2"))
        XCTAssertEqual(got["stranger"]?.confirmed, false)
        XCTAssertEqual(got["stranger"]?.statements, [statement, statement], "as served; the SDK verifies them")
    }

    /// A receive-only member is never given the pins, even when some exist.
    func testAReceiveOnlyMemberNeverGoesWithPins() {
        let got = rows([candidate("receiveOnly")], verdicts: ["receiveOnly": .confirmed(.ownKind2)],
                       pinned: ["receiveOnly": pinnedKeys], receiveOnly: ["receiveOnly": recordKeys])
        XCTAssertEqual(got["receiveOnly"]?.keys, recordKeys)
    }

    /// This account goes with ITS OWN keys from this device, confirmed, never
    /// the roster's row; and it is there even if the roster didn't show it.
    func testThisAccountGoesWithItsOwnKeys() {
        let listedMe = rows([candidate(me, sharing: "ff", signing: "fe")], verdicts: [:])
        XCTAssertEqual(listedMe[me]?.keys, mine)
        XCTAssertEqual(listedMe[me]?.confirmed, true)
        XCTAssertEqual(listedMe[me]?.listed, true)
        let unlisted = rows([candidate("other")], verdicts: [:])
        XCTAssertEqual(unlisted[me]?.keys, mine)
        XCTAssertEqual(unlisted[me]?.confirmed, true)
        XCTAssertEqual(unlisted[me]?.listed, false)
    }

    /// No published keys: no keys, never confirmed (the SDK refuses a
    /// confirmed member with none), but listed: present, and nothing more.
    func testAMemberWithNoKeysIsListedAndNothingMore() {
        let got = rows([candidate("keyless", sharing: nil, signing: nil), candidate("half", signing: ""),
                        candidate("confirmedKeyless", sharing: nil, signing: nil)],
                       verdicts: ["keyless": .unconfirmable, "confirmedKeyless": .confirmed(.statement)])
        for id in ["keyless", "half", "confirmedKeyless"] {
            XCTAssertNil(got[id]?.keys, id)
            XCTAssertEqual(got[id]?.confirmed, false, id)
            XCTAssertEqual(got[id]?.listed, true, id)
        }
    }

    /// An incomplete roster lists nobody, so no seen departure counts on it.
    func testAnIncompleteRosterListsNobody() {
        let got = rows([candidate(me), candidate("pinned")], verdicts: ["pinned": .confirmed(.statement)],
                       complete: false, pinned: ["pinned": pinnedKeys])
        XCTAssertTrue(got.values.allSatisfy { !$0.listed })
        XCTAssertEqual(got["pinned"]?.confirmed, true)
    }

    /// Person-confirmed keys: only for a member this device's person chose,
    /// with the keys the person confirmed (the pin, or the receive-only
    /// record): never the roster's keys, never this account, never someone
    /// not confirmed.
    func testPersonConfirmedKeysOnlyForTheKeysThePersonConfirmed() {
        let got = rows(
            [candidate("chosenPinned"), candidate("chosenFresh"), candidate("statementPinned"),
             candidate("chosenReceiveOnly"), candidate("chosenStranger"), candidate(me)],
            verdicts: ["chosenPinned": .confirmed(.ownAction), "chosenFresh": .confirmed(.ownAction),
                       "statementPinned": .confirmed(.statement), "chosenReceiveOnly": .confirmed(.ownKind2),
                       "chosenStranger": .unconfirmable],
            pinned: ["chosenPinned": pinnedKeys, "statementPinned": pinnedKeys],
            receiveOnly: ["chosenReceiveOnly": recordKeys],
            chosen: ["chosenPinned", "chosenFresh", "chosenReceiveOnly", "chosenStranger", me])
        XCTAssertEqual(got["chosenPinned"]?.personConfirmedKeys, true)
        XCTAssertEqual(got["chosenReceiveOnly"]?.personConfirmedKeys, true)
        XCTAssertEqual(got["chosenFresh"]?.personConfirmedKeys, false, "not pinned yet: the roster's keys")
        XCTAssertEqual(got["statementPinned"]?.personConfirmedKeys, false, "not chosen here")
        XCTAssertEqual(got["chosenStranger"]?.personConfirmedKeys, false)
        XCTAssertEqual(got[me]?.personConfirmedKeys, false)
    }

    /// The SDK's delivery rule: the server says they hold no copy
    /// yet.
    func testServerSaysKeylessIsTheRowsMissingCopy() {
        let got = rows([candidate("new", keyVersion: nil), candidate("old", keyVersion: 2)], verdicts: [:])
        XCTAssertEqual(got["new"]?.serverSaysKeyless, true)
        XCTAssertEqual(got["old"]?.serverSaysKeyless, false)
    }
}
