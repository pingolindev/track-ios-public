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
import CryptoKit
import PingolinTrackSDK

/// Self-tracking key bootstrap. Mirrors the Android app's
/// `LocationRepository.ensurePersonalKeyExists`. The server stores
/// the user's own (non-circle) location points under a nil-UUID
/// pseudo-circle; the SDK needs the wrapped self-key loaded under
/// the same nil UUID before history queries against that circle can
/// decrypt.
///
/// Flow on a fresh device:
///
///   1. GET /api/v1/users/me/self-key. If the server already holds a
///      key bundle (user previously signed in from web or Android),
///      import it via `cryptoManager.storeCircleKey(SELF_CIRCLE_UUID, …)`.
///   2. If the server returns nil-data, generate a fresh key via
///      `prepareCircleCreation()`, POST it so other devices can pick it up
///      later, and install it locally under SELF_CIRCLE_UUID only once the
///      server has accepted it. That order is load-bearing — see
///      `mintAndPublish`.
///
/// Idempotent — a personal key in use (`personalKeyInUse`) short-
/// circuits if we've already done this.
@MainActor
enum SelfKeyManager {

    /// Server-side pseudo-circle id for personal tracking. Matches
    /// the Android app's SELF_CIRCLE_UUID and the nil-UUID
    /// convention in `/api/v1/circles/{circleId}/locations`.
    nonisolated static let selfCircleUuid = "00000000-0000-0000-0000-000000000000"

    private static let api = APIService.shared
    private static let crypto = SDKCrypto.cryptoManager

    /// Whether `crypto` has a personal key IN USE: one new rows are sealed
    /// under. Not `hasCircleKey`, which is also true for a slot that holds only
    /// RETIRED keys. After an email reset and a restore the old personal key
    /// comes in exactly like that: it reads old history, nothing is sealed
    /// under it, and this device still has to mint a new one. The SDK's write
    /// gate.
    nonisolated static func personalKeyInUse(_ crypto: PingolinTrackSDK.CryptoManager) -> Bool {
        crypto.hasCircleKeyInUse(circleId: selfCircleUuid)
    }

    /// Best-effort bootstrap. Returns true when a usable self key is
    /// registered against the SDK by the time we return. Failures
    /// are non-fatal — log + return false; callers fall back to
    /// "no personal history available" instead of crashing.
    ///
    /// Every exit also records a `SelfKeyHealth` on `SelfKeyStatus.shared`, so
    /// the failure states have a surface other than the console. See
    /// SelfKeyHealth for what each one means and why they are not
    /// interchangeable.
    ///
    /// `mayReplace`: whether this pass may mint over a stored copy it cannot
    /// open when personal tracking looks empty. Only a launch or a sign-in may:
    /// the passes that run by themselves — a background relaunch, the
    /// foreground cadence, the retry clock — never reach that branch, because
    /// "empty" is only the server's word.
    @discardableResult
    static func ensure(mayReplace: Bool = true) async -> Bool {
        // One pass at a time. Launch, sign-in, a background relaunch, the
        // foreground and the retry clock all call this, and two passes that
        // both find no stored key would each mint and publish one: the second
        // POST is an upsert, so it would replace the key the first pass had
        // just installed. A caller that arrives while a pass runs gets a pass
        // that started after it — the one running may predate what the
        // caller just changed (the password typed in place).
        if let running = inFlight {
            runAgain = true
            runAgainMayReplace = runAgainMayReplace || mayReplace
            return await running.value
        }
        let pass = Task { @MainActor () -> Bool in
            var result = await ensureOnce(mayReplace: mayReplace)
            while runAgain {
                let again = runAgainMayReplace
                runAgain = false
                runAgainMayReplace = false
                result = await ensureOnce(mayReplace: again)
            }
            inFlight = nil
            return result
        }
        inFlight = pass
        return await pass.value
    }

    private static var inFlight: Task<Bool, Never>?
    private static var runAgain = false
    private static var runAgainMayReplace = false

    /// When the retry clock next runs a pass, while the last one ended in a
    /// state that clears itself (`SelfKeyHealth.retriesItself`).
    private static var nextRetryAt: Date?
    private static var failuresInARow = 0

    /// Every outcome goes through here: the notice, and the retry clock.
    private static func record(_ health: SelfKeyHealth, now: Date = Date()) {
        SelfKeyStatus.shared.record(health)
        (nextRetryAt, failuresInARow) = retrySchedule(after: health, failuresInARow: failuresInARow, now: now)
    }

