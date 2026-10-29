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
import UIKit

/// Best-effort jailbreak detection. Complements
/// DCAppAttestService.isSupported (which goes false on jailbroken
/// devices) with classic filesystem + URL-scheme signals so we can
/// surface a warning even on attestation-supported environments where
/// the JB tools are subtle.
///
/// All checks are cheap and cached after the first call.
///
/// Mirrors the Android app's RootDetector intent. Anything detected is
/// non-blocking — the app still runs — but high-trust flows (sensitive
/// account changes, payment) can use this to require additional
/// verification.
enum DeviceIntegrity {
    /// True if any of the classic jailbreak signals are present. False
    /// negatives are expected against well-hidden tooling; we don't
    /// chase a complete arms race here.
    static let isJailbroken: Bool = {
        // Simulator never reports jailbroken; many checks hit false
        // positives there because the FS is wide open by design.
        #if targetEnvironment(simulator)
        return false
        #else
        return decide(
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            canOpenScheme: { url in UIApplication.shared.canOpenURL(url) },
            canWriteOutsideSandbox: canWriteOutsideSandbox
        )
        #endif
    }()

    /// The DECISION, with the three probes injected.
    ///
    /// Split out so a test can exercise it: on the simulator `isJailbroken` takes
    /// the `#if targetEnvironment(simulator)` branch above and returns false, so a
    /// test of it could not tell a working detector from a deleted one.
    ///
    /// The probes are function parameters for the same reason
    /// `EventTypeHasher` takes a closure rather than the CryptoManager: the logic
    /// worth testing is WHICH signals are consulted and how they combine, not
    /// whether `FileManager` can stat a path.
    ///
    /// Order is deliberate — cheapest first, and the sandbox write last, since it
    /// touches the filesystem.
    static func decide(
        fileExists: (String) -> Bool,
        canOpenScheme: (URL) -> Bool,
        canWriteOutsideSandbox: () -> Bool
    ) -> Bool {
        if jailbreakPaths.contains(where: fileExists) { return true }
        if jailbreakSchemes.compactMap(URL.init(string:)).contains(where: canOpenScheme) { return true }
        if canWriteOutsideSandbox() { return true }
        return false
    }

    /// Filesystem artefacts that only exist on a jailbroken device. Exposed so a
    /// test can assert against the real list rather than a copy that drifts.
    static let jailbreakPaths = [
        "/Applications/Cydia.app",
        "/Applications/Sileo.app",
        "/Applications/Zebra.app",
        "/Library/MobileSubstrate/MobileSubstrate.dylib",
        "/Library/MobileSubstrate/DynamicLibraries/Veency.plist",
        "/private/var/lib/apt/",
        "/private/var/lib/cydia",
        "/private/var/stash",
        "/private/var/tmp/cydia.log",
        "/usr/sbin/sshd",
        "/etc/ssh/sshd_config",
        "/bin/bash",
        "/bin/sh",
        "/usr/bin/ssh",
        "/var/jb/",
    ]

    /// URL schemes only a jailbreak package manager answers. `canOpenURL` returns
    /// false for these on a stock device.
    static let jailbreakSchemes = ["cydia://package/com.example.package", "sileo://", "zbra://"]

    /// Combine with App Attest to get a clearer "trustworthy
    /// environment" verdict than either signal alone. Apps can route
    /// destructive flows through here.
    static var trustworthyEnvironment: Bool {
        !isJailbroken
    }

    // MARK: - Private signals

    private static func canWriteOutsideSandbox() -> Bool {
        // App sandbox forbids writes to /. If this succeeds the
        // sandbox is broken, which is a strong jailbreak signal.
        let probe = "/private/jailbreak_probe_\(UUID().uuidString)"
        do {
            try "x".write(toFile: probe, atomically: true, encoding: .utf8)
            try? FileManager.default.removeItem(atPath: probe)
            return true
        } catch {
            return false
        }
    }
}
