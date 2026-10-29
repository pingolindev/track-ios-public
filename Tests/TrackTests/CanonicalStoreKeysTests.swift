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

/// In the stores, keys and the compares that keep someone OUT go by an
/// id's key (`CanonicalId.sameKey`: equal non-UUIDs too), and every
/// compare that lets someone in or says "this is me" by `CanonicalId.same`
/// (false for nil or a non-UUID). Nothing else lower-cases an account,
/// circle or member id there.
@MainActor
final class CanonicalStoreKeysTests: XCTestCase {
    private var directory: URL!
    private let me = "0f0f0f0f-1111-2222-3333-444455556666"
    private let circle = "c5000000-0000-4000-8000-000000000001"
    private var upper: String { circle.uppercased() }
    private var bare: String { circle.replacingOccurrences(of: "-", with: "") }
    private let member = "e5000000-0000-4000-8000-000000000001"

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("keys-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func checkIn(_ message: String, circleId: String, now: Date = Date()) -> PendingChange {
        PendingChanges.make(.checkIn, account: me, circleId: circleId,
                            inputs: .checkIn(.init(type: "general", message: message, latitude: 1, longitude: 2,
                                                   placeId: nil, checkedInAt: now)),
                            seen: .init(privacy: .precise), now: now)
    }

    // MARK: - The waiting changes

    /// A circle's changes and lines in any spelling are one circle's; a
    /// change for the same member in another spelling is the same target.
    func testTheWaitingChangesKeyEveryCircleAndMemberAsOne() {
        let store = PendingChangeStore(directory: directory)
        let admin = PendingChanges.make(.makeAdmin, account: me, circleId: circle, inputs: .makeAdmin(memberId: member))
        guard case .queued = store.queue(admin) else { return XCTFail("not queued") }
        let again = PendingChanges.make(.makeAdmin, account: me.uppercased(), circleId: upper,
                                        inputs: .makeAdmin(memberId: member.replacingOccurrences(of: "-", with: "")))
        guard case .merged = store.queue(again) else { return XCTFail("the same target, not merged") }
        XCTAssertEqual(store.pending(circleId: bare).count, 1)
        XCTAssertEqual(store.all(circleId: "{\(circle)}").count, 1)
        guard case .queued = store.queue(checkIn("one", circleId: upper)) else { return XCTFail("not queued") }
        XCTAssertEqual(store.circlesWithWork.map { CanonicalId.key($0) }, [circle], "one circle")
        store.addNotice(account: me, circleId: upper, line: "a line")
        XCTAssertEqual(store.notices(circleId: bare).count, 1)
        store.noticesSeen(circleId: circle)
        XCTAssertTrue(store.notices(circleId: upper).isEmpty)
        let relaunched = PendingChangeStore(directory: directory)
        relaunched.use(account: me.replacingOccurrences(of: "-", with: ""))
        XCTAssertEqual(relaunched.changes.count, 2, "the account's file under any spelling of it")
        store.forgetCircle("{\(circle)}")
        XCTAssertTrue(store.all(circleId: circle).isEmpty)
    }

    /// The cap per circle counts every spelling of it.
    func testThePerCircleCapCountsEverySpelling() {
        let store = PendingChangeStore(directory: directory)
        let start = Date()
        for n in 0..<PendingChangeStore.maxPerCircle {
            let spelling = [circle, upper, bare][n % 3]
            guard case .queued = store.queue(checkIn("n\(n)", circleId: spelling, now: start.addingTimeInterval(Double(n) * 3)),
                                             now: start.addingTimeInterval(Double(n) * 3)) else {
                return XCTFail("\(n) not queued")
            }
        }
        XCTAssertEqual(store.queue(checkIn("over", circleId: "{\(circle)}", now: start.addingTimeInterval(90)),
                                   now: start.addingTimeInterval(90)), .tooMany)
    }

    /// The circles a change waits for an import of, in any spelling.
    func testTheImportWaitsKeyEveryCircleAsOne() {
        var waits = Track.CircleManager.ImportWaits()
        waits.wait(upper)
        XCTAssertTrue(waits.waits(bare))
        waits.end("{\(circle)}")
        XCTAssertFalse(waits.waits(circle))
    }

    // MARK: - Every site, and its kind

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private enum Kind: String { case key, excluding, including }

