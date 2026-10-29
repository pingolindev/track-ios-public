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
import Combine
import PingolinTrackSDK

extension Error {
    /// What a person reads about this failure: never text that is not this
    /// app's. An `APIError` is its plain line, by code — the server's
    /// `error`/`message` can carry key talk, or whatever a compromised server
    /// wants shown. The SDK's errors describe themselves as
    /// `MobileError.KeyNotFound(message: …)`: key talk, and a network one can
    /// carry the server's words. Everything else is this app's own words, or
    /// the system's.
    var plainText: String {
        if let api = self as? APIError { return api.plainLine }
        if let sdk = self as? PingolinTrackSDK.MobileError {
            if case .NetworkError = sdk { return APIError.unreachableText }
            return APIError.failedText
        }
        return localizedDescription
    }

    /// A load that was CANCELLED, not one that failed: a Task cancelled, or its
    /// URLSession request ended by that cancellation (`URLError.cancelled`, whose
    /// text is the system's "cancelled"). SwiftUI cancels a view's `.task` when
    /// its id changes, and the newer run does the work.
    var isCancellation: Bool {
        if self is CancellationError { return true }
        if let url = self as? URLError { return url.code == .cancelled }
        let ns = self as NSError
        return ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled
    }
}

/// Global transient-error surface. Managers (or anything else) post a
/// human message via `ErrorBanner.shared.post(...)` and a slide-in
/// notification renders at the top of RootView for `displayDuration`
/// seconds before auto-dismissing. Distinct from APIError throws so the
/// caller doesn't have to wrap every catch with UI code.
///
/// Special-cases the standard transient APIErrors APIService emits:
///   - code:"circuit_open" — show "Service paused while it recovers."
///   - code:"rate_limited"  — show "Too many requests, slow down a sec."
///   - URLError.notConnectedToInternet etc. — show "You're offline."
@MainActor
final class ErrorBanner: ObservableObject {
    static let shared = ErrorBanner()

    struct Banner: Equatable {
        let id: UUID
        let message: String
        let kind: Kind

        enum Kind: Equatable {
            case warning   // orange — recoverable, retry will likely work
            case error     // red — caller needs to act
            case info      // blue — neutral
        }
    }

    @Published private(set) var current: Banner?

    /// Auto-dismiss after this many seconds. Tap-to-dismiss is also
    /// wired in the SwiftUI overlay.
    let displayDuration: TimeInterval = 5

    private var dismissTask: Task<Void, Never>?

    private init() {}

    func post(_ message: String, kind: Banner.Kind = .warning) {
        let banner = Banner(id: UUID(), message: message, kind: kind)
        current = banner
        dismissTask?.cancel()
        dismissTask = Task { [weak self, displayDuration] in
            try? await Task.sleep(nanoseconds: UInt64(displayDuration * 1_000_000_000))
            await MainActor.run {
                guard let self = self, self.current?.id == banner.id else { return }
                self.current = nil
            }
        }
    }

    /// Convenience for catch-blocks: translate a thrown error into a
    /// human-readable banner. Returns nothing so callers can write
    /// `ErrorBanner.shared.post(error)` without ceremony.
    func post(_ error: Error) {
        // Nothing failed, so nothing is said. The map's `.task(id:)` runs
        // again once the active circle resolves, on every launch, and that
        // cancels the first run's `/places` request; reporting it would show
        // "cancelled" at the top on every opening of the app.
        if error.isCancellation { return }
        if let api = error as? APIError {
            switch api.code {
            case "circuit_open":
                post("Service paused while it recovers. Retrying soon.", kind: .warning)
                return
            case "rate_limited":
                post("Too many requests, slow down a moment.", kind: .warning)
                return
            case "unsupported":
                post("This action isn't available yet.", kind: .info)
                return
            case "unauthorized":
                // "Sign in again" only when the sign-in is
                // truly gone, and that has one caller
                // (`postSignedOut`). Any other 401 is a
                // request that raced a refresh or a sign-out,
                // and nothing the person does fixes it: the
                // loads behind it run again on their own
                // clock, and an action's own control snaps
                // back.
                return
            default:
                // Never the server's words: the app's own,
                // by code.
                post(api.plainLine, kind: .error)
                return
            }
        }
        if let urlError = error as? URLError, urlError.code == .notConnectedToInternet {
            post("You're offline. Showing cached data.", kind: .info)
            return
        }
        post(error.plainText, kind: .error)
    }

    /// The one time "sign in again" is true: the server refused this device's
    /// sign-in for good (`AuthManager.handleSessionRevoked`) and the sign-in
    /// screen is what comes next.
    func postSignedOut() {
        post(Self.signedOutText, kind: .error)
    }

    static let signedOutText = "Your session expired. Please sign in again."

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        current = nil
    }
}

/// SwiftUI overlay you wrap RootView with. Listens to ErrorBanner.shared
/// and slides the current banner down from the top when present.
struct ErrorBannerOverlay: ViewModifier {
    @ObservedObject private var banner = ErrorBanner.shared

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let current = banner.current {
                    BannerView(banner: current)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .onTapGesture { banner.dismiss() }
                }
            }
            .animation(.easeInOut(duration: 0.2), value: banner.current)
    }

    private struct BannerView: View {
        let banner: ErrorBanner.Banner

        var body: some View {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(.white)
                Text(banner.message)
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.leading)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        }

        private var icon: String {
            switch banner.kind {
            case .warning: return "exclamationmark.triangle.fill"
            case .error: return "xmark.octagon.fill"
            case .info: return "info.circle.fill"
            }
        }

        private var background: Color {
            switch banner.kind {
            case .warning: return .orange
            case .error: return .red
            case .info: return .blue
            }
        }
    }
}

extension View {
    /// Apply once near the root of your view tree so transient API
    /// errors surface uniformly across the app.
    func errorBannerOverlay() -> some View {
        modifier(ErrorBannerOverlay())
    }
}
