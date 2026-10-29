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
import UIKit
import PingolinTrackSDK

/// App environment configuration
enum AppEnvironment: String, CaseIterable {
    case production
    case development
    case local

    var authBaseURL: String {
        switch self {
        case .production: return "https://api-auth.pingolin.com"
        case .development: return "https://api-auth.pingolindev.com"
        case .local: return "http://localhost:8081"
        }
    }

    var apiBaseURL: String {
        switch self {
        case .production: return "https://api-track.pingolin.com"
        case .development: return "https://api-track.pingolindev.com"
        case .local: return "http://localhost:8080"
        }
    }

    var ingestURL: String {
        switch self {
        case .production: return "https://ingest-track.pingolin.com"
        case .development: return "https://ingest-track.pingolindev.com"
        case .local: return "http://localhost:50051"
        }
    }

    /// Account dashboard URL — surfaces the full signed-in-sessions
    /// list (Security page) for web / Note / admin sessions that
    /// don't share location and therefore don't appear in the in-app
    /// Manage Devices screen. Linked from the footer banner there.
    /// The Android app defines the same URL.
    var accountBaseURL: String {
        switch self {
        case .production: return "https://account.pingolin.com"
        case .development: return "https://account.pingolindev.com"
        case .local: return "http://localhost:3001"
        }
    }

    var displayName: String {
        switch self {
        case .production: return "Production"
        case .development: return "Development"
        case .local: return "Local"
        }
    }
}

/// App-wide configuration
final class AppConfiguration {
    static let shared = AppConfiguration()

    private let defaults = UserDefaults.standard
    private let environmentKey = "app_environment"

    private init() {}

    var environment: AppEnvironment {
        get {
            #if DEBUG
            guard let rawValue = defaults.string(forKey: environmentKey),
                  let env = AppEnvironment(rawValue: rawValue) else {
                return .development
            }
            return env
            #elseif RELEASE_DEV
            // ReleaseDev: a distribution-signed TestFlight build
            // whose hosts are pinned to development at compile
            // time (project.yml sets the RELEASE_DEV condition on
            // that configuration only). Like Release, it has no
            // runtime switch: the persisted override is ignored.
            return .development
            #else
            // Release is pinned to production. Never honor a persisted
            // app_environment override — a runtime env switch would also
            // repoint the app off its pinned production hosts. Matches the
            // "Release = production, no runtime env switch" posture.
            return .production
            #endif
        }
        set {
            defaults.set(newValue.rawValue, forKey: environmentKey)
        }
    }

    var authBaseURL: String { environment.authBaseURL }
    var apiBaseURL: String { environment.apiBaseURL }
    var ingestURL: String { environment.ingestURL }
    var accountBaseURL: String { environment.accountBaseURL }

    // MARK: - Account portal deep links

    /// Where accounts are created. The app has no sign-up form: the portal
    /// owns registration the same way it owns password reset, including the
    /// assisted lane for people who cannot clear the CAPTCHA, guardian-managed
    /// signups, and the recovery key. Deep-link straight to /register rather
    /// than the portal home so the page carries no pricing.
    var registerURL: URL? { accountURL(path: "/register") }

    /// Where someone who cannot sign in goes. The portal owns the whole
    /// reset flow — the app deliberately implements none of it.
    var forgotPasswordURL: URL? { accountURL(path: "/forgot-password") }

    /// Where the recovery address and recovery keys are managed. Both live on
    /// the portal's Settings page.
    var recoverySettingsURL: URL? { accountURL(path: "/settings") }

    /// The Settings section that restores data from before a password reset
    /// with the recovery key. auth renders it only for an account that has
    /// such data; without it the link opens Settings at the top.
    var preResetDataURL: URL? { accountURL(path: "/settings#pre-reset-data") }

    /// Where two-factor authentication is turned on. The app has no
    /// two-factor screen of its own: the portal owns this flow the same way
    /// it owns password reset.
    var securitySettingsURL: URL? { accountURL(path: "/security") }

    /// The portal's support page that needs no session: where the
    /// under-review and not-approved screens send people, as the
    /// portal's own under-review screen does.
    var publicSupportURL: URL? { accountURL(path: "/public-support") }

    /// Join a portal path onto `accountBaseURL` so every deep link follows the
    /// environment and a Release build cannot open the dev portal. Trailing
    /// slashes are trimmed (the Android app does the same), because
    /// `//forgot-password` is a different path to the router.
    private func accountURL(path: String) -> URL? {
        var base = accountBaseURL
        while base.hasSuffix("/") { base.removeLast() }
        return URL(string: base + path)
    }

    // App info
    var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    /// User-Agent in the shape the auth server reads a device model
    /// from: `Track/<ver> (<model>; iOS <release>) urlsession`. The
    /// `(...)` comment lets the server label sessions with the real
    /// device (e.g. "iPhone15,3" instead of a generic "on iOS"). The
    /// prefix must be one of `["Track/", "Note/", "PingolinTrack/",
    /// "PingolinNote/"]` — anything else falls through to generic
    /// user-agent parsing.
    var userAgent: String {
        "Track/\(appVersion) (\(Self.deviceModelToken); iOS \(Self.iosReleaseToken)) urlsession"
    }

