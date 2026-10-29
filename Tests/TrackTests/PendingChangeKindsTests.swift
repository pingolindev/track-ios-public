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

/// Waiting changes: each kind's wiring into the SAME function the button
/// calls, the privacy rule for a waiting position, the request ids, the
/// triggers, the wipe, removal while behind, and the approved wording.
@MainActor
final class PendingChangeKindsTests: XCTestCase {
    private let me = "0f0f0f0f-1111-2222-3333-444455556666"
    private let circle = "c1c1c1c1-0000-0000-0000-000000000001"

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// The body of `func <name>(` in a file, up to the next function at the
    /// same indentation.
    private func body(of name: String, in path: String) throws -> Substring {
        let text = try source(path)
        let start = try XCTUnwrap(text.range(of: "func \(name)("), name)
        let end = text.range(of: "\n    func ", range: start.upperBound..<text.endIndex)?.lowerBound
            ?? text.range(of: "\n    private func ", range: start.upperBound..<text.endIndex)?.lowerBound
            ?? text.endIndex
        return text[start.lowerBound..<end]
    }

    // MARK: - The position a waiting check-in or arrival sends

    func testThePositionIsTheStricterOfQueueAndSend() {
        let (lat, lng) = (51.501234, -0.141234)
        // "approximate" when queued and "precise" at send → sent coarsened.
        let queuedCoarse = LocationCoarsener.coarsenLocation(lat: lat, lng: lng, radiusMeters: 1609.344)
        let a = PendingChangeKinds.stricterPosition(
            latitude: queuedCoarse.0, longitude: queuedCoarse.1, placeId: nil,
            queued: .approximate(radiusMeters: 1609.344), atSend: .precise)
        XCTAssertEqual(a.latitude ?? 0, queuedCoarse.0, accuracy: 1e-9)
        XCTAssertNil(a.placeId)
        // "precise" when queued and "paused" at send → no position.
        let b = PendingChangeKinds.stricterPosition(latitude: lat, longitude: lng, placeId: "p",
                                                    queued: .precise, atSend: .none)
        XCTAssertNil(b.latitude); XCTAssertNil(b.longitude); XCTAssertNil(b.placeId)
        // "paused" when queued → no position, whatever the setting at send.
        let c = PendingChangeKinds.stricterPosition(latitude: lat, longitude: lng, placeId: "p",
                                                    queued: PendingChange.QueuedPrivacy.none, atSend: .precise)
        XCTAssertNil(c.latitude)
        // "precise" then "approximate" at send → coarsened now, with no place.
        let d = PendingChangeKinds.stricterPosition(latitude: lat, longitude: lng, placeId: "p",
                                                    queued: .precise, atSend: .approximate(radiusMeters: 3218.688))
        let coarse = LocationCoarsener.coarsenLocation(lat: lat, lng: lng, radiusMeters: 3218.688)
        XCTAssertEqual(d.latitude ?? 0, coarse.0, accuracy: 1e-9)
        XCTAssertNil(d.placeId)
        // Approximate both times: the larger cell, whichever time had it. At
        // the point above the two cells coincide, so this uses one where they
        // differ on both axes.
        let (flat, flng) = (51.513609, -0.16842)
        let small = LocationCoarsener.coarsenLocation(lat: flat, lng: flng, radiusMeters: 1609.344)
        let large = LocationCoarsener.coarsenLocation(lat: flat, lng: flng, radiusMeters: 3218.688)
        XCTAssertNotEqual(small.0, large.0); XCTAssertNotEqual(small.1, large.1)
        for (queued, atSend) in [(1609.344, 3218.688), (3218.688, 1609.344)] {
            let f = PendingChangeKinds.stricterPosition(latitude: flat, longitude: flng, placeId: nil,
                                                        queued: .approximate(radiusMeters: queued),
                                                        atSend: .approximate(radiusMeters: atSend))
            XCTAssertEqual(f.latitude ?? 0, large.0, accuracy: 1e-9)
            XCTAssertEqual(f.longitude ?? 0, large.1, accuracy: 1e-9)
        }
        // Precise both times: as queued.
        let e = PendingChangeKinds.stricterPosition(latitude: lat, longitude: lng, placeId: "p",
                                                    queued: .precise, atSend: .precise)
        XCTAssertEqual(e.latitude, lat); XCTAssertEqual(e.placeId, "p")
    }

    // MARK: - Queued, not refused: the hook is the live gate, before any seal

