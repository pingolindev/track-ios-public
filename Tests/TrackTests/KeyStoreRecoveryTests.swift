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
import Security
import PingolinTrackSDK
@testable import Track

/// What the app does with the SDK's key store: the decisions, then the same
/// against the real SDK with a store that fails as asked.
@MainActor
final class KeyStoreRecoveryTests: XCTestCase {
    /// A key store in memory whose reads and deletes fail on demand.
    private final class MemoryStorage: KeyStorageCallback, @unchecked Sendable {
        private let lock = NSLock()
        private var stored: StoredKeyData?
        private var loadCount = 0
        var failReads = false
        var failDeletes = false

        init(_ data: StoredKeyData? = nil) { stored = data }

        var held: StoredKeyData? {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
        var loads: Int { lock.lock(); defer { lock.unlock() }; return loadCount }

        func loadKeys() throws -> StoredKeyData? {
            lock.lock(); defer { lock.unlock() }
            loadCount += 1
            if failReads { throw KeychainKeyStorageError.osStatus(errSecInteractionNotAllowed) }
            return stored
        }
        func storeKeys(data: StoredKeyData) throws { held = data }
        func deleteKeys() throws {
            if failDeletes { throw KeychainKeyStorageError.osStatus(errSecIO) }
            held = nil
        }
    }

    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        super.setUp()
        suite = "key-store-recovery-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func manager(on storage: MemoryStorage) -> CryptoManager {
        let manager = CryptoManager()
        manager.registerSecureStorage(storage: storage)
        return manager
    }

    private func status(_ load: KeyStoreLoad, seed: Bool = false, entries: Bool = false) -> KeyStoreStatus {
        KeyStoreStatus(load: load, signingSeedUnreadable: seed, entriesUnreadable: entries)
    }

    /// A whole, readable store: the keys a sign-in imports, written by the SDK.
    private func wholeStore() -> StoredKeyData {
        let storage = MemoryStorage()
        let writer = manager(on: storage)
        XCTAssertFalse(try writer.loadPersistedKeys())
        _ = writer.generateKeypair()
        _ = writer.generateSigningKeypair()
        return storage.held!
    }

    // MARK: - The decisions

    /// Only a store that doesn't decode signs the person out; a seed or
    /// entries that didn't read raise the banner (the app still works); a read
    /// that failed, a wipe still owed, or no load yet show nothing.
    func testTheVerdictForEachState() {
        typealias R = KeyStoreRecovery
        XCTAssertEqual(R.verdict(status(.doesNotDecode)), .signOut)
        XCTAssertEqual(R.verdict(status(.doesNotDecode, seed: true, entries: true)), .signOut)
        XCTAssertEqual(R.verdict(status(.loaded)), .carryOn)
        XCTAssertEqual(R.verdict(status(.loaded, seed: true)), .banner)
        XCTAssertEqual(R.verdict(status(.loaded, entries: true)), .banner)
        XCTAssertEqual(R.verdict(status(.nothingStored)), .carryOn)
        XCTAssertEqual(R.verdict(status(.readFailed)), .carryOn, "never signed out for a read that failed")
        XCTAssertEqual(R.verdict(status(.readFailed, entries: true)), .carryOn)
        XCTAssertEqual(R.verdict(status(.deleteFailed)), .carryOn)
        XCTAssertEqual(R.verdict(status(.notLoaded)), .carryOn)
        XCTAssertEqual(R.syncErrorText, "Sync error. Please sign in again.", "the sign-in notice, word for word")
    }

    /// The pins go out at a sign-out only from a store that loaded.
    func testPinsExportOnlyFromAStoreThatLoaded() {
        XCTAssertTrue(KeyStoreRecovery.pinsExportable(status(.loaded)))
        XCTAssertTrue(KeyStoreRecovery.pinsExportable(status(.nothingStored)))
        for load in [KeyStoreLoad.readFailed, .doesNotDecode, .deleteFailed, .notLoaded] {
            XCTAssertFalse(KeyStoreRecovery.pinsExportable(status(load)), "\(load)")
        }
    }

    /// The SDK's calls a sign-in makes, recorded.
    private final class Calls {
        var log: [String] = []
        var statuses: [KeyStoreStatus] = []
        var owed = false
        var dropFails = false

