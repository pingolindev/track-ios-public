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

/// App Store purchases for Track premium.
///
/// WHAT THIS DOES NOT DO IS THE IMPORTANT PART: it never decides whether the
/// user has premium. `PremiumManager.effectivePremium` is the only answer to
/// that, sourced from the server, because premium can be circle-derived — a
/// member of your circle subscribing on the web grants it to you, and StoreKit
/// has no idea that happened. A client that gated on `currentEntitlements` would
/// silently drop every circle-derived and web-bought subscriber to the free
/// tier.
///
/// So the job here is narrow: complete a purchase, hand Apple's signed
/// transaction to the server, and ask the server to re-read entitlement.
///
/// THE ACCOUNT LINK. Every purchase carries `appAccountToken` set to the signed-in
/// user's id. That is the only thing in Apple's payload that names an account —
/// the server refuses a transaction without one, and refuses one naming a
/// different account — so a purchase made without it is unattributable and the
/// customer would be charged with nothing granted.
@MainActor
final class StoreKitManager: ObservableObject {
    static let shared = StoreKitManager()

    /// Products fetched from the App Store, empty until `loadProducts()` lands.
    @Published private(set) var products: [Product] = []
    /// True while a purchase is in flight, for disabling the button.
    @Published private(set) var purchasing = false
    /// Set when a purchase could not be completed, for the caller to surface.
    @Published var lastError: String?

    private var updatesTask: Task<Void, Never>?

    private init() {}

    // MARK: - Product identifiers

    /// The App Store Connect product identifiers for Track premium.
    ///
    /// Single products only: bundles are web-only by design, so there is no
    /// combined SKU here and there should not be one without revisiting that.
    enum ProductID {
        static let monthly = "com.pingolin.track.premium.monthly"
        static let yearly = "com.pingolin.track.premium.yearly"
        static let all: [String] = [monthly, yearly]
    }

    /// The product slug these SKUs grant, for the eligibility pre-flight.
    static let productSlug = "track"

    /// Legal pages the purchase screen must link to. See `subscriptionTerms` in
    /// `PremiumPromptSheet` for why they are mandatory rather than decorative.
    enum Legal {
        static let terms = URL(string: "https://pingolin.com/terms")!
        static let privacy = URL(string: "https://pingolin.com/privacy")!
    }

    /// "month", "3 months", "year" — how a billing period reads next to a price.
    ///
    /// Returns nil for a unit StoreKit adds later, so the caller can fall back to
    /// the bare price rather than render "$3.00 / " with nothing after it.
    ///
    /// Takes the unit and value rather than a `SubscriptionPeriod` so the
    /// pluralisation can be tested without a live App Store product.
    nonisolated static func periodLabel(unit: Product.SubscriptionPeriod.Unit, value: Int) -> String? {
        let singular: String
        switch unit {
        case .day: singular = "day"
        case .week: singular = "week"
        case .month: singular = "month"
        case .year: singular = "year"
        @unknown default: return nil
        }
        return value == 1 ? singular : "\(value) \(singular)s"
    }

    // MARK: - Lifecycle

    /// Start listening for transactions that arrive outside a purchase.
    ///
    /// Renewals, Ask-to-Buy approvals, refunds, and purchases made on another
    /// device all land here rather than as the result of `purchase()`. Without
    /// this listener a renewal would never be reported and the subscription would
    /// look lapsed until Apple's server notification happened to arrive.
    ///
    /// Call once, at launch.
    func startObservingTransactions() {
        guard updatesTask == nil else { return }
        updatesTask = Task.detached { [weak self] in
            for await update in Transaction.updates {
                guard let self else { return }
                await self.handle(verificationResult: update, source: "update")
            }
        }
    }

    func stopObservingTransactions() {
        updatesTask?.cancel()
        updatesTask = nil
    }

    func loadProducts() async {
        do {
            let fetched = try await Product.products(for: ProductID.all)
            // Cheapest first so the monthly option reads as the entry point.
            products = fetched.sorted { $0.price < $1.price }
            // An EMPTY result is how StoreKit says "I do not recognise these
            // ids" — it does not throw. That is the common failure (App Store
            // Connect agreement not active, products not yet Ready to Submit,
            // wrong bundle), and without a log the paywall's "Purchases are
            // unavailable" gives no way to tell whether we had even asked.
            // Name the ids so the answer is checkable against App Store
            // Connect.
            if fetched.isEmpty {
                print("[Track] StoreKit returned NO products for \(ProductID.all) "
                      + "— check the Paid Applications agreement and that each SKU is at least Ready to Submit")
            } else {
                print("[Track] StoreKit loaded \(fetched.count) product(s): \(fetched.map(\.id))")
            }
        } catch {
            // Not surfaced as an error: an empty product list already renders as
            // "purchases unavailable", and a failed fetch is usually the device
            // being offline rather than anything the user can act on.
            print("[Track] StoreKit product fetch failed: \(error)")
        }
    }

