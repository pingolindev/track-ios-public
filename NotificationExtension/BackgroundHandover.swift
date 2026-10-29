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
#if TRACK_TESTS
// The unit tests compile this file too, and reach the rules it shares with the
// app (`AccessHandover` and the rest) through the app module.
@testable import Track
#endif

/// Hands a circle to the members who are owed it, from the Notification Service
/// Extension, while a visible notification is on its way to the screen. Nobody
/// should have to open the app for software to do what it can do by itself.
///
/// It runs because a visible push that carries data has mutable-content, so
/// iOS starts this extension for it — even when the app was swiped away, which
/// a silent wake never reaches. A "New circle member" push names only this
/// user's notification ROW (`alert_id`); the row, fetched over the app's own
/// connection, says which circle and who joined. Any other visible push but
/// "Notify my circle" sweeps the circles the server flags `delivery_needed`.
/// Either way the push picks circles, never recipients.
///
/// The decision is the app's, from the same code (`AccessHandover`,
/// `MembershipConfirmation`): this device's approval record (its tag), re-read
/// on every run; the roster's signed statements; the confirmation rules to
/// decide who is confirmed, the delivery rule to decide who is owed the circle
/// by THIS device, and the send-side gate. What the app would record on this
/// roster (a confirmation, a receive-only member's first keys, a first pin)
/// counts for this run only; the app records it on its next roster load. The
/// one thing recorded here is who LEFT — trust taken away, never added
/// (`ApprovalRecordStore.persistDepartures`, under the lock the app's writes
/// take). Nothing here writes a key or a pin: the key store is read with
/// `ExtensionKeyStorage`, whose writes are no-ops, and nothing else is called
/// that could change it.
///
/// The session token is the app's, from the shared keychain; one that has run
/// out is refreshed behind the app's own cross-process lock, and the new pair
/// saved before it is used (`ExtensionSessionRefresh`).
///
/// Every step checks the deadline, so the banner is never late: out of time,
/// the run stops where it is and reports what it knows.
enum BackgroundHandover {
    static let log = Logger(subsystem: "com.pingolin.track.NotificationExtension", category: "handover")

    /// What one run learned, for the banner and the log.
    struct Outcome: Equatable {
        var circleId: String?
        var circleName: String?
        /// The member who joined, when this run can tell who — and only a
        /// member this device confirmed.
        var joinerName: String?
        var delivered: [String] = []
        /// Why the run ended early (nil: it ran to the end).
        var stopped: String?
        /// Milliseconds per step ("row", "circles", "roster", "decide", "wrap",
        /// "put", "total"), for the log and the probe.
        var timings: [String: Int] = [:]
        /// The highest memory footprint seen during the run, in MB.
        var peakFootprintMB: Double = 0
        /// The app's token had run out and a refreshed one was used.
        var refreshed = false
    }

    /// Everything a run reads from outside itself, behind one seam: live, the
    /// shared keychain, the app group and the network; in a test, a scratch key
    /// store and a stub server.
    struct Environment {
        var accessToken: () -> String?
        /// A refreshed token when the stored one has run out — nil while
        /// refreshing is off (`ExtensionSessionRefresh.enabled`).
        var refreshedToken: () async -> String? = { nil }
        var keychainUserId: () -> String?
        var shared: () -> UserDefaults?
        /// This device's tag: only a record carrying it is this device's.
        var deviceTag: () -> String?
        /// Held for the one write a run makes: departures (`persistDepartures`).
        var approvalsLock: () -> AppGroupLock?
        var makeCrypto: () -> PingolinTrackSDK.CryptoManager?
        var transport: HandoverTransport
        var now: () -> Date

