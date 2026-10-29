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
import Combine

/// What the last `SelfKeyManager.ensure()` concluded about this device's
/// personal (self-tracking) key, and the sentence the user should read about it.
///
/// WHY THIS EXISTS
///   Without a surface, these states look like nothing at all on the screen:
///   personal history empty, personal places missing, circles fine, no
///   explanation — the most consequential one being that the server holds a
///   self key this device cannot open.
///
///   The web app has the same states, and this mirrors the distinctions it
///   makes. The important one is `undecryptable` vs `noAccountKeys`: the first
///   means live key material exists that must not be replaced, and only another
///   device can fix it; the second means this device holds no account keys at
///   all, and the password (asked for in place) brings them back. Asking a user
///   in the first state for anything is useless — `ensure()` refuses again for
///   the same reason.
enum SelfKeyHealth: Equatable {
    /// Not attempted yet this launch, or nobody is signed in.
    case unknown
    /// A usable self key is registered with the SDK.
    case ok
    /// The lookup itself failed, so we do not know. Deliberately NOT treated as
    /// "no key on file" — that conflation would let a dropped connection at
    /// launch overwrite a perfectly good self key.
    case unreachable
    /// The server holds a self key and this device cannot unwrap it, AND
    /// personal tracking is not empty, so replacing it would destroy data.
    /// Never self-heals on iOS: `ensure()` refuses to mint over it every time.
    case undecryptable
    /// The SERVER refused the key this device tried to publish
    /// (`key_self_key_in_use`, 409): it already holds one with data under it.
    ///
    /// Distinct from `undecryptable`, which is THIS device's own refusal after
    /// failing to unwrap what the server sent. Here the client believed there
    /// was nothing to lose — the lookup returned no key, or returned one whose
    /// history looked empty — and the server, which can see personal check-ins
    /// and place wraps that `/latest` does not, disagreed. So the fact worth
    /// keeping is that the real key still EXISTS and is reachable: another
    /// device can re-publish it, and unlike `undecryptable` a later launch may
    /// simply fetch it. Nothing was installed locally, so a later launch is
    /// free to try — see `mintAndPublish`.
    case replacementRefused
    /// This device holds no account keys at all, so nothing personal can be
    /// opened or set up here. Only the account's password fixes that, and it is
    /// asked for right where this notice is shown — never "sign out and back
    /// in". Checked before anything else, so it is never taken for a broken
    /// personal setup.
    case noAccountKeys
    /// A new personal setup did not reach the server. Nothing was installed and
    /// nothing is lost; `SelfKeyManager` tries again by itself.
    case publishFailed
    /// The history here works, but this device can't check the account's
    /// published copy until its password is typed (the SDK's `NoSigningKey`):
    /// asked for in place in Settings, never as a prompt.
    case needsPassword
}

/// The two lines to show, and how loudly.
struct SelfKeyNotice: Equatable {
    enum Severity: Equatable {
        /// Informational — likely transient, nothing is broken yet.
        case warning
        /// The user has to do something, and nothing improves until they do.
        case error
    }

    let title: String
    let detail: String
    let severity: Severity
}