    // MARK: - Purchase

    enum PurchaseOutcome {
        case success
        /// The user dismissed the sheet. Not an error, and must not be reported
        /// as one.
        case cancelled
        /// Ask-to-Buy and similar: Apple will deliver the transaction later
        /// through `Transaction.updates`.
        case pending
        case failed(String)
    }

    /// Buy `product` for the signed-in user.
    ///
    /// The caller is responsible for having checked eligibility first — see
    /// `APIService.getApplePurchaseEligibility`. That check cannot live here
    /// because it must happen before the sheet is even offered.
    func purchase(_ product: Product, userID: String) async -> PurchaseOutcome {
        guard let accountToken = UUID(uuidString: userID) else {
            // Refuse rather than purchase without the link. A transaction with no
            // appAccountToken is one the server cannot attribute, so the customer
            // would pay and get nothing — worse than not selling.
            print("[Track] Cannot start a purchase: user id \(userID) is not a UUID")
            // Not "sign in again": the id is the account's own, and a new
            // sign-in brings back the same one.
            return .failed("Could not start the purchase.")
        }

        purchasing = true
        defer { purchasing = false }

        do {
            let result = try await product.purchase(options: [.appAccountToken(accountToken)])
            switch result {
            case .success(let verification):
                await handle(verificationResult: verification, source: "purchase")
                return .success
            case .userCancelled:
                return .cancelled
            case .pending:
                return .pending
            @unknown default:
                return .failed("The purchase could not be completed.")
            }
        } catch {
            print("[Track] StoreKit purchase failed: \(error)")
            return .failed("The purchase could not be completed.")
        }
    }

    /// Re-report anything the App Store still considers current.
    ///
    /// Run at launch, and it is what makes a reinstall or a new device work: the
    /// server may already know, in which case the link is a no-op upsert, but if
    /// it does not — a notification lost, an install on a fresh device — this is
    /// what repairs it.
    func restore() async {
        for await entitlement in Transaction.currentEntitlements {
            await handle(verificationResult: entitlement, source: "restore")
        }
    }

    /// What the Restore Purchases button reports back.
    enum RestoreOutcome: Equatable {
        /// At least one current App Store subscription was reported and accepted.
        case restored
        /// The App Store holds no current subscription for this Apple ID.
        case nothingToRestore
        /// The user dismissed the App Store sign-in. Nothing to say.
        case cancelled
        case failed(String)

        /// Copy for the sheet, or nil when there is nothing to say.
        var message: String? {
            switch self {
            case .restored: return "Your App Store subscription has been restored."
            case .nothingToRestore: return "No active App Store subscription was found for this Apple ID."
            case .cancelled: return nil
            case .failed(let message): return message
            }
        }
    }

    /// The user-initiated restore behind the Restore Purchases button.
    ///
    /// `AppStore.sync()` first: it asks the App Store for this Apple ID's
    /// transactions instead of trusting the device's copy, which is what a
    /// reinstall or a new phone can be missing. Apple says to call it only in
    /// response to an explicit user action — it can ask the user to sign in —
    /// which is why launch runs the plain `restore()` and only this button syncs.
    ///
    /// Then the same report-and-finish path as a purchase, so a restore is
    /// attributed, and refused (another account's purchase, a family-shared one),
    /// by exactly the rules a purchase is.
    func restorePurchases() async -> RestoreOutcome {
        do {
            try await AppStore.sync()
        } catch StoreKitError.userCancelled {
            return .cancelled
        } catch {
            print("[Track] AppStore.sync failed: \(error)")
            return .failed("Couldn't reach the App Store. Please try again.")
        }
        lastError = nil
        var found = 0
        for await entitlement in Transaction.currentEntitlements {
            found += 1
            await handle(verificationResult: entitlement, source: "restore-button")
        }
        return Self.restoreOutcome(found: found, error: lastError)
    }

    /// Pure, so the result the user is shown is testable without StoreKit. A
    /// refusal or failure from `handle` outranks the count: finding a
    /// subscription the server would not accept is not a restore.
    nonisolated static func restoreOutcome(found: Int, error: String?) -> RestoreOutcome {
        if let error { return .failed(error) }
        return found == 0 ? .nothingToRestore : .restored
    }

    // MARK: - Reporting

