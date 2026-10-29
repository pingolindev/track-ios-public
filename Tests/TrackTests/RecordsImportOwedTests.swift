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

/// A circle no records import has decided in this process stands `.wait`:
/// nobody who joins it is given its key, its invitations carry none, and its
/// security refreshes wait. A circle made here is imported right after it is
/// made; any other that owes an import gets one from a light pass, after that
/// pass's rosters, at most once per retry time, and never one an import
/// decided (latched or forked waits as decided).
@MainActor
final class RecordsImportOwedTests: XCTestCase {
    typealias Manager = Track.CircleManager

    private struct Party {
        let userId = UUID().uuidString.lowercased()
        let sdk = CryptoManager()
        let keys: MemberKeyPair

        init() {
            func hex(_ b64: String) -> String { Data(base64Encoded: b64)!.map { String(format: "%02x", $0) }.joined() }
            keys = MemberKeyPair(sharingKeyHex: hex(sdk.generateKeypair().publicKey),
                                 signingKeyHex: hex(sdk.generateSigningKeypair().verifyingKeyB64))
        }
    }

    /// A circle id spelt otherwise than its key, as a server may send it.
    private let circle = "C1C1C1C1-0000-4000-8000-0000000000A1"
    private var key: String { CanonicalId.key(circle) }
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func owing(_ state: Manager.RecordsState?, id: String? = nil, holdsKey: Bool = true) -> [String] {
        Manager.circlesOwingRecordsImport([id ?? circle], states: state.map { [key: $0] } ?? [:],
                                          holdsKey: { _ in holdsKey })
    }

    /// Only a circle no import has decided owes one, looked up by its key in
    /// any spelling; never one an import decided, the personal key's slot, or
    /// a circle this phone holds no key for.
    func testOnlyACircleNoImportDecidedOwesOne() {
        XCTAssertEqual(owing(nil), [circle], "no import has decided it: it stands .wait")
        XCTAssertEqual(Manager.standing(nil, hasRecords: true), .wait)
        XCTAssertEqual(Manager.standing(nil, hasRecords: false), .wait, "no records, and no import said legacy yet")
        XCTAssertEqual(owing(.latched), [], "withheld: it waits for its records, as decided")
        XCTAssertEqual(owing(.imported(forked: true)), [], "forked: it waits, as decided")
        XCTAssertEqual(owing(.imported(forked: false)), [])
        XCTAssertEqual(owing(.legacy), [])
        XCTAssertEqual(owing(.latched, id: circle.lowercased()), [], "any spelling finds its state")
        XCTAssertEqual(owing(nil, id: CanonicalId.personalSlot), [], "the personal key's slot has no records")
        XCTAssertEqual(owing(nil, id: "00000000000000000000000000000000"), [], "in any spelling")
        XCTAssertEqual(owing(nil, holdsKey: false), [], "no key here: the install of its key runs the import")
    }

    /// After an import that leaves a circle owing one, the next waits 30 s,
    /// then twice as long each time, at most 15 minutes; a circle that owes
    /// none any more (decided, or gone) starts afresh.
    func testTheRetryTimeDoublesUpToItsLongestAndEndsWhenDecided() {
        XCTAssertEqual((1...8).map(Manager.RecordsImportRetry.delay(after:)), [30, 60, 120, 240, 480, 900, 900, 900])
        var retry = Manager.RecordsImportRetry()
        XCTAssertTrue(retry.due(circle, now: start), "no import yet")
        retry.imported(owing: [circle], at: start)
        XCTAssertFalse(retry.due(circle, now: start + 29))
        XCTAssertFalse(retry.due(circle.lowercased(), now: start + 29), "by its key")
        XCTAssertTrue(retry.due(circle, now: start + 30))
        retry.imported(owing: [circle.lowercased()], at: start + 30)
        XCTAssertEqual(retry.waits[key]?.imports, 2)
        XCTAssertFalse(retry.due(circle, now: start + 89))
        XCTAssertTrue(retry.due(circle, now: start + 90))
        retry.imported(owing: [], at: start + 90)
        XCTAssertTrue(retry.waits.isEmpty, "decided: no wait left")
        XCTAssertTrue(retry.due(circle, now: start + 90))
        retry.imported(owing: [circle], at: start + 100)
        XCTAssertEqual(retry.waits[key]?.imports, 1, "a circle owing one again starts from the first wait")
        retry.removeAll()
        XCTAssertTrue(retry.waits.isEmpty)
    }

