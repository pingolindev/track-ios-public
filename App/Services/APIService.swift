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
import os
import PingolinTrackSDK
import UIKit

/// MainActor wrapper around the UIKit background-task assertion held across a
/// token rotation. The app is kept alive in the background for location, so
/// background subsystems (the inactivity watcher, the location streamer) can
/// trigger a `/auth/refresh` while backgrounded. iOS may suspend the app
/// between the server committing the rotation (200) and the client persisting
/// the new single-use token pair — stranding a consumed token → forced logout
/// on next launch. Holding this assertion across the response + keychain
/// writes buys the seconds needed to finish persisting before suspension.
/// Isolated to its own type so the APIService actor reaches it in one hop.
@MainActor
enum TokenRefreshAssertion {
    static func begin() -> UIBackgroundTaskIdentifier {
        UIApplication.shared.beginBackgroundTask(withName: "token-refresh")
    }
    static func end(_ id: UIBackgroundTaskIdentifier) {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
    }
}

private let trackDiagLog = Logger(subsystem: "com.pingolin.track", category: "TrackDiag")

/// HTTP API client for Pingolin Track
actor APIService {
    static let shared = APIService()

    private let session: URLSession
    private let config = AppConfiguration.shared
    private let keychain = KeychainService.shared
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    private init() {
        let configuration = Self.makeSessionConfiguration()
        // Cookies earlier versions let this session store — see
        // `makeSessionConfiguration`. Once per process; cheap when there are none.
        Self.purgeStoredAuthCookies()
        // And the responses they let it cache, once per install.
        Self.purgeCachedResponsesOnce()
        // No certificate pinning, on purpose: system trust only. Every host
        // sits behind Cloudflare Universal SSL, which picks the issuing CA and
        // rotates it without notice, so a pin hard-fails every request the
        // day Cloudflare swaps CA. Pinning would need Advanced Certificate
        // Manager (to choose the CA), root pins with a backup, and a remote
        // kill switch. The Android app makes the same choice. System trust
        // minus the compromised emSign keys (`TrustBlocklist`), which only
        // ever refuses.
        self.session = TrustBlocklist.session(configuration: configuration)

        self.decoder = Self.makeWireDecoder()
        self.encoder = Self.makeWireEncoder()
    }

    /// The configuration the API session is built from. Static so a test can
    /// check it.
    ///
    /// NO COOKIE JAR. Every request authenticates with a bearer token and the
    /// refresh token travels in `X-Refresh-Token`, which auth prefers over any
    /// cookie. auth nonetheless answers SRP step 2, the 2FA login and
    /// `/auth/refresh` with `Set-Cookie: auth_token=<JWT>` and
    /// `refresh_token=<token>; Max-Age=2592000` (for the web portal), and the
    /// default configuration keeps them in `HTTPCookieStorage.shared` — on
    /// disk under Library/Cookies, which iCloud and computer backups include.
    /// That would put a 30-day bearer credential outside the `…ThisDeviceOnly`
    /// Keychain item that exists precisely so a restored backup cannot carry
    /// it to another device. The Android app's HTTP client keeps no cookie jar
    /// either.
    nonisolated static func makeSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        // NO RESPONSE CACHE either. The default configuration shares
        // `URLCache.shared`, which keeps auth's replies on disk in
        // Library/Caches/<bundle>/Cache.db: SRP step 2 with the refresh and
        // access tokens in its body and its Set-Cookie, and every cached
        // request with its `Authorization: Bearer` header — plaintext
        // outside the Keychain (auth sends no Cache-Control). Nothing here
        // wants HTTP caching: offline data has CacheStore.
        configuration.urlCache = nil
        return configuration
    }

    /// Delete the auth cookies earlier versions stored (see
    /// `makeSessionConfiguration`). Nothing else in the jar is touched. Returns
    /// how many were removed.
    @discardableResult
    nonisolated static func purgeStoredAuthCookies(from storage: HTTPCookieStorage = .shared) -> Int {
        var removed = 0
        for cookie in storage.cookies ?? [] where cookie.name == "refresh_token" || cookie.name == "auth_token" {
            storage.deleteCookie(cookie)
            removed += 1
        }
        return removed
    }

    /// Empty the shared URL cache ONCE, on the first launch of a version whose
    /// API session does not write to it (see `makeSessionConfiguration`), so any
    /// auth replies and bearer headers an earlier version left there are gone.
    /// The cache is shared with the map, whose tiles and style are fetched again
    /// once; hence once, not every launch. Returns whether it ran.
    @discardableResult
    nonisolated static func purgeCachedResponsesOnce(
        cache: URLCache = .shared,
        defaults: UserDefaults = .standard
    ) -> Bool {
        let done = "apiResponseCachePurged.v1"
        guard !defaults.bool(forKey: done) else { return false }
        cache.removeAllCachedResponses()
        defaults.set(true, forKey: done)
        return true
    }

    /// The encoder every request body goes through. Factored out of `init` so
    /// `encodeRequestBody` below can produce byte-identical output — a test that
    /// configures its own JSONEncoder is testing its own configuration.
    nonisolated static func makeWireEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Int64(date.timeIntervalSince1970 * 1000))
        }
        return encoder
    }

    /// The exact bytes `post` / `put` / `patch` put in `URLRequest.httpBody`.
    ///
    /// Exists so a wire contract can be asserted against the REQUEST rather
    /// than against the model the caller keeps. Those are not the same claim:
    /// a local model can hold the value the user picked while the request
    /// carries something else (a hard-coded default, say), and a test looking
    /// at the returned object would pass while the value was being thrown
    /// away.
    nonisolated static func encodeRequestBody<B: Encodable>(_ body: B) throws -> Data {
        try makeWireEncoder().encode(body)
    }

    /// A value for a query string, escaped so the server reads back exactly what
    /// was sent. `.urlQueryAllowed` (and `URLQueryItem`) leave `+`, `&`, `=` and
    /// `#` alone, and a query string decodes `+` as a SPACE: unescaped, the key
    /// lookup for `name+tag@example.com` would ask about "name tag@example.com",
    /// find no account, and send the invitation as an invitation to an EMAIL
    /// for an address that has an account — which the server refuses.
    nonisolated static func queryValue(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=#")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// The decoder every response body goes through. Factored out of `init` for
    /// the same reason as `makeWireEncoder`: so a test can decode a REAL body
    /// exactly as the live path does, rather than testing a JSONDecoder it
    /// configured itself.
    nonisolated static func makeWireDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let timestamp = try? container.decode(Double.self) {
                return Date(timeIntervalSince1970: timestamp / 1000)
            }
            if let dateString = try? container.decode(String.self) {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let date = formatter.date(from: dateString) {
                    return date
                }
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date format")
        }
        return decoder
    }

    /// Unwrap `{"success":…,"data":…}` into `T`. This IS the live decode — the
    /// private `decodeResponse` calls it with the instance decoder — exposed so
    /// a test can assert which `T` a route's body actually admits.
    ///
    /// `T` is chosen by the accessor: `get` asks for the payload type directly,
    /// `getPaginated` asks for `Paginated<E>` and reads `.items`. Point the
    /// second at a route whose `data` is a bare array and every call throws
    /// `keyNotFound("items")` on a 200 — see `listCircleCheckIns`.
    nonisolated static func decodeResponseBody<T: Decodable>(
        _ data: Data,
        using decoder: JSONDecoder = makeWireDecoder()
    ) throws -> T {
        // Try to decode as APIResponse wrapper first
        if let apiResponse = try? decoder.decode(APIResponse<T>.self, from: data) {
            if let result = apiResponse.data {
                return result
            }
            if let error = apiResponse.error {
                throw error
            }
        }

        // Fall back to direct decode
        return try decoder.decode(T.self, from: data)
    }

    // MARK: - Auth Endpoints

    /// SRP login, step 1.
    ///
    /// `identifyDevice: true` — one of exactly two requests in this app that send
    /// the device-labeled UA without a bearer token. This one is the load-bearing
    /// half: the auth server reads the UA off THIS request, stores it on the SRP
    /// session, and step 2 then names the device from that stored UA rather than
    /// from its own headers. The 2FA branch keeps the same string and reads it
    /// back, so a two-factor login is named from here too.
    ///
    /// Without it every iOS session would be stored as "Unknown Device", and the
    /// account portal's device list could not tell one iPhone from another.
    func srpStep1(email: String) async throws -> SRPStep1Response {
        let body = SRPStep1Request(email: email)
        let attestation = await AttestationManager.shared.getOrFetchToken()
        return try await post(
            path: "/api/v1/auth/srp/step1",
            body: body,
            auth: false,
            baseURL: config.authBaseURL,
            attestationToken: attestation,
            identifyDevice: true
        )
    }

    /// SRP login, step 2 — the request that creates the session.
    ///
    /// `identifyDevice: true` for the same reason as step 1. The server names the
    /// device from the step-1 UA it stored, so this half changes nothing on its
    /// own; it is here so the pair stays consistent if the server ever reads the
    /// creating request's own headers, which is the intuitive reading.
    func srpStep2(sessionId: String, clientPublic: String, clientProof: String) async throws -> SRPStep2Response {
        let body = SRPStep2Request(sessionId: sessionId, clientPublic: clientPublic, clientProof: clientProof)
        return try await post(
            path: Self.srpStep2Path,
            body: body,
            auth: false,
            baseURL: config.authBaseURL,
            identifyDevice: true
        )
    }

    /// The sign-in's SRP step 2. Its 401 is the proof failing (see `execute`).
    nonisolated static let srpStep2Path = "/api/v1/auth/srp/step2"

    /// SRP step-up re-authentication, step 1. Unlike login's srpStep1 the
    /// request carries NO email — the server identifies the user from the
    /// bearer/session, so this MUST be sent authenticated (`auth: true`).
    /// The response shape matches login step1 (salt, server public B,
    /// session correlator, bcrypt salt), so we reuse SRPStep1Response.
    /// Backend route: POST /api/v1/auth/reauth/srp/step1.
    func reauthStep1() async throws -> SRPStep1Response {
        return try await post(path: "/api/v1/auth/reauth/srp/step1", body: EmptyBody(), auth: true, baseURL: config.authBaseURL)
    }

    /// SRP step-up re-authentication, step 2. Reuses SRPStep2Request
    /// (session_id, client_public, client_proof). On a valid proof the
    /// server returns a short-lived `reauth_token` the caller passes to
    /// DELETE /api/v1/auth/me in place of the raw password. A wrong
    /// password fails proof verification server-side and throws (401).
    /// Sent authenticated (`auth: true`) as an authenticated step-up.
    /// Backend route: POST /api/v1/auth/reauth/srp/step2.
    func reauthStep2(sessionId: String, clientPublic: String, clientProof: String) async throws -> ReauthStep2Response {
        let body = SRPStep2Request(sessionId: sessionId, clientPublic: clientPublic, clientProof: clientProof)
        return try await post(path: "/api/v1/auth/reauth/srp/step2", body: body, auth: true, baseURL: config.authBaseURL)
    }

    /// Complete a login that stopped at the 2FA challenge.
    ///
    /// The route is `/api/v1/auth/login/2fa` (`twoFactorLoginPath`); the server
    /// serves no `/auth/2fa/verify`. The body carries `two_factor_token`,
    /// `code` and `method`, the fields the server's 2FA login expects.
    func verify2FA(twoFactorToken: String, code: String, method: String = "totp") async throws -> TwoFactorLoginResponse {
        let body = Verify2FARequest(twoFactorToken: twoFactorToken, code: code, method: method)
        return try await post(path: Self.twoFactorLoginPath, body: body, auth: false, baseURL: config.authBaseURL)
    }

    /// The two-step sign-in's route. A refusal there throws `http_<status>`
    /// with auth's `error_code` (see `execute`), which
    /// `AuthManager.twoFactorRefusal` reads.
    nonisolated static let twoFactorLoginPath = "/api/v1/auth/login/2fa"

    /// Refresh the access + refresh tokens via `POST /api/v1/auth/refresh`.
    ///
    /// Preferred (Proton-style) path: the opaque refresh token rides
    /// in `X-Refresh-Token`. The server hashes it, looks the session
    /// up by hash, atomically rotates the row, and returns the new
    /// pair in the body. JWT signature isn't consulted, so issuer /
    /// audience / key rotations don't log everyone out. Mirrors
    /// the Android app.
    ///
    /// Legacy fallback: for a session the server holds no
    /// refresh-token row for, it uses its JWT-based path when the
    /// header is absent and *attaches* a freshly minted refresh token
    /// to the response. We forward the (possibly expired) access JWT
    /// via Authorization so that fallback can fire — the refresh
    /// endpoint skips the exp check.
    func refreshToken(refreshToken: String?) async throws -> AuthResponse {
        var request = URLRequest(url: URL(string: config.authBaseURL + "/api/v1/auth/refresh")!)
        request.httpMethod = "POST"
        request.httpBody = "{}".data(using: .utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.userAgent, forHTTPHeaderField: "User-Agent")
        // Server rotates the refresh token on every call — `none`
        // is the registration sentinel for "no refresh token yet"
        // and an empty string is the older completeLogin sentinel.
        // In either case we omit the header and let the legacy JWT
        // path attach a fresh token to the response.
        if let token = refreshToken, !token.isEmpty, token != "none" {
            request.setValue(token, forHTTPHeaderField: "X-Refresh-Token")
        }
        if let access = keychain.getString(for: .accessToken), !access.isEmpty {
            request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        }
        return try await execute(request)
    }

    func getMe() async throws -> User {
        return try await get(path: "/api/v1/auth/me", baseURL: config.authBaseURL)
    }

    /// Change the account's display name.
    ///
    /// PATCH, not PUT: the server serves GET, PATCH and DELETE on this
    /// path, and answers a PUT with 405 Method Not Allowed.
    ///
    /// The response is `UpdateDisplayNameResponse`, not `User`: the
    /// server returns `{ "display_name": ... }` and nothing else, so
    /// decoding it as `User` would throw `keyNotFound(id)`.
    func updateProfile(displayName: String) async throws -> UpdateDisplayNameResponse {
        let body = UpdateProfileRequest(displayName: displayName)
        return try await patch(path: "/api/v1/auth/me", body: body, baseURL: config.authBaseURL)
    }

    func verifyEmail(code: String) async throws -> EmptyResponse {
        let body = VerifyEmailRequest(code: code)
        return try await post(path: "/api/v1/auth/verify-email", body: body, baseURL: config.authBaseURL)
    }

    func resendVerificationEmail() async throws -> EmptyResponse {
        return try await post(path: "/api/v1/auth/email/resend-verification", body: EmptyBody(), baseURL: config.authBaseURL)
    }

    func getEmailVerificationStatus() async throws -> EmailStatusResponse {
        return try await get(path: "/api/v1/auth/email/status", baseURL: config.authBaseURL)
    }

    // MARK: - Circle Endpoints

    /// Every circle of this account, every page (`getAllPages`). `whole` only
    /// when the server gave them on ONE page: it orders a first page by the
    /// member's own sort position and later pages by (day bucket, id), so a
    /// reorder between two page reads can skip a circle. Only a whole list may
    /// say a circle is gone (the Android app's rule).
    func getCircleList() async throws -> (circles: [CircleResponse], whole: Bool) {
        let list = try await getAllPages(path: "/api/v1/circles", id: { (circle: CircleResponse) in circle.id })
        return (list.items, list.pages == 1)
    }

    func createCircle(
        encryptedName: EncryptedBlobRequest,
        encryptedCircleKey: EncryptedBlobRequest,
        ephemeralPublicKey: String,
        locationConsent: LocationConsentGrant?,
        circleId: String? = nil,
        genesis: RefreshRecordWire? = nil
    ) async throws -> CircleResponse {
        var body = CreateCircleRequest(
            encryptedName: encryptedName,
            encryptedCircleKey: encryptedCircleKey,
            ephemeralPublicKey: ephemeralPublicKey,
            locationConsent: locationConsent
        )
        body.circleId = circleId
        body.genesis = genesis
        return try await post(path: "/api/v1/circles", body: body)
    }

    // MARK: - Refresh records

    /// A fresh circle id the server reserved for this account, short-lived and
    /// used once: the genesis record binds it.
    func reserveCircleId() async throws -> ReservedCircleId {
        return try await post(path: "/api/v1/circles/reserve-id", body: EmptyBody())
    }

    /// Every circle's refresh records above `since` (the SDK's
    /// `refreshHeadVersions`), with the heads of its active members, one
    /// snapshot a page, all circles in one call. While `more`, ask again
    /// with each circle's `since` raised to the last version served.
    func refreshRecords(since: [String: Int32]) async throws -> RefreshRecordsPage {
        let body = RefreshRecordsRequest(since: Dictionary(since.map { ($0.key.lowercased(), Int($0.value)) },
                                                           uniquingKeysWith: { first, _ in first }))
        return try await post(path: "/api/v1/circles/refresh-records", body: body)
    }

    /// Publish this account's head for a circle. The server keeps it forward
    /// only, or the same head signed again (after a reset). `stored` is
    /// false when it kept a newer one.
    func putCircleHead(circleId: String, head: String, signature: String) async throws -> PutCircleHeadResponse {
        return try await put(path: "/api/v1/circles/\(circleId)/head",
                             body: PutCircleHeadRequest(head: head, signature: signature))
    }

    // MARK: - Location consent

    /// The notice text this server serves, and the digest it will stamp a
    /// consent with.
    ///
    /// Fetched rather than bundled. The server records which text a consent was
    /// given against, so a client rendering its own copy of something similar
    /// would produce a record naming a text the user never saw. The English
    /// fallback in `LocationConsentNotice` is only for the case where this call
    /// fails outright.
    func locationConsentNotice() async throws -> LocationConsentNoticeResponse {
        return try await get(path: "/api/v1/consent/location/notice")
    }

    /// Whether this circle has a live consent, and whether it is against the
    /// current text.
    func locationConsent(circleId: String) async throws -> LocationConsentResponse {
        return try await get(path: "/api/v1/consent/location/circles/\(circleId)")
    }

    func leaveCircle(circleId: String) async throws -> EmptyResponse {
        return try await delete(path: "/api/v1/circles/\(circleId)/leave")
    }

    /// Owner-only delete. Backend route: DELETE /api/v1/circles/:id.
    func deleteCircle(circleId: String) async throws -> EmptyResponse {
        return try await delete(path: "/api/v1/circles/\(circleId)")
    }

    /// This account's own name in a circle, sealed with the circle key (field
    /// tag "display_name"). Backend route: PUT /api/v1/circles/:id/display-name
    /// (active members only). It is what lets the circle's apps name this
    /// person in notifications from data they open themselves; web and Android
    /// write it after creating or joining a circle.
    func setCircleDisplayName(circleId: String, sealed: EncryptedBlobRequest) async throws -> EmptyResponse {
        return try await put(path: "/api/v1/circles/\(circleId)/display-name",
                             body: SetCircleDisplayNameRequest(encryptedDisplayName: sealed))
    }

    /// Owner-only rename. Backend route: PATCH /api/v1/circles/:id.
    /// Re-encrypt the new name with the *existing* circle key — no
    /// rotation; just an in-place update of encrypted_name + nonce.
    /// `keyVersion`: the version the new name is sealed under, so the server can
    /// say which key the name is under (`name_key_version`; a newcomer's app
    /// checks its first key against the name only then).
    func renameCircle(circleId: String, encryptedName: EncryptedBlobRequest, keyVersion: Int?) async throws -> EmptyResponse {
        let request = UpdateCircleRequest(encryptedName: encryptedName, keyVersion: keyVersion)
        return try await patch(path: "/api/v1/circles/\(circleId)", body: request)
    }

    /// Backend route: GET /api/v1/sos/:sos_id. Same shape as a single
    /// element of /sos/active.
    func getSOSAlert(alertId: String) async throws -> SOSResponse {
        return try await get(path: "/api/v1/sos/\(alertId)")
    }

    /// The same route for the raiser's own alert, with who is responding
    /// (`OwnSOSResponse`). Only the raiser's status poll reads it.
    func getOwnSOSAlert(alertId: String) async throws -> OwnSOSResponse {
        return try await get(path: "/api/v1/sos/\(alertId)")
    }

    /// Backfill per-user pseudonyms across all circle-key versions the
    /// caller currently holds. Idempotent. Mirrors the Android refresh
    /// path that calls this after key rotation so historical rows stay
    /// visible. Backend route:
    /// POST /api/v1/circles/:circle_id/pseudonyms/backfill.
    func backfillPseudonyms(circleId: String, pseudonyms: [String]) async throws -> PseudonymBackfillResponse {
        let request = PseudonymBackfillRequest(pseudonyms: pseudonyms)
        return try await post(path: "/api/v1/circles/\(circleId)/pseudonyms/backfill", body: request)
    }

    /// Look up a user's X25519 sharing public key by email. Used to wrap a
    /// circle key for a known invitee at invite-time. Backend route:
    /// GET /api/v1/users/public-key?email=... .
    func lookupPublicKey(email: String) async throws -> UserPublicKeyResponse {
        return try await get(path: "/api/v1/users/public-key?email=\(Self.queryValue(email))")
    }

    /// Fetch every active member's sharing public key, used during owner-driven
    /// key rotation. Backend route: GET /api/v1/circles/:id/member-public-keys.
    /// A row naming nobody (no UUID at all) is dropped (`ServedEntries`).
    func memberPublicKeys(circleId: String) async throws -> [MemberPublicKeyResponse] {
        let list: ServedEntries<MemberPublicKeyResponse> = try await get(path: "/api/v1/circles/\(circleId)/member-public-keys")
        return list.items
    }

    /// Rotate a circle's symmetric key. Backend route:
    /// POST /api/v1/circles/:id/rotate-keys. Server CAS-serializes
    /// concurrent rotations against expectedKeyVersion.
    func rotateKeys(circleId: String, request: RotateKeysRequest) async throws -> RotateKeysResponse {
        return try await post(path: "/api/v1/circles/\(circleId)/rotate-keys", body: request)
    }

    /// Invite a user by email. Backend route: POST /api/v1/circles/:id/invite/email.
    /// A known invitee is given the circle key pre-encrypted when both
    /// `encryptedCircleKey` and `ephemeralPublicKey` are supplied.
    func inviteByEmail(circleId: String, request: InviteByEmailRequest) async throws -> EmptyResponse {
        return try await post(path: "/api/v1/circles/\(circleId)/invite/email", body: request)
    }

    /// Which of these statements, signed by this account, the server holds
    /// in the circle (a pending invitation, a member's invitation, or this
    /// account's vouch), read from the primary in one snapshot. At most 20
    /// ids, 16 bytes of hex each; one not held, not this account's, or
    /// unknown is simply absent.
    func statementsHeld(circleId: String, statementIds: [String]) async throws -> [HeldStatement] {
        let response: HeldStatementsResponse = try await post(
            path: "/api/v1/circles/\(circleId)/statements/held",
            body: HeldStatementsRequest(statementIds: statementIds))
        return response.held
    }

    /// Atomically eject a member and rotate the circle key for the survivors.
    /// Backend route: POST /api/v1/circles/:id/members/eject-and-rotate.
    ///
    /// This is the ONLY way to remove somebody else. `DELETE /members/:user_id`
    /// answers 410 Gone, because a delete that is not atomic with the rotation
    /// leaves a window in which the ejected member is off the roster but still
    /// holds a live circle key.
    func ejectAndRotate(
        circleId: String,
        request: EjectAndRotateRequest
    ) async throws -> EjectAndRotateResponse {
        return try await post(
            path: "/api/v1/circles/\(circleId)/members/eject-and-rotate",
            body: request
        )
    }

    /// Remove a member WITHOUT rotating the circle key.
    /// Backend route: POST /api/v1/circles/:id/members/:user_id/revoke-access.
    ///
    /// Only for when `ejectAndRotate` has actually failed. It needs a fresh
    /// wrap for every remaining member, which a survivor with an unverified key
    /// change or an unresolvable identity key makes impossible — without this,
    /// nobody could be removed from the circle at all.
    ///
    /// The member is off the roster immediately; the key they already hold is
    /// unchanged, so what they already downloaded stays readable to them. The
    /// server says so in `warning` and that is the sentence to show.
    func revokeMemberAccess(circleId: String, userId: String) async throws -> RevokeAccessResponse {
        return try await post(
            path: "/api/v1/circles/\(circleId)/members/\(userId)/revoke-access",
            body: EmptyBody()
        )
    }

    /// Owner-only role change. Backend route:
    /// PUT /api/v1/circles/:id/members/:user_id/role.
    func updateMemberRole(circleId: String, userId: String, role: String) async throws -> EmptyResponse {
        return try await put(
            path: "/api/v1/circles/\(circleId)/members/\(userId)/role",
            body: UpdateMemberRoleRequest(role: role)
        )
    }

    /// The owner's hand-over on the server alone: POST
    /// /api/v1/circles/:id/transfer-ownership (owner only, to an active member;
    /// the outgoing owner becomes a member). On a circle whose records' owner
    /// is this account the record goes first instead: rotate-keys with
    /// `transfer_to` (`CircleManager.handOver`).
    func transferOwnership(circleId: String, newOwnerId: String) async throws -> EmptyResponse {
        return try await post(
            path: "/api/v1/circles/\(circleId)/transfer-ownership",
            body: TransferOwnershipRequest(newOwnerId: newOwnerId)
        )
    }

    // MARK: - Circle Ownership Claims

    /// The live claim on a circle's ownership, or nil when there is none.
    /// Backend route: GET /api/v1/circles/:id/claim-ownership.
    ///
    /// Readable by ANY active member on purpose (the server allows owner, admin
    /// and member): a circle changing hands is not a private negotiation
    /// between two people, since everybody in it is about to have a different
    /// person able to delete it.
    ///
    /// The server reads it from the primary rather than a replica, so the
    /// claim an admin has just opened reads back immediately instead of
    /// looking like the POST failed.
    func getOwnershipClaim(circleId: String) async throws -> OwnershipClaimResponse? {
        let envelope: OwnershipClaimEnvelope = try await get(
            path: "/api/v1/circles/\(circleId)/claim-ownership"
        )
        return envelope.data
    }

    /// "No live claim" is a SUCCESSFUL answer carrying `data: null`.
    /// `decodeResponse` cannot express that: it unwraps `data`, and a null one
    /// falls through to a direct decode of the whole body, which throws. So
    /// decode the envelope itself, exactly as `SelfKeyEnvelope` does for the
    /// self key.
    ///
    /// `success` is deliberately REQUIRED for the same reason it is there:
    /// `decodeResponse` tries `APIResponse<T>` first, which would hand this type
    /// the *inner* claim object, and without a mandatory key of its own it would
    /// decode from that happily and report "no claim" for a claim that is
    /// live — an owner shown nothing to refuse while the countdown runs.
    struct OwnershipClaimEnvelope: Decodable {
        let success: Bool
        let data: OwnershipClaimResponse?
    }

    /// Ask to take over a circle whose owner cannot act.
    /// Backend route: POST /api/v1/circles/:id/claim-ownership → 201.
    ///
    /// Server-side this is admin-only, and the client deliberately does NOT
    /// pre-judge that: the server is the authority and its refusal is what the
    /// caller shows. A second claim on the same circle is refused with 409 +
    /// `circle_ownership_claim_exists`.
    func claimOwnership(circleId: String) async throws -> OwnershipClaimResponse {
        return try await post(
            path: "/api/v1/circles/\(circleId)/claim-ownership",
            body: EmptyBody()
        )
    }

    /// The owner's veto. Backend route:
    /// POST /api/v1/circles/:id/claim-ownership/refuse.
    ///
    /// Permanent — a refused claim is never reopened. 403 when the caller is not
    /// the owner, 404 when there is no live claim (which is also what a second
    /// tap on a refusal that already landed returns).
    @discardableResult
    func refuseOwnershipClaim(circleId: String) async throws -> EmptyResponse {
        return try await post(
            path: "/api/v1/circles/\(circleId)/claim-ownership/refuse",
            body: EmptyBody()
        )
    }

    /// The claimant changing their mind. Backend route:
    /// DELETE /api/v1/circles/:id/claim-ownership.
    ///
    /// Distinct from the owner's refusal forever after: "the admin thought
    /// better of it" and "the owner said no" are different facts about the same
    /// circle. 404 when the caller has no live claim of their own.
    @discardableResult
    func withdrawOwnershipClaim(circleId: String) async throws -> EmptyResponse {
        return try await delete(path: "/api/v1/circles/\(circleId)/claim-ownership")
    }

    /// Pending invites the current user has received but not yet acted on.
    /// Backend route: GET /api/v1/invites/received.
    func receivedInvites() async throws -> [ReceivedInviteResponse] {
        // Server returns `{ success, data: [...] }` — a bare array,
        // NOT the `{ items, has_more, next_cursor }` Paginated
        // envelope. Using getPaginated here silently throws a
        // decode error every call, which the catch in
        // InvitesManager.refresh swallows behind a #if DEBUG print,
        // leaving the cached list empty no matter how many 200s
        // the server returns. An invitation to an id no circle has is
        // dropped, the rest read (`ServedEntries`).
        let received: ServedEntries<ReceivedInviteResponse> = try await get(path: "/api/v1/invites/received")
        return received.items
    }

    /// Invites this circle has SENT and nobody has acted on yet. Owner/admin
    /// only — the server allows only those roles and answers 403 for a plain
    /// member, so gate the UI the same way rather than showing a section that
    /// always errors.
    ///
    /// Backend route: GET /api/v1/circles/:id/invites. Returns only invites
    /// that are still pending AND unexpired, so anything in this list is
    /// genuinely revocable.
    func pendingInvites(circleId: String) async throws -> [PendingInviteResponse] {
        return try await get(path: "/api/v1/circles/\(circleId)/invites")
    }

    /// Withdraw an invite that has not been accepted. Owner/admin only.
    /// Backend route: DELETE /api/v1/circles/:id/invites/:invite_id. The server
    /// marks it revoked, so the recipient can no longer join.
    ///
    /// 404 means the invite was already accepted, declined or revoked — treat it
    /// as done, not as a failure.
    @discardableResult
    func revokeInvite(circleId: String, inviteId: String) async throws -> EmptyResponse {
        return try await delete(path: "/api/v1/circles/\(circleId)/invites/\(inviteId)")
    }

    /// Replace a pending ACCOUNT invitation's statement after "Is this really
    /// {email}?" → "It's them". The statement keeps the original's id, times
    /// and user id and binds the keys the question showed (sdk
    /// `renewInvitation`); the wrap, when there is one, is for exactly those
    /// keys.
    func renewInvitation(circleId: String, inviteId: String,
                         request: RenewInvitationRequest) async throws -> RenewInvitationResponse {
        try await put(path: "/api/v1/circles/\(circleId)/invites/\(inviteId)/statement", body: request)
    }

    /// Accept a received invite. Backend route: POST /api/v1/invites/:id/accept.
    /// `encryptedCircleKey` + `ephemeralPublicKey` are required for link-style
    /// invites where the inviter didn't already wrap the key for us.
    ///
    /// Server returns `{"success": true, "data": null}` on success — no
    /// CircleResponse object — so callers should re-fetch
    /// CircleManager.circles and match by the invite's `circleId` to
    /// find the freshly-promoted circle. Decoding the response into
    /// CircleResponse would throw (null data cannot be decoded into the
    /// required-fields struct).
    @discardableResult
    func acceptInvite(
        inviteId: String,
        encryptedCircleKey: EncryptedBlobRequest? = nil,
        ephemeralPublicKey: String? = nil,
        locationConsent: LocationConsentGrant?
    ) async throws -> EmptyResponse {
        let body = AcceptInviteRequest(
            encryptedCircleKey: encryptedCircleKey,
            ephemeralPublicKey: ephemeralPublicKey,
            locationConsent: locationConsent
        )
        return try await post(path: "/api/v1/invites/\(inviteId)/accept", body: body)
    }

    /// Decline a received invite. Backend route: POST /api/v1/invites/:id/decline.
    func declineInvite(inviteId: String) async throws -> EmptyResponse {
        return try await post(path: "/api/v1/invites/\(inviteId)/decline", body: EmptyBody())
    }

    // MARK: - Blocked people

    /// The people this account has blocked from inviting it to a circle.
    /// Backend route: GET /api/v1/invites/blocks (a bare list under `data`).
    func listBlockedPeople() async throws -> [BlockedPerson] {
        try await get(path: "/api/v1/invites/blocks")
    }

    /// Backend route: POST /api/v1/invites/block. The server trims and lowers
    /// the address, refuses one's own, and answers the same whether or not it
    /// belongs to an account.
    func blockPerson(email: String) async throws -> EmptyResponse {
        try await post(path: Self.blockPersonPath, body: BlockPersonRequest(email: email))
    }

    /// Backend route: POST /api/v1/invites/unblock. The address goes in the
    /// BODY, like a block's, never in the path: a path is what a proxy's
    /// access log keeps, and every address a person unblocked would stand
    /// there in the clear.
    func unblockPerson(email: String) async throws -> EmptyResponse {
        try await post(path: Self.unblockPersonPath, body: BlockPersonRequest(email: email))
    }

    /// The two paths, as constants so that a test can say what neither holds:
    /// an address, or a place for one.
    nonisolated static let blockPersonPath = "/api/v1/invites/block"
    nonisolated static let unblockPersonPath = "/api/v1/invites/unblock"

    /// This invitation does not name this account as it is now. The server
    /// marks it and wakes who can renew it; only the addressee may report
    /// (404 `invite_not_found` otherwise).
    func reportInviteMismatch(inviteId: String) async throws {
        let _: EmptyResponse = try await post(path: "/api/v1/invites/\(inviteId)/mismatch", body: EmptyBody())
    }

    // MARK: - Notifications

    /// Cursor-paginated list of notifications for the current user.
    /// Backend route: GET /api/v1/notifications.
    func listNotifications(
        limit: Int = 50,
        cursor: String? = nil,
        unreadOnly: Bool = false
    ) async throws -> NotificationsListResponse {
        var query = "limit=\(limit)&unread_only=\(unreadOnly)"
        if let cursor = cursor {
            query += "&cursor=\(Self.queryValue(cursor))"
        }
        return try await get(path: "/api/v1/notifications?\(query)")
    }

    /// Count of unread notifications for the current user.
    /// Backend route: GET /api/v1/notifications/unread-count.
    func unreadNotificationCount() async throws -> UnreadCountResponse {
        return try await get(path: "/api/v1/notifications/unread-count")
    }

    /// Mark a notification as read. Backend route:
    /// POST /api/v1/notifications/:id/read.
    func markNotificationRead(notificationId: String) async throws -> EmptyResponse {
        return try await post(
            path: "/api/v1/notifications/\(notificationId)/read",
            body: EmptyBody()
        )
    }

    /// Mark all notifications as read. Backend route:
    /// POST /api/v1/notifications/read-all.
    func markAllNotificationsRead() async throws -> EmptyResponse {
        return try await post(path: "/api/v1/notifications/read-all", body: EmptyBody())
    }

    /// Delete a notification. Backend route:
    /// DELETE /api/v1/notifications/:id.
    func deleteNotification(notificationId: String) async throws -> EmptyResponse {
        return try await delete(path: "/api/v1/notifications/\(notificationId)")
    }

    // MARK: - Notification Preferences
    //
    // Global delivery-channel preferences (push / email / SMS / quiet
    // hours / per-category overrides). Mirrors the web Global Delivery →
    // Email switch and the Android app, which reads/writes the
    // whole preferences object via GET/PUT.
    //
    // The `category_preferences` field is arbitrary server-defined JSON,
    // so we deliberately DON'T model the object as a fixed Codable
    // struct — a read-modify-write through `[String: Any]` preserves
    // every field (including per-category overrides + quiet hours) that
    // the iOS UI doesn't surface, instead of silently dropping them on
    // the PUT.

    /// Fetch the current user's notification preferences as a raw map.
    /// Backend route: GET /api/v1/notifications/preferences. Pulls the
    /// `data` object out of the `{success, data, error}` envelope.
    func getNotificationPreferences() async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: config.apiBaseURL + "/api/v1/notifications/preferences")!)
        request.httpMethod = "GET"
        try addHeaders(to: &request, auth: true)
        let data = try await executeRaw(request)
        let json = try JSONSerialization.jsonObject(with: data)
        // Envelope: { success, data: {...}, error }. The preferences live
        // under `data`; anything else is a malformed response.
        guard let envelope = json as? [String: Any],
              let prefs = envelope["data"] as? [String: Any] else {
            throw APIError(code: "decode_failed", message: "Unexpected notification-preferences shape")
        }
        return prefs
    }

    /// Read-modify-write the full notification preferences object.
    /// Backend route: PUT /api/v1/notifications/preferences — the body is
    /// the FULL preferences map so per-category overrides + quiet hours
    /// are preserved (mirrors the Android app).
    func updateNotificationPreferences(_ prefs: [String: Any]) async throws {
        var request = URLRequest(url: URL(string: config.apiBaseURL + "/api/v1/notifications/preferences")!)
        request.httpMethod = "PUT"
        request.httpBody = try JSONSerialization.data(withJSONObject: prefs)
        try addHeaders(to: &request, auth: true)
        _ = try await executeRaw(request)
    }

    // MARK: - Support

    /// Open a support conversation. Backend route:
    /// POST /api/v1/support/ticket — lives on the auth API host
    /// (auth.pingolin.com), not the track API. Authenticated; the server
    /// resolves the user from the access token.
    /// Category is hardcoded to "track" to match the Android app.
    func submitSupportTicket(subject: String, message: String) async throws -> SupportTicketResponse {
        let request = SupportTicketRequest(
            subject: subject,
            message: message,
            category: "track"
        )
        return try await post(
            path: "/api/v1/support/ticket",
            body: request,
            baseURL: config.authBaseURL
        )
    }

    // MARK: - Account

    /// Permanently delete the current account. Backend route:
    /// DELETE /api/v1/auth/me on the auth API. Carries a short-lived
    /// `reauth_token` minted by the SRP step-up (reauthStep1/step2) in
    /// place of the raw password, plus an optional list of per-circle
    /// (circleId, userPseudonym) pairs so the backend can purge the
    /// user's location rows GDPR-compliantly.
    func deleteAccount(
        reauthToken: String,
        pseudonyms: [DeletionPseudonymRequest],
        forfeitCreditBalance: Bool = false
    ) async throws -> DeleteAccountResponse {
        let body = DeleteAccountRequest(
            reauthToken: reauthToken,
            pseudonyms: pseudonyms,
            forfeitCreditBalance: forfeitCreditBalance ? true : nil
        )
        return try await delete(
            path: "/api/v1/auth/me",
            body: body,
            baseURL: config.authBaseURL
        )
    }

    /// One page of GET /api/v1/export (GDPR Article 20).
    ///
    /// Day buckets are days since the Unix epoch; omitting them exports the last
    /// 30 days. `include` names the sections still being paged — a section that
    /// has finished is dropped from it, so the server stops re-sending its last
    /// page. `cursors` is the per-section keyset position, built by
    /// `DataExportService.cursors(from:)`.
    func exportData(
        startDayBucket: Int?,
        endDayBucket: Int?,
        include: Set<String>,
        includePreferences: Bool,
        cursors: [String: String]
    ) async throws -> DataExportResponse {
        let params = Self.exportQueryParams(
            startDayBucket: startDayBucket, endDayBucket: endDayBucket,
            include: include, includePreferences: includePreferences, cursors: cursors
        )
        return try await get(path: "/api/v1/export", queryParams: params)
    }

    /// The query of one export page: what `exportData` sends. Its own function
    /// so that a test can read what a request says without a network.
    static func exportQueryParams(
        startDayBucket: Int?,
        endDayBucket: Int?,
        include: Set<String>,
        includePreferences: Bool,
        cursors: [String: String]
    ) -> [String: String] {
        var params: [String: String] = [:]
        if let s = startDayBucket { params["start_day_bucket"] = String(s) }
        if let e = endDayBucket { params["end_day_bucket"] = String(e) }
        params["include_devices"] = include.contains("devices") ? "true" : "false"
        params["include_circles"] = include.contains("circles") ? "true" : "false"
        params["include_places"] = include.contains("places") ? "true" : "false"
        params["include_check_ins"] = include.contains("check_ins") ? "true" : "false"
        params["include_locations"] = include.contains("locations") ? "true" : "false"
        params["include_alerts"] = include.contains("alerts") ? "true" : "false"
        params["include_alert_rules"] = include.contains("alert_rules") ? "true" : "false"
        params["include_inactivity_alerts"] = include.contains("inactivity_alerts") ? "true" : "false"
        params["include_privacy"] = include.contains("privacy") ? "true" : "false"
        params["include_preferences"] = includePreferences ? "true" : "false"
        // Explicit rather than relying on the server's default-true,
        // so the request and the file stay honest about the same list.
        // profile is a singleton with no cursor and no has_more, so it
        // is not part of the paging set and is simply asked for every
        // page; merge keeps the first.
        params["include_profile"] = "true"
        params["include_circle_invites"] = include.contains("circle_invites") ? "true" : "false"
        params["include_alert_events"] = include.contains("alert_events") ? "true" : "false"
        params["include_place_shares"] = include.contains("place_shares") ? "true" : "false"
        params["include_web_push_subscriptions"] = include.contains("web_push_subscriptions") ? "true" : "false"
        params["include_boundary_events"] = include.contains("boundary_events") ? "true" : "false"
        params["include_destinations"] = include.contains("destinations") ? "true" : "false"
        params["include_circle_notifications"] = include.contains("circle_notifications") ? "true" : "false"
        params["include_notification_history"] = include.contains("notification_history") ? "true" : "false"
        params["include_circle_activity"] = include.contains("circle_activity") ? "true" : "false"
        // Format 1.9. Explicit for another reason than the lines above: this is
        // the one section the server does NOT serve unless it is asked for.
        params["include_blocked_people"] = include.contains("blocked_people") ? "true" : "false"
        params.merge(cursors) { _, new in new }
        return params
    }

    // MARK: - Premium

    /// Effective premium entitlement — own subscription OR
    /// circle-derived (any member of a circle the user belongs to is
    /// subscribed). Backend route: GET /api/v1/users/me/premium.
    /// Mirrors the Android app. The only word on Track's plan: a failure
    /// keeps the last-known value (`PremiumManager.refresh`).
    func getPremiumStatus() async throws -> PremiumStatusResponse {
        return try await get(path: "/api/v1/users/me/premium")
    }

    /// May this account buy `product` through the App Store right now?
    ///
    /// Consulted before the purchase sheet is shown. The server refuses when a
    /// live WEB subscription already covers the product, because buying again
    /// would charge the customer twice and we cannot cancel the web one on their
    /// behalf from here.
    func getApplePurchaseEligibility(product: String) async throws -> ApplePurchaseEligibility {
        return try await get(
            path: "/api/v1/billing/apple/eligibility",
            queryParams: ["product": product],
            baseURL: config.authBaseURL)
    }

    /// Report a completed App Store purchase so the subscription exists without
    /// waiting for Apple's server notification.
    ///
    /// The notification remains the authority; this only closes the gap where a
    /// customer who has just paid would otherwise still see the free tier. Both
    /// write the same row by the same key, so arriving twice changes nothing.
    func linkApplePurchase(signedTransaction: String) async throws -> SubscriptionInfo {
        struct Body: Encodable { let signedTransaction: String }
        return try await post(
            path: "/api/v1/billing/apple/link",
            body: Body(signedTransaction: signedTransaction),
            baseURL: config.authBaseURL)
    }

    /// Per-user usage + entitlements for the Settings Plan card — tier,
    /// where premium comes from, and current/limit counts for places,
    /// circles and place alerts (counted the same way the enforcement
    /// gates count). Backend route: GET /api/v1/quota. Mirrors the Note iOS
    /// app's `getQuota()`.
    func getQuota() async throws -> TrackQuotaUsage {
        return try await get(path: "/api/v1/quota")
    }

    // MARK: - Devices
    //
    // The user-facing Devices list comes from the auth server's
    // sessions. createDevice + updateDevicePushToken register this
    // device and its push token with the track server during
    // onboarding, which is what push delivery fans out from.
    // DeviceManagementView talks to listSessions() /
    // revokeSession(). Mirrors the Android app.

    /// Backend route: POST /api/v1/devices.
    func createDevice(request: CreateDeviceRequest) async throws -> DeviceResponse {
        return try await post(path: "/api/v1/devices", body: request)
    }

    /// Backend route: PUT /api/v1/devices/:id/push-token.
    func updateDevicePushToken(deviceId: String, request: UpdatePushTokenRequest) async throws -> EmptyResponse {
        return try await put(path: "/api/v1/devices/\(deviceId)/push-token", body: request)
    }

    // MARK: - Sessions (= Devices)
    //
    // On the auth server a session IS the device record from the
    // user's perspective: trust lifecycle owner, user-visible label,
    // revoke surface. Push tokens hang off sessions via session_id.
    // The iOS Devices screen surfaces sessions; revoke + rename are
    // scoped to the session, not the legacy device row.

    /// Backend route: GET /api/v1/auth/sessions on the auth API.
    /// `auth: true` includes the bearer; the request hits authBaseURL
    /// instead of the default track apiBaseURL.
    func listSessions() async throws -> SessionsListResponse {
        return try await get(path: "/api/v1/auth/sessions", baseURL: config.authBaseURL)
    }

    /// Backend route: PATCH /api/v1/auth/sessions/:id on the auth
    /// API. Renames the user-visible label that appears in the
    /// Devices section. Pass nil deviceName to clear the override
    /// (server falls back to the auto-detected User-Agent string).
    func renameSession(sessionId: String, deviceName: String?) async throws -> EmptyResponse {
        return try await patch(
            path: "/api/v1/auth/sessions/\(sessionId)",
            body: RenameSessionRequest(deviceName: deviceName),
            baseURL: config.authBaseURL
        )
    }

    /// Backend route: POST /api/v1/auth/logout on the auth API. Ends THIS
    /// session: the server revokes it and deactivates the push registrations
    /// tied to it — so a signed-out phone stops getting the account's pushes,
    /// and the device id the next sign-in mints does not leave the old
    /// registration delivering every push a second time.
    ///
    /// The body names the session by its refresh token, so a sign-out whose
    /// access token has expired still ends it (auth finds the session by that
    /// token, current or just retired). The Bearer goes too when there is
    /// one. Nothing is refreshed first, and a 401 is never refreshed and
    /// retried (`neverRefreshed`): a sign-out mints nothing.
    func logout(refreshToken: String?) async throws -> EmptyResponse {
        try await post(path: Self.logoutPath, body: LogoutRequest(refreshToken: refreshToken),
                       auth: keychain.getString(for: .accessToken) != nil, baseURL: config.authBaseURL)
    }

    nonisolated static let logoutPath = "/api/v1/auth/logout"

    /// Requests a 401 does not refresh and retry: the sign-out (above).
    nonisolated static func neverRefreshed(path: String?) -> Bool {
        path == logoutPath
    }

    /// Backend route: DELETE /api/v1/auth/sessions/:id on the auth
    /// API. Revokes the session; the server then deactivates the
    /// push registration tied to it on its next delivery.
    func revokeSession(sessionId: String) async throws -> EmptyResponse {
        return try await delete(path: "/api/v1/auth/sessions/\(sessionId)", baseURL: config.authBaseURL)
    }

    /// Family-tracker-only device list. Same caller as `listSessions`,
    /// but the track server lists only devices with an active push
    /// registration, so the response only includes devices that
    /// actually push location. Web logins, Note app sessions, admin
    /// dashboards never appear here — those are surfaced on the
    /// account dashboard's Security page. Mirrors the Android app's
    /// `TrackApi.listTrackingDevices`.
    func listTrackingDevices() async throws -> [TrackingDevice] {
        return try await get(path: "/api/v1/tracking-devices")
    }

    /// Whether sign-outs are currently being enforced.
    ///
    /// Track's revocation check fails OPEN when auth is unreachable (refusing
    /// would be worse), and this is how that stops being silent. Read the
    /// tense: `enforcing == false` means we could not confirm a session had
    /// ended RECENTLY, not that a service is down right now. The copy on the
    /// devices screen must match that, or it claims a diagnosis nobody has.
    func revocationStatus() async throws -> RevocationStatus {
        return try await get(path: "/api/v1/security/revocation-status")
    }

    // MARK: - Attestation (App Attest)

    /// Backend route: GET /api/v1/auth/attest/challenge?platform=apple.
    /// Returns a server-generated nonce we feed into DCAppAttestService
    /// .attestKey() so the resulting attestation object proves freshness.
    /// Lives on the auth API host. Does not need an access token. Server
    /// requires the `platform` query param to pick the right verifier
    /// (apple vs play-integrity).
    func getAttestationChallenge() async throws -> AttestationChallengeResponse {
        return try await get(
            path: "/api/v1/auth/attest/challenge?platform=apple",
            auth: false,
            baseURL: config.authBaseURL
        )
    }

    /// Backend route: POST /api/v1/auth/attest/apple.
    /// Sends the App Attest object + challenge + key_id; server verifies
    /// against Apple's root cert and issues an attestation_token to echo
    /// on subsequent register/login as X-Attestation-Token.
    func verifyAppleAttestation(
        attestation: String,
        challenge: String,
        keyId: String
    ) async throws -> AttestationVerifyResponse {
        let request = AppleAttestVerifyRequest(
            attestation: attestation,
            challenge: challenge,
            keyId: keyId
        )
        return try await post(
            path: "/api/v1/auth/attest/apple",
            body: request,
            auth: false,
            baseURL: config.authBaseURL
        )
    }

    /// The circle's roster, and whether it is COMPLETE.
    ///
    /// Asks for the server's largest page (100; the default is 50) and reports
    /// `complete == false` when the server says there is more. Anything that
    /// acts on who is NOT on the roster — retiring pins, forgetting approvals,
    /// the hidden-member check before a rotation — must only trust a complete
    /// one: a second page read as "they left" would retire real members.
    func getCircleRoster(circleId: String) async throws -> (members: [CircleMemberResponse], complete: Bool) {
        let page: Paginated<CircleMemberResponse> = try await get(
            path: "/api/v1/circles/\(circleId)/members",
            queryParams: ["limit": "100"]
        )
        return (page.items, page.hasMore != true)
    }

    func inviteToCircle(circleId: String) async throws -> InviteCodeResponse {
        return try await post(path: "/api/v1/circles/\(circleId)/invite", body: EmptyBody())
    }

    /// Identities the user recovered after a password reset. Empty for almost
    /// every account; see PreviousIdentityLoader.
    ///
    /// baseURL is the AUTH host, not track's: this route lives on the auth
    /// server, and the track server has no `/api/v1/auth/*` routes at all, so
    /// without the override every call 404s. That failure would be silent,
    /// because PreviousIdentityLoader.ensureLoaded catches and returns 0, the
    /// correct answer for almost every account — yet this endpoint is what
    /// lets a user who reset their password still read their pre-reset data.
    /// Every other auth-hosted call here passes config.authBaseURL too; see
    /// srpStep1.
    func getPreviousIdentities() async throws -> [PreviousIdentityResponse] {
        let response: PreviousIdentitiesResponse = try await get(
            path: "/api/v1/auth/previous-identities",
            baseURL: config.authBaseURL
        )
        return response.identities
    }

    /// Does the account have data from before an email password reset that the
    /// account portal can restore? True when auth lists at least one archived,
    /// still-usable recovery key — the same list that makes the portal's
    /// Settings show "Data from before your password reset". Used only to pick
    /// the explanation on a locked circle.
    ///
    /// Auth host, authenticated, and rate limited there (20/hour), so
    /// CircleManager asks once per session. The entries carry wrapped key
    /// material that is inert without the recovery key; only the count is kept.
    func hasPreResetDataToRestore() async throws -> Bool {
        let response: ArchivedRecoveryListResponse = try await get(
            path: "/api/v1/auth/archived-recovery",
            baseURL: config.authBaseURL
        )
        return !response.archived.isEmpty
    }

    func getCircleKeys() async throws -> [CircleKeyResponse] {
        // GET /api/v1/circles/keys returns a BARE array in `data`, NOT
        // the {items, has_more, next_cursor} pagination envelope.
        // Routing through `get` lets decodeResponse try APIResponse<T>
        // first (T = [CircleKeyResponse]), pulling the array straight
        // out of `.data`. getPaginated would decode Paginated<T>
        // (expects `items`) and ALWAYS throw here, so historical circle
        // keys would never be imported, and after any rotation
        // old-version ciphertext (and its places) would go
        // undecryptable AND unmonitored.
        return try await get(path: "/api/v1/circles/keys")
    }

    func updatePrivacySettings(circleId: String, settings: PrivacySettingsRequest) async throws -> EmptyResponse {
        return try await put(path: "/api/v1/privacy/circles/\(circleId)", body: settings)
    }

    /// Backend route: GET /api/v1/privacy/circles/:id.
    func getPrivacySettings(circleId: String) async throws -> PrivacySettingsResponse {
        return try await get(path: "/api/v1/privacy/circles/\(circleId)")
    }

    /// Backend route: POST /api/v1/privacy/circles/:id/resume. Ends a pause the
    /// way a timed expiry does, back to the mode held before it, and answers
    /// with the row exactly as GET does. A row that isn't paused comes back as it is.
    func resumePrivacySharing(circleId: String) async throws -> PrivacySettingsResponse {
        return try await post(path: "/api/v1/privacy/circles/\(circleId)/resume", body: EmptyBody())
    }

    // MARK: - Location Endpoints

    /// Fetch a circle's location history. Backend route:
    /// GET /api/v1/circles/:circle_id/locations?start_day_bucket=&end_day_bucket=
    ///
    /// Returns the WHOLE wrapper rather than a flattened `[LocationResponse]`:
    /// `history_days_allowed` is the field that lets a client distinguish a
    /// plan boundary from missing data, and flattening would discard it with
    /// the rest of the envelope before any caller could see it.
    ///
    /// The server accepts `start_day_bucket` and `end_day_bucket` (days since
    /// unix epoch, i32) — *not* raw start_time/end_time. We compute the
    /// buckets locally from the caller's Date range so an iOS range chip like
    /// "7d" maps to start_day_bucket = today - 6, end_day_bucket = today
    /// instead of silently falling back to the server default
    /// (yesterday-today).
    func getLocationHistory(
        circleId: String,
        startTime: Date,
        endTime: Date,
        userId: String? = nil
    ) async throws -> HistoryLocationsResponse {
        let startBucket = Self.dayBucket(startTime)
        let endBucket = Self.dayBucket(endTime)
        // One member's rows (`user_id`, a circle's history only).
        let member = CanonicalId.of(userId).map { "&user_id=\($0)" } ?? ""
        return try await get(
            path: "/api/v1/circles/\(circleId)/locations?start_day_bucket=\(startBucket)&end_day_bucket=\(endBucket)\(member)"
        )
    }

    /// Days since the unix epoch — the backend's `start_day_bucket` /
    /// `end_day_bucket` unit. Exposed (and static) because the caller has to
    /// measure the range it ASKED for in the same unit the server answers in,
    /// and a second copy of this arithmetic elsewhere would drift.
    nonisolated static func dayBucket(_ date: Date) -> Int {
        let msPerDay: Int64 = 86_400_000
        return Int(Int64(date.timeIntervalSince1970 * 1000) / msPerDay)
    }

    /// Fetch the latest known location per circle member. Backend route:
    /// GET /api/v1/circles/:circle_id/locations/latest. Returns the wrapper
    /// so callers can also inspect key-rotation status.
    func getLatestLocations(circleId: String) async throws -> LatestLocationsResponse {
        return try await get(path: "/api/v1/circles/\(circleId)/locations/latest")
    }

    /// This account's frozen last location in the circle, sealed again under the
    /// circle's current key (`LastKnownReseal`). Backend route:
    /// POST /api/v1/circles/:circle_id/locations/last-known/reseal. Every refusal,
    /// whatever its reason, is the one 404; the same request again answers 200.
    func resealLastKnown(circleId: String, body: ResealLastKnownRequest) async throws -> ResealLastKnownResponse {
        return try await post(path: "/api/v1/circles/\(circleId)/locations/last-known/reseal", body: body)
    }

    /// `fetchSessionKey`, below: fetch a peer's active session key for
    /// `sessionKeyId` and import it into the SDK so session-key-sealed location
    /// rows decrypt. A location row whose `key_id` starts with "s:" (e.g. the
    /// Android app's manual "send now" via `encryptLocationWithSessionKeyBound`)
    /// seals its ciphertext directly under the circle's active SESSION key —
    /// without the imported peer key that member silently vanishes from the map
    /// until their next envelope row.
    ///
    /// Backend route: GET /api/v1/circles/:circle_id/session-keys/:session_key_id.
    /// The server keys it by the bare UUID, so strip the "s:" routing prefix for
    /// the path. The SDK cache is keyed by the circle and that same bare uuid —
    /// its readers (`hasPeerSessionKeyFor` and the decrypt resolver) strip an
    /// "s:" prefix, so either form may be handed to them. `circleId` is the
    /// on-wire circle id — for self-tracking that is already the all-zero uuid
    /// (`SelfKeyManager.selfCircleUuid`), so no remap is needed (web maps its
    /// own "self" sentinel; iOS carries the uuid directly).
    ///
    /// Returns true only on a successful import. Fails CLOSED: any network /
    /// decode / import error returns false so the caller drops the row rather
    /// than surfacing plaintext. Mirrors the web app and the Android app's
    /// getSessionKey + importPeerSessionKey.
    ///
    /// `sessionKeyIdToImport`: the id a fetched session key is imported under:
    /// the bare id requested, when the answer names that same id (one "s:"
    /// stripped from each, no case folding); nil for an answer naming another.
    nonisolated static func sessionKeyIdToImport(requested: String, answered: String) -> String? {
        func bare(_ id: String) -> String { id.hasPrefix("s:") ? String(id.dropFirst(2)) : id }
        let id = bare(requested)
        guard !id.isEmpty, bare(answered) == id else { return nil }
        return id
    }

    @discardableResult
    func fetchSessionKey(circleId: String, sessionKeyId: String) async -> Bool {
        let apiKeyId = sessionKeyId.hasPrefix("s:") ? String(sessionKeyId.dropFirst(2)) : sessionKeyId
        do {
            let resp: SessionKeyResponse = try await get(
                path: "/api/v1/circles/\(circleId)/session-keys/\(apiKeyId)"
            )
            // RFC3339 expires_at → epoch seconds for the SDK cache TTL. Fall back
            // to +6h when it can't be parsed (matches the Android app's default).
            let expiresAtSecs: Int64 = {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let date = formatter.date(from: resp.expiresAt)
                    ?? ISO8601DateFormatter().date(from: resp.expiresAt) {
                    return Int64(date.timeIntervalSince1970)
                }
                return Int64(Date().timeIntervalSince1970) + 21_600
            }()
            // Import under the id REQUESTED, the one the row names,
            // and only when the answer is for that id: an answer
            // naming another id would take that entry's place in the
            // cache. Every SDK reader of the peer cache normalizes
            // the "s:" read prefix internally, so the prefixed
            // `key_id` a row carries resolves to this entry too.
            guard let importId = Self.sessionKeyIdToImport(requested: sessionKeyId, answered: resp.sessionKeyId) else {
                print("[Track] fetchSessionKey: the answer names another session key; not imported")
                return false
            }
            try SDKCrypto.cryptoManager.importPeerSessionKey(
                circleId: circleId,
                sessionKeyId: importId,
                encryptedSessionKey: resp.encryptedSessionKey,
                keyNonce: resp.keyNonce,
                keyVersion: Int32(resp.keyVersion),
                expiresAtSecs: expiresAtSecs
            )
            return true
        } catch {
            #if DEBUG
            print("[Track] fetchSessionKey failed for \(sessionKeyId) circle \(circleId): \(error)")
            #endif
            return false
        }
    }

    // MARK: - Place Endpoints

    /// Every place the current user can see, across ALL their circles, as the
    /// raw array under `data` (NOT the paginated {items, has_more} envelope
    /// circles uses). Unfiltered — one row per place, each carrying its own
    /// requester-relevant wrap (self-key for owned, `wrap_via_circle` for
    /// received shares) plus the full `shared_circles` list. The geofencing
    /// path needs this union so a place shared to a NON-active circle still
    /// gets monitored; the per-circle UI list is derived via
    /// `getPlaces(circleId:)` / `PlaceManager`'s local filter.
    func getAllPlaces() async throws -> [PlaceResponse] {
        // Follow the server's pagination to EXHAUSTION. GET /places caps a
        // page at 50 by default and 100 at most — a single unpaginated call
        // silently truncates the union at 50, leaving places 51+ unmonitored
        // for geofencing. Page at the max size and stop on a short page.
        // Offset-based (the backend honors `offset` for backward
        // compatibility) to mirror the Android app's PlaceRepository exhaustion
        // loop. A later-page failure propagates like any other error, so the
        // caller (PlaceManager.loadPlaces) falls back to the last full cached
        // union rather than acting on a truncated live set.
        let pageSize = 100
        // Pages overlap and merge by id, so a place deleted
        // meanwhile can't push another one past a page boundary
        // unseen: to a waiting change a missing place reads as
        // deleted.
        let overlap = 20
        var offset = 0
        var all: [PlaceResponse] = []
        var ids = Set<String>()
        while true {
            let page: [PlaceResponse] = try await get(
                path: "/api/v1/places",
                queryParams: ["limit": "\(pageSize)", "offset": "\(offset)"]
            )
            for place in page where ids.insert(place.id).inserted {
                all.append(place)
            }
            if page.count < pageSize { break }
            offset += pageSize - overlap
            // Safety valve against a server that never returns a short page.
            if offset >= 10_000 { break }
        }
        return all
    }

    func getPlaces(circleId: String) async throws -> [PlaceResponse] {
        // Filter the union client-side: include places shared with the
        // requested circle (`shared_circles` contains the id) plus self-only
        // places (empty or nil).
        let all = try await getAllPlaces()
        return all.filter { PlaceResponse.isVisible(sharedCircles: $0.sharedCircles, in: circleId) }
    }

    /// POST returns a bare place id string (`"data": "<uuid>"`), not
    /// a full PlaceResponse — the client already has the cleartext
    /// it just sent, so the server doesn't echo the encrypted blobs
    /// back. Decode to String and let the caller build the Place
    /// model locally.
    func createPlace(circleId: String, request: CreatePlaceRequest) async throws -> String {
        return try await post(path: "/api/v1/places", body: request)
    }

    /// PUT returns no row (`"data": null`), not the updated place —
    /// same reasoning as `createPlace`: the client already has the cleartext.
    /// Decoding it as `PlaceResponse` would throw `keyNotFound("id")` after a
    /// SUCCESSFUL write, which would skip everything the caller does next —
    /// including `removeGeofence` + `syncMonitoredRegions()`, leaving
    /// CoreLocation monitoring the place's OLD ring.
    func updatePlace(placeId: String, request: UpdatePlaceRequest) async throws -> EmptyResponse {
        return try await put(path: "/api/v1/places/\(placeId)", body: request)
    }

    func deletePlace(placeId: String) async throws -> EmptyResponse {
        return try await delete(path: "/api/v1/places/\(placeId)")
    }

    /// Share a place: POST a new circle wrap of the place key. Mirrors
    /// the Android app's PlaceRepository.sharePlaceWithCircle. The server
    /// records the share; on the recipient's next /places
    /// fetch, the place appears with `wrap_via_circle = circleId` and
    /// the unwrap is via the receiving circle's key.
    func sharePlace(placeId: String, request: SharePlaceRequest) async throws -> EmptyResponse {
        return try await post(path: "/api/v1/places/\(placeId)/share", body: request)
    }

    /// Unshare a personal place: delete the circle wrap. The place
    /// row stays with its owner; only the per-circle visibility is
    /// removed.
    func unsharePlace(placeId: String, circleId: String) async throws -> EmptyResponse {
        return try await delete(path: "/api/v1/places/\(placeId)/share/\(circleId)")
    }

    // MARK: - Place Alerts

    /// Cursor-paginated list of place alerts created by the current user.
    /// Backend route: GET /api/v1/place-alerts. There is no place_id query
    /// filter on the server — callers that want per-place alerts
    /// should fetch the full list and group locally.
    func listPlaceAlerts(
        limit: Int = 50,
        cursorDayBucket: Int? = nil,
        cursorId: String? = nil
    ) async throws -> [PlaceAlertResponse] {
        var query = "limit=\(limit)"
        if let cdb = cursorDayBucket {
            query += "&cursor_day_bucket=\(cdb)"
        }
        if let cid = cursorId {
            query += "&cursor_id=\(Self.queryValue(cid))"
        }
        // NOT getPaginated: the server returns a BARE ARRAY here — it
        // accepts limit/cursor as INPUTS but does not wrap the result in a
        // paged envelope. getPaginated expects `data.items`, so every call
        // would throw `keyNotFound("items")`, and because callers use
        // `try?` that would be silent: no place alerts on iOS at all — no
        // bells, no arming from alerts, no subscriber-side evaluation, and
        // no rotation-hash heal.
        return try await get(path: "/api/v1/place-alerts?\(query)")
    }

    /// Backend route: DELETE /api/v1/place-alerts/:id.
    func deletePlaceAlert(alertId: String) async throws -> EmptyResponse {
        return try await delete(path: "/api/v1/place-alerts/\(alertId)")
    }

    // MARK: - Destinations

    /// List every active and historical destination the current user can see.
    /// Backend route: GET /api/v1/destinations. Returns a raw `data:
    /// [...]` array (not the paginated envelope), same shape as /places
    /// and /devices.
    func listDestinations() async throws -> [DestinationResponse] {
        return try await get(path: "/api/v1/destinations")
    }

    /// List destinations for a single circle. Backend route:
    /// GET /api/v1/circles/:circle_id/destinations.
    ///
    /// NOT getPaginated: the server returns a BARE array here, same as
    /// `listDestinations` above. getPaginated looks for `data.items`, so every
    /// call would throw `keyNotFound("items")`.
    func listCircleDestinations(circleId: String) async throws -> [DestinationResponse] {
        return try await get(path: "/api/v1/circles/\(circleId)/destinations")
    }

    /// Backend route: POST /api/v1/destinations.
    func createDestination(request: CreateDestinationRequest) async throws -> DestinationResponse {
        return try await post(path: "/api/v1/destinations", body: request)
    }

    /// Backend route: PUT /api/v1/destinations/:id (used to flip status to
    /// cancelled or update ETA / notification preference).
    func updateDestination(destinationId: String, request: UpdateDestinationRequest) async throws -> DestinationResponse {
        return try await put(path: "/api/v1/destinations/\(destinationId)", body: request)
    }

    /// Backend route: DELETE /api/v1/destinations/:id.
    func deleteDestination(destinationId: String) async throws -> EmptyResponse {
        return try await delete(path: "/api/v1/destinations/\(destinationId)")
    }

    /// Report arrival. Backend route: POST /api/v1/destinations/:id/arrive.
    /// Server uses event_type_hash (BLAKE3 of circle_key || "arrival") to
    /// route notifications without learning the event type.
    func reportDestinationArrival(
        destinationId: String,
        request: ReportArrivalRequest
    ) async throws -> ReportArrivalResponse {
        return try await post(path: "/api/v1/destinations/\(destinationId)/arrive", body: request)
    }

    // MARK: - Inactivity Alerts

    /// Backend route: GET /api/v1/inactivity-alerts.
    ///
    /// NOT getPaginated: the server returns a BARE array here, like
    /// `listCircleDestinations` and `listCircleCheckIns`. getPaginated would
    /// throw `keyNotFound("items")` on every load, and because
    /// `InactivityAlertsManager.refresh` assigns `alerts = try await …` the
    /// throw happens BEFORE the assignment, so the published list would stay
    /// empty and the Alerts screen would show no inactivity rule the user had
    /// ever created.
    func listInactivityAlerts() async throws -> [InactivityAlertResponse] {
        return try await get(path: "/api/v1/inactivity-alerts")
    }

    /// Returns only the new alert's id — the backend create responds with
    /// a bare id, not the full row (decoding it as the full
    /// response would throw). Callers re-fetch the list to get the row.
    func createInactivityAlert(request: CreateInactivityAlertRequest) async throws -> String {
        return try await post(path: "/api/v1/inactivity-alerts", body: request)
    }

    func updateInactivityAlert(alertId: String, request: UpdateInactivityAlertRequest) async throws -> InactivityAlertResponse {
        return try await put(path: "/api/v1/inactivity-alerts/\(alertId)", body: request)
    }

    func deleteInactivityAlert(alertId: String) async throws -> EmptyResponse {
        return try await delete(path: "/api/v1/inactivity-alerts/\(alertId)")
    }

    // No inactivity-EVENTS calls: the server serves no
    // `GET /api/v1/inactivity-events` or its `/dismiss`.

    // MARK: - Alert Rules (low-battery smart alerts)

    /// Every rule, every page (`getAllPages`).
    func listAlertRules() async throws -> [AlertRuleResponse] {
        return try await getAllPages(path: "/api/v1/alert-rules", id: { (rule: AlertRuleResponse) in rule.id }).items
    }

    /// Returns the new rule's id — create responds with the bare id.
    func createAlertRule(request: CreateAlertRuleRequest) async throws -> String {
        return try await post(path: "/api/v1/alert-rules", body: request)
    }

    func getAlertRule(ruleId: String) async throws -> AlertRuleResponse {
        return try await get(path: "/api/v1/alert-rules/\(ruleId)")
    }

    /// Report a firing this device decided on. See CreateAlertEventRequest.
    @discardableResult
    func createAlertEvent(request: CreateAlertEventRequest) async throws -> String {
        return try await post(path: "/api/v1/alert-events", body: request)
    }

    /// The self-alerts other members of my circles have asked me to watch.
    func listCircleSelfAlerts() async throws -> [CircleSelfAlertResponse] {
        return try await get(path: "/api/v1/inactivity-alerts/circle-self-alerts")
    }

    /// Ask the server to wake the people holding alert rules in this circle.
    ///
    /// Called by the WATCHED device when its own battery falls far enough to
    /// be worth someone looking. The body is the whole request — no level, no
    /// threshold, no target — and the reply carries no count, because how many
    /// people watch your battery is not something the server should tell you
    /// about yourself, let alone anyone else.
    func wakeWatchers(circleId: String) async throws -> EmptyResponse {
        return try await post(path: "/api/v1/alerts/wake-watchers",
                              body: WakeWatchersRequest(circleId: circleId))
    }

    /// Partial update (COALESCE server-side) — only the fields sent change.
    /// Returns unit; callers re-fetch for the row.
    func updateAlertRule(ruleId: String, request: UpdateAlertRuleRequest) async throws -> EmptyResponse {
        return try await put(path: "/api/v1/alert-rules/\(ruleId)", body: request)
    }

    func deleteAlertRule(ruleId: String) async throws -> EmptyResponse {
        return try await delete(path: "/api/v1/alert-rules/\(ruleId)")
    }

    /// Backend route: POST /api/v1/place-alerts. Returns a BARE alert id
    /// (`"data": "<uuid>"`), not a full row, exactly like `createPlace`.
    /// Declaring `PlaceAlertResponse` here would make every save throw
    /// `keyNotFound("id")` AFTER the server had already committed the alert —
    /// so the sheet would show an error over an alert that exists, and tapping
    /// Save again would create a second one.
    func createPlaceAlert(request: CreatePlaceAlertRequest) async throws -> String {
        return try await post(path: "/api/v1/place-alerts", body: request)
    }

    /// Backend route: PUT /api/v1/place-alerts/:id. Returns no row
    /// (`"data": null`). Callers already hold the values
    /// they sent; re-fetch if the server-side row is needed.
    func updatePlaceAlert(alertId: String, request: UpdatePlaceAlertRequest) async throws -> EmptyResponse {
        return try await put(path: "/api/v1/place-alerts/\(alertId)", body: request)
    }

    /// Backend route: POST /api/v1/place-alerts/:id/refresh-hashes. After a
    /// circle key rotation the match hashes are stale (BLAKE3(old_circle_key, …));
    /// re-derive with the current key and post here to clear needs_hash_update
    /// and restore alerting.
    @discardableResult
    func refreshPlaceAlertHashes(alertId: String, arrivalHash: String?, departureHash: String?, enterHash: String?, exitHash: String?) async throws -> EmptyResponse {
        // enter/exit are the hashes the worker matches a crossing against;
        // the backend clears `needs_hash_update` ONLY when they're supplied.
        struct Body: Encodable {
            let arrivalHash: String?
            let departureHash: String?
            let enterTypeHash: String?
            let exitTypeHash: String?
        }
        return try await post(
            path: "/api/v1/place-alerts/\(alertId)/refresh-hashes",
            body: Body(arrivalHash: arrivalHash, departureHash: departureHash, enterTypeHash: enterHash, exitTypeHash: exitHash)
        )
    }

    // MARK: - SOS Endpoints

    /// POST /api/v1/sos. The circle is carried in the BODY (`CreateSOSRequest.circleId`),
    /// not the path: the server has no circle-scoped SOS route. The `circleId`
    /// parameter is kept for call-site symmetry with the other circle APIs.
    func triggerSOS(circleId: String, request: CreateSOSRequest) async throws -> SOSResponse {
        return try await post(path: "/api/v1/sos", body: request)
    }

    /// PUT /api/v1/sos/:id/reseal — the raiser's phone re-seals its still-open
    /// alert under the circle's current key. Every refusal is a 404.
    func resealSOS(alertId: String, request: ResealSOSRequest) async throws -> SOSResponse {
        return try await put(path: "/api/v1/sos/\(alertId)/reseal", body: request)
    }

    func acknowledgeSOS(alertId: String) async throws -> SOSResponse {
        return try await post(path: "/api/v1/sos/\(alertId)/acknowledge", body: EmptyBody())
    }

    /// Per-viewer hide. Records a private dismissal; does NOT close the alert
    /// or change what any other member sees.
    func dismissSOS(alertId: String) async throws -> SOSResponse {
        return try await post(path: "/api/v1/sos/\(alertId)/dismiss", body: EmptyBody())
    }

    /// Undo a dismissal within the grace window. Restores the list row and
    /// the map marker together — both read the same dismissed_by_me flag.
    func undismissSOS(alertId: String) async throws -> SOSResponse {
        return try await delete(path: "/api/v1/sos/\(alertId)/dismiss")
    }

    /// POST /api/v1/sos/:id/receipt — confirm the PUSH for this alert reached
    /// this device.
    ///
    /// Call from the notification path only. Reporting a receipt after learning
    /// about an alert any other way would confirm a notification that never
    /// arrived, which is precisely what the raiser's delivery summary exists to
    /// detect.
    ///
    /// Not acknowledgement: this says bytes landed, not that anyone looked.
    func reportSOSReceipt(alertId: String) async throws {
        let _: EmptyResponse = try await post(
            path: "/api/v1/sos/\(alertId)/receipt",
            body: SOSReceiptRequest(platform: "ios")
        )
    }

    /// GET /api/v1/sos/:id/delivery — how far MY OWN alert got. 404s for
    /// anyone else's.
    func getSOSDelivery(alertId: String) async throws -> SOSDeliveryResponse {
        return try await get(path: "/api/v1/sos/\(alertId)/delivery")
    }

    /// POST /api/v1/sos/:id/resolve — closes the alert as `resolved` FOR
    /// EVERYONE. The server always records `resolved` and reads no body, so
    /// the `resolution` we send is read by nothing; it is kept only because
    /// the caller labels its own cached copy with it. To close an alert as a
    /// false alarm use `markSOSFalseAlarm` — posting "false_alarm" here
    /// records `resolved` for every other member.
    ///
    /// Permitted for the raiser or a circle admin/owner.
    func resolveSOS(alertId: String, resolution: String) async throws -> SOSResponse {
        let body = ResolveSOSRequest(resolution: resolution)
        return try await post(path: "/api/v1/sos/\(alertId)/resolve", body: body)
    }

    /// POST /api/v1/sos/:id/false-alarm — the separate route that actually
    /// records `status = 'false_alarm'`. Restricted to the RAISER (nobody else
    /// is in a position to know it was one) and to alerts still open, so a
    /// resolved alert can't be rewritten after the fact. Takes no body.
    func markSOSFalseAlarm(alertId: String) async throws -> SOSResponse {
        return try await post(path: "/api/v1/sos/\(alertId)/false-alarm", body: EmptyBody())
    }

    /// GET /api/v1/sos/active — `data` is a PLAIN ARRAY of SOSResponse, not a
    /// paginated envelope.
    ///
    /// Do not use `getPaginated` here: it decodes `data` as `Paginated` — an
    /// object with an `items` key — and decoding a bare array into that always
    /// throws. Every caller wraps the load in `try?`, so `activeAlerts` would
    /// silently stay empty and iOS would never show another member's SOS.
    func getActiveSOSAlerts() async throws -> [SOSResponse] {
        return try await get(path: "/api/v1/sos/active")
    }

    // MARK: - Check-in Endpoints

    /// `POST /api/v1/check-ins`: the circle rides in the body. The circle's own
    /// path serves only GET, and answers a POST with 405.
    func createCheckIn(circleId: String, request: CreateCheckInRequest) async throws -> CheckInResponse {
        return try await post(path: "/api/v1/check-ins", body: request)
    }

    /// Path + query for one page of a circle's check-in history.
    ///
    /// WHY THIS IS NOT `/api/v1/check-ins`
    ///   That route is the PERSONAL feed, and it authorizes the queried
    ///   `user_pseudonym` against the account's SELF-key pseudonym domain. A
    ///   per-CIRCLE pseudonym (`deriveUserPseudonym(circleId:userId:)`) is a
    ///   different domain, so a history load through the personal route is
    ///   answered 403, every time.
    ///
    ///   The circle route is authorized by MEMBERSHIP, takes the same
    ///   limit/cursor_day_bucket/cursor_id keyset pagination, and returns rows
    ///   sealed under the CIRCLE key — which is the key
    ///   `decryptCheckInResponse(_:circleId:)` opens them with. It is also what
    ///   the Android app calls (`TrackApi.getCircleCheckIns`) and what web calls
    ///   for the same view (`fetchCircleCheckIns`); web reserves the personal
    ///   route for `fetchMyCheckIns`, which derives its pseudonym from
    ///   `SELF_CIRCLE_ID`.
    ///
    /// Split out as a pure function so the query shape is testable without a
    /// network — see CheckInHistoryWireTests.
    nonisolated static func circleCheckInsPath(
        circleId: String,
        limit: Int,
        cursorDayBucket: Int? = nil,
        cursorId: String? = nil
    ) -> String {
        let circle = circleId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? circleId
        var query = "limit=\(limit)"
        if let cdb = cursorDayBucket {
            query += "&cursor_day_bucket=\(cdb)"
        }
        if let cid = cursorId {
            query += "&cursor_id=\(Self.queryValue(cid))"
        }
        return "/api/v1/circles/\(circle)/check-ins?\(query)"
    }

    /// Backend route: GET /api/v1/circles/:circle_id/check-ins. Cursor-paginated
    /// history for one circle, authorized by membership. See
    /// `circleCheckInsPath` for why the personal `/api/v1/check-ins` route is
    /// the wrong one here.
    ///
    /// NOT getPaginated: the route returns a BARE array in `data`. It paginates
    /// by CURSOR (the caller sends `cursor_day_bucket`/`cursor_id` and walks
    /// from the last row), which is why "paginated" is true of the route and
    /// false of its envelope: there is no `{items, has_more, next_cursor}`
    /// object to unwrap. getPaginated looks for `data.items`, so every call
    /// would throw `keyNotFound("items")` — on a 200.
    ///
    /// `listCircleDestinations` has the same envelope; see `decodeResponseBody`
    /// for why the accessor is the thing that picks the envelope.
    func listCircleCheckIns(
        circleId: String,
        limit: Int = 50,
        cursorDayBucket: Int? = nil,
        cursorId: String? = nil
    ) async throws -> [CheckInResponse] {
        return try await get(
            path: Self.circleCheckInsPath(
                circleId: circleId,
                limit: limit,
                cursorDayBucket: cursorDayBucket,
                cursorId: cursorId
            )
        )
    }

    /// First page of the same route, for `loadRecentCheckIns`. Bare array for
    /// the same reason `listCircleCheckIns` is — one route, one envelope.
    func getCheckIns(circleId: String) async throws -> [CheckInResponse] {
        return try await get(path: "/api/v1/circles/\(circleId)/check-ins")
    }

    // MARK: - Boundary Endpoints

    /// Report a client-detected boundary crossing so the server can fan
    /// out pushes to matching subscribers. Backend route:
    /// POST /api/v1/boundaries/crossing.
    func reportBoundaryCrossing(request: BoundaryCrossingRequest) async throws -> BoundaryCrossingResponse {
        return try await post(path: "/api/v1/boundaries/crossing", body: request)
    }

    // MARK: - Notification Endpoints

    func sendNotification(request: SendNotificationRequest) async throws -> SendNotificationResponse {
        return try await post(path: "/api/v1/internal/notify", body: request)
    }

    // MARK: - Config Endpoints
    //
    // Map config is served at `GET /api/config` and read by
    // `MapTileConfig.refresh(apiBaseURL:)`, which decodes its shape and
    // treats every field as optional.

    // MARK: - Self Key (Personal Tracking)

    /// Fetch the user's personal self-tracking key (wrapped for the
    /// user's own X25519 sharing key). Returns nil-data when no key
    /// has been stored yet. Mirrors the Android app's
    /// `TrackApi.getSelfKey` — `GET /api/v1/users/me/self-key`.
    /// Successful import yields the SDK's circle key registered under
    /// the nil UUID, enabling the user's own /circles/{nil}/locations
    /// history endpoint to decrypt.
    ///
    /// `try?` here would lose data rather than be a convenience: it collapses a
    /// 500, a timeout and a dropped connection into the very same `nil` the
    /// server returns for "no key on file", and `SelfKeyManager.ensure()`
    /// answers that `nil` by minting a replacement and POSTing it to an
    /// UPSERT — destroying the only server copy of the key every personal
    /// location row is encrypted under. Only a genuine `data: null` may
    /// return nil; everything else must throw so the caller's catch can
    /// refuse to mint.
    func getSelfKey() async throws -> CircleKeyBundleResponse? {
        let envelope: SelfKeyEnvelope = try await get(path: "/api/v1/users/me/self-key")
        return envelope.data
    }

    /// The self-key GET is the one endpoint whose *successful* answer can be
    /// `{"success": true, "data": null}`: a missing row is a success with no
    /// key. `decodeResponse` cannot express that: it unwraps `data`, and a
    /// null one falls through to a direct decode of the full body, which
    /// throws. So decode the envelope itself.
    ///
    /// `success` is deliberately REQUIRED. `decodeResponse` tries
    /// `APIResponse<T>` first, which would hand this type the *inner* bundle
    /// object; without a mandatory key of its own it would decode from that
    /// happily and report `data: nil` for a key that is actually present —
    /// the same data loss by another route. Demanding `success` makes that
    /// attempt throw, so the fallback direct decode always sees the envelope.
    ///
    /// Internal rather than private so SelfKeyEnvelopeTests can pin all three
    /// of those behaviours — the cost of getting this wrong is the user's
    /// entire personal location history.
    struct SelfKeyEnvelope: Decodable {
        let success: Bool
        let data: CircleKeyBundleResponse?
    }

    /// Store a freshly generated self-tracking key. Body shape mirrors
    /// `StoreSelfKeyRequest` in the Android app: encrypted_self_key
    /// (nonce+ciphertext, wrapped for our sharing key) plus the
    /// ephemeral public key the SDK emitted. Backend route:
    /// `POST /api/v1/users/me/self-key`.
    ///
    /// `wrapSignature`: our own Ed25519 signature over this exact wrap, so
    /// a device importing it can tell it from a wrap the server made up.
    /// Re-publishing the IDENTICAL wrap with a signature is how an unsigned
    /// server copy gets signed; the replace guard always allows identical
    /// bytes. Omitted from the body when nil.
    func storeSelfKey(
        encryptedSelfKey: EncryptedBlobRequest,
        ephemeralPublicKey: String,
        wrapSignature: String? = nil,
        userPseudonym: String? = nil,
        replace: Bool? = nil
    ) async throws -> EmptyResponse {
        let body = StoreSelfKeyRequest(
            encryptedSelfKey: encryptedSelfKey,
            ephemeralPublicKey: ephemeralPublicKey,
            wrapSignature: wrapSignature,
            userPseudonym: userPseudonym,
            replace: replace
        )
        return try await post(path: "/api/v1/users/me/self-key", body: body)
    }

    /// auth's refusals of re-auth step 2 that are NOT about the access session:
    /// by `error_code`, else by the text older servers send.
    /// `invalid_credentials` is the wrong password, and only it says so;
    /// `reauth_session_expired` is a handshake that is gone (expired, used, or
    /// not this user's), started again at step 1. nil for anything else: a 401
    /// from the middleware is refreshed and retried like any call.
    nonisolated static func reauthRefusal(_ body: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        if let code = object["error_code"] as? String {
            return ["invalid_credentials", "reauth_session_expired"].contains(code) ? code : nil
        }
        switch object["error"] as? String {
        case "Invalid credentials": return "invalid_credentials"
        case "Invalid or expired re-auth session": return "reauth_session_expired"
        default: return nil
        }
    }

    /// This device cannot use the personal copy it was served. The server
    /// marks it and silently wakes the account's OTHER phones, whose own pass
    /// republishes when the copy cannot be opened there either. 404 when
    /// nothing is stored.
    func reportSelfKeyUnreadable(copySha256: String) async throws -> SelfKeyUnreadableResponse {
        try await post(path: "/api/v1/users/me/self-key/unreadable", body: SelfKeyUnreadableRequest(copySha256: copySha256))
    }

    /// The compare-and-set repair of the account's recorded pseudonym — only
    /// while exactly this copy is stored (409 `key_wrap_changed` otherwise:
    /// re-read), and only with the pseudonym under the key the copy carries,
    /// when this device's own key opens it.
    func repairSelfKeyPseudonym(_ request: SelfKeyPseudonymRequest) async throws {
        let _: EmptyResponse = try await put(path: "/api/v1/users/me/self-key/pseudonym", body: request)
    }

    /// Attach our signature to our OWN stored wrap of a circle key —
    /// `PUT /api/v1/circles/{id}/wrap-signature`.
    ///
    /// Used right after creating a circle (the signature binds the circle id,
    /// which only exists once the create returns), for legacy unsigned wraps of
    /// our own, and — with the nil circle id — for our personal key. The server
    /// stores it only if its copy is exactly these bytes at exactly this
    /// version; otherwise 409 `key_wrap_changed` (a rotation or another device
    /// replaced it) — nothing to do then.
    func signOwnCircleWrap(
        circleId: String,
        keyVersion: Int,
        encryptedCircleKey: EncryptedBlobRequest,
        ephemeralPublicKey: String,
        wrapSignature: String
    ) async throws -> SignOwnWrapResponse {
        let body = SignOwnWrapRequest(
            keyVersion: keyVersion,
            encryptedCircleKey: encryptedCircleKey,
            ephemeralPublicKey: ephemeralPublicKey,
            wrapSignature: wrapSignature
        )
        return try await put(path: "/api/v1/circles/\(circleId)/wrap-signature", body: body)
    }

    /// Hand a member the circle's CURRENT key — any active member may, for a
    /// member owed it. The body is the usual wrap, signed by this device's user
    /// as sender. The server keeps the FIRST delivery; a later one is answered
    /// 409 (`already_delivered`, or a stale `key_version`).
    func deliverAccess(
        circleId: String,
        userId: String,
        keyVersion: Int,
        encryptedCircleKey: EncryptedBlobRequest,
        ephemeralPublicKey: String,
        wrapSignature: String
    ) async throws {
        let body = SignOwnWrapRequest(
            keyVersion: keyVersion,
            encryptedCircleKey: encryptedCircleKey,
            ephemeralPublicKey: ephemeralPublicKey,
            wrapSignature: wrapSignature
        )
        let _: EmptyResponse = try await put(path: "/api/v1/circles/\(circleId)/members/\(userId)/access", body: body)
    }

    /// An owner's or admin's ADMISSION of another member: a signed kind-3
    /// statement that this account, with exactly these keys, belongs in the
    /// circle — the legacy "Let them in", the backfill, and a promotion to
    /// admin.
    func storeMemberStatement(circleId: String, userId: String, statementHex: String, signatureHex: String) async throws {
        let body = MemberStatementRequest(statement: statementHex, statementSignature: signatureHex)
        let _: EmptyResponse = try await put(path: "/api/v1/circles/\(circleId)/members/\(userId)/statement", body: body)
    }

    /// Ask the circle's other members for a fresh copy of its key: this device
    /// refused the one it has, or cannot open it. Deletes nothing; the next
    /// delivery may replace our copy once.
    func requestAccess(circleId: String) async throws {
        let _: EmptyResponse = try await post(path: "/api/v1/circles/\(circleId)/access/request", body: EmptyResponse())
    }

    /// This member is listed with a sharing key and no signing key — an app
    /// too old to be let back in. The server checks that itself (409
    /// `member_up_to_date` otherwise) and tells THEM, by push and email, at
    /// most once a day; the roster then says `update_requested`.
    func requestMemberUpdate(circleId: String, userId: String) async throws -> MemberUpdateRequestResponse {
        try await post(path: "/api/v1/circles/\(circleId)/members/\(userId)/update-request", body: EmptyResponse())
    }

    /// Send a pre-built authed request and return the raw response body,
    /// running the SAME bearer-token refresh-and-retry as `execute<T>` but
    /// for callers whose payload isn't `Decodable` (e.g. the arbitrary
    /// `[String: Any]` notification-preferences map). A 401 triggers one
    /// `/auth/refresh` + retry with the rotated token; everything else maps
    /// the server's `{error}` envelope to an `APIError` like the rest of the
    /// API. Skips the circuit breaker + 429 budgeting that `execute` layers
    /// on — preferences are a low-frequency, user-initiated call.
    private func executeRaw(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError(code: "network_error", message: "Invalid response")
        }
        if (200...299).contains(http.statusCode) {
            return data
        }
        // 401 — refresh the access token once and retry, mirroring
        // execute()'s refresh path (minus the nbf clock-skew loop, which
        // isn't worth the complexity on a settings toggle).
        if http.statusCode == 401 {
            try await refreshTokenIfNeeded()
            var retry = request
            if let token = keychain.getString(for: .accessToken) {
                retry.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            let (retryData, retryResponse) = try await session.data(for: retry)
            guard let retryHttp = retryResponse as? HTTPURLResponse else {
                throw APIError(code: "network_error", message: "Invalid response")
            }
            if (200...299).contains(retryHttp.statusCode) {
                return retryData
            }
            if let error = try? decoder.decode(APIResponse<EmptyResponse>.self, from: retryData).error {
                throw error
            }
            throw APIError(code: "http_\(retryHttp.statusCode)", message: "Request failed")
        }
        // Non-401 error — surface the server's structured `{error}` if present.
        if let error = try? decoder.decode(APIResponse<EmptyResponse>.self, from: data).error {
            throw error
        }
        throw APIError(code: "http_\(http.statusCode)", message: "Request failed")
    }

    // MARK: - Private HTTP Methods

    private func get<T: Decodable>(path: String, queryParams: [String: String]? = nil, auth: Bool = true, baseURL: String? = nil) async throws -> T {
        var components = URLComponents(string: (baseURL ?? config.apiBaseURL) + path)!
        if let params = queryParams {
            // Pre-encoded: `URLQueryItem` would leave a `+` as it is (see `queryValue`).
            components.percentEncodedQueryItems = params.map {
                URLQueryItem(name: Self.queryValue($0.key), value: Self.queryValue($0.value))
            }
        }

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        try addHeaders(to: &request, auth: auth)

        return try await execute(request)
    }

    /// Every item of a cursor-paged list (the `{items, has_more, next_cursor}`
    /// envelope the backend uses for collection endpoints), following its pages
    /// to the end. One page (50 by default) leaves the rest out, and a list
    /// that leaves some out must never read as "these are gone" (a waiting
    /// change is checked against these lists). So a list whose pages don't end
    /// (more promised without a cursor that moves on, or past the page cap) is
    /// an error, never a whole list. Pages are merged by `id`: a scan the
    /// server restarts (an old cursor) repeats items, never twice here.
    private func getAllPages<E: Decodable>(path: String, id: (E) -> String) async throws -> PagedItems<E> {
        var all: [E] = []
        var seen = Set<String>()
        var cursor: String?
        for pages in 1...100 {
            var query = ["limit": "100"]
            if let cursor { query["cursor"] = cursor }
            let page: Paginated<E> = try await get(path: path, queryParams: query)
            for item in page.items where seen.insert(id(item).lowercased()).inserted {
                all.append(item)
            }
            guard page.hasMore == true else { return PagedItems(items: all, pages: pages) }
            guard let next = page.nextCursor, next != cursor else {
                throw APIError(code: "incomplete_list", message: "The list's pages didn't end")
            }
            cursor = next
        }
        throw APIError(code: "incomplete_list", message: "The list is longer than this app reads")
    }

    /// A cursor-paged list's items, and how many pages they came on.
    struct PagedItems<E> {
        let items: [E]
        let pages: Int
    }

    private func post<T: Decodable, B: Encodable>(
        path: String,
        body: B,
        auth: Bool = true,
        baseURL: String? = nil,
        attestationToken: String? = nil,
        identifyDevice: Bool = false
    ) async throws -> T {
        var request = URLRequest(url: URL(string: (baseURL ?? config.apiBaseURL) + path)!)
        request.httpMethod = "POST"
        request.httpBody = try encoder.encode(body)
        try addHeaders(
            to: &request,
            auth: auth,
            attestationToken: attestationToken,
            identifyDevice: identifyDevice
        )
        return try await execute(request)
    }

    private func put<T: Decodable, B: Encodable>(path: String, body: B, auth: Bool = true, baseURL: String? = nil) async throws -> T {
        var request = URLRequest(url: URL(string: (baseURL ?? config.apiBaseURL) + path)!)
        request.httpMethod = "PUT"
        request.httpBody = try encoder.encode(body)
        try addHeaders(to: &request, auth: auth)

        return try await execute(request)
    }

    private func patch<T: Decodable, B: Encodable>(path: String, body: B, auth: Bool = true, baseURL: String? = nil) async throws -> T {
        var request = URLRequest(url: URL(string: (baseURL ?? config.apiBaseURL) + path)!)
        request.httpMethod = "PATCH"
        request.httpBody = try encoder.encode(body)
        try addHeaders(to: &request, auth: auth)

        return try await execute(request)
    }

    private func delete<T: Decodable>(path: String, auth: Bool = true, baseURL: String? = nil) async throws -> T {
        var request = URLRequest(url: URL(string: (baseURL ?? config.apiBaseURL) + path)!)
        request.httpMethod = "DELETE"
        try addHeaders(to: &request, auth: auth)

        return try await execute(request)
    }

    /// DELETE with a JSON body. RFC 7231 §4.3.5 allows a body on DELETE;
    /// some backends require it (e.g. the auth API's
    /// `DELETE /api/v1/auth/me` takes `{password, pseudonyms}` for SRP
    /// re-verification + GDPR purge).
    private func delete<T: Decodable, B: Encodable>(
        path: String,
        body: B,
        auth: Bool = true,
        baseURL: String? = nil
    ) async throws -> T {
        var request = URLRequest(url: URL(string: (baseURL ?? config.apiBaseURL) + path)!)
        request.httpMethod = "DELETE"
        request.httpBody = try encoder.encode(body)
        try addHeaders(to: &request, auth: auth)
        return try await execute(request)
    }

    /// Which User-Agent a request carries. Pure and `static` so a test drives the
    /// real decision on a real `URLRequest` rather than a copy of the rule —
    /// `APIService` is a singleton whose `URLSession` is built once
    /// (`TrustBlocklist.session`) and is deliberately not injectable, so this
    /// is the honest seam.
    ///
    /// Three cases, not two:
    ///   - authenticated            → device UA; the server names the session.
    ///   - anonymous                → no `(...)` comment, so nothing links the
    ///                                request to this handset.
    ///   - anonymous + identifying  → device UA on an unauthenticated request.
    ///     ONLY the SRP login pair. See `identifyDevice` at those call sites.
    nonisolated static func applyUserAgent(
        to request: inout URLRequest,
        auth: Bool,
        identifyDevice: Bool,
        deviceUA: String,
        anonymousUA: String
    ) {
        let ua = (auth || identifyDevice) ? deviceUA : anonymousUA
        request.setValue(ua, forHTTPHeaderField: "User-Agent")
    }

    private func addHeaders(
        to request: inout URLRequest,
        auth: Bool,
        attestationToken: String? = nil,
        identifyDevice: Bool = false
    ) throws {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Session-less / anonymous requests (e.g. the geocode-token redemption)
        // must NOT carry a device-identifying UA — combined with the source IP it
        // would let the geocoder fingerprint the "anonymous" request back to this
        // device (parity with the Android app).
        //
        // The SRP login pair is the deliberate exception. The server derives the
        // session's `device_name` from the UA it sees in the login handshake (see
        // `srpStep1`), so with the anonymous string every iOS session would be
        // stored as "Unknown Device" and the account portal's device list — the
        // list a user reads to spot an intruder — could not tell one iPhone from
        // another. Identifying the device to the login endpoint you are handing
        // your password to costs no privacy the login itself has not already
        // spent; identifying it to the geocoder would.
        Self.applyUserAgent(
            to: &request,
            auth: auth,
            identifyDevice: identifyDevice,
            deviceUA: config.userAgent,
            anonymousUA: config.anonymousUserAgent
        )

        if auth {
            guard let token = keychain.getString(for: .accessToken) else {
                throw APIError(code: "unauthorized", message: "No access token")
            }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        if let attestationToken = attestationToken {
            request.setValue(attestationToken, forHTTPHeaderField: "X-Attestation-Token")
        }
    }

    private func execute<T: Decodable>(_ request: URLRequest) async throws -> T {
        #if DEBUG
        let reqMethod = request.httpMethod ?? "?"
        let reqURL = request.url?.absoluteString ?? "?"
        trackDiagLog.info("\("→ \(reqMethod) \(reqURL)", privacy: .public)")
        #endif
        // Circuit breaker check — protected paths fail fast for 30s
        // after 5 consecutive failures so a cold backend doesn't turn
        // into a UI hang.
        let path = request.url?.path ?? ""
        let circuitKey: String?
        do {
            circuitKey = try await CircuitBreaker.shared.canSendRequest(path: path)
        } catch {
            throw APIError(
                code: "circuit_open",
                message: "Service temporarily unavailable; retry shortly."
            )
        }

        var attempt = 0
        var totalWaitedMs: UInt64 = 0
        while true {
            let (data, response) = try await runOnce(request: request, circuitKey: circuitKey)
            guard let httpResponse = response as? HTTPURLResponse else {
                await CircuitBreaker.shared.record(failure: circuitKey)
                throw APIError(code: "network_error", message: "Invalid response")
            }
            #if DEBUG
            // Never a token or key material, even here (`LogRedaction`): the
            // preview and the file are written from the scrubbed body.
            let loggable = LogRedaction.scrub(body: data)
            let bodyPreview = String(data: loggable.prefix(1200), encoding: .utf8)?
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ") ?? "<binary>"
            trackDiagLog.info("\("← \(httpResponse.statusCode) \(reqURL) bytes=\(data.count) body=\(bodyPreview)", privacy: .public)")
            // Write the raw body to the app's Documents/ so it can be pulled
            // via `xcrun devicectl device copy from --domain-type appDataContainer`.
            if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                let slug = (request.url?.path ?? "unknown")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    .replacingOccurrences(of: "/", with: "_")
                    .replacingOccurrences(of: ":", with: "_")
                let stamp = Int(Date().timeIntervalSince1970)
                let url = docs.appendingPathComponent("diag-\(slug)-\(stamp)-\(httpResponse.statusCode).json")
                try? loggable.write(to: url)
                trackDiagLog.info("\("wrote \(url.lastPathComponent)", privacy: .public)")
            }
            #endif

            // The two-step sign-in is answered by its status and
            // auth's code, and never retried or refreshed: a retry
            // sends the same code again and spends another of the
            // attempt's five tries, and its 401 is a wrong code on
            // a live attempt, not a dead token.
            if path == Self.twoFactorLoginPath, !(200...299).contains(httpResponse.statusCode) {
                if httpResponse.statusCode >= 500 {
                    await CircuitBreaker.shared.record(failure: circuitKey)
                }
                let serverCode = (try? decoder.decode(APIResponse<EmptyResponse>.self, from: data))?.error?.errorCode
                throw APIError(code: "http_\(httpResponse.statusCode)", message: "Two-step sign-in refused",
                               errorCode: serverCode)
            }

            // 429 — wait + retry within budget. We deliberately don't
            // count 429s as breaker failures because the server is
            // healthy, just throttling us.
            if httpResponse.statusCode == 429 {
                // A cap the server names is not throttling: the
                // invitation e-mails of the last 24 hours don't free up in
                // seconds. Said at once, with its code, never waited out.
                if let named = (try? decoder.decode(APIResponse<EmptyResponse>.self, from: data))?.error?.errorCode,
                   APIError.capsNotWaitedOut.contains(named) {
                    throw APIError(code: "http_429", message: "Limit reached", errorCode: named)
                }
                attempt += 1
                let header = httpResponse.value(forHTTPHeaderField: "Retry-After")
                guard let waitMs = await RateLimiter.shared.waitMs(
                    forRetryAfterHeader: header,
                    attempt: attempt,
                    totalWaitedMs: totalWaitedMs
                ) else {
                    var limited = APIError(code: "rate_limited", message: "Too many requests; please try again later.")
                    // Seconds only, as the backend sends it; a caller that
                    // schedules its own retry waits at least this long.
                    limited.retryAfter = header.flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                    throw limited
                }
                totalWaitedMs += waitMs
                try await Task.sleep(nanoseconds: waitMs * 1_000_000)
                continue
            }

            // 401 — two distinct cases:
            //
            // (a) "Token not yet valid" — JWT nbf clock skew
            //     between the auth and track servers. A freshly
            //     issued token can take a few seconds before the
            //     track server accepts it. Refreshing doesn't help
            //     (the token IS valid, just slightly future-
            //     dated). Sleep + retry the same request with
            //     exponential backoff: 1s, 2s, 4s (~7s total).
            //
            // (b) Anything else — the refresh-and-retry path.
            if httpResponse.statusCode == 401 {
                let body = String(data: data, encoding: .utf8) ?? ""
                if body.localizedCaseInsensitiveContains("not yet valid"),
                   attempt < 3,
                   totalWaitedMs < 7_000 {
                    attempt += 1
                    let waitMs: UInt64 = 1_000 * UInt64(1 << (attempt - 1))
                    totalWaitedMs += waitMs
                    try await Task.sleep(nanoseconds: waitMs * 1_000_000)
                    continue
                }
                // Never recurse into refresh from the refresh endpoint
                // itself — a 401 on /auth/refresh means the refresh
                // token is dead, not that we need to refresh again.
                // Without this guard, an invalid stored refresh_token
                // causes an infinite retry storm (each refresh attempt
                // hits 401, which calls refreshTokenIfNeeded, which
                // calls refreshToken, which hits execute again...).
                // A step-up's wrong password is a 401 too. It is the
                // person's to retype, not a dead token: no refresh and
                // no retry. So is a handshake that went stale, which
                // the caller starts again. Only by auth's code (or its
                // exact text on older servers); a 401 about the
                // session carries neither and is refreshed and
                // retried like any other call.
                // The sign-in's own step 2: its 401 is the proof
                // failing, a wrong password (or an address with no
                // account, which step 1 never tells), not a dead
                // token. There is no session to refresh yet, and a
                // refresh would only turn it into "Couldn't sign in":
                // the person retypes.
                if request.url?.path == Self.srpStep2Path {
                    let serverCode = (try? decoder.decode(APIResponse<EmptyResponse>.self, from: data))?.error?.errorCode
                    throw APIError(code: "http_401", message: "Sign-in proof refused", errorCode: serverCode)
                }
                if request.url?.path == "/api/v1/auth/reauth/srp/step2", let refusal = Self.reauthRefusal(data) {
                    throw APIError(code: refusal, message: refusal == "invalid_credentials"
                                   ? "Invalid credentials" : "Invalid or expired re-auth session")
                }
                // A sign-out is not refreshed and retried.
                if Self.neverRefreshed(path: request.url?.path) {
                    throw APIError(code: "unauthorized", message: "Sign-out refused")
                }
                let isRefreshEndpoint = request.url?.path == "/api/v1/auth/refresh"
                if isRefreshEndpoint {
                    await CircuitBreaker.shared.record(failure: circuitKey)
                    // Surface the server's reason in the thrown error +
                    // log so operators can tell session-revoked from
                    // session-not-found from signature-failure (parity
                    // with the Android app). A single opaque
                    // "Refresh token rejected" string would hide all of
                    // those behind the same message.
                    let serverReason = body.isEmpty ? "(no body)" : body
                    print("[Track] /auth/refresh \(httpResponse.statusCode): \(serverReason)")
                    throw APIError(
                        code: "refresh_failed",
                        message: "Refresh token rejected: \(serverReason)"
                    )
                }
                // Refresh-token rotation race:
                // a parallel SRP sign-in or another in-flight refresh
                // may have stored a brand-new access token while this
                // request's 401-handler was about to call /auth/refresh
                // with the now-stale one. Without the guards below the
                // failing refresh would propagate up and AuthManager
                // would force-logout an actually-authenticated user
                // ("signed in, then immediately signed out").
                let originalAuth = request.value(forHTTPHeaderField: "Authorization")
                // If another in-flight request already rotated the token
                // while this one was being sent, skip the refresh entirely
                // and just retry with the new token. Combined with the
                // coalesced refresh, this collapses a startup burst of 401s
                // to a single /auth/refresh.
                let storedBearer = keychain.getString(for: .accessToken).flatMap {
                    $0.isEmpty ? nil : "Bearer \($0)"
                }
                let alreadyRotated = storedBearer != nil && storedBearer != originalAuth
                var refreshError: Error?
                if !alreadyRotated {
                    do {
                        try await refreshTokenIfNeeded()
                    } catch {
                        refreshError = error
                    }
                }
                var newRequest = request
                if let token = keychain.getString(for: .accessToken) {
                    newRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                }
                let newAuth = newRequest.value(forHTTPHeaderField: "Authorization")
                // Only force-fail when the refresh truly failed *and*
                // nothing else updated the stored token underneath us.
                // If `newAuth != originalAuth` the user is currently
                // authenticated under a different token than the dead
                // one — retry with that.
                if let refreshError = refreshError, newAuth == originalAuth {
                    await CircuitBreaker.shared.record(failure: circuitKey)
                    throw refreshError
                }
                // Retry with the refreshed token, tolerating a
                // brief "not yet valid" window — a freshly issued
                // token can have an nbf a couple seconds ahead
                // (auth vs track server clock skew), which would
                // otherwise fail this single retry and leave the
                // cold-start data unloaded.
                var retryAttempt = 0
                while true {
                    let (retryData, retryResponse) = try await session.data(for: newRequest)
                    guard let retryHttp = retryResponse as? HTTPURLResponse else {
                        await CircuitBreaker.shared.record(failure: circuitKey)
                        throw APIError(code: "network_error", message: "Invalid response")
                    }
                    if (200...299).contains(retryHttp.statusCode) {
                        await CircuitBreaker.shared.record(success: circuitKey)
                        return try decodeResponse(retryData)
                    }
                    let retryBody = String(data: retryData, encoding: .utf8) ?? ""
                    if retryHttp.statusCode == 401,
                       retryBody.localizedCaseInsensitiveContains("not yet valid"),
                       retryAttempt < 3, totalWaitedMs < 7_000 {
                        retryAttempt += 1
                        let waitMs: UInt64 = 1_000 * UInt64(1 << (retryAttempt - 1))
                        totalWaitedMs += waitMs
                        try await Task.sleep(nanoseconds: waitMs * 1_000_000)
                        continue
                    }
                    await CircuitBreaker.shared.record(failure: circuitKey)
                    throw APIError(code: "unauthorized", message: "Token refresh failed")
                }
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                // 5xx counts as a breaker failure; 4xx (other than 401/429)
                // is a client bug, not service health, so it doesn't.
                if httpResponse.statusCode >= 500 {
                    await CircuitBreaker.shared.record(failure: circuitKey)
                }
                if let apiResponse = try? decoder.decode(APIResponse<EmptyResponse>.self, from: data),
                   let error = apiResponse.error {
                    // Keep the STATUS on the error. The track API
                    // reports failures as a bare `"error": "message"`
                    // string, which the envelope decoder can only
                    // label "server_error" because it never sees the
                    // response — without the status every 404 would
                    // look like a 500, and every
                    // `code == "http_404"` carve-out in the app would
                    // be dead code. CircleManager's matters most: a
                    // deleted circle is handled quietly, not with
                    // "Couldn't reach server — showing last known"
                    // over the map.
                    //
                    // Only the generic label is replaced; a
                    // server-supplied code (quota gates,
                    // `unauthorized`) is more specific than the
                    // status and keeps priority.
                    if error.code == "server_error" {
                        throw APIError(
                            code: "http_\(httpResponse.statusCode)",
                            message: error.message,
                            errorCode: error.errorCode,
                            quota: error.quota
                        )
                    }
                    throw error
                }
                #if DEBUG
                let bodyPreview = String(data: LogRedaction.scrub(body: data).prefix(400), encoding: .utf8)?
                    .replacingOccurrences(of: "\n", with: " ") ?? "<binary>"
                throw APIError(code: "http_\(httpResponse.statusCode)", message: "Request failed: \(bodyPreview)")
                #else
                throw APIError(code: "http_\(httpResponse.statusCode)", message: "Request failed")
                #endif
            }

            await CircuitBreaker.shared.record(success: circuitKey)
            do {
                return try decodeResponse(data)
            } catch {
                #if DEBUG
                // Surface the actual response body so the on-screen diagnostic
                // can show what shape the server returned and we can fix the
                // Codable to match.
                let bodyPreview = String(data: LogRedaction.scrub(body: data).prefix(600), encoding: .utf8)?
                    .replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "\r", with: " ") ?? "<binary>"
                throw APIError(
                    code: "decode_failed",
                    message: "Decode failed: \(error). Body[\(data.count)B]: \(bodyPreview)"
                )
                #else
                throw error
                #endif
            }
        }
    }

    /// One round-trip helper that translates URLSession transport errors
    /// (DNS, TLS, connection refused, …) into a circuit-breaker failure.
    private func runOnce(
        request: URLRequest,
        circuitKey: String?
    ) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            await CircuitBreaker.shared.record(failure: circuitKey)
            throw error
        }
    }

    private func decodeResponse<T: Decodable>(_ data: Data) throws -> T {
        try Self.decodeResponseBody(data, using: decoder)
    }

    /// One shared in-flight `/auth/refresh`. The server rotates the refresh
    /// token on every call, so concurrent refreshes invalidate each other.
    private var inflightRefresh: Task<Void, Error>?

    /// When the last `/auth/refresh` succeeded. The server rotates the
    /// single-use refresh token on every call, so a *burst* of refreshes —
    /// even serialized ones a second apart — leaves the client holding a
    /// token the server has already rotated past, which is then rejected
    /// minutes later (when the access token next expires) → forced logout.
    /// `inflightRefresh` only coalesces *truly concurrent* callers (it
    /// clears the instant the task finishes), so trailing 401-handlers that
    /// arrive a beat later would each start a fresh rotation. This
    /// timestamp adds a short grace window so those trailing callers reuse
    /// the token the first refresh just saved instead of burning another
    /// rotation.
    private var lastSuccessfulRefresh: Date?

    /// How long after a successful refresh to treat the stored token as fresh
    /// and skip re-rotating. Far shorter than the access-token TTL (~5 min),
    /// so a genuinely-expired token is still refreshed promptly; long enough
    /// to absorb a cold-start / reopen burst.
    private let refreshGraceWindow: TimeInterval = 10

    /// The last refresh failure, and when it happened. `lastSuccessfulRefresh`
    /// only stamps on SUCCESS, so while refresh keeps failing neither it nor
    /// `inflightRefresh` (cleared the instant the task finishes) damps anything
    /// — every caller would start its own round-trip: against one revoked
    /// session, bursts of `/auth/refresh` calls sustained for hours, each one
    /// surfacing an error banner. Re-throwing the cached failure inside the
    /// cooldown keeps the caller's semantics identical (it still sees a thrown
    /// error) while collapsing the burst to one network call.
    private var lastRefreshFailure: (error: Error, at: Date)?

    /// How long to serve the cached refresh failure before trying the network
    /// again. Short enough that a recovering backend is picked up promptly,
    /// long enough to collapse a same-instant burst.
    private let refreshFailureCooldown: TimeInterval = 5

    /// Coalesce concurrent token refreshes into ONE shared `/auth/refresh`.
    /// On a cold start ~10 calls 401 simultaneously on an expired access
    /// token; without this each would fire its own refresh, rotating the
    /// refresh token against the others and desyncing the session (leaving
    /// the app stuck on 401s with no circle data). Actor isolation makes the
    /// check-or-create atomic — there is NO await between the read of
    /// `inflightRefresh` and the assignment, so reentrancy can't double it.
    /// Callers that arrive while a refresh is running await that one.
    private func refreshTokenIfNeeded() async throws {
        // Truly-concurrent callers await the one in-flight refresh.
        if let existing = inflightRefresh {
            return try await existing.value
        }
        // A refresh that succeeded within the grace window already wrote a
        // fresh token to the keychain. Rotating again would burn the
        // single-use refresh token a second time and desync the session,
        // ending in a forced logout.
        // Trailing 401-handlers land here and simply retry with the token the
        // first refresh saved (execute() re-reads it from the keychain).
        if let last = lastSuccessfulRefresh,
           Date().timeIntervalSince(last) < refreshGraceWindow {
            return
        }
        // Symmetrically, a refresh that FAILED moments ago is re-thrown from
        // cache instead of re-hitting the network. Without this the failure
        // path has no damping at all: `/api/v1/auth/refresh` is deliberately
        // absent from CircuitBreaker.protectedPrefixes, so nothing else
        // rate-limits it.
        if let failure = lastRefreshFailure,
           Date().timeIntervalSince(failure.at) < refreshFailureCooldown {
            throw failure.error
        }
        let task = Task { try await self.performTokenRefresh() }
        inflightRefresh = task
        // Do NOT clear `inflightRefresh` or stamp the grace window from
        // HERE. This awaiting caller is frequently CANCELLED at cold start
        // — the SwiftUI `.task` / loadInitialData tasks that fire the first
        // burst of requests get torn down as the view tree settles, so
        // `try await task.value` throws CancellationError and any cleanup
        // after it is skipped. `lastSuccessfulRefresh` would stay unset,
        // the grace window would never engage and the cold-start refresh
        // STORM would run anyway: several refreshes, each invalidating the
        // prior access token (session rotation), so every retry with an
        // intermediate token 401s. `performTokenRefresh` (the uncancellable
        // inner task, below) owns both the slot-clear and the grace stamp,
        // so a cancelled caller can't reopen the storm.
        try await task.value
    }

    /// Public entry point for non-REST token consumers — specifically the gRPC
    /// location streamer, which must not call the raw `refreshToken(...)`
    /// endpoint directly: that would form a SECOND, un-coalesced refresh
    /// authority, and with single-use rotation two independent refreshers
    /// rotate the token against each other and desync the session. Routing the
    /// streamer through this shared path means every rotation — REST or
    /// streamer — goes through one coalesced, grace-windowed,
    /// background-assertion-protected authority. The caller reads the rotated
    /// access token from the keychain afterward.
    func ensureFreshAccessToken() async throws {
        try await refreshTokenIfNeeded()
    }

    private func performTokenRefresh() async throws {
        // Clear the in-flight slot when the ACTUAL refresh work finishes (on
        // the actor), not when an awaiting caller resumes — a cancelled caller
        // must not drop the slot while this task is still rotating, or a
        // concurrent request would start a second refresh. Runs on success and
        // on throw.
        defer { inflightRefresh = nil }
        let refreshToken = keychain.getString(for: .refreshToken)
        let hasAccess = (keychain.getString(for: .accessToken)?.isEmpty == false)
        let hasRefresh = refreshToken.map { !$0.isEmpty && $0 != "none" } ?? false
        // The server lets a refresh fire with either credential.
        // Only bail when we have neither — otherwise let the server
        // pick the legacy JWT path and attach a fresh refresh token
        // to the response (we save it below).
        if !hasAccess && !hasRefresh {
            throw APIError(code: "no_tokens", message: "No access or refresh token available")
        }
        // Hold a background-task assertion across the entire rotation
        // (network response → both keychain writes) so iOS can't suspend
        // the app mid-rotation and strand a consumed token. Otherwise: a
        // background inactivity-watch call 401s → refresh 200 → app
        // suspended before the save → reopen presents the dead token
        // ("logged out on reopen"). See TokenRefreshAssertion.
        let assertion = await TokenRefreshAssertion.begin()
        defer { Task { await TokenRefreshAssertion.end(assertion) } }

        // ONE refresh at a time across this app and its notification extension
        // (`AppGroupLock.refresh()`): two refreshes from the same stored token
        // retire one of the two pairs, and presenting a retired one later revokes
        // the session. Under the lock the stored token is read again: changed
        // means the extension refreshed meanwhile — its pair is ours, and
        // nothing is refreshed here.
        let lock = AppGroupLock.refresh()
        let held = await lock?.acquire(timeout: AppGroupLock.appWait)
        defer { held?.release() }
        if lock != nil, held == nil {
            throw APIError(code: "refresh_busy", message: "Another refresh is in progress")
        }
        if SessionRefresh.anotherProcessRefreshed(before: refreshToken, now: keychain.getString(for: .refreshToken)),
           let theirs = keychain.getString(for: .accessToken), !theirs.isEmpty {
            Task { @MainActor in SDKLocationStreamer.shared.updateToken(theirs) }
            lastSuccessfulRefresh = Date()
            lastRefreshFailure = nil
            return
        }

        let response: AuthResponse
        do {
            response = try await self.refreshToken(refreshToken: refreshToken)
        } catch {
            lastRefreshFailure = (error, Date())
            // A 401 from /auth/refresh is the ONE definitive "this session
            // is gone" signal — the endpoint resolves the session by
            // refresh-token hash and ignores the JWT signature, so 401
            // means revoked / expired / replayed, never transient.
            // execute() surfaces it as APIError code "refresh_failed".
            //
            // AuthManager checks this on the LAUNCH path
            // (checkExistingSession), but a session revoked while the app
            // is RUNNING must log out too: otherwise every call 401s,
            // refreshes, is denied, and posts a banner until a force-quit,
            // while the app renders as signed-in and no location reaches
            // the backend. Broadcasting here covers every refresh caller,
            // because this is the single coalesced refresh authority.
            //
            // EXCEPT under the synthetic-session UI-test bypass. That
            // session is authenticated with a token the backend has never
            // issued (`applySyntheticUITestSession`), so its first
            // background call 401s, refreshes, and is definitively
            // rejected — the app would then conclude the session is dead
            // and sign itself out, landing every shell test on the login
            // screen. A synthetic session's rejection is expected, not a
            // revocation. DEBUG-only and launch-argument gated: this is a
            // compile-time `false` in Release, so real revocation handling
            // is untouched.
            if !Self.isSyntheticUITestSession, APIError.isSessionDefinitivelyExpired(error) {
                NotificationCenter.default.post(name: .sessionRevoked, object: nil)
            }
            throw error
        }
        // Persist BOTH tokens independently and non-fatally. Were the
        // writes sequential `try`s, one failing keychain write would skip
        // the second write AND throw out of this method — leaving
        // `lastSuccessfulRefresh` unset, so the grace window never engages
        // and the cold-start rotation STORM returns, every call seeing
        // "Token expired". So each write stands alone: a failure is logged
        // but never aborts the refresh, so the storm can't restart and at
        // least one token still lands. Refresh token first — it's the
        // recovery anchor if the app is killed between the two writes (the
        // rotation is already committed server-side). Only persist a
        // rotated refresh token when the response actually carries one
        // (the legacy access-token-only path omits it — keep the existing
        // one).
        if let newRefresh = response.refreshToken, !newRefresh.isEmpty, newRefresh != "none" {
            do {
                try keychain.save(newRefresh, for: .refreshToken)
            } catch {
                print("[Track] refreshToken keychain save failed: \(error)")
            }
        }
        do {
            try keychain.save(response.accessToken, for: .accessToken)
        } catch {
            print("[Track] accessToken keychain save failed: \(error)")
        }
        // Hand the rotated token to the location stream as well. The SDK
        // reads its token per RPC, but only the one it was GIVEN: without
        // this the stream would keep its original token, be refused at
        // expiry, drop that upload and be rebuilt — every ~20 minutes for a
        // finite session. This is the single refresh authority, so doing it
        // here covers every caller. Handed over even if the keychain write
        // failed: the token is valid either way, and the stream should not
        // be the thing that finds out.
        let rotatedAccessToken = response.accessToken
        Task { @MainActor in SDKLocationStreamer.shared.updateToken(rotatedAccessToken) }
        // Stamp the grace window HERE — inside the uncancellable task, after
        // the keychain already holds the rotated token. Trailing 401-handlers
        // (and any caller that arrives within the window) then reuse this token
        // instead of starting another rotation, which is what collapses the
        // cold-start storm to a single /auth/refresh. A failed refresh throws
        // before reaching this line, so the window only opens on real success.
        lastSuccessfulRefresh = Date()
        // A success retires any cached failure, so a recovered backend isn't
        // shadowed by a stale error for the rest of the cooldown.
        lastRefreshFailure = nil
    }
}

