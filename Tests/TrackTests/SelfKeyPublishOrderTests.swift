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

import XCTest
import PingolinTrackSDK
@testable import Track

/// The order in which a freshly minted self key is published and installed.
///
/// # Why an ordering has its own test file
///
/// `POST /users/me/self-key` upserts, so a client that mints over a stored key
/// makes every personal location the account ever wrote undecryptable. The
/// server can refuse such a publish with `key_self_key_in_use`, and that
/// refusal only helps if the client has not committed the key before asking.
///
/// `finalizeCircleCreation` calls `persist_keys()` in the SDK, so the key
/// reaches secure storage and `loadPersistedKeys` restores it on every launch
/// after. `SelfKeyManager.ensure()` opens with
///
///     if crypto.hasCircleKey(circleId: selfCircleUuid) { return true }
///
/// so once that persist has happened a refusal can never be retried — not on
/// this launch, not on any future one. The account would then write personal
/// locations sealed under a key the server does not hold and no other device
/// can obtain. Silent, permanent, and strictly worse than the overwrite the
/// refusal exists to prevent.
///
/// So the assertion that bites is not "an error was thrown". It is what the
/// device is left holding afterwards.
final class SelfKeyPublishOrderTests: XCTestCase {

    // MARK: - Test doubles

    /// What actually happened, in order. A class rather than captured `var`s so
    /// the non-escaping closures can record across the `await` without any
    /// question about concurrent access.
    private final class Journal {
        enum Step: Equatable { case prepared, published, installed }
        private(set) var steps: [Step] = []
        func record(_ step: Step) { steps.append(step) }
        var installed: Bool { steps.contains(.installed) }
        var published: Bool { steps.contains(.published) }
    }

    /// Stand-in for the SDK's persisted circle-key map — the thing
    /// `finalizeCircleCreation` writes to and `hasCircleKey` reads back.
    private final class KeyStore {
        private var ids: Set<String> = []
        func install(_ id: String) { ids.insert(id) }
        func holds(_ id: String) -> Bool { ids.contains(id) }
    }

    private func sampleCreation() -> CircleCreationData {
        CircleCreationData(
            encryptedCircleKey: EncryptedData(nonce: "0011", ciphertext: "cafebabe"),
            ephemeralPublicKey: "f00d",
            tempCircleId: "temp_0011223344556677"
        )
    }

    /// The refusal exactly as it arrives: a 409 whose body is
    /// `{"success":false,"error":"<prose>","error_code":"key_self_key_in_use"}`.
    /// Because `error` is a bare string, `APIResponse`'s decoder puts the
    /// envelope's code into BOTH `code` and `errorCode`, and `execute` throws
    /// that value through untouched — its `"server_error"` relabelling only
    /// fires when the server supplied no code of its own.
    private func refusal() -> APIError {
        APIError(
            code: "key_self_key_in_use",
            message: "A self key is already stored for this account and data exists under it.",
            errorCode: "key_self_key_in_use"
        )
    }

    // MARK: - The invariant

    /// A refused publish must leave NOTHING under the self circle id.
    ///
    /// This is the assertion an install-first ordering fails: by the time the
    /// 409 comes back the key is already in secure storage.
    @MainActor
    func testARefusedPublishInstallsNothingLocally() async {
        let journal = Journal()
        let creation = sampleCreation()

        let health = await SelfKeyManager.mintAndPublish(
            prepare: { journal.record(.prepared); return creation },
            publish: { _ in journal.record(.published); throw self.refusal() },
            install: { _ in journal.record(.installed) }
        )

        XCTAssertEqual(health, .replacementRefused)
        XCTAssertFalse(
            journal.installed,
            "a refused key must not reach secure storage — finalizeCircleCreation persists, "
            + "and a persisted key makes ensure()'s hasCircleKey short-circuit pass forever"
        )
    }

    /// The invariant stated the way it is actually experienced: a LATER launch
    /// has to be able to try again.
    ///
    /// Models `ensure()`'s opening short-circuit over a stand-in key store, and
    /// runs the flow twice. With an install-first ordering the first attempt
    /// would persist the refused key, so the second launch would report a
    /// perfectly healthy `.ok` against a key the server rejected — which is the
    /// silent failure, not a recovery.
    @MainActor
    func testASecondLaunchStillTriesAfterARefusal() async {
        let keyStore = KeyStore()
        let creation = sampleCreation()
        let selfCircle = SelfKeyManager.selfCircleUuid

        @MainActor
        func launch() async -> SelfKeyHealth {
            // `ensure()`'s first line, verbatim in effect.
            if keyStore.holds(selfCircle) { return .ok }
            return await SelfKeyManager.mintAndPublish(
                prepare: { creation },
                publish: { _ in throw self.refusal() },
                install: { _ in keyStore.install(selfCircle) }
            )
        }

        let first = await launch()
        XCTAssertEqual(first, .replacementRefused)

        let second = await launch()
        XCTAssertEqual(
            second, .replacementRefused,
            "the second launch must re-attempt and land on the refusal again — reporting .ok "
            + "here means the device short-circuited on a key the server refused, and every "
            + "personal location from now on is sealed under something nobody else can read"
        )
    }

