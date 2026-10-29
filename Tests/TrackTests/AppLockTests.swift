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

import XCTest
import LocalAuthentication
@testable import Track

/// App Lock (Settings → App Lock & Privacy → App Lock): the time it compares
/// against is the last time Track went to the background, the timeout is the
/// Auto-Lock choice, "Require on Launch" locks every launch, and the check
/// takes the device passcode as well as Face ID or Touch ID, as the row
/// promises.
final class AppLockTests: XCTestCase {
    private let away = Date(timeIntervalSince1970: 1_800_000_000)

    private func locks(enabled: Bool = true, onLaunch: Bool = false, autoLock: Int = 300, launching: Bool = false,
                       after seconds: TimeInterval?) -> Bool {
        AppLockRule.locks(enabled: enabled, requireOnLaunch: onLaunch, autoLock: autoLock, launching: launching,
                          backgroundedAt: seconds == nil ? nil : away,
                          now: away.addingTimeInterval(seconds ?? 0))
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func body(of start: String, until end: String, in text: String) throws -> Substring {
        let from = try XCTUnwrap(text.range(of: start), start)
        let to = try XCTUnwrap(text[from.upperBound...].range(of: end), end)
        return text[from.upperBound..<to.lowerBound]
    }

    /// Off, nothing locks, whatever else is set.
    func testOffNeverLocks() {
        for onLaunch in [false, true] {
            for autoLock in [0, 60, 300, 900, AppLockRule.never] {
                for launching in [false, true] {
                    for seconds in [nil, 0, 59, 3_600] as [TimeInterval?] {
                        XCTAssertFalse(locks(enabled: false, onLaunch: onLaunch, autoLock: autoLock, launching: launching,
                                             after: seconds))
                    }
                }
            }
        }
    }

    /// The Auto-Lock choice counts from the last time Track went to the
    /// background: "Immediately", 1, 5 and 15 minutes, each at its boundary;
    /// "Never" never.
    func testAutoLockCountsFromTheLastBackground() {
        XCTAssertTrue(locks(autoLock: 0, after: 0), "Immediately")
        XCTAssertFalse(locks(autoLock: 60, after: 59))
        XCTAssertTrue(locks(autoLock: 60, after: 60))
        XCTAssertFalse(locks(autoLock: 300, after: 299))
        XCTAssertTrue(locks(autoLock: 300, after: 300))
        XCTAssertFalse(locks(autoLock: 900, after: 899))
        XCTAssertTrue(locks(autoLock: 900, after: 900))
        XCTAssertFalse(locks(autoLock: AppLockRule.never, after: 86_400), "Never")
    }

    /// "Require on Launch" locks every launch, even straight after the last
    /// use and with Auto-Lock "Never"; a return to the front is Auto-Lock's.
    func testRequireOnLaunchLocksEveryLaunch() {
        XCTAssertTrue(locks(onLaunch: true, autoLock: AppLockRule.never, launching: true, after: 0))
        XCTAssertTrue(locks(onLaunch: true, autoLock: 900, launching: true, after: 1))
        XCTAssertFalse(locks(onLaunch: true, autoLock: AppLockRule.never, launching: false, after: 3_600))
        XCTAssertFalse(locks(onLaunch: true, autoLock: 300, launching: false, after: 10))
    }

    /// Without "Require on Launch", a launch counts from the time an earlier
    /// process went to the background: killing Track and opening it again
    /// doesn't skip the lock.
    func testALaunchCountsFromTheEarlierProcessesTime() {
        XCTAssertTrue(locks(autoLock: 300, launching: true, after: 600))
        XCTAssertFalse(locks(autoLock: 300, launching: true, after: 60))
        XCTAssertFalse(locks(autoLock: AppLockRule.never, launching: true, after: 86_400))
    }

    /// No record of the time, or a clock set back past it: how long Track was
    /// away isn't known, so it locks (unless Auto-Lock is "Never").
    func testNoRecordOrAClockSetBackLocks() {
        XCTAssertTrue(locks(autoLock: 900, after: nil))
        XCTAssertTrue(locks(autoLock: 900, launching: true, after: nil))
        XCTAssertTrue(locks(autoLock: 900, after: -60), "the clock was set back")
        XCTAssertFalse(locks(autoLock: AppLockRule.never, after: nil))
    }

    /// The device passcode is the way in when Face ID or Touch ID fail; a
    /// device with no passcode at all can't lock anything, so it opens.
    func testOnlyAMissingDevicePasscodeOpensWithoutAsking() {
        XCTAssertTrue(AuthManager.noDevicePasscode(NSError(domain: LAError.errorDomain,
                                                           code: LAError.Code.passcodeNotSet.rawValue)))
        for code in [LAError.Code.biometryNotAvailable, .biometryNotEnrolled, .biometryLockout, .userCancel,
                     .authenticationFailed] {
            XCTAssertFalse(AuthManager.noDevicePasscode(NSError(domain: LAError.errorDomain, code: code.rawValue)),
                           "\(code)")
        }
        XCTAssertFalse(AuthManager.noDevicePasscode(NSError(domain: "other", code: LAError.Code.passcodeNotSet.rawValue)))
        XCTAssertFalse(AuthManager.noDevicePasscode(nil))
    }

    /// The Auto-Lock choice and "Require on Launch" survive a relaunch.
    /// Loading them must not run their `didSet`: its save would write
    /// Auto-Lock's default (5 minutes) over the stored choice at every
    /// launch, and "Immediately" would never last past one. The time of the
    /// last background is nil until one is recorded.
    func testTheChoicesSurviveARelaunch() throws {
        let suite = "app-lock-tests-\(UUID().uuidString)"
        let store = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
        let first = UserSettings(defaults: store)
        XCTAssertNil(store.object(forKey: "auto_lock_timeout"), "loading saves nothing")
        XCTAssertEqual(first.autoLockTimeout, 300)
        XCTAssertFalse(first.requireAuthOnLaunch)
        XCTAssertNil(first.lastActiveTime, "never \"now\" when not recorded")

        first.autoLockTimeout = 0
        first.requireAuthOnLaunch = true
        first.updateLastActiveTime()
        let relaunched = UserSettings(defaults: store)
        XCTAssertEqual(relaunched.autoLockTimeout, 0)
        XCTAssertTrue(relaunched.requireAuthOnLaunch)
        XCTAssertNotNil(relaunched.lastActiveTime)

        relaunched.autoLockTimeout = AppLockRule.never
        relaunched.requireAuthOnLaunch = false
        let again = UserSettings(defaults: store)
        XCTAssertEqual(again.autoLockTimeout, AppLockRule.never)
        XCTAssertFalse(again.requireAuthOnLaunch)
    }

    /// The lock shows on the way back, before Track is in front, so Face ID
    /// is asked for once it is: asked earlier, iOS answers "User interaction
    /// required" and the person would see "Authentication Failed". Answers
    /// that aren't the person's (not in front, sent away during the prompt)
    /// ask again later without that alert; a real failure or cancel still
    /// shows it.
    func testFaceIDIsAskedForOnceTrackIsInFront() throws {
        for code in [LAError.Code.notInteractive, .systemCancel, .appCancel] {
            XCTAssertTrue(BiometricLockView.asksAgainLater(LAError(code)), "\(code)")
        }
        for code in [LAError.Code.userCancel, .authenticationFailed, .biometryLockout, .passcodeNotSet] {
            XCTAssertFalse(BiometricLockView.asksAgainLater(LAError(code)), "\(code)")
        }
        XCTAssertFalse(BiometricLockView.asksAgainLater(URLError(.timedOut)))

        let view = try source("App/Views/Auth/BiometricLockView.swift")
        XCTAssertTrue(view.contains(".onChange(of: scenePhase, initial: true) { _, phase in\n"
                                    + "            if phase == .active && !asked {\n"
                                    + "                asked = true\n                authenticate()\n"))
        XCTAssertFalse(view.contains(".onAppear {\n            authenticate()"), "not before Track is in front")
        XCTAssertTrue(view.contains("                    if Self.asksAgainLater(error) {\n"
                                    + "                        // Not the person's answer: Track wasn't in front, or\n"
                                    + "                        // went away during the prompt. Asked again next time.\n"
                                    + "                        asked = false\n"))
    }

    /// Nothing presents over the lock. The lock is a
    /// view swap, and RootView's three hosts present above whatever is on top:
    /// "Is this really {name}?" ("It's them" pins new keys), "Let {name} into
    /// {circle}?" ("Let them in" delivers the circle's key) and the invitation
    /// renewal question. Each reads `appLocked` and presents nothing while the
    /// lock shows; one already up goes, and its question stays queued (the
    /// setters never consume a question while locked). The in-app browser,
    /// presented over the root by UIKit, closes as the lock comes up. RootView
    /// presents nothing else above the lock but the account-deleted notice
    /// (signed out, so never locked).
    func testNothingPresentsOverTheLock() throws {
        let app = try source("App/TrackApp.swift")
        let root = try body(of: "struct RootView: View {", until: "    /// App Lock. Going to the background", in: app)
        let hosts = ["MemberKeyAlertHost", "KeyDeliveryPromptHost", "InvitationRenewalQuestionHost"]
        let environment = try XCTUnwrap(root.range(of: "        .environment(\\.appLocked, showBiometricLock)\n"))
        for host in hosts {
            let applied = try XCTUnwrap(root.range(of: ".modifier(\(host)())"), host)
            XCTAssertLessThan(applied.upperBound, environment.lowerBound, "\(host) inside the lock's environment")
        }
        XCTAssertEqual(root.components(separatedBy: ".modifier(").count - 1, hosts.count, "a new host needs the gate too")
        XCTAssertEqual(root.components(separatedBy: ".alert(").count - 1, 1, "only the account-deleted notice")
        XCTAssertFalse(root.contains(".sheet(") || root.contains(".fullScreenCover(") || root.contains(".confirmationDialog("))
        XCTAssertTrue(root.contains(".onChange(of: showBiometricLock) { _, locked in\n"
                                    + "            if locked { InAppSafari.closeForLock() }\n"))

        let member = try source("App/Views/Circles/MemberKeyAlertHost.swift")
        XCTAssertTrue(member.contains("@SwiftUI.Environment(\\.appLocked) private var appLocked"))
        XCTAssertTrue(member.contains("get: { !appLocked && pinner.alerts.first != nil },"))
        XCTAssertTrue(member.contains("get: { !appLocked && approvalFailure != nil },\n"
                                      + "                    set: { if !$0 && !appLocked { approvalFailure = nil } }"))
        let delivery = try body(of: "struct KeyDeliveryPromptHost: ViewModifier {", until: "\n}\n",
                                in: try source("App/Managers/KeyDeliveryApprovals.swift"))
        XCTAssertTrue(delivery.contains("@SwiftUI.Environment(\\.appLocked) private var appLocked"))
        XCTAssertTrue(delivery.contains("get: { !appLocked && current != nil },"))
        let renewal = try body(of: "struct InvitationRenewalQuestionHost: ViewModifier {", until: "    private func answer(",
                               in: try source("App/Managers/InvitationRenewals.swift"))
        XCTAssertTrue(renewal.contains("@SwiftUI.Environment(\\.appLocked) private var appLocked"))
        XCTAssertTrue(renewal.contains("isPresented: Binding(get: { !appLocked && current != nil }, set: { _ in }),"))
        XCTAssertTrue(renewal.contains(
            "isPresented: Binding(get: { !appLocked && outcome != nil }, set: { if !$0 && !appLocked { outcome = nil } }),"))
        for (name, text) in [("member", member), ("delivery", String(delivery)), ("renewal", String(renewal))] {
            XCTAssertEqual(text.components(separatedBy: "isPresented: Binding(").count,
                           text.components(separatedBy: "get: { !appLocked && ").count, "every alert of \(name) is gated")
        }

        let browser = try source("App/Views/Shared/InAppSafari.swift")
        let safari = try body(of: "    static func closeForLock() {", until: "\n    }\n", in: browser)
        XCTAssertTrue(safari.contains("if presented is SFSafariViewController {\n"
                                      + "                    presented.presentingViewController?.dismiss(animated: false)"))
        // A full-screen presentation takes RootView out of the window, where it
        // hears no scene phase: there would be no lock while a page is open.
        // Pages go over the app; nothing in App/ covers it whole.
        XCTAssertTrue(browser.contains("        page.modalPresentationStyle = .overFullScreen\n        top.present(page, animated: true)"))
        let sources = try FileManager.default.subpathsOfDirectory(atPath: try appDirectory())
            .filter { $0.hasSuffix(".swift") }
        for file in sources {
            let text = try String(contentsOfFile: try appDirectory() + "/" + file, encoding: .utf8)
            XCTAssertFalse(text.contains(".fullScreenCover("), file)
            XCTAssertFalse(text.contains("modalPresentationStyle = .fullScreen"), file)
        }
    }

    private func appDirectory() throws -> String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("App").path
    }