    /// The retry clock after an outcome: when the next pass runs (nil: none
    /// is needed, or only the password helps) and the failures in a row so far.
    ///
    /// A failed publish is tried again at most once an hour, the same cap as a
    /// republish; the others, which only look, on the backoff.
    nonisolated static func retrySchedule(after health: SelfKeyHealth, failuresInARow: Int,
                                          now: Date) -> (at: Date?, failures: Int) {
        guard health.retriesItself else { return (nil, 0) }
        let failures = failuresInARow + 1
        let wait = health == .publishFailed ? publishRetryInterval : RetryClock.delay(afterFailures: failures)
        return (now.addingTimeInterval(wait), failures)
    }

    nonisolated static let publishRetryInterval: TimeInterval = 60 * 60

    /// A state that can clear itself is tried again by the app, never by
    /// asking anybody to reopen it. MainTabView's foreground loop calls this
    /// on every tick — active only, so a resident background process does not
    /// poll all night; background relaunches run `ensure()` themselves.
    static func retryIfDue(now: Date = Date()) async {
        guard let due = nextRetryAt, now >= due else { return }
        await ensure(mayReplace: false)
    }

    private static func ensureOnce(mayReplace: Bool) async -> Bool {
        if personalKeyInUse(crypto) {
            if let userId = AuthManager.shared.userId {
                // The account's published copy, judged by the
                // SDK alone (adopt, flag, republish), then the
                // unsigned-copy duty.
                await checkServerCopy(userId: userId)
                await signServerCopyIfUnsigned(userId: userId)
            }
            // The history here works either way; without the signing
            // key the copy just can't be checked, and nothing new
            // signed, until the password is typed.
            record(Self.healthWithHistoryHere(verdict: lastCopyCheck?.verdict, signingKeyMissing: signingKeyMissing,
                                              passwordTried: passwordDidNotRestoreSigningKey))
            return true
        }
        guard let userId = AuthManager.shared.userId else {
            record(.unknown)
            return false
        }

        // No account keys on this device: nothing can be opened or set up
        // here, and the server's copy must not be judged by a failed
        // unwrap that says nothing about it. Only the password fixes this,
        // asked for in place — so say that, before anything below could
        // call it a broken personal setup.
        guard (try? crypto.exportPublicKey()) != nil else {
            record(.noAccountKeys)
            return false
        }

        // 1) Try to fetch an existing wrap from the server.
        //
        // `try?` would collapse a THROWN lookup into the same nil the
        // server returns when it holds no key — so one flaky GET would
        // fall through to generation, and the POST that follows is an
        // upsert: a dropped connection at launch would be enough to
        // overwrite a perfectly fine self key. Distinguish them and
        // fail closed.
        let bundle: CircleKeyBundleResponse?
        var supersededByReset = false
        do {
            bundle = try await api.getSelfKey()
        } catch {
            print("[Track] SelfKeyManager: self-key lookup failed (\(error)) — not minting over what may be there")
            record(.unreachable)
            return false
        }

        if let bundle {
            do {
                try crypto.storeCircleKey(
                    circleId: selfCircleUuid,
                    encryptedKey: bundle.encryptedCircleKey.nonce + bundle.encryptedCircleKey.ciphertext,
                    senderPublicKey: bundle.ephemeralPublicKey,
                    keyVersion: Int32(bundle.keyVersion),
                    senderUserId: bundle.senderUserId ?? userId,
                    recipientUserId: bundle.recipientUserId ?? userId,
                    wrapSignatureHex: bundle.wrapSignature,
                    // A self-key wrap is authored by THIS
                    // account, so verify it against our OWN
                    // local signing key — never the signer key
                    // the server echoes back next to the wrap.
                    // Otherwise a substituting server passes
                    // verification trivially and installs a
                    // self circle key it knows, breaking
                    // blindness for personal history. nil if
                    // the seed isn't imported yet → SDK
                    // grace-accepts (first-use TOFU). We
                    // deliberately do NOT fall back to
                    // bundle.senderSigningPubkey — verifying
                    // against a server-supplied key is a false
                    // guarantee, strictly worse than nil.
                    senderSigningPubkeyHex: try? crypto.signingPublicKeyHex()
                )
                // A copy that opened only through an identity
                // from before a password reset is kept RETIRED,
                // for reading old history, never as the key in
                // use. Then nothing is lost by a new personal
                // key: mint and publish one (below, replacing
                // the server's copy, which the server keeps as
                // a retired row), asking nobody. The old key
                // stays retired here.
                supersededByReset = crypto.personalCopySupersededByReset(
                    encryptedKey: bundle.encryptedCircleKey.nonce + bundle.encryptedCircleKey.ciphertext,
                    senderPublicKey: bundle.ephemeralPublicKey)
                if !supersededByReset {
                    record(Self.healthWithHistoryHere(verdict: nil, signingKeyMissing: signingKeyMissing,
                                                      passwordTried: passwordDidNotRestoreSigningKey))
                    await signServerCopyIfUnsigned(userId: userId, knownBundle: bundle)
                    return true
                }
                print("[Track] SelfKeyManager: the published copy opens only through a restored identity — "
                      + "kept retired; a new personal key is minted")
            } catch {
                // Logged unconditionally, so a silent
                // unwrap failure can be diagnosed in any
                // build. The most common cause is that the
                // SDK's X25519 private key wasn't imported
                // before this call (a caller ordering
                // mistake) — the wrap can't be
                // ECDH-decrypted and storeCircleKey
                // returns KeyNotFound.
                print("[Track] SelfKeyManager: server-side wrap failed to import: \(error)")

                // A copy whose signature does not verify under
                // this account's own key is a key someone ELSE
                // chose: refused, never minted over, and not
                // "can't open it" either — no flag.
                if let mobile = error as? MobileError, case .SignatureInvalid = mobile {
                    record(.undecryptable)
                    return false
                }
                // It does not open here: say so. The server
                // wakes the account's other phones; the one
                // that holds the key republishes it for the
                // account's current keys, and this device
                // takes it on its next pass. Once per
                // distinct copy.
                await flagUnreadable(bundle)

                // The server HAS a key; we merely cannot open
                // it. That is not "no key", and falling
                // through to generation here destroys data:
                // POST /users/me/self-key is an UPSERT, and
                // the Android app deliberately never mints a
                // replacement (a local key would break
                // cross-platform sync), so the phone keeps
                // encrypting every personal row under the key
                // whose only server copy would be gone.
                //
                // "Malformed payload" and "wrong keypair" are
                // indistinguishable from here — both surface
                // as a failed unwrap — so decide on what is at
                // stake instead: mint only if the stored key
                // is demonstrably protecting nothing.
                if mayReplace, await personalTrackingIsEmpty() {
                    print("[Track] SelfKeyManager: stored key protects no personal history — replacing it")
                } else {
                    print("[Track] SelfKeyManager: stored key is in use by another device — refusing to replace it; "
                          + "reported it, so the device that holds it republishes it")
                    // The one branch that MUST reach the user. We refuse to mint
                    // over live key material; it clears once a device that holds
                    // the key has republished it and a later pass here opens it.
                    record(.undecryptable)
                    return false
                }
            }
        }

        // 2) No usable server-side key, and nothing to lose — generate +
        // publish. A copy is only ever published signed, so without the
        // signing key the password comes first, once; if it did not
        // bring the key back, the publish is tried on its hourly clock.
        if signingKeyMissing, !passwordDidNotRestoreSigningKey {
            record(.noAccountKeys)
            return false
        }
        let outcome = await mintAndPublish(
            prepare: { try crypto.prepareCircleCreation() },
            publish: { creation in
                // Published only as the SDK's publishable
                // copy: wrapped to this account, signed, with
                // the account's pseudonym under exactly this
                // key so the server records both in one
                // write. Never unsigned: without the signing
                // key this throws, and the publish is tried
                // again on the hourly clock.
                let copy = try crypto.publishablePersonalKey(heldUnder: creation.tempCircleId, userId: userId)
                _ = try await api.storeSelfKey(
                    encryptedSelfKey: EncryptedBlobRequest(
                        nonce: copy.encryptedKey.nonce,
                        ciphertext: copy.encryptedKey.ciphertext
                    ),
                    ephemeralPublicKey: copy.ephemeralPublicKey,
                    wrapSignature: copy.wrapSignature,
                    userPseudonym: copy.userPseudonym,
                    replace: supersededByReset ? true : nil
                )
            },
            install: { creation in
                // Promote the temp circle id to the canonical nil UUID so
                // future hasCircleKey checks resolve.
                try crypto.finalizeCircleCreation(
                    tempCircleId: creation.tempCircleId,
                    realCircleId: selfCircleUuid
                )
            }
        )
        record(outcome)
        return outcome == .ok
    }

