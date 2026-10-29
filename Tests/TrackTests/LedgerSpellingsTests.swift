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

/// The refresh and backfill ledgers key circles and members by their one
/// canonical form, a removal is taken back by an account's id only, and
/// entries an earlier build kept under two spellings fold at the read,
/// whatever keeps someone out winning.
@MainActor
final class LedgerSpellingsTests: XCTestCase {
    private var directory: URL!
    private let me = "0f0f0f0f-1111-2222-3333-444455556666"
    private let circle = "c4000000-0000-4000-8000-000000000001"
    private var upper: String { circle.uppercased() }
    private var bare: String { circle.replacingOccurrences(of: "-", with: "") }
    private let clock = Date(timeIntervalSince1970: 1_800_000_000)
    private func member(_ n: Int) -> String { String(format: "e4000000-0000-4000-8000-%012d", n) }
    private func unhyphenated(_ id: String) -> String { id.replacingOccurrences(of: "-", with: "") }

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("spellings-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func keep<T: Encodable>(_ value: T, account: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: directory.appendingPathComponent("\(account).json"))
    }

    // MARK: - The refresh ledger

    /// Every spelling of a circle is one entry, filed under its one form.
    func testEverySpellingOfACircleIsOneEntry() throws {
        let ledger = RefreshLedger(directory: directory)
        XCTAssertTrue(ledger.noteRemoval(account: me, circleId: upper, userId: member(1), at: clock))
        XCTAssertTrue(ledger.update(account: me.uppercased(), circleId: bare) { $0.roleChanges[member(2)] = "admin" })
        let entry = RefreshLedger(directory: directory).circle(account: me, circleId: "{\(circle)}")
        XCTAssertEqual(entry.removals.map(\.userId), [member(1)])
        XCTAssertEqual(entry.roleChanges, [member(2): "admin"])
        let file = try JSONDecoder().decode([String: RefreshLedger.Circle].self,
                                            from: Data(contentsOf: directory.appendingPathComponent("\(me).json")))
        XCTAssertEqual(Array(file.keys), [circle])
    }

    /// Two spellings of a circle kept by an earlier build fold at the read:
    /// every member's removal at the later time, and one pending under any
    /// spelling stays pending though another cleared it; the budget's
    /// versions all, the latest repair; a repair's members and a
    /// re-invitation's clear the canonical spelling's; two role changes that
    /// differ give the one with the least authority. The next write keeps it.
    func testTwoSpellingsOfACircleFoldWhateverKeepsSomeoneOutWinning() throws {
        let cleared = RefreshLedger.Cleared(removal: .init(userId: member(2), at: clock), until: clock.addingTimeInterval(9))
        try keep([
            circle: RefreshLedger.Circle(
                removals: [.init(userId: member(1), at: clock)], roleChanges: [member(4): "admin", member(9): "viewer"],
                rejectedSeen: [5],
                repaired: [3], lastRepairAt: clock, repairs: ["4": [member(3)]], clearedByInvitations: ["s-1": cleared]),
            upper: RefreshLedger.Circle(
                removals: [.init(userId: member(1).uppercased(), at: clock.addingTimeInterval(60)),
                           .init(userId: member(2), at: clock)],
                roleChanges: [member(4).uppercased(): "member", member(7): "admin", member(9): "admin"],
                rejectedSeen: [6], repaired: [4],
                lastRepairAt: clock.addingTimeInterval(60), repairs: ["4": [member(5)], "7": [member(6)]],
                clearedByInvitations: ["s-1": .init(removal: .init(userId: member(8), at: clock), until: clock)]),
        ], account: me)
        let ledger = RefreshLedger(directory: directory)
        let folded = ledger.circle(account: me, circleId: circle)
        XCTAssertEqual(folded.removals, [.init(userId: member(1), at: clock.addingTimeInterval(60)),
                                         .init(userId: member(2), at: clock)])
        XCTAssertEqual(folded.clearedByInvitations, ["s-1": cleared])
        XCTAssertEqual(Set(folded.rejectedSeen), [5, 6])
        XCTAssertEqual(Set(folded.repaired), [3, 4])
        XCTAssertEqual(folded.lastRepairAt, clock.addingTimeInterval(60))
        XCTAssertEqual(folded.repairs, ["4": [member(3)], "7": [member(6)]])
        XCTAssertEqual(folded.roleChanges, [member(4): "member", member(7): "admin", member(9): "admin"],
                       "the least authority; a role the SDK doesn't know never wins")
        XCTAssertEqual(ledger.circle(account: me, circleId: upper), folded, "read under either spelling")
        XCTAssertTrue(ledger.update(account: me, circleId: circle) { $0.rejectedSeen.append(8) })
        let file = try JSONDecoder().decode([String: RefreshLedger.Circle].self,
                                            from: Data(contentsOf: directory.appendingPathComponent("\(me).json")))
        XCTAssertEqual(Array(file.keys), [circle], "the next write keeps the fold")
        XCTAssertEqual(file[circle]?.removals, folded.removals)
    }

