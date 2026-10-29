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

/// Backend device registration bootstrap. Mirrors the Android app's
/// `LocationRepository.ensureDeviceRegistered`.
///
/// Why this exists: the server checks every incoming location against a push
/// registration for this device and user ("Device not found or not owned by
/// user"), and so do needs-attention and check-ins. The deviceId iOS uses for
/// the SDK stream is the one stashed at `keychain.deviceId` (minted at first
/// login).
///
/// `POST /api/v1/devices` writes that registration ONLY when it carries a push
/// token: a device cannot exist on the server without declaring a push route.
/// A token-less POST still answers 201, with `push_registered: false` — the
/// only thing that tells the client it is not addressable yet. So the
/// registration that counts is the token-carrying one from
/// `PushNotificationManager.register(deviceToken:)`; a token-less `ensure()`
/// answers true only once that has happened (the flag below), or when an
/// older server, which says nothing, takes it.
///
/// `ensure()` is idempotent — a UserDefaults flag scoped to (userId, deviceId)
/// lets us short-circuit after the first registration the server took, without
/// re-hitting the API on every cold launch.
@MainActor
enum DeviceRegistrar {

    private static let api = APIService.shared
    private static let crypto = SDKCrypto.cryptoManager
    private static let keychain = KeychainService.shared

    /// The user id lowercased. A flag an earlier version wrote in another case
    /// is missed once: one more idempotent POST /devices.
    private static func flagKey(userId: String, deviceId: String) -> String {
        "device.registered.\(userId.lowercased()).\(deviceId)"
    }

    /// What one registration reads and calls, behind one seam: live, the
    /// session, the Keychain, the SDK and the API; in a test, stubs.
    struct Seam {
        var userId: @MainActor () -> String?
        var deviceId: @MainActor () -> String?
        /// This device's name or type sealed under the personal key; nil when
        /// it can't be (`sealUnderPersonalKey`).
        var seal: @MainActor (_ plaintext: String, _ fieldTag: String) -> EncryptedBlobRequest?
        var createDevice: @MainActor (CreateDeviceRequest) async throws -> DeviceResponse
        var defaults: UserDefaults

        static var live: Seam {
            Seam(
                userId: { AuthManager.shared.userId },
                deviceId: { keychain.getString(for: KeychainService.Key.deviceId) },
                seal: { sealUnderPersonalKey($0, fieldTag: $1) },
                createDevice: { try await api.createDevice(request: $0) },
                defaults: .standard
            )
        }
    }

    /// This device's name or type sealed under the personal key, or nil: no
    /// key in use to seal with (not loaded yet, its publish failed, or a slot
    /// holding only the retired key from before a password reset), or a seal
    /// that failed.
    private static func sealUnderPersonalKey(_ plaintext: String, fieldTag: String) -> EncryptedBlobRequest? {
        guard SelfKeyManager.personalKeyInUse(crypto) else {
            return nil
        }
        guard let sealed = try? crypto.encryptDataV2(
            circleId: SelfKeyManager.selfCircleUuid, plaintext: plaintext, fieldTag: fieldTag) else { return nil }
        return EncryptedBlobRequest(nonce: sealed.nonce, ciphertext: sealed.ciphertext)
    }

    /// What the device's name and type go as when nothing can seal them. The
    /// server discards both blobs and accepts empty ones.
    static let unsealed = EncryptedBlobRequest(nonce: "", ciphertext: "")

    /// Best-effort registration. Returns true when the deviceId is
    /// known to be registered against this user by the time we
    /// return. Failures are non-fatal — log + return false; callers
    /// shouldn't gate the rest of the login flow on this.
    ///
    /// `pushToken`/`pushType` carry the APNs token when called from the
    /// push path. This matters because the backend writes a push
    /// registration ONLY when the create request carries a token — a
    /// token-less create persists nothing, and the dedicated
    /// `PUT /devices/:id/push-token` 404s when no registration exists
    /// (it only updates). So the APNs token MUST ride this POST or it
    /// never lands. When a token is supplied we also skip the
    /// registered-flag short-circuit: an existing install (flag already
    /// set) still needs the token registration written/refreshed.
    /// Mirrors the Android app: the device-registration POST carries the
    /// push token.
    @discardableResult
    static func ensure(pushToken: String? = nil, pushType: String? = nil) async -> Bool {
        await ensure(pushToken: pushToken, pushType: pushType, seam: .live)
    }

    static func ensure(pushToken: String?, pushType: String?, seam: Seam) async -> Bool {
        guard let userId = seam.userId(), let deviceId = seam.deviceId() else {
            return false
        }
        let key = flagKey(userId: userId, deviceId: deviceId)
        // A token-carrying call must always POST (the server's push
        // registration is only written when the token is present); only the
        // token-less SDK-stream registration may short-circuit on the flag.
        if pushToken == nil, seam.defaults.bool(forKey: key) {
            return true
        }
        // Nothing to seal with (no personal key in use: not loaded yet,
        // or its publish failed and retries in an hour): the name and
        // type go empty rather than holding the registration back. The
        // server does not keep them, and dropping a delivered APNs token
        // here would leave the device with no registration: no location
        // stored, no needs-attention, no check-in.
        let encName = seam.seal(UIDevice.current.name, "device_name") ?? unsealed
        let encType = seam.seal("iOS", "device_type") ?? unsealed
        do {
            let request = CreateDeviceRequest(
                deviceId: deviceId,
                encryptedDeviceType: encType,
                encryptedDeviceName: encName,
                pushToken: pushToken,
                pushType: pushType,
                pushEndpoint: nil
            )
            let response = try await seam.createDevice(request)
            // FALSE: the server wrote no row (no push route yet), and ingest,
            // needs-attention and check-ins will refuse this device until a
            // token-carrying POST. Not registered: the flag stays unset, so a
            // caller can wait (a check-in) instead of acting on a yes the
            // server didn't give. Absent: an older server that doesn't say.
            guard response.pushRegistered != false else {
                #if DEBUG
                print("[Track] DeviceRegistrar.ensure: registered with no push route yet (push_registered false)")
                #endif
                return false
            }
            seam.defaults.set(true, forKey: key)
            return true
        } catch {
            #if DEBUG
            print("[Track] DeviceRegistrar.ensure failed: \(error)")
            #endif
            return false
        }
    }

    /// Forget that THIS device is registered, so the next token-less
    /// `ensure()` actually POSTs instead of short-circuiting on the flag.
    ///
    /// Needed because the server can decide the registration is invalid without
    /// the app knowing: it refuses every location send whose device_id
    /// it cannot match to the user ("Device not found or not owned by user"), and
    /// `ensure()` would otherwise read its own flag and report success without
    /// talking to anybody. Mirrors the Android app's
    /// `sessionManager.setDeviceRegistered(false)` on the same signal.
    static func invalidate() {
        guard let userId = AuthManager.shared.userId,
              let deviceId = keychain.getString(for: KeychainService.Key.deviceId) else { return }
        UserDefaults.standard.removeObject(forKey: flagKey(userId: userId, deviceId: deviceId))
    }

    /// Drop the registered-flag for the current user so the next
    /// login re-registers. Called from AuthManager.logout to keep
    /// the per-user scoping honest across account switches.
    static func reset(userId: String) {
        let prefix = "device.registered.\(userId.lowercased())."
        for key in UserDefaults.standard.dictionaryRepresentation().keys
        where key.lowercased().hasPrefix(prefix) {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