    /// Each kind queues on the live path's own "behind" refusal and nothing
    /// else, at the gate, before anything is sealed; a run (`waiting`) is never
    /// queued again. A break (the seal before the gate) fails here.
    func testEachKindQueuesAtTheGateBeforeAnySeal() throws {
        let hooks: [(file: String, function: String, queue: String)] = [
            ("App/Managers/CheckInManager.swift", "createCheckInOverWire",
             "try CircleManager.shared.requireCurrentKey(for: circleId)"),
            ("App/Managers/DestinationsManager.swift", "createDestination",
             "} catch CircleManager.CircleError.keyNotCurrent where waiting == nil {"),
            ("App/Managers/DestinationsManager.swift", "reportArrival",
             "} catch CircleManager.CircleError.keyNotCurrent where byPerson && waiting == nil {"),
            ("App/Managers/PlaceManager.swift", "sharePlaceWithCircle",
             "} catch CircleManager.CircleError.keyNotCurrent where waiting == nil {"),
            ("App/Managers/PlaceManager.swift", "updatePlace",
             "} catch CircleManager.CircleError.keyNotCurrent where waiting == nil {"),
            ("App/Managers/AlertRulesManager.swift", "createBatteryRule",
             "} catch CircleManager.CircleError.keyNotCurrent where waiting == nil {"),
            ("App/Managers/AlertRulesManager.swift", "updateRule",
             "} catch CircleManager.CircleError.keyNotCurrent where waiting == nil {"),
            ("App/Managers/InactivityAlertsManager.swift", "createAlert",
             "} catch CircleManager.CircleError.keyNotCurrent where waiting == nil {"),
            ("App/Managers/CircleManager.swift", "updateCircle",
             "} catch CircleError.keyNotCurrent where waiting == nil && circle.readableName != nil {"),
        ]
        let seals = ["encryptDataV2(", "encryptData(", "encryptLocation(", "wrapPlaceKey(", "encryptWithPlaceKeyV2(",
                     "deriveUserPseudonym(", "computeEventTypeHash("]
        for hook in hooks {
            let text = try body(of: hook.function, in: hook.file)
            let gate = try XCTUnwrap(text.range(of: hook.queue), "\(hook.function): \(hook.queue)")
            // An edit of a place with its own key seals under that key, which is
            // never behind: only the circle-key seals count there.
            let circleSeals = hook.function == "updatePlace"
                ? ["encryptDataV2(circleId: place.circleId", "encryptLocation(circleId: place.circleId"] : seals
            for seal in circleSeals {
                if let first = text.range(of: seal) {
                    XCTAssertLessThan(gate.lowerBound, first.lowerBound, "\(hook.function) seals before the gate: \(seal)")
                }
            }
        }
        // The check-in's queue is one level up, around the live call.
        let checkIn = try body(of: "checkIn", in: "App/Managers/CheckInManager.swift")
        XCTAssertTrue(checkIn.contains("} catch CircleManager.CircleError.keyNotCurrent {\n"))
        XCTAssertTrue(checkIn.contains("try PendingChanges.queue(\n                .checkIn, circleId: circleId,"))
        // `.memberPlaceAlert`: an alert on an older circle-owned place, at
        // its target's seal.
        let alert = try body(of: "savePlaceAlert", in: "App/Managers/PlaceManager.swift")
        XCTAssertTrue(alert.contains("encTargetBlob = try encryptAlertTarget(for: place, targetUserId: targetUserId)\n            } catch CircleManager.CircleError.keyNotCurrent where waiting == nil {"))
        // The manual arrival is the person's; the automatic one never queues.
        let view = try source("App/Views/Destinations/DestinationsView.swift")
        XCTAssertTrue(view.contains("manager.reportArrival(destination: row, byPerson: true)"))
        let auto = try body(of: "checkAutoArrival", in: "App/Managers/DestinationsManager.swift")
        XCTAssertFalse(auto.contains("byPerson: true"))
    }

    /// A run calls the SAME function the button calls, passing the change.
    func testEachRunCallsTheButtonsFunction() throws {
        let kinds = try source("App/Domain/PendingChanges/PendingChangeKinds.swift")
        for call in [
            "try await CheckInManager.shared.sendWaitingCheckIn(change)",
            "eta: inputs.eta, notifyArrival: inputs.notifyArrival, waiting: change)",
            "destination: destination, currentLocation: coordinate, byPerson: true, waiting: change)",
            "try await PlaceManager.shared.sharePlaceWithCircle(placeId: placeId, circleId: change.circleId, waiting: change)",
            "try await PlaceManager.shared.updatePlace(place, waiting: change)",
            "notifyPush: inputs.notifyPush, notifyEmail: inputs.notifyEmail, notifySms: inputs.notifySms,\n            waiting: change)",
            "notifyPush: inputs.notifyPush, notifyEmail: inputs.notifyEmail, cooldownMinutes: inputs.cooldownMinutes,\n            waiting: change)",
            "notifyEmail: inputs.notifyEmail, cooldownMinutes: inputs.cooldownMinutes, waiting: change)",
            "notifyOnReturn: inputs.notifyOnReturn, waiting: change)",
            "try await CircleManager.shared.updateCircle(circle, name: newName, waiting: change)",
        ] {
            XCTAssertTrue(kinds.contains(call), call)
        }
        // The create route the server serves: the circle's own path is GET only
        // (a POST there is answered 405).
        let api = try source("App/Services/APIService.swift")
        XCTAssertTrue(api.contains("return try await post(path: \"/api/v1/check-ins\", body: request)"))
        XCTAssertFalse(api.contains("post(path: \"/api/v1/circles/\\(circleId)/check-ins\""))
        let sent = try body(of: "sendWaitingCheckIn", in: "App/Managers/CheckInManager.swift")
        XCTAssertTrue(sent.contains("checkedInAt: inputs.checkedInAt,\n            clientRequestId: change.requestId()"),
                      "the time the person checked in, and the request id")
        let wire = try body(of: "createCheckInOverWire", in: "App/Managers/CheckInManager.swift")
        XCTAssertTrue(wire.contains("let now = checkedInAt"))
    }

    // MARK: - Request ids