    /// Report one verified transaction to the server, then finish it.
    ///
    /// ORDER MATTERS. `finish()` is called only after the server has accepted the
    /// transaction. An unfinished transaction is redelivered by StoreKit on the
    /// next launch, which is exactly the retry we want if the report failed —
    /// finishing first would drop a paid purchase on a flaky network and the
    /// customer would have to contact support to get what they paid for.
    private func handle(verificationResult: VerificationResult<Transaction>, source: String) async {
        // Apple's own signature check. An `.unverified` result is not a
        // transaction we should act on, and reporting it would be handing the
        // server something it is about to reject anyway.
        guard case .verified(let transaction) = verificationResult else {
            print("[Track] Ignoring an unverified StoreKit transaction (\(source))")
            return
        }

        // Revoked or refunded: nothing to grant. The server learns this from
        // Apple's REFUND notification, which is authoritative; reporting it here
        // would only be refused.
        if transaction.revocationDate != nil {
            await transaction.finish()
            return
        }

        do {
            _ = try await APIService.shared.linkApplePurchase(
                signedTransaction: verificationResult.jwsRepresentation)
            await transaction.finish()
            print("[Track] Reported an App Store transaction to the server (\(source))")
        } catch {
            // A PERMANENT refusal and a transient failure look alike from here
            // unless we read the code. Treating the first as the second would
            // leave the transaction unfinished: StoreKit would hand it back on
            // every launch, and each time the user would be told it would
            // "activate automatically — no need to buy again". For a Family
            // Sharing purchase that is false forever.
            if let api = error as? APIError, Self.isPermanentRefusal(api) {
                // Finish it. There is nothing to retry, and leaving it pending
                // means re-asking the server the same refused question daily.
                await transaction.finish()
                print("[Track] App Store transaction refused permanently (\(source)): \(api.errorCode ?? "-")")
                // Which refusal it is comes from the server's code; the words
                // are this app's, never the server's text.
                lastError = Self.refusalText(api)
            } else {
                // Deliberately NOT finished. StoreKit will hand it back on the next
                // launch and `restore()` will try again.
                print("[Track] Could not report an App Store transaction (\(source)): \(error)")
                lastError = "Your purchase went through, but we could not activate it yet. "
                    + "It will activate automatically — no need to buy again."
            }
        }

        // The server is the authority on entitlement, so ask it rather than
        // inferring premium from the transaction we just sent.
        await PremiumManager.shared.refresh()
        await PremiumManager.shared.refreshQuota()
    }
}

extension StoreKitManager {
    /// Refusals that will never succeed on a retry.
    ///
    /// Anything else — a network blip, a 500, an expired token — is transient
    /// and must keep the transaction pending so StoreKit re-offers it. Getting
    /// this backwards in either direction is costly: retrying forever tells a
    /// paying customer a falsehood on every launch, and finishing a transient
    /// failure throws away a purchase the server never recorded.
    static func isPermanentRefusal(_ error: APIError) -> Bool {
        switch error.errorCode {
        // Every code here is PERMANENT: nothing about replaying the same
        // transaction can change the answer.
        //
        //   apple_family_shared      — a product decision, not a transient fault
        //   apple_transaction_revoked — Apple took the money back
        //   apple_wrong_account       — the token names a different account, which
        //                               is what a delete-and-re-register leaves
        //                               behind; `restore()` replays it forever
        //   apple_unattributable      — no token and no known subscription, so
        //                               there is nobody to attribute it to
        //   apple_already_expired     — the period has ended; a renewal arrives as
        //                               its own transaction, never as this one
        //
        // Each of these must take this branch: the transient one would never
        // finish the transaction, and every launch would tell the user their
        // purchase "went through" and needed no action.
        case "apple_family_shared", "apple_transaction_revoked",
             "apple_wrong_account", "apple_unattributable", "apple_already_expired":
            return true
        default:
            return false
        }
    }

    /// What a permanent refusal says, by its code: the facts the auth
    /// server's refusals state, in this app's words.
    nonisolated static func refusalText(_ error: APIError) -> String {
        switch error.errorCode {
        case "apple_family_shared":
            return "This subscription was shared through Apple Family Sharing, which Pingolin can't accept. "
                + "Premium reaches other people through a Pingolin circle instead: add them to your circle and "
                + "they get the premium features there. If you're out of pocket, write to "
                + "help@support.pingolin.com and we'll sort it out."
        case "apple_transaction_revoked":
            return "This purchase has been refunded or cancelled by Apple, so it no longer grants a subscription."
        case "apple_wrong_account":
            return "This purchase belongs to a different account."
        case "apple_unattributable":
            return "This purchase can't be matched to an account."
        case "apple_already_expired":
            return "This subscription has already expired."
        default:
            return "This purchase can't be used for a subscription."
        }
    }
}

extension Product {
    /// "$3.00 / month" — price AND period, together.
    ///
    /// `displayPrice` on its own is just "$3.00", which is not enough in front of
    /// an auto-renewable subscription: what the customer is committing to per
    /// period has to be visible before they buy, not inferred from the product
    /// name. Falls back to the bare price if StoreKit reports a period we cannot
    /// name, which is better than rendering a dangling separator.
    var displayPriceWithPeriod: String {
        guard let period = subscription?.subscriptionPeriod,
              let label = StoreKitManager.periodLabel(unit: period.unit, value: period.value)
        else { return displayPrice }
        return "\(displayPrice) / \(label)"
    }
}