        static let live = Environment(
            accessToken: ExtensionSession.accessToken,
            refreshedToken: {
                await ExtensionSessionRefresh.token(
                    now: Date(), margin: 30,
                    authBase: UserDefaults(suiteName: ExtensionBridgeKeys.suite)?.string(forKey: ExtensionBridgeKeys.authBaseURL),
                    lock: AppGroupLock.refresh(), transport: URLSessionHandoverTransport(), store: .keychain)
            },
            keychainUserId: ExtensionSession.userId,
            shared: { UserDefaults(suiteName: ExtensionBridgeKeys.suite) },
            deviceTag: DeviceTag.read,
            approvalsLock: AppGroupLock.approvals,
            makeCrypto: {
                // Never while a wipe of the key store is owed: what
                // it holds may be the account's the app signed out
                // (`OwedWipe`). The app pays it; the extension never
                // clears anything.
                guard UserDefaults(suiteName: ExtensionBridgeKeys.suite)?
                    .bool(forKey: ExtensionBridgeKeys.keyStoreWipeOwed) != true else { return nil }
                // A fresh read for every run: an extension process can outlive
                // several notifications, and a pin or key the app changed since
                // must count.
                let manager = PingolinTrackSDK.CryptoManager()
                manager.registerSecureStorage(storage: ExtensionKeyStorage())
                return (try? manager.loadPersistedKeys()) == true ? manager : nil
            },
            transport: URLSessionHandoverTransport(),
            now: Date.init
        )
    }

    /// What starts a run. A join push names this user's notification row, which
    /// names the circle; any other visible push asks for a sweep of the circles
    /// where the server says a delivery is due (`delivery_needed`: someone holds
    /// no copy, an older one, or asked for a fresh one). Either way the push only
    /// picks WHICH CIRCLES to look at — never who is handed anything: that comes
    /// from the roster and the app's rules alone.
    enum Trigger: Equatable {
        case join(pushId: String)
        case sweep
    }

    /// The run a visible push starts, or none: a "Notify my circle" (sos*) banner
    /// goes first and alone — nothing may delay or risk it.
    static func trigger(alertType: String, alertId: String?) -> Trigger? {
        if alertType.hasPrefix("sos") { return nil }
        if alertType == "member_joined", let alertId, !alertId.isEmpty { return .join(pushId: alertId) }
        return .sweep
    }

    /// A join push's run.
    static func run(pushId: String, deadline: Date, env: Environment) async -> Outcome {
        await run(.join(pushId: pushId), deadline: deadline, env: env)
    }

    /// One run: re-read this device's trust state, pick the circles, and hand
    /// each one to whoever this device owes it.
    static func run(_ trigger: Trigger, deadline: Date, env: Environment) async -> Outcome {
        var outcome = Outcome()
        var watch = Stopwatch()
        var peak = Footprint.bytes()
        var circleId = "?"
        func finish(_ why: String?) -> Outcome {
            if let why, outcome.stopped == nil { outcome.stopped = why }
            outcome.timings["total"] = watch.totalMs
            peak = max(peak, Footprint.bytes())
            outcome.peakFootprintMB = Double(peak) / 1_048_576
            if let why {
                log.info("circle \(circleId, privacy: .public): no handover — \(why, privacy: .public)")
            }
            log.info("handover done: \(outcome.delivered.count, privacy: .public) delivered, peak \(String(format: "%.1f", outcome.peakFootprintMB), privacy: .public) MB, ms \(outcome.timings.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "), privacy: .public)")
            return outcome
        }
        log.info("handover starts, footprint \(Footprint.megabytes(), privacy: .public) MB")

        // Who is signed in here, with a token that still works: the
        // app's, or one refreshed behind the app's own lock.
        guard var token = env.accessToken(), TokenClaims(token) != nil else { return finish("not signed in") }
        if let expires = TokenClaims(token)?.expiresAt, expires <= env.now().addingTimeInterval(30) {
            guard let fresh = await env.refreshedToken(), TokenClaims(fresh) != nil else {
                return finish("session token expired")
            }
            token = fresh
            outcome.refreshed = true
            outcome.timings["refresh"] = watch.lap()
        }
        guard let claims = TokenClaims(token) else { return finish("not signed in") }
        // The account in its one canonical form: the Keychain's, the
        // token's and the app's word for it name the same one, or
        // nothing runs.
        guard let me = env.keychainUserId().flatMap({ CanonicalId.of($0) }), CanonicalId.of(claims.subject) == me else {
            return finish("token is for another account")
        }
        guard let shared = env.shared(),
              let bridged = shared.string(forKey: ExtensionBridgeKeys.accountUserId),
              CanonicalId.of(bridged) == me,
              let email = shared.string(forKey: ExtensionBridgeKeys.accountEmail),
              let base = shared.string(forKey: ExtensionBridgeKeys.apiBaseURL) else {
            return finish("the app has not run since this account signed in")
        }
        let api = HandoverClient(base: base, token: token, transport: env.transport, deadline: deadline, now: env.now)
        // Records are only this device's with its tag (the app makes it at
        // launch); without one there is no record to decide with.
        guard let tag = env.deviceTag() else { return finish("no device tag yet") }
        let lock = env.approvalsLock()