    func testCreatesCarryTheRequestIdOnlyWhenWaiting() throws {
        let encoder = APIService.makeWireEncoder()
        let blob = EncryptedBlobRequest(nonce: "n", ciphertext: "c")
        var checkIn = CreateCheckInRequest(
            deviceId: "d", circleId: circle, encryptedLocation: blob, placeId: nil, encryptedMessage: nil,
            checkInType: "general", encryptedUserId: blob, encryptedDeviceId: blob, dayBucket: 1,
            encryptedTimestamp: blob, userPseudonym: "p")
        XCTAssertFalse(String(decoding: try encoder.encode(checkIn), as: UTF8.self).contains("client_request_id"),
                       "never from a plain tap")
        checkIn.clientRequestId = "3f0c0000-0000-4000-8000-000000000001"
        XCTAssertTrue(String(decoding: try encoder.encode(checkIn), as: UTF8.self)
            .contains("\"client_request_id\":\"3f0c0000-0000-4000-8000-000000000001\""))
        var destination = CreateDestinationRequest(
            circleId: circle, encryptedDestination: blob, encryptedDestName: nil, encryptedEta: nil,
            etaDayBucket: nil, notifyArrival: true, encryptedUserId: blob)
        destination.clientRequestId = "abc"
        XCTAssertTrue(String(decoding: try encoder.encode(destination), as: UTF8.self).contains("\"client_request_id\":\"abc\""))
        let api = try source("App/Services/APIService.swift")
        for name in ["CreateCheckInRequest", "CreateDestinationRequest", "CreatePlaceAlertRequest",
                     "CreateAlertRuleRequest", "CreateInactivityAlertRequest"] {
            let start = try XCTUnwrap(api.range(of: "struct \(name): Encodable {"))
            let end = try XCTUnwrap(api.range(of: "\n}\n", range: start.upperBound..<api.endIndex))
            XCTAssertTrue(api[start.upperBound..<end.lowerBound].contains("var clientRequestId: String? = nil"), name)
        }
        for (file, line) in [
            ("App/Managers/DestinationsManager.swift", "clientRequestId: waiting?.requestId()"),
            ("App/Managers/PlaceManager.swift", "clientRequestId: waiting?.requestId()"),
            ("App/Managers/AlertRulesManager.swift", "clientRequestId: waiting?.requestId()"),
            ("App/Managers/InactivityAlertsManager.swift", "clientRequestId: waiting?.requestId(for: userId)"),
        ] {
            XCTAssertTrue(try source(file).contains(line), file)
        }
    }

    /// One request id per row a change creates: stable across runs, distinct
    /// per row, a UUID (version 5).
    func testRowIdsAreNameBasedAndStable() {
        let change = PendingChanges.make(.inactivityAlert, account: me, circleId: circle, inputs: .inactivityAlert(.init(
            memberIds: ["a", "b"], everyone: false, timeoutMinutes: 60, notifyPush: true, notifyEmail: false,
            cooldownMinutes: 60, notifyOnReturn: false)))
        XCTAssertEqual(change.requestId(), change.id)
        let a = change.requestId(for: "a")
        XCTAssertEqual(a, change.requestId(for: "A"))
        XCTAssertNotEqual(a, change.requestId(for: "b"))
        XCTAssertNotNil(UUID(uuidString: a))
        XCTAssertEqual(Array(a)[14], "5")
        XCTAssertEqual(PendingChange.wireStatementId("0A1B2C3D-0000-4000-8000-00000000000F"),
                       "0a1b2c3d000040008000" + "00000000000f")
    }

    // MARK: - Triggers, wipe, removal

    func testTriggersWipeAndRemoval() throws {
        let circles = try source("App/Managers/CircleManager.swift")
        XCTAssertTrue(circles.contains("            circlesLoaded = true\n"
                                       + "            SDKLocationStreamer.shared.uploadTargetsLoaded(account: AuthManager.shared.userId)\n"
                                       + "        }\n        PendingChangeRunner.shared.trigger()\n"
                                       + "        // This account's own open SOS in a circle whose key moved here (a\n"),
                      "the end of every loadCircles (then only the SOS re-seal's look)")
        XCTAssertTrue(try source("App/Services/BackgroundTaskScheduler.swift")
            .contains("await PendingChangeRunner.shared.run(background: true)"))
        XCTAssertTrue(try source("App/TrackApp.swift").contains("PendingChangeRunner.shared.trigger()"))
        let auth = try source("App/Managers/AuthManager.swift")
        let purge = try XCTUnwrap(auth.range(of: "private func purgeAccountData() async {"))
        XCTAssertTrue(auth[purge.upperBound...].prefix(9000).contains("PendingChangeStore.shared.wipeAll()"))
        let expire = try XCTUnwrap(auth.range(of: "func expireSession("))
        XCTAssertFalse(auth[expire.upperBound...].prefix(3000).contains("PendingChangeStore"),
                       "kept on a session expiry")
        // A person leaving a circle takes its changes with them, silently.
        for leave in ["func leaveCircle(", "func deleteCircle("] {
            let start = try XCTUnwrap(circles.range(of: leave))
            XCTAssertTrue(circles[start.upperBound...].prefix(400).contains("PendingChangeStore.shared.forgetCircle("), leave)
        }
        // Removal while behind: at once, without a new key, never queued.
        let view = try source("App/Views/Circles/CirclesView.swift")
        XCTAssertTrue(view.contains("if circleManager.removesWithoutNewKey(circle.id) {"))
        XCTAssertTrue(view.contains("removedWithoutRotationWarning = PendingChangeCopy.removed(\n                                        name: member.displayName, circle: circle.name, serverLine: serverLine)"))
        XCTAssertTrue(circles.contains("return (circle.isLocked || !holdsCurrentVersion(for: circleId) || standing(of: circleId) == .wait)"))
        // Nothing runs before the circle list loaded (an empty list reads as "left").
        let runner = try source("App/Domain/PendingChanges/PendingChangeRunner.swift")
        XCTAssertTrue(runner.contains("guard !store.changes.isEmpty, circlesLoaded() else { return }"))
        XCTAssertTrue(runner.contains("if inBackground, !tokenLastsWithoutRefresh() { return }"))
    }

    // MARK: - Gone only by a whole list (a 404 is not "gone")