    /// The order, asserted directly, so a later edit cannot install first while
    /// still passing the two tests above by some other route.
    @MainActor
    func testTheKeyIsPublishedBeforeItIsInstalled() async {
        let journal = Journal()
        let creation = sampleCreation()

        let health = await SelfKeyManager.mintAndPublish(
            prepare: { journal.record(.prepared); return creation },
            publish: { _ in journal.record(.published) },
            install: { _ in journal.record(.installed) }
        )

        XCTAssertEqual(health, .ok)
        XCTAssertEqual(
            journal.steps, [.prepared, .published, .installed],
            "publish must precede install; prepare_circle_creation files the key under a temp id "
            + "and does not persist, so this order is what leaves a refusal recoverable"
        )
    }

    /// The happy path still installs. Without this, "never install anything"
    /// passes every other test in this file and ships an app with no personal
    /// tracking at all.
    @MainActor
    func testAnAcceptedPublishInstallsTheKey() async {
        let journal = Journal()
        let creation = sampleCreation()

        let health = await SelfKeyManager.mintAndPublish(
            prepare: { creation },
            publish: { _ in journal.record(.published) },
            install: { _ in journal.record(.installed) }
        )

        XCTAssertEqual(health, .ok)
        XCTAssertTrue(journal.installed, "an accepted key must be usable on this device")
    }

    /// A publish that fails for an ordinary reason gets the same treatment, and
    /// on purpose: a key held locally that the server never received is the same
    /// divergence reached by a different road. Installing the key anyway would
    /// create that divergence.
    @MainActor
    func testAGenericPublishFailureAlsoInstallsNothing() async {
        let journal = Journal()
        let creation = sampleCreation()

        let health = await SelfKeyManager.mintAndPublish(
            prepare: { creation },
            publish: { _ in throw APIError(code: "http_503", message: "Request failed") },
            install: { _ in journal.record(.installed) }
        )

        XCTAssertEqual(health, .publishFailed, "not a refusal — nothing is known to be stored; tried again by itself")
        XCTAssertFalse(
            journal.installed,
            "a key the server never acknowledged must not become this device's permanent answer"
        )
    }

    /// A mint that cannot even be generated is the third outcome and must not be
    /// mistaken for a refusal — there is no stored key to go and fetch.
    @MainActor
    func testAFailureToMintIsNotARefusal() async {
        let journal = Journal()
        struct NoKeypair: Error {}

        let health = await SelfKeyManager.mintAndPublish(
            prepare: { throw NoKeypair() },
            publish: { _ in journal.record(.published) },
            install: { _ in journal.record(.installed) }
        )

        XCTAssertEqual(health, .publishFailed)
        XCTAssertFalse(journal.published, "nothing to publish")
        XCTAssertFalse(journal.installed)
    }

    // MARK: - Recognising the refusal

    /// The refusal has to be told apart from every other 409 and 4xx, because
    /// it is the only one carrying a fact the user can act on: the real key
    /// still exists and another device can re-publish it.
    func testTheRefusalIsRecognisedFromTheWireCode() {
        XCTAssertTrue(refusal().isSelfKeyInUse)
    }

    /// Both envelope shapes. The bare-string body the track API actually sends
    /// puts the code in `code` and `errorCode` alike; a structured
    /// `{code, message}` body would set only `errorCode`. Matching one field
    /// only would work in a test and fail on a device, or the reverse.
    func testTheRefusalIsRecognisedFromEitherEnvelopeShape() {
        XCTAssertTrue(
            APIError(code: "server_error", message: "x", errorCode: "key_self_key_in_use")
                .isSelfKeyInUse,
            "structured body: the code rides errorCode"
        )
        XCTAssertTrue(
            APIError(code: "key_self_key_in_use", message: "x").isSelfKeyInUse,
            "bare-string body: APIResponse lifts error_code into code"
        )
    }

    /// And nothing else is. A predicate that said yes to ordinary failures
    /// would report "another device holds your key" to users whose key is
    /// merely unreachable.
    func testOrdinaryFailuresAreNotRefusals() {
        XCTAssertFalse(APIError(code: "http_409", message: "Conflict").isSelfKeyInUse)
        XCTAssertFalse(APIError(code: "network_error", message: "Invalid response").isSelfKeyInUse)
        XCTAssertFalse(
            APIError(code: "server_error", message: "x", errorCode: "key_membership_changed")
                .isSelfKeyInUse,
            "a neighbouring key_ code must not match"
        )
    }
}