    /// Folding again gives the same; an entry with nothing to fold is left
    /// exactly as it is; a member under two spellings in one entry folds.
    func testTheFoldIsIdempotentAndLeavesTheRestAlone() {
        let untouched = RefreshLedger.Circle(removals: [.init(userId: "x", at: clock)], roleChanges: ["Y": "admin"],
                                             rejectedSeen: [9, 2], repaired: [4, 1])
        XCTAssertEqual(RefreshLedger.folded([circle: untouched]), [circle: untouched])
        let twice = RefreshLedger.Circle(removals: [.init(userId: member(1), at: clock),
                                                    .init(userId: unhyphenated(member(1)), at: clock.addingTimeInterval(9))])
        let stored = [circle: twice, upper: untouched]
        let folded = RefreshLedger.folded(stored)
        XCTAssertEqual(folded[circle]?.removals, [.init(userId: member(1), at: clock.addingTimeInterval(9)),
                                                  .init(userId: "x", at: clock)])
        XCTAssertEqual(RefreshLedger.folded(folded), folded)
        XCTAssertEqual(RefreshLedger.folded([circle: twice])[circle]?.removals,
                       [.init(userId: member(1), at: clock.addingTimeInterval(9))])
    }

    /// Only an account's id takes a removal back: a clear, a re-invitation
    /// that ran out while "listed", or a newer statement, naming no UUID
    /// leaves it standing. Noting it again files under its key.
    func testOnlyAnAccountsIdTakesARemovalBack() {
        let ledger = RefreshLedger(directory: directory)
        XCTAssertTrue(ledger.noteRemoval(account: me, circleId: circle, userId: "x", at: clock))
        XCTAssertTrue(ledger.clearRemoval(account: me, circleId: circle, userId: "x", decidedAt: clock.addingTimeInterval(60)))
        XCTAssertEqual(ledger.circle(account: me, circleId: circle).removals.map(\.userId), ["x"], "it stands")
        XCTAssertTrue(ledger.noteRemoval(account: me, circleId: circle, userId: "X", at: clock.addingTimeInterval(9)))
        XCTAssertEqual(ledger.circle(account: me, circleId: circle).removals.map(\.userId), ["X"], "one per key")
        XCTAssertTrue(ledger.noteRemoval(account: me, circleId: circle, userId: unhyphenated(member(1)), at: clock))
        XCTAssertTrue(ledger.noteRemoval(account: me, circleId: circle, userId: member(1), at: clock))
        XCTAssertEqual(ledger.circle(account: me, circleId: circle).removals.map(\.userId), ["X", member(1)])
        XCTAssertTrue(ledger.clearRemoval(account: me, circleId: circle, userId: member(1).uppercased(),
                                          decidedAt: clock.addingTimeInterval(60)))
        XCTAssertEqual(ledger.circle(account: me, circleId: circle).removals.map(\.userId), ["X"])

        let other = RefreshLedger(directory: directory)
        let ended = Date().addingTimeInterval(-60)
        for user in ["n", member(2)] {
            XCTAssertTrue(other.update(account: me, circleId: circle) {
                $0.clearedByInvitations["s-\(user)"] = .init(removal: .init(userId: user, at: self.clock), until: ended)
            })
        }
        XCTAssertTrue(other.settleRunOutReInvites(account: me, circleId: circle, listed: ["N", member(2).uppercased()],
                                                  now: Date()))
        XCTAssertEqual(Set(other.circle(account: me, circleId: circle).removals.map(\.userId)), ["X", "n"],
                       "listed by an id only: a non-UUID comes back")
    }