// MARK: - Notification Names

extension Notification.Name {
    /// Posted by the refresh authority when the server has DEFINITIVELY
    /// rejected the session (401 from `/auth/refresh`). AuthManager observes
    /// this and signs out. Deliberately not posted for 5xx / 429 / offline —
    /// those are transient, and force-logging-out on them wipes the refresh
    /// token and leaves the device dark until a manual re-login.
    static let sessionRevoked = Notification.Name("sessionRevoked")
}

// MARK: - Request/Response Types

struct EmptyBody: Encodable {}
struct EmptyResponse: Codable {}

/// The location-processing notice, as the server serves it.
struct LocationConsentNoticeResponse: Codable {
    let version: String
    let digest: String
    /// Markdown. Rendered by `LocationConsentView`; see the parser there for
    /// which subset is supported.
    let text: String
}

/// Current consent state for one circle.
struct LocationConsentResponse: Codable {
    let circleId: String
    /// `granted` | `withdrawn` | `none`.
    ///
    /// `none` and `withdrawn` are different and the UI must not merge them: one
    /// is a question nobody has been asked, the other is an answer somebody
    /// gave. Re-prompting on `withdrawn` would be asking again after being told
    /// no.
    let status: String
    /// `presented` | `implied`. An `implied` grant is NOT a consent — it records
    /// that the membership predates the notice, so it still needs asking.
    let mode: String?
    let noticeVersion: String?
    let grantedAt: Date?
    let withdrawnAt: Date?
    let withdrawalReason: String?
    /// The live grant was given against a notice the server no longer serves.
    let noticeOutdated: Bool
}

