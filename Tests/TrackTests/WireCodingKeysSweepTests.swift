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

/// No type pairs snake_case CodingKeys raw values with a `.convertFromSnakeCase`
/// decoder. That decoder turns every JSON key into camelCase BEFORE matching, so
/// a raw value like "key_version" never matches: an optional field stays nil and
/// a required one throws, silently under `try?`.
///
/// Every decoder here that reads the wire converts from snake case (APIService,
/// the notification extension's, InviteNotificationCopy's). The one type with
/// snake_case raw values, EnergyMetrics.Report, is written and read back only
/// with a plain JSONEncoder/JSONDecoder, where those raw values are what
/// matches. A new one fails here until it's checked the same way.
final class WireCodingKeysSweepTests: XCTestCase {

    private let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    func testNoSnakeCaseCodingKeysMeetASnakeCaseDecoder() throws {
        var withSnakeCaseKeys: [String] = []
        for directory in ["App", "NotificationExtension"] {
            let enumerator = FileManager.default.enumerator(at: root.appendingPathComponent(directory),
                                                            includingPropertiesForKeys: nil)
            while let url = enumerator?.nextObject() as? URL {
                guard url.pathExtension == "swift" else { continue }
                let text = try String(contentsOf: url, encoding: .utf8)
                let snakeCase = Self.codingKeyBodies(text).contains {
                    $0.range(of: #"=\s*"[A-Za-z0-9]*_[A-Za-z0-9_]*""#, options: .regularExpression) != nil
                }
                if snakeCase {
                    withSnakeCaseKeys.append(String(url.path.dropFirst(root.path.count + 1)))
                }
            }
        }
        XCTAssertEqual(withSnakeCaseKeys.sorted(), ["App/Services/EnergyMetrics.swift"])

        let energy = try String(contentsOf: root.appendingPathComponent("App/Services/EnergyMetrics.swift"),
                                encoding: .utf8)
        XCTAssertFalse(energy.contains("convertFromSnakeCase"))
        XCTAssertTrue(energy.contains("(try? JSONDecoder().decode([Report].self, from: data))"))
        XCTAssertTrue(energy.contains("JSONEncoder().encode(reports)"))
        XCTAssertTrue(energy.contains("request.httpBody = try? JSONEncoder().encode(report)"))
    }

    /// The report round-trips through the plain coders it is used with, and
    /// its wire keys are snake case.
    func testTheEnergyReportKeepsItsKeys() throws {
        let report = EnergyMetrics.Report(platform: "ios", appVersion: "1.0", appBuild: "94", osVersion: "26.0",
                                          periodHours: 24, metrics: ["cpu_seconds": 1.5])
        let data = try JSONEncoder().encode(report)
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]).keys.sorted()
        XCTAssertEqual(keys, ["app_build", "app_version", "metrics", "os_version", "period_hours", "platform"])
        XCTAssertEqual(try JSONDecoder().decode(EnergyMetrics.Report.self, from: data), report)
    }

    /// The body of each `…: String, CodingKey { … }` enum, by counting braces.
    static func codingKeyBodies(_ text: String) -> [Substring] {
        var bodies: [Substring] = []
        var searchFrom = text.startIndex
        while let header = text.range(of: "CodingKey {", range: searchFrom..<text.endIndex) {
            let open = text.index(before: header.upperBound)
            var depth = 0
            var index = open
            while index < text.endIndex {
                if text[index] == "{" { depth += 1 }
                if text[index] == "}" {
                    depth -= 1
                    if depth == 0 { break }
                }
                index = text.index(after: index)
            }
            bodies.append(text[open..<min(index, text.endIndex)])
            searchFrom = header.upperBound
        }
        return bodies
    }
}
