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
import CoreLocation

/// Each kind's re-check and run. A run calls the SAME function the button
/// calls, with the stored inputs and the change passed as `waiting`: that
/// function keeps its own gate, and a refusal while behind comes back to the
/// runner instead of being queued again.
enum PendingChangeKinds {
    @MainActor
    static var live: [PendingChange.Kind: PendingChangeHandler] {
        [
            .invite: InviteKind(),
            .makeAdmin: MakeAdminKind(),
            .letIn: LetInKind(),
            .renewInvitation: RenewInvitationKind(),
            .checkIn: CheckInKind(),
            .destination: DestinationKind(),
            .arrived: ArrivedKind(),
            .sharePlace: SharePlaceKind(),
            .editPlace: EditPlaceKind(),
            .memberPlaceAlert: PlaceAlertKind(),
            .batteryAlert: BatteryAlertKind(),
            .alertChange: AlertChangeKind(),
            .inactivityAlert: InactivityAlertKind(),
            .renameCircle: RenameCircleKind(),
        ]
    }

    /// The position a waiting check-in or arrival sends: the STRICTER of the
    /// circle's setting when it was queued (already applied to the stored
    /// coordinate) and the setting now. Paused, real-time off or not known at
    /// either time: none. Approximate at either time: coarsened, to the larger
    /// cell, and never with an exact place.
    nonisolated static func stricterPosition(
        latitude: Double?, longitude: Double?, placeId: String?,
        queued: PendingChange.QueuedPrivacy?, atSend: PendingChange.QueuedPrivacy
    ) -> (latitude: Double?, longitude: Double?, placeId: String?) {
        guard let latitude, let longitude else { return (nil, nil, nil) }
        let both = [queued ?? .none, atSend]
        if both.contains(.none) { return (nil, nil, nil) }
        let radii = both.compactMap { privacy -> Double? in
            if case .approximate(let radius) = privacy { return radius }
            return nil
        }
        if let radius = radii.max() {
            let (lat, lng) = LocationCoarsener.coarsenLocation(lat: latitude, lng: longitude, radiusMeters: radius)
            return (lat, lng, nil)
        }
        return (latitude, longitude, placeId)
    }

    // A re-check says something is gone (the circle, a member, a place, a
    // destination, an alert) only from a list the server gave whole: never
    // from a 404, a list that didn't load, the saved copy, or a list that may
    // be partial. Otherwise the change waits (`notYet`), bounded by its age.

    /// A change whose circle this account may have left, by the last list the
    /// server gave (`CircleManager.listsCircle`), not the screens' list, which
    /// a roster's 404 prunes for the moment. Missing from a list that came on
    /// one page: dropped with the left-circle line. Missing from a list with
    /// more pages, which a reorder between two page reads can skip a circle
    /// from: it waits. Listed: nil, and the re-check goes on.
    @MainActor
    static func notInCircle(_ change: PendingChange) -> PendingRecheck? {
        switch CircleManager.shared.listsCircle(change.circleId) {
        case true?: return nil
        case false?: return .drop(line: leftCircleLine(change))
        case nil: return .notYet
        }
    }

    /// Whether a member is still in the circle, by its last complete roster
    /// (shown here or not). Nil without one: the change waits.
    @MainActor
    static func memberInCircle(_ userId: String, circleId: String) -> Bool? {
        CircleManager.shared.rosterLists(userId, in: circleId)
    }

    /// The places, loaded as the screens load them: the ids the server listed
    /// just now (every page), or nil when that fetch failed.
    @MainActor
    static func placesListedNow() async -> Set<String>? {
        let active = CircleManager.shared.activeCircle?.id ?? SelfKeyManager.selfCircleUuid
        try? await PlaceManager.shared.loadPlaces(for: active)
        return PlaceManager.shared.listedPlaceIds
    }

    /// Whether this account is still an owner or admin of the circle, by its
    /// complete roster; nil without one (the change waits). A 403 at send is
    /// not an answer to this: the runner lets the change wait, and this decides.
    @MainActor
    static func ownerOrAdmin(_ change: PendingChange) -> Bool? {
        guard let me = AuthManager.shared.userId,
              CircleManager.shared.rosterLists(me, in: change.circleId) == true else { return nil }
        let role = CircleManager.shared.rosters[change.circleId]?
            .first { $0.userId.caseInsensitiveCompare(me) == .orderedSame }?.role
        return role == .owner || role == .admin
    }