struct SRPStep1Request: Encodable {
    let email: String
}

struct SRPStep1Response: Codable {
    let salt: String
    let serverPublic: String
    /// Opaque correlator the backend emits in step1 and requires
    /// back on step2. Without threading this through, step2 fails
    /// 422 unknown-session. Mirrors the Android app's SrpStep1Response.
    let sessionId: String
    /// Proton-style bcrypt salt used to preprocess the password before SRP.
    /// Always returned by the backend (fake value for non-existent users, so
    /// user-enumeration attacks can't distinguish success vs. not-found here).
    let bcryptSalt: String?
    /// Re-auth step 1 only: the address this challenge's verifier was derived
    /// with — the SRP identity to prove against (the current one, even after an
    /// email change). Absent on login step 1.
    var email: String? = nil
}

struct SRPStep2Request: Encodable {
    /// session_id returned by step1. The backend uses this, not
    /// email, to correlate the handshake. Sending email here
    /// yields 422 Invalid request body.
    let sessionId: String
    let clientPublic: String
    let clientProof: String
}

struct SRPStep2Response: Decodable {
    /// Opaque bearer token the server issues on successful proof
    /// verification. Absent when 2FA is required.
    let accessToken: String?
    /// Opaque refresh token bound to this session — clients send it
    /// to /auth/refresh via `X-Refresh-Token`. Nullable because the
    /// 2FA branch of this response doesn't include one (the user
    /// hasn't completed login yet); only the success branch sets it.
    /// Mirrors the Android app.
    let refreshToken: String?
    /// Emitted only when the account has 2FA enrolled; the client
    /// exchanges this + the TOTP/WebAuthn response via
    /// POST /api/v1/auth/login/2fa for the real access token.
    /// Matches the Android app's SrpStep2Response.two_factor_token.
    let twoFactorToken: String?
    /// `requires_2fa`. Optional because the backend omits the field on
    /// 2FA-free accounts. Decoded by hand — see `init(from:)`.
    let requires2fa: Bool?
    /// The second factors the account can answer the challenge with —
    /// `available_methods` in the auth server's reply, a subset of
    /// ["totp", "passkey"]. This app can only type a TOTP code, so a list
    /// without "totp" means the challenge cannot be answered here and the 2FA
    /// screen says so instead of offering a code box. nil means "not told"
    /// (the success branch has no such field), which keeps the code box.
    let availableMethods: [String]?
    /// `preferred_method`. Informational only: the code box always sends
    /// `method: "totp"`, never this value.
    let preferredMethod: String?
    /// The server's proof M2, on both branches: checked BEFORE anything in the
    /// reply is used — tokens, keys or a 2FA challenge.
    let serverProof: String?
    /// The success branch's keys: what the password that just proved opens,
    /// with the account's public keys beside them. The sign-in takes its keys
    /// from here, never from /auth/me.
    let kdfParams: KdfParamsResponse?
    let encryptedKeys: EncryptedKeysResponse?
    let sharingPublicKey: String?
    let signingPublicKey: String?

