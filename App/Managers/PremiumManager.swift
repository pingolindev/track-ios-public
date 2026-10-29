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

import Foundation
import StoreKit
import SwiftUI

/// Effective premium entitlement for the current user — own
/// subscription OR circle-derived (any member of a circle the user
/// is in is subscribed). Fetched from the Track server's
/// `/api/v1/users/me/premium`; a failure keeps the last-known value
/// (see `refresh`). Mirrors the Android app's
/// `SessionManager.effectivePremium` +
/// `SettingsViewModel.fetchSubscriptionTier`.
///
/// The Settings tier badge and the server-side geocoder toggle gate
/// both bind to `effectivePremium` / `tierLabel` so they react to
/// the same source of truth and stay consistent with the server
/// (which returns 402 to a non-premium geocoder request).
@MainActor
final class PremiumManager: ObservableObject {
    static let shared = PremiumManager()

    @Published private(set) var effectivePremium: Bool
    /// One of "own", "circle", or "none". Drives the badge label
    /// ("Premium · Circle" vs plain "Premium").
    @Published private(set) var premiumSource: String
    /// Human-readable badge: "Premium · Circle" / "Premium" / "Free".
    @Published private(set) var tierLabel: String
    /// Latest per-user usage + limits (places/circles/place-alerts counts,
    /// history days, feature flags) for the Settings Plan card, or nil until
    /// the first fetch lands / after sign-out. Refresh-on-open; the server
    /// stays the authority. Sourced from GET /api/v1/quota.
    @Published private(set) var quota: TrackQuotaUsage?

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let effectivePremium = "premium.effective"
        static let premiumSource = "premium.source"
        static let tierLabel = "premium.tier"
    }

    private init() {
        // Seed from cached values so the UI doesn't flash "Free"
        // while the fetch is in flight on a returning premium user.
        self.effectivePremium = defaults.bool(forKey: Keys.effectivePremium)
        self.premiumSource = defaults.string(forKey: Keys.premiumSource) ?? "none"
        self.tierLabel = defaults.string(forKey: Keys.tierLabel) ?? "Free"
    }

    /// Pull the latest entitlement: the Track server's `/users/me/premium`, the
    /// only word on Track's plan (own or circle-derived). A failure keeps the
    /// last-known value. Never a fallback to the auth server's
    /// `/billing/subscription`: that list names no product, so counting any
    /// active subscription there would read a Note subscription as Track
    /// Premium.
    func refresh() async {
        do {
            let status = try await APIService.shared.getPremiumStatus()
            apply(hasPremium: status.hasPremium, source: status.source)
        } catch {
            // Keep the last-known value.
        }
    }

    /// Pull the latest per-user usage for the Settings Plan card. Best
    /// effort: a transient failure keeps the last-known numbers rather than
    /// blanking the card. A 401 is sorted out by the next request's refresh
    /// path.
    func refreshQuota() async {
        do {
            quota = try await APIService.shared.getQuota()
        } catch {
            // Keep the last-known value.
        }
    }

    /// Wipe cached state. Called from `AuthManager.logout` so a
    /// re-login on a different account starts clean.
    func reset() {
        defaults.removeObject(forKey: Keys.effectivePremium)
        defaults.removeObject(forKey: Keys.premiumSource)
        defaults.removeObject(forKey: Keys.tierLabel)
        effectivePremium = false
        premiumSource = "none"
        tierLabel = "Free"
        quota = nil
    }

    private func apply(hasPremium: Bool, source: String) {
        let label: String
        switch source {
        case "circle":  label = "Premium · Circle"
        default:        label = hasPremium ? "Premium" : "Free"
        }
        effectivePremium = hasPremium
        premiumSource = source
        tierLabel = label
        defaults.set(hasPremium, forKey: Keys.effectivePremium)
        defaults.set(source, forKey: Keys.premiumSource)
        defaults.set(label, forKey: Keys.tierLabel)
    }
}

/// Copy for the premium prompt, derived from a gated 402's `error_code` +
/// `quota`. A count limit shows "N of M used" plus a benefit line; a feature
/// gate shows just the benefit. Presented as a sheet from the create/share
/// flows (places, circles, members, destinations) when the server enforces a
/// subscription gate (see `PremiumPromptSheet`).
struct PremiumPrompt: Identifiable {
    let id = UUID()
    let title: String
    let benefit: String
    /// "2 of 2 places used" for a count limit; nil for a feature gate.
    let usage: String?

    /// Generic overview for the Settings Plan card's info button — not tied
    /// to a specific gate.
    static let overview = PremiumPrompt(
        title: "Track Premium",
        benefit: "Unlimited places, circles and alerts, larger circles (up to 50 members), and a full year of location history.",
        usage: nil)

