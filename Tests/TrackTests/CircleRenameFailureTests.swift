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

/// A rename that fails keeps Circle Settings open and says why.
///
/// WHY THIS IS WORTH TESTING
///   `updateCircle` throws when the name can't be sealed or the server
///   refuses it or can't be reached, and the local name changes only after
///   the server took it. A Save that swallowed the error (`try?`) and then
///   dismissed whatever happened would close the sheet as if the rename had
///   worked, with the earlier name still in place and nothing said why. A
///   rename that waits for this iPhone to catch up returns normally from
///   `updateCircle`, and still closes the sheet.
@MainActor
final class CircleRenameFailureTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// The sheet's own `saveChanges`, from its doc comment to the end of the sheet.
    private func saveChanges() throws -> String {
        let view = try source("App/Views/Circles/CirclesView.swift")
        let sheet = try XCTUnwrap(view.range(of: "struct CircleSettingsSheet: View {"))
        let end = try XCTUnwrap(view.range(of: "struct PrivacySettingsSheet: View {", range: sheet.upperBound..<view.endIndex))
        let body = String(view[sheet.lowerBound..<end.lowerBound])
        let start = try XCTUnwrap(body.range(of: "    private func saveChanges() {\n"))
        return String(body[start.lowerBound...])
    }

    /// The line says the name stayed, then why, in this app's words.
    func testAFailedRenameSaysTheNameWasNotChangedAndWhy() {
        let down = APIError(code: "http_503", message: "upstream connect error")
        XCTAssertEqual(CircleSettingsSheet.renameFailedLine(down),
                       "The name wasn't changed. Pingolin is having trouble just now. Please try again in a moment.")
        let refused = APIError(code: "http_403", message: "at_version is not this circle's current key version")
        let line = CircleSettingsSheet.renameFailedLine(refused)
        XCTAssertEqual(line, "The name wasn't changed. \(APIError.notAllowedText)")
        XCTAssertFalse(line.contains("key"), "never the server's words")
    }

    /// Save closes the sheet only after `updateCircle` returned; a throw keeps it
    /// open with the line, and Save can be pressed again.
    func testSaveClosesOnlyWhenTheRenameWentThroughOrWaits() throws {
        let save = try saveChanges()
        XCTAssertFalse(save.contains("try? await circleManager.updateCircle"), "a failure must not read as done")
        XCTAssertTrue(save.contains("""
                    do {
                        try await circleManager.updateCircle(circle, name: name)
                        dismiss()
                    } catch {
                        saveError = Self.renameFailedLine(error)
                        isLoading = false
                    }
        """))
        XCTAssertEqual(save.components(separatedBy: "dismiss()").count - 1, 1, "one close, after the rename")
    }

    /// The line is on the sheet, under the name being edited.
    func testTheSheetShowsTheLine() throws {
        let view = try source("App/Views/Circles/CirclesView.swift")
        XCTAssertTrue(view.contains("""
                        Section {
                            TextField("Circle Name", text: $name)
                        }

                        if let saveError {
                            Section {
                                Label(saveError, systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(.red)
                            }
                        }
        """))
    }
}
