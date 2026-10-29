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
import CoreLocation

/// Edge arrows for active SOS alerts outside the current viewport.
///
/// An off-screen marker has, by definition, no on-screen map coordinate to
/// attach to — the position is a screen-space construction: a ray from the
/// viewport centre in the compass direction of the alert, clipped to the
/// viewport rectangle. So it lives in the view hierarchy above the map rather
/// than in the annotation system.
struct SOSEdgeIndicatorOverlay: View {
    let indicators: [SOSEdgeIndicator]
    let onTap: (String) -> Void

    private let edgeInset: CGFloat = 28
    private let badgeRadius: CGFloat = 20

    var body: some View {
        GeometryReader { geo in
            ForEach(indicators) { indicator in
                let position = edgePosition(
                    bearingDegrees: indicator.screenBearingDegrees,
                    in: geo.size
                )
                ZStack {
                    // SwiftUI.Circle, spelled out: the app defines its own
                    // `Circle` model (Models.swift), which shadows the shape
                    // inside this module.
                    SwiftUI.Circle()
                        .fill(Color.red)
                        .overlay(SwiftUI.Circle().strokeBorder(.white, lineWidth: 2.5))
                        .frame(width: badgeRadius * 2, height: badgeRadius * 2)
                    // Warning triangle rather than the word "SOS". This badge
                    // is 40pt across and ships no localized strings, so a glyph
                    // is the only thing that reads in every locale — and it
                    // claims attention without claiming rescue.
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 15, weight: .heavy))
                        .foregroundStyle(.white)
                    // Chevron just outside the badge, aimed along the bearing.
                    Image(systemName: "arrowtriangle.up.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .offset(y: -(badgeRadius + 9))
                        .rotationEffect(.degrees(indicator.screenBearingDegrees))
                }
                .position(position)
                .contentShape(SwiftUI.Circle())
                .onTapGesture { onTap(indicator.sosId) }
                .accessibilityLabel("Active circle notification off screen — tap to show")
            }
        }
        .allowsHitTesting(!indicators.isEmpty)
    }

    /// Cast a ray from the centre along `bearingDegrees` (0 = up the screen,
    /// increasing clockwise) and return where it meets the inset viewport.
    ///
    /// Solved per-axis rather than by walking the ray: for each axis the
    /// distance at which the ray crosses that boundary is one division, and the
    /// smaller of the two is the edge actually hit.
    private func edgePosition(bearingDegrees: Double, in size: CGSize) -> CGPoint {
        let cx = size.width / 2
        let cy = size.height / 2
        let halfW = max(cx - edgeInset, 1)
        let halfH = max(cy - edgeInset, 1)

        let radians = bearingDegrees * .pi / 180
        let dx = CGFloat(sin(radians))
        // Screen y grows downward while north is up, hence the negation.
        let dy = CGFloat(-cos(radians))

        // A perfectly axis-aligned direction has a zero component; guard the
        // division rather than special-casing the four cardinal bearings.
        let tx = abs(dx) < 1e-6 ? CGFloat.greatestFiniteMagnitude : halfW / abs(dx)
        let ty = abs(dy) < 1e-6 ? CGFloat.greatestFiniteMagnitude : halfH / abs(dy)
        let t = min(tx, ty)

        return CGPoint(x: cx + dx * t, y: cy + dy * t)
    }
}

/// Detail sheet for an SOS marker: who, when, where, and a private Dismiss.
///
/// Everything here is resolved on device. The server holds the alert's
/// timestamp and location encrypted and cannot supply either, so the time comes
/// from the decrypted alert and the address from an on-device reverse geocode.
struct SOSDetailSheet: View {
    /// The alert as the sheet opened on it; `live` follows the store, so a
    /// position the raiser's phone updates moves here too.
    let alert: SOSAlert
    let memberName: String?
    let onDismissAlert: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var address: String?
    @State private var addressResolved = false
    @StateObject private var sosManager = SOSManager.shared
    /// Watched so the responders are named once their names open.
    @StateObject private var circleManager = CircleManager.shared

    private var live: SOSAlert {
        sosManager.activeAlerts.first { $0.id == alert.id } ?? alert
    }

    private var isMine: Bool {
        alert.userId == AuthManager.shared.userId
    }

    private var title: String {
        if isMine { return "You asked for attention" }
        return "\(memberName ?? "A circle member") asked for attention"
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    SwiftUI.Circle()
                        .fill(Color.red)
                        .frame(width: 12, height: 12)
                    Text(title)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.red)
                }

                // Absolute clock time AND elapsed. "23:02" alone is useless
                // when you've just woken to the notification; "8 minutes ago"
                // alone is useless when relaying it to somebody else.
                Text("Triggered \(live.createdAt.formatted(date: .omitted, time: .shortened)) · \(live.createdAt.formatted(.relative(presentation: .named)))")
                    .font(.subheadline)

                // How old the position is, or that it is still on its way,
                // so nobody reads a last-known pin as live.
                if let line = SOSPositionText.line(live.positionReading()) {
                    Text(line).font(.subheadline)
                } else if live.coordinate == nil {
                    Text(SOSPositionText.noPosition)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if let address, !live.hasApproximatePosition {
                    Text(address).font(.subheadline)
                } else if !addressResolved {
                    Text("Looking up address…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                // An area has no precise point to give.
                if let area = live.positionAreaMeters, live.coordinate != nil {
                    Text(SOSPositionText.within(area))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let coordinate = live.coordinate, !live.hasApproximatePosition {
                    Text(String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Who is responding, on the raiser's own alert;
                // everyone else's view stays a count.
                if isMine, let responding = sosManager.respondingLine(for: live) {
                    Text(responding)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if live.acknowledgmentCount > 0 {
                    Text("^[\(live.acknowledgmentCount) member](inflect: true) acknowledged")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button(role: .destructive) {
                    onDismissAlert()
                    dismiss()
                } label: {
                    Text("Dismiss").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .padding(.top, 4)

                // Dismissal is private and closes nothing: say so, so nobody
                // dismisses expecting it to stand the emergency down.
                Text("Dismissing only hides this for you. Other members still see the alert, and it stays active.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Spacer()
            }
            .padding(20)
            .navigationTitle("Needs attention")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        // Keyed on the alert's position: an update resolves the address again.
        .task(id: live.positionKey) {
            address = nil
            addressResolved = false
            guard let coordinate = live.coordinate, !live.hasApproximatePosition else {
                addressResolved = true
                return
            }
            let result = await GeocodingService.shared.reverse(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude
            )
            // An emergency callout that says "1500 McHenry Avenue" without
            // saying WHICH McHenry Avenue is the case this has to survive, and
            // `text` carries the locality only when the tiles answered.
            address = result.flatMap { AddressFormat.placardAddress($0, withPOIName: true) }
            addressResolved = true
        }
    }
}