    /// A member counts as gone only when the circle's last COMPLETE roster
    /// doesn't list them, shown here or not; without one, the change waits.
    func testAMemberIsGoneOnlyByACompleteRoster() {
        func member(_ userId: String) -> CircleMember {
            CircleMember(circleId: circle, userId: userId, displayName: userId, role: .member, canSeeRealtime: true,
                         canSeeHistory: true, canRotateKeys: false, joinedAt: Date())
        }
        let roster = [member("AAAA"), member("bbbb")]
        XCTAssertEqual(CircleManager.rosterLists("aaaa", roster: roster, complete: true), true)
        XCTAssertEqual(CircleManager.rosterLists("cccc", roster: roster, complete: true), false)
        XCTAssertNil(CircleManager.rosterLists("cccc", roster: roster, complete: false), "part of a roster")
        XCTAssertNil(CircleManager.rosterLists("cccc", roster: nil, complete: true), "no roster loaded")
    }

    /// Each re-check says the circle, a member, a place, a destination or an
    /// alert is gone only from a list the server gave whole just now, never
    /// from a 404, a list that didn't load, the saved copy or a partial list.
    func testARecheckSaysGoneOnlyFromAWholeList() throws {
        let kinds = try source("App/Domain/PendingChanges/PendingChangeKinds.swift")
        // The circle: the server's last list, not the screens' (a roster's
        // 404 prunes that one).
        XCTAssertTrue(kinds.contains("        switch CircleManager.shared.listsCircle(change.circleId) {\n        case true?: return nil\n        case false?: return .drop(line: leftCircleLine(change))\n        case nil: return .notYet\n        }"))
        XCTAssertEqual(kinds.components(separatedBy: "if let left = PendingChangeKinds.notInCircle(change) { return left }").count - 1, 14,
                       "every kind asks it")
        let circles = try source("App/Managers/CircleManager.swift")
        XCTAssertTrue(circles.contains("        if listedNow {\n            listedCircleIds = Set(responses.map { $0.id.lowercased() })\n            circleListWhole = listedWhole\n            circlesLoaded = true\n"
                                       + "            SDKLocationStreamer.shared.uploadTargetsLoaded(account: AuthManager.shared.userId)\n        }"),
                      "only a list the server just gave, never the saved copy")
        // Missing counts only from a list that came on one page (a
        // reorder between two page reads can skip a circle); from one
        // with more pages, the change waits.
        let listed: Set<String> = ["c1"]
        XCTAssertEqual(CircleManager.listsCircle("C1", listed: listed, whole: false), true)
        XCTAssertEqual(CircleManager.listsCircle("c2", listed: listed, whole: true), false)
        XCTAssertNil(CircleManager.listsCircle("c2", listed: listed, whole: false))
        XCTAssertEqual(PendingChangeRunner.lookAfter404(circleListed: nil), .couldNotLook)
        let runner = try source("App/Domain/PendingChanges/PendingChangeRunner.swift")
        XCTAssertTrue(runner.contains("CircleManager.listsCircle(circleId, listed: Set(list.circles.map { $0.id.lowercased() }),\n                                          whole: list.whole)"))
        XCTAssertFalse(try body(of: "pruneLocalCircle", in: "App/Managers/CircleManager.swift").contains("listedCircleIds"))
        // A member: the last complete roster, or wait.
        XCTAssertTrue(kinds.contains("static func memberInCircle(_ userId: String, circleId: String) -> Bool? {\n        CircleManager.shared.rosterLists(userId, in: circleId)"))
        XCTAssertFalse(kinds.contains("CircleManager.shared.members["), "the shown members are not the roster")
        // Every member re-check waits when the circle has no complete roster:
        // `.makeAdmin`, `.letIn`, `.memberPlaceAlert`, `.batteryAlert` and
        // `.inactivityAlert`.
        let memberChecks = kinds.components(separatedBy: "PendingChangeKinds.memberInCircle(").dropFirst()
        XCTAssertEqual(memberChecks.count, 5)
        for use in memberChecks {
            let guardEnd = try XCTUnwrap(use.range(of: "}"))
            XCTAssertTrue(use[..<guardEnd.lowerBound].contains("return .notYet"), String(use.prefix(120)))
        }
        XCTAssertTrue(kinds.contains("circleId: change.circleId) else {\n            return .notYet\n        }\n        guard present else"))
        XCTAssertTrue(kinds.contains("circleId: change.circleId) else {\n                return .notYet\n            }\n            if !present"))
        // Places, destinations, alerts: fetched whole just now, or wait.
        XCTAssertEqual(kinds.components(separatedBy: "guard let listed = await PendingChangeKinds.placesListedNow() else { return .notYet }").count - 1, 4,
                       "the check-in's place, sharePlace, editPlace, memberPlaceAlert")
        XCTAssertEqual(kinds.components(separatedBy: "if listed.contains(").count - 1, 4,
                       "listed but not readable here yet: it waits")
        // `.editPlace` compares with the place as the server has it NOW:
        // against an older copy it would overwrite a newer edit made
        // elsewhere.
        XCTAssertTrue(kinds.contains("guard case .editPlace(let placeId, _) = change.inputs else { return .drop(line: nil) }\n        if let left = PendingChangeKinds.notInCircle(change) { return left }\n        // Compared with the place as the server has it now, never an older copy.\n        guard let listed = await PendingChangeKinds.placesListedNow() else { return .notYet }\n        guard let place = PlaceManager.shared.monitoredPlace(for: placeId) else {"))
        XCTAssertTrue(kinds.contains("guard let listed = DestinationsManager.shared.listedIds else { return .notYet }"))
        // A listed destination needs no whole list; only a missing
        // one does.
        let arrived = try XCTUnwrap(kinds.range(of: "struct ArrivedKind: PendingChangeHandler {"))
        let arrivedBody = kinds[arrived.upperBound...].prefix(2_000)
        let present = try XCTUnwrap(arrivedBody.range(of: "guard let destination = DestinationsManager.shared.destinations.first(where: { $0.id == inputs.destinationId })"))
        XCTAssertTrue(arrivedBody.contains("guard let listed = DestinationsManager.shared.listedIds else { return .notYet }"))
        let whole = try XCTUnwrap(arrivedBody.range(of: "listedIds"), "the first use of the whole list")
        XCTAssertLessThan(present.lowerBound, whole.lowerBound)
        XCTAssertTrue(kinds.contains("guard await AlertRulesManager.shared.refresh() else { return .notYet }"))
        XCTAssertTrue(kinds.contains("guard await rules.refresh() else { return .notYet }"))
        XCTAssertTrue(kinds.contains("guard (try? await PlaceManager.shared.refreshAllAlerts()) != nil else { return .notYet }"))
        let places = try source("App/Managers/PlaceManager.swift")
        XCTAssertTrue(places.contains("responses = try await api.getAllPlaces()\n            listedPlaceIds = Set(responses.map(\\.id))"))
        XCTAssertTrue(places.contains("        } catch {\n            listedPlaceIds = nil\n"), "the saved copy says nothing is gone")
        let destinations = try source("App/Managers/DestinationsManager.swift")
        XCTAssertTrue(destinations.contains("listedIds = responses.count < Self.listLimit ? Set(responses.map(\\.id)) : nil"))
        XCTAssertTrue(destinations.contains("        } catch {\n            listedIds = nil\n"))
        XCTAssertEqual(DestinationsManager.listLimit, 100)
        // Lists the server pages are read to the end.
        let api = try source("App/Services/APIService.swift")
        XCTAssertTrue(api.contains("let list = try await getAllPages(path: \"/api/v1/circles\", id: { (circle: CircleResponse) in circle.id })\n        return (list.items, list.pages == 1)"),
                      "whole only on one page")
        XCTAssertTrue(api.contains("return try await getAllPages(path: \"/api/v1/alert-rules\", id: { (rule: AlertRuleResponse) in rule.id }).items"))
        // A list whose pages don't end is an error, never a whole list, and
        // pages are merged by id (a restarted scan repeats items).
        let pages = try XCTUnwrap(api.range(of: "    private func getAllPages<E: Decodable>(path: String, id: (E) -> String) async throws -> PagedItems<E> {"))
        let pagesBody = api[pages.upperBound...].prefix(1_400)
        XCTAssertTrue(pagesBody.contains("for item in page.items where seen.insert(id(item).lowercased()).inserted {\n                all.append(item)\n            }"))
        XCTAssertTrue(pagesBody.contains("guard page.hasMore == true else { return PagedItems(items: all, pages: pages) }"))
        XCTAssertTrue(pagesBody.contains("guard let next = page.nextCursor, next != cursor else {\n                throw APIError(code: \"incomplete_list\""))
        XCTAssertTrue(pagesBody.contains("        throw APIError(code: \"incomplete_list\", message: \"The list is longer than this app reads\")"))
        XCTAssertFalse(pagesBody.contains("break"), "never ends early as if whole")
        XCTAssertTrue(api.contains("offset += pageSize - overlap"), "place pages overlap: a delete can't hide one")
        XCTAssertTrue(api.contains("for place in page where ids.insert(place.id).inserted {"), "merged by id")
        // A 403 at send waits; "still an owner or admin" is the complete
        // roster's answer, in each kind that needs it. The `letIn` kind hands
        // it to `LetInKind.admitted`, where nil waits too, after its own held
        // admission.
        XCTAssertEqual(kinds.components(separatedBy: "guard let allowed = PendingChangeKinds.ownerOrAdmin(change) else { return .notYet }").count - 1, 4,
                       "invite, makeAdmin, renewInvitation, renameCircle")
        XCTAssertTrue(kinds.contains("change, ownerOrAdmin: PendingChangeKinds.ownerOrAdmin(change),"), "letIn")
        XCTAssertTrue(kinds.contains("        guard let ownerOrAdmin else { return .notYet }\n"), "letIn")
        // A 404 at send never drops: no kind claims it.
        XCTAssertFalse(kinds.contains(".isNotFound(error) ?"))
        XCTAssertFalse(kinds.contains("isGone("))
    }

