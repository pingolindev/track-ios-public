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
import UserNotifications

/// First-launch walkthrough: a coherent four-page sequence that
/// explains *why* each permission is asked before the system dialog
/// appears.
///
/// Persisted via @AppStorage("onboarding.complete"); once set, RootView
/// skips straight to MainTabView for subsequent launches. Reset via
/// AuthManager.logout if the user signs out.
struct OnboardingView: View {
    @AppStorage("onboarding.complete") private var onboardingComplete = false

    @State private var currentPage = 0

    /// Observed so the Location page can offer the background step only once
    /// When-in-Use has actually been granted. iOS ignores a
    /// `requestAlwaysAuthorization` made from `.notDetermined` in a way that
    /// still spends the one-shot prompt, so "has it been granted yet" is a
    /// question this screen has to be able to answer rather than assume.
    @StateObject private var locationService = LocationService.shared

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $currentPage) {
                welcomePage.tag(0)
                locationPage.tag(1)
                notificationsPage.tag(2)
                motionPage.tag(3)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            HStack {
                if currentPage > 0 {
                    Button("Back") {
                        withAnimation { currentPage -= 1 }
                    }
                }
                Spacer()
                Button(currentPage == 3 ? "Get Started" : "Next") {
                    if currentPage < 3 {
                        withAnimation { currentPage += 1 }
                    } else {
                        onboardingComplete = true
                        // First-run hook: poke CoreLocation so we have
                        // a fix ready when MapView appears; the map
                        // wrapper's `didUpdate userLocation` then
                        // auto-centers on it. Best-effort — failures
                        // are silent.
                        //
                        // This button does NOT request Always: the
                        // strongest grant in the product must not be
                        // asked for by a control labelled "Get
                        // Started". The escalation lives on the
                        // Location page, behind its own labelled
                        // control, and only appears once When-in-Use
                        // has been granted — which is also the only
                        // state iOS will actually raise the Always
                        // dialog from.
                        Task {
                            _ = try? await LocationService.shared.requestSingleLocation()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
    }

    // MARK: - Pages

    private var welcomePage: some View {
        OnboardingPage(
            icon: "paperplane.fill",
            iconColor: .blue,
            title: "Welcome to Track",
            subtitle: "Share your location with the people you choose, encrypted end-to-end. The server can't read where you are or who you're sharing with.",
            actionTitle: nil,
            actionHandler: nil
        )
    }

    /// Whether iOS will actually show the Always dialog if we ask now.
    ///
    /// Only `.authorizedWhenInUse` can raise it. From `.notDetermined` the call
    /// is a no-op that still burns the one-shot, and from `.authorizedAlways`
    /// there is nothing to ask for — so the control is offered in exactly one
    /// state rather than always.
    private var canEscalateToAlways: Bool {
        locationService.authorizationStatus == .authorizedWhenInUse
    }

    private var locationPage: some View {
        OnboardingPage(
            icon: "location.fill",
            iconColor: .blue,
            title: "Location",
            // What this page can honestly promise. The detail about who reads
            // it, which vendors carry it and how long it is kept belongs to the
            // notice shown when a circle is created or joined
            // (LocationConsentView) — this is a permission prompt, and at this
            // point in the flow there is no circle to name recipients for.
            subtitle: "Track needs your location to share it with the circles you choose. Nothing is shared until you create or join one, and we'll tell you exactly what leaves your phone before that happens.",
            actionTitle: "Allow Location",
            actionHandler: {
                LocationService.shared.requestAuthorization()
            },
            // The background grant, as its own step with its own words. Appears
            // only once the first has been granted.
            secondaryTitle: canEscalateToAlways ? "Keep sharing in the background" : nil,
            secondaryCaption: "Lets your circle stay up to date while Track is closed. You can skip this and Track still shares while the app is open.",
            secondaryHandler: {
                LocationService.shared.requestAlwaysAuthorization()
            }
        )
    }

    private var notificationsPage: some View {
        OnboardingPage(
            icon: "bell.badge.fill",
            iconColor: .orange,
            title: "Notifications",
            subtitle: "We notify you when a family member notifies their circle, arrives at a place you care about, or checks in. You can fine-tune which alerts you receive in Settings.",
            actionTitle: "Allow Notifications",
            actionHandler: {
                Task { await PushNotificationManager.shared.requestAuthorization() }
            }
        )
    }

    private var motionPage: some View {
        OnboardingPage(
            icon: "figure.walk.motion",
            iconColor: .green,
            title: "Motion (Optional)",
            subtitle: "If you allow motion, Track notices the moment you start moving and shares a fresh location right away, instead of your circle waiting for the next update. We never collect or upload motion data itself.",
            actionTitle: "Allow Motion",
            actionHandler: {
                MotionDetectionManager.shared.start()
            }
        )
    }
}

private struct OnboardingPage: View {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String
    let actionTitle: String?
    let actionHandler: (() -> Void)?
    /// An optional second, weaker-by-default step on the same page. Nil hides it
    /// entirely, which is how every page except Location renders.
    var secondaryTitle: String? = nil
    var secondaryCaption: String? = nil
    var secondaryHandler: (() -> Void)? = nil

    @State private var actionRan = false
    @State private var secondaryRan = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            ZStack {
                SwiftUI.Circle()
                    .fill(iconColor.opacity(0.15))
                    .frame(width: 120, height: 120)
                Image(systemName: icon)
                    .font(.system(size: 56))
                    .foregroundStyle(iconColor)
            }
            Text(title)
                .font(.title)
                .fontWeight(.semibold)
            Text(subtitle)
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
            if let actionTitle = actionTitle, let handler = actionHandler {
                Button {
                    actionRan = true
                    handler()
                } label: {
                    Label(actionRan ? "Asked" : actionTitle, systemImage: actionRan ? "checkmark" : "arrow.right.circle.fill")
                        .padding(.horizontal, 24)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.bordered)
                .tint(iconColor)
                .disabled(actionRan)
            }
            if let secondaryTitle, let secondaryHandler {
                VStack(spacing: 8) {
                    if let secondaryCaption {
                        Text(secondaryCaption)
                            .font(.footnote)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 32)
                    }
                    Button {
                        secondaryRan = true
                        secondaryHandler()
                    } label: {
                        Label(
                            secondaryRan ? "Asked" : secondaryTitle,
                            systemImage: secondaryRan ? "checkmark" : "clock.arrow.circlepath"
                        )
                        .padding(.horizontal, 24)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered)
                    .tint(iconColor)
                    .disabled(secondaryRan)
                }
                .padding(.top, 4)
            }
            Spacer()
        }
    }
}
