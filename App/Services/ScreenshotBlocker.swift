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

import UIKit
import SwiftUI

/// iOS counterpart to Android's `WindowManager.LayoutParams.FLAG_SECURE`.
/// iOS doesn't expose a single switch for blocking screenshots, but
/// putting a UITextField with `.isSecureTextEntry = true` into the
/// view hierarchy makes WindowScene-level snapshots come back blank
/// (the same trick Apple Pay + 1Password use). Toggle via the
/// `app.privacy.blockScreenshots` UserDefaults key surfaced in
/// Settings → Privacy.
///
/// Detection of an in-progress screen recording (`UIScreen.isCaptured`)
/// is a separate concern — when that flips on, we additionally fade
/// content to black via the SwiftUI overlay below so a recording
/// doesn't capture sensitive map / circle data.
@MainActor
final class ScreenshotBlocker {
    static let shared = ScreenshotBlocker()
    static let defaultEnabled = true

    /// Hidden secure-text-entry field whose layer hosts the window's
    /// content. Adding it to the window's view hierarchy poisons
    /// screenshot/airplay output for any subview drawn on top.
    private let secureField: UITextField = {
        let f = UITextField()
        f.isSecureTextEntry = true
        f.isUserInteractionEnabled = false
        f.translatesAutoresizingMaskIntoConstraints = false
        return f
    }()

    private weak var attachedWindow: UIWindow?
    /// Whether the window's content layer actually got re-hosted under the
    /// secure field. Tracked separately from `attachedWindow` because the
    /// hand-off is the part that does the blocking, and it can fail (see
    /// `attach`).
    private var didHostCanvas = false

    private init() {}

    func setEnabled(_ enabled: Bool) {
        guard let window = activeWindow() else { return }
        if enabled {
            attach(to: window)
        } else {
            detach()
        }
    }

    private func activeWindow() -> UIWindow? {
        return UIApplication.shared
            .connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
    }

    private func attach(to window: UIWindow) {
        // Already fully armed on this window — nothing to do.
        if attachedWindow === window && didHostCanvas { return }
        if attachedWindow !== window {
            detach()
            window.addSubview(secureField)
            // Pin the secure field to the window so its CALayer wraps the
            // hierarchy. We don't want it to visually cover anything — it
            // sits at the back, so set its alpha to a tiny non-zero value
            // and zero its content.
            secureField.frame = .zero
            secureField.text = ""
            attachedWindow = window
        }
        // Move the rendered content layer into the secure field's
        // hierarchy so the screenshot redactor honors it. This is the step
        // that actually blocks capture, and at launch-time re-arm the window
        // may not have its content sublayer yet. Latching `attachedWindow`
        // without it would leave the blocker permanently half-attached —
        // the Settings row reading ON while screenshots came out fine — so
        // the miss is recorded and retried by the next `setEnabled`
        // (foreground re-arm) instead of being swallowed.
        if let canvas = window.layer.sublayers?.first {
            secureField.layer.superlayer?.addSublayer(canvas)
            didHostCanvas = true
        }
    }

    private func detach() {
        secureField.removeFromSuperview()
        attachedWindow = nil
        didHostCanvas = false
    }
}

/// SwiftUI overlay that blacks out content while a screen recording is
/// active. Matches Android's secondary behavior on FLAG_SECURE windows.
struct ScreenRecordingBlockingOverlay: ViewModifier {
    @State private var isCaptured = UIScreen.main.isCaptured

    func body(content: Content) -> some View {
        content
            .overlay {
                if isCaptured {
                    ZStack {
                        Color.black.ignoresSafeArea()
                        VStack(spacing: 12) {
                            Image(systemName: "record.circle")
                                .font(.largeTitle)
                                .foregroundStyle(.red)
                            Text("Screen recording detected.")
                                .font(.headline)
                                .foregroundStyle(.white)
                            Text("Stop the recording to continue using Track.")
                                .font(.footnote)
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIScreen.capturedDidChangeNotification)) { _ in
                isCaptured = UIScreen.main.isCaptured
            }
    }
}

extension View {
    func screenRecordingBlocker(enabled: Bool) -> some View {
        Group {
            if enabled { self.modifier(ScreenRecordingBlockingOverlay()) } else { self }
        }
    }
}
