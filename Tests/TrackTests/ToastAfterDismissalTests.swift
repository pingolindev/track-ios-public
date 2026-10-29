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

/// A toast that follows a closing sheet is said to VoiceOver once the sheet
/// has gone: VoiceOver can cut off what is said while the screen changes.
/// The dismissal's own end, the sheet's `onDismiss`, says it; a guessed
/// delay never does. A toast with no sheet closing, like every send toast,
/// is said at once.
final class ToastAfterDismissalTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func body(_ text: String, from start: String, to end: String) throws -> String {
        let a = try XCTUnwrap(text.range(of: start), start)
        let b = try XCTUnwrap(text.range(of: end, range: a.upperBound..<text.endIndex), end)
        return String(text[a.lowerBound..<b.lowerBound])
    }

    /// The gone circle's toast follows the sheets it closes, so it waits for them.
    func testTheGoneCirclesToastWaitsForItsSheetToGo() throws {
        let map = try source("App/Views/Map/MapView.swift")
        XCTAssertTrue(map.contains(
            "                if closed { showSendToast(\"This circle isn't on this device any more.\", afterDismissal: true) }\n"))
        XCTAssertEqual(map.components(separatedBy: "afterDismissal: true").count - 1, 1, "that toast alone")
    }

    /// Every sheet that handler can close says the held words when it has gone.
    func testEverySheetItClosesSaysItOnceGone() throws {
        let map = try source("App/Views/Map/MapView.swift")
        for flag in ["$mapTapState.showingMemberDetail", "$mapTapState.showingPlaceDetail", "$showingCheckIn",
                     "$showingDestinationsList", "$showingDestinations", "$showingHistory",
                     "$mapTapState.showingSOSDetail"] {
            XCTAssertTrue(map.contains(".sheet(isPresented: \(flag), onDismiss: announceHeldToast) {"), flag)
        }
        XCTAssertEqual(map.components(separatedBy: "onDismiss: announceHeldToast").count - 1, 7)
    }

    /// Held only while a sheet closes; said once, by the dismissal or, if none
    /// came, at the toast's end rather than never.
    func testHeldOnlyForADismissalAndSaidOnce() throws {
        let map = try source("App/Views/Map/MapView.swift")
        let toast = try body(map, from: "    private func showSendToast(_ message: String, afterDismissal: Bool = false) {\n",
                             to: "    /// The words a closing sheet held back")
        XCTAssertTrue(toast.contains("""
                if afterDismissal {
                    heldToastAnnouncement = message
                } else {
                    AccessibilityNotification.Announcement(message).post()
                }
        """))
        XCTAssertTrue(toast.contains("""
                    if sendToastToken == token {
                        sendToast = nil
                        // No dismissal came in the toast's time: said now rather than
                        // never.
                        announceHeldToast()
                    }
        """))
        let held = try body(map, from: "    private func announceHeldToast() {\n", to: "    /// One of three states")
        XCTAssertTrue(held.contains("""
                guard let message = heldToastAnnouncement else { return }
                heldToastAnnouncement = nil
                AccessibilityNotification.Announcement(message).post()
        """))
    }
}