    /// Build a prompt from a gated APIError, or nil when the error isn't a
    /// subscription gate (the caller then falls back to a plain error alert).
    static func forGate(_ error: APIError) -> PremiumPrompt? {
        guard error.isPremiumGate else { return nil }
        // The structured quota carries the resource + counts; fall back to the
        // error_code for a feature gate that arrived without a quota object.
        let resource = error.quota?.resource ?? resourceName(fromCode: error.errorCode)
        let spec = self.spec(for: resource)
        var usage: String?
        if let q = error.quota, q.isCountLimit, q.limit >= 0 {
            usage = "\(q.current) of \(q.limit) \(spec.noun) used"
        }
        return PremiumPrompt(title: spec.title, benefit: spec.benefit, usage: usage)
    }

    private static func spec(for resource: String) -> (title: String, benefit: String, noun: String) {
        switch resource {
        case "places":
            return ("Unlimited places",
                    "Premium removes the limit on saved places.", "places")
        case "circles":
            return ("Unlimited circles",
                    "Premium lets you create as many circles as you need.", "circles")
        case "members":
            return ("Bigger circles",
                    "Premium raises the circle member limit to 50.", "members")
        case "place_alerts":
            return ("Unlimited place alerts",
                    "Premium removes the limit on place alerts.", "place alerts")
        case "destinations":
            return ("Add more destinations",
                    "The free plan includes one active destination. Premium removes the limit.", "destinations")
        case "smart_alerts":
            return ("Smart alerts",
                    // Inactivity alerts are FREE: the server puts no quota
                    // gate on them. Only the condition rules behind
                    // `alerts_enabled` (low battery, and the deprecated offline
                    // type) are premium. Naming inactivity here would sell a
                    // subscription for something the free tier already
                    // includes, and the Terms say it is free.
                    "Alerts about a member's battery running low are a Premium feature. Being told when a device goes quiet is free.", "alerts")
        // No "web_push" case on purpose. Browser push is free on both tiers, so
        // the server has no gate to send for this resource, and copy calling it
        // Premium would be a false claim.
        case "geocode":
            return ("Address search",
                    "Server-side address lookup is a Premium feature.", "")
        default:
            return ("Premium feature", "This is a Premium feature.",
                    resource.replacingOccurrences(of: "_", with: " "))
        }
    }

    /// Defensive fallback: derive the resource from the error_code when no
    /// quota object was sent (e.g. `premium_required_destinations` →
    /// `destinations`, `quota_places_exceeded` → `places`).
    private static func resourceName(fromCode code: String?) -> String {
        guard let code else { return "" }
        return code
            .replacingOccurrences(of: "premium_required_", with: "")
            .replacingOccurrences(of: "quota_", with: "")
            .replacingOccurrences(of: "_exceeded", with: "")
    }
}