    /// Where the rule is applied: the time recorded on going to the background
    /// from the front (never "now" when missing), the rule asked on a return
    /// from the background and on the first time in front, the lock dropped
    /// at a sign-out, and the device passcode allowed.
    func testTheLockIsWiredToTheSettingsAndTheScene() throws {
        let settings = try source("App/Configuration.swift")
        XCTAssertTrue(settings.contains("    var lastActiveTime: Date? {\n"
                                        + "        get { defaults.object(forKey: Keys.lastActiveTime) as? Date }\n"))

        let app = try source("App/TrackApp.swift")
        let root = try body(of: "struct RootView: View {", until: "/// A once-per-interval gate", in: app)
        XCTAssertTrue(root.contains(".onChange(of: scenePhase, initial: true) { _, phase in\n            appLockSees(phase)\n        }"))
        XCTAssertTrue(root.contains("        case .background:\n            guard launched else { return }\n"
                                    + "            UserSettings.shared.updateLastActiveTime()\n            wentToBackground = true\n"
                                    + "            lockIfDue(launching: false)\n"), "recorded, and Immediately locks then")
        XCTAssertTrue(root.contains("        case .inactive, .active:\n"
                                    + "            let launching = !launched\n"
                                    + "            launched = true\n"
                                    + "            guard launching || wentToBackground else { return }\n"
                                    + "            wentToBackground = false\n"
                                    + "            lockIfDue(launching: launching)\n"), "decided at the first phase in front")
        XCTAssertTrue(root.contains(
            "        if AppLockRule.locks(enabled: settings.biometricEnabled, requireOnLaunch: settings.requireAuthOnLaunch,\n"
            + "                             autoLock: settings.autoLockTimeout, launching: launching,\n"
            + "                             backgroundedAt: settings.lastActiveTime, now: Date()) {\n"
            + "            showBiometricLock = true\n"))
        XCTAssertTrue(root.contains("guard authManager.isAuthenticated || authManager.isCheckingSession else { return }"))
        XCTAssertTrue(root.contains(".onChange(of: authManager.isAuthenticated) { _, signedIn in\n"
                                    + "            if !signedIn { showBiometricLock = false }\n"))
        XCTAssertTrue(root.contains("if !checking && !authManager.isAuthenticated { showBiometricLock = false }"))
        XCTAssertFalse(app.contains("willEnterForegroundNotification"), "one place decides")
        XCTAssertFalse(app.contains("180 // 3 minutes"))

        let auth = try source("App/Managers/AuthManager.swift")
        let check = try body(of: "    func authenticateForAppLock() async throws -> Bool {", until: "\n    }\n", in: auth)
        XCTAssertTrue(check.contains("context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)"))
        XCTAssertTrue(check.contains("context.evaluatePolicy(\n            .deviceOwnerAuthentication,\n"))
        XCTAssertFalse(check.contains("WithBiometrics"), "the device passcode is a way in")
        XCTAssertTrue(try source("App/Views/Auth/BiometricLockView.swift")
            .contains("try await AuthManager.shared.authenticateForAppLock()"))

        let screen = try source("App/Views/Settings/SettingsView.swift")
        let security = try body(of: "struct SecuritySettingsView: View {", until: "    var biometricLabel: String {", in: screen)
        XCTAssertTrue(security.contains("Text(\"Never\").tag(AppLockRule.never)"))
        XCTAssertEqual(security.components(separatedBy: ".disabled(!settings.biometricEnabled)").count - 1, 2,
                       "Require on Launch and Auto-Lock")
    }