    /// Each store site, labelled: KEY (a key, a file name, the store's own
    /// lookups), EXCLUDING (sameKey, where a match keeps someone out) and
    /// INCLUDING (same, where a match lets someone in or says "this is me").
    private let sites: [(Kind, String, String)] = [
        (.key, "App/Managers/ApprovalRecord.swift", "\"\\(prefix)\\(CanonicalId.key(owner)).\\(CanonicalId.key(circleId))\""),
        (.key, "App/Managers/ApprovalRecord.swift", "\"\\(legacyPrefix)\\(CanonicalId.key(owner)).\\(CanonicalId.key(circleId))\""),
        (.key, "App/Managers/ApprovalRecord.swift", "transitionPrefix + CanonicalId.key(owner)"),
        (.key, "App/Managers/ApprovalRecord.swift", "invitees[CanonicalId.key(userId)] = PendingInvitee("),
        (.key, "App/Managers/ApprovalRecord.swift", "byKey[CanonicalId.key(userId), default: []].append(invitee)"),
        (.including, "App/Managers/ApprovalRecord.swift", "if let row = CanonicalId.of(userId).flatMap({ rows[$0] }) {"),
        (.including, "App/Managers/ApprovalRecord.swift", "CanonicalId.of(entry.key).map { ($0, (userId: entry.key, invitation: entry.value)) }"),
        (.including, "App/Managers/ApprovalRecord.swift", "let listed = Set(listedUsers.compactMap { CanonicalId.of($0) })"),
        (.including, "App/Managers/ApprovalRecord.swift", "|| CanonicalId.of($0.key).map(listed.contains) == true"),
        (.including, "App/Managers/ApprovalRecord.swift", "guard let subject = CanonicalId.of(subject), let invitee = invitees[subject] else { return false }"),
        (.including, "App/Managers/ApprovalRecord.swift", "guard let userId = CanonicalId.of(candidate).flatMap({ listed[$0] }) else { continue }"),
        (.key, "App/Managers/KeyDeliveryApprovals.swift", "stored.invitees[CanonicalId.key(invitee.userId)]?.statementId"),
        (.key, "App/Managers/KeyDeliveryApprovals.swift", "found.insert(CanonicalId.key(String(owner)))"),
        (.key, "App/Managers/KeyDeliveryApprovals.swift", "let keep = owner.map { CanonicalId.key($0) }"),
        (.key, "App/Managers/KeyDeliveryApprovals.swift", "if let keep, CanonicalId.key(String(found)) == keep { continue }"),
        (.key, "App/Managers/KeyDeliveryApprovals.swift", "owner != CanonicalId.key(String(owner))"),
        (.excluding, "App/Managers/KeyDeliveryApprovals.swift", "let members = users.filter { !CanonicalId.sameKey($0, owner) }"),
        (.key, "App/Managers/RefreshLedger.swift", "        let key = CanonicalId.key(circleId)\n        var entry = circles[key] ?? Circle()"),
        (.key, "App/Managers/RefreshLedger.swift", "        let key = CanonicalId.key(circleId)\n        let before = circles"),
        (.key, "App/Managers/RefreshLedger.swift", "unwritten[CanonicalId.key(account), default: []].append((circle: CanonicalId.key(circleId), change: change))"),
        (.key, "App/Managers/RefreshLedger.swift", "        let account = CanonicalId.key(account)\n        guard self.account != account || unreadable"),
        (.key, "App/Managers/RefreshLedger.swift", "directory?.appendingPathComponent(\"\\(CanonicalId.key(account)).json\", isDirectory: false)"),
        (.key, "App/Managers/RefreshLedger.swift", "let again = Set(before.map { CanonicalId.key($0) })"),
        (.key, "App/Managers/RefreshLedger.swift", "Set((status.notAllowed + uncountedNamed).map { CanonicalId.key($0) }).sorted()"),
        (.excluding, "App/Managers/RefreshLedger.swift", "func isOf(_ userId: String) -> (Removal) -> Bool {\n            { CanonicalId.sameKey($0.userId, userId) }"),
        (.including, "App/Managers/RefreshLedger.swift", "func isSubject(_ userId: String) -> (Removal) -> Bool {\n            { CanonicalId.same($0.userId, userId) }"),
        (.including, "App/Managers/RefreshLedger.swift", "CanonicalId.same($0.userId, userId) && $0.at < decidedAt"),
        (.including, "App/Managers/RefreshLedger.swift", "make(.ranOut(listed: Set(listed.compactMap { CanonicalId.of($0) }), at: now),"),
        (.including, "App/Managers/RefreshLedger.swift", "if CanonicalId.of(cleared.removal.userId).map(listed.contains) != true { noteAgain(cleared.removal) }"),
        (.including, "App/Managers/RefreshLedger.swift", "let about = statements.first { CanonicalId.same($0.key, removal.userId) }?.value ?? []"),
        (.including, "App/Managers/RefreshLedger.swift", "CanonicalId.same(statement.circleId, circleId),"),
        (.including, "App/Managers/RefreshLedger.swift", "CanonicalId.same(statement.signerUserId, me),"),
        (.including, "App/Managers/RefreshLedger.swift", "CanonicalId.same(statement.subjectUserId, removal.userId),"),
        (.key, "App/Managers/BackfillLedger.swift", "\"\\(CanonicalId.key(circleId)):\\(CanonicalId.key(userId))\""),
        (.key, "App/Managers/BackfillLedger.swift", "        let account = CanonicalId.key(account)\n        guard self.account != account || unreadable"),
        (.key, "App/Managers/BackfillLedger.swift", "directory?.appendingPathComponent(\"\\(CanonicalId.key(account)).json\", isDirectory: false)"),
        (.key, "App/Domain/PendingChanges/PendingChangeStore.swift", "directory?.appendingPathComponent(\"\\(CanonicalId.key(account)).json\", isDirectory: false)"),
        (.key, "App/Domain/PendingChanges/PendingChangeStore.swift", "        let account = CanonicalId.key(account)\n        guard self.account != account || unreadable"),
        (.key, "App/Domain/PendingChanges/PendingChangeStore.swift", "changes.filter { CanonicalId.sameKey($0.circleId, circleId) && $0.isPending }"),
        (.key, "App/Domain/PendingChanges/PendingChangeStore.swift", "        changes.filter { CanonicalId.sameKey($0.circleId, circleId) }\n    }"),
        (.key, "App/Domain/PendingChanges/PendingChangeStore.swift", "seen.insert(CanonicalId.key(change.circleId)).inserted ? change.circleId : nil"),
        (.key, "App/Domain/PendingChanges/PendingChangeStore.swift", "        notices.filter { CanonicalId.sameKey($0.circleId, circleId) }\n    }"),
        (.key, "App/Domain/PendingChanges/PendingChangeStore.swift", "$0.kind == change.kind && CanonicalId.sameKey($0.circleId, change.circleId)"),
        (.key, "App/Domain/PendingChanges/PendingChangeStore.swift", "guard live.filter({ CanonicalId.sameKey($0.circleId, change.circleId) }).count < Self.maxPerCircle,"),
        (.key, "App/Domain/PendingChanges/PendingChangeStore.swift", "guard a.kind == b.kind, CanonicalId.sameKey(a.circleId, b.circleId) else { return false }"),
        (.key, "App/Domain/PendingChanges/PendingChangeStore.swift", "case let (.makeAdmin(x), .makeAdmin(y)): return CanonicalId.sameKey(x, y)"),
        (.key, "App/Domain/PendingChanges/PendingChangeStore.swift", "case let (.letIn(x), .letIn(y)): return CanonicalId.sameKey(x.memberId, y.memberId)"),
        (.key, "App/Domain/PendingChanges/PendingChangeStore.swift", "account: CanonicalId.key(account),"),
        (.excluding, "App/Domain/PendingChanges/PendingChangeStore.swift", "        notices.removeAll { CanonicalId.sameKey($0.circleId, circleId) }\n        if notices.count != before { save() }"),
        (.excluding, "App/Domain/PendingChanges/PendingChangeStore.swift", "        changes.removeAll { CanonicalId.sameKey($0.circleId, circleId) }\n        notices.removeAll { CanonicalId.sameKey($0.circleId, circleId) }"),
        (.key, "App/Managers/CircleManager.swift", "chains[CanonicalId.key(keyResp.circleId), default: []]"),
        (.key, "App/Managers/CircleManager.swift", "$0.roleChanges[CanonicalId.key(userId)] = role.rawValue"),
        (.key, "App/Managers/CircleManager.swift", "let id = circles.first { CanonicalId.sameKey($0.id, circleId) }?.id ?? circleId"),
        (.key, "App/Managers/CircleManager.swift", "change.removals.contains { CanonicalId.sameKey($0, removed.userId) }"),
        (.key, "App/Managers/CircleManager.swift", "func waits(_ circleId: String) -> Bool { circles.contains(CanonicalId.key(circleId)) }"),
        (.key, "App/Managers/CircleManager.swift", "mutating func wait(_ circleId: String) { circles.insert(CanonicalId.key(circleId)) }"),
        (.key, "App/Managers/CircleManager.swift", "mutating func end(_ circleId: String) { circles.remove(CanonicalId.key(circleId)) }"),
        (.key, "App/Managers/CircleManager.swift", "inputs[CanonicalId.key(circle.id)] = RefreshRecordsSync.CircleInput("),
        (.key, "App/Managers/CircleManager.swift", "keyChain: Self.importLinks(fetched: keyChainsLastImport[CanonicalId.key(circle.id)] ?? [],"),
        (.key, "App/Managers/CircleManager.swift", "own: ownLinks[CanonicalId.key(circle.id)] ?? []))"),
        (.key, "App/Managers/CircleManager.swift", "        ownLinks.removeValue(forKey: CanonicalId.key(circleId))\n    }"),
    ]