    /// Light passes every 20 s while the circle owes an import: one import,
    /// none within its retry time, one after it, none once an import decided
    /// it; none at all while another import runs.
    func testALightPassImportsOncePerRetryTimeUntilDecided() {
        var retry = Manager.RecordsImportRetry()
        var states: [String: Manager.RecordsState] = [:]
        var imports: [TimeInterval] = []
        for tick in stride(from: 0.0, through: 600, by: 20) {
            let now = start + tick
            let owed = Manager.circlesOwingRecordsImport([circle], states: states, holdsKey: { _ in true })
            guard Manager.recordsImportDue(owing: owed, retry: retry, running: false, now: now) else { continue }
            imports.append(tick)
            // "Not now" (or no answer) until the import at 220 s decides it.
            if tick >= 200 { states[key] = .imported(forked: false) }
            retry.imported(owing: Manager.circlesOwingRecordsImport([circle], states: states, holdsKey: { _ in true }),
                           at: now)
        }
        XCTAssertEqual(imports, [0, 40, 100, 220])
        XCTAssertFalse(Manager.recordsImportDue(owing: [circle], retry: .init(), running: true, now: start),
                       "never while an import runs")
        XCTAssertFalse(Manager.recordsImportDue(owing: [], retry: .init(), running: false, now: start), "nothing owed")
    }

    /// A circle that never settles costs at most 100 imports a day, against
    /// 4,320 light passes at the foreground's 20 s.
    func testTheRetryTimeBoundsTheImportsOfACircleThatNeverSettles() {
        var retry = Manager.RecordsImportRetry()
        var imports = 0
        for tick in stride(from: 0.0, to: 86_400, by: 20) {
            guard Manager.recordsImportDue(owing: [circle], retry: retry, running: false, now: start + tick) else { continue }
            imports += 1
            retry.imported(owing: [circle], at: start + tick)
        }
        XCTAssertEqual(imports, 100)
    }

    /// The circle made here, with the real SDK: before an import decides it,
    /// it stands `.wait` and owes one; its one import after the roster pass
    /// (the creator's own row) answers imported, not forked. Then it stands
    /// `.recorded`: its next invitation carries the key, a keyless joiner its
    /// owner invited is given it, and a leave's security refresh runs, with
    /// no full load.
    func testACircleMadeHereStandsRecordedAfterItsOneImport() async throws {
        let owner = Party()
        let joiner = Party()
        let circle = UUID().uuidString.lowercased()
        let made = try owner.sdk.prepareRecordedCircleCreation(creatorUserId: owner.userId, circleId: circle)
        let role = owner.sdk.chainRole(circleId: circle, userId: owner.userId)
        XCTAssertEqual(role, .owner)

        let before = Manager.standing(nil, hasRecords: owner.sdk.circleHasRefreshRecords(circleId: circle))
        XCTAssertEqual(before, .wait)
        XCTAssertEqual(Manager.circlesOwingRecordsImport([circle], states: [:], holdsKey: { owner.sdk.hasCircleKey(circleId: $0) }),
                       [circle])
        XCTAssertFalse(Manager.invitationCarriesKey(standing: before, myChainRole: role), "while the records wait, an invitation carries no key")
        XCTAssertEqual(Manager.rotationMode(before, ownerOrAdmin: true, repairDue: false), .wait, "a leave's refresh skipped")

        // The server's records read: the genesis above what the device holds,
        // and no head yet (the creator publishes its own after the import).
        let mine = RecordMemberRow(userId: owner.userId, keys: owner.keys, confirmed: true, listed: true, listedRole: .owner,
                                   statements: [], personConfirmedKeys: false, serverSaysKeyless: false)
        let outcomes = await RefreshRecordsSync.run(
            me: owner.userId, inputs: [circle: .init(members: [mine], rosterComplete: true, keyChain: [])], sdk: owner.sdk
        ) { since in
            let genesis = ServedRefreshRecord(version: 1, record: made.genesis.recordHex, signature: made.genesis.signatureHex)
            return RefreshRecordsPage(circles: [CircleRefreshRecords(
                circleId: circle, records: (since[circle] ?? 0) < 1 ? [genesis] : [], heads: [], complete: true)], more: false)
        }
        guard case .imported(let report, _)? = outcomes?[circle] else { return XCTFail("not imported: \(String(describing: outcomes))") }
        XCTAssertFalse(report.forked)
        // The import's own mapping (`importRefreshRecords`).
        let state = Manager.RecordsState.imported(forked: report.forked)

        let after = Manager.standing(state, hasRecords: owner.sdk.circleHasRefreshRecords(circleId: circle))
        XCTAssertEqual(after, .recorded)
        XCTAssertEqual(Manager.circlesOwingRecordsImport([circle], states: [CanonicalId.key(circle): state],
                                                         holdsKey: { owner.sdk.hasCircleKey(circleId: $0) }), [])
        XCTAssertTrue(Manager.invitationCarriesKey(standing: after, myChainRole: role), "its next invitation carries the key")
        XCTAssertTrue(Manager.performsSecurityRefresh(flagged: true, cause: "member_left"))
        XCTAssertEqual(Manager.rotationMode(after, ownerOrAdmin: true, repairDue: false), .recorded(.rotation),
                       "a leave's security refresh runs")

        // A joiner with keys whom the owner invited, keyless on the server.
        let now = Int64(Date().timeIntervalSince1970)
        let invitation = try owner.sdk.signMembershipStatement(statement: MembershipStatement(
            kind: .invitationToAccount, circleId: circle, statementId: UUID().uuidString.lowercased(),
            signerUserId: owner.userId, issuedAt: now, expiresAt: now + 604_800, atVersion: 1,
            subjectUserId: joiner.userId, subjectSharingPublicKeyHex: joiner.keys.sharingKeyHex,
            subjectSigningPublicKeyHex: joiner.keys.signingKeyHex, subjectEmail: nil))
        let joined = RecordMemberRow(
            userId: joiner.userId, keys: joiner.keys, confirmed: true, listed: true, listedRole: .member,
            statements: [SignedStatementRecord(statementHex: invitation.statementHex, signatureHex: invitation.signatureHex)],
            personConfirmedKeys: false, serverSaysKeyless: true)
        let answers = try owner.sdk.refreshEligibility(circleId: circle, members: [mine, joined].map(\.sdkMember),
                                                      purpose: .deliver)
        let theirs = try XCTUnwrap(answers.first { $0.userId == joiner.userId })
        XCTAssertTrue(theirs.eligible, "delivery eligibility gives the keyless joiner the key")
        XCTAssertEqual(theirs.basis, .invitation)
    }

