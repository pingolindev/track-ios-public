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

/// The owner hands a circle to another member from the iPhone.
///
/// WHY THIS IS WORTH TESTING
///   The app's own words tell owners to "transfer ownership and then leave",
///   so the iPhone must offer a hand-over. Where the circle has refresh
///   records and this account is their owner, the hand-over has to be a
///   record first, as on the web and Android. The server moves the ownership
///   to whoever `transfer_to` names and never checks the record, so the
///   record is the only tie between the two:
///   - `transfer_to` goes only with a record whose plan names that member
///     owner, included, and this account member;
///   - a kept hand-over finishes whichever way the server went, and never
///     with the server's transfer while the records don't name the member;
///   - kept means written, before the send;
///   - only the keys this device held for them at the tap;
///   - someone invited to an email is asked about, with their number.
@MainActor
final class HandOverTests: XCTestCase {

    private let me = "0f0f0f0f-1111-4222-8333-444455556666"
    private let ava = "a1000000-0000-4000-8000-00000000000a"
    private let ben = "a1000000-0000-4000-8000-00000000000b"
    private let circle = "c1c1c1c1-0000-4000-8000-000000000001"

    private func listed(_ userId: String, _ role: CircleRole = .member, keys: Bool = true) -> RecordedRotation.Listed {
        RecordedRotation.Listed(userId: userId, role: role, hasKeys: keys)
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func body(of start: String, until end: String, in text: String) throws -> String {
        let from = try XCTUnwrap(text.range(of: start), start)
        let to = try XCTUnwrap(text.range(of: end, range: from.upperBound..<text.endIndex), end)
        return String(text[from.lowerBound..<to.lowerBound])
    }

    // MARK: - The record

    func testThePlanNamesTheMemberOwnerAndThisAccountMember() {
        let plan = RecordedRotation.rotationPlan(
            me: me, roster: [listed(me, .owner), listed(ava), listed(ben, .admin)],
            includable: [me, ava, ben], blocked: [], counted: [me: .owner, ava: .member, ben: .admin],
            removing: [], handOverTo: ava.uppercased())
        XCTAssertEqual(plan.first { $0.userId == me }, PlannedEntry(userId: me, state: .included, role: .member))
        XCTAssertEqual(plan.first { $0.userId == ava }, PlannedEntry(userId: ava, state: .included, role: .owner))
        XCTAssertNil(plan.first { $0.userId == ben }?.role, "nobody else's role changes")
        XCTAssertTrue(RecordedRotation.handsOver(plan, me: me, to: ava))
        // Without a hand-over the plan gives no role to anyone.
        let plain = RecordedRotation.rotationPlan(
            me: me, roster: [listed(me, .owner), listed(ava)], includable: [me, ava], blocked: [],
            counted: [me: .owner, ava: .member], removing: [])
        XCTAssertTrue(plain.allSatisfy { $0.role == nil })
        XCTAssertFalse(RecordedRotation.handsOver(plain, me: me, to: ava))
    }

    /// A member the record could only carry pending (not a yes from the SDK's
    /// eligibility rule, or blocked) is handed nothing: the plan names a
    /// pending owner, and that is no hand-over (the web client applies the
    /// same rule).
    func testAMemberTheRecordCarriesOnlyPendingIsHandedNothing() {
        let cases: [(includable: Set<String>, blocked: Set<String>)] = [([me], []), ([me, ava], [ava])]
        for (includable, blocked) in cases {
            let plan = RecordedRotation.rotationPlan(
                me: me, roster: [listed(me, .owner), listed(ava)], includable: includable, blocked: blocked,
                counted: [me: .owner, ava: .member], removing: [], handOverTo: ava)
            XCTAssertEqual(plan.first { $0.userId == ava }?.state, .pending)
            XCTAssertFalse(RecordedRotation.handsOver(plan, me: me, to: ava))
        }
        // Someone this person removes is never named owner either.
        let removing = RecordedRotation.rotationPlan(
            me: me, roster: [listed(me, .owner), listed(ava)], includable: [me, ava], blocked: [],
            counted: [me: .owner, ava: .member], removing: [ava], handOverTo: ava)
        XCTAssertFalse(RecordedRotation.handsOver(removing, me: me, to: ava))
    }

    /// An owner's claim and a hand-over never go in one record.
    func testAClaimHandsNothingOver() {
        let plan = RecordedRotation.rotationPlan(
            me: me, roster: [listed(me, .owner), listed(ava)], includable: [me, ava], blocked: [],
            counted: [me: .admin, ava: .member], removing: [], claimsOwner: true, handOverTo: ava)
        XCTAssertEqual(plan.first { $0.userId == me }?.role, .owner)
        XCTAssertNil(plan.first { $0.userId == ava }?.role)
        XCTAssertFalse(RecordedRotation.handsOver(plan, me: me, to: ava))
    }

    /// Exactly one owner, the member asked for and included, and this account
    /// included as a member: anything else is no hand-over.
    func testHandsOverNeedsExactlyThatOwner() {
        let ownerAva = PlannedEntry(userId: ava, state: .included, role: .owner)
        let selfMember = PlannedEntry(userId: me, state: .included, role: .member)
        XCTAssertTrue(RecordedRotation.handsOver([selfMember, ownerAva], me: me, to: ava.uppercased()))
        XCTAssertFalse(RecordedRotation.handsOver([selfMember, ownerAva], me: me, to: ben), "another member")
        XCTAssertFalse(RecordedRotation.handsOver([selfMember, ownerAva,
                                                   PlannedEntry(userId: ben, state: .included, role: .owner)],
                                                  me: me, to: ava), "two owners")
        XCTAssertFalse(RecordedRotation.handsOver([PlannedEntry(userId: me, state: .included, role: nil), ownerAva],
                                                  me: me, to: ava), "this account still the owner")
        XCTAssertFalse(RecordedRotation.handsOver([selfMember, PlannedEntry(userId: ava, state: .pending, role: .owner)],
                                                  me: me, to: ava), "a pending owner")
    }

    /// `transfer_to` is the plan's owner entry, sent with the record that
    /// names them, and left out of every other rotation.
    func testTransferToGoesOnlyWithTheRecordThatNamesTheOwner() throws {
        let bundle = RecordedRotationBundle(
            rotation: KeyRotationBundle(newKeyVersion: 4, encryptedName: EncryptedData(nonce: "00", ciphertext: "00"),
                                        memberKeys: [], keyChainLink: nil),
            refreshRecord: SignedRefreshRecord(recordHex: "aa", signatureHex: "bb"))
        func wire(_ transferTo: String?) throws -> [String: Any] {
            var change = CircleManager.RecordedChange(
                bundle: bundle, kind: .rotation, pendingMembers: [], removals: [], roleChanges: [:], repairing: nil,
                name: .keepStored)
            change.transferTo = transferTo
            let request = CircleManager.rotateKeysRequest(expectedKeyVersion: 3, change: change)
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase  // as APIService encodes
            return try XCTUnwrap(try JSONSerialization.jsonObject(with: encoder.encode(request)) as? [String: Any])
        }
        XCTAssertEqual(try wire(ava)["transfer_to"] as? String, ava)
        XCTAssertFalse(try wire(nil).keys.contains("transfer_to"), "left out, never null")

        let circles = try source("App/Managers/CircleManager.swift")
        let prepare = try body(of: "    private func prepareRecordedChange(", until: "    private func recordedChangeTaken(", in: circles)
        XCTAssertTrue(prepare.contains("""
                    if let handOver {
                        guard RecordedRotation.handsOver(planned, me: me, to: handOver.target),
                              let owner = planned.first(where: { $0.role == .owner }) else { throw CircleError.handOverNotNow }
                        transferTo = owner.userId
                    }
        """))
        XCTAssertTrue(prepare.contains("            let claims = handOver == nil\n"), "never with a claim")
        XCTAssertTrue(prepare.contains("claimsOwner: claims, handOverTo: myChainRole == .owner ? handOver?.target : nil)"),
                      "only the chain's owner hands over")
        XCTAssertTrue(prepare.contains("uncountedNamed: uncounted.sorted(), name: name, transferTo: transferTo)"))
        XCTAssertTrue(circles.contains("                                             signature: change.bundle.refreshRecord.signatureHex),\n            transferTo: change.transferTo)"))
    }

    /// The record names them only with the keys held at the tap, while the
    /// roster pass confirms them with exactly those, in a rotation only.
    func testOnlyTheKeysHeldAtTheTapAreNamedOwner() throws {
        let circles = try source("App/Managers/CircleManager.swift")
        let prepare = try body(of: "    private func prepareRecordedChange(", until: "    private func recordedChangeTaken(", in: circles)
        XCTAssertTrue(prepare.contains(
            "            guard mode == .recorded(.rotation), ejecting == nil else { throw CircleError.handOverNotNow }\n"))
        XCTAssertTrue(prepare.contains("""
                    guard let row = members.first(where: { CanonicalId.same($0.userId, handOver.target) }),
                          row.listed, row.confirmed,
                          row.keys?.matches(sharing: handOver.sharingKeyHex, signing: handOver.signingKeyHex) == true
                    else { throw CircleError.handOverDetailsChanged }
        """))
        // And at the tap: the keys this device holds, only while the member
        // list shows exactly those and they are the ones the person decided on.
        let tap = try body(of: "    func handOver(_ circleId: String, to target: String, keys: MemberKeyPair?)",
                           until: "    private func handOverWithRecord(", in: circles)
        XCTAssertTrue(tap.contains("""
                    guard let held = promotionKeys(for: target, in: circle.id),
                          Self.promotionAdmissionKeys(held: held, listed: listedKeys(for: target, in: circle.id),
                                                      decided: keys) != nil
                    else { throw CircleError.handOverDetailsChanged }
        """))
    }

    // MARK: - The way it goes

    func testTheWayAHandOverGoes() {
        XCTAssertEqual(CircleManager.handOverPath(standing: .noRecords, myChainRole: nil), .serverOnly,
                       "the first record takes the list's roles")
        XCTAssertEqual(CircleManager.handOverPath(standing: .recorded, myChainRole: .owner), .record)
        XCTAssertEqual(CircleManager.handOverPath(standing: .recorded, myChainRole: .admin), .serverOnly,
                       "a claimant's circle: the records keep their owner")
        XCTAssertEqual(CircleManager.handOverPath(standing: .recorded, myChainRole: nil), .serverOnly)
        XCTAssertEqual(CircleManager.handOverPath(standing: .wait, myChainRole: .owner), .notNow)
    }

    /// The record-first hand-over: every precondition of a rotation before
    /// anything is planned; kept (written) before the send, or nothing is
    /// sent; a refusal for good ends it, anything else leaves it kept.
    func testTheRecordFirstHandOverInOrder() throws {
        let circles = try source("App/Managers/CircleManager.swift")
        let send = try body(of: "    private func handOverWithRecord(", until: "    nonisolated static func handOverRefusedForGood(",
                            in: circles)
        let gates = try XCTUnwrap(send.range(of: """
                guard !rotationsInFlight.contains(circle.id), rotationMode(for: circle, due: due) == .recorded(.rotation),
                      !nameHoldsBack(circle, due: due), holdsWhatItRotates(circle), !changesAwaitingImport.waits(circle.id),
                      keyChangesMayBuild(circle)
                else { throw CircleError.handOverNotNow }

        """))
        let planned = try XCTUnwrap(send.range(of: "let (plan, _, blocked) = try await planRotation(for: circle, rotatorUserId: me)"))
        let built = try XCTUnwrap(send.range(of: """
                    change = try prepareRecordedChange(circle, me: me, mode: .recorded(.rotation), due: nil, decision: plan,
                                                       blocked: blocked, handOver: handOver)
        """))
        let kept = try XCTUnwrap(send.range(of: """
                guard RefreshLedger.shared.noteHandOver(account: me, circleId: circle.id, handOver) else {
                    _ = cryptoManager.discardUnconfirmedRotation(circleId: circle.id)
                    throw CircleError.handOverNotNow
                }

        """))
        let sent = try XCTUnwrap(send.range(of: "            try await sendRecordedRotation(circle, me: me, change: change)\n"))
        let refused = try XCTUnwrap(send.range(of: """
                    guard Self.handOverRefusedForGood(error) else { return .pending }
                    RefreshLedger.shared.clearHandOver(account: me, circleId: circle.id)
                    throw CircleError.handOverNotNow

        """))
        XCTAssertLessThan(gates.lowerBound, planned.lowerBound)
        XCTAssertLessThan(planned.lowerBound, built.lowerBound)
        XCTAssertLessThan(built.lowerBound, kept.lowerBound, "kept before it is sent")
        XCTAssertLessThan(kept.lowerBound, sent.lowerBound)
        XCTAssertLessThan(sent.lowerBound, refused.lowerBound)
        // One per circle, and the own name sealed again after the rotation.
        XCTAssertTrue(send.contains("""
                if let kept = RefreshLedger.shared.circle(account: me, circleId: circle.id).handOver,
                   !CanonicalId.same(kept.target, handOver.target) {
                    throw CircleError.handOverNotNow
                }
        """))
        XCTAssertTrue(send.contains("                Task { await self.sealOwnName(circleId: circle.id) }\n"))
    }

    // MARK: - The finish

    func testAKeptHandOverFinishesWhicheverWayTheServerWent() {
        XCTAssertEqual(CircleManager.handOverStep(serverOwner: ava.uppercased(), me: me, target: ava, recordsNameTarget: true),
                       .done, "both applied")
        XCTAssertEqual(CircleManager.handOverStep(serverOwner: ava, me: me, target: ava, recordsNameTarget: false),
                       .done, "done on the server's word: nothing here writes that owner")
        XCTAssertEqual(CircleManager.handOverStep(serverOwner: ben, me: me, target: ava, recordsNameTarget: false), .moved)
        XCTAssertEqual(CircleManager.handOverStep(serverOwner: me.uppercased(), me: me, target: ava, recordsNameTarget: true),
                       .transferOnServer, "the record landed, the transfer was dropped")
        XCTAssertEqual(CircleManager.handOverStep(serverOwner: me, me: me, target: ava, recordsNameTarget: false),
                       .rebuild, "neither landed: built again, never the server's transfer alone")
        XCTAssertEqual(CircleManager.handOverStep(serverOwner: nil, me: me, target: ava, recordsNameTarget: true), .wait)
        XCTAssertEqual(CircleManager.handOverStep(serverOwner: "not-an-id", me: me, target: ava, recordsNameTarget: true), .wait)
    }

    func testARefusalForGoodEndsAHandOver() {
        for status in [400, 403, 404, 409] {
            XCTAssertTrue(CircleManager.handOverRefusedForGood(APIError(code: "http_\(status)", message: "x")), "\(status)")
        }
        for code in ["key_refresh_record_invalid", "key_refresh_record_stale", "key_refresh_record_required"] {
            XCTAssertFalse(CircleManager.handOverRefusedForGood(APIError(code: "http_409", message: "x", errorCode: code)),
                           "\(code): built again")
        }
        XCTAssertFalse(CircleManager.handOverRefusedForGood(APIError(code: "http_500", message: "x")))
        XCTAssertFalse(CircleManager.handOverRefusedForGood(APIError(code: "http_429", message: "x")))
        XCTAssertFalse(CircleManager.handOverRefusedForGood(URLError(.notConnectedToInternet)))
    }

    /// The finish runs at every load of the list, on the list the server just
    /// gave, and its rebuild never sends the server's transfer.
    func testTheFinishIsWiredInAndNeverTransfersBehindTheRecords() throws {
        let circles = try source("App/Managers/CircleManager.swift")
        XCTAssertTrue(circles.contains("        if listedNow { finishHandOvers(listed: responses, whole: listedWhole) }\n"))
        let finish = try body(of: "    private func finishHandOver(_ circleKey: String,", until: "    /// Drop a circle from local state",
                              in: circles)
        let rebuild = try body(of: "        case .rebuild:\n", until: "        case .wait:\n", in: finish)
        XCTAssertFalse(rebuild.contains("transferOwnership("), "never while the records don't name them")
        XCTAssertTrue(rebuild.contains("_ = try await handOverWithRecord(circle, me: me, handOver)"))
        XCTAssertTrue(rebuild.contains("} catch CircleError.handOverDetailsChanged {\n"))
        let transfer = try body(of: "        case .transferOnServer:\n", until: "        case .rebuild:\n", in: finish)
        XCTAssertTrue(transfer.contains("_ = try await api.transferOwnership(circleId: row.id, newOwnerId: handOver.target)"))
        XCTAssertTrue(finish.contains("        guard CanonicalId.same(AuthManager.shared.userId, me) else { return }\n"),
                      "never another account's")
        XCTAssertTrue(finish.contains("            if whole { RefreshLedger.shared.clearHandOver(account: me, circleId: circleKey) }\n"),
                      "a circle gone from a whole list ends it")
    }

    // MARK: - The ledger

    func testTheLedgerKeepsAHandOverOnlyWhenItWrites() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("handover-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ledger = RefreshLedger(directory: directory)
        let handOver = RefreshLedger.HandOver(target: ava, sharingKeyHex: "11", signingKeyHex: "22")
        XCTAssertTrue(ledger.noteHandOver(account: me, circleId: circle, handOver))
        XCTAssertEqual(ledger.circle(account: me, circleId: circle.uppercased()).handOver, handOver)
        XCTAssertEqual(ledger.handOvers(account: me), [circle: handOver])
        XCTAssertEqual(RefreshLedger(directory: directory).circle(account: me, circleId: circle).handOver, handOver,
                       "kept across a relaunch")
        XCTAssertTrue(ledger.clearHandOver(account: me, circleId: circle))
        XCTAssertNil(ledger.circle(account: me, circleId: circle).handOver)
        XCTAssertEqual(ledger.handOvers(account: me), [:])

        let locked: [FileAttributeKey: Any] = [.posixPermissions: 0o555]
        let open: [FileAttributeKey: Any] = [.posixPermissions: 0o755]
        try FileManager.default.setAttributes(locked, ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes(open, ofItemAtPath: directory.path) }
        XCTAssertFalse(ledger.noteHandOver(account: me, circleId: circle, handOver), "not written: nothing is sent")
        XCTAssertNil(ledger.circle(account: me, circleId: circle).handOver, "and never kept for the session only")
    }

    /// A file an earlier build wrote, with no hand-over, still reads.
    func testAnEntryWithoutAHandOverStillReads() throws {
        let entry = try JSONDecoder().decode(RefreshLedger.Circle.self, from: Data(#"{"roleChanges":{"x":"admin"}}"#.utf8))
        XCTAssertNil(entry.handOver)
        XCTAssertEqual(entry.roleChanges, ["x": "admin"])
    }

    // MARK: - The tap and the words

    /// "Transfer Ownership", the same words as on the web and Android:
    /// someone following "transfer ownership and then leave" finds it.
    func testTheMenuOffersTransferOwnershipToTheOwner() throws {
        let view = try source("App/Views/Circles/CirclesView.swift")
        let start = try XCTUnwrap(view.range(of: "struct MemberRow: View {"))
        let end = try XCTUnwrap(view.range(of: "\nstruct ", range: start.upperBound..<view.endIndex))
        let row = String(view[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(row.contains("""
                            Button("Transfer Ownership") {
                                // The keys this device holds for them, fixed now, as
                                // for a promotion: the record names only those.
                                let keys = circleManager.promotionKeys(for: member.userId, in: circle.id)
                                handOverAsk = PendingPromotion(
                                    keys: keys,
                                    number: circleManager.isReceiveOnly(member.userId, in: circle.id)
                                        ? keys.flatMap { circleManager.securityCode(for: member.userId, keys: $0) } : nil)
                            }
                        }
        """), "for the owner only, about anyone but the owner")
        XCTAssertTrue(row.contains("""
                        Button("Transfer") {
                            let keys = handOverAsk?.keys
                            handOverAsk = nil
                            handOver(keys: keys)
                        }
        """), "the keys decided at the question are the ones handed on")
        XCTAssertTrue(row.contains(
            "let outcome = try await circleManager.handOver(circle.id, to: member.userId, keys: keys)"))
        XCTAssertTrue(row.contains("                \"Transfer ownership to \\(member.displayName)?\",\n"), "the question's title")
        XCTAssertTrue(row.contains(
            "handOverResult = HandOverResult(title: \"Couldn't transfer ownership to \\(member.displayName)\",\n"),
                      "the failure's title")
        XCTAssertFalse(row.contains("\"Make Owner\""))
    }

    func testTheWords() {
        XCTAssertEqual(MemberRow.handOverQuestion(name: "Ava", circle: "Family", number: nil),
                       "Ava will have full control of Family: they can delete it or hand it on. "
                       + "You'll stay in it as a member. This can't be undone.")
        XCTAssertEqual(MemberRow.handOverQuestion(name: "Ava", circle: "Family", number: "12345 67890", device: "iPhone"),
                       "Ava was invited by email, so this iPhone can't tell on its own that the account is really theirs. "
                       + "If you're not sure it's them, check with Ava another way first. Their number: 12345 67890. "
                       + "Ava will have full control of Family: they can delete it or hand it on. "
                       + "You'll stay in it as a member. This can't be undone.")
        XCTAssertEqual(MemberRow.handOverResult(.done, name: "Ava", circle: "Family"),
                       MemberRow.HandOverResult(title: "Ava is the owner now",
                                                message: "You're a member of Family, and can leave it whenever you like."))
        XCTAssertEqual(MemberRow.handOverResult(.pending, name: "Ava", circle: "Family"),
                       MemberRow.HandOverResult(title: "Handing Family over", message: "The handover will finish on its own."))
        XCTAssertEqual(CircleManager.CircleError.handOverNotNow.errorDescription, "Couldn't hand the circle over just now.")
        XCTAssertEqual(CircleManager.CircleError.handOverDetailsChanged.errorDescription,
                       "Their details changed, so the circle wasn't handed over.")
    }

    /// The server's own transfer: its route and body.
    func testTheServerTransfer() throws {
        let api = try source("App/Services/APIService.swift")
        XCTAssertTrue(api.contains("""
                return try await post(
                    path: "/api/v1/circles/\\(circleId)/transfer-ownership",
                    body: TransferOwnershipRequest(newOwnerId: newOwnerId)
                )
        """))
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: encoder.encode(TransferOwnershipRequest(newOwnerId: ava))) as? [String: String])
        XCTAssertEqual(body, ["new_owner_id": ava])
    }
}
