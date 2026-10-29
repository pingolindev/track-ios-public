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
// app (`SOSReceiverRules` and the rest) through the app module.
@testable import Track
#endif

/// The check an SOS push gets before it rings. The app's own rules decide
/// (`SOSReceiverRules`), from this phone's keys and marks and the server's list
/// of open alerts, fetched over the app's connection:
///
/// - CAN'T CHECK → the server's own loud alert: no token, the keys
///   or the marks unreadable (before the first unlock, a wipe owed, a key store
///   entry that doesn't read), no usable answer in the budget (offline, a
///   timeout, any status but 200, a 404 too: the list route never answers one,
///   so it says nothing of the SOS; 401/403 after one refresh), a 200 that
///   doesn't decode, or an SOS that may be sealed under a key version this
///   phone doesn't hold yet (no key refresh here).
/// - CHECKED, not live (not listed, history, ended, its raiser off a complete
///   roster, past MAX_SOS_ALARM_AGE, closed) → the quiet notice.
/// - CHECKED, current or sticky → the real alarm, naming the raiser only when
///   the app's own roster pass shows them (`AccessHandover.rosterPass`) and
///   their sealed name opens here: never the plaintext name the server sends
///   for older clients. It rings once per SOS on this phone: one this phone has
///   rung already (its "rang" mark) is shown silently.
///
/// Read-only but for two marks: an SOS that alarms here while current is noted
/// "seen current", so it stays sticky across a rotation the app hasn't seen,
/// and an alarm that rang is noted "rang" once it is shown (`noteRang`).
enum SOSCheck {
    static let log = Logger(subsystem: "com.pingolin.track.NotificationExtension", category: "sos")

    /// The whole check, inside the extension's ~30 s; every request
    /// at most 8 s (`HandoverClient`). Past it: can't check.
    static let budget: TimeInterval = 10

    enum Verdict: Equatable {
        /// Ring with the server's own words, and why.
        case cantCheck(String)
        /// Checked, and not live here: the quiet notice, and why.
        case refused(String)
        /// Checked, current or sticky: the real alarm.
        case alarm(Alarm)
    }

    /// The real alarm, and the SOS it is for.
    struct Alarm: Equatable {
        var name: String?
        var circle: String?
        /// False when this phone has rung this SOS already: shown silently.
        var rings: Bool
        /// Whose marks, and which SOS: for the "rang" mark once it is shown.
        var account: String
        var circleId: String
        var sosId: String
        /// The pruning clock of a new mark (`SOSAlarmMarks.Mark.at`).
        var at: Int64
    }

    /// Once the alarm is shown (handed to iOS): one that rang is noted "rang",
    /// so no later pass on this phone rings it again. After the post, never
    /// before: a mark without a post would leave a genuine SOS that never rang.
    @discardableResult
    static func noteRang(_ verdict: Verdict, marks: SOSAlarmMarks) -> Bool {
        guard case .alarm(let alarm) = verdict, alarm.rings else { return false }
        return marks.noteRang(account: alarm.account, circleId: alarm.circleId, sosId: alarm.sosId, at: alarm.at)
    }

    /// A member's name as it opened here, sealed under the circle key; nil
    /// otherwise. Never the plaintext name the server sends for older clients:
    /// the server could name a genuine alarm with it.
    static func openedName(_ row: CircleMemberResponse, circleId: String,
                           crypto: PingolinTrackSDK.CryptoManager) -> String? {
        guard let blob = row.encryptedDisplayName,
              let name = try? crypto.decryptDataV2(
                  circleId: circleId, encryptedData: EncryptedData(nonce: blob.nonce, ciphertext: blob.ciphertext),
                  fieldTag: "display_name"), !name.isEmpty else { return nil }
        return name
    }