    func testEverySiteIsInPlaceWithItsKind() throws {
        var files: [String: String] = [:]
        for (kind, path, needle) in sites {
            if files[path] == nil { files[path] = try source(path) }
            XCTAssertTrue(files[path]?.contains(needle) == true, "\(kind.rawValue) site missing in \(path): \(needle)")
            switch kind {
            case .excluding: XCTAssertTrue(needle.contains("CanonicalId.sameKey("), needle)
            case .including: XCTAssertTrue(needle.contains("CanonicalId.same(") || needle.contains("CanonicalId.of("), needle)
            case .key: XCTAssertFalse(needle.contains("CanonicalId.same("), needle)
            }
        }
    }

    /// What still lower-cases in those files: statement ids, key hex and ids
    /// this device makes fresh, each named. Nothing else, and no id goes
    /// through `caseInsensitiveCompare` but key hex.
    func testNothingElseLowerCasesAnId() throws {
        let kept: [String: [String]] = [
            "App/Managers/ApprovalRecord.swift": [
                "PendingInvitee(statementId: statementId.lowercased(), expiresAt: expiresAt)",
                "if row.invitation?.lowercased() == invitee.statementId,",
                "    mutating func withdrawInvitation(statementId: String) {\n        let id = statementId.lowercased()",
                "let pending = Set(pendingStatementIds.map { $0.lowercased() })",
                "let keep = Set(carried.map { $0.lowercased() })",
                "        let id = statementId.lowercased()\n        guard let subject = CanonicalId.of(subject)",
            ],
            "App/Managers/KeyDeliveryApprovals.swift": [
                "let dead = Set(dead.map { $0.lowercased() })",
                "?.statementId == invitee.statementId.lowercased()",
                "let tag = UUID().uuidString.lowercased()",
            ],
            "App/Managers/RefreshLedger.swift": [
                "(statementId: $0.statementId.lowercased(), until:",
                "        let id = statementId.lowercased()\n        if isReadable(account: account)",
                "let dead = Set(dead.map { $0.lowercased() })",
                "!dead.contains(statement.statementId.lowercased()),",
            ],
            "App/Managers/BackfillLedger.swift": [
                "entry.ids.append(statementId.lowercased())",
                "settle(held: signed.statementId.lowercased(),",
            ],
            "App/Domain/PendingChanges/PendingChangeStore.swift": [
                "        let id = statementId.lowercased()\n        return update(changeId) {",
                "DroppedNotice(id: UUID().uuidString.lowercased(),",
            ],
        ]
        for (path, needles) in kept {
            let text = try source(path)
            for needle in needles { XCTAssertTrue(text.contains(needle), "\(path): \(needle)") }
            XCTAssertEqual(text.components(separatedBy: ".lowercased()").count - 1, needles.count,
                           "\(path) lower-cases only statement ids, key hex and fresh ids")
            let compares = text.components(separatedBy: "caseInsensitiveCompare").count - 1
            XCTAssertEqual(compares, path.hasSuffix("ApprovalRecord.swift") ? 2 : 0, "\(path): key hex only")
        }
        XCTAssertTrue(try source("App/Managers/ApprovalRecord.swift")
            .contains("return sharingKeyHex.caseInsensitiveCompare(sharing) == .orderedSame\n"
                      + "            && signingKeyHex.caseInsensitiveCompare(signing) == .orderedSame"))
    }

    /// CircleManager's maps are read and written by the circle's key only.
    func testTheCircleMapsGoByKey() throws {
        let circles = try source("App/Managers/CircleManager.swift")
        for map in ["repairsDue", "tipNamedListed", "transitionRefusedFor", "keyChainsLastImport", "ownLinks", "recordsState"] {
            let uses = circles.components(separatedBy: "\(map)[").count - 1
            XCTAssertGreaterThan(uses, 0, map)
            XCTAssertEqual(circles.components(separatedBy: "\(map)[CanonicalId.key(").count - 1, uses, map)
        }
        XCTAssertTrue(circles.contains("        repairsDue.removeValue(forKey: CanonicalId.key(circleId))\n"
                                       + "        tipNamedListed.removeValue(forKey: CanonicalId.key(circleId))\n"))
    }
}
