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

/// The days of a scheduled check-in rule: one button a day, Monday first, each
/// read out by its full name and as selected or not.
struct CheckInDayPicker: View {
    /// Bit 0 = Monday ... bit 6 = Sunday.
    @Binding var days: Int

    private static let letters = ["M", "T", "W", "T", "F", "S", "S"]
    private static let names = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<7, id: \.self) { index in
                let on = days & (1 << index) != 0
                Button {
                    days ^= 1 << index
                } label: {
                    Text(Self.letters[index])
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundStyle(on ? Color.white : Color.primary)
                        .background(on ? Color.a11yAccent : Color.secondary.opacity(0.15), in: Capsule())
                }
                // Several buttons in one row: each takes its own taps.
                .buttonStyle(.borderless)
                .accessibilityLabel(Self.names[index])
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }
}

/// A zone to pick, by city ("New York"), this phone's own first, searchable.
struct TimeZonePickerView: View {
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    /// This phone's zone first, then every zone this device knows by city.
    static func zones(matching query: String, phone: String = TimeZone.autoupdatingCurrent.identifier) -> [String] {
        let all = TimeZone.knownTimeZoneIdentifiers
            .filter { $0 != phone }
            .sorted { CheckInSchedule.zoneName($0) < CheckInSchedule.zoneName($1) }
        let listed = [phone] + all
        let wanted = query.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty else { return listed }
        return listed.filter {
            CheckInSchedule.zoneName($0).localizedCaseInsensitiveContains(wanted)
                || $0.localizedCaseInsensitiveContains(wanted)
        }
    }

    var body: some View {
        List(Self.zones(matching: query), id: \.self) { zone in
            Button {
                selection = zone
                dismiss()
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(CheckInSchedule.zoneName(zone)).foregroundStyle(.primary)
                        Text(zone).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if zone == selection {
                        Image(systemName: "checkmark").foregroundStyle(Color.a11yLink)
                    }
                }
            }
            .accessibilityAddTraits(zone == selection ? .isSelected : [])
        }
        .searchable(text: $query)
        .navigationTitle("Time zone")
        .navigationBarTitleDisplayMode(.inline)
    }
}