    /// Only an import's outcome decides: one that finds the circle forked, or
    /// latched (no record served or held, its own head proves records), leaves
    /// it waiting as decided, and a light pass never imports it again for that.
    func testAnImportsLatchedOrForkedOutcomeStands() async {
        final class Answers: RefreshRecordsSDK {
            var recorded: Set<String> = []
            var forked = false
            func refreshHeadVersions() -> [String: Int32] { [:] }
            func circleHasRefreshRecords(circleId: String) -> Bool { recorded.contains(circleId) }
            func noteCircleHasRecords(circleId: String) { recorded.insert(circleId) }
            func signingPublicKeyHex() throws -> String { String(repeating: "0a", count: 32) }
            func verifyCircleHead(headHex: String, signatureHex: String, signerSigningPublicKeyHex: String) throws -> CircleHead? {
                CircleHead(circleId: "c1c1c1c1-0000-4000-8000-0000000000a1", userId: "0f0f0f0f-1111-2222-3333-444455556666",
                           version: 1, chainHex: "")
            }
            func importRecords(circleId: String, records: [SignedRefreshRecord], keyChain: [KeyChainLinkData],
                               members: [RecordMemberRow], rosterComplete: Bool, ownHead: SignedCircleHead?,
                               memberHeads: [MemberHead]) throws -> RefreshRecordsReport {
                RefreshRecordsReport(versions: [], sealingVersion: 1, askForFreshCopy: false, forked: forked,
                                     headConfirmedMembers: [], tipNamedListed: [])
            }
        }
        let me = "0f0f0f0f-1111-2222-3333-444455556666"
        let head = ServedCircleHead(userId: me, head: String(repeating: "04", count: 69), signature: String(repeating: "03", count: 64))
        let input = RefreshRecordsSync.CircleInput(members: [], rosterComplete: true, keyChain: [])
        func run(_ sdk: Answers) async -> RefreshRecordsSync.Outcome? {
            await RefreshRecordsSync.run(me: me, inputs: [key: input], sdk: sdk) { _ in
                RefreshRecordsPage(circles: [CircleRefreshRecords(circleId: self.key, records: [], heads: [head], complete: true)],
                                   more: false)
            }?[key]
        }
        let forkedSDK = Answers()
        forkedSDK.recorded = [key]
        forkedSDK.forked = true
        guard case .imported(let report, _)? = await run(forkedSDK) else { return XCTFail("not imported") }
        let forked = Manager.RecordsState.imported(forked: report.forked)
        XCTAssertEqual(forked, .imported(forked: true))
        XCTAssertEqual(Manager.standing(forked, hasRecords: true), .wait)
        XCTAssertEqual(owing(forked), [])

        let latchedSDK = Answers()
        let latched = await run(latchedSDK)
        XCTAssertEqual(latched, .latched)
        XCTAssertEqual(Manager.standing(.latched, hasRecords: latchedSDK.circleHasRefreshRecords(circleId: key)), .wait)
        XCTAssertEqual(owing(.latched), [])
    }

    /// A join is answered by delivery, never by a new key; a departure is.
    func testAJoinNeverRotates() throws {
        XCTAssertFalse(Manager.performsSecurityRefresh(flagged: true, cause: "member_joined"))
        for cause in ["member_left", "member_removed", "periodic", "other", nil] {
            XCTAssertTrue(Manager.performsSecurityRefresh(flagged: true, cause: cause), String(describing: cause))
        }
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let push = try String(contentsOf: root.appendingPathComponent("App/Managers/PushNotificationManager.swift"), encoding: .utf8)
        let from = try XCTUnwrap(push.range(of: "    private static func handleMemberJoined(circleId: String?) async -> UIBackgroundFetchResult {"))
        let to = try XCTUnwrap(push[from.upperBound...].range(of: "\n    }\n"))
        let handler = push[from.upperBound..<to.lowerBound]
        XCTAssertTrue(handler.contains("try await CircleManager.shared.loadCircles(light: true)"))
        XCTAssertFalse(handler.lowercased().contains("rotate"), "no rotation for a join")
    }
}
