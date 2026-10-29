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

/// This account's heads: after this device accepts a circle's records, it
/// publishes the head it accepted, signed by the account's CURRENT signing
/// key, so a later fresh install of the account can take the chain up to it
/// by the account's word.
///
/// Published when the server serves none of this account's own for the circle,
/// or one that doesn't verify under the current key, or one older than the head
/// just accepted. So after a password reset, the first import under the new key
/// publishes every head again at once (the server takes the same head
/// re-signed), and after that only when the head moves. Ed25519 is
/// deterministic: the account's devices write the same signature and never churn.
///
/// Only the app publishes, never the notification extension.
@MainActor
enum AccountHeads {
    /// Pure, for tests: whether this account's head must be published again,
    /// given the head this device accepted (`refreshHeadVersions`, 0: none yet)
    /// and this account's own served head as it verified under the current key
    /// (nil: none served, or it doesn't verify).
    nonisolated static func mustPublish(accepted: Int32, own: CircleHead?) -> Bool {
        guard accepted > 0 else { return false }
        guard let own else { return true }
        return own.version < accepted
    }

    /// This account's own head among a circle's served ones, verified under
    /// the account's current signing key and bound to this circle and account;
    /// nil otherwise (a head signed before a reset doesn't verify).
    static func ownHead(circleId: String, me: String, served: [ServedCircleHead],
                        crypto: PingolinTrackSDK.CryptoManager) -> CircleHead? {
        guard let key = try? crypto.signingPublicKeyHex(),
              let mine = served.first(where: { $0.userId.caseInsensitiveCompare(me) == .orderedSame }),
              let head = try? crypto.verifyCircleHead(headHex: mine.head, signatureHex: mine.signature,
                                                      signerSigningPublicKeyHex: key),
              head.circleId.caseInsensitiveCompare(circleId) == .orderedSame,
              head.userId.caseInsensitiveCompare(me) == .orderedSame else { return nil }
        return head
    }

    /// After an import of a circle's records: publish this account's head for
    /// it when `mustPublish` says so, at most once (which head it keeps is the
    /// server's rule alone). The head is the SDK's, in format 2. A failure
    /// waits for the next import. `put` is the PUT (tests pass their own).
    static func publishIfNeeded(circleId: String, me: String, served: [ServedCircleHead],
                                crypto: PingolinTrackSDK.CryptoManager = SDKCrypto.cryptoManager,
                                put: ((_ circleId: String, _ head: String, _ signature: String) async throws -> Void)? = nil) async {
        let accepted = crypto.refreshHeadVersions()
            .first { $0.key.caseInsensitiveCompare(circleId) == .orderedSame }?.value ?? 0
        guard mustPublish(accepted: accepted, own: ownHead(circleId: circleId, me: me, served: served, crypto: crypto))
        else { return }
        do {
            let head = try crypto.signCircleHead(circleId: circleId, userId: me)
            if let put {
                try await put(circleId, head.headHex, head.signatureHex)
            } else {
                _ = try await APIService.shared.putCircleHead(circleId: circleId, head: head.headHex,
                                                              signature: head.signatureHex)
            }
        } catch let error as MobileError where headNotYet(error) {
            // Not now, and nothing is wrong: the SDK asks for that record
            // again (head − 1), and the import that serves it publishes.
            PendingChangeRunner.log.info("circle \(circleId, privacy: .public): the head waits for its record to be served again")
        } catch {
            PendingChangeRunner.log.error("circle \(circleId, privacy: .public): head not published: \(String(describing: error), privacy: .public)")
        }
    }

    /// Pure, for tests: `signCircleHead` can't sign yet: the record at the head
    /// isn't known here in full (e.g. a store an older SDK wrote), or anything
    /// else that means "import this circle's records first", the one "not yet"
    /// of both SDK calls (`RecordedRotation.notYet`). Any other refusal is a
    /// failure.
    nonisolated static func headNotYet(_ error: MobileError) -> Bool {
        RecordedRotation.notYet(error)
    }
}
