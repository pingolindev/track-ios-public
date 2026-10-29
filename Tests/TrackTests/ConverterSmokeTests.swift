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
@testable import Track

/// Smoke tests for the Response -> Model converters in
/// App/Services/APIService+Converters.swift. These don't touch the
/// network or the SDK; they pin down the day-bucket -> Date math and
/// the optional-field defaulting behavior.
final class ConverterSmokeTests: XCTestCase {

    func testCircleResponseToModelDefaults() {
        let response = CircleResponse(
            id: "c1",
            ownerId: "u1",
            isOwner: true,
            encryptedName: EncryptedBlobResponse(nonce: "00", ciphertext: "00"),
            dayBucket: 20_000,             // 2024-10-04 in days-since-epoch
            memberCount: 3,
            keyRotationNeeded: nil,
            keyVersion: 4,
            keyRotationRequestedDayBucket: nil,
            keyRotationDeadlineDayBucket: nil,
            keyRotationOverdue: nil,
            encryptedCircleKey: nil,
            circleKeyNonce: nil,
            ephemeralPublicKey: nil,
            wrapSignature: nil,
            senderUserId: nil
        )
        let circle = response.toModel()
        XCTAssertEqual(circle.id, "c1")
        // No decrypted name → the one locked-circle placeholder, and a reason
        // (the converter knows none, so the generic one) for the UI to explain.
        XCTAssertEqual(circle.name, "Locked circle")
        XCTAssertEqual(circle.lockReason, .keyUnavailable)
        XCTAssertTrue(circle.isLocked)
        XCTAssertTrue(circle.isOwner)
        XCTAssertFalse(circle.keyRotationNeeded) // nil flag defaults to false
        XCTAssertEqual(circle.keyVersion, 4)
        // dayBucket * 86400 seconds since epoch
        XCTAssertEqual(circle.createdAt.timeIntervalSince1970, 20_000 * 86_400, accuracy: 1)
    }

    func testCircleResponseToModelWithDecryptedName() {
        let response = CircleResponse(
            id: "c1",
            ownerId: "u1",
            isOwner: false,
            encryptedName: EncryptedBlobResponse(nonce: "00", ciphertext: "00"),
            dayBucket: 0,
            memberCount: 1,
            keyRotationNeeded: true,
            keyVersion: 1,
            keyRotationRequestedDayBucket: 19_999,
            keyRotationDeadlineDayBucket: 20_010,
            keyRotationOverdue: false,
            encryptedCircleKey: "deadbeef",
            circleKeyNonce: "01",
            ephemeralPublicKey: "abcd",
            wrapSignature: nil,
            senderUserId: nil
        )
        let circle = response.toModel(name: "My Family")
        XCTAssertEqual(circle.name, "My Family")
        XCTAssertNil(circle.lockReason, "a decrypted circle is not locked")
        XCTAssertFalse(circle.isLocked)
        XCTAssertEqual(circle.encryptedKey, "deadbeef")
        XCTAssertTrue(circle.keyRotationNeeded)
    }

    func testCircleMemberResponseToModelMapsBooleans() {
        let response = CircleMemberResponse(
            userId: "u9",
            displayName: "Alex",
            encryptedDisplayName: nil,
            role: "admin",
            encryptedCircleKey: EncryptedBlobResponse(nonce: "00", ciphertext: "00"),
            ephemeralPublicKey: "xyz",
            canSeeHistory: false,
            canSeeRealtime: true,
            canRotateKeys: nil,
            status: "active",
            joinedDayBucket: 20_000,
            sharingPublicKey: nil,
            signingPublicKey: nil
        )
        let member = response.toModel(in: "circle-1")
        XCTAssertEqual(member.userId, "u9")
        XCTAssertEqual(member.role, .admin)
        // can_rotate_keys absent from the response: an ADMIN is not assumed to
        // hold it. Only ownership can be inferred, and this member is not the
        // owner, so the safe read is false and the sweep waits for a real roster.
        XCTAssertFalse(member.canRotateKeys)
        XCTAssertFalse(member.canSeeHistory)
        XCTAssertTrue(member.canSeeRealtime)
        XCTAssertEqual(member.joinedAt.timeIntervalSince1970, 20_000 * 86_400, accuracy: 1)
    }

    func testCircleMemberResponseFallsBackWhenNameNil() {
        let response = CircleMemberResponse(
            userId: "u9",
            displayName: nil,
            encryptedDisplayName: nil,
            role: "owner",
            encryptedCircleKey: EncryptedBlobResponse(nonce: "00", ciphertext: "00"),
            ephemeralPublicKey: "xyz",
            canSeeHistory: true,
            canSeeRealtime: true,
            canRotateKeys: nil,
            status: "active",
            joinedDayBucket: nil,
            sharingPublicKey: nil,
            signingPublicKey: nil
        )
        let member = response.toModel(in: "circle-1")
        XCTAssertEqual(member.displayName, "Member") // converter sentinel
        XCTAssertEqual(member.role, .owner)
        // can_rotate_keys absent, but role owner: owners always hold the bit
        // server-side, so this is the one case the converter can infer.
        XCTAssertTrue(member.canRotateKeys)
        // joinedDayBucket nil -> Date() (now); just check it's not absurdly old.
        XCTAssertGreaterThan(
            member.joinedAt.timeIntervalSince1970,
            Date().timeIntervalSince1970 - 5
        )
    }

    func testUnknownRoleFallsBackToMember() {
        let response = CircleMemberResponse(
            userId: "u9",
            displayName: "Alex",
            encryptedDisplayName: nil,
            role: "intern", // not in the enum
            encryptedCircleKey: EncryptedBlobResponse(nonce: "00", ciphertext: "00"),
            ephemeralPublicKey: "xyz",
            canSeeHistory: true,
            canSeeRealtime: true,
            canRotateKeys: nil,
            status: "active",
            joinedDayBucket: 0,
            sharingPublicKey: nil,
            signingPublicKey: nil
        )
        XCTAssertEqual(response.toModel(in: "circle-1").role, .member)
    }
}
