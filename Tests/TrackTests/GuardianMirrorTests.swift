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

/// The map's standing guardian line before this process's /auth/me answers.
///
/// A launch has /auth/me's answer (`currentUser`) only once the network
/// answers, and with Always location the headless resume is already sharing by
/// then: read from /auth/me alone, a guardian-managed account would share with
/// no line. So /auth/me's answer is mirrored with the account (`ExtensionBridge
/// .syncAccount`: its id, its email, its guardian), and the line shows from the
/// mirror until /auth/me answers, for this same account only.
@MainActor
final class GuardianMirrorTests: XCTestCase {

    private let me = "4c8a8a8e-5b3c-4d0a-9a1e-6f2b7c9d0e11"
    private let other = "9d0e4c8a-8a8e-5b3c-4d0a-9a1e6f2b7c11"

    private func user(managed: Bool?, handover: String? = nil) -> User {
        var user = User(id: me, email: "young@example.com", displayName: nil, publicKey: nil,
                        createdAt: Date(), updatedAt: nil)
        user.guardianManaged = managed
        user.guardianHandoverDate = handover
        return user
    }

    private func mirror(_ userId: String?, managed: Bool, handover: String? = nil) -> ExtensionBridge.MirroredGuardian {
        ExtensionBridge.MirroredGuardian(userId: userId, managed: managed, handoverDate: handover)
    }

    private func guardian(served: User? = nil, userId: String? = nil,
                          mirrored: ExtensionBridge.MirroredGuardian) -> AuthManager.GuardianStatus {
        AuthManager.guardian(served: served, userId: userId ?? me, mirrored: mirrored)
    }

    // MARK: - The reader

    /// /auth/me's answer, whenever this process has one, whatever the mirror.
    func testTheAnswerReadWins() {
        XCTAssertEqual(guardian(served: user(managed: true, handover: "2031-05-01"), mirrored: mirror(me, managed: false)),
                       AuthManager.GuardianStatus(managed: true, handoverDate: "2031-05-01"))
        XCTAssertEqual(guardian(served: user(managed: false), mirrored: mirror(me, managed: true, handover: "2031-05-01")),
                       .notManaged, "a guardian revoked since: the line goes")
        XCTAssertEqual(guardian(served: user(managed: nil), mirrored: mirror(me, managed: true)), .notManaged,
                       "an answer without the field shows nothing")
    }

    /// Before /auth/me answers: the mirror, when it is this account's,
    /// however its id is spelt.
    func testBeforeTheAnswerTheMirrorForThisAccount() {
        let mirrored = AuthManager.GuardianStatus(managed: true, handoverDate: "2031-05-01")
        XCTAssertEqual(guardian(mirrored: mirror(me, managed: true, handover: "2031-05-01")), mirrored)
        XCTAssertEqual(guardian(mirrored: mirror(me.uppercased(), managed: true, handover: "2031-05-01")), mirrored)
        XCTAssertEqual(guardian(mirrored: mirror("{\(me)}", managed: true, handover: "2031-05-01")), mirrored)
        XCTAssertEqual(guardian(mirrored: mirror(me, managed: false)), .notManaged)
    }

    /// Never another account's mirror, nor one whose id is no UUID.
    func testNeverAnotherAccountsMirror() {
        XCTAssertEqual(guardian(mirrored: mirror(other, managed: true)), .notManaged)
        XCTAssertEqual(guardian(mirrored: mirror(nil, managed: true)), .notManaged, "nothing mirrored")
        XCTAssertEqual(guardian(userId: "uitest-user", mirrored: mirror("uitest-user", managed: true)), .notManaged)
        XCTAssertEqual(AuthManager.guardian(served: nil, userId: nil, mirrored: mirror(me, managed: true)), .notManaged,
                       "signed out")
    }

    // MARK: - The mirror

    private func scratchDefaults() throws -> (UserDefaults, String) {
        let name = "guardian-mirror-tests-\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: name)), name)
    }