    var keysToOpen: SignInKeys? {
        SignInKeys(kdfParams: kdfParams, encryptedKeys: encryptedKeys,
                   sharingPublicKey: sharingPublicKey, signingPublicKey: signingPublicKey)
    }

    private enum CodingKeys: String, CodingKey {
        case accessToken, refreshToken, twoFactorToken, availableMethods, preferredMethod
        case serverProof, kdfParams, encryptedKeys, sharingPublicKey, signingPublicKey
        case requires2fa
        /// What `.convertFromSnakeCase` actually makes of `requires_2fa` on
        /// the iOS 26 runtime: it capitalizes the first LETTER of "2fa", not
        /// its first character, so the key is `requires2Fa`, not
        /// `requires2fa`. Missed, the flag decodes as nil, `login()` takes
        /// neither branch, and a 2FA account cannot sign in at all. Both
        /// spellings are read so no Foundation's casing rule can drop it.
        case requires2Fa
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try container.decodeIfPresent(String.self, forKey: .accessToken)
        refreshToken = try container.decodeIfPresent(String.self, forKey: .refreshToken)
        twoFactorToken = try container.decodeIfPresent(String.self, forKey: .twoFactorToken)
        availableMethods = try container.decodeIfPresent([String].self, forKey: .availableMethods)
        preferredMethod = try container.decodeIfPresent(String.self, forKey: .preferredMethod)
        requires2fa = try container.decodeIfPresent(Bool.self, forKey: .requires2fa)
            ?? container.decodeIfPresent(Bool.self, forKey: .requires2Fa)
        serverProof = try container.decodeIfPresent(String.self, forKey: .serverProof)
        kdfParams = try container.decodeIfPresent(KdfParamsResponse.self, forKey: .kdfParams)
        encryptedKeys = try container.decodeIfPresent(EncryptedKeysResponse.self, forKey: .encryptedKeys)
        sharingPublicKey = try container.decodeIfPresent(String.self, forKey: .sharingPublicKey)
        signingPublicKey = try container.decodeIfPresent(String.self, forKey: .signingPublicKey)
    }
}