extension SelfKeyHealth {
    /// The notice for this state, or nil when there is nothing worth saying.
    ///
    /// Pure so the copy is testable without standing up Settings.
    var notice: SelfKeyNotice? {
        switch self {
        case .unknown, .ok:
            return nil

        case .undecryptable:
            // This repairs itself. This device reports the copy it can't
            // open; the server wakes the account's other devices, and the
            // one that holds the key republishes it; the next pass here
            // opens it. Said as what happens — no "Repair my other
            // devices", no "sign out and back in" — and honestly
            // conditional: it needs another device of theirs that has the
            // history.
            return SelfKeyNotice(
                title: "Can't show your location history yet",
                detail: "Your circles aren't affected — members still see you. "
                    + "Your personal history and personal places show here as soon as another of "
                    + "your devices that can show them is online.",
                severity: .error
            )

        case .replacementRefused:
            // Says the one thing that makes this actionable: nothing is
            // lost, it is on the server and on whichever device set it
            // up. A generic "couldn't set up" would send the user looking
            // for a fix on THIS device, where there isn't one.
            //
            // Unlike `undecryptable` this can clear itself — the refusal
            // proves the setup is stored, so the next lookup may well
            // return it — and the retry clock looks again by itself:
            // nobody is told to reopen anything.
            return SelfKeyNotice(
                title: "Location history isn't set up on this device",
                detail: "Your circles aren't affected — members still see you. "
                    + "Your account already has location history that this device wasn't allowed "
                    + "to replace, so personal history and personal places stay unreadable here "
                    + "and personal tracking isn't recording. This device keeps checking by itself, "
                    + "and it all shows here as soon as another of your devices that can show it is online.",
                severity: .error
            )

        case .noAccountKeys:
            // The one state a person must act on here: the password is theirs
            // alone. Settings shows the field right under this.
            return SelfKeyNotice(
                title: "Enter your password",
                detail: "This device needs your password to show your personal history and personal places. "
                    + "Nothing has been lost.",
                severity: .error
            )

        case .needsPassword:
            // Nothing is unreadable, so a note in Settings, not a Map banner.
            return SelfKeyNotice(
                title: "Enter your password",
                detail: "Your history is here. Enter your password so this device can keep it in step with "
                    + "your other devices.",
                severity: .warning
            )

        case .publishFailed:
            // Clears itself (`retriesItself`), so it says what happens and asks
            // nothing.
            return SelfKeyNotice(
                title: "Setting up your location history",
                detail: "Your personal history and personal places appear here as soon as this device "
                    + "reaches the server. Nothing has been lost.",
                severity: .warning
            )

        case .unreachable:
            // Says what was NOT done on purpose. `ensure()` fails closed here
            // rather than replacing anything, and a user who is told only
            // "couldn't check" has no way to know their history is intact.
            return SelfKeyNotice(
                title: "Couldn't check your location history",
                detail: "Your personal history and personal places may not load until this device "
                    + "reaches the server again. Nothing has been changed.",
                severity: .warning
            )
        }
    }
}

extension SelfKeyHealth {
    /// The password, asked for in place where this state is shown.
    var asksForPassword: Bool { self == .noAccountKeys || self == .needsPassword }

    /// A state that can clear itself, so the app tries again on its own clock
    /// (`SelfKeyManager.retryIfDue`) instead of asking anybody to reopen
    /// anything. The password state cannot: nothing changes until it is typed.
    var retriesItself: Bool {
        switch self {
        case .unreachable, .publishFailed, .replacementRefused, .undecryptable:
            return true
        case .unknown, .ok, .noAccountKeys, .needsPassword:
            return false
        }
    }

    /// Whether this state earns a banner on the Map as well as the row in
    /// Settings.
    ///
    /// Settings alone is a surface the user has to go looking for, and every
    /// state here is one they have no other way to discover — personal history
    /// simply looks empty. The Map already duplicates standing conditions for
    /// exactly that reason (see the location-permission banner: "The Settings
    /// tab has the same banner; duplicating it here means a user who only opens
    /// the Map tab still discovers the gap").
    ///
    /// The `.error` states only. `unreachable` clears itself on the next
    /// successful lookup, and a banner over the map on every flaky launch
    /// teaches the user to ignore the ones that matter.
    var deservesTopLevelSurface: Bool {
        notice?.severity == .error
    }
}

/// Observable holder so views can react to the last outcome. Written only by
/// `SelfKeyManager.ensure()`.
@MainActor
final class SelfKeyStatus: ObservableObject {
    static let shared = SelfKeyStatus()

    @Published private(set) var health: SelfKeyHealth = .unknown

    var notice: SelfKeyNotice? { health.notice }

    private init() {}

    func record(_ health: SelfKeyHealth) {
        self.health = health
    }
}
