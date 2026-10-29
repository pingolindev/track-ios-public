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

/// What a waiting change stores, where, and how it is queued.
@MainActor
final class PendingChangeStoreTests: XCTestCase {
    private var directory: URL!
    private let me = "0f0f0f0f-1111-2222-3333-444455556666"
    private let circle = "c1c1c1c1-0000-0000-0000-000000000001"

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func checkIn(_ message: String = "hi", account: String? = nil, circleId: String? = nil,
                         now: Date = Date()) -> PendingChange {
        PendingChanges.make(.checkIn, account: account ?? me, circleId: circleId ?? circle,
                            inputs: .checkIn(.init(type: "general", message: message, latitude: 1, longitude: 2,
                                                   placeId: nil, checkedInAt: now)),
                            seen: .init(privacy: .precise), now: now)
    }

    func testAChangeKeepsItsInputsAcrossARelaunch() throws {
        let store = PendingChangeStore(directory: directory)
        guard case .queued(let queued) = store.queue(checkIn()) else { return XCTFail("not queued") }
        let relaunched = PendingChangeStore(directory: directory)
        relaunched.use(account: me)
        XCTAssertEqual(relaunched.changes, [queued])
        XCTAssertEqual(relaunched.change(id: queued.id)?.inputs, queued.inputs)
    }

    /// A file that is there but can't be read (protected until the first
    /// unlock after a restart, when the runner may wake in the background; or
    /// damaged) is never written over or deleted, and it's read again at the
    /// next use: its changes are found once it reads, and a tap meanwhile
    /// never saves over them.
    func testAFileThatCantBeReadIsNeverWrittenOver() throws {
        let store = PendingChangeStore(directory: directory)
        guard case .queued(let waiting) = store.queue(checkIn("kept")) else { return XCTFail("not queued") }
        let file = try XCTUnwrap(store.fileURL(account: me))
        let intact = try Data(contentsOf: file)
        try Data("{not json".utf8).write(to: file)
        let relaunched = PendingChangeStore(directory: directory)
        relaunched.use(account: me)
        XCTAssertTrue(relaunched.unreadable)
        XCTAssertTrue(relaunched.changes.isEmpty)
        guard case .queued(let meanwhile) = relaunched.queue(checkIn("meanwhile")) else { return XCTFail("not queued") }
        relaunched.use(account: me)
        XCTAssertEqual(relaunched.changes, [meanwhile], "still unreadable: this session's own stay")
        relaunched.remove(meanwhile.id)  // empties the store again; the unreadable file must survive
        XCTAssertEqual(try Data(contentsOf: file), Data("{not json".utf8), "never written over or deleted")
        // Readable again: read at the next use, with the change it holds.
        try intact.write(to: file)
        relaunched.use(account: me)
        XCTAssertFalse(relaunched.unreadable)
        XCTAssertEqual(relaunched.changes, [waiting])
    }

    /// Another account never sees, or runs, this account's changes.
    func testAnotherAccountNeverSeesThem() {
        let store = PendingChangeStore(directory: directory)
        _ = store.queue(checkIn())
        let other = PendingChangeStore(directory: directory)
        other.use(account: "99999999-aaaa-bbbb-cccc-dddddddddddd")
        XCTAssertTrue(other.changes.isEmpty)
        other.use(account: me)
        XCTAssertEqual(other.changes.count, 1)
    }

    /// One file per account: another account's changes never overwrite these.
    func testEachAccountKeepsItsOwnFile() {
        let other = "99999999-aaaa-bbbb-cccc-dddddddddddd"
        let store = PendingChangeStore(directory: directory)
        guard case .queued(let mine) = store.queue(checkIn()),
              case .queued(let theirs) = store.queue(checkIn(account: other)) else { return XCTFail("not queued") }
        XCTAssertNotEqual(store.fileURL(account: me), store.fileURL(account: other))
        let relaunched = PendingChangeStore(directory: directory)
        relaunched.use(account: me)
        XCTAssertEqual(relaunched.changes, [mine])
        relaunched.use(account: other)
        XCTAssertEqual(relaunched.changes, [theirs])
    }