    /// What the circle's record chain says about the member a change would
    /// sign for.
    enum RemovalCheck: Equatable {
        /// The circle has no refresh records: nothing to check here.
        case noRecords
        /// It has, and the SDK's eligibility rule couldn't be applied
        /// here now (its records not imported in this process yet, or
        /// the chain forked): the change waits.
        case unknown
        /// Their last word: a counting removal at this version, or none.
        case lastWord(removedAt: Int32?)
    }

    /// Pure: a waiting change that would sign for a member ends with item 23
    /// (`PendingChangeCopy.memberLeft`) and signs nothing when their last word
    /// is a counting removal at a version above the one this device had
    /// accepted when the person decided (`versionAtTap`, getActiveVersion
    /// then). An owed admission counts as decided at no version: any counting
    /// removal ends it. Nil: it carries on; `.notYet`: it waits.
    nonisolated static func removedSinceTheTap(_ check: RemovalCheck, change: PendingChange,
                                               name: String) -> PendingRecheck? {
        switch check {
        case .noRecords, .lastWord(removedAt: nil):
            return nil
        case .unknown:
            return .notYet
        case .lastWord(removedAt: let removedAt?):
            var decidedAt = change.versionAtTap ?? 0
            if case .letIn(let inputs) = change.inputs, inputs.questionKind == "owed" { decidedAt = 0 }
            return Int(removedAt) > decidedAt ? .drop(line: PendingChangeCopy.memberLeft(change, name: name)) : nil
        }
    }

    /// The circle is missing from this account's list, and the person didn't
    /// leave it themselves (leaving clears its changes with no line).
    static func leftCircleLine(_ change: PendingChange) -> String { PendingChangeCopy.notDone(change) }

    /// A 404, or the thing wasn't found here to send. Not "gone" by itself:
    /// the runner lets the change wait, and its next re-check decides.
    static func isNotFound(_ error: Error) -> Bool {
        guard let api = error as? APIError else { return false }
        let gone: Set<String> = ["http_404", "destination_not_active", "missing_place"]
        let codes: [String] = [api.code, api.errorCode].compactMap { $0 }
        return codes.contains { code in gone.contains(code) || code.hasSuffix("_not_found") }
    }
}

// MARK: - invite

@MainActor
struct InviteKind: PendingChangeHandler {
    func recheck(_ change: PendingChange) async -> PendingRecheck {
        guard case .invite = change.inputs else { return .drop(line: nil) }
        if let left = PendingChangeKinds.notInCircle(change) { return left }
        guard let allowed = PendingChangeKinds.ownerOrAdmin(change) else { return .notYet }
        guard allowed else { return .drop(line: PendingChangeCopy.notOwnerOrAdmin(change)) }
        // "Already in" and "already has an invitation" are the server's answers
        // at send; the runner's look then says whether the one it holds is
        // its own.
        return .run(change)
    }

    func perform(_ change: PendingChange) async throws {
        guard case .invite(let inputs) = change.inputs else { return }
        try await CircleManager.shared.inviteMember(to: change.circleId, email: inputs.email, waiting: change)
    }

    func classify(_ error: Error, change: PendingChange) -> PendingOutcome? {
        guard case .invite(let inputs) = change.inputs else { return nil }
        if case .removedSinceDecided(let line)? = error as? CircleManager.CircleError {
            // Removed after the person decided; nothing was signed.
            return .drop(line: line)
        }
        if case .inviteeDetailsChanged? = error as? CircleManager.CircleError {
            // Answered "It's them" about one account, and the address shows
            // another, other keys or none now: item 30
            // (`PendingChangeCopy.detailsKeepChangingInvite`), never
            // asked again.
            return .drop(line: PendingChangeCopy.detailsKeepChangingInvite(email: inputs.email))
        }
        if case .inviteeChanged(let found)? = error as? CircleManager.CircleError {
            // "Is this really {email}?", at most once per change; changed again
            // after the answer, it is dropped.
            guard !change.seen.askedAgain else {
                return .drop(line: PendingChangeCopy.detailsKeepChangingInvite(email: inputs.email))
            }
            var seen = change.seen
            seen.askedAgain = true
            seen.keys = MemberKeyPair(sharingKeyHex: found.sharingKeyHex, signingKeyHex: found.signingKeyHex)
            seen.subjectUserId = found.userId
            return .needsPerson(.keysChanged, seen: seen)
        }
        guard let api = error as? APIError else { return nil }
        let circle = PendingChangeCopy.circleName(change)
        if api.isServerCode("invite_already_exists") {
            return .drop(line: PendingChangeCopy.alreadyInvited(email: inputs.email, circle: circle))
        }
        if api.isServerCode("circle_already_member") {
            return .done(line: PendingChangeCopy.alreadyMember(email: inputs.email, circle: circle))
        }
        return nil
    }
}

