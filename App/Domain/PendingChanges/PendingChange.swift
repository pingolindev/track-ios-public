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
import CryptoKit

/// A person's write that was refused only because this device is behind in its
/// circle: kept here and carried out by the same code path the button uses once
/// this device holds the circle's current version ("waiting to sync" changes
/// that go through by themselves).
///
/// It stores what the person asked for and its inputs, as plain values: an
/// email, a place id, a message, a coordinate (already coarsened or left out as
/// the circle's setting said), an answer, the keys it was about. Never bytes that
/// were sealed or signed, a version number, a wrap or a key: every seal and
/// every signature is made at run time, at the version current then, by the
/// live path. The kinds that sign keep only the ids of the statements their runs
/// signed (`signedIds`).
///
/// Device-local and per account: kept in this account's file only
/// (`PendingChangeStore`), wiped at sign-out and on an account switch, kept
/// across a session expiry.
struct PendingChange: Codable, Equatable, Identifiable {
    /// The kinds of change this app can queue. The raw
    /// values are stored identifiers; the numbering has
    /// gaps because it also counts kinds this app does
    /// not have.
    enum Kind: String, Codable, CaseIterable {
        case invite = "K1"
        case makeAdmin = "K2"
        case letIn = "K3"
        case renewInvitation = "K4"
        case checkIn = "K5"
        case destination = "K6"
        case arrived = "K7"
        case sharePlace = "K9"
        case editPlace = "K12"
        case memberPlaceAlert = "K13"
        case batteryAlert = "K15"
        case alertChange = "K16"
        case inactivityAlert = "K17"
        case renameCircle = "K18"

        /// How long it may wait before it is dropped as too old, from
        /// when it was queued. Limits that depend on the change's own
        /// dates (as for `renewInvitation`) are set when it is queued.
        var ageLimit: TimeInterval {
            switch self {
            case .checkIn, .destination: return 24 * 3600
            case .arrived: return 2 * 3600
            default: return 7 * 24 * 3600
            }
        }

        /// The kinds that sign a statement and keep its id.
        var signs: Bool { self == .invite || self == .makeAdmin || self == .letIn }
    }

    /// Where a change stands. Done, dropped and cancelled changes are
    /// deleted, so there is no stored "done" to flip back to waiting.
    enum State: Codable, Equatable {
        case waiting
        /// Being sent now ("Sending…"): it can't be cancelled until it ends.
        case running(attemptId: String, startedAt: Date)
        /// Waiting for a decision only the person can make.
        case needsPerson(NeedsPerson)
        /// Cancelled after a lost answer, while the runner looks whether it went
        /// out (the kinds that sign): "Cancelling…".
        case cancelling
        /// Ended while the look couldn't run: kept only for its ids, not
        /// shown as pending, settled by the next look.
        case settling
    }

    enum NeedsPerson: String, Codable {
        /// The subject's keys differ from what the person saw: asked once.
        case keysChanged
        /// Signing needs the password on this device first.
        case password
    }

    let id: String
    let account: String
    let circleId: String
    let kind: Kind
    var inputs: Inputs
    var seen: Seen
    /// The kinds that sign (`Kind.signs`): the id of every statement a run
    /// signed, saved before its request went out. Ids only: never a
    /// statement or a signature.
    var signedIds: [String]
    let createdAt: Date
    /// Its age limit. A merge restarts it from the new tap; the
    /// change keeps its id and its place in the queue (`createdAt`).
    var expiresAt: Date
    var state: State
    var attempts: Int
    var nextAttemptAt: Date?
    /// Backoff and diagnostics only; never consulted by a check (the look
    /// after a lost answer depends on `signedIds` alone).
    var lastOutcome: String?
    /// A request for it went out and got no answer: it may have been stored.
    var mayHaveGoneOut: Bool
    /// The names its lines use, as they were when it was queued, so a line
    /// about a deleted place or a departed member still names them.
    var labels: Labels

    // The fields below are all optional: a file written without them
    // still decodes (a missing key reads as nil).

