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
import LocalAuthentication
import WebKit

struct SettingsView: View {
    @StateObject private var authManager = AuthManager.shared
    @StateObject private var settings = UserSettings.shared
    @StateObject private var locationService = LocationService.shared
    @StateObject private var premiumManager = PremiumManager.shared
    @StateObject private var selfKeyStatus = SelfKeyStatus.shared
    @ObservedObject private var keyStoreRecovery = KeyStoreRecovery.shared
    /// Changes waiting on this iPhone: the sign-out question says they won't
    /// be made.
    @ObservedObject private var pendingChanges = PendingChangeStore.shared
    @State private var showingLogoutConfirm = false
    @State private var showingDeleteAccountConfirm = false
    @State private var showingPremiumSheet = false

    // The server's notification preferences, held WHOLE.
    //
    // The server is the source of truth; there is no local mirror. Every
    // switch in the notifications section reads out of this map and writes
    // back through a read-modify-write PUT, which is what makes them mean
    // something: a switch kept only in UserDefaults would be read by
    // nothing, so turning "Circle notifications" off would leave the phone
    // buzzing for every alert forever.
    //
    // Whole, rather than a field per switch, so a write preserves the parts
    // this screen does not show: the per-category EMAIL overrides web exposes,
    // quiet hours, and anything a later server adds.
    @State private var notificationPrefs: [String: Any] = [:]
    // Guards the initial programmatic load from triggering a spurious PUT —
    // a toggle's custom-setter Binding only writes once the fetched values
    // have landed.
    @State private var notificationPrefsLoaded = false
    // A load that failed, so the switches can say WHY they are inert
    // instead of just being inert.
    @State private var notificationPrefsError: String?

    // Android-mirror persisted settings: the same shapes as the
    // Android app's settings.
    @AppStorage("theme") private var themeRaw: String = "system"
    // Default mirrors the Android app — 1 min time interval + 100 m
    // distance threshold. A longer interval (15 min, say) spares
    // battery but reads as broken: real-world use expects sub-minute
    // updates, so users open the app, see a stale marker, and report
    // otherwise-fine tracking as failing. The distance pump still gates
    // spam during static periods, so the 1 min ceiling only fires when
    // someone is moving less than 100 m / min.
    @AppStorage("location.intervalSec") private var locationIntervalSec: Int = 60
    @AppStorage("location.distanceMeters") private var locationDistanceMeters: Int = 100
    @AppStorage("location.batchUploads") private var locationBatchUploads: Bool = false
    @AppStorage("diagnostics.crashReporting") private var crashReportingEnabled: Bool = false
    @AppStorage("app.privacy.blockScreenshots") private var blockScreenshots = ScreenshotBlocker.defaultEnabled
    /// Mirrors the Android app's `SessionManager.useServerGeocoder` —
    /// flipping this both in Settings and on the Geocoding sub-screen
    /// reads/writes the same default so there's a single source of
    /// truth.
    @AppStorage("geocoding.useServerSide") private var useServerGeocoder: Bool = false
    @State private var showingGeocoderInfo = false

