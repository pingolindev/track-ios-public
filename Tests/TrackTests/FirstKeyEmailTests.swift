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

/// The account email the confirmation pass checks an own invitation to an email
/// against, and what happens without one.
///
/// A headless relaunch never reads /auth/me, and a launch reads it only once the
/// network answers. Taking the email from /auth/me alone, the pass would have
/// none there: an own invitation to an email would name nobody, the device
/// would anchor on nobody, and its first key for the circle would be taken on
/// trust from whoever was listed. So the pass falls back on the email the app
/// last mirrored for this same account (what the notification extension decides
/// with). With none at all, or another address than the invitation names, the
/// device is receive-only and its first key waits (`MembershipConfirmationTests
/// .testAnEmailInvitationNoEmailCanCheck…`, `…ToAnotherAddress…`).
@MainActor
final class FirstKeyEmailTests: XCTestCase {

    private let me = "4c8a8a8e-5b3c-4d0a-9a1e-6f2b7c9d0e11"
    private let other = "9d0e4c8a-8a8e-5b3c-4d0a-9a1e6f2b7c11"

    private func user(_ id: String, _ email: String) -> User {
        User(id: id, email: email, displayName: nil, publicKey: nil, createdAt: Date(), updatedAt: nil)
    }

    private func email(served: User? = nil, bridged: String? = nil, bridgedEmail: String? = "mirrored@example.com",
                       userId: String? = nil) -> String? {
        CircleManager.ownEmail(userId: userId ?? me, served: served, bridgedUserId: bridged, bridgedEmail: bridgedEmail)
    }

    /// /auth/me's when read in this process; else the mirror, when it is this
    /// same account's, however its id is spelt; else none.
    func testTheEmailIsTheOneReadOrTheOneMirroredForThisAccount() {
        XCTAssertEqual(email(served: user(me, "read@example.com"), bridged: me), "read@example.com", "/auth/me's first")
        XCTAssertEqual(email(bridged: me), "mirrored@example.com", "not read in this process: the mirror")
        XCTAssertEqual(email(bridged: me.uppercased()), "mirrored@example.com", "this account, spelt otherwise")
        XCTAssertEqual(email(bridged: "{\(me)}"), "mirrored@example.com")
        XCTAssertNil(email(), "nothing mirrored")
        XCTAssertNil(email(bridged: me, bridgedEmail: nil))
    }

    /// Never another account's, and a non-UUID is nobody's, even an equal one.
    func testNeverAnotherAccountsEmail() {
        XCTAssertNil(email(bridged: other), "another account's mirror")
        XCTAssertEqual(email(served: user(other, "theirs@example.com"), bridged: me), "mirrored@example.com",
                       "read for another account: this one's mirror")
        XCTAssertNil(email(served: user(other, "theirs@example.com")))
        XCTAssertNil(email(bridged: "uitest-user", userId: "uitest-user"))
        XCTAssertNil(email(bridged: me, userId: "uitest-user"))
        XCTAssertNil(email(served: user("uitest-user", "uitest@example.test"), userId: "uitest-user"),
                     "a synthetic session's id is nobody")
    }

    // MARK: - Wiring (source)

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func body(_ text: String, from start: String, to end: String) throws -> String {
        let from = try XCTUnwrap(text.range(of: start), start)
        let to = try XCTUnwrap(text.range(of: end, range: from.upperBound..<text.endIndex), end)
        return String(text[from.lowerBound..<to.lowerBound])
    }

    /// The pass gets the email in one place, from both sources, and the mirror
    /// is read as the extension reads it.
    func testThePassAsksForTheEmailInOnePlace() throws {
        let circles = try source("App/Managers/CircleManager.swift")
        let own = try body(circles, from: "    func ownIdentity(userId: String) -> MembershipConfirmation.Me {",
                           to: "    /// This account's email for the confirmation pass:")
        XCTAssertTrue(own.contains("""
                    .own(userId: userId,
                         email: Self.ownEmail(userId: userId, served: AuthManager.shared.currentUser,
                                              bridgedUserId: ExtensionBridge.accountUserId,
                                              bridgedEmail: ExtensionBridge.accountEmail),
                         crypto: cryptoManager)
            """))
        XCTAssertFalse(own.contains("currentUser?.email"), "never /auth/me's alone")
        let bridge = try source("App/Notifications/ExtensionBridge.swift")
        XCTAssertTrue(bridge.contains("""
                static var accountUserId: String? {
                    UserDefaults(suiteName: suite)?.string(forKey: ExtensionBridgeKeys.accountUserId)
                }

                static var accountEmail: String? {
                    UserDefaults(suiteName: suite)?.string(forKey: ExtensionBridgeKeys.accountEmail)
                }
            """))
    }

    /// A first key that waits is stored nowhere and taken by no other door: not
    /// by the older versions' import, not into the keychain mirror, not signed;
    /// and it asks for nothing (`rejectedCircleIds` would: `.keyNotVerified`).
    func testAWaitingFirstKeyIsKeptOutOfEverything() throws {
        let circles = try source("App/Managers/CircleManager.swift")
        let branch = try body(circles, from: "                if firstKey == .wait {\n",
                              to: "                } else if firstKey == .refuse")
        XCTAssertTrue(branch.contains("                    firstKeyRefused.insert(response.id)\n"), "no older version")
        XCTAssertTrue(branch.contains("                    firstKeyWaiting.insert(response.id)\n"))
        XCTAssertFalse(branch.contains("rejectedCircleIds.insert"), "that asks for a copy")
        XCTAssertFalse(branch.contains("firstKeyAnchors"), "nobody anchors it")
        XCTAssertEqual(circles.components(separatedBy: "where !firstKeyRefused.contains(keyResp.circleId)").count - 1, 2,
                       "the older versions' import, both loops")
        XCTAssertTrue(circles.contains(
            "            if rejectedCircleIds.contains(response.id) || firstKeyWaiting.contains(response.id) { continue }\n"),
                      "no keychain mirror")
        XCTAssertTrue(circles.contains(
            "skipping: rejectedCircleIds.union(unopenedWrapCircleIds).union(firstKeyWaiting))"), "no signing")
    }

    /// By itself a waiting circle says nothing more specific, which asks for no
    /// copy (a circle refused on an earlier pass keeps that reason, and asks).
    func testAWaitingCircleAsksForNoCopyOfItsOwn() {
        let reason = CircleManager.lockReason(
            deviceHasAccountKeys: true, hasWrapForUs: true, wrapRefused: false, wrapFailedToOpen: false,
            holdsSomeKey: false, accountHasPreResetData: nil, previousReason: nil)
        XCTAssertEqual(reason, .keyUnavailable)
        XCTAssertFalse(CircleManager.asksForAFreshCopy(reason))
    }
}