    /// A clear made while the file can't be read is made on it once it reads:
    /// naming no UUID, it takes nothing back there either.
    func testAClearWhileTheFileCantBeReadTakesBackByIdOnly() throws {
        let ledger = RefreshLedger(directory: directory)
        XCTAssertTrue(ledger.noteRemoval(account: me, circleId: circle, userId: "x", at: clock))
        XCTAssertTrue(ledger.noteRemoval(account: me, circleId: circle, userId: member(1), at: clock))
        let file = directory.appendingPathComponent("\(me).json")
        let good = try Data(contentsOf: file)
        try Data("{not json".utf8).write(to: file)
        let relaunched = RefreshLedger(directory: directory)
        XCTAssertFalse(relaunched.clearRemoval(account: me, circleId: circle, userId: "x", decidedAt: clock.addingTimeInterval(60)))
        XCTAssertFalse(relaunched.clearRemoval(account: me, circleId: circle, userId: member(1).uppercased(),
                                               decidedAt: clock.addingTimeInterval(60)))
        try good.write(to: file)
        XCTAssertEqual(relaunched.circle(account: me, circleId: circle).removals.map(\.userId), ["x"])
    }

    private final class Checker: MembershipStatementChecking {
        var parsed: [String: MembershipStatement] = [:]
        func parse(_ statementHex: String) throws -> MembershipStatement {
            guard let statement = parsed[statementHex] else { throw MobileError.InvalidInput(message: "unknown") }
            return statement
        }
        func verify(statementHex: String, signatureHex: String, signerKeyHex: String) throws -> Bool { false }
        func pinnedSigningKey(circleId: String, userId: String) -> String? { nil }
        func pinnedSharingKey(circleId: String, userId: String) -> String? { nil }
        func ownSigningKey() -> String? { nil }
        func ownSigner(statementHex: String, signatureHex: String) -> OwnStatementSigner? { .currentKey }
        func holdsPreviousIdentity(sharingKeyHex: String) -> Bool { false }
    }

    /// A newer statement of this account clears a removal only when its
    /// circle, signer and subject are ids, in any spelling.
    func testAStatementClearsARemovalOnlyByIds() {
        let checker = Checker()
        func stands(_ removed: String, signer: String, subject: String, circleId: String, me: String,
                    in ledgerCircle: String? = nil) -> Bool {
            checker.parsed["st"] = MembershipStatement(
                kind: .invitationToAccount, circleId: circleId, statementId: "st", signerUserId: signer,
                issuedAt: Int64(clock.timeIntervalSince1970) + 60, expiresAt: 0, atVersion: 3, subjectUserId: subject,
                subjectSharingPublicKeyHex: nil, subjectSigningPublicKeyHex: nil, subjectEmail: nil)
            return !RefreshLedger.removalsStanding(
                [.init(userId: removed, at: clock)], me: me, circleId: ledgerCircle ?? circle,
                statements: [subject: [SignedStatementRecord(statementHex: "st", signatureHex: "00")]], dead: [],
                checker: checker).isEmpty
        }
        XCTAssertFalse(stands(member(1), signer: self.me.uppercased(), subject: unhyphenated(member(1)), circleId: upper,
                              me: self.me))
        XCTAssertTrue(stands("x", signer: self.me, subject: "x", circleId: circle, me: self.me), "no account")
        XCTAssertTrue(stands(member(1), signer: "me", subject: member(1), circleId: circle, me: "me"), "no account is me")
        XCTAssertTrue(stands(member(1), signer: self.me, subject: member(1), circleId: "c1", me: self.me), "no circle")
        XCTAssertTrue(stands(member(1), signer: self.me, subject: member(1), circleId: "C1", me: self.me, in: "c1"),
                      "a circle that is no UUID is no circle, even the same one")
    }