/// The keys a sign-in opens, as its own reply carries them (SRP step 2, or the
/// 2FA step after it): the auth server's login-reply shapes, with the account's
/// public keys beside the wrapped ones. nil when the reply has none.
struct SignInKeys: Equatable {
    let keys: EncryptedKeysResponse
    let kdf: KdfParamsResponse

    init?(kdfParams: KdfParamsResponse?, encryptedKeys: EncryptedKeysResponse?,
          sharingPublicKey: String?, signingPublicKey: String?) {
        guard let kdfParams, let encryptedKeys else { return nil }
        kdf = kdfParams
        keys = EncryptedKeysResponse(
            masterKey: encryptedKeys.masterKey, sharingPrivateKey: encryptedKeys.sharingPrivateKey,
            signingPrivateKey: encryptedKeys.signingPrivateKey,
            sharingPublicKey: encryptedKeys.sharingPublicKey ?? sharingPublicKey,
            signingPublicKey: encryptedKeys.signingPublicKey ?? signingPublicKey)
    }
}

/// `POST /api/v1/auth/login/2fa`'s answer: the session's tokens and, like
/// SRP step 2's success branch, the keys to open.
struct TwoFactorLoginResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let kdfParams: KdfParamsResponse?
    let encryptedKeys: EncryptedKeysResponse?
    let sharingPublicKey: String?
    let signingPublicKey: String?

    var keysToOpen: SignInKeys? {
        SignInKeys(kdfParams: kdfParams, encryptedKeys: encryptedKeys,
                   sharingPublicKey: sharingPublicKey, signingPublicKey: signingPublicKey)
    }
}