        func store() -> KeyStoreRecovery.Store {
            KeyStoreRecovery.Store(
                status: { [unowned self] in
                    log.append("status")
                    return statuses.count > 1 ? statuses.removeFirst() : statuses[0]
                },
                load: { [unowned self] in log.append("load") },
                clear: { [unowned self] in log.append("clear") },
                dropUnreadableEntries: { [unowned self] in
                    log.append("drop")
                    if dropFails { throw MobileError.StorageError(message: "x") }
                    return 1
                },
                wipeOwed: { [unowned self] in owed })
        }
    }

    private func signIn(_ statuses: [KeyStoreStatus], owed: Bool = false, dropFails: Bool = false)
        -> (KeyStoreRecovery.BeforeImport, [String]) {
        let calls = Calls()
        calls.statuses = statuses
        calls.owed = owed
        calls.dropFails = dropFails
        let recovery = KeyStoreRecovery(store: calls.store())
        return (recovery.beforeSignInImport(), calls.log.filter { $0 != "status" })
    }

    /// At the sign-in: the store is read again; still not decoding, it is
    /// cleared and the import follows; entries that didn't read go; a kept
    /// seed needs nothing more; a read that failed never clears and stops the
    /// sign-in.
    func testTheSignInReadsAgainThenClearsOrDropsOrStops() {
        XCTAssertEqual(signIn([status(.doesNotDecode)]).0, .importKeys)
        XCTAssertEqual(signIn([status(.doesNotDecode)]).1, ["load", "clear"])
        XCTAssertEqual(signIn([status(.loaded, entries: true)]).1, ["load", "drop"])
        XCTAssertEqual(signIn([status(.loaded, seed: true)]).1, ["load"], "the import replaces the seed")
        XCTAssertEqual(signIn([status(.loaded)]).1, ["load"])
        XCTAssertEqual(signIn([status(.nothingStored)]).1, ["load"])
        let failed = signIn([status(.readFailed)])
        XCTAssertEqual(failed.0, .stop)
        XCTAssertEqual(failed.1, ["load"], "never cleared, nothing dropped")
        let dropFailed = signIn([status(.loaded, entries: true)], dropFails: true)
        XCTAssertEqual(dropFailed.0, .importKeys, "kept as they were; the banner stays")
    }

    /// A wipe owed is paid first. Paid (the clear leaves `.loaded`): the
    /// sign-in goes on as usual. Still owed: nothing is loaded or written, and
    /// the import stays in memory.
    func testTheSignInPaysAnOwedWipeFirst() {
        let paid = signIn([status(.loaded), status(.nothingStored)], owed: true)
        XCTAssertEqual(paid.0, .importKeys)
        XCTAssertEqual(paid.1, ["clear", "load"])
        let stillOwed = signIn([status(.deleteFailed)], owed: true)
        XCTAssertEqual(stillOwed.0, .importKeys)
        XCTAssertEqual(stillOwed.1, ["clear"], "nothing loaded")
    }

    /// The banner follows the store, and goes at a sign-out.
    func testTheBannerFollowsTheStore() {
        let calls = Calls()
        calls.statuses = [status(.loaded, entries: true), status(.loaded)]
        let recovery = KeyStoreRecovery(store: calls.store())
        XCTAssertEqual(recovery.check(), .banner)
        XCTAssertTrue(recovery.showsSyncBanner)
        XCTAssertEqual(recovery.check(), .carryOn)
        XCTAssertFalse(recovery.showsSyncBanner)
        calls.statuses = [status(.loaded, seed: true)]
        _ = recovery.check()
        recovery.signedOut()
        XCTAssertFalse(recovery.showsSyncBanner)
    }

    // MARK: - With the real SDK

    /// A store that doesn't decode: the verdict signs the person out, and the
    /// sign-in clears it; the import then writes it whole.
    func testAStoreThatDoesntDecodeIsClearedAtTheSignIn() throws {
        var broken = wholeStore()
        broken.circleKeysJson = "{not json"
        let storage = MemoryStorage(broken)
        let sdk = manager(on: storage)
        XCTAssertThrowsError(try sdk.loadPersistedKeys())
        XCTAssertEqual(sdk.keyStoreStatus().load, .doesNotDecode)
        let recovery = KeyStoreRecovery(store: .sdk(sdk, defaults))
        XCTAssertEqual(recovery.check(), .signOut)
        XCTAssertEqual(storage.held, broken, "nothing written over it before the sign-in")

        XCTAssertEqual(recovery.beforeSignInImport(), .importKeys)
        XCTAssertEqual(sdk.keyStoreStatus().load, .loaded)
        XCTAssertNil(storage.held, "cleared")
        _ = sdk.generateKeypair()
        let written = try XCTUnwrap(storage.held, "the import writes it whole")
        let relaunched = manager(on: MemoryStorage(written))
        XCTAssertTrue(try relaunched.loadPersistedKeys())
        XCTAssertEqual(relaunched.keyStoreStatus().load, .loaded)
    }