// MARK: - make admin

@MainActor
struct MakeAdminKind: PendingChangeHandler {
    func recheck(_ change: PendingChange) async -> PendingRecheck {
        guard case .makeAdmin(let memberId) = change.inputs else { return .drop(line: nil) }
        if let left = PendingChangeKinds.notInCircle(change) { return left }
        guard let allowed = PendingChangeKinds.ownerOrAdmin(change) else { return .notYet }
        guard allowed else { return .drop(line: PendingChangeCopy.notOwnerOrAdmin(change)) }
        let name = change.labels.subject ?? "They"
        guard let present = PendingChangeKinds.memberInCircle(memberId, circleId: change.circleId) else { return .notYet }
        guard present else { return .drop(line: PendingChangeCopy.memberLeft(change, name: name)) }
        // Removed after the person decided: it signs nothing.
        if change.heldStatementId == nil, let removed = PendingChangeKinds.removedSinceTheTap(
            CircleManager.shared.removalCheck(userId: memberId, circleId: change.circleId), change: change, name: name) {
            return removed
        }
        // The role already changed counts only once its admission is stored.
        if change.heldStatementId != nil, PendingChangeRunner.liveRoleChanged(change) == true {
            return .done(line: nil)
        }
        let circles = CircleManager.shared
        // What this device holds for them, and the list agrees: else their keys
        // changed and the reset question waits for the person.
        guard let held = circles.promotionKeys(for: memberId, in: change.circleId),
              let listed = circles.listedKeys(for: memberId, in: change.circleId),
              held.matches(sharing: listed.sharingKeyHex, signing: listed.signingKeyHex) else { return .notYet }
        var adjusted = change
        if let decided = change.seen.keys, !decided.matches(sharing: held.sharingKeyHex, signing: held.signingKeyHex) {
            // The person took their new keys since: those, once; changed
            // again after that, dropped.
            guard !change.seen.askedAgain else {
                return .drop(line: PendingChangeCopy.detailsKeepChangingAdmin(name: name))
            }
            adjusted.seen.keys = held
            adjusted.seen.askedAgain = true
        }
        if change.heldStatementId == nil, SelfKeyManager.signingKeyMissing {
            return .needsPerson(.password, seen: change.seen)
        }
        return .run(adjusted)
    }

    func perform(_ change: PendingChange) async throws {
        guard case .makeAdmin(let memberId) = change.inputs else { return }
        try await CircleManager.shared.updateMemberRole(in: change.circleId, userId: memberId, role: .admin,
                                                        keys: change.seen.keys, waiting: change)
    }

    func classify(_ error: Error, change: PendingChange) -> PendingOutcome? {
        if case .promotionDetailsChanged? = error as? CircleManager.CircleError {
            // The keys moved between the re-check and the run: checked again.
            return .transient(sent: false)
        }
        return nil
    }
}

// MARK: - let in

@MainActor
struct LetInKind: PendingChangeHandler {
    func recheck(_ change: PendingChange) async -> PendingRecheck {
        guard case .letIn(let inputs) = change.inputs else { return .drop(line: nil) }
        if let left = PendingChangeKinds.notInCircle(change) { return left }
        let name = change.labels.subject ?? "They"
        guard let present = PendingChangeKinds.memberInCircle(inputs.memberId, circleId: change.circleId) else {
            return .notYet
        }
        guard present else { return .drop(line: PendingChangeCopy.memberLeft(change, name: name)) }
        // Removed after the person decided: it signs nothing (with its
        // own admission already out, nothing more is signed).
        if change.heldStatementId == nil, let removed = PendingChangeKinds.removedSinceTheTap(
            CircleManager.shared.removalCheck(userId: inputs.memberId, circleId: change.circleId),
            change: change, name: name) {
            return removed
        }
        if let decided = Self.admitted(
            change, ownerOrAdmin: PendingChangeKinds.ownerOrAdmin(change),
            verdict: CircleManager.shared.membership[change.circleId]?.verdicts[inputs.memberId]) {
            return decided
        }
        guard let listed = CircleManager.shared.listedKeys(for: inputs.memberId, in: change.circleId) else {
            return .notYet
        }
        let pin = MemberKeyPinner.shared.pinnedKeys(circleId: change.circleId, userId: inputs.memberId)
        let pinned = pin.sharing.flatMap { s in pin.signing.map { MemberKeyPair(sharingKeyHex: s, signingKeyHex: $0) } }
        if let asked = change.seen.keys, !CircleManager.letInHolds(asked: asked, listed: listed, pinned: pinned) {
            // Other keys than the question showed: asked again once, about the
            // keys the list shows now; changed again after that, dropped.
            guard !change.seen.askedAgain else {
                return .drop(line: PendingChangeCopy.detailsKeepChangingLetIn(name: name))
            }
            var seen = change.seen
            seen.keys = listed
            seen.askedAgain = true
            return .needsPerson(.keysChanged, seen: seen)
        }
        guard !SelfKeyManager.signingKeyMissing else { return .needsPerson(.password, seen: change.seen) }
        return .run(change)
    }

