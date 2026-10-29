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
import DeviceCheck
import CryptoKit

/// App Attest integration. Acquires a server-issued attestation token
/// (`X-Attestation-Token` header) so register / login + other captcha-
/// guarded endpoints can skip Cloudflare Turnstile when the request
/// comes from a real, unmodified app on a real device.
///
/// Flow, as the auth server expects it:
///   1. DCAppAttestService.generateKey() once per install -> keyId.
///   2. GET /api/v1/auth/attest/challenge -> server-issued nonce.
///   3. DCAppAttestService.attestKey(keyId, clientDataHash:
///        sha256(challenge)) -> attestation object.
///   4. POST /api/v1/auth/attest/apple {attestation, challenge, key_id}
///        -> {attestation_token, platform, expires_at}.
///   5. Echo attestation_token back as X-Attestation-Token on
///        subsequent register / login requests.
///
/// The token is cached in keychain until 5 min before expiry so the app
/// doesn't hit step 1-4 every login.
@MainActor
final class AttestationManager {
    static let shared = AttestationManager()

    private let api = APIService.shared
    private let keychain = KeychainService.shared
    private let attest = DCAppAttestService.shared

    private struct CachedToken: Codable {
        let token: String
        let expiresAt: Date
    }

    private static let cachedTokenKey = "attest.cached_token"
    private static let keyIdKey = "attest.key_id"

    private init() {}

    /// Returns a usable attestation token, fetching one if the cache is
    /// empty or near expiry. Returns nil on devices that don't support
    /// App Attest (Simulator, jailbroken, < iOS 14) — callers should
    /// fall back to CAPTCHA in that case.
    func getOrFetchToken() async -> String? {
        if let cached = loadCachedToken(), cached.expiresAt > Date().addingTimeInterval(5 * 60) {
            return cached.token
        }
        guard attest.isSupported else { return nil }
        do {
            let keyId = try await ensureKeyId()
            let challenge = try await api.getAttestationChallenge()
            guard let challengeData = challenge.challenge.data(using: .utf8) else { return nil }
            let hash = Data(SHA256.hash(data: challengeData))
            let attestation = try await attest.attestKey(keyId, clientDataHash: hash)
            let response = try await api.verifyAppleAttestation(
                attestation: attestation.base64EncodedString(),
                challenge: challenge.challenge,
                keyId: keyId
            )
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let expires = formatter.date(from: response.expiresAt)
                ?? Date().addingTimeInterval(60 * 60)
            cache(CachedToken(token: response.attestationToken, expiresAt: expires))
            return response.attestationToken
        } catch {
            print("[Track] attestation fetch failed: \(error)")
            return nil
        }
    }

    /// Drop the cached token + key id (e.g. on logout, or when the
    /// server rejects the token as expired). Next call will regenerate.
    func reset() {
        keychain.deleteSDKData(for: Self.cachedTokenKey)
        keychain.deleteSDKData(for: Self.keyIdKey)
    }

    // MARK: - Internal

    private func ensureKeyId() async throws -> String {
        if let existing = keychain.getSDKData(for: Self.keyIdKey) {
            return existing
        }
        let keyId = try await attest.generateKey()
        try keychain.saveSDKData(keyId, for: Self.keyIdKey)
        return keyId
    }

    private func loadCachedToken() -> CachedToken? {
        guard let raw = keychain.getSDKData(for: Self.cachedTokenKey),
              let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(CachedToken.self, from: data)
    }

    private func cache(_ token: CachedToken) {
        guard let encoded = try? JSONEncoder().encode(token),
              let raw = String(data: encoded, encoding: .utf8) else { return }
        try? keychain.saveSDKData(raw, for: Self.cachedTokenKey)
    }
}
