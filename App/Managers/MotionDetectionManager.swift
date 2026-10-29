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
import CoreMotion
import Combine

/// Still vs. moving, for the poll cadence. Mirrors the Android app's
/// MotionDetectionManager but uses iOS's higher-level
/// CMMotionActivityManager — same intent (still vs. moving), no
/// accelerometer polling.
///
/// `LocationService` observes `motionState` to pick the GPS POLL cadence:
/// 20 s moving, 5 min still (see `LocationService.pollInterval`). It does not
/// pause sharing — a still phone keeps checking in. Low-confidence readings,
/// and readings that name no activity at all, are ignored rather than
/// applied, so transient jitter doesn't flap the state.
@MainActor
final class MotionDetectionManager: ObservableObject {
    static let shared = MotionDetectionManager()

    enum MotionState: String {
        case still
        case moving
        case unknown
    }

    @Published private(set) var motionState: MotionState = .unknown
    @Published private(set) var isAvailable: Bool = false

    private let activityManager = CMMotionActivityManager()
    private var isStarted = false

    private init() {
        isAvailable = CMMotionActivityManager.isActivityAvailable()
    }

    /// Begin streaming activity classifications. The system prompts for
    /// motion permission lazily on first call. Idempotent — starting
    /// twice is a no-op.
    func start() {
        guard isAvailable, !isStarted else { return }
        isStarted = true
        activityManager.startActivityUpdates(to: .main) { [weak self] activity in
            guard let self = self, let activity = activity else { return }
            // Ignore low-confidence classifications: a brief
            // low-confidence reading would drop us to .unknown, and
            // consumers treat .unknown ≠ .still and rev the polling
            // back up, so the state would flap during stop-and-go
            // trips. Preserving the previous high-confidence state
            // until we get another high-confidence reading damps
            // that chatter.
            guard let newState = Self.classify(
                stationary: activity.stationary,
                walking: activity.walking,
                running: activity.running,
                automotive: activity.automotive,
                cycling: activity.cycling,
                unknown: activity.unknown,
                lowConfidence: activity.confidence == .low
            ) else { return }
            if newState != self.motionState {
                self.motionState = newState
            }
        }
    }

    /// The classification rule, pure so it can be tested without a
    /// CMMotionActivity (which has no public initializer). nil means IGNORE the
    /// reading and keep the previous state — the low-confidence damping above.
    ///
    /// `stationary` alone is still. `stationary` WITH `automotive` or `cycling`
    /// is a vehicle or bike that has paused — a red light, a station stop — and
    /// is reported as moving: Core Motion sets both flags in that case, and
    /// treating it as still would drop the poll to its still cadence in the
    /// middle of a trip, then haul it back at the next light. Android's activity
    /// recognition reports IN_VEHICLE for the same moment and never downshifts
    /// there either.
    ///
    /// Moving needs a POSITIVE reading: walking, running, automotive or
    /// cycling. A reading that is `unknown`, or names nothing at all, is
    /// ignored. Counted as moving, one such reading would give a phone on a
    /// desk an immediate Best-accuracy poll and the 20 s cadence until Core
    /// Motion next said stationary.
    nonisolated static func classify(
        stationary: Bool,
        walking: Bool,
        running: Bool,
        automotive: Bool,
        cycling: Bool,
        unknown: Bool,
        lowConfidence: Bool
    ) -> MotionState? {
        if lowConfidence { return nil }
        if automotive || cycling || walking || running { return .moving }
        if stationary && !unknown { return .still }
        return nil
    }

    /// Stop streaming. Frees the system resources backing the activity
    /// manager when the feature isn't needed (e.g. on logout).
    func stop() {
        guard isStarted else { return }
        activityManager.stopActivityUpdates()
        isStarted = false
        motionState = .unknown
    }
}
