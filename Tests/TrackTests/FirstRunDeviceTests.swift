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
@testable import Track

/// A fresh sign-in must register the iPhone with its push token: without one
/// the server refuses every location, needs-attention and check-in from it
/// ("Device not found or not owned by user") while the app shows everything
/// as working.
///
/// The server's side: ingest, needs-attention and check-ins all require the
/// device's push-token registration, and `POST /api/v1/devices` records it
/// only when the request carries a push token; without one it answers 201
/// with `push_registered: false`. The response bodies below are that route's,
/// field for field.
@MainActor
final class FirstRunDeviceTests: XCTestCase {

    private var asks = 0
    private var keptAskForToken: (() -> Void)?

    override func setUp() async throws {
        try await super.setUp()
        let push = PushNotificationManager.shared
        keptAskForToken = push.askForToken
        asks = 0
        push.askForToken = { [weak self] in self?.asks += 1 }
        push.reset()
    }

    override func tearDown() async throws {
        let push = PushNotificationManager.shared
        if let keptAskForToken { push.askForToken = keptAskForToken }
        push.reset()
        try await super.tearDown()
    }

    // MARK: - 1. A sign-in asks iOS for the token

    func testASignInAsksIOSForTheTokenWithoutAPrompt() throws {
        PushNotificationManager.shared.requestDeviceToken()
        XCTAssertEqual(asks, 1, "no cooldown on the sign-in's ask")

        let auth = try source("App/Managers/AuthManager.swift")
        let login = try body(auth, from: "    private func completeLogin(accessToken: String,",
                             to: "    /// Undo what `completeLogin` wrote before the keys failed to unlock")
        let reset = try XCTUnwrap(login.range(of: "PushNotificationManager.shared.reset()"))
        let ask = try XCTUnwrap(login.range(of: "PushNotificationManager.shared.requestDeviceToken()"),
                                "completeLogin asks iOS for the token")
        XCTAssertLessThan(reset.upperBound, ask.lowerBound,
                          "after the token cache is cleared, so the token that comes is POSTed again")
        // No prompt at sign-in: that stays on onboarding's page, where it is explained.
        XCTAssertFalse(login.contains("requestAuthorization()"))

        // What the ask is: iOS's own call, the same one the launch path makes.
        let push = try source("App/Managers/PushNotificationManager.swift")
        XCTAssertTrue(push.contains("var askForToken: () -> Void = { UIApplication.shared.registerForRemoteNotifications() }"))
        XCTAssertEqual(push.components(separatedBy: "registerForRemoteNotifications()").count - 1, 1,
                       "every ask goes through askForToken")
    }

    // MARK: - 2. A refusal asks for the token, once per cooldown

    func testARefusedDeviceAsksForTheTokenOncePerCooldown() {
        let push = PushNotificationManager.shared
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)

        XCTAssertTrue(push.requestDeviceTokenAfterRefusal(now: t0))
        XCTAssertEqual(asks, 1)
        XCTAssertFalse(push.requestDeviceTokenAfterRefusal(now: t0.addingTimeInterval(60)), "one refused fix after another")
        XCTAssertFalse(push.requestDeviceTokenAfterRefusal(now: t0.addingTimeInterval(299)))
        XCTAssertEqual(asks, 1, "a phone that gets no token doesn't ask on every refused fix")
        XCTAssertTrue(push.requestDeviceTokenAfterRefusal(now: t0.addingTimeInterval(300)))
        XCTAssertEqual(asks, 2)