/// Response to the SRP step-up (reauthStep2). `server_proof` /
/// `reauth_token` are mapped from snake_case by the decoder's
/// convertFromSnakeCase strategy (matching the SRPStep*Response
/// structs), so no explicit CodingKeys — declaring them here would
/// double-convert and fail the match.
struct ReauthStep2Response: Codable {
    /// Server's SRP proof M2: checked before the reply is used.
    let serverProof: String?
    /// Short-lived token the client hands to DELETE /api/v1/auth/me
    /// in place of the password. Required — its absence is an error.
    let reauthToken: String
    /// What the password that just proved opens: the same shapes as the login
    /// reply, for THAT credential. Absent only for an account with no keys at
    /// all. The login reply's `encrypted_keys` carries no public keys (they
    /// are optional on `EncryptedKeysResponse`); they come at the top level,
    /// as at login.
    var kdfParams: KdfParamsResponse? = nil
    var encryptedKeys: EncryptedKeysResponse? = nil
    var sharingPublicKey: String? = nil
    var signingPublicKey: String? = nil

    /// The keys to open, with the account's public keys beside them (the
    /// signing-key check sign-in makes needs the server's public key).
    var keysToOpen: EncryptedKeysResponse? {
        guard let keys = encryptedKeys else { return nil }
        return EncryptedKeysResponse(
            masterKey: keys.masterKey, sharingPrivateKey: keys.sharingPrivateKey,
            signingPrivateKey: keys.signingPrivateKey,
            sharingPublicKey: keys.sharingPublicKey ?? sharingPublicKey,
            signingPublicKey: keys.signingPublicKey ?? signingPublicKey)
    }
}

struct Verify2FARequest: Encodable {
    /// Serialises as `two_factor_token` under .convertToSnakeCase, the name
    /// the server expects.
    let twoFactorToken: String
    let code: String
    /// "totp" or "passkey". This screen is the code entry, so totp.
    let method: String
}


struct AuthResponse: Codable {
    let accessToken: String
    // Optional because `/auth/refresh` returns ONLY {access_token, refresh_token}
    // — no `user_id` — and the legacy JWT path can return just {access_token}.
    // Declared required, they would make EVERY refresh response fail to decode
    // ("decode failed" banner), which would also abort performTokenRefresh
    // before it could stamp the grace window → the cold-start refresh storm.
    // Login / 2FA responses still carry all three; this only relaxes the decode.
    let refreshToken: String?
    let userId: String?
}

struct UpdateProfileRequest: Encodable {
    let displayName: String
}

/// The whole of what `PATCH /api/v1/auth/me` returns:
/// `{ "display_name": <string or null> }`.
///
/// Deliberately its own type rather than a reuse of `User`. The server sends
/// no id, no email and no created_at, all of which `User` requires — so
/// decoding that route's reply as a `User` fails on a request that in fact
/// succeeded, and the user is told their rename failed after it worked.
/// `displayName` is optional because the server's field is nullable.
struct UpdateDisplayNameResponse: Decodable {
    let displayName: String?
}

struct VerifyEmailRequest: Encodable {
    let code: String
}

struct EmailStatusResponse: Codable {
    /// True once the user has clicked the link in their inbox. Maps to
    /// the server's `email_verified` field via convertFromSnakeCase.
    let emailVerified: Bool
    /// True while a verification email is in flight (initial signup or
    /// after a resend). Not surfaced in the UI, but useful for
    /// distinguishing "haven't tapped" from "no email sent" states.
    let pendingVerification: Bool?
}

// Circles
//
// Wire format mirrors the server's circle routes. Field naming uses
// camelCase here because the APIService decoder runs convertFromSnakeCase.

/// Envelope-encrypted payload: a fresh msg_key per message, the ciphertext
/// encrypted under msg_key, and msg_key itself wrapped with the circle key.
/// The server stores everything base64-encoded; the iOS SDK unwrap helper
/// wants hex, so callers convert before invoking
/// `cryptoManager.unwrapAndDecryptLocation` / `unwrapAndDecryptPlace`.
struct EncryptedPayloadResponse: Codable, Equatable {
    let nonce: String
    let ciphertext: String
    /// Either "" (current circle key), "s:{uuid}" (session key), or a circle
    /// key version. Empty means the wrapper is the active circle key.
    let keyId: String?
    let wrappedMsgKey: String?
    let wrappedMsgKeyNonce: String?
}

struct CreateCircleRequest: Encodable {
    let encryptedName: EncryptedBlobRequest
    let encryptedCircleKey: EncryptedBlobRequest
    let ephemeralPublicKey: String
    /// The creator's answer to the location notice: no circle without it.
    let locationConsent: LocationConsentGrant?
    /// The id the server reserved for this account, and the circle's genesis
    /// record, which binds it. Together or neither; omitted on the wire when
    /// nil.
    var circleId: String? = nil
    var genesis: RefreshRecordWire? = nil
}

/// A refresh record as the server takes and serves it: the wire bytes (the
/// body, the key tag, and a transition's anchor tag) and the signature, hex.
struct RefreshRecordWire: Codable, Equatable {
    let record: String
    let signature: String
}

struct RefreshRecordsRequest: Encodable {
    let since: [String: Int]
}

struct RefreshRecordsPage: Decodable {
    /// Every circle this account is an active member of.
    let circles: [CircleRefreshRecords]
    let more: Bool
}

struct CircleRefreshRecords: Decodable {
    let circleId: String
    /// Above `since`, oldest first.
    let records: [ServedRefreshRecord]
    /// The active members' heads, this account's own included; served with
    /// the circle's last page only.
    let heads: [ServedCircleHead]
    /// Every record above `since` and the heads are in this reply.
    let complete: Bool
}

struct ServedRefreshRecord: Decodable, Equatable {
    let version: Int
    let record: String
    let signature: String
}

struct ServedCircleHead: Decodable, Equatable {
    let userId: String
    let head: String
    let signature: String
}

struct PutCircleHeadRequest: Encodable {
    let head: String
    let signature: String
}

struct PutCircleHeadResponse: Decodable {
    let stored: Bool
}

struct ReservedCircleId: Decodable {
    let circleId: String
}

/// A consent to location sharing sent WITH the request it is a condition of —
/// joining or creating — so the membership and the consent are one
/// transaction. The server stamps its own notice version and digest; this
/// names the version that was on screen, recorded beside them.
struct LocationConsentGrant: Encodable, Equatable {
    let clientNoticeVersion: String?
    let surface: String

    init(_ shown: ShownNotice?) {
        clientNoticeVersion = shown?.version
        surface = "ios"
    }
}

struct RotateKeysRequest: Encodable {
    /// nil: left out (never null), and the server keeps the stored name
    /// (`CircleManager.NameToSeal.keepStored`).
    let encryptedName: EncryptedBlobRequest?
    let memberKeys: [MemberKeyUpdateRequest]
    /// CAS guard: server fails with CONFLICT if this doesn't match the
    /// circle's current key_version.
    let expectedKeyVersion: Int?
    /// Old key encrypted with the new key so members can derive previous
    /// versions for historical data.
    let keyChainLink: KeyChainLinkRequest?
    /// Active members deliberately left without a wrap of the new key —
    /// `pending_members`, same meaning as on eject-and-rotate. nil when none.
    var pendingMembers: [String]? = nil
    /// The change's refresh record, required on a circle that has records
    /// (and a transition's, its first). Omitted when nil.
    var refreshRecord: RefreshRecordWire? = nil
    /// The owner's hand-over, in this rotation's own transaction
    /// (`transfer_to`): only with the record that names this member owner
    /// (`CircleManager.RecordedChange.transferTo`). Omitted when nil.
    var transferTo: String? = nil
}

struct MemberKeyUpdateRequest: Encodable {
    let userId: String
    let encryptedCircleKey: EncryptedBlobRequest
    let ephemeralPublicKey: String
    /// Ed25519 signature over the wrap context (hex). Optional for back-compat,
    /// but a recipient on the strict-verify path rejects an unsigned wrap once
    /// the signer is pinned, so omitting it breaks cross-client key rotation.
    let wrapSignature: String?
}

struct KeyChainLinkRequest: Encodable {
    let fromVersion: Int
    let toVersion: Int
    let encryptedKey: String
    let nonce: String
}

struct EjectAndRotateRequest: Encodable {
    let ejectUserId: String
    /// Must be EXACTLY one past the circle's current key_version — the server
    /// refuses anything else so a caller cannot jump the version to i32::MAX
    /// and make rotation permanently impossible for the circle. Take it from
    /// the SDK bundle rather than computing it here.
    let newKeyVersion: Int
    /// Every remaining active member, and nobody else. The server rejects the
    /// request if the set does not match exactly — a missing member would lose
    /// decrypt access, and including the ejected user would defeat the point.
    let memberWraps: [EjectMemberWrapRequest]
    let encryptedName: EncryptedBlobRequest?
    let keyChainLink: KeyChainLinkRequest?
    /// Remaining members this device DELIBERATELY gives no wrap of the new key
    /// (`pending_members`): an unapproved key change, a member the owner has
    /// not approved for access yet, or someone the server lists for keys who is
    /// not on the roster. Every remaining member must be in `memberWraps` or
    /// here. nil (omitted on the wire) when there are none, so an ordinary
    /// eject's body carries no such field.
    var pendingMembers: [String]? = nil
    /// The eject's refresh record, on a circle that has records.
    var refreshRecord: RefreshRecordWire? = nil
}

/// One member's rewrap of the new circle key.
///
/// NOTE the shape: flat hex fields, NOT the nested `EncryptedBlobRequest` that
/// `MemberKeyUpdateRequest` uses on `/rotate-keys`. This endpoint takes
/// `encrypted_circle_key` and `circle_key_nonce` side by side, so the SDK's
/// `encryptedCircleKey` has to be split across the two.
struct EjectMemberWrapRequest: Encodable {
    let userId: String
    let encryptedCircleKey: String
    let circleKeyNonce: String
    let ephemeralPublicKey: String
    let wrapSignature: String?
}

struct EjectAndRotateResponse: Codable {
    let newKeyVersion: Int
    let ejectedUserId: String
}

/// Response from `POST /circles/:id/members/:user_id/revoke-access`.
///
/// `warning` is the server's wording for what a removal without a rotation
/// leaves behind. Optional so an older server simply omits it — in which case
/// we state the bare fact rather than inventing reassurance. It is shown
/// verbatim: the paraphrase everyone reaches for is "they no longer have
/// access", which is true of the API and false of the data they already hold.
///
/// Decoded with .convertFromSnakeCase, so `revoked_user_id` arrives as
/// `revokedUserId` and needs no CodingKeys.
struct RevokeAccessResponse: Codable {
    let revokedUserId: String
    let keyRotationNeeded: Bool?
    let warning: String?
}

/// A live claim on a circle's ownership.
///
/// Mirrors the server's ownership-claim response, which serializes six
/// always-present fields:
/// `claim_id`, `circle_id`, `claimant_user_id`, `status`, `requested_at`,
/// `resolves_at`. Decoded with `.convertFromSnakeCase`, so no CodingKeys.
///
/// Only `claimId` is required, and that is a deliberate split:
///
///  * Everything else is DISPLAY. This struct is what the owner's refuse screen
///    is built from, and a screen that throws rather than renders is a circle
///    quietly transferred fourteen days later. Losing the claimant's name or
///    even the deadline must degrade the wording, not blank the screen.
///  * `claimId` is required because something has to be. `decodeResponse` tries
///    `APIResponse<T>` first and falls back to decoding the whole envelope as
///    `T`; an all-optional struct would decode from `{"success":true,"data":null}`
///    without complaint and report a claim that is not there.
///
/// The two timestamps are raw Strings, not Dates. `APIService`'s date strategy
/// demands fractional seconds, and the server emits sub-second digits only when
/// they are NONZERO — so a claim opened on an exact second would throw on the
/// one screen that must not fail. They are parsed defensively at the call site
/// instead, the same way `NotificationResponse.createdAt` is.
struct OwnershipClaimResponse: Codable, Equatable {
    let claimId: String
    let circleId: String?
    let claimantUserId: String?
    /// 'pending' | 'completed' | 'refused' | 'withdrawn' | 'void'. The GET
    /// only ever returns pending rows, so a row that came back at all is
    /// live.
    let status: String?
    let requestedAt: String?
    /// When SILENCE completes the claim. The server reads it from the stored
    /// row rather than recomputing it, so the countdown the owner is watching
    /// cannot move under them if the default window is ever changed.
    let resolvesAt: String?

    /// The deadline as a real instant, or nil when the server did not send one
    /// (or sent something unparseable). Callers render it in the device's local
    /// timezone; the string on the wire is UTC.
    var deadline: Date? { resolvesAt.flatMap(Self.parseTimestamp) }

    var requested: Date? { requestedAt.flatMap(Self.parseTimestamp) }

    /// A row from the GET is live by construction; the POST echoes "pending".
    /// A nil status therefore reads as pending rather than as "unknown, show
    /// nothing" — the failure that hides a countdown from the person it is
    /// running against.
    var isPending: Bool { (status ?? "pending") == "pending" }

    /// Parse an RFC3339 timestamp with OR without fractional seconds. chrono
    /// serializes `DateTime<Utc>` with sub-second digits only when they are
    /// nonzero, so a formatter configured for one form silently rejects the
    /// other. Returns nil rather than throwing so a bad timestamp costs the
    /// date in the sentence and nothing else.
    static func parseTimestamp(_ s: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: s) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: s)
    }
}

struct RotateKeysResponse: Codable {
    let newKeyVersion: Int
    /// Server returns this when another client raced us and won — the
    /// caller should re-fetch circle data; no further action needed.
    let alreadyRotated: Bool?
}

/// `PUT /api/v1/circles/:id/display-name`: `{"encrypted_display_name": {nonce, ciphertext}}`.
struct SetCircleDisplayNameRequest: Encodable {
    let encryptedDisplayName: EncryptedBlobRequest
}

struct UpdateCircleRequest: Encodable {
    let encryptedName: EncryptedBlobRequest
    /// Omitted when nil (synthesized `encodeIfPresent`): an older server sees
    /// the body it always did.
    var keyVersion: Int? = nil
}

struct PseudonymBackfillRequest: Encodable {
    /// Hex-encoded user pseudonyms (32 chars each) — output of
    /// SDK CryptoManager.deriveUserPseudonymsAllVersions.
    let pseudonyms: [String]
}

struct PseudonymBackfillResponse: Codable {
    let inserted: Int
    let skipped: Int
}

struct UserPublicKeyResponse: Codable {
    let email: String
    /// Absent when the email isn't registered (or hasn't published a key yet).
    let sharingPublicKey: String?
    /// Invitee's Ed25519 verifying key. Required to wrap the
    /// circle key with a signed envelope under the SDK API.
    let signingPublicKey: String?
    /// Server-resolved user_id for the email. Populated when the
    /// account exists (regardless of whether they've published keys).
    let userId: String?
}

struct RevocationStatus: Codable {
    /// False when this pod failed open recently enough that a sign-out may not
    /// be taking effect yet. Per-pod on the server, so `false` is authoritative
    /// and `true` is not.
    let enforcing: Bool
}

struct MemberPublicKeyResponse: Codable {
    /// In its one form (`ServedId`); a row naming nobody is dropped.
    @ServedId var userId: String
    let sharingPublicKey: String
    /// Member's Ed25519 verifying key. Required for the signed
    /// key-rotation flow that wraps the new circle key for each
    /// member.
    let signingPublicKey: String?
    /// The version of this member's STORED wrap; absent when they hold none
    /// (a keyless join). A member is OWED the current key when this is absent
    /// or below the circle's `key_version` — and an owed member gets the key
    /// only after this device's user approves it. nil from an older server,
    /// which reports it for nobody.
    var keyVersion: Int? = nil
    /// Present only for members owed the current key, for the approval prompt.
    var email: String? = nil
}

struct InviteByEmailRequest: Encodable {
    let email: String
    /// Pre-encrypted circle key for known invitees (otherwise the invitee
    /// supplies a key bundle when they accept).
    let encryptedCircleKey: EncryptedBlobRequest?
    let ephemeralPublicKey: String?
    /// The circle's name, for the e-mail to an address with NO account: the
    /// only notice that person gets. nil for every account
    /// (`CircleManager.circleNameForInvitation`). The server puts it in the
    /// e-mail's body and stores nothing.
    let circleName: String?
    /// Ed25519 signature over the pre-encrypted circle-key wrap (hex), present
    /// when a key is pre-encrypted for a known invitee.
    let wrapSignature: String?
    /// The signed invitation: kind 1 when the lookup found an account, kind 2
    /// otherwise. Every member's app checks it before letting the newcomer in.
    var statement: String? = nil
    var statementSignature: String? = nil
    /// A waiting change's id: a resend of it is answered 409
    /// request_already_done, and `statementsHeld` then says which statement is
    /// held. Never sent from a plain tap.
    var clientRequestId: String? = nil
}

struct HeldStatementsRequest: Encodable {
    /// 16 bytes of hex each, at most 20.
    let statementIds: [String]
}

struct HeldStatementsResponse: Decodable {
    let held: [HeldStatement]
}

struct HeldStatement: Decodable, Equatable {
    let statementId: String
    /// "pending_invitation", "member_invitation" or "vouch".
    let heldAs: String
}

struct UpdateMemberRoleRequest: Encodable {
    /// One of "owner", "admin", "member".
    let role: String
}

struct TransferOwnershipRequest: Encodable {
    let newOwnerId: String
}

struct AcceptInviteRequest: Encodable {
    let encryptedCircleKey: EncryptedBlobRequest?
    let ephemeralPublicKey: String?
    /// Joining is agreeing: the answer to the location notice, in the same
    /// request.
    let locationConsent: LocationConsentGrant?
}

/// One invite this circle has sent that is still outstanding.
///
/// Timestamps are DAY BUCKETS, not instants — days since the Unix epoch,
/// deliberately coarse so the server cannot be asked exactly when somebody was
/// invited. Render them as dates, never as times.
struct PendingInviteResponse: Codable, Identifiable, Equatable {
    let id: String
    let inviteType: String
    /// Absent when the invite was not addressed to an email.
    let targetEmail: String?
    let status: String
    let createdDayBucket: Int
    let expiresDayBucket: Int
    /// The inviter managed to wrap the circle key at invite time, which is only
    /// possible when the invitee already had an account with a published
    /// sharing key. False means the recipient joins keyless and waits for a
    /// member's device to distribute a wrap.
    let hasEncryptedKey: Bool
    /// For owners/admins: who signed it, the account it is bound to, the
    /// signed statement itself, and whether it waits to be renewed.
    /// `needs_renewal` alone (a wrap the circle rotated past) is never acted
    /// on: nothing is re-signed silently.
    var invitedBy: String? = nil
    var targetUserId: String? = nil
    var statement: String? = nil
    var statementSignature: String? = nil
    var keyVersion: Int? = nil
    var renewalRequested: Bool? = nil
    var needsRenewal: Bool? = nil

    /// Midnight UTC of the bucket. `Date` and not a formatted string so the
    /// view can localise it; the underlying value has day precision either way.
    var expiresOn: Date {
        Date(timeIntervalSince1970: TimeInterval(expiresDayBucket) * 86_400)
    }

    var invitedOn: Date {
        Date(timeIntervalSince1970: TimeInterval(createdDayBucket) * 86_400)
    }

    /// The note under an invitation that carries no key: when the circle
    /// opens for them, never why it carries none. The list knows of an
    /// account only for an invitation bound to one (`targetUserId`), and one
    /// sent to an address may still reach an account, so "They had no
    /// account yet" would be wrong for invitations to accounts.
    var keylessNote: String? {
        hasEncryptedKey ? nil : "When they join, the circle opens for them as soon as another member's app is online."
    }
}

struct NotificationResponse: Codable {
    let id: String
    let circleId: String?
    let notificationType: String
    let title: String
    let body: String?
    let metadata: [String: AnyCodableValue]?
    let isRead: Bool
    let createdDayBucket: Int?
    /// Exact creation timestamp (server clock, RFC3339 string). Clients
    /// render the relative "Today"/"Yesterday" label from this in the
    /// device's LOCAL timezone — the day bucket is UTC-based and rolls
    /// over at UTC midnight, mislabeling events for users west of UTC.
    /// Decoded as a raw String (not Date) and parsed defensively at the
    /// call site so an unexpected precision/format never breaks the whole
    /// list decode — absent/unparseable just degrades to the bucket
    /// label. Nullable for rows cached without this field.
    /// Mirrors the Android app.
    let createdAt: String?
}

struct NotificationsListResponse: Codable {
    let notifications: [NotificationResponse]
    let unreadCount: Int
    let nextCursor: String?
    let hasMore: Bool?
}

struct DeleteAccountRequest: Encodable {
    /// Short-lived SRP step-up token (`reauth_token` on the wire via the
    /// encoder's convertToSnakeCase). Sent in place of the raw password
    /// so the plaintext credential never leaves the device on delete.
    let reauthToken: String?
    /// Legacy raw-password field, kept optional. The reauth path leaves it
    /// nil and the synthesized Encodable omits nil optionals
    /// (encodeIfPresent), so no `password` key is emitted at all.
    let password: String?
    let pseudonyms: [DeletionPseudonymRequest]?
    /// The user's explicit answer to the 409 the server returns when the account
    /// still holds credit it paid for. Deleting destroys it — the record goes
    /// with the account — so the server refuses the first attempt rather than
    /// doing it quietly. nil on a first attempt, and the synthesized Encodable
    /// omits nil optionals so no key is emitted at all.
    let forfeitCreditBalance: Bool?

    init(
        reauthToken: String? = nil,
        password: String? = nil,
        pseudonyms: [DeletionPseudonymRequest]?,
        forfeitCreditBalance: Bool? = nil
    ) {
        self.reauthToken = reauthToken
        self.password = password
        self.pseudonyms = pseudonyms
        self.forfeitCreditBalance = forfeitCreditBalance
    }
}

struct DeletionPseudonymRequest: Encodable {
    let circleId: String
    let userPseudonym: String
}

/// What deleting the account did to the user's billing.
///
/// The server cancels every subscription it can reach. Two it cannot, and both
/// leave money moving after the account is gone:
///   - an App Store subscription, which only the customer can stop, in their
///     Apple account settings — Apple offers no server-side call
///   - a cancellation that failed at the provider, which deliberately does not
///     block the deletion, because erasure is a right and a payment API outage
///     is not a reason to refuse it
///
/// Every field has a default so a build running against an older backend
/// decodes rather than throwing — a delete that succeeded must never
/// surface as a failure because the response gained a field.
struct DeleteAccountResponse: Codable {
    let deleted: Bool
    let subscriptionsCanceled: Int
    let appStoreSubscriptionsRemaining: Int
    let subscriptionCancellationsFailed: Int
    /// What happened to the location and note data: "completed",
    /// "not_applicable", "queued" or "failed", so a screen can show
    /// which happened. Defaulted rather than required so an older
    /// backend decodes.
    let dataErasure: String
    /// Key off this rather than re-deriving it from the counts.
    let billingNeedsAttention: Bool

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deleted = try c.decode(Bool.self, forKey: .deleted)
        subscriptionsCanceled = try c.decodeIfPresent(Int.self, forKey: .subscriptionsCanceled) ?? 0
        dataErasure = try c.decodeIfPresent(String.self, forKey: .dataErasure) ?? "completed"
        appStoreSubscriptionsRemaining = try c.decodeIfPresent(Int.self, forKey: .appStoreSubscriptionsRemaining) ?? 0
        subscriptionCancellationsFailed = try c.decodeIfPresent(Int.self, forKey: .subscriptionCancellationsFailed) ?? 0
        billingNeedsAttention = try c.decodeIfPresent(Bool.self, forKey: .billingNeedsAttention) ?? false
    }
}

struct CreateDeviceRequest: Encodable {
    /// Client-provided uuid so re-registration is idempotent. The
    /// backend dedupes by this id and returns the existing row.
    let deviceId: String
    let encryptedDeviceType: EncryptedBlobRequest
    let encryptedDeviceName: EncryptedBlobRequest
    /// Hex-encoded APNs token; the backend stores it on the device row
    /// for later push delivery.
    let pushToken: String?
    /// One of "apns", "fcm", "unifiedpush".
    let pushType: String?
    /// Required when pushType == "unifiedpush".
    let pushEndpoint: String?
}

struct UpdatePushTokenRequest: Encodable {
    let pushToken: String?
    let pushType: String
    let pushEndpoint: String?
}

struct DeviceResponse: Codable {
    let id: String
    let encryptedDeviceType: EncryptedBlobResponse
    let encryptedDeviceName: EncryptedBlobResponse
    let isActive: Bool
    let lastSeenDayBucket: Int?
    let dayBucket: Int
    /// Whether the server holds a push registration for this device.
    /// FALSE: registered with no push route, and every device-gated
    /// endpoint (ingest, needs-attention, check-ins) answers "Device not
    /// found" until a POST carries a token. nil from an older server,
    /// which doesn't say.
    var pushRegistered: Bool? = nil
}

struct AttestationChallengeResponse: Codable {
    let challenge: String
    /// Backend echoes the platform it expects you to attest with —
    /// always "apple" for iOS. RFC3339 expiry.
    let method: String
    let expiresAt: String
}

struct AppleAttestVerifyRequest: Encodable {
    /// Base64-encoded attestation object from DCAppAttestService.
    let attestation: String
    let challenge: String
    let keyId: String
}

struct AttestationVerifyResponse: Codable {
    let attestationToken: String
    let platform: String
    let expiresAt: String
}

struct SupportTicketRequest: Encodable {
    let subject: String
    let message: String
    /// One of "account", "track", "billing", etc. Default "general" on the
    /// server; this app always sends "track" to keep tickets routed to
    /// the right support inbox.
    let category: String
}

struct SupportTicketResponse: Codable {
    /// Support conversation id (numeric on the server; mirror as Int).
    let ticketId: Int
    let message: String
}

struct UnreadCountResponse: Codable {
    let count: Int
}