        // A join: which circle, and who joined — this user's own notification
        // row, and nothing else: `alert_id` names the row, never a circle. No
        // row (or not a join's) leaves the sweep below, which finds a circle
        // with a delivery due by itself. Ids go into request paths: ids only.
        var named: String?
        var joinedUserId: String?
        if case .join(let pushId) = trigger, UUID(uuidString: pushId) != nil {
            let row: NotificationRow? = try? await api.get("/api/v1/notifications/\(pushId)", query: [:])
            outcome.timings["row"] = watch.lap()
            if let row, row.notificationType == "member_joined", let rowCircle = row.circleId,
               UUID(uuidString: rowCircle) != nil {
                circleId = rowCircle
                outcome.circleId = rowCircle
                named = rowCircle
                joinedUserId = row.metadata?.joinedUserId
            }
        }

        // This device's keys and pins, read afresh: an extension process can
        // outlive several notifications, and whatever the app changed since
        // must count. Unreadable is nothing (`ExtensionKeyStorage`).
        guard let crypto = env.makeCrypto() else { return finish("keys not readable (before first unlock?)") }
        peak = max(peak, Footprint.bytes())

        guard let circles: Page<CircleResponse> = try? await api.get("/api/v1/circles", query: ["limit": "100"]) else {
            return finish(named == nil ? "circle list unavailable" : "circle not listed")
        }
        outcome.timings["circles"] = watch.lap()
        var targets: [CircleResponse] = []
        if let named {
            if let circle = circles.items.first(where: { $0.id == named }) {
                targets.append(circle)
            } else {
                outcome.stopped = "circle not listed"
            }
        }
        targets += circles.items.filter { $0.deliveryNeeded == true && $0.id != named && UUID(uuidString: $0.id) != nil }
        // The personal key's slot is never handed to anyone, whatever
        // the list says; the list refuses it first.
        targets.removeAll { CanonicalId.isPersonalSlot($0.id) }

