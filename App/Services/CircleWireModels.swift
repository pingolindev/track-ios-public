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

// The circle wire shapes the app and its Notification Service Extension both
// read (project.yml compiles this file into both): the extension hands over
// access in the background from the same rows the app decides on. Wire
// format mirrors the server's circle routes; the field names are camelCase
// because both decoders run convertFromSnakeCase.

/// Encrypted blob (nonce + ciphertext, both hex-encoded). Same shape on the
/// way in (request) and the way out (response); aliasing keeps the call sites
/// readable without duplicating storage.
struct EncryptedBlobResponse: Codable, Equatable {
    let nonce: String
    let ciphertext: String
}

typealias EncryptedBlobRequest = EncryptedBlobResponse

struct CircleResponse: Codable {
    /// In its one form (`ServedCircleId`). A row whose id is no circle's (no
    /// UUID, or the personal key's slot in any spelling) is dropped from a
    /// list and refuses any single response.
    @ServedCircleId var id: String
    let ownerId: String
    let isOwner: Bool
    /// Circle name encrypted with the circle key (server-blind).
    let encryptedName: EncryptedBlobResponse
    /// Days since Unix epoch (server avoids fine-grained timestamps for E2EE).
    let dayBucket: Int
    let memberCount: Int
    /// Backend skips this field when false; default to false on the client.
    let keyRotationNeeded: Bool?
    let keyVersion: Int
    let keyRotationRequestedDayBucket: Int?
    let keyRotationDeadlineDayBucket: Int?
    let keyRotationOverdue: Bool?
    /// Circle key wrapped for this user (hex). Absent for newly-joined-via-link
    /// users until they post their key bundle back.
    let encryptedCircleKey: String?
    let circleKeyNonce: String?
    let ephemeralPublicKey: String?
    /// Ed25519 signature over the wrapped circle key, hex-encoded.
    /// Optional — legacy wraps omit it and the SDK grace-accepts (no
    /// verification). When present, the client verifies it against
    /// the signer's key resolved from its OWN pinned member directory
    /// (see `senderUserId`) — never a server-supplied key, which a
    /// malicious relay could forge to match its own wrap.
    let wrapSignature: String?
    /// User id of whoever signed this wrap (circle owner or the last
    /// rotator). The client resolves this id to an Ed25519 signing key in
    /// its locally-pinned member directory and verifies `wrapSignature`
    /// against it. Maps `sender_user_id`; absent on legacy wraps → grace. In
    /// its one form (`ServedOptionalId`), as every served account id is.
    @ServedOptionalId var senderUserId: String?
    /// The caller's OWN privacy posture for this circle (`my_privacy`), exactly
    /// the body `GET /api/v1/privacy/circles/{id}` returns. Embedded so a circle
    /// refresh does not cost one privacy GET per circle.
    ///
    /// Optional, and nil means "fetch it separately": an older backend omits the
    /// key, and a circle with no privacy row may send null. `var … = nil` keeps
    /// the memberwise initializer source-compatible; synthesized decoding still
    /// reads the key when it is present.
    var myPrivacy: PrivacySettingsResponse? = nil
    /// Why `key_rotation_needed` is set (present only while it is):
    /// "member_left", "member_removed", "member_joined", "periodic" or "other".
    /// After a removal or a leave the removed person's key still opens new
    /// locations until the rotation lands, which owners and admins are told.
    var keyRotationCause: String? = nil
    /// The version of the CALLER's own stored wrap — which can be BELOW
    /// `keyVersion` when a rotation left this member pending. Our wrap has to
    /// be installed and verified under THIS version: its signature binds the
    /// version it was made for. nil from an older server or when we hold none.
    var memberKeyVersion: Int? = nil
    /// The version `encryptedName` is sealed under. A first key is checked
    /// against the name only when this is the delivered version; a rotation
    /// may leave the name under an older one. nil from an older server.
    var nameKeyVersion: Int? = nil
    /// Some OTHER active member is owed the current copy: they hold none, an
    /// older one, or asked for a fresh one (absent when false). It only says
    /// WHERE to look — the roster and the rules decide who gets anything. The
    /// notification extension's sweep reads it.
    var deliveryNeeded: Bool? = nil
    /// Owners and admins only: a pending invitation of this circle waits to be
    /// renewed. Only says where to look; this device asks
    /// "Is this really {email}?" only after reading the directory itself.
    var invitesNeedRenewal: Bool? = nil
}

/// Body for `PUT /api/v1/circles/{id}/wrap-signature`.
struct SignOwnWrapRequest: Encodable {
    let keyVersion: Int
    let encryptedCircleKey: EncryptedBlobRequest
    let ephemeralPublicKey: String
    let wrapSignature: String
}

