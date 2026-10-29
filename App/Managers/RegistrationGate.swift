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

/// The account's approval, from GET /auth/me's `registration_status`, and the
/// auth server's own answer for Track, `track_access`, when it serves one.
///
/// An assisted-lane account waits for an admin ("pending"), and one turned down
/// stays "rejected" until the auth server deletes it, 30 days after the
/// decision. The auth server gives a token Track's audience only when the
/// account's email is verified and its registration status is "approved".
/// Everyone else's token gets `aud` ["auth"]: it reaches the account service
/// alone, and Track refuses every call. Such an account gets its own screen and
/// nothing of Track's runs: no circles, no device registration, no location
/// stream, no location tracking.
///
/// `track_access` is that same decision, served as the auth server computes it,
/// so the phone holds exactly what Track refuses. Without it the status alone
/// decides: /auth/me's `email_verified` is the signed-in credential's, not the
/// account's that the token decision reads, and the two differ when a
/// verification's credential update fails.
///
/// Kept in UserDefaults, so a launch that has no answer from /auth/me yet
/// (offline, or a headless relaunch) still holds the gate. The server is
/// authoritative: every /auth/me read that answers replaces both, and one that
/// fails changes nothing kept. Read from any thread.
enum RegistrationGate {
    enum Status: String, Equatable {
        case approved, pending, rejected
    }

    static let defaultsKey = "auth.registrationStatusCached"
    static let trackAccessKey = "auth.trackAccessCached"

    /// Pure: the status /auth/me served. No field at all (a server without
    /// approvals) is approved; any word but the three is not approved yet,
    /// since the auth server gives full access to "approved" alone.
    static func served(_ status: String?) -> Status {
        guard let status else { return .approved }
        return Status(rawValue: status.lowercased()) ?? .pending
    }

    /// Pure: auth's own answer when it serves one, the status rule otherwise.
    static func allows(_ status: Status, trackAccess: Bool?) -> Bool {
        trackAccess ?? (status == .approved)
    }

    /// The status this device last read: approved when it read none.
    static var current: Status {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(Status.init(rawValue:)) ?? .approved
    }

    /// Auth's answer as this device last read it; nil when it served none.
    static var trackAccess: Bool? {
        UserDefaults.standard.object(forKey: trackAccessKey) as? Bool
    }

    /// THE predicate: whether anything of Track's may run on this device now
    /// (tracking, the location stream, Track's calls).
    static var allowsTrack: Bool { allows(current, trackAccess: trackAccess) }

    /// What this device knows, for a resume that runs before any /auth/me read
    /// (a headless relaunch).
    enum Knowledge: Equatable {
        case allowed, refused
        /// Nothing kept, though it could have been read: never written, as
        /// after an update from a version without the gate. Read /auth/me first.
        case unread
    }

    /// Pure: nothing kept is `unread` only once it could have been read, after
    /// the first unlock since a restart. Before it nothing reads at all, the
    /// tokens included, so the answer is `allowed`.
    static func knowledge(status: String?, trackAccess: Bool?, protectedDataAvailable: Bool) -> Knowledge {
        guard let status else { return protectedDataAvailable ? .unread : .allowed }
        return allows(served(status), trackAccess: trackAccess) ? .allowed : .refused
    }

    static func knowledge(protectedDataAvailable: Bool) -> Knowledge {
        knowledge(status: UserDefaults.standard.string(forKey: defaultsKey), trackAccess: trackAccess,
                  protectedDataAvailable: protectedDataAvailable)
    }

    static func keep(_ status: Status) {
        UserDefaults.standard.set(status.rawValue, forKey: defaultsKey)
    }

    static func keep(trackAccess: Bool?) {
        if let trackAccess {
            UserDefaults.standard.set(trackAccess, forKey: trackAccessKey)
        } else {
            UserDefaults.standard.removeObject(forKey: trackAccessKey)
        }
    }

    /// Sign-out: the next account is read afresh.
    static func clear() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        UserDefaults.standard.removeObject(forKey: trackAccessKey)
    }
}
