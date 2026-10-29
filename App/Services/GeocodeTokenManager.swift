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

// MARK: - Wire DTOs (Privacy-Pass-style VOPRF geocode tokens)
//
// Shared between the APIService extension (network) and GeocodeTokenManager
// (state machine). The encoder is `.convertToSnakeCase` and the decoder
// `.convertFromSnakeCase` (see APIService.init), so camelCase Swift properties
// map to the backend's snake_case JSON automatically.

/// `GET /api/v1/geocode/token-key` (public). Flat JSON — clients pin
/// `(keyId, publicKey)` to verify issuance DLEQ proofs and detect rotation.
struct GeocodeTokenKeyResponse: Decodable {
    let success: Bool
    let keyId: String?
    let publicKey: String?
    let ttlSeconds: Int?
    let suite: String?
}

/// Body of `POST /api/v1/geocode/tokens`.
struct GeocodeIssueRequest: Encodable {
    let blinded: [String]
}

/// `data` payload of the `APIResponse` from `POST /api/v1/geocode/tokens`.
/// `evaluated` + `proofs` are index-paired with the request `blinded` batch.
struct GeocodeIssueResponse: Decodable {
    let keyId: String
    let publicKey: String
    let evaluated: [String]
    let proofs: [String]
    let ttlSeconds: Int?
    let suite: String?
}

/// The single-use credit presented at redemption: `(nonce, W)`.
struct GeocodeRedeemToken: Encodable {
    let nonceB64: String
    let evaluatedB64: String
}

/// Body of `POST /api/v1/geocode/reverse` (session-less redemption). Carries NO
/// identity — only the spent credit + coordinates. The backend aliases lat/lng.
struct GeocodeRedeemRequest: Encodable {
    let token: GeocodeRedeemToken
    let keyId: String
    let lat: Double
    let lng: Double
    let size: Int
}

/// Body of `POST /api/v1/geocode/search` (session-less redemption). Same trust
/// model as the reverse request — one spent credit, no identity — but note what
/// it additionally carries: **the user's search string**. That is what this
/// endpoint DOES reveal and reverse did not, and it is never logged on either
/// side. Treat `text` with the same care as coordinates.
///
/// FIELD NAMES: the encoder applies `.convertToSnakeCase`, so `focusLat` goes on
/// the wire as `focus_lat`. Pelias itself wants `focus.point.lat`, so the server
/// accepts BOTH spellings and relies on the snake_case one here. That keeps this
/// struct free of hand-written CodingKeys (which would have to spell every other
/// key in its already-converted form). If the server ever dropped that alias,
/// this would silently stop biasing results toward the map rather than failing
/// loudly — so the alias is load-bearing.
struct GeocodeSearchRequest: Encodable {
    let token: GeocodeRedeemToken
    let keyId: String
    let text: String
    let size: Int
    let focusLat: Double?
    let focusLng: Double?
}