    /// The UA for requests that must NOT be attributable to this device.
    /// Same `Track/` prefix so the server still knows which app is calling,
    /// but no `(...)` comment — which is precisely where the auth server
    /// reads the device model from, so a session created under this
    /// string is stored as "Unknown Device".
    ///
    /// Lives here rather than inline at the call site so the two strings have
    /// one source and a test can compare them.
    var anonymousUserAgent: String {
        "Track/\(appVersion) urlsession"
    }

    /// `utsname.machine` (e.g. "iPhone15,3") sanitized to the same
    /// charset Android applies (`[A-Za-z0-9 ._-]`), trimmed, and
    /// length-capped so it can't break the UA header or the server
    /// parser. Empty machine string falls back to `iPhone`.
    private static let deviceModelToken: String = {
        var info = utsname()
        uname(&info)
        let raw: String = withUnsafeBytes(of: &info.machine) { buf in
            guard let base = buf.baseAddress else { return "" }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 ._-")
        let cleaned = raw
            .filter { allowed.contains($0) }
            .trimmingCharacters(in: .whitespaces)
        let capped = String(cleaned.prefix(60))
        return capped.isEmpty ? "iPhone" : capped
    }()

    private static let iosReleaseToken: String = {
        // Computed once — systemVersion never changes within a process.
        UIDevice.current.systemVersion
    }()

}

/// Signal-style notification display verbosity (Settings → Push
/// Notifications → Notification detail). A pure display-layer choice,
/// mirroring Signal's Settings → Notifications → Show: the push
/// transport is always a content-free tickle regardless. It controls
/// how much decrypted content the app renders into the iOS notification
/// tray / lock screen, and the names this device puts into a bell row
/// (`NamedNotificationCopy`): this setting governs every named text.
/// The rest of the bell list keeps full detail behind the app lock.
enum NotificationDetailLevel: String, CaseIterable, Identifiable {
    case full
    case names
    case generic

    var id: String { rawValue }

    var label: String {
        switch self {
        case .full: return "Names and places"
        case .names: return "Names only"
        case .generic: return "Generic"
        }
    }

    /// Example body, shown as the picker caption.
    var example: String {
        switch self {
        case .full: return "“Alice arrived at Home”"
        case .names: return "“Alice arrived at a place”"
        case .generic: return "“Tap to view”"
        }
    }

    /// Body shown at the generic level — no names, places, or message
    /// content. Matches the server's privacy-generic push copy.
    static let genericBody = "Tap to view"

    /// Pick the notification body for the user's detail level. Titles
    /// are never redacted — they only name the event type, and hiding
    /// "Someone needs attention" would bury exactly the notification that
    /// must never be ignored. Callers whose detailed copy contains no place
    /// or message content can pass it as `namesOnly` too.
    static func resolveBody(detailed: String, namesOnly: String) -> String {
        switch UserSettings.shared.notificationDetailLevel {
        case .full: return detailed
        case .names: return namesOnly
        case .generic: return genericBody
        }
    }
}

/// Short local date + time appended to place and destination notification
/// bodies — "Alice arrived at Home · 7/28, 7:25 PM".
///
/// Applied AFTER `NotificationDetailLevel.resolveBody`, so it survives
/// redaction: a time says nothing about who or where, and knowing WHEN a
/// crossing happened is the point when a push arrives late (device asleep,
/// offline, or in a Low Power delay).
///
/// Rendered on the device rather than by the server, which knows neither the
/// user's timezone nor their locale — the date template reorders to d/M where
/// that is the convention and `.short` time honours the 24-hour setting.
/// The Android app renders the same stamp.
enum NotificationStamp {

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("Md")
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    static func short(_ date: Date = Date()) -> String {
        "\(dateFormatter.string(from: date)), \(timeFormatter.string(from: date))"
    }

    static func appended(to body: String, at date: Date = Date()) -> String {
        "\(body) · \(short(date))"
    }
}

/// User settings stored in UserDefaults
final class UserSettings: ObservableObject {
    static let shared = UserSettings()

    private let defaults: UserDefaults

    // Keys
    private enum Keys {
        static let biometricEnabled = "biometric_enabled"
        static let lastActiveTime = "last_active_time"
        static let batterySaverEnabled = "battery_saver_enabled"
        static let batterySaverInterval = "battery_saver_interval"
        static let autoGeocodingEnabled = "auto_geocoding_enabled"
        static let theme = "theme"
        static let dateFormat = "date_format"
        static let timeFormat = "time_format"
        static let notificationDetailLevel = "notification_detail_level"
        static let requireAuthOnLaunch = "require_auth_on_launch"
        static let autoLockTimeout = "auto_lock_timeout"
    }

