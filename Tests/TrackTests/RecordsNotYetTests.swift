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
import PingolinTrackSDK
@testable import Track

/// The SDK's "not yet": a refusal of `prepareRecordedRotation` or
/// `signCircleHead` whose text says "import this circle's records first", in
/// whatever case it comes. It is no failure and nothing backs off: the
/// circle's change is tried again after the next import of its records, the
/// only thing that can change the answer. Every other refusal keeps its
/// failure and back-off.
@MainActor
final class RecordsNotYetTests: XCTestCase {
    private typealias C = Track.CircleManager

    /// The six refusal texts in the SDK's `refresh.rs`: four "not yet", two
    /// failures.
    func testOnlyTheLockedTextIsNotYetInWhateverCaseItComes() {
        let notYet: [MobileError] = [
            .InvalidInput(message: "import this circle's records first, then rotate"),
            .KeyNotFound(message: "import this circle's records first"),
            .InvalidInput(message: "the head's record isn't known here in full yet: import this circle's records first"),
        ]
        for error in notYet {
            XCTAssertTrue(RecordedRotation.notYet(error), "\(error)")
            XCTAssertTrue(AccountHeads.headNotYet(error), "the head publisher's is the same: \(error)")
        }
        let failures: [Error] = [
            MobileError.InvalidInput(message: "this circle has records: import them, then rotate"),
            MobileError.KeyNotFound(message: "no record of this circle is accepted here"),
            MobileError.InvalidInput(message: "this circle's chain forked: it waits"),
            MobileError.InvalidInput(message: "v3 of this circle waits here: no record is built until it's decided"),
            MobileError.InvalidInput(message: "no record of this circle is accepted here yet"),
            C.CircleError.waitingToSync,
            NSError(domain: "not the SDK", code: 1, userInfo: [NSLocalizedDescriptionKey: RecordedRotation.notYetText]),
        ]
        for error in failures {
            XCTAssertFalse(RecordedRotation.notYet(error), "\(error)")
        }
        XCTAssertFalse(AccountHeads.headNotYet(.KeyNotFound(message: "no record of this circle is accepted here")))
    }

    /// The real builder's "not yet", on a device that hasn't imported the
    /// circle's records in this process: caught, in its own words.
    func testTheRealBuildersNotYetIsCaught() throws {
        let sdk = CryptoManager()
        func hex(_ b64: String) -> String { Data(base64Encoded: b64)!.map { String(format: "%02x", $0) }.joined() }
        let keys = MemberKeyPair(sharingKeyHex: hex(sdk.generateKeypair().publicKey),
                                 signingKeyHex: hex(sdk.generateSigningKeypair().verifyingKeyB64))
        let (me, circle) = (UUID().uuidString.lowercased(), UUID().uuidString.lowercased())
        let mine = RecordMemberRow(userId: me, keys: keys, confirmed: true, listed: true, listedRole: .owner,
                                   statements: [], personConfirmedKeys: false, serverSaysKeyless: false)
        for kind in [RefreshRecordKind.rotation, .repair] {
            XCTAssertThrowsError(try sdk.prepareRecordedRotation(
                circleId: circle, senderUserId: me, kind: kind, planned: [PlannedEntry(userId: me, state: .included, role: nil)],
                members: [mine.sdkMember], rosterComplete: true, currentCircleNamePlaintext: "Family")) { error in
                guard case MobileError.InvalidInput(let message) = error else { return XCTFail("\(error)") }
                XCTAssertTrue(message.contains("import this circle's records first, then rotate"), message)
                XCTAssertTrue(RecordedRotation.notYet(error), "\(kind)")
            }
        }
    }

