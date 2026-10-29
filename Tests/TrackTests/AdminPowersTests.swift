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

import XCTest
@testable import Track

/// What an admin may do on the iPhone is what the server allows: the owner
/// and admins invite, manage invitations and remove members; only the owner
/// changes roles, hands the circle over or deletes it.
///
/// WHY THIS IS WORTH TESTING
///   The app must offer exactly what the server allows. A plain member
///   offered Invite only meets the server's refusal ("You don't have
///   permission to do that."), and an admin must be offered Remove, which the
///   server allows: eject-and-rotate and revoke-access go by
///   `can_rotate_keys`, which the owner and admins hold, for anyone but the
///   owner. Admins see and revoke the circle's invitations: that list is the
///   server's owner-or-admin answer.
@MainActor
final class AdminPowersTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func memberRow() throws -> String {
        let view = try source("App/Views/Circles/CirclesView.swift")
        let start = try XCTUnwrap(view.range(of: "struct MemberRow: View {"))
        let end = try XCTUnwrap(view.range(of: "\nstruct ", range: start.upperBound..<view.endIndex))
        return String(view[start.lowerBound..<end.lowerBound])
    }

    /// Removal is the owner's or an admin's, never of the owner or oneself;
    /// roles and the hand-over stay the owner's.
    func testWhoMayRemoveAndWhoMayChangeRoles() throws {
        let row = try memberRow()
        XCTAssertTrue(row.contains("""
            private var canRemove: Bool {
                !isCurrentUser && member.role != .owner && circleManager.isOwnerOrAdmin(circle)
            }
        """))
        XCTAssertTrue(row.contains("""
            private var canManage: Bool {
                !isCurrentUser && circle.isOwner && member.role != .owner
            }
        """), "roles and the hand-over: the owner only")
        // The menu: the owner's part, then the owner's or an admin's removal.
        let manage = try XCTUnwrap(row.range(of: "                if canManage {\n"))
        let transfer = try XCTUnwrap(row.range(of: "Button(\"Transfer Ownership\") {"))
        let remove = try XCTUnwrap(row.range(of: """
                        }
                        if canRemove {
                            Button("Remove from Circle", role: .destructive) {
        """))
        XCTAssertLessThan(manage.lowerBound, transfer.lowerBound)
        XCTAssertLessThan(transfer.lowerBound, remove.lowerBound)
        XCTAssertEqual(row.components(separatedBy: "Button(\"Remove from Circle\", role: .destructive)").count - 1, 1)
        XCTAssertTrue(row.contains("            if canSeeSecurity || canManage || canRemove {\n"), "the menu opens for an admin too")
        // Who counts as an admin: this account's own roster row (or the owner).
        let manager = try source("App/Managers/CircleManager.swift")
        XCTAssertTrue(manager.contains("""
            func isOwnerOrAdmin(_ circle: Circle) -> Bool {
                if circle.isOwner { return true }
                guard let me = AuthManager.shared.userId,
                      let mine = members[circle.id]?.first(where: { $0.userId == me }) else { return false }
                return mine.role == .owner || mine.role == .admin
            }
        """))
    }

    /// An invitation counts where its signer is the circle's owner or an admin
    /// on the server, and, on a circle with records, in its chain as well (the
    /// other apps take an invitee in on a statement signed by an owner or
    /// admin in the chain); nothing while the records wait.
    func testAnInvitationIsOfferedWhereItCounts() {
        XCTAssertTrue(CircleManager.invitesTakeEffect(serverOwnerOrAdmin: true, standing: .noRecords, chainOwnerOrAdmin: false))
        XCTAssertTrue(CircleManager.invitesTakeEffect(serverOwnerOrAdmin: true, standing: .recorded, chainOwnerOrAdmin: true))
        XCTAssertFalse(CircleManager.invitesTakeEffect(serverOwnerOrAdmin: true, standing: .recorded, chainOwnerOrAdmin: false),
                       "a server-only admin's invitee would wait for a chain admin")
        XCTAssertFalse(CircleManager.invitesTakeEffect(serverOwnerOrAdmin: true, standing: .wait, chainOwnerOrAdmin: true))
        XCTAssertFalse(CircleManager.invitesTakeEffect(serverOwnerOrAdmin: false, standing: .noRecords, chainOwnerOrAdmin: true),
                       "a plain member: the server refuses")
    }

    /// Invite is offered to the owner and admins only: a plain member is
    /// offered nothing that can only fail.
    func testOnlyTheOwnerAndAdminsAreOfferedInvite() throws {
        let view = try source("App/Views/Circles/CirclesView.swift")
        XCTAssertTrue(view.contains("""
                .toolbar {
                    // The owner and admins invite: the server refuses anyone
                    // else, so a plain member is offered nothing that can only
                    // fail; and on a circle with records only where the
                    // invitation counts (`invitesTakeEffect`).
                    if circleManager.invitesTakeEffect(circle) {
                        ToolbarItem(placement: .primaryAction) {
                            Button(action: { showingInvite = true }) {
                                Image(systemName: "person.badge.plus")
                            }
                            // Named for VoiceOver as the sheet it opens.
                            .accessibilityLabel("Invite Member")
                        }
                    }
                }
        """))
        XCTAssertEqual(view.components(separatedBy: "showingInvite = true").count - 1, 1, "the one way into the invite sheet")
        XCTAssertTrue(view.contains("            .navigationTitle(\"Invite Member\")\n"), "the label names the sheet it opens")
        let rule = try source("App/Managers/CircleManager.swift")
        XCTAssertTrue(rule.contains("""
                Self.invitesTakeEffect(serverOwnerOrAdmin: isOwnerOrAdmin(circle), standing: standing(of: circle.id),
                                       chainOwnerOrAdmin: removesInTheChain(circle.id))
        """))
        // The circle's invitations: read for everyone, and the server answers
        // the owner and admins only (a member's 403 shows nothing).
        let manager = try source("App/Managers/CircleManager.swift")
        XCTAssertTrue(manager.contains("""
                do {
                    let invites = try await api.pendingInvites(circleId: circleId)
                    pendingInvites[circleId] = invites
        """))
    }
}