/// Explainer shown when a create/share action hits a subscription gate, with
/// an in-app purchase route.
///
/// App Store guideline 3.1.3(b) permits honouring a subscription bought
/// elsewhere PROVIDED the same thing is available as an in-app purchase. So
/// the button below is not a nicety — it is the condition on which honouring
/// web subscriptions in this app is allowed.
///
/// The prices match the web exactly, so there is nothing to steer anyone
/// towards and no reason to mention another channel.
struct PremiumPromptSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = StoreKitManager.shared
    let prompt: PremiumPrompt

    /// nil while unknown, then the server's answer. Purchase is offered only on
    /// an explicit yes — see `checkEligibility`.
    @State private var eligibility: ApplePurchaseEligibility?
    @State private var checkingEligibility = true
    /// A check or a product load has failed at least once and is being tried
    /// again by itself, so the spinner says what it is waiting for.
    @State private var eligibilityRetrying = false
    @State private var productsRetrying = false
    @State private var purchaseError: String?
    @State private var restoring = false
    @State private var restoreMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 12) {
                        Image(systemName: "star.circle.fill")
                            .font(.largeTitle)
                            .foregroundStyle(.tint)
                        Text(prompt.title)
                            .font(.title2.weight(.semibold))
                    }

                    Text(prompt.benefit)
                        .font(.subheadline)

                    if let usage = prompt.usage {
                        Label(usage, systemImage: "chart.bar.fill")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Divider()

                    purchaseSection

                    restoreSection
                }
                .padding()
            }
            .navigationTitle("Premium")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Got it") { dismiss() }
                        .accessibilityIdentifier("premium-prompt-dismiss")
                }
            }
            // Both are tried again by themselves while the sheet is open
            // (`RetryClock`) — never "try again later".
            .task {
                await RetryClock.untilDone {
                    await store.loadProducts()
                    productsRetrying = store.products.isEmpty
                    return !store.products.isEmpty
                }
            }
            .task {
                await RetryClock.untilDone {
                    let answered = await checkEligibility()
                    eligibilityRetrying = !answered
                    return answered
                }
            }
        }
    }

    @ViewBuilder
    private var purchaseSection: some View {
        if checkingEligibility {
            waiting(eligibilityRetrying ? "Waiting for a connection…" : nil)
        } else if let eligibility, !eligibility.canPurchase {
            // Already subscribed on the web. Buying here would charge them a
            // second time and we cannot cancel the web subscription for them, so
            // this states the situation rather than offering a button: the app's
            // own words, never the server's text.
            Label("You already have a subscription for this.", systemImage: "info.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("premium-already-subscribed")
        } else if store.products.isEmpty {
            // Offline, or the products are not configured in App Store Connect
            // yet. Saying nothing would leave a sheet that explains a paywall and
            // offers no way past it — so it says what it is waiting for, and
            // keeps asking the App Store by itself.
            waiting(productsRetrying ? "Waiting for the App Store…" : "Loading…")
                .accessibilityIdentifier("premium-purchase-unavailable")
        } else {
            VStack(spacing: 10) {
                ForEach(store.products, id: \.id) { product in
                    Button {
                        Task { await buy(product) }
                    } label: {
                        HStack {
                            Text(product.displayName)
                            Spacer()
                            Text(product.displayPriceWithPeriod)
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.purchasing)
                    .accessibilityIdentifier("premium-buy-\(product.id)")
                }

                if store.purchasing {
                    ProgressView().padding(.top, 2)
                }

                subscriptionTerms
            }
        }

        if let purchaseError {
            Text(purchaseError)
                .font(.footnote)
                .foregroundStyle(.red)
                .accessibilityIdentifier("premium-purchase-error")
        }
    }

    /// A spinner, and what it is waiting for once that is worth saying.
    private func waiting(_ text: String?) -> some View {
        HStack(spacing: 8) {
            ProgressView()
            if let text {
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    /// Renewal terms and the two legal links, shown with the buy buttons.
    ///
    /// NOT decoration and not optional. Guideline 3.1.2(c) points at Schedule 2 of
    /// the Developer Program License Agreement, which requires an auto-renewable
    /// subscription to show its length and price per period, plus FUNCTIONAL links
    /// to the terms of use and privacy policy, before the customer buys. A paywall
    /// missing these is rejected in App Review.
    ///
    /// The price/period half is handled by `displayPriceWithPeriod` on the button
    /// itself, so what is left here is the renewal behaviour and the links.
    private var subscriptionTerms: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Subscriptions renew automatically unless auto-renew is turned off at "
                 + "least 24 hours before the end of the current period. Manage or cancel "
                 + "in your Apple account settings.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 18) {
                Link("Terms of Use", destination: StoreKitManager.Legal.terms)
                    .accessibilityIdentifier("premium-terms-link")
                Link("Privacy Policy", destination: StoreKitManager.Legal.privacy)
                    .accessibilityIdentifier("premium-privacy-link")
            }
            .font(.caption2)
        }
        .padding(.top, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Restore Purchases, in every state of the sheet — while eligibility is
    /// checked or tried again (offline, a session the server refuses), and with
    /// "you already subscribe on the web" or "purchases unavailable" — because
    /// the person looking for it is exactly the one whose purchase did not show
    /// up. Restoring asks the App Store, never the eligibility answer. Guideline
    /// 3.1.1 expects a visible restore; the launch-time `restore()` is
    /// invisible, and cannot see past the device's copy of the history.
    @ViewBuilder
    private var restoreSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                Task { await restorePurchases() }
            } label: {
                Group {
                    if restoring {
                        ProgressView()
                    } else {
                        Text("Restore Purchases")
                    }
                }
                // 44pt, the same hit-area floor as the legal links.
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .font(.footnote)
            .disabled(restoring || store.purchasing)
            .accessibilityIdentifier("premium-restore-purchases")

            if let restoreMessage {
                Text(restoreMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("premium-restore-result")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func restorePurchases() async {
        restoring = true
        defer { restoring = false }
        restoreMessage = nil
        let outcome = await store.restorePurchases()
        restoreMessage = outcome.message
        // A restored App Store subscription changes what eligibility answers.
        if outcome == .restored {
            _ = await checkEligibility()
        }
    }

    /// Ask the server whether this account may buy through the App Store.
    /// True once it has answered.
    ///
    /// FAILS CLOSED. Until the server answers, no button is shown, because the
    /// question is "does this person already pay for this on the web" — and
    /// selling to them again on a guess charges them twice for one
    /// entitlement. A failed check keeps the spinner and is asked again by
    /// itself, rather than ending on a sentence asking for another try.
    private func checkEligibility() async -> Bool {
        do {
            eligibility = try await APIService.shared.getApplePurchaseEligibility(
                product: StoreKitManager.productSlug)
            checkingEligibility = false
            return true
        } catch {
            print("[Track] Purchase eligibility check failed: \(error)")
            return false
        }
    }

    private func buy(_ product: Product) async {
        purchaseError = nil
        // The singleton rather than @EnvironmentObject: this sheet is presented
        // from several places, and a missing environment object is a crash rather
        // than a degraded view.
        // The STORED account id: `currentUser` is only there once `/auth/me` has
        // answered this launch, and its absence would ask a signed-in person to
        // "sign in again". Nil only when truly signed out.
        guard let userID = AuthManager.shared.userId else {
            purchaseError = "Please sign in again to subscribe."
            return
        }
        switch await store.purchase(product, userID: userID) {
        case .success:
            dismiss()
        case .cancelled:
            // Dismissing the App Store sheet is not a failure and must not be
            // reported as one.
            break
        case .pending:
            purchaseError = "Your purchase needs approval. It will activate once approved."
        case .failed(let message):
            purchaseError = message
        }
    }
}