        var delivered = Set<String>()
        for circle in targets {
            circleId = circle.id
            guard api.remaining > 2 else {
                outcome.stopped = outcome.stopped ?? "out of time"
                break
            }
            let pass = await handOver(
                in: circle, me: me, email: email, shared: shared, tag: tag, lock: lock, crypto: crypto, api: api,
                joinedUserId: circle.id == named ? joinedUserId : nil, now: env.now())
            for (step, ms) in pass.timings { outcome.timings[step, default: 0] += ms }
            delivered.formUnion(pass.delivered)
            peak = max(peak, pass.peak)
            if circle.id == named {
                outcome.circleName = pass.circleName
                outcome.joinerName = pass.joinerName
                if let stop = pass.stopped { outcome.stopped = stop }
            } else if let stop = pass.stopped {
                log.info("circle \(circle.id, privacy: .public): no handover — \(stop, privacy: .public)")
            }
        }
        outcome.delivered = delivered.sorted()
        return finish(nil)
    }

    /// One circle's pass: its record (none or unreadable: nothing), its roster,
    /// the app's decision, and the hand-over.
    private struct CirclePass {
        var circleName: String?
        var joinerName: String?
        var delivered = Set<String>()
        var stopped: String?
        var timings: [String: Int] = [:]
        var peak: UInt64 = 0
    }

    private static func handOver(in circle: CircleResponse, me: String, email: String, shared: UserDefaults,
                                 tag: String?, lock: AppGroupLock?, crypto: PingolinTrackSDK.CryptoManager,
                                 api: HandoverClient, joinedUserId: String?, now: Date) async -> CirclePass {
        var pass = CirclePass()
        var watch = Stopwatch()
        let circleId = circle.id
        // The record the app keeps for this circle, when it is this device's.
        // None (or one this build cannot read) means none of its tombstones
        // either: decide nothing.
        guard case .record(let stored) = ApprovalRecordStore.stored(
            in: shared, owner: me, circleId: circleId, deviceTag: tag) else {
            pass.stopped = "no approval record for the circle"
            return pass
        }
        pass.circleName = (try? crypto.decryptDataV2(
            circleId: circleId,
            encryptedData: EncryptedData(nonce: circle.encryptedName.nonce, ciphertext: circle.encryptedName.ciphertext),
            fieldTag: "name")).flatMap { $0.isEmpty ? nil : $0 }
        let held = (try? crypto.getActiveVersion(circleId: circleId)).map { Int($0) }
        pass.timings["decide"] = watch.lap()

        guard let roster: Page<CircleMemberResponse> = try? await api.get(
            "/api/v1/circles/\(circleId)/members", query: ["limit": "100"]) else {
            pass.stopped = "roster unavailable"
            return pass
        }
        pass.timings["roster"] = watch.lap()
        let decided = AccessHandover.rosterPass(
            circleId: circleId, me: .own(userId: me, email: email, crypto: crypto), roster: roster.items,
            rosterComplete: roster.hasMore != true, activeVersion: held, stored: stored, checker: crypto)
        // Whoever this roster shows gone is recorded gone — the one thing this
        // process writes, and only ever less trust — before anyone is handed
        // anything: so a server that lists them again cannot get them back in
        // through a record that still vouches for them. Not recorded, nothing
        // is handed over.
        let departed = decided.record.tombstones.filter { stored.tombstones[$0.key] != $0.value }
        if !departed.isEmpty {
            guard await ApprovalRecordStore.persistDepartures(
                departed, in: shared, owner: me, circleId: circleId, deviceTag: tag, lock: lock,
                wait: AppGroupLock.extensionWait) else {
                pass.stopped = "departures not recorded"
                return pass
            }
            pass.timings["record", default: 0] += watch.lap()
        }
        let names = displayNames(roster.items, circleId: circleId, crypto: crypto)
        var targets: [AccessHandover.Delivery] = []
        if crypto.circleHasRefreshRecords(circleId: circleId) {
            // A circle with refresh records is handed over only on
            // the records' own delivery answer, after an import of
            // its records, and the app does that. This process hands
            // over nothing there.
            pass.stopped = "a circle with refresh records: the app hands it over"
        } else if AccessHandover.mayHandOver(
            heldVersion: held, circleKeyVersion: circle.keyVersion,
            circleOpens: !AccessHandover.isShownLocked(nameOpened: pass.circleName != nil, circle),
            selfIsReceiveOnly: decided.result.selfIsReceiveOnly, isBehind: crypto.isBehind(circleId: circleId)) {
            targets = AccessHandover.deliveries(
                me: me, circleKeyVersion: circle.keyVersion, heldVersion: circle.keyVersion,
                createdHere: AccessHandover.createdHere(stored, me: me),
                members: roster.items.map { row in
                    AccessHandover.Member(
                        userId: row.userId, displayName: names[row.userId] ?? "Member",
                        sharingKeyHex: AccessHandover.nonEmpty(row.sharingPublicKey),
                        signingKeyHex: AccessHandover.nonEmpty(row.signingPublicKey))
                },
                candidates: decided.candidates, result: decided.result, record: decided.record, now: now,
                pinGate: AccessHandover.readOnlyPinGate(
                    me: me, circleId: circleId,
                    pinnedSharing: { crypto.pinnedSharingKey(circleId: $0, userId: $1) },
                    pinnedSigning: { crypto.pinnedSigningKey(circleId: $0, userId: $1) }))
        } else {
            pass.stopped = "this device does not hand over in this circle"
        }
        pass.timings["decide", default: 0] += watch.lap()
        pass.peak = Footprint.bytes()
        log.info("circle \(circleId, privacy: .public): decided, footprint \(Footprint.megabytes(), privacy: .public) MB")

        for target in targets {
            guard api.remaining > 2 else {
                pass.stopped = "out of time"
                break
            }
            do {
                let bundle = try crypto.wrapCircleKeyForMemberFull(
                    circleId: circleId, memberPublicKeyHex: target.sharingKeyHex, senderUserId: me,
                    recipientUserId: target.userId, recipientSigningPubkeyHex: target.signingKeyHex)
                pass.timings["wrap", default: 0] += watch.lap()
                let status = try await api.put(
                    "/api/v1/circles/\(circleId)/members/\(target.userId)/access",
                    body: SignOwnWrapRequest(
                        keyVersion: circle.keyVersion,
                        encryptedCircleKey: EncryptedBlobRequest(
                            nonce: bundle.encryptedCircleKey.nonce, ciphertext: bundle.encryptedCircleKey.ciphertext),
                        ephemeralPublicKey: bundle.ephemeralPublicKey,
                        wrapSignature: bundle.wrapSignature))
                pass.timings["put", default: 0] += watch.lap()
                switch status {
                case 200..<300:
                    pass.delivered.insert(target.userId)
                    log.info("circle \(circleId, privacy: .public) v\(circle.keyVersion, privacy: .public): handed to a confirmed member")
                case 409:
                    // Another member's app got there first, or the circle
                    // moved on: the server keeps the first delivery.
                    log.info("circle \(circleId, privacy: .public): delivery overtaken (409)")
                default:
                    log.error("circle \(circleId, privacy: .public): delivery answered \(status, privacy: .public)")
                }
            } catch {
                log.error("circle \(circleId, privacy: .public): delivery failed: \(String(describing: error), privacy: .public)")
            }
        }
        pass.peak = max(pass.peak, Footprint.bytes())
        pass.joinerName = joinerName(
            roster: roster.items, me: me, joinedUserId: joinedUserId, result: decided.result,
            delivered: pass.delivered, names: names, now: now)
        return pass
    }

    /// Members' names as the app shows them: sealed under the circle key, else
    /// the plaintext one older clients still send. No placeholder: a banner
    /// names someone or nobody.
    static func displayNames(_ roster: [CircleMemberResponse], circleId: String,
                             crypto: PingolinTrackSDK.CryptoManager) -> [String: String] {
        var names: [String: String] = [:]
        for row in roster {
            if let blob = row.encryptedDisplayName,
               let name = try? crypto.decryptDataV2(
                   circleId: circleId, encryptedData: EncryptedData(nonce: blob.nonce, ciphertext: blob.ciphertext),
                   fieldTag: "display_name"), !name.isEmpty {
                names[row.userId] = name
            } else if let plain = row.displayName, !plain.isEmpty {
                names[row.userId] = plain
            }
        }
        return names
    }

    /// Who the push is about: the member the notification row names
    /// (`joined_user_id`), if this device confirmed them. A server that does
    /// not name them leaves a guess: the one member this device confirmed who
    /// joined today or yesterday (UTC day buckets, as the server keeps them) and
    /// is still waiting for their first copy — or got it from this run; failing
    /// that, the one confirmed member who joined today. Anyone else — a member
    /// this device keeps out, or a guess between two — leaves the banner
    /// without a name.
    static func joinerName(roster: [CircleMemberResponse], me: String, joinedUserId: String?,
                           result: MembershipConfirmation.Result, delivered: Set<String>,
                           names: [String: String], now: Date) -> String? {
        if let joinedUserId {
            let row = roster.first { $0.userId.caseInsensitiveCompare(joinedUserId) == .orderedSame }
            guard let row, row.userId != me, result.verdicts[row.userId]?.isShown == true else { return nil }
            return names[row.userId]
        }
        let today = Int(now.timeIntervalSince1970 / 86_400)
        let recent = roster.filter { row in
            guard row.userId != me, result.verdicts[row.userId]?.isShown == true,
                  let day = row.joinedDayBucket else { return false }
            return day >= today - 1
        }
        let waiting = recent.filter { $0.keyVersion == nil || delivered.contains($0.userId) }
        if waiting.count == 1 { return names[waiting[0].userId] }
        let joinedToday = recent.filter { $0.joinedDayBucket == today }
        if waiting.isEmpty, joinedToday.count == 1 { return names[joinedToday[0].userId] }
        return nil
    }
}