    /// One change per target; the newest inputs win, an edit's fields
    /// merge; a merge never touches the ids a change already signed.
    func testMergedPerTarget() {
        let store = PendingChangeStore(directory: directory)
        let first = PendingChanges.make(.renameCircle, account: me, circleId: circle,
                                        inputs: .renameCircle(newName: "A"), seen: .init(name: "Old"))
        guard case .queued(let queued) = store.queue(first) else { return XCTFail("not queued") }
        store.update(queued.id) { $0.signedIds = ["kept"] }
        let second = PendingChanges.make(.renameCircle, account: me, circleId: circle,
                                         inputs: .renameCircle(newName: "B"), seen: .init(name: "A"))
        guard case .merged(let merged) = store.queue(second) else { return XCTFail("not merged") }
        XCTAssertEqual(store.changes.count, 1)
        XCTAssertEqual(merged.inputs, .renameCircle(newName: "B"))
        XCTAssertEqual(merged.seen.name, "Old", "compared against the name as first shown")
        XCTAssertEqual(merged.signedIds, ["kept"])

        let edit1 = PendingChanges.make(.alertChange, account: me, circleId: circle,
                                        inputs: .alertChange(.init(ruleId: "r", threshold: 20)))
        let edit2 = PendingChanges.make(.alertChange, account: me, circleId: circle,
                                        inputs: .alertChange(.init(ruleId: "r", notifyPush: false)))
        _ = store.queue(edit1)
        guard case .merged(let fields) = store.queue(edit2) else { return XCTFail("not merged") }
        XCTAssertEqual(fields.inputs, .alertChange(.init(ruleId: "r", threshold: 20, notifyPush: false)))
    }

    /// While a change has never gone out, a merge restarts its age limit from
    /// the new tap, the later of the two, also while it waits for the person.
    /// Its id and its place in the queue stay.
    func testAMergeRestartsTheAgeLimit() {
        let day: TimeInterval = 24 * 3600
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let store = PendingChangeStore(directory: directory)
        func rename(_ name: String, at now: Date, expiresAt: Date? = nil) -> PendingChange {
            PendingChanges.make(.renameCircle, account: me, circleId: circle, inputs: .renameCircle(newName: name),
                                seen: .init(name: "Old"), expiresAt: expiresAt, now: now)
        }
        guard case .queued(let first) = store.queue(rename("A", at: start), now: start) else {
            return XCTFail("not queued")
        }
        XCTAssertEqual(first.expiresAt, start.addingTimeInterval(7 * day))

        let day6 = start.addingTimeInterval(6 * day)
        guard case .merged(let merged) = store.queue(rename("B", at: day6), now: day6) else {
            return XCTFail("not merged")
        }
        XCTAssertEqual(merged.expiresAt, day6.addingTimeInterval(7 * day))
        XCTAssertEqual(merged.id, first.id)
        XCTAssertEqual(merged.createdAt, start)

        // A tap that allows less never shortens it.
        guard case .merged(let capped) = store.queue(rename("C", at: day6, expiresAt: day6.addingTimeInterval(day)),
                                                     now: day6) else { return XCTFail("not merged") }
        XCTAssertEqual(capped.expiresAt, day6.addingTimeInterval(7 * day))

        // Waiting for the person: restarted too.
        store.update(first.id) { $0.state = .needsPerson(.password) }
        let day10 = start.addingTimeInterval(10 * day)
        guard case .merged(let asked) = store.queue(rename("D", at: day10), now: day10) else {
            return XCTFail("not merged")
        }
        XCTAssertEqual(asked.expiresAt, day10.addingTimeInterval(7 * day))
    }