    var body: some View {
        NavigationStack {
            List {
                untrustedEnvironmentSection
                syncErrorSection
                personalKeySection
                // Section order mirrors the Android app's
                // settings screen. Encryption and
                // Devices are one "Security & Devices"
                // section below Location Tracking, with the
                // other advanced settings, so the middle of
                // the list is the settings people actually
                // change. The iOS-only sections sit below
                // the shared block so Android users find
                // each option in the same vertical order.
                supportSection
                accountSection
                planSection
                appearanceSection
                appLockSection
                pushNotificationsSection
                geocodingSection
                backgroundLocationUpgradeBanner
                preciseLocationUpgradeBanner
                locationTrackingSection
                securityAndDevicesSection
                dataExportSection

                // iOS-only sections (no Android parity); placed
                // below the Android-mirrored block so the shared
                // sections line up. There is no global battery or
                // inactivity switch here: both kinds of alert are
                // governed in the circle's permissions, as on
                // Android.
                diagnosticsSection
                activitySection
                privacySection
                aboutSection
                accountActionsSection
            }
            .navigationTitle("Settings")
            .task {
                // Refresh the effective premium entitlement when
                // Settings opens so the badge + geocoder gate
                // reflect what the server actually grants right
                // now (own subscription or circle-derived).
                await premiumManager.refresh()
                // ...and the per-user usage counts behind the Plan card.
                await premiumManager.refreshQuota()
            }
            // Tried again by itself until it loads, while
            // Settings is open — no "Try Again" tap needed.
            .task { await RetryClock.untilDone { await loadNotificationPreferences() } }
            .alert("Sign Out?", isPresented: $showingLogoutConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Sign Out", role: .destructive) {
                    Task { await authManager.logout() }
                }
            } message: {
                // A title-only alert says what the button said and
                // nothing about the consequence. Signing out stops
                // location sharing until the next sign-in, which is
                // the part worth knowing before pressing it.
                Text(Self.signOutMessage(waiting: pendingChanges.pendingCount))
            }
            .sheet(isPresented: $showingDeleteAccountConfirm) {
                NavigationStack { DeleteAccountSheet() }
            }
            .sheet(isPresented: $showingPremiumSheet) {
                PremiumPromptSheet(prompt: .overview)
            }
        }
    }

    // MARK: - Sections (Android-mirrored order)

    @ViewBuilder
    private var untrustedEnvironmentSection: some View {
        if !DeviceIntegrity.trustworthyEnvironment {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Untrusted Environment")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        Text("This device shows signs of jailbreak. Track keeps working normally, but a jailbroken device gives other software on it access to your data — including your family's locations.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "exclamationmark.shield.fill")
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    /// The key store's sync error (`KeyStoreRecovery`): a signing seed or
    /// entries that didn't read. The app still works, so nobody is signed out
    /// for it; the person signs in again when ready, and that sign-in repairs
    /// the store. Sign Out asks first, as everywhere.
    @ViewBuilder
    private var syncErrorSection: some View {
        if keyStoreRecovery.showsSyncBanner {
            Section {
                Label {
                    Text(KeyStoreRecovery.syncErrorText)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.red)
                }
                .accessibilityIdentifier("sync-error-notice")
                Button(action: {
                    if let me = authManager.userId { pendingChanges.use(account: me) }
                    showingLogoutConfirm = true
                }) {
                    Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                }
                .foregroundStyle(.red)
                .accessibilityIdentifier("sync-error-sign-out")
            }
        }
    }

    /// The personal (self-tracking) key, when it is not working.
    ///
    /// Without this, that state is invisible on screen: personal history
    /// empty, personal places gone, circles fine, no reason given.
    ///
    /// Sits at the top of the list, under the untrusted-environment warning and
    /// the key store's sync error, and follows the warning's shape, because it
    /// is the same kind of thing — a standing condition the user cannot
    /// discover any other way. Silent when the key is fine, so
    /// it costs nothing in the ordinary case. The worst state repairs itself
    /// (reported here, republished by another device), and the detail line
    /// says so; the password states carry their field here.
    @ViewBuilder
    private var personalKeySection: some View {
        if let notice = selfKeyStatus.notice {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(notice.title)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        Text(notice.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: notice.severity == .error
                          ? "exclamationmark.triangle.fill"
                          : "exclamationmark.circle")
                        .foregroundStyle(notice.severity == .error ? Color.red : Color.orange)
                }
                .accessibilityIdentifier("self-key-notice")
                // The password, right here. The Map's banner for
                // this state opens Settings, so this is where it
                // lands.
                if selfKeyStatus.health.asksForPassword {
                    PasswordUnlockForm()
                }
            }
        }
    }

    private var supportSection: some View {
        Section("Support") {
            NavigationLink(destination: SupportTicketView()) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Contact Support")
                        Text("Submit a support ticket")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "questionmark.circle")
                }
            }
        }
    }

    /// Plan card mirroring note-ios's Settings "Plan" section: a tier line,
    /// an info button opening the premium explainer, and — on the free tier —
    /// live usage bars for the per-user count limits (places, circles, place
    /// alerts). Numbers come from GET /api/v1/quota via PremiumManager; a
    /// `-1` limit reads as Unlimited.
    ///
    /// History gets its own line, on BOTH tiers, carrying the number the
    /// SERVER reports. It is the entitlement people actually feel when premium
    /// arrives or ends — and the only one whose loss destroys data — so it
    /// must not be inferred from the tier. Mirrors the Android app's
    /// `tvPlanHistory`.
    @ViewBuilder
    private var planSection: some View {
        Section("Plan") {
            HStack(spacing: 10) {
                Image(systemName: premiumManager.effectivePremium ? "star.circle.fill" : "person.circle")
                    .font(.title3)
                    .foregroundStyle(premiumManager.effectivePremium ? Color.orange : Color.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(premiumManager.effectivePremium ? "Track — \(premiumManager.tierLabel)" : "Track — Free")
                        .font(.subheadline.weight(.semibold))
                    // Rendered from the server's
                    // `history_days`, never from the tier: a
                    // hardcoded number would be untrue for a
                    // plan whose retention the server set to
                    // anything else, or for a premium user
                    // mid-expiry. Absent until the first
                    // /quota lands, which is the honest state:
                    // no line beats a made-up one.
                    if let days = premiumManager.quota?.historyDays {
                        Text("\(days) days of location history")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("plan-history-days")
                    }
                    if premiumManager.effectivePremium {
                        // No history figure here — the line above states it, on
                        // both tiers, with the real number.
                        Text("Unlimited places · circles · alerts · destinations")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                // An ⓘ reads as "explain this", not "buy this", and on the free
                // tier this is the one place someone who has decided to
                // subscribe comes looking. So label it on free and keep the
                // glyph once premium.
                //
                // Gated on `effectivePremium`, NOT on owning a subscription:
                // premium here can be circle-derived, so a member covered by
                // someone else's subscription must not be told to upgrade —
                // there is nothing for them to buy.
                //
                // It still opens the SHEET rather than starting a purchase: the
                // sheet is where eligibility is checked and fails closed, which
                // is what stops a customer with a live web subscription buying a
                // second one through Apple. The identifier stays
                // `plan-info-button` in both states so the UI tests keep
                // finding it.
                Button {
                    showingPremiumSheet = true
                } label: {
                    if premiumManager.effectivePremium {
                        Image(systemName: "info.circle")
                    } else {
                        Text("Upgrade").font(.subheadline.weight(.semibold))
                    }
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(premiumManager.effectivePremium
                                    ? "About Track Premium"
                                    : "Upgrade to Track Premium")
                .accessibilityIdentifier("plan-info-button")
            }
            // Grace countdown, and ONLY while the server is actually counting.
            // It sends nil when premium is active and when there was never any
            // premium to lose, so this never nags someone with nothing at
            // stake — and a permanently-parked "0 days" would be worse than no
            // line at all.
            if let q = premiumManager.quota, let expiring = q.historyExpiresInDays {
                Label {
                    Text(Self.historyExpiryMessage(
                        daysLeft: expiring,
                        keptDays: q.historyDays,
                        premiumDays: q.premiumHistoryDays))
                        .font(.caption)
                        .accessibilityIdentifier("plan-history-expiring")
                } icon: {
                    Image(systemName: "clock.badge.exclamationmark")
                        .foregroundStyle(.orange)
                }
            }
            if !premiumManager.effectivePremium, let q = premiumManager.quota {
                usageRow(label: "Places", current: q.currentPlaces, limit: q.maxPlaces)
                usageRow(label: "Circles", current: q.currentCircles, limit: q.maxCircles)
                usageRow(label: "Place alerts", current: q.currentPlaceAlerts, limit: q.maxPlaceAlerts)
                usageRow(label: "Destinations", current: q.currentDestinations, limit: q.maxDestinations)
            }
        }
    }

    /// Copy for the grace countdown.
    ///
    /// Deliberately NOT a translation of the Android app's
    /// `plan_history_expiring` ("Premium ends in %1$d days — history drops to
    /// %2$d days"). The server sends this value only to someone who is ALREADY
    /// on the free tier, so their premium has already ended and their visible
    /// history has already dropped — that sentence would describe something past
    /// as though it were pending. What is genuinely still counting down is the
    /// DELETION of the older data, and that is the only part the user can still
    /// act on: re-subscribing inside the window restores the history intact.
    ///
    /// `keptDays` comes from the server's `history_days` rather than a
    /// hardcoded free-tier 2 (which is what Android interpolates), for the
    /// same reason the history line above uses it.
    ///
    /// `premiumDays` likewise comes from the server (`premium_history_days`),
    /// never from a literal: the server owns that number, and the reader of
    /// this message is on the free tier, so their own `history_days` says
    /// nothing about it. When it is unknown the sentence says a premium
    /// circle keeps LONGER without naming a figure, which is true whatever
    /// the tier is set to.
    static func historyExpiryMessage(daysLeft: Int, keptDays: Int, premiumDays: Int? = nil) -> String {
        // The server clamps at zero, so "in 0 days" is reachable on the last
        // day of the window and reads like a bug.
        let when: String
        switch daysLeft {
        case ..<1:  when = "today"
        case 1:     when = "tomorrow"
        default:    when = "in \(daysLeft) days"
        }
        let kept = keptDays == 1 ? "1 day" : "\(keptDays) days"
        // A premium figure that is not actually longer than what this user
        // already keeps would make the sentence an argument for nothing, so it
        // falls back to the unquantified form rather than printing it.
        let premium: String
        if let premiumDays, premiumDays > keptDays {
            let days = premiumDays == 1 ? "1 day" : "\(premiumDays) days"
            premium = "Circles with a premium member keep \(days)."
        } else {
            premium = "Circles with a premium member keep a longer history."
        }
        return "Location history older than \(kept) is deleted \(when). " + premium
    }

    @ViewBuilder
    private func usageRow(label: String, current: Int, limit: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.subheadline)
                Spacer()
                Text(limit < 0 ? "\(current) / Unlimited" : "\(current) / \(limit)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if limit > 0 {
                ProgressView(value: Double(min(current, limit)), total: Double(limit))
                    .tint(current >= limit ? .red : .accentColor)
            }
        }
    }

    @State private var showRecoveryInfo = false

    private var accountSection: some View {
        Section("Account") {
            NavigationLink(destination: ProfileView()) {
                HStack(spacing: 12) {
                    ZStack {
                        SwiftUI.Circle()
                            .fill(.blue.opacity(0.2))
                            .frame(width: 50, height: 50)

                        Text(authManager.currentUser?.displayName?.prefix(1).uppercased() ?? "?")
                            .font(.title2)
                            .fontWeight(.semibold)
                            .foregroundStyle(.blue)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(authManager.currentUser?.displayName ?? "User")
                            .fontWeight(.medium)
                        Text(authManager.currentUser?.email ?? "")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            // Effective premium tier badge
                            // — the server's
                            // /users/me/premium endpoint
                            // drives "Premium · Circle" (a
                            // circle peer is subscribed)
                            // vs "Premium" (own) vs
                            // "Free". Tints for any
                            // non-Free state. Mirrors
                            // the Android app's
                            // tvSubscriptionTier.
                            let isPaid = premiumManager.tierLabel != "Free"
                            Text(premiumManager.tierLabel)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(
                                    isPaid ? Color.blue.opacity(0.15) : Color.gray.opacity(0.15)
                                ))
                                .foregroundStyle(isPaid ? Color.blue : Color.secondary)
                            // Env badge — matches Android's tvEnvironment ("DEV").
                            // Also shown in ReleaseDev so a TestFlight tester can
                            // see the build talks to the development backend.
                            #if DEBUG || RELEASE_DEV
                            Text("DEV")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.orange.opacity(0.15)))
                                .foregroundStyle(.orange)
                            #endif
                        }
                    }
                }
            }

            // Recovery lives here rather than in a section of its own: it
            // is an account action, and this card is where someone looks.
            recoveryEmailRow
        }
    }

    /// Recovery address: one control, and the explanation behind an info button.
    ///
    /// Sits directly under Account because that is what it is about, and
    /// because a recovery address is only worth anything if it is added BEFORE
    /// the lockout — burying it would mean the people who need it never find
    /// it. It is managed only in the account portal, so without this row a
    /// phone-first user would have no way to learn it exists.
    ///
    /// A link-out, not a form. Setting, verifying and consuming a recovery
    /// address all stay in the portal's single implementation — see the note
    /// on `RecoveryEmailStatus` for why a second one is a bad trade in this
    /// particular flow.
    ///
    /// The row's only job is to open the portal, so the prose lives in a
    /// popover, which is where a sentence you read once belongs, and the
    /// status summary goes with it.
    private var recoveryEmailRow: some View {
        HStack {
            if let settingsURL = AppConfiguration.shared.recoverySettingsURL {
                Link(destination: settingsURL) {
                    Label {
                        HStack {
                            Text("Manage recovery email")
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "envelope.badge.shield.half.filled")
                            .foregroundStyle(Color.accentColor)
                    }
                }
                // Without this the Link tints its whole label blue and the row
                // stops looking like its neighbours. The arrow is what says
                // "this opens a web page" (in the app, `InAppSafari`).
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings-recovery-email")
            }

            Button {
                showRecoveryInfo = true
            } label: {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
            }
            // .plain, or the Button steals the whole row's tap target inside a
            // Form and the Link above stops being reachable.
            .buttonStyle(.plain)
            .accessibilityLabel("What is a recovery email?")
            .accessibilityIdentifier("settings-recovery-email-info")
            .popover(isPresented: $showRecoveryInfo) {
                // Status first, then what a recovery address is
                // for. Status leads because it is the question
                // someone opens this to answer; the explanation
                // is the same every time and the state is not.
                // Orange marks "needs attention".
                let status = RecoveryEmailStatus.resolve(
                    address: authManager.currentUser?.recoveryEmail,
                    verified: authManager.currentUser?.recoveryEmailVerified
                )
                // Every Text takes its full height. Inside a
                // width-constrained popover SwiftUI will
                // otherwise truncate rather than grow,
                // ellipsing the popover's own explanation —
                // the one thing it exists to say.
                VStack(alignment: .leading, spacing: 10) {
                    Text(status.summary)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(status.needsAttention ? Color.orange : Color.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("recovery-email-status")
                    Text(status.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Divider()
                    Text(RecoveryCopy.scope)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding()
                .frame(maxWidth: 320)
                .presentationCompactAdaptation(.popover)
            }
        }
    }
    /// Mirrors the Android app's merged "Security &amp; Devices" card.
    /// Encryption and Devices are one section rather than a single-row
    /// section each, which would cost two headers for two rows in the
    /// middle of the list.
    private var securityAndDevicesSection: some View {
        Section("Security & Devices") {
            NavigationLink(destination: MyKeysView()) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Security details")
                        Text("What other members compare to confirm it's you")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "key.fill")
                }
            }
            NavigationLink(destination: DeviceManagementView()) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Manage Devices")
                        Text("Sign devices out and review what's registered to this account")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "iphone.gen3")
                }
            }
            // People who may not invite this account to a
            // circle. The words are in `BlockedPeople`.
            NavigationLink(destination: BlockedPeopleView()) {
                Label {
                    Text(BlockedPeople.title)
                } icon: {
                    Image(systemName: "person.crop.circle.badge.xmark")
                }
            }
        }
    }

    private var appearanceSection: some View {
        Section("Appearance") {
            Picker(selection: $themeRaw) {
                Text("System").tag("system")
                Text("Light").tag("light")
                Text("Dark").tag("dark")
            } label: {
                Label("Theme", systemImage: "paintbrush.fill")
            }
            .pickerStyle(.segmented)
        }
    }

    private var appLockSection: some View {
        Section("App Lock & Privacy") {
            // ONE row, and it describes the screen it opens: a
            // biometric toggle, Require on Launch, and
            // Auto-Lock. There is no PIN anywhere in this app,
            // so the row promises none, and one destination is
            // never shown as two different settings.
            NavigationLink(destination: SecuritySettingsView()) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("App Lock")
                        Text("Lock the app with Face ID, Touch ID or your device passcode")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "lock.fill")
                }
            }
            // Two-factor authentication lives on the account portal, so this
            // is a link that leaves the app. A local switch not backed by the
            // server would let somebody turn it on, watch it stay on, and be
            // protected by nothing — while the Terms say two-factor is what
            // stops a stolen mailbox completing a password reset. A link that
            // leaves the app is worth more than a switch that lies.
            if let securityURL = AppConfiguration.shared.securitySettingsURL {
                Link(destination: securityURL) {
                    Label {
                        HStack {
                            Text("Two-Factor Authentication")
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "lock.shield.fill")
                    }
                }
            }
            // Block screenshots / screen recording — Android FLAG_SECURE
            // counterpart. Toggling this poisons screenshot capture
            // (via a UITextField.isSecureTextEntry trick) and blacks
            // out the UI during in-progress screen recordings.
            Toggle(isOn: $blockScreenshots) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Block Screenshots & Recording")
                        Text("Hide sensitive content from screenshots and screen recording")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "eye.slash.fill")
                }
            }
            .onChange(of: blockScreenshots) { _, enabled in
                ScreenshotBlocker.shared.setEnabled(enabled)
            }
        }
    }

    /// One row in the per-category notification list.
    struct PushCategory: Identifiable {
        /// The server's preference field for this category.
        let key: String
        let title: String
        let icon: String
        /// The server will deliver this family whatever the column says, so the
        /// row is shown LOCKED rather than as a switch. See
        /// `undeniableCategoryNote`.
        var undeniable: Bool = false
        var id: String { key }
    }

    /// Why the locked row cannot be switched off.
    ///
    /// Shown in the row itself, not in a Section footer: SwiftUI renders only
    /// the FIRST view of a footer, so putting the reason there is how the
    /// reason disappears.
    ///
    /// Never says "SOS" or "Emergency alert" — the product's name for the
    /// feature is "notify my circle", and the same rule that governs the row
    /// title governs this: Track does not summon anyone and the Terms say so,
    /// so the copy that explains why this row is locked must not promise an
    /// emergency service either.
    ///
    /// It also says the e-mail. A circle notification is e-mailed to every
    /// member with an address whatever `sos_email` or "Email notifications"
    /// say, so the web shows that e-mail locked too; this row is where iOS
    /// says so.
    static let undeniableCategoryNote =
        "Always on. A circle notification, and the all-clear that clears it, can't be turned off. "
        + "A circle notification is also always emailed to you."

    /// The per-category push columns this screen drives, in display order.
    ///
    /// Titles are web's, so the three clients describe the same server column
    /// the same way. Two deliberate notes:
    ///   - `sos_push` is "Circle notifications". The Android app labels it
    ///     "SOS alerts"; web and iOS do not, and the product's name for the
    ///     feature is not SOS. Do not use that label here.
    ///     It is also `undeniable`: see below.
    ///   - `safety_alert_push` is "Alert rules" (web's name, and what iOS's own
    ///     AlertRulesManager calls them). Android says "Safety alerts" for the
    ///     same column.
    ///
    /// `destination_push` covers both destination_shared and
    /// destination_arrival, and there is no destination_email column, so that
    /// row is push-only everywhere.
    ///
    /// `check_in_push` is "Check-ins": a real server column that gates
    /// check-in pushes. Push-only, like Destinations and for the same reason:
    /// nothing sends a check-in by email, so there is no `check_in_email`
    /// column and a second switch would have no channel behind it.
    ///
    /// `sos_push` IS SHOWN BUT LOCKED. It governs nothing: the server treats
    /// the whole emergency exchange (the raise, its acknowledgements and its
    /// resolution) as undeniable, bypassing the global switch, quiet hours AND
    /// the per-category column — and decides that BEFORE the preferences are
    /// loaded, so a failed preferences query cannot silence an emergency
    /// either. A live switch over that column would render a promise the
    /// system will not keep.
    ///
    /// It is not DELETED, for two reasons. Someone hunting for the switch
    /// should learn why it is not there instead of finding a silent gap; and a
    /// bare gap invites a later "restore the missing row", which would make
    /// emergencies deniable. The lock is the documentation.
    static let pushCategories: [PushCategory] = [
        PushCategory(key: "circle_invite_push", title: "Circle invites", icon: "envelope.badge"),
        PushCategory(key: "member_joined_push", title: "Member joined", icon: "person.badge.plus"),
        PushCategory(key: "place_alert_push", title: "Place Alerts", icon: "mappin.circle.fill"),
        PushCategory(key: "safety_alert_push", title: "Alert rules", icon: "bell.badge"),
        PushCategory(key: "sos_push", title: "Circle notifications", icon: "exclamationmark.triangle",
                     undeniable: true),
        PushCategory(key: "destination_push", title: "Destinations", icon: "flag.fill"),
        PushCategory(key: "check_in_push", title: "Check-ins", icon: "hand.wave.fill"),
    ]

    /// Resolve a per-category push override against the global switch.
    ///
    /// Exactly the web client's `resolvedPush` and the Android app's
    /// `prefs[key] as? Boolean ?: pushEnabled`: an explicit true/false wins,
    /// JSON `null` (an untouched category — it arrives as NSNull, so
    /// `as? Bool` is nil) inherits the global, and a server that has never
    /// stored a row for this user defaults to on.
    static func resolvedPush(_ prefs: [String: Any], _ key: String) -> Bool {
        if let value = prefs[key] as? Bool { return value }
        return prefs["push_enabled"] as? Bool ?? true
    }

    /// The email channel's default is OFF, not on — the server seeds
    /// `email_enabled: false`. Kept separate from `resolvedPush` so the two
    /// defaults cannot drift into each other.
    static func resolvedEmail(_ prefs: [String: Any], _ key: String) -> Bool {
        if let value = prefs[key] as? Bool { return value }
        return prefs["email_enabled"] as? Bool ?? false
    }

    /// One server-backed switch. `resolve` is the read side so the same row
    /// works for a global channel and for a category that inherits from one.
    @ViewBuilder
    private func notificationToggle(
        _ title: String,
        systemImage: String,
        key: String,
        resolve: @escaping ([String: Any], String) -> Bool
    ) -> some View {
        Toggle(isOn: Binding(
            get: { resolve(notificationPrefs, key) },
            set: { newValue in
                // Ignore the initial programmatic load (and any set before
                // prefs have landed) so we don't PUT a stale default back
                // over the server's real value.
                guard notificationPrefsLoaded,
                      newValue != resolve(notificationPrefs, key) else { return }
                setNotificationPreference(key, newValue)
            }
        )) {
            Label(title, systemImage: systemImage)
        }
        // A switch that cannot yet know its own value must not be flippable:
        // the guard above would silently swallow the tap, which reads as a
        // broken control.
        .disabled(!notificationPrefsLoaded)
        .accessibilityIdentifier("notification-pref-\(key)")
    }

    /// A category the server will deliver whatever the preference says.
    ///
    /// Rendered as the same switch as its neighbours, pinned ON and disabled,
    /// with the reason underneath — so the row reads as "this exists, it is on,
    /// and you cannot change it" rather than as a control that quietly ignores
    /// you. It is deliberately NOT bound to `notificationPrefs`: the stored
    /// column is not what decides delivery, and showing its value here would be
    /// the same lie in a different position.
    @ViewBuilder
    private func lockedNotificationRow(_ category: PushCategory) -> some View {
        Toggle(isOn: .constant(true)) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(category.title)
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    Text(Self.undeniableCategoryNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: category.icon)
            }
        }
        .disabled(true)
        .accessibilityIdentifier("notification-pref-\(category.key)")
    }

    @ViewBuilder
    private var pushNotificationsSection: some View {
        Section {
            notificationToggle("Push Notifications",
                               systemImage: "bell.fill",
                               key: "push_enabled",
                               resolve: Self.resolvedPush)
            // Global "Email notifications" delivery channel, backed by
            // GET/PUT /notifications/preferences. Mirrors the web
            // client's Global Delivery → Email switch and the Android
            // app.
            notificationToggle("Email notifications",
                               systemImage: "envelope.fill",
                               key: "email_enabled",
                               resolve: Self.resolvedEmail)
            // Signal-style display verbosity — how much decrypted
            // content lands on the lock screen. Mirrors the Android
            // app.
            Picker(selection: $settings.notificationDetailLevel) {
                ForEach(NotificationDetailLevel.allCases) { level in
                    Text(level.label).tag(level)
                }
            } label: {
                Label("Notification detail", systemImage: "eye")
            }
        } header: {
            Text("Notification Delivery")
        } footer: {
            Text("Notification detail: \(settings.notificationDetailLevel.example). The app's notification list follows this setting too; at Generic it keeps the standard wording.")
        }

        Section {
            // A ROW, not a footer. A footer would be the natural place, but
            // SwiftUI renders only the first view of a Section footer and does
            // not reliably deliver taps to a control inside one — and this
            // needs a working button, or the switches stay inert with no way
            // out.
            if notificationPrefsError != nil {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Loading your notification settings…")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                    }
                    Text("The switches here show defaults, not your settings, until they load, and changing one does nothing until then. This finishes by itself.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                .accessibilityIdentifier("notification-prefs-loading")
            }
            ForEach(Self.pushCategories) { category in
                if category.undeniable {
                    lockedNotificationRow(category)
                } else {
                    notificationToggle(category.title,
                                       systemImage: category.icon,
                                       key: category.key,
                                       resolve: Self.resolvedPush)
                }
            }
        } header: {
            Text("Notification Categories")
        } footer: {
            // One of the rows is locked on, so the sentence has to say which
            // rows it is talking about.
            Text("Categories you can change follow Push Notifications above until you set them here. Per-category email delivery is set on the web.")
        }
    }

    private var geocodingSection: some View {
        Section {
            // Server gates this on circle-effective premium and
            // returns 402 otherwise — match that here. Disabled +
            // dimmed for non-premium so the control reflects the
            // server's behaviour without naming a purchasable tier
            // or steering to an upgrade flow. Mirrors the Android app.
            Toggle(isOn: $useServerGeocoder) {
                HStack {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            // Title matches the Android app, where a
                            // "Use" prefix ellipsized on narrow RelativeLayouts.
                            // iOS has more room, but the intent is parity.
                            Text("Server-side geocoder")
                            Text(useServerGeocoder
                                 ? "Pelias gateway, hosted lookup"
                                 : "Offline tiles, on-device")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "globe")
                    }
                    Button {
                        showingGeocoderInfo = true
                    } label: {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("About the server-side geocoder")
                }
            }
            .disabled(!premiumManager.effectivePremium)
            .opacity(premiumManager.effectivePremium ? 1.0 : 0.5)

        } header: {
            Text("Geocoding")
        }
        .alert("Server-side geocoder", isPresented: $showingGeocoderInfo) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Look up addresses and places from our hosted geocoder instead of on-device data.\n\nYour search text and the coordinates you look up are sent to our server. Requests carry no account identifier, and coordinates are rounded to about 10 metres before they are sent, so the server does not link queries to you or your account.\n\nWhen this is off, nothing about your searches leaves the device — lookups use map data downloaded to your phone.")
        }
    }

    /// Banner shown when the user has When-In-Use but not Always.
    /// Background pumps (SLC + Visit + allowsBackgroundLocationUpdates)
    /// silently no-op without Always; the user otherwise has no signal
    /// that their marker freezes the moment they leave the app. First
    /// tap calls requestAlwaysAuthorization (iOS will show the prompt
    /// once); subsequent taps deep-link into Settings since iOS
    /// suppresses the second native prompt.
    @ViewBuilder
    private var backgroundLocationUpgradeBanner: some View {
        // `== .whenInUse`, not `authorizationStatus == .authorizedWhenInUse`:
        // reduced accuracy outranks this, so "While Using" + Precise Off
        // lights one banner, not both at once.
        if locationWarning == .whenInUse {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Background tracking is off", systemImage: "location.slash.fill")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.orange)
                    Text("Track currently only updates your location while the app is open. Enable \"Always\" so your circles can see your location during drives, walks, and stops.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        upgradeToAlwaysLocation()
                    } label: {
                        Label(
                            alwaysPromptAvailable ? "Enable Background Tracking" : "Open Settings",
                            systemImage: "location.fill.viewfinder"
                        )
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                }
                .padding(.vertical, 4)
            }
        }
    }

    /// Banner shown when location is granted but "Precise Location" is off.
    ///
    /// iOS then coarsens every fix to kilometre scale, and the accuracy filter
    /// in `LocationService.didUpdateLocations` rejects all of them — so the
    /// user disappears from their circle's map while their permission still
    /// reads "Always" and nothing anywhere says why. Their family sees them
    /// simply stop moving.
    ///
    /// Same shape as the when-in-use banner above, deliberately. First tap
    /// asks iOS for temporary full accuracy; once that has been declined iOS
    /// suppresses the prompt, so later taps deep-link to Settings, where the
    /// permanent switch lives.
    @ViewBuilder
    private var preciseLocationUpgradeBanner: some View {
        if locationWarning == .reducedAccuracy {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Your circle can't see you", systemImage: "location.slash.fill")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.orange)
                    Text("Precise Location is off, so iOS only tells Track roughly which area you are in — too coarse to put you on your circle's map. Turn it on to start appearing again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        upgradeToPreciseLocation()
                    } label: {
                        Label(
                            precisePromptAvailable ? "Turn On Precise Location" : "Open Settings",
                            systemImage: "scope"
                        )
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .accessibilityIdentifier("precise-location-upgrade")
                }
                .padding(.vertical, 4)
            }
        }
    }

    /// The single ranked answer to "what is wrong with location permission",
    /// shared with the Map banner so the two surfaces cannot disagree.
    private var locationWarning: LocationPermissionWarning? {
        LocationPermissionWarning.resolve(
            status: locationService.authorizationStatus,
            hasReducedAccuracy: locationService.hasReducedAccuracy
        )
    }

    /// Whether each native prompt is still available. Mirrors the gates in
    /// `upgradeToAlwaysLocation` / `upgradeToPreciseLocation` so a button's
    /// words and its action cannot drift apart.
    private var alwaysPromptAvailable: Bool {
        !UserDefaults.standard.bool(forKey: LocationService.alwaysPromptAttemptedKey)
    }

    private var precisePromptAvailable: Bool {
        !UserDefaults.standard.bool(forKey: LocationService.precisePromptAttemptedKey)
    }

    /// First tap: the native temporary-accuracy prompt. Later taps: deep-link
    /// to Settings, since iOS suppresses that prompt once it has been
    /// declined. The flag is only set on a DECLINE — a temporary grant expires,
    /// and the next lapse deserves the same one-tap path rather than a trip to
    /// Settings.
    private func upgradeToPreciseLocation() {
        let attempted = UserDefaults.standard.bool(forKey: LocationService.precisePromptAttemptedKey)
        if attempted {
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        } else {
            locationService.requestTemporaryFullAccuracy()
        }
    }

    /// First tap: native iOS prompt (one-shot per install). Later
    /// taps: deep-link to Settings since iOS won't re-show the prompt
    /// after the user dismissed it once. The
    /// `location.alwaysPromptAttempted` flag is also set when
    /// onboarding fires the same prompt, so a returning user who
    /// said "Keep While Using" during onboarding lands on the
    /// Settings deep-link immediately.
    private func upgradeToAlwaysLocation() {
        let attempted = UserDefaults.standard.bool(forKey: LocationService.alwaysPromptAttemptedKey)
        if attempted && locationService.authorizationStatus == .authorizedWhenInUse {
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        } else {
            // LocationService writes the flag, and only from a status that can
            // raise the dialog.
            locationService.requestAlwaysAuthorization()
        }
    }

    /// Seed every notification switch from the server. True once loaded.
    ///
    /// A failure leaves the switches disabled rather than blocking the screen,
    /// and crucially can never be written back — an unreachable server must not
    /// end up overwriting real preferences with this screen's defaults. The
    /// failure is said, not swallowed — a row of switches that is silently
    /// inert is the same failure this whole section exists to remove — and the
    /// caller loads again by itself (`RetryClock`). Mirrors the Android app
    /// reading the preferences map on open.
    private func loadNotificationPreferences() async -> Bool {
        do {
            notificationPrefs = try await APIService.shared.getNotificationPreferences()
            notificationPrefsLoaded = true
            notificationPrefsError = nil
            return true
        } catch {
            print("[Track] notification settings did not load: \(error)")
            notificationPrefsError = error.plainText
            return false
        }
    }

    /// Read-modify-write ONE notification preference. Re-fetches the FULL
    /// current map, sets `key`, and PUTs the whole thing back, so the fields
    /// this screen does not show — per-category email overrides, quiet hours —
    /// survive, and so does a change made from another device between the
    /// screen opening and this tap. On failure, revert and surface the error.
    /// Mirrors the Android app's onCheckedChange handler.
    ///
    /// Fields the server left null stay null: they round-trip as NSNull, and
    /// the server COALESCEs a null onto the stored value, so PUTting
    /// the map back never collapses an inherited category into an explicit one.
    private func setNotificationPreference(_ key: String, _ enabled: Bool) {
        let previous = notificationPrefs
        // Optimistic, so the switch moves under the finger.
        notificationPrefs[key] = enabled
        Task {
            do {
                var prefs = try await APIService.shared.getNotificationPreferences()
                prefs[key] = enabled
                try await APIService.shared.updateNotificationPreferences(prefs)
                notificationPrefs = prefs
            } catch {
                // Revert the optimistic flip and tell the user.
                notificationPrefs = previous
                ErrorBanner.shared.post(error)
            }
        }
    }

    private var locationTrackingSection: some View {
        Section("Location Tracking") {
            HStack {
                Label("Status", systemImage: "location.fill")
                Spacer()
                Text(locationStatusText)
                    .foregroundStyle(.secondary)
            }

            Picker(selection: $locationIntervalSec) {
                Text("10s").tag(10)
                Text("30s").tag(30)
                Text("1 min").tag(60)
                Text("5 min").tag(300)
                Text("10 min").tag(600)
                Text("15 min").tag(900)
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Send on time interval")
                        Text("Send location at a regular time interval")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "clock.fill")
                }
            }

            Picker(selection: $locationDistanceMeters) {
                Text("50m").tag(50)
                Text("100m").tag(100)
                Text("250m").tag(250)
                Text("500m").tag(500)
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Send on distance")
                        Text("Send when you move beyond a distance threshold")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "ruler")
                }
            }

            Toggle(isOn: $locationBatchUploads) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Batch Uploads")
                        Text("Queue locations and sync periodically")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "arrow.up.arrow.down")
                }
            }

            Toggle(isOn: $settings.batterySaverEnabled) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Battery Saver")
                        Text("Reduce battery usage from location tracking")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "battery.100")
                }
            }

            // No global "Pause Tracking" toggle here: pausing is PER
            // CIRCLE, server-backed via PrivacySettings.pausedUntil,
            // under Circles → a circle → Privacy Settings → Pause
            // Sharing. A second, global, local-only switch would not
            // be that feature — and the one thing worse than no pause
            // control is two, one of which lies.
            //
            // Installs of older builds may hold an @AppStorage
            // "location.paused" = true that nothing reads. Do NOT wire
            // that key up to a real pause: it would silently pause
            // everyone who ever flipped that switch.
            NavigationLink(destination: LocationPermissionsView()) {
                Label("Permissions", systemImage: "lock.shield")
            }
        }
        // The three tracking knobs apply to the RUNNING session: read only
        // by startTracking(), a change would take effect at the next
        // sign-in or process restart, and the row would be wrong until
        // then.
        .onChange(of: settings.batterySaverEnabled) { _, _ in
            locationService.applyTrackingSettingsChange()
        }
        .onChange(of: locationIntervalSec) { _, _ in
            locationService.applyTrackingSettingsChange()
        }
        .onChange(of: locationDistanceMeters) { _, _ in
            locationService.applyTrackingSettingsChange()
        }
    }

    private var diagnosticsSection: some View {
        Section("Diagnostics") {
            Toggle(isOn: $crashReportingEnabled) {
                Label("Crash Reporting", systemImage: "ladybug.fill")
            }
        }
    }

    private var dataExportSection: some View {
        Section("Data Export") {
            NavigationLink(destination: DataExportView()) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Export My Data")
                        Text("Download your location history and data")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
    }

    // MARK: - iOS-only sections (kept below the Android-mirrored block)

    private var activitySection: some View {
        Section("Activity") {
            NavigationLink(destination: NotificationsView()) {
                HStack {
                    Label("Inbox", systemImage: "tray.fill")
                    Spacer()
                    if NotificationsManager.shared.unreadCount > 0 {
                        Text("\(NotificationsManager.shared.unreadCount)")
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.red))
                            .foregroundStyle(.white)
                    }
                }
            }
            NavigationLink(destination: DestinationsView()) {
                Label("Destinations", systemImage: "location.north.circle.fill")
            }
            NavigationLink(destination: CheckInHistoryView()) {
                Label("Check-in History", systemImage: "clock.arrow.circlepath")
            }
            NavigationLink(destination: AlertsView()) {
                Label("Alerts", systemImage: "bell.badge")
            }
        }
    }

    private var privacySection: some View {
        // The two documents, nothing else.
        Section("Legal") {
            NavigationLink(destination: PrivacyPolicyView()) {
                Label("Privacy Policy", systemImage: "hand.raised.fill")
            }
            // The Terms, as in the purchase sheet: the same
            // published page, opened in Safari.
            Link(destination: StoreKitManager.Legal.terms) {
                Label("Terms of Service", systemImage: "doc.text")
            }
        }
    }

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version", value: Bundle.main.appVersion)
            LabeledContent("Build", value: Bundle.main.buildNumber)
            NavigationLink(destination: OpenSourceLicensesView()) {
                Label("Open Source Licenses", systemImage: "doc.plaintext")
            }
        }
    }

    private var accountActionsSection: some View {
        Section {
            Button(action: {
                if let me = authManager.userId { pendingChanges.use(account: me) }
                showingLogoutConfirm = true
            }) {
                Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
            }
            .foregroundStyle(.red)

            Button(action: { showingDeleteAccountConfirm = true }) {
                Label("Delete Account", systemImage: "trash")
            }
            .foregroundStyle(.red)
        }
    }

    var locationStatusText: String {
        // Reduced accuracy is qualified INTO the grant rather than
        // replacing it: the permission really is "Always", and
        // reporting a bare "Always" to someone whose every fix is
        // being discarded would hide the problem.
        let suffix = locationService.hasReducedAccuracy ? " (Approximate)" : ""
        switch locationService.authorizationStatus {
        case .authorizedAlways: return "Always" + suffix
        case .authorizedWhenInUse: return "While Using" + suffix
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        case .notDetermined: return "Not Set"
        @unknown default: return "Unknown"
        }
    }
}


