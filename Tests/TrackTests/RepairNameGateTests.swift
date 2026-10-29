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

/// A repair is for a version this device holds but rejected, so the key in use
/// is never the version it answers. The circle's name judges a repair by the
/// version it answers (`holdsForTheName`), any other change by the key in use,
/// in the rotation sweep, the owed rotation, the rotation itself and the
/// change's name. The two-device case with the real builder is
/// CircleNameSealingTests'
/// `testARepairOfAVersionHeldButRejectedForR2IsAdmittedAndBuilt`.
final class RepairNameGateTests: XCTestCase {
    private typealias C = Track.CircleManager

    private let problems: [RecordProblem] = [.r2NotAllowed, .r2UnmatchedEntry, .role, .removal, .signature]

    /// The version the repair answers is held, the key in use isn't. Admitted.
    func testARepairWhoseVersionIsHeldButNotTheKeyInUseIsAdmitted() {
        let mode = C.RotationMode.recorded(.repair)
        let holds = C.holdsForTheName(mode: mode, keyInUse: false, repairNeeds: true)
        XCTAssertTrue(holds)
        for problem in problems {
            XCTAssertFalse(C.nameHoldsBack(holds: holds, mode: mode, answering: problem), "\(problem)")
        }
        XCTAssertTrue(C.holdsForTheName(mode: mode, keyInUse: true, repairNeeds: true))
    }

    /// A repair lacking the version it answers waits, whatever it answers but a
    /// misattribution, and whether or not the key in use is held.
    func testARepairLackingItsVersionWaits() {
        let mode = C.RotationMode.recorded(.repair)
        for keyInUse in [false, true] {
            let holds = C.holdsForTheName(mode: mode, keyInUse: keyInUse, repairNeeds: false)
            XCTAssertFalse(holds, "key in use \(keyInUse)")
            for problem in problems {
                XCTAssertTrue(C.nameHoldsBack(holds: holds, mode: mode, answering: problem), "\(problem)")
            }
            XCTAssertFalse(C.nameHoldsBack(holds: holds, mode: mode, answering: .misattributed),
                           "a misattribution's repair still goes from below")
        }
    }

    /// Any other change still needs the key in use, whatever a repair would hold.
    func testAPlainRotationWithoutTheKeyInUseWaits() {
        for mode in [C.RotationMode.recorded(.rotation), .transition, .legacy, .wait] {
            for repairNeeds in [false, true] {
                let without = C.holdsForTheName(mode: mode, keyInUse: false, repairNeeds: repairNeeds)
                XCTAssertFalse(without, "\(mode)")
                XCTAssertTrue(C.nameHoldsBack(holds: without, mode: mode, answering: nil), "\(mode)")
                let with = C.holdsForTheName(mode: mode, keyInUse: true, repairNeeds: repairNeeds)
                XCTAssertTrue(with, "\(mode)")
                XCTAssertFalse(C.nameHoldsBack(holds: with, mode: mode, answering: nil), "\(mode)")
            }
        }
    }

    /// A repair never seals the name (`sealableName` is nil for it: it seals
    /// under an older version than it replaces): it keeps the stored one,
    /// readable here or not, once it holds what it answers; never `.name`.
    func testARepairsNameIsKeptStoredReadableOrNot() {
        // Even a name that opened under the key in use (v1): a repair seals
        // under v1 and replaces v2, so there is nothing to seal again.
        XCTAssertNil(C.sealableName(readable: "Family", openedUnder: 1, isCurrent: { $0 == 1 },
                                    sealingVersion: 1, replacedVersion: 2),
                     "a repair seals under v1 and replaces v2: nothing to seal again")
        XCTAssertEqual(C.sealableName(readable: "Family", openedUnder: 1, isCurrent: { $0 == 1 },
                                      sealingVersion: 1, replacedVersion: 1), "Family",
                       "control: a rotation from the key in use seals it again")
        let holds = C.holdsForTheName(mode: .recorded(.repair), keyInUse: false, repairNeeds: true)
        for readable in ["Family", nil] as [String?] {
            XCTAssertEqual(C.nameToSeal(readable: readable, sealable: nil, ejectingFromBelow: false, holds: holds),
                           .keepStored, "readable: \(readable != nil)")
        }
        let lacking = C.holdsForTheName(mode: .recorded(.repair), keyInUse: false, repairNeeds: false)
        XCTAssertNil(C.nameToSeal(readable: nil, sealable: nil, ejectingFromBelow: false, holds: lacking),
                     "lacking the version it answers, an unreadable name waits")
        XCTAssertEqual(C.nameToSeal(readable: "Family", sealable: nil, ejectingFromBelow: false, holds: lacking),
                       .keepStored)
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func body(of start: String, until end: String, in text: String) throws -> Substring {
        let from = try XCTUnwrap(text.range(of: start), start)
        let to = try XCTUnwrap(text[from.upperBound...].range(of: end), end)
        return text[from.upperBound..<to.lowerBound]
    }

    /// The circle's name reads `holdsForTheName` in the one instance gate the
    /// sweep, the owed rotation and the rotation itself go through, and in the
    /// change's name; the key in use alone appears in neither.
    func testTheNameGateAndTheChangesNameReadTheRepairsHolding() throws {
        let circles = try source("App/Managers/CircleManager.swift")
        let gate = try body(of: "    private func nameHoldsBack(_ circle: Circle, due: RecordVersionStatus?) -> Bool {",
                            until: "\n    }\n", in: circles)
        XCTAssertTrue(gate.contains("        let mode = rotationMode(for: circle, due: due)\n"
                                    + "        return Self.nameHoldsBack(holds: holdsForTheName(circle, mode: mode, due: due), mode: mode,\n"
                                    + "                                  answering: due?.problem)"))
        XCTAssertFalse(gate.contains("holdsKeyInUse("))
        let helper = try body(of: "    private func holdsForTheName(_ circle: Circle, mode: RotationMode, due: RecordVersionStatus?) -> Bool {",
                              until: "\n    }\n", in: circles)
        XCTAssertTrue(helper.contains("mode: mode, keyInUse: holdsKeyInUse(circle.id),"))
        XCTAssertTrue(helper.contains("held: cryptoManager.newestHeldVersion(circleId: circle.id).map { Int($0) },\n"
                                      + "                circleKeyVersion: circle.keyVersion, answering: due?.problem))"))
        let prepare = try body(of: "    private func prepareRecordedChange(", until: "    private func recordedChangeTaken(", in: circles)
        XCTAssertTrue(prepare.contains(
            "ejectingFromBelow: ejecting != nil && ejectsFromBelow(circle), holds: holdsForTheName(circle, mode: mode, due: due),"))
        // The three that rotate go through the instance gate.
        XCTAssertTrue(circles.contains("&& !nameHoldsBack($0, due: repairsDue[CanonicalId.key($0.id)]) && holdsWhatItRotates($0)"),
                      "the sweep")
        XCTAssertTrue(circles.contains("recordedRotationDue(circle), !nameHoldsBack(circle, due: repairsDue[CanonicalId.key(circleId)]),"),
                      "the owed rotation")
        XCTAssertTrue(circles.contains("        if nameHoldsBack(circle, due: due) {\n"), "the rotation")
        XCTAssertTrue(circles.contains("              !nameHoldsBack(circle, due: due), holdsWhatItRotates(circle), !changesAwaitingImport.waits(circle.id),\n"),
                      "the owner's hand-over")
        XCTAssertEqual(circles.components(separatedBy: "nameHoldsBack(").count - 1, 7,
                       "the pure one, the instance one, its call of the pure one, and its four callers")
    }
}