    /// Mint a fresh self key, publish it, and only then install it locally.
    ///
    /// # The order is the whole point
    ///
    /// `install` is `finalizeCircleCreation`, which does not merely rename an
    /// in-memory entry: it calls the SDK's `persist_keys()`, so
    /// the key lands in secure storage and `loadPersistedKeys` brings it back on
    /// every future launch. `ensure()` opens with
    /// `if personalKeyInUse(crypto) { … return true }`.
    ///
    /// Doing that BEFORE the publish would make a refused publish silent and
    /// permanent. The POST throws, `ensure()` returns false, and the key is
    /// nevertheless on disk, so the short-circuit above passes on this launch
    /// and every launch after it. Nothing ever retries. Every personal location
    /// the device then writes is sealed under a key the server does not hold
    /// and no other device can obtain: worse than the overwrite the server's
    /// replace-guard refusal exists to prevent, because it is invisible.
    ///
    /// Publishing first inverts that. `prepare_circle_creation` files the key
    /// under a `temp_…` id and does NOT persist, so a refusal leaves nothing
    /// under `selfCircleUuid` in memory or on disk, no personal key is in use,
    /// and the next launch runs the whole flow again — by then the lookup will
    /// usually return the stored key and simply import it. Rolling the persist
    /// back instead is not available: the SDK exposes no per-circle removal,
    /// only `clear_all_keys()`, which would drop every circle key on the device
    /// to undo one.
    ///
    /// This is also the order the Android app uses (`createAndUploadSelfKey`
    /// uploads before `finalizeCircleCreation`) — though Android logs a failed
    /// upload and finalizes anyway, so it keeps the divergence this avoids.
    ///
    /// A publish that fails for any OTHER reason is treated the same way, and
    /// deliberately: a key installed locally that the server never received is
    /// the same silent divergence arrived at by a different route. The cost is
    /// that a device which cannot reach the server does not start personal
    /// tracking until it can — recoverable on any later launch, unlike the key
    /// material it protects.
    ///
    /// The three effects are parameters so the ORDER can be tested without a
    /// network or a device — same reason `routingIds` and `notice` are pure.
    /// Returns the health to record; it never records it itself.
    static func mintAndPublish(
        prepare: () throws -> CircleCreationData,
        publish: (CircleCreationData) async throws -> Void,
        install: (CircleCreationData) throws -> Void
    ) async -> SelfKeyHealth {
        do {
            let creation = try prepare()
            do {
                try await publish(creation)
            } catch let error as APIError where error.isSelfKeyInUse {
                // The server holds a key that is protecting data and
                // would not let this one replace it. Correct of it, and
                // nothing is lost: we install NOTHING, so the next launch
                // is free to try again, and what it finds will be the
                // key we were refused permission to destroy. Logged
                // unconditionally — a release build that hits this has a
                // user with no personal tracking and no idea why, and the
                // state is reported to `SelfKeyStatus` for exactly that
                // reason.
                print("[Track] SelfKeyManager: server refused the new self key — it already holds "
                      + "one that is protecting data (\(error.message)). Nothing installed locally; "
                      + "the retry clock fetches the stored key, and a copy that won't open here is "
                      + "reported so the device that holds it republishes it.")
                return .replacementRefused
            }
            try install(creation)
            return .ok
        } catch {
            #if DEBUG
            print("[Track] SelfKeyManager: failed to mint + publish self key: \(error)")
            #endif
            // Nothing was installed, so the retry clock is free to run the
            // whole flow again (`retriesItself`).
            return .publishFailed
        }
    }