    /// The guarded tidy finds and takes an account's file under any spelling.
    func testAnAccountsFileUnderAnySpellingIsFoundAndTaken() throws {
        try keep([circle: RefreshLedger.Circle(removals: [.init(userId: member(1), at: clock)])], account: unhyphenated(me))
        let ledger = RefreshLedger(directory: directory)
        XCTAssertEqual(ledger.accounts(), [me])
        ledger.forget(account: me)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("\(unhyphenated(me)).json").path))
    }

    /// The ping-pong stop compares members by their key.
    func testThePingPongStopComparesKeys() {
        let entry = RefreshLedger.Circle(rejectedSeen: [6], repaired: [4], repairs: ["5": [unhyphenated(member(1))]])
        let status = RecordVersionStatus(version: 6, state: .rejected, problem: .r2NotAllowed,
                                         notAllowed: [member(1).uppercased()], unmatchedEntries: 0, namedListed: [])
        XCTAssertFalse(RefreshLedger.mayRepair(status, circle: entry, now: clock))
        XCTAssertEqual(RefreshLedger.rejectedFor(status, uncountedNamed: ["{\(member(1))}"]), [member(1)])
    }

    // MARK: - The backfill ledger

    /// Every spelling of a circle and a member is one entry.
    func testTheBackfillKeysEverySpellingAsOne() {
        let ledger = BackfillLedger(directory: directory)
        XCTAssertTrue(ledger.keep("S-1", account: me, circleId: upper, userId: unhyphenated(member(1)), now: clock))
        XCTAssertEqual(BackfillLedger(directory: directory)
            .entry(account: me.uppercased(), circleId: "{\(circle)}", userId: member(1).uppercased())?.ids, ["s-1"])
    }

    /// Entries kept under two spellings fold at the read: every id in order
    /// and none dropped (each must be able to go dead), the latest send,
    /// stopped if any was. A key that isn't two ids stays as it is. Folding
    /// again gives the same.
    func testTheBackfillFoldKeepsEveryId() throws {
        let keys = ["\(circle):\(member(1))", "\(upper):\(member(1).uppercased())", "urn:uuid:\(circle):\(member(1))"]
        let ids = (1...25).map { "s-\($0)" }
        try keep([
            keys[0]: BackfillLedger.Entry(ids: Array(ids[0..<12]), lastSentAt: clock, stopped: false),
            keys[1]: BackfillLedger.Entry(ids: Array(ids[10..<20]), lastSentAt: clock.addingTimeInterval(60), stopped: true),
            keys[2]: BackfillLedger.Entry(ids: Array(ids[18..<25]), lastSentAt: nil, stopped: false),
            "c1:u1": BackfillLedger.Entry(ids: ["s-x"], lastSentAt: nil, stopped: false),
        ], account: me)
        let folded = try XCTUnwrap(BackfillLedger(directory: directory).entry(account: me, circleId: circle, userId: member(1)))
        XCTAssertEqual(folded.ids, ids, "every id, in order, past maxIds")
        XCTAssertEqual(folded.lastSentAt, clock.addingTimeInterval(60))
        XCTAssertTrue(folded.stopped)
        XCTAssertEqual(BackfillLedger(directory: directory).entry(account: me, circleId: "c1", userId: "u1")?.ids, ["s-x"])
        let stored = try JSONDecoder().decode([String: BackfillLedger.Entry].self,
                                              from: Data(contentsOf: directory.appendingPathComponent("\(me).json")))
        XCTAssertEqual(BackfillLedger.folded(BackfillLedger.folded(stored)), BackfillLedger.folded(stored))
    }
}