/// Type-erased Codable wrapper for the open-ended `metadata` map on
/// NotificationResponse. The backend ships this as free-form JSON,
/// so we accept any of the JSON primitives + arrays/objects.
enum AnyCodableValue: Codable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([AnyCodableValue])
    case object([String: AnyCodableValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let v = try? container.decode(Bool.self) { self = .bool(v); return }
        if let v = try? container.decode(Int.self) { self = .int(v); return }
        if let v = try? container.decode(Double.self) { self = .double(v); return }
        if let v = try? container.decode(String.self) { self = .string(v); return }
        if let v = try? container.decode([AnyCodableValue].self) { self = .array(v); return }
        if let v = try? container.decode([String: AnyCodableValue].self) { self = .object(v); return }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Unsupported JSON value in notification metadata"
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let v): try container.encode(v)
        case .int(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .string(let v): try container.encode(v)
        case .array(let v): try container.encode(v)
        case .object(let v): try container.encode(v)
        }
    }
}

struct ReceivedInviteResponse: Codable {
    let id: String
    /// In its one form; an invitation to an id no circle has (the personal
    /// key's slot, or no UUID) is dropped from the list (`ServedCircleId`).
    @ServedCircleId var circleId: String
    let invitedBy: String
    let inviteType: String
    let createdDayBucket: Int
    let expiresDayBucket: Int
    let hasEncryptedKey: Bool
    let circleName: String?
    let encryptedCircleName: String?
    let circleNameNonce: String?
    let inviterDisplayName: String?
    /// The signed invitation, hex; nil on an unsigned one. The app checks it
    /// names THIS account before accepting.
    var statement: String? = nil
    var statementSignature: String? = nil
    /// Reported as not naming this account (or refused as out of date) and
    /// waiting to be renewed by the circle.
    var renewalRequested: Bool? = nil
}


struct InviteCodeResponse: Codable {
    let inviteCode: String
    let expiresAt: Date
}

/// Response shape for `GET /api/v1/users/me/self-key`. Mirrors
/// the Android app's `CircleKeyBundleResponse` — the same payload it
/// uses for circle-key bundles. `encryptedCircleKey` is the wrap
/// pair (nonce + ciphertext) generated by the SDK's circle-key wrap;
/// importing it under the nil UUID enables decryption of every
/// payload stored under the user's self-tracking circle.
struct CircleKeyBundleResponse: Codable {
    let circleId: String
    let encryptedCircleKey: EncryptedBlobResponse
    let ephemeralPublicKey: String
    let keyVersion: Int
    /// Wrap-signature metadata (optional). The ids in
    /// their one form (`ServedOptionalId`): the SDK tells this account's own
    /// copy by them.
    @ServedOptionalId var senderUserId: String?
    @ServedOptionalId var recipientUserId: String?
    let wrapSignature: String?
    let senderSigningPubkey: String?
    /// The account's recorded personal pseudonym: the PUBLISHED copy's.
    /// The server's word — it only decides WHEN to look.
    var userPseudonym: String? = nil
    /// Another device of this account could not use this copy (≤ 7 days).
    var republishRequested: Bool? = nil
}

/// Body for `POST /api/v1/users/me/self-key` (the Android app's
/// `StoreSelfKeyRequest`). Sent on first sign-in for users who don't
/// have a self-tracking key yet.
struct StoreSelfKeyRequest: Encodable {
    let encryptedSelfKey: EncryptedBlobRequest
    let ephemeralPublicKey: String
    /// Hex Ed25519 signature over this wrap. nil is omitted on the wire, so
    /// an unsigned publish carries no such field.
    var wrapSignature: String? = nil
    /// The account's pseudonym under exactly this key: the server
    /// records it atomically with these bytes. nil is omitted.
    var userPseudonym: String? = nil
    /// "I know a key is there and mean to replace it" — only a republish of the
    /// key this device holds, over a copy that does not open here.
    var replace: Bool? = nil
}

/// Body for `PUT /api/v1/circles/{id}/invites/{invite_id}/statement`.
struct RenewInvitationRequest: Encodable {
    let statement: String
    let statementSignature: String
    var encryptedCircleKey: EncryptedBlobRequest? = nil
    var ephemeralPublicKey: String? = nil
    var wrapSignature: String? = nil
}

struct RenewInvitationResponse: Decodable {
    let renewed: Bool
    var keyVersion: Int? = nil
}

/// `POST /api/v1/users/me/self-key/unreadable`.
struct SelfKeyUnreadableRequest: Encodable {
    /// sha256 over the served copy's RAW bytes ciphertext ‖ nonce ‖ ephemeral.
    let copySha256: String
}

struct SelfKeyUnreadableResponse: Decodable {
    /// Whether the copy is marked for republishing.
    let requested: Bool
    /// Whether other phones were woken this time (once per distinct copy, and
    /// at most once per 15 minutes per account).
    var woken: Bool? = nil
    /// The report was about a copy that is no longer stored: re-read.
    var copyChanged: Bool? = nil
}

/// Body for `PUT /api/v1/users/me/self-key/pseudonym`.
struct SelfKeyPseudonymRequest: Encodable {
    let keyVersion: Int
    let encryptedCircleKey: EncryptedBlobRequest
    let ephemeralPublicKey: String
    let userPseudonym: String
}

struct MemberStatementRequest: Encodable {
    let statement: String
    let statementSignature: String
}

struct SignOwnWrapResponse: Decodable {
    let signed: Bool
}

/// `POST …/members/{user_id}/update-request`.
struct MemberUpdateRequestResponse: Decodable {
    /// They have been told, now or within the last day.
    let requested: Bool
    /// This call sent the push and the email.
    let sent: Bool
}

/// GET /api/v1/circles/keys — the backend's oblivious key-distribution shape.
/// These field names + types MUST match what the server actually emits —
/// `encrypted_circle_key` is a {nonce, ciphertext} OBJECT (not a bare
/// `encrypted_key` string), the wrap's ephemeral X25519 key is
/// `ephemeral_public_key` (not `sender_public_key`), and the version is
/// `key_version` (not `version`). Any other names silently fail to decode,
/// and historical keys never import. Mirrors the identical
/// `CircleKeyBundleResponse` used for the self-key endpoint.
///
/// `key_chain` is NOT optional to honour. A member's row holds ONE wrapped key —
/// the current version, overwritten on every rotation — so this bundle is the
/// only wrap the server has for a rotated circle, and every older version is
/// reachable solely through the chain links (`from_version` → `to_version`,
/// the older key sealed under the newer). The SDK does not re-derive chains
/// from the versions it stores: `importKeyChainLink` is the only way an older
/// version enters the SDK on the read path. Without it, anything sealed under
/// an older version stays unreadable — e.g. an owner's display name sealed at
/// v1 shows as "Member" on a device that joined at v2. The web app walks the
/// same chain; Android does it in its key import.
struct CircleKeyResponse: Codable {
    let circleId: String
    let encryptedCircleKey: EncryptedBlobResponse
    let ephemeralPublicKey: String
    let keyVersion: Int
    /// Older key versions, each sealed under the next newer one. Absent (nil or
    /// empty) on a never-rotated circle and on the self-key bundle.
    let keyChain: [KeyChainLinkResponse]?
    /// Wrap metadata (optional; absent on legacy and self wraps → the SDK
    /// grace-accepts). The signer's signing key is NOT carried on the wire;
    /// it's resolved locally from the pinned member directory via
    /// `senderUserId`. Maps `wrap_signature` / `sender_user_id`; the id in its
    /// one form.
    let wrapSignature: String?
    @ServedOptionalId var senderUserId: String?
}

/// One link of a circle's key chain as the backend serves it (`KeyChainLink`):
/// the key for `to_version` encrypted under the key for `from_version`, hex
/// nonce and ciphertext — exactly what the SDK's `importKeyChainLink` takes.
struct KeyChainLinkResponse: Codable, Equatable {
    let fromVersion: Int
    let toVersion: Int
    let encryptedKey: String
    let nonce: String
}

/// One active session key for a circle, returned by
/// GET /api/v1/circles/:circle_id/session-keys/:session_key_id.
/// `encryptedSessionKey` / `keyNonce` are hex;
/// `expiresAt` is an RFC3339 timestamp. Extra server fields (user_id, device_id,
/// created_at) are ignored. Field names arrive snake_case and are mapped by the
/// actor's convertFromSnakeCase decoder.
struct SessionKeyResponse: Codable {
    let sessionKeyId: String
    let encryptedSessionKey: String
    let keyNonce: String
    let keyVersion: Int
    let expiresAt: String
}

struct PrivacySettingsRequest: Encodable {
    /// One of "exact", "approximate", "paused".
    let sharingMode: String
    /// Required when sharingMode == "approximate".
    let approximateRadiusMiles: Int?
    /// RFC3339 timestamp; auto-revert to exact after this point.
    let approximateUntil: String?
    /// RFC3339 timestamp; auto-resume sharing after this point.
    let pausedUntil: String?
    let shareRealtime: Bool
    let shareHistory: Bool
    let shareBattery: Bool
    let primaryDeviceId: String?
    let primaryDevicePseudonym: String?
    let showAllDevices: Bool
    /// Opt-out consent: when false, other members can't set arrival/
    /// departure alerts targeting me in this circle.
    let allowAlertsOnMe: Bool
}

// Locations — wire shape mirrors the server's location routes.

struct LocationResponse: Codable {
    /// Plaintext user_id mapped from the per-circle pseudonym (server-side
    /// lookup is allowed here because circle members already know each
    /// other). May be absent for members the server hasn't resolved yet.
    let userId: String?
    /// Encrypted user_id for clients that prefer to decrypt the metadata
    /// themselves rather than trust the server-side pseudonym lookup.
    let encryptedUserId: EncryptedBlobResponse?
    let encryptedDeviceId: EncryptedBlobResponse?
    let dayBucket: Int
    let encryptedTimestamp: EncryptedBlobResponse?
    let encryptedPayload: EncryptedPayloadResponse
    /// One of "exact", "approximate", "paused". Paused entries are hidden from
    /// the map; an approximate member is drawn as an area (`ApproximateArea`).
    let sharingMode: String?
    /// Under "approximate", the member's radius in miles, varied ±20 % on every
    /// response (`approximate_radius_miles`).
    let approximateRadiusMiles: Double?
    /// Whether this member permits alerts about them in this circle
    /// (`allow_alerts_on_me`), as the server reported it ALONGSIDE THIS FIX.
    ///
    /// Plaintext beside the ciphertext, like `sharingMode`, because it is the
    /// server's own consent field rather than part of the sealed payload — and,
    /// like `sharingMode`, it is AN INSTRUCTION THE RECIPIENT CARRIES OUT. The
    /// blind server never sees a subscriber-side crossing and so cannot suppress
    /// it; this device is the only place the opt-out can be honoured on that path.
    ///
    /// `nil` = the backend did not say = ALLOWED. Absence permits at every consent
    /// gate in this system; reading it as denial would silently disable alerts for
    /// every member with no privacy row, which is the default state.
    let allowAlertsOnMe: Bool?
}

/// Wrapper for the latest-per-member endpoint (key rotation status piggy-backs).
struct LatestLocationsResponse: Codable {
    let locations: [LocationResponse]
    let keyRotation: KeyRotationStatus?
    /// Members who switched real-time sharing off in this circle and kept
    /// history on: the last location each shared, frozen (`last_known`).
    /// Only drawn, with "Location sharing off"; never judged. Omitted when
    /// empty, and by an older server.
    var lastKnown: [LocationResponse]? = nil
    /// The same `last_known` rows, their blobs as served: this account's own is
    /// what a re-seal finds and sends back. Read beside `lastKnown`, never
    /// encoded, and nil when it can't be read whole.
    var lastKnownServed: [ServedFrozenBlobs]? = nil

    private enum CodingKeys: String, CodingKey {
        case locations, keyRotation, lastKnown
    }
}

extension LatestLocationsResponse {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        locations = try container.decode([LocationResponse].self, forKey: .locations)
        keyRotation = try container.decodeIfPresent(KeyRotationStatus.self, forKey: .keyRotation)
        lastKnown = try container.decodeIfPresent([LocationResponse].self, forKey: .lastKnown)
        lastKnownServed = try? container.decodeIfPresent([ServedFrozenBlobs].self, forKey: .lastKnown)
    }
}

/// One `last_known` row's id and its two sealed blobs, the blobs as JSON exactly
/// as served: a re-seal sends them back untouched as `previous_*` for the
/// server's compare-and-swap, so a field this app doesn't model, or a value it
/// would write another way, still compares equal there.
struct ServedFrozenBlobs: Decodable {
    let userId: String?
    let encryptedPayload: AnyCodableValue
    let encryptedTimestamp: AnyCodableValue?
}

/// POST …/locations/last-known/reseal: this account's frozen row, found by
/// the bytes this phone sealed, and the same point sealed again.
struct ResealLastKnownRequest: Encodable {
    let devicePseudonym: String
    /// The row's blobs exactly as `/latest` serves them now (`ServedFrozenBlobs`).
    let previousEncryptedPayload: AnyCodableValue
    let previousEncryptedTimestamp: AnyCodableValue?
    /// The point sealed straight under the circle's current key: `key_id`
    /// "c:<version>", no wrap. The time likewise, present exactly when the row
    /// has one.
    let encryptedPayload: ResealBlob
    let encryptedTimestamp: ResealBlob?
}

/// A blob sealed straight under a circle key, as the re-seal route takes one.
struct ResealBlob: Encodable, Equatable {
    let nonce: String
    let ciphertext: String
    let keyId: String?
}

struct ResealLastKnownResponse: Decodable {
    /// The row is under the circle's current key now: just re-sealed, or already.
    let resealed: Bool
}

struct KeyRotationStatus: Codable {
    let rotationNeeded: Bool
    let deadline: String?
    let message: String?
}

struct HistoryLocationsResponse: Codable {
    let locations: [LocationResponse]
    let keyRotation: KeyRotationStatus?
    /// The caller's history entitlement in days, straight from the backend's
    /// `history_days_allowed`. A request for a LONGER range is clamped rather
    /// than refused, so this is the only thing that tells "your plan stops
    /// here" apart from "the data is missing". Without it, a free-tier user who
    /// picks "7d" would see two days and no explanation.
    ///
    /// OPTIONAL despite the server declaring it non-null: a required `Int`
    /// here would make the whole history decode throw against any backend that
    /// predates the field, turning a missing notice into a missing timeline.
    let historyDaysAllowed: Int?
    /// Set when the server's downsample overflowed its hard limit and dropped
    /// the OLDEST groups. The server omits it when false, so this must be
    /// optional too.
    let truncated: Bool?
}

// Places — wire shape mirrors the server's place routes.

struct PlaceResponse: Codable, Sendable {
    let id: String
    let userId: String?
    let circleId: String?
    let encryptedName: EncryptedBlobResponse
    let encryptedAddress: EncryptedBlobResponse?
    /// Place location ciphertext + nonce (hex). The wrapper key lives in
    /// the top-level `wrappedKey` / `wrappedKeyNonce` / `wrapViaCircle`
    /// fields rather than nested next to the ciphertext (different from
    /// the locations envelope shape).
    let encryptedLocation: EncryptedBlobResponse
    let radiusMeters: Int
    let icon: String?
    let color: String?
    /// OPTIONAL: the backend does not send `place_type` (or
    /// `boundary_radius`) — every row is just a place. A required `String`
    /// here would make the whole places decode fail. Defaults to "place" at
    /// the model.
    let placeType: String?
    /// Server-maintained: TRUE iff an active alert subscription targets this
    /// place. This — not place_type/boundary_radius — is the sole switch for
    /// whether the place is monitored for enter/leave crossings. Optional for
    /// decode resilience (default false if a response ever omits it). Mirrors
    /// the Android app's places.alerts_enabled.
    let alertsEnabled: Bool?
    let createdDayBucket: Int
    let updatedDayBucket: Int
    let encryptedNotes: EncryptedBlobResponse?
    let boundaryRadius: Int?
    let sharedCircles: [String]?
    let wrappedKey: String?
    let wrappedKeyNonce: String?
    /// Circle id whose symmetric key unwraps `wrappedKey`. For self-only
    /// places this is the self-tracking pseudo-circle.
    let wrapViaCircle: String?
    /// TRUE iff the current user OWNS this place (vs. received it as a share).
    /// Optional so an older backend that omits it still decodes.
    let isOwner: Bool?

    /// Whether a place with `sharedCircles` should appear in `circleId`'s list.
    /// Self-only places (empty/nil shares) show in every circle; otherwise the
    /// place shows only in circles it was explicitly shared to. Shared by
    /// `APIService.getPlaces` and `PlaceManager`'s local UI derive so
    /// both stay in lockstep.
    static func isVisible(sharedCircles: [String]?, in circleId: String) -> Bool {
        guard let shared = sharedCircles, !shared.isEmpty else { return true }
        return shared.contains(circleId)
    }
}

/// POST /api/v1/places.
///
/// A place has ONE geofence radius: the server takes `radius_meters` (an
/// integer, bounded to 50–25000) and nothing else about size. It silently
/// drops unknown fields, so a size sent under any other name (such as
/// `place_type` or `boundary_radius`) is ignored with a 200 and the place is
/// stored with whatever `radius_meters` said — no error anywhere on either
/// side.
struct CreatePlaceRequest: Encodable {
    let circleId: String?
    let encryptedName: EncryptedBlobRequest
    let encryptedAddress: EncryptedBlobRequest?
    let encryptedLocation: EncryptedBlobRequest
    /// The place's one geofence radius, in metres. This IS the alert ring, so
    /// it is the user's choice and must not be a placeholder.
    let radiusMeters: Int
    let icon: String?
    let color: String?
    let encryptedUserId: EncryptedBlobRequest?
    let encryptedNotes: EncryptedBlobRequest?
    /// Owner-side wrap of the per-place key under
    /// the user's self-key. Required for new personal places (where
    /// every field ciphertext was encrypted with the place key, not
    /// the circle key); server enforces both-or-neither.
    let wrappedKey: String?
    let wrappedKeyNonce: String?
}

/// Wrap the per-place key for a new recipient circle and POST to
/// `/api/v1/places/:id/share`. The server stores the wrap;
/// recipients see this place on subsequent
/// `/places` reads with `wrap_via_circle = circleId` and decrypt
/// via the same SDK unwrap path.
struct SharePlaceRequest: Encodable {
    let circleId: String
    let wrappedKey: String
    let wrappedKeyNonce: String
}

struct CreatePlaceAlertRequest: Encodable {
    let placeId: String
    /// The circle the subscriber set this alert in — lets the server
    /// route the notification, so an alert on a personal place shared to
    /// a circle still notifies. nil = derive from the place's circle.
    /// (Optional on the wire, for back-compat with older backends.)
    let circleId: String?
    /// Server-side reference for verification — encrypted variant is the
    /// authoritative one E2EE-wise. Pass nil for circle-wide alerts.
    let targetUserId: String?
    /// Always required; encrypts a sentinel like "all" for circle-wide.
    let encryptedTargetUserId: EncryptedBlobRequest
    /// Deprecated plaintext flags kept for legacy server compatibility.
    let alertOnArrival: Bool
    let alertOnDeparture: Bool
    let activeDays: [String]?
    let activeStartTime: String?
    let activeEndTime: String?
    /// Encrypted alert conditions (schedule + triggers) for client-side
    /// evaluation. Setting this also flips clientOnly true server-side.
    let encryptedConditions: EncryptedBlobRequest?
    let clientOnly: Bool
    let notifyPush: Bool
    let notifyEmail: Bool
    let notifySms: Bool
    let isRecurring: Bool
    /// RFC3339; nil for non-expiring alerts.
    let expiresAt: String?
    let dayBucket: Int
    /// BLAKE3(circle_key, "arrival") — privacy-preserving server match.
    let arrivalHash: String?
    /// BLAKE3(circle_key, "departure").
    let departureHash: String?
    /// BLAKE3(circle_key, "enter") / "exit" — the hashes the place-alert WORKER
    /// actually matches a crossing against (a crossing is reported under
    /// eventType "enter"/"exit"). arrival/departure above are the legacy names;
    /// without enter/exit the alert's `enter_type_hash`/`exit_type_hash` stay
    /// NULL server-side and the alert NEVER fires. Parity with the Android app,
    /// which co-sends all four. enter ↔ arrival trigger, exit ↔
    /// departure trigger, keyed under the SAME routing circle.
    let enterTypeHash: String?
    let exitTypeHash: String?
    let encryptedSchedule: EncryptedBlobRequest?
    let encryptedCooldown: EncryptedBlobRequest?
    /// IANA zone the `activeStartTime`/`activeEndTime` window is written in —
    /// `TimeZone.current.identifier`, e.g. "America/Los_Angeles".
    ///
    /// The server evaluates the window in the alert's stored zone, UTC unless a
    /// client sent one, while this device's own evaluator uses the device zone
    /// (`PlaceAlertRules.isWithinSchedule`, `calendar: Calendar = .current`).
    /// In UTC, an 08:00-17:00 alert in America/Los_Angeles would fire
    /// 00:00-09:00 local when the server saw the crossing and 08:00-17:00
    /// local when the phone did — the same alert behaving differently
    /// depending on which detector noticed. A server that does not know the
    /// field ignores it.
    ///
    /// Named `timezone` and not `timeZone` because the encoder runs
    /// `.convertToSnakeCase`, which would turn the latter into `time_zone`, a
    /// field the server silently ignores. `PlaceAlertRulesTests` pins the
    /// emitted spelling.
    let timezone: String
    /// A waiting change's id. Never sent from a plain tap.
    var clientRequestId: String? = nil
}

struct UpdatePlaceAlertRequest: Encodable {
    let alertOnArrival: Bool
    let alertOnDeparture: Bool
    let activeDays: [String]?
    let activeStartTime: String?
    let activeEndTime: String?
    let encryptedConditions: EncryptedBlobRequest?
    let notifyPush: Bool
    let notifyEmail: Bool
    let notifySms: Bool
    let isRecurring: Bool
    let isActive: Bool
    let expiresAt: String?
    let arrivalHash: String?
    let departureHash: String?
    /// See CreatePlaceAlertRequest: the enter/exit hashes the worker matches on
    /// (NULL of these = alert never fires). enter ↔ arrival, exit ↔ departure.
    let enterTypeHash: String?
    let exitTypeHash: String?
    let encryptedSchedule: EncryptedBlobRequest?
    let encryptedCooldown: EncryptedBlobRequest?
    /// See `CreatePlaceAlertRequest.timezone`. Sent on UPDATE as well as CREATE
    /// because this endpoint full-replaces the row: an edit made on a phone that
    /// has since moved zones must carry the zone the window is now written in,
    /// or the alert keeps being evaluated against wherever it was created.
    let timezone: String
}

struct DestinationResponse: Codable, Sendable {
    let id: String
    /// The destination's CREATOR as the server records it (the row's own
    /// `user_id`). "Mine" needs this AND the sealed id to name this account
    /// (`Destination.isMine`). Optional so an older server still decodes;
    /// then nothing is "mine".
    let userId: String?
    let encryptedUserId: EncryptedBlobResponse
    let circleId: String
    let encryptedDestination: EncryptedBlobResponse
    let encryptedDestName: EncryptedBlobResponse?
    let encryptedEta: EncryptedBlobResponse?
    let etaDayBucket: Int?
    let notifyArrival: Bool
    let status: String
    let startedDayBucket: Int
    let arrivedDayBucket: Int?
    let createdDayBucket: Int
    let updatedDayBucket: Int
}

struct CreateDestinationRequest: Encodable {
    let circleId: String
    let encryptedDestination: EncryptedBlobRequest
    let encryptedDestName: EncryptedBlobRequest?
    let encryptedEta: EncryptedBlobRequest?
    let etaDayBucket: Int?
    let notifyArrival: Bool
    let encryptedUserId: EncryptedBlobRequest
    /// A waiting change's id. Never sent from a plain tap.
    var clientRequestId: String? = nil
}

struct UpdateDestinationRequest: Encodable {
    let status: String?
    let encryptedEta: EncryptedBlobRequest?
    let etaDayBucket: Int?
    let notifyArrival: Bool?
}

struct ReportArrivalRequest: Encodable {
    let encryptedLocation: EncryptedBlobRequest?
    let encryptedUserId: EncryptedBlobRequest
    /// BLAKE3(circle_key, "arrival") — server routes notifications
    /// without learning the event type.
    let eventTypeHash: String
    let encryptedEventType: EncryptedBlobRequest
    /// E2EE: when the arrival actually happened — see
    /// BoundaryCrossingRequest.encryptedOccurredAt.
    let encryptedOccurredAt: EncryptedBlobRequest?
}

struct ReportArrivalResponse: Codable {
    let destinationId: String
    let eventId: String
    let notificationsSent: Int
}

struct InactivityAlertResponse: Codable {
    let id: String
    let userId: String
    let circleId: String
    let encryptedTargetUserId: EncryptedBlobResponse
    /// Hour-level granularity for privacy — server can run the
    /// evaluation cron without decryption.
    let timeoutHours: Int
    let isSelfAlert: Bool
    let notifyPush: Bool
    let notifyEmail: Bool
    let cooldownMinutes: Int
    let isActive: Bool
    let lastTriggeredDayBucket: Int?
    let dayBucket: Int
    let encryptedConditions: EncryptedBlobResponse?
    /// Opt-in "back online" alert: fire when a flagged member resumes sharing.
    /// Optional so decoding tolerates an older backend that does not send it.
    let notifyOnReturn: Bool?
}

