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

/// The History sheet says "History" once, in its title. The one card it holds
/// does not say it again under the title and has no close of its own beside
/// Done (which would do the same as Done): the card's first line is the point
/// count, and the sheet's height leaves no line for a second heading.
final class HistorySheetHeadingTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// One type's declaration, up to the next top-level one.
    private func declaration(_ name: String, in text: String) throws -> String {
        let start = try XCTUnwrap(text.range(of: "struct \(name): View {\n"), name)
        let end = text.range(of: "\n}\n", range: start.upperBound..<text.endIndex)?.upperBound ?? text.endIndex
        return String(text[start.lowerBound..<end])
    }

    func testTheCardHasNoHeadingOfItsOwn() throws {
        let card = try declaration("HistoryCard", in: try source("App/Views/Map/HistoryView.swift"))
        XCTAssertFalse(card.contains("Text(\"History\")"))
        XCTAssertTrue(card.contains("Text(\"\\(viewModel.pointCount) point\\(viewModel.pointCount == 1 ? \"\" : \"s\")\")"),
                      "the count is its first line")
        XCTAssertTrue(card.contains("ProgressView().controlSize(.small)"), "still beside the count")
    }

    func testTheCardHasNoCloseOfItsOwn() throws {
        let card = try declaration("HistoryCard", in: try source("App/Views/Map/HistoryView.swift"))
        XCTAssertFalse(card.contains("xmark"))
        XCTAssertFalse(card.contains("onClose"))
    }

    func testTheSheetKeepsItsTitleAndDone() throws {
        let sheet = try declaration("HistorySheet", in: try source("App/Views/Map/HistoryView.swift"))
        XCTAssertTrue(sheet.contains(".navigationTitle(\"History\")\n"))
        XCTAssertTrue(sheet.contains("Button(\"Done\") { dismiss() }"))
        XCTAssertTrue(sheet.contains("HistoryCard(viewModel: viewModel)\n"))
    }

    /// The sheet's height is set by what it shows, so it has no line for
    /// a heading of its own.
    func testTheSheetHasNoLineForAHeading() throws {
        let sheet = try declaration("HistorySheet", in: try source("App/Views/Map/HistoryView.swift"))
        XCTAssertTrue(sheet.contains(
            "238 + (viewModel.range == .custom ? 100 : 0) + (viewModel.memberName == nil ? 0 : 28)"))
    }
}