struct ProfileView: View {
    @StateObject private var authManager = AuthManager.shared
    @State private var displayName: String = ""
    @State private var isEditing = false
    @State private var isSaving = false
    @State private var saveError: String?

    var body: some View {
        List {
            Section {
                // Avatar
                HStack {
                    Spacer()
                    ZStack {
                        SwiftUI.Circle()
                            .fill(.blue.opacity(0.2))
                            .frame(width: 100, height: 100)

                        Text(authManager.currentUser?.displayName?.prefix(1).uppercased() ?? "?")
                            .font(.system(size: 40))
                            .fontWeight(.semibold)
                            .foregroundStyle(.blue)
                    }
                    Spacer()
                }
                .listRowBackground(Color.clear)
            }

            Section("Profile") {
                if isEditing {
                    TextField("Display Name", text: $displayName)
                } else {
                    LabeledContent("Display Name", value: authManager.currentUser?.displayName ?? "")
                }

                LabeledContent("Email", value: authManager.currentUser?.email ?? "")
            }

            Section {
                LabeledContent("Member Since", value: authManager.currentUser?.createdAt.formatted(date: .abbreviated, time: .omitted) ?? "")
                LabeledContent("User ID", value: String(authManager.currentUser?.id.prefix(8) ?? ""))
            }
        }
        .navigationTitle("Profile")
        .alert("Couldn't Save", isPresented: .constant(saveError != nil)) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if isEditing {
                    Button("Save") {
                        saveChanges()
                    }
                    .disabled(isSaving)
                } else {
                    Button("Edit") {
                        displayName = authManager.currentUser?.displayName ?? ""
                        isEditing = true
                    }
                }
            }
        }
    }

    private func saveChanges() {
        isSaving = true
        Task {
            do {
                try await authManager.updateDisplayName(displayName)
                // Only leave edit mode on success. Closing the field on a
                // failure discards what the user typed as well as hiding the
                // failure.
                isEditing = false
            } catch {
                // Not `try? await …`, which would swallow the
                // error whole: the field would close, the name
                // on screen would revert to the previous one,
                // and nothing would be said.
                saveError = error.plainText
            }
            isSaving = false
        }
    }
}

