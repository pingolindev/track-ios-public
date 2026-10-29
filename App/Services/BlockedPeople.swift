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

/// One person this account has blocked from inviting it to a circle, as
/// `GET /api/v1/invites/blocks` lists them.
///
/// camelCase properties and no `CodingKeys`: the wire decoder converts from
/// snake case (`blocked_email`, `created_at`). The time stays a `String`:
/// nothing here does arithmetic on it.
struct BlockedPerson: Decodable, Equatable, Identifiable {
    let blockedEmail: String
    let createdAt: String?

    var id: String { blockedEmail.lowercased() }
}

/// The body of `POST /api/v1/invites/block`, and of `POST /api/v1/invites/unblock`:
/// the address, which is never part of a path.
struct BlockPersonRequest: Encodable, Equatable {
    let email: String
}

/// "Blocked people" in Settings: where a person adds an address whose
/// invitations they block.
///
/// What a block does is the server's work: a blocked person's invitation is
/// made and stays pending for THEM like any other, and the person who blocked
/// them never sees it and is never told. Here are the words, and the rules of
/// the field, apart from the screen so that each has a test.
enum BlockedPeople {
    // Pinned letter for letter by BlockedPeopleTests: user-facing copy
    // does not change without them. The description's "even after
    // changing their email address" holds because a block stays with
    // the person's account.
    static let title = "Blocked people"
    static let description = "People you block can't invite you to a circle, even after changing their email address. They are not notified."
    static let emailLabel = "Email address"
    static let block = "Block"
    static let unblock = "Unblock"
    static let empty = "You haven't blocked anyone."
    /// A full list.
    static let full = "Your list of blocked people is full. Unblock someone to add another."

    /// The server's code for a block refused because the list holds as many
    /// addresses as it may (a 409).
    static let listFullCode = "blocked_people_limit"

    /// Was a block refused because the list is full? By its CODE. Said as
    /// "Something went wrong", it would be tried again for ever: nothing is
    /// wrong, and nothing on the screen would say what to do.
    static func isListFull(_ error: Error) -> Bool {
        (error as? APIError)?.errorCode == listFullCode
    }

    /// What to say about a block that did not go through: a full list in its
    /// own words, anything else in the app's (`plainText`), never the server's.
    static func whyNotBlocked(_ error: Error) -> String {
        isListFull(error) ? full : error.plainText
    }

    /// The address "Block" would send, or nil while the field holds nothing
    /// that can be blocked:
    ///
    /// - the list has not been read yet (`blocked` is nil): nothing is blocked
    ///   on a guess of what is already there;
    /// - what is typed is not an address;
    /// - it is the person's own (the server refuses it);
    /// - it is on the list already, in any case.
    static func addressToBlock(_ typed: String, blocked: [BlockedPerson]?, ownEmail: String?) -> String? {
        guard let blocked else { return nil }
        let address = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard EmailFormat.isPlausible(address) else { return nil }
        let lower = address.lowercased()
        if let own = ownEmail?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), own == lower {
            return nil
        }
        if blocked.contains(where: { $0.blockedEmail.lowercased() == lower }) { return nil }
        return address
    }

    /// The list as it is shown: by address, whatever the case, so that it does
    /// not move about between two readings.
    static func inListOrder(_ blocked: [BlockedPerson]) -> [BlockedPerson] {
        blocked.sorted { $0.blockedEmail.lowercased() < $1.blockedEmail.lowercased() }
    }

    /// What an "Unblock" button says to someone who cannot see its row.
    static func unblockLabel(for person: BlockedPerson) -> String {
        "\(unblock) \(person.blockedEmail)"
    }
}