    /// The account whose server copy has been checked this process.
    private static var signCheckedFor: String?

    /// The server's copy of our personal key may have been stored WITHOUT a
    /// signature by an older client. An unsigned "from me, to me" wrap is
    /// exactly what a substituting server can fabricate, so once a device that
    /// holds the key sees such a copy, it attaches its signature to THOSE
    /// bytes: `PUT /circles/<nil uuid>/wrap-signature` stores it only if the
    /// stored wrap is still exactly what we read, so it cannot land on a key
    /// another device published meanwhile — which a re-POST of the old bytes
    /// could. The SDK signs only a wrap that opens to the key this device
    /// already holds, so this never vouches for a server-chosen key. Once per
    /// account per process; best effort.
    ///
    /// `evenIfSigned`: the SDK found the copy's signature not valid for this
    /// account (`PublishedCopyStatus.unsigned`) — sign those bytes too.
    static func signServerCopyIfUnsigned(userId: String, knownBundle: CircleKeyBundleResponse? = nil,
                                         evenIfSigned: Bool = false) async {
        guard signCheckedFor != userId else { return }
        signCheckedFor = userId
        let bundle: CircleKeyBundleResponse
        if let knownBundle {
            bundle = knownBundle
        } else {
            guard let fetched = try? await api.getSelfKey() else { return }
            bundle = fetched
        }
        guard evenIfSigned || (bundle.wrapSignature ?? "").isEmpty else { return }
        do {
            let signature = try crypto.signOwnCircleKeyWrap(
                circleId: selfCircleUuid,
                userId: userId,
                keyVersion: Int32(bundle.keyVersion),
                encryptedKey: bundle.encryptedCircleKey.nonce + bundle.encryptedCircleKey.ciphertext,
                senderPublicKey: bundle.ephemeralPublicKey
            )
            _ = try await api.signOwnCircleWrap(
                circleId: selfCircleUuid,
                keyVersion: bundle.keyVersion,
                encryptedCircleKey: EncryptedBlobRequest(
                    nonce: bundle.encryptedCircleKey.nonce,
                    ciphertext: bundle.encryptedCircleKey.ciphertext
                ),
                ephemeralPublicKey: bundle.ephemeralPublicKey,
                wrapSignature: signature
            )
            print("[Track] SelfKeyManager: signed the server's copy of the personal key")
        } catch {
            // SignatureInvalid here means the server's copy does NOT open to
            // the key this device holds — worth knowing, never worth
            // "fixing" by signing it. InvalidInput means this device took the
            // key on trust (an unsigned first contact): it is never signed
            // here, and the copy stays unsigned until a copy this account
            // signed arrives.
            print("[Track] SelfKeyManager: did not sign the server's personal key copy: \(error)")
        }
    }