struct LocationPermissionsView: View {
    @StateObject private var locationService = LocationService.shared

    var body: some View {
        List {
            Section {
                HStack {
                    Text("Current Permission")
                    Spacer()
                    Text(permissionText)
                        .foregroundStyle(permissionColor)
                }
            }

            Section {
                Text("Track needs \"Always\" location permission to share your location with your circles even when the app is in the background.")
                    .foregroundStyle(.secondary)
                if locationService.hasReducedAccuracy {
                    Text("It also needs Precise Location. With that off, iOS reports your position to within kilometres, which is too coarse to place you on your circle's map — so you stop appearing on it.")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            }
        }
        .navigationTitle("Location Permissions")
    }

    var permissionText: String {
        // Same qualification as the Settings status row: a bare
        // "Always" while every fix is being discarded for
        // coarseness would hide the problem.
        let suffix = locationService.hasReducedAccuracy ? " (Approximate)" : ""
        switch locationService.authorizationStatus {
        case .authorizedAlways: return "Always" + suffix
        case .authorizedWhenInUse: return "While Using" + suffix
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        case .notDetermined: return "Not Set"
        @unknown default: return "Unknown"
        }
    }

    var permissionColor: Color {
        // Green means "this is working". Reduced accuracy is not working, even
        // on an Always grant.
        if locationService.hasReducedAccuracy { return .orange }
        switch locationService.authorizationStatus {
        case .authorizedAlways: return .green
        case .authorizedWhenInUse: return .orange
        default: return .red
        }
    }
}

/// The system sheet's line when App Lock is made weaker, one for each of
/// Android's three cases, in the unlock's "Authenticate to …" shape.
enum AppLockProofCopy {
    static let turnOff = "Authenticate to turn off App Lock"
    static let requireOnLaunchOff = "Authenticate to change App Lock"
    static let autoLockLater = "Authenticate to change when Track locks"
}

struct SecuritySettingsView: View {
    @StateObject private var settings = UserSettings.shared
    @State private var biometricType: LABiometryType = .none