    /// One wait per circle, in its one form, until an import of its records
    /// (or the circle is gone here, or the account signs out).
    func testAWaitIsPerCircleInItsOneFormAndEndsAtAnImport() {
        var waits = C.ImportWaits()
        let circle = UUID().uuidString.lowercased()
        waits.wait(circle.uppercased())
        XCTAssertTrue(waits.waits(circle))
        XCTAssertTrue(waits.waits(circle.uppercased()))
        XCTAssertFalse(waits.waits(UUID().uuidString.lowercased()))
        waits.end(circle.uppercased())
        XCTAssertFalse(waits.waits(circle))
        waits.wait(circle)
        waits.removeAll()
        XCTAssertFalse(waits.waits(circle))
        XCTAssertEqual(waits, C.ImportWaits())
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func body(of start: String, until end: String, in text: String) throws -> String {
        let from = try XCTUnwrap(text.range(of: start), start)
        let to = try XCTUnwrap(text.range(of: end, range: from.upperBound..<text.endIndex), end)
        return String(text[from.lowerBound..<to.lowerBound])
    }

    /// Only a "not yet" enters the waits, with no failure recorded; the sweep
    /// and the owed rotation skip a waiting circle; an import of its records,
    /// its leave or removal here, and a sign-out end the wait. The claim's
    /// second build and the eject's log leave "not yet" alone.
    func testNotYetIsWiredIn() throws {
        let circles = try source("App/Managers/CircleManager.swift")
        let rotate = try body(of: "    func rotateCircleKey(for circleId: String) async throws {", until: "    // MARK: - Errors",
                              in: circles)
        XCTAssertTrue(rotate.contains(
            "            } catch let refusal where RecordedRotation.notYet(refusal) {\n"
            + "                // \"Import this circle's records first\": no failure and no\n"
            + "                // back-off; it is tried again after the next import of its\n"
            + "                // records.\n"
            + "                changesAwaitingImport.wait(circleId)\n"))
        let notYet = try XCTUnwrap(rotate.range(of: "} catch let refusal where RecordedRotation.notYet(refusal) {"))
        let transition = try XCTUnwrap(rotate.range(of: "} catch let refusal as MobileError where mode == .transition {"))
        XCTAssertLessThan(notYet.upperBound, transition.lowerBound)
        XCTAssertTrue(rotate[notYet.upperBound..<transition.lowerBound].contains("                return\n"), "no throw: no failure, no back-off")
        XCTAssertEqual(circles.components(separatedBy: "changesAwaitingImport.wait(").count - 1, 1, "only a not yet waits")

        let load = try body(of: "    func loadCircles(light: Bool = false) async throws {", until: "    func setActiveCircle(", in: circles)
        XCTAssertTrue(load.contains("&& !inRotationBackoff($0.id) && rotationMode(for: $0) != .wait\n"
                                    + "                && !changesAwaitingImport.waits($0.id)\n"))
        XCTAssertTrue(load.contains("print(\"[Track] auto-rotation failed for circle \\(circle.id): \\(error)\")\n"
                                    + "                        await self.recordRotationFailure(circle.id, error)"),
                      "every other refusal: a failure, backed off")
        let owed = try body(of: "    private func rotateOwedNow(_ circleId: String) {", until: "\n    }\n", in: circles)
        XCTAssertTrue(owed.contains("!inRotationBackoff(circleId), !changesAwaitingImport.waits(circleId)"))
        let imported = try body(of: "    private func importRefreshRecords() async {",
                                until: "    private func askForFreshCopy(_ circleId: String) async {", in: circles)
        XCTAssertTrue(imported.contains("            case .imported(let report, let heads):\n"
                                        + "                recordsState[CanonicalId.key(circleId)] = .imported(forked: report.forked)\n"
                                        + "                // A change the SDK answered \"not yet\" is tried again after this.\n"
                                        + "                changesAwaitingImport.end(circleId)\n"))
        XCTAssertEqual(imported.components(separatedBy: "changesAwaitingImport.end(").count - 1, 1, "only an import that ran")
        let prune = try body(of: "    private func pruneLocalCircle(circleId: String) {", until: "\n    }\n", in: circles)
        XCTAssertTrue(prune.contains("changesAwaitingImport.end(circleId)"), "removed here")
        let forget = try body(of: "    private func forgetCircleKeys(_ circleId: String) {", until: "\n    }\n", in: circles)
        XCTAssertTrue(forget.contains("changesAwaitingImport.end(circleId)"), "left or deleted")
        let reset = try body(of: "    func reset() {\n        circles = []", until: "\n    }\n", in: circles)
        XCTAssertTrue(reset.contains("changesAwaitingImport.removeAll()"), "signed out")

        let prepare = try body(of: "    private func prepareRecordedChange(", until: "    private func recordedChangeTaken(", in: circles)
        XCTAssertTrue(prepare.contains("where withoutClaim != nil\n                    && !message.contains(RecordedRotation.notYetText) {"),
                      "no second build for a not yet")
        let eject = try body(of: "    func removeMember(from circleId: String, userId: String) async throws {",
                             until: "    func removesWithoutNewKey(_ circleId: String) -> Bool {", in: circles)
        XCTAssertTrue(eject.contains("                    if RecordedRotation.notYet(refusal) {\n"
                                     + "                        Self.keyLog.info("))
        XCTAssertTrue(eject.contains("                    throw CircleError.ejectFailed(CircleError.notDoneWhileWaitingToSync)\n"),
                      "the person's answer stays: waiting to sync")

        let heads = try source("App/Managers/AccountHeads.swift")
        XCTAssertTrue(heads.contains("    nonisolated static func headNotYet(_ error: MobileError) -> Bool {\n"
                                     + "        RecordedRotation.notYet(error)\n    }"))
    }
}
