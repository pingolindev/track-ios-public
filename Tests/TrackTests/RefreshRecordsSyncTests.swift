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

/// The records import after a key import: what each circle's served
/// records and heads lead to, with the SDK's calls faked.
@MainActor
final class RefreshRecordsSyncTests: XCTestCase {
    private let me = "0f0f0f0f-1111-2222-3333-444455556666"
    private let member = "1a1a1a1a-2222-3333-4444-555566667777"
    private let stranger = "2b2b2b2b-2222-3333-4444-555566667777"
    private let a = "c1c1c1c1-0000-4000-8000-000000000001"
    private let b = "c1c1c1c1-0000-4000-8000-000000000002"
    private let ownKey = String(repeating: "0a", count: 32)
    private let memberKey = String(repeating: "0b", count: 32)

    final class FakeSDK: RefreshRecordsSDK {
        var since: [String: Int32] = [:]
        var recorded: Set<String> = []
        var latched: [String] = []
        var imports: [(circleId: String, records: Int, members: [RecordMemberRow], complete: Bool,
                       ownHead: SignedCircleHead?, memberHeads: [MemberHead])] = []
        var report = RefreshRecordsReport(versions: [], sealingVersion: 3, askForFreshCopy: false, forked: false,
                                          headConfirmedMembers: [], tipNamedListed: [])
        var importFails = false
        /// signer key → heads (by head hex) that verify under it, and what they say.
        var verifying: [String: [String: CircleHead]] = [:]

        func refreshHeadVersions() -> [String: Int32] { since }
        func circleHasRefreshRecords(circleId: String) -> Bool { recorded.contains(circleId) }
        func noteCircleHasRecords(circleId: String) { latched.append(circleId) }
        func signingPublicKeyHex() throws -> String { String(repeating: "0a", count: 32) }
        func verifyCircleHead(headHex: String, signatureHex: String, signerSigningPublicKeyHex: String) throws -> CircleHead? {
            verifying[signerSigningPublicKeyHex]?[headHex]
        }
        func importRecords(circleId: String, records: [SignedRefreshRecord], keyChain: [KeyChainLinkData],
                           members: [RecordMemberRow], rosterComplete: Bool, ownHead: SignedCircleHead?,
                           memberHeads: [MemberHead]) throws -> RefreshRecordsReport {
            if importFails { throw MobileError.InvalidInput(message: "no") }
            imports.append((circleId, records.count, members, rosterComplete, ownHead, memberHeads))
            return report
        }
    }

    private var sdk: FakeSDK!
    private var asked: [[String: Int32]] = []

    override func setUp() {
        super.setUp()
        sdk = FakeSDK()
        asked = []
    }

    private func hex(_ byte: String, _ count: Int) -> String { String(repeating: byte, count: count) }
    private func record(_ version: Int) -> ServedRefreshRecord {
        ServedRefreshRecord(version: version, record: hex("01", 135), signature: hex("02", 64))
    }
    private func head(_ userId: String, _ byte: String) -> ServedCircleHead {
        ServedCircleHead(userId: userId, head: hex(byte, 69), signature: hex("03", 64))
    }
    private func row(_ userId: String, confirmed: Bool, key: String?) -> RecordMemberRow {
        RecordMemberRow(userId: userId, keys: key.map { MemberKeyPair(sharingKeyHex: $0, signingKeyHex: $0) },
                        confirmed: confirmed, listed: true, listedRole: .member, statements: [],
                        personConfirmedKeys: false, serverSaysKeyless: false)
    }
    private func run(_ circles: [CircleRefreshRecords],
                     inputs: [String: RefreshRecordsSync.CircleInput]) async -> [String: RefreshRecordsSync.Outcome]? {
        await RefreshRecordsSync.run(me: me, inputs: inputs, sdk: sdk) { map in
            self.asked.append(map)
            return RefreshRecordsPage(circles: circles, more: false)
        }
    }
    private func input(_ members: [RecordMemberRow]?) -> RefreshRecordsSync.CircleInput {
        RefreshRecordsSync.CircleInput(members: members, rosterComplete: true, keyChain: [])
    }

