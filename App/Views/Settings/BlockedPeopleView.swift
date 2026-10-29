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

/// The state of the "Blocked people" screen, apart from the screen so that it
/// has tests. The three requests are handed in; the app's are `Calls.live`.
@MainActor
final class BlockedPeopleViewModel: ObservableObject {
    /// The requests the screen makes.
    struct Calls {
        var list: () async throws -> [BlockedPerson]
        var block: (String) async throws -> Void
        var unblock: (String) async throws -> Void

        static let live = Calls(
            list: { try await APIService.shared.listBlockedPeople() },
            block: { _ = try await APIService.shared.blockPerson(email: $0) },
            unblock: { _ = try await APIService.shared.unblockPerson(email: $0) }
        )
    }

    /// Nil until the list has been READ. A list that could not be read is
    /// never shown as "You haven't blocked anyone".
    @Published private(set) var people: [BlockedPerson]?
    /// A block or an unblock is on its way.
    @Published private(set) var busy = false
    /// What to say about a request that did not go through, in the app's own
    /// words (`plainText`), or nil.
    @Published private(set) var failure: String?
    @Published var typed = ""

    private let calls: Calls
    private let ownEmail: @MainActor () -> String?

    init(calls: Calls = .live,
         ownEmail: @escaping @MainActor () -> String? = { AuthManager.shared.currentUser?.email }) {
        self.calls = calls
        self.ownEmail = ownEmail
    }

    /// The address "Block" would send now, or nil (see `BlockedPeople.addressToBlock`).
    var addressReady: String? {
        BlockedPeople.addressToBlock(typed, blocked: people, ownEmail: ownEmail())
    }

    var canBlock: Bool { addressReady != nil && !busy }

    /// Reads the list. True when it was read: the screen tries again by itself
    /// until then (`RetryClock.untilDone`), so nobody is asked to press "retry".
    @discardableResult
    func load() async -> Bool {
        do {
            people = try await calls.list()
            return true
        } catch {
            return false
        }
    }

    /// Blocks what is typed. The field is emptied only when the server took it.
    func blockTyped() async {
        guard !busy, let address = addressReady else { return }
        busy = true
        failure = nil
        defer { busy = false }
        do {
            try await calls.block(address)
        } catch {
            failure = BlockedPeople.whyNotBlocked(error)
            return
        }
        typed = ""
        // The server took it: the address is on the list, whatever the reading
        // that follows says (it can fail, or be a moment behind).
        let listed = try? await calls.list()
        var next = listed ?? people ?? []
        if !next.contains(where: { $0.blockedEmail.lowercased() == address.lowercased() }) {
            next.append(BlockedPerson(blockedEmail: address.lowercased(), createdAt: nil))
        }
        people = next
    }

    func unblock(_ person: BlockedPerson) async {
        guard !busy else { return }
        busy = true
        failure = nil
        defer { busy = false }
        do {
            try await calls.unblock(person.blockedEmail)
        } catch {
            failure = error.plainText
            return
        }
        people = people?.filter { $0.id != person.id }
    }
}

/// Settings → Blocked people. The same screen as the web client's
/// dialog and the Android app's.
struct BlockedPeopleView: View {
    @StateObject private var model = BlockedPeopleViewModel()

    var body: some View {
        List {
            Section {
                Text(BlockedPeople.description)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                HStack {
                    TextField(BlockedPeople.emailLabel, text: $model.typed)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit { Task { await model.blockTyped() } }
                    Button(BlockedPeople.block) {
                        Task { await model.blockTyped() }
                    }
                    .buttonStyle(.borderless)
                    .disabled(!model.canBlock)
                }
                if let failure = model.failure {
                    Text(failure)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            Section {
                if let people = model.people {
                    if people.isEmpty {
                        Text(BlockedPeople.empty)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(BlockedPeople.inListOrder(people)) { person in
                            HStack {
                                Text(person.blockedEmail)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Button(BlockedPeople.unblock) {
                                    Task { await model.unblock(person) }
                                }
                                .buttonStyle(.borderless)
                                .disabled(model.busy)
                                .accessibilityLabel(BlockedPeople.unblockLabel(for: person))
                            }
                        }
                    }
                } else {
                    // Not read yet: neither a list nor "nobody".
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                }
            }
        }
        .navigationTitle(BlockedPeople.title)
        .navigationBarTitleDisplayMode(.inline)
        // Tried again by itself until it loads, while the screen is open.
        .task { await RetryClock.untilDone { await model.load() } }
    }
}
