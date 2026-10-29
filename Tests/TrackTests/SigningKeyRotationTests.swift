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

/// The account's signing key is never replaced here. A legacy shape (the
/// sharing private key used as the signing seed) is recognised from the keys
/// just opened — never from the server's unauthenticated
/// `signing_public_key` — and only logged and counted.
final class SigningKeyRotationTests: XCTestCase {

    private func bytes(_ b64: String) -> Data { Data(base64Encoded: b64)! }

    private func hex(_ b64: String) -> String {
        bytes(b64).map { String(format: "%02x", $0) }.joined()
    }

    /// A genuine account: its own signing seed and its own sharing key.
    private func genuineAccount() throws -> (seed: Data, sharing: Data, derivedHex: String) {
        let crypto = CryptoManager()
        let sharing = crypto.generateKeypair()
        let signing = crypto.generateSigningKeypair()
        return (bytes(signing.secretSeedB64), bytes(sharing.privateKey), try crypto.signingPublicKeyHex())
    }

    func testTheServersMismatchNeverRotates() throws {
        let account = try genuineAccount()
        let someoneElse = hex(CryptoManager().generateSigningKeypair().verifyingKeyB64)
        XCTAssertEqual(AuthManager.signingKeyVerdict(signingPrivateKey: account.seed,
                                                     sharingPrivateKey: account.sharing,
                                                     derivedVerifyingKeyHex: account.derivedHex,
                                                     serverVerifyingKeyHex: someoneElse),
                       .serverDisagrees)
    }

    func testAKeyTheServerAgreesWithIsLeftAlone() throws {
        let account = try genuineAccount()
        for server in [account.derivedHex, account.derivedHex.uppercased(), nil] {
            XCTAssertEqual(AuthManager.signingKeyVerdict(signingPrivateKey: account.seed,
                                                         sharingPrivateKey: account.sharing,
                                                         derivedVerifyingKeyHex: account.derivedHex,
                                                         serverVerifyingKeyHex: server),
                           .matches)
        }
    }

    /// The legacy seed is recognised whatever the server says (and is then
    /// only logged and counted); a genuine key is never taken for it.
    func testTheLegacySeedIsRecognisedWhateverTheServerSays() throws {
        let crypto = CryptoManager()
        let sharing = crypto.generateKeypair()
        try crypto.importSigningPrivateKey(secretSeedB64: sharing.privateKey)
        let legacyHex = try crypto.signingPublicKeyHex()
        let elsewhere = hex(CryptoManager().generateSigningKeypair().verifyingKeyB64)
        for server in [legacyHex, elsewhere, nil] {
            XCTAssertEqual(AuthManager.signingKeyVerdict(signingPrivateKey: bytes(sharing.privateKey),
                                                         sharingPrivateKey: bytes(sharing.privateKey),
                                                         derivedVerifyingKeyHex: legacyHex,
                                                         serverVerifyingKeyHex: server),
                           .legacy)
        }

        let fresh = crypto.generateSigningKeypairDetached()
        try crypto.importSigningPrivateKey(secretSeedB64: fresh.secretSeedB64)
        XCTAssertEqual(AuthManager.signingKeyVerdict(signingPrivateKey: bytes(fresh.secretSeedB64),
                                                     sharingPrivateKey: bytes(sharing.privateKey),
                                                     derivedVerifyingKeyHex: try crypto.signingPublicKeyHex(),
                                                     serverVerifyingKeyHex: hex(fresh.verifyingKeyB64)),
                       .matches)
    }

    /// libsodium's 64-byte secret key (seed‖verifying key) is judged by its seed.
    func testTheSeedOfALongKeyIsWhatIsCompared() throws {
        let account = try genuineAccount()
        let long = account.sharing + Data(repeating: 7, count: 32)
        XCTAssertEqual(AuthManager.signingKeyVerdict(signingPrivateKey: long,
                                                     sharingPrivateKey: account.sharing,
                                                     derivedVerifyingKeyHex: account.derivedHex,
                                                     serverVerifyingKeyHex: account.derivedHex),
                       .legacy)
        let genuineLong = account.seed + Data(repeating: 7, count: 32)
        XCTAssertEqual(AuthManager.signingKeyVerdict(signingPrivateKey: genuineLong,
                                                     sharingPrivateKey: account.sharing,
                                                     derivedVerifyingKeyHex: account.derivedHex,
                                                     serverVerifyingKeyHex: account.derivedHex),
                       .matches)
        XCTAssertNotEqual(AuthManager.signingKeyVerdict(signingPrivateKey: Data(),
                                                        sharingPrivateKey: Data(),
                                                        derivedVerifyingKeyHex: nil,
                                                        serverVerifyingKeyHex: nil),
                          .legacy, "nothing opened is not a legacy key")
    }

    func testTheComparisonNeedsTheSameBytes() {
        XCTAssertTrue(AuthManager.constantTimeEqual(Data([1, 2, 3]), Data([1, 2, 3])))
        XCTAssertFalse(AuthManager.constantTimeEqual(Data([1, 2, 3]), Data([1, 2, 4])))
        XCTAssertFalse(AuthManager.constantTimeEqual(Data([1, 2, 3]), Data([1, 2])))
    }

    /// Nothing rotates the signing key: no regenerate call exists anywhere in
    /// the app, the legacy verdict only logs and counts, a key the server's
    /// record disagrees with is kept, and no blob means nothing is minted.
    func testNothingRotatesTheSigningKey() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let appDir = root.appendingPathComponent("App")
        let files = FileManager.default.enumerator(at: appDir, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for never in ["regenerateSigningKey", "signing-key/regenerate", "generateSigningKeypairDetached",
                          "generateSigningKeypair()"] {
                XCTAssertFalse(text.contains(never), "\(file.lastPathComponent): \(never)")
            }
        }
        let auth = try String(contentsOf: appDir.appendingPathComponent("Managers/AuthManager.swift"), encoding: .utf8)
        let legacy = try XCTUnwrap(auth.range(of: "case .legacy:"))
        let branch = auth[legacy.upperBound...].prefix(400)
        XCTAssertTrue(branch.contains("Self.countLegacySigningKey(userId: userId)"))
        XCTAssertTrue(branch.contains("it is kept, never replaced here"))
        let disagrees = try XCTUnwrap(auth.range(of: "case .serverDisagrees:"))
        XCTAssertTrue(auth[disagrees.upperBound..<legacy.lowerBound].contains("return"),
                      "a key the server's record disagrees with is kept")
        XCTAssertTrue(auth.contains("if let signingBlob = keys.signingPrivateKey {"),
                      "no signing blob, nothing imported and nothing minted")
    }

    /// The legacy shape is counted per account, one more each time it is seen.
    func testTheLegacyShapeIsCounted() throws {
        let suite = "SigningKeyRotationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(AuthManager.countLegacySigningKey(userId: "A", defaults: defaults), 1)
        XCTAssertEqual(AuthManager.countLegacySigningKey(userId: "a", defaults: defaults), 2)
        XCTAssertEqual(AuthManager.countLegacySigningKey(userId: "b", defaults: defaults), 1)
    }
}
