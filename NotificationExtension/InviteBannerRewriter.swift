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
import UserNotifications
#if TRACK_TESTS
// The unit tests compile this file too, and reach `TrustBlocklist` through the
// app module, as its neighbours reach the rules they share with the app.
@testable import Track
#endif

/// Puts the inviter's and the circle's names on an invite banner, at the detail
/// level the user chose, without either name ever crossing Apple's relay.
///
/// The push arrives as the server's generic "Circle invitation / You've been
/// invited to join a circle". This fetches the pending invite over the app's own
/// authenticated connection — the same TLS session the app uses, with the
/// session token the app persisted in the shared keychain — and rewrites the
/// body from what came back. The app's `postLocalInviteNotification` does the
/// same for a silent push; both go through `InviteNotificationCopy`, so the
/// words are identical whichever path produced them.
///
/// Best-effort by design. iOS gives the extension a few seconds; each fetch
/// (the notification row, then the pending invites) gets at most eight, and
/// every failure — no token, an expired one, offline, a
/// decode error, an ambiguous list — hands back the generic copy with the
/// improved title. A missing name must never cost the notification.
enum InviteBannerRewriter {
    private static let fetchTimeout: TimeInterval = 8
    // Must match ExtensionBridge in the app.
    private static let appGroupSuite = "group.com.pingolin.track"
    private static let detailLevelKey = "notification_detail_level"
    private static let apiBaseURLKey = "api_base_url"

    /// The fetch carries the session token, so nothing about it may be kept on
    /// disk: no response cache — the shared session stored the request WITH
    /// its Authorization header, and the reply, in this extension's
    /// Library/Caches — and no cookies.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        return TrustBlocklist.session(configuration: configuration)
    }()

    /// The invite banner with its names, at the user's detail level; the
    /// generic copy (with the event title) when anything is missing.
    static func rewritten(
        _ content: UNMutableNotificationContent,
        circleId: String?,
        pushId: String?
    ) async -> UNMutableNotificationContent {
        // What earlier builds cached here. Nothing else in the extension uses
        // this cache, so emptying it on every run costs nothing.
        URLCache.shared.removeAllCachedResponses()
        content.title = InviteNotificationCopy.title
        let shared = UserDefaults(suiteName: appGroupSuite)
        let level = shared?.string(forKey: detailLevelKey)
        // Generic: the user asked for no names on the lock screen, so there is
        // nothing to fetch.
        if level == "generic" {
            content.body = InviteNotificationCopy.body(inviter: nil, circle: nil, level: level)
            return content
        }
        guard let base = shared?.string(forKey: apiBaseURLKey), let baseURL = URL(string: base),
              let token = ExtensionSession.accessToken()
        else { return content }
        // The circle: the notification ROW the push names says which
        // (`alert_id` is the row, never the circle). A push from an older
        // server carries the circle id itself, which no row matches.
        var circle = circleId
        if circle == nil, let pushId, UUID(uuidString: pushId) != nil,
           let row = await fetch(baseURL.appendingPathComponent("api/v1/notifications/\(pushId)"), token: token) {
            circle = InviteNotificationCopy.decodeRowCircle(row)
        }
        guard let data = await fetch(baseURL.appendingPathComponent("api/v1/invites/received"), token: token),
              let invite = InviteNotificationCopy.pick(
                  from: InviteNotificationCopy.decodePending(data), circleId: circle ?? pushId)
        else { return content }
        content.body = InviteNotificationCopy.body(
            inviter: invite.inviterDisplayName, circle: invite.circleName, level: level)
        // A stable identifier per invite lets the app's tap handler and its
        // own local notification agree on which invite this is.
        var info = content.userInfo
        info["invite_id"] = invite.id
        content.userInfo = info
        return content
    }

    /// One GET with the session token; the body of a 200, else nil.
    private static func fetch(_ url: URL, token: String) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = fetchTimeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }
}

/// READ-ONLY access to the session token the app keeps in the keychain.
///
/// Reads the SAME item as the app's `KeychainService` (service
/// "com.pingolin.track", account "access_token"), deliberately duplicated here
/// rather than shared — pulling the app's file in would drag its dependencies
/// into the extension, the same reasoning as `ExtensionKeyStorage`. Readable
/// because the extension declares the app's keychain-access-group and the app
/// stores the token `AfterFirstUnlockThisDeviceOnly`, so it works on a locked
/// phone after the first unlock since boot. Never refreshes or writes: refresh
/// tokens rotate, and an extension rotating one behind the app's back would log
/// the user out. An expired token simply means the generic copy.
enum ExtensionSession {
    private static let service = "com.pingolin.track"
    private static let accessTokenAccount = "access_token"
    private static let userIdAccount = "user_id"

    static func accessToken() -> String? {
        read(account: accessTokenAccount)
    }

    /// The signed-in account's id, as the app keeps it (`AuthManager.userId`):
    /// the owner of the approval records the background handover reads.
    static func userId() -> String? {
        read(account: userIdAccount)
    }

    private static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else { return nil }
        return value
    }
}