    /// Pure, for tests: a let-in whose circle and member are still listed,
    /// before its keys are checked. Its own admission is stored (the run's
    /// answer, or the look): the let-in went out, and only this device's
    /// choice is left, so it runs, whatever this account's role is now
    /// ("still owner or admin" gates signing only), and never ends first as
    /// "already let in", which that admission makes true here. Otherwise: the
    /// owner/admin check, then, confirmed here, someone else let them in (an
    /// owed one is confirmed by construction: it only signs). Nil: it carries
    /// on.
    nonisolated static func admitted(_ change: PendingChange, ownerOrAdmin: Bool?,
                                     verdict: MembershipVerdict?) -> PendingRecheck? {
        guard case .letIn(let inputs) = change.inputs else { return nil }
        if change.heldStatementId != nil { return .run(change) }
        guard let ownerOrAdmin else { return .notYet }
        guard ownerOrAdmin else { return .drop(line: PendingChangeCopy.notOwnerOrAdmin(change)) }
        // A late joiner, and a member "It's them" admits, is confirmed
        // here already: what is missing is the admission that lets the
        // SDK's eligibility rule count them, so it always signs.
        if inputs.questionKind != "owed", inputs.questionKind != LateJoiner.questionKind,
           inputs.questionKind != CircleManager.itsThemQuestionKind, case .confirmed? = verdict {
            return .done(line: PendingChangeCopy.alreadyLetIn(name: change.labels.subject ?? "They"))
        }
        return nil
    }

    func perform(_ change: PendingChange) async throws {
        try await CircleManager.shared.letInWaiting(change)
    }

    func classify(_ error: Error, change: PendingChange) -> PendingOutcome? {
        // Changed between the re-check and the run: checked again.
        guard case .letInDetailsChanged? = error as? CircleManager.CircleError else { return nil }
        return .transient(sent: false)
    }
}

// MARK: - renew an invitation

@MainActor
struct RenewInvitationKind: PendingChangeHandler {
    func recheck(_ change: PendingChange) async -> PendingRecheck {
        guard case .renewInvitation(let inputs) = change.inputs, let keys = change.seen.keys else {
            return .drop(line: nil)
        }
        if let left = PendingChangeKinds.notInCircle(change) { return left }
        guard let allowed = PendingChangeKinds.ownerOrAdmin(change) else { return .notYet }
        guard allowed else { return .drop(line: PendingChangeCopy.notOwnerOrAdmin(change)) }
        // Still pending, its original verified now; the renewal facts
        // and the directory are read again when it runs.
        let question: InvitationRenewals.Question?
        do {
            question = try await InvitationRenewals.shared.waitingQuestion(change, inputs: inputs, keys: keys)
        } catch {
            return .notYet
        }
        guard question != nil else { return .drop(line: PendingChangeCopy.invitationEnded(email: inputs.email)) }
        guard !SelfKeyManager.signingKeyMissing else { return .needsPerson(.password, seen: change.seen) }
        return .run(change)
    }

    func perform(_ change: PendingChange) async throws {
        try await InvitationRenewals.shared.renewWaiting(change)
    }