    /// When its last request went out (written with the running mark, before
    /// the request). The look after a lost answer waits
    /// `PendingChangeRunner.lookAfterSend` after it: a request the server is
    /// still working on isn't "not held".
    var lastSentAt: Date? = nil
    /// `.makeAdmin`: the id of its admission the server holds, once known (a
    /// 2xx, or a look). The run then only changes the role.
    var heldStatementId: String? = nil
    /// `.invite`: whom each signed invitation to an account names and when it
    /// expires, by statement id, so the held one becomes this device's invitee
    /// record even after a lost answer.
    var signedInvitations: [String: SignedInvitation]? = nil
    /// A `settling` change ends with this line if none of its statements turns
    /// out held (with none if one does: then it went out).
    var parkedLine: String? = nil
    /// `.invite`, `.renewInvitation`: its address couldn't be checked the last
    /// time it was tried (the server's 503 `lookup_unavailable`, offline, a
    /// timeout, a 5xx), and its line says so. Nothing was signed for it then.
    var addressUnchecked: Bool? = nil
    /// The circle's key version this device held at the tap (nil: none): a
    /// change that would sign ends when the member was removed at a later
    /// version. A new tap is a new decision, and brings its own.
    var versionAtTap: Int? = nil

    struct SignedInvitation: Codable, Equatable {
        var subjectUserId: String
        var expiresAt: Int64
    }

    struct Labels: Codable, Equatable {
        var circleName: String?
        /// The email, member name, place name or destination name it is about.
        var subject: String?
        /// The member an alert is about, for "{name} is no longer in {circle}".
        var member: String?
    }

    /// Facts captured when queued that the re-check compares against.
    struct Seen: Codable, Equatable {
        /// `.invite` (once "Is this really…?" was answered), `.makeAdmin`,
        /// `.letIn`, `.renewInvitation`: the keys the person decided on.
        /// Nothing else is ever signed for.
        var keys: MemberKeyPair?
        /// `.invite`, `.makeAdmin`, `.letIn`,
        /// `.renewInvitation`: the one question was
        /// already asked again.
        var askedAgain: Bool = false
        /// `.checkIn`, `.arrived`: the circle's privacy
        /// setting when queued.
        var privacy: QueuedPrivacy?
        /// `.editPlace`: the place as shown when the edit was made.
        var place: PlaceFields?
        /// `.renameCircle`: the circle's name as shown.
        var name: String?
        /// `.invite`: the account a question was about, which
        /// "It's them" binds.
        var subjectUserId: String?
        /// `.alertChange`: the rule's fields when the change was made: a
        /// rule changed on another device meanwhile is never overwritten.
        var rule: AlertChangeInputs?
    }

    /// The circle's privacy setting when a position was queued. The stored
    /// coordinate already has it applied; at send the stricter of this and the
    /// setting then goes out.
    enum QueuedPrivacy: Codable, Equatable {
        /// Paused, real-time off, or not known: no position.
        case none
        /// Approximate: coarsened to cells of this radius, in meters.
        case approximate(radiusMeters: Double)
        case precise
    }

    struct PlaceFields: Codable, Equatable {
        var name: String
        var latitude: Double
        var longitude: Double
        var radius: Double
        var icon: String
        var color: String
    }

    /// What the person asked for, per kind: plain values only.
    enum Inputs: Codable, Equatable {
        case checkIn(CheckInInputs)
        case destination(DestinationInputs)
        case arrived(ArrivedInputs)
        case sharePlace(placeId: String)
        case editPlace(placeId: String, fields: PlaceFields)
        case memberPlaceAlert(PlaceAlertInputs)
        case batteryAlert(BatteryAlertInputs)
        case alertChange(AlertChangeInputs)
        case inactivityAlert(InactivityAlertInputs)
        case renameCircle(newName: String)
        case invite(InviteInputs)
        case makeAdmin(memberId: String)
        case letIn(LetInInputs)
        case renewInvitation(RenewalInputs)
    }

