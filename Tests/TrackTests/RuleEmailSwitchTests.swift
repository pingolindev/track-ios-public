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

import SwiftUI
import XCTest
@testable import Track

/// E-mail switches that would send nothing. Low-battery and inactivity rules
/// are judged on the subscriber's own phone, so the server never learns who
/// watches whom and cannot send their e-mail; those rules have no Email
/// switch. A circle notification's e-mail goes to every member with an
/// address whatever any switch says, so the row that describes it is locked,
/// and says so.
@MainActor
final class RuleEmailSwitchTests: XCTestCase {

    // SwiftUI builds its accessibility tree only while an assistive technology
    // is on — see MemberRowAccessibilityTests, whose switch this borrows.
    private func spokenLabels(of view: some View) throws -> [String] {
        typealias Getter = @convention(c) () -> Bool
        typealias Setter = @convention(c) (Bool) -> Void
        guard let lib = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW),
              let getter = dlsym(lib, "_AXSApplicationAccessibilityEnabled"),
              let setter = dlsym(lib, "_AXSApplicationAccessibilitySetEnabled") else {
            throw XCTSkip("this simulator runtime has no application accessibility switch")
        }
        let get = unsafeBitCast(getter, to: Getter.self)
        let set = unsafeBitCast(setter, to: Setter.self)
        let was = get()
        set(true)
        defer { set(was) }
        let host = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        var found: [String] = []
        collect(host.view, into: &found, depth: 0)
        window.isHidden = true
        return found
    }

    private func collect(_ object: NSObject, into found: inout [String], depth: Int) {
        guard depth < 30 else { return }
        if object.isAccessibilityElement, let label = object.accessibilityLabel, !label.isEmpty {
            found.append(label)
        }
        if let elements = object.accessibilityElements as? [NSObject] {
            for element in elements { collect(element, into: &found, depth: depth + 1) }
        } else {
            let count = object.accessibilityElementCount()
            if count != NSNotFound, count > 0 {
                for index in 0..<count {
                    if let element = object.accessibilityElement(at: index) as? NSObject {
                        collect(element, into: &found, depth: depth + 1)
                    }
                }
            }
        }
        if let view = object as? UIView {
            for subview in view.subviews { collect(subview, into: &found, depth: depth + 1) }
        }
    }

    /// Both editors offer Push and nothing that claims to e-mail.
    func testTheRuleEditorsHaveNoEmailSwitch() throws {
        for mode in [AlertEditorMode.createBattery, .createInactivity] {
            let spoken = try spokenLabels(of: NavigationStack { AlertEditorView(mode: mode) })
            XCTAssertTrue(spoken.contains { $0 == "Push" }, "\(mode.id) spoken: \(spoken)")
            XCTAssertFalse(spoken.contains { $0.localizedCaseInsensitiveContains("email") },
                           "\(mode.id) spoken: \(spoken)")
        }
    }

    /// A rule saved with e-mail only notifies through the phones (the server
    /// wakes them for push OR e-mail), so it opens with Push on and saving it
    /// keeps it notifying.
    func testAnEmailOnlyRuleOpensWithPushOn() {
        XCTAssertTrue(AlertEditorView.initialPush(notifyPush: false, notifyEmail: true))
        XCTAssertTrue(AlertEditorView.initialPush(notifyPush: true, notifyEmail: false))
        XCTAssertTrue(AlertEditorView.initialPush(notifyPush: true, notifyEmail: true))
        XCTAssertFalse(AlertEditorView.initialPush(notifyPush: false, notifyEmail: false),
                       "a rule with Push off and no e-mail stays as its owner left it")

        // ...and a save of it sends push true, email false.
        let saved = AlertEditorView.savedChannels(push: AlertEditorView.initialPush(notifyPush: false, notifyEmail: true))
        XCTAssertTrue(saved.notifyPush)
        XCTAssertFalse(saved.notifyEmail)
        // Every save — creates included, where the server requires the field — says false.
        XCTAssertFalse(AlertEditorView.savedChannels(push: false).notifyEmail)
    }

    /// The locked circle-notification row says the e-mail goes regardless, as
    /// the web's locked row does, still without the word SOS.
    func testTheLockedRowSaysTheEmailGoesToo() {
        let note = SettingsView.undeniableCategoryNote
        XCTAssertTrue(note.contains("emailed"), note)
        XCTAssertTrue(note.contains("can't be turned off"), note)
        XCTAssertFalse(note.localizedCaseInsensitiveContains("SOS"), note)
    }
}