    /// Written with the account, cleared with it; a handover day the answer
    /// no longer carries is removed.
    func testTheGuardianIsMirroredAndClearedWithTheAccount() throws {
        let (defaults, name) = try scratchDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        ExtensionBridge.syncAccount(userId: me, email: "young@example.com", guardianManaged: true,
                                    guardianHandoverDate: "2031-05-01", defaults: defaults)
        XCTAssertEqual(ExtensionBridge.mirroredGuardian(defaults: defaults),
                       mirror(me, managed: true, handover: "2031-05-01"))
        XCTAssertEqual(defaults.string(forKey: ExtensionBridgeKeys.accountEmail), "young@example.com")

        ExtensionBridge.syncAccount(userId: me, email: "young@example.com", guardianManaged: true,
                                    guardianHandoverDate: nil, defaults: defaults)
        XCTAssertNil(defaults.object(forKey: ExtensionBridgeKeys.accountGuardianHandoverDate), "no day named now")
        XCTAssertEqual(ExtensionBridge.mirroredGuardian(defaults: defaults), mirror(me, managed: true))

        ExtensionBridge.syncAccount(userId: nil, email: nil, defaults: defaults)
        for key in [ExtensionBridgeKeys.accountUserId, ExtensionBridgeKeys.accountEmail,
                    ExtensionBridgeKeys.accountGuardianManaged, ExtensionBridgeKeys.accountGuardianHandoverDate] {
            XCTAssertNil(defaults.object(forKey: key), "signed out: \(key)")
        }
        XCTAssertEqual(ExtensionBridge.mirroredGuardian(defaults: defaults), mirror(nil, managed: false))
    }

    /// What an older build mirrored (the id and the email, no guardian) reads
    /// as not managed, with no handover day: the line waits for /auth/me.
    func testAnOlderBuildsMirrorReadsAsNotManaged() throws {
        let (defaults, name) = try scratchDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(me, forKey: ExtensionBridgeKeys.accountUserId)
        defaults.set("young@example.com", forKey: ExtensionBridgeKeys.accountEmail)
        let mirrored = ExtensionBridge.mirroredGuardian(defaults: defaults)
        XCTAssertEqual(mirrored, mirror(me, managed: false))
        XCTAssertEqual(AuthManager.guardian(served: nil, userId: me, mirrored: mirrored), .notManaged)
    }

    // MARK: - Wiring (source)

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// Every /auth/me answer the app holds is mirrored with its guardian, and the
    /// map reads the line and its handover through the one reader.
    func testTheAnswerIsMirroredAndTheMapReadsTheReader() throws {
        let auth = try source("App/Managers/AuthManager.swift")
        XCTAssertTrue(auth.contains("""
                    didSet {
                        ExtensionBridge.syncAccount(userId: currentUser.flatMap { CanonicalId.of($0.id) }, email: currentUser?.email,
                                                    guardianManaged: currentUser?.guardianManaged == true,
                                                    guardianHandoverDate: currentUser?.guardianHandoverDate)
                    }
            """))
        XCTAssertTrue(auth.contains(
            "        Self.guardian(served: currentUser, userId: userId, mirrored: ExtensionBridge.mirroredGuardian())\n"))
        let map = try source("App/Views/Map/MapView.swift")
        XCTAssertTrue(map.contains("            if authManager.guardian.managed {\n"))
        XCTAssertTrue(map.contains("        guard let named = authManager.guardian.handoverDate,\n"))
        XCTAssertFalse(map.contains("currentUser?.guardian"), "never /auth/me's alone")
    }

    /// Another account's id goes before its fields are written, and the id is
    /// written last: a process stopped in between pairs no id with another
    /// account's fields.
    func testTheIdIsWrittenLastAndAnotherAccountsFirstRemoved() throws {
        let bridge = try source("App/Notifications/ExtensionBridge.swift")
        let start = try XCTUnwrap(bridge.range(of: "        if let userId, let email {\n"))
        let rest = bridge[start.upperBound...]
        let removeOther = try XCTUnwrap(rest.range(of: """
                        if defaults.string(forKey: ExtensionBridgeKeys.accountUserId) != userId {
                            defaults.removeObject(forKey: ExtensionBridgeKeys.accountUserId)
                        }
            """))
        let fields = try XCTUnwrap(rest.range(of: "            defaults.set(email, forKey: ExtensionBridgeKeys.accountEmail)\n"))
        let id = try XCTUnwrap(rest.range(of: "            defaults.set(userId, forKey: ExtensionBridgeKeys.accountUserId)\n"))
        XCTAssertLessThan(removeOther.upperBound, fields.lowerBound)
        XCTAssertLessThan(fields.upperBound, id.lowerBound)
    }
}