    func classify(_ error: Error, change: PendingChange) -> PendingOutcome? {
        guard case .renewInvitation(let inputs) = change.inputs else { return nil }
        if let renewal = error as? InvitationRenewals.RenewalError {
            switch renewal {
            case .keysChangedWaiting(let keys):
                // Other keys in the directory than the ones decided on: asked
                // again once; changed again after that, dropped.
                guard !change.seen.askedAgain else {
                    return .drop(line: PendingChangeCopy.detailsKeepChangingRenewal)
                }
                var seen = change.seen
                seen.keys = keys
                seen.askedAgain = true
                return .needsPerson(.keysChanged, seen: seen)
            case .notDone(let line):
                return .drop(line: line)
            case .askedAgain:
                return nil
            }
        }
        guard let api = error as? APIError else { return nil }
        // The directory moved after the lookup: the next run reads it again.
        if api.isServerCode("invite_lookup_changed") { return .transient(sent: false) }
        if api.isServerCode("invite_changed", "invite_not_found") {
            return .drop(line: PendingChangeCopy.invitationEnded(email: inputs.email))
        }
        if api.isServerCode("invite_not_renewable") { return .drop(line: PendingChangeCopy.notOwnerOrAdmin(change)) }
        return nil
    }
}

// MARK: - check-in

@MainActor
struct CheckInKind: PendingChangeHandler {
    func recheck(_ change: PendingChange) async -> PendingRecheck {
        guard case .checkIn(var inputs) = change.inputs else { return .drop(line: nil) }
        if let left = PendingChangeKinds.notInCircle(change) { return left }
        let position = PendingChangeKinds.stricterPosition(
            latitude: inputs.latitude, longitude: inputs.longitude, placeId: inputs.placeId,
            queued: change.seen.privacy, atSend: CheckInManager.privacyNow(circleId: change.circleId))
        inputs.latitude = position.latitude
        inputs.longitude = position.longitude
        inputs.placeId = position.placeId
        // Sent without the place if it was deleted meanwhile.
        if let placeId = inputs.placeId {
            guard let listed = await PendingChangeKinds.placesListedNow() else { return .notYet }
            if !listed.contains(placeId) { inputs.placeId = nil }
        }
        var adjusted = change
        adjusted.inputs = .checkIn(inputs)
        return .run(adjusted)
    }

    func perform(_ change: PendingChange) async throws {
        try await CheckInManager.shared.sendWaitingCheckIn(change)
    }

    func classify(_ error: Error, change: PendingChange) -> PendingOutcome? { nil }
}

// MARK: - destination

@MainActor
struct DestinationKind: PendingChangeHandler {
    func recheck(_ change: PendingChange) async -> PendingRecheck {
        guard case .destination = change.inputs else { return .drop(line: nil) }
        if let left = PendingChangeKinds.notInCircle(change) { return left }
        return .run(change)
    }

    func perform(_ change: PendingChange) async throws {
        guard case .destination(let inputs) = change.inputs else { return }
        _ = try await DestinationsManager.shared.createDestination(
            circleId: change.circleId, name: inputs.name,
            coordinate: CLLocationCoordinate2D(latitude: inputs.latitude, longitude: inputs.longitude),
            eta: inputs.eta, notifyArrival: inputs.notifyArrival, waiting: change)
    }

    func classify(_ error: Error, change: PendingChange) -> PendingOutcome? { nil }
}

// MARK: - arrived

@MainActor
struct ArrivedKind: PendingChangeHandler {
    func recheck(_ change: PendingChange) async -> PendingRecheck {
        guard case .arrived(let inputs) = change.inputs else { return .drop(line: nil) }
        if let left = PendingChangeKinds.notInCircle(change) { return left }
        await DestinationsManager.shared.refresh()
        guard let destination = DestinationsManager.shared.destinations.first(where: { $0.id == inputs.destinationId })
        else {
            // Missing: only a whole list says so (a listed one
            // needs none), and a row listed but not readable here
            // yet waits. Arrived rows leave the list, so a missing
            // one is arrived, ended or deleted: nothing to send.
            // After a lost answer that may be its own arrival: it
            // ends quietly.
            guard let listed = DestinationsManager.shared.listedIds else { return .notYet }
            if listed.contains(inputs.destinationId) { return .notYet }
            if change.mayHaveGoneOut { return .done(line: nil) }
            return .drop(line: PendingChangeCopy.deleted(change, thing: "the destination"))
        }
        if destination.status == .arrived { return .done(line: nil) }
        guard destination.status.isLive else { return .drop(line: PendingChangeCopy.notDone(change)) }
        return .run(change)
    }

