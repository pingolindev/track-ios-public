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

/// The late-joiner question, run against the vector the three apps share
/// (Fixtures/late-joiner-vector.json). Every case, the batch and the
/// closing.
///
/// WHY THIS IS WORTH TESTING
///   Who is asked, which case and which lines, once per invitation and past
///   the cap of 3, must come out the same on the web, Android and iOS: the
///   question is answered on one device and closes on every other. The cases
///   are read in one fixed order (ran out, then a signer who is not an owner
///   or admin in the chain, then an e-mail address), and past the cap the
///   questions already raised come first, then the oldest — never the rows'
///   order.
final class LateJoinerVectorTests: XCTestCase {

    private func vector() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/late-joiner-vector.json")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        return try XCTUnwrap(object as? [String: Any])
    }

    private func role(_ value: Any?) -> CircleRole? {
        switch value as? String {
        case "owner": return .owner
        case "admin": return .admin
        case "member": return .member
        default: return nil
        }
    }

    private func keys(_ value: Any?) -> MemberKeyPair? {
        guard let pair = value as? [String: Any], let sharing = pair["sharing"] as? String,
              let signing = pair["signing"] as? String else { return nil }
        return MemberKeyPair(sharingKeyHex: sharing, signingKeyHex: signing)
    }

    private func invitation(_ value: Any?) throws -> LateJoiner.Invitation {
        let fields = try XCTUnwrap(value as? [String: Any])
        return LateJoiner.Invitation(
            statementId: try XCTUnwrap(fields["id"] as? String), signerUserId: try XCTUnwrap(fields["signer"] as? String),
            person: try XCTUnwrap(fields["person"] as? String),
            issuedAt: try XCTUnwrap((fields["issuedAt"] as? NSNumber)?.int64Value),
            signedBeforeReset: fields["signedBeforeReset"] as? Bool, boundKeys: keys(fields["boundKeys"]))
    }

    private func standing(_ value: Any?) throws -> LateJoiner.Standing {
        let flags = try XCTUnwrap(value as? [String: Bool])
        return LateJoiner.Standing(
            eligible: flags["eligible"] ?? false, invitationExpired: flags["invitationExpired"] ?? false,
            signerNotChainAdmin: flags["signerNotChainAdmin"] ?? false,
            emailInvitationWithoutSignedId: flags["emailInvitationWithoutSignedId"] ?? false,
            removedByOwnerOrAdmin: flags["removedByOwnerOrAdmin"] ?? false)
    }

    private func caseName(_ kind: LateJoiner.Case) -> String {
        switch kind {
        case .ranOut: return "ranOut"
        case .inviterNotChainAdmin: return "inviterNotChainAdmin"
        case .emailInvitation: return "emailInvitation"
        case .ownInvitationBeforeReset: return "ownInvitationBeforeReset"
        }
    }

    func testEveryCase() throws {
        let cases = try XCTUnwrap(try vector()["cases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 22, "V1–V21 and V2b")
        for vectorCase in cases {
            let name = try XCTUnwrap(vectorCase["name"] as? String)
            let input = try XCTUnwrap(vectorCase["input"] as? [String: Any])
            let expect = try XCTUnwrap(vectorCase["expect"] as? [String: Any])
            let ask = LateJoiner.ask(
                me: try XCTUnwrap(input["me"] as? String), myChainRole: role(input["myChainRole"]),
                invitation: try invitation(input["invitation"]), standing: try standing(input["standing"]),
                signerChainRole: role(input["signerChainRole"]), signerName: input["signerName"] as? String,
                answered: try (input["answered"] as? [Any] ?? []).map { try invitation($0) },
                pending: try (input["pending"] as? [Any] ?? []).map { try invitation($0) },
                pendingCapped: (input["pendingCapped"] as? Int) ?? 0, listedKeys: keys(input["listedKeys"]))
            guard expect["ask"] as? Bool == true else {
                XCTAssertNil(ask, name)
                continue
            }
            let asked = try XCTUnwrap(ask, name)
            XCTAssertEqual(caseName(asked.kind), expect["case"] as? String, name)
            XCTAssertEqual(asked.inviterLine, expect["inviterLine"] as? String, name)
            XCTAssertEqual(asked.capped, expect["capped"] as? Bool, name)
            let body = LateJoiner.body(asked)
            XCTAssertEqual(body.isEmpty ? [] : body.components(separatedBy: "\n"), expect["lines"] as? [String], name)
        }
    }

    /// Past the cap, the already raised first, then the oldest; a chain
    /// owner's own invitation uncapped.
    func testTheBatch() throws {
        let batch = try XCTUnwrap(try vector()["batch"] as? [[String: Any]])
        XCTAssertEqual(batch.count, 1)
        for vectorCase in batch {
            let name = try XCTUnwrap(vectorCase["name"] as? String)
            let input = try XCTUnwrap(vectorCase["input"] as? [String: Any])
            let expect = try XCTUnwrap(vectorCase["expect"] as? [String: Any])
            let me = try XCTUnwrap(input["me"] as? String)
            let standingFor = input["standingFor"] as? [String: Any] ?? [:]
            var found: [(member: String, ask: LateJoiner.Ask)] = []
            var raised = Set<String>()
            for candidate in try XCTUnwrap(input["candidates"] as? [[String: Any]]) {
                let member = try XCTUnwrap(candidate["member"] as? String)
                if candidate["raised"] as? Bool == true { raised.insert(CanonicalId.key(member)) }
                guard let ask = LateJoiner.ask(
                    me: me, myChainRole: role(input["myChainRole"]), invitation: try invitation(candidate["invitation"]),
                    standing: try standing(standingFor[member] ?? input["standingAll"]),
                    signerChainRole: role(candidate["signerChainRole"]), signerName: nil, answered: [],
                    pendingCapped: 0) else { continue }
                found.append((member: member, ask: ask))
            }
            XCTAssertEqual(Set(LateJoiner.chosen(found, raised: raised)), Set(try XCTUnwrap(expect["asked"] as? [String])), name)
        }
    }

    /// A raised question closes when the eligibility check lets the member
    /// in or they leave the list; one it still doesn't allow stays.
    func testTheClosing() throws {
        let closing = try XCTUnwrap(try vector()["closing"] as? [[String: Any]])
        XCTAssertEqual(closing.count, 1)
        for vectorCase in closing {
            let name = try XCTUnwrap(vectorCase["name"] as? String)
            let input = try XCTUnwrap(vectorCase["input"] as? [String: Any])
            let expect = try XCTUnwrap(vectorCase["expect"] as? [String: Any])
            var invitationOf: [String: String] = [:]
            for pair in try XCTUnwrap(input["raised"] as? [[Any]]) {
                invitationOf[try XCTUnwrap(pair.first as? String)] = try invitation(pair.last).statementId
            }
            var eligible: [String: Bool] = [:]
            for row in try XCTUnwrap(input["eligibility"] as? [[String: Any]]) {
                eligible[try XCTUnwrap(row["userId"] as? String).lowercased()] = row["eligible"] as? Bool
            }
            let closed = LateJoiner.closed(queued: invitationOf.keys.sorted(), eligible: eligible)
            XCTAssertEqual(Set(closed.compactMap { invitationOf[$0] }), Set(try XCTUnwrap(expect["closed"] as? [String])), name)
        }
    }

    /// The fixture is the shared vector, with its ordering decisions
    /// recorded in it.
    func testTheFixtureCarriesItsDecisions() throws {
        let decisions = try XCTUnwrap(try vector()["decisions"] as? [String: Any])
        for key in ["D1", "D2", "D3"] {
            XCTAssertFalse((decisions[key] as? String ?? "").isEmpty, key)
        }
    }
}