    // MARK: - The account's published copy

    /// The last look at the server's copy, and what the SDK said.
    private(set) static var lastCopyCheck: (at: Date, verdict: PersonalKeyVerdict)?
    /// Arguments of a copy the last check said to adopt, in case the adoption
    /// itself did not happen then (a send adopts first).
    private static var pendingAdoption: (at: Date, bundle: CircleKeyBundleResponse, recorded: String, userId: String)?
    /// The hourly cap on republishing. Persisted: silent pushes relaunch
    /// the app, and an in-memory cap would reset with every one.
    private static var lastRepublishAt: Date? {
        get {
            guard let key = republishKey else { return nil }
            let at = UserDefaults.standard.double(forKey: key)
            return at > 0 ? Date(timeIntervalSince1970: at) : nil
        }
        set {
            guard let key = republishKey else { return }
            if let newValue {
                UserDefaults.standard.set(newValue.timeIntervalSince1970, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    private static var republishKey: String? {
        AuthManager.shared.userId.map { "selfKey.lastRepublishAt.\($0.lowercased())" }
    }

    /// What one verdict makes this device do.
    enum CopyAction: Equatable {
        case none
        case adopt
        /// "Can't open it" (POST self-key/unreadable), once per distinct copy.
        case flag
        /// The password, asked for in place — never as a prompt from a pass
        /// that runs by itself (the Settings field shows it).
        case askForPassword
        /// Refused; logged only.
        case log
    }

    nonisolated static func action(for verdict: PersonalKeyVerdict) -> CopyAction {
        switch verdict {
        case .adopt: return .adopt
        case .ownCopyMatches, .tooSoon, .nothingRecorded: return .none
        // Only these two raise the flag: PseudonymMismatch only
        // means another device sent last.
        case .unsigned, .cannotOpen: return .flag
        case .noSigningKey: return .askForPassword
        case .retiredKey, .signatureInvalid, .pseudonymMismatch, .newerVersionHeld, .malformed: return .log
        }
    }

    /// Republish at most once an hour (as Android's
    /// SELF_KEY_REPUBLISH_COOLDOWN_MS).
    nonisolated static func mayRepublish(lastAt: Date?, now: Date) -> Bool {
        guard let lastAt else { return true }
        return now.timeIntervalSince(lastAt) >= 60 * 60
    }

    /// A copy's identity for the flag, as the server computes it: sha256
    /// over the RAW bytes encrypted_self_key ‖ nonce ‖ ephemeral_public_key.
    /// The same value dedupes here and goes in the flag as `copySha256`.
    nonisolated static func copyDigest(_ bundle: CircleKeyBundleResponse) -> String {
        let raw = [bundle.encryptedCircleKey.ciphertext, bundle.encryptedCircleKey.nonce, bundle.ephemeralPublicKey]
            .map { Self.bytes(fromHex: $0) }.reduce(Data(), +)
        return SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined()
    }

    /// Hex to bytes; anything that isn't hex hashes as its own text, so a
    /// malformed copy still has a stable identity.
    nonisolated static func bytes(fromHex hex: String) -> Data {
        let chars = Array(hex.lowercased())
        guard chars.count % 2 == 0 else { return Data(hex.utf8) }
        var data = Data(capacity: chars.count / 2)
        var index = 0
        while index < chars.count {
            guard let byte = UInt8(String(chars[index...index + 1]), radix: 16) else { return Data(hex.utf8) }
            data.append(byte)
            index += 2
        }
        return data
    }

    /// Look at the server's copy: at most every 5 minutes, or now (`force`,
    /// on a wake). The SDK decides; the app only acts on its verdict.
    static func checkServerCopy(userId: String, force: Bool = false, now: Date = Date()) async {
        if !force, let last = lastCopyCheck, now.timeIntervalSince(last.at) < 5 * 60 { return }
        // No answer, or nothing stored: nothing to judge (the first-publish
        // path is ensure()'s, and never runs from here).
        guard let bundle = try? await api.getSelfKey() else { return }
        guard let recorded = bundle.userPseudonym, !recorded.isEmpty else {
            lastCopyCheck = (now, .nothingRecorded)
            // Nothing recorded: when this device's own key opens the
            // published copy, the record is set to its pseudonym
            // (compare-and-set).
            await repairRecordIfCopyOpensHere(bundle, userId: userId)
            return
        }
        let verdict = crypto.checkPersonalKeyAdoption(
            userId: userId,
            encryptedKey: bundle.encryptedCircleKey.nonce + bundle.encryptedCircleKey.ciphertext,
            senderPublicKey: bundle.ephemeralPublicKey,
            keyVersion: Int32(bundle.keyVersion),
            wrapSignatureHex: bundle.wrapSignature,
            recordedPseudonym: recorded
        )
        lastCopyCheck = (now, verdict)
        switch action(for: verdict) {
        case .adopt:
            pendingAdoption = (now, bundle, recorded, userId)
            adoptPending(now: now)
        case .flag:
            print("[Track] SelfKeyManager: the account's personal copy can't be used here (\(verdict)) — reporting it")
            await flagUnreadable(bundle)
        case .askForPassword:
            print("[Track] SelfKeyManager: the signing key isn't loaded here — the copy can't be checked until the password is typed")
        case .log:
            print("[Track] SelfKeyManager: the account's personal copy was refused (\(verdict))")
            // PseudonymMismatch only means another device sent last.
            // When this device's own key opens the published copy
            // anyway, the record is what's wrong: repaired with the
            // compare-and-set.
            if verdict == .pseudonymMismatch {
                await repairRecordIfCopyOpensHere(bundle, userId: userId)
            }
        case .none:
            if verdict == .ownCopyMatches {
                await holderDuty(bundle, userId: userId, now: now)
            }
        }
    }

    /// Adopt what a check at most 5 minutes old said to adopt — the check does it
    /// at once, and a personal send calls this first (adopt first, and never skip
    /// or hold the send).
    @discardableResult
    static func adoptPending(now: Date = Date()) -> Bool {
        guard let pending = pendingAdoption else { return false }
        pendingAdoption = nil
        guard now.timeIntervalSince(pending.at) <= 5 * 60 else { return false }
        do {
            let result = try crypto.adoptPersonalKey(
                userId: pending.userId,
                encryptedKey: pending.bundle.encryptedCircleKey.nonce + pending.bundle.encryptedCircleKey.ciphertext,
                senderPublicKey: pending.bundle.ephemeralPublicKey,
                keyVersion: Int32(pending.bundle.keyVersion),
                wrapSignatureHex: pending.bundle.wrapSignature,
                recordedPseudonym: pending.recorded
            )
            lastCopyCheck = (now, result)
            print("[Track] SelfKeyManager: took the account's published personal copy (\(result)); the key held before stays readable")
            if result == .adopt { clearFlag() }
            return result == .adopt
        } catch {
            print("[Track] SelfKeyManager: adopting the account's published personal copy failed: \(error)")
            return false
        }
    }

    /// What the holder of the recorded key does about the published copy
    /// (the SDK's `checkPublishedPersonalCopy`), by the SDK's status alone:
    /// - `.opens`: nothing (the copy works here);
    /// - `.unsigned`: sign it in place (the unsigned-copy duty below);
    /// - `.cannotOpen`: publish the key in use again for the account's current
    ///   keys — signed, with its pseudonym, replacing — at most once an hour,
    ///   never a mint, never a key taken on trust;
    /// - `.opensToDifferentKey`: NOTHING. Another genuine key is published;
    ///   divergence is adoption's, or the wrong device would win.
    nonisolated static func holderAction(for status: PublishedCopyStatus) -> HolderAction {
        switch status {
        case .opens: return .none
        case .unsigned: return .signInPlace
        case .cannotOpen: return .republish
        case .opensToDifferentKey, .noKeyHere, .noSigningKey, .malformed: return .none
        }
    }

    enum HolderAction: Equatable {
        case none
        case signInPlace
        case republish
    }

    private static func holderDuty(_ bundle: CircleKeyBundleResponse, userId: String, now: Date) async {
        let status = crypto.checkPublishedPersonalCopy(
            userId: userId,
            encryptedKey: bundle.encryptedCircleKey.nonce + bundle.encryptedCircleKey.ciphertext,
            senderPublicKey: bundle.ephemeralPublicKey,
            keyVersion: Int32(bundle.keyVersion),
            wrapSignatureHex: bundle.wrapSignature
        )
        if status == .opens { clearFlag() }
        switch holderAction(for: status) {
        case .none:
            return
        case .signInPlace:
            // Never a key taken on trust (the SDK refuses too).
            guard !crypto.personalKeyTakenOnTrust() else { return }
            signCheckedFor = nil
            await signServerCopyIfUnsigned(userId: userId, knownBundle: bundle, evenIfSigned: true)
        case .republish:
            guard mayRepublish(lastAt: lastRepublishAt, now: now), !crypto.personalKeyTakenOnTrust() else { return }
            lastRepublishAt = now
            do {
                let copy = try crypto.publishablePersonalKey(heldUnder: selfCircleUuid, userId: userId)
                _ = try await api.storeSelfKey(
                    encryptedSelfKey: EncryptedBlobRequest(nonce: copy.encryptedKey.nonce,
                                                           ciphertext: copy.encryptedKey.ciphertext),
                    ephemeralPublicKey: copy.ephemeralPublicKey,
                    wrapSignature: copy.wrapSignature,
                    userPseudonym: copy.userPseudonym,
                    replace: true
                )
                print("[Track] SelfKeyManager: republished the personal key for the account's current keys")
            } catch {
                // InvalidInput: taken on trust here — never
                // published.
                print("[Track] SelfKeyManager: did not republish the personal key: \(error)")
            }
        }
    }

    private static var flaggedCopyKey: String? {
        AuthManager.shared.userId.map { "selfKey.flaggedCopy.\($0.lowercased())" }
    }

    /// "This device can't use the personal copy it was served": once per
    /// distinct copy, until one opens here.
    private static func flagUnreadable(_ bundle: CircleKeyBundleResponse) async {
        guard let key = flaggedCopyKey else { return }
        let digest = copyDigest(bundle)
        guard UserDefaults.standard.string(forKey: key) != digest else { return }
        do {
            let answer = try await api.reportSelfKeyUnreadable(copySha256: digest)
            if answer.copyChanged == true {
                // Stale: the stored copy is another one now. The next pass reads
                // it again; nothing is remembered for this one.
                return
            }
            UserDefaults.standard.set(digest, forKey: key)
        } catch let error as APIError where error.code == "http_404" {
            // Nothing stored: nothing to republish.
            UserDefaults.standard.set(digest, forKey: key)
        } catch {
            print("[Track] SelfKeyManager: the can't-open report did not go out (\(error)) — sent at the next pass")
        }
    }

    /// The compare-and-set repair of the recorded pseudonym: only when this
    /// device's own key OPENS the published copy (the SDK's `.opens`, or
    /// `.unsigned`: it opens to the key in use and only lacks a valid
    /// signature), with the pseudonym under exactly that key, derived directly
    /// (nothing is wrapped or signed just to read it), and never for a key
    /// taken on trust. A copy replaced meanwhile answers `key_wrap_changed`:
    /// the next pass reads it again.
    private static func repairRecordIfCopyOpensHere(_ bundle: CircleKeyBundleResponse, userId: String) async {
        let status = crypto.checkPublishedPersonalCopy(
            userId: userId,
            encryptedKey: bundle.encryptedCircleKey.nonce + bundle.encryptedCircleKey.ciphertext,
            senderPublicKey: bundle.ephemeralPublicKey,
            keyVersion: Int32(bundle.keyVersion),
            wrapSignatureHex: bundle.wrapSignature
        )
        guard status == .opens || status == .unsigned, !crypto.personalKeyTakenOnTrust(),
              let mine = (try? crypto.deriveUserPseudonym(circleId: selfCircleUuid, userId: userId))?.lowercased(),
              mine != bundle.userPseudonym?.lowercased() else { return }
        do {
            try await api.repairSelfKeyPseudonym(SelfKeyPseudonymRequest(
                keyVersion: bundle.keyVersion,
                encryptedCircleKey: EncryptedBlobRequest(nonce: bundle.encryptedCircleKey.nonce,
                                                         ciphertext: bundle.encryptedCircleKey.ciphertext),
                ephemeralPublicKey: bundle.ephemeralPublicKey,
                userPseudonym: mine))
            print("[Track] SelfKeyManager: repaired the recorded pseudonym for the published copy")
        } catch {
            print("[Track] SelfKeyManager: the record repair did not land (\(error)) — read again next pass")
        }
    }

    private static func clearFlag() {
        if let key = flaggedCopyKey { UserDefaults.standard.removeObject(forKey: key) }
    }

    /// Sign-out: the next account must be checked afresh.
    static func reset() {
        signCheckedFor = nil
        nextRetryAt = nil
        failuresInARow = 0
        lastCopyCheck = nil
        pendingAdoption = nil
        passwordDidNotRestoreSigningKey = false
    }

    /// This device holds the account's keys but not its signing key — its
    /// blob would not open at sign-in, or its Keychain item went. Nothing is
    /// unreadable, but nothing new can be signed or checked here. The
    /// password, asked for in place (re-auth on this session,
    /// `AuthManager.unlockWithPassword`), puts it back.
    static var signingKeyMissing: Bool {
        (try? crypto.exportPublicKey()) != nil && (try? crypto.signingPublicKeyHex()) == nil
    }

    /// The password was typed and the signing key still did not come back (a
    /// blob that cannot open): it is not asked for again this session.
    static var passwordDidNotRestoreSigningKey = false

    /// Pure, for tests: the state when this device's personal history works —
    /// the password is asked for, once, when the signing key is missing (or the
    /// SDK's check could not run without it), else all is well.
    nonisolated static func healthWithHistoryHere(verdict: PersonalKeyVerdict?, signingKeyMissing: Bool,
                                                  passwordTried: Bool) -> SelfKeyHealth {
        (verdict == .noSigningKey || signingKeyMissing) && !passwordTried ? .needsPassword : .ok
    }

    /// True when replacing the stored self key would lose nothing.
    ///
    /// The server answers `/latest` for the nil circle from the pseudonym it
    /// records for the account's self key, which it writes only once a device
    /// has actually sent a personal row. An empty list therefore means no
    /// device has ever recorded personal tracking under the stored key —
    /// nothing is encrypted under it and minting a replacement costs nothing.
    /// A non-empty list means some device is using it, whether or not we can
    /// read what came back.
    ///
    /// Fails CLOSED: anything we cannot check returns false, because "unknown"
    /// must never authorise overwriting live key material.
    private static func personalTrackingIsEmpty() async -> Bool {
        do {
            let latest = try await api.getLatestLocations(circleId: selfCircleUuid)
            return latest.locations.isEmpty
        } catch {
            print("[Track] SelfKeyManager: could not check personal history (\(error)) — assuming in use")
            return false
        }
    }
}
