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

import Foundation
import PingolinTrackSDK

/// The SDK's refresh-record calls as the app uses them, with its own member
/// rows (`RecordMemberRow`). `CryptoManager`'s conformance is the one place
/// that builds the SDK's `RecordMember`; tests pass their own.
protocol RefreshRecordsSDK: AnyObject {
    func refreshHeadVersions() -> [String: Int32]
    func circleHasRefreshRecords(circleId: String) -> Bool
    func noteCircleHasRecords(circleId: String)
    func signingPublicKeyHex() throws -> String
    func verifyCircleHead(headHex: String, signatureHex: String, signerSigningPublicKeyHex: String) throws -> CircleHead?
    func importRecords(circleId: String, records: [SignedRefreshRecord], keyChain: [KeyChainLinkData],
                       members: [RecordMemberRow], rosterComplete: Bool, ownHead: SignedCircleHead?,
                       memberHeads: [MemberHead]) throws -> RefreshRecordsReport
}

/// The records import that follows every key import: one records read for
/// every circle, then each circle's records checked by the SDK against the
/// member list its last roster pass judged. What the reports call for is
/// the caller's (`Outcome`).
@MainActor
enum RefreshRecordsSync {
    /// What this device knows of one circle for the import.
    struct CircleInput {
        /// From the circle's last roster pass; nil before one.
        let members: [RecordMemberRow]?
        /// That roster was complete.
        let rosterComplete: Bool
        /// The circle's key chain from this key import.
        let keyChain: [KeyChainLinkData]
    }

    enum Outcome: Equatable {
        /// No record served or held, and no head seen: a circle without
        /// records, on the rules without records (a transition is due from
        /// an owner or admin).
        case legacy
        /// No record held, but a head proves records exist: latched,
        /// it waits for them, and is never legacy again here.
        case latched
        /// Imported, with the circle's served heads (the account's own is
        /// published again from them). The report's `forked`: seal,
        /// deliver and rotate nothing ("Waiting to sync").
        case imported(RefreshRecordsReport, heads: [ServedCircleHead])
        /// Not imported this time: no roster pass yet, or the SDK refused the
        /// call. Nothing changed; the next key import tries again.
        case notNow
    }

    /// One pass. Nil when the records read got no answer, or a reply that
    /// doesn't hold together (`RefreshRecordsReader`): nothing changes then.
    static func run(me: String, inputs: [String: CircleInput], sdk: RefreshRecordsSDK,
                    page: ([String: Int32]) async throws -> RefreshRecordsPage) async -> [String: Outcome]? {
        guard let read = await RefreshRecordsReader.read(since: sdk.refreshHeadVersions(), page: page) else {
            return nil
        }
        var outcomes: [String: Outcome] = [:]
        for served in read {
            let circleId = served.circleId
            let input = inputs.first { $0.key.caseInsensitiveCompare(circleId) == .orderedSame }?.value
            let ownServed = served.heads.first { $0.userId.caseInsensitiveCompare(me) == .orderedSame }
            let ownHead = ownServed.map { SignedCircleHead(headHex: $0.head, signatureHex: $0.signature) }
            // The heads of the members this device confirms, with the keys it
            // confirms them by (the SDK verifies each under those).
            let confirmed = (input?.members ?? []).filter { $0.confirmed && $0.keys != nil }
            let memberHeads = served.heads.compactMap { head -> MemberHead? in
                guard head.userId.caseInsensitiveCompare(me) != .orderedSame,
                      confirmed.contains(where: { $0.userId.caseInsensitiveCompare(head.userId) == .orderedSame })
                else { return nil }
                return MemberHead(userId: head.userId,
                                  head: SignedCircleHead(headHex: head.head, signatureHex: head.signature))
            }
            if served.records.isEmpty && !sdk.circleHasRefreshRecords(circleId: circleId) {
                // No record anywhere here. A head that verifies (the account's
                // own under its current key, or a confirmed member's under the
                // key this device confirms) proves records exist: the server is
                // withholding them, and the circle waits.
                if headProvesRecords(circleId: circleId, me: me, own: ownServed, members: confirmed,
                                     heads: served.heads, sdk: sdk) {
                    sdk.noteCircleHasRecords(circleId: circleId)
                    outcomes[circleId] = .latched
                } else {
                    outcomes[circleId] = .legacy
                }
                continue
            }
            guard let input, let members = input.members else {
                outcomes[circleId] = .notNow
                continue
            }
            do {
                let report = try sdk.importRecords(
                    circleId: circleId,
                    records: served.records.map { SignedRefreshRecord(recordHex: $0.record, signatureHex: $0.signature) },
                    keyChain: input.keyChain, members: members, rosterComplete: input.rosterComplete,
                    ownHead: ownHead, memberHeads: memberHeads)
                outcomes[circleId] = .imported(report, heads: served.heads)
            } catch {
                PendingChangeRunner.log.error("circle \(circleId, privacy: .public): records not imported: \(String(describing: error), privacy: .public)")
                outcomes[circleId] = .notNow
            }
        }
        return outcomes
    }

    /// Whether a served head proves this circle has records: one that verifies
    /// and names this circle and its signer.
    nonisolated static func headProvesRecords(circleId: String, me: String, own: ServedCircleHead?,
                                              members: [RecordMemberRow], heads: [ServedCircleHead],
                                              sdk: RefreshRecordsSDK) -> Bool {
        func verifies(_ head: ServedCircleHead, under key: String?) -> Bool {
            guard let key, let verified = try? sdk.verifyCircleHead(
                headHex: head.head, signatureHex: head.signature, signerSigningPublicKeyHex: key) else { return false }
            return verified.circleId.caseInsensitiveCompare(circleId) == .orderedSame
                && verified.userId.caseInsensitiveCompare(head.userId) == .orderedSame
        }
        if let own, verifies(own, under: try? sdk.signingPublicKeyHex()) { return true }
        return heads.contains { head in
            guard head.userId.caseInsensitiveCompare(me) != .orderedSame,
                  let member = members.first(where: { $0.userId.caseInsensitiveCompare(head.userId) == .orderedSame })
            else { return false }
            return member.confirmed && verifies(head, under: member.keys?.signingKeyHex)
        }
    }
}
