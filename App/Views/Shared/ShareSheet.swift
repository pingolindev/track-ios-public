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
import UIKit

/// UIActivityViewController bridge for SwiftUI. Use via the
/// `.shareSheet(item:)` modifier; passing a non-nil item presents
/// the system share UI with that item, and resets the binding when
/// the user dismisses.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct ShareSheetItem: Identifiable, Equatable {
    let id = UUID()
    let items: [String]

    static func == (lhs: ShareSheetItem, rhs: ShareSheetItem) -> Bool { lhs.id == rhs.id }
}

extension View {
    /// Drop-in helper: pass a binding to a `ShareSheetItem?` and call
    /// `binding.wrappedValue = ShareSheetItem(items: [...])` to present.
    func shareSheet(item: Binding<ShareSheetItem?>) -> some View {
        self.sheet(item: item) { wrapped in
            ShareSheet(items: wrapped.items)
        }
    }
}