    /// Once a run may have reached the server (a send with no answer, found
    /// running after a restart, or a saved statement id), a merge keeps the
    /// change's own limit, so the server's 8-day request-id record covers
    /// every resend. The signed ids stay.
    func testAMergeKeepsTheLimitOfAChangeThatMayHaveGoneOut() {
        let day: TimeInterval = 24 * 3600
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let day6 = start.addingTimeInterval(6 * day)
        func rename(_ name: String, at now: Date) -> PendingChange {
            PendingChanges.make(.renameCircle, account: me, circleId: circle, inputs: .renameCircle(newName: name),
                                seen: .init(name: "Old"), now: now)
        }
        for mark in ["no answer", "a signed id"] {
            let store = PendingChangeStore(directory: directory.appendingPathComponent(mark))
            guard case .queued(let first) = store.queue(rename("A", at: start), now: start) else {
                return XCTFail("not queued")
            }
            store.update(first.id) {
                if mark == "no answer" { $0.mayHaveGoneOut = true } else { $0.signedIds = ["kept"] }
            }
            guard case .merged(let merged) = store.queue(rename("B", at: day6), now: day6) else {
                return XCTFail("not merged")
            }
            XCTAssertEqual(merged.expiresAt, start.addingTimeInterval(7 * day), mark)
            XCTAssertEqual(merged.inputs, .renameCircle(newName: "B"), mark)
            XCTAssertEqual(merged.signedIds, mark == "no answer" ? [] : ["kept"], mark)
        }
        // Found running after a restart: it may have gone out, so the same.
        let store = PendingChangeStore(directory: directory.appendingPathComponent("restart"))
        guard case .queued(let first) = store.queue(rename("A", at: start), now: start) else {
            return XCTFail("not queued")
        }
        store.update(first.id) { $0.state = .running(attemptId: "a", startedAt: start) }
        let relaunched = PendingChangeStore(directory: directory.appendingPathComponent("restart"))
        guard case .merged(let merged) = relaunched.queue(rename("B", at: day6), now: day6) else {
            return XCTFail("not merged")
        }
        XCTAssertEqual(merged.expiresAt, start.addingTimeInterval(7 * day))
    }

    /// Check-ins are events: never merged, except the same tap twice within 2 s.
    func testEventsAreNeverMergedButTheSameTapIsOne() {
        let store = PendingChangeStore(directory: directory)
        let now = Date()
        _ = store.queue(checkIn("a", now: now), now: now)
        _ = store.queue(checkIn("b", now: now), now: now)
        XCTAssertEqual(store.changes.count, 2)
        if case .merged = store.queue(checkIn("a", now: now.addingTimeInterval(1)), now: now.addingTimeInterval(1)) {
        } else { XCTFail("the same tap again within 2 s is one tap") }
        XCTAssertEqual(store.changes.count, 2)
        _ = store.queue(checkIn("a", now: now.addingTimeInterval(3)), now: now.addingTimeInterval(3))
        XCTAssertEqual(store.changes.count, 3)
    }

    /// 20 per circle, 100 per account; beyond that refused at once.
    func testCaps() {
        XCTAssertEqual(PendingChangeStore.maxPerCircle, 20)
        XCTAssertEqual(PendingChangeStore.maxPerAccount, 100)
        let store = PendingChangeStore(directory: directory)
        let start = Date()
        for i in 0..<PendingChangeStore.maxPerCircle {
            let at = start.addingTimeInterval(Double(i) * 3)
            XCTAssertNotEqual(store.queue(checkIn("m\(i)", now: at), now: at), .tooMany)
        }
        let late = start.addingTimeInterval(1000)
        XCTAssertEqual(store.queue(checkIn("over", now: late), now: late), .tooMany)
        XCTAssertEqual(PendingChanges.TooManyWaiting(circleName: "Family").errorDescription,
                       "Not done: 20 changes are already waiting to go out for Family from this iPhone.")
        for c in 0..<4 {
            for i in 0..<PendingChangeStore.maxPerCircle {
                let at = start.addingTimeInterval(Double(c * 100 + i) * 3 + 2000)
                _ = store.queue(checkIn("x\(c)-\(i)", circleId: "circle-\(c)", now: at), now: at)
            }
        }
        XCTAssertEqual(store.pendingCount, PendingChangeStore.maxPerAccount)
        let later = start.addingTimeInterval(99_999)
        XCTAssertEqual(store.queue(checkIn("over", circleId: "circle-9", now: later), now: later), .tooMany)
    }