    func perform(_ change: PendingChange) async throws {
        guard case .arrived(let inputs) = change.inputs,
              let destination = DestinationsManager.shared.destinations.first(where: { $0.id == inputs.destinationId })
        else { throw APIError(code: "destination_not_found", message: "Not listed") }
        let position = PendingChangeKinds.stricterPosition(
            latitude: inputs.latitude, longitude: inputs.longitude, placeId: nil,
            queued: change.seen.privacy, atSend: CheckInManager.privacyNow(circleId: change.circleId))
        let coordinate = position.latitude.flatMap { lat in
            position.longitude.map { CLLocationCoordinate2D(latitude: lat, longitude: $0) }
        }
        _ = try await DestinationsManager.shared.reportArrival(
            destination: destination, currentLocation: coordinate, byPerson: true, waiting: change)
    }

    func classify(_ error: Error, change: PendingChange) -> PendingOutcome? { nil }
}

// MARK: - share a place

@MainActor
struct SharePlaceKind: PendingChangeHandler {
    func recheck(_ change: PendingChange) async -> PendingRecheck {
        guard case .sharePlace(let placeId) = change.inputs else { return .drop(line: nil) }
        if let left = PendingChangeKinds.notInCircle(change) { return left }
        guard let listed = await PendingChangeKinds.placesListedNow() else { return .notYet }
        guard let place = PlaceManager.shared.monitoredPlace(for: placeId) else {
            if listed.contains(placeId) { return .notYet }
            return .drop(line: PendingChangeCopy.deleted(change, thing: change.labels.subject ?? "the place"))
        }
        if (place.sharedCircles ?? []).contains(where: { $0.caseInsensitiveCompare(change.circleId) == .orderedSame }) {
            return .done(line: PendingChangeCopy.alreadyShared(place: place.name,
                                                                circle: PendingChangeCopy.circleName(change)))
        }
        // It may have gone out, and the place isn't shared now: the person may
        // have unshared it on another device meanwhile, and sharing it again
        // would hand its name and location back to the circle. Never sent
        // again; it ends with item 32 (`PendingChangeCopy.notDone`).
        if change.mayHaveGoneOut { return .drop(line: PendingChangeCopy.notDone(change)) }
        return .run(change)
    }

    func perform(_ change: PendingChange) async throws {
        guard case .sharePlace(let placeId) = change.inputs else { return }
        try await PlaceManager.shared.sharePlaceWithCircle(placeId: placeId, circleId: change.circleId, waiting: change)
    }

    func classify(_ error: Error, change: PendingChange) -> PendingOutcome? {
        if let api = error as? APIError, api.code == "http_409" {
            return .done(line: PendingChangeCopy.alreadyShared(place: change.labels.subject ?? "The place",
                                                                circle: PendingChangeCopy.circleName(change)))
        }
        return nil
    }
}

// MARK: - edit a place

@MainActor
struct EditPlaceKind: PendingChangeHandler {
    func recheck(_ change: PendingChange) async -> PendingRecheck {
        guard case .editPlace(let placeId, _) = change.inputs else { return .drop(line: nil) }
        if let left = PendingChangeKinds.notInCircle(change) { return left }
        // Compared with the place as the server has it now, never an older copy.
        guard let listed = await PendingChangeKinds.placesListedNow() else { return .notYet }
        guard let place = PlaceManager.shared.monitoredPlace(for: placeId) else {
            if listed.contains(placeId) { return .notYet }
            return .drop(line: PendingChangeCopy.deleted(change, thing: change.labels.subject ?? "the place"))
        }
        if let seen = change.seen.place, PlaceManager.fields(of: place) != seen {
            return .drop(line: PendingChangeCopy.placeChangedElsewhere(place: change.labels.subject ?? place.name))
        }
        return .run(change)
    }

    func perform(_ change: PendingChange) async throws {
        guard case .editPlace(let placeId, let fields) = change.inputs,
              var place = PlaceManager.shared.monitoredPlace(for: placeId) else {
            throw APIError(code: "missing_place", message: "Not listed")
        }
        place.name = fields.name
        place.latitude = fields.latitude
        place.longitude = fields.longitude
        place.radius = fields.radius
        if let icon = Place.PlaceIcon(rawValue: fields.icon) { place.icon = icon }
        place.color = fields.color
        try await PlaceManager.shared.updatePlace(place, waiting: change)
    }

    func classify(_ error: Error, change: PendingChange) -> PendingOutcome? { nil }
}

// MARK: - place alert

