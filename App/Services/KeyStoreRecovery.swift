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
import PingolinTrackSDK

/// What this app does with the state of the SDK's key store. Track shares
/// locations, so nobody is signed out while the app still works:
/// - the store doesn't decode (`doesNotDecode`): this device holds no keys and
///   nothing works. The session ends (`AuthManager.expireSession`) and the
///   sign-in screen says "Sync error. Please sign in again." The sign-in then
///   clears the store, and its import writes it whole.
/// - a signing seed or entries that didn't read (`signingSeedUnreadable`,
///   `entriesUnreadable`): it still works, partly. The same line, as a banner
///   on the Map and a row in Settings with Sign Out. The sign-in drops the
///   entries, and its import replaces the seed.
/// - the platform couldn't read it (`readFailed`, before the first unlock):
///   nothing is shown. It is loaded again once the device is unlocked
///   (`SDKCrypto`), and never cleared.
/// - a wipe a sign-out couldn't finish (`OwedWipe`) is paid before anything is
///   loaded: at launch (`SDKCrypto.prepare`), and first at the sign-in. While it
///   stays owed, the sign-in's keys stay in memory.
/// While the load has failed, the SDK takes nobody on first contact and every
/// circle waits: the app's existing waiting states, and no pins export.
@MainActor
final class KeyStoreRecovery: ObservableObject {
    static let shared = KeyStoreRecovery()

    nonisolated static let syncErrorText = "Sync error. Please sign in again."

    /// The SDK's calls, behind a seam for tests.
    struct Store {
        var status: () -> KeyStoreStatus
        /// `loadPersistedKeys()`; what it found is `status()`.
        var load: () -> Void
        /// Through `OwedWipe`, so a refused delete is always recorded.
        var clear: () -> Void
        var dropUnreadableEntries: () throws -> UInt32
        var wipeOwed: () -> Bool

        static func sdk(_ manager: PingolinTrackSDK.CryptoManager, _ defaults: UserDefaults = OwedWipe.defaults) -> Store {
            Store(
                status: { manager.keyStoreStatus() },
                load: { _ = try? manager.loadPersistedKeys() },
                clear: { _ = OwedWipe.clear(manager, defaults) },
                dropUnreadableEntries: { try manager.dropUnreadableEntries() },
                wipeOwed: { OwedWipe.isOwed(defaults) }
            )
        }
    }

    var store: Store

    /// The sync error's banner is up (a seed or entries that didn't read).
    @Published private(set) var showsSyncBanner = false

    init(store: Store? = nil) {
        self.store = store ?? .sdk(SDKCrypto.cryptoManager)
    }

    /// What a signed-in session does with the store as the launch, or the load
    /// after the unlock, found it.
    enum Verdict: Equatable {
        case carryOn
        /// The store doesn't decode: the session ends, with the sync error.
        case signOut
        /// A seed or entries that didn't read: the sync error's banner.
        case banner
    }

    nonisolated static func verdict(_ status: KeyStoreStatus) -> Verdict {
        switch status.load {
        case .doesNotDecode:
            return .signOut
        case .loaded, .nothingStored:
            return status.signingSeedUnreadable || status.entriesUnreadable ? .banner : .carryOn
        case .notLoaded, .readFailed, .deleteFailed:
            // Not read yet: loaded again after the unlock. A wipe still owed:
            // paid at the next sign-in.
            return .carryOn
        }
    }

    /// For a signed-in session (`AuthManager`): the verdict now, with the
    /// banner raised or lowered to match.
    func check() -> Verdict {
        let verdict = Self.verdict(store.status())
        showsSyncBanner = verdict == .banner
        return verdict
    }

    /// Signed out: no banner.
    func signedOut() {
        showsSyncBanner = false
    }

    /// Whether the pins may be exported at a sign-out: only from a store
    /// that loaded. Otherwise the pins held are not this account's whole set,
    /// and the export would replace the ones kept at the last sign-out.
    nonisolated static func pinsExportable(_ status: KeyStoreStatus) -> Bool {
        status.load == .loaded || status.load == .nothingStored
    }

    /// What the sign-in does before any of its keys goes into the SDK.
    enum BeforeImport: Equatable {
        /// Go on with the import.
        case importKeys
        /// The platform couldn't read the store, which is never cleared: the
        /// sign-in stops ("Couldn't sign in. Please try again.").
        case stop
    }

    /// An explicit sign-in, before any of its keys goes into the SDK
    /// (`AuthManager.completeLogin`). A wipe still owed is paid first; while it
    /// stays owed nothing is loaded or written (the SDK refuses both) and the
    /// sign-in's keys stay in memory. Then the store is read again: one that
    /// still doesn't decode is cleared, so the import writes it whole; entries
    /// that didn't read go, before the sign-in's key sync; a kept seed is
    /// replaced by the import itself. One the platform couldn't read is never
    /// cleared: the sign-in stops.
    func beforeSignInImport() -> BeforeImport {
        if store.wipeOwed() {
            store.clear()
            guard store.status().load == .loaded else { return .importKeys }
        }
        store.load()
        let status = store.status()
        switch status.load {
        case .readFailed:
            return .stop
        case .doesNotDecode:
            store.clear()
        case .notLoaded, .nothingStored, .loaded, .deleteFailed:
            if status.entriesUnreadable {
                do {
                    _ = try store.dropUnreadableEntries()
                } catch {
                    // Kept as they were: the banner stays, and the next
                    // sign-in tries again.
                    print("[Track] key store: the entries that didn't read could not be dropped")
                }
            }
        }
        return .importKeys
    }
}
