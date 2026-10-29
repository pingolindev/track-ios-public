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

/// Browse a circle's recent check-ins. Bound to the active circle from
/// CircleManager; defaults the time range to the last 30 days. Thin
/// wrapper over CheckInManager.loadCheckInHistory which walks the
/// cursor-paginated /api/v1/check-ins endpoint and decrypts each row.
struct CheckInHistoryView: View {
    @StateObject private var checkIns = CheckInManager.shared
    @StateObject private var circleManager = CircleManager.shared

    @State private var loaded: [CheckIn] = []
    @State private var isLoading = false
    @State private var loadError: String?

    var body: some View {
        Group {
            if loaded.isEmpty && !isLoading {
                emptyState
            } else {
                List(loaded) { row in
                    historyRow(row)
                }
            }
        }
        .navigationTitle("Check-in History")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if isLoading && loaded.isEmpty {
                ProgressView()
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    @ViewBuilder
    private func historyRow(_ row: CheckIn) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                SwiftUI.Circle()
                    .fill(typeColor(row.type).opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: row.type.icon)
                    .foregroundStyle(typeColor(row.type))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(row.type.displayName)
                    .font(.subheadline)
                    .fontWeight(.medium)
                if let message = row.message, !message.isEmpty {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text(row.timestamp, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "hand.wave")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(loadError ?? "No check-ins in the last 30 days")
                .font(.headline)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }

    private func typeColor(_ type: CheckIn.CheckInType) -> Color {
        switch type {
        case .safeArrival: return .green
        case .general: return .blue
        case .emergencyOk: return .mint
        }
    }

    private func load() async {
        guard let circle = circleManager.activeCircle else {
            loadError = "Pick an active circle from the Circles tab first."
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let to = Date()
            let from = to.addingTimeInterval(-30 * 86_400)
            loaded = try await checkIns.loadCheckInHistory(for: circle.id, from: from, to: to)
            loadError = nil
        } catch {
            loadError = "Couldn't load check-in history: \(error.plainText)"
        }
    }
}
