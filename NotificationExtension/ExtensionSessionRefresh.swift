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
import Security
#if TRACK_TESTS
@testable import Track
#endif

/// The session, refreshed from the notification extension when the app's access
/// token has run out — so a phone left alone for more than a day still hands a
/// newcomer their circle.
///
/// This is safe because the server keeps the old token good until the new pair is
/// first used (and two refreshes from one token within 60 s become siblings). A
/// server that rotated the stored token at once would strand the app's next
/// launch whenever the extension stopped before it saved the new pair. So the
/// rule is: refresh holding `AppGroupLock.refresh()` (the app takes it too), read
/// the stored pair AGAIN under it (changed: the app refreshed — use its pair),
/// save the new pair, and only then use it. A pair that could not be saved is
/// never used.
///
/// The only keychain writes this extension makes are here, to the app's two
/// session items, and only ever as an update of items the app created.
enum ExtensionSessionRefresh {
    /// Whether the extension refreshes a token that has run
    /// out.
    static let enabled = true

    /// The stored pair, and the one write: a refreshed pair.
    struct TokenStore {
        var read: () -> (access: String?, refresh: String?)
        var write: (_ access: String, _ refresh: String?) -> Bool

        static let keychain = TokenStore(
            read: { (ExtensionSession.accessToken(), ExtensionSession.refreshToken()) },
            write: { ExtensionSession.saveRefreshedPair(access: $0, refresh: $1) })
    }

    /// An access token good for `margin` more seconds: the stored one, or — when
    /// refreshing is on — a refreshed one, per the rule above. nil: no handover
    /// this time (the banner still shows).
    static func token(now: Date, margin: TimeInterval, authBase: String?, lock: AppGroupLock?,
                      transport: HandoverTransport, store: TokenStore, enabled: Bool = enabled,
                      wait: TimeInterval = AppGroupLock.extensionWait) async -> String? {
        let stored = store.read()
        if let access = stored.access, let claims = TokenClaims(access), claims.expiresAt > now.addingTimeInterval(margin) {
            return access
        }
        guard enabled, let authBase, let url = URL(string: authBase + "/api/v1/auth/refresh"), let lock,
              let refresh = stored.refresh, !refresh.isEmpty, refresh != "none" else { return nil }
        guard let held = await lock.acquire(timeout: wait) else { return nil }
        defer { held.release() }
        let again = store.read()
        if SessionRefresh.anotherProcessRefreshed(before: refresh, now: again.refresh) {
            return again.access
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(refresh, forHTTPHeaderField: "X-Refresh-Token")
        if let access = again.access, !access.isEmpty {
            request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        }
        guard let (data, response) = try? await transport.send(request), response.statusCode == 200,
              let pair = RefreshedPair.decode(data) else { return nil }
        guard store.write(pair.accessToken, pair.refreshToken) else { return nil }
        return pair.accessToken
    }

    /// `/auth/refresh`'s answer, with or without the `{success, data}` envelope.
    struct RefreshedPair: Decodable, Equatable {
        let accessToken: String
        let refreshToken: String?

        static func decode(_ data: Data) -> RefreshedPair? {
            struct Envelope: Decodable { let data: RefreshedPair? }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let pair = (try? decoder.decode(Envelope.self, from: data))?.data
                ?? (try? decoder.decode(RefreshedPair.self, from: data))
            guard let pair, !pair.accessToken.isEmpty else { return nil }
            return pair
        }
    }
}

extension ExtensionSession {
    private static let tokenService = "com.pingolin.track"

    /// The app's refresh token, read only for a refresh.
    static func refreshToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: tokenService,
            kSecAttrAccount as String: "refresh_token",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let token = String(data: data, encoding: .utf8), !token.isEmpty
        else { return nil }
        return token
    }

    /// A refreshed pair over the app's own two items — an UPDATE only: the
    /// extension never creates a session. Refresh token first, as the app does:
    /// it is the one that recovers the session if the access token's write fails.
    static func saveRefreshedPair(access: String, refresh: String?) -> Bool {
        func update(_ account: String, _ value: String) -> Bool {
            let identity: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: tokenService,
                kSecAttrAccount as String: account,
            ]
            let attributes: [String: Any] = [
                kSecValueData as String: Data(value.utf8),
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]
            return SecItemUpdate(identity as CFDictionary, attributes as CFDictionary) == errSecSuccess
        }
        if let refresh, !refresh.isEmpty, refresh != "none", !update("refresh_token", refresh) { return false }
        return update("access_token", access)
    }
}
