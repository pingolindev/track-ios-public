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

/// The account's PERSONAL key is held under the nil UUID, so a "circle" a
/// server lists under that id would have the personal key wrapped to its
/// members: handed over, rotated (a new key linked down to the personal one)
/// or sent with an invitation. The id is refused where it comes in, in any
/// spelling, with any id that is no UUID; and every entry that would read a
/// roster, hand over, rotate, remove, invite or renew refuses it again,
/// whatever put it in `circles`.
@MainActor
final class PersonalSlotCircleTests: XCTestCase {
    private typealias C = Track.CircleManager

    /// The five spellings of the personal key's slot the SDK parses.
    private let spellings = [
        "00000000-0000-0000-0000-000000000000",
        "00000000-0000-0000-0000-000000000000".uppercased(),
        "00000000000000000000000000000000",
        "{00000000-0000-0000-0000-000000000000}",
        "urn:uuid:00000000-0000-0000-0000-000000000000",
    ]

    func testThePersonalSlotInAnySpellingIsNoCircle() {
        for id in spellings {
            XCTAssertTrue(CanonicalId.isPersonalSlot(id), id)
            XCTAssertNil(CanonicalId.circle(id), id)
        }
        XCTAssertEqual(CanonicalId.personalSlot, SelfKeyManager.selfCircleUuid, "the slot SelfKeyManager keeps the key under")
        XCTAssertNil(CanonicalId.circle("family"), "no UUID: no circle")
        XCTAssertNil(CanonicalId.circle(nil))
        let real = UUID().uuidString
        XCTAssertEqual(CanonicalId.circle(real), real.lowercased())
        XCTAssertEqual(CanonicalId.circle(real.lowercased().replacingOccurrences(of: "-", with: "")), real.lowercased())
        XCTAssertFalse(CanonicalId.isPersonalSlot(real))
        XCTAssertFalse(CanonicalId.isPersonalSlot(nil))
    }