/// Client for the privacy-preserving geocode-token flow (VOPRF / Privacy Pass).
/// Mirrors the Android app's `GeocodeTokenManager`. Splits "who you are" from
/// "where you are":
///
///  1. **Mint** (authenticated, premium-gated): blind random nonces in the SDK,
///     `POST /geocode/tokens`, then `geocodeFinalizeTokens` — which VERIFIES the
///     issuance DLEQ proof against the pinned public key — into single-use
///     anonymous credits, stored in the Keychain.
///  2. **Spend** (session-less): pop one credit and `POST /geocode/reverse` with
///     NO Authorization header (see `APIService.geocodeRedeemReverse`).
///
/// `redeemReverse` returns the raw Pelias GeoJSON on success, or `nil` when the
/// private path is unavailable (not premium, VOPRF unconfigured, no credits,
/// stale key epoch) — the caller (`ServerGeocoder`) then falls back to the
/// authenticated proxy, so this is a strict privacy *upgrade* that degrades
/// gracefully on a server with no VOPRF key configured.
///
/// KEY PINNING: we pin `(keyId, publicKey)` from the public token-key endpoint
/// (the same value every user sees) and require each issuance to match it — a
/// server trying to tag this user with a per-user key to deanonymize them at
/// redemption would diverge and be refused. (Assurance against a server that
/// lies consistently at both endpoints needs key transparency — out of scope.)
///
/// Being an `actor` makes each step's pool bookkeeping atomic, but NOT the whole
/// mint/spend cycle: calls interleave at every `await`, and every spend awaits
/// the network. `presenting` and `refilling` are what keep two callers from
/// presenting the same credit or minting twice.
actor GeocodeTokenManager {
    static let shared = GeocodeTokenManager()

    private let api = APIService.shared
    private let keychain = KeychainService.shared

    /// A stored credit `(nonce_b64, output_b64=W)`. Short field names keep the
    /// Keychain blob compact and semantics-free.
    struct StoredToken: Codable, Equatable {
        let n: String
        let w: String
    }

    /// Credits minted per refill (backend caps a batch at 128).
    private let refillBatch: UInt32 = 40
    /// Refill when the pool drops to/below this.
    private let lowWatermark = 8
    /// Cap redeem retries when consecutive credits come back spent (409).
    private let maxRedeemRetries = 4

    /// Credits a spend is presenting right now, by nonce. Without it, two
    /// searches that read the same pool would both take `pool.last` and one of
    /// them would meet a 409; a spend presents only credits no other spend holds.
    private var presenting: Set<String> = []
    /// The refill in flight. A spend that finds the pool low while another is
    /// minting waits for that batch instead of minting a second one.
    private var refilling: Task<Bool, Never>?

    /// The pool and the pinned key id that a spend reads, when not the Keychain.
    /// A test gives a manager of its own an in-memory pool, to run two real
    /// spends side by side.
    struct PoolStore {
        var pinnedKeyId: () -> String?
        var load: () -> [StoredToken]
        var save: ([StoredToken]) -> Void
        /// Wipes the pin and the pool (`clearPinAndPool`).
        var clear: () -> Void = {}
    }
    /// nil = the Keychain, which is every manager but a test's.
    private let store: PoolStore?

    private init() { store = nil }

    /// A manager over `store` instead of the Keychain. Tests only.
    init(store: PoolStore) { self.store = store }

    /// Reverse-geocode privately by spending one anonymous credit. Returns the
    /// raw Pelias GeoJSON `Data` on success, or `nil` if the private path is
    /// unavailable — the caller must then fall back.
    func redeemReverse(latitude: Double, longitude: Double, size: Int) async -> Data? {
        await spend { [api] token, keyId in
            try await api.geocodeRedeemReverse(GeocodeRedeemRequest(
                token: token, keyId: keyId,
                lat: latitude, lng: longitude, size: size))
        }
    }

    /// Forward-geocode privately by spending one anonymous credit. Returns the
    /// raw Pelias GeoJSON `Data` on success, or `nil` if the private path is
    /// unavailable — the caller must then fall back to tiles.
    ///
    /// `nil` here means the server COULD NOT answer (no credit, HTTP error,
    /// unreachable). It does NOT mean "no matches" — an empty feature collection
    /// inside a 200 is an authoritative no-match and is a completely different
    /// thing to the caller. See `ServerGeocoder.forward`.
    func redeemSearch(text: String, size: Int, focusLat: Double?, focusLng: Double?) async -> Data? {
        await spend { [api] token, keyId in
            try await api.geocodeRedeemSearch(GeocodeSearchRequest(
                token: token, keyId: keyId,
                text: text, size: size,
                focusLat: focusLat, focusLng: focusLng))
        }
    }

    /// Pin a key, top the pool up, then spend credits until one redeems.
    ///
    /// Extracted so reverse and search cannot drift apart on the parts that are
    /// actually security-relevant: single-use consumption, dropping already-spent
    /// (409) credits, and wiping the pin on a rotated key epoch (401). Android
    /// factors the same loop as `spendCredit { tok, keyId -> ... }`.
    ///
    /// RUNS TO ITS END WHATEVER HAPPENS TO THE CALLER. The next keystroke
    /// cancels a search, and that cancellation must not reach a redemption
    /// already on the wire: the loop would take the thrown error for a network
    /// failure and KEEP the credit, but the server takes a credit before it
    /// asks the geocoder and gives it back only on a 502. The answer would be
    /// paid for and thrown away, and the next search would open with a 409 on
    /// the dead credit. The same cut could drop a batch the refill had just
    /// minted.
    func spend(
        _ send: @escaping (GeocodeRedeemToken, String) async throws -> (data: Data, status: Int)
    ) async -> Data? {
        await Self.shielded { await self.spendToTheEnd(send) }
    }

    /// `work` in a task of its own: a task inherits no cancellation, so the
    /// caller's never reaches the work. The caller still waits for the answer.
    static func shielded<T: Sendable>(_ work: @escaping @Sendable () async -> T) async -> T {
        await Task { await work() }.value
    }

    private func spendToTheEnd(
        _ send: @escaping (GeocodeRedeemToken, String) async throws -> (data: Data, status: Int)
    ) async -> Data? {
        // 1. Pin the current key (once, then cached until rotation/401).
        if pinnedKeyId() == nil {
            guard await fetchAndPinKey() else { return nil }
        }

        // 2. Top up if we're low or empty.
        if loadPool().count <= lowWatermark {
            _ = await refillOnce()
        }
        var mine = Self.available(loadPool(), presenting: presenting, by: \.n)
        if mine.isEmpty { return nil }

        guard let keyId = pinnedKeyId() else { return nil }

        // 3. Spend credits until one redeems; drop spent (409) ones. The loop
        //    presents from the end of `mine`, never more than `maxRedeemRetries`.
        let held = Set(mine.suffix(maxRedeemRetries).map(\.n))
        presenting.formUnion(held)
        let before = mine
        let spent = await Self.runSpendLoop(pool: &mine, maxAttempts: maxRedeemRetries) { tok in
            try await send(GeocodeRedeemToken(nonceB64: tok.n, evaluatedB64: tok.w), keyId)
        }
        presenting.subtract(held)
        if spent.keyRotated {
            // Stale/rotated key epoch: our pinned key is no longer
            // current. Wipe and fall back this round; the next call
            // re-pins + mints. Never write `mine` back: that would
            // resurrect credits minted under the old, now-rejected
            // key epoch.
            // Wipe only while the pin is still the one this spend
            // presented under: another spend may have re-pinned and
            // minted under the current key while this one was on the
            // wire, and that is not this 401's to wipe. Then only
            // what this spend used up comes out, the 401's credit
            // included; `afterSpend` never adds, so nothing of the
            // old epoch comes back.
            if pinnedKeyId() == keyId {
                clearPinAndPool()
            } else {
                savePool(Self.afterSpend(loadPool(), before: before, after: mine, by: \.n))
            }
            return nil
        }
        // Take out what THIS spend used up, from the pool as it is NOW.
        // Writing `mine` back whole would put back any credit another
        // spend had consumed meanwhile, to come back later as a 409.
        savePool(Self.afterSpend(loadPool(), before: before, after: mine, by: \.n))
        return spent.data
    }

    /// The credits a spend may present: the pool minus those another spend holds.
    static func available<Credit, ID: Hashable>(
        _ pool: [Credit], presenting: Set<ID>, by id: (Credit) -> ID
    ) -> [Credit] {
        pool.filter { !presenting.contains(id($0)) }
    }

    /// The pool after a spend: `current` minus what the spend used up, which is
    /// what it held `before` the loop and no longer holds `after` it (consumed,
    /// or dropped as already spent). Only ever removes.
    static func afterSpend<Credit, ID: Hashable>(
        _ current: [Credit], before: [Credit], after: [Credit], by id: (Credit) -> ID
    ) -> [Credit] {
        let usedUp = Set(before.map(id)).subtracting(after.map(id))
        return current.filter { !usedUp.contains(id($0)) }
    }

    /// One refill at a time: a second caller waits for the batch in flight.
    private func refillOnce() async -> Bool {
        if let refilling { return await refilling.value }
        let minting = Task { await self.refill() }
        refilling = minting
        let minted = await minting.value
        refilling = nil
        return minted
    }

    /// What one redemption reply means for the credit that was presented.
    ///
    /// A type of its own because the loop's exits are easy to get wrong
    /// unseen: in Swift, a `break` inside a `switch` leaves the `switch`, not
    /// the loop, so a 5xx meant to fall back would present the SAME credit
    /// again, up to `maxRedeemRetries` times. Against a geocoder that needs
    /// its whole 10 s upstream timeout to fail, the user would wait through a
    /// second failed call before the tiles were allowed to answer, and two
    /// credits would be gone. (Kotlin's `break` in the Android client does
    /// leave the loop.)
    enum RedeemStep: Equatable {
        /// 2xx: the credit is consumed and the reply is the answer.
        case answered
        /// 409: the server has this credit as spent. Drop it, try the next.
        case alreadySpent
        /// 401: the pinned key epoch is stale. The credit is consumed like any
        /// reply's; the caller wipes pin and pool, if still its pin, and falls back.
        case keyRotated
        /// The server could have seen it and gave no answer: any other status
        /// (502, 503, any 5xx, 429), a timeout, an error after the request may
        /// have left. DROP the credit and fall back to the tiles now.
        ///
        /// THE CREDIT IS NOT PRESENTED AGAIN, EVEN WHEN THE SERVER GAVE IT BACK
        /// (the same rule in all three apps). The server refunds a credit the
        /// geocoder did not answer, but a kept credit goes out again with the
        /// NEXT query, and one nonce under two queries lets the gateway link
        /// them. One credit per failure buys that.
        case unanswered
        /// The request provably never left the phone: no network, no DNS answer,
        /// no connection to the host, cellular data or roaming refused by the
        /// system, or a body that could not be encoded. KEEP the credit and fall
        /// back.
        case neverLeft

        static func of(status: Int) -> RedeemStep {
            switch status {
            case 200...299: return .answered
            case 409: return .alreadySpent
            case 401: return .keyRotated
            default: return .unanswered
            }
        }

        /// A redemption that threw. Kept only when it is certain nothing reached
        /// the server: the connection never opened, or the body was never built
        /// (`encoder.encode` throws before `session.data(for:)`, APIService). A
        /// timeout, a dropped connection, or anything else may have delivered it.
        static func of(error: Error) -> RedeemStep {
            if let url = error as? URLError, Self.neverSent.contains(url.code) { return .neverLeft }
            if error is EncodingError { return .neverLeft }
            return .unanswered
        }

        /// Refused before a packet left. The last two are the system's own
        /// refusals when cellular data is off for Track, or roaming is: without
        /// them such a phone would drop a credit per search, for nothing.
        static let neverSent: Set<URLError.Code> = [
            .notConnectedToInternet, .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost,
            .dataNotAllowed, .internationalRoamingOff,
        ]
    }

    /// What `runSpendLoop` did.
    struct SpendLoopResult: Equatable {
        /// The reply body of the redemption that was answered, if one was.
        var data: Data?
        /// The pinned key was rejected: the caller must wipe pin AND pool.
        var keyRotated = false
        /// Redemptions sent. One, unless credits came back already spent.
        var attempts = 0
    }

    /// Spend credits from the END of `pool` until one redeems.
    ///
    /// Static, and generic over the credit, so the rule runs without a Keychain,
    /// a network or this actor: `GeocodeSpendLoopTests` drives it with integers.
    /// `pool` is edited in place. A credit the server could have seen is
    /// removed, answered or not; only one that never left stays where it was.
    static func runSpendLoop<Credit>(
        pool: inout [Credit],
        maxAttempts: Int,
        send: (Credit) async throws -> (data: Data, status: Int)
    ) async -> SpendLoopResult {
        var out = SpendLoopResult()
        spending: while let credit = pool.last, out.attempts < maxAttempts {
            out.attempts += 1
            var data: Data?
            let step: RedeemStep
            do {
                let reply = try await send(credit)
                data = reply.data
                step = RedeemStep.of(status: reply.status)
            } catch {
                step = RedeemStep.of(error: error)
            }
            switch step {
            case .answered:
                pool.removeLast()          // single-use, consumed
                out.data = data
                break spending
            case .alreadySpent:
                pool.removeLast()          // drop, try the next one
            case .keyRotated:
                pool.removeLast()          // a reply like any other: never presented again
                out.keyRotated = true
                break spending
            case .unanswered:
                pool.removeLast()          // seen: never presented again; fall back
                break spending
            case .neverLeft:
                break spending             // never sent: keep the credit, fall back
            }
        }
        return out
    }

    /// Fetch + pin `(keyId, publicKey)` from the public token-key endpoint.
    private func fetchAndPinKey() async -> Bool {
        guard let resp = try? await api.geocodeTokenKey(),
              let kid = resp.keyId, let pk = resp.publicKey else {
            return false
        }
        do {
            try keychain.save(kid, for: .geocodeKeyId)
            try keychain.save(pk, for: .geocodePublicKey)
        } catch {
            return false
        }
        return true
    }

    /// Mint a fresh batch of credits. Verifies the issuance key against the
    /// pinned/published key (per-user-key defense) and the DLEQ proof (inside
    /// `geocodeFinalizeTokens`) before storing anything.
    private func refill() async -> Bool {
        guard let pinnedKeyId = keychain.getString(for: .geocodeKeyId),
              let pinnedPk = keychain.getString(for: .geocodePublicKey) else {
            return false
        }

        let blind = geocodeBlindTokens(count: refillBatch)

        let data: GeocodeIssueResponse
        do {
            data = try await api.geocodeIssueTokens(blinded: blind.blinded)
        } catch {
            return false   // 402 (free) / 429 / 503 / network
        }

        // Per-user-key defense: issuance must use the public, everyone-sees-the-
        // same key we pinned. On divergence, trust ONLY the public endpoint.
        var pkForFinalize = pinnedPk
        if data.keyId != pinnedKeyId || data.publicKey != pinnedPk {
            guard await fetchAndPinKey(),
                  let freshKeyId = keychain.getString(for: .geocodeKeyId),
                  let freshPk = keychain.getString(for: .geocodePublicKey),
                  freshKeyId == data.keyId, freshPk == data.publicKey else {
                // Published key still disagrees with what we were handed →
                // refuse (potential per-user key). Drop the whole batch.
                return false
            }
            // Legitimate rotation: old credits are invalid under the new epoch.
            savePool([])
            pkForFinalize = data.publicKey
        }

        let tokens: [GeocodeToken]
        do {
            tokens = try geocodeFinalizeTokens(
                states: blind.states,
                evaluated: data.evaluated,
                proofs: data.proofs,
                publicKey: pkForFinalize)
        } catch {
            // DLEQ proof verification failed — evaluation inconsistent with the
            // pinned key. Store nothing.
            return false
        }

        var pool = loadPool()
        pool.append(contentsOf: tokens.map { StoredToken(n: $0.nonceB64, w: $0.outputB64) })
        savePool(pool)
        return true
    }

    private func clearPinAndPool() {
        if let store { return store.clear() }
        keychain.delete(key: .geocodeKeyId)
        keychain.delete(key: .geocodePublicKey)
        keychain.delete(key: .geocodeTokenPool)
    }

    private func pinnedKeyId() -> String? {
        if let store { return store.pinnedKeyId() }
        return keychain.getString(for: .geocodeKeyId)
    }

    private func loadPool() -> [StoredToken] {
        if let store { return store.load() }
        guard let json = keychain.getString(for: .geocodeTokenPool),
              let data = json.data(using: .utf8),
              let pool = try? JSONDecoder().decode([StoredToken].self, from: data) else {
            return []
        }
        return pool
    }

    private func savePool(_ pool: [StoredToken]) {
        if let store { return store.save(pool) }
        guard let data = try? JSONEncoder().encode(pool),
              let json = String(data: data, encoding: .utf8) else { return }
        try? keychain.save(json, for: .geocodeTokenPool)
    }
}
