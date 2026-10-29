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

/// Jailbreak detection.
///
/// WHY THE DECISION IS TESTED THROUGH `decide`
///
/// On the simulator `DeviceIntegrity.isJailbroken` is a compile-time `false` (its
/// `#if targetEnvironment(simulator)` branch is `return false`), and
/// `trustworthyEnvironment` is `!isJailbroken` by definition, so tests against either
/// could never fail: they would pass against a detector with its signal list deleted,
/// which is the only failure this file exists to catch. Ask what a test prints when the
/// thing it guards is broken; if the answer is the same, it is not a test.
///
/// `DeviceIntegrity.decide` takes the three probes as parameters, so the decision can be
/// exercised without a jailbroken device — the same technique `EventTypeHasher` uses to
/// test which event types are consulted without the native crypto library.
final class DeviceIntegritySmokeTests: XCTestCase {

    /// No signal present → not jailbroken. The baseline, and the control for every
    /// positive case below: without it, a `decide` that returned `true`
    /// unconditionally would pass all of them.
    func testAStockDeviceIsNotFlagged() {
        XCTAssertFalse(
            DeviceIntegrity.decide(
                fileExists: { _ in false },
                canOpenScheme: { _ in false },
                canWriteOutsideSandbox: { false }
            )
        )
    }

    /// Each signal is sufficient ON ITS OWN. Tested separately because a `&&` where
    /// an `||` belongs still passes a test that asserts only the all-signals case —
    /// and would mean a device showing one clear sign of jailbreak is reported
    /// clean.
    func testAnySingleSignalIsEnough() {
        XCTAssertTrue(
            DeviceIntegrity.decide(
                fileExists: { $0 == "/Applications/Cydia.app" },
                canOpenScheme: { _ in false },
                canWriteOutsideSandbox: { false }
            ),
            "a jailbreak artefact on disk did not flag the device"
        )
        XCTAssertTrue(
            DeviceIntegrity.decide(
                fileExists: { _ in false },
                canOpenScheme: { $0.scheme == "sileo" },
                canWriteOutsideSandbox: { false }
            ),
            "an answerable package-manager URL scheme did not flag the device"
        )
        XCTAssertTrue(
            DeviceIntegrity.decide(
                fileExists: { _ in false },
                canOpenScheme: { _ in false },
                canWriteOutsideSandbox: { true }
            ),
            "a writable path outside the sandbox did not flag the device"
        )
    }

    /// Every path in the list is consulted, not just the first. A `first` where
    /// `contains` belongs, or a truncated list, both read as a clean device.
    func testEveryListedPathIsConsulted() {
        for path in DeviceIntegrity.jailbreakPaths {
            XCTAssertTrue(
                DeviceIntegrity.decide(
                    fileExists: { $0 == path },
                    canOpenScheme: { _ in false },
                    canWriteOutsideSandbox: { false }
                ),
                "\(path) is in jailbreakPaths but does not flag the device"
            )
        }
    }

    /// Same for the schemes — and it proves they parse. A scheme string that
    /// `URL(string:)` rejects is silently dropped by `compactMap`, so a typo here
    /// removes a signal with no error anywhere.
    func testEveryListedSchemeIsConsultedAndParses() {
        for scheme in DeviceIntegrity.jailbreakSchemes {
            XCTAssertNotNil(URL(string: scheme), "\(scheme) is not a parseable URL and is silently ignored")
            XCTAssertTrue(
                DeviceIntegrity.decide(
                    fileExists: { _ in false },
                    canOpenScheme: { $0.absoluteString == scheme },
                    canWriteOutsideSandbox: { false }
                ),
                "\(scheme) is in jailbreakSchemes but does not flag the device"
            )
        }
    }

    /// A path NOT on the list must not flag. Guards against a `contains` that
    /// matches loosely — a prefix or substring test would flag an app whose bundle
    /// path merely resembles one of these.
    func testAnUnrelatedPathDoesNotFlag() {
        XCTAssertFalse(
            DeviceIntegrity.decide(
                fileExists: { $0 == "/Applications/Track.app" },
                canOpenScheme: { _ in false },
                canWriteOutsideSandbox: { false }
            )
        )
    }

    /// The lists are non-empty. `contains(where:)` over an empty collection is
    /// `false`, so emptying either one disables that signal silently — and every
    /// other test here would still pass, because they each supply their own match.
    func testTheSignalListsAreNotEmpty() {
        XCTAssertFalse(DeviceIntegrity.jailbreakPaths.isEmpty)
        XCTAssertFalse(DeviceIntegrity.jailbreakSchemes.isEmpty)
    }
}