    /// A change cut off while sending goes back through the re-check,
    /// marked as possibly gone out.
    func testARunningChangeIsWaitingAfterARelaunch() {
        let store = PendingChangeStore(directory: directory)
        guard case .queued(let queued) = store.queue(checkIn()) else { return XCTFail("not queued") }
        store.update(queued.id) { $0.state = .running(attemptId: "a", startedAt: Date()) }
        let relaunched = PendingChangeStore(directory: directory)
        relaunched.use(account: me)
        XCTAssertEqual(relaunched.change(id: queued.id)?.state, .waiting)
        XCTAssertEqual(relaunched.change(id: queued.id)?.mayHaveGoneOut, true)
    }

    /// Done changes are deleted; a dropped one leaves only its line, cleared
    /// once seen, or after a week.
    func testDoneLeavesNothingAndDroppedLeavesALine() {
        let store = PendingChangeStore(directory: directory)
        guard case .queued(let a) = store.queue(checkIn("a")),
              case .queued(let b) = store.queue(checkIn("b")) else { return XCTFail("not queued") }
        store.remove(a.id)
        store.drop(b.id, line: "Your check-in wasn't done.")
        XCTAssertTrue(store.changes.isEmpty)
        XCTAssertEqual(store.notices(circleId: circle).map(\.line), ["Your check-in wasn't done."])
        store.noticesSeen(circleId: circle)
        XCTAssertTrue(store.notices.isEmpty)

        store.addNotice(account: me, circleId: circle, line: "old", now: Date().addingTimeInterval(-8 * 86_400))
        store.pruneNotices()
        XCTAssertTrue(store.notices.isEmpty)
    }

    /// The person left the circle: its changes go with no line.
    func testLeavingForgetsSilently() {
        let store = PendingChangeStore(directory: directory)
        _ = store.queue(checkIn())
        store.forgetCircle(circle)
        XCTAssertTrue(store.changes.isEmpty)
        XCTAssertTrue(store.notices.isEmpty)
    }

    /// Sign-out and account switch: everything goes, the file too.
    func testWipe() throws {
        let store = PendingChangeStore(directory: directory)
        _ = store.queue(checkIn())
        let file = try XCTUnwrap(store.fileURL(account: me))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        store.wipeAll()
        XCTAssertTrue(store.changes.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    /// The file is in Application Support, excluded from backup, with
    /// the protection class set.
    func testTheFileIsInApplicationSupportProtectedAndNotBackedUp() throws {
        let store = PendingChangeStore()
        let account = UUID().uuidString.lowercased()
        let file = try XCTUnwrap(store.fileURL(account: account))
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: false)
        XCTAssertTrue(file.path.hasPrefix(support.path), file.path)
        XCTAssertFalse(file.path.contains("/Caches/"))
        defer { try? FileManager.default.removeItem(at: file) }
        _ = store.queue(checkIn(account: account))
        let values = try file.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "App/Domain/PendingChanges/PendingChangeStore.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])"))
    }

    /// The notification extension has no reference to it.
    func testTheNotificationExtensionNeverReadsIt() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dir = root.appendingPathComponent("NotificationExtension")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(text.contains("PendingChange"), file.lastPathComponent)
        }
        let project = try String(contentsOf: root.appendingPathComponent("project.yml"), encoding: .utf8)
        XCTAssertFalse(project.contains("PendingChange"), "no extension target lists its files")
    }

    /// What is never stored.
    func testNothingSealedSignedOrVersionedIsStored() throws {
        let store = PendingChangeStore(directory: directory)
        _ = store.queue(checkIn())
        let data = try Data(contentsOf: try XCTUnwrap(store.fileURL(account: me)))
        let text = try XCTUnwrap(String(data: data, encoding: .utf8)).lowercased()
        for never in ["ciphertext", "nonce", "signature", "statement\"", "version", "wrap", "token"] {
            XCTAssertFalse(text.contains(never), never)
        }
    }
}