    /// Auto-Lock later is a weaker lock, and "Never" is the latest of all.
    /// Earlier, or the same, is not.
    func testWhatLocksLater() {
        let never = AppLockRule.never
        XCTAssertTrue(AppLockRule.locksLater(900, than: 300))
        XCTAssertTrue(AppLockRule.locksLater(60, than: 0))
        XCTAssertTrue(AppLockRule.locksLater(never, than: 300))
        XCTAssertTrue(AppLockRule.locksLater(never, than: 0))
        XCTAssertFalse(AppLockRule.locksLater(60, than: 300), "earlier: stronger")
        XCTAssertFalse(AppLockRule.locksLater(0, than: 900))
        XCTAssertFalse(AppLockRule.locksLater(300, than: 300), "the same")
        XCTAssertFalse(AppLockRule.locksLater(900, than: never), "anything after Never locks earlier")
        XCTAssertFalse(AppLockRule.locksLater(0, than: never))
        XCTAssertFalse(AppLockRule.locksLater(never, than: never))
    }

    /// Making App Lock weaker needs the device owner's proof first: App Lock
    /// off, "Require on Launch" off, Auto-Lock later or "Never". A control
    /// that wrote its setting straight away would let anyone holding an
    /// unlocked Track switch the lock off. A stronger lock asks nothing, and a
    /// proof not given leaves the control where it was, with nothing said.
    func testEveryWeakerLockIsProvenFirst() throws {
        let screen = try source("App/Views/Settings/SettingsView.swift")
        let security = try body(of: "struct SecuritySettingsView: View {", until: "    var biometricLabel: String {", in: screen)
        XCTAssertTrue(security.contains(
            "change(weakens: !on, reason: AppLockProofCopy.turnOff) { settings.biometricEnabled = on }\n"), "App Lock off")
        XCTAssertTrue(security.contains(
            "change(weakens: !on, reason: AppLockProofCopy.requireOnLaunchOff) {\n"
            + "                            settings.requireAuthOnLaunch = on\n"), "Require on Launch off")
        XCTAssertTrue(security.contains(
            "change(weakens: AppLockRule.locksLater(choice, than: settings.autoLockTimeout),\n"
            + "                               reason: AppLockProofCopy.autoLockLater) { settings.autoLockTimeout = choice }\n"),
                      "Auto-Lock later or Never")
        for direct in ["$settings.biometricEnabled", "$settings.requireAuthOnLaunch", "$settings.autoLockTimeout"] {
            XCTAssertFalse(security.contains(direct), "no control writes \(direct) straight away")
        }

        let change = try body(of: "    private func change(weakens: Bool, reason: String, _ apply: @escaping () -> Void) {",
                              until: "\n    }\n", in: screen)
        XCTAssertTrue(change.contains("""
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
            """), "stronger at once; weaker only once proven, the control showing what holds until then")
        XCTAssertEqual(change.components(separatedBy: "apply()").count - 1, 2)

        XCTAssertEqual(AppLockProofCopy.turnOff, "Authenticate to turn off App Lock")
        XCTAssertEqual(AppLockProofCopy.requireOnLaunchOff, "Authenticate to change App Lock")
        XCTAssertEqual(AppLockProofCopy.autoLockLater, "Authenticate to change when Track locks")
    }

    /// The proof is the lock's own: Face ID or Touch ID, or the device
    /// passcode. With no passcode there is nothing to keep, so it passes, as
    /// the lock itself opens there; a cancel or a failure doesn't.
    func testTheProofIsTheLocksOwn() throws {
        let auth = try source("App/Managers/AuthManager.swift")
        let prove = try body(of: "    func proveForAppLockChange(reason: String) async -> Bool {", until: "\n    }\n", in: auth)
        XCTAssertTrue(prove.contains("context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)"))
        XCTAssertTrue(prove.contains("            return Self.noDevicePasscode(error)\n"), "no passcode: nothing to keep")
        XCTAssertTrue(prove.contains(
            "return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false"),
                      "a cancel or a failure: no")
        XCTAssertFalse(prove.contains("WithBiometrics"), "the device passcode is a way in")
    }
}