    var body: some View {
        List {
            Section("App Lock") {
                Toggle(isOn: Binding(
                    get: { settings.biometricEnabled },
                    set: { on in
                        change(weakens: !on, reason: AppLockProofCopy.turnOff) { settings.biometricEnabled = on }
                    }
                )) {
                    Label(biometricLabel, systemImage: biometricIcon)
                }

                Toggle(isOn: Binding(
                    get: { settings.requireAuthOnLaunch },
                    set: { on in
                        change(weakens: !on, reason: AppLockProofCopy.requireOnLaunchOff) {
                            settings.requireAuthOnLaunch = on
                        }
                    }
                )) {
                    Label("Require on Launch", systemImage: "lock.fill")
                }
                .disabled(!settings.biometricEnabled)
            }

            Section("Session") {
                Picker("Auto-Lock", selection: Binding(
                    get: { settings.autoLockTimeout },
                    set: { choice in
                        change(weakens: AppLockRule.locksLater(choice, than: settings.autoLockTimeout),
                               reason: AppLockProofCopy.autoLockLater) { settings.autoLockTimeout = choice }
                    }
                )) {
                    Text("Immediately").tag(0)
                    Text("1 minute").tag(60)
                    Text("5 minutes").tag(300)
                    Text("15 minutes").tag(900)
                    Text("Never").tag(AppLockRule.never)
                }
                // Like "Require on Launch": it times App Lock, so without App
                // Lock it would change nothing.
                .disabled(!settings.biometricEnabled)
            }
        }
        .navigationTitle("Security")
        .onAppear {
            checkBiometricType()
        }
    }