    /// A read the platform refused: nothing shown, never cleared, and the
    /// sign-in stops with the store as it was.
    func testAStoreThatCantBeReadIsNeverCleared() throws {
        let whole = wholeStore()
        let storage = MemoryStorage(whole)
        storage.failReads = true
        let sdk = manager(on: storage)
        XCTAssertThrowsError(try sdk.loadPersistedKeys())
        XCTAssertEqual(sdk.keyStoreStatus().load, .readFailed)
        let recovery = KeyStoreRecovery(store: .sdk(sdk, defaults))
        XCTAssertEqual(recovery.check(), .carryOn)
        XCTAssertFalse(recovery.showsSyncBanner)
        XCTAssertEqual(recovery.beforeSignInImport(), .stop)
        XCTAssertEqual(storage.held, whole, "never cleared")
        XCTAssertFalse(KeyStoreRecovery.pinsExportable(sdk.keyStoreStatus()))
    }

    /// A write cut short (the private key without the circle keys): the
    /// Keychain callback gives what it has, with "" for the missing part, so
    /// the SDK says it doesn't decode, and the sign-in clears it. nil only
    /// when nothing at all is stored.
    func testAHalfWrittenStoreDoesntDecode() throws {
        XCTAssertNil(KeychainKeyStorageCallback.stored(privateKey: nil, circleKeysJson: nil, pinnedKeysJson: nil,
                                                       signingPrivateKeyB64: nil))
        let whole = wholeStore()
        let half = try XCTUnwrap(KeychainKeyStorageCallback.stored(
            privateKey: whole.privateKey, circleKeysJson: nil, pinnedKeysJson: whole.pinnedKeysJson,
            signingPrivateKeyB64: whole.signingPrivateKeyB64))
        XCTAssertEqual(half.circleKeysJson, "", "never nil, never \"{}\"")
        let onlyPins = try XCTUnwrap(KeychainKeyStorageCallback.stored(
            privateKey: nil, circleKeysJson: nil, pinnedKeysJson: "{}", signingPrivateKeyB64: nil))
        XCTAssertEqual(onlyPins.privateKey, "")
        let storage = MemoryStorage(half)
        let sdk = manager(on: storage)
        XCTAssertThrowsError(try sdk.loadPersistedKeys())
        XCTAssertEqual(sdk.keyStoreStatus().load, .doesNotDecode)
        XCTAssertEqual(KeyStoreRecovery(store: .sdk(sdk, defaults)).beforeSignInImport(), .importKeys)
        XCTAssertNil(storage.held, "cleared at the sign-in")
    }

    /// Entries that didn't read: the banner, and the sign-in drops them, and
    /// only them, before its key sync.
    func testEntriesThatDidntReadGoAtTheSignIn() throws {
        var withBadKey = wholeStore()
        withBadKey.circleKeysJson = #"{"c1c1c1c1-0000-0000-0000-000000000001":{"9":"AAAA"}}"#
        let storage = MemoryStorage(withBadKey)
        let sdk = manager(on: storage)
        XCTAssertTrue(try sdk.loadPersistedKeys())
        XCTAssertTrue(sdk.keyStoreStatus().entriesUnreadable)
        let recovery = KeyStoreRecovery(store: .sdk(sdk, defaults))
        XCTAssertEqual(recovery.check(), .banner)
        XCTAssertEqual(recovery.beforeSignInImport(), .importKeys)
        XCTAssertFalse(sdk.keyStoreStatus().entriesUnreadable)
        XCTAssertEqual(recovery.check(), .carryOn)
        XCTAssertFalse(recovery.showsSyncBanner)
        XCTAssertEqual(storage.held?.privateKey, withBadKey.privateKey, "the rest written back as it was")
    }

    // MARK: - The owed wipe