    /// SettingsView binds its switches straight to these, so there is no
    /// explicit "save" step in the UI — the `didSet` write-back below is the
    /// only thing that makes a flipped switch survive a relaunch. `init` loads
    /// them into their stores directly: these are property wrappers, so
    /// assigning them there would run `didSet`, and that first save would
    /// write Auto-Lock's default over the stored choice at every launch.
    ///
    /// Notification preferences are deliberately not kept here: they are
    /// server state, read and written by SettingsView through
    /// GET/PUT /api/v1/notifications/preferences — the same settings the
    /// other Track apps use — so there is no local mirror to fall out of
    /// step with them.
    @Published var requireAuthOnLaunch: Bool = false {
        didSet { saveNotificationSettings() }
    }
    @Published var autoLockTimeout: Int = 300 {
        didSet { saveNotificationSettings() }
    }

    /// `defaults`: the standard store; tests pass their own.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        _requireAuthOnLaunch = Published(initialValue: defaults.bool(forKey: Keys.requireAuthOnLaunch))
        _autoLockTimeout = Published(initialValue: defaults.object(forKey: Keys.autoLockTimeout) as? Int ?? 300)
    }

    // Persisted computed properties
    var biometricEnabled: Bool {
        get { defaults.bool(forKey: Keys.biometricEnabled) }
        set {
            defaults.set(newValue, forKey: Keys.biometricEnabled)
            objectWillChange.send()
        }
    }

    /// Signal-style display verbosity for tray notifications. Defaults
    /// to full detail; unknown stored values also normalise to full.
    /// The Android app has the same setting.
    var notificationDetailLevel: NotificationDetailLevel {
        get {
            NotificationDetailLevel(
                rawValue: defaults.string(forKey: Keys.notificationDetailLevel) ?? ""
            ) ?? .full
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.notificationDetailLevel)
            objectWillChange.send()
            // The Notification Service Extension reads the level from the
            // app-group suite; keep it current (see ExtensionBridge).
            ExtensionBridge.sync()
        }
    }

    /// When Track last went to the background from the front, for App Lock's
    /// Auto-Lock (`AppLockRule`). Nil until then: no record is no answer,
    /// never "just now" — read as "just now", every check would see no time
    /// away and the lock would never come.
    var lastActiveTime: Date? {
        get { defaults.object(forKey: Keys.lastActiveTime) as? Date }
        set { defaults.set(newValue, forKey: Keys.lastActiveTime) }
    }

    var batterySaverEnabled: Bool {
        get { defaults.bool(forKey: Keys.batterySaverEnabled) }
        set {
            defaults.set(newValue, forKey: Keys.batterySaverEnabled)
            objectWillChange.send()
        }
    }

    var batterySaverInterval: TimeInterval {
        get {
            let value = defaults.double(forKey: Keys.batterySaverInterval)
            return value > 0 ? value : 900 // Default 15 minutes
        }
        set { defaults.set(newValue, forKey: Keys.batterySaverInterval) }
    }

    var autoGeocodingEnabled: Bool {
        get { defaults.bool(forKey: Keys.autoGeocodingEnabled) }
        set { defaults.set(newValue, forKey: Keys.autoGeocodingEnabled) }
    }

    enum Theme: String, CaseIterable {
        case system, light, dark
    }

    var theme: Theme {
        get { Theme(rawValue: defaults.string(forKey: Keys.theme) ?? "system") ?? .system }
        set { defaults.set(newValue.rawValue, forKey: Keys.theme) }
    }

    enum DateFormat: String, CaseIterable {
        case mdy = "MM/dd/yyyy"
        case dmy = "dd/MM/yyyy"
        case ymd = "yyyy-MM-dd"
    }

    var dateFormat: DateFormat {
        get { DateFormat(rawValue: defaults.string(forKey: Keys.dateFormat) ?? "mdy") ?? .mdy }
        set { defaults.set(newValue.rawValue, forKey: Keys.dateFormat) }
    }

    var use24HourTime: Bool {
        get { defaults.bool(forKey: Keys.timeFormat) }
        set { defaults.set(newValue, forKey: Keys.timeFormat) }
    }

    func updateLastActiveTime() {
        lastActiveTime = Date()
    }

    func saveNotificationSettings() {
        defaults.set(requireAuthOnLaunch, forKey: Keys.requireAuthOnLaunch)
        defaults.set(autoLockTimeout, forKey: Keys.autoLockTimeout)
    }
}

// MARK: - SDK Logging

/// Start the Rust SDK's tracing subscriber.
///
/// This must forward to `PingolinTrackSDK.initLogging`: nothing else calls
/// `pingolin_mobile::init_logging` on iOS. A local type that declares its
/// own `LogLevel` and only `print`s would shadow the SDK's, so
/// `initLogging(level:)` in TrackApp would bind to it and every `tracing::`
/// line inside the Rust SDK (geocoder, crypto and tile I/O alike) would be
/// dropped without any error, including the `"Tile not in manifest,
/// skipping"` warning that names a tile-loading failure. Android wires the
/// same SDK to `tracing_android`.
///
/// On Apple targets the SDK's subscriber is `tracing_subscriber::fmt()`, i.e.
/// stdout — which `devicectl device process launch --console` captures.
func initLogging(level: PingolinTrackSDK.LogLevel) {
    PingolinTrackSDK.initLogging(level: level)
    #if DEBUG
    print("[Track] SDK logging initialized at level: \(level)")
    #endif
}