    // MARK: - A kept alert never lets its save remove the live ones

    /// A place-alert save whose new alert would wait goes ahead only as that
    /// one new alert on a place with none. Anything more is refused whole,
    /// before any of it runs: kept in part, the save would remove the live
    /// alerts while their replacement only waited.
    func testAPlaceAlertSaveIsKeptOnlyWhole() throws {
        let refused = PlaceManager.refusedWholeWhileNewAlertsWait
        XCTAssertFalse(refused([], nil), "the first alert, for everyone")
        XCTAssertFalse(refused([], ["a"]), "the first alert, for one member")
        XCTAssertTrue(refused([], ["a", "b"]), "two new alerts")
        XCTAssertTrue(refused(["a"], ["b"]), "one new, one removed")
        XCTAssertTrue(refused(["a"], nil), "everyone, replacing a member's")
        XCTAssertTrue(refused([nil], ["a"]), "a member's, replacing everyone's")
        XCTAssertTrue(refused(["a"], ["a", "b"]), "one updated, one new")
        XCTAssertFalse(refused(["a"], ["a"]), "only an update: nothing waits")
        XCTAssertFalse(refused(["a", "b"], ["a"]), "an update and a removal: nothing waits")
        let save = try body(of: "savePlaceAlerts", in: "App/Managers/PlaceManager.swift")
        XCTAssertTrue(save.contains("if let place = monitoredPlace(for: placeId), newAlertWouldWait(on: place),"))
        let refusal = try XCTUnwrap(save.range(of: "throw CircleManager.CircleError.keyNotCurrent"))
        let firstStep = try XCTUnwrap(save.range(of: "try await savePlaceAlert("))
        XCTAssertLessThan(refusal.lowerBound, firstStep.lowerBound, "refused before anything is saved or removed")
    }