    static func run(alertId: String?, level: String?, deadline: Date, env: BackgroundHandover.Environment,
                    marks: SOSAlarmMarks) async -> Verdict {
        // The session: the app's token, refreshed behind the app's own lock
        // when it has run out, and the account it names.
        guard var token = env.accessToken(), TokenClaims(token) != nil else { return .cantCheck("no token") }
        if let expires = TokenClaims(token)?.expiresAt, expires <= env.now().addingTimeInterval(30) {
            guard let fresh = await env.refreshedToken(), TokenClaims(fresh) != nil else {
                return .cantCheck("session token expired")
            }
            token = fresh
        }
        guard let claims = TokenClaims(token), let me = env.keychainUserId().flatMap({ CanonicalId.of($0) }),
              CanonicalId.of(claims.subject) == me else { return .cantCheck("token for another account") }
        guard let shared = env.shared(), let base = shared.string(forKey: ExtensionBridgeKeys.apiBaseURL) else {
            return .cantCheck("the app group is unreadable")
        }
        guard let sosId = CanonicalId.of(alertId) else { return .cantCheck("no alert id") }

        // What this phone holds: its keys and its marks, both as they are now.
        guard let crypto = env.makeCrypto() else { return .cantCheck("keys not readable") }
        // Every entry of the key store read: one that didn't may be the key of
        // the version this SOS is sealed under.
        let keys = crypto.keyStoreStatus()
        guard keys.load == .loaded, !keys.entriesUnreadable else { return .cantCheck("a key store entry not readable") }
        let held: [String: SOSAlarmMarks.Mark]
        switch marks.read(account: me) {
        case .missing: held = [:]
        case .loaded(let stored): held = stored
        case .unreadable: return .cantCheck("marks not readable")
        }

        // The server's list of open alerts: one refresh on a 401/403.
        var api = HandoverClient(base: base, token: token, transport: env.transport, deadline: deadline, now: env.now)
        var listed: HandoverClient.Fetched<[SOSResponse]> = await api.fetch("/api/v1/sos/active")
        if case .status(let status) = listed, status == 401 || status == 403 {
            guard let fresh = await env.refreshedToken(), let freshClaims = TokenClaims(fresh),
                  CanonicalId.of(freshClaims.subject) == me else {
                return .cantCheck("answered \(status)")
            }
            api = HandoverClient(base: base, token: fresh, transport: env.transport, deadline: deadline, now: env.now)
            listed = await api.fetch("/api/v1/sos/active")
        }
        let list: [SOSResponse]
        switch listed {
        case .value(let value): list = value
        case .status(let status): return .cantCheck("answered \(status)")
        case .undecodable: return .cantCheck("an answer that doesn't decode")
        case .noAnswer: return .cantCheck("no answer")
        }
        guard let response = list.first(where: { CanonicalId.same($0.id, sosId) }) else {
            return .refused("not listed")
        }
        let circleId = response.circleId
        let opened = SOSReceiverRules.open(response, myUserId: me, myDeviceId: nil, crypto: crypto)

        // The circle (its served key version, and its name for the alarm),
        // fetched only when it decides or names: nothing opened while this
        // phone may be behind, or a level that names the circle.
        var circle: CircleResponse?
        var behind = crypto.isBehind(circleId: circleId)
        let nameTheCircle = level != "generic" && level != "names"
        if (!opened.current && opened.nothingOpened && !behind) || nameTheCircle {
            let circles: HandoverClient.Fetched<Page<CircleResponse>> = await api.fetch(
                "/api/v1/circles", query: ["limit": "100"])
            if case .value(let page) = circles {
                circle = page.items.first { CanonicalId.same($0.id, circleId) }
                let active = (try? crypto.getActiveVersion(circleId: circleId)).map { Int($0) } ?? 0
                behind = behind || (circle.map { $0.keyVersion > active } ?? false)
            } else if !opened.current && opened.nothingOpened {
                return .cantCheck("the circle list didn't answer")
            }
        }

        // The roster, when it decides (a sticky SOS's raiser off a complete
        // roster) or names (a level that names someone).
        var raiserShown: Bool?
        var raiserName: String?
        let nameTheRaiser = level != "generic"
        if let raiser = opened.raiserId, (!opened.current && opened.opened) || nameTheRaiser,
           case .record(let stored) = ApprovalRecordStore.stored(
               in: shared, owner: me, circleId: circleId, deviceTag: env.deviceTag()),
           let email = shared.string(forKey: ExtensionBridgeKeys.accountEmail) {
            let roster: HandoverClient.Fetched<Page<CircleMemberResponse>> = await api.fetch(
                "/api/v1/circles/\(circleId)/members", query: ["limit": "100"])
            if case .value(let page) = roster {
                let decided = AccessHandover.rosterPass(
                    circleId: circleId, me: .own(userId: me, email: email, crypto: crypto), roster: page.items,
                    rosterComplete: page.hasMore != true,
                    activeVersion: (try? crypto.getActiveVersion(circleId: circleId)).map { Int($0) },
                    stored: stored, checker: crypto, now: env.now())
                let row = page.items.first { CanonicalId.same($0.userId, raiser) }
                let shown = row.map { decided.result.verdicts[$0.userId]?.isShown == true } ?? false
                raiserShown = shown ? true : (page.hasMore != true ? false : nil)
                if shown, let row {
                    raiserName = openedName(row, circleId: circleId, crypto: crypto)
                }
            }
        }

        let mark = held[SOSAlarmMarks.key(circleId: circleId, sosId: response.id)]
        let now = Int64(env.now().timeIntervalSince1970 * 1000)
        let verdict = SOSReceiverRules.verdict(
            live: SOSReceiverRules.isLive(response.status), opened: opened, behind: behind,
            marks: .read(ended: mark?.ended == true, seenCurrent: mark?.seenCurrent.contains(opened.payloadHash) == true),
            raiserShown: raiserShown, now: now)
        switch verdict {
        case .cantCheck:
            return .cantCheck("it may be sealed under a version not held here")
        case .quiet, .hidden:
            return .refused(verdict == .quiet ? "listed quietly" : "not shown here")
        case .alarming:
            if opened.current {
                marks.noteSeenCurrent(account: me, circleId: circleId, sosId: response.id,
                                      hash: opened.payloadHash, at: opened.sealedTimeMs ?? now)
            }
            let circleName = nameTheCircle ? circle.flatMap { circle in
                (try? crypto.decryptDataV2(
                    circleId: circleId,
                    encryptedData: EncryptedData(nonce: circle.encryptedName.nonce,
                                                 ciphertext: circle.encryptedName.ciphertext),
                    fieldTag: "name")).flatMap { $0.isEmpty ? nil : $0 }
            } : nil
            return .alarm(Alarm(name: raiserName, circle: circleName, rings: mark?.rang != true, account: me,
                                circleId: circleId, sosId: response.id, at: opened.sealedTimeMs ?? now))
        }
    }
}
