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

/// A member who is not sharing is SPOKEN as not sharing: the status is part of
/// the row's accessibility label, not only something drawn under the name.
/// (With the status hidden from VoiceOver the row reads just "M, Maya", and
/// this fails.)
@MainActor
final class MemberRowAccessibilityTests: XCTestCase {

    /// SwiftUI builds its accessibility tree only while an assistive technology
    /// is on, so a unit test sees none (measured: an empty tree) until
    /// application accessibility is switched on — the switch VoiceOver throws,
    /// reached the way snapshot tools reach it, in this test bundle only. Put
    /// back afterwards. A runtime without the switch skips, saying so.
    private func withAccessibilityOn<T>(_ body: () -> T) throws -> T {
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
        return body()
    }

    private func labels(of view: some View) -> [String] {
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

    func testTheRowIsSpokenWithTheStatus() throws {
        let circle = Circle(id: UUID().uuidString.lowercased(), name: "Family", isOwner: false,
                            keyRotationNeeded: false, keyVersion: 1)
        let member = CircleMember(circleId: circle.id, userId: UUID().uuidString.lowercased(), displayName: "Maya",
                                  role: .member, canSeeRealtime: true, canSeeHistory: true, canRotateKeys: false,
                                  joinedAt: Date(), keyVersion: 1, locationSharing: "off")
        let spoken = try withAccessibilityOn {
            labels(of: List { MemberRow(member: member, circle: circle, onSecurityDetails: {}) })
        }
        XCTAssertTrue(spoken.contains { $0.contains("Maya") && $0.contains("Location sharing off") },
                      "spoken: \(spoken)")
    }
}