    // MARK: - The signing kinds: queued while behind; ids saved when they
    // run

    /// Each signing kind queues at its gate while behind, before anything is
    /// looked up, pinned or signed; its run saves each statement's id before
    /// the request goes out, and only the run pins or approves.
    func testTheSigningKindsQueueAndSaveEachIdBeforeItGoesOut() throws {
        let circles = try source("App/Managers/CircleManager.swift")
        // .invite
        let invite = try XCTUnwrap(circles.range(of: "    func inviteMember(to circleId: String, email: String, lookupRetried: Bool = false,"))
        let inviteBody = circles[invite.upperBound...].prefix(16_000)
        let queued = try XCTUnwrap(inviteBody.range(of: "try PendingChanges.queue(.invite, circleId: circleId, inputs: kept.inputs, seen: kept.seen,\n                                     subject: email.lowercased())"))
        let lookup = try XCTUnwrap(inviteBody.range(of: "Self.canonicalLookup(try await api.lookupPublicKey(email: email))"))
        let kept = try XCTUnwrap(inviteBody.range(of: "if let waiting { try PendingChanges.keepSigned(signed.statement, for: waiting) }"))
        let sent = try XCTUnwrap(inviteBody.range(of: "_ = try await api.inviteByEmail(circleId: circleId, request: request)"))
        XCTAssertLessThan(queued.lowerBound, lookup.lowerBound, "nothing looked up while behind")
        XCTAssertLessThan(kept.lowerBound, sent.lowerBound, "the id is on disk before the request")
        XCTAssertTrue(inviteBody.contains("request.clientRequestId = waiting?.requestId()"))
        XCTAssertTrue(inviteBody.contains("if waiting != nil { throw error }"), "a run never sends what it couldn't sign")
        // .makeAdmin
        let role = try XCTUnwrap(circles.range(of: "    func updateMemberRole(in circleId: String, userId: String, role: CircleMember.MemberRole,"))
        let roleBody = circles[role.upperBound...].prefix(5_000)
        XCTAssertTrue(roleBody.contains("try PendingChanges.queue(\n                    .makeAdmin, circleId: circleId, inputs: .makeAdmin(memberId: userId), seen: .init(keys: signed),"))
        let admitWaiting = try XCTUnwrap(circles.range(of: "    func admitWaiting(_ change: PendingChange, userId: String, circleId: String, keys: MemberKeyPair) async throws {"))
        let admitBody = circles[admitWaiting.upperBound...].prefix(2_000)
        let keep = try XCTUnwrap(admitBody.range(of: "try PendingChanges.keepSigned(signed.statement, for: change)"))
        let store = try XCTUnwrap(admitBody.range(of: "try await api.storeMemberStatement("))
        XCTAssertLessThan(keep.lowerBound, store.lowerBound)
        // `.letIn`: the answer is a change; the owed pass signs nothing.
        let owed = try XCTUnwrap(circles.range(of: "    private func signOwedAdmissions(in circle: Circle, result: MembershipConfirmation.Result) async {"))
        let owedBody = circles[owed.upperBound...].prefix(2_000)
        XCTAssertTrue(owedBody.contains(".letIn, circleId: circle.id, inputs: .letIn(.init(memberId: userId, questionKind: \"owed\")),"))
        XCTAssertFalse(owedBody.contains("admit("), "never signed from the owed pass")
        let ask = try XCTUnwrap(circles.range(of: "    private func askAboutHiddenMembers(in circle: Circle, members hidden: [CircleMember],"))
        let askBody = circles[ask.upperBound...].prefix(1_500)
        XCTAssertFalse(askBody.contains("holdsCurrentKey"), "asked while behind too")
        XCTAssertTrue(askBody.contains("&& !answered.contains($0.userId.lowercased())"), "never again while the answer waits")
        // The `letIn` re-check: in the circle, the member present, then
        // `LetInKind.admitted` decides "its admission is held", the
        // owner/admin check and "already let in", in that order (its
        // behaviour: PendingChangeSignedIdTests), before their keys or the signing
        // key are checked: a held one only records the choice, so none of
        // those may stop it. The role is asked nowhere else.
        let kindsSource = try source("App/Domain/PendingChanges/PendingChangeKinds.swift")
        let letInKind = try XCTUnwrap(kindsSource.range(of: "struct LetInKind: PendingChangeHandler {"))
        let letInBody = kindsSource[letInKind.upperBound...].prefix(3_000)
        let inCircle = try XCTUnwrap(letInBody.range(of: "if let left = PendingChangeKinds.notInCircle(change) { return left }"))
        let listedCheck = try XCTUnwrap(letInBody.range(of: "guard present else { return .drop(line: PendingChangeCopy.memberLeft(change, name: name)) }"))
        let decided = try XCTUnwrap(letInBody.range(of: "if let decided = Self.admitted(\n            change, ownerOrAdmin: PendingChangeKinds.ownerOrAdmin(change),\n            verdict: CircleManager.shared.membership[change.circleId]?.verdicts[inputs.memberId]) {\n            return decided\n        }"))
        let keysCheck = try XCTUnwrap(letInBody.range(of: "guard let listed = CircleManager.shared.listedKeys(for: inputs.memberId, in: change.circleId) else {"))
        let signingKey = try XCTUnwrap(letInBody.range(of: "guard !SelfKeyManager.signingKeyMissing else { return .needsPerson(.password, seen: change.seen) }"))
        XCTAssertLessThan(inCircle.lowerBound, listedCheck.lowerBound)
        XCTAssertLessThan(listedCheck.lowerBound, decided.lowerBound)
        XCTAssertLessThan(decided.lowerBound, keysCheck.lowerBound)
        XCTAssertLessThan(decided.lowerBound, signingKey.lowerBound)
        XCTAssertEqual(letInBody[..<signingKey.lowerBound].components(separatedBy: "ownerOrAdmin(").count, 2,
                       "the role is asked once, inside `admitted`, after the held check")
        XCTAssertEqual(PendingChangeCopy.alreadyLetIn(name: "Sam"), "Sam was already let in.")
        // All four run.
        let kinds = try source("App/Domain/PendingChanges/PendingChangeKinds.swift")
        for kind in [".invite: InviteKind()", ".makeAdmin: MakeAdminKind()", ".letIn: LetInKind()",
                     ".renewInvitation: RenewInvitationKind()"] {
            XCTAssertTrue(kinds.contains(kind), kind)
        }
        // The Invite button is enabled while behind; the invitation waits.
        let view = try source("App/Views/Circles/CirclesView.swift")
        XCTAssertTrue(view.contains(".disabled(email.isEmpty || isLoading)\n"))
        XCTAssertTrue(view.contains("PendingChangesInPlace(kinds: [.invite, .renewInvitation], circleId: circle.id)"))
        XCTAssertTrue(view.contains("PendingChangesInPlace(kinds: [.makeAdmin, .letIn], circleId: circle.id)"))
        // The question and the password, in place.
        let rows = try source("App/Views/Circles/PendingChangeViews.swift")
        XCTAssertTrue(rows.contains("case .needsPerson(.keysChanged):\n                PendingQuestion(change: change)"))
        XCTAssertTrue(rows.contains("case .needsPerson(.password):\n                // Asked in place: once typed, the change carries on.\n                PasswordUnlockForm()"))
    }