    /// A clear whose delete the platform refuses leaves a wipe owed, kept in
    /// the app's own defaults. The next launch pays it before any load; while
    /// it stays owed nothing is loaded; once paid, the load runs.
    func testARefusedDeleteIsOwedAndPaidBeforeAnyLoad() throws {
        let storage = MemoryStorage(wholeStore())
        storage.failDeletes = true
        let signingOut = manager(on: storage)
        XCTAssertTrue(try signingOut.loadPersistedKeys())
        XCTAssertFalse(OwedWipe.clear(signingOut, defaults))
        XCTAssertEqual(signingOut.keyStoreStatus().load, .deleteFailed)
        XCTAssertTrue(OwedWipe.isOwed(defaults))
        XCTAssertNotNil(storage.held, "still there")

        // The app's own loads are counted: the SDK refuses a load while the
        // wipe is owed anyway, which would hide an app that asks for one.
        var appLoads = 0
        let counting: SDKCrypto.Load = { appLoads += 1; return try $0.loadPersistedKeys() }
        let loadsBefore = storage.loads
        let stillFailing = manager(on: storage)
        SDKCrypto.prepare(stillFailing, defaults, load: counting)
        XCTAssertEqual(appLoads, 0, "the app asks for no load while it is owed")
        XCTAssertEqual(storage.loads, loadsBefore, "nothing loaded while it is owed")
        XCTAssertTrue(OwedWipe.isOwed(defaults))
        XCTAssertEqual(stillFailing.keyStoreStatus().load, .deleteFailed)

        storage.failDeletes = false
        let next = manager(on: storage)
        SDKCrypto.prepare(next, defaults, load: counting)
        XCTAssertFalse(OwedWipe.isOwed(defaults), "paid")
        XCTAssertNil(storage.held)
        XCTAssertEqual(appLoads, 1, "then loaded")
        XCTAssertEqual(storage.loads, loadsBefore + 1)
        XCTAssertEqual(next.keyStoreStatus().load, .nothingStored)
    }

    /// The load the unlock retries pays an owed wipe first too; still owed,
    /// the app asks for no load. Nothing owed, it just loads.
    func testTheUnlocksRetriedLoadPaysAnOwedWipeFirst() throws {
        var appLoads = 0
        let counting: SDKCrypto.Load = { appLoads += 1; return try $0.loadPersistedKeys() }
        let storage = MemoryStorage(wholeStore())
        storage.failDeletes = true
        let sdk = manager(on: storage)
        XCTAssertTrue(try sdk.loadPersistedKeys())
        XCTAssertFalse(OwedWipe.clear(sdk, defaults))
        SDKCrypto.loadAgain(sdk, defaults, load: counting)
        XCTAssertEqual(appLoads, 0, "still owed: no load asked for")
        XCTAssertTrue(OwedWipe.isOwed(defaults))
        storage.failDeletes = false
        SDKCrypto.loadAgain(sdk, defaults, load: counting)
        XCTAssertEqual(appLoads, 1)
        XCTAssertFalse(OwedWipe.isOwed(defaults), "paid first")
        XCTAssertNil(storage.held)
        let fresh = manager(on: MemoryStorage(wholeStore()))
        SDKCrypto.loadAgain(fresh, defaults, load: counting)
        XCTAssertEqual(appLoads, 2, "nothing owed: it loads")
        XCTAssertEqual(fresh.keyStoreStatus().load, .loaded)
    }

    /// Nothing owed: the launch just loads. Only a clear's `.loaded` pays a
    /// wipe; any other state leaves the flag as it is.
    func testNothingOwedJustLoads() throws {
        let storage = MemoryStorage(wholeStore())
        let sdk = manager(on: storage)
        SDKCrypto.prepare(sdk, defaults)
        XCTAssertEqual(sdk.keyStoreStatus().load, .loaded)
        XCTAssertNotNil(storage.held)
        defaults.set(true, forKey: ExtensionBridgeKeys.keyStoreWipeOwed)
        for load in [KeyStoreLoad.nothingStored, .readFailed, .doesNotDecode, .notLoaded] {
            XCTAssertFalse(OwedWipe.note(load, defaults))
            XCTAssertTrue(OwedWipe.isOwed(defaults), "\(load)")
        }
        XCTAssertTrue(OwedWipe.note(.loaded, defaults))
        XCTAssertFalse(OwedWipe.isOwed(defaults))
    }

