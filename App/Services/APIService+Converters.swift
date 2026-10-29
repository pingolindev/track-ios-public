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

// Response DTO -> domain model conversions used by the Manager layer.
//
// Some responses carry only plaintext metadata (ids, flags, timestamps) and can
// be converted with a pure field map. Others carry encrypted payloads
// (place names, check-in messages, SOS locations) that can only be turned into
// full Model values after decryption with the relevant circle key. Those are
// not covered here — managers build them explicitly via CryptoManager.

extension CircleResponse {
    /// Hydrate the wire response into a Circle model. The encrypted name needs
    /// the circle key to decrypt — callers that have it pass the plaintext;
    /// without it the circle is LOCKED: it carries the one placeholder name and
    /// a reason (`lockReason`, `.keyUnavailable` when the caller knows none),
    /// so the UI can explain the cause instead of showing a bare label. A
    /// caller may also lock a circle whose name DID decrypt, by passing a reason.
    func toModel(name decryptedName: String? = nil, lockReason: CircleLockReason? = nil,
                 nameOpenedUnder: Int32? = nil) -> Circle {
        Circle(
            id: id,
            name: decryptedName ?? Circle.lockedPlaceholderName,
            encryptedKey: encryptedCircleKey,
            isOwner: isOwner,
            keyRotationNeeded: keyRotationNeeded ?? false,
            keyVersion: keyVersion,
            createdAt: Date(timeIntervalSince1970: TimeInterval(dayBucket) * 86400),
            // A decrypted name can still come with a reason: a circle whose
            // newer key has not reached this device (see CircleManager).
            lockReason: decryptedName == nil ? (lockReason ?? .keyUnavailable) : lockReason,
            keyRotationCause: (keyRotationNeeded ?? false) ? keyRotationCause : nil,
            nameKeyVersion: nameKeyVersion,
            nameOpenedUnder: decryptedName == nil ? nil : nameOpenedUnder
        )
    }
}

extension CircleMemberResponse {
    func toModel(in circleId: String) -> CircleMember {
        CircleMember(
            circleId: circleId,
            userId: userId,
            displayName: displayName ?? "Member",
            role: CircleMember.MemberRole(rawValue: role) ?? .member,
            canSeeRealtime: canSeeRealtime,
            canSeeHistory: canSeeHistory,
            // A response that omits the field falls back to the role. Owners
            // always hold the bit server-side, so this agrees with the server
            // for the only case it can be inferred from.
            canRotateKeys: canRotateKeys ?? (role == "owner"),
            joinedAt: joinedDayBucket
                .map { Date(timeIntervalSince1970: TimeInterval($0) * 86400) } ?? Date(),
            updateRequested: updateRequested ?? false,
            locationSharing: locationSharing,
            sharingPausedUntil: MemberSharingStatus.wireDate(sharingPausedUntil),
            historySharing: historySharing
        )
    }
}

extension CircleKeyResponse {
    // A CircleKeyResponse is the oblivious-key-distribution form returned by
    // GET /api/v1/circles/keys. Managers typically pair it with the matching
    // CircleResponse to hydrate keyVersion.
    func merged(into circle: Circle) -> Circle {
        Circle(
            id: circle.id,
            name: circle.name,
            // The wrap is a {nonce, ciphertext} pair + `keyVersion`, not a bare
            // `encryptedKey` string + `version`. Circle.encryptedKey
            // is the legacy String? mirror; keep the ciphertext half to match
            // CircleResponse.toModel's semantics.
            encryptedKey: encryptedCircleKey.ciphertext,
            isOwner: circle.isOwner,
            keyRotationNeeded: circle.keyRotationNeeded,
            keyVersion: keyVersion,
            createdAt: circle.createdAt,
            lockReason: circle.lockReason,
            keyRotationCause: circle.keyRotationCause,
            nameKeyVersion: circle.nameKeyVersion
        )
    }
}
