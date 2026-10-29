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

/// On the asker's own live screen (SOSView's card, the map's sheet), who is
/// responding comes ONLY from `GET /sos/{id}`, which serves `acknowledged_by`
/// to the raiser alone, never the raiser's own id. /sos/active and every
/// other reply stay counts-only. One name, the first (oldest first) whose
/// sealed name opened here, and how many others, counted from the list and
/// never from `acknowledgment_count`; "Someone" when no name opened.
final class RaiserRespondersTests: XCTestCase {
    // The server's own answers, exactly as served: (a) GET /sos/{id} to the
    // raiser after two acknowledgements, (b) to the raiser before any, (c) to
    // another member, (d) /sos/active to the raiser. The sealed fields are
    // test bytes.
    private static let asRaiserAfterTwo = #"{"success":true,"data":{"id":"2b6d26f0-90ba-42dc-8b5c-43f6e7e473bb","circle_id":"82007c83-d324-4e8b-baf5-5f975ee5c61f","encrypted_location":{"nonce":"080808080808080808080808080808080808080808080808","ciphertext":"0707070707070707070707070707070707070707070707070707070707070707"},"encrypted_device_state":null,"status":"active","encrypted_user_id":{"nonce":"080808080808080808080808080808080808080808080808","ciphertext":"0707070707070707070707070707070707070707070707070707070707070707"},"encrypted_device_id":{"nonce":"080808080808080808080808080808080808080808080808","ciphertext":"0707070707070707070707070707070707070707070707070707070707070707"},"day_bucket":20000,"encrypted_timestamp":{"nonce":"080808080808080808080808080808080808080808080808","ciphertext":"0707070707070707070707070707070707070707070707070707070707070707"},"resolved_day_bucket":null,"acknowledged_by_me":false,"dismissed_by_me":false,"dismissed_at":null,"acknowledgment_count":2,"acknowledged_by":["2e12fee7-0f26-4867-bfcc-58f0905a944e","ca25129b-f5b6-46e3-8e3f-c62844c490d9"]}}"#
    private static let asRaiserBeforeAny = #"{"success":true,"data":{"id":"2b6d26f0-90ba-42dc-8b5c-43f6e7e473bb","circle_id":"82007c83-d324-4e8b-baf5-5f975ee5c61f","encrypted_location":{"nonce":"080808080808080808080808080808080808080808080808","ciphertext":"0707070707070707070707070707070707070707070707070707070707070707"},"encrypted_device_state":null,"status":"active","encrypted_user_id":{"nonce":"080808080808080808080808080808080808080808080808","ciphertext":"0707070707070707070707070707070707070707070707070707070707070707"},"encrypted_device_id":{"nonce":"080808080808080808080808080808080808080808080808","ciphertext":"0707070707070707070707070707070707070707070707070707070707070707"},"day_bucket":20000,"encrypted_timestamp":{"nonce":"080808080808080808080808080808080808080808080808","ciphertext":"0707070707070707070707070707070707070707070707070707070707070707"},"resolved_day_bucket":null,"acknowledged_by_me":false,"dismissed_by_me":false,"dismissed_at":null,"acknowledgment_count":0,"acknowledged_by":[]}}"#
    private static let asAnotherMember = #"{"success":true,"data":{"id":"2b6d26f0-90ba-42dc-8b5c-43f6e7e473bb","circle_id":"82007c83-d324-4e8b-baf5-5f975ee5c61f","encrypted_location":{"nonce":"080808080808080808080808080808080808080808080808","ciphertext":"0707070707070707070707070707070707070707070707070707070707070707"},"encrypted_device_state":null,"status":"active","encrypted_user_id":{"nonce":"080808080808080808080808080808080808080808080808","ciphertext":"0707070707070707070707070707070707070707070707070707070707070707"},"encrypted_device_id":{"nonce":"080808080808080808080808080808080808080808080808","ciphertext":"0707070707070707070707070707070707070707070707070707070707070707"},"day_bucket":20000,"encrypted_timestamp":{"nonce":"080808080808080808080808080808080808080808080808","ciphertext":"0707070707070707070707070707070707070707070707070707070707070707"},"resolved_day_bucket":null,"acknowledged_by_me":true,"dismissed_by_me":false,"dismissed_at":null,"acknowledgment_count":2}}"#
    private static let activeAsRaiser = #"{"success":true,"data":[{"id":"2b6d26f0-90ba-42dc-8b5c-43f6e7e473bb","circle_id":"82007c83-d324-4e8b-baf5-5f975ee5c61f","encrypted_location":{"nonce":"080808080808080808080808080808080808080808080808","ciphertext":"0707070707070707070707070707070707070707070707070707070707070707"},"encrypted_device_state":null,"status":"active","encrypted_user_id":{"nonce":"080808080808080808080808080808080808080808080808","ciphertext":"0707070707070707070707070707070707070707070707070707070707070707"},"encrypted_device_id":{"nonce":"080808080808080808080808080808080808080808080808","ciphertext":"0707070707070707070707070707070707070707070707070707070707070707"},"day_bucket":20000,"encrypted_timestamp":{"nonce":"080808080808080808080808080808080808080808080808","ciphertext":"0707070707070707070707070707070707070707070707070707070707070707"},"resolved_day_bucket":null,"acknowledged_by_me":false,"dismissed_by_me":false,"dismissed_at":null,"acknowledgment_count":2}]}"#
    private let raiser = "89351dd8-e5af-4e40-9947-83e479cdc047"
    private let first = "2e12fee7-0f26-4867-bfcc-58f0905a944e"
    private let second = "ca25129b-f5b6-46e3-8e3f-c62844c490d9"
    private let circleId = "82007c83-d324-4e8b-baf5-5f975ee5c61f"
    private let alertId = "2b6d26f0-90ba-42dc-8b5c-43f6e7e473bb"
    private let otherAlert = "a7a70000-0000-4000-8000-0000000000f6"
    private let stranger = "a7a70000-0000-4000-8000-00000000000e"