    struct CheckInInputs: Codable, Equatable {
        var type: String
        var message: String?
        /// As the circle's setting allowed when queued: coarsened, or none.
        var latitude: Double?
        var longitude: Double?
        var placeId: String?
        /// When the person checked in: what the check-in says.
        var checkedInAt: Date
    }

    struct DestinationInputs: Codable, Equatable {
        var name: String?
        var latitude: Double
        var longitude: Double
        var eta: Date?
        var notifyArrival: Bool
    }

    struct ArrivedInputs: Codable, Equatable {
        var destinationId: String
        var arrivedAt: Date
        /// As for a check-in: coarsened, or none.
        var latitude: Double?
        var longitude: Double?
    }

    struct PlaceAlertInputs: Codable, Equatable {
        var placeId: String
        var targetUserId: String?
        var alertType: String
        var activeDays: [String]?
        var activeStartTime: String?
        var activeEndTime: String?
        var notifyPush: Bool
        var notifyEmail: Bool
        var notifySms: Bool
    }

    struct BatteryAlertInputs: Codable, Equatable {
        var targetUserId: String
        var threshold: Int
        var notifyPush: Bool
        var notifyEmail: Bool
        var cooldownMinutes: Int
    }

    /// Only the changed fields.
    struct AlertChangeInputs: Codable, Equatable {
        var ruleId: String
        var threshold: Int?
        var isActive: Bool?
        var notifyPush: Bool?
        var notifyEmail: Bool?
        var cooldownMinutes: Int?
    }

    struct InactivityAlertInputs: Codable, Equatable {
        /// Nil: the person themselves ("me").
        var memberIds: [String]?
        var everyone: Bool
        var timeoutMinutes: Int
        var notifyPush: Bool
        var notifyEmail: Bool
        var cooldownMinutes: Int
        var notifyOnReturn: Bool
    }

    struct InviteInputs: Codable, Equatable {
        /// Lower-cased.
        var email: String
        /// Set once the person answered "Is this really {email}?": their account.
        var confirmedUserId: String?
    }

    struct LetInInputs: Codable, Equatable {
        var memberId: String
        var questionKind: String
        /// A late joiner's question: asked again in its own words.
        var lateJoiner: LateJoiner.Ask? = nil
    }

    struct RenewalInputs: Codable, Equatable {
        var inviteId: String
        var statementId: String
        var inviteeUserId: String
        var email: String
    }

    /// Whether this change still shows in the circle's pending list (a
    /// `settling` record is kept only for its ids).
    var isPending: Bool { state != .settling }

    var isSending: Bool {
        if case .running = state { return true }
        return false
    }
}

/// A dropped change's one line, shown until it has been seen (at most 7 days)
/// and then deleted.
struct DroppedNotice: Codable, Equatable, Identifiable {
    let id: String
    let account: String
    let circleId: String
    let line: String
    let createdAt: Date
    var seenAt: Date?

    static let maxAge: TimeInterval = 7 * 24 * 3600
}

extension PendingChange {
    /// The change's id as the request id a create carries: the change
    /// id itself, or, for one of several rows it creates, a name-based UUID
    /// from the change id and the row's own id, so a re-run sends the same ids
    /// and the second row never gets the first one back.
    func requestId(for part: String? = nil) -> String {
        guard let part else { return id }
        return Self.nameBasedUUID(namespace: id, name: part)
    }

    /// A version-5-style UUID (SHA-1 of the namespace and the name), stable
    /// across runs and devices.
    static func nameBasedUUID(namespace: String, name: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data((namespace.lowercased() + ":" + name.lowercased()).utf8))
        var bytes = Array(Array(digest).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let parts = [hex.prefix(8), hex.dropFirst(8).prefix(4), hex.dropFirst(12).prefix(4),
                     hex.dropFirst(16).prefix(4), hex.dropFirst(20)]
        return parts.map(String.init).joined(separator: "-")
    }

    /// A statement id as the look route takes it: 16 bytes of hex, lower case.
    static func wireStatementId(_ id: String) -> String {
        id.replacingOccurrences(of: "-", with: "").lowercased()
    }
}