    /// After a lost answer a change never undoes what the person did
    /// elsewhere: a `sharePlace` change is never shared again
    /// (`PendingChangeCopy.notDone`), an `alertChange` never overwrites a
    /// rule changed meanwhile (`alertChangedElsewhere`), and an `arrived`
    /// change ends quietly when its destination left the list.
    func testALostAnswerNeverUndoesWhatThePersonDidElsewhere() throws {
        let kinds = try source("App/Domain/PendingChanges/PendingChangeKinds.swift")
        let share = try XCTUnwrap(kinds.range(of: "struct SharePlaceKind: PendingChangeHandler {"))
        let shareBody = kinds[share.upperBound...].prefix(2_500)
        let guardLost = try XCTUnwrap(shareBody.range(of: "if change.mayHaveGoneOut { return .drop(line: PendingChangeCopy.notDone(change)) }"))
        let run = try XCTUnwrap(shareBody.range(of: "return .run(change)"))
        XCTAssertLessThan(guardLost.lowerBound, run.lowerBound)
        XCTAssertTrue(kinds.contains("""
                    if .alertChange(now) == target { return .done(line: nil) }
                    guard now == seen else { return .drop(line: PendingChangeCopy.alertChangedElsewhere) }
        """))
        XCTAssertTrue(kinds.contains("if change.mayHaveGoneOut { return .done(line: nil) }\n            return .drop(line: PendingChangeCopy.deleted(change, thing: \"the destination\"))"))
        let rules = try source("App/Managers/AlertRulesManager.swift")
        XCTAssertTrue(rules.contains("seen: .init(rule: fields(of: rule)))"), "the rule as the person saw it")
        XCTAssertEqual(PendingChangeCopy.alertChangedElsewhere,
                       "Your change to this alert wasn't saved: it was changed on another device in the meantime.")
        let share2 = PendingChanges.make(.sharePlace, account: me, circleId: circle, inputs: .sharePlace(placeId: "p"),
                                         subject: "Home")
        XCTAssertEqual(PendingChangeCopy.notDone(share2), "Sharing Home wasn't done.")
    }

    // MARK: - The wording (iPhone)