        // A new session (sign-out, sign-in) starts with no cooldown.
        push.reset()
        XCTAssertTrue(push.requestDeviceTokenAfterRefusal(now: t0.addingTimeInterval(301)))
        XCTAssertEqual(asks, 3)
    }

    func testBothRefusalHandlersAskForTheTokenAndTheFixRefusalHasACooldown() throws {
        let streamer = try source("App/Services/SDKLocationStreamer.swift")
        let streamError = try body(streamer, from: "    fileprivate func handleStreamError(_ message: String) {",
                                   to: "    private func refreshTokenAndRestart(userId: String, deviceId: String) async {")
        let fixRefused = try body(streamer, from: "    fileprivate func handleLocationRejected(deviceId: String, error: String) {",
                                  to: "    /// Which table the server files the row under.")
        for (name, handler) in [("stream error", streamError), ("refused fix", fixRefused)] {
            XCTAssertTrue(handler.contains("PushNotificationManager.shared.requestDeviceTokenAfterRefusal()"), name)
        }
        // The refused fix re-registers at most once per 5 minutes, like the stream error.
        let gate = try XCTUnwrap(fixRefused.range(of: "guard Self.reregisterIsDue(last: lastRejectionReregisterAt, now: now) else {"))
        let repost = try XCTUnwrap(fixRefused.range(of: "let ok = await DeviceRegistrar.ensure()"))
        XCTAssertLessThan(gate.upperBound, repost.lowerBound)

        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        XCTAssertTrue(SDKLocationStreamer.reregisterIsDue(last: nil, now: t0))
        XCTAssertFalse(SDKLocationStreamer.reregisterIsDue(last: t0, now: t0.addingTimeInterval(299)))
        XCTAssertTrue(SDKLocationStreamer.reregisterIsDue(last: t0, now: t0.addingTimeInterval(300)))

        // Once the token-carrying registration lands, a stream the server ended comes back.
        let push = try source("App/Managers/PushNotificationManager.swift")
        let register = try body(push, from: "    func register(deviceToken: Data) async {",
                                to: "    func registrationFailed(_ error: Error) {")
        let cached = try XCTUnwrap(register.range(of: "try? keychain.saveSDKData(hex, for: Self.lastPushedTokenKey)"))
        let wake = try XCTUnwrap(register.range(of: "SDKLocationStreamer.shared.deviceBecameAddressable()"))
        XCTAssertLessThan(cached.upperBound, wake.lowerBound, "only on the registration the server took")
    }

    // MARK: - 3. No personal key: the token still goes

    func testWithoutThePersonalKeyTheTokenStillGoesToTheServer() async throws {
        var sent: [CreateDeviceRequest] = []
        let seam = makeSeam(keyInUse: false, answer: Self.registered, sent: { sent.append($0) }, sealed: { _ in })

        let ok = await DeviceRegistrar.ensure(pushToken: Self.token, pushType: "apns", seam: seam)

        XCTAssertTrue(ok)
        XCTAssertEqual(sent.count, 1, "a delivered token is never dropped for a missing personal key")
        XCTAssertEqual(sent.first?.pushToken, Self.token)
        XCTAssertEqual(sent.first?.pushType, "apns")
        XCTAssertEqual(sent.first?.deviceId, Self.deviceId)
        // Nothing to seal with: the empties the server takes (and discards).
        XCTAssertEqual(sent.first?.encryptedDeviceName, EncryptedBlobRequest(nonce: "", ciphertext: ""))
        XCTAssertEqual(sent.first?.encryptedDeviceType, EncryptedBlobRequest(nonce: "", ciphertext: ""))
        XCTAssertTrue(seam.defaults.bool(forKey: Self.flag))

        // The live seal: only under a key IN USE, and not a gate on the whole registration.
        let registrar = try source("App/Services/DeviceRegistrar.swift")
        let seal = try body(registrar, from: "    private static func sealUnderPersonalKey(",
                            to: "    /// What the device's name and type go as when nothing can seal them.")
        let gate = try XCTUnwrap(seal.range(of: "guard SelfKeyManager.personalKeyInUse(crypto) else {"))
        let sealing = try XCTUnwrap(seal.range(of: "crypto.encryptDataV2("))
        XCTAssertLessThan(gate.upperBound, sealing.lowerBound)
        let ensure = try body(registrar, from: "    static func ensure(pushToken: String?, pushType: String?, seam: Seam) async -> Bool {",
                              to: "    /// Forget that THIS device is registered")
        XCTAssertFalse(ensure.contains("personalKeyInUse"), "nothing in ensure waits for the personal key")
    }

    func testWithThePersonalKeyNameAndTypeAreSealed() async throws {
        var sent: [CreateDeviceRequest] = []
        var sealed: [String] = []
        let seam = makeSeam(keyInUse: true, answer: Self.registered, sent: { sent.append($0) }, sealed: { sealed.append($0) })

        _ = await DeviceRegistrar.ensure(pushToken: Self.token, pushType: "apns", seam: seam)

        XCTAssertEqual(sealed.sorted(), ["device_name", "device_type"])
        XCTAssertEqual(sent.first?.encryptedDeviceType, EncryptedBlobRequest(nonce: "n-device_type", ciphertext: "c-device_type"))
    }

    func testASealThatFailsSendsEmptiesRatherThanNothing() async throws {
        var sent: [CreateDeviceRequest] = []
        var seam = makeSeam(keyInUse: true, answer: Self.registered, sent: { sent.append($0) }, sealed: { _ in })
        seam.seal = { _, _ in nil }

        let ok = await DeviceRegistrar.ensure(pushToken: Self.token, pushType: "apns", seam: seam)

        XCTAssertTrue(ok)
        XCTAssertEqual(sent.first?.encryptedDeviceName, EncryptedBlobRequest(nonce: "", ciphertext: ""))
    }

    // MARK: - 4. push_registered: false is not "registered"

    func testA201WithPushRegisteredFalseIsNotRegistered() async throws {
        var sent: [CreateDeviceRequest] = []
        var answer = Self.notAddressable
        var seam = makeSeam(keyInUse: true, answer: answer, sent: { sent.append($0) }, sealed: { _ in })
        seam.createDevice = { request in
            sent.append(request)
            return try APIService.decodeResponseBody(Data(answer.utf8))
        }

        // The sign-in's token-less registration: the server wrote no row.
        let first = await DeviceRegistrar.ensure(pushToken: nil, pushType: nil, seam: seam)
        XCTAssertFalse(first, "201 with push_registered false: not addressable, so not registered")
        XCTAssertFalse(seam.defaults.bool(forKey: Self.flag))
        // So the next token-less call asks again instead of trusting a flag.
        _ = await DeviceRegistrar.ensure(pushToken: nil, pushType: nil, seam: seam)
        XCTAssertEqual(sent.count, 2)

        // The token arrives: the row is written, and from then on it is registered.
        answer = Self.registered
        let withToken = await DeviceRegistrar.ensure(pushToken: Self.token, pushType: "apns", seam: seam)
        XCTAssertTrue(withToken)
        XCTAssertTrue(seam.defaults.bool(forKey: Self.flag))
        let later = await DeviceRegistrar.ensure(pushToken: nil, pushType: nil, seam: seam)
        XCTAssertTrue(later)
        XCTAssertEqual(sent.count, 3, "a token-less call after that reads the flag")
    }

    func testAnOlderServerThatDoesNotSayIsTakenAtItsWord() async throws {
        var sent: [CreateDeviceRequest] = []
        let seam = makeSeam(keyInUse: true, answer: Self.olderServer, sent: { sent.append($0) }, sealed: { _ in })

        let ok = await DeviceRegistrar.ensure(pushToken: nil, pushType: nil, seam: seam)

        XCTAssertTrue(ok)
        XCTAssertTrue(seam.defaults.bool(forKey: Self.flag))
    }

    func testTheResponseDecodesTheServersField() throws {
        let no: DeviceResponse = try APIService.decodeResponseBody(Data(Self.notAddressable.utf8))
        let yes: DeviceResponse = try APIService.decodeResponseBody(Data(Self.registered.utf8))
        let older: DeviceResponse = try APIService.decodeResponseBody(Data(Self.olderServer.utf8))
        XCTAssertEqual(no.pushRegistered, false)
        XCTAssertEqual(yes.pushRegistered, true)
        XCTAssertNil(older.pushRegistered)
    }

    // MARK: - Fixtures

    private static let userId = "11111111-1111-1111-1111-111111111111"
    private static let deviceId = "0A1B2C3D-0000-4000-8000-000000000001"
    private static let token = String(repeating: "ab", count: 32)
    private static var flag: String { "device.registered.\(userId).\(deviceId)" }

    /// `POST /api/v1/devices` as the server answers it: the blobs are empty
    /// placeholders, and `push_registered` says whether the device's row was
    /// written.
    private static func answer(pushRegistered: Bool?) -> String {
        let field = pushRegistered.map { ",\"push_registered\":\($0)" } ?? ""
        return """
        {"success":true,"data":{"id":"\(deviceId.lowercased())",\
        "encrypted_device_type":{"nonce":"","ciphertext":""},\
        "encrypted_device_name":{"nonce":"","ciphertext":""},\
        "is_active":true,"last_seen_day_bucket":null,"day_bucket":20375\(field)}}
        """
    }
    private static let notAddressable = answer(pushRegistered: false)
    private static let registered = answer(pushRegistered: true)
    private static let olderServer = answer(pushRegistered: nil)

    private func makeSeam(keyInUse: Bool, answer: String,
                          sent: @escaping (CreateDeviceRequest) -> Void,
                          sealed: @escaping (String) -> Void) -> DeviceRegistrar.Seam {
        let suite = "FirstRunDeviceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return DeviceRegistrar.Seam(
            userId: { Self.userId },
            deviceId: { Self.deviceId },
            seal: { _, fieldTag in
                sealed(fieldTag)
                return keyInUse ? EncryptedBlobRequest(nonce: "n-\(fieldTag)", ciphertext: "c-\(fieldTag)") : nil
            },
            createDevice: { request in
                sent(request)
                return try APIService.decodeResponseBody(Data(answer.utf8))
            },
            defaults: defaults
        )
    }

    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    private func body(_ src: String, from start: String, to end: String) throws -> String {
        let a = try XCTUnwrap(src.range(of: start), start)
        let b = try XCTUnwrap(src.range(of: end, range: a.upperBound..<src.endIndex), end)
        return String(src[a.lowerBound..<b.lowerBound])
    }
}