struct CircleMemberResponse: Codable {
    /// Backend serializes its `id` field as `user_id` for clarity. In its one
    /// form (`ServedId`): a row naming this account in another spelling is
    /// this account's, and a row naming nobody is dropped from the list.
    @ServedId var userId: String
    /// Plaintext display-name fallback for clients that don't decrypt
    /// `encrypted_display_name`.
    let displayName: String?
    let encryptedDisplayName: EncryptedBlobResponse?
    let role: String
    let encryptedCircleKey: EncryptedBlobResponse
    let ephemeralPublicKey: String
    let canSeeHistory: Bool
    let canSeeRealtime: Bool
    /// May this member rotate the circle key? The server gates
    /// POST /circles/:id/rotate-keys on it, owners get it at creation, and
    /// update_member_role is the only thing that grants it to anyone else.
    ///
    /// OPTIONAL on purpose. Codable drops unknown keys silently, so a field
    /// that is not declared goes unread; making it non-optional would swing the
    /// failure the other way and break the whole member-list decode against any
    /// response that omits it. nil means "not known from this response", which
    /// the rotation sweep treats as "fall back to ownership".
    let canRotateKeys: Bool?
    let status: String
    let joinedDayBucket: Int?
    let sharingPublicKey: String?
    /// Member's Ed25519 verifying key (hex or base64). Used by
    /// the TOFU pinner + safety-number screen. Optional: an account
    /// that never published a signing key has none.
    let signingPublicKey: String?
    /// The version of the circle this member's stored copy opens; absent when
    /// the server holds none for them.
    var keyVersion: Int? = nil
    /// Who made (and signed) this member's stored copy, and the signature — the
    /// backfill checks a trusted member already handed it to them.
    var wrapSignature: String? = nil
    @ServedOptionalId var wrapSignerUserId: String? = nil
    /// The signed invitation this member joined with (absent for one sent
    /// from an older app).
    var invitation: MembershipStatementResponse? = nil
    /// Admissions (kind 3) owners and admins signed about this member.
    var vouches: [MembershipStatementResponse]? = nil
    /// They asked for a fresh copy of the circle (`POST …/access/request`).
    var accessRequested: Bool? = nil
    /// The server has told this member, by push and email, that their app is
    /// too old to be let back in (`POST …/update-request`), and it still is.
    /// The others' apps say so instead of asking anyone to pass it on.
    var updateRequested: Bool? = nil
    /// Why their position may not be updating here: "on", "paused" or "off"
    /// (`MemberSharingStatus`). Absent from an older server, read as "on".
    var locationSharing: String? = nil
    /// When a timed pause ends, as text: see `MemberSharingStatus.wireDate`
    /// for why this is not a `Date`.
    var sharingPausedUntil: String? = nil
    /// Whether their location history is shown to this circle: "on" or "off"
    /// (`history_sharing`). Absent from an older server, read as "on".
    var historySharing: String? = nil
}

/// A signed membership statement as the roster carries it: the exact bytes
/// that were signed and the signature, both hex.
struct MembershipStatementResponse: Codable, Equatable {
    let statement: String
    let signature: String
    /// Who the server says signed it; the statement names its own signer, which
    /// is what counts.
    var signerUserId: String? = nil
}

struct PrivacySettingsResponse: Codable {
    let id: String
    let circleId: String
    let sharingMode: String
    let approximateRadiusMiles: Int?
    let approximateUntil: String?
    let pausedUntil: String?
    let shareRealtime: Bool
    let shareHistory: Bool
    let shareBattery: Bool
    let primaryDeviceId: String?
    let primaryDevicePseudonym: String?
    let showAllDevices: Bool
    /// Opt-out consent (default true). Optional to tolerate an older
    /// backend that doesn't send it; callers treat nil as true.
    let allowAlertsOnMe: Bool?
    let createdDayBucket: Int?
    let updatedDayBucket: Int?
    /// While paused, the mode the pause returns to: "exact" or "approximate".
    /// nil when not paused, and from an older server: read as exact.
    var modeBeforePause: String? = nil
    /// The spans in which ingest drops this account's points to the circle,
    /// by the server's clock, ascending: every one that has not ended or
    /// ended within the last 72 hours. nil from an older server.
    var notSharingIntervals: [NotSharingIntervalResponse]? = nil
    /// The spans in which this account's points to the circle had to be
    /// coarsened, and to what, ascending: every one that has not ended or
    /// ended within the last 72 hours. nil from an older server.
    var approximateIntervals: [ApproximateIntervalResponse]? = nil
}

/// One of `PrivacySettingsResponse.approximateIntervals`.
struct ApproximateIntervalResponse: Codable, Equatable {
    let start: String
    /// nil while it runs.
    let end: String?
    /// The bubble then, in miles. Optional so one span without it cannot fail
    /// the whole row: it reads as the largest a member can set.
    let radiusMiles: Int?
}

/// One of `PrivacySettingsResponse.notSharingIntervals`, RFC 3339 strings as
/// the server writes them (a `Date` field would fail the whole body on a
/// whole-second stamp).
struct NotSharingIntervalResponse: Codable, Equatable {
    let start: String
    /// Its end: a timed pause's `paused_until`, the planned end while it runs.
    /// nil while it runs with no end known (an indefinite pause, real time off).
    let end: String?
}