struct CreateInactivityAlertRequest: Encodable {
    let circleId: String
    let targetUserId: String
    let encryptedTargetUserId: EncryptedBlobRequest
    /// 5-1440 minutes; backend rounds to hours for storage.
    let timeoutMinutes: Int
    let isSelfAlert: Bool
    let notifyPush: Bool
    let notifyEmail: Bool?
    let cooldownMinutes: Int?
    let encryptedConditions: EncryptedBlobRequest?
    /// Server cannot evaluate when encrypted_conditions is set — the
    /// client polls/fires. Auto-true server-side when conditions present.
    let clientOnly: Bool
    /// Per-circle pseudonym of the watched user — encodes as
    /// `target_user_pseudonym` via the actor's convertToSnakeCase. Lets the
    /// SERVER attribute the target's location rows and evaluate the rule
    /// without learning the raw user id (encrypted_target_user_id stays the
    /// E2EE round-trip field). Sent for every server-eval row; nil only for
    /// legacy client_only rules.
    let targetUserPseudonym: String?
    /// E2EE coarse timing (days since epoch). REQUIRED by the backend —
    /// omitting it 422s the create before the handler runs.
    let dayBucket: Int
    /// Opt-in: also fire a "back online" alert when the flagged member resumes.
    let notifyOnReturn: Bool
    /// A waiting change's id. Never sent from a plain tap.
    var clientRequestId: String? = nil
}

struct UpdateInactivityAlertRequest: Encodable {
    let timeoutMinutes: Int?
    let isActive: Bool?
    let notifyPush: Bool?
    let notifyEmail: Bool?
    let cooldownMinutes: Int?
    let encryptedConditions: EncryptedBlobRequest?
    let notifyOnReturn: Bool?
}

// MARK: - Alert Rules (low-battery)

/// Plaintext server-evaluated conditions for a rule. For `low_battery`
/// the only key is `threshold` (battery %); kept plaintext so the server
/// can evaluate without decryption (it's not relationship/location data).
struct AlertRuleConditions: Codable, Equatable {
    var threshold: Int?
}

struct AlertRuleResponse: Codable {
    let id: String
    let userId: String
    let circleId: String?
    /// "low_battery" (or legacy "offline"). Server needs it plaintext to evaluate.
    let ruleType: String
    /// {"threshold": N} — present so the owner can read/edit the threshold.
    let conditions: AlertRuleConditions?
    let isActive: Bool
    let notifyPush: Bool
    let notifyEmail: Bool
    let notifySms: Bool
    let cooldownMinutes: Int?
    let dayBucket: Int
    /// Who the rule watches, encrypted to the circle. Decoded because the
    /// rule is evaluated on this device: the server applies no threshold and
    /// resolves no target, so a rule whose target we cannot read is a rule
    /// nothing fires. Optional so a response that somehow omits it decodes to
    /// a skipped rule rather than failing the whole list.
    let encryptedTargetUserId: EncryptedBlobResponse?
    /// The threshold, sealed with the circle key. This is where it lives: the
    /// plaintext `conditions` field above is written empty by every client and
    /// kept only so old rules still read back.
    let encryptedConditions: EncryptedBlobResponse?
}

/// A firing this device decided on, reported so the account's other devices —
/// and the web, which cannot evaluate at all — share one history.
///
/// Everything saying WHAT happened is sealed with the circle key. The server
/// ends up holding that this account recorded something on this day, which is
/// what it needs to hand the rows back.
struct CreateAlertEventRequest: Encodable {
    let alertRuleId: String?
    let dayBucket: Int
    let encryptedUserId: EncryptedBlobRequest
    let encryptedTargetUserId: EncryptedBlobRequest
    let encryptedAlertType: EncryptedBlobRequest
    let encryptedTriggeredAt: EncryptedBlobRequest
}

/// A circle-mate's request to be watched.
///
/// Their own device cannot raise it — the phone that has gone quiet is the one
/// that would have to notice — and the server does not decide these, so ours
/// is one of the devices that has to. This is how it learns the request exists.
struct CircleSelfAlertResponse: Codable {
    let id: String
    /// The member who asked; for a self-alert the owner IS the subject.
    let userId: String
    let circleId: String
    let timeoutHours: Int
    let notifyOnReturn: Bool
}

/// `{"circle_id": "..."}` — the whole of it. Serialises via the encoder's
/// convertToSnakeCase.
struct WakeWatchersRequest: Encodable {
    let circleId: String
}

struct CreateAlertRuleRequest: Encodable {
    let circleId: String?
    let targetUserId: String
    let ruleType: String
    let conditions: AlertRuleConditions
    let notifyPush: Bool
    let notifyEmail: Bool
    let notifySms: Bool
    let cooldownMinutes: Int?
    let encryptedConditions: EncryptedBlobRequest?
    let encryptedTargetUserId: EncryptedBlobRequest
    let dayBucket: Int
    /// A waiting change's id. Never sent from a plain tap.
    var clientRequestId: String? = nil
}

struct UpdateAlertRuleRequest: Encodable {
    let isActive: Bool?
    let notifyPush: Bool?
    let notifyEmail: Bool?
    let notifySms: Bool?
    let cooldownMinutes: Int?
    let encryptedConditions: EncryptedBlobRequest?
    /// Lets the battery threshold be edited ({"threshold": N}).
    let conditions: AlertRuleConditions?
}

struct PlaceAlertResponse: Codable {
    let id: String
    let placeId: String
    /// Plaintext user_id of the alert's creator. Server returns it because
    /// alerts are scoped to the current user (no leak).
    let userId: String
    /// Encrypted target user id (all for circle-wide alerts) — only
    /// circle members can decrypt.
    let encryptedTargetUserId: EncryptedBlobResponse
    /// DEPRECATED plaintext schedule fields, kept here so we can decode
    /// historical rows. Prefer encryptedConditions / encryptedSchedule.
    let alertOnArrival: Bool
    let alertOnDeparture: Bool
    let activeDays: [String]?
    let activeStartTime: String?
    let activeEndTime: String?
    let isOvernight: Bool
    /// Encrypted alert conditions for client-side evaluation.
    let encryptedConditions: EncryptedBlobResponse?
    let clientOnly: Bool
    let notifyPush: Bool
    let notifyEmail: Bool
    let notifySms: Bool
    let isRecurring: Bool
    let isActive: Bool
    let expiresAt: String?
    let dayBucket: Int
    /// BLAKE3(circle_key, arrival) — server-side privacy-preserving match.
    let arrivalHash: String?
    let departureHash: String?
    let encryptedSchedule: EncryptedBlobResponse?
    let encryptedCooldown: EncryptedBlobResponse?
    let lastTriggeredDayBucket: Int?
    /// TRUE after a circle key rotation: the arrival/departure match hashes
    /// are derived from the now-old key and no longer match a mover's crossing.
    /// Optional so an older backend that omits it still decodes.
    let needsHashUpdate: Bool?
    /// The TARGET has withdrawn `allow_alerts_on_me` in the circle this alert's
    /// consent is anchored to, so the alert is DORMANT: the server will not route
    /// it and this device must not raise it. The row stays active and fully
    /// configured, so consent returning restores it untouched. Optional so an
    /// older backend that omits it still decodes, and so absence reads as ALLOWED.
    let suppressedByTarget: Bool?
    /// The alert's routing circle (`CreatePlaceAlertRequest.circle_id`) — the
    /// circle whose key the arrival/departure hashes must be re-derived under
    /// after a rotation. For a personal place this is a REAL circle the place
    /// is shared to, never the self pseudo-circle. Optional so an older
    /// backend that omits it still decodes; callers fall back to the place's
    /// own circle when nil.
    let circleId: String?
}

/// PUT /api/v1/places/:id.
///
/// There is no `boundary_radius` here, for the same reason as in
/// `CreatePlaceRequest` above: the server has no such field. It reads the
/// same request type on this route too, and validates the one radius
/// against the same (50, 25000) band.
///
/// A phantom size field is where a value gets hidden, and this is the route
/// by which a place actually gets RESIZED, so `radiusMeters` is the only
/// size field.
struct UpdatePlaceRequest: Encodable {
    let encryptedName: EncryptedBlobRequest?
    let encryptedAddress: EncryptedBlobRequest?
    let encryptedLocation: EncryptedBlobRequest?
    /// The place's one geofence radius, in metres — the alert ring itself.
    let radiusMeters: Int?
    let icon: String?
    let color: String?
    let encryptedNotes: EncryptedBlobRequest?
}

// SOS — wire shape mirrors the server's SOS routes.

struct CreateSOSRequest: Encodable {
    let deviceId: String
    let circleId: String
    let encryptedLocation: EncryptedBlobRequest
    let encryptedDeviceState: EncryptedBlobRequest?
    let encryptedUserId: EncryptedBlobRequest
    let encryptedDeviceId: EncryptedBlobRequest
    let dayBucket: Int
    let encryptedTimestamp: EncryptedBlobRequest
}

/// Body of PUT /api/v1/sos/:id/reseal: the create's sealed fields exactly,
/// under the circle's current key. The time is the ORIGINAL raise time, never
/// "now"; no device state stores none.
struct ResealSOSRequest: Encodable {
    let encryptedLocation: EncryptedBlobRequest
    let encryptedDeviceState: EncryptedBlobRequest?
    let encryptedUserId: EncryptedBlobRequest
    let encryptedDeviceId: EncryptedBlobRequest
    let encryptedTimestamp: EncryptedBlobRequest
}

struct ResolveSOSRequest: Encodable {
    let resolution: String
}

struct SOSReceiptRequest: Encodable {
    /// Always "ios" from this app; the server also accepts "android" and "web".
    let platform: String
}

/// How far the caller's OWN alert got. Counts only — the server never says
/// which members were reached, the same posture `acknowledgmentCount` takes.
struct SOSDeliveryResponse: Decodable {
    /// Active circle members other than the raiser.
    let recipients: Int
    /// Recipients reachable on at least one push surface.
    let addressable: Int
    /// Recipients a push was handed to a provider for. Not receipt evidence.
    let dispatched: Int
    /// Recipients the email fallback reached.
    let emailed: Int
    /// Recipients whose DEVICE confirmed arrival. The only receipt evidence.
    let confirmed: Int
    /// One of: alone, pending, confirmed, partial, no_confirmation,
    /// undeliverable. Derived server-side so iOS, Android and web cannot each
    /// invent a different threshold for "this failed".
    let state: String
}

/// `SOSResponse` (the active list's rows) lives with the receiver rules
/// (SOSReceiverRules.swift): the notification extension reads it too.

/// The raiser's own alert as `GET /api/v1/sos/:sos_id` serves it to them: the
/// alert, and who is responding (`acknowledged_by`, oldest first), which the
/// server serves to the raiser alone, and only on this route. Every other
/// read (/sos/active, a mutation's reply, another member's GET) is
/// counts-only and decodes as `SOSResponse`, which has no such field.
struct OwnSOSResponse: Decodable {
    let alert: SOSResponse
    /// nil when not served (an older server, or not the raiser) or unreadable:
    /// the status poll this rides on must never fail over it.
    let acknowledgedBy: [String]?

    private enum CodingKeys: String, CodingKey {
        case acknowledgedBy
    }

    init(from decoder: Decoder) throws {
        alert = try SOSResponse(from: decoder)
        acknowledgedBy = (try? decoder.container(keyedBy: CodingKeys.self)
            .decodeIfPresent([String].self, forKey: .acknowledgedBy)) ?? nil
    }
}

// Check-ins — wire shape mirrors the server's check-in routes.

struct CreateCheckInRequest: Encodable {
    let deviceId: String
    let circleId: String?
    let encryptedLocation: EncryptedBlobRequest
    let placeId: String?
    let encryptedMessage: EncryptedBlobRequest?
    let checkInType: String
    let encryptedUserId: EncryptedBlobRequest
    let encryptedDeviceId: EncryptedBlobRequest
    let dayBucket: Int
    let encryptedTimestamp: EncryptedBlobRequest
    /// Keyed-hash of the user id used for server-side filtering without
    /// revealing identity. Computed client-side via blake3-keyed.
    let userPseudonym: String
    /// A waiting change's id: a resend is answered with the first row. Never
    /// sent from a plain tap.
    var clientRequestId: String? = nil
}

struct CheckInResponse: Codable, Sendable {
    let id: String
    let circleId: String?
    let placeId: String?
    /// OPTIONAL, matching the server: a check-in may omit its location (e.g. an
    /// "I'm safe" check-in that doesn't reveal where you are), and the web and
    /// Android clients treat it as optional. Such a row goes over the wire as
    /// `"encrypted_location": null`.
    ///
    /// Declared non-optional, this would throw `valueNotFound` on that row, and
    /// because the whole page is decoded as one array a SINGLE location-less
    /// check-in from web or Android would empty the entire history for every
    /// iOS member of the circle.
    let encryptedLocation: EncryptedBlobResponse?
    let encryptedMessage: EncryptedBlobResponse?
    let checkInType: String
    let encryptedUserId: EncryptedBlobResponse
    let encryptedDeviceId: EncryptedBlobResponse
    let dayBucket: Int
    let encryptedTimestamp: EncryptedBlobResponse
}

// Boundaries — mirrors the server's crossing-report request. The client
// detects crossings locally (E2EE: the server can't geofence ciphertext)
// and reports them here; the server routes pushes to subscribers whose
// stored event-type hash matches, without learning the event type.
struct BoundaryCrossingRequest: Encodable {
    let placeId: String
    let crossingUserId: String
    /// Circle-key ciphertext of "enter" / "exit".
    let encryptedEventType: EncryptedBlobRequest
    /// Circle-key ciphertext of the reporting device id.
    let encryptedDeviceId: EncryptedBlobRequest
    /// BLAKE3(circle_key, event_type) for server-side routing.
    let eventTypeHash: String
    let encryptedLocation: EncryptedBlobRequest?
    /// E2EE: when the crossing actually happened (epoch ms as a string), sealed
    /// with the circle key. The server stores and echoes it without reading it;
    /// the SUBSCRIBER decrypts it to stamp their notification. Without it the only
    /// time they receive is the server's own row timestamp, so a crossing reported
    /// after an offline stretch would read as if it had just happened.
    let encryptedOccurredAt: EncryptedBlobRequest?
}

struct BoundaryCrossingResponse: Codable {
    let eventId: String
    let notificationsSent: Int
}

// Notifications
struct SendNotificationRequest: Encodable {
    let notificationType: String
    let circleIds: [String]
    let data: [String: String]
}

struct SendNotificationResponse: Codable {
    let notificationsSent: Int
}

// Config — the `/api/config` body is decoded by MapTileConfig (see
// "MARK: - Config Endpoints").

// Sessions (= Devices)
struct SessionInfo: Codable, Identifiable {
    let id: String
    let deviceName: String?
    let ipAddress: String?
    let lastUsedAt: String
    let createdAt: String
    let isCurrent: Bool
}

struct SessionsListResponse: Codable {
    let sessions: [SessionInfo]
    let total: Int
    let limit: Int
    let offset: Int
}

struct RenameSessionRequest: Encodable {
    let deviceName: String?
}

/// Single row from GET /api/v1/tracking-devices — the user's devices
/// with an active push registration, filtered server-side to devices
/// that actually push location. The `sessionId` back-link is the
/// canonical identifier the Manage Devices screen intersects with
/// /auth/sessions to filter out web / Note / admin sessions. Mirrors
/// the Android app's `TrackingDevice` DTO.
struct TrackingDevice: Codable {
    let id: String
    let sessionId: String?
    let platform: String
    let pushType: String
    let lastSeenDayBucket: Int?
    let createdDayBucket: Int
    let isCurrent: Bool
}

/// Effective premium entitlement from the track server — own
/// subscription OR circle-derived (any member of a circle the user
/// is in is subscribed). `source` is "own", "circle", or "none".
/// Mirrors the Android app's `PremiumStatusResponse`.
struct PremiumStatusResponse: Codable {
    let hasPremium: Bool
    let source: String
}

/// Answer to "may this account start an App Store purchase for this product",
/// from auth's GET /api/v1/billing/apple/eligibility.
///
/// Asked BEFORE the purchase sheet, because it cannot be enforced afterwards:
/// once StoreKit completes, Apple has taken the money, and the server refusing
/// to record it would leave the customer charged with nothing. The server fails
/// closed, so a transport error here must be treated as "do not sell", never as
/// a default yes.
struct ApplePurchaseEligibility: Codable {
    let canPurchase: Bool
    /// The server's words for a refusal: never shown (the sheet says the app's
    /// own line).
    let reason: String?
    /// Which provider the blocking subscription is on, so the UI can say where
    /// to go. `"apple"` never blocks — StoreKit surfaces that as a restore.
    let existingProvider: String?
}

/// Per-user quota usage + entitlements from the track server's
/// GET /api/v1/quota. Counts (`current*`) mirror how the enforcement
/// gates count (per-user across all circles). A `max*` of -1 means
/// unlimited; `remaining*` of Int.max likewise. snake_case JSON maps via
/// the decoder's `.convertFromSnakeCase`. Mirrors the Note iOS app's
/// QuotaDto.
struct TrackQuotaUsage: Codable, Equatable {
    let tier: String
    let source: String
    let maxPlaces: Int
    let currentPlaces: Int
    let remainingPlaces: Int
    let maxCircles: Int
    let currentCircles: Int
    let remainingCircles: Int
    let maxPlaceAlerts: Int
    let currentPlaceAlerts: Int
    let remainingPlaceAlerts: Int
    let maxDestinations: Int
    let currentDestinations: Int
    let remainingDestinations: Int
    let maxMembers: Int
    let historyDays: Int
    /// Days until history older than `historyDays` is DELETED, for someone who
    /// is on the free tier now but was premium recently. Distinct from
    /// `historyDays`, which is what is READABLE right now: visibility drops the
    /// moment premium ends, but the data survives until this hits zero, so
    /// re-subscribing inside the window restores it intact.
    ///
    /// nil whenever nothing is counting down — premium active, or there was
    /// never any premium to lose. Optional, so a backend that predates the
    /// field decodes as nil rather than failing the whole quota response.
    let historyExpiresInDays: Int?
    /// What a circle with a premium member retains, in days. Optional: a server
    /// that does not send it leaves it nil.
    ///
    /// `history_days` is no substitute: it is what the CALLER may read, and the
    /// caller who sees the grace countdown is by definition on the free tier, so
    /// their `history_days` says nothing about the premium figure. The number is
    /// read from the server rather than written into the app, so a change to the
    /// tier needs no app update; without it the sentence simply does not claim a
    /// number (see `SettingsView.historyExpiryMessage`).
    let premiumHistoryDays: Int?
    let destinationsEnabled: Bool
    let smartAlertsEnabled: Bool
    let webPushEnabled: Bool

    /// The gates report "premium" / "free"; anything non-free is paid.
    var isPaid: Bool { tier != "free" }
}

/// A subscription row as auth answers it, here the one an App Store purchase
/// was linked to (`linkApplePurchase`). Status is "active", "trialing",
/// "canceled", etc. Mirrors the Android app's `SubscriptionInfo`.
struct SubscriptionInfo: Codable {
    let status: String
}

// MARK: - Privacy-preserving geocode tokens (Privacy-Pass-style VOPRF)
//
// Same file as APIService so these can reach its private `session`, `config`,
// `keychain`, `decoder`, `encoder`, and `addHeaders`. See GeocodeTokenManager
// for the state machine.
extension APIService {

    /// `GET /api/v1/geocode/token-key` — public. Fetch the current VOPRF key so
    /// the client can pin it, verify issuance DLEQ proofs, and detect rotation.
    /// Sent WITHOUT auth (public + works pre-login).
    func geocodeTokenKey() async throws -> GeocodeTokenKeyResponse {
        var request = URLRequest(url: URL(string: config.apiBaseURL + "/api/v1/geocode/token-key")!)
        request.httpMethod = "GET"
        try addHeaders(to: &request, auth: false)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError(code: "network_error", message: "Invalid response")
        }
        guard (200...299).contains(http.statusCode) else {
            throw APIError(code: "http_\(http.statusCode)", message: "token-key \(http.statusCode)")
        }
        return try decoder.decode(GeocodeTokenKeyResponse.self, from: data)
    }

    /// `POST /api/v1/geocode/tokens` — authenticated + premium-gated issuance.
    /// BlindEvaluate a batch of client-blinded elements into anonymous credits
    /// (with DLEQ proofs). Throws `http_402/429/503` on the gated/error paths.
    func geocodeIssueTokens(blinded: [String]) async throws -> GeocodeIssueResponse {
        var request = URLRequest(url: URL(string: config.apiBaseURL + "/api/v1/geocode/tokens")!)
        request.httpMethod = "POST"
        try addHeaders(to: &request, auth: true)
        request.httpBody = try encoder.encode(GeocodeIssueRequest(blinded: blinded))
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError(code: "network_error", message: "Invalid response")
        }
        guard (200...299).contains(http.statusCode) else {
            throw APIError(code: "http_\(http.statusCode)", message: "issue \(http.statusCode)")
        }
        let wrapped = try decoder.decode(APIResponse<GeocodeIssueResponse>.self, from: data)
        guard let payload = wrapped.data else {
            throw APIError(code: "decode_error", message: "missing issue data")
        }
        return payload
    }

    /// `POST /api/v1/geocode/reverse` — SESSION-LESS redemption. Sent with NO
    /// Authorization header (privacy: no identity next to the coordinates) and
    /// NO 401 bearer-refresh-retry (a 401 here must never attach a bearer and
    /// retry — that would leak identity onto a deliberately anonymous request).
    /// Returns the raw Pelias body + HTTP status so the caller can branch on
    /// 200 / 409 (spent) / 401 (rotated) / 503.
    func geocodeRedeemReverse(_ body: GeocodeRedeemRequest) async throws -> (data: Data, status: Int) {
        var request = URLRequest(url: URL(string: config.apiBaseURL + "/api/v1/geocode/reverse")!)
        request.httpMethod = "POST"
        try addHeaders(to: &request, auth: false)   // NO Authorization
        Self.applyAnonymousLanguage(to: &request)
        request.httpBody = try encoder.encode(body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError(code: "network_error", message: "Invalid response")
        }
        return (data, http.statusCode)
    }

    /// The one language code an anonymous geocode request carries, e.g. "de".
    ///
    /// WHY IT IS SET AT ALL. The search needs it: the backend passes it to the
    /// geocoder so that "eiffelturm" finds the tower and the rows come back
    /// named in the user's language.
    ///
    /// WHY IT IS SET BY HAND. Left alone, URLSession writes this header itself
    /// from the device's languages, with region and weight (e.g.
    /// "en-US,en;q=0.9" on a request that set no such header, and "de" once
    /// the request sets it). That says more about a device than a search
    /// needs, on the two requests this app otherwise strips of what identifies
    /// it (see `addHeaders`, the User-Agent). So both carry the primary code of
    /// the first language and nothing else.
    ///
    /// Nil only if the first language has no usable code; the header is then
    /// left to URLSession.
    static func anonymousLanguage(preferred: [String] = Locale.preferredLanguages) -> String? {
        guard let first = preferred.first else { return nil }
        let primary = first.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init)?
            .lowercased() ?? ""
        let letters = primary.unicodeScalars.allSatisfy { ("a"..."z").contains($0) }
        return (2...3).contains(primary.count) && letters ? primary : nil
    }

    static func applyAnonymousLanguage(
        to request: inout URLRequest, preferred: [String] = Locale.preferredLanguages
    ) {
        guard let language = anonymousLanguage(preferred: preferred) else { return }
        request.setValue(language, forHTTPHeaderField: "Accept-Language")
    }

    /// Forward geocode against the anonymous endpoint. Same shape and the same
    /// `auth: false` rule as the reverse redemption above — attaching the user's
    /// JWT would put identity back onto a deliberately anonymous request, which
    /// is the entire point of spending a VOPRF credit instead.
    func geocodeRedeemSearch(_ body: GeocodeSearchRequest) async throws -> (data: Data, status: Int) {
        var request = URLRequest(url: URL(string: config.apiBaseURL + "/api/v1/geocode/search")!)
        request.httpMethod = "POST"
        try addHeaders(to: &request, auth: false)   // NO Authorization
        Self.applyAnonymousLanguage(to: &request)
        request.httpBody = try encoder.encode(body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError(code: "network_error", message: "Invalid response")
        }
        return (data, http.statusCode)
    }
}


/// `POST /auth/logout`'s body: the session's refresh token.
/// Omitted when there is none, so the body is `{}`.
struct LogoutRequest: Encodable {
    let refreshToken: String?
}

// MARK: - Identities from before a password reset

/// A recovered pre-reset private key, sealed for this app by the account portal.
///
/// The portal's own copy is wrapped under the auth MASTER key, which this app
/// never holds — so it seals a second copy under a value the SDK derives from
/// the key we already have. Absent when the recovery predates that.
struct SealedPreviousIdentityResponse: Codable {
    let nonce: String
    let ciphertext: String
}

/// No explicit CodingKeys, on purpose. The wire decoder runs
/// `.convertFromSnakeCase`, which converts the JSON keys BEFORE matching, so
/// snake_case CodingKeys ("key_version", "app_sealed_private_key") could never
/// match: every response would fail to decode, `PreviousIdentityLoader` would
/// catch it and import nothing, and a user who restored their pre-reset data
/// in the account portal could not read it on iOS.
struct PreviousIdentityResponse: Codable {
    let keyVersion: Int
    let appSealedPrivateKey: SealedPreviousIdentityResponse?
    /// The same identity with its old signing PUBLIC key, sealed the same way
    /// (v2). Absent until the portal has written it; preferred when present.
    let appSealedPrivateKeyV2: SealedPreviousIdentityResponse?

    /// The blob to hand the SDK for this identity: v2 when the entry has one.
    var sealedForThisApp: SealedPreviousIdentityResponse? { appSealedPrivateKeyV2 ?? appSealedPrivateKey }
}

struct PreviousIdentitiesResponse: Codable {
    let identities: [PreviousIdentityResponse]
}

/// `GET /api/v1/auth/archived-recovery`, reduced to what `hasPreResetDataToRestore`
/// needs. Each entry also carries salts and wrapped keys; Codable drops the
/// fields this type does not name, so none of that is held in memory here.
struct ArchivedRecoveryListResponse: Decodable {
    struct Entry: Decodable {
        let keyVersion: Int
    }
    let archived: [Entry]
}

/// Is this process running under the DEBUG-only synthetic-session UI-test
/// bypass? Used to suppress the session-revoked broadcast, whose trigger that
/// bypass provokes by design. Always false in Release.
extension APIService {
    static var isSyntheticUITestSession: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-UITestSyntheticSession")
        #else
        return false
        #endif
    }
}