    private func decoded<T: Decodable>(_ envelope: String) throws -> T {
        try APIService.decodeResponseBody(Data(envelope.utf8))
    }

    /// Answer (a) with another list (nil: none) and count: the server's own
    /// shape, varied.
    private func asRaiser(listing list: Any?, count: Int = 2) throws -> String {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(Self.asRaiserAfterTwo.utf8)) as? [String: Any])
        var data = try XCTUnwrap(object["data"] as? [String: Any])
        data["acknowledged_by"] = list
        data["acknowledgment_count"] = count
        object["data"] = data
        return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    func testGetByIdTellsTheRaiserWhoIsRespondingOldestFirst() throws {
        let own: OwnSOSResponse = try decoded(Self.asRaiserAfterTwo)
        XCTAssertEqual(own.acknowledgedBy, [first, second])
        XCTAssertEqual(own.alert.id, alertId)
        XCTAssertEqual(own.alert.acknowledgmentCount, 2)
        XCTAssertEqual(SOSManager.servedResponders(own, alertId: alertId, mine: alertId.uppercased()), [first, second])

        let nobodyYet: OwnSOSResponse = try decoded(Self.asRaiserBeforeAny)
        XCTAssertEqual(nobodyYet.alert.acknowledgmentCount, 0)
        XCTAssertEqual(SOSManager.servedResponders(nobodyYet, alertId: alertId, mine: alertId), [])

        let odd: OwnSOSResponse = try decoded(asRaiser(listing: [first, "not-an-id", first.uppercased(), second],
                                                       count: 3))
        XCTAssertEqual(SOSManager.servedResponders(odd, alertId: alertId, mine: alertId), [first, second],
                       "each once, in its one form; no id names nobody")
        let unreadable: OwnSOSResponse = try decoded(asRaiser(listing: "everyone", count: 1))
        XCTAssertNil(unreadable.acknowledgedBy, "an unreadable list never fails the status poll")
        XCTAssertEqual(unreadable.alert.acknowledgmentCount, 1)
    }

    /// Another member's GET has no key (the count alone), and a list on an
    /// alert that isn't this device's own would name nobody even if one
    /// ever appeared.
    func testAnotherMembersViewStaysACount() throws {
        let theirs: OwnSOSResponse = try decoded(Self.asAnotherMember)
        XCTAssertNil(theirs.acknowledgedBy)
        XCTAssertEqual(theirs.alert.acknowledgmentCount, 2)
        XCTAssertNil(SOSManager.servedResponders(theirs, alertId: alertId, mine: alertId), "no list: the count alone")

        let stray: OwnSOSResponse = try decoded(Self.asRaiserAfterTwo)
        XCTAssertNil(SOSManager.servedResponders(stray, alertId: alertId, mine: nil), "no alert of this device's own")
        XCTAssertNil(SOSManager.servedResponders(stray, alertId: alertId, mine: otherAlert), "not this device's alert")
        XCTAssertNil(SOSManager.servedResponders(stray, alertId: otherAlert, mine: otherAlert),
                     "an answer about another alert")
    }

    /// /sos/active, and every reply but the raiser's GET, decode as
    /// `SOSResponse`, which has no place for who is responding: even a key
    /// there would name nobody.
    func testTheActiveListNamesNobody() throws {
        let list: [SOSResponse] = try decoded(Self.activeAsRaiser)
        XCTAssertEqual(list.map(\.acknowledgmentCount), [2])
        let fields = Mirror(reflecting: list[0]).children.compactMap(\.label)
        XCTAssertTrue(fields.contains("acknowledgmentCount"))
        XCTAssertFalse(fields.contains("acknowledgedBy"), "\(fields)")
        let keyed: SOSResponse = try decoded(Self.asRaiserAfterTwo)
        XCTAssertFalse(Mirror(reflecting: keyed).children.contains { $0.label == "acknowledgedBy" },
                       "read as SOSResponse, the list is dropped")
    }

    func testOneNameAndHowManyOthers() {
        let names = [first: "Ana", second: "Ben"]
        func line(_ ids: [String]?, shown: [String: String]? = nil) -> String? {
            NamedNotificationCopy.responding(ids, me: raiser) { (shown ?? names)[$0] }
        }
        XCTAssertNil(line(nil), "not served: the count alone")
        XCTAssertNil(line([]), "nobody yet")
        XCTAssertEqual(line([first]), "Ana is responding")
        XCTAssertEqual(line([first, second]), "Ana and 1 other are responding", "the first, oldest first")
        XCTAssertEqual(line([stranger, second, first]), "Ben and 2 others are responding", "the first whose name opened")
        XCTAssertEqual(line([stranger]), "Someone is responding")
        XCTAssertEqual(line([stranger, otherAlert]), "Someone and 1 other are responding")
        XCTAssertEqual(line([raiser.uppercased(), first]), "Ana is responding",
                       "the raiser's own id (older data) is skipped, never counted")
        XCTAssertNil(line([raiser]))
        XCTAssertEqual(line([first], shown: [first: ""]), "Someone is responding", "an empty name is no name")
    }

    /// The line names only as every named surface does: a member this device
    /// shows, by the sealed name that opened here; on this device's own alert
    /// alone; and counts the LIST, whatever `acknowledgment_count` says.
    func testTheLineNamesOnlyAShownMemberWhoseNameOpenedHere() throws {
        var alert = SOSAlert(id: alertId, circleId: circleId.uppercased(), userId: raiser, status: .active,
                             latitude: nil, longitude: nil, acknowledgedBy: [], createdAt: Date())
        alert.acknowledgmentCount = 2
        func member(_ userId: String, _ name: String) -> CircleMember {
            CircleMember(circleId: circleId, userId: userId, displayName: name, role: .member, canSeeRealtime: true,
                         canSeeHistory: true, canRotateKeys: false, joinedAt: Date())
        }
        let shown = [circleId: [member(first, "Ana"), member(second, "Ben")]]
        let served = try XCTUnwrap(SOSManager.servedResponders(decoded(Self.asRaiserAfterTwo), alertId: alertId,
                                                               mine: alertId))
        func line(_ responders: [String]? = nil, mine: String? = nil, members: [String: [CircleMember]]? = nil,
                  opened: [String: Set<String>]) -> String? {
            SOSManager.respondingLine(for: alert, mine: mine ?? alertId, responders: [alertId: responders ?? served],
                                      me: raiser, members: members ?? shown, opened: opened)
        }
        XCTAssertEqual(line(opened: [circleId: [first, second]]), "Ana and 1 other are responding")
        XCTAssertEqual(line(opened: [circleId: [second]]), "Ben and 1 other are responding",
                       "Ana's sealed name didn't open: the next one")
        XCTAssertEqual(line(opened: [:]), "Someone and 1 other are responding", "the plaintext name: never")
        XCTAssertEqual(line(members: [circleId: [member(second, "Ben")]], opened: [circleId: [first, second]]),
                       "Ben and 1 other are responding", "Ana isn't shown here (left, or not confirmed)")
        XCTAssertEqual(line([first], opened: [circleId: [first, second]]), "Ana is responding",
                       "two acknowledgements counted, one in the list (the raiser's own): the list decides")
        XCTAssertEqual(line([raiser, first], opened: [circleId: [first, raiser]]), "Ana is responding",
                       "the raiser's own id in older data: skipped")
        XCTAssertNil(line(mine: otherAlert, opened: [circleId: [first, second]]), "another member's alert: the count")
        XCTAssertNil(SOSManager.respondingLine(for: alert, mine: alertId, responders: [:], me: raiser, members: shown,
                                               opened: [circleId: [first, second]]), "not served: the count")
    }

    // MARK: - Wiring

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// Only the raiser's own reads, the status poll and the restore of an
    /// alert raised elsewhere, read who is responding, and both screens show
    /// it on the raiser's own alert alone.
    func testOnlyTheRaisersPollReadsWhoIsResponding() throws {
        let manager = try source("App/Managers/SOSManager.swift")
        XCTAssertEqual(manager.components(separatedBy: "getOwnSOSAlert(").count - 1, 2,
                       "the status poll and the restore")
        XCTAssertTrue(manager.contains("""
                        if let served = Self.servedResponders(own, alertId: alertId, mine: myActiveAlert?.id) {
                            responders[CanonicalId.key(alertId)] = served
                        }
        """))
        XCTAssertTrue(manager.contains("""
                        responders[CanonicalId.key(restored.id)] = Self.servedResponders(served, alertId: restored.id,
                                                                                         mine: restored.id)
        """), "the restore keeps them for the alert it shows as the asker's own")
        XCTAssertEqual(manager.components(separatedBy: "responders[CanonicalId.key(").count - 1, 4,
                       "set by the poll and the restore, cleared on close, read by the line")
        XCTAssertTrue(try source("App/Views/Safety/SOSView.swift")
            .contains("if let responding = sosManager.respondingLine(for: alert) {"))
        let sheet = try source("App/Views/Map/SOSMapOverlays.swift")
        // The sheet reads the store's copy of the alert (`live`), which an
        // update moves in place.
        XCTAssertTrue(sheet.contains("if isMine, let responding = sosManager.respondingLine(for: live) {"))
        XCTAssertTrue(sheet.contains("} else if live.acknowledgmentCount > 0 {"), "everyone else: the count")
    }

    // MARK: - Did it get through?

    private func delivery(_ json: String?, checking: Bool) throws -> SOSManager.DeliveryStatus {
        let response = try json.map { try JSONDecoder().decode(SOSDeliveryResponse.self, from: Data($0.utf8)) }
        return SOSManager.DeliveryStatus(alertId: alertId, response: response, stillChecking: checking)
    }

    /// The verdict is the server's latest answer, for each state, the moment
    /// it is known; "Checking…" only while nothing has answered and the checks
    /// go on; and checks that end with no answer say so, never "Checking…" for
    /// ever.
    func testTheVerdictIsTheLatestAnswer() throws {
        XCTAssertEqual(SOSDeliveryCopy.verdict(try delivery(nil, checking: true)),
                       "Checking whether your circle received it…")
        XCTAssertEqual(SOSDeliveryCopy.verdict(try delivery(nil, checking: false)),
                       "We couldn't find out whether it arrived. If this matters right now, reach someone another way.")
        // An answer exactly as the server sends it.
        let nobody = #"{"addressable":1,"confirmed":0,"dispatched":1,"emailed":0,"recipients":1,"state":"no_confirmation"}"#
        let nobodyText = "Nobody's device has confirmed yet. We sent it, but we cannot tell whether it arrived. "
            + "If this matters right now, reach someone another way."
        XCTAssertEqual(SOSDeliveryCopy.verdict(try delivery(nobody, checking: true)), nobodyText)
        XCTAssertEqual(SOSDeliveryCopy.verdict(try delivery(nobody, checking: false)), nobodyText, "kept once the checks end")
        let partial = #"{"addressable":3,"confirmed":1,"dispatched":3,"emailed":1,"recipients":3,"state":"partial"}"#
        XCTAssertEqual(SOSDeliveryCopy.verdict(try delivery(partial, checking: true)),
                       "1 of 3 confirmed their device received it. The rest have not yet — a phone that is off or has no "
                       + "signal cannot confirm.\n\nWe also emailed 1.\n\nConfirmed means the notification reached "
                       + "their device — not that anyone has read it or is on their way.")
        let all = #"{"addressable":2,"confirmed":2,"dispatched":2,"emailed":0,"recipients":2,"state":"confirmed"}"#
        XCTAssertTrue(SOSDeliveryCopy.verdict(try delivery(all, checking: false))
            .hasPrefix("All 2 confirmed their device received it."))
        let alone = #"{"addressable":0,"confirmed":0,"dispatched":0,"emailed":0,"recipients":0,"state":"alone"}"#
        XCTAssertTrue(SOSDeliveryCopy.verdict(try delivery(alone, checking: false)).hasPrefix("Nobody else is in this circle"))
        let none = #"{"addressable":0,"confirmed":0,"dispatched":0,"emailed":0,"recipients":2,"state":"undeliverable"}"#
        XCTAssertTrue(SOSDeliveryCopy.verdict(try delivery(none, checking: false)).hasPrefix("This did not reach anyone."))
        let pending = #"{"addressable":2,"confirmed":0,"dispatched":0,"emailed":0,"recipients":2,"state":"pending"}"#
        XCTAssertEqual(SOSDeliveryCopy.verdict(try delivery(pending, checking: true)), SOSDeliveryCopy.checking)
        XCTAssertEqual(SOSDeliveryCopy.verdict(try delivery(pending, checking: false)), SOSDeliveryCopy.noAnswer)
    }

    /// The active card shows it, bound to `delivery` as it changes, and keeps
    /// it; no alert carries it, since an alert's text is set when it shows; it
    /// goes with the alert, and at a sign-out.
    func testTheVerdictIsOnTheActiveCardAsItChanges() throws {
        let view = try source("App/Views/Safety/SOSView.swift")
        XCTAssertFalse(view.contains("\"Did it get through?\",\n"), "never an alert's title again")
        XCTAssertFalse(view.contains("deliveryMessage"))
        let start = try XCTUnwrap(view.range(of: "struct ActiveSOSCard: View {"))
        let end = try XCTUnwrap(view.range(of: "\n}\n", range: start.upperBound..<view.endIndex))
        let card = String(view[start.upperBound..<end.lowerBound])
        XCTAssertTrue(card.contains("if let delivery = sosManager.delivery, CanonicalId.same(delivery.alertId, alert.id) {"))
        XCTAssertTrue(card.contains("Text(\"Did it get through?\")"))
        XCTAssertTrue(card.contains("Text(SOSDeliveryCopy.verdict(delivery))"))
        XCTAssertTrue(card.contains("if delivery.stillChecking {"))
        let manager = try source("App/Managers/SOSManager.swift")
        XCTAssertTrue(manager.contains(
            "        if let delivery, CanonicalId.same(delivery.alertId, alertId) { clearDelivery() }\n"))
        let reset = try XCTUnwrap(manager.range(of: "    func reset() {\n"))
        let resetEnd = try XCTUnwrap(manager.range(of: "\n    }\n", range: reset.upperBound..<manager.endIndex))
        XCTAssertTrue(manager[reset.upperBound..<resetEnd.lowerBound].contains("        clearDelivery()\n"))
    }

    /// The card's headline claims nothing about delivery: "Your circle was
    /// notified" would be false when nobody was reached, right above "This did
    /// not reach anyone". "Did it get through?" alone speaks of delivery.
    func testTheHeadlineClaimsNoDelivery() throws {
        let view = try source("App/Views/Safety/SOSView.swift")
        XCTAssertFalse(view.contains("Your circle was notified"))
        XCTAssertTrue(view.contains("                    Text(\"Your circle notification\")\n"))
    }

    /// A circle notification that settled as reaching nobody, or whose checks
    /// ended with no answer at all, is said once, unmissably: an alert
    /// wherever the person is in the app, or a local notification when Track
    /// isn't in front. Each in its own words; never while the checks go on,
    /// never for one that reached someone, never twice.
    func testANotificationThatReachedNobodyOrNoAnswerIsSaidOnce() throws {
        let alone = #"{"addressable":0,"confirmed":0,"dispatched":0,"emailed":0,"recipients":0,"state":"alone"}"#
        let none = #"{"addressable":0,"confirmed":0,"dispatched":0,"emailed":0,"recipients":2,"state":"undeliverable"}"#
        let nobody = "Your circle notification didn't reach anyone"
        XCTAssertEqual(SOSDeliveryCopy.reachedNobodyTitle, nobody)
        XCTAssertEqual(SOSManager.deliveryNotice(try delivery(alone, checking: false), alreadySaid: [])?.body,
                       "Nobody else is in this circle, so there was no one to notify. "
                       + "If you need help now, contact someone directly, or notify a different circle.")
        XCTAssertEqual(SOSManager.deliveryNotice(try delivery(none, checking: false), alreadySaid: [])?.body,
                       "Nobody in this circle has a device we can notify. Contact them another way.",
                       "not the card's line: the title already says it reached nobody")
        for json in [alone, none] {
            let settled = try delivery(json, checking: false)
            XCTAssertEqual(SOSManager.deliveryNotice(settled, alreadySaid: [])?.title, nobody)
            XCTAssertNil(SOSManager.deliveryNotice(settled, alreadySaid: [CanonicalId.key(alertId.uppercased())]),
                         "said once, in any spelling of the id")
            XCTAssertNil(SOSManager.deliveryNotice(try delivery(json, checking: true), alreadySaid: []),
                         "never while the checks go on")
        }

        // No answer at all, or one that is no answer (as the card has it).
        let unknownTitle = "Your circle notification may not have arrived"
        let unknownBody = "We couldn't find out whether it reached anyone. If you need help now, contact someone directly."
        XCTAssertEqual(SOSDeliveryCopy.noAnswerTitle, unknownTitle)
        XCTAssertEqual(SOSDeliveryCopy.noAnswerBody, unknownBody)
        let pending = #"{"addressable":2,"confirmed":0,"dispatched":0,"emailed":0,"recipients":2,"state":"pending"}"#
        for json in [nil, pending] {
            let notice = SOSManager.deliveryNotice(try delivery(json, checking: false), alreadySaid: [])
            XCTAssertEqual(notice?.title, unknownTitle, json ?? "nil")
            XCTAssertEqual(notice?.body, unknownBody)
            XCTAssertNotEqual(notice?.title, nobody, "unknown is not nobody")
            XCTAssertNil(SOSManager.deliveryNotice(try delivery(json, checking: true), alreadySaid: []))
        }

        // Reached someone, or sent and waiting on a device: none.
        let reached = [
            #"{"addressable":2,"confirmed":2,"dispatched":2,"emailed":0,"recipients":2,"state":"confirmed"}"#,
            #"{"addressable":2,"confirmed":1,"dispatched":2,"emailed":0,"recipients":2,"state":"partial"}"#,
            #"{"addressable":2,"confirmed":0,"dispatched":2,"emailed":0,"recipients":2,"state":"no_confirmation"}"#,
        ]
        for json in reached {
            XCTAssertNil(SOSManager.deliveryNotice(try delivery(json, checking: false), alreadySaid: []), json)
        }
        for words in [nobody, unknownTitle, unknownBody,
                      SOSDeliveryCopy.reachedNobodyBody("alone") ?? "", SOSDeliveryCopy.reachedNobodyBody("undeliverable") ?? ""] {
            XCTAssertFalse(words.localizedCaseInsensitiveContains("try again"), "same circle, same answer: \(words)")
            XCTAssertFalse(words.localizedCaseInsensitiveContains("SOS"), words)
        }

        let manager = try source("App/Managers/SOSManager.swift")
        XCTAssertTrue(manager.contains(
            "    @Published var delivery: DeliveryStatus? {\n        didSet { if let delivery { noteDeliveryNotice(delivery) } }\n"),
                      "every change of the answer is looked at")
        XCTAssertTrue(manager.contains("        if UIApplication.shared.applicationState == .active {\n"
                                       + "            deliveryNotice = DeliveryNotice(alertId: status.alertId, title: notice.title, body: notice.body)\n"
                                       + "        } else {\n"))
        XCTAssertTrue(manager.contains("            content.title = notice.title\n            content.body = notice.body\n"))
        XCTAssertTrue(manager.contains("        deliveryNotice = nil\n        saidDeliveryNotice = []\n"), "gone at a sign-out")
        let tabs = try source("App/Views/MainTabView.swift")
        XCTAssertTrue(tabs.contains("        .alert(sosManager.deliveryNotice?.title ?? \"\",\n"
                                    + "               isPresented: Binding(get: { sosManager.deliveryNotice != nil },\n"),
                      "shown wherever the person is in the app")
        XCTAssertTrue(tabs.contains("            Button(\"OK\", role: .cancel) { sosManager.deliveryNotice = nil }\n"), "OK only")
        XCTAssertTrue(tabs.contains("            Text(sosManager.deliveryNotice?.body ?? \"\")\n"))
    }
}