/// The claims of the app's access token this extension needs, read without
/// verifying it: the server verifies every request; this only decides whether
/// a request is worth making.
struct TokenClaims {
    let subject: String
    let expiresAt: Date

    init?(_ token: String) {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sub = json["sub"] as? String, !sub.isEmpty,
              let exp = (json["exp"] as? NSNumber)?.doubleValue else { return nil }
        subject = sub
        expiresAt = Date(timeIntervalSince1970: exp)
    }
}

/// Sends one request. The live one is an ephemeral session: the request
/// carries the session token, so nothing about it may be kept on disk.
protocol HandoverTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionHandoverTransport: HandoverTransport {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        return TrustBlocklist.session(configuration: configuration)
    }()

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

/// The track API as the extension uses it: bearer token, the `{success, data}`
/// envelope, snake_case on the wire (as the app's `APIService`), and a timeout
/// that never runs past the run's deadline.
struct HandoverClient {
    let base: String
    let token: String
    let transport: HandoverTransport
    let deadline: Date
    let now: () -> Date

    var remaining: TimeInterval { deadline.timeIntervalSince(now()) }

    private struct Envelope<T: Decodable>: Decodable { let data: T? }

    func get<T: Decodable>(_ path: String, query: [String: String]) async throws -> T {
        guard var components = URLComponents(string: base + path) else { throw URLError(.badURL) }
        components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw URLError(.badURL) }
        let (data, response) = try await transport.send(request(url, method: "GET", body: nil))
        guard response.statusCode == 200 else { throw URLError(.badServerResponse) }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let value = try decoder.decode(Envelope<T>.self, from: data).data else { throw URLError(.cannotParseResponse) }
        return value
    }

    /// What a GET came back with, each kind apart (the SOS check tells
    /// "can't check" apart from "refused").
    enum Fetched<T> {
        case value(T)
        /// An HTTP status other than 200.
        case status(Int)
        /// A 200 whose body doesn't decode.
        case undecodable
        /// No answer at all: offline, DNS or TLS, a timeout, out of time.
        case noAnswer
    }

    func fetch<T: Decodable>(_ path: String, query: [String: String] = [:]) async -> Fetched<T> {
        guard var components = URLComponents(string: base + path) else { return .noAnswer }
        components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url, let request = try? request(url, method: "GET", body: nil),
              let (data, response) = try? await transport.send(request) else { return .noAnswer }
        guard response.statusCode == 200 else { return .status(response.statusCode) }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let value = (try? decoder.decode(Envelope<T>.self, from: data))?.data else { return .undecodable }
        return .value(value)
    }

    /// The HTTP status of a PUT.
    func put<B: Encodable>(_ path: String, body: B) async throws -> Int {
        guard let url = URL(string: base + path) else { throw URLError(.badURL) }
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let (_, response) = try await transport.send(request(url, method: "PUT", body: try encoder.encode(body)))
        return response.statusCode
    }

    private func request(_ url: URL, method: String, body: Data?) throws -> URLRequest {
        let left = remaining
        guard left > 1 else { throw URLError(.timedOut) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = min(8, left - 0.5)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return request
    }
}