    func testTheWording() {
        func change(_ kind: PendingChange.Kind, _ inputs: PendingChange.Inputs, subject: String? = nil) -> PendingChange {
            PendingChanges.make(kind, account: me, circleId: circle, inputs: inputs, circleName: "Family",
                                subject: subject)
        }
        let checkIn = change(.checkIn, .checkIn(.init(type: "general", message: nil, latitude: nil, longitude: nil,
                                                      placeId: nil, checkedInAt: Date())))
        let destination = change(.destination, .destination(.init(name: "Gym", latitude: 1, longitude: 2, eta: nil,
                                                                  notifyArrival: true)))
        let unnamed = change(.destination, .destination(.init(name: nil, latitude: 1, longitude: 2, eta: nil,
                                                              notifyArrival: true)))
        let arrived = change(.arrived, .arrived(.init(destinationId: "d", arrivedAt: Date())))
        let share = change(.sharePlace, .sharePlace(placeId: "p"), subject: "Home")
        let edit = change(.editPlace, .editPlace(placeId: "p", fields: .init(name: "Home", latitude: 1, longitude: 2,
                                                                            radius: 100, icon: "house", color: "#fff")),
                          subject: "Home")
        let newAlert = change(.batteryAlert, .batteryAlert(.init(targetUserId: "u", threshold: 20, notifyPush: true,
                                                                 notifyEmail: false, cooldownMinutes: 60)))
        let alertChange = change(.alertChange, .alertChange(.init(ruleId: "r", threshold: 10)))
        let rename = change(.renameCircle, .renameCircle(newName: "Clan"))

        XCTAssertEqual(PendingChangeCopy.waiting(checkIn),
                       "Waiting to sync. Your check-in will be sent as soon as this iPhone catches up, with the time you checked in.")
        XCTAssertEqual(PendingChangeCopy.waiting(destination),
                       "Waiting to sync. Gym will be shared with Family as soon as this iPhone catches up.")
        XCTAssertEqual(PendingChangeCopy.waiting(unnamed),
                       "Waiting to sync. Your destination will be shared with Family as soon as this iPhone catches up.")
        XCTAssertEqual(PendingChangeCopy.waiting(arrived),
                       "Waiting to sync. Your arrival will be sent as soon as this iPhone catches up.")
        XCTAssertEqual(PendingChangeCopy.waiting(share),
                       "Waiting to sync. Home will be shared with Family as soon as this iPhone catches up.")
        XCTAssertEqual(PendingChangeCopy.waiting(edit),
                       "Waiting to sync. Your changes to Home will be saved as soon as this iPhone catches up.")
        XCTAssertEqual(PendingChangeCopy.waiting(newAlert),
                       "Waiting to sync. This alert will be set up as soon as this iPhone catches up.")
        XCTAssertEqual(PendingChangeCopy.waiting(alertChange),
                       "Waiting to sync. Your changes to this alert will be saved as soon as this iPhone catches up.")
        XCTAssertEqual(PendingChangeCopy.waiting(rename),
                       "Waiting to sync. Family will be renamed to \"Clan\" as soon as this iPhone catches up.")
        XCTAssertEqual(PendingChangeCopy.sending, "Sending…")
        XCTAssertEqual(PendingChangeCopy.cancelling, "Cancelling…")
        XCTAssertEqual(PendingChangeCopy.waitingForPassword, "Waiting for your password")
        XCTAssertEqual(PendingChangeCopy.count(1), "1 change waiting to go out from this iPhone")
        XCTAssertEqual(PendingChangeCopy.count(3), "3 changes waiting to go out from this iPhone")
        XCTAssertEqual(PendingChangeCopy.tooOld(checkIn), "Your check-in wasn't done: this iPhone took too long to catch up.")
        XCTAssertEqual(PendingChangeCopy.alreadyShared(place: "Home", circle: "Family"), "Home is already shared with Family.")
        XCTAssertEqual(PendingChangeCopy.memberLeft(newAlert, name: "Sam"), "This alert wasn't done: Sam is no longer in Family.")
        XCTAssertEqual(PendingChangeCopy.deleted(arrived, thing: "the destination"),
                       "Your arrival wasn't done: the destination was deleted.")
        XCTAssertEqual(PendingChangeCopy.deleted(alertChange, thing: "the alert"),
                       "Your changes to this alert wasn't done: the alert was deleted.")
        XCTAssertEqual(PendingChangeCopy.placeChangedElsewhere(place: "Home"),
                       "Your changes to Home weren't saved: it was changed on another device in the meantime.")
        XCTAssertEqual(PendingChangeCopy.renamedElsewhere(circle: "Family", to: "Kin"),
                       "Family wasn't renamed: it was renamed to \"Kin\" in the meantime.")
        XCTAssertEqual(PendingChangeCopy.notOwnerOrAdmin(rename),
                       "Renaming Family wasn't done: you're no longer an owner or admin of Family.")
        XCTAssertEqual(PendingChangeCopy.circleGone(checkIn), "Your check-in wasn't done: Family no longer exists.")
        XCTAssertEqual(PendingChangeCopy.notDone(checkIn), "Your check-in wasn't done.")
        // {what} per kind, the same on all three clients.
        XCTAssertEqual(PendingChangeCopy.what(destination), "Your destination", "not its name")
        XCTAssertEqual(PendingChangeCopy.what(edit), "Your changes to Home")
        XCTAssertEqual(PendingChangeCopy.what(alertChange), "Your changes to this alert")
        XCTAssertEqual(PendingChangeCopy.what(share), "Sharing Home")
        XCTAssertEqual(PendingChangeCopy.what(rename), "Renaming Family")
        XCTAssertEqual(PendingChangeCopy.what(arrived), "Your arrival")
        XCTAssertEqual(PendingChangeCopy.what(newAlert), "This alert")
        XCTAssertEqual(PendingChangeCopy.mayHaveGoneOut(share),
                       "Cancelled, but sharing Home may already have gone out. If it did, it shows as usual.")
        XCTAssertEqual(PendingChangeCopy.mayHaveGoneOut(checkIn),
                       "Cancelled, but your check-in may already have gone out. If it did, it shows as usual.")
        XCTAssertEqual(PendingChangeCopy.signOutLine(2), "2 changes waiting to sync on this iPhone won't be made.")
        XCTAssertEqual(PendingChangeCopy.removed(name: "Sam", circle: "Family", serverLine: "They can no longer reach this circle."),
                       "Sam was removed from Family. They can no longer reach this circle.")
        XCTAssertEqual(PendingChangeCopy.detailsKeepChangingRenewal, InvitationRenewals.changedTwiceText)
        XCTAssertEqual(SettingsView.signOutMessage(waiting: 0),
                       "This device stops sharing your location with your circles until you sign in again.")
        XCTAssertEqual(SettingsView.signOutMessage(waiting: 1),
                       "This device stops sharing your location with your circles until you sign in again.\n\n1 change waiting to sync on this iPhone won't be made.")
    }
}