    /// A change that leaves Track less locked takes effect only once the
    /// device's owner has proven it (`proveForAppLockChange`). Until then, and
    /// if they don't, the control shows what still holds, and nothing is said.
    /// A stronger lock applies at once.
    private func change(weakens: Bool, reason: String, _ apply: @escaping () -> Void) {
        guard weakens else {
            apply()
            return
        }
        settings.objectWillChange.send()
        Task { @MainActor in
            if await AuthManager.shared.proveForAppLockChange(reason: reason) {
                apply()
            }
        }
    }

    var biometricLabel: String {
        switch biometricType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "Biometric Authentication"
        }
    }

    var biometricIcon: String {
        switch biometricType {
        case .faceID: return "faceid"
        case .touchID: return "touchid"
        default: return "lock.fill"
        }
    }

    private func checkBiometricType() {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        biometricType = context.biometryType
    }
}


/// The privacy policy, shown in-app from a bundled copy.
///
/// The document ships INSIDE the app, so it opens with no network and no
/// dependency on a website being reachable: `App/Resources/privacy-policy.html`
/// is the website's own no-JavaScript rendering of the policy (generated from
/// the same component the site serves, never transcribed), loaded offline in a
/// WKWebView. Links inside it that leave the document open in Safari.
struct PrivacyPolicyView: View {
    var body: some View {
        LegalDocumentView(resource: "privacy-policy")
            .navigationTitle("Privacy Policy")
            .navigationBarTitleDisplayMode(.inline)
    }
}