@MainActor
struct PlaceAlertKind: PendingChangeHandler {
    func recheck(_ change: PendingChange) async -> PendingRecheck {
        guard case .memberPlaceAlert(let inputs) = change.inputs else { return .drop(line: nil) }
        if let left = PendingChangeKinds.notInCircle(change) { return left }
        guard let listed = await PendingChangeKinds.placesListedNow() else { return .notYet }
        guard PlaceManager.shared.monitoredPlace(for: inputs.placeId) != nil else {
            if listed.contains(inputs.placeId) { return .notYet }
            return .drop(line: PendingChangeCopy.deleted(change, thing: change.labels.subject ?? "the place"))
        }
        if let target = inputs.targetUserId {
            guard let present = PendingChangeKinds.memberInCircle(target, circleId: change.circleId) else {
                return .notYet
            }
            if !present { return .drop(line: PendingChangeCopy.memberLeft(change, name: change.labels.member ?? "They")) }
        }
        guard (try? await PlaceManager.shared.refreshAllAlerts()) != nil else { return .notYet }
        let existing = PlaceManager.shared.placeAlerts[inputs.placeId] ?? []
        if existing.contains(where: { $0.targetUserId == inputs.targetUserId }) { return .done(line: nil) }
        return .run(change)
    }

    func perform(_ change: PendingChange) async throws {
        guard case .memberPlaceAlert(let inputs) = change.inputs,
              let alertType = PlaceAlert.AlertType(rawValue: inputs.alertType) else { return }
        _ = try await PlaceManager.shared.savePlaceAlert(
            placeId: inputs.placeId, existingAlertId: nil, targetUserId: inputs.targetUserId, alertType: alertType,
            activeDays: inputs.activeDays, activeStartTime: inputs.activeStartTime, activeEndTime: inputs.activeEndTime,
            notifyPush: inputs.notifyPush, notifyEmail: inputs.notifyEmail, notifySms: inputs.notifySms,
            waiting: change)
    }

    func classify(_ error: Error, change: PendingChange) -> PendingOutcome? { nil }
}

// MARK: - battery alert

@MainActor
struct BatteryAlertKind: PendingChangeHandler {
    func recheck(_ change: PendingChange) async -> PendingRecheck {
        guard case .batteryAlert(let inputs) = change.inputs else { return .drop(line: nil) }
        if let left = PendingChangeKinds.notInCircle(change) { return left }
        guard let present = PendingChangeKinds.memberInCircle(inputs.targetUserId, circleId: change.circleId) else {
            return .notYet
        }
        guard present else { return .drop(line: PendingChangeCopy.memberLeft(change, name: change.labels.member ?? "They")) }
        let rules = AlertRulesManager.shared
        guard await rules.refresh() else { return .notYet }
        let identical = rules.rules.contains { rule in
            rule.circleId?.caseInsensitiveCompare(change.circleId) == .orderedSame && rule.ruleType == "low_battery"
                && rules.target(for: rule)?.caseInsensitiveCompare(inputs.targetUserId) == .orderedSame
                && rules.threshold(for: rule) == inputs.threshold
        }
        return identical ? .done(line: nil) : .run(change)
    }

    func perform(_ change: PendingChange) async throws {
        guard case .batteryAlert(let inputs) = change.inputs else { return }
        _ = try await AlertRulesManager.shared.createBatteryRule(
            circleId: change.circleId, targetUserId: inputs.targetUserId, threshold: inputs.threshold,
            notifyPush: inputs.notifyPush, notifyEmail: inputs.notifyEmail, cooldownMinutes: inputs.cooldownMinutes,
            waiting: change)
    }

    func classify(_ error: Error, change: PendingChange) -> PendingOutcome? { nil }
}

// MARK: - change an alert

@MainActor
struct AlertChangeKind: PendingChangeHandler {
    func recheck(_ change: PendingChange) async -> PendingRecheck {
        guard case .alertChange(let inputs) = change.inputs else { return .drop(line: nil) }
        if let left = PendingChangeKinds.notInCircle(change) { return left }
        guard await AlertRulesManager.shared.refresh() else { return .notYet }
        guard let rule = AlertRulesManager.shared.rules.first(where: { $0.id == inputs.ruleId }) else {
            return .drop(line: PendingChangeCopy.deleted(change, thing: "the alert"))
        }
        // Never over a change made on another device meanwhile: as the
        // person saw it, it runs; already as they wanted it, it's done with no
        // request; anything else is someone else's change.
        if let seen = change.seen.rule {
            let now = AlertRulesManager.shared.fields(of: rule)
            let target = PendingChangeStore.merged(.alertChange(seen), with: .alertChange(inputs))
            if .alertChange(now) == target { return .done(line: nil) }
            guard now == seen else { return .drop(line: PendingChangeCopy.alertChangedElsewhere) }
        }
        return .run(change)
    }

