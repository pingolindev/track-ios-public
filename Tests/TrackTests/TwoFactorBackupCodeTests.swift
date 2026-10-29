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

/// A backup code at the two-step prompt. Backup codes are 12 characters, so a
/// number pad cut at 6 that sends itself would leave someone who has lost
/// their authenticator unable to sign in here at all. The code is sent whole
/// (only spaces and dashes dropped, nothing cut, no case change), never sent
/// by itself, with the same attempt handling as an authenticator code, and
/// never logged. The live half is
/// AuthIntegrationTests.testABackupCodeWrittenInGroupsSignsIn.
final class TwoFactorBackupCodeTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// The same cases as the account portal's `codeToSend`.
    func testACodeIsSentWholeWithoutItsSpacesAndDashes() {
        XCTAssertEqual(TwoFactorView.codeToSend("123456"), "123456")
        XCTAssertEqual(TwoFactorView.codeToSend("123 456"), "123456")
        XCTAssertEqual(TwoFactorView.codeToSend(" 123456\n"), "123456")
        XCTAssertEqual(TwoFactorView.codeToSend("ABCD-EFGH-JKLM"), "ABCDEFGHJKLM")
        XCTAssertEqual(TwoFactorView.codeToSend("abcd efgh jklm"), "abcdefghjklm", "the case is left alone")
        XCTAssertEqual(TwoFactorView.codeToSend("A1B2C3D4E5F6").count, 12, "nothing is cut")
    }

    func testTheBackupFieldNeverSendsItselfAndTheCodePathStaysAsItWas() throws {
        let sheet = try source("App/Views/Auth/TwoFactorView.swift")
        let start = try XCTUnwrap(sheet.range(of: "private var backupCodeField: some View {"))
        let end = try XCTUnwrap(sheet.range(of: "\n    }\n", range: start.upperBound..<sheet.endIndex))
        let field = sheet[start.upperBound..<end.lowerBound]
        XCTAssertFalse(field.contains(".onChange"), "never sent by itself at some length")
        XCTAssertFalse(field.contains("prefix("), "never cut")
        XCTAssertTrue(field.contains(".onSubmit(verifyBackupCode)"), "sent when the person says so")
        XCTAssertTrue(field.contains(".textInputAutocapitalization(.never)"))
        XCTAssertTrue(sheet.contains("let sent = Self.codeToSend(backupCode)\n        guard !sent.isEmpty else { return }\n        submit(sent)"))
        XCTAssertTrue(sheet.contains("Button(usingBackupCode ? \"Use your authenticator app\" : \"Use a backup code\") {"))
        XCTAssertTrue(sheet.contains("Text(usingBackupCode ? \"Enter one of your backup codes\""))
        // Either kind: the same verify2FA, so the same attempt handling.
        XCTAssertTrue(sheet.contains("try await authManager.verify2FA(code: sent)"))
        // The 6-digit path: a number pad, cut at 6, sent at 6.
        XCTAssertTrue(sheet.contains("code = String(newValue.prefix(6))"))
        XCTAssertTrue(sheet.contains("if newValue.count == 6 {\n                    verify()"))
    }

    /// A code never reaches a log from the sheet or the sign-in step (the
    /// DEBUG diagnostics dump only responses, which never carry it).
    func testTheCodeIsNeverLogged() throws {
        let sheet = try source("App/Views/Auth/TwoFactorView.swift")
        XCTAssertFalse(sheet.contains("print("))
        XCTAssertFalse(sheet.contains("Logger"))
        let auth = try source("App/Managers/AuthManager.swift")
        let start = try XCTUnwrap(auth.range(of: "func verify2FA(code: String) async throws {"))
        let end = try XCTUnwrap(auth.range(of: "\n    }\n", range: start.upperBound..<auth.endIndex))
        let step = auth[start.upperBound..<end.lowerBound]
        for call in ["print(", "Logger(", ".info(", ".error(", ".debug(", ".notice(", ".warning(", ".fault("] {
            XCTAssertFalse(step.contains(call), call)
        }
    }
}