/// Renders a bundled legal document (a self-contained HTML file) offline.
struct LegalDocumentView: UIViewRepresentable {
    /// Resource name without the `.html` extension.
    let resource: String

    /// Where the bundled document lives, or nil when the build forgot to ship it —
    /// exposed so a unit test can fail on that instead of a user seeing a blank screen.
    static func bundledURL(for resource: String, in bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: resource, withExtension: "html")
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // The document carries the website's header/footer navigation, whose
        // links point at site routes that mean nothing offline. Hide that chrome
        // and let the text fill the screen; the policy text itself is untouched.
        let hideChrome = WKUserScript(
            source: "var s=document.createElement('style');s.textContent='header,footer,nav{display:none !important}';document.documentElement.appendChild(s);",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(hideChrome)
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        if let url = Self.bundledURL(for: resource) {
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            web.loadHTMLString("<p style=\"font-family:-apple-system;padding:24px\">This document is missing from the app bundle.</p>", baseURL: nil)
        }
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Keeps the web view on the bundled document: any link that leaves it
    /// (website routes, mailto:) is handed to the system instead.
    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else { decisionHandler(.allow); return }
            if url.isFileURL || navigationAction.navigationType != .linkActivated {
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)
            UIApplication.shared.open(url)
        }
    }
}

/// Export the account's data to a file the user keeps.
///
/// The Terms tell people to export before a deadline, so an
/// iPhone-only user needs a real export here.
///
/// The work is in `DataExportService`: page the API, decrypt on the device,
/// write the same file the web and Android write.
struct DataExportView: View {
    @State private var range: Range = .days30
    @State private var isExporting = false
    @State private var errorMessage: String?
    /// Blank keeps the readable file; anything else seals it.
    @State private var exportPassphrase: String = ""
    @State private var built: ExportedFile?

    /// What a sealed backup is, and where it can actually be opened.
    ///
    /// The notice does not claim that a sealed file opens on any Pingolin app.
    /// Track for iOS has no import path whatsoever — no
    /// `CFBundleDocumentTypes` in project.yml, no `onOpenURL`, no file picker,
    /// nothing that parses the format — so the one app the user is reading
    /// this sentence in is the one that cannot open what it just produced.
    /// The Android app restores configuration only (places, privacy and
    /// preferences, alerts — never history or check-ins). The website is the
    /// only surface with a full restore, so it is the only one named.
    ///
    /// Hoisted out of the view so the claim is testable — see
    /// ExportFooterCopyTests.
    static let sealedFileNotice =
        "With a passphrase the backup is sealed and only that passphrase opens it. "
        + "We cannot recover it. To restore from a backup, open the file on the Pingolin "
        + "website — Track for iPhone can write a backup but cannot read one back in."

    enum Range: String, CaseIterable, Identifiable {
        case days7 = "Last 7 days"
        case days30 = "Last 30 days"
        case days90 = "Last 90 days"
        case days365 = "Last year"

        var id: String { rawValue }

        var days: Int {
            switch self {
            case .days7: return 7
            case .days30: return 30
            case .days90: return 90
            case .days365: return 365
            }
        }
    }

    /// Wraps the built file so `.sheet(item:)` can drive the share sheet.
    struct ExportedFile: Identifiable {
        let id = UUID()
        let url: URL
        let counts: [String: Int]
    }