    /// At the sign-in, a wipe still owed: paid first. Still refused, the
    /// sign-in goes on with nothing loaded; the store is as it was.
    func testTheSignInPaysTheOwedWipeOrLoadsNothing() throws {
        let whole = wholeStore()
        let storage = MemoryStorage(whole)
        storage.failDeletes = true
        let sdk = manager(on: storage)
        XCTAssertTrue(try sdk.loadPersistedKeys())
        XCTAssertFalse(OwedWipe.clear(sdk, defaults))
        let loads = storage.loads
        XCTAssertEqual(KeyStoreRecovery(store: .sdk(sdk, defaults)).beforeSignInImport(), .importKeys)
        XCTAssertEqual(storage.loads, loads, "nothing loaded")
        XCTAssertTrue(OwedWipe.isOwed(defaults))
        storage.failDeletes = false
        XCTAssertEqual(KeyStoreRecovery(store: .sdk(sdk, defaults)).beforeSignInImport(), .importKeys)
        XCTAssertFalse(OwedWipe.isOwed(defaults))
        XCTAssertNil(storage.held)
    }

    // MARK: - Wiring

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func swiftFiles(under folder: String) throws -> [String] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let base = root.appendingPathComponent(folder)
        let files = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        return files.map { $0.path.replacingOccurrences(of: root.path + "/", with: "") }
    }

    /// Every clear goes through `OwedWipe`, so a refused delete is always
    /// recorded.
    func testEveryClearGoesThroughTheOwedWipe() throws {
        var clears: [String] = []
        for folder in ["App", "NotificationExtension"] {
            for path in try swiftFiles(under: folder) {
                let code = try source(path).components(separatedBy: "\n")
                    .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                let count = code.map { $0.components(separatedBy: "clearAllKeys()").count - 1 }.reduce(0, +)
                if count > 0 { clears.append("\(path): \(count)") }
            }
        }
        XCTAssertEqual(clears, ["App/Services/SDKCrypto.swift: 1"])
        let sdk = try source("App/Services/SDKCrypto.swift")
        XCTAssertTrue(sdk.contains("        manager.clearAllKeys()\n        return note(manager.keyStoreStatus().load, defaults)\n"))
        XCTAssertTrue(sdk.contains("        if OwedWipe.isOwed(defaults), !OwedWipe.clear(manager, defaults) { return }\n"
                                   + "        do {\n            _ = try load(manager)"),
                      "paid before the launch's load")
        XCTAssertTrue(sdk.contains("        prepare(manager)\n        return manager\n"), "the app's launch uses the real load")
        XCTAssertTrue(sdk.contains("        ) { _ in\n            loadAgain(manager)\n"),
                      "the load the unlock retries is loadAgain's (tested above)")
        let auth = try source("App/Managers/AuthManager.swift")
        XCTAssertTrue(auth.contains("        PendingCircleLocations.shared.clearAll()\n        // A delete the platform refuses leaves a wipe owed.\n        OwedWipe.clear(cryptoManager)\n"))
    }

    /// The launch judges the store as soon as a session is found, and again
    /// before either way it signs in (the load after the unlock may have run
    /// meanwhile); a signed-in session judges it after that load. The sign-in
    /// repairs the store before its keys go in; a store that can't be read
    /// stops it. The pins go out only from a store that loaded. Signed out:
    /// no banner.
    func testTheLaunchAndTheSignInJudgeTheStore() throws {
        let auth = try source("App/Managers/AuthManager.swift")
        XCTAssertTrue(auth.contains("        case .stored:\n            break\n        }\n"
                                    + "        // The SDK's key store as the launch found it: one that\n"
                                    + "        // doesn't decode ends the session, with the sync error.\n"
                                    + "        if endSessionForKeyStore() { return }\n"))
        XCTAssertEqual(auth.components(separatedBy: "if endSessionForKeyStore() { return }\n").count - 1, 3)
        XCTAssertTrue(auth.contains("        if endSessionForKeyStore() { return }\n        isAuthenticated = true\n        #if DEBUG"),
                      "the launch, finished in completeLaunch")
        XCTAssertTrue(auth.contains("                if endSessionForKeyStore() { return }\n                isAuthenticated = true\n                ErrorBanner.shared.post(error)"))
        XCTAssertTrue(auth.contains("        guard KeyStoreRecovery.shared.check() == .signOut else { return false }\n"
                                    + "        signInNotice = KeyStoreRecovery.syncErrorText\n        expireSession()\n        return true\n"))
        XCTAssertTrue(auth.contains("for await _ in NotificationCenter.default.notifications(named: SDKCrypto.keysLoadedAgain) {"))
        XCTAssertTrue(auth.contains("    private func keyStoreLoadedAgain() {\n        guard isAuthenticated else { return }\n        endSessionForKeyStore()\n    }\n"))
        let complete = try XCTUnwrap(auth.range(of: "    private func completeLogin(")).upperBound
        let repair = try XCTUnwrap(auth.range(of: "        if KeyStoreRecovery.shared.beforeSignInImport() == .stop {\n"
                                              + "            Self.authLog.error(\"sign-in: the key store could not be read; nothing was cleared\")\n"
                                              + "            withdrawIncompleteSignIn()\n            throw AuthError.keysUnavailable\n        }\n"
                                              + "        if let signInKeys {\n"))
        let purge = try XCTUnwrap(auth.range(of: "            await purgeAccountData()\n            deleteOutgoingKeyMaterial()"))
        XCTAssertTrue(complete < purge.lowerBound && purge.upperBound < repair.lowerBound,
                      "after an account switch's purge, before any key goes in")
        XCTAssertTrue(auth.contains("        isAuthenticated = true\n        signInNotice = nil\n"))
        XCTAssertTrue(auth.contains("           KeyStoreRecovery.pinsExportable(cryptoManager.keyStoreStatus()),\n"
                                    + "           RetainedMemberPins.retain(owner: userId, crypto: cryptoManager) {"))
        XCTAssertEqual(auth.components(separatedBy: "        KeyStoreRecovery.shared.signedOut()\n    }\n").count - 1, 2,
                       "expireSession and logout")
        let sdk = try source("App/Services/SDKCrypto.swift")
        XCTAssertTrue(sdk.contains("            if load == .readFailed { retryLoadWhenProtectedDataAvailable(manager) }"))
        XCTAssertTrue(sdk.contains("            NotificationCenter.default.post(name: keysLoadedAgain, object: nil)"))
        XCTAssertTrue(try source("App/Views/Auth/LoginView.swift").contains("if let notice = authManager.signInNotice {"))
        XCTAssertTrue(try source("App/Views/Map/MapView.swift").contains("if keyStoreRecovery.showsSyncBanner {"))
        let settings = try source("App/Views/Settings/SettingsView.swift")
        XCTAssertTrue(settings.contains("        if keyStoreRecovery.showsSyncBanner {\n            Section {"))
        XCTAssertTrue(settings.contains("                    showingLogoutConfirm = true\n                }) {\n"
                                        + "                    Label(\"Sign Out\", systemImage: \"rectangle.portrait.and.arrow.right\")\n"
                                        + "                }\n                .foregroundStyle(.red)\n"
                                        + "                .accessibilityIdentifier(\"sync-error-sign-out\")"))
    }

    /// The extension never clears; while a wipe is owed it loads nothing.
    func testTheExtensionLoadsNothingWhileAWipeIsOwed() throws {
        let guardLine = ".bool(forKey: ExtensionBridgeKeys.keyStoreWipeOwed) != true else { return nil }"
        let handover = try source("NotificationExtension/BackgroundHandover.swift")
        let makeCrypto = try XCTUnwrap(handover.range(of: "            makeCrypto: {"))
        let guarded = try XCTUnwrap(handover.range(of: guardLine))
        let load = try XCTUnwrap(handover.range(of: "manager.loadPersistedKeys()"))
        XCTAssertTrue(makeCrypto.upperBound < guarded.lowerBound && guarded.upperBound < load.lowerBound)
        let service = try source("NotificationExtension/NotificationService.swift")
        XCTAssertTrue(service.contains("    private static let cryptoManager: CryptoManager? = {\n"
                                       + "        // Nothing while a wipe of the key store is owed (`OwedWipe`).\n"
                                       + "        guard UserDefaults(suiteName: ExtensionBridgeKeys.suite)?\n            " + guardLine))
        for path in try swiftFiles(under: "NotificationExtension") {
            XCTAssertFalse(try source(path).contains("clearAllKeys"), path)
        }
    }
}
