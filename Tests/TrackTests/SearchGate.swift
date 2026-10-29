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

import Foundation

/// Holds a piece of work at `wait()` until the test opens it, so a test can act
/// (cancel a caller, start a second search) while the work is "on the wire".
actor SearchGate {
    private var opened = false
    private var held: [CheckedContinuation<Void, Never>] = []
    private var watchers: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation in
            held.append(continuation)
            watchers.forEach { $0.resume() }
            watchers = []
        }
    }

    /// Returns once some work is held at the gate.
    func somethingWaits() async {
        if !held.isEmpty { return }
        await withCheckedContinuation { watchers.append($0) }
    }

    func open() {
        opened = true
        held.forEach { $0.resume() }
        held = []
    }
}

/// A task a fake can reach while the test holds the handle.
@MainActor
final class TaskSlot<T: Sendable> {
    var task: Task<T, Never>?
}
