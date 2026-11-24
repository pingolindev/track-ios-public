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

/// The countdown on one of this account's own check-in rules
/// (`CheckInCountdown`). A one-time rule: "Your circle is alerted in 3 h 12
/// min", or once due, "Your circle was alerted at 9:40 PM. Check in to clear
/// it." ("on Jan 15 at 9:40 PM" on another day). A scheduled one: "Your circle
/// is alerted at 9:00 PM unless you check in.", "Checked in. Next due
/// tomorrow by 9:00 PM." or the missed line.
///
/// It turns over as its minutes do, in step with the deadline
/// (`DeadlineMinutes`). VoiceOver reads it like any other text and is not told
/// of each new minute: no updates-frequently trait, no announcement.
struct CheckInCountdownLine: View {
    let countdown: CheckInCountdown.Countdown

    init(countdown: CheckInCountdown.Countdown) {
        self.countdown = countdown
    }

    /// A one-time rule's line.
    init(deadline: Date) {
        self.init(countdown: .once(deadline: deadline))
    }

    var body: some View {
        switch countdown {
        case .once(let deadline):
            TimelineView(DeadlineMinutes(deadline: deadline)) { _ in
                // The clock, not the tick's date: a tick lands on the minute
                // boundary itself, where the tick's date still reads the
                // minute before.
                Text(CheckInCountdown.text(countdown, now: Date()))
            }
        case .scheduled:
            // A scheduled rule's line names times, not time left: it changes
            // when an occurrence comes due, a window opens or the day turns,
            // so every minute is enough.
            TimelineView(.everyMinute) { _ in
                Text(CheckInCountdown.text(countdown, now: Date()))
            }
        }
    }
}

/// Every minute, in step with a deadline: the minutes left change on these
/// ticks, and the line turns to "was alerted" on the one at the deadline.
struct DeadlineMinutes: TimelineSchedule {
    let deadline: Date

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        var next = deadline.addingTimeInterval((startDate.timeIntervalSince(deadline) / 60).rounded(.down) * 60)
        return AnyIterator {
            defer { next = next.addingTimeInterval(60) }
            return next
        }
    }
}
