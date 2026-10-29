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

/// One member of a circle as iOS gives it to the SDK's refresh-record calls
/// (the SDK's `RecordMember`): `importRefreshRecords`,
/// `refreshEligibility` and `prepareRecordedRotation`.
struct RecordMemberRow: Equatable {
    let userId: String
    /// nil: no published keys. Such a member is listed and nothing more: never
    /// confirmed, matched, vouched for or named in a record.
    let keys: MemberKeyPair?
    /// This device confirms them, with `keys`.
    let confirmed: Bool
    /// On this device's COMPLETE member list now.
    let listed: Bool
    /// The server's word: a transition's roles and the ownership claim only,
    /// never the SDK's eligibility rule.
    let listedRole: CircleRole?
    /// Their invitation and admissions as served; the SDK verifies them.
    let statements: [SignedStatementRecord]
    /// DELIVER only: this device's person chose them with these keys.
    let personConfirmedKeys: Bool
    /// DELIVER only: the server says they hold no copy yet.
    let serverSaysKeyless: Bool
}

/// The mapping from the roster the confirmation pass judged to the SDK's
/// member list. The keys come from the SAME roster the pass judged, never
/// a later fetch, and are optional. Pure.
enum RecordMembers {
    /// Where one member's keys come from.
    enum KeySource: Equatable {
        /// This account's own, from this device.
        case own
        /// The SDK's pins (a confirmed member).
        case pinned
        /// The approval record's (a confirmed receive-only member).
        case receiveOnlyRecord
        /// The roster the pass judged: a member it confirmed that isn't pinned
        /// yet, or one it doesn't confirm (the SDK then uses them only to see
        /// whether the account's own head vouches for them).
        case listed
        /// None published.
        case none
    }

    /// `candidates`: the pass's members (their keys as that roster served
    /// them). `roles`: the same roster's roles. `complete`: that roster was
    /// complete; if not, nobody is listed, so no seen departure counts on it.
    /// `chosen`: this device's person chose them (their approval entry
    /// `isChosen`: an own invitation, the circle created here, "Let them in",
    /// "It's them").
    nonisolated static func rows(
        me: String, myKeys: MemberKeyPair,
        candidates: [String: MembershipCandidate], roles: [String: CircleRole], complete: Bool,
        verdicts: [String: MembershipVerdict], receiveOnlyKeys: [String: MemberKeyPair],
        pinned: (String) -> MemberKeyPair?, chosen: (String) -> Bool
    ) -> [RecordMemberRow] {
        var rows: [RecordMemberRow] = []
        var seen: Set<String> = []
        for (userId, candidate) in candidates.sorted(by: { $0.key < $1.key }) where seen.insert(userId.lowercased()).inserted {
            let isMe = userId.caseInsensitiveCompare(me) == .orderedSame
            let listedKeys = candidate.sharingKeyHex.flatMap { sharing in
                candidate.signingKeyHex.map { MemberKeyPair(sharingKeyHex: sharing, signingKeyHex: $0) }
            }.flatMap { $0.sharingKeyHex.isEmpty || $0.signingKeyHex.isEmpty ? nil : $0 }
            let (keys, source) = Self.keys(isMe: isMe, myKeys: myKeys, verdict: verdicts[userId],
                                           listed: listedKeys, receiveOnly: receiveOnlyKeys[userId],
                                           pinned: pinned(userId))
            // Never confirmed without keys: the SDK refuses that call.
            let confirmed = keys != nil && (isMe || Self.isConfirmed(verdicts[userId]))
            rows.append(RecordMemberRow(
                userId: userId, keys: keys, confirmed: confirmed, listed: complete,
                listedRole: roles[userId], statements: candidate.statements,
                personConfirmedKeys: confirmed && !isMe && chosen(userId)
                    && (source == .pinned || source == .receiveOnlyRecord),
                serverSaysKeyless: candidate.keyVersion == nil))
        }
        // This account, from this device, even on a roster that didn't show it:
        // every record includes it, and the SDK's recipient check matches that
        // entry against this row.
        if !seen.contains(me.lowercased()) {
            rows.append(RecordMemberRow(
                userId: me, keys: myKeys, confirmed: true, listed: false, listedRole: nil, statements: [],
                personConfirmedKeys: false, serverSaysKeyless: false))
        }
        return rows
    }

    /// The keys for one member, and where they come from.
    nonisolated static func keys(isMe: Bool, myKeys: MemberKeyPair, verdict: MembershipVerdict?,
                                 listed: MemberKeyPair?, receiveOnly: MemberKeyPair?,
                                 pinned: MemberKeyPair?) -> (MemberKeyPair?, KeySource) {
        if isMe { return (myKeys, .own) }
        guard case .confirmed(let origin)? = verdict else {
            return listed.map { ($0, .listed) } ?? (nil, .none)
        }
        if origin.isReceiveOnly {
            if let receiveOnly { return (receiveOnly, .receiveOnlyRecord) }
        } else if let pinned {
            return (pinned, .pinned)
        }
        return listed.map { ($0, .listed) } ?? (nil, .none)
    }

    private nonisolated static func isConfirmed(_ verdict: MembershipVerdict?) -> Bool {
        if case .confirmed? = verdict { return true }
        return false
    }
}

extension RecordMemberRow {
    /// The SDK's `RecordMember` for this row: the one place the app builds it.
    var sdkMember: RecordMember {
        RecordMember(
            userId: userId, sharingPublicKeyHex: keys?.sharingKeyHex, signingPublicKeyHex: keys?.signingKeyHex,
            confirmed: confirmed, listed: listed, listedRole: listedRole,
            statements: statements.map {
                PingolinTrackSDK.HeldStatement(statementHex: $0.statementHex, signatureHex: $0.signatureHex)
            },
            personConfirmedKeys: personConfirmedKeys, serverSaysKeyless: serverSaysKeyless)
    }
}

extension PingolinTrackSDK.CryptoManager: RefreshRecordsSDK {
    func importRecords(circleId: String, records: [SignedRefreshRecord], keyChain: [KeyChainLinkData],
                       members: [RecordMemberRow], rosterComplete: Bool, ownHead: SignedCircleHead?,
                       memberHeads: [MemberHead]) throws -> RefreshRecordsReport {
        try importRefreshRecords(circleId: circleId, records: records, keyChain: keyChain,
                                 members: members.map(\.sdkMember), rosterComplete: rosterComplete,
                                 ownHead: ownHead, memberHeads: memberHeads)
    }
}
