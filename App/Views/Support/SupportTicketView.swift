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

/// Open a support ticket. Mirrors the Android app's
/// SupportTicketFragment: subject + message form, send button,
/// success/error state. Posts to the auth API's POST
/// /api/v1/support/ticket, which opens a support conversation
/// server-side.
struct SupportTicketView: View {
    @State private var subject: String = ""
    @State private var message: String = ""
    @State private var state: FormState = .idle
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                TextField("Subject", text: $subject)
                    .textInputAutocapitalization(.sentences)
                    .disabled(state == .submitting || state.succeeded)
            } footer: {
                Text("A short summary of what you need help with.")
            }

            Section {
                TextEditor(text: $message)
                    .frame(minHeight: 160)
                    .disabled(state == .submitting || state.succeeded)
            } header: {
                Text("Message")
            } footer: {
                Text("Detail what's going on. Logs and your account info ride along automatically.")
            }

            Section {
                Button {
                    Task { await submit() }
                } label: {
                    HStack {
                        if state == .submitting {
                            ProgressView().padding(.trailing, 4)
                        }
                        Text(state == .submitting ? "Sending…" : "Send")
                    }
                    .frame(maxWidth: .infinity)
                }
                .disabled(!canSubmit)
            }

            switch state {
            case .error(let msg):
                Section {
                    Label(msg, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            case .success(let ticketId):
                Section {
                    Label("Ticket #\(ticketId) created", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Text("We'll email a reply when one of our humans picks this up.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            default:
                EmptyView()
            }
        }
        .navigationTitle("Contact Support")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if state.succeeded {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var canSubmit: Bool {
        guard state != .submitting && !state.succeeded else { return false }
        return !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() async {
        let trimmedSubject = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        state = .submitting
        do {
            let response = try await APIService.shared.submitSupportTicket(
                subject: trimmedSubject,
                message: trimmedMessage
            )
            state = .success(ticketId: response.ticketId)
        } catch let apiError as APIError {
            state = .error(apiError.plainLine)
        } catch {
            state = .error(error.plainText)
        }
    }

    enum FormState: Equatable {
        case idle
        case submitting
        case success(ticketId: Int)
        case error(String)

        var succeeded: Bool {
            if case .success = self { return true }
            return false
        }
    }
}
