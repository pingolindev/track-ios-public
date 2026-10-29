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

/// The launch check reads the stored session from the Keychain, with the
/// same split as the Note iOS app: only "nothing stored" is signed out. A
/// Keychain that can't be read yet, as before the first unlock after a
/// restart when a location event launches the app in the background, is no
/// answer: never shown as signed out, and checked again once it can be read.
final class SessionAtLaunchTests: XCTestCase {
    private let token = KeychainService.Read.value(Data("token".utf8))
    private let account = KeychainService.Read.value(Data("0f0f0f0f-1111-2222-3333-444455556666".utf8))
    private let locked = KeychainService.Read.unavailable(errSecInteractionNotAllowed)

    func testOnlyNothingStoredIsSignedOut() {
        typealias Auth = Track.AuthManager
        XCTAssertEqual(Auth.sessionAtLaunch(token: token, userId: account), .stored)
        XCTAssertEqual(Auth.sessionAtLaunch(token: .notFound, userId: account), .signedOut)
        XCTAssertEqual(Auth.sessionAtLaunch(token: token, userId: .notFound), .signedOut)
        XCTAssertEqual(Auth.sessionAtLaunch(token: locked, userId: locked), .notKnownYet,
                       "before the first unlock: not signed out")
        XCTAssertEqual(Auth.sessionAtLaunch(token: token, userId: locked), .notKnownYet)
        XCTAssertEqual(Auth.sessionAtLaunch(token: .unavailable(errSecAuthFailed), userId: account), .notKnownYet,
                       "any other Keychain failure is no answer either")
        XCTAssertEqual(Auth.sessionAtLaunch(token: .notFound, userId: locked), .signedOut,
                       "no token stored: signed out, whatever else can't be read")
        XCTAssertEqual(Auth.sessionAtLaunch(token: .value(Data([0xff, 0xfe])), userId: account), .signedOut,
                       "a token that isn't text is none")
    }

    func testAKeychainStatusIsARead() {
        typealias Read = KeychainService.Read
        XCTAssertEqual(Read.of(status: errSecSuccess, result: Data("x".utf8) as AnyObject), .value(Data("x".utf8)))
        XCTAssertEqual(Read.of(status: errSecItemNotFound, result: nil), .notFound)
        XCTAssertEqual(Read.of(status: errSecInteractionNotAllowed, result: nil), .unavailable(errSecInteractionNotAllowed))
        XCTAssertEqual(Read.of(status: errSecSuccess, result: nil), .unavailable(errSecDecode), "no data is no answer")
    }

    /// Before the first unlock the check waits for it, however long. On a
    /// device unlocked all along, a Keychain that still doesn't answer is
    /// checked again ten times, a second apart, then the sign-in screen shows,
    /// with nothing deleted: it never spins the launch.
    func testAnUnlockedDeviceIsCheckedAgainTenTimesThenSignIn() {
        typealias Auth = Track.AuthManager
        XCTAssertTrue(Auth.checksAgain(unlocked: false, unlockedRechecks: 50), "locked: the unlock answers it")
        for done in 0..<10 { XCTAssertTrue(Auth.checksAgain(unlocked: true, unlockedRechecks: done), "\(done)") }
        XCTAssertFalse(Auth.checksAgain(unlocked: true, unlockedRechecks: 10))
        XCTAssertEqual(Auth.unlockedRecheckLimit, 10)
    }

    /// The launch check keeps its splash and waits when the answer isn't
    /// known: it never marks the person signed out then.
    func testTheLaunchCheckWaitsInsteadOfSigningOut() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let auth = try String(contentsOf: root.appendingPathComponent("App/Managers/AuthManager.swift"), encoding: .utf8)
        XCTAssertTrue(auth.contains("        var answered = true\n        defer { if answered { isCheckingSession = false } }"))
        XCTAssertTrue(auth.contains("""
                    switch Self.sessionAtLaunch(token: keychain.read(.accessToken), userId: keychain.read(.userId)) {
                    case .signedOut:
                        isAuthenticated = false
                        return
                    case .notKnownYet:
            """))
        XCTAssertTrue(auth.contains("""
                        let unlocked = UIApplication.shared.isProtectedDataAvailable
                        guard Self.checksAgain(unlocked: unlocked, unlockedRechecks: unlockedRechecks) else {
                            isAuthenticated = false
                            return
                        }
                        if unlocked { unlockedRechecks += 1 }
                        answered = false
                        checkSessionAgainWhenReadable()
                        return
            """))
        XCTAssertTrue(auth.contains("""
                    if UIApplication.shared.isProtectedDataAvailable {
                        Task {
                            try? await Task.sleep(nanoseconds: 1_000_000_000)
                            await checkSessionAgain()
                        }
                    }
            """), "never at once: a second apart")
        XCTAssertFalse(auth.contains("guard keychain.getString(for: .accessToken) != nil,"),
                       "no read that takes a Keychain failure for no token")
        XCTAssertTrue(auth.contains("forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main"))
    }
}