    func perform(_ change: PendingChange) async throws {
        guard case .alertChange(let inputs) = change.inputs,
              let rule = AlertRulesManager.shared.rules.first(where: { $0.id == inputs.ruleId }) else {
            throw APIError(code: "rule_not_found", message: "Not listed")
        }
        try await AlertRulesManager.shared.updateRule(
            rule, isActive: inputs.isActive, threshold: inputs.threshold, notifyPush: inputs.notifyPush,
            notifyEmail: inputs.notifyEmail, cooldownMinutes: inputs.cooldownMinutes, waiting: change)
    }

    func classify(_ error: Error, change: PendingChange) -> PendingOutcome? { nil }
}

// MARK: - inactivity alert

@MainActor
struct InactivityAlertKind: PendingChangeHandler {
    func recheck(_ change: PendingChange) async -> PendingRecheck {
        guard case .inactivityAlert(var inputs) = change.inputs else { return .drop(line: nil) }
        if let left = PendingChangeKinds.notInCircle(change) { return left }
        if let ids = inputs.memberIds {
            var still: [String] = []
            for id in ids {
                guard let present = PendingChangeKinds.memberInCircle(id, circleId: change.circleId) else { return .notYet }
                if present { still.append(id) }
            }
            guard !still.isEmpty else {
                return .drop(line: PendingChangeCopy.memberLeft(change, name: change.labels.member ?? "They"))
            }
            inputs.memberIds = still
        }
        var adjusted = change
        adjusted.inputs = .inactivityAlert(inputs)
        return .run(adjusted)
    }

    func perform(_ change: PendingChange) async throws {
        guard case .inactivityAlert(let inputs) = change.inputs else { return }
        let target: InactivityAlertsManager.Target
        if inputs.everyone {
            target = .everyone
        } else if let ids = inputs.memberIds {
            target = .members(ids)
        } else {
            target = .selfUser
        }
        _ = try await InactivityAlertsManager.shared.createAlert(
            circleId: change.circleId, target: target, timeoutMinutes: inputs.timeoutMinutes,
            notifyPush: inputs.notifyPush, notifyEmail: inputs.notifyEmail, cooldownMinutes: inputs.cooldownMinutes,
            notifyOnReturn: inputs.notifyOnReturn, waiting: change)
    }

    func classify(_ error: Error, change: PendingChange) -> PendingOutcome? {
        if let api = error as? APIError, api.code == "no_members_to_watch" { return .done(line: nil) }
        return nil
    }
}

// MARK: - rename a circle

@MainActor
struct RenameCircleKind: PendingChangeHandler {
    func recheck(_ change: PendingChange) async -> PendingRecheck {
        guard case .renameCircle(let newName) = change.inputs else { return .drop(line: nil) }
        if let left = PendingChangeKinds.notInCircle(change) { return left }
        // From the complete roster, never from a 403 at send.
        guard let allowed = PendingChangeKinds.ownerOrAdmin(change) else { return .notYet }
        guard allowed else { return .drop(line: PendingChangeCopy.notOwnerOrAdmin(change)) }
        guard let circle = CircleManager.shared.circles.first(where: {
            $0.id.caseInsensitiveCompare(change.circleId) == .orderedSame
        }), let current = circle.readableName else { return .notYet }
        if current == newName { return .done(line: nil) }
        if let seen = change.seen.name, current != seen {
            return .drop(line: PendingChangeCopy.renamedElsewhere(circle: seen, to: current))
        }
        return .run(change)
    }

    func perform(_ change: PendingChange) async throws {
        guard case .renameCircle(let newName) = change.inputs else { return }
        guard let circle = CircleManager.shared.circles.first(where: {
            $0.id.caseInsensitiveCompare(change.circleId) == .orderedSame
        }) else { throw PendingChanges.NotReady() }
        try await CircleManager.shared.updateCircle(circle, name: newName, waiting: change)
    }

    func classify(_ error: Error, change: PendingChange) -> PendingOutcome? { nil }
}