    var body: some View {
        List {
            Section {
                Text("You can export a copy of all your data stored in Track — your devices, circles, places, check-ins and location history.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Period", selection: $range) {
                    ForEach(Range.allCases) { r in Text(r.rawValue).tag(r) }
                }
            } footer: {
                Text("How much location history to include. Everything else is exported in full.")
            }

            Section {
                Button {
                    Task { await runExport() }
                } label: {
                    HStack {
                        if isExporting { ProgressView().padding(.trailing, 4) }
                        Label(isExporting ? "Exporting…" : "Export My Data", systemImage: "square.and.arrow.up")
                    }
                }
                .disabled(isExporting)
            } footer: {
                // Said plainly, because it is the one property of the file that
                // can hurt someone: it is decrypted. That is what makes it
                // useful — it opens in other tools without needing anything from
                // us — and it is also why it must not be left in a shared folder.
                Text("The file is written in JSON, decrypted on this device. Anyone who opens it can read it, so keep it somewhere safe — or seal it below.")
            }

            Section("Passphrase (optional)") {
                SecureField("Leave blank for a readable file", text: $exportPassphrase)
                    .textContentType(.newPassword)
                    .accessibilityIdentifier("export-passphrase")
                Text(Self.sealedFileNotice)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let err = errorMessage {
                Section {
                    Label(err, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Export Data")
        .sheet(item: $built) { file in
            ShareSheet(items: [file.url])
        }
    }

    private func runExport() async {
        isExporting = true
        errorMessage = nil
        defer { isExporting = false }

        do {
            let service = DataExportService(crypto: SDKCrypto.cryptoManager)
            let today = DataExportService.dayBucket()
            let result = try await service.buildBackup(
                startDayBucket: today - range.days,
                endDayBucket: today,
                passphrase: exportPassphrase.isEmpty ? nil : exportPassphrase
            )

            // Written to a temporary file rather than handed over as
            // Data: the share sheet gives a real file name that way,
            // so what lands in Files or Mail is
            // `pingolin-track-export-YYYY-MM-DD.json` and not an
            // untitled blob the user cannot identify a month later.
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(result.fileName)
            try result.data.write(to: url, options: .atomic)
            built = ExportedFile(url: url, counts: result.sectionCounts)
        } catch {
            errorMessage = error.plainText
        }
    }
}

// MARK: - Bundle Extension

extension Bundle {
    var appVersion: String {
        infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    var buildNumber: String {
        infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }
}

#Preview {
    SettingsView()
}

struct DeleteAccountSheet: View {
    /// What deleting the account does to the circles it owns: the
    /// server deletes them, members, history and all.
    nonisolated static let ownedCirclesText = "Circles you own are deleted for everyone in them, along with all the "
        + "location history they hold. To keep a circle going, transfer its ownership first."

    /// Under "You still have credit", in place of the server's sentence (which
    /// named the amount): the same facts and the same two ways on.
    nonisolated static let unspentCreditText = "Deleting your account destroys the credit on it, and it can't be returned "
        + "afterwards because the record goes with the account. Write to help@support.pingolin.com to have it "
        + "refunded first, or delete anyway."

    @StateObject private var authManager = AuthManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var password: String = ""
    @State private var confirmText: String = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    /// Server's wording when the account still holds bought credit. Non-nil
    /// raises the confirmation below; nothing has been deleted at that point.
    @State private var creditWarning: String?

    var body: some View {
        Form {
            Section {
                Text("Deleting your account permanently removes your profile, places, check-ins and location history. This cannot be undone.")
                    .font(.subheadline)
            }

            // The circles this account owns end with it, for every
            // member: said plainly, with the way to keep one.
            Section {
                Text(Self.ownedCirclesText)
                    .font(.subheadline)
            }

            // The account is the Pingolin account, not a per-app one, and
            // deleting it removes the user's data in every app that hangs
            // off it (Track and Note). Someone
            // deleting from Track has no way to know their notes go with it
            // unless the app says so here, before the button.
            Section {
                Text("This is your Pingolin account, which every Pingolin app shares. Deleting it deletes your data in all of them — Pingolin Track and Pingolin Note — not just this app.")
                    .font(.subheadline)
            }

            // Billing, stated before the button rather than after it. Deleting
            // cancels what the server can cancel; an App Store subscription only
            // the customer can stop, in Apple's settings. Once the account is gone
            // there is no screen left to tell them that on — so it goes here,
            // where they can still act on it.
            Section {
                Text("Deleting your account also cancels your subscription. If you subscribed through the App Store, only you can cancel that - in Settings, tap your name, then Subscriptions. We cannot do it for you.")
                    .font(.subheadline)
            }

            Section("Password") {
                SecureField("Your account password", text: $password)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .disabled(isSubmitting)
            }

            Section {
                TextField("Type DELETE to confirm", text: $confirmText)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
                    .disabled(isSubmitting)
            } footer: {
                Text("Belt-and-braces guard against accidental taps.")
            }

            if let err = errorMessage {
                Section {
                    Label(err, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }

            Section {
                Button(role: .destructive) {
                    Task { await submit() }
                } label: {
                    HStack {
                        if isSubmitting {
                            ProgressView().padding(.trailing, 4)
                        }
                        Text(isSubmitting ? "Deleting…" : "Delete My Account")
                    }
                    .frame(maxWidth: .infinity)
                }
                .disabled(!canSubmit)
            }
        }
        .navigationTitle("Delete Account")
        .navigationBarTitleDisplayMode(.inline)
        // The account still holds credit it paid for. Nothing has been deleted
        // yet — this is the second, deliberate act. "Keep my credit" is the
        // cancel role so it is the safe default, and the destructive one is not
        // the one a stray tap finds.
        .alert(
            "You still have credit",
            isPresented: Binding(
                get: { creditWarning != nil },
                set: { if !$0 { creditWarning = nil } }
            )
        ) {
            Button("Keep my credit", role: .cancel) { creditWarning = nil }
            Button("Delete anyway", role: .destructive) {
                creditWarning = nil
                Task { await submit(forfeitCredit: true) }
            }
        } message: {
            Text(creditWarning ?? "")
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") { dismiss() }
                    .disabled(isSubmitting)
            }
        }
    }

    private var canSubmit: Bool {
        guard !isSubmitting else { return false }
        return !password.isEmpty && confirmText == "DELETE"
    }

    private func submit(forfeitCredit: Bool = false) async {
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            // Any billing notice is published on AuthManager, not held here.
            // `deleteAccount` logs out, which swaps the whole view tree for
            // AuthView and takes this sheet with it — an alert raised on the
            // sheet would never be seen. TrackApp shows it at the root instead.
            try await authManager.deleteAccount(
                password: password,
                forfeitCreditBalance: forfeitCredit
            )
            dismiss()
        } catch let apiError as APIError
            where apiError.errorCode == "unspent_credit_balance" {
            // Not an error to show in red: the server is asking a
            // question, and nothing has been deleted. The balance is
            // money this account paid for and it goes with the
            // account, so the answer is the user's. In this app's
            // words: the server's are never shown.
            creditWarning = Self.unspentCreditText
        } catch let apiError as APIError {
            errorMessage = apiError.plainLine
        } catch {
            errorMessage = error.plainText
        }
    }
}

extension SettingsView {
    /// The sign-out question's message: what signing out stops, and, when
    /// changes are waiting to sync here, that they won't be made (information,
    /// not a question).
    static func signOutMessage(waiting: Int) -> String {
        let base = "This device stops sharing your location with your circles until you sign in again."
        guard waiting > 0 else { return base }
        return base + "\n\n" + PendingChangeCopy.signOutLine(waiting)
    }
}
