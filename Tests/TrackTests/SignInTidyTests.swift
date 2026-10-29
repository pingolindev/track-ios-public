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

/// At a sign-in, what another account left here that holds against the
/// server (its owed removals, its approvals with their tombstones and dead
/// ids, its retained pins) goes only when the person typed an email and it
/// differs from the one saved with that account: a server naming some other
/// account at a sign-in can't make this device forget them. Only once the
/// sign-in has succeeded.
@MainActor
final class SignInTidyTests: XCTestCase {
    private let a = "0a0a0a0a-1111-4222-8333-444455556666"
    private let b = "0b0b0b0b-1111-4222-8333-444455556666"
    private let circle = "c1c1c1c1-0000-4000-8000-000000000001"
    private let member = "d1d1d1d1-0000-4000-8000-000000000002"
    private var directory: URL!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("SignInTidyTests-\(UUID().uuidString)")
        suiteName = "SignInTidyTests.\(UUID().uuidString)"
        RetainedMemberPins.deleteAll(except: nil)
        SignInEmails.deleteAll()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        UserDefaults().removePersistentDomain(forName: suiteName)
        RetainedMemberPins.deleteAll(except: nil)
        SignInEmails.deleteAll()
        super.tearDown()
    }

    private func approvals() -> KeyDeliveryApprovals {
        KeyDeliveryApprovals(
            defaults: UserDefaults(suiteName: suiteName)!, deviceTag: { "device-tag" },
            lock: AppGroupLock(url: FileManager.default.temporaryDirectory
                .appendingPathComponent("approvals-\(UUID().uuidString).lock")))
    }

    /// Account A's data, as A's sign-out leaves it here.
    private func leaveAccountA(email: String?, ledger: RefreshLedger, approvals: KeyDeliveryApprovals) throws {
        XCTAssertTrue(ledger.noteRemoval(account: a, circleId: circle, userId: member, at: Date()))
        approvals.approve(owner: a, circleId: circle, userId: member, origin: .statement)
        try RetainedMemberPins.write("{}", account: a.uppercased())  // stored under the upper-case id, as older versions do
        if let email { SignInEmails.save(email, for: a) }
    }

    private func holds(_ account: String, ledger: RefreshLedger, approvals: KeyDeliveryApprovals) -> [Bool] {
        [ledger.accounts().contains(account), approvals.owners().contains(account),
         RetainedMemberPins.accounts().contains { CanonicalId.key($0) == account }]
    }

    func testTheRule() {
        XCTAssertFalse(SignInTidy.mayForget(typedEmail: "a@example.com", savedEmail: "a@example.com"))
        XCTAssertFalse(SignInTidy.mayForget(typedEmail: " A@Example.com\n", savedEmail: "a@example.com"), "as compared")
        XCTAssertTrue(SignInTidy.mayForget(typedEmail: "b@example.com", savedEmail: "a@example.com"))
        XCTAssertFalse(SignInTidy.mayForget(typedEmail: nil, savedEmail: "a@example.com"), "no email typed: kept")
        XCTAssertFalse(SignInTidy.mayForget(typedEmail: "b@example.com", savedEmail: nil), "none saved: kept")
    }

    /// A signs in with A's own email and the server names account B: A's
    /// guarded data stays. With no email typed it stays too. A different
    /// person, typing a different email, takes it, all of it.
    func testAnotherAccountsGuardedDataGoesOnlyForADifferentTypedEmail() throws {
        let ledger = RefreshLedger(directory: directory)
        let store = approvals()
        try leaveAccountA(email: "A@example.com", ledger: ledger, approvals: store)
        XCTAssertEqual(holds(a, ledger: ledger, approvals: store), [true, true, true])

        XCTAssertEqual(SignInTidy.run(signedIn: b.uppercased(), typedEmail: " a@EXAMPLE.com",
                                      ledger: ledger, approvals: store), [])
        XCTAssertEqual(holds(a, ledger: ledger, approvals: store), [true, true, true], "the same person: kept")
        XCTAssertEqual(SignInEmails.saved(for: a), "a@example.com")
        XCTAssertEqual(SignInEmails.saved(for: b), "a@example.com", "this sign-in's typed email, saved with it")

        XCTAssertEqual(SignInTidy.run(signedIn: b, typedEmail: nil, ledger: ledger, approvals: store), [])
        XCTAssertEqual(holds(a, ledger: ledger, approvals: store), [true, true, true], "no email typed: kept")

        store.approve(owner: b, circleId: circle, userId: member, origin: .statement)
        XCTAssertEqual(SignInTidy.run(signedIn: b, typedEmail: "b@example.com", ledger: ledger, approvals: store), [a])
        XCTAssertEqual(holds(a, ledger: ledger, approvals: store), [false, false, false], "another person: gone")
        XCTAssertEqual(store.owners(), [b], "the account signing in keeps its own")
        XCTAssertNil(SignInEmails.saved(for: a))
        XCTAssertEqual(ledger.circle(account: a, circleId: circle), RefreshLedger.Circle())
        XCTAssertTrue(store.approvedMembers(owner: a, circleId: circle).isEmpty)
        XCTAssertEqual(SignInEmails.saved(for: b), "b@example.com")
    }

    /// What another account saw of each SOS (`SOSAlarmMarks`) goes only by the
    /// same guarded tidy, even when nothing else of it is here; it is never
    /// adopted.
    func testSOSMarksGoOnlyByTheGuardedTidy() throws {
        let ledger = RefreshLedger(directory: directory)
        let store = approvals()
        let marks = SOSAlarmMarks(directory: directory.appendingPathComponent("marks", isDirectory: true))
        XCTAssertTrue(marks.noteEnded(account: a.uppercased(), circleId: circle, sosId: member, at: 1))
        SignInEmails.save("a@example.com", for: a)
        XCTAssertEqual(SignInTidy.run(signedIn: b, typedEmail: " A@example.com", ledger: ledger, approvals: store,
                                      marks: marks), [])
        XCTAssertNotNil(marks.mark(account: a, circleId: circle, sosId: member), "the same person: kept")
        XCTAssertNil(marks.mark(account: b, circleId: circle, sosId: member), "never adopted")
        XCTAssertEqual(SignInTidy.run(signedIn: b, typedEmail: "b@example.com", ledger: ledger, approvals: store,
                                      marks: marks), [a], "another person")
        XCTAssertNil(marks.mark(account: a, circleId: circle, sosId: member), "another person: gone")
        XCTAssertEqual(marks.accounts(), [])
    }

    /// An account with no email saved (data left by an older version): kept
    /// whatever is typed.
    func testNoSavedEmailKeepsIt() throws {
        let ledger = RefreshLedger(directory: directory)
        let store = approvals()
        try leaveAccountA(email: nil, ledger: ledger, approvals: store)
        XCTAssertEqual(SignInTidy.run(signedIn: b, typedEmail: "b@example.com", ledger: ledger, approvals: store), [])
        XCTAssertEqual(holds(a, ledger: ledger, approvals: store), [true, true, true])
    }

    /// The account signing in keeps its own, and its record takes the email.
    func testTheSignedInAccountKeepsItsOwn() throws {
        let ledger = RefreshLedger(directory: directory)
        let store = approvals()
        try leaveAccountA(email: "a@example.com", ledger: ledger, approvals: store)
        XCTAssertEqual(SignInTidy.run(signedIn: a.uppercased(), typedEmail: "a2@example.com",
                                      ledger: ledger, approvals: store), [])
        XCTAssertEqual(holds(a, ledger: ledger, approvals: store), [true, true, true])
        XCTAssertEqual(SignInEmails.saved(for: a), "a2@example.com")
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// The wiring: the typed email reaches the sign-in, through the second
    /// step too; the outgoing account's pins are kept before a switch's purge;
    /// the tidy runs only once the keys are in, before anything touches a
    /// circle, and nothing else at a sign-in deletes another account's guarded
    /// data; an erasure takes every email record.
    func testTheTidyIsWiredAfterTheSignInSucceeds() throws {
        let auth = try source("App/Managers/AuthManager.swift")
        func body(from start: String, to end: String) throws -> Substring {
            let from = try XCTUnwrap(auth.range(of: start), start)
            let to = try XCTUnwrap(auth[from.upperBound...].range(of: end), end)
            return auth[from.upperBound..<to.lowerBound]
        }
        let login = try body(from: "    func login(email: String, password: String) async throws {", to: "    func verify2FA(")
        XCTAssertTrue(login.contains("            self.pendingEmail = email\n"))
        XCTAssertTrue(login.contains("                keys: step2.keysToOpen,\n                typedEmail: email\n"))
        let verify = try body(from: "    func verify2FA(code: String) async throws {", to: "    nonisolated static func twoFactorRefusal(")
        XCTAssertTrue(verify.contains("        let typedEmail = pendingEmail\n"))
        XCTAssertTrue(verify.contains("password: password, keys: response.keysToOpen, typedEmail: typedEmail)"))
        for exit in ["func cancelTwoFactor() {", "func logout(retainingTrust: Bool = true) async {", "func expireSession() {"] {
            let at = try XCTUnwrap(auth.range(of: exit), exit)
            XCTAssertTrue(auth[at.upperBound...].prefix(6_000).contains("pendingEmail = nil"), exit)
        }

        let complete = try body(from: "    private func completeLogin(", to: "    /// Undo what `completeLogin` wrote")
        let retained = try XCTUnwrap(complete.range(of: """
                        if let outgoing = CanonicalId.of(prior), KeyStoreRecovery.pinsExportable(cryptoManager.keyStoreStatus()) {
                            RetainedMemberPins.retain(owner: outgoing, crypto: cryptoManager)
                        }
                        await purgeAccountData()

            """))
        let imported = try XCTUnwrap(complete.range(of: "try await deriveAndImportSharingKey(password: password, keys: signInKeys.keys, kdf: signInKeys.kdf)"))
        let restored = try XCTUnwrap(complete.range(of: "let restoredPins = RetainedMemberPins.restore(owner: me, crypto: cryptoManager)"))
        let tidy = try XCTUnwrap(complete.range(of: """
                    SignInTidy.run(signedIn: me, typedEmail: typedEmail)
                    AccountKeyedDefaults.wipe(except: me)
                    MemberVerificationStore.adopt(owner: me)

            """))
        let selfKey = try XCTUnwrap(complete.range(of: "        await SelfKeyManager.ensure()\n"))
        XCTAssertLessThan(retained.lowerBound, imported.lowerBound)
        XCTAssertLessThan(imported.upperBound, tidy.lowerBound, "only once the keys are in")
        XCTAssertLessThan(restored.upperBound, tidy.lowerBound)
        XCTAssertLessThan(tidy.upperBound, selfKey.lowerBound, "before anything touches a circle")
        for failing in ["throw", "try"] {
            XCTAssertFalse(complete[tidy.upperBound...].contains(failing), "nothing after it fails the sign-in")
        }
        for gone in ["clearAll(exceptOwner:", "wipeAll(except:", "RetainedMemberPins.deleteAll(", "forget("] {
            XCTAssertFalse(complete.contains(gone), gone)
        }
        XCTAssertTrue(auth.contains("                AccountKeyedDefaults.wipe(except: nil)\n                SignInEmails.deleteAll()\n"),
                      "an erasure takes every email record")
    }
}