    private func row(_ id: String) -> [String: Any] {
        [
            "id": id, "owner_id": UUID().uuidString.lowercased(), "is_owner": true,
            "encrypted_name": ["nonce": "00", "ciphertext": "00"], "day_bucket": 20_000, "member_count": 3,
            "key_rotation_needed": true, "key_version": 1,
        ]
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    /// A listed nil-id row flagged for a rotation, with this account as its
    /// owner, never gets into the circle list, so no sweep, owed rotation or
    /// transition ever sees it; the rest of the page is read. One that is no
    /// UUID goes the same way.
    func testTheCircleListDropsARowNamedByNoCirclesId() throws {
        let good = UUID().uuidString
        let page: [String: Any] = [
            "items": [row(good.uppercased())] + spellings.map(row) + [row("not-a-uuid")],
            "has_more": false,
        ]
        let data = try JSONSerialization.data(withJSONObject: page)
        let circles = try decoder().decode(Paginated<CircleResponse>.self, from: data).items
        XCTAssertEqual(circles.map(\.id), [good.lowercased()], "only the real circle, in its one form")
        XCTAssertTrue(circles.allSatisfy { $0.keyRotationNeeded == true && $0.isOwner })

        for id in spellings + ["not-a-uuid"] {
            let single = try JSONSerialization.data(withJSONObject: row(id))
            XCTAssertThrowsError(try decoder().decode(CircleResponse.self, from: single), id) { error in
                XCTAssertEqual(error as? CanonicalId.NotACircle, CanonicalId.NotACircle(), id)
            }
        }
        // Written back as read: a list saved to the disk cache decodes again.
        let cached = try decoder().decode([CircleResponse].self, from: JSONEncoder().encode(circles))
        XCTAssertEqual(cached.map(\.id), [good.lowercased()])
    }

    /// No invitation to the personal key's slot, or to no UUID, can be accepted:
    /// it never gets into the list.
    func testTheReceivedInvitationsDropOneToNoCirclesId() throws {
        func invitation(_ circleId: String) -> [String: Any] {
            [
                "id": UUID().uuidString.lowercased(), "circle_id": circleId,
                "invited_by": UUID().uuidString.lowercased(), "invite_type": "email",
                "created_day_bucket": 20_000, "expires_day_bucket": 20_007, "has_encrypted_key": false,
            ]
        }
        let good = UUID().uuidString.lowercased()
        let data = try JSONSerialization.data(withJSONObject: [invitation(good)] + spellings.map(invitation) + [invitation("x")])
        let invitations = try decoder().decode(ServedEntries<ReceivedInviteResponse>.self, from: data).items
        XCTAssertEqual(invitations.map(\.circleId), [good])
    }

    /// Whatever put the personal key's slot in a call, no roster is read and
    /// nobody is invited there: each entry refuses it before anything else.
    func testTheRosterAndTheInvitationRefuseThePersonalSlot() async {
        for id in spellings {
            do {
                try await C.shared.loadMembers(for: id)
                XCTFail("a roster read for \(id)")
            } catch C.CircleError.memberNotFound {
            } catch {
                XCTFail("\(id): \(error)")
            }
            do {
                try await C.shared.inviteMember(to: id, email: "someone@example.com")
                XCTFail("an invitation to \(id)")
            } catch C.CircleError.memberNotFound {
            } catch {
                XCTFail("\(id): \(error)")
            }
        }
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

    /// The guard comes first in `body`, before `later` (each of them).
    private func guardsFirst(_ body: String, _ guardLine: String, before later: [String],
                             file: StaticString = #filePath, line: UInt = #line) throws {
        let found = try XCTUnwrap(body.range(of: guardLine), guardLine, file: file, line: line)
        for text in later {
            let after = try XCTUnwrap(body.range(of: text), text, file: file, line: line)
            XCTAssertLessThan(found.upperBound, after.lowerBound, "\(guardLine) before \(text)", file: file, line: line)
        }
    }

    /// A listed nil-id row never reaches prepareKeyRotation or
    /// prepareRecordedRotation; nor delivery, the owed rotation, an eject, a
    /// renewal or the extension's handover.
    func testEveryKeyEntryRefusesThePersonalSlotFirst() throws {
        let circles = try source("App/Managers/CircleManager.swift")
        let rotate = try body(of: "    func rotateCircleKey(for circleId: String) async throws {", until: "    // MARK: - Errors",
                              in: circles)
        try guardsFirst(rotate, "        guard !CanonicalId.isPersonalSlot(circleId) else {\n",
                        before: ["planRotation(", "prepareRecordedChange(", "cryptoManager.prepareKeyRotation(",
                                 "cryptoManager.createKeyChainLink(", "api.rotateKeys("])
        let prepare = try body(of: "    private func prepareRecordedChange(", until: "    private func recordedChangeTaken(", in: circles)
        try guardsFirst(prepare, "        guard !CanonicalId.isPersonalSlot(circle.id) else { throw CircleError.memberNotFound }\n",
                        before: ["recordMemberRows(for: circle.id)", "cryptoManager.prepareRecordedRotation("])
        let eject = try body(of: "    func removeMember(from circleId: String, userId: String) async throws {",
                             until: "    func removesWithoutNewKey(_ circleId: String) -> Bool {", in: circles)
        try guardsFirst(eject, "        guard !CanonicalId.isPersonalSlot(circleId) else { throw CircleError.memberNotFound }\n",
                        before: ["planRotation(", "prepareRecordedChange(", "cryptoManager.prepareKeyRotation("])
        let deliver = try body(of: "    func deliverToConfirmedMembers(circleId: String) async {", until: "\n    }\n", in: circles)
        try guardsFirst(deliver, "        guard !CanonicalId.isPersonalSlot(circleId) else { return }\n",
                        before: ["AccessHandover.mayHandOver(", "cryptoManager.wrapCircleKeyForMemberFull("])
        let owed = try body(of: "    private func rotateOwedNow(_ circleId: String) {", until: "\n    }\n", in: circles)
        try guardsFirst(owed, "        guard !CanonicalId.isPersonalSlot(circleId) else { return }\n",
                        before: ["rotationsInFlight.insert(circleId)", "rotateCircleKey(for: circleId)"])
        // The owner's hand-over: the person's tap, and the record it builds.
        let handOver = try body(of: "    func handOver(_ circleId: String, to target: String, keys: MemberKeyPair?)",
                                until: "    private func handOverWithRecord(", in: circles)
        try guardsFirst(handOver, "        guard !CanonicalId.isPersonalSlot(circleId) else { throw CircleError.memberNotFound }\n",
                        before: ["api.transferOwnership(", "handOverWithRecord("])
        let handOverRecord = try body(of: "    private func handOverWithRecord(", until: "    nonisolated static func handOverRefusedForGood(",
                                      in: circles)
        try guardsFirst(handOverRecord, "        guard !CanonicalId.isPersonalSlot(circle.id) else { throw CircleError.memberNotFound }\n",
                        before: ["planRotation(", "prepareRecordedChange(", "sendRecordedRotation("])
        let roster = try body(of: "    func loadMembers(for circleId: String) async throws {", until: "\n    }\n", in: circles)
        try guardsFirst(roster, "        guard !CanonicalId.isPersonalSlot(circleId) else { throw CircleError.memberNotFound }\n",
                        before: ["api.getCircleRoster(circleId: circleId)"])
        let invite = try body(of: "    func inviteMember(to circleId: String,", until: "\n    }\n", in: circles)
        try guardsFirst(invite, "        guard !CanonicalId.isPersonalSlot(circleId) else { throw CircleError.memberNotFound }\n",
                        before: ["takeTransitionSeedIfNeeded()"])
        let load = try body(of: "    func loadCircles(light: Bool = false) async throws {", until: "    func setActiveCircle(", in: circles)
        XCTAssertTrue(load.contains("                && !changesAwaitingImport.waits($0.id)\n"
                                    + "                && !CanonicalId.isPersonalSlot($0.id)\n"), "the sweep")
        // A listed circle's wrap is never stored into the personal key's slot,
        // and neither is an exported circle's.
        let install = try XCTUnwrap(load.range(of: "            if shouldInstallKey, CanonicalId.circle(response.id) != nil,\n"))
        let firstStore = try XCTUnwrap(load.range(of: "cryptoManager.storeFirstCircleKey("))
        let store = try XCTUnwrap(load.range(of: "try cryptoManager.storeCircleKey("))
        XCTAssertLessThan(install.upperBound, firstStore.lowerBound)
        XCTAssertLessThan(install.upperBound, store.lowerBound)
        // The export's wraps open only in its own key store, for a circle.
        let export = try source("App/Services/DataExportService.swift")
        XCTAssertTrue(export.contains("guard let id = CanonicalId.circle(c.circleId),\n                      !live.hasCircleKey(circleId: id),\n"))

        let renewals = try source("App/Managers/InvitationRenewals.swift")
        XCTAssertTrue(renewals.contains("for circleId in circleIds where !CanonicalId.isPersonalSlot(circleId) {"))
        XCTAssertTrue(renewals.contains("guard let me = AuthManager.shared.userId, !CanonicalId.isPersonalSlot(question.circleId) else { return }"))
        let invites = try source("App/Managers/InvitesManager.swift")
        let accept = try body(of: "    func accept(invite: ReceivedInviteResponse,", until: "\n    }\n", in: invites)
        try guardsFirst(accept, "        guard !CanonicalId.isPersonalSlot(invite.circleId) else {\n", before: ["api.acceptInvite("])
        let handover = try source("NotificationExtension/BackgroundHandover.swift")
        let removed = try XCTUnwrap(handover.range(of: "        targets.removeAll { CanonicalId.isPersonalSlot($0.id) }\n"))
        let loop = try XCTUnwrap(handover.range(of: "        for circle in targets {"))
        XCTAssertLessThan(removed.upperBound, loop.lowerBound, "before any handover")

        // Where the ids come in: the circle list's rows (the app's and the
        // extension's, one shared type) and the invitations.
        let wire = try source("App/Services/CircleWireModels.swift")
        XCTAssertTrue(wire.contains("struct CircleResponse: Codable {\n"))
        XCTAssertTrue(wire.contains("    @ServedCircleId var id: String\n"))
        let api = try source("App/Services/APIService.swift")
        XCTAssertTrue(api.contains("    @ServedCircleId var circleId: String\n    let invitedBy: String"))
        XCTAssertTrue(api.contains("let received: ServedEntries<ReceivedInviteResponse> = try await get(path: \"/api/v1/invites/received\")"))
        XCTAssertTrue(handover.contains("items = try container.decode(ServedEntries<T>.self, forKey: .items).items"),
                      "the extension's page drops such a row too")
    }
}
