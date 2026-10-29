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

/// One run at a time per key, in the order asked: one serialized operation
/// per alert, so a re-seal after a key change and a position update never
/// interleave and neither undoes the other. A run asked for while another
/// already waits to start joins that one: it reads everything afresh when
/// it starts, so a second would find nothing new.
@MainActor
final class SerialRuns<Output: Sendable> {
    private var tail: [String: Task<Output?, Never>] = [:]
    private var waiting: Set<String> = []

    /// `body` once every run of `key` asked for before it has ended. The task
    /// gives its output, or nil once `reset` dropped it before it started.
    func run(_ key: String, _ body: @escaping @MainActor () async -> Output) -> Task<Output?, Never> {
        if waiting.contains(key), let queued = tail[key] { return queued }
        let previous = tail[key]
        let generation = self.generation
        waiting.insert(key)
        let task = Task { @MainActor [weak self] () -> Output? in
            _ = await previous?.value
            guard let self, self.generation == generation else { return nil }
            self.waiting.remove(key)
            return await body()
        }
        tail[key] = task
        return task
    }

    /// Sign-out: a run not started yet never starts.
    func reset() {
        generation += 1
        tail = [:]
        waiting = []
    }

    private var generation = 0
}