/// This user's notification row, as `GET /api/v1/notifications/{id}` serves
/// it: which circle, and (for a join) who joined; for a crossing or a check-in
/// (`NamedBanner`), the server's words and who and where.
struct NotificationRow: Decodable, Equatable {
    struct Metadata: Decodable, Equatable {
        /// In its one form (`ServedOptionalId`); a row naming nobody is no row.
        @ServedOptionalId var joinedUserId: String?
        /// A crossing's member.
        @ServedOptionalId var targetUserId: String?
        /// A crossing's or a check-in's place.
        @ServedOptionalId var placeId: String?
        /// A check-in's sender as they sealed it (hex).
        var encryptedUserId: String?
        var userIdNonce: String?
        /// A follow-up's alert, and who responded or closed it.
        @ServedOptionalId var sosId: String?
        @ServedOptionalId var acknowledgedBy: String?
        @ServedOptionalId var closedBy: String?
    }
    let circleId: String?
    let notificationType: String
    let title: String?
    let body: String?
    let metadata: Metadata?
}

/// A collection page as the track API serves one (`{items, has_more}`). An
/// item naming an account by no id at all is dropped (`ServedEntries`).
struct Page<T: Decodable>: Decodable {
    let items: [T]
    let hasMore: Bool?

    private enum CodingKeys: String, CodingKey {
        case items, hasMore
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decode(ServedEntries<T>.self, forKey: .items).items
        hasMore = try container.decodeIfPresent(Bool.self, forKey: .hasMore)
    }
}

/// This process's memory footprint (what the system's limit counts), for the
/// log: a service extension is stopped when it passes its cap.
enum Footprint {
    static func bytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    static func megabytes() -> String {
        String(format: "%.1f", Double(bytes()) / 1_048_576)
    }
}

/// Milliseconds since the last lap, and since the start.
struct Stopwatch {
    private let start = DispatchTime.now().uptimeNanoseconds
    private var last = DispatchTime.now().uptimeNanoseconds

    mutating func lap() -> Int {
        let now = DispatchTime.now().uptimeNanoseconds
        defer { last = now }
        return Int((now - last) / 1_000_000)
    }

    var totalMs: Int { Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000) }
}
