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

/// Smoke tests for the SDK SRP-6a helpers AuthManager uses. These run
/// entirely against the bundled mobile-sdk static lib — no network — so
/// they catch breakage in the binding glue without needing a backend.
final class SRPSmokeTests: XCTestCase {

    func testRegistrationProducesAllThreeFields() throws {
        let data = try srpGenerateRegistration(
            email: "smoke@example.test",
            password: "hunter2-correct-horse-battery-staple"
        )
        XCTAssertFalse(data.salt.isEmpty)
        XCTAssertFalse(data.verifier.isEmpty)
        // bcryptSalt should be a $2<variant>$<cost>$<22-char salt> MCF prefix.
        XCTAssertTrue(data.bcryptSalt.hasPrefix("$2"))
        XCTAssertGreaterThanOrEqual(data.bcryptSalt.count, 29)
    }

    func testWrongBcryptSaltIsRejectedNotCrashed() {
        // Passing a malformed bcrypt salt should surface a typed error,
        // not a fatalError or hang (the SDK's salt parser).
        XCTAssertThrowsError(
            try srpComputeLoginProof(
                email: "smoke@example.test",
                password: "doesntmatter",
                saltB64: "AAAA", // 3 padded base64 = 2 bytes; valid b64 but tiny salt
                bcryptSalt: "not-a-bcrypt-mcf-string",
                serverPublicB64: Self.dummyServerPublicB64
            )
        )
    }

    /// 256-byte zero buffer base64-encoded — not a real server pubkey but
    /// the SDK only validates the *length* shape during compute_proof,
    /// not value-level math, before throwing if math fails. For the
    /// "didn't crash" tests above we just need something parseable.
    private static let dummyServerPublicB64: String = {
        Data(repeating: 0, count: 256).base64EncodedString()
    }()
}
