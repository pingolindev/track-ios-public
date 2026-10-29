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
import PingolinTrackSDK

/// Holds the single SDK-backed `CryptoManager` instance the app uses for all
/// crypto. Wires the iOS Keychain into the SDK as a `KeyStorageCallback` so
/// the user's private key and circle keys persist across launches.
///
/// This singleton bridges the iOS app to the Rust crypto core (X25519 +
/// XChaCha20-Poly1305) that the Android app uses too, so anything iOS
/// encrypts can be decrypted by Android and the other way round.
enum SDKCrypto {
    /// Set when `loadPersistedKeys` fails on cold start. What the load found
    /// is the SDK's `keyStoreStatus()`, which `KeyStoreRecovery` acts on;
    /// this is kept for logs only.
    private(set) static var keyLoadError: Error?

    /// Posted on the main queue after each load retried once protected data
    /// came back: what it found may call for the sync error (`KeyStoreRecovery`).
    static let keysLoadedAgain = Notification.Name("SDKCrypto.keysLoadedAgain")

    static let cryptoManager: PingolinTrackSDK.CryptoManager = {
        let manager = PingolinTrackSDK.CryptoManager()
        let storage = KeychainKeyStorageCallback()
        manager.registerSecureStorage(storage: storage)
        prepare(manager)
        return manager
    }()

    /// The SDK's load; tests count the app's calls (the SDK refuses a load
    /// while a wipe is owed anyway, which would hide an app that asks).
    typealias Load = (PingolinTrackSDK.CryptoManager) throws -> Bool

    /// A wipe a sign-out couldn't finish is paid before anything is loaded
    /// (`OwedWipe`). While it stays owed nothing is loaded (the SDK refuses to
    /// anyway), and the next clear pays it: the next sign-in's. Otherwise the
    /// stored keys load.
    static func prepare(_ manager: PingolinTrackSDK.CryptoManager, _ defaults: UserDefaults = OwedWipe.defaults,
                        load: Load = { try $0.loadPersistedKeys() }) {
        if OwedWipe.isOwed(defaults), !OwedWipe.clear(manager, defaults) { return }
        do {
            _ = try load(manager)
        } catch {
            keyLoadError = error
            let load = manager.keyStoreStatus().load
            print("[Track] Failed to load persisted SDK keys: \(load)")
            if load == .readFailed { retryLoadWhenProtectedDataAvailable(manager) }
        }
    }

    /// Observer for the retry below; removed once a load succeeds.
    private static var protectedDataObserver: NSObjectProtocol?

    /// The load fails when the process started before the first unlock after
    /// a reboot (the Keychain items are `…AfterFirstUnlock…`), which is
    /// exactly how a location event relaunches this app. The SDK then refuses
    /// every write, so nothing on disk is lost — but nothing is loaded either.
    /// Load again as soon as the Keychain is readable. Only a store the
    /// platform couldn't read (`readFailed`): one that doesn't decode doesn't
    /// change by unlocking, and is never cleared here.
    private static func retryLoadWhenProtectedDataAvailable(_ manager: PingolinTrackSDK.CryptoManager) {
        guard protectedDataObserver == nil else { return }
        protectedDataObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil,
            queue: .main
        ) { _ in
            loadAgain(manager)
            if manager.keyStoreStatus().load != .readFailed, let observer = protectedDataObserver {
                NotificationCenter.default.removeObserver(observer)
                protectedDataObserver = nil
            }
            NotificationCenter.default.post(name: keysLoadedAgain, object: nil)
        }
    }

    /// The load the unlock retries. An owed wipe is paid before it too, as at
    /// launch: before the first unlock the app group's defaults may not have
    /// read. Still owed, nothing is loaded.
    static func loadAgain(_ manager: PingolinTrackSDK.CryptoManager, _ defaults: UserDefaults = OwedWipe.defaults,
                          load: Load = { try $0.loadPersistedKeys() }) {
        guard !OwedWipe.isOwed(defaults) || OwedWipe.clear(manager, defaults) else { return }
        do {
            _ = try load(manager)
            keyLoadError = nil
        } catch {
            keyLoadError = error
            print("[Track] Retried SDK key load failed: \(manager.keyStoreStatus().load)")
        }
    }
}

/// A wipe of the SDK's key store that the platform refused (the SDK's
/// `deleteFailed`): a sign-out cleared the keys in memory, but the account's
/// entries may still be in the Keychain. It is owed until a `clearAllKeys()`
/// leaves the store `.loaded` (known, and empty). Until then the SDK loads
/// and writes nothing, so no later account's store exists for the owed wipe
/// to delete. Kept in the app group's defaults, not the Keychain whose
/// delete just failed, so the notification extension loads nothing while it
/// is owed either; it names nothing but the debt.
enum OwedWipe {
    static var defaults: UserDefaults { UserDefaults(suiteName: ExtensionBridgeKeys.suite) ?? .standard }

    static func isOwed(_ defaults: UserDefaults = OwedWipe.defaults) -> Bool {
        defaults.bool(forKey: ExtensionBridgeKeys.keyStoreWipeOwed)
    }

    /// `clearAllKeys()`, and whether the store is empty after it. EVERY clear
    /// goes through here, so a refused delete is always recorded, and a clear
    /// that went through pays what was owed.
    @discardableResult
    static func clear(_ manager: PingolinTrackSDK.CryptoManager, _ defaults: UserDefaults = OwedWipe.defaults) -> Bool {
        manager.clearAllKeys()
        return note(manager.keyStoreStatus().load, defaults)
    }

    /// Only a clear's status is noted: a later import's `.loaded` is no proof
    /// a write went through.
    @discardableResult
    static func note(_ load: KeyStoreLoad, _ defaults: UserDefaults = OwedWipe.defaults) -> Bool {
        switch load {
        case .loaded:
            defaults.removeObject(forKey: ExtensionBridgeKeys.keyStoreWipeOwed)
            return true
        case .deleteFailed:
            defaults.set(true, forKey: ExtensionBridgeKeys.keyStoreWipeOwed)
            return false
        case .notLoaded, .nothingStored, .readFailed, .doesNotDecode:
            return false
        }
    }
}