    /// The read asks from the heads this device accepted; each circle's records
    /// go to the SDK with the member list, the account's own head, and only
    /// the heads of members this device confirms (never a stranger's, never
    /// its own as a member's).
    func testEachCircleIsImportedWithTheHeadsOfConfirmedMembersOnly() async {
        sdk.since = [a: 2]
        let members = [row(me, confirmed: true, key: ownKey), row(member, confirmed: true, key: memberKey),
                       row(stranger, confirmed: false, key: memberKey)]
        let got = await run(
            [CircleRefreshRecords(circleId: a, records: [record(3)],
                                  heads: [head(me, "04"), head(member, "05"), head(stranger, "06")], complete: true)],
            inputs: [a: input(members)])
        XCTAssertEqual(asked, [[a: 2]])
        XCTAssertEqual(sdk.imports.count, 1)
        XCTAssertEqual(sdk.imports.first?.records, 1)
        XCTAssertEqual(sdk.imports.first?.members, members)
        XCTAssertEqual(sdk.imports.first?.ownHead?.headHex, hex("04", 69))
        XCTAssertEqual(sdk.imports.first?.memberHeads.map(\.userId), [member])
        guard case .imported(let report, let heads)? = got?[a] else { return XCTFail("not imported") }
        XCTAssertEqual(report.sealingVersion, 3)
        XCTAssertEqual(heads.map(\.userId), [me, member, stranger], "every served head, for the account's own")
    }

    /// No answer, or a reply that doesn't hold together: nothing imported,
    /// nothing latched.
    func testNoAnswerChangesNothing() async {
        let got = await RefreshRecordsSync.run(me: me, inputs: [a: input([])], sdk: sdk) { _ in
            throw URLError(.timedOut)
        }
        XCTAssertNil(got)
        XCTAssertTrue(sdk.imports.isEmpty)
        XCTAssertTrue(sdk.latched.isEmpty)
    }

    /// A circle with no record served or held is legacy, unless a head that
    /// verifies proves records exist: then it is latched and waits.
    /// A head that doesn't verify, names another circle, or comes from a member
    /// this device doesn't confirm proves nothing.
    func testAVerifiedHeadLatchesACircleWithNoRecords() async {
        sdk.verifying = [
            ownKey: [hex("04", 69): CircleHead(circleId: a, userId: me, version: 2, chainHex: "")],
            memberKey: [hex("05", 69): CircleHead(circleId: b, userId: member, version: 2, chainHex: ""),
                        hex("07", 69): CircleHead(circleId: b, userId: stranger, version: 2, chainHex: "")],
        ]
        let members = [row(member, confirmed: true, key: memberKey), row(stranger, confirmed: false, key: memberKey)]
        let got = await run(
            [CircleRefreshRecords(circleId: a, records: [], heads: [head(me, "04")], complete: true),
             CircleRefreshRecords(circleId: b, records: [], heads: [head(member, "05")], complete: true)],
            inputs: [a: input(members), b: input(members)])
        XCTAssertEqual(got?[a], .latched, "the account's own head under its current key")
        XCTAssertEqual(got?[b], .latched, "a confirmed member's head under the key this device confirms")
        XCTAssertEqual(sdk.latched, [a, b])
        XCTAssertTrue(sdk.imports.isEmpty)

        sdk.latched = []
        let proves = await run(
            [CircleRefreshRecords(circleId: a, records: [], heads: [head(member, "05")], complete: true),
             CircleRefreshRecords(circleId: b, records: [], heads: [head(stranger, "07"), head(me, "09")],
                                  complete: true)],
            inputs: [a: input(members), b: input(members)])
        XCTAssertEqual(proves?[a], .legacy, "a head naming another circle")
        XCTAssertEqual(proves?[b], .legacy, "an unconfirmed member's head, and one that doesn't verify")
        XCTAssertTrue(sdk.latched.isEmpty)
    }

    /// A circle this device already holds records for is imported even when
    /// nothing new is served: its heads are compared, and a withheld chain is
    /// no way back to legacy.
    func testARecordedCircleIsImportedWithNothingNew() async {
        sdk.recorded = [a]
        let got = await run([CircleRefreshRecords(circleId: a, records: [], heads: [], complete: true)],
                            inputs: [a: input([row(me, confirmed: true, key: ownKey)])])
        guard case .imported? = got?[a] else { return XCTFail("not imported") }
        XCTAssertEqual(sdk.imports.first?.records, 0)
    }

    /// Before the circle's first roster pass, or when the SDK refuses the call,
    /// nothing is imported and nothing changes: the next pass tries again.
    func testNoRosterPassYetOrARefusalIsNotNow() async {
        let got = await run([CircleRefreshRecords(circleId: a, records: [record(1)], heads: [], complete: true),
                             CircleRefreshRecords(circleId: b, records: [record(1)], heads: [], complete: true)],
                            inputs: [a: input(nil)])
        XCTAssertEqual(got?[a], .notNow)
        XCTAssertEqual(got?[b], .notNow)
        XCTAssertTrue(sdk.imports.isEmpty)
        sdk.importFails = true
        let refused = await run([CircleRefreshRecords(circleId: a, records: [record(1)], heads: [], complete: true)],
                                inputs: [a: input([])])
        XCTAssertEqual(refused?[a], .notNow)
    }
}
