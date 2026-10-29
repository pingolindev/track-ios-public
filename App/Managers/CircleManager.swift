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
import Combine
import os
import CoreLocation
import UIKit
import PingolinTrackSDK

/// Manages circles and members
@MainActor
final class CircleManager: ObservableObject {
    static let shared = CircleManager()

    // MARK: - Published State

    @Published private(set) var circles: [Circle] = []
    @Published private(set) var activeCircle: Circle?
    @Published private(set) var members: [String: [CircleMember]] = [:] // circleId -> members
    @Published private(set) var memberLocations: [String: LocationData] = [:] // userId -> latest location
    /// The last location each member who switched real-time sharing off (and
    /// kept history on) shared in a circle, frozen: `/latest`'s `last_known`.
    /// Kept APART from `memberLocations` on purpose. Everything that judges a
    /// member (inactivity, low battery, place alerts, "last seen", the replay
    /// guard) reads `memberLocations` and a refresh's `refreshedUserIds`, and
    /// must never see these; only the map and the member card draw them. A
    /// refresh of the circle replaces them, never appends. userId -> row,
    /// scoped as `memberLocations` is.
    @Published private(set) var frozenLocations: [String: LocationData] = [:]
    /// Frozen rows kept drawn across a rotation, for a while. In memory only.
    private var frozenGrace = FrozenGrace()
    @Published private(set) var privacySettings: [String: PrivacySettings] = [:] // circleId -> settings
    /// Invites SENT from a circle and still outstanding. circleId -> invites.
    /// Owner/admin only; a member's fetch 403s, so this stays empty for them.
    @Published private(set) var pendingInvites: [String: [PendingInviteResponse]] = [:]
    @Published private(set) var isLoading = false
    /// circleId -> when a rotation may be tried again after a failure.
    private var rotationRetryAt: [String: Date] = [:]
    static let rotationBackoff: TimeInterval = 5 * 60
    /// The server takes one rotation of a circle per 30 s. Its 429 is retried
    /// after the reply's Retry-After, else after this, with a few seconds of
    /// jitter: never the 5 minutes of `rotationBackoff`, which outlast the
    /// 5-minute read deadline a departure sets.
    static let rotationRateLimitRetry: TimeInterval = 35
    /// Diagnostic captured from the most recent loadCircles attempt. Surfaced
    /// in the Circles-tab empty state to show what the server actually
    /// returned.
    @Published private(set) var lastDiagnostic: String?
    /// True while a foreground `loadMemberLocations` round-trip has been in
    /// flight for longer than `slowRefreshThreshold`. The Map's refresh-status
    /// pill watches this to render "Updating…". Distinct from `isLoading` (which
    /// covers the whole circle-tree load). Mirrors the Android app's
    /// `MapViewModel.isRefreshingLocations`.
    ///
    /// Only a slow refresh flips it: flipping for EVERY refresh — twice a tick
    /// on the 20 s foreground loop, and on every background pass too — would
    /// make the pill flicker every 20 seconds and fan two publishes a tick out
    /// to every observer of this manager. A refresh that answers within a
    /// second has nothing worth announcing; one that does not, still shows the
    /// pill.
    @Published private(set) var isRefreshingLocations = false
    /// Refreshes in flight; the pill clears when the last one ends.
    private var locationRefreshesInFlight = 0
    static let slowRefreshThreshold: TimeInterval = 1.0
    /// Non-nil after a failed `loadMemberLocations` attempt that looked
    /// like a connectivity issue (anything except a clean "circle gone"
    /// 404). Cleared on the next successful fetch. The Map's pill turns
    /// into "Couldn't reach server — showing last known" while this is
    /// set.
    @Published private(set) var lastLocationRefreshFailedAt: Date?
    /// Each circle's whole roster as the server sent it, confirmed or not. Every
    /// decision reads this; `members` holds only who is shown.
    private(set) var rosters: [String: [CircleMember]] = [:]
    /// Per circle, the members (`CanonicalId.key`) whose sealed display name
    /// opened here at the last roster load: the only names an SOS alarm may
    /// show (`SOSManager.openedName`).
    private(set) var openedNames: [String: Set<String>] = [:]

    /// The last confirmation pass per circle.
    private(set) var membership: [String: MembershipConfirmation.Result] = [:]

    /// What that pass read, per circle and member — for delivery.
    private var membershipCandidates: [String: [String: MembershipCandidate]] = [:]
    /// The roster rows as served, for the backfill's check of who handed a
    /// member their copy.
    private var rosterWraps: [String: [String: CircleMemberResponse]] = [:]
    /// How many people each circle kept out, for its owners and admins.
    @Published private(set) var hiddenMemberCounts: [String: Int] = [:]

    /// Who this device removed without the refresh, per circle, until the
    /// refresh lands — so the owner reads "Finishing removing Sam", not "a member".
    @Published private(set) var pendingRemovalNames: [String: String] = [:]

    // MARK: - Dependencies

    private let api = APIService.shared
    private let keychain = KeychainService.shared
    private let cryptoManager = SDKCrypto.cryptoManager
    /// Circle key + name decryption diagnostics. `os.Logger`, not `print`:
    /// `print` goes to stdout, which a release build on a real device discards,
    /// so none of the existing `[Track]` lines in this file are visible when a
    /// user reports a problem from a TestFlight build. These are, via
    /// `log collect --device-udid`.
    static let keyLog = Logger(subsystem: "com.pingolin.track", category: "CircleKeys")
    /// Opens circle keys wrapped to an identity from before a password reset.
    /// A re-check that opens another loads the circles again, in full.
    private let previousIdentityLoader = PreviousIdentityLoader(
        api: APIService.shared, cryptoManager: SDKCrypto.cryptoManager,
        onOpened: {
            try? await CircleManager.shared.loadCircles()
            // The personal copy from before the reset may open now too,
            // kept retired; then a new personal key is minted, asking
            // nobody, without waiting for the next launch.
            if !SelfKeyManager.personalKeyInUse(SDKCrypto.cryptoManager) {
                await SelfKeyManager.ensure(mayReplace: false)
            }
        })
    private let locationService = LocationService.shared

    private var cancellables = Set<AnyCancellable>()
    private var locationSyncTimer: Timer?
    /// The circle list as last written to the on-disk cache, so an unchanged
    /// list is not rewritten on every refresh.
    private var lastCachedCirclesData: Data?

    // Upload throttle state (see `setupLocationSync`).
    private var pendingSendRequest: LocationService.SendRequest?
    private var lastUploadFlushAt: Date?
    private var uploadFlushScheduled = false
    static let uploadThrottleInterval: TimeInterval = 10

    /// Verify on store: our own view of each circle member's Ed25519
    /// signing pubkey (hex), keyed by "circleId:userId". Populated by
    /// `loadMembers` from the member-list response and read by the
    /// circle-key store sites in `loadCircles`, so a wrap's signature is
    /// verified against the signer key WE pinned — never one the same
    /// server handed us alongside the wrap (which it could trivially
    /// forge). In-memory only (rebuilt each launch); nil on a miss makes
    /// the SDK grace-accept (no lockout). Mirrors the Android app's
    /// `signingPubkeyCache`.
    private var signingPubkeyCache: [String: String] = [:]

    /// Companion to `signingPubkeyCache`: each member's X25519 sharing pubkey
    /// (hex), keyed by "circleId:userId". Populated by `loadMembers` from the
    /// SAME member-list response, so the pair a safety number is computed over
    /// always comes from one fetch. Read by `MemberDetailView`, which must NOT
    /// go to `GET /circles/:id/member-public-keys` for it — the server allows
    /// that route to owners and admins only, so a plain member asking for it
    /// gets 403 "Insufficient permissions" and never sees a safety number. The
    /// roster route hands every member both keys. In-memory only (rebuilt each
    /// launch). Mirrors the Android app's `sharingPubkeyCache`.
    private var sharingPubkeyCache: [String: String] = [:]

    /// Does the account have data from before an email password reset that the
    /// portal can restore? nil until asked (see `refinePreResetLocks`).
    private var accountHasPreResetData: Bool?
    private var preResetProbeAttemptAt: Date?

    /// Circle ids with an auto-rotation currently in flight. The 20s
    /// foreground poll re-enters the rotation sweep in `loadCircles` ~180×/hr; a
    /// rotation that hasn't ACKed within a tick would otherwise be launched a
    /// SECOND time concurrently for the same circle, both runs racing the SDK's
    /// local key-version bump (which happens BEFORE the server POST) → this
    /// device ends up on a version the other members never received. A circle id
    /// is inserted before its rotation Task launches and removed when the Task
    /// settles. @MainActor-isolated (whole class), so the check-and-insert in the
    /// sweep is atomic. Not a custody issue — wraps stay pin-gated.
    private var rotationsInFlight: Set<String> = []

    /// Per-(circle, member) last-accepted AUTHENTICATED location timestamp
    /// (epoch ms). Replay/reorder guard: a member's location is E2E-encrypted
    /// and its `timestamp` is AEAD-authenticated (inside the ciphertext, so
    /// the server can't forge it), but a hostile/compromised server can still
    /// REPLAY or REORDER old envelopes. A decrypted member location whose
    /// authenticated timestamp is <= the last accepted one FOR THAT CIRCLE is
    /// dropped so the displayed pin never rewinds. Only the authenticated
    /// timestamp feeds this — the coarse server `dayBucket` fallback is never
    /// used as a guard value.
    ///
    /// Keyed per circle via `cacheKey(circleId, userId)` ("circleId:userId"),
    /// NOT globally per user: the SAME physical update is re-encrypted
    /// independently per circle with an IDENTICAL authenticated timestamp, so
    /// a global-per-user key would false-drop that member (newTs == lastTs)
    /// when the update surfaces in a second circle. Per-circle keying accepts
    /// it as first-seen in each circle while still catching a replay within a
    /// circle. iOS shows one location per user (`memberLocations` is keyed by
    /// user id), so no device dimension is needed. (Matches the Android app's
    /// per-(circle, member) guard.)
    ///
    /// Mutated only on the @MainActor publish path. A circle's entries are
    /// pruned in `pruneLocalCircle`; the whole table is wiped on logout via
    /// `resetReplayGuard()`.
    private var lastAcceptedLocationTs: [String: Int64] = [:]
    /// The area drawn for each approximate member, per circle: the largest seen
    /// while they stay approximate, so it keeps its size between refreshes.
    /// Wiped with the replay guard on logout.
    private var approximateAreas = ApproximateAreaMemory()
    /// Each member's row as each circle last accepted it (`CircleRowMemory`):
    /// what a circle's alert rules read (`acceptedRow(of:in:)`), never
    /// `memberLocations`. Trimmed wherever `memberLocations` is.
    private var rowsByCircle = CircleRowMemory()

    private func cacheKey(_ circleId: String, _ userId: String) -> String {
        "\(circleId):\(userId)"
    }

    /// The signer's locally-known Ed25519 signing pubkey, or nil when we
    /// haven't seen/pinned this member in this circle yet.
    private func cachedMemberSigningPubkey(circleId: String, userId: String) -> String? {
        signingPubkeyCache[cacheKey(circleId, userId)]
    }

    /// A member's locally-known (sharing, signing) pubkey pair as lowercase hex,
    /// or nil until `loadMembers` has run for this circle. Both keys or neither:
    /// a safety number needs the pair, and a half-populated entry would only
    /// produce a confusing partial screen.
    func cachedMemberKeys(circleId: String, userId: String) -> (sharing: String, signing: String)? {
        let key = cacheKey(circleId, userId)
        guard let sharing = sharingPubkeyCache[key], !sharing.isEmpty,
              let signing = signingPubkeyCache[key], !signing.isEmpty else { return nil }
        return (sharing, signing)
    }

    private init() {
        setupLocationSync()
    }

    /// True when the error looks like a "circle is gone server-side"
    /// 404, rather than a connectivity blip. Used to gate the
    /// `lastLocationRefreshFailedAt` flag so a deleted circle doesn't
    /// surface the offline pill forever.
    /// Test seam for the carve-out below, which is only reachable through a live
    /// network call otherwise.
    static func isCircleNotFoundForTesting(_ error: Error) -> Bool { isCircleNotFound(error) }

    /// The order key-chain links must be imported in: newest `from_version`
    /// first, so that each link's source key is already present when it is
    /// used (v3→v2 before v2→v1). A link whose target is not older than its
    /// source is malformed and dropped rather than fed to the SDK.
    nonisolated static func chainImportOrder(_ links: [KeyChainLinkResponse]) -> [KeyChainLinkResponse] {
        links
            .filter { $0.toVersion < $0.fromVersion }
            .sorted { $0.fromVersion > $1.fromVersion }
    }

    private static func isCircleNotFound(_ error: Error) -> Bool {
        if let api = error as? APIError {
            return api.code == "http_404" || api.code == "not_found"
        }
        return false
    }

    /// Does this device hold the circle's CURRENT key — the version `GET /circles`
    /// says the circle is at?
    ///
    /// Not after a rotation that left us pending (an unapproved key change, a
    /// member not approved yet), and not before a peer's rotation has been
    /// imported. Anything new sealed under the key we DO hold is readable by
    /// whoever that rotation shut out: a removed member holds exactly that key.
    /// So nothing new is sealed for such a circle — locations, places,
    /// check-ins, destinations, alert settings, a rename — until the new wrap
    /// arrives. The personal key and a circle this device has not loaded are
    /// not judged here; a path that can run before the list loads uses
    /// `holdsCurrentKeyPrimed(for:)`.
    ///
    /// Nor while this device's rotation step is due: its key came only through
    /// an identity from before a password reset, or was taken on trust, and
    /// this device rotates the circle before it seals or hands over anything
    /// new under it (`rotationStepPending`).
    ///
    /// Nor while this device knows it is behind on the circle, whatever key
    /// version the server lists (behind is the device's own knowledge:
    /// `isBehind`): a server that spoils a record, or gets one passed over, and
    /// lists the circle at the version before it would have this device seal
    /// under a key the member that record removes still holds. SOS doesn't ask.
    func holdsCurrentKey(for circleId: String) -> Bool {
        Self.holdsCurrentKey(currentVersion: holdsCurrentVersion(for: circleId),
                             rotationStepDue: rotationStepPending(circleId), behind: isBehind(circleId))
    }

    /// Pure, for tests: `holdsCurrentKey(for:)`'s three conditions.
    nonisolated static func holdsCurrentKey(currentVersion: Bool, rotationStepDue: Bool, behind: Bool) -> Bool {
        currentVersion && !rotationStepDue && !behind
    }

    /// Whether this device knows it is behind on the circle (the SDK's
    /// `isBehind`: its own state only, never the server's word). Never for the
    /// personal key.
    func isBehind(_ circleId: String) -> Bool {
        circleId != SelfKeyManager.selfCircleUuid && cryptoManager.isBehind(circleId: circleId)
    }

    /// The circle's key version this device holds now; nil when it holds none.
    func heldVersion(for circleId: String) -> Int? {
        (try? cryptoManager.getActiveVersion(circleId: circleId)).map { Int($0) }
    }

    /// Pure, for tests: whether a failed circle creation was the server's
    /// refusal, so the circle was not made. No answer (offline, a timeout, a
    /// 5xx) isn't: the server may have made it.
    nonisolated static func creationWasRefused(_ error: Error) -> Bool {
        guard let api = error as? APIError else { return !(error is URLError) }
        let codes = [api.code, api.errorCode].compactMap { $0 }
        return !codes.contains { code in
            ["network_error", "circuit_open", "server_error", "internal_error", "http_408"].contains(code)
                || code.hasPrefix("http_5")
        }
    }

    /// Whether this device holds the key the circle is in now, and isn't behind
    /// on it by its own knowledge: what a key change seals under, and the one
    /// thing an unreadable name may still wait for.
    func holdsKeyInUse(_ circleId: String) -> Bool {
        holdsCurrentVersion(for: circleId) && !isBehind(circleId)
    }

    /// Whether this device holds the circle's current version (or newer), with
    /// no other condition: the rotation itself runs on this.
    func holdsCurrentVersion(for circleId: String) -> Bool {
        guard circleId != SelfKeyManager.selfCircleUuid,
              let circle = circles.first(where: { $0.id == circleId }) else { return true }
        let local = (try? cryptoManager.getActiveVersion(circleId: circleId)).map { Int($0) }
        return Self.holdsCurrentKey(localActiveVersion: local, circleKeyVersion: circle.keyVersion)
    }

    /// The rotation step, due on THIS device: the circle's active key came
    /// only through a restored identity from before a password reset (someone
    /// who had the old account keys has it too), or was taken on trust at
    /// first contact (it may be the server's choice), and this device may
    /// rotate the circle: an owner or admin holding the right to rotate, not
    /// receive-only — exactly the device `rotateCircleKey` rotates on. It
    /// rotates at once, before sealing or delivering anything new under that
    /// key. Where this device may not rotate, nothing waits: the next periodic
    /// or departure rotation ends it.
    func rotationStepPending(_ circleId: String) -> Bool {
        guard circleId != SelfKeyManager.selfCircleUuid,
              let circle = circles.first(where: { $0.id == circleId }) else { return false }
        return Self.rotationStepDue(
            cameViaPreviousIdentity: cryptoManager.activeKeyCameViaPreviousIdentity(circleId: circleId),
            takenOnTrust: cryptoManager.activeKeyTakenOnTrust(circleId: circleId),
            mayRotate: isOwnerOrAdmin(circle) && mayRotate(circle)
                && !selfIsReceiveOnly(circleId))
    }

    nonisolated static func rotationStepDue(cameViaPreviousIdentity: Bool, takenOnTrust: Bool, mayRotate: Bool) -> Bool {
        mayRotate && (cameViaPreviousIdentity || takenOnTrust)
    }

    /// The rule behind `holdsCurrentKey(for:)`, pure for tests. No key at all
    /// seals nothing either way.
    nonisolated static func holdsCurrentKey(localActiveVersion: Int?, circleKeyVersion: Int) -> Bool {
        guard let local = localActiveVersion else { return false }
        return local >= circleKeyVersion
    }

    // MARK: - This account's sealed name in each circle

    /// Names this process has sealed, by circle, version and name: one write
    /// each, so a server that does not reflect it back is not asked again and
    /// again. A failed write is forgotten, and a later roster load tries again.
    private var ownNamesSealed: Set<String> = []

    /// The name this account goes by in its circles, as web and Android seal
    /// it (`uploadEncryptedDisplayName`: the display name, else the address):
    /// this account's own, never anyone else's. nil: nothing to seal.
    nonisolated static func ownName(displayName: String?, email: String?) -> String? {
        for candidate in [displayName, email] {
            if let name = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        }
        return nil
    }

    /// Whether this account owes a circle its sealed name. Every app names a
    /// member only by the sealed name it opens itself, never the plaintext the
    /// server sends, so a member who never seals one is "A member" everywhere.
    /// Owed when this device holds the circle's current key, there is a name,
    /// and this account's own roster row carries none that opens here under
    /// the current version as that name. `opened`: the row's sealed name as
    /// it opened here, nil when it has none or it does not open.
    nonisolated static func ownNameOwed(name: String?, opened: (text: String, current: Bool)?,
                                        holdsCurrentKey: Bool) -> Bool {
        guard holdsCurrentKey, let name = name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return false }
        guard let opened else { return true }
        return !opened.current || opened.text != name
    }

    /// Whether this device's key for a circle moved on (a rotation it made, or
    /// a first key): a name sealed under the older one no longer opens for a
    /// newcomer.
    nonisolated static func versionAdvanced(from before: Int32?, to after: Int32?) -> Bool {
        guard let after else { return false }
        return before.map { after > $0 } ?? true
    }

    /// Seal this account's name under the circle's CURRENT key, with the field
    /// tag every reader opens it with ("display_name"), and send it
    /// (`PUT /circles/{id}/display-name`) — the same call web and Android make.
    /// Nothing while this device is behind in the circle, or there is no name.
    /// Called after creating, joining and rotating, and by the roster-load
    /// backfill (`sealOwnNameIfOwed`).
    func sealOwnName(circleId: String) async {
        guard !CanonicalId.isPersonalSlot(circleId), holdsCurrentKey(for: circleId),
              let name = Self.ownName(displayName: AuthManager.shared.currentUser?.displayName,
                                      email: AuthManager.shared.currentUser?.email),
              let version = try? cryptoManager.getActiveVersion(circleId: circleId) else { return }
        let marker = "\(CanonicalId.key(circleId))|\(version)|\(name)"
        guard ownNamesSealed.insert(marker).inserted else { return }
        do {
            let sealed = try cryptoManager.encryptDataV2(circleId: circleId, plaintext: name, fieldTag: "display_name")
            _ = try await api.setCircleDisplayName(
                circleId: circleId, sealed: EncryptedBlobRequest(nonce: sealed.nonce, ciphertext: sealed.ciphertext))
        } catch {
            ownNamesSealed.remove(marker)
            print("[Track] sealing this account's name for circle \(circleId.prefix(8)) failed: \(error)")
        }
    }

    /// The roster-load backfill: seal this account's name when its own row has
    /// none that opens here under the current version as its name
    /// (`ownNameOwed`). Nothing is sent when it is current.
    private func sealOwnNameIfOwed(circleId: String, ownRow: CircleMemberResponse) async {
        let name = Self.ownName(displayName: AuthManager.shared.currentUser?.displayName,
                                email: AuthManager.shared.currentUser?.email)
        let opened = ownRow.encryptedDisplayName.flatMap { blob -> (text: String, current: Bool)? in
            guard let text = try? cryptoManager.decryptDataV2Opened(
                circleId: circleId, encryptedData: EncryptedData(nonce: blob.nonce, ciphertext: blob.ciphertext),
                fieldTag: "display_name") else { return nil }
            return (text.text, cryptoManager.isCurrentKeyVersion(circleId: circleId, keyVersion: text.keyVersion))
        }
        guard Self.ownNameOwed(name: name, opened: opened, holdsCurrentKey: holdsCurrentKey(for: circleId)) else { return }
        await sealOwnName(circleId: circleId)
    }

    /// `holdsCurrentKey(for:)` as a precondition for a user action that seals
    /// something new for the circle: throws the explanation instead of sealing.
    func requireCurrentKey(for circleId: String) throws {
        guard holdsCurrentKey(for: circleId) else { throw CircleError.keyNotCurrent }
    }

    /// `holdsCurrentKey(for:)` for a path that can run before this process has
    /// loaded the circle list — a region wake of a cold app. Prime-on-miss, as
    /// `presencePosture(for:)` does for privacy: a circle not listed yet is
    /// loaded first (a failed fetch serves the cached list), because an unlisted
    /// circle is otherwise waved through under whatever key this device holds.
    func holdsCurrentKeyPrimed(for circleId: String) async -> Bool {
        if circleId != SelfKeyManager.selfCircleUuid,
           !circles.contains(where: { $0.id == circleId }) {
            try? await loadCircles(light: true)
        }
        return holdsCurrentKey(for: circleId)
    }

    /// The version of the caller's own stored wrap in a `GET /circles` row:
    /// `member_key_version` when the server sends it, else (an older
    /// server) the circle's `key_version`, the only label such a server
    /// provides.
    nonisolated static func ownWrapVersion(_ response: CircleResponse) -> Int {
        AccessHandover.ownWrapVersion(response)
    }

    /// Whether a light poll (the foreground refresh, every few minutes) installs
    /// our wrap from a `GET /circles` row: when this device holds no key for the
    /// circle yet, or the row's wrap is newer than the version it holds. The
    /// second case is how a device a rotation left behind catches up by itself
    /// once an owner or admin delivers the new key — no restart, no sign-in:
    /// the install raises the active version, which unlocks the circle and lets
    /// `holdsCurrentKey(for:)` seal for it again.
    nonisolated static func lightPollInstalls(heldVersion: Int?, _ response: CircleResponse) -> Bool {
        guard let heldVersion else { return true }
        return ownWrapVersion(response) > heldVersion
    }

    /// Whether a `GET /circles` row is shown locked: its name did not open, or
    /// our own wrap is older than the circle's key — a rotation left us pending,
    /// and a name it left sealed under the old key still opening changes
    /// nothing: nothing new is shared with the circle until the key arrives
    /// (`holdsCurrentKey(for:)`), and the member should see why.
    nonisolated static func isShownLocked(nameOpened: Bool, _ response: CircleResponse) -> Bool {
        AccessHandover.isShownLocked(nameOpened: nameOpened, response)
    }

    /// Why a circle whose name did not decrypt is locked, from what one
    /// `loadCircles` pass observed. Pure so every branch is testable; the order
    /// is the point — each cause hides the ones below it:
    ///   1. no account keys on this device at all: nothing opens, whatever the
    ///      circle, so the fix is signing in again, not anything per circle;
    ///   2. a wrap refused for its signature;
    ///   3. a wrap present that would not open — sealed to the account's
    ///      pre-reset keys when the account has such data to restore;
    ///   4. a rotation that deliberately left us out (our wrap is older than
    ///      the circle's key: `member_key_version` < `key_version`);
    ///   5. no wrap for us and no key held: an invite that carried none;
    ///   6. some key held, just not the one the name is under;
    ///   7. otherwise whatever the previous pass concluded (a light pass that
    ///      did not re-install the key learns nothing new).
    nonisolated static func lockReason(
        deviceHasAccountKeys: Bool,
        hasWrapForUs: Bool,
        wrapRefused: Bool,
        wrapFailedToOpen: Bool,
        holdsSomeKey: Bool,
        leftPending: Bool = false,
        accountHasPreResetData: Bool?,
        previousReason: CircleLockReason?
    ) -> CircleLockReason {
        if !deviceHasAccountKeys { return .keysNotUnlocked }
        if wrapRefused { return .keyNotVerified }
        if wrapFailedToOpen {
            return accountHasPreResetData == true ? .sealedBeforeReset : .keyUnreadable
        }
        if leftPending { return .awaitingNewerKey }
        if !hasWrapForUs && !holdsSomeKey { return .awaitingKey }
        if holdsSomeKey { return .keyOutOfDate }
        return previousReason ?? .keyUnavailable
    }

    /// The transition seed's capture point. On the first run of this code
    /// for an account, before anything that could pin or retire a pin (the
    /// first `loadCircles` / `loadMembers` both start here), the circle pins
    /// this device ALREADY holds become the approval record of every circle
    /// it has none for: once, as the one-time transition seed
    /// (`KeyDeliveryApprovals.takeTransitionSeed`). Waits until the account's
    /// keys — and with them the pins — are loaded, so an empty store is never
    /// taken for "no pins".
    private func takeTransitionSeedIfNeeded() {
        guard let me = AuthManager.shared.userId,
              !KeyDeliveryApprovals.shared.transitionSeedTaken(owner: me),
              (try? cryptoManager.exportPublicKey()) != nil,
              let export = try? cryptoManager.exportMemberPins(ownerUserId: me),
              let pins = Self.circlePins(fromExport: export) else { return }
        let seeded = KeyDeliveryApprovals.shared.takeTransitionSeed(owner: me, pins: pins)
        Self.keyLog.info("transition seed taken from existing pins: \(seeded, privacy: .public) circle(s)")
    }

    /// Circle id → the users pinned in it, from `exportMemberPins`'s JSON (the
    /// `pins` map is keyed "circleId:userId"; identity pins are not circle pins
    /// and never seed). nil when the export does not read.
    nonisolated static func circlePins(fromExport json: String) -> [String: Set<String>]? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let pins = object["pins"] as? [String: Any] else { return nil }
        var byCircle: [String: Set<String>] = [:]
        for key in pins.keys {
            guard let colon = key.firstIndex(of: ":") else { continue }
            let circleId = String(key[..<colon]), userId = String(key[key.index(after: colon)...])
            guard !circleId.isEmpty, !userId.isEmpty else { continue }
            byCircle[circleId, default: []].insert(userId)
        }
        return byCircle
    }

    /// What to do with the first key this device would hold for a circle.
    enum FirstKeyDecision: Equatable {
        /// From a member confirmed here, or our own signed wrap:
        /// `storeFirstCircleKey`, verified under that member's pinned key (or
        /// ours) and, when it can be, against the circle's sealed name.
        case fromConfirmedSender
        /// Taken on trust, once: nothing anchors this device in the
        /// circle; it anchors on the sender.
        case onTrustAndAnchor
        /// The sender is not confirmed here: store nothing and ask for a copy.
        case refuse
        /// This device's own invitation is to an email this pass couldn't match
        /// to the account's (`MembershipConfirmation.Result
        /// .ownInvitationUnchecked`): store nothing and ask for nothing; a pass
        /// that can, or an admission, decides.
        case wait
    }

    /// Whether this device takes the FIRST key it would hold for a circle:
    /// from a member it has confirmed; from our own slot when it is signed
    /// (the SDK verifies it under our own key); and, on a device nothing
    /// anchors yet — a legacy member before the backfill, a new device after
    /// a reset without the recovery key — from whoever on the member list
    /// sent it, trusted on first use, once. Otherwise nothing: an anchored
    /// device never takes a first key from someone it cannot confirm. Before
    /// the member list has loaded, only a signed own slot.
    ///
    /// With an own invitation to an email the pass couldn't match to this
    /// account's (none known in this process, or another address), who invited
    /// this device can't be confirmed, so it looks anchored by nobody: nothing is
    /// taken on trust then, and nothing refused (that asks for a copy). It waits.
    /// A confirmed sender's key needs no email, and stands.
    nonisolated static func firstKeyDecision(
        senderUserId: String?, selfUserId: String, signed: Bool,
        membership: MembershipConfirmation.Result?
    ) -> FirstKeyDecision {
        let decided = firstKeyDecisionWithTheEmailKnown(
            senderUserId: senderUserId, selfUserId: selfUserId, signed: signed, membership: membership)
        if decided != .fromConfirmedSender, membership?.ownInvitationUnchecked == true { return .wait }
        return decided
    }

    private nonisolated static func firstKeyDecisionWithTheEmailKnown(
        senderUserId: String?, selfUserId: String, signed: Bool,
        membership: MembershipConfirmation.Result?
    ) -> FirstKeyDecision {
        let me = selfUserId.lowercased()
        let sender = senderUserId?.lowercased() ?? me
        let verdicts = Dictionary(
            (membership?.verdicts ?? [:]).map { ($0.key.lowercased(), $0.value) },
            uniquingKeysWith: { first, _ in first })
        let anchored: Bool? = membership.map { _ in
            verdicts.contains { id, verdict in
                guard id != me, case .confirmed(let origin) = verdict else { return false }
                return !origin.isReceiveOnly
            }
        }
        if sender == me {
            if signed { return .fromConfirmedSender }
            return anchored == false ? .onTrustAndAnchor : .refuse
        }
        guard let anchored else { return .refuse }
        if case .confirmed(let origin)? = verdicts[sender], !origin.isReceiveOnly, signed { return .fromConfirmedSender }
        if !anchored, verdicts[sender] != nil { return .onTrustAndAnchor }
        return .refuse
    }

    /// The first key this device takes from a copy signed by THIS account.
    /// `storeFirstCircleKey` checks the signature under the account's CURRENT
    /// key, with the sealed-name check, so a copy signed before an email reset
    /// fails there. Then, and only then — our own signed copy refused with
    /// SignatureInvalid — the same copy goes to `storeCircleKey`, with sender
    /// and recipient us and no signer hint. There a signed own copy has no
    /// first-contact arm: it is stored, as a NEW key, only when a restored
    /// identity's key opens it and that identity's signing key verified it; it
    /// is refused when the current identity opens it; and it fails with
    /// DecryptionFailed while no restored identity opens it, which the pass
    /// shows as the reset state (the previous-identity loader then looks for
    /// the restore). Any other refusal of the first store stands.
    nonisolated static func storeOwnFirstKey(
        crypto: PingolinTrackSDK.CryptoManager, circleId: String, encryptedKey: String, senderPublicKey: String,
        keyVersion: Int32, me: String, wrapSignatureHex: String, currentSigningKeyHex: String,
        sealedCircleName: EncryptedData?
    ) throws {
        do {
            try crypto.storeFirstCircleKey(
                circleId: circleId, encryptedKey: encryptedKey, senderPublicKey: senderPublicKey,
                keyVersion: keyVersion, senderUserId: me, recipientUserId: me, wrapSignatureHex: wrapSignatureHex,
                confirmedSenderSigningPubkeyHex: currentSigningKeyHex, sealedCircleName: sealedCircleName)
        } catch MobileError.SignatureInvalid(_) {
            try crypto.storeCircleKey(
                circleId: circleId, encryptedKey: encryptedKey, senderPublicKey: senderPublicKey,
                keyVersion: keyVersion, senderUserId: me, recipientUserId: me,
                wrapSignatureHex: wrapSignatureHex, senderSigningPubkeyHex: nil)
        }
    }

    /// When this device last asked for a fresh copy of each circle.
    private var freshCopyRequestedAt: [String: Date] = [:]

    /// A circle this device refused a copy of, or cannot open, asks the other
    /// members for a fresh one while it says "Waiting to sync". The roster
    /// does not show such a member as owed (their copy is at the current
    /// version), so without the ask nobody would deliver. At most every ten
    /// minutes per circle; a circle that is merely behind or has no copy yet
    /// is owed already and needs no ask.
    private func requestFreshCopies() async {
        for circle in circles where Self.asksForAFreshCopy(circle.lockReason) {
            if let last = freshCopyRequestedAt[circle.id], Date().timeIntervalSince(last) < 600 { continue }
            freshCopyRequestedAt[circle.id] = Date()
            do {
                try await api.requestAccess(circleId: circle.id)
                Self.keyLog.info("asked the members of circle \(circle.id, privacy: .public) for a fresh copy")
            } catch {
                Self.keyLog.error("fresh-copy request for circle \(circle.id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// When this device last reported each (circle, member) as too old.
    private var updateRequestedAt: [String: Date] = [:]

    /// A member whose app is too old to have a signing key cannot be
    /// confirmed by anybody, so nobody is asked "Is this really {name}?".
    /// The server is told instead, and it tells THEM (push and email, once a
    /// day); the roster's `update_requested` then shows "{name} has been asked
    /// to update Pingolin" on every member's app. At most once a day per member
    /// and circle from this device; the server checks the claim itself.
    func askMemberToUpdate(circleId: String, userId: String) async {
        // Already told (the roster says so): nothing to send.
        if rosters[circleId]?.first(where: { $0.userId.caseInsensitiveCompare(userId) == .orderedSame })?
            .updateRequested == true { return }
        let key = "\(circleId):\(userId.lowercased())"
        if let last = updateRequestedAt[key], Date().timeIntervalSince(last) < 24 * 60 * 60 { return }
        updateRequestedAt[key] = Date()
        do {
            let answer = try await api.requestMemberUpdate(circleId: circleId, userId: userId)
            Self.keyLog.info("member \(userId, privacy: .private) of circle \(circleId, privacy: .public) asked to update (sent=\(answer.sent, privacy: .public))")
            // Shown at once; the next roster says the same.
            if answer.requested {
                func marked(_ list: [CircleMember]?) -> [CircleMember]? {
                    list?.map { member in
                        var member = member
                        if member.userId.caseInsensitiveCompare(userId) == .orderedSame { member.updateRequested = true }
                        return member
                    }
                }
                rosters[circleId] = marked(rosters[circleId])
                members[circleId] = marked(members[circleId])
            }
        } catch let error as APIError where error.isServerCode("member_up_to_date") {
            // Their app has a signing key after all: the ordinary question applies.
        } catch {
            Self.keyLog.error("update request for circle \(circleId, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
    }

    nonisolated static func asksForAFreshCopy(_ reason: CircleLockReason?) -> Bool {
        switch reason {
        case .keyNotVerified, .keyUnreadable, .sealedBeforeReset, .keyOutOfDate: return true
        default: return false
        }
    }

    /// The account restored an identity from before a password reset in the
    /// portal (the `identities_check` nudge). Look now, within the loader's
    /// limits; the circles load again only if another one opens.
    func recheckPreviousIdentities() async {
        guard AuthManager.shared.isAuthenticated else { return }
        await previousIdentityLoader.recheck()
    }

    /// The foreground half of `recheckPreviousIdentities`: a silent push is
    /// best effort, so a return to the app looks while a circle is still
    /// locked since a reset, and runs a re-check a nudge left waiting.
    func previousIdentitiesOnForeground() async {
        guard AuthManager.shared.isAuthenticated else { return }
        await previousIdentityLoader.foreground(
            locked: circles.contains { $0.lockReason == .sealedBeforeReset })
    }

    /// Upgrade `.keyUnreadable` to `.sealedBeforeReset` when the account has
    /// data from before a password reset waiting to be restored in the portal —
    /// the case where the app must point at Account → Settings instead of at
    /// the circle's owner.
    ///
    /// Asks the server once per session, and only when some circle actually
    /// failed to open its key: for nearly every account nothing is locked and
    /// the call is never made. A failed ask is retried at most every ten
    /// minutes (the route is rate limited, and the 20 s poll comes through here).
    private func refinePreResetLocks() async {
        guard circles.contains(where: { $0.lockReason == .keyUnreadable }) else { return }
        if accountHasPreResetData == nil {
            if let last = preResetProbeAttemptAt, Date().timeIntervalSince(last) < 600 { return }
            preResetProbeAttemptAt = Date()
            do {
                accountHasPreResetData = try await api.hasPreResetDataToRestore()
            } catch {
                Self.keyLog.error(
                    "pre-reset data probe failed: \(String(describing: error), privacy: .public)"
                )
                return
            }
        }
        guard accountHasPreResetData == true else { return }
        for index in circles.indices where circles[index].lockReason == .keyUnreadable {
            circles[index].lockReason = .sealedBeforeReset
        }
    }

    #if DEBUG
    /// Write a single line to Documents/<tag>-<nsts>.txt so callers can pull
    /// the trace via `xcrun devicectl device copy from
    /// --domain-type appDataContainer --domain-identifier com.pingolin.track`.
    /// Uses nanosecond precision so back-to-back writes don't overwrite.
    fileprivate nonisolated static func diag(_ tag: String, _ message: String) {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let stamp = UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
        let url = docs.appendingPathComponent("\(tag)-\(stamp).txt")
        try? message.write(to: url, atomically: true, encoding: .utf8)
    }
    #endif

    // MARK: - Circle Operations

    /// - Parameter light: the 20s foreground poll (MainTabView) passes `true` to
    ///   run the CHEAP refresh — circle list + members (GETs only) — so a peer
    ///   join/leave shows without a relaunch, WITHOUT re-running the
    ///   once-per-session, login-weight steps every tick (pseudonym-backfill
    ///   POSTs, historical `getCircleKeys` import, keychain re-mirror, redundant
    ///   key re-unwrap). A brand-new/just-joined circle still gets its key
    ///   installed once even in light mode. `false` (the default) is the full
    ///   login-grade load used by every one-shot/refresh caller.
    /// Assign only on change: every assignment to a published property is a
    /// publish to all of this manager's observers, even when the value is equal.
    private func setDiagnostic(_ message: String) {
        if lastDiagnostic != message { lastDiagnostic = message }
    }

    /// The recovered identities: through the load started with the list when
    /// there is one, so they are never asked for twice at once; else asked
    /// for now.
    private func identitiesLoaded(_ started: Task<Int, Never>?) async {
        if let started {
            _ = await started.value
        } else {
            await previousIdentityLoader.ensureLoaded()
        }
    }

    func loadCircles(light: Bool = false) async throws {
        takeTransitionSeedIfNeeded()
        isLoading = true
        defer { isLoading = false }

        let responses: [CircleResponse]
        // Whether `responses` is the server's list now, not the saved copy, and
        // whether it came on one page (only then may it say a circle is gone).
        var listedNow = false
        var listedWhole = false
        // Recovered identities from before a password reset, asked for alongside
        // the list on a full load, so it costs nothing: the early roster pass
        // below confirms members against them (`holdsPreviousIdentity`,
        // MembershipConfirmation), and the SDK keeps none across launches. Once
        // per session; nothing at all once loaded.
        let identitiesLoad: Task<Int, Never>? = light ? nil : Task { await self.previousIdentityLoader.ensureLoaded() }
        do {
            let list = try await api.getCircleList()
            responses = list.circles
            listedNow = true
            listedWhole = list.whole
            setDiagnostic("getCircles OK: \(responses.count) circle(s) from server")
            // Refresh the on-disk cache so the next cold launch has
            // something to render even when offline — but only when
            // the list actually changed, so the 20 s foreground loop
            // doesn't rewrite an identical file every tick.
            let encoded = try? JSONEncoder().encode(responses)
            if encoded == nil || encoded != lastCachedCirclesData {
                await CacheStore.shared.save(responses, forKey: "circles.list")
                lastCachedCirclesData = encoded
            }
        } catch {
            setDiagnostic("getCircles threw: \(error.localizedDescription)")
            // Fall back to the previous successful list when the
            // network is unhappy (offline, breaker open, 5xx, …).
            // Throwing past would leave the UI empty when it has
            // perfectly good cached data.
            if let cached: [CircleResponse] = await CacheStore.shared.load(
                [CircleResponse].self,
                forKey: "circles.list"
            ) {
                print("[Track] loadCircles: serving \(cached.count) circle(s) from cache after \(error)")
                ErrorBanner.shared.post(error)
                responses = cached
            } else {
                throw error
            }
        }
        // The per-circle SDK ECDH key-unwrap (storeCircleKey) and
        // circle-name decrypt below run synchronously on the main
        // actor: the loop also reads main-actor state
        // (AuthManager.shared, published state), so moving the FFI
        // work to a background executor means re-isolating those
        // reads first.

        // Light poll path: in light mode install/mirror a circle's key
        // ONLY when it's brand-new (no key yet) OR the server's wrap is a NEWER
        // version than the one we hold (a rotation happened — we MUST pick it up
        // or the per-tick location refresh below can't decrypt the peers'
        // post-rotation rows and they'd vanish from the map). Everything else is
        // a redundant re-store of the current key — skipped to keep the 20s tick
        // cheap. Computed BEFORE the pass mutates any SDK key state so the map
        // and the keychain-mirror loop agree; both checks are in-memory (no I/O).
        // Empty in full mode (every circle is unconditionally (re)stored/mirrored).
        // Compared against the version of OUR wrap (`member_key_version`), not
        // the circle's: a member a rotation left pending holds an older wrap,
        // and comparing with the circle's version would re-install it every tick.
        let circleIdsToInstall: Set<String> = light
            ? Set(responses.compactMap { response -> String? in
                // The newest version HELD, not the one sealed under:
                // on a circle with refresh records a version waiting
                // for its record is held but not yet sealed under,
                // and would otherwise be installed again on every
                // tick.
                let held: Int? = cryptoManager.newestHeldVersion(circleId: response.id).map { Int($0) }
                return Self.lightPollInstalls(heldVersion: held, response) ? response.id : nil
            })
            : []

        // A circle this device holds no key for takes its FIRST key only from a
        // member it has confirmed — so learn who that is before anything is
        // stored. Asking the roster first is also what pins the anchor, which
        // the SDK then holds the wrap's signature to.
        for response in responses where response.encryptedCircleKey != nil
            && (!light || circleIdsToInstall.contains(response.id))
            && !cryptoManager.hasCircleKey(circleId: response.id) {
            _ = try? await loadMembers(for: response.id)
        }
        // First keys refused this pass (their sender is not confirmed here), and
        // senders a device with no anchor took its first key from.
        var firstKeyRefused = Set<String>()
        var firstKeyAnchors: [String: String] = [:]
        // First keys waiting for a pass that knows this account's email.
        var firstKeyWaiting = Set<String>()

        // Circles whose wrap failed signature verification this pass.
        // We must not persist their wrapped key anywhere (not even the
        // legacy keychain mirror below), so track them here.
        var rejectedCircleIds = Set<String>()
        // Circles whose wrap was present, NOT refused for its signature, and
        // still could not be opened — sealed to a key this device does not
        // hold. Feeds the locked-circle explanation.
        var unopenedWrapCircleIds = Set<String>()
        // Whether this device holds the account's keys at all. Without them no
        // wrap can open, and the explanation is "sign in again", not anything
        // about the circle.
        let deviceHasAccountKeys = (try? cryptoManager.exportPublicKey()) != nil
        // PERF: each `storeCircleKey` below implicitly calls the
        // SDK's `persist_keys` — a full-blob encrypted write across ~4 keychain
        // items — even on a no-op re-store. Defer those to ONE flush at the end
        // of this synchronous import pass. The window is balanced by
        // `endBulkKeyImport` right after the map and holds no `await`, so the
        // concurrent loadMembers windows in the fan-out can't interleave with it.
        cryptoManager.beginBulkKeyImport()
        let fetchedCircles = responses.map { response -> Circle in
            // 1. Install the wrapped circle key into the SDK so future
            //    encrypt/decrypt calls find it. The SDK accepts hex(nonce ||
            //    ciphertext) as a single string; matches the Android app.
            //    In light mode, skip this re-store for a circle whose
            //    current key we already hold (pure MainActor ECDH churn every
            //    20s); a brand-new/just-joined circle OR a freshly-rotated one
            //    (newer version) still installs (see circleIdsToInstall). Full
            //    mode always (re)stores. The name decrypt below still runs either
            //    way — for a skipped circle the key is already in the SDK.
            let shouldInstallKey = !light || circleIdsToInstall.contains(response.id)
            // A listed circle's wrap is NEVER stored into the personal
            // key's slot: personal locations are sealed under that
            // slot. The list refuses such a row first.
            if shouldInstallKey, CanonicalId.circle(response.id) != nil,
               let encryptedKey = response.encryptedCircleKey,
               let nonce = response.circleKeyNonce,
               let ephemeral = response.ephemeralPublicKey,
               let currentUserId = AuthManager.shared.userId {
                // Verify on store: resolve the wrap signer's
                // Ed25519 key from OUR pinned member directory
                // (keyed by senderUserId), never from a
                // server-supplied field — a malicious relay
                // could otherwise sign its forged wrap with a
                // matching key. nil when the signer isn't
                // pinned yet → SDK grace-accepts (no lockout).
                // Mirrors the Android app's decryptCircleName.
                let senderSigningPubkey = response.senderUserId.flatMap {
                    cachedMemberSigningPubkey(circleId: response.id, userId: $0)
                }
                let firstKey: FirstKeyDecision? = cryptoManager.hasCircleKey(circleId: response.id)
                    ? nil
                    : Self.firstKeyDecision(
                        senderUserId: response.senderUserId, selfUserId: currentUserId,
                        signed: !(response.wrapSignature ?? "").isEmpty, membership: membership[response.id])
                // The confirmed sender's PINNED signing key — or ours for our own
                // wrap — never one the server sent.
                let senderIsMe = response.senderUserId.map { $0.lowercased() == currentUserId.lowercased() } ?? true
                var confirmedSenderKey: String?
                if firstKey == .fromConfirmedSender {
                    confirmedSenderKey = senderIsMe
                        ? try? cryptoManager.signingPublicKeyHex()
                        : response.senderUserId.flatMap { cryptoManager.pinnedSigningKey(circleId: response.id, userId: $0) }
                }
                if firstKey == .wait {
                    // Nothing stored, no older version by another door, no mirror
                    // and no signing; and nothing asked for, so not
                    // `rejectedCircleIds` (`.keyNotVerified` asks for a copy).
                    firstKeyRefused.insert(response.id)
                    firstKeyWaiting.insert(response.id)
                    Self.keyLog.info("first key for circle \(response.id, privacy: .public) waits: this account's email isn't known here yet")
                } else if firstKey == .refuse || (firstKey == .fromConfirmedSender && confirmedSenderKey == nil) {
                    // Nothing stored; the circle says it is waiting to sync and
                    // asks the members for a copy from someone it can confirm.
                    firstKeyRefused.insert(response.id)
                    rejectedCircleIds.insert(response.id)
                    Self.keyLog.error("first key for circle \(response.id, privacy: .public) refused: its sender is not confirmed on this device")
                } else {
                    do {
                        if firstKey == .fromConfirmedSender, let confirmedSenderKey {
                            // Checked against the circle's name only when the name
                            // is sealed under the version delivered.
                            let nameIsAtThisVersion = response.nameKeyVersion == Self.ownWrapVersion(response)
                            let sealedName = nameIsAtThisVersion
                                ? EncryptedData(nonce: response.encryptedName.nonce,
                                                ciphertext: response.encryptedName.ciphertext)
                                : nil
                            if senderIsMe {
                                try Self.storeOwnFirstKey(
                                    crypto: cryptoManager, circleId: response.id,
                                    encryptedKey: nonce + encryptedKey, senderPublicKey: ephemeral,
                                    keyVersion: Int32(Self.ownWrapVersion(response)), me: currentUserId,
                                    wrapSignatureHex: response.wrapSignature ?? "",
                                    currentSigningKeyHex: confirmedSenderKey, sealedCircleName: sealedName)
                            } else {
                                try cryptoManager.storeFirstCircleKey(
                                    circleId: response.id,
                                    encryptedKey: nonce + encryptedKey,
                                    senderPublicKey: ephemeral,
                                    keyVersion: Int32(Self.ownWrapVersion(response)),
                                    senderUserId: response.senderUserId ?? currentUserId,
                                    recipientUserId: currentUserId,
                                    wrapSignatureHex: response.wrapSignature ?? "",
                                    confirmedSenderSigningPubkeyHex: confirmedSenderKey,
                                    sealedCircleName: sealedName
                                )
                            }
                        } else {
                            try cryptoManager.storeCircleKey(
                                circleId: response.id,
                                encryptedKey: nonce + encryptedKey,
                                senderPublicKey: ephemeral,
                                // The version OUR wrap was made for, which its signature
                                // binds. `key_version` is where the circle has moved to;
                                // for a member a rotation left pending they differ, and
                                // verifying under the wrong one refuses a good wrap.
                                keyVersion: Int32(Self.ownWrapVersion(response)),
                                // A wrap with no signer on record is
                                // our own slot (a creation wrap from
                                // before signing): label it as ours
                                // so the SDK verifies it under OUR
                                // key when it is signed, and
                                // otherwise accepts it only as an
                                // identical re-import or on first
                                // contact. An empty sender would make
                                // it an unpinned stranger's wrap,
                                // refused in any circle with pins.
                                senderUserId: response.senderUserId ?? currentUserId,
                                recipientUserId: currentUserId,
                                wrapSignatureHex: response.wrapSignature,
                                senderSigningPubkeyHex: senderSigningPubkey
                            )
                            if firstKey == .onTrustAndAnchor, let sender = response.senderUserId {
                                firstKeyAnchors[response.id] = sender
                            }
                        }
                    } catch MobileError.SignatureInvalid(let message) {
                        // Present-but-invalid signature: the wrap was signed by a
                        // key that doesn't match the signer we pinned (tamper or
                        // wrong signer). The SDK already refused to store it; also
                        // skip the keychain mirror so the bad wrap isn't kept.
                        rejectedCircleIds.insert(response.id)
                        Self.keyLog.error(
                            "storeCircleKey REJECTED wrap circle=\(response.id, privacy: .public) reason=\(message, privacy: .public)"
                        )
                    } catch {
                        unopenedWrapCircleIds.insert(response.id)
                        Self.keyLog.error(
                            "storeCircleKey FAILED circle=\(response.id, privacy: .public) error=\(String(describing: error), privacy: .public)"
                        )
                    }
                }
            }

            // 2. With the key loaded, decrypt the server-blind name. Surface
            //    a sentinel string when decryption fails (e.g. key missing
            //    for invitee-style flows that haven't completed accept yet).
            // With the version that opened it: a rotation re-seals the name
            // only from the key in use. The list still shows a name any held
            // key opens.
            let openedName: OpenedText? = {
                let blob = EncryptedData(
                    nonce: response.encryptedName.nonce,
                    ciphertext: response.encryptedName.ciphertext
                )
                do {
                    return try cryptoManager.decryptDataV2Opened(circleId: response.id, encryptedData: blob, fieldTag: "name")
                } catch {
                    // The failure the USER sees as a locked circle. Logged
                    // rather than discarded, through the unified log
                    // (`print` does not reach it in a release build), so a
                    // report of exactly that can be diagnosed from a device.
                    //
                    // The three facts logged are chosen to SEPARATE the
                    // candidates rather than just record a failure:
                    //   heldKey=false        → the wrap never installed (store
                    //                          rejected it, or it was absent).
                    //   localV != serverV    → version skew: we hold a different
                    //                          generation than the one the name
                    //                          was sealed under.
                    //   held, versions equal → the NAME is under some other key
                    //                          than the one this member holds —
                    //                          i.e. a rotation moved the key
                    //                          without re-encrypting the name.
                    //
                    // Ids and version numbers only. The circle id is plaintext
                    // metadata the server already holds; the name and any key
                    // material are never logged.
                    let heldKey = cryptoManager.hasCircleKey(circleId: response.id)
                    let localVersion = cryptoManager.newestHeldVersion(circleId: response.id) ?? 0
                    Self.keyLog.error(
                        """
                        circle name decrypt FAILED circle=\(response.id, privacy: .public)                         heldKey=\(heldKey, privacy: .public)                         localVersion=\(localVersion, privacy: .public)                         serverVersion=\(response.keyVersion, privacy: .public)                         rejectedWrapThisPass=\(rejectedCircleIds.contains(response.id), privacy: .public)                         error=\(String(describing: error), privacy: .public)
                        """
                    )
                    return nil
                }
            }()
            let decryptedName = openedName?.text

            // Say WHY, from what this pass observed. The pre-reset case
            // needs a server answer and is refined after this synchronous
            // pass.
            let shownLocked = Self.isShownLocked(nameOpened: decryptedName != nil, response)
            let lockReason: CircleLockReason? = !shownLocked ? nil : Self.lockReason(
                deviceHasAccountKeys: deviceHasAccountKeys,
                hasWrapForUs: response.encryptedCircleKey != nil,
                wrapRefused: rejectedCircleIds.contains(response.id),
                wrapFailedToOpen: unopenedWrapCircleIds.contains(response.id),
                holdsSomeKey: cryptoManager.hasCircleKey(circleId: response.id),
                leftPending: Self.ownWrapVersion(response) < response.keyVersion,
                accountHasPreResetData: accountHasPreResetData,
                previousReason: circles.first(where: { $0.id == response.id })?.lockReason
            )
            return response.toModel(name: decryptedName, lockReason: lockReason,
                                    nameOpenedUnder: openedName?.keyVersion)
        }
        // Flush the single deferred keychain write for the pass above.
        try? cryptoManager.endBulkKeyImport()
        // A device nothing anchored took its first key on trust, once, and now
        // anchors on whoever sent it: the next roster load pins them.
        if let me = AuthManager.shared.userId {
            for (circleId, sender) in firstKeyAnchors where cryptoManager.hasCircleKey(circleId: circleId) {
                KeyDeliveryApprovals.shared.approve(owner: me, circleId: circleId, userId: sender, origin: .anchor)
                Self.keyLog.info("circle \(circleId, privacy: .public): first key taken on trust; anchored on its sender")
            }
        }
        circles = fetchedCircles
        pendingRemovalNames = pendingRemovalNames.filter { id, _ in
            fetchedCircles.contains { $0.id == id && $0.removedMemberStillHasKey }
        }
        // The map's first members and positions wait for the active circle
        // (MapView's `.task(id: activeCircle?.id)` reads its positions), and
        // on a cold start none is active yet. Picked from this list now, with
        // its current key installed above, and its members read at once, so
        // the first markers come with their names: not after the historical
        // key import, the own-wrap signing and the pseudonym backfill below,
        // which only older data needs. The fan-out below reads every circle's
        // members again, and the end of this load takes the loaded copy.
        var pickedEarly = false
        if activeCircle == nil, let first = Self.activeAfterLoad(nil, loaded: circles) {
            setActiveCircle(first)
            pickedEarly = true
            // Never before the recovered identities are in: the pass
            // stores approvals and pins, retires the pins of everyone it
            // can't confirm, and can ask an owner or admin about them.
            await identitiesLoaded(identitiesLoad)
            _ = try? await loadMembers(for: first.id)
        }
        await refinePreResetLocks()
        await requestFreshCopies()
        // An invitation of an owner's or admin's circle waits to be
        // renewed. This device reads the directory itself and asks "Is
        // this really {email}?" only where it should
        // (`InvitationRenewals`).
        let renewing = responses.filter { $0.invitesNeedRenewal == true }.map(\.id)
        if !renewing.isEmpty {
            await InvitationRenewals.shared.look(circleIds: renewing)
        }

        // Mirror the wrapped key into the app keychain too, for legacy
        // callers that read it there (e.g. CircleManager.syncLocation's
        // pre-SDK fallback path).
        for response in responses {
            // Never mirror a wrap we just rejected for a bad signature, nor one
            // whose first key waits.
            if rejectedCircleIds.contains(response.id) || firstKeyWaiting.contains(response.id) { continue }
            // In light mode, only mirror a circle we're installing this
            // pass (brand-new or freshly-rotated — same gate as the store above),
            // skipping the N keychain writes for unchanged circles every 20s. A
            // newly-joined circle seen first by the poll still gets both the SDK
            // store and this mirror once.
            if light && !circleIdsToInstall.contains(response.id) { continue }
            if let encryptedKey = response.encryptedCircleKey {
                try keychain.saveCircleKey(encryptedKey, for: response.id)
            }
        }

        // Load every historical wrapped circle key into the SDK so
        // payloads encrypted before a rotation (e.g. places created
        // when the circle was at v1) still decrypt today. The current
        // version is already stored above from the /api/v1/circles
        // response; this pass just adds the older versions. Failures
        // here are non-fatal — the user might still see a few rotated-
        // out items render as encrypted sentinels.
        //
        // Full mode — OR a light tick that ACTUALLY installed a brand-new/
        // just-joined/freshly-rotated circle this pass (circleIdsToInstall
        // non-empty). Historical/intermediate key versions matter right after a
        // rotation or join, so a light tick that picked one up MUST import them
        // too — otherwise that circle's pre-rotation ciphertext
        // (peer locations, places) decrypts to nil until the next FULL
        // loadCircles, and those places drop from the geofencing union + go
        // unmonitored in the meantime. A steady-state light tick (nothing new
        // installed) still skips this extra HTTP round-trip + N stores, so the 20s
        // poll stays cheap ~180×/hr.
        let needHistoricalKeys = !light || !circleIdsToInstall.isEmpty
        if needHistoricalKeys {
            do {
                // Make any RECOVERED pre-reset identity available BEFORE
                // unwrapping. After an email password reset every existing wrap
                // was made for the old public key, so without this the bundles
                // below all fail and the circles go silent with their data intact.
                await identitiesLoaded(identitiesLoad)

                let allKeys = try await api.getCircleKeys()
                // Each circle's key chain goes to its records import
                // too: the SDK walks it for the circle's secret. Not a
                // circle whose first key was refused here.
                var chains: [String: [KeyChainLinkData]] = [:]
                for keyResp in allKeys where !firstKeyRefused.contains(keyResp.circleId) {
                    chains[CanonicalId.key(keyResp.circleId), default: []] += (keyResp.keyChain ?? []).map { link in
                        KeyChainLinkData(fromVersion: Int32(link.fromVersion), toVersion: Int32(link.toVersion),
                                         encryptedKey: link.encryptedKey, nonce: link.nonce)
                    }
                }
                keyChainsLastImport = chains
                // Same keychain-write deferral as the current-version pass
                // above: one keychain flush for the whole historical-key import
                // rather than one full-blob write per version. Synchronous window
                // (no await).
                cryptoManager.beginBulkKeyImport()
                // A circle whose first key was refused above takes no older
                // version either: that is the same first key by another door.
                for keyResp in allKeys where !firstKeyRefused.contains(keyResp.circleId) {
                    do {
                        guard let currentUserId = AuthManager.shared.userId else { continue }
                        // Resolve the signer's key from our
                        // pinned directory (nil when unpinned
                        // → SDK grace-accepts, no lockout);
                        // never trust a server-supplied
                        // signer key. Mirrors the Android
                        // app's importCircleKeys.
                        let senderSigningPubkey = keyResp.senderUserId.flatMap {
                            cachedMemberSigningPubkey(circleId: keyResp.circleId, userId: $0)
                        }
                        // The server's CircleKeyBundle carries
                        // the wrap as a {nonce, ciphertext}
                        // OBJECT under `encrypted_circle_key`,
                        // the ephemeral X25519 key under
                        // `ephemeral_public_key`, and the
                        // version under `key_version`.
                        // storeCircleKey wants
                        // hex(nonce || ciphertext), matching
                        // the current-version path above.
                        try cryptoManager.storeCircleKey(
                            circleId: keyResp.circleId,
                            encryptedKey: keyResp.encryptedCircleKey.nonce + keyResp.encryptedCircleKey.ciphertext,
                            senderPublicKey: keyResp.ephemeralPublicKey,
                            keyVersion: Int32(keyResp.keyVersion),
                            // Same rule as the current-version
                            // pass: no signer on record means
                            // our own slot (the personal key's
                            // bundle names us; older servers
                            // name nobody).
                            senderUserId: keyResp.senderUserId ?? currentUserId,
                            recipientUserId: currentUserId,
                            wrapSignatureHex: keyResp.wrapSignature,
                            senderSigningPubkeyHex: senderSigningPubkey
                        )
                    } catch MobileError.SignatureInvalid(let message) {
                        // Present-but-invalid signature on a
                        // historical wrap: the wrap is not
                        // stored. The chain import below
                        // still runs, on purpose. A chain
                        // link is the older key sealed (AEAD)
                        // under the newer one, so it can only
                        // be opened with a version this
                        // device already holds and a forged
                        // link yields nothing, not a wrong
                        // key — its trust comes from the key,
                        // not from this signature. Skipping
                        // the chain here would leave every
                        // pre-rotation version missing on a
                        // device whose current wrap was
                        // rejected here while the
                        // /api/v1/circles pass had accepted
                        // it.
                        print("[Track] storeCircleKey v\(keyResp.keyVersion) REJECTED for \(keyResp.circleId): \(message)")
                    } catch {
                        #if DEBUG
                        print("[Track] storeCircleKey v\(keyResp.keyVersion) failed for \(keyResp.circleId): \(error)")
                        #endif
                    }
                    // Walk the key chain DOWN from the version
                    // just stored so every older version the
                    // server no longer wraps for us becomes
                    // available: v(n) unlocks v(n-1), which
                    // unlocks v(n-2). Newest link first,
                    // because each link's "from" key must
                    // already be in the store. Without this
                    // pass a member who was in the circle
                    // across a rotation would hold only the
                    // current version, and everything sealed
                    // before it — the owner's display name,
                    // pre-rotation places — would read as
                    // undecryptable.
                    for link in Self.chainImportOrder(keyResp.keyChain ?? []) {
                        do {
                            try cryptoManager.importKeyChainLink(
                                circleId: keyResp.circleId,
                                fromVersion: Int32(link.fromVersion),
                                toVersion: Int32(link.toVersion),
                                encryptedKeyHex: link.encryptedKey,
                                nonceHex: link.nonce
                            )
                            #if DEBUG
                            Self.diag("key-chain", "\(keyResp.circleId) v\(link.fromVersion)→v\(link.toVersion) imported")
                            #endif
                        } catch {
                            #if DEBUG
                            print("[Track] importKeyChainLink v\(link.fromVersion)→v\(link.toVersion) failed for \(keyResp.circleId): \(error)")
                            Self.diag("key-chain", "\(keyResp.circleId) v\(link.fromVersion)→v\(link.toVersion) FAILED: \(error)")
                            #endif
                        }
                    }
                }
                try? cryptoManager.endBulkKeyImport()
                #if DEBUG
                Self.diag("circle-keys", "loaded \(allKeys.count) historical key(s)")
                #endif
            } catch {
                #if DEBUG
                print("[Track] getCircleKeys failed: \(error)")
                #endif
            }
        }

        // Sign our own wraps the server holds unsigned. Full mode only —
        // once per session per circle is plenty.
        if !light {
            await signOwnUnsignedWraps(responses, skipping: rejectedCircleIds.union(unopenedWrapCircleIds).union(firstKeyWaiting))
        }

        // Backfill the server's member-pseudonym mapping so history
        // queries can still resolve rows tagged with pseudonyms from
        // older circle-key versions. Idempotent; runs on
        // login/foreground and catches the post-rotation case. Mirrors
        // the Android refresh path.
        //
        // Full mode only. This is N server WRITES (one POST per circle)
        // — the costliest step the 20s poll could take;
        // login/foreground frequency is plenty for an idempotent
        // backfill.
        if !light, let userId = AuthManager.shared.userId {
            // One POST per circle, all at once rather than one after
            // another: they are independent, and idempotent.
            var backfills: [(circleId: String, pseudonyms: [String])] = []
            for response in responses {
                do {
                    let pseudonyms = try cryptoManager.deriveUserPseudonymsAllVersions(
                        circleId: response.id,
                        userId: userId
                    )
                    if !pseudonyms.isEmpty { backfills.append((response.id, pseudonyms)) }
                } catch {
                    print("[Track] pseudonym backfill failed for circle \(response.id): \(error)")
                }
            }
            let api = self.api
            await withTaskGroup(of: Void.self) { group in
                for backfill in backfills {
                    group.addTask {
                        do {
                            _ = try await api.backfillPseudonyms(circleId: backfill.circleId, pseudonyms: backfill.pseudonyms)
                        } catch {
                            print("[Track] pseudonym backfill failed for circle \(backfill.circleId): \(error)")
                        }
                    }
                }
            }
        }

        // The active circle is a copy: take the loaded one, or the map's
        // button goes on saying "Locked circle" after the load that
        // opened it. None picked: the first.
        if let active = Self.activeAfterLoad(activeCircle, loaded: circles), active != activeCircle {
            setActiveCircle(active)
        }

        // Load members + privacy settings for every circle in parallel
        // — neither depends on the other within a circle, and the
        // per-circle pairs can run concurrently across circles. Mirrors
        // the Android app's fan-out: only `circles → members` is on the
        // critical path for map paint, so fan as wide as we can here.
        // Failures are caught per-circle so a single bad circle doesn't
        // stall the rest.
        //
        // Privacy the server embedded in GET /circles (`my_privacy`) is
        // applied here and costs no request of its own; only circles
        // without it — an older backend, or no privacy row yet — are
        // fetched one by one. Assigned only on change: each assignment
        // publishes.
        let privacyPlan = Self.privacyRefreshPlan(circleIds: circles.map(\.id), responses: responses)
        for (id, settings) in privacyPlan.embedded where privacySettings[id] != settings {
            privacySettings[id] = settings
        }
        // Every row a list the server gave NOW is what it holds now, changed or
        // not: when this account was not sharing. A saved copy says nothing of
        // now.
        if listedNow {
            let now = Date()
            for settings in privacyPlan.embedded.values {
                CirclePauseRecord.shared.observe(settings, at: now, owner: AuthManager.shared.userId)
            }
        }
        // A circle that caught up sends what was kept for it while it waited
        // — now, not only behind the next live send: a phone that stands
        // still may not send one for a while. After the rows above reached
        // the record: a kept point waits for a row read since it was taken.
        SDKLocationStreamer.shared.drainKeptLocations()
        let privacyToFetch = Set(privacyPlan.fetch)
        await withTaskGroup(of: Void.self) { group in
            for circle in circles {
                let id = circle.id
                group.addTask { [weak self] in
                    guard let self = self else { return }
                    _ = try? await self.loadMembers(for: id)
                }
                if privacyToFetch.contains(id) {
                    group.addTask { [weak self] in
                        guard let self = self else { return }
                        _ = try? await self.loadPrivacySettings(for: id)
                    }
                }
            }
        }
        // A circle picked early had its positions read before the
        // historical keys were in: read them once more, so a point sealed
        // under a key version from before a rotation opens now, not at the
        // next tick.
        if pickedEarly, let activeId = activeCircle?.id {
            _ = try? await loadMemberLocations(for: activeId)
        }

        // Every key import is followed by the records import, once the
        // rosters above are judged (the SDK checks the records against
        // them). The rotations below wait for it. A light pass with no
        // key import runs it too while a listed circle owes one
        // (`recordsImportDue`).
        if needHistoricalKeys || recordsImportDue(now: Date()) {
            await importRefreshRecords()
            // After a reset, an owner's or admin's own admission,
            // before the rotations below (which wait for it).
            await publishSelfAdmissionsIfDue()
        }
        // Security-refresh sweep. The server sets `key_rotation_needed = true` on
        // the circle row when someone leaves or is removed, and every 14 days. It
        // only ever raises the flag; it holds no circle key and cannot rotate.
        // The Android app calls autoRotateIfNeeded from its refresh paths for the
        // same reason.
        //
        // ANY member's device does it: while the circle is flagged the server
        // lets any active member rotate, so the refresh does not wait for an
        // owner or admin to come online. A newcomer's join (`member_joined`) is
        // not answered here — delivery gives them the current key with no version
        // bump (`deliverToConfirmedMembers`).
        //
        // There is no manual alternative: the app deliberately has no rotate
        // control (see the note in CirclesView), because a rotation is a
        // mechanical consequence of a membership change and not something a user
        // can meaningfully ask for. So if this sweep does not run, a departed
        // member's key stays current after a leave or a revoke.
        //
        // We fire the rotation in a detached Task to keep loadCircles
        // off the rotation network round-trip. Per-circle failures
        // log only; the next loadCircles will retry the flag.
        // The rotation step runs here too, on the owner's or an admin's device
        // whose active key came through a restored identity or was taken on
        // trust. Its seals wait for it (`holdsCurrentKey`).
        //
        // A circle's rotations wait for this process's records import
        // (`rotationMode`), and this device may owe some beyond the flag
        // (`recordedRotationDue`): a transition, a repair, its person's removals
        // and role changes.
        let circlesNeedingRotation = circles.filter {
            (Self.performsSecurityRefresh(flagged: $0.keyRotationNeeded, cause: $0.keyRotationCause)
                || rotationStepPending($0.id) || recordedRotationDue($0))
                && !nameHoldsBack($0, due: repairsDue[CanonicalId.key($0.id)]) && holdsWhatItRotates($0)
                && !inRotationBackoff($0.id) && rotationMode(for: $0) != .wait
                && !changesAwaitingImport.waits($0.id)
                && !CanonicalId.isPersonalSlot($0.id)
                && keyChangesMayBuild($0)
        }
        // Skip circles already mid-rotation so the 20s poll re-entering
        // this sweep can't launch a SECOND concurrent rotation for the same
        // circle (both reading the same current_version and racing the SDK's
        // local key-version bump). Mark each in-flight before launching and clear
        // it when the rotation settles (success or failure). The check-and-insert
        // is atomic on the MainActor.
        let toRotate = circlesNeedingRotation.filter { !rotationsInFlight.contains($0.id) }
        if !toRotate.isEmpty {
            for circle in toRotate { rotationsInFlight.insert(circle.id) }
            Task { [weak self] in
                guard let self = self else { return }
                // Randomised 0-5s, then re-check. When a membership change
                // lands, every eligible client refreshes at once; without
                // this they all build a full rewrap and all but one lose
                // the CAS, paying N-1 wasted ECDH fan-outs. One client
                // usually gets there first and the rest see the flag
                // already cleared. Mirrors the Android app's
                // autoRotateIfNeeded.
                //
                // `rotationsInFlight` above covers the same device; this
                // covers the fleet, and the two are not substitutes.
                try? await Task.sleep(nanoseconds: UInt64.random(in: 0...5_000_000_000))
                for circle in toRotate {
                    // A peer may have rotated during the delay, which clears the
                    // flag server-side; our own next loadCircles reflects that.
                    if await self.rotationNoLongerNeeded(circle.id) {
                        print("[Track] auto-rotation skipped for \(circle.id) — flag cleared during jitter")
                        await self.clearRotationInFlight(circle.id)
                        continue
                    }
                    do {
                        try await self.rotateCircleKey(for: circle.id)
                        print("[Track] auto-rotation OK for circle \(circle.id)")
                        await self.clearRotationFailure(circle.id)
                    } catch {
                        print("[Track] auto-rotation failed for circle \(circle.id): \(error)")
                        await self.recordRotationFailure(circle.id, error)
                    }
                    await self.clearRotationInFlight(circle.id)
                }
            }
        }

        // The hand-overs this device sent and hasn't seen done finish against
        // the list the server just gave. Cheap when none is kept.
        if listedNow { finishHandOvers(listed: responses, whole: listedWhole) }
        // The late points kept for a circle a WHOLE list no longer has go with
        // it. Never on a list with more pages (a reorder between page reads
        // can skip a circle), nor on a roster's 404 (`pruneLocalCircle`).
        if listedNow, listedWhole, let me = AuthManager.shared.userId {
            let listed = Set(responses.map { CanonicalId.key($0.id) })
            for circleId in Self.keptPointsToDiscard(kept: PendingCircleLocations.shared.circlesWithPoints(owner: me),
                                                     listed: listed) {
                PendingCircleLocations.shared.discard(circleId: circleId)
            }
            // And what this phone last sent each of them, kept for a
            // re-seal: it holds a point.
            for circleId in Self.keptPointsToDiscard(kept: OwnLastSentStore.shared.circles(owner: me), listed: listed) {
                OwnLastSentStore.shared.forget(circleId: circleId)
            }
        }
        // A circle the last list had and a WHOLE list the server gives now
        // lacks is this account's no more: it was removed from it, or it was
        // deleted. It is pruned, as on a confirmed refusal — otherwise it
        // would stay the map's circle, with its members' last places, until
        // sign-out (`activeAfterLoad` keeps a circle no longer listed). Never
        // on a list with more pages, nor on the saved copy.
        for circleId in Self.circlesGone(before: circlesOfLastList, listed: Set(responses.map { CanonicalId.key($0.id) }),
                                         whole: listedWhole, now: listedNow) {
            pruneGoneCircle(circleId)
        }
        // This list is the last one only now, after its prune: a load that
        // throws on the way here (the keychain's refusal before the first
        // unlock, above) leaves the last list as it was, so a circle gone
        // from this one is still pruned by the next.
        circlesOfLastList = fetchedCircles.map(\.id)
        // Changes waiting for a circle this iPhone now holds the current
        // version of go out, here at the end of every load (the light one
        // the silent push runs included). Cheap when nothing waits. Which
        // circles are still this account's is only what the server just
        // listed: never the saved copy, and never `circles` after a
        // roster's 404 pruned one from it (a 404 is not "gone").
        if listedNow {
            listedCircleIds = Set(responses.map { $0.id.lowercased() })
            circleListWhole = listedWhole
            circlesLoaded = true
            SDKLocationStreamer.shared.uploadTargetsLoaded(account: AuthManager.shared.userId)
        }
        PendingChangeRunner.shared.trigger()
        // This account's own open SOS in a circle whose key moved here (a
        // rotation this device landed, or a key import) goes along to the new
        // key. Cheap when nothing moved.
        SOSManager.shared.resealAfterKeyChange()
    }

    /// Whether this process has loaded the circle list from the server: the
    /// waiting changes run only after that, never against the saved copy or
    /// an empty list (which would read as "no longer in the circle").
    private(set) var circlesLoaded = false

    /// The circles of the last list the server gave this process. A 404 from
    /// one of a circle's own routes prunes it from `circles` until the next
    /// list; it never changes this.
    private(set) var listedCircleIds: Set<String> = []
    /// Whether that list came on one page: only such a list is whole (see
    /// `APIService.getCircleList`).
    private(set) var circleListWhole = false
    /// The circles the last list had, the server's or the saved copy, as
    /// listed: only these can be gone from a later one. A circle made here
    /// since that list was read is not that list's to judge.
    private var circlesOfLastList: [String] = []
    /// A circle this account is in no more, by the server's word (a WHOLE list
    /// without it, or a roster's refusal one confirms), sent just before it is
    /// pruned: what is open of it closes. An event, never a state, so a circle
    /// joined again opens as any other. Not for this account's own leave or
    /// delete, whose screen closes itself.
    let circleGone = PassthroughSubject<String, Never>()

    /// Whether the server's last list still has this circle for this account:
    /// what a waiting change asks before it is dropped as "not in the circle".
    /// Listed: true. Missing from a list that came on one page: false. Missing
    /// from a list with more pages: nil, since a reorder between two page reads
    /// can skip a circle; the change waits.
    func listsCircle(_ circleId: String) -> Bool? {
        Self.listsCircle(circleId, listed: listedCircleIds, whole: circleListWhole)
    }

    /// Pure, for tests.
    nonisolated static func listsCircle(_ circleId: String, listed: Set<String>, whole: Bool) -> Bool? {
        if listed.contains(circleId.lowercased()) { return true }
        return whole ? false : nil
    }

    /// Whether the circle's last COMPLETE roster lists this person, shown here
    /// or not. Nil without one (not loaded yet, or the server sent only part):
    /// someone missing from a roster that isn't whole may still be in it.
    func rosterLists(_ userId: String, in circleId: String) -> Bool? {
        Self.rosterLists(userId, roster: rosters[circleId], complete: !incompleteRosters.contains(circleId))
    }

    nonisolated static func rosterLists(_ userId: String, roster: [CircleMember]?, complete: Bool) -> Bool? {
        guard let roster, complete else { return nil }
        return roster.contains { $0.userId.caseInsensitiveCompare(userId) == .orderedSame }
    }

    /// `consent`: the location notice the creator agreed to — sent with the
    /// create, so there is no circle without it.
    func createCircle(name: String, consent: ShownNotice?) async throws -> Circle {
        isLoading = true
        defer { isLoading = false }
        guard let creator = AuthManager.shared.userId else { throw CircleError.memberNotFound }

        // 1. The server reserves the circle's id first: the circle's
        //    genesis record binds it. Under that id the SDK makes a fresh
        //    circle key, wraps it for this account, and signs the genesis
        //    as the creator. It persists everything via
        //    KeychainKeyStorageCallback.
        let reserved = try await api.reserveCircleId()
        let recorded = try cryptoManager.prepareRecordedCircleCreation(creatorUserId: creator,
                                                                      circleId: reserved.circleId)
        let creation = recorded.creation

        // 2. Encrypt the chosen circle name with the new circle key, and tell
        //    the server about the new circle, with its genesis. A refusal drops
        //    the circle here again; no answer keeps it, since the server may
        //    have made it, and its next list says (`discardCircleCreation` drops
        //    only such a creation).
        let response: CircleResponse
        do {
            let nameBlob = try cryptoManager.encryptDataV2(circleId: recorded.circleId, plaintext: name,
                                                           fieldTag: "name")
            response = try await api.createCircle(
                encryptedName: EncryptedBlobRequest(
                    nonce: nameBlob.nonce,
                    ciphertext: nameBlob.ciphertext
                ),
                encryptedCircleKey: EncryptedBlobRequest(
                    nonce: creation.encryptedCircleKey.nonce,
                    ciphertext: creation.encryptedCircleKey.ciphertext
                ),
                ephemeralPublicKey: creation.ephemeralPublicKey,
                locationConsent: LocationConsentGrant(consent),
                circleId: recorded.circleId,
                genesis: RefreshRecordWire(record: recorded.genesis.recordHex, signature: recorded.genesis.signatureHex)
            )
        } catch {
            if Self.creationWasRefused(error) { _ = cryptoManager.discardCircleCreation(circleId: recorded.circleId) }
            throw error
        }
        // The genesis binds the reserved id: a circle under any other is not
        // the one whose key and record this device holds.
        guard response.id.caseInsensitiveCompare(recorded.circleId) == .orderedSame else {
            throw CircleError.noCircleKey
        }

        // 5. Sign the creator's wrap now that the circle id exists (the
        //    signature binds it, so it cannot ride on the create POST).
        //    Without it this is the one unsigned "own" wrap a server could
        //    imitate. Best effort — the next full sync's
        //    `signOwnUnsignedWraps` retries.
        if let me = AuthManager.shared.userId {
            do {
                let signature = try cryptoManager.signCircleCreationWrap(
                    creation: creation, circleId: response.id, userId: me
                )
                _ = try await api.signOwnCircleWrap(
                    circleId: response.id,
                    keyVersion: 1,
                    encryptedCircleKey: EncryptedBlobRequest(
                        nonce: creation.encryptedCircleKey.nonce,
                        ciphertext: creation.encryptedCircleKey.ciphertext
                    ),
                    ephemeralPublicKey: creation.ephemeralPublicKey,
                    wrapSignature: signature
                )
                ownWrapSignAttempted.insert(response.id)
            } catch {
                Self.keyLog.error("could not sign the creator wrap of circle \(response.id, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }

        // The circle's approval record starts here, with its creator alone,
        // so it is never seeded from a roster the server wrote.
        if let me = AuthManager.shared.userId {
            KeyDeliveryApprovals.shared.recordCreatedCircle(owner: me, circleId: response.id)
        }

        // We have the cleartext name locally — pass it into the converter so
        // the model doesn't fall back to the locked-circle placeholder.
        let circle = response.toModel(name: name)
        circles.append(circle)
        // This account's name, sealed for the circle it just made.
        Task { await self.sealOwnName(circleId: circle.id) }
        // Nothing selected yet (a first circle, or the last one was left):
        // the new circle is, now. Otherwise only a load would pick one, and
        // until then the map would say "Select Circle" and "Notify my
        // circle" would have no circle to notify.
        if let picked = Self.activeAfterCreate(activeCircle, created: circle) {
            setActiveCircle(picked)
        }
        // Its records import, once, after its first roster pass (the SDK
        // judges the records against it). Until an import decides it, a
        // circle stands `.wait` here: its invitations would carry no key,
        // and nobody who joins would be given one. Only the import's
        // outcome decides; none (no answer, "not now") leaves it to a
        // light pass's (`recordsImportDue`). Best effort: the circle is
        // made either way.
        _ = try? await loadMembers(for: circle.id)
        await importRefreshRecords()
        return circle
    }

    /// While this iPhone is behind in the circle the new name waits, against
    /// the name as it was shown. `waiting`: the waiting change being run now.
    func updateCircle(_ circle: Circle, name: String, waiting: PendingChange? = nil) async throws {
        // A name sealed under a key the circle has moved past is readable by
        // whoever the rotation shut out.
        do {
            try requireCurrentKey(for: circle.id)
        } catch CircleError.keyNotCurrent where waiting == nil && circle.readableName != nil {
            // Only a name the person could read waits: it is what the new name
            // is checked against when it goes out.
            try PendingChanges.queue(.renameCircle, circleId: circle.id, inputs: .renameCircle(newName: name),
                                     seen: .init(name: circle.readableName))
            return
        }
        // PATCH /api/v1/circles/:id takes just the re-encrypted name —
        // no key rotation, backend leaves encrypted_circle_key / version
        // alone. Encrypt with the existing circle key, ship the nonce +
        // ciphertext, then mutate the local cache so the UI flips
        // immediately without a refetch.
        let nameBlob = try cryptoManager.encryptDataV2(circleId: circle.id, plaintext: name, fieldTag: "name")
        _ = try await api.renameCircle(
            circleId: circle.id,
            encryptedName: EncryptedBlobRequest(
                nonce: nameBlob.nonce,
                ciphertext: nameBlob.ciphertext
            ),
            // Sealed under this device's ACTIVE version (encryptDataV2 uses it).
            keyVersion: (try? cryptoManager.getActiveVersion(circleId: circle.id)).map { Int($0) }
        )
        if let index = circles.firstIndex(where: { $0.id == circle.id }) {
            circles[index].name = name
            if activeCircle?.id == circle.id {
                activeCircle = circles[index]
            }
        }
    }

    func deleteCircle(_ circle: Circle) async throws {
        _ = try await api.deleteCircle(circleId: circle.id)
        PendingChangeStore.shared.forgetCircle(circle.id)
        circles.removeAll { $0.id == circle.id }
        keychain.deleteCircleKey(for: circle.id)
        forgetCircleKeys(circle.id)
        PendingCircleLocations.shared.discard(circleId: circle.id)
        OwnLastSentStore.shared.forget(circleId: circle.id)

        if activeCircle?.id == circle.id {
            activeCircle = circles.first
        }
    }

    func setActiveCircle(_ circle: Circle) {
        activeCircle = circle
    }

    /// The active circle after a load: the loaded copy of the one picked (its
    /// name, lock and version as they are now); the first circle when none was
    /// picked. One no longer listed stays as it was: leaving and deleting move
    /// it on themselves, and a WHOLE list without it prunes it.
    nonisolated static func activeAfterLoad(_ active: Circle?, loaded: [Circle]) -> Circle? {
        guard let active else { return loaded.first }
        return loaded.first { CanonicalId.sameKey($0.id, active.id) } ?? active
    }

    /// The circle to select once this account made `created`: it, when none
    /// is selected; nil, nothing to change, when one is.
    nonisolated static func activeAfterCreate(_ active: Circle?, created: Circle) -> Circle? {
        active == nil ? created : nil
    }

    // MARK: - Members

    /// The active circle's members' sharing, read on every foreground tick. A
    /// member's "Paused" or "Location sharing off" comes with their roster
    /// row; read only with the circle list, every 180 s, it would show up to
    /// three minutes late (the web and Android: under 30 s). Only those two
    /// fields change, on members already listed here. Who is in the circle,
    /// with what name, role and keys, stays with `loadMembers` and its roster
    /// pass; and a refusal prunes nothing here, the next full load decides
    /// that.
    func refreshMemberSharing(for circleId: String) async throws {
        guard !CanonicalId.isPersonalSlot(circleId) else { return }
        let account = AuthManager.shared.userId
        let roster = try await api.getCircleRoster(circleId: circleId)
        // Another account signed in meanwhile: these rows are not its circle's.
        guard CanonicalId.same(AuthManager.shared.userId, account) else { return }
        if let listed = rosters[circleId] {
            let updated = Self.withSharing(of: roster.members, on: listed)
            if updated != listed { rosters[circleId] = updated }
        }
        if let listed = members[circleId] {
            let updated = Self.withSharing(of: roster.members, on: listed)
            if updated != listed { members[circleId] = updated }
        }
    }

    /// Pure: `listed` with each member's sharing as `rows` say (the roster's
    /// `location_sharing` and pause end, by canonical id). A member the rows
    /// don't name keeps what it had; nobody is added or dropped.
    nonisolated static func withSharing(of rows: [CircleMemberResponse], on listed: [CircleMember]) -> [CircleMember] {
        var sharing: [String: CircleMemberResponse] = [:]
        for row in rows { sharing[CanonicalId.key(row.userId)] = row }
        return listed.map { member in
            guard let row = sharing[CanonicalId.key(member.userId)] else { return member }
            var updated = member
            updated.locationSharing = row.locationSharing
            updated.sharingPausedUntil = MemberSharingStatus.wireDate(row.sharingPausedUntil)
            return updated
        }
    }

    func loadMembers(for circleId: String) async throws {
        takeTransitionSeedIfNeeded()
        // The personal key's slot is no circle: no roster is read for it,
        // whatever put it here (a push, a list).
        guard !CanonicalId.isPersonalSlot(circleId) else { throw CircleError.memberNotFound }
        let responses: [CircleMemberResponse]
        let rosterComplete: Bool
        do {
            let roster = try await api.getCircleRoster(circleId: circleId)
            responses = roster.members
            rosterComplete = roster.complete
        } catch let error as APIError {
            // Server says we're not in this circle anymore. The members
            // route also says so off a replica that lags or fails, so a
            // WHOLE circle list decides first, as the Android app's
            // `isStillAMember` does: only a circle it no longer has is
            // pruned here, so we stop retrying every tracking tick and stop
            // logging "Missing key" on envelope sends, and what was kept
            // for it goes with it. Still listed, or no whole list to ask:
            // nothing changes here, and the read reports its failure.
            let message = error.message.lowercased()
            let isGone = error.code == "http_404"
                || error.code == "http_403"
                || error.code == "not_found"
                || message.contains("circle not found")
                || message.contains("not a member")
            if isGone, Self.rosterRefusalPrunes(listed: await wholeListHas(circleId)) {
                pruneGoneCircle(circleId)
            }
            throw error
        }
        let currentUserId = AuthManager.shared.userId
        let keepIds = Set(responses.map { $0.userId })
        // PERF: decrypt every member's E2EE display name OFF the
        // main actor before the synchronous pin/state pass below. Under the 20s
        // foreground poll this AEAD decrypt otherwise runs on @MainActor for all N
        // members each tick and janks the UI. `decryptDataV2` is pure SDK FFI
        // (the SDK CryptoManager is internally synchronized — UniFFI Send+Sync),
        // so it's race-safe off-main; we capture only the Sendable cryptoManager,
        // the circleId, and a String-only (userId, nonce, ciphertext) tuple list
        // (avoids capturing the non-Sendable CircleMemberResponse). The decrypt
        // runs BEFORE beginBulkKeyImport so the begin/end pin-deferral window
        // stays fully synchronous (no await) — the invariant the concurrent
        // per-circle loadMembers fan-out relies on. Mirrors loadMemberLocations'
        // off-main decode.
        let crypto = cryptoManager
        let nameInputs: [(userId: String, nonce: String, ciphertext: String)] = responses.compactMap { response in
            guard let blob = response.encryptedDisplayName else { return nil }
            return (userId: response.userId, nonce: blob.nonce, ciphertext: blob.ciphertext)
        }
        let decryptedNames: [String: String] = await Task.detached {
            var names: [String: String] = [:]
            for input in nameInputs {
                let encrypted = EncryptedData(nonce: input.nonce, ciphertext: input.ciphertext)
                do {
                    let decrypted = try crypto.decryptDataV2(circleId: circleId, encryptedData: encrypted, fieldTag: "display_name")
                    if !decrypted.isEmpty {
                        names[input.userId] = decrypted
                    }
                } catch {
                    // A name that does not decrypt renders as
                    // the "Member" placeholder, so the reason
                    // is worth a diag line.
                    #if DEBUG
                    Self.diag("member-name", "\(circleId) \(input.userId): \(error)")
                    #endif
                }
            }
            return names
        }.value

        let mappedMembers = responses.map { response -> CircleMember in
            // E2EE display name decrypted off-main above; fall back to the
            // plaintext display_name the server still echoes for legacy
            // clients, then a generic placeholder:
            // decrypted-if-present-and-nonempty, else plaintext, else
            // "Member".
            let displayName = decryptedNames[response.userId] ?? response.displayName ?? "Member"
            // Cache every member's signing pubkey (keyed by
            // circleId:userId, including ourselves) so the circle-key
            // store sites in loadCircles can resolve a wrap signer's key
            // from our own directory instead of trusting a
            // server-supplied key. Mirrors the Android app's
            // signingPubkeyCache population in refreshMembers.
            if let signing = response.signingPublicKey, !signing.isEmpty {
                signingPubkeyCache[cacheKey(circleId, response.userId)] = signing
            }
            // ...and the matching sharing pubkey, so MemberDetailView can build
            // a safety number from the pair without hitting the owner/admin-only
            // member-public-keys route. Cached for ourselves too: the Encryption
            // screen reads our own row back to prove the server publishes the
            // key this device actually holds.
            if let sharing = response.sharingPublicKey, !sharing.isEmpty {
                sharingPubkeyCache[cacheKey(circleId, response.userId)] = sharing
            }
            return CircleMember(
                circleId: circleId,
                userId: response.userId,
                displayName: displayName,
                role: CircleMember.MemberRole(rawValue: response.role) ?? .member,
                canSeeRealtime: response.canSeeRealtime,
                canSeeHistory: response.canSeeHistory,
                // Same fallback as CircleMemberResponse.toModel: a response
                // without the field yields the value ownership implies. THIS is
                // the array mayRotate() consults — loadMembers builds members
                // inline instead of calling toModel, so the two must agree.
                canRotateKeys: response.canRotateKeys ?? (response.role == "owner"),
                joinedAt: response.joinedDayBucket
                    .map { Date(timeIntervalSince1970: TimeInterval($0) * 86_400) } ?? Date(),
                keyVersion: response.keyVersion,
                updateRequested: response.updateRequested ?? false,
                locationSharing: response.locationSharing,
                sharingPausedUntil: MemberSharingStatus.wireDate(response.sharingPausedUntil),
                historySharing: response.historySharing
            )
        }
        rosters[circleId] = mappedMembers
        openedNames[circleId] = Set(decryptedNames.keys.map { CanonicalId.key($0) })
        // This account's own sealed name, when owed: after this load, never
        // inside it (the pass below stays synchronous).
        if let ownRow = responses.first(where: { CanonicalId.same($0.userId, AuthManager.shared.userId) }) {
            Task { await self.sealOwnNameIfOwed(circleId: circleId, ownRow: ownRow) }
        }
        let activeVersion = (try? cryptoManager.getActiveVersion(circleId: circleId)).map { Int($0) }

        // Who has LEFT may only be read off a COMPLETE roster (see
        // `getCircleRoster`). Someone who left loses this device's confirmation
        // and is tombstoned — in the roster pass below — so a server that
        // re-adds them later cannot bring them back with their old statements.
        // Nothing is SEEDED from a roster: a server listing a ghost to a fresh
        // device would get it confirmed.
        if rosterComplete {
            incompleteRosters.remove(circleId)
            // Retire the circle pins of everyone no longer in it FIRST.
            // Someone who has left must vouch for nobody — confirming
            // before retiring would give a removed signer one more say.
            // Their IDENTITY pin stays, so if they come back they are
            // recognised (MATCHED / CHANGED), never first contact.
            do {
                let retired = try cryptoManager.retainMemberPins(circleId: circleId, memberUserIds: Array(keepIds))
                pinsRetainedAt[circleId] = Date()
                if retired > 0 {
                    Self.keyLog.info("retired \(retired, privacy: .public) departed member pin(s) in circle \(circleId, privacy: .public)")
                }
            } catch {
                pinsRetainedAt.removeValue(forKey: circleId)
                Self.keyLog.error("retainMemberPins failed for circle \(circleId, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        } else {
            incompleteRosters.insert(circleId)
        }

        guard let me = currentUserId else {
            members[circleId] = []
            return
        }

        // WHO IS CONFIRMED — the same pass the notification extension runs
        // before it hands anyone the circle (`AccessHandover.rosterPass`):
        // departures tombstoned (complete rosters only), then this device's
        // record, the signer of this user's own membership statement, then
        // signed statements to a fixpoint. What it confirms is recorded, with
        // why, and receive-only members' first keys are kept.
        let approvals = KeyDeliveryApprovals.shared
        var base = approvals.record(owner: me, circleId: circleId)
        var pass = AccessHandover.rosterPass(
            circleId: circleId, me: ownIdentity(userId: me), roster: responses,
            rosterComplete: rosterComplete, activeVersion: activeVersion, stored: base, checker: cryptoManager)
        // The notification extension may have recorded a departure meanwhile:
        // the store merges it in, and the pass, which decided without it,
        // decides again from the stored record (bounded; it settles at once).
        for _ in 0..<3 {
            guard approvals.store(pass.record, base: base, owner: me, circleId: circleId,
                                  confirmed: Array(pass.result.newlyConfirmed.keys)) else { break }
            base = approvals.record(owner: me, circleId: circleId)
            pass = AccessHandover.rosterPass(
                circleId: circleId, me: ownIdentity(userId: me), roster: responses,
                rosterComplete: rosterComplete, activeVersion: activeVersion, stored: base, checker: cryptoManager)
        }
        let result = pass.result
        membership[circleId] = result
        membershipCandidates[circleId] = pass.candidates
        rosterWraps[circleId] = Dictionary(responses.map { ($0.userId, $0) }, uniquingKeysWith: { a, _ in a })
        // This pass's member rows are what the SDK reads this account's own row from.
        ownRows.removeValue(forKey: CanonicalId.key(circleId))

        // PIN ON CONFIRMATION, NEVER ON SIGHT. The SDK takes a new version of
        // a circle from any member it has pinned, so a pin is trust: pinning
        // everyone the server listed would let a listed ghost sign the next
        // version for every device. A confirmed member is pinned (a first pin,
        // or a match); keys that differ from the pin are a changed identity —
        // "Is this really {name}?" — and the pin does not move. A receive-only
        // member is never pinned: their keys live in the approval record, used
        // only to hand the circle TO them. A subject conflict is compared with
        // the read-only getters and asked about, never pinned. PERF: each pin
        // persists the whole key store, so the pass is one bulk window —
        // synchronous, so the concurrent per-circle loadMembers in the fan-out
        // cannot interleave.
        let record = pass.record
        let pinner = MemberKeyPinner.shared
        cryptoManager.beginBulkKeyImport()
        for member in mappedMembers where member.userId != me {
            guard let sharing = sharingPubkeyCache[cacheKey(circleId, member.userId)] else { continue }
            let signing = signingPubkeyCache[cacheKey(circleId, member.userId)]
            let known = record.receiveOnlyKeys[member.userId]
            switch pass.pinActions[member.userId] ?? .nothing {
            case .pin:
                pinner.pinConfirmed(
                    circleId: circleId, userId: member.userId, displayName: member.displayName,
                    sharingPubkeyHex: sharing, signingPubkeyHex: signing)
            case .rememberReceiveOnlyKeys:
                continue  // kept in the record by the pass
            case .askIfReceiveOnlyKeysChanged:
                pinner.askAboutChangedKeys(
                    circleId: circleId, userId: member.userId, displayName: member.displayName,
                    known: (known?.sharingKeyHex, known?.signingKeyHex),
                    sharingPubkeyHex: sharing, signingPubkeyHex: signing, receiveOnly: true)
            case .askIfPinnedKeysChanged:
                pinner.askAboutChangedKeys(
                    circleId: circleId, userId: member.userId, displayName: member.displayName,
                    known: pinner.pinnedKeys(circleId: circleId, userId: member.userId),
                    sharingPubkeyHex: sharing, signingPubkeyHex: signing)
            case .nothing:
                continue
            }
        }
        try? cryptoManager.endBulkKeyImport()
        // ...and after every complete roster, only confirmed members keep a pin
        // in this circle: this also retires the view-pins earlier builds made.
        // Retired circle pins stay as identity pins, so a changed identity is
        // still recognised.
        // Never before the one-time seed has been taken from those very pins:
        // they are its evidence.
        if rosterComplete, approvals.transitionSeedTaken(owner: me) {
            let keep = Self.pinsKept(roster: mappedMembers.map(\.userId), verdicts: result.verdicts, selfUserId: me)
            do {
                let retired = try cryptoManager.retainMemberPins(circleId: circleId, memberUserIds: Array(keep))
                if retired > 0 {
                    Self.keyLog.info("retired \(retired, privacy: .public) pin(s) of unconfirmed members in circle \(circleId, privacy: .public)")
                }
            } catch {
                pinsRetainedAt.removeValue(forKey: circleId)
                Self.keyLog.error("retainMemberPins (confirmed) failed for circle \(circleId, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }

        // WHO IS SHOWN: confirmed members and subject conflicts, everywhere —
        // lists, map, counts, pickers. Nobody else, and nobody else is given
        // anything.
        let shown = Set(mappedMembers.filter { result.verdicts[$0.userId]?.isShown ?? false }.map(\.userId))
        members[circleId] = mappedMembers.filter { shown.contains($0.userId) }
        memberLocations = memberLocations.filter { _, loc in
            loc.circleId != circleId || shown.contains(loc.userId)
        }
        rowsByCircle.keepOnly(shown, in: circleId)
        frozenLocations = frozenLocations.filter { _, loc in
            loc.circleId != circleId || shown.contains(loc.userId)
        }
        purgeForSharing(circleId: circleId)
        let hidden = mappedMembers.filter { !shown.contains($0.userId) }
        hiddenMemberCounts[circleId] = hidden.isEmpty ? nil : hidden.count
        if !hidden.isEmpty {
            let invalid = hidden.filter { result.verdicts[$0.userId] == .invalid }.count
            Self.keyLog.error("circle \(circleId, privacy: .public): kept \(hidden.count, privacy: .public) person(s) out (\(invalid, privacy: .public) with statements that do not hold)")
        }
        if let circle = circles.first(where: { $0.id == circleId }), isOwnerOrAdmin(circle) {
            // Owners' and admins' question: only about a member whose
            // statement's signer this device cannot confirm — never
            // about someone with no statement, a forged statement, a
            // changed identity or an invitation to an email.
            let askable = hidden.filter { result.askReasons[$0.userId] != nil }
            if !askable.isEmpty { await askAboutHiddenMembers(in: circle, members: askable, result: result) }
            await signOwedAdmissions(in: circle, result: result)
            await backfillAdmissions(in: circle, result: result)
        }
        Task { await deliverToConfirmedMembers(circleId: circleId) }
        askLateJoinerQuestions(circleId: circleId)
    }

    /// What the pin pass does for one member (`AccessHandover.PinAction`).
    typealias PinAction = AccessHandover.PinAction

    nonisolated static func pinAction(for verdict: MembershipVerdict?, receiveOnlyKeysKnown: Bool) -> PinAction {
        AccessHandover.pinAction(for: verdict, receiveOnlyKeysKnown: receiveOnlyKeysKnown)
    }

    /// Who keeps a circle pin after a complete roster: this device's user and
    /// the members it confirmed that are not receive-only. Everyone else's pin
    /// — a departed member's, or a view-pin an earlier build made — is retired.
    nonisolated static func pinsKept(roster: [String], verdicts: [String: MembershipVerdict], selfUserId: String) -> Set<String> {
        Set(roster.filter { userId in
            if userId == selfUserId { return true }
            if case .confirmed(let origin)? = verdicts[userId] { return !origin.isReceiveOnly }
            return false
        })
    }

    /// Confirmed members by this device's RECORD alone: its user, and everyone
    /// the record holds who is on the roster. The full rule adds signed
    /// statements (`MembershipConfirmation`).
    nonisolated static func confirmedMembers(roster: Set<String>, approved: Set<String>, selfUserId: String?) -> Set<String> {
        var confirmed = roster.intersection(approved)
        if let selfUserId, roster.contains(selfUserId) { confirmed.insert(selfUserId) }
        return confirmed
    }

    /// This device as the confirmation pass needs it: its user, its OWN keys (not
    /// the roster's word for them) and its account email, normalized.
    func ownIdentity(userId: String) -> MembershipConfirmation.Me {
        .own(userId: userId,
             email: Self.ownEmail(userId: userId, served: AuthManager.shared.currentUser,
                                  bridgedUserId: ExtensionBridge.accountUserId,
                                  bridgedEmail: ExtensionBridge.accountEmail),
             crypto: cryptoManager)
    }

    /// This account's email for the confirmation pass: /auth/me's when this
    /// process has read it, else the one the app last mirrored for this same
    /// account (`ExtensionBridge.syncAccount`, which the notification extension
    /// decides with), else none. A headless relaunch never reads /auth/me, and
    /// a launch reads it only once the network answers: with /auth/me's alone,
    /// an own invitation to an email would name nobody there, and the first
    /// key would be taken on trust. Ids as `CanonicalId.same` compares them: a
    /// non-UUID is nobody.
    nonisolated static func ownEmail(userId: String, served: User?,
                                     bridgedUserId: String?, bridgedEmail: String?) -> String? {
        if let served, CanonicalId.same(served.id, userId) { return served.email }
        guard CanonicalId.same(bridgedUserId, userId) else { return nil }
        return bridgedEmail
    }

    /// An owner's or admin's ADMISSION: a signed kind-3 statement that this
    /// member, with these keys, belongs in the circle — so every other member's
    /// app confirms them too. The legacy "Let them in", the backfill and a
    /// promotion to admin come here, with the keys the decision was about (the
    /// roster's current ones when none are given). Never while this device is
    /// behind: the statement carries this device's version, which must be the
    /// circle's. Returns whether the admission was stored; one owed by an
    /// answer stays owed until it is (`signOwedAdmissions`).
    @discardableResult
    func admit(userId: String, circleId: String,
               sharingKeyHex: String? = nil, signingKeyHex: String? = nil, reload: Bool = true) async -> Bool {
        let candidate = membershipCandidates[circleId]?[userId]
        guard let me = AuthManager.shared.userId, holdsCurrentKey(for: circleId),
              let sharing = sharingKeyHex ?? candidate?.sharingKeyHex,
              let signing = signingKeyHex ?? candidate?.signingKeyHex else { return false }
        do {
            let signed = try cryptoManager.signMembershipAdmission(
                circleId: circleId, signerUserId: me, subjectUserId: userId,
                subjectSharingPublicKeyHex: sharing, subjectSigningPublicKeyHex: signing)
            try await api.storeMemberStatement(
                circleId: circleId, userId: userId,
                statementHex: signed.statementHex, signatureHex: signed.signatureHex)
            KeyDeliveryApprovals.shared.admissionSigned(owner: me, circleId: circleId, userId: userId)
            // A person's own new statement about them: a removal this
            // device made before it no longer stands.
            RefreshLedger.shared.clearRemoval(account: me, circleId: circleId, userId: userId, decidedAt: Date())
            Self.keyLog.info("admitted a member of circle \(circleId, privacy: .public)")
            // Reloaded after a stored admission only: a failure re-runs on the
            // next refresh, not in a loop. A batch reloads once, at its end.
            if reload { Task { try? await self.loadMembers(for: circleId) } }
            return true
        } catch {
            Self.keyLog.error("admission for a member of circle \(circleId, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// The admission a waiting change's run signs (`.makeAdmin`, `.letIn`), for
    /// exactly `keys`: its id is on disk before it goes out, and every failure
    /// is thrown for the runner to classify. Not while behind.
    func admitWaiting(_ change: PendingChange, userId: String, circleId: String, keys: MemberKeyPair) async throws {
        guard let me = AuthManager.shared.userId else { throw CircleError.memberNotFound }
        guard holdsCurrentKey(for: circleId) else { throw CircleError.waitingToSync }
        guard !SelfKeyManager.signingKeyMissing else { throw PendingChanges.NeedsPassword() }
        let signed = try cryptoManager.signMembershipAdmission(
            circleId: circleId, signerUserId: me, subjectUserId: userId,
            subjectSharingPublicKeyHex: keys.sharingKeyHex, subjectSigningPublicKeyHex: keys.signingKeyHex)
        try PendingChanges.keepSigned(signed.statement, for: change)
        try await api.storeMemberStatement(
            circleId: circleId, userId: userId, statementHex: signed.statementHex, signatureHex: signed.signatureHex)
        // Stored: a later run only changes the role (`.makeAdmin`).
        PendingChangeStore.shared.update(change.id) { $0.heldStatementId = signed.statement.statementId.lowercased() }
        KeyDeliveryApprovals.shared.admissionSigned(owner: me, circleId: circleId, userId: userId)
        // The person's decision at the tap clears a removal this device made
        // before it; an owed admission is no new decision.
        if case .letIn(let inputs) = change.inputs, inputs.questionKind == "owed" {} else {
            RefreshLedger.shared.clearRemoval(account: me, circleId: circleId, userId: userId, decidedAt: change.createdAt)
        }
        Self.keyLog.info("admitted a member of circle \(circleId, privacy: .public) for a waiting change")
        Task { try? await self.loadMembers(for: circleId) }
    }

    /// "It's them", this device's answer only: its pin moves and its person
    /// chose them, so it may hand them the circle again; their app asks for a
    /// fresh copy because it cannot open the one made for their old keys. A
    /// receive-only member's keys are this device's record, not a pin, and
    /// stay receive-only: only a promotion lifts that. On an owner's or
    /// admin's device, for a member the chain doesn't count, the yes also
    /// admits exactly the keys it showed, where the SDK's eligibility rule has
    /// no other answer for them (`itsThemAdmits`): the waiting "Let them in"
    /// signs that admission with this account's current key once this device
    /// holds the key in use.
    func answerItsThem(_ alert: MemberKeyAlert) throws {
        if alert.receiveOnly {
            guard let me = AuthManager.shared.userId, let signing = alert.newSigningPubkeyHex else {
                throw MemberKeyApprovalError.incompleteKeys
            }
            KeyDeliveryApprovals.shared.replaceReceiveOnlyKeys(
                owner: me, circleId: alert.circleId, userId: alert.userId,
                keys: MemberKeyPair(sharingKeyHex: alert.newSharingPubkeyHex, signingKeyHex: signing))
            MemberKeyPinner.shared.dismiss(alert)
        } else {
            try MemberKeyPinner.shared.approve(alert)
            if let me = AuthManager.shared.userId {
                KeyDeliveryApprovals.shared.approve(owner: me, circleId: alert.circleId, userId: alert.userId, origin: .ownAction)
            }
        }
        if let circle = circles.first(where: { $0.id == alert.circleId }), let signing = alert.newSigningPubkeyHex {
            let shown = MemberKeyPair(sharingKeyHex: alert.newSharingPubkeyHex, signingKeyHex: signing)
            if Self.itsThemAdmits(receiveOnly: alert.receiveOnly, ownerOrAdmin: isOwnerOrAdmin(circle),
                                  chainRole: cryptoManager.chainRole(circleId: alert.circleId, userId: alert.userId),
                                  standing: { itsThemStanding(of: alert.userId, keys: shown, in: alert.circleId) }) {
                do {
                    try PendingChanges.queue(
                        .letIn, circleId: alert.circleId,
                        inputs: .letIn(.init(memberId: alert.userId, questionKind: Self.itsThemQuestionKind)),
                        seen: .init(keys: shown), subject: alert.displayName)
                    PendingChangeRunner.shared.trigger()
                } catch {
                    Self.keyLog.error("circle \(alert.circleId, privacy: .public): the admission \"It's them\" owes was not queued: \(String(describing: error), privacy: .public)")
                }
            }
        }
        Task {
            try? await self.loadMembers(for: alert.circleId)
            await self.deliverToConfirmedMembers(circleId: alert.circleId)
        }
    }

    /// The waiting "Let them in" an owner's or admin's "It's them" queues.
    nonisolated static let itsThemQuestionKind = "itsThem"

    /// Pure: "It's them" also admits only on an owner's or admin's device,
    /// never a receive-only member (their way in stays the email
    /// invitation's question), only a member the chain doesn't count, and
    /// only when the SDK's eligibility rule, read for the keys the yes
    /// showed, neither lets them in nor names a late joiner's case (that
    /// question decides), and no owner or admin removed them. No answer
    /// from the rule: nothing. `standing` is read only when it decides.
    nonisolated static func itsThemAdmits(receiveOnly: Bool, ownerOrAdmin: Bool, chainRole: CircleRole?,
                                          standing: () -> LateJoiner.Standing?) -> Bool {
        guard !receiveOnly, ownerOrAdmin, chainRole == nil, let e = standing() else { return false }
        return !e.eligible && !e.invitationExpired && !e.signerNotChainAdmin && !e.emailInvitationWithoutSignedId
            && !e.removedByOwnerOrAdmin
    }

    /// The SDK's eligibility rule, read for this member: this device's last
    /// roster pass, the member's row with exactly the keys the yes showed,
    /// confirmed by it. Nil when the rule can't say: records not imported in
    /// this process or forked, no pass, the member not on it, or the read
    /// threw.
    func itsThemStanding(of userId: String, keys: MemberKeyPair, in circleId: String) -> LateJoiner.Standing? {
        guard standing(of: circleId) == .recorded, let listing = recordMemberRows(for: circleId),
              let rows = Self.itsThemRows(listing.rows, member: userId, keys: keys),
              let answers = try? cryptoManager.refreshEligibility(circleId: circleId, members: rows.map(\.sdkMember),
                                                                  purpose: .include),
              let answer = answers.first(where: { CanonicalId.same($0.userId, userId) }) else { return nil }
        return LateJoiner.Standing(answer)
    }

    /// Pure: the member list for that read: the member's row with `keys`,
    /// confirmed (the yes chose them with exactly those); nil when they aren't
    /// on it.
    nonisolated static func itsThemRows(_ rows: [RecordMemberRow], member: String, keys: MemberKeyPair) -> [RecordMemberRow]? {
        guard let row = rows.first(where: { CanonicalId.same($0.userId, member) }) else { return nil }
        let shown = RecordMemberRow(userId: row.userId, keys: keys, confirmed: true, listed: row.listed,
                                    listedRole: row.listedRole, statements: row.statements,
                                    personConfirmedKeys: true, serverSaysKeyless: row.serverSaysKeyless)
        return rows.map { CanonicalId.same($0.userId, member) ? shown : $0 }
    }

    /// "Let them in": the pin AND the admission are for exactly the keys
    /// behind the number the question showed, and the pin is made before
    /// anything can hand them the circle. Without it the next pass would take
    /// them on first contact with whatever keys the list showed then, so a
    /// server that swapped the keys after the answer would get the swapped
    /// ones pinned and delivered to. If the list shows other keys at the tap,
    /// or this device already pins other keys for them, nothing is pinned or
    /// signed, and the question is asked again about the keys shown now.
    func letIn(_ request: KeyDeliveryRequest) {
        guard let sharing = request.sharingKeyHex, let signing = request.signingKeyHex else { return }
        var lateJoiner: LateJoiner.Ask?
        if case .lateJoiner(let ask) = request.reason { lateJoiner = ask }
        // The answer is a let-in change bound to exactly the keys the
        // question showed: run at once when this iPhone holds the
        // circle's current version, else once it does. Only the run
        // pins, approves and signs, and its retries look before they
        // sign again.
        do {
            try PendingChanges.queue(
                .letIn, circleId: request.circleId,
                inputs: .letIn(.init(memberId: request.userId, questionKind: request.reason.kindName,
                                     lateJoiner: lateJoiner)),
                seen: .init(keys: MemberKeyPair(sharingKeyHex: sharing, signingKeyHex: signing)),
                subject: request.displayName)
        } catch {
            // Too many changes waiting: the question stays for another answer.
            return
        }
        KeyDeliveryApprovals.shared.answered(request)
        PendingChangeRunner.shared.trigger()
    }

    /// A waiting "Let them in" runs: the pin AND the admission are for exactly
    /// the keys the question showed, and the pin comes before anything can
    /// hand them the circle. If the list shows other keys now, or this device
    /// pins others, nothing is pinned or signed: the runner asks again once.
    /// The admission's id is on disk before it goes out, and this device's
    /// choice, which hands them the circle here, comes after the admission is
    /// stored: until then they are not "already let in" to the re-check. A run
    /// that stops in between leaves its admission held (the answer, or the
    /// look), and the next run pins and signs nothing: it only records the
    /// choice. Without the choice, only an unexpired invitation or an
    /// admission at this device's version would let anyone hand them the
    /// circle, so after a rotation nobody would. The choice is read back: not
    /// stored, the change stays, and runs again.
    func letInWaiting(_ change: PendingChange) async throws {
        // It may pin: the one-time transition seed is taken first, as for
        // an invite.
        takeTransitionSeedIfNeeded()
        guard case .letIn(let inputs) = change.inputs, let asked = change.seen.keys,
              AuthManager.shared.userId != nil else { return }
        guard holdsCurrentKey(for: change.circleId) else { throw CircleError.waitingToSync }
        if change.heldStatementId == nil {
            let pinned = cryptoManager.pinnedSharingKey(circleId: change.circleId, userId: inputs.memberId).flatMap { s in
                cryptoManager.pinnedSigningKey(circleId: change.circleId, userId: inputs.memberId)
                    .map { MemberKeyPair(sharingKeyHex: s, signingKeyHex: $0) }
            }
            guard Self.letInHolds(asked: asked, listed: listedKeys(for: inputs.memberId, in: change.circleId),
                                  pinned: pinned) else {
                throw CircleError.letInDetailsChanged
            }
            if pinned == nil {
                let result = try? cryptoManager.pinMemberKeys(
                    circleId: change.circleId, userId: inputs.memberId,
                    sharingPubkeyHex: asked.sharingKeyHex, signingPubkeyHex: asked.signingKeyHex)
                guard result?.state == .newPinning || result?.state == .matched else {
                    throw CircleError.letInDetailsChanged
                }
            }
            try await admitWaiting(change, userId: inputs.memberId, circleId: change.circleId, keys: asked)
        }
        guard recordLetInChoice(change, reload: change.heldStatementId != nil) else {
            throw PendingChanges.ChoiceNotSaved()
        }
    }

    /// This device's choice, for a let-in whose own admission is stored: read
    /// back, and false when it isn't stored (the change then stays). Then the
    /// roster pass that follows a reload hands them the circle; `reload` is
    /// false only for a run that has just admitted them, which reloads
    /// already.
    func recordLetInChoice(_ change: PendingChange, reload: Bool) -> Bool {
        guard case .letIn(let inputs) = change.inputs, let me = AuthManager.shared.userId,
              me.caseInsensitiveCompare(change.account) == .orderedSame,
              KeyDeliveryApprovals.shared.approveAnswer(owner: me, circleId: change.circleId,
                                                        userId: inputs.memberId) else { return false }
        if reload { Task { try? await self.loadMembers(for: change.circleId) } }
        return true
    }

    /// Pure, for tests: whether "Let them in" may pin and sign the keys the
    /// question was about: the list still shows exactly them, and this device
    /// pins nothing else for them.
    nonisolated static func letInHolds(asked: MemberKeyPair, listed: MemberKeyPair?, pinned: MemberKeyPair?) -> Bool {
        guard let listed, asked.matches(sharing: listed.sharingKeyHex, signing: listed.signingKeyHex) else {
            return false
        }
        if let pinned, !asked.matches(sharing: pinned.sharingKeyHex, signing: pinned.signingKeyHex) { return false }
        return true
    }

    /// Owed admissions (a "Let them in" or a promotion that could not be
    /// signed then) become let-in changes: the runner signs them, for the
    /// keys this device confirmed them with, and its retries look before
    /// they sign again. Nothing is signed from here.
    private func signOwedAdmissions(in circle: Circle, result: MembershipConfirmation.Result) async {
        guard let me = AuthManager.shared.userId else { return }
        let record = KeyDeliveryApprovals.shared.record(owner: me, circleId: circle.id)
        for userId in record.admissionsOwed.sorted() {
            guard case .confirmed(let origin)? = result.verdicts[userId],
                  let row = membershipCandidates[circle.id]?[userId] else { continue }
            // For the keys this device holds for them: its pin, or a
            // receive-only member's record (a promotion lifts that).
            let held: MemberKeyPair? = origin.isReceiveOnly
                ? record.receiveOnlyKeys[userId]
                : cryptoManager.pinnedSharingKey(circleId: circle.id, userId: userId).flatMap { s in
                    cryptoManager.pinnedSigningKey(circleId: circle.id, userId: userId)
                        .map { MemberKeyPair(sharingKeyHex: s, signingKeyHex: $0) }
                }
            guard let held, held.matches(sharing: row.sharingKeyHex, signing: row.signingKeyHex) else { continue }
            do {
                try PendingChanges.queue(
                    .letIn, circleId: circle.id, inputs: .letIn(.init(memberId: userId, questionKind: "owed")),
                    seen: .init(keys: held), subject: members[circle.id]?.first { $0.userId == userId }?.displayName)
            } catch {
                continue
            }
            KeyDeliveryApprovals.shared.admissionSigned(owner: me, circleId: circle.id, userId: userId)
        }
    }

    /// Circles with an admission pass (owed or backfill) running on this device:
    /// one at a time, so a reload cannot sign the same admission twice.
    private var admissionsInFlight: Set<String> = []

    /// The backfill, on an owner's or admin's device, never while it is behind
    /// or receive-only: an admission, once, for a member this device confirmed
    /// that no other device can confirm from their statements —
    /// * a `preRound2Seed` member (an earlier version's approval, or one the
    ///   one-time seed took from the pins it held) whose statements, if any, do
    ///   not hold (none, or the signer left): the seed itself is the evidence;
    /// * a member it confirmed by a statement that no longer verifies here —
    ///   made under a signer's previous key — only when a member CONFIRMED here
    ///   already handed them the circle (their stored copy verifies under that
    ///   member's signing key).
    /// Never one it took on first use since, and only while their keys are
    /// still the ones pinned for them: a password reset is never confirmed for
    /// anyone else. A new device of such a member then anchors on the
    /// admission about itself.
    ///
    /// Nobody decides these at that moment, and on a circle with refresh
    /// records a fresh admission is what brings a removed member back. So on
    /// such a circle it signs only as an owner or admin in the chain, and only
    /// for a member the chain still counts here (`chainRole`); and everywhere
    /// it keeps the waiting let-in's discipline (`AdmissionBackfill`): the look
    /// first, each id saved before its request, done once the server holds
    /// one, stopped after 20.
    private func backfillAdmissions(in circle: Circle, result: MembershipConfirmation.Result) async {
        guard let me = AuthManager.shared.userId, !selfIsReceiveOnly(circle.id), holdsCurrentKey(for: circle.id),
              !admissionsInFlight.contains(circle.id) else { return }
        let recorded = cryptoManager.circleHasRefreshRecords(circleId: circle.id)
        if recorded {
            guard let role = cryptoManager.chainRole(circleId: circle.id, userId: me),
                  role == .owner || role == .admin else { return }
        }
        admissionsInFlight.insert(circle.id)
        defer { admissionsInFlight.remove(circle.id) }
        var admitted = false
        defer { if admitted { Task { try? await self.loadMembers(for: circle.id) } } }
        let approvals = KeyDeliveryApprovals.shared
        let record = approvals.record(owner: me, circleId: circle.id)
        let backfill = AdmissionBackfill(ledger: .shared, account: me, deps: backfillDeps(me: me))
        for (userId, origin) in record.entries.sorted(by: { $0.key < $1.key })
        where userId != me && !record.backfilled.contains(userId) {
            guard case .confirmed(let now)? = result.verdicts[userId], !now.isReceiveOnly,
                  let row = rosterWraps[circle.id]?[userId],
                  let candidate = membershipCandidates[circle.id]?[userId],
                  keysMatchPin(candidate, circleId: circle.id),
                  Self.backfillDue(origin: origin, statementHolds: result.statementHolds.contains(userId),
                                   statementsFail: result.statementsFail.contains(userId),
                                   copyVouched: storedCopyIsVouched(row, circleId: circle.id, me: me, result: result))
            else { continue }
            guard backfillSigns(circleId: circle.id, me: me, userId: userId) else { continue }
            if await backfill.run(circleId: circle.id, userId: userId) == .stored {
                approvals.admissionSigned(owner: me, circleId: circle.id, userId: userId)
                approvals.markBackfilled(owner: me, circleId: circle.id, userId: userId)
                admitted = true
            }
        }
    }

    /// Pure: whether the backfill signs for a member. On a circle with
    /// records, only while the chain counts them here, only as an owner or
    /// admin in the chain, and never while the circle waits (its records
    /// not imported in this process, withheld, forked). The caller checks
    /// that this device isn't behind.
    nonisolated static func backfillSigns(hasRecords: Bool, standing: RecordsStanding, myChainRole: CircleRole?,
                                          memberChainRole: CircleRole?) -> Bool {
        guard hasRecords else { return true }
        return standing == .recorded && (myChainRole == .owner || myChainRole == .admin) && memberChainRole != nil
    }

    /// `backfillSigns` for a circle's member, as the chain says now.
    func backfillSigns(circleId: String, me: String, userId: String) -> Bool {
        Self.backfillSigns(hasRecords: cryptoManager.circleHasRefreshRecords(circleId: circleId),
                           standing: standing(of: circleId),
                           myChainRole: cryptoManager.chainRole(circleId: circleId, userId: me),
                           memberChainRole: cryptoManager.chainRole(circleId: circleId, userId: userId))
    }

    /// The backfill's reach outside itself: the look for its signed ids, the
    /// SDK's admission for the keys the roster shows (the pin,
    /// `keysMatchPin`), the store, and the dead ids in this account's record,
    /// read back. The signature asks the chain again: the look before it
    /// awaits, and an eject taken meanwhile signs nothing.
    private func backfillDeps(me: String) -> AdmissionBackfill.Deps {
        AdmissionBackfill.Deps(
            look: { circleId, ids in await PendingChangeRunner.liveLook(circleId: circleId, statementIds: ids) },
            sign: { [self, cryptoManager, membershipCandidates] circleId, userId in
                guard holdsCurrentKey(for: circleId), backfillSigns(circleId: circleId, me: me, userId: userId) else {
                    throw CircleError.waitingToSync
                }
                guard let candidate = membershipCandidates[circleId]?[userId],
                      let sharing = candidate.sharingKeyHex, let signing = candidate.signingKeyHex else {
                    throw CircleError.memberNotFound
                }
                let signed = try cryptoManager.signMembershipAdmission(
                    circleId: circleId, signerUserId: me, subjectUserId: userId,
                    subjectSharingPublicKeyHex: sharing, subjectSigningPublicKeyHex: signing)
                return AdmissionBackfill.Signed(statementId: signed.statement.statementId.lowercased(),
                                                statementHex: signed.statementHex, signatureHex: signed.signatureHex)
            },
            store: { [api] circleId, userId, signed in
                try await api.storeMemberStatement(circleId: circleId, userId: userId,
                                                   statementHex: signed.statementHex, signatureHex: signed.signatureHex)
            },
            settle: { circleId, dead in
                KeyDeliveryApprovals.shared.settleSignedStatements(owner: me, circleId: circleId, dead: dead, invitee: nil)
            },
            now: Date.init)
    }

    /// Which of this device's confirmations the backfill vouches for: a
    /// `preRound2Seed` whose statements do not hold for anyone else — the
    /// seed itself is the evidence (legacy wraps are often unsigned) — and a
    /// member confirmed here by a statement that no longer verifies, when a
    /// member confirmed here handed them their copy (`copyVouched`). Never
    /// one taken on first use, never a receive-only one, never this device's
    /// own choice (a reset answer is for this device alone).
    nonisolated static func backfillDue(origin: ApprovalOrigin, statementHolds: Bool, statementsFail: Bool,
                                        copyVouched: Bool) -> Bool {
        switch origin {
        case .preRound2Seed: return !statementHolds
        case .statement: return statementsFail && copyVouched
        case .ownAction, .kind2, .ownKind2, .anchor: return false
        }
    }

    /// Whether a member's current keys are the ones this device pinned for them
    /// — no changed identity waiting for "It's them".
    /// The keys this device holds for a member: a receive-only member's
    /// recorded pair — never an SDK pin — else the pinned pair. nil when it
    /// holds none.
    /// The keys the member list shows for someone now: the server's word, to
    /// compare with what this device holds, never to sign by itself.
    func listedKeys(for userId: String, in circleId: String) -> MemberKeyPair? {
        membershipCandidates[circleId]?[userId].flatMap { row in
            row.sharingKeyHex.flatMap { sharing in
                row.signingKeyHex.map { MemberKeyPair(sharingKeyHex: sharing, signingKeyHex: $0) }
            }
        }
    }

    func promotionKeys(for userId: String, in circleId: String) -> MemberKeyPair? {
        guard let me = AuthManager.shared.userId else { return nil }
        if isReceiveOnly(userId, in: circleId) {
            return KeyDeliveryApprovals.shared.record(owner: me, circleId: circleId).receiveOnlyKeys[userId]
        }
        let pinned = MemberKeyPinner.shared.pinnedKeys(circleId: circleId, userId: userId)
        guard let sharing = pinned.sharing, let signing = pinned.signing else { return nil }
        return MemberKeyPair(sharingKeyHex: sharing, signingKeyHex: signing)
    }

    /// Pure, for tests: the keys a promotion's admission signs — the held ones,
    /// only when the member list shows exactly them and they are the ones the
    /// person decided on (the dialog's, when there was one). nil: nothing signed.
    nonisolated static func promotionAdmissionKeys(held: MemberKeyPair?, listed: MemberKeyPair?,
                                                   decided: MemberKeyPair?) -> MemberKeyPair? {
        guard let held, let listed, held.matches(sharing: listed.sharingKeyHex, signing: listed.signingKeyHex) else {
            return nil
        }
        if let decided, !held.matches(sharing: decided.sharingKeyHex, signing: decided.signingKeyHex) { return nil }
        return held
    }

    /// Their security code for exactly these keys (the promotion question).
    func securityCode(for userId: String, keys: MemberKeyPair) -> String? {
        guard let me = AuthManager.shared.userId else { return nil }
        return try? cryptoManager.computeSafetyNumber(
            selfUserId: me, peerUserId: userId, peerSharingPubkeyHex: keys.sharingKeyHex,
            peerSigningPubkeyHex: keys.signingKeyHex)
    }

    private func keysMatchPin(_ member: MembershipCandidate, circleId: String) -> Bool {
        let pinned = MemberKeyPinner.shared.pinnedKeys(circleId: circleId, userId: member.userId)
        guard let sharing = member.sharingKeyHex, let signing = member.signingKeyHex,
              let pinnedSharing = pinned.sharing, let pinnedSigning = pinned.signing else { return false }
        return sharing.caseInsensitiveCompare(pinnedSharing) == .orderedSame
            && signing.caseInsensitiveCompare(pinnedSigning) == .orderedSame
    }

    /// Whether a member's stored copy was made — and signed — by this device or
    /// by a member CONFIRMED here (not merely pinned), under the key pinned
    /// for them: proof a trusted member already let them in.
    private func storedCopyIsVouched(_ row: CircleMemberResponse, circleId: String, me: String,
                                     result: MembershipConfirmation.Result) -> Bool {
        Self.copyIsVouched(
            row, circleId: circleId, me: me,
            signerKey: { [cryptoManager] signer in
                if signer.lowercased() == me.lowercased() { return try? cryptoManager.signingPublicKeyHex() }
                guard case .confirmed(let origin)? = result.verdicts[signer], !origin.isReceiveOnly else { return nil }
                return cryptoManager.pinnedSigningKey(circleId: circleId, userId: signer)
            },
            verify: { [cryptoManager] key, signature, params in
                (try? cryptoManager.verifyWrap(signingPubkeyHex: key, signatureHex: signature, params: params)) == true
            })
    }

    /// Evidence for a member confirmed by a statement that no longer verifies:
    /// their stored copy was handed to them by a member confirmed HERE — its
    /// wrap signature verifies under that signer's key (`signerKey`: this
    /// device's own, or a confirmed, non-receive-only member's pin), under
    /// EITHER domain a copy is signed in: a delivery or a creation
    /// (`circle_member_wrap`) or a refresh (`rotation_member_wrap`), as the
    /// SDK's own store path accepts. A copy the member signed for THEMSELVES
    /// proves nothing about anybody else vouching for them and never counts.
    /// Any version will do, as on Android and the web. Model: the Android
    /// app's `CircleRepository.handedOverByConfirmed`.
    nonisolated static func copyIsVouched(_ row: CircleMemberResponse, circleId: String, me: String,
                                          signerKey: (String) -> String?,
                                          verify: (String, String, SignWrapParams) -> Bool) -> Bool {
        guard let signer = row.wrapSignerUserId, let signature = row.wrapSignature, !signature.isEmpty,
              let keyVersion = row.keyVersion, keyVersion > 0, !row.ephemeralPublicKey.isEmpty,
              signer.caseInsensitiveCompare(row.userId) != .orderedSame,
              let key = signerKey(signer) else { return false }
        return wrapDomains.contains { domain in
            verify(key, signature, SignWrapParams(
                domain: domain,
                senderUserId: signer,
                recipientUserId: row.userId,
                circleId: circleId,
                placeId: "",
                keyVersion: UInt32(keyVersion),
                ephemeralPubkeyHex: row.ephemeralPublicKey,
                wrapNonceHex: row.encryptedCircleKey.nonce,
                wrapCiphertextHex: row.encryptedCircleKey.ciphertext
            ))
        }
    }

    /// The domain every circle-member wrap is signed under (SDK
    /// `DOMAIN_CIRCLE_MEMBER_WRAP`).
    nonisolated static let memberWrapDomain = "pingolin.sig.v1.circle_member_wrap"
    /// A refresh's copies (SDK `DOMAIN_ROTATION_MEMBER_WRAP`).
    nonisolated static let rotationMemberWrapDomain = "pingolin.sig.v1.rotation_member_wrap"
    nonisolated static let wrapDomains = [memberWrapDomain, rotationMemberWrapDomain]

    /// The owner's and admin's question: someone whose statement's signer
    /// this device cannot confirm is asked about once: "Let {name} into
    /// {circle}?", showing their number. "Not now" waits for the next
    /// launch. Their email comes from `member-public-keys`, whose `email`
    /// only owners and admins get. Nobody with no statement at all is asked
    /// about: they stay out, counted.
    private func askAboutHiddenMembers(in circle: Circle, members hidden: [CircleMember],
                                       result: MembershipConfirmation.Result) async {
        // Asked while this iPhone is behind too: the answer then waits as a
        // let-in change, bound to the keys shown. Never asked again about
        // someone whose answer already waits.
        guard let me = AuthManager.shared.userId else { return }
        let approvals = KeyDeliveryApprovals.shared
        let deferred = approvals.deferredMembers(circleId: circle.id)
        let answered = Set(PendingChangeStore.shared.pending(circleId: circle.id).compactMap { change -> String? in
            if case .letIn(let inputs) = change.inputs { return inputs.memberId.lowercased() }
            return nil
        })
        let toAsk = hidden.filter {
            !deferred.contains($0.userId) && !approvals.isQueued(circleId: circle.id, userId: $0.userId)
                && !answered.contains($0.userId.lowercased())
        }
        guard !toAsk.isEmpty else { return }
        let emails = Dictionary(
            ((try? await api.memberPublicKeys(circleId: circle.id)) ?? []).map { ($0.userId, $0.email) },
            uniquingKeysWith: { first, _ in first }
        )
        for member in toAsk {
            guard let reason = result.askReasons[member.userId],
                  let candidate = membershipCandidates[circle.id]?[member.userId],
                  let sharing = candidate.sharingKeyHex, let signing = candidate.signingKeyHex else { continue }
            approvals.ask(KeyDeliveryRequest(
                circleId: circle.id,
                circleName: circle.name,
                userId: member.userId,
                displayName: member.displayName,
                email: emails[member.userId] ?? nil,
                reason: reason,
                sharingKeyHex: sharing,
                signingKeyHex: signing,
                number: reason == .unconfirmedInviter
                    ? try? cryptoManager.computeSafetyNumber(
                        selfUserId: me, peerUserId: member.userId,
                        peerSharingPubkeyHex: sharing, peerSigningPubkeyHex: signing)
                    : nil
            ))
        }
    }

    /// While this iPhone is behind in the circle the invitation waits.
    /// `waiting`: the waiting change being run now; its statement's id is
    /// saved before the request goes out, and a refusal while behind is
    /// thrown, not queued again. `confirmed`: the account and keys the
    /// person just said "It's them" about.
    func inviteMember(to circleId: String, email: String, lookupRetried: Bool = false,
                      confirmed: InviteeChange? = nil, waiting: PendingChange? = nil) async throws {
        // Nobody is invited to the personal key's slot.
        guard !CanonicalId.isPersonalSlot(circleId) else { throw CircleError.memberNotFound }
        // An invite may pin the invitee: the one-time transition seed is
        // taken first.
        takeTransitionSeedIfNeeded()
        // An invitation is a signed statement carrying this device's version of
        // the circle, which must be the circle's. While behind, it waits:
        // nothing is looked up, pinned or signed until it runs.
        guard holdsCurrentKey(for: circleId) else {
            guard waiting == nil else { throw CircleError.waitingToSync }
            // With the "It's them" it may carry (a live answer that finds this
            // iPhone behind meanwhile): then only that account, those keys.
            let kept = Self.keptInvitation(email: email, confirmed: confirmed)
            try PendingChanges.queue(.invite, circleId: circleId, inputs: kept.inputs, seen: kept.seen,
                                     subject: email.lowercased())
            return
        }
        // A run signs with this device's signing key, which only the
        // password puts back: "Waiting for your password".
        if waiting != nil, SelfKeyManager.signingKeyMissing { throw PendingChanges.NeedsPassword() }
        // 1. Lookup the invitee's published X25519 sharing public key.
        //    A nil sharingPublicKey means the email isn't registered — fall
        //    back to a link-style invite (no pre-encrypted key) instead of
        //    failing the whole call.
        let lookup: UserPublicKeyResponse
        do {
            // The account's id only in its one form, before anything
            // reads it: spelt another way it would miss this device's
            // pins for them. Such an answer is no answer.
            guard let answer = Self.canonicalLookup(try await api.lookupPublicKey(email: email)) else {
                throw PendingChanges.AnswerNotReadable()
            }
            lookup = answer
        } catch where PendingChanges.addressCouldNotBeChecked(error) {
            // The address couldn't be checked: the invitation is kept
            // as a waiting change, and nothing is signed or sent until
            // the check answers. Never an error, never an invitation to
            // the address, never an unsigned one.
            if let waiting {
                PendingChangeStore.shared.update(waiting.id) { $0.addressUnchecked = true }
                throw PendingChanges.AddressNotChecked()
            }
            let kept = Self.keptInvitation(email: email, confirmed: confirmed)
            try PendingChanges.queue(.invite, circleId: circleId, inputs: kept.inputs, seen: kept.seen,
                                     subject: email.lowercased(), addressUnchecked: true)
            return
        }

        // After "It's them" about one account (the live answer, or a waiting
        // invitation's), the invitation goes ONLY to that account with exactly
        // the keys confirmed. A directory that shows another account, other
        // keys or none now gets nothing: never a first contact, never an
        // invitation to the address; it ends with item 30
        // (`PendingChangeCopy.detailsKeepChangingInvite`), live or waiting.
        let confirmedAs = Self.confirmedInvitee(live: confirmed, waiting: waiting)
        if let confirmedAs, !Self.lookupShows(confirmedAs, lookup) {
            throw CircleError.inviteeDetailsChanged(email: email)
        }
        // A waiting invitation to an account the circle's records show
        // removed after the person decided signs nothing (item 23,
        // `PendingChangeCopy.memberLeft`); one this device can't judge
        // yet waits.
        if let waiting, let inviteeUserId = lookup.userId {
            switch PendingChangeKinds.removedSinceTheTap(removalCheck(userId: inviteeUserId, circleId: circleId),
                                                         change: waiting, name: email) {
            case .drop(let line)?: throw CircleError.removedSinceDecided(line: line ?? PendingChangeCopy.notDone(waiting))
            case .notYet?: throw CircleError.waitingToSync
            default: break
            }
        }

        // An account this device already knows, with other keys than it holds
        // for them now: their identity changed (a password reset — or a server
        // swapping keys). The invitation would SIGN those keys for every other
        // member's app, so nothing is sent until this device's user says it is
        // them, having seen their number (the Android app asks the same).
        if confirmedAs == nil, let inviteeUserId = lookup.userId, let sharing = lookup.sharingPublicKey,
           let signing = lookup.signingPublicKey,
           Self.inviteeKeysChanged(
               sharing: sharing, signing: signing,
               pinned: MemberKeyPinner.shared.pinnedKeys(circleId: circleId, userId: inviteeUserId)) {
            let number = AuthManager.shared.userId.flatMap { me in
                try? cryptoManager.computeSafetyNumber(
                    selfUserId: me, peerUserId: inviteeUserId,
                    peerSharingPubkeyHex: sharing, peerSigningPubkeyHex: signing)
            }
            throw CircleError.inviteeChanged(InviteeChange(
                circleId: circleId, email: email, userId: inviteeUserId,
                sharingKeyHex: sharing.lowercased(), signingKeyHex: signing.lowercased(), number: number))
        }
        // "It's them" (the live answer, or a waiting invitation's), and the
        // directory shows exactly what was confirmed: this device takes those
        // keys now, once the check has answered, never at the tap or when it
        // was queued.
        if confirmedAs != nil, let inviteeUserId = lookup.userId, let sharing = lookup.sharingPublicKey,
           let signing = lookup.signingPublicKey,
           Self.inviteeKeysChanged(
               sharing: sharing, signing: signing,
               pinned: MemberKeyPinner.shared.pinnedKeys(circleId: circleId, userId: inviteeUserId)) {
            try cryptoManager.approveMemberKeyChange(
                circleId: circleId, userId: inviteeUserId,
                newSharingPubkeyHex: sharing, newSigningPubkeyHex: signing)
            MemberVerificationStore.clearVerified(circleId: circleId, userId: inviteeUserId)
        }

        // 2. If we have a public key, wrap the active circle key for them.
        //    The SDK gives us back both the encrypted key and the matching
        //    ephemeral public key in one bundle.
        var encryptedKeyForInvitee: EncryptedBlobRequest? = nil
        var ephemeralPublicKey: String? = nil
        var wrapSignatureForInvitee: String? = nil
        // A device the circle's newest key has not reached would hand the
        // invitee the OLD key — the one a removed member still holds. It
        // sends a keyless invite instead; an owner or admin whose device
        // holds the current key then gives them access. On a circle with
        // records, the key goes only with an owner's or admin's invitation in
        // the chain (`invitationCarriesKey`).
        if let inviteePublicKey = lookup.sharingPublicKey,
           let inviteeUserId = lookup.userId,
           let currentUserId = AuthManager.shared.userId,
           holdsCurrentKey(for: circleId), invitationCarriesKey(circleId: circleId) {
            // Signed wrap requires the recipient's Ed25519 verifying
            // key. If the invitee hasn't published one yet (older
            // account), the SDK rejects the wrap — fall back to a
            // link-style invite without the pre-encrypted key.
            if let inviteeSigningKey = lookup.signingPublicKey {
                // Proton-style recipient-key pin gate: NEVER wrap the
                // live circle key to a server-substituted key. A
                // divergence from a pin was asked about above and never
                // reaches here; this stays as the second line. On
                // genuine first contact (no pin) the recipient is pinned
                // — this user chose them — so a LATER substitution
                // diverges and is caught.
                let pinned = cryptoManager.pinnedSharingKey(circleId: circleId, userId: inviteeUserId)
                if let pinned, pinned.caseInsensitiveCompare(inviteePublicKey) != .orderedSame {
                    print("[Track] invite: recipient \(inviteeUserId) sharing key diverges from pin — refusing to pre-encrypt the circle key")
                } else {
                    // First contact (no pin yet): TOFU-pin the recipient
                    // BEFORE wrapping. If pin PERSISTENCE fails, do NOT
                    // pre-encrypt — a wrap sent with no pin on record leaves a
                    // later re-invite key-substitution uncatchable by the
                    // rotation gate. Fall back to the link-style invite
                    // (encryptedKeyForInvitee stays nil), matching the
                    // fail-closed spirit of the divergence gate above.
                    var pinReady = true
                    if pinned == nil {
                        do {
                            _ = try cryptoManager.pinMemberKeys(
                                circleId: circleId,
                                userId: inviteeUserId,
                                sharingPubkeyHex: inviteePublicKey,
                                signingPubkeyHex: inviteeSigningKey
                            )
                        } catch {
                            print("[Track] invite: failed to persist recipient key pin for \(inviteeUserId) — falling back to link invite (no pre-encrypted key): \(error)")
                            pinReady = false
                        }
                    }
                    if pinReady {
                        let bundle = try cryptoManager.wrapCircleKeyForMemberFull(
                            circleId: circleId,
                            memberPublicKeyHex: inviteePublicKey,
                            senderUserId: currentUserId,
                            recipientUserId: inviteeUserId,
                            recipientSigningPubkeyHex: inviteeSigningKey
                        )
                        encryptedKeyForInvitee = EncryptedBlobRequest(
                            nonce: bundle.encryptedCircleKey.nonce,
                            ciphertext: bundle.encryptedCircleKey.ciphertext
                        )
                        ephemeralPublicKey = bundle.ephemeralPublicKey
                        wrapSignatureForInvitee = bundle.wrapSignature.isEmpty ? nil : bundle.wrapSignature
                    }
                }
            }
        }

        // 3. The circle's name goes only to an address the lookup above
        //    ANSWERED has no account: the e-mail is that person's only notice
        //    of the invitation, and the server puts the name in its body and
        //    keeps none. Never to an account, not even one without keys (it
        //    still signs a kind 2 below): it reads the invitation in the app,
        //    where the circle's name shows once it has joined.
        let circleName = Self.circleNameForInvitation(
            lookupUserId: lookup.userId, name: circles.first(where: { $0.id == circleId })?.name)

        // 4. Sign the invitation: it is what lets ANY member's app let the
        //    newcomer in without asking anyone. Kind 1 exactly when the
        //    lookup found an account with both keys — it binds that account and
        //    exactly those keys; kind 2 otherwise, binding the email (no account
        //    yet, or one that never published keys).
        var request = InviteByEmailRequest(
            email: email,
            encryptedCircleKey: encryptedKeyForInvitee,
            ephemeralPublicKey: ephemeralPublicKey,
            circleName: circleName,
            wrapSignature: wrapSignatureForInvitee
        )
        var boundAccount: String?
        var boundStatement: MembershipStatement?
        var invitation: MembershipStatement?
        if let me = AuthManager.shared.userId {
            var signed: SignedMembershipStatement?
            do {
                if let inviteeUserId = lookup.userId,
                   let sharing = lookup.sharingPublicKey, let signing = lookup.signingPublicKey {
                    let statement = try cryptoManager.signInvitationToAccount(
                        circleId: circleId, signerUserId: me, subjectUserId: inviteeUserId,
                        subjectSharingPublicKeyHex: sharing, subjectSigningPublicKeyHex: signing)
                    signed = statement
                    boundAccount = inviteeUserId
                    boundStatement = try? cryptoManager.parseMembershipStatement(statementHex: statement.statementHex)
                } else {
                    signed = try cryptoManager.signInvitationToEmail(circleId: circleId, signerUserId: me, email: email)
                }
            } catch {
                Self.keyLog.error("could not sign an invitation to circle \(circleId, privacy: .public): \(String(describing: error), privacy: .public)")
                // A waiting change never sends what it couldn't sign.
                if waiting != nil { throw error }
            }
            if let signed {
                request.statement = signed.statementHex
                request.statementSignature = signed.signatureHex
                invitation = signed.statement
                // Its id is on disk before the request goes
                // out, or nothing goes out.
                if let waiting { try PendingChanges.keepSigned(signed.statement, for: waiting) }
            }
        }
        request.clientRequestId = waiting?.requestId()

        do {
            _ = try await api.inviteByEmail(circleId: circleId, request: request)
            // A re-invite from this device clears a removal it made before
            // the person decided: at the tap, or now. Only a signed one,
            // which this device can match when it's withdrawn: that brings
            // the removal back.
            if let me = AuthManager.shared.userId, let inviteeUserId = lookup.userId, let invitation {
                RefreshLedger.shared.clearRemoval(account: me, circleId: circleId, userId: inviteeUserId,
                                                  decidedAt: waiting?.createdAt ?? Date(), invitation: invitation)
            }
        } catch let error as APIError where error.isServerCode("invite_lookup_changed") && !lookupRetried {
            // The address's account moved on since the lookup above. Look it
            // up again and sign again, once, inside this same action — asking
            // "Is this really {email}?" first if a known account's keys
            // changed.
            try await inviteMember(to: circleId, email: email, lookupRetried: true, confirmed: confirmed,
                                   waiting: waiting)
            return
        }

        // Whom this device's user invited to their ACCOUNT is theirs to let in
        // once they join — with THIS invitation, before it expires. An
        // invitation to an email is not: that member is receive-only here too,
        // confirmed by this device's own kind-2 statement when they appear.
        if let inviteeUserId = boundAccount, let statement = boundStatement, let me = AuthManager.shared.userId {
            KeyDeliveryApprovals.shared.approveInvitee(owner: me, circleId: circleId, userId: inviteeUserId,
                                                       statementId: statement.statementId,
                                                       expiresAt: statement.expiresAt)
        }

        // Reload members so a freshly-accepted invite shows up promptly.
        try await loadMembers(for: circleId)
    }

    /// Pure, for tests: an invitation kept as a waiting change (`.invite`),
    /// with the "It's them" it may carry: that account and exactly those
    /// keys, the question asked already.
    nonisolated static func keptInvitation(email: String, confirmed: InviteeChange?)
        -> (inputs: PendingChange.Inputs, seen: PendingChange.Seen) {
        let address = email.lowercased()
        guard let confirmed else { return (.invite(.init(email: address)), PendingChange.Seen()) }
        return (.invite(.init(email: address, confirmedUserId: confirmed.userId)),
                PendingChange.Seen(keys: MemberKeyPair(sharingKeyHex: confirmed.sharingKeyHex,
                                                       signingKeyHex: confirmed.signingKeyHex),
                                   askedAgain: true, subjectUserId: confirmed.userId))
    }

    /// Pure, for tests: whom "It's them" confirmed for this invitation, as an
    /// account and its keys: the live answer's, else a waiting invitation's;
    /// nil when nobody was. The account by its comparison key: one an earlier
    /// build kept in another form never matches the directory's canonical id.
    nonisolated static func confirmedInvitee(live: InviteeChange?,
                                             waiting: PendingChange?) -> (userId: String, keys: MemberKeyPair?)? {
        if let live {
            return (CanonicalId.key(live.userId),
                    MemberKeyPair(sharingKeyHex: live.sharingKeyHex, signingKeyHex: live.signingKeyHex))
        }
        guard let waiting, case .invite(let inputs) = waiting.inputs, let userId = inputs.confirmedUserId else {
            return nil
        }
        return (CanonicalId.key(userId), waiting.seen.keys)
    }

    /// Pure, for tests: whether the directory shows exactly the account and
    /// both keys that were confirmed.
    nonisolated static func lookupShows(_ confirmed: (userId: String, keys: MemberKeyPair?),
                                        _ lookup: UserPublicKeyResponse) -> Bool {
        guard let userId = lookup.userId, userId.caseInsensitiveCompare(confirmed.userId) == .orderedSame,
              let keys = confirmed.keys else { return false }
        return keys.matches(sharing: lookup.sharingPublicKey, signing: lookup.signingPublicKey)
    }

    /// Pure, for tests: the directory's answer with the account's id in its
    /// one form (`CanonicalId.strict`: the 36 hyphenated characters, in any
    /// case), or nil when it names the account any other way, even another
    /// spelling of a UUID: that is no answer. No account stays no account.
    nonisolated static func canonicalLookup(_ answer: UserPublicKeyResponse) -> UserPublicKeyResponse? {
        guard let raw = answer.userId else { return answer }
        guard let userId = CanonicalId.strict(raw) else { return nil }
        return UserPublicKeyResponse(email: answer.email, sharingPublicKey: answer.sharingPublicKey,
                                     signingPublicKey: answer.signingPublicKey, userId: userId)
    }

    /// The circle's name to send with an invitation: only when the lookup
    /// answered that the address has NO account (`userId` nil, after
    /// `canonicalLookup`). Any account, with keys or without, gets none.
    nonisolated static func circleNameForInvitation(lookupUserId: String?, name: String?) -> String? {
        lookupUserId == nil ? name : nil
    }

    /// Whether an invitee's looked-up keys differ from what this device pinned
    /// for them (this circle's pin, else their identity pin) — either key.
    nonisolated static func inviteeKeysChanged(sharing: String, signing: String,
                                               pinned: (sharing: String?, signing: String?)) -> Bool {
        let sharingChanged = pinned.sharing.map { $0.caseInsensitiveCompare(sharing) != .orderedSame } ?? false
        let signingChanged = pinned.signing.map { $0.caseInsensitiveCompare(signing) != .orderedSame } ?? false
        return sharingChanged || signingChanged
    }

    /// "It's them" about an invitee whose account changed: THIS device takes
    /// their new details (no statement about it; other devices ask their own
    /// users), then invites them as usual — signing the keys just confirmed,
    /// and only those, for that account only. The details are taken once the
    /// address check has answered (`inviteMember`), never before: an answer
    /// kept waiting pins nothing.
    func confirmInviteeAndInvite(_ change: InviteeChange) async throws {
        // Behind: the answer waits with the invitation, for exactly these keys,
        // and nothing is taken now; if their keys differ again when it runs, it
        // is dropped.
        guard holdsCurrentKey(for: change.circleId) else {
            let kept = Self.keptInvitation(email: change.email, confirmed: change)
            try PendingChanges.queue(.invite, circleId: change.circleId, inputs: kept.inputs, seen: kept.seen,
                                     subject: change.email.lowercased())
            return
        }
        try await inviteMember(to: change.circleId, email: change.email, confirmed: change)
    }

    /// Remove somebody else from a circle.
    ///
    /// Goes through `eject-and-rotate`, which drops them from the roster AND
    /// re-keys the circle for the survivors in one server-side transaction.
    /// Not the plain `DELETE /members/:user_id`, which the server answers
    /// with 410 Gone: a delete that is not atomic with the rotation leaves a
    /// window in which the ejected member is off the roster but still holds a
    /// live circle key.
    ///
    /// Rotating on its own is NOT a fallback. `/rotate-keys` demands a wrap for
    /// every active member, so it would re-seal the fresh key to the very
    /// person being removed.
    ///
    /// THROWS RATHER THAN RETURNING QUIETLY. Every guard here means the member
    /// is still in the circle and still receiving locations, so the caller has
    /// to be able to say so — this is the path somebody uses to get an ex or a
    /// stalker out, and a silent failure is the worst possible outcome.
    func removeMember(from circleId: String, userId: String) async throws {
        // Nobody is removed from the personal key's slot: no new key.
        guard !CanonicalId.isPersonalSlot(circleId) else { throw CircleError.memberNotFound }
        guard let circle = circles.first(where: { $0.id == circleId }) else {
            throw CircleError.memberNotFound
        }
        guard let senderUserId = AuthManager.shared.userId else {
            throw CircleError.ejectFailed("Not signed in")
        }
        guard userId != senderUserId else {
            // The server refuses this too; catching it here gives a better
            // message than "cannot eject yourself".
            throw CircleError.ejectFailed("Use Leave Circle to remove yourself")
        }

        // The new key seals the circle NAME as well, so a device that cannot
        // read the current name cannot rotate without overwriting it with a
        // placeholder for everybody. Refuse loudly instead, except for an
        // owner's or admin's eject from below, which then sends no name
        // (`nameToSeal`).
        if circle.isLocked && !ejectsFromBelow(circle) {
            // What is true, with no "try again" and no promise.
            throw CircleError.ejectFailed(CircleError.notDoneWhileWaitingToSync)
        }

        // Same plan as the automatic rotation, with the person being removed
        // taken out first. The TOFU send-side gate still refuses to wrap the
        // fresh key to a survivor whose server-supplied key does not match our
        // pin — but that survivor is now left PENDING (no new key) instead of
        // stopping the removal: an unrelated member's key change must never be
        // what keeps someone who is being removed inside the circle. Hidden
        // members and unapproved newcomers are pending too.
        let (plan, keysById, blocked) = try await planRotation(
            for: circle, rotatorUserId: senderUserId, ejecting: userId
        )
        let survivors = plan.wrap.compactMap { keysById[$0] }
        guard !survivors.isEmpty else {
            throw CircleError.ejectFailed("Cannot remove the only member")
        }

        // With refresh records the eject carries its record, naming
        // them removed (and a circle without records gets its
        // transition, its first record, with it); its records not
        // imported yet, or forked: not now. The repair entry is read
        // once, for the mode, the name and the build.
        let due = repairsDue[CanonicalId.key(circleId)]
        var mode = rotationMode(for: circle, due: due)
        if mode == .transition, transitionRefused(circleId) { mode = .legacy }
        switch mode {
        case .wait:
            throw CircleError.ejectFailed(CircleError.notDoneWhileWaitingToSync)
        case .transition, .recorded:
            // Not while the SDK doesn't count this account's own row
            // (after its password reset, until its own admission is
            // served).
            guard keyChangesMayBuild(circle) else {
                throw CircleError.ejectFailed(CircleError.notDoneWhileWaitingToSync)
            }
            let change: RecordedChange
            do {
                change = try prepareRecordedChange(circle, me: senderUserId, mode: mode, due: due, decision: plan,
                                                   blocked: blocked, ejecting: userId)
            } catch let refusal as MobileError {
                guard mode == .transition else {
                    // The SDK's own words stay in the log
                    // (never on screen). Its "not yet" is
                    // no failure, as the answer says: this
                    // iPhone is waiting to sync.
                    if RecordedRotation.notYet(refusal) {
                        Self.keyLog.info("circle \(circleId, privacy: .public): the removal's record waits for an import of its records")
                    } else {
                        Self.keyLog.error("circle \(circleId, privacy: .public): the removal's record was refused: \(String(describing: refusal), privacy: .public)")
                    }
                    throw CircleError.ejectFailed(CircleError.notDoneWhileWaitingToSync)
                }
                // Its first record can't be written for this
                // list: the removal goes the legacy way, with
                // no record, and the circle stays without
                // records.
                noteTransitionRefused(circleId, refusal)
                break
            }
            try await sendRecordedEject(circle, userId: userId, me: senderUserId, change: change)
            members[circleId]?.removeAll { $0.userId == userId }
            rosters[circleId]?.removeAll { $0.userId == userId }
            try await loadCircles()
            return
        case .legacy:
            break
        }

        // The name only from the key in use, else none: the server keeps it.
        let sealable = sealableName(circle)
        let bundle = try cryptoManager.prepareKeyRotation(
            circleId: circleId,
            senderUserId: senderUserId,
            memberUserIds: survivors.map { $0.userId },
            memberPublicKeysHex: survivors.map { $0.sharingPublicKey },
            memberSigningPubkeysHex: survivors.map { $0.signingPublicKey ?? "" },
            currentCircleNamePlaintext: sealable ?? ""
        )

        // Carry the two things that keep pre-rotation ciphertext readable: the
        // name re-sealed under the new key, and the outgoing key sealed under
        // it. Without the chain link every holder of only the latest key — the
        // web, a fresh install, a later joiner — is permanently locked out of
        // everything written before this eject.
        let chainLink: KeyChainLinkRequest? = bundle.keyChainLink.map { link in
            KeyChainLinkRequest(
                fromVersion: Int(link.fromVersion),
                toVersion: Int(link.toVersion),
                encryptedKey: link.encryptedKey,
                nonce: link.nonce
            )
        }
        if chainLink == nil {
            print("[Track] removeMember: no key chain link for \(circleId) — pre-rotation data will not be readable by key-only holders")
        }

        let response: EjectAndRotateResponse
        do {
            response = try await api.ejectAndRotate(
                circleId: circleId,
                request: EjectAndRotateRequest(
                    ejectUserId: userId,
                    newKeyVersion: Int(bundle.newKeyVersion),
                    memberWraps: bundle.memberKeys.map { entry in
                        EjectMemberWrapRequest(
                            userId: entry.userId,
                            encryptedCircleKey: entry.bundle.encryptedCircleKey.ciphertext,
                            circleKeyNonce: entry.bundle.encryptedCircleKey.nonce,
                            ephemeralPublicKey: entry.bundle.ephemeralPublicKey,
                            wrapSignature: entry.bundle.wrapSignature.isEmpty ? nil : entry.bundle.wrapSignature
                        )
                    },
                    encryptedName: Self.legacyEncryptedName(sealable: sealable, sealed: bundle.encryptedName),
                    keyChainLink: chainLink,
                    pendingMembers: plan.pending.isEmpty ? nil : plan.pending.sorted()
                )
            )
        } catch {
            // The server did not take our new key. `prepareKeyRotation` already
            // made it this device's active version; left there, every location
            // sent from now on is sealed under a key nobody else holds. If the
            // server DID take it, the next import brings the same key back.
            _ = cryptoManager.discardUnconfirmedRotation(circleId: circleId)
            throw error
        }

        members[circleId]?.removeAll { $0.userId == userId }
        rosters[circleId]?.removeAll { $0.userId == userId }
        print("[Track] removeMember: ejected from \(circleId), key v\(response.newKeyVersion)")
        // Re-read so the new key version and re-sealed name land locally rather
        // than being inferred.
        try await loadCircles()
    }

    /// Whether removing a member from this circle happens at once without a
    /// new key: this iPhone is behind in it, so it can't make the circle's
    /// next key. Never queued: the person loses the circle now, and the
    /// circle's refresh follows from a member who holds the current version.
    /// The next roster pass records the departure here as for any other
    /// (tombstone, dead statement ids, retired pins).
    func removesWithoutNewKey(_ circleId: String) -> Bool {
        guard let circle = circles.first(where: { $0.id == circleId }) else { return false }
        // Nor while its records wait (not imported here yet, withheld or
        // forked): the next record can't be made then either. An owner's
        // or admin's eject from below does make one (`ejectsFromBelow`).
        if standing(of: circleId) == .recorded, !removesInTheChain(circleId) { return true }
        return (circle.isLocked || !holdsCurrentVersion(for: circleId) || standing(of: circleId) == .wait)
            && !ejectsFromBelow(circle)
    }

    /// Remove somebody WITHOUT re-keying the circle — only after
    /// `removeMember(from:userId:)` has thrown.
    ///
    /// The strong removal re-keys, and it needs a fresh key for every remaining
    /// member; a survivor whose key changed without being verified makes that
    /// impossible, and this is the way to remove somebody in that state. This
    /// is the weaker tool by design: they lose the circle now, but the key they
    /// hold is unchanged, so anything they already downloaded stays readable to
    /// them.
    ///
    /// Returns the server's warning for the caller to display verbatim. Nil
    /// from an older server, and nil must stay nil — writing our own
    /// reassurance here is how somebody comes to believe a removal reached
    /// backwards.
    @discardableResult
    func revokeMemberAccess(from circleId: String, userId: String) async throws -> String? {
        let removedName = rosters[circleId]?.first(where: { $0.userId == userId })?.displayName
        let response = try await api.revokeMemberAccess(circleId: circleId, userId: userId)
        // Removal while behind: this device names them removed in its own
        // next record, whatever the server's flag says. Not on a circle
        // without records: its first record never names them.
        if let me = AuthManager.shared.userId, standing(of: circleId) != .noRecords {
            RefreshLedger.shared.noteRemoval(account: me, circleId: circleId, userId: userId, at: Date())
        }
        if let removedName { pendingRemovalNames[circleId] = removedName }
        members[circleId]?.removeAll { $0.userId == userId }
        rosters[circleId]?.removeAll { $0.userId == userId }
        print("[Track] revokeMemberAccess: removed \(userId) from \(circleId) WITHOUT rotating")
        // Re-read so the circle's pending-rotation flag lands locally rather
        // than being assumed.
        try await loadCircles()
        return response.warning
    }

    /// `keys`: for a promotion to admin, the keys the person decided on — the
    /// ones this device holds for the member, and the number shown was worked
    /// out from (`promotionKeys`).
    ///
    /// While this iPhone is behind in the circle a promotion waits for exactly
    /// the keys decided on. `waiting`: the waiting change being run now: its
    /// admission's id is saved before it goes out, and one the server already
    /// holds is not signed again; then the role.
    func updateMemberRole(in circleId: String, userId: String, role: CircleMember.MemberRole,
                          keys: MemberKeyPair? = nil, waiting: PendingChange? = nil) async throws {
        // The chain's owner writes its person's role change in a record,
        // rotating right away (or at its next rotation if it can't now).
        // Nobody else's device copies a role from the list, so what that
        // record owes must not be lost (`RoleRecord`): nothing is signed
        // or sent while the ledger can't be read. Nor while the circle's
        // records wait: whether a record is owed isn't known yet there,
        // and a queued promotion waits (`roleChangesTakeEffect`).
        guard standing(of: circleId) != .wait else { throw CircleError.waitingToSync }
        let me = AuthManager.shared.userId
        let record = Self.roleRecord(chainOwner: writesRoleRecords(circleId), role: role)
        if record != .notOwed {
            guard let me, RefreshLedger.shared.isReadable(account: me) else { throw CircleError.roleChangeNotKept }
        }
        // A new admin invites and admits others, so every app must be able to
        // rely on their signing key: an admission — which also lifts a
        // receive-only (kind-2) member. It carries this device's version,
        // so not while behind.
        if role == .admin {
            guard AuthManager.shared.userId != nil else { throw CircleError.memberNotFound }
            // The admission signs ONLY the keys this device holds for
            // them (a receive-only member's record, else the pin), the
            // ones the person decided on — and nothing when the member
            // list shows others now: a server swapping them never gets
            // them signed.
            let listed = membershipCandidates[circleId]?[userId].flatMap { candidate in
                candidate.sharingKeyHex.flatMap { sharing in
                    candidate.signingKeyHex.map { MemberKeyPair(sharingKeyHex: sharing, signingKeyHex: $0) }
                }
            }
            guard let signed = Self.promotionAdmissionKeys(held: promotionKeys(for: userId, in: circleId),
                                                           listed: listed, decided: keys) else {
                throw CircleError.promotionDetailsChanged
            }
            guard holdsCurrentKey(for: circleId) else {
                guard waiting == nil else { throw CircleError.waitingToSync }
                try PendingChanges.queue(
                    .makeAdmin, circleId: circleId, inputs: .makeAdmin(memberId: userId), seen: .init(keys: signed),
                    subject: members[circleId]?.first { $0.userId == userId }?.displayName)
                return
            }
            if let waiting {
                if waiting.heldStatementId == nil {
                    try await admitWaiting(waiting, userId: userId, circleId: circleId, keys: signed)
                }
            } else {
                // The admission is stored BEFORE the role changes: never an
                // admin whom no other app can confirm. A person's tap bounds
                // its retries, so a failure is said and nothing is owed.
                guard await admit(userId: userId, circleId: circleId,
                                  sharingKeyHex: signed.sharingKeyHex, signingKeyHex: signed.signingKeyHex) else {
                    throw CircleError.promotionNotDone
                }
            }
        }
        // A demotion is owed before the server hears of it; the ledger not
        // taking it sends nothing.
        var owedBefore: String??
        if record == .owedFirst, let me {
            let before = RefreshLedger.shared.circle(account: me, circleId: circleId).roleChanges[CanonicalId.key(userId)]
            guard RefreshLedger.shared.update(account: me, circleId: circleId, {
                $0.roleChanges[CanonicalId.key(userId)] = role.rawValue
            }) else { throw CircleError.roleChangeNotKept }
            owedBefore = .some(before)
        }
        do {
            _ = try await api.updateMemberRole(circleId: circleId, userId: userId, role: role.rawValue)
        } catch {
            // Refused: the demotion isn't owed. A take-back the file can't take
            // is kept for this session; lost to a relaunch, the record demotes
            // someone the server didn't, which is the safe direction.
            if let me, case .some(let before) = owedBefore {
                RefreshLedger.shared.noteRoleChange(account: me, circleId: circleId, userId: userId, role: before)
            }
            throw error
        }
        if let index = members[circleId]?.firstIndex(where: { $0.userId == userId }) {
            members[circleId]?[index].role = role
        }
        if let index = rosters[circleId]?.firstIndex(where: { $0.userId == userId }) {
            rosters[circleId]?[index].role = role
        }
        if record != .notOwed, let me {
            // A promotion is owed once the server took it, and kept for this
            // session when the file can't take it.
            if record == .owedAfter {
                RefreshLedger.shared.noteRoleChange(account: me, circleId: circleId, userId: userId, role: role.rawValue)
            }
            rotateOwedNow(circleId)
        }
    }

    /// How a role change is owed to the circle's records. Roles reach the other
    /// apps only through the chain owner's record, and one the record misses
    /// fails the way it went:
    /// - a lost promotion fails safe (nobody's app honours the new admin), so
    ///   it is owed once the server took it;
    /// - a lost demotion fails unsafe: every other app would go on honouring
    ///   an admin the owner removed. So it is owed BEFORE the server hears of
    ///   it, and taken back if the server refuses.
    /// Nothing is owed on a circle without records (its first record takes the
    /// list's roles), or by an account that isn't the chain's owner, where the
    /// change isn't offered (`roleChangesTakeEffect`).
    enum RoleRecord: Equatable {
        case notOwed
        case owedFirst
        case owedAfter
    }

    nonisolated static func roleRecord(chainOwner: Bool, role: CircleMember.MemberRole) -> RoleRecord {
        guard chainOwner else { return .notOwed }
        return role == .admin ? .owedAfter : .owedFirst
    }

    /// Whether this account writes the role changes in `circleId`'s records:
    /// the chain's owner.
    private func writesRoleRecords(_ circleId: String) -> Bool {
        guard let me = AuthManager.shared.userId else { return false }
        return cryptoManager.circleHasRefreshRecords(circleId: circleId)
            && cryptoManager.chainRole(circleId: circleId, userId: me) == .owner
    }

    /// Whether a role this account changes in `circleId` takes effect where it
    /// counts (as the Android app's `roleChangesTakeEffect` decides it). On a
    /// circle without refresh records the first record takes the list's roles.
    /// On one with records only a record of the chain's owner changes a role,
    /// so after an ownership claim the claimant's app doesn't offer role
    /// changes as if they would take effect: every other app would go on as
    /// before. Nor while the circle's records wait (not imported in this
    /// process yet, withheld or forked): on a fresh install the SDK doesn't
    /// know yet that the circle has records, and a change would go to the
    /// server alone.
    func roleChangesTakeEffect(_ circleId: String) -> Bool {
        Self.roleChangesTakeEffect(standing: standing(of: circleId), chainOwner: writesRoleRecords(circleId))
    }

    nonisolated static func roleChangesTakeEffect(standing: RecordsStanding, chainOwner: Bool) -> Bool {
        switch standing {
        case .noRecords: return true
        case .recorded: return chainOwner
        case .wait: return false
        }
    }

    // MARK: - Hand-over

    /// Where a hand-over the person asked for stands.
    enum HandOverOutcome: Equatable {
        /// The circle reads back as the other member's.
        case done
        /// Sent, and not read back as theirs yet: it finishes by itself, at a
        /// later load of the circle list (`finishHandOvers`).
        case pending
    }

    /// Which way a hand-over goes (as the web and Android do it):
    /// - `serverOnly`: the server's transfer alone, on a circle without records
    ///   (its first record takes the list's roles), and on one whose records'
    ///   owner is someone else (a claimant's: the records keep their owner,
    ///   frozen and safe);
    /// - `record`: a record first, where this account is the records' owner;
    /// - `notNow`: nothing, while the circle's records wait (not imported in
    ///   this process yet, withheld or forked).
    enum HandOverPath: Equatable {
        case serverOnly
        case record
        case notNow
    }

    nonisolated static func handOverPath(standing: RecordsStanding, myChainRole: CircleRole?) -> HandOverPath {
        switch standing {
        case .noRecords: return .serverOnly
        case .recorded: return myChainRole == .owner ? .record : .serverOnly
        case .wait: return .notNow
        }
    }

    /// Hand `circleId` to `target`, another member, as its owner; this
    /// account stays as a member (the server makes it one). `keys`: their keys
    /// as this device held them at the tap (`promotionKeys`), the only ones a
    /// record may name owner, and only while the member list shows exactly
    /// those.
    func handOver(_ circleId: String, to target: String, keys: MemberKeyPair?) async throws -> HandOverOutcome {
        // Never for the personal key's slot, whatever put it in `circles`.
        guard !CanonicalId.isPersonalSlot(circleId) else { throw CircleError.memberNotFound }
        guard let me = AuthManager.shared.userId, !CanonicalId.same(me, target),
              let circle = circles.first(where: { CanonicalId.sameKey($0.id, circleId) }), circle.isOwner
        else { throw CircleError.notOwner }
        switch Self.handOverPath(standing: standing(of: circle.id),
                                 myChainRole: cryptoManager.chainRole(circleId: circle.id, userId: me)) {
        case .notNow:
            throw CircleError.handOverNotNow
        case .serverOnly:
            _ = try await api.transferOwnership(circleId: circle.id, newOwnerId: target)
            try? await loadCircles()
            return .done
        case .record:
            guard let held = promotionKeys(for: target, in: circle.id),
                  Self.promotionAdmissionKeys(held: held, listed: listedKeys(for: target, in: circle.id),
                                              decided: keys) != nil
            else { throw CircleError.handOverDetailsChanged }
            return try await handOverWithRecord(circle, me: me, RefreshLedger.HandOver(
                target: CanonicalId.key(target), sharingKeyHex: held.sharingKeyHex, signingKeyHex: held.signingKeyHex))
        }
    }

    /// The owner's hand-over as a record first. Nothing is built or sent unless
    /// every precondition of a rotation holds: no other change of the circle
    /// under way here, its records imported and not forked, no repair due, the
    /// current version held, the name not held back, nothing waiting for an
    /// import, this account's own admission served. The record names that
    /// member owner and this account member (`prepareRecordedChange`), and goes
    /// as rotate-keys with `transfer_to`, so the server moves the ownership in
    /// the rotation's own transaction or not at all. It is kept in the ledger
    /// from before the send until the circle reads back theirs.
    /// Throws when nothing was sent. Once sent: a refusal for good ends it
    /// (`handOverNotNow`); any other failure leaves it kept (`.pending`).
    private func handOverWithRecord(_ circle: Circle, me: String,
                                    _ handOver: RefreshLedger.HandOver) async throws -> HandOverOutcome {
        guard !CanonicalId.isPersonalSlot(circle.id) else { throw CircleError.memberNotFound }
        // One per circle: a kept hand-over to another member starts nothing.
        if let kept = RefreshLedger.shared.circle(account: me, circleId: circle.id).handOver,
           !CanonicalId.same(kept.target, handOver.target) {
            throw CircleError.handOverNotNow
        }
        let due = repairsDue[CanonicalId.key(circle.id)]
        guard !rotationsInFlight.contains(circle.id), rotationMode(for: circle, due: due) == .recorded(.rotation),
              !nameHoldsBack(circle, due: due), holdsWhatItRotates(circle), !changesAwaitingImport.waits(circle.id),
              keyChangesMayBuild(circle)
        else { throw CircleError.handOverNotNow }
        rotationsInFlight.insert(circle.id)
        defer { rotationsInFlight.remove(circle.id) }
        // A rotation leaves this account's sealed name under the older key:
        // sealed again once the key moved on, as after any rotation.
        let versionBefore = try? cryptoManager.getActiveVersion(circleId: circle.id)
        defer {
            if Self.versionAdvanced(from: versionBefore, to: try? cryptoManager.getActiveVersion(circleId: circle.id)) {
                Task { await self.sealOwnName(circleId: circle.id) }
            }
        }
        let (plan, _, blocked) = try await planRotation(for: circle, rotatorUserId: me)
        let change: RecordedChange
        do {
            change = try prepareRecordedChange(circle, me: me, mode: .recorded(.rotation), due: nil, decision: plan,
                                               blocked: blocked, handOver: handOver)
        } catch let refusal where RecordedRotation.notYet(refusal) {
            throw CircleError.handOverNotNow
        }
        // Kept before it is sent, and only once the ledger wrote it.
        // Otherwise nothing is sent.
        guard RefreshLedger.shared.noteHandOver(account: me, circleId: circle.id, handOver) else {
            _ = cryptoManager.discardUnconfirmedRotation(circleId: circle.id)
            throw CircleError.handOverNotNow
        }
        do {
            try await sendRecordedRotation(circle, me: me, change: change)
        } catch {
            guard Self.handOverRefusedForGood(error) else { return .pending }
            RefreshLedger.shared.clearHandOver(account: me, circleId: circle.id)
            throw CircleError.handOverNotNow
        }
        try? await loadCircles()
        return circles.first(where: { CanonicalId.sameKey($0.id, circle.id) })?.isOwner == false ? .done : .pending
    }

    /// A refusal of a hand-over that no later attempt gets past: the member
    /// gone, not this account's circle, the ownership moved, the circle gone
    /// (400, 403, 404, 409). A refusal of the record itself (invalid, stale,
    /// required) is answered by building it again.
    nonisolated static func handOverRefusedForGood(_ error: Error) -> Bool {
        guard let api = error as? APIError else { return false }
        if let code = api.errorCode,
           ["key_refresh_record_invalid", "key_refresh_record_stale", "key_refresh_record_required"].contains(code) {
            return false
        }
        return ["http_400", "http_403", "http_404", "http_409"].contains(api.code)
    }

    /// What a kept hand-over does next, from the circle's owner as the server
    /// lists it.
    enum HandOverStep: Equatable {
        /// Its owner is the member it names: done.
        case done
        /// Another owner now (a claim completed, another hand-over): it stops.
        case moved
        /// Still this account's, and the records name the member owner: the
        /// record landed and the transfer didn't (a server that ignores
        /// `transfer_to`). The server's transfer.
        case transferOnServer
        /// Still this account's, and the records don't name them: built again
        /// on the current head, every precondition checked again. Never the
        /// server's transfer then: it would leave the records frozen to this
        /// account with someone else the server's owner.
        case rebuild
        /// The owner can't be read: nothing now.
        case wait
    }

    nonisolated static func handOverStep(serverOwner: String?, me: String, target: String,
                                         recordsNameTarget: Bool) -> HandOverStep {
        guard CanonicalId.of(serverOwner) != nil else { return .wait }
        if CanonicalId.same(serverOwner, target) { return .done }
        if !CanonicalId.same(serverOwner, me) { return .moved }
        return recordsNameTarget ? .transferOnServer : .rebuild
    }

    /// Whether the finish below is running: one pass at a time, and a load it
    /// causes starts none.
    private var finishingHandOvers = false

    /// The hand-overs this device keeps, each against its circle as the server
    /// just listed it: at every load of the list.
    private func finishHandOvers(listed: [CircleResponse], whole: Bool) {
        guard !finishingHandOvers, let me = AuthManager.shared.userId else { return }
        let kept = RefreshLedger.shared.handOvers(account: me)
        guard !kept.isEmpty else { return }
        finishingHandOvers = true
        Task { [weak self] in
            guard let self else { return }
            for (circleKey, handOver) in kept.sorted(by: { $0.key < $1.key }) {
                await self.finishHandOver(circleKey, handOver, whole: whole, me: me,
                                          row: listed.first { CanonicalId.sameKey($0.id, circleKey) })
            }
            self.finishingHandOvers = false
        }
    }

    private func finishHandOver(_ circleKey: String, _ handOver: RefreshLedger.HandOver, whole: Bool, me: String,
                                row: CircleResponse?) async {
        // Another account signed in meanwhile: not its to finish.
        guard CanonicalId.same(AuthManager.shared.userId, me) else { return }
        guard let row else {
            // Not on a whole list: deleted, or this account isn't in it any more.
            if whole { RefreshLedger.shared.clearHandOver(account: me, circleId: circleKey) }
            return
        }
        let recordsNameTarget = cryptoManager.chainRole(circleId: row.id, userId: handOver.target) == .owner
        switch Self.handOverStep(serverOwner: row.ownerId, me: me, target: handOver.target,
                                 recordsNameTarget: recordsNameTarget) {
        case .done, .moved:
            RefreshLedger.shared.clearHandOver(account: me, circleId: row.id)
        case .transferOnServer:
            do {
                _ = try await api.transferOwnership(circleId: row.id, newOwnerId: handOver.target)
                RefreshLedger.shared.clearHandOver(account: me, circleId: row.id)
                try? await loadCircles()
            } catch let error where Self.handOverRefusedForGood(error) {
                RefreshLedger.shared.clearHandOver(account: me, circleId: row.id)
            } catch {
                // No answer: the next load tries again.
            }
        case .rebuild:
            guard let circle = circles.first(where: { CanonicalId.sameKey($0.id, row.id) }) else { return }
            do {
                _ = try await handOverWithRecord(circle, me: me, handOver)
            } catch CircleError.handOverDetailsChanged {
                // They left, or their keys changed since the person decided:
                // nothing is handed to keys nobody chose.
                RefreshLedger.shared.clearHandOver(account: me, circleId: row.id)
            } catch {
                // Not now (or the send's refusal for good, which ended it).
            }
        case .wait:
            break
        }
    }

    /// Level-triggered on EVERY roster read, so an update also clears what an
    /// older build kept. A member whose location history this circle isn't
    /// shown keeps only their newest position on this phone (all
    /// `memberLocations` and `frozenLocations` hold); one with both switches off
    /// is drawn nowhere, so that goes too. The addresses of where they were go
    /// with them. Notifications already received are no history, and stay.
    private func purgeForSharing(circleId: String, now: Date = Date()) {
        let me = AuthManager.shared.userId
        var locations = memberLocations
        var frozen = frozenLocations
        for member in members[circleId] ?? [] where !member.sharesHistory && !CanonicalId.same(member.userId, me) {
            let drawnNowhere = member.sharing(at: now) == .off
            if drawnNowhere {
                if locations[member.userId]?.circleId == circleId { locations.removeValue(forKey: member.userId) }
                if frozen[member.userId]?.circleId == circleId { frozen.removeValue(forKey: member.userId) }
                rowsByCircle.forget(circleId: circleId, userId: member.userId)
                approximateAreas.forget(circleId: circleId, userId: member.userId)
            }
            let newest = locations[member.userId] ?? frozen[member.userId]
            MemberAddressStore.shared.keepOnly(userId: member.userId,
                                               keeping: newest.map { (latitude: $0.latitude, longitude: $0.longitude) })
        }
        if locations != memberLocations { memberLocations = locations }
        if frozen != frozenLocations { frozenLocations = frozen }
    }

    /// A circle this account is in no more, by the server's word: what is
    /// open of it is told first (`circleGone`), then it goes as on a leave,
    /// keeping its keys (`pruneLocalCircle`), with what was kept for it.
    private func pruneGoneCircle(_ circleId: String) {
        circleGone.send(circleId)
        pruneLocalCircle(circleId: circleId)
        PendingCircleLocations.shared.discard(circleId: circleId)
        // Its alerts and destinations are drawn across circles: they go too.
        SOSManager.shared.forgetCircle(circleId)
        Task { await DestinationsManager.shared.forgetCircle(circleId) }
        // And what this phone last sent there, kept for a re-seal: it holds a
        // point.
        OwnLastSentStore.shared.forget(circleId: circleId)
    }

    /// Pure: the circles a list says this account is in no more: those the
    /// last list had and this one lacks, by their one form. Only a WHOLE list
    /// the server gives now says so: one with more pages can skip a circle (a
    /// reorder between page reads), and the saved copy says nothing of now.
    /// Never the personal history's slot: it is no circle.
    nonisolated static func circlesGone(before: [String], listed: Set<String>, whole: Bool, now: Bool) -> [String] {
        guard whole, now else { return [] }
        return before.filter { !CanonicalId.isPersonalSlot($0) && !listed.contains(CanonicalId.key($0)) }
    }

    /// Drop a circle from local state because the server says we're
    /// no longer in it: this account left, a roster refused us (404 / 403 /
    /// "not a member") and a WHOLE circle list confirms it
    /// (`rosterRefusalPrunes`), or a WHOLE list no longer has it
    /// (`circlesGone`). Mirrors the Android app's `deleteLocalCircle` — removes
    /// the row, scoped members and locations, and the keychain's mirror of the
    /// circle's wrapped key (`circle_key_<id>`, which nothing reads). The SDK
    /// keeps its keys: only a leave or a delete forgets them
    /// (`forgetCircleKeys`).
    /// The late points kept for it are its callers' to discard: a leave, a
    /// confirmed refusal, a delete, or a WHOLE list without the circle
    /// (`keptPointsToDiscard`).
    private func pruneLocalCircle(circleId: String) {
        changesAwaitingImport.end(circleId)
        circles.removeAll { $0.id == circleId }
        members.removeValue(forKey: circleId)
        rosters.removeValue(forKey: circleId)
        openedNames.removeValue(forKey: circleId)
        memberLocations = memberLocations.filter { _, loc in loc.circleId != circleId }
        frozenLocations = frozenLocations.filter { _, loc in loc.circleId != circleId }
        frozenGrace.forget(circleId: circleId)
        // Drop this circle's replay/reorder guard entries in step with the
        // locations we just removed (guard is keyed "circleId:userId"), so a
        // member removed with the circle leaves no stale last-accepted
        // timestamp behind that could wrongly drop a legitimate fresh update
        // if they are later re-added.
        lastAcceptedLocationTs = lastAcceptedLocationTs.filter { key, _ in !key.hasPrefix("\(CanonicalId.key(circleId)):") }
        rowsByCircle.forget(circleId: circleId)
        privacySettings.removeValue(forKey: circleId)
        keychain.deleteCircleKey(for: circleId)
        if activeCircle?.id == circleId {
            activeCircle = circles.first
        }
    }

    /// Pure: a roster's refusal (404, 403, "not a member") prunes only a
    /// circle a WHOLE list the server gives now no longer has (as the Android
    /// app's `isStillAMember`). The members route gives one off a replica that
    /// lags or fails; still listed, or no whole list to ask (`nil`), decides
    /// nothing.
    nonisolated static func rosterRefusalPrunes(listed: Bool?) -> Bool {
        listed == false
    }

    /// Whether a WHOLE circle list the server gives now has the circle, by its
    /// one form; nil when none can be read whole (no answer, or more pages).
    private func wholeListHas(_ circleId: String) async -> Bool? {
        guard let list = try? await api.getCircleList(), list.whole else { return nil }
        return list.circles.contains { CanonicalId.sameKey($0.id, circleId) }
    }

    /// Pure: the circles whose kept late points go, against a WHOLE circle
    /// list: those it no longer has (left, removed or deleted), by their one
    /// form. Never the personal history's: it is no circle, and no list has it.
    nonisolated static func keptPointsToDiscard(kept: [String], listed: Set<String>) -> [String] {
        kept.filter { !CanonicalId.isPersonalSlot($0) && !listed.contains(CanonicalId.key($0)) }
    }

    /// Is this device allowed to rotate `circle`'s key?
    ///
    /// The server gates rotation on the per-member `can_rotate_keys` right, NOT
    /// on ownership: it is grantable precisely so a dormant owner cannot block
    /// rotation after somebody is removed, and a promotion to admin grants it.
    /// Testing `circle.isOwner` instead would leave a promoted admin never
    /// rotating, with the flag set until the owner happened to open the app —
    /// after a leave or a revoke, that leaves the departed member's key current
    /// for exactly that long.
    ///
    /// Falls back to ownership when our own roster row has not loaded, because
    /// the sweep that calls this runs EARLIER IN loadCircles than the
    /// loadMembers fan-out — on a cold launch `members` is still empty here.
    /// Owners always hold the bit server-side, so the fallback never grants more
    /// than the server would. Same cold-cache fallback as the Android app's
    /// `canRotateKeysCache[circleId] ?: circle.isOwner`.
    func mayRotate(_ circle: Circle) -> Bool {
        let me = AuthManager.shared.userId
        let mine = me.flatMap { id in members[circle.id]?.first(where: { $0.userId == id }) }
        return Self.mayRotate(isOwner: circle.isOwner, myMemberRow: mine)
    }

    /// Owners and admins are the ones told about pending re-keys and withheld
    /// keys: they are the people who can act on them. Ownership from the
    /// circle row; admin from our own roster row once it has loaded.
    func isOwnerOrAdmin(_ circle: Circle) -> Bool {
        if circle.isOwner { return true }
        guard let me = AuthManager.shared.userId,
              let mine = members[circle.id]?.first(where: { $0.userId == me }) else { return false }
        return mine.role == .owner || mine.role == .admin
    }

    /// Whether this device performs a planned refresh: an owner's or admin's
    /// device always (pending members and all); a plain member's only when
    /// nobody would be left pending; a receive-only member's never.
    nonisolated static func mayRunRefresh(pending: Int, iAmOwnerOrAdmin: Bool, selfIsReceiveOnly: Bool) -> Bool {
        if selfIsReceiveOnly { return false }
        return iAmOwnerOrAdmin || pending == 0
    }

    /// Whether this device runs the server-flagged refresh for a circle: yes for
    /// every flagged cause but a newcomer's join, which delivery answers with no
    /// version bump — and no role check, because any member may.
    nonisolated static func performsSecurityRefresh(flagged: Bool, cause: String?) -> Bool {
        flagged && cause != "member_joined"
    }

    /// The decision itself, with no actor state, so it can be tested. `nil` row
    /// means "our roster entry has not loaded", NOT "we are ineligible" — the two
    /// answers differ and conflating them is what a plain `?? false` would do.
    nonisolated static func mayRotate(isOwner: Bool, myMemberRow: CircleMember?) -> Bool {
        guard let myMemberRow else { return isOwner }
        return myMemberRow.canRotateKeys
    }

    /// Skip a circle whose rotation failed recently.
    ///
    /// Without this a circle that fails for a durable reason — a member whose
    /// key fails the TOFU pin, say, which fails closed every time — would
    /// retry the whole rewrap on every refresh. Not the retry storm it would be
    /// under a timer (nothing polls loadCircles; it runs on login, tab appear,
    /// pull-to-refresh and pushes), but it is still a full ECDH fan-out per
    /// refresh for something that will not succeed. 5 minutes matches the
    /// Android app's ROTATION_BACKOFF_MS. A rate limit's 429 is tried again
    /// sooner (`rotationRetryDelay`).
    func inRotationBackoff(_ circleId: String) -> Bool {
        guard let retryAt = rotationRetryAt[circleId] else { return false }
        return Date() < retryAt
    }

    private func recordRotationFailure(_ circleId: String, _ error: Error) {
        rotationRetryAt[circleId] = Date().addingTimeInterval(
            Self.rotationRetryDelay(after: error, jitter: .random(in: 0...5)))
    }

    /// Pure: how long after a failed rotation it may be tried again. A 429 (the
    /// server's per-circle rotation interval, or any rate limit): its
    /// Retry-After within `rotationRetryAfterBounds`, else
    /// `rotationRateLimitRetry`, plus the jitter. Anything else:
    /// `rotationBackoff`.
    nonisolated static func rotationRetryDelay(after error: Error, jitter: TimeInterval) -> TimeInterval {
        guard let api = error as? APIError,
              [api.code, api.errorCode].compactMap({ $0 }).contains(where: {
                  $0 == "rate_limited" || $0 == "http_429" || $0 == "rate_limit_exceeded"
              }) else { return rotationBackoff }
        let asked = api.retryAfter.flatMap { $0.isFinite ? $0 : nil } ?? rotationRateLimitRetry
        return min(max(asked, rotationRetryAfterBounds.lowerBound), rotationRetryAfterBounds.upperBound) + jitter
    }

    /// The server's Retry-After is taken within these bounds: a 0 would try
    /// again at once, over and over, and a huge one would hold the circle's
    /// rotations for days.
    nonisolated static let rotationRetryAfterBounds: ClosedRange<TimeInterval> = 30...300

    private func clearRotationFailure(_ circleId: String) {
        rotationRetryAt.removeValue(forKey: circleId)
    }

    /// A rotation owed right away (the chain owner's role change), run as the
    /// sweep runs one: once at a time per circle, never while behind or in
    /// the backoff.
    private func rotateOwedNow(_ circleId: String) {
        guard !CanonicalId.isPersonalSlot(circleId) else { return }
        guard !rotationsInFlight.contains(circleId), let circle = circles.first(where: { $0.id == circleId }),
              recordedRotationDue(circle), !nameHoldsBack(circle, due: repairsDue[CanonicalId.key(circleId)]),
              holdsWhatItRotates(circle), !inRotationBackoff(circleId), !changesAwaitingImport.waits(circleId),
              keyChangesMayBuild(circle)
        else { return }
        rotationsInFlight.insert(circleId)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.rotateCircleKey(for: circleId)
                self.clearRotationFailure(circleId)
            } catch {
                print("[Track] owed rotation failed for circle \(circleId): \(error)")
                self.recordRotationFailure(circleId, error)
            }
            self.clearRotationInFlight(circleId)
        }
    }

    /// Re-read the flag after the jitter delay. Reads the in-memory model, which
    /// is what a peer's successful rotation clears on our next loadCircles —
    /// the same locality as the Android app re-reading its own DAO.
    /// A rotation needs the circle's current version, sealed under here. A
    /// repair is for a version this device holds but rejected (so it
    /// seals under an older one): it needs that version's key, which its link
    /// goes down to. One answering a MISATTRIBUTED version doesn't: it links
    /// from below at once (`holdsWhatARepairNeeds`).
    private func holdsWhatItRotates(_ circle: Circle) -> Bool {
        if case .recorded(.repair) = rotationMode(for: circle) {
            return Self.holdsWhatARepairNeeds(
                held: cryptoManager.newestHeldVersion(circleId: circle.id).map { Int($0) },
                circleKeyVersion: circle.keyVersion, answering: repairsDue[CanonicalId.key(circle.id)]?.problem)
        }
        return holdsCurrentVersion(for: circle.id)
    }

    /// Pure, for tests: whether this device holds what a repair needs. The key
    /// of the version it answers, which its link goes down to; for a version
    /// rejected as MISATTRIBUTED, any version held: nothing honest was sealed
    /// under that version's key, so the repair links from below at once, with
    /// no day's wait. The SDK picks the link within the floors and refuses a
    /// repair it can't link.
    nonisolated static func holdsWhatARepairNeeds(held: Int?, circleKeyVersion: Int, answering: RecordProblem?) -> Bool {
        guard let held else { return false }
        return answering == .misattributed || held == circleKeyVersion
    }

    private func rotationNoLongerNeeded(_ circleId: String) -> Bool {
        guard let circle = circles.first(where: { $0.id == circleId }) else { return true }
        return !circle.keyRotationNeeded && !rotationStepPending(circleId) && !recordedRotationDue(circle)
    }

    func resetReplayGuard() {
        lastAcceptedLocationTs.removeAll()
        approximateAreas.removeAll()
    }

    #if DEBUG
    /// Tests only: the locations a refresh would have published, so a view
    /// that reads them (the member row) can be rendered with a given one.
    func setMemberLocationsForTesting(_ locations: [String: LocationData]) {
        memberLocations = locations
    }
    #endif

    /// Full teardown for `AuthManager.logout()`: drop every piece of decrypted,
    /// account-scoped state so account A's circles/members/locations can't
    /// linger in memory for account B on the same device. Clears the published
    /// decrypted stores, the per-member pinned signing-pubkey directory, and
    /// the replay guard. (Keychain circle keys are wiped separately by
    /// keychain.deleteAll() in logout.)
    func reset() {
        circles = []
        circlesLoaded = false
        listedCircleIds = []
        circleListWhole = false
        circlesOfLastList = []
        activeCircle = nil
        members = [:]
        rosters = [:]
        openedNames = [:]
        membership = [:]
        membershipCandidates = [:]
        rosterWraps = [:]
        hiddenMemberCounts = [:]
        // A sign-out ends every privacy write queued or on its way: none is
        // ever sent for whoever signs in next (`privacyWrite`).
        for task in privacyWriteTasks.values { task.cancel() }
        privacyWriteTasks = [:]
        privacyWriteTail = [:]
        pendingRemovalNames = [:]
        freshCopyRequestedAt = [:]
        memberLocations = [:]
        rowsByCircle.removeAll()
        frozenLocations = [:]
        frozenGrace.clear()
        privacySettings = [:]
        // Per-(circle, member) Ed25519 signing-pubkey directory. Public-key
        // material (no confidentiality impact), but scoped to the signed-out
        // account — clear it for account-boundary hygiene so a stale entry
        // can't outlive the session.
        signingPubkeyCache.removeAll()
        sharingPubkeyCache.removeAll()
        accountHasPreResetData = nil
        preResetProbeAttemptAt = nil
        // Without this the next sign-in in this process would take the first load
        // as done, and its pre-reset data would stay locked until a restart.
        previousIdentityLoader.reset()
        incompleteRosters.removeAll()
        ownWrapSignAttempted.removeAll()
        pinsRetainedAt.removeAll()
        rotationsInFlight.removeAll()
        // The next account's circles wait for its own records import.
        recordsState.removeAll()
        recordsImportRetry.removeAll()
        keyChainsLastImport.removeAll()
        ownLinks.removeAll()
        repairsDue.removeAll()
        transitionRefusedFor.removeAll()
        changesAwaitingImport.removeAll()
        ownRows.removeAll()
        resetReplayGuard()
        // A queued upload must not outlive the account it was built for, and the
        // next account's first list must reach the disk cache.
        pendingSendRequest = nil
        lastUploadFlushAt = nil
        lastCachedCirclesData = nil
    }

    func leaveCircle(_ circleId: String) async throws {
        _ = try await api.leaveCircle(circleId: circleId)
        PendingChangeStore.shared.forgetCircle(circleId)
        // Reuse the same local cleanup as the 404/not-a-member
        // recovery path — drops the row from circles + members +
        // memberLocations (scoped to the circle) + privacySettings +
        // SDK key, and re-points activeCircle. Clearing only
        // circles + members + keychain would leave stale
        // memberLocations entries rendering on the map as the
        // "Me" marker after the user left.
        pruneLocalCircle(circleId: circleId)
        forgetCircleKeys(circleId)
        // Left, as the server just confirmed: what was kept for it goes.
        PendingCircleLocations.shared.discard(circleId: circleId)
        OwnLastSentStore.shared.forget(circleId: circleId)
    }

    /// This account left or deleted the circle, as the server just confirmed:
    /// every key this device holds for it goes, with the circle's refresh state
    /// and its secret, and any change waiting for its records. Only on the
    /// person's own leave or delete: a roster's 404 or 403 (`pruneLocalCircle`)
    /// is not "gone", and never costs the keys.
    private func forgetCircleKeys(_ circleId: String) {
        if !cryptoManager.forgetCircle(circleId: circleId) {
            Self.keyLog.info("circle \(circleId, privacy: .public): no keys held to forget")
        }
        changesAwaitingImport.end(circleId)
        ownLinks.removeValue(forKey: CanonicalId.key(circleId))
    }

    // MARK: - Privacy Settings

    /// Refresh the outstanding invites this circle has sent.
    ///
    /// SILENT on failure by design. The server allows this to owner/admin only,
    /// so a plain member viewing a circle gets a 403 every time — raising that
    /// would put an error in front of somebody looking at a perfectly healthy
    /// circle. An empty list and a hidden section is the right outcome for them,
    /// and it is indistinguishable from "no invites outstanding", which is also
    /// fine because there is nothing they could do either way.
    func refreshPendingInvites(for circleId: String) async {
        do {
            let invites = try await api.pendingInvites(circleId: circleId)
            pendingInvites[circleId] = invites
            forgetInviteesNoLongerPending(circleId: circleId, invites: invites)
        } catch {
            // Leave whatever was there rather than blanking a list that was
            // valid a moment ago on one failed refresh.
            #if DEBUG
            print("[Track] refreshPendingInvites(\(circleId)) failed: \(error)")
            #endif
        }
    }

    /// Withdraw an invite that has not been accepted yet.
    ///
    /// Drops it from the local list on success so the row disappears without
    /// waiting for a refetch. A 404 means somebody already accepted, declined or
    /// revoked it — the caller wanted it gone and it is gone, so that counts as
    /// success and the row goes too. Anything else rethrows for the view to show.
    func revokeInvite(circleId: String, inviteId: String) async throws {
        let statementId = pendingInvites[circleId]?.first { $0.id == inviteId }?.statement
            .flatMap { try? cryptoManager.parseMembershipStatement(statementHex: $0).statementId }
        var withdrawn = true
        do {
            _ = try await api.revokeInvite(circleId: circleId, inviteId: inviteId)
        } catch {
            guard Self.isInviteAlreadyGone(error) else { throw error }
            // Gone already — perhaps ACCEPTED: its id is not made dead.
            withdrawn = false
        }
        pendingInvites[circleId]?.removeAll { $0.id == inviteId }
        // Withdrawn by this device's user: the id is dead here, so a server that
        // lists the invitee with it again gets nothing.
        if withdrawn, let statementId, let me = AuthManager.shared.userId {
            KeyDeliveryApprovals.shared.withdrawInvitation(owner: me, circleId: circleId, statementId: statementId)
            InvitationRenewals.markWithdrawn(statementId, owner: me)
            // A re-invite that cleared a removal, withdrawn unused: the
            // removal is noted again.
            RefreshLedger.shared.invitationWithdrawn(account: me, circleId: circleId, statementId: statementId)
        }
    }

    /// A pending-invite list the server JUST gave (owners and admins) — never a
    /// cached one, which may predate an invitation made since: this device's
    /// invitee records whose invitation is not on it go — accepted, declined,
    /// expired, or withdrawn elsewhere. Trust is only dropped: no id is made
    /// dead, so an invitation accepted meanwhile still counts.
    func forgetInviteesNoLongerPending(circleId: String, invites: [PendingInviteResponse]) {
        guard let me = AuthManager.shared.userId else { return }
        let pending = Set(invites.compactMap { invite in
            invite.statement.flatMap { try? cryptoManager.parseMembershipStatement(statementHex: $0).statementId }
        })
        // Whoever the roster already lists keeps their record until the next
        // roster pass settles it: they may have just accepted.
        let listed = Set((rosters[circleId] ?? []).map { $0.userId })
        KeyDeliveryApprovals.shared.keepPendingInvitations(owner: me, circleId: circleId, statementIds: pending,
                                                           listedUsers: listed)
    }

    /// A 404 from revoke means "not pending any more", which is the state the
    /// caller asked for. Separated out and named so the swallow above is a
    /// decision and not a bare `try?`. Same two codes `isCircleNotFound` tests —
    /// the server answers `not_found` here for an invite that was already
    /// accepted, declined or revoked.
    static func isInviteAlreadyGone(_ error: Error) -> Bool {
        guard let api = error as? APIError else { return false }
        return api.code == "http_404" || api.code == "not_found"
    }

    /// What the server answers when this member has no privacy row in a
    /// circle yet, in its envelope.
    static let noPrivacyRow = "Privacy settings not found for this circle"

    /// Whether `error` is the server's own "no privacy row yet": a 404 carrying
    /// the server's words (`noPrivacyRow`). Only that may stand for the server's
    /// default posture, exact and sharing. Any other 404 says nothing about the
    /// posture: a proxy answering while the server restarts (`http_404`,
    /// "Request failed"), a route that isn't there, another not-found. The
    /// Android app's `NO_PRIVACY_ROW` makes the same distinction.
    static func isServersNoPrivacyRow(_ error: Error) -> Bool {
        guard let api = error as? APIError else { return false }
        return (api.code == "http_404" || api.code == "not_found") && api.message == noPrivacyRow
    }

    func loadPrivacySettings(for circleId: String) async throws {
        // Translate the backend's sharing_mode string into the iOS model's
        // bubble/paused booleans. RFC3339 paused_until parses into Date.
        let response: PrivacySettingsResponse
        do {
            response = try await api.getPrivacySettings(circleId: circleId)
        } catch {
            // A circle's privacy row is seeded best-effort on create and can be
            // absent. The server then says so (`isServersNoPrivacyRow`), and that
            // answer stands for its default posture (share on, alerts-on-me on,
            // exact location) instead of a blank privacy dialog. Mirrors
            // the Android app. Anything else is thrown, any other 404 included:
            // nothing is made up, and the send gates take the posture as unknown.
            if Self.isServersNoPrivacyRow(error) {
                privacySettings[circleId] = .default(for: circleId)
                CirclePauseRecord.shared.observe(.default(for: circleId), at: Date(), owner: AuthManager.shared.userId)
                return
            }
            throw error
        }
        privacySettings[circleId] = Self.privacySettings(from: response)
        CirclePauseRecord.shared.observe(Self.privacySettings(from: response), at: Date(), owner: AuthManager.shared.userId)
    }

    /// The one translation from the server's privacy row to the iOS model, shared
    /// by the per-circle GET above and the `my_privacy` copy embedded in
    /// `GET /circles`, so both paths hand the send gates identical values.
    nonisolated static func privacySettings(from response: PrivacySettingsResponse, now: Date = Date()) -> PrivacySettings {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let pausedUntil: Date? = response.pausedUntil
            .flatMap { formatter.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) }
        let approximateUntil: Date? = response.approximateUntil
            .flatMap { formatter.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) }
        let date: (String) -> Date? = { formatter.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) }
        var settings = PrivacySettings(
            circleId: response.circleId,
            // Carried verbatim: a "paused" row with a null paused_until is a
            // PERMANENT pause, and nothing else on this model can say so.
            sharingMode: response.sharingMode,
            shareRealtime: response.shareRealtime,
            shareHistory: response.shareHistory,
            shareBattery: response.shareBattery,
            bubbleEnabled: response.sharingMode == "approximate",
            // The server NULLs approximate_radius_miles whenever the mode is
            // exact (a pause keeps it), so this is nil for most rows. Falling
            // back to 0 would make the next save send Int(0), which the server
            // rejects with "approximate_radius_miles must be between 1 and 25".
            // 1 is the real minimum.
            bubbleRadius: Double(response.approximateRadiusMiles ?? 1),
            pausedUntil: pausedUntil,
            updatedAt: response.updatedDayBucket
                .map { Date(timeIntervalSince1970: TimeInterval($0) * 86_400) } ?? Date(),
            allowAlertsOnMe: response.allowAlertsOnMe ?? true,
            // Round-tripped, not defaulted: this is a fail-OPEN field. iOS has
            // no control for it, so anything other than preserving what the
            // server holds publishes devices the user hid elsewhere.
            showAllDevices: response.showAllDevices,
            primaryDeviceId: response.primaryDeviceId,
            modeBeforePause: response.modeBeforePause,
            approximateUntil: approximateUntil,
            // Fail closed: a start that does not read, from the beginning; an
            // end, still running.
            notSharingIntervals: response.notSharingIntervals?.map { span in
                PauseInterval(start: date(span.start) ?? .distantPast, end: span.end.flatMap(date))
            },
            // Fail closed: a start that does not read, from the beginning; an
            // end, still running; a bubble missing or not one, the largest a
            // member can set.
            approximateIntervals: response.approximateIntervals?.map { span in
                ApproximateInterval(start: date(span.start) ?? .distantPast, end: span.end.flatMap(date),
                                    radiusMiles: span.radiusMiles.flatMap { $0 > 0 ? Double($0) : nil }
                                        ?? CirclePauseRecord.unknownBubbleMiles)
            }
        )
        // While paused, Bubble Mode is the mode the pause returns to, by the
        // server's own rule ("mode held before the pause"), so a refresh during
        // a pause cannot switch it off and a Resume from the sheet sends it back.
        settings.alignBubbleWithPause(at: now)
        return settings
    }

    /// Which circles' privacy a circles refresh can take straight from the
    /// `GET /circles` payload (`my_privacy`), and which still need their own
    /// `GET /privacy/circles/{id}`.
    ///
    /// A circle is taken from the payload only when its embedded row names that
    /// same circle. Anything else falls back to the per-circle fetch: the key
    /// absent (an older backend), null (no privacy row yet, which the per-circle
    /// GET's 404 turns into the server's defaults) or a row for another circle.
    /// So a missing or odd field can only ever cost the per-circle GET.
    nonisolated static func privacyRefreshPlan(
        circleIds: [String],
        responses: [CircleResponse]
    ) -> (embedded: [String: PrivacySettings], fetch: [String]) {
        var own: [String: PrivacySettingsResponse] = [:]
        for response in responses {
            if let row = response.myPrivacy,
               row.circleId.caseInsensitiveCompare(response.id) == .orderedSame {
                own[response.id] = row
            }
        }
        var embedded: [String: PrivacySettings] = [:]
        var fetch: [String] = []
        for id in circleIds {
            if let row = own[id] {
                embedded[id] = privacySettings(from: row)
            } else {
                fetch.append(id)
            }
        }
        return (embedded, fetch)
    }

    /// Sent for `owner`, the account the write was queued for (`privacyWrite`):
    /// checked right before each request, and nothing is kept for whoever
    /// signed in since.
    func updatePrivacySettings(_ settings: PrivacySettings, for owner: String?) async throws {
        let before = privacySettings
        defer { Task { await self.sendFreshFixIfNewlyApproximate(before: before) } }
        try await Self.savePrivacy(
            settings, confirmed: privacySettings[settings.circleId],
            put: { step in
                try self.checkStillSignedIn(as: owner)
                return try await self.sendPrivacySettings(step)
            },
            store: {
                guard CanonicalId.same(AuthManager.shared.userId, owner) else { return }
                self.privacySettings[$0.circleId] = $0
                // A change made here: exactly when.
                CirclePauseRecord.shared.observe($0, at: Date(), exact: true, owner: AuthManager.shared.userId)
            })
    }

    /// A save, as the requests it takes: one, but for a pause saved together
    /// with a change of Bubble Mode. A pause returns to the mode the SERVER's
    /// row held when it began (`mode_before_pause`), and a paused save carries
    /// no mode, so Bubble Mode switched on — or off, or resized — in the same
    /// visit as the Pause tap would be forgotten and the pause would end in the
    /// old mode. That mode is saved first, on its own, then the pause. If the
    /// pause then fails, the person is told what stands.
    ///
    /// `put` sends one step and answers the row as it then stands; only the
    /// OUTCOME is kept (`store`). While the pause step is on its way this phone
    /// keeps the row it held, so a Resume, a change and a Pause in one visit
    /// never lets it send in between.
    static func savePrivacy(
        _ settings: PrivacySettings, confirmed: PrivacySettings?, now: Date = Date(),
        put: (PrivacySettings) async throws -> PrivacySettings,
        store: (PrivacySettings) -> Void
    ) async throws {
        guard let first = modeToSaveBeforePause(settings, confirmed: confirmed, now: now) else {
            store(try await put(settings))
            return
        }
        let modeSaved = try await put(first)
        // The mode just saved has no end: iOS sends none, and the server drops
        // any on that save. The pause returns to it as it now stands.
        var pause = settings
        pause.approximateUntil = nil
        do {
            store(try await put(pause))
        } catch {
            store(modeSaved)
            throw PauseNotSaved(approximate: first.bubbleEnabled, reason: error)
        }
    }

    /// The mode to save before a pause, or nil when the server already holds
    /// the one this pause should return to (with the same radius).
    nonisolated static func modeToSaveBeforePause(
        _ settings: PrivacySettings, confirmed: PrivacySettings?, now: Date = Date()
    ) -> PrivacySettings? {
        guard settings.isPaused, let confirmed else { return nil }
        let wanted = settings.returnsToApproximate(at: now)
        // What the server's pause will return to: a running pause keeps its own
        // mode; otherwise the row's mode as it stands is recorded.
        let held = confirmed.sharingMode == "paused"
            ? confirmed.returnsToApproximate(at: now)
            : confirmed.sharingMode == "approximate"
        let sameRadius = Int(settings.bubbleRadius.rounded()) == Int(confirmed.bubbleRadius.rounded())
        if wanted == held && (!wanted || sameRadius) { return nil }
        var first = settings
        first.resume(at: now)
        return first
    }

    /// The mode was saved and the pause was not (`savePrivacy`): said plainly,
    /// because the circle now sees this person in that mode, unpaused.
    struct PauseNotSaved: LocalizedError {
        let approximate: Bool
        let reason: Error

        var errorDescription: String? {
            let stands = approximate
                ? "Bubble Mode is on, but the pause wasn't saved: this circle sees your approximate location now."
                : "Bubble Mode is off, but the pause wasn't saved: this circle sees your exact location now."
            return "\(reason.plainText) \(stands) Tap Pause Sharing to try again."
        }
    }

    /// One PUT of `settings`; answers the row as it then stands, to be kept.
    private func sendPrivacySettings(_ settings: PrivacySettings) async throws -> PrivacySettings {
        let request = Self.privacyRequest(for: settings).request
        _ = try await api.updatePrivacySettings(circleId: settings.circleId, settings: request)
        return Self.storedCopy(after: settings)
    }

    /// The row as it stands after a PUT of `settings`: the posture actually
    /// sent, so the copy kept can't drift from the row (a clamped radius, or
    /// the mode just derived).
    nonisolated static func storedCopy(after settings: PrivacySettings) -> PrivacySettings {
        let (_, sharingMode, approximateRadius) = privacyRequest(for: settings)
        var stored = settings
        stored.sharingMode = sharingMode
        if let approximateRadius { stored.bubbleRadius = Double(approximateRadius) }
        // A save that is not a pause clears the mode a pause would return to,
        // and the bubble's end (iOS sends none); a paused save leaves both as
        // the server held them.
        if sharingMode != "paused" {
            stored.modeBeforePause = nil
            stored.approximateUntil = nil
        }
        // A PUT answers no spans: these are the last read's, not the row's now
        // (`CirclePauseRecord` keeps the server's, and ends what this save ends).
        stored.notSharingIntervals = nil
        stored.approximateIntervals = nil
        return stored
    }

    /// The body of a privacy PUT for `settings`, with the mode and radius it sends.
    nonisolated static func privacyRequest(
        for settings: PrivacySettings
    ) -> (request: PrivacySettingsRequest, sharingMode: String, approximateRadius: Int?) {
        // Backend wants a single sharing_mode string, not separate booleans.
        // Precedence: paused > bubble > exact. RFC3339 timestamps for the
        // optional auto-expiry fields.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let sharingMode: String
        var pausedUntilStr: String? = nil
        var approximateRadius: Int? = nil
        // `isPaused`, not a bare `pausedUntil` check: an indefinite pause
        // (mode "paused", no timestamp) has nothing to compare against, and
        // re-deriving from the timestamp alone silently resent it as "exact",
        // un-pausing the user server-side as a side effect of any other edit.
        // A nil pausedUntil here is therefore deliberate — it re-sends the
        // indefinite pause as an indefinite pause.
        if settings.isPaused {
            sharingMode = "paused"
            pausedUntilStr = settings.pausedUntil.map { formatter.string(from: $0) }
        } else if settings.bubbleEnabled {
            sharingMode = "approximate"
            // Clamped to the server's accepted range rather than trusting the
            // caller: the server rejects anything outside 1...25 outright.
            approximateRadius = min(25, max(1, Int(settings.bubbleRadius.rounded())))
        } else {
            sharingMode = "exact"
        }
        let request = PrivacySettingsRequest(
            sharingMode: sharingMode,
            approximateRadiusMiles: approximateRadius,
            approximateUntil: nil,
            pausedUntil: pausedUntilStr,
            shareRealtime: settings.shareRealtime,
            shareHistory: settings.shareHistory,
            shareBattery: settings.shareBattery,
            // The server stores whatever is sent here — a nil does not keep
            // the old value — so a nil wipes the user's pinned device.
            // Only sent when it can still matter: with showAllDevices true the
            // server ignores it, and re-asserting a device that has since gone
            // inactive is a hard 400 ("must be an active device belonging to
            // you") on an otherwise unrelated save.
            primaryDeviceId: settings.showAllDevices ? nil : settings.primaryDeviceId,
            // Left nil on purpose: the server COALESCEs this one, so nil keeps
            // whatever pseudonym it already holds.
            primaryDevicePseudonym: nil,
            // Round-tripped, never hard-coded: a constant `true` would be
            // fail-OPEN — a user who picked "show only my most recent device"
            // on web or Android would have every device published again the
            // next time they touched any setting on their iPhone.
            showAllDevices: settings.showAllDevices,
            // Preserve the opt-out flag on EVERY update — pause/resume and any
            // other partial change funnel through here, so omitting it would
            // silently reset the user's choice to the default.
            allowAlertsOnMe: settings.allowAlertsOnMe
        )
        return (request, sharingMode, approximateRadius)
    }

    /// The circles this account shared with exactly in `before` and shares
    /// with approximately in `after`, both as of `now`. A circle new to the list
    /// is not one, nor one coming back from a pause (it returns to the mode it
    /// had, whose last fixes were coarsened already).
    nonisolated static func newlyApproximate(before: [String: PrivacySettings], after: [String: PrivacySettings],
                                             at now: Date) -> [String] {
        after.compactMap { id, row in
            guard let was = before[id], CirclePauseRecord.shares(was, at: now), !was.sharesApproximately(at: now),
                  CirclePauseRecord.shares(row, at: now), row.sharesApproximately(at: now) else { return nil }
            return id
        }.sorted()
    }

    /// On a switch from exact to approximate, the circle's last stored fix
    /// of this person's may be a PRECISE one, which it now shows as
    /// approximate. One fresh fix at once, through the normal uploads, which
    /// coarsen it for that circle, replaces it. Asked after a change made
    /// here, and after a refresh a `privacy_check` wake asked for.
    func sendFreshFixIfNewlyApproximate(before: [String: PrivacySettings]) async {
        guard !Self.newlyApproximate(before: before, after: privacySettings, at: Date()).isEmpty else { return }
        _ = await locationService.sendOneFreshFix(reason: "switched to approximate")
    }

    /// The sheet's Pause, sent at once: the pause of the row the server holds
    /// now, read again first, returning to the Bubble Mode the person chose in
    /// the sheet, else the row's own (`pauseRequest`). The sheet's other
    /// changes are not part of it: they wait for its Save. One privacy write
    /// at a time (`privacyWrite`); saved as any pause is (`savePrivacy`).
    func pauseSharing(_ edited: PrivacySettings, shownFrom shown: PrivacySettings, until: Date?) async throws {
        try await privacyWrite(edited.circleId) { owner in
            let latest = try await self.latestPrivacyRow(edited.circleId, for: owner)
            try await self.updatePrivacySettings(
                Self.pauseRequest(on: latest, edited: edited, shown: shown, until: until), for: owner)
        }.value
    }

    /// Pure: what Pause sends. The row the server holds, with the person's
    /// change of Bubble Mode if they made one (`bubbleChange`), which is the
    /// mode the pause returns to (saved first when it differs, `savePrivacy`),
    /// then the pause. Never the sheet's other switches: a change not saved is
    /// not sent by Pause.
    nonisolated static func pauseRequest(on row: PrivacySettings, edited: PrivacySettings,
                                         shown: PrivacySettings, until: Date?) -> PrivacySettings {
        var request = bubbleChange(edited, from: shown, onto: row)
        request.pause(until: until)
        return request
    }

    /// The sheet's Save: the switches the person changed from what the sheet
    /// showed (`changes`), on the row the server holds now, read again first,
    /// one privacy write at a time (`privacyWrite`). Never the sheet's whole
    /// copy, which is as old as the sheet: a pause made on the web while it was
    /// open, a bubble's end, a choice made on another device, or a write of
    /// this phone's still on its way, all stand.
    func saveChanges(_ edited: PrivacySettings, shownFrom shown: PrivacySettings) async throws {
        try await privacyWrite(edited.circleId) { owner in
            let latest = try await self.latestPrivacyRow(edited.circleId, for: owner)
            try await self.updatePrivacySettings(Self.changes(edited, from: shown, onto: latest), for: owner)
        }.value
    }

    /// Pure: every change the person made in a sheet, switch by switch, on
    /// `row`. A switch left as the sheet showed it takes `row`'s value, so a
    /// change made meanwhile elsewhere is never undone by one made here.
    nonisolated static func changes(_ edited: PrivacySettings, from shown: PrivacySettings,
                                    onto row: PrivacySettings) -> PrivacySettings {
        var request = bubbleChange(edited, from: shown, onto: row)
        if edited.shareRealtime != shown.shareRealtime { request.shareRealtime = edited.shareRealtime }
        if edited.shareHistory != shown.shareHistory { request.shareHistory = edited.shareHistory }
        if edited.shareBattery != shown.shareBattery { request.shareBattery = edited.shareBattery }
        if edited.allowAlertsOnMe != shown.allowAlertsOnMe { request.allowAlertsOnMe = edited.allowAlertsOnMe }
        return request
    }

    /// Pure: the person's change of Bubble Mode in a sheet, if they made one,
    /// on `row`; else `row` as it is. On a row paused meanwhile elsewhere, it
    /// is the mode that pause returns to, saved first as any such change is
    /// (`savePrivacy`), never dropped by the pause keeping its own.
    nonisolated static func bubbleChange(_ edited: PrivacySettings, from shown: PrivacySettings,
                                         onto row: PrivacySettings) -> PrivacySettings {
        var request = row
        guard edited.bubbleEnabled != shown.bubbleEnabled || edited.bubbleRadius != shown.bubbleRadius
                || edited.approximateUntil != shown.approximateUntil else { return request }
        request.bubbleEnabled = edited.bubbleEnabled
        request.bubbleRadius = edited.bubbleRadius
        request.approximateUntil = edited.approximateUntil
        if request.isPaused { request.modeBeforePause = edited.bubbleEnabled ? "approximate" : "exact" }
        return request
    }

    /// The privacy write last queued for each circle (`privacyWrite`).
    private var privacyWriteTail: [String: Task<Void, Error>] = [:]
    /// Every privacy write queued or on its way, so a sign-out ends them all.
    private var privacyWriteTasks: [UUID: Task<Void, Error>] = [:]

    /// One privacy write at a time for a circle: each waits until the one
    /// queued before it has ended, however it ended. A whole-row PUT built
    /// while another was on its way could undo it (the second of two quick
    /// switches could turn real-time sharing back on); a sheet closed with its
    /// write on the way and opened again starts from a row older than that
    /// write.
    ///
    /// Made for the account signed in when it was queued, `owner`, and only
    /// ever sent for it: `write` checks right before each request
    /// (`checkStillSignedIn`), and a sign-out cancels every write (`reset`).
    /// Otherwise a write still waiting when one person signs out and another
    /// signs in would go out on the new session, into their privacy row.
    @discardableResult
    func privacyWrite(_ circleId: String,
                      _ write: @escaping @MainActor (_ owner: String?) async throws -> Void) -> Task<Void, Error> {
        let key = CanonicalId.key(circleId)
        let owner = AuthManager.shared.userId
        let before = privacyWriteTail[key]
        let id = UUID()
        let task = Task { @MainActor in
            defer { self.privacyWriteTasks[id] = nil }
            _ = await before?.result
            try Task.checkCancellation()
            try await write(owner)
        }
        privacyWriteTail[key] = task
        privacyWriteTasks[id] = task
        return task
    }

    /// Pure: a privacy write made for `owner` goes out only while `owner` is
    /// the account signed in, ids in their one form; otherwise it is dropped.
    nonisolated static func stillSignedIn(as owner: String?, now signedIn: String?) throws {
        guard CanonicalId.same(signedIn, owner) else { throw CancellationError() }
    }

    private func checkStillSignedIn(as owner: String?) throws {
        try Self.stillSignedIn(as: owner, now: AuthManager.shared.userId)
    }

    /// The row the server holds for the circle now, read again: what each
    /// privacy write is built on, never a copy taken when a sheet opened.
    private func latestPrivacyRow(_ circleId: String, for owner: String?) async throws -> PrivacySettings {
        try checkStillSignedIn(as: owner)
        try await loadPrivacySettings(for: circleId)
        guard let latest = privacySettings[circleId] else { throw PauseNotSent() }
        return latest
    }

    /// Pause with no row of the circle's held here: nothing was sent.
    struct PauseNotSent: LocalizedError {
        var errorDescription: String? { "Your settings for this circle haven't loaded yet. Try again in a moment." }
    }

    /// End this circle's pause, back to the mode held before it. The server
    /// decides, by the rule it applies when a pause expires
    /// (`POST …/resume`), and its answer is stored as it stands. No PUT
    /// fallback: a missing route must show as an error, not resume as exact.
    func resumeSharing(for circleId: String) async throws {
        try await privacyWrite(circleId) { owner in
            try self.checkStillSignedIn(as: owner)
            let response = try await self.api.resumePrivacySharing(circleId: circleId)
            guard CanonicalId.same(AuthManager.shared.userId, owner) else { return }
            self.privacySettings[circleId] = Self.privacySettings(from: response)
            CirclePauseRecord.shared.observe(Self.privacySettings(from: response), at: Date(), exact: true,
                                             owner: AuthManager.shared.userId)
        }.value
    }

    // MARK: - Location Sharing

    /// Pure replay/reorder decision for one member location row. Returns
    /// `true` when the incoming update should be ACCEPTED and `false` when
    /// it is a stale replay/reorder that must be dropped.
    ///
    /// - `incomingAuthTs == nil` → the row carried no AEAD-authenticated
    ///   timestamp (coarse `dayBucket` only), which is not the replay
    ///   vector → always accept (the caller records no high-water mark).
    /// - first-seen (`lastAcceptedTs == nil`) → accept.
    /// - otherwise accept only when strictly newer; equal or older is a
    ///   replay/reorder → drop.
    ///
    /// `nonisolated` so it is a pure function independent of the manager's
    /// `@MainActor` state (and directly unit-testable).
    nonisolated static func shouldAcceptLocation(
        incomingAuthTs: Int64?, lastAcceptedTs: Int64?, now: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) -> Bool {
        guard let incoming = incomingAuthTs else { return true }
        // Beyond the bound: dropped, and the guard doesn't move.
        guard incoming <= now + maxFutureSkewMs else { return false }
        // A stored time beyond it reads as absent: one planted far-future fix
        // can't hold every genuine one back.
        guard let last = lastAcceptedTs, last <= now + maxFutureSkewMs else { return true }
        return incoming > last
    }

    /// MAX_FUTURE_SKEW_MS: how far ahead of this device's clock an
    /// authenticated time may be (one constant with the web and Android). A
    /// location beyond it is dropped: not accepted, the replay guard not
    /// advanced, no alert. A stored guard or alert watermark beyond it reads
    /// as absent.
    nonisolated static let maxFutureSkewMs: Int64 = 600_000

    /// The replay guard's key: the circle and the member in their one form,
    /// so a re-spelled id can't start the member's guard afresh.
    nonisolated static func guardKey(_ circleId: String, _ userId: String) -> String {
        CanonicalId.key(circleId) + ":" + CanonicalId.key(userId)
    }

    /// `userId`'s row as `circleId` last accepted it: what that circle's alert
    /// rules judge them by (`CircleRowMemory`).
    func acceptedRow(of userId: String, in circleId: String) -> LocationData? {
        rowsByCircle.row(of: userId, in: circleId)
    }

    /// The fix this device already holds for a member, drawn the way a newer
    /// response says they share NOW — nil when nothing changes on the map.
    ///
    /// The replay guard drops a row whose time is not newer than the one held,
    /// and the server re-serves a member's last fix until they send another. A
    /// member who switches to approximate is therefore reported "approximate"
    /// on that same old fix, and without this they would stay a pin with an
    /// address until their phone next sent something. It is the HELD fix that is
    /// redrawn — its own point (put on the senders' grid if it is not on it) and
    /// its own time — so a replay still cannot rewind anyone.
    nonisolated static func heldFix(_ held: LocationData?, takingPostureOf row: LocationData,
                                    areas: inout ApproximateAreaMemory) -> LocationData? {
        guard let held, CanonicalId.key(held.circleId) == CanonicalId.key(row.circleId) else { return nil }
        var restated = held
        restated.approximate = row.approximate
        let redrawn = areas.draw(restated, circleId: held.circleId, userId: held.userId)
        let unchanged = redrawn.latitude == held.latitude && redrawn.longitude == held.longitude
            && redrawn.approximate?.drawnMiles == held.approximate?.drawnMiles
        return unchanged ? nil : redrawn
    }

    /// Whose a latest-location row is.
    enum RowOwner: Equatable {
        /// This account, in any spelling and from any of its devices: never
        /// read. The device id is sealed under the circle's key, which every
        /// member holds, so a planted row can't be told from one of ours.
        case me
        /// Another account, as the row names it, and the key version its
        /// sealed id opened under (nil when the server's plaintext named it).
        case member(String, sealedUnder: Int32?)
        /// No id, a sealed one that won't open, or one that is no UUID: nobody's,
        /// and never passed on as some other member.
        case nobody
    }

    /// The row's user id: the server's plaintext, else the sealed one opened
    /// under the circle's key. Pure apart from the SDK read, so every case is
    /// testable with real sealing.
    nonisolated static func owner(
        of response: LocationResponse, circleId: String, me: String?, crypto: CryptoManager
    ) -> RowOwner {
        var userId: String? = response.userId
        var sealedUnder: Int32?
        if userId == nil, let blob = response.encryptedUserId,
           let opened = try? crypto.decryptDataV2Opened(
               circleId: circleId,
               encryptedData: EncryptedData(nonce: blob.nonce, ciphertext: blob.ciphertext),
               fieldTag: "user_id"
           ) {
            userId = opened.text
            sealedUnder = opened.keyVersion
        }
        guard let userId, CanonicalId.of(userId) != nil else { return .nobody }
        return CanonicalId.same(userId, me) ? .me : .member(userId, sealedUnder: sealedUnder)
    }

    /// What one latest-location row is to this device.
    enum RowDecode {
        /// This account's own: never read.
        case mine
        /// Nobody's (`RowOwner.nobody`).
        case nobody
        /// A session-key row whose key this device doesn't hold for this circle.
        case keyMissing
        /// A payload that would not open.
        case unopened
        /// It opened, but its payload, or the sealed id or time it was read
        /// with, only under a key version this device doesn't seal under: a
        /// key a member removed at the last rotation still holds opens it.
        case history(String)
        /// A current row: the member's position, and the authenticated time
        /// when it came sealed.
        case live(LocationData, authenticatedTs: Int64?)
    }

    /// One latest-location row, read. Pure apart from the SDK reads, so every
    /// case is testable with real sealing. CURRENT only when the payload, and
    /// the sealed id and the sealed time whenever they were used, opened under
    /// the version this device seals the circle under: `isCurrentKeyVersion`
    /// is the one test, never a comparison made here.
    nonisolated static func decodeRow(
        _ response: LocationResponse, circleId: String, me: String?, crypto: CryptoManager
    ) -> RowDecode {
        // Whose it is decides whether it is read at all.
        let resolvedUserId: String
        let idVersion: Int32?
        switch owner(of: response, circleId: circleId, me: me, crypto: crypto) {
        case .me:
            return .mine
        case .nobody:
            return .nobody
        case .member(let userId, let sealedUnder):
            resolvedUserId = userId
            idVersion = sealedUnder
        }

        // Decrypt the location payload. Newer backends wrap an
        // ephemeral msg_key per record; the SDK helper unwraps with the
        // circle key, then decrypts the ciphertext with the recovered
        // msg_key.
        // Bind to the sender by passing the resolved (E2EE) user_id;
        // the SDK re-derives the claimed pseudonym PER held circle-key
        // version, so a server relabel fails the payload tag AND a row
        // sealed under a now-superseded key version still verifies after
        // a circle-key rotation. Legacy rows read back with
        // senderVerified=false via the SDK's v2/v1 fallback. Which version
        // opened it is reported (`keyVersion`), and decides whether the row
        // is live (below).
        //
        // Read path by payload shape:
        //  - session-key rows (key_id "s:{uuid}", e.g. the Android app's
        //    manual "send now") seal the ciphertext directly under the
        //    circle's active SESSION key — read via the session-key bound
        //    reader, with THIS circle's session key only. The peer key
        //    was imported before the detached block (fetch-on-miss); if it's
        //    still absent the fetch failed → drop the row (fail closed, never
        //    plaintext).
        //  - no wrapped msg_key at all (neither field): sealed straight under
        //    the circle key. A frozen last location re-sealed after a rotation
        //    (key_id "c:<version>"), or the Android app's send when its session
        //    key fails (key_id ""). Web and Android read these too. Left
        //    unopened, one in `locations` would make the whole refresh unusable
        //    for judging anyone. The `key_id` names no version that counts
        //    here: only the key that opened it does (below).
        //  - otherwise the per-message wrapped-msg-key envelope. One with only
        //    one of its two wrap fields would not open, and stays a failure.
        let payload = response.encryptedPayload
        // Split rather than collapsed to nil, because "we never had the
        // key" and "we had the key and the payload would not open" are
        // different operator problems.
        let bound: BoundLocation?
        if let keyId = payload.keyId, keyId.hasPrefix("s:") {
            guard crypto.hasPeerSessionKeyFor(circleId: circleId, sessionKeyId: keyId) else {
                // The pre-fetch tried and failed to import it.
                return .keyMissing
            }
            bound = EnvelopeDecoding.decryptSessionLocationBound(
                circleId: circleId,
                payload: payload,
                keyId: keyId,
                userId: resolvedUserId,
                crypto: crypto
            )
        } else if payload.wrappedMsgKey == nil && payload.wrappedMsgKeyNonce == nil {
            bound = EnvelopeDecoding.decryptDirectLocationBound(
                circleId: circleId,
                payload: payload,
                userId: resolvedUserId,
                crypto: crypto
            )
        } else {
            bound = EnvelopeDecoding.decryptLocationBound(
                circleId: circleId,
                payload: payload,
                userId: resolvedUserId,
                crypto: crypto
            )
        }
        guard let bound = bound else {
            #if DEBUG
            Self.diag("location-decrypt", "user=\(resolvedUserId) circle=\(circleId) keyId=\(response.encryptedPayload.keyId ?? "<nil>") wrappedKey?=\(response.encryptedPayload.wrappedMsgKey != nil) wrappedKeyNonce?=\(response.encryptedPayload.wrappedMsgKeyNonce != nil) noncePrefix=\(response.encryptedPayload.nonce.prefix(20)) ctPrefix=\(response.encryptedPayload.ciphertext.prefix(20))")
            #endif
            return .unopened
        }
        let decrypted = bound.location

        // Decrypt device id when present (best-effort, display only).
        var deviceId = "unknown"
        if let blob = response.encryptedDeviceId,
           let decryptedDevice = try? crypto.decryptDataV2(
            circleId: circleId,
            encryptedData: EncryptedData(nonce: blob.nonce, ciphertext: blob.ciphertext),
            fieldTag: "device_id"
        ) {
            deviceId = decryptedDevice
        }

        // Prefer the encrypted timestamp for sub-day precision; fall
        // back to dayBucket otherwise. The encrypted variant is
        // AEAD-authenticated (the server can't forge it), so capture
        // it separately — only that value is trusted by the
        // replay/reorder guard on the publish path.
        var authenticatedTimestampMs: Int64?
        var timeVersion: Int32?
        if let blob = response.encryptedTimestamp,
           let opened = try? crypto.decryptDataV2Opened(
               circleId: circleId,
               encryptedData: EncryptedData(nonce: blob.nonce, ciphertext: blob.ciphertext),
               fieldTag: "timestamp"
           ),
           let ts = Int64(opened.text) {
            authenticatedTimestampMs = ts
            timeVersion = opened.keyVersion
        }

        let versions = [bound.keyVersion] + [idVersion, timeVersion].compactMap { $0 }
        guard versions.allSatisfy({ crypto.isCurrentKeyVersion(circleId: circleId, keyVersion: $0) }) else {
            return .history(resolvedUserId)
        }
        #if DEBUG
        Self.diag("location-decrypt-ok", "user=\(resolvedUserId) lat=\(decrypted.latitude) lng=\(decrypted.longitude)")
        #endif
        let timestampMs = authenticatedTimestampMs ?? Int64(response.dayBucket) * 86_400_000

        return .live(LocationData(
            circleId: circleId,
            userId: resolvedUserId,
            deviceId: deviceId,
            latitude: decrypted.latitude,
            longitude: decrypted.longitude,
            altitude: decrypted.altitude,
            speed: decrypted.speed,
            heading: decrypted.heading,
            accuracy: decrypted.accuracy,
            batteryLevel: decrypted.batteryLevel.map { Int($0) },
            timestamp: Date(timeIntervalSince1970: TimeInterval(timestampMs) / 1000),
            isSynced: true,
            // Plaintext on the row, not inside the sealed payload: it is the
            // server's consent field. Carried onto the location so the
            // evaluator judges this fix against the posture that arrived WITH it.
            allowAlertsOnMe: response.allowAlertsOnMe,
            // The same kind of field: the member shares only an area here.
            approximate: ApproximateArea(sharingMode: response.sharingMode,
                                         radiusMiles: response.approximateRadiusMiles)
        ), authenticatedTs: authenticatedTimestampMs)
    }

    /// What one refresh of a circle's locations actually produced.
    ///
    /// `memberLocations` is a CACHE of last-known positions, not a snapshot of
    /// this refresh: the publish loop below writes per key and never replaces the
    /// dictionary, so a member absent from this response keeps their previous
    /// entry with its previous timestamp. Anything that judges a member by "how
    /// long since we last heard from them" therefore cannot read that dictionary
    /// alone — it needs to know whether this refresh actually said anything about
    /// them. That is what `refreshedUserIds` is for.
    ///
    /// THE SET IS DERIVED FROM DECODE RESULTS, NEVER FROM THE PRIVACY LIST.
    ///   A member who has paused sharing is absent because the SERVER filtered
    ///   them out: it never sends a paused member's ciphertext at all. Absence
    ///   is the only signal this device is given, and it is sufficient.
    ///   Cross-referencing the privacy list to find out WHO is paused would
    ///   look like a tidier implementation and would open exactly the
    ///   disclosure that server-side filter exists to prevent. Do not do it.
    ///
    /// POPULATED FROM `fresh`, NOT FROM `accepted`.
    ///   The replay guard below drops a row whose authenticated timestamp is not
    ///   newer than the last accepted one. That member is not stale — the entry we
    ///   already hold is at least as new as what arrived — so excluding them would
    ///   suppress genuine alerts for any device that re-sends an identical fix.
    ///   The Android app keeps the same two things apart for the same reason. A
    ///   HISTORY row (opened only under a key version not in use) counts too,
    ///   the same way: the member is judged by their last current point as it
    ///   ages, and one planted row can't hide them.
    ///
    /// The two counts are circle-level: a refresh that half-failed cannot be used
    /// to judge ANYONE in that circle, because the members it failed to decrypt
    /// are indistinguishable from members who went quiet. They mirror the
    /// Android app's `LocationFetchResult.keyMissingCount` / `decryptionFailures`.
    struct MemberLocationRefresh {
        /// Members this refresh produced a location for. Judge only these.
        let refreshedUserIds: Set<String>
        /// Rows that could not be opened for want of a key. Judge nobody.
        let keyMissingCount: Int
        /// Rows present that failed to decrypt or decode. Judge nobody.
        let decryptionFailures: Int
        /// Rows the server returned, before any of the above.
        let totalReceived: Int

        /// Whether this refresh is a sound basis for judging the circle at all.
        var isComplete: Bool { keyMissingCount == 0 && decryptionFailures == 0 }
    }

    /// May an alert evaluator judge this member on the strength of this refresh?
    ///
    /// The whole two-tier rule in one place, pure and directly testable — same
    /// shape as `shouldAcceptLocation` above and for the same reason: what
    /// matters is a DECISION, and a decision is testable without a network, a
    /// circle key or a live actor.
    ///
    /// Callers also short-circuit on `isComplete` once per circle rather than
    /// once per member. That is an optimisation, not the rule; re-checking it
    /// here means a site that later drops the outer guard is still correct.
    nonisolated static func shouldJudge(_ userId: String, from refresh: MemberLocationRefresh) -> Bool {
        // Tier 1: a refresh that could not open every row cannot tell "went
        // quiet" from "we could not read it", so it judges nobody.
        guard refresh.isComplete else { return false }
        // Tier 2: a member this refresh produced nothing for is paused, has never
        // shared, or was filtered server-side. All three mean: say nothing.
        return refresh.refreshedUserIds.contains(userId)
    }

    /// - Parameter surfaceFailures: whether a failure here may raise the map's
    ///   "Couldn't reach server — showing last known" pill. True for refreshes the
    ///   user is watching; FALSE for background ones, which they are not.
    ///
    ///   A push-driven wake runs with the app off-screen, on whatever signal the
    ///   phone has in a pocket, for a circle id chosen by the payload rather than
    ///   by the user. Letting that paint a persistent error over a map nobody is
    ///   looking at — one that then survives until some later refresh happens to
    ///   succeed — reports a problem the user does not have.
    ///
    /// - Returns: what this refresh produced; see `MemberLocationRefresh`.
    ///   `@discardableResult` because the six display call sites correctly do not
    ///   care — only the alert evaluators do.
    @discardableResult
    /// Count a refresh in, and raise the pill only if it is still running after
    /// `slowRefreshThreshold` — and only in the foreground, where the pill can be
    /// seen. Background passes never touch it.
    private func beginLocationRefresh() {
        locationRefreshesInFlight += 1
        guard UIApplication.shared.applicationState == .active else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.slowRefreshThreshold * 1_000_000_000))
            guard let self, self.locationRefreshesInFlight > 0, !self.isRefreshingLocations else { return }
            self.isRefreshingLocations = true
        }
    }

    private func endLocationRefresh() {
        locationRefreshesInFlight = max(0, locationRefreshesInFlight - 1)
        if locationRefreshesInFlight == 0, isRefreshingLocations {
            isRefreshingLocations = false
        }
    }

    func loadMemberLocations(for circleId: String, surfaceFailures: Bool = true) async throws -> MemberLocationRefresh {
        // Backend route: GET /api/v1/circles/:id/locations/latest. Returns
        // the latest location per member; we decrypt user_id + payload with
        // the circle key (already loaded by loadCircles -> SDK.storeCircleKey).
        beginLocationRefresh()
        defer { endLocationRefresh() }
        let wrapper: LatestLocationsResponse
        do {
            wrapper = try await api.getLatestLocations(circleId: circleId)
            // Clear the "stale data" pill on any successful refresh. Only when
            // set: assigning nil to nil still publishes.
            if lastLocationRefreshFailedAt != nil { lastLocationRefreshFailedAt = nil }
        } catch {
            #if DEBUG
            Self.diag("locations-fetch", "circle=\(circleId) FETCH_THREW: \(error)")
            #endif
            // Flag the network failure so the map pill renders
            // "Couldn't reach server — showing last known". Skip the
            // flag on clean 404s — those mean the circle is genuinely
            // gone, not a connectivity issue. Mirrors the Android app's
            // CircleNotFoundException carve-out.
            if surfaceFailures, Self.isCircleNotFound(error) == false {
                lastLocationRefreshFailedAt = Date()
            }
            throw error
        }
        #if DEBUG
        Self.diag("locations-fetch", "circle=\(circleId) responses=\(wrapper.locations.count)")
        #endif
        let myUserId = AuthManager.shared.userId
        // PERF: decrypt every member row off the main actor. The
        // per-row work is synchronous SDK FFI (decryptDataV2 +
        // EnvelopeDecoding.decryptLocation) and janks the UI on a large circle
        // when run on @MainActor. The SDK CryptoManager is internally
        // synchronized (UniFFI Send+Sync), so the decrypt is safe off-main;
        // only the @Published memberLocations write below stays on MainActor.
        let crypto = cryptoManager
        let locations = wrapper.locations
        let lastKnown = wrapper.lastKnown ?? []
        // Pre-import peer session keys for any session-key rows (key_id
        // "s:{uuid}") so the off-main decrypt below stays fully synchronous.
        // These rows (e.g. the Android app's manual "send now" via
        // encryptLocationWithSessionKeyBound) seal the ciphertext under the
        // circle's active SESSION key rather than a per-message wrapped msg_key,
        // so without the imported peer key they can't be read and the member
        // silently vanishes from the map until their next envelope row. Fetch
        // each distinct missing key once; a failed fetch leaves the key absent →
        // the decrypt branch drops the row (fail closed). Mirrors the Android
        // app's LocationRepository session-key branch.
        let sessionKeyIds = Set((locations + lastKnown).compactMap { row -> String? in
            guard let keyId = row.encryptedPayload.keyId, keyId.hasPrefix("s:") else { return nil }
            return keyId
        })
        // Fetch each missing peer session key concurrently. The fetches are
        // independent (distinct key ids), their results are discarded, and both
        // APIService (an actor) and the SDK CryptoManager import
        // (importPeerSessionKey) are internally synchronized, so the fan-out is
        // race-safe. Naturally bounded by the distinct session-key count.
        // Mirrors the members/privacy withTaskGroup fan-out in loadCircles.
        let api = self.api
        await withTaskGroup(of: Void.self) { group in
            for keyId in sessionKeyIds where !crypto.hasPeerSessionKeyFor(circleId: circleId, sessionKeyId: keyId) {
                group.addTask {
                    _ = await api.fetchSessionKey(circleId: circleId, sessionKeyId: keyId)
                }
            }
        }
        let decoded: (
            fresh: [String: LocationData],
            authTs: [String: Int64],
            heardFrom: Set<String>,
            history: Int,
            keyMissing: Int,
            decryptFailed: Int,
            frozen: [String: LocationData],
            frozenStale: Set<String>
        ) = await Task.detached {
            var fresh: [String: LocationData] = [:]
            // Circle-level health. A row dropped for want of a key and a row that
            // failed to decrypt are counted apart, matching the Android app, because
            // they mean different things to an operator even though both make the
            // refresh unusable for judging anyone.
            //
            // The `paused` skip below is deliberately NOT counted as either. It is
            // not a failure — it is the server declining to send, and the whole
            // point of `refreshedUserIds` is that such a member is simply not
            // judged. Counting it would make one paused member suppress alerting
            // for everyone else in the circle.
            var keyMissing = 0
            var decryptFailed = 0
            // AUTHENTICATED (AEAD "timestamp" AAD) epoch-ms per member, when
            // present. Only these feed the replay/reorder guard on the
            // @MainActor publish path below — the coarse dayBucket fallback
            // never does, so it is deliberately not recorded here.
            var authTs: [String: Int64] = [:]
            // Members a HISTORY row came from: heard from, as a replay drop
            // is, so their last current point is judged as it ages. Never live.
            var heardFrom = Set<String>()
            var history = 0
            for response in locations {
                // Skip rows with sharing_mode = paused — those members have
                // explicitly opted out of being tracked. An "approximate" row is
                // read like any other and carries its area (`decodeRow`), which
                // every surface draws instead of the point.
                if response.sharingMode == "paused" { continue }

                switch Self.decodeRow(response, circleId: circleId, me: myUserId, crypto: crypto) {
                case .mine:
                    // This account's own position and alerts come from this
                    // phone's own fixes alone. Counted as nothing: a planted
                    // row must not make the refresh incomplete and silence the
                    // circle's rules.
                    continue
                case .nobody, .unopened:
                    // The row exists and we cannot say whose it is, or it would
                    // not open — a decrypt failure, not an absence.
                    decryptFailed += 1
                case .keyMissing:
                    keyMissing += 1
                case .history(let userId):
                    // Never live, never a "last seen", never alert input, and
                    // the guard doesn't move for it. Not a failure either: one
                    // planted old-key row would otherwise silence every judgment
                    // in the circle.
                    history += 1
                    heardFrom.insert(userId)
                case .live(let location, let authenticatedTs):
                    fresh[location.userId] = location
                    if let authenticatedTs { authTs[location.userId] = authenticatedTs }
                }
            }
            // The frozen rows: opened as any row is, and only drawn. Never
            // counted for the refresh's health, never heard from, never live.
            // One that opens only as history (an older key version) is not
            // drawn: no row is ever shown on an old key's word. Its member is
            // only noted, so that one already drawn may stay a while across a
            // rotation (`FrozenGrace`).
            var frozen: [String: LocationData] = [:]
            var frozenStale = Set<String>()
            for response in lastKnown {
                switch Self.decodeRow(response, circleId: circleId, me: myUserId, crypto: crypto) {
                case .live(var location, _):
                    location.sharingOff = true
                    frozen[location.userId] = location
                case .history(let userId):
                    frozenStale.insert(userId)
                case .mine, .nobody, .keyMissing, .unopened:
                    break
                }
            }
            return (fresh: fresh, authTs: authTs, heardFrom: heardFrom, history: history,
                    keyMissing: keyMissing, decryptFailed: decryptFailed, frozen: frozen, frozenStale: frozenStale)
        }.value
        if decoded.history > 0 {
            // A count only: never an id or a position.
            Self.keyLog.info("circle \(circleId, privacy: .public): \(decoded.history, privacy: .public) location row(s) opened only under a key version not in use, read as history")
        }
        let fresh = decoded.fresh
        let authTs = decoded.authTs

        // Render the server's rows for the circle's other members. This
        // account's own never get here (dropped at decode): its marker is
        // this phone's own fix (`LocationService.currentLocation`).
        //
        // Rows that survive the replay guard below are also the input to
        // subscriber-side place-alert evaluation; see the call after the loop.
        var accepted: [LocationData] = []
        // Collected here and published ONCE after the loop: assigning into the
        // published dictionary per member would publish once per member per
        // refresh.
        var updatedLocations = memberLocations
        // Set when a row the replay guard drops still changes how a held fix is
        // drawn — see `heldFix(_:takingPostureOf:)`.
        var postureChanged = false
        for (userId, row) in fresh {
            // Only members shown on this device appear on its map.
            guard isShown(userId, in: circleId) else { continue }
            // An approximate member as drawn: the area never smaller than the
            // largest radius seen while they stay approximate, centred on a
            // point on the senders' grid (`ApproximateAreaMemory.draw`).
            let data = approximateAreas.draw(row, circleId: circleId, userId: userId)
            // Replay/reorder guard (@MainActor publish). An incoming
            // AEAD-authenticated timestamp that is <= the last accepted one is
            // a stale replay/reorder and is dropped so a hostile server can't
            // rewind a member's pin. Rows carrying only the coarse dayBucket
            // (no authenticated ts) pass through unguarded — that server
            // plaintext is not the replay vector.
            let incomingAuthTs: Int64? = authTs[userId]
            // Guard is keyed per (circle, member): the same physical update
            // is re-encrypted per circle with an IDENTICAL authenticated
            // timestamp, so a global-per-user key would false-drop it in a
            // second circle. Per-circle keying still catches a replay within
            // this circle. Matches the Android app's guard.
            let guardKey = Self.guardKey(circleId, userId)
            guard Self.shouldAcceptLocation(
                incomingAuthTs: incomingAuthTs,
                lastAcceptedTs: lastAcceptedLocationTs[guardKey],
                now: Int64(Date().timeIntervalSince1970 * 1000)
            ) else {
                #if DEBUG
                Self.diag("location-replay-guard", "circle=\(circleId) user=\(userId) DROP incoming=\(String(describing: incomingAuthTs)) last=\(String(describing: lastAcceptedLocationTs[guardKey]))")
                #endif
                // A "no" served now still counts (`takeWithdrawal`).
                rowsByCircle.takeWithdrawal(of: row)
                // How they share here now goes to this circle's own row too, as to
                // the map's below: the Circles tab's "Approximate location" reads it.
                if let own = Self.heldFix(rowsByCircle.row(of: userId, in: circleId), takingPostureOf: row,
                                          areas: &approximateAreas) {
                    rowsByCircle.accept(own)
                }
                if let held = Self.heldFix(updatedLocations[userId], takingPostureOf: row, areas: &approximateAreas) {
                    updatedLocations[userId] = held
                    postureChanged = true
                }
                continue
            }
            if let ts = incomingAuthTs {
                lastAcceptedLocationTs[guardKey] = ts
            }
            updatedLocations[userId] = data
            rowsByCircle.accept(data)
            accepted.append(data)
        }
        // The frozen rows REPLACE this circle's, never append, for members
        // shown on this device. Such a member's last live row goes with it:
        // the frozen one is now their position, and nothing judges them.
        var frozenNow = frozenLocations.filter { _, loc in loc.circleId != circleId }
        var replacedByFrozen = false
        var drawnFrozen = Set<String>()
        for (userId, row) in decoded.frozen where isShown(userId, in: circleId) {
            frozenNow[userId] = approximateAreas.draw(row, circleId: circleId, userId: userId)
            drawnFrozen.insert(userId)
            if updatedLocations[userId]?.circleId == circleId, fresh[userId] == nil {
                updatedLocations.removeValue(forKey: userId)
                replacedByFrozen = true
            }
            if fresh[userId] == nil { rowsByCircle.forget(circleId: circleId, userId: userId) }
        }
        // Across a rotation, a frozen row already drawn here stays drawn a while,
        // until its member's phone re-seals it under the new key (`FrozenGrace`):
        // never a row this phone didn't draw, never past the bound, never someone
        // it doesn't show.
        let carried = frozenGrace.carried(
            circleId: circleId,
            versionKnown: (try? cryptoManager.getActiveVersion(circleId: circleId)) != nil,
            now: Date(),
            previous: frozenLocations.filter { _, loc in loc.circleId == circleId },
            current: drawnFrozen,
            staleServed: decoded.frozenStale.filter { isShown($0, in: circleId) })
        for (userId, row) in carried { frozenNow[userId] = row }
        if frozenNow != frozenLocations { frozenLocations = frozenNow }
        if !accepted.isEmpty || postureChanged || replacedByFrozen {
            memberLocations = updatedLocations
        }

        // THE subscriber-side place-alert choke point for other members. Every
        // decrypted member location this device accepts is evaluated against the
        // places this user holds alerts on, locally — no crossing is reported, no
        // circle-key hash derived, no place_shares row or wrapped place key
        // needed, so a personal place never has to be shared (and thereby exposed
        // to the whole circle) to alert on it.
        //
        // Fed AFTER the replay guard on purpose: a row the guard rejected is a
        // stale replay, and driving the alert state machine from it would let a
        // hostile server rewind a member's in/out standing and forge a crossing.
        if !accepted.isEmpty {
            await PlaceAlertEvaluator.shared.evaluate(locations: accepted)
        }

        if let warning = wrapper.keyRotation, warning.rotationNeeded {
            print("[Track] key rotation needed for circle \(circleId): \(warning.message ?? "")")
        }

        // This account's own frozen row, sealed again under the circle's current
        // key when that is due (`LastKnownReseal`), found among the rows just
        // read, as served. Off this refresh's path.
        let servedFrozen = wrapper.lastKnownServed ?? []
        Task { await LastKnownReseal.shared.run(circleId: circleId, served: servedFrozen) }

        // `fresh.keys`, NOT `accepted` — see MemberLocationRefresh. A row the
        // replay guard dropped still means this refresh heard from that member,
        // and so does a history row.
        return MemberLocationRefresh(
            refreshedUserIds: Set(fresh.keys).union(decoded.heardFrom),
            keyMissingCount: decoded.keyMissing,
            decryptionFailures: decoded.decryptFailed,
            totalReceived: wrapper.locations.count
        )
    }

    private func setupLocationSync() {
        // Subscriber-side place alerts on this device's OWN fix, on EVERY fix.
        //
        // Deliberately OUTSIDE syncLocation and ahead of it: that function's
        // privacy gates govern what is STREAMED to a circle, and returns early
        // when sharing is paused or a circle key is missing. A local alert on
        // your own private place must fire regardless — it involves no circle,
        // no share and no server, so gating it on sharing permission would
        // silently disable exactly the case the privacy model exists to enable.
        //
        // It stays on `locationUpdates` rather than moving to the gated stream
        // below for the same reason: crossing your own geofence is not something
        // the SEND policy gets a vote on, and a fix suppressed as "you have not
        // moved far enough to be worth a row" can still be the fix that carries
        // you over a place boundary.
        locationService.locationUpdates
            .debounce(for: .seconds(10), scheduler: DispatchQueue.main)
            .sink { location in
                Task {
                    await PlaceAlertEvaluator.shared.evaluateOwn(
                        latitude: location.coordinate.latitude,
                        longitude: location.coordinate.longitude,
                        timestamp: location.timestamp
                    )
                }
            }
            .store(in: &cancellables)

        // Uploads run off the GATED stream. A fix that has not moved far enough
        // arrives tagged `.liveness` and is filed by the server in the
        // latest-position table only; a fix inside the check-in window never
        // arrives here at all.
        //
        // THROTTLED, not debounced. A debounce only fires after 10 s of
        // SILENCE, so any steady stream of requests less than 10 s apart — a
        // 10 s user interval while moving, or a run of piggybacked fixes —
        // would starve uploads entirely until the stream paused, while the gate
        // believed it had sent. The throttle sends the first request at once and
        // then at most one per 10 s, keeping the best request seen in between
        // (`coalesceSendRequests`: a trail point beats a check-in).
        locationService.locationSendRequests
            .receive(on: DispatchQueue.main)
            .sink { [weak self] request in
                Task { @MainActor in self?.enqueueUpload(request) }
            }
            .store(in: &cancellables)
    }

    /// Of two send requests waiting in one throttle window, which to send.
    ///
    /// A history row is a trail point; a liveness check-in only refreshes the
    /// latest position. So history wins over liveness whatever the order, and
    /// between two of a kind the newer wins — it is where the device is now.
    nonisolated static func coalesceSendRequests(
        _ pending: LocationService.SendRequest?,
        _ incoming: LocationService.SendRequest
    ) -> LocationService.SendRequest {
        guard let pending else { return incoming }
        if pending.mode == .history && incoming.mode == .liveness { return pending }
        return incoming
    }

    /// How long until the next upload may go, given when the last one went.
    nonisolated static func uploadThrottleDelay(lastFlushAt: Date?, now: Date, interval: TimeInterval) -> TimeInterval {
        guard let last = lastFlushAt else { return 0 }
        return max(0, interval - now.timeIntervalSince(last))
    }

    private func enqueueUpload(_ request: LocationService.SendRequest) {
        // A past point is history alone, never the latest: it neither waits
        // behind the live request the throttle holds nor displaces it.
        if request.mode == .pastHistory {
            Task { await syncLocation(request.location, mode: .pastHistory) }
            return
        }
        pendingSendRequest = Self.coalesceSendRequests(pendingSendRequest, request)
        guard !uploadFlushScheduled else { return }
        let delay = Self.uploadThrottleDelay(
            lastFlushAt: lastUploadFlushAt, now: Date(), interval: Self.uploadThrottleInterval)
        if delay <= 0 {
            flushUpload()
            return
        }
        uploadFlushScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self else { return }
            self.uploadFlushScheduled = false
            self.flushUpload()
        }
    }

    private func flushUpload() {
        guard let request = pendingSendRequest else { return }
        pendingSendRequest = nil
        lastUploadFlushAt = Date()
        Task { await syncLocation(request.location, mode: request.mode) }
    }

    /// Whether realtime location streaming is currently permitted to [circleId].
    ///
    /// Mirrors the privacy gate in `syncLocation`: self-tracking (the nil-UUID
    /// pseudo-circle) is always permitted; a real circle requires a loaded
    /// privacy setting that is neither paused nor realtime-off, and FAILS CLOSED
    /// when the setting hasn't loaded yet — so an automatic background wake or a
    /// foreground nudge can't leak an exact fix to a circle the user paused.
    /// `syncLocation` applies this inline; the wake-push and foreground-nudge
    /// paths must call this so they don't bypass it.
    func mayStreamRealtime(to circleId: String) -> Bool {
        if circleId == SelfKeyManager.selfCircleUuid { return true }
        guard let settings = privacySettings[circleId],
              !settings.isPaused,
              settings.shareRealtime else { return false }
        return true
    }

    /// Prime-on-miss variant of `mayStreamRealtime` for cold-wake paths (a
    /// geofence-relaunch crossing, a wake-push location, an auto-arrival, a
    /// foreground nudge). `privacySettings` is populated only by the loadCircles
    /// fan-out — whose per-circle privacy GETs are best-effort and swallowed —
    /// so a crossing that fires BEFORE that circle's GET lands would hit the
    /// sync gate's fail-closed branch and be silently suppressed and lost. When
    /// the setting is absent, fetch it once (mirroring Android's
    /// `ensurePrivacyPrimed`) before evaluating; we only fall back to
    /// fail-closed AFTER a real fetch attempt. Self-tracking short-circuits with
    /// no fetch.
    func mayStreamRealtimePrimed(to circleId: String) async -> Bool {
        await presencePosture(for: circleId) == .allowed
    }

    /// What a presence gate could actually ESTABLISH about a circle's posture.
    ///
    /// `mayStreamRealtimePrimed` collapses this to a Bool, which is right for a
    /// caller that can only send or not send. It is wrong for one that can DEFER,
    /// because it conflates two answers that want opposite handling:
    ///
    ///   * `.denied` — we know: paused, or realtime sharing off. Never send, and
    ///     never retry; the user decided this.
    ///   * `.unknown` — we could not find out. The privacy GET failed.
    ///
    /// A Bool alone makes a network error look like an opt-out — silently, with
    /// no log and no retry — and leaves a cold-wake crossing before this circle's
    /// privacy GET landed fail-closed and lost: exactly what prime-on-miss
    /// exists to prevent.
    ///
    /// Both still SUPPRESS the send. Fail-closed is correct for a presence signal —
    /// a crossing disclosed to a circle the user paused is a real harm, and being
    /// unsure is not a licence. What matters is that the closure can be told from
    /// consent withdrawn, so it can be retried and seen to have happened.
    ///
    /// The `guard` covers a successful load that somehow left the dictionary empty
    /// as well as the throw: absent means unestablished, which is not the same
    /// answer as a posture that says no.
    enum PresencePosture {
        case allowed
        case denied
        case unknown
    }

    func presencePosture(for circleId: String) async -> PresencePosture {
        // Self-tracking has no server privacy row and never needs one.
        if circleId == SelfKeyManager.selfCircleUuid { return .allowed }

        if privacySettings[circleId] == nil {
            do {
                try await loadPrivacySettings(for: circleId)
            } catch {
                // Only the server's own "no privacy row yet" is handled inside
                // loadPrivacySettings, as the server's default posture. Reaching
                // here is anything else: a transport or server failure, or a 404
                // that isn't the server's answer (an ingress page).
                Self.presenceLog.error(
                    "privacy prime failed for circle \(circleId, privacy: .public); presence posture UNKNOWN, crossing will be deferred not dropped: \(error.localizedDescription, privacy: .public)"
                )
                return .unknown
            }
        }

        guard privacySettings[circleId] != nil else { return .unknown }
        return mayStreamRealtime(to: circleId) ? .allowed : .denied
    }

    /// `Logger`, not the `diag` helper below it: that one is `#if DEBUG`, so every
    /// failure on this path would be invisible in the builds where it matters.
    /// `SOSManager` is the precedent for an unguarded `Logger.error` on a path that
    /// has to be diagnosable from a shipped build.
    private static let presenceLog = Logger(subsystem: "com.pingolin.track", category: "PlaceAlerts")

    /// Whether this circle receives our battery level at all.
    ///
    /// Load-priming matters as much as it does above: an unprimed posture
    /// answers from the default rather than from the user's setting. The
    /// default is TRUE, matching the server column and SDKLocationStreamer,
    /// which is the code that actually strips the level on the way out.
    ///
    /// Used to decide which circles are worth waking on a low battery — where
    /// the level was stripped, nobody can evaluate anything, so the wake would
    /// be pure cost to somebody else's battery.
    func mayShareBattery(with circleId: String) async -> Bool {
        if circleId == SelfKeyManager.selfCircleUuid { return false }
        if privacySettings[circleId] == nil {
            try? await loadPrivacySettings(for: circleId)
        }
        return privacySettings[circleId]?.sendsBattery ?? true
    }

    /// Upload one fix to every eligible target.
    ///
    /// Every target one fix is sent to, in send order.
    ///
    /// The self copy comes FIRST and is unconditional: self-tracking has no
    /// per-circle "share realtime" toggle, and nothing about any circle —
    /// deleted, paused, refusing — may cost the user their own copy. Then every
    /// circle in `circleIds`, which is the list the last successful
    /// `GET /circles` returned (a failed fetch serves the cached copy of that
    /// same list), so a circle the server stopped listing drops out at the next
    /// successful load. A circle whose privacy posture has not loaded is skipped:
    /// FAIL CLOSED, matching the android heartbeat, so a possibly-exact fix never
    /// goes to a circle on the assumption it is allowed.
    nonisolated static func uploadTargets(
        selfId: String,
        circleIds: [String],
        privacy: [String: PrivacySettings]
    ) -> [String] {
        var targets: [String] = [selfId]
        for id in circleIds where id != selfId {
            guard let settings = privacy[id] else { continue }
            guard !settings.isPaused, settings.shareRealtime else { continue }
            targets.append(id)
        }
        return targets
    }

    /// `mode` decides which of two SDK calls each target gets, and nothing else:
    /// the target list, the privacy gates, the battery reading and the envelope
    /// are identical either way, because a liveness check-in differs from an
    /// ordinary send by one flag on the wire and nothing more.
    private func syncLocation(_ location: CLLocation, mode: LocationService.SendMode) async {
        // Solo users (no active circle) still get tracked under the
        // nil-UUID self-tracking pseudo-circle: without it every
        // `didUpdateLocations` event from the distance pump would be dropped
        // silently for solo users, and Send-Location taps would be the only
        // way anything reached the backend.
        //
        // EVERY eligible target, not just one: one envelope to self plus every
        // eligible circle, as the Android app sends (LocationTrackingService,
        // and the heartbeat worker's `targets`), so the two clients agree about
        // what a location upload is. Sending to the active circle OR self alone
        // would let one copy go stale: with no active circle, the person's row
        // in the circle roster would age while their own history stayed
        // current, and the map would draw a trail segment to a position hours
        // old; with an active circle, the self copy would go dark instead.
        //
        // Self is unconditional: self-tracking has no per-circle "share
        // realtime" toggle, because there are no other members to share with.
        var targetCircleIds = Self.uploadTargets(
            selfId: SelfKeyManager.selfCircleUuid,
            circleIds: circles.map(\.id),
            privacy: privacySettings
        )

        // Kept for the fields below that are per-upload rather than per-target
        // (battery, and the LocationData record). Naming it `primary` rather
        // than `target` so nobody reads it as "the one place this goes".
        let primaryCircleId = activeCircle?.id ?? SelfKeyManager.selfCircleUuid

        guard let userId = AuthManager.shared.userId,
              let deviceId = AuthManager.shared.deviceId else { return }

        // A check-in re-sends a HELD fix, maybe taken while this phone was
        // offline; a pause set and ended elsewhere meanwhile reached it by no
        // wake. After an offline stretch, the circles not read since then wait
        // for one light refresh, shared and bounded
        // (`PrivacyReadAfterOffline`); one still unread is skipped by this
        // check-in, and the next tries again. Personal history never waits. A
        // send that went meanwhile proved this phone alive with a newer fix.
        if mode == .liveness {
            let sentBefore = SDKLocationStreamer.lastSuccessfulSendMs
            targetCircleIds = await checkInTargetsAfterOffline(targetCircleIds, owner: userId)
            if SDKLocationStreamer.lastSuccessfulSendMs != sentBefore { return }
        }

        let locationData = LocationData(
            circleId: primaryCircleId,
            userId: userId,
            deviceId: deviceId,
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            altitude: location.altitude,
            speed: location.speed >= 0 ? location.speed : nil,
            heading: location.course >= 0 ? location.course : nil,
            accuracy: location.horizontalAccuracy,
            batteryLevel: locationService.getBatteryLevel(),
            // A check-in carries the CURRENT time, not the fix's. The map and
            // the inactivity logic both read the decrypted timestamp, and a
            // check-in is very often built from a fix Core Location had already
            // cached — so sending the fix's own time would land a "this phone is
            // alive now" message stamped several minutes ago and defeat the
            // whole point. Stamped here, at the moment of the send, rather than
            // at the moment of the decision, so the 10 s upload throttle
            // upstream cannot age it either. A history row keeps the fix's time: it is a
            // trail point and belongs where the device actually was.
            timestamp: LocationService.payloadTimestamp(
                mode: mode,
                fixTimestamp: location.timestamp,
                now: Date()
            )
        )

        // Same reading, handed to the monitor. This path runs on background
        // location wake-ups, where an in-app NotificationCenter observer does
        // not, so it is what lets a phone that is draining in someone's pocket
        // ask the server to wake its watchers.
        if let level = locationData.batteryLevel {
            let charging = locationService.isCharging()
            Task { @MainActor in
                await MonitoringManager.shared.noteOwnBattery(level: level, isCharging: charging)
            }
        }

        // Hand the location to the SDK gRPC streamer. It envelope-
        // encrypts (one ciphertext + per-circle wrapped msg_key) and
        // forwards to the server. start() must have run at login.
        let sdkLocation = PingolinTrackSDK.Location(
            latitude: locationData.latitude,
            longitude: locationData.longitude,
            altitude: locationData.altitude,
            speed: locationData.speed,
            heading: locationData.heading,
            accuracy: locationData.accuracy,
            timestamp: Int64(locationData.timestamp.timeIntervalSince1970 * 1000),
            // The current battery is no reading of a past point's.
            batteryLevel: mode == .pastHistory ? nil : locationData.batteryLevel.map { UInt8(min(max($0, 0), 100)) },
            isCharging: nil as Bool?
        )
        // One send per target. The streamer builds a single-target envelope
        // (`targetIds: [circleId]`), which is the same wire shape the Android
        // app's per-target fallback uses, so N sends here are N valid envelopes
        // rather than one malformed batch.
        //
        // The liveness arm fans out identically — one call per target, the same
        // list, the same envelope. Sending a check-in to self alone would leave
        // every circle roster ageing while "Your Location" stayed current, which
        // is the exact split this loop exists to prevent.
        //
        // No target gets a fix taken while this account was not sharing with
        // it, by the fix's own time: a check-in's held fix included. Self is
        // never asked about. A past point is judged by the streamer, which keeps
        // it while it waits for a row read since it was taken rather than
        // dropping it for what that read will tell.
        for targetId in targetCircleIds {
            if mode != .pastHistory,
               CirclePauseRecord.shared.withholds(circleId: targetId, capturedAt: location.timestamp, owner: userId) {
                continue
            }
            switch mode {
            case .history:
                try? SDKLocationStreamer.shared.send(circleId: targetId, location: sdkLocation)
            case .liveness:
                try? SDKLocationStreamer.shared.sendLiveness(circleId: targetId, location: sdkLocation,
                                                             capturedAt: location.timestamp)
            case .pastHistory:
                try? SDKLocationStreamer.shared.sendPastHistory(circleId: targetId, location: sdkLocation)
            }
        }
    }

    /// A check-in's targets after an offline stretch: all of them when every
    /// circle has been read since; otherwise one light refresh first, and
    /// those still unread left out.
    private func checkInTargetsAfterOffline(_ targets: [String], owner: String) async -> [String] {
        let record = CirclePauseRecord.shared
        guard targets.contains(where: { record.unreadSinceOffline(circleId: $0, owner: owner) }) else { return targets }
        await PrivacyReadAfterOffline.shared.refresh()
        return targets.filter { !record.unreadSinceOffline(circleId: $0, owner: owner) }
    }

    // MARK: - Refresh records

    /// What this process's records imports found for a circle. Nothing before
    /// the first: its deliveries and rotations wait for one.
    enum RecordsState: Equatable {
        /// No record served or held, and no head seen: a circle without refresh
        /// records.
        case legacy
        /// A head proves records exist, and none is held yet: it waits for
        /// them.
        case latched
        /// Its records were imported. `forked`: seal, deliver and rotate
        /// nothing.
        case imported(forked: Bool)
    }

    /// By circle key (`CanonicalId.key`), from this process's records imports.
    private(set) var recordsState: [String: RecordsState] = [:]
    /// Each circle's key chain from the last key import, by circle key: its
    /// records import walks it for the circle's secret.
    private var keyChainsLastImport: [String: [KeyChainLinkData]] = [:]
    /// The link of each key change of this device's that the server took, by
    /// circle key, until an import decides its version (as on the web). Every
    /// records import gets it with the fetched chain, so this device's own
    /// record is judged with its own link even when the key fetch after the
    /// change failed. Not written into `keyChainsLastImport`: a fetch replaces
    /// that, and one answered before the change but stored after it would
    /// drop the link again.
    private var ownLinks: [String: [KeyChainLinkData]] = [:]
    /// The rejected version a repair is due for, by circle key, from the last
    /// import (with the repair budget applied).
    private var repairsDue: [String: RecordVersionStatus] = [:]
    /// The listed members the record a new one goes after names, included or
    /// pending, when this device rejected that record (the SDK's
    /// `tipNamedListed`; empty when it is the head), by circle key, from the
    /// last import. EVERY recorded change names them, pending those it can't
    /// include, a repair or not.
    private var tipNamedListed: [String: [String]] = [:]
    /// The circles whose change the SDK answered "not yet" (import this
    /// circle's records first, `RecordedRotation.notYet`): none is tried again
    /// before an import of their records.
    private var changesAwaitingImport = ImportWaits()
    /// The SDK's answer for this account's own row (`ownRowState`), by circle
    /// key: read again after each records import and each roster pass, the two
    /// things it depends on.
    private var ownRows: [String: SelfAdmission.OwnRow] = [:]
    /// When a light pass may run the records import again for a circle an
    /// import left owing one (`circlesOwingRecordsImport`), by circle key.
    private var recordsImportRetry = RecordsImportRetry()
    /// Records imports under way: a light pass starts none while one runs.
    private var recordsImportsRunning = 0

    /// Circles by key, as `repairsDue`, each waiting for an import of
    /// its records. Pure, for tests.
    struct ImportWaits: Equatable {
        private(set) var circles: Set<String> = []

        func waits(_ circleId: String) -> Bool { circles.contains(CanonicalId.key(circleId)) }
        mutating func wait(_ circleId: String) { circles.insert(CanonicalId.key(circleId)) }
        /// An import of its records ran, or the circle is gone from here.
        mutating func end(_ circleId: String) { circles.remove(CanonicalId.key(circleId)) }
        mutating func removeAll() { circles.removeAll() }
    }

    func recordsState(for circleId: String) -> RecordsState? { recordsState[CanonicalId.key(circleId)] }

    /// Each circle an import left owing one, by circle key, with when a light
    /// pass may run the next: `first` after the first such import, twice as
    /// long after each one more, at most `longest`. Ends once the circle owes
    /// none: an import decided it, or it is gone. Pure, for tests.
    struct RecordsImportRetry: Equatable {
        static let first: TimeInterval = 30
        static let longest: TimeInterval = 15 * 60

        struct Wait: Equatable {
            var imports: Int
            var until: Date
        }

        private(set) var waits: [String: Wait] = [:]

        func due(_ circleId: String, now: Date) -> Bool {
            waits[CanonicalId.key(circleId)].map { now >= $0.until } ?? true
        }

        /// An import ran (any): `owing`, the circles still owing one after it.
        mutating func imported(owing: [String], at now: Date) {
            let owing = Set(owing.map(CanonicalId.key))
            waits = waits.filter { owing.contains($0.key) }
            for key in owing {
                let imports = (waits[key]?.imports ?? 0) + 1
                waits[key] = Wait(imports: imports, until: now.addingTimeInterval(Self.delay(after: imports)))
            }
        }

        static func delay(after imports: Int) -> TimeInterval {
            min(first * pow(2, Double(max(imports, 1) - 1)), longest)
        }

        mutating func removeAll() { waits.removeAll() }
    }

    /// Pure: the listed circles that owe a records import in this process: no
    /// import has decided one yet (`recordsState`, by circle key), so it stands
    /// `.wait`. Never one an import decided (legacy, latched, imported or
    /// forked): it waits, or doesn't, as decided. Never the personal key's slot
    /// (no records), nor a circle this phone holds no key for: it has nothing
    /// to deliver or seal, and the install of its key runs the import.
    nonisolated static func circlesOwingRecordsImport(_ circleIds: [String], states: [String: RecordsState],
                                                      holdsKey: (String) -> Bool) -> [String] {
        circleIds.filter { id in
            states[CanonicalId.key(id)] == nil && !CanonicalId.isPersonalSlot(id) && holdsKey(id)
        }
    }

    func circlesOwingRecordsImport() -> [String] {
        Self.circlesOwingRecordsImport(circles.map(\.id), states: recordsState,
                                       holdsKey: { [cryptoManager] in cryptoManager.hasCircleKey(circleId: $0) })
    }

    /// A light pass runs the records import too while a listed circle owes one
    /// and its retry time has come: a circle made here before its import
    /// answered, or one whose import got no answer or "not now". Until then
    /// it stands `.wait`: nobody who joins it is given its key, its
    /// invitations carry none, and its security refreshes wait.
    func recordsImportDue(now: Date) -> Bool {
        Self.recordsImportDue(owing: circlesOwingRecordsImport(), retry: recordsImportRetry,
                              running: recordsImportsRunning > 0, now: now)
    }

    /// Pure: never while an import runs (what that one leaves owing waits for
    /// its retry time), else when a circle owing one is due.
    nonisolated static func recordsImportDue(owing: [String], retry: RecordsImportRetry, running: Bool,
                                             now: Date) -> Bool {
        !running && owing.contains { retry.due($0, now: now) }
    }

    /// Where a circle stands for deliveries, rotations and waiting changes.
    enum RecordsStanding: Equatable {
        /// A circle with no refresh records: the rules without records apply.
        case noRecords
        /// Its records imported in this process, not forked: the SDK's
        /// eligibility rule and the records.
        case recorded
        /// Not imported in this process yet, withheld (latched) or forked:
        /// nothing that needs them happens.
        case wait
    }

    /// Pure: a circle's standing from this process's import and whether the
    /// SDK holds records for it (one it learned of since the import is not
    /// "no records" any more).
    nonisolated static func standing(_ state: RecordsState?, hasRecords: Bool) -> RecordsStanding {
        switch state {
        case .legacy? where !hasRecords: return .noRecords
        case .imported(forked: false)?: return .recorded
        default: return .wait
        }
    }

    /// An owner's or admin's eject from below, at once, on a device that
    /// doesn't hold the circle's current version: only when that version's
    /// record is this device's head (accepted or reference, never waiting or
    /// rejected) and not forked. The circle's name never blocks it
    /// (`nameToSeal`). The SDK builds it from that record and links down to
    /// the highest version held within the floors. Pure.
    nonisolated static func ejectsFromBelow(standing: RecordsStanding, head: Int32, circleVersion: Int,
                                            holdsCurrent: Bool, ownerOrAdmin: Bool) -> Bool {
        standing == .recorded && !holdsCurrent && ownerOrAdmin && head > 0 && Int(head) == circleVersion
    }

    /// What a recorded change seals under the new key as the circle's name.
    enum NameToSeal: Equatable {
        /// The name this device reads, sealed again.
        case name(String)
        /// None: nothing is sent for it, and the server keeps the stored one
        /// (readable through the key chain, fixable by a rename).
        case keepStored

        /// What the SDK is given to seal: a sealed empty name is never sent.
        var plaintext: String {
            if case .name(let name) = self { return name }
            return ""
        }
    }

    /// Pure: the name a recorded change seals: the one that opened under the
    /// key in use, when that is the version the change replaces (`sealable`,
    /// see `sealableName`). A name this device reads only under another
    /// version is not sealed, and never holds the change back: the server
    /// keeps the stored one. Unreadable: the change goes without one while
    /// this device holds what it needs (`holds`, see `holdsForTheName`: the
    /// key in use, or for a repair the version it answers; any member can
    /// plant a name nobody opens), as an eject from below does; only while it
    /// lacks that does it wait (nil).
    ///
    /// A repair answering a MISATTRIBUTED version seals none: it runs from
    /// below, and the key in use there is held by the member who
    /// misattributed, who could have planted a name under it.
    nonisolated static func nameToSeal(readable: String?, sealable: String?, ejectingFromBelow: Bool,
                                       holds: Bool, misattributionRepair: Bool = false) -> NameToSeal? {
        if misattributionRepair { return .keepStored }
        if let sealable { return .name(sealable) }
        if readable != nil { return .keepStored }
        return ejectingFromBelow || holds ? .keepStored : nil
    }

    /// Pure: the name a rotation may seal again (as the web client decides
    /// it): the one it read, only when the version that opened it is the one
    /// this device seals under (`isCurrent`, the SDK's one test) AND that is
    /// the version the rotation replaces. Otherwise none: a member removed at
    /// the last rotation, with the server, could have sealed it under a key
    /// they still hold, and a rotation must not carry it on.
    nonisolated static func sealableName(readable: String?, openedUnder: Int32?, isCurrent: (Int32) -> Bool,
                                         sealingVersion: Int?, replacedVersion: Int) -> String? {
        guard let readable, let openedUnder, isCurrent(openedUnder), sealingVersion == replacedVersion else {
            return nil
        }
        return readable
    }

    /// Pure: the name a legacy rotation's or eject's request carries: the
    /// one sealed from `sealable`, or none, and the server keeps the stored name.
    nonisolated static func legacyEncryptedName(sealable: String?, sealed: EncryptedData) -> EncryptedBlobRequest? {
        guard sealable != nil else { return nil }
        return EncryptedBlobRequest(nonce: sealed.nonce, ciphertext: sealed.ciphertext)
    }

    /// `sealableName` for a circle as listed (its version is the one replaced),
    /// with a device's own keys.
    nonisolated static func sealableName(_ circle: Circle, crypto: CryptoManager) -> String? {
        sealableName(
            readable: circle.readableName, openedUnder: circle.nameOpenedUnder,
            isCurrent: { crypto.isCurrentKeyVersion(circleId: circle.id, keyVersion: $0) },
            sealingVersion: (try? crypto.getActiveVersion(circleId: circle.id)).map { Int($0) },
            replacedVersion: circle.keyVersion)
    }

    private func sealableName(_ circle: Circle) -> String? {
        Self.sealableName(circle, crypto: cryptoManager)
    }

    /// Pure: whether a change repairs a version rejected as MISATTRIBUTED:
    /// a repair, answering that problem.
    nonisolated static func repairsMisattribution(mode: RotationMode, answering: RecordProblem?) -> Bool {
        mode == .recorded(.repair) && answering == .misattributed
    }

    /// Pure: whether the circle's name holds a rotation back. Only while this
    /// device doesn't hold what the change needs (`holds`, see `holdsForTheName`):
    /// a name nobody opens holds nothing back otherwise, since any member can
    /// plant one, and the change goes without a name. Never for a repair
    /// answering a MISATTRIBUTED version: that version's key, and the name
    /// sealed under it, may have reached nobody here.
    nonisolated static func nameHoldsBack(holds: Bool, mode: RotationMode, answering: RecordProblem?) -> Bool {
        !holds && !repairsMisattribution(mode: mode, answering: answering)
    }

    /// Pure: what a change must hold before the circle's name stops holding it
    /// back, or an unreadable name may go without one. A repair: the version it
    /// answers (`holdsWhatARepairNeeds`, the same test `holdsWhatItRotates`
    /// applies). Any other change: the key in use. A repair is for a version
    /// this device holds but rejected, so it seals under an older one, and the
    /// key in use is never the version it answers: judged by that, every repair
    /// would wait for good.
    nonisolated static func holdsForTheName(mode: RotationMode, keyInUse: Bool, repairNeeds: Bool) -> Bool {
        mode == .recorded(.repair) ? repairNeeds : keyInUse
    }

    /// `holdsForTheName` for a circle in `mode`, on `due`: the repair entry the
    /// change answers.
    private func holdsForTheName(_ circle: Circle, mode: RotationMode, due: RecordVersionStatus?) -> Bool {
        Self.holdsForTheName(
            mode: mode, keyInUse: holdsKeyInUse(circle.id),
            repairNeeds: Self.holdsWhatARepairNeeds(
                held: cryptoManager.newestHeldVersion(circleId: circle.id).map { Int($0) },
                circleKeyVersion: circle.keyVersion, answering: due?.problem))
    }

    /// `nameHoldsBack` for a circle, on `due`: the repair entry the change
    /// would answer, the one it is then built on.
    private func nameHoldsBack(_ circle: Circle, due: RecordVersionStatus?) -> Bool {
        let mode = rotationMode(for: circle, due: due)
        return Self.nameHoldsBack(holds: holdsForTheName(circle, mode: mode, due: due), mode: mode,
                                  answering: due?.problem)
    }

    /// Whether an invitation from this account lets someone in where it
    /// counts: it is the circle's owner or an admin on the server, and on a
    /// circle with records an owner or admin in its chain too, since the other
    /// apps take an invitee in on a statement signed by one (the SDK's
    /// eligibility rule): a server-only admin's would leave the invitee
    /// waiting. Nothing while the circle's records wait here.
    func invitesTakeEffect(_ circle: Circle) -> Bool {
        Self.invitesTakeEffect(serverOwnerOrAdmin: isOwnerOrAdmin(circle), standing: standing(of: circle.id),
                               chainOwnerOrAdmin: removesInTheChain(circle.id))
    }

    nonisolated static func invitesTakeEffect(serverOwnerOrAdmin: Bool, standing: RecordsStanding,
                                              chainOwnerOrAdmin: Bool) -> Bool {
        guard serverOwnerOrAdmin else { return false }
        switch standing {
        case .noRecords: return true
        case .recorded: return chainOwnerOrAdmin
        case .wait: return false
        }
    }

    /// Whether this account may remove someone in the circle's records: an
    /// owner or admin in the chain. A server-only admin (promoted on the
    /// server only, e.g. by a claimant) removes without a new key; the next
    /// rotation records the departure.
    func removesInTheChain(_ circleId: String) -> Bool {
        guard let me = AuthManager.shared.userId else { return false }
        let role = cryptoManager.chainRole(circleId: circleId, userId: me)
        return role == .owner || role == .admin
    }

    func ejectsFromBelow(_ circle: Circle) -> Bool {
        let head = cryptoManager.refreshHeadVersions()
            .first { $0.key.caseInsensitiveCompare(circle.id) == .orderedSame }?.value ?? 0
        return Self.ejectsFromBelow(
            standing: standing(of: circle.id), head: head, circleVersion: circle.keyVersion,
            holdsCurrent: holdsCurrentVersion(for: circle.id), ownerOrAdmin: isOwnerOrAdmin(circle) && mayRotate(circle))
    }

    func standing(of circleId: String) -> RecordsStanding {
        Self.standing(recordsState(for: circleId), hasRecords: cryptoManager.circleHasRefreshRecords(circleId: circleId))
    }

    /// This account's own row under the SDK's eligibility rule: read only on
    /// a circle whose records this process imported, not forked, with its
    /// last roster pass; anything else is no answer.
    func ownRowState(_ circle: Circle) -> SelfAdmission.OwnRow {
        let key = CanonicalId.key(circle.id)
        if let known = ownRows[key] { return known }
        guard let me = AuthManager.shared.userId else { return .notKnown }
        let listing = recordMemberRows(for: circle.id)
        let row = SelfAdmission.ownRow(importedNotForked: standing(of: circle.id) == .recorded && listing != nil, me: me) {
            try cryptoManager.refreshEligibility(circleId: circle.id, members: listing?.rows.map(\.sdkMember) ?? [],
                                                 purpose: .include)
        }
        ownRows[key] = row
        return row
    }

    /// No record is built for this account while the SDK doesn't count its
    /// own row (after its password reset, until its own admission is
    /// served): the SDK would refuse to build it.
    func keyChangesMayBuild(_ circle: Circle) -> Bool {
        let standing = standing(of: circle.id)
        return SelfAdmission.keyChangesMayBuild(standing: standing, ownRow: standing == .recorded ? ownRowState(circle) : .notKnown)
    }

    /// Receive-only on this device: the statement rule, lifted on a circle
    /// with records once the SDK counts this account's own row; never because
    /// a statement binds its keys.
    func selfIsReceiveOnly(_ circleId: String) -> Bool {
        let statementRule = membership[circleId]?.selfIsReceiveOnly ?? false
        guard statementRule, let circle = circles.first(where: { $0.id == circleId }) else { return statementRule }
        return SelfAdmission.receiveOnly(statementRule: statementRule, ownRow: ownRowState(circle))
    }

    /// After a password reset: an owner's or admin's own admission of its
    /// CURRENT keys, where the SDK doesn't count this account's own row, by
    /// the retry rule of `SelfAdmission.due`. It reaches this account's row
    /// only from a roster that serves it, never from here.
    private func publishSelfAdmissionsIfDue() async {
        guard let me = AuthManager.shared.userId else { return }
        for circle in circles where !CanonicalId.isPersonalSlot(circle.id) {
            guard SelfAdmission.due(ownRow: ownRowState(circle), listedOwnerOrAdmin: isOwnerOrAdmin(circle),
                                    holdsKeyInUse: holdsKeyInUse(circle.id)) else { continue }
            let role = circle.isOwner ? "owner" : "admin"
            guard SelfAdmission.mayAttempt(SelfAdmission.lastAttempt(circleId: circle.id, owner: me),
                                           keyVersion: circle.keyVersion, role: role, now: Date()) else { continue }
            let own = ownIdentity(userId: me)
            guard let sharing = own.sharingKeyHex, let signing = own.signingKeyHex else { continue }
            var failure: Error?
            do {
                let signed = try cryptoManager.signMembershipAdmission(
                    circleId: circle.id, signerUserId: me, subjectUserId: me,
                    subjectSharingPublicKeyHex: sharing, subjectSigningPublicKeyHex: signing)
                try await api.storeMemberStatement(
                    circleId: circle.id, userId: me, statementHex: signed.statementHex, signatureHex: signed.signatureHex)
            } catch {
                failure = error
            }
            let outcome = SelfAdmission.outcome(failure)
            SelfAdmission.note(.init(keyVersion: circle.keyVersion, role: role, outcome: outcome, at: Date()),
                               circleId: circle.id, owner: me)
            if outcome == .stored {
                Self.keyLog.info("circle \(circle.id, privacy: .public): this account's own admission is stored")
                try? await loadMembers(for: circle.id)
            } else {
                Self.keyLog.error("circle \(circle.id, privacy: .public): this account's own admission was not stored (\(outcome.rawValue, privacy: .public)): \(String(describing: failure), privacy: .public)")
            }
        }
    }

    /// The member list the SDK is given for a circle, from its LAST roster pass
    /// and never a later fetch. Nil before one.
    func recordMemberRows(for circleId: String) -> (rows: [RecordMemberRow], complete: Bool)? {
        guard let me = AuthManager.shared.userId, let candidates = membershipCandidates[circleId],
              let result = membership[circleId] else { return nil }
        let own = ownIdentity(userId: me)
        guard let sharing = own.sharingKeyHex, let signing = own.signingKeyHex else { return nil }
        let complete = !incompleteRosters.contains(circleId)
        let record = KeyDeliveryApprovals.shared.record(owner: me, circleId: circleId)
        let roles = (rosterWraps[circleId] ?? [:]).compactMapValues { Self.circleRole($0.role) }
        let rows = RecordMembers.rows(
            me: me, myKeys: MemberKeyPair(sharingKeyHex: sharing, signingKeyHex: signing),
            candidates: candidates, roles: roles, complete: complete, verdicts: result.verdicts,
            receiveOnlyKeys: record.receiveOnlyKeys,
            pinned: { [cryptoManager] userId in
                cryptoManager.pinnedSharingKey(circleId: circleId, userId: userId).flatMap { pinnedSharing in
                    cryptoManager.pinnedSigningKey(circleId: circleId, userId: userId)
                        .map { MemberKeyPair(sharingKeyHex: pinnedSharing, signingKeyHex: $0) }
                }
            },
            chosen: { record.entries[$0]?.isChosen == true })
        return (rows, complete)
    }

    /// Delivery eligibility for the key an invitation carries (wrapped at
    /// invite time, handed over by the server on accept): on a circle with
    /// records, only this device's own fresh invitation as an owner or admin
    /// in the chain counts, so only then does it carry the key, with the
    /// records imported here and not forked. Otherwise it goes without one:
    /// the invitee waits, and the late joiner's question asks. A circle
    /// without records: it always carries the key. The caller checks the
    /// version (`holdsCurrentKey`).
    func invitationCarriesKey(circleId: String) -> Bool {
        guard let me = AuthManager.shared.userId else { return false }
        return Self.invitationCarriesKey(standing: standing(of: circleId),
                                         myChainRole: cryptoManager.chainRole(circleId: circleId, userId: me))
    }

    nonisolated static func invitationCarriesKey(standing: RecordsStanding, myChainRole: CircleRole?) -> Bool {
        switch standing {
        case .noRecords: return true
        case .recorded: return myChainRole == .owner || myChainRole == .admin
        case .wait: return false
        }
    }

    /// What the chain says now about someone a waiting change would sign for
    /// (`PendingChangeKinds.removedSinceTheTap`). Before this process's
    /// records import, or while forked or waiting for records: not known, and
    /// the change waits.
    func removalCheck(userId: String, circleId: String) -> PendingChangeKinds.RemovalCheck {
        switch standing(of: circleId) {
        case .noRecords:
            return .noRecords
        case .recorded:
            guard var rows = recordMemberRows(for: circleId)?.rows else { return .unknown }
            if !rows.contains(where: { $0.userId.caseInsensitiveCompare(userId) == .orderedSame }) {
                // Not on the list (an invitee): the chain's word about them all the same.
                rows.append(RecordMemberRow(userId: userId, keys: nil, confirmed: false, listed: false,
                                            listedRole: nil, statements: [], personConfirmedKeys: false,
                                            serverSaysKeyless: false))
            }
            guard let answers = try? cryptoManager.refreshEligibility(
                      circleId: circleId, members: rows.map(\.sdkMember), purpose: .include),
                  let answer = answers.first(where: { $0.userId.caseInsensitiveCompare(userId) == .orderedSame })
            else { return .unknown }
            return .lastWord(removedAt: answer.removedAtVersion)
        case .wait:
            return .unknown
        }
    }

    /// The late joiner's question, on this account's device when it is the
    /// one asked (`LateJoiner.ask`). Only on a circle whose records were
    /// imported here, not forked, from a complete roster; queued once per
    /// member (`KeyDeliveryApprovals.ask`), and never again for an invitation
    /// answered here (and never while the ledger that keeps the answers can't
    /// be read). "Let them in" signs an admission (a waiting let-in); an
    /// admission from any device withdraws the question here.
    func askLateJoinerQuestions(circleId: String) {
        guard let me = AuthManager.shared.userId, standing(of: circleId) == .recorded,
              RefreshLedger.shared.isReadable(account: me),
              let circle = circles.first(where: { $0.id == circleId }), let circleName = circle.readableName,
              let listing = recordMemberRows(for: circleId), listing.complete,
              let answers = try? cryptoManager.refreshEligibility(
                  circleId: circleId, members: listing.rows.map(\.sdkMember), purpose: .include) else { return }
        let myChainRole = cryptoManager.chainRole(circleId: circleId, userId: me)
        let approvals = KeyDeliveryApprovals.shared
        let roster = rosters[circleId] ?? []
        let queued = approvals.requests.filter { request in
            guard request.circleId == circleId, case .lateJoiner = request.reason else { return false }
            return true
        }
        let eligible = Dictionary(answers.map { ($0.userId.lowercased(), $0.eligible) }, uniquingKeysWith: { first, _ in first })
        let closed = Set(LateJoiner.closed(queued: queued.map(\.userId), eligible: eligible))
        // Closed elsewhere is answered: its invitation is never asked about
        // again, on any other row.
        for request in queued where closed.contains(request.userId) {
            approvals.askAgain(request)
            KeyDeliveryApprovals.keepLateJoinerAnswer(request)
        }
        let answered = RefreshLedger.shared.circle(account: me, circleId: circleId).lateJoinerAnswered
        let record = approvals.record(owner: me, circleId: circleId)
        // Every question the pass finds first, with no cap and nothing pending,
        // then which are asked (`LateJoiner.chosen`): not the rows' order.
        var found: [(member: String, ask: LateJoiner.Ask, request: KeyDeliveryRequest)] = []
        for row in listing.rows where row.confirmed && row.userId.caseInsensitiveCompare(me) != .orderedSame {
            guard let keys = row.keys,
                  let answer = answers.first(where: { $0.userId.caseInsensitiveCompare(row.userId) == .orderedSame }),
                  let invitation = Self.lateJoinerInvitation(row.statements, of: row.userId, circleId: circleId, me: me,
                                                             checker: cryptoManager, record: record) else { continue }
            let signer = roster.first { $0.userId.caseInsensitiveCompare(invitation.signerUserId) == .orderedSame }
            guard let ask = LateJoiner.ask(
                me: me, myChainRole: myChainRole, invitation: invitation, standing: LateJoiner.Standing(answer),
                signerChainRole: cryptoManager.chainRole(circleId: circleId, userId: invitation.signerUserId),
                signerName: signer?.displayName, answered: answered, pendingCapped: 0,
                listedKeys: listedKeys(for: row.userId, in: circleId)) else { continue }
            guard let name = roster.first(where: { $0.userId.caseInsensitiveCompare(row.userId) == .orderedSame })?
                .displayName else { continue }
            found.append((row.userId, ask, KeyDeliveryRequest(
                circleId: circleId, circleName: circleName, userId: row.userId, displayName: name, email: nil,
                reason: .lateJoiner(ask), sharingKeyHex: keys.sharingKeyHex, signingKeyHex: keys.signingKeyHex)))
        }
        // Raised already: they keep their place. One raised about a member the
        // pass doesn't find still holds its invitation, and its place in the cap.
        let raised = approvals.requests.filter { request in
            guard request.circleId == circleId, case .lateJoiner = request.reason else { return false }
            return true
        }
        let foundKeys = Set(found.map { CanonicalId.key($0.member) })
        let outside: [LateJoiner.Ask] = raised.compactMap { request in
            guard !foundKeys.contains(CanonicalId.key(request.userId)), case .lateJoiner(let ask) = request.reason else { return nil }
            return ask
        }
        let asked = Set(LateJoiner.chosen(found.map { ($0.member, $0.ask) },
                                          raised: Set(raised.map { CanonicalId.key($0.userId) }),
                                          pending: outside.map(\.invitation),
                                          pendingCapped: outside.filter(\.capped).count).map(CanonicalId.key))
        for question in found where asked.contains(CanonicalId.key(question.member)) {
            approvals.ask(question.request)
        }
    }

    /// The invitation a member joined with (kind 1 or 2), as the late
    /// joiner's question counts it: the first among their statements as
    /// served that is an invitation to this circle, of them (kind 1), and
    /// holds under the key this device trusts for its signer: any of this
    /// account's own, else the signer's pin. One that doesn't is the server's
    /// word, and never says who is asked, what the cap counts or whom the
    /// question names. Pure but for the checks.
    ///
    /// After a password reset, this account's own statement signed before it
    /// is marked so (`signedBeforeReset`), an admission of them included: a
    /// restored key verifies it, or, when no held key does, this device's OWN
    /// approval of them made before the reset names it by id
    /// (`keptApproval`). Nothing else that doesn't verify ever counts.
    nonisolated static func lateJoinerInvitation(_ statements: [SignedStatementRecord], of member: String, circleId: String,
                                                 me: String, checker: MembershipStatementChecking,
                                                 record: CircleApprovalRecord? = nil) -> LateJoiner.Invitation? {
        for signed in statements {
            guard let statement = try? checker.parse(signed.statementHex),
                  statement.circleId.caseInsensitiveCompare(circleId) == .orderedSame else { continue }
            let mine = statement.signerUserId.caseInsensitiveCompare(me) == .orderedSame
            let invitation = statement.kind == .invitationToAccount || statement.kind == .invitationToEmail
            guard invitation || (mine && statement.kind == .admission),
                  statement.kind == .invitationToEmail
                    || statement.subjectUserId?.caseInsensitiveCompare(member) == .orderedSame,
                  let person = statement.subjectUserId ?? statement.subjectEmail else { continue }
            var beforeReset = false
            let holds: Bool
            if mine {
                switch checker.ownSigner(statementHex: signed.statementHex, signatureHex: signed.signatureHex) {
                case .currentKey?:
                    holds = invitation
                case .previousKey?:
                    holds = true
                    beforeReset = true
                default:
                    holds = keptApproval(record, of: member, statementId: statement.statementId)
                    beforeReset = holds
                }
            } else if invitation, let pinned = checker.pinnedSigningKey(circleId: circleId, userId: statement.signerUserId) {
                holds = (try? checker.verify(statementHex: signed.statementHex, signatureHex: signed.signatureHex,
                                             signerKeyHex: pinned)) == true
            } else {
                holds = false
            }
            guard holds else { continue }
            let bound = statement.subjectSharingPublicKeyHex.flatMap { sharing in
                statement.subjectSigningPublicKeyHex.map { MemberKeyPair(sharingKeyHex: sharing, signingKeyHex: $0) }
            }
            return LateJoiner.Invitation(statementId: statement.statementId, signerUserId: statement.signerUserId,
                                         person: person, issuedAt: statement.issuedAt,
                                         signedBeforeReset: beforeReset ? true : nil, boundKeys: bound)
        }
        return nil
    }

    /// Pure: this device's own approval of `member`, by a statement or its
    /// person's own choice (never a `preRound2Seed`), names `statementId`.
    /// Only such an approval stands behind an own statement no held key
    /// verifies any more.
    nonisolated static func keptApproval(_ record: CircleApprovalRecord?, of member: String, statementId: String) -> Bool {
        guard let record,
              let origin = record.entries.first(where: { CanonicalId.same($0.key, member) })?.value,
              origin == .statement || origin == .ownAction else { return false }
        let ids = record.statementIds.first(where: { CanonicalId.same($0.key, member) })?.value ?? []
        return ids.contains { $0.caseInsensitiveCompare(statementId) == .orderedSame }
    }

    /// For the joiner's own screen: that this account's invitation ran out
    /// (with the grace the SDK's eligibility rule allows) before it got the
    /// key, on a circle with records, and whom it names as asked to let it
    /// in. Nil otherwise: the usual line.
    func lateJoinerRanOut(_ circleId: String) -> LateJoiner.RanOut? {
        guard let me = AuthManager.shared.userId,
              let row = rosterWraps[circleId]?.first(where: { $0.key.caseInsensitiveCompare(me) == .orderedSame })?.value,
              let invitation = row.invitation,
              let statement = try? cryptoManager.parse(invitation.statement),
              LateJoiner.ranOutForJoiner(
                  expiresAt: statement.expiresAt, now: Date(), holdsKey: cryptoManager.hasCircleKey(circleId: circleId),
                  hasRecords: cryptoManager.circleHasRefreshRecords(circleId: circleId)) else { return nil }
        let roster = rosters[circleId] ?? []
        let inviter = roster.first { $0.userId.caseInsensitiveCompare(statement.signerUserId) == .orderedSame }
        return LateJoiner.RanOut(asked: LateJoiner.askedName(
            inviterRole: inviter.flatMap { Self.circleRole($0.role.rawValue) }, inviterName: inviter?.displayName,
            ownerName: roster.first { $0.role == .owner }?.displayName))
    }

    nonisolated static func circleRole(_ role: String) -> CircleRole? {
        switch role {
        case "owner": return .owner
        case "admin": return .admin
        case "member": return .member
        default: return nil
        }
    }

    /// After a key import, every circle's refresh records, checked by the SDK
    /// against the circle's last roster pass; then what the reports call for:
    /// a fresh copy asked for, the account's head published, a repair noted,
    /// and the deliveries that waited for it.
    private func importRefreshRecords() async {
        guard let me = AuthManager.shared.userId else { return }
        recordsImportsRunning += 1
        defer {
            recordsImportsRunning -= 1
            recordsImportRetry.imported(owing: circlesOwingRecordsImport(), at: Date())
        }
        var inputs: [String: RefreshRecordsSync.CircleInput] = [:]
        for circle in circles {
            let listing = recordMemberRows(for: circle.id)
            inputs[CanonicalId.key(circle.id)] = RefreshRecordsSync.CircleInput(
                members: listing?.rows, rosterComplete: listing?.complete ?? false,
                keyChain: Self.importLinks(fetched: keyChainsLastImport[CanonicalId.key(circle.id)] ?? [],
                                           own: ownLinks[CanonicalId.key(circle.id)] ?? []))
        }
        let api = self.api
        guard let outcomes = await RefreshRecordsSync.run(me: me, inputs: inputs, sdk: cryptoManager, page: { since in
            try await api.refreshRecords(since: since)
        }) else {
            Self.keyLog.error("refresh records: no answer; nothing changed")
            return
        }
        var settled: [String] = []
        for (circleId, outcome) in outcomes.sorted(by: { $0.key < $1.key }) {
            let id = circles.first { CanonicalId.sameKey($0.id, circleId) }?.id ?? circleId
            switch outcome {
            case .notNow:
                continue
            case .legacy:
                recordsState[CanonicalId.key(circleId)] = .legacy
                settled.append(id)
            case .latched:
                recordsState[CanonicalId.key(circleId)] = .latched
                Self.keyLog.info("circle \(id, privacy: .public): a head proves records the server didn't serve; waiting for them")
            case .imported(let report, let heads):
                recordsState[CanonicalId.key(circleId)] = .imported(forked: report.forked)
                // A change the SDK answered "not yet" is tried again after this.
                changesAwaitingImport.end(circleId)
                // An own link whose version this import decided has done its work.
                if let own = ownLinks[CanonicalId.key(circleId)] {
                    let undecided = Self.ownLinksAfterImport(own, versions: report.versions)
                    ownLinks[CanonicalId.key(circleId)] = undecided.isEmpty ? nil : undecided
                }
                if report.forked {
                    Self.keyLog.error("circle \(id, privacy: .public): its records forked; it waits")
                }
                if report.askForFreshCopy { await askForFreshCopy(id) }
                noteRejected(circleId: id, report: report, me: me)
                if !report.forked {
                    // Only an accepted head, never while forked, at most one PUT
                    // per circle per import.
                    await AccountHeads.publishIfNeeded(circleId: id, me: me, served: heads)
                    settled.append(id)
                }
            }
        }
        // Every own row is read again from the chain this import left.
        ownRows.removeAll()
        for circleId in settled {
            Task { await self.deliverToConfirmedMembers(circleId: circleId) }
            askLateJoinerQuestions(circleId: circleId)
        }
    }

    /// Pure: a circle's links for its records import: the fetched chain, and
    /// each of this device's own links (`ownLinks`) whose versions it doesn't
    /// serve. Where it serves one, the server's copy stays.
    nonisolated static func importLinks(fetched: [KeyChainLinkData], own: [KeyChainLinkData]) -> [KeyChainLinkData] {
        fetched + own.filter { link in !fetched.contains { sameVersions($0, link) } }
    }

    /// Pure: a circle's own links with `link` noted, in place of one for the
    /// same versions.
    nonisolated static func noting(_ link: KeyChainLinkData, in links: [KeyChainLinkData]) -> [KeyChainLinkData] {
        links.filter { !sameVersions($0, link) } + [link]
    }

    /// Pure: the own links an import left undecided. One whose version the
    /// import decided (accepted, reference or rejected) goes; one that waits,
    /// or wasn't judged, stays.
    nonisolated static func ownLinksAfterImport(_ links: [KeyChainLinkData],
                                                versions: [RecordVersionStatus]) -> [KeyChainLinkData] {
        links.filter { link in
            !versions.contains { $0.version == link.fromVersion && $0.state != .waiting }
        }
    }

    private nonisolated static func sameVersions(_ a: KeyChainLinkData, _ b: KeyChainLinkData) -> Bool {
        a.fromVersion == b.fromVersion && a.toVersion == b.toVersion
    }

    /// The fresh-copy request, for a circle whose records call for a fresh
    /// copy: at most every ten minutes.
    private func askForFreshCopy(_ circleId: String) async {
        if let last = freshCopyRequestedAt[circleId], Date().timeIntervalSince(last) < 600 { return }
        freshCopyRequestedAt[circleId] = Date()
        do {
            try await api.requestAccess(circleId: circleId)
            Self.keyLog.info("asked the members of circle \(circleId, privacy: .public) for a fresh copy (its records)")
        } catch {
            Self.keyLog.error("fresh-copy request for circle \(circleId, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// The versions rejected here are remembered for the next pass, and the
    /// first one the repair budget allows is due for a repair now.
    private func noteRejected(circleId: String, report: RefreshRecordsReport, me: String) {
        let ledger = RefreshLedger.shared
        let before = ledger.circle(account: me, circleId: circleId)
        let uncounted = uncountedNamed(report.tipNamedListed, circleId: circleId)
        repairsDue[CanonicalId.key(circleId)] = RecordedRotation.repairable(report.versions)
            .first { RefreshLedger.mayRepair($0, circle: before, now: Date(), uncountedNamed: uncounted) }
        tipNamedListed[CanonicalId.key(circleId)] = report.tipNamedListed
        let seen = RefreshLedger.rejectedSeen(after: report.versions)
        if seen != before.rejectedSeen {
            ledger.update(account: me, circleId: circleId) { $0.rejectedSeen = seen }
        }
    }

    /// Of the listed members the rejected tip names, those the chain doesn't
    /// count here: its newcomers the SDK's eligibility rule refused, or
    /// matched to nobody here (the report has no id for the latter). The
    /// ping-pong stop compares them.
    private func uncountedNamed(_ named: [String], circleId: String) -> [String] {
        named.filter { cryptoManager.chainRole(circleId: circleId, userId: $0) == nil }
    }

    /// How this device may rotate a circle now.
    enum RotationMode: Equatable {
        /// No records yet, and this account is a plain member: the legacy
        /// rotation, with no record.
        case legacy
        /// No records yet, and this account is an owner or admin: the
        /// rotation writes the circle's first record.
        case transition
        /// It has records: a rotation, or a repair when one is due.
        case recorded(RefreshRecordKind)
        /// Not now: its records not imported in this process yet, withheld, or
        /// forked.
        case wait
    }

    func rotationMode(for circle: Circle) -> RotationMode {
        rotationMode(for: circle, due: repairsDue[CanonicalId.key(circle.id)])
    }

    /// `rotationMode` on `due`: the repair entry a change reads once, for its
    /// admission, its name and its build.
    func rotationMode(for circle: Circle, due: RecordVersionStatus?) -> RotationMode {
        // The server takes a circle's first record only from an owner or admin
        // holding `can_rotate_keys`.
        let mode = Self.rotationMode(standing(of: circle.id), ownerOrAdmin: isOwnerOrAdmin(circle) && mayRotate(circle),
                                     repairDue: due != nil)
        return Self.rotationMode(mode, ownChangeUndecided: !(ownLinks[CanonicalId.key(circle.id)] ?? []).isEmpty)
    }

    /// Pure: an owner or admin writes a circle's first record; a plain member
    /// rotates a circle without records the legacy way; a circle with records
    /// gets a repair when one is due, else a rotation.
    nonisolated static func rotationMode(_ standing: RecordsStanding, ownerOrAdmin: Bool, repairDue: Bool) -> RotationMode {
        switch standing {
        case .noRecords: return ownerOrAdmin ? .transition : .legacy
        case .recorded: return .recorded(repairDue ? .repair : .rotation)
        case .wait: return .wait
        }
    }

    /// Pure: while a change of this device's is taken and no import has decided
    /// it yet (`ownLinks`), the next record waits. Built now, it would go after
    /// the accepted head, at that change's own version, and replace the key the
    /// server took with it.
    nonisolated static func rotationMode(_ mode: RotationMode, ownChangeUndecided: Bool) -> RotationMode {
        ownChangeUndecided ? .wait : mode
    }

    /// The list a circle's first record was refused for, by circle key: that
    /// list is never tried again.
    private var transitionRefusedFor: [String: String] = [:]

    /// Pure: a circle's list as a transition judges it (who is listed, with
    /// what role, with keys or not, confirmed or not): a change in it may let
    /// the SDK take the transition it refused.
    nonisolated static func transitionListing(_ rows: [RecordMemberRow]) -> String {
        rows.filter(\.listed).map { row in
            "\(row.userId.lowercased()) \(row.listedRole.map { String(describing: $0) } ?? "-") \(row.keys != nil) \(row.confirmed)"
        }.sorted().joined(separator: ",")
    }

    private func transitionRefused(_ circleId: String) -> Bool {
        guard let refused = transitionRefusedFor[CanonicalId.key(circleId)],
              let rows = recordMemberRows(for: circleId)?.rows else { return false }
        return refused == Self.transitionListing(rows)
    }

    private func noteTransitionRefused(_ circleId: String, _ refusal: MobileError) {
        transitionRefusedFor[CanonicalId.key(circleId)] = recordMemberRows(for: circleId)
            .map { Self.transitionListing($0.rows) }
        Self.keyLog.error("circle \(circleId, privacy: .public): its first record was refused for this list: \(String(describing: refusal), privacy: .public)")
    }

    /// A rotation this device owes a circle besides the server's flag: the
    /// transition of a circle without records, at once, a repair (any member
    /// on a flagged circle, owners and admins at any time), and its person's
    /// removals and role changes the chain doesn't carry yet, whatever the
    /// flag says.
    private func recordedRotationDue(_ circle: Circle) -> Bool {
        guard let me = AuthManager.shared.userId else { return false }
        switch rotationMode(for: circle) {
        case .transition:
            guard let listing = recordMemberRows(for: circle.id), listing.complete,
                  !transitionRefused(circle.id) else { return false }
            return RecordedRotation.transitionPlan(
                me: me, roster: Self.listed(listing.rows),
                confirmed: Set(listing.rows.filter(\.confirmed).map(\.userId)), blocked: []) != nil
        case .recorded(.repair):
            return circle.keyRotationNeeded || isOwnerOrAdmin(circle)
        case .recorded:
            let owed = RefreshLedger.shared.circle(account: me, circleId: circle.id)
            if !standingRemovals(circle.id, owed.removals, me: me).isEmpty && removesInTheChain(circle.id) { return true }
            // Only a role change a record can carry now (the shared role
            // vector's `due`): any owed one would rotate every sweep.
            return roleChangesDue(circle.id, owed: owed.roleChanges, me: me)
        case .legacy, .wait:
            return false
        }
    }

    /// The role part of a record owed now (`RecordedRotation.roleChangesDue`),
    /// read from this device's complete roster and the chain. The SDK's
    /// eligibility rule is asked only when a never-named member's promotion
    /// needs its answer.
    private func roleChangesDue(_ circleId: String, owed: [String: String], me: String) -> Bool {
        let wanted = owed.compactMapValues { Self.circleRole($0) }
        guard !wanted.isEmpty, cryptoManager.chainRole(circleId: circleId, userId: me) == .owner,
              let listing = recordMemberRows(for: circleId), listing.complete else { return false }
        let rows = listing.rows
        let chainRoles = Dictionary(rows.map { ($0.userId, cryptoManager.chainRole(circleId: circleId, userId: $0.userId)) },
                                    uniquingKeysWith: { first, _ in first })
        let asksE = wanted.contains { userId, role in
            role == .admin && rows.contains { CanonicalId.sameKey($0.userId, userId) && chainRoles[$0.userId] == .some(nil) }
        }
        let includable: Set<String> = asksE
            ? Set(((try? cryptoManager.refreshEligibility(circleId: circleId, members: rows.map(\.sdkMember),
                                                          purpose: .include)) ?? []).filter(\.eligible).map(\.userId))
            : []
        return RecordedRotation.roleChangesDue(myChainRole: .owner, owed: wanted, members: rows.map { row in
            RecordedRotation.RoleMember(userId: row.userId, listed: row.listed, hasKeys: row.keys != nil,
                                        eligible: includable.contains { CanonicalId.sameKey($0, row.userId) },
                                        chainRole: chainRoles[row.userId] ?? nil)
        })
    }

    /// This device's pending removals in a circle that still stand, judged
    /// against the statements its last roster pass read (`removalsStanding`).
    private func standingRemovals(_ circleId: String, _ removals: [RefreshLedger.Removal],
                                  me: String) -> [RefreshLedger.Removal] {
        guard !removals.isEmpty else { return [] }
        let statements = (membershipCandidates[circleId] ?? [:]).mapValues(\.statements)
        let record = KeyDeliveryApprovals.shared.record(owner: me, circleId: circleId)
        let dead = record.deadStatementIds.union(record.tombstones.values.flatMap(\.statementIds))
        return RefreshLedger.removalsStanding(removals, me: me, circleId: circleId, statements: statements, dead: dead,
                                              checker: cryptoManager)
    }

    nonisolated static func listed(_ rows: [RecordMemberRow]) -> [RecordedRotation.Listed] {
        rows.filter(\.listed).map {
            RecordedRotation.Listed(userId: $0.userId, role: $0.listedRole ?? .member, hasKeys: $0.keys != nil)
        }
    }

    /// A change that carries a refresh record, ready to send.
    struct RecordedChange {
        let bundle: RecordedRotationBundle
        let kind: RefreshRecordKind
        /// Every active member the new key isn't given to (`pending_members`).
        let pendingMembers: [String]
        /// The person's own removals this record carries, and the role changes
        /// it settles (member → role, as the ledger keeps them): they leave the
        /// ledger once the server takes it, a role only while the ledger still
        /// holds that same role (`RefreshLedger.settling`).
        let removals: Set<String>
        let roleChanges: [String: String]
        /// The rejected version this repairs, if it is a repair.
        let repairing: RecordVersionStatus?
        /// A repair's `uncountedNamed`: what it was rejected for, with
        /// `repairing.notAllowed` (`RefreshLedger.rejectedFor`).
        var uncountedNamed: [String] = []
        /// The circle's name it seals (`nameToSeal`).
        let name: NameToSeal
        /// The owner's hand-over this record carries: the member its plan names
        /// owner, sent as `transfer_to`, and nil otherwise. Taken from the plan,
        /// never from the request: the server moves the ownership to whoever
        /// `transfer_to` names and never checks the record.
        var transferTo: String? = nil
    }

    /// Plan and build a change with its record, from the roster pass
    /// `planRotation` just ran; the SDK's record builder checks it as every
    /// other device will. `due`: the repair entry `mode` was read on, the one
    /// a repair answers. `ejecting`: the member an eject removes. `handOver`:
    /// the owner's hand-over, only in a rotation of a circle with records; the
    /// record names that member owner, with the keys this device held for
    /// them at the tap, or nothing is built.
    private func prepareRecordedChange(_ circle: Circle, me: String, mode: RotationMode, due: RecordVersionStatus?,
                                       decision: RotationDecision, blocked: Set<String>,
                                       ejecting: String? = nil,
                                       handOver: RefreshLedger.HandOver? = nil) throws -> RecordedChange {
        // Never a record, a new key or a link for the personal key's slot.
        guard !CanonicalId.isPersonalSlot(circle.id) else { throw CircleError.memberNotFound }
        guard let listing = recordMemberRows(for: circle.id), listing.complete else { throw CircleError.waitingToSync }
        // This person's removals and role changes, and the repair budget, come
        // from the ledger: nothing is decided while its file can't be read.
        guard RefreshLedger.shared.isReadable(account: me) else { throw CircleError.waitingToSync }
        // The new key seals the circle's name only from the key in use:
        // never the placeholder, never a name read under another version. An
        // eject from below that can't read it, a repair answering a
        // MISATTRIBUTED version, and a repair that holds the version it answers
        // (`holdsForTheName`), go without one.
        guard let name = Self.nameToSeal(
            readable: circle.readableName, sealable: sealableName(circle),
            ejectingFromBelow: ejecting != nil && ejectsFromBelow(circle), holds: holdsForTheName(circle, mode: mode, due: due),
            misattributionRepair: Self.repairsMisattribution(mode: mode, answering: due?.problem)) else {
            throw CircleError.waitingToSync
        }
        let rows = listing.rows
        let confirmed = Set(rows.filter(\.confirmed).map(\.userId))
        let planned: [PlannedEntry]
        // The same plan without an owner's claim, for when the chain doesn't
        // allow the claim: planned again once, never in a loop.
        var withoutClaim: [PlannedEntry]?
        var removals = Set<String>(), roleChanges: [String: String] = [:]
        // Read for the role changes a record settles, once its plan is built.
        var owedRoles: [String: CircleRole] = [:]
        var chainRoleHere: CircleRole?
        var repairing: RecordVersionStatus?
        var uncounted: [String] = []
        let kind: RefreshRecordKind
        // The member an eject removes is no longer listed: a record names every
        // listed member with keys, and they are named removed or not at all.
        let members = rows.map { row in
            guard let ejecting, row.userId.caseInsensitiveCompare(ejecting) == .orderedSame else { return row }
            return RecordMemberRow(userId: row.userId, keys: row.keys, confirmed: row.confirmed, listed: false,
                                   listedRole: row.listedRole, statements: row.statements,
                                   personConfirmedKeys: row.personConfirmedKeys,
                                   serverSaysKeyless: row.serverSaysKeyless)
        }
        var transferTo: String?
        if let handOver {
            // Only in a rotation of a circle with records, and never with an eject.
            guard mode == .recorded(.rotation), ejecting == nil else { throw CircleError.handOverNotNow }
            // Only the keys this device held for them at the tap, and only
            // while this roster pass confirms them with exactly those: a
            // server swapping their keys never gets its own named owner.
            guard let row = members.first(where: { CanonicalId.same($0.userId, handOver.target) }),
                  row.listed, row.confirmed,
                  row.keys?.matches(sharing: handOver.sharingKeyHex, signing: handOver.signingKeyHex) == true
            else { throw CircleError.handOverDetailsChanged }
        }
        switch mode {
        case .transition:
            kind = .transition
            guard let plan = RecordedRotation.transitionPlan(
                me: me, roster: Self.listed(members), confirmed: confirmed, blocked: blocked) else {
                throw CircleError.waitingToSync
            }
            planned = plan
        case .recorded(let recordedKind):
            kind = recordedKind
            // A re-invite from here that ran out unused brings back the removal
            // it cleared, unless they are on the complete list.
            RefreshLedger.shared.settleRunOutReInvites(account: me, circleId: circle.id,
                                                       listed: Set(rows.filter(\.listed).map(\.userId)), now: Date())
            let owed = RefreshLedger.shared.circle(account: me, circleId: circle.id)
            let includable = Set(try cryptoManager.refreshEligibility(
                circleId: circle.id, members: members.map(\.sdkMember), purpose: .include)
                .filter(\.eligible).map(\.userId))
            // Only an owner or admin in the chain names anyone removed; a removal
            // this account made as a server-only admin is recorded as a
            // departure by whoever rotates, and leaves the ledger here.
            var removing = removesInTheChain(circle.id)
                ? Set(standingRemovals(circle.id, owed.removals, me: me).map(\.userId)) : []
            if let ejecting { removing.insert(ejecting) }
            var counted: [String: CircleRole] = [:]
            for userId in Set(rows.map(\.userId)).union(removing) {
                if let role = cryptoManager.chainRole(circleId: circle.id, userId: userId) { counted[userId] = role }
            }
            let myChainRole = counted.first { $0.key.caseInsensitiveCompare(me) == .orderedSame }?.value
            let myListedRole = rows.first { $0.userId.caseInsensitiveCompare(me) == .orderedSame }?.listedRole
            owedRoles = owed.roleChanges.compactMapValues { Self.circleRole($0) }
            chainRoleHere = myChainRole
            let changes = RecordedRotation.writtenRoles(myChainRole: myChainRole, owed: owedRoles)
            if recordedKind == .repair { repairing = due }
            // Built after the rejected tip, repair or not: every listed member it
            // names is named, pending those this device can't include (the SDK
            // refuses a plan that leaves one out).
            let rejectedIncluded = Set(tipNamedListed[CanonicalId.key(circle.id)] ?? [])
            if repairing != nil { uncounted = uncountedNamed(Array(rejectedIncluded), circleId: circle.id) }
            let claims = handOver == nil
                && RecordedRotation.claimsOwner(myChainRole: myChainRole, myListedRole: myListedRole,
                                                removing: removing, counted: counted)
            planned = RecordedRotation.rotationPlan(
                me: me, roster: Self.listed(members), includable: includable, blocked: blocked, counted: counted,
                removing: removing, rejectedIncluded: rejectedIncluded, roleChanges: changes,
                claimsOwner: claims, handOverTo: myChainRole == .owner ? handOver?.target : nil)
            // A hand-over goes only in a record that names that member owner,
            // included, and this account member; `transfer_to` is that owner
            // entry, nothing else.
            if let handOver {
                guard RecordedRotation.handsOver(planned, me: me, to: handOver.target),
                      let owner = planned.first(where: { $0.role == .owner }) else { throw CircleError.handOverNotNow }
                transferTo = owner.userId
            }
            if claims {
                withoutClaim = RecordedRotation.rotationPlan(
                    me: me, roster: Self.listed(members), includable: includable, blocked: blocked, counted: counted,
                    removing: removing, rejectedIncluded: rejectedIncluded, roleChanges: changes,
                    claimsOwner: false)
            }
            // Whatever this record could carry leaves the ledger once it is
            // taken: a removal of someone the chain no longer counts has nothing
            // left to carry, and must not rotate the circle again. Role changes
            // settle by member AND role, once the plan is known (below).
            removals = Set(owed.removals.map(\.userId))
        case .legacy, .wait:
            throw CircleError.waitingToSync
        }
        let bundle: RecordedRotationBundle
        var built = planned
        do {
            bundle = try cryptoManager.prepareRecordedRotation(
                circleId: circle.id, senderUserId: me, kind: kind, planned: planned,
                members: members.map(\.sdkMember), rosterComplete: listing.complete,
                currentCircleNamePlaintext: name.plaintext)
        } catch MobileError.InvalidInput(let message) where withoutClaim != nil
                    && !message.contains(RecordedRotation.notYetText) {
            Self.keyLog.info("circle \(circle.id, privacy: .public): no owner's claim yet (\(message, privacy: .public)); roles carried")
            built = withoutClaim ?? planned
            bundle = try cryptoManager.prepareRecordedRotation(
                circleId: circle.id, senderUserId: me, kind: kind, planned: built,
                members: members.map(\.sdkMember), rosterComplete: listing.complete,
                currentCircleNamePlaintext: name.plaintext)
        }
        // The role changes this record settles: what the plan it was built
        // from names with that same role, or every one off the chain owner's
        // device, or a member no longer listed (an eject's included; see
        // `RecordedRotation.roleChangesSettled`).
        if case .recorded = mode {
            roleChanges = RecordedRotation.roleChangesSettled(
                owed: owedRoles, myChainRole: chainRoleHere, listed: Set(members.filter(\.listed).map(\.userId)),
                plan: built).mapValues(RecordedRotation.roleName)
        }
        // The server wants every active member either given the new key or
        // named pending: everyone the plan's lists name, less those wrapped.
        let wrapped = Set(bundle.rotation.memberKeys.map { $0.userId.lowercased() })
        let pending = (decision.wrap + decision.pending).filter {
            !wrapped.contains($0.lowercased()) && $0.caseInsensitiveCompare(me) != .orderedSame
        }
        return RecordedChange(bundle: bundle, kind: kind, pendingMembers: Array(Set(pending)).sorted(),
                              removals: removals, roleChanges: roleChanges, repairing: repairing,
                              uncountedNamed: uncounted.sorted(), name: name, transferTo: transferTo)
    }

    /// After the server took a change with its record: what it carried leaves
    /// the ledger, a repair counts in the budget, its link goes to the
    /// records imports, and the circle is listed at its version.
    private func recordedChangeTaken(_ change: RecordedChange, circleId: String, me: String) {
        RefreshLedger.shared.update(account: me, circleId: circleId) { entry in
            entry.removals.removeAll { removed in
                change.removals.contains { CanonicalId.sameKey($0, removed.userId) }
            }
            entry.roleChanges = RefreshLedger.settling(entry.roleChanges, taken: change.roleChanges)
            if let repairing = change.repairing {
                entry.repaired.append(repairing.version)
                entry.lastRepairAt = Date()
                entry.repairs[String(change.bundle.rotation.newKeyVersion)] =
                    RefreshLedger.rejectedFor(repairing, uncountedNamed: change.uncountedNamed)
            }
        }
        repairsDue.removeValue(forKey: CanonicalId.key(circleId))
        tipNamedListed.removeValue(forKey: CanonicalId.key(circleId))
        // The link it carried goes into the records imports until one decides
        // its version: the very bytes the server took with the record.
        if let link = change.bundle.rotation.keyChainLink {
            ownLinks[CanonicalId.key(circleId)] = Self.noting(link, in: ownLinks[CanonicalId.key(circleId)] ?? [])
        }
        // The circle is at the new version now, whether or not the load after
        // this succeeds: the write gate compares with it, never with the
        // version this change replaced.
        if let index = circles.firstIndex(where: { CanonicalId.sameKey($0.id, circleId) }) {
            let listed = Self.listedVersion(circles[index].keyVersion, taken: change.bundle.rotation.newKeyVersion)
            if circles[index].keyVersion != listed {
                circles[index].keyVersion = listed
                if let active = activeCircle, CanonicalId.sameKey(active.id, circleId) {
                    activeCircle = circles[index]
                }
            }
        }
    }

    /// Pure: a circle's listed key version once the server took this device's
    /// change to `taken`: never below it, and never lowered.
    nonisolated static func listedVersion(_ listed: Int, taken: Int32) -> Int {
        max(listed, Int(taken))
    }

    /// Send a rotation with its record (rotate-keys). The server not taking it
    /// drops this device's unconfirmed key again, and so does a lost race (the
    /// record isn't stored then).
    private func sendRecordedRotation(_ circle: Circle, me: String, change: RecordedChange) async throws {
        let rotation = change.bundle.rotation
        let request = Self.rotateKeysRequest(expectedKeyVersion: circle.keyVersion, change: change)
        let response: RotateKeysResponse
        do {
            response = try await api.rotateKeys(circleId: circle.id, request: request)
        } catch {
            _ = cryptoManager.discardUnconfirmedRotation(circleId: circle.id)
            throw error
        }
        if response.alreadyRotated == true {
            _ = cryptoManager.discardUnconfirmedRotation(circleId: circle.id)
            print("[Track] rotateCircleKey: another client rotated first for \(circle.id); its record wasn't stored")
            return
        }
        recordedChangeTaken(change, circleId: circle.id, me: me)
        Self.keyLog.info("circle \(circle.id, privacy: .public): v\(rotation.newKeyVersion, privacy: .public) sent with its record (\(String(describing: change.kind), privacy: .public))")
    }

    /// The rotation's request, from its change. Pure: the circle's name goes
    /// only when this device sealed one (`nameToSeal`); otherwise it is left
    /// out, never null, and the server keeps the stored one.
    nonisolated static func rotateKeysRequest(expectedKeyVersion: Int, change: RecordedChange) -> RotateKeysRequest {
        let rotation = change.bundle.rotation
        return RotateKeysRequest(
            encryptedName: change.name == .keepStored ? nil
                : EncryptedBlobRequest(nonce: rotation.encryptedName.nonce, ciphertext: rotation.encryptedName.ciphertext),
            memberKeys: rotation.memberKeys.map { entry in
                MemberKeyUpdateRequest(
                    userId: entry.userId,
                    encryptedCircleKey: EncryptedBlobRequest(nonce: entry.bundle.encryptedCircleKey.nonce,
                                                             ciphertext: entry.bundle.encryptedCircleKey.ciphertext),
                    ephemeralPublicKey: entry.bundle.ephemeralPublicKey,
                    wrapSignature: entry.bundle.wrapSignature.isEmpty ? nil : entry.bundle.wrapSignature)
            },
            expectedKeyVersion: expectedKeyVersion,
            keyChainLink: rotation.keyChainLink.map(Self.linkRequest),
            pendingMembers: change.pendingMembers.isEmpty ? nil : change.pendingMembers,
            refreshRecord: RefreshRecordWire(record: change.bundle.refreshRecord.recordHex,
                                             signature: change.bundle.refreshRecord.signatureHex),
            transferTo: change.transferTo)
    }

    /// Send an eject with its record (eject-and-rotate). The server not taking
    /// it drops this device's unconfirmed key again; nothing changed then.
    private func sendRecordedEject(_ circle: Circle, userId: String, me: String, change: RecordedChange) async throws {
        do {
            _ = try await api.ejectAndRotate(circleId: circle.id, request: Self.ejectRequest(userId: userId, change: change))
        } catch {
            _ = cryptoManager.discardUnconfirmedRotation(circleId: circle.id)
            throw error
        }
        recordedChangeTaken(change, circleId: circle.id, me: me)
        Self.keyLog.info("circle \(circle.id, privacy: .public): a member removed with v\(change.bundle.rotation.newKeyVersion, privacy: .public) and its record")
    }

    /// The eject's request, from its change. Pure: the circle's name goes
    /// only when this device sealed one it reads (`nameToSeal`); otherwise it
    /// is left out, never null, and the server keeps the stored one.
    nonisolated static func ejectRequest(userId: String, change: RecordedChange) -> EjectAndRotateRequest {
        let rotation = change.bundle.rotation
        return EjectAndRotateRequest(
            ejectUserId: userId,
            newKeyVersion: Int(rotation.newKeyVersion),
            memberWraps: rotation.memberKeys.map { entry in
                EjectMemberWrapRequest(
                    userId: entry.userId,
                    encryptedCircleKey: entry.bundle.encryptedCircleKey.ciphertext,
                    circleKeyNonce: entry.bundle.encryptedCircleKey.nonce,
                    ephemeralPublicKey: entry.bundle.ephemeralPublicKey,
                    wrapSignature: entry.bundle.wrapSignature.isEmpty ? nil : entry.bundle.wrapSignature)
            },
            encryptedName: change.name == .keepStored ? nil
                : EncryptedBlobRequest(nonce: rotation.encryptedName.nonce, ciphertext: rotation.encryptedName.ciphertext),
            keyChainLink: rotation.keyChainLink.map(Self.linkRequest),
            pendingMembers: change.pendingMembers.isEmpty ? nil : change.pendingMembers,
            refreshRecord: RefreshRecordWire(record: change.bundle.refreshRecord.recordHex,
                                             signature: change.bundle.refreshRecord.signatureHex))
    }

    nonisolated static func linkRequest(_ link: KeyChainLinkData) -> KeyChainLinkRequest {
        KeyChainLinkRequest(fromVersion: Int(link.fromVersion), toVersion: Int(link.toVersion),
                            encryptedKey: link.encryptedKey, nonce: link.nonce)
    }

    // MARK: - Key Rotation

    /// Who a rotation wraps the new circle key to, and who it deliberately
    /// leaves pending. See `rotationDecision`.
    struct RotationDecision: Equatable {
        /// Wrap the new key to these (always includes the rotator).
        var wrap: [String]
        /// Active members given NO wrap (`pending_members`). They keep the
        /// versions they already hold and get nothing newer.
        var pending: [String]
        /// Subset of `pending`: listed by `member-public-keys` but absent from
        /// the roster — a member nobody can see. Logged, never given anything.
        var ghosts: [String]
        /// Subset of `pending`: on the roster but not confirmed on this device —
        /// whatever the server says they already hold. Not shown, not asked about
        /// by a rotation (an owner's or admin's device asks its question, when
        /// there is one, as it loads the roster).
        var unconfirmed: [String]
        /// Nothing worth rotating for: the flag was raised by a keyless join
        /// and every member owed the key is pending. Rotating would bump the
        /// version and deliver to nobody.
        var skip: Bool
    }

    /// The decision behind every rotation this device makes — the security
    /// refresh and an eject alike. Pure, so each rule is testable. A member is
    /// wrapped to only when they are on the complete roster AND confirmed on
    /// this device AND their key passes the pin gate:
    ///
    /// * The server alone decides who is listed, and `member-public-keys`
    ///   (whom a rotation wraps to) is a different endpoint from the roster.
    ///   Someone on the first and not the second is never wrapped to.
    /// * A roster member this device has not confirmed is left pending,
    ///   WHATEVER the server says about their wrap. The key chain hands a new
    ///   member ALL history, so an account the server added must not get it by
    ///   being listed as already holding the key.
    /// * A member blocked by an unapproved key change is left pending instead
    ///   of aborting the rotation for everyone — otherwise one unrelated key
    ///   change could keep a removed member's key current indefinitely.
    ///
    /// Being OWED the key (no wrap, or an older one; from `key_version`) decides
    /// only whether a rotation delivers anything — see `skip` — never trust.
    /// `wrapSet` is `member-public-keys` minus any member being ejected. An
    /// older server reports no `key_version`, and then nobody counts as owed.
    nonisolated static func rotationDecision(
        selfUserId: String,
        circleKeyVersion: Int,
        cause: String?,
        wrapSet: [(userId: String, keyVersion: Int?)],
        roster: Set<String>,
        blocked: Set<String>,
        confirmed: Set<String>
    ) -> RotationDecision {
        let versionsReported = wrapSet.contains { $0.keyVersion != nil }
        func owed(_ version: Int?) -> Bool {
            guard versionsReported else { return false }
            guard let version else { return true }
            return version < circleKeyVersion
        }
        var decision = RotationDecision(wrap: [], pending: [], ghosts: [], unconfirmed: [], skip: false)
        var owedWrapped = false
        for member in wrapSet {
            let id = member.userId
            if id == selfUserId {
                decision.wrap.append(id)
            } else if !roster.contains(id) {
                decision.pending.append(id)
                decision.ghosts.append(id)
            } else if blocked.contains(id) {
                decision.pending.append(id)
            } else if !confirmed.contains(id) {
                decision.pending.append(id)
                decision.unconfirmed.append(id)
            } else {
                decision.wrap.append(id)
                if owed(member.keyVersion) { owedWrapped = true }
            }
        }
        // Roster members `member-public-keys` does not list have published no
        // key: there is nothing to wrap to. The server wants every active member
        // either wrapped or named pending, so name them — otherwise one keyless
        // account refuses the whole rotation.
        let listed = Set(wrapSet.map(\.userId))
        for id in roster.sorted() where id != selfUserId && !listed.contains(id) {
            decision.pending.append(id)
        }
        decision.skip = cause == "member_joined" && !owedWrapped
        return decision
    }

    /// Everything a rotation needs, gathered and decided: the server's wrap
    /// set, a FRESH roster to check it against, the TOFU gate, and who this
    /// device has confirmed. Throws when the roster cannot be read — the check
    /// that keeps a member without a valid invitation out cannot be skipped.
    private func planRotation(
        for circle: Circle,
        rotatorUserId: String,
        ejecting ejectedUserId: String? = nil
    ) async throws -> (decision: RotationDecision, keys: [String: MemberPublicKeyResponse], blocked: Set<String>) {
        let publicKeys = try await api.memberPublicKeys(circleId: circle.id)
            .filter { $0.userId != ejectedUserId }
        let planStartedAt = Date()
        try await loadMembers(for: circle.id)
        if incompleteRosters.contains(circle.id) {
            throw CircleError.ejectFailed("This circle has too many members for this phone to check first. Try again from Pingolin on the web.")
        }
        // RETAIN BEFORE YOU ROTATE: THIS plan's roster fetch must have retired
        // the pins of everyone who left. Otherwise a removed member who is still
        // pinned could sign a wrap for the new version and win the lost-race
        // replacement of our unconfirmed key.
        guard let retained = pinsRetainedAt[circle.id], retained >= planStartedAt else {
            throw CircleError.ejectFailed("Couldn't refresh this circle's member list — try again")
        }
        // The member being removed is on the roster until the eject lands; they
        // are neither wrapped nor pending, so they are not part of the plan.
        let roster = Set((rosters[circle.id] ?? []).map(\.userId).filter { $0 != ejectedUserId })
        let keysById = Dictionary(publicKeys.map { ($0.userId, $0) }, uniquingKeysWith: { first, _ in first })
        func name(_ userId: String) -> String {
            rosters[circle.id]?.first(where: { $0.userId == userId })?.displayName ?? "Member"
        }

        // SEND-SIDE GATE — only over members this device has confirmed: running
        // it over anyone else would pin a hidden account's keys as if this device
        // trusted them. The unconfirmed are left pending below.
        let confirmation = membership[circle.id] ?? MembershipConfirmation.Result()
        let confirmedNow = confirmation.confirmed
        let gateMembers: [(userId: String, displayName: String, sharingPubkeyHex: String?, signingPubkeyHex: String?)] =
            publicKeys
                .filter { roster.contains($0.userId) && confirmedNow.contains($0.userId) }
                .map { pk in (userId: pk.userId, displayName: name(pk.userId),
                              sharingPubkeyHex: pk.sharingPublicKey, signingPubkeyHex: pk.signingPublicKey) }
        let blocked = sendSideGate(circleId: circle.id, me: rotatorUserId, result: confirmation, members: gateMembers)

        let decision = Self.rotationDecision(
            selfUserId: rotatorUserId,
            circleKeyVersion: circle.keyVersion,
            cause: circle.keyRotationCause,
            wrapSet: publicKeys.map { (userId: $0.userId, keyVersion: $0.keyVersion) },
            roster: roster,
            blocked: blocked,
            confirmed: confirmedNow
        )

        if !decision.ghosts.isEmpty {
            // Diagnostics only, with no visible alarm: the server listed
            // accounts for the key that are not on the roster.
            Self.keyLog.error(
                "member-public-keys lists \(decision.ghosts.count, privacy: .public) user(s) absent from the roster of circle \(circle.id, privacy: .public): \(decision.ghosts.joined(separator: ","), privacy: .public) — not wrapping to them"
            )
        }
        if !decision.pending.isEmpty {
            print("[Track] rotation plan \(circle.id): wrapping \(decision.wrap.count), pending \(decision.pending.count) (ghosts \(decision.ghosts.count), unconfirmed \(decision.unconfirmed.count), blocked \(blocked.count))")
        }
        return (decision, keysById, blocked)
    }

    /// Whether a member is shown on this device: on the confirmed list once the
    /// roster has loaded; before that, whoever this device has confirmed before
    /// (so a cold start shows the people it knows, and nobody else).
    func isShown(_ userId: String, in circleId: String) -> Bool {
        if let shown = members[circleId] { return shown.contains { $0.userId == userId } }
        guard let me = AuthManager.shared.userId else { return false }
        return KeyDeliveryApprovals.shared.approvedMembers(owner: me, circleId: circleId).contains(userId)
    }

    /// A member confirmed receive-only on this device: invited to an email, so
    /// taken on the server's word that the account is that email.
    func isReceiveOnly(_ userId: String, in circleId: String) -> Bool {
        membership[circleId]?.origin(of: userId)?.isReceiveOnly ?? false
    }

    /// A member's security code with this device's user, from the keys the
    /// member list shows for them now; nil when it cannot be worked out.
    func securityCode(for userId: String, in circleId: String) -> String? {
        guard let me = AuthManager.shared.userId,
              let sharing = sharingPubkeyCache[cacheKey(circleId, userId)],
              let signing = signingPubkeyCache[cacheKey(circleId, userId)] else { return nil }
        return try? cryptoManager.computeSafetyNumber(
            selfUserId: me, peerUserId: userId, peerSharingPubkeyHex: sharing, peerSigningPubkeyHex: signing)
    }

    /// This device's confirmed members of a circle right now, from the last
    /// confirmation pass (or, before one, its record).
    func confirmedMembers(in circleId: String) -> Set<String> {
        if let result = membership[circleId] { return result.confirmed }
        let me = AuthManager.shared.userId
        let roster = Set((rosters[circleId] ?? []).map(\.userId))
        let approved = me.map { KeyDeliveryApprovals.shared.approvedMembers(owner: $0, circleId: circleId) } ?? []
        return Self.confirmedMembers(roster: roster, approved: approved, selfUserId: me)
    }

    /// When each circle's pins were last retired against a complete roster.
    /// A rotation plan requires one from its own roster fetch.
    private var pinsRetainedAt: [String: Date] = [:]

    /// Circles whose own-wrap signature was attempted this session.
    private var ownWrapSignAttempted: Set<String> = []

    /// Our own wrap of a circle key stored WITHOUT a signature — as creation
    /// wraps made by older versions of the app are — is exactly the shape a
    /// server can forge ("from me, to me", unsigned). Sign it: the SDK signs
    /// only if the wrap opens to the key this device ALREADY holds for that
    /// version, so this can never vouch for a key the server chose. Best
    /// effort; a 409 means a rotation replaced the wrap, which the next sync
    /// handles.
    private func signOwnUnsignedWraps(_ responses: [CircleResponse], skipping: Set<String>) async {
        guard let me = AuthManager.shared.userId else { return }
        for response in responses where !skipping.contains(response.id) && !ownWrapSignAttempted.contains(response.id) {
            guard let ciphertext = response.encryptedCircleKey,
                  let nonce = response.circleKeyNonce,
                  let ephemeral = response.ephemeralPublicKey,
                  (response.wrapSignature ?? "").isEmpty,
                  response.senderUserId == nil || response.senderUserId == me else { continue }
            ownWrapSignAttempted.insert(response.id)
            let version = Self.ownWrapVersion(response)
            // Never sign a key this device took on trust at first contact
            // (the SDK refuses it too); only this account's own signed copy
            // clears that mark, and the rotation step replaces the key.
            if cryptoManager.circleKeyTakenOnTrust(circleId: response.id, keyVersion: Int32(version)) {
                Self.keyLog.info("circle \(response.id, privacy: .public) v\(version, privacy: .public): key taken on trust; our copy is not signed")
                continue
            }
            do {
                let signature = try cryptoManager.signOwnCircleKeyWrap(
                    circleId: response.id,
                    userId: me,
                    keyVersion: Int32(version),
                    encryptedKey: nonce + ciphertext,
                    senderPublicKey: ephemeral
                )
                _ = try await api.signOwnCircleWrap(
                    circleId: response.id,
                    keyVersion: version,
                    encryptedCircleKey: EncryptedBlobRequest(nonce: nonce, ciphertext: ciphertext),
                    ephemeralPublicKey: ephemeral,
                    wrapSignature: signature
                )
                Self.keyLog.info("signed our own wrap of circle \(response.id, privacy: .public) v\(version, privacy: .public)")
            } catch {
                Self.keyLog.error("could not sign our own wrap of circle \(response.id, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Circles whose last roster fetch said there was more than one page. A
    /// rotation there cannot tell a hidden member from one on page two, so it
    /// is refused (the server caps a rotation at 100 members anyway).
    private var incompleteRosters: Set<String> = []

    /// Circles with a delivery pass running on this device.
    private var deliveriesInFlight: Set<String> = []

    /// Delivery by ANY member. A device that holds the circle's CURRENT
    /// version hands it to the confirmed members it may — a newcomer with a
    /// valid, unexpired invitation (the first delivery), a member admitted at
    /// or after this device's version, someone this device's user chose; an
    /// owner's or admin's device to any confirmed member who is owed it — with
    /// no question and no version bump. The server keeps the first delivery; a
    /// 409 means another member's app got there first and is not an error.
    /// Never to anyone unconfirmed, never across a changed key (the pin gate),
    /// never from a receive-only member's device, and never from a device
    /// holding anything but exactly the current version. Runs after every
    /// roster load: the `member_joined` wake-up, the periodic and foreground
    /// refreshes, and pull-to-refresh all come through it. The decision is
    /// `AccessHandover`'s — the one the notification extension makes when the
    /// app is not running.
    func deliverToConfirmedMembers(circleId: String) async {
        // The personal key's slot is never handed to anyone.
        guard !CanonicalId.isPersonalSlot(circleId) else { return }
        guard let me = AuthManager.shared.userId,
              let circle = circles.first(where: { $0.id == circleId }),
              let result = membership[circleId],
              AccessHandover.mayHandOver(
                  heldVersion: (try? cryptoManager.getActiveVersion(circleId: circleId)).map { Int($0) },
                  circleKeyVersion: circle.keyVersion, circleOpens: !circle.isLocked,
                  selfIsReceiveOnly: selfIsReceiveOnly(circleId), isBehind: isBehind(circleId)),
              !deliveriesInFlight.contains(circleId) else { return }
        // Deliveries wait for this process's records import. On a circle with
        // records, the SDK's delivery eligibility, from its last roster pass;
        // on one without records, `AccessHandover.deliveries`'s own rules;
        // nothing while it forked or waits for its records (the import runs
        // them again after).
        let eDeliver: Set<String>?
        switch standing(of: circleId) {
        case .noRecords:
            eDeliver = nil
        case .recorded:
            guard let listing = recordMemberRows(for: circleId),
                  let answers = try? cryptoManager.refreshEligibility(
                      circleId: circleId, members: listing.rows.map(\.sdkMember), purpose: .deliver) else { return }
            eDeliver = Set(answers.filter(\.eligible).map(\.userId))
        case .wait:
            return
        }
        let targets = AccessHandover.deliveries(
            me: me, circleKeyVersion: circle.keyVersion, heldVersion: circle.keyVersion,
            createdHere: AccessHandover.createdHere(KeyDeliveryApprovals.shared.record(owner: me, circleId: circleId), me: me),
            members: (rosters[circleId] ?? []).map { member in
                AccessHandover.Member(
                    userId: member.userId, displayName: member.displayName,
                    sharingKeyHex: sharingPubkeyCache[cacheKey(circleId, member.userId)],
                    signingKeyHex: signingPubkeyCache[cacheKey(circleId, member.userId)])
            },
            candidates: membershipCandidates[circleId] ?? [:],
            result: result,
            record: KeyDeliveryApprovals.shared.record(owner: me, circleId: circleId),
            now: Date(),
            eDeliver: eDeliver,
            pinGate: { MemberKeyPinner.shared.gateMembersForRotation(circleId: circleId, currentUserId: me, members: $0) })
        guard !targets.isEmpty else { return }
        deliveriesInFlight.insert(circleId)
        defer { deliveriesInFlight.remove(circleId) }

        for target in targets {
            do {
                let bundle = try cryptoManager.wrapCircleKeyForMemberFull(
                    circleId: circleId,
                    memberPublicKeyHex: target.sharingKeyHex,
                    senderUserId: me,
                    recipientUserId: target.userId,
                    recipientSigningPubkeyHex: target.signingKeyHex
                )
                try await api.deliverAccess(
                    circleId: circleId,
                    userId: target.userId,
                    keyVersion: circle.keyVersion,
                    encryptedCircleKey: EncryptedBlobRequest(
                        nonce: bundle.encryptedCircleKey.nonce,
                        ciphertext: bundle.encryptedCircleKey.ciphertext
                    ),
                    ephemeralPublicKey: bundle.ephemeralPublicKey,
                    wrapSignature: bundle.wrapSignature
                )
                markDelivered(circleId: circleId, userId: target.userId, keyVersion: circle.keyVersion)
                Self.keyLog.info("delivered circle \(circleId, privacy: .public) v\(circle.keyVersion, privacy: .public) to a confirmed member")
            } catch let error as APIError where error.isServerCode("key_already_delivered", "http_409") {
                // Someone else's app delivered first: the next roster load shows it.
                markDelivered(circleId: circleId, userId: target.userId, keyVersion: circle.keyVersion)
            } catch let error as APIError where error.isServerCode("key_version_mismatch", "circle_target_not_member") {
                // The circle moved on, or they left: the next refresh sorts it out.
                Self.keyLog.info("delivery in circle \(circleId, privacy: .public) overtaken: \(error.errorCode ?? error.code, privacy: .public)")
            } catch {
                Self.keyLog.error("delivery to a member of circle \(circleId, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// The send-side gate for handing a member the circle — delivery and
    /// rotation both (`AccessHandover.sendSideGate`). Here a confirmed member
    /// goes through the pinner: pinned on first contact, blocked (and asked
    /// about) when their keys differ from the pin. Returns who is blocked.
    private func sendSideGate(
        circleId: String, me: String, result: MembershipConfirmation.Result,
        members: [AccessHandover.GateMember]
    ) -> Set<String> {
        AccessHandover.sendSideGate(
            me: me, result: result, record: KeyDeliveryApprovals.shared.record(owner: me, circleId: circleId),
            members: members,
            pinGate: { MemberKeyPinner.shared.gateMembersForRotation(circleId: circleId, currentUserId: me, members: $0) })
    }

    /// Record a delivery locally so "Joining…" clears at once; the next roster
    /// load brings the server's word.
    private func markDelivered(circleId: String, userId: String, keyVersion: Int) {
        if let index = rosters[circleId]?.firstIndex(where: { $0.userId == userId }) {
            rosters[circleId]?[index].keyVersion = keyVersion
        }
        if let index = members[circleId]?.firstIndex(where: { $0.userId == userId }) {
            members[circleId]?[index].keyVersion = keyVersion
        }
    }

    /// Clear a circle's in-flight rotation marker once its auto-rotation
    /// Task settles (success or failure), so a later membership change can re-arm
    /// it on a subsequent sweep. @MainActor-isolated.
    private func clearRotationInFlight(_ circleId: String) {
        rotationsInFlight.remove(circleId)
    }

    func rotateCircleKey(for circleId: String) async throws {
        // Real key rotation: SDK.prepareKeyRotation generates a new
        // symmetric key, re-encrypts the circle name with it, and wraps
        // it for each member's X25519 public key in one call. We pair
        // that with a key chain link (old key encrypted with new key) so
        // members can still decrypt historical data.
        //
        // Never for the personal key's slot, whatever put it in `circles`: a
        // "rotation" there would wrap a new personal key to the listed members
        // and seal the old one under it. The sweep, an owed rotation and a
        // transition all come through here.
        guard !CanonicalId.isPersonalSlot(circleId) else {
            Self.keyLog.error("a rotation of the personal key's slot as a circle was refused")
            return
        }
        // A rotation leaves this account's sealed name under the older key,
        // where a newcomer can't open it: sealed again once the key moved on.
        let versionBefore = try? cryptoManager.getActiveVersion(circleId: circleId)
        defer {
            if Self.versionAdvanced(from: versionBefore, to: try? cryptoManager.getActiveVersion(circleId: circleId)) {
                Task { await self.sealOwnName(circleId: circleId) }
            }
        }
        guard let circle = circles.first(where: { $0.id == circleId }) else {
            throw CircleError.memberNotFound
        }
        // The repair entry, read once: this admission, the change's name and
        // its build all answer the same one.
        let due = repairsDue[CanonicalId.key(circleId)]
        if nameHoldsBack(circle, due: due) {
            // Behind on this circle: the key it is in, and its name, may be
            // under a version this device doesn't hold yet. A repair answering
            // a MISATTRIBUTED version goes on.
            print("[Track] rotateCircleKey: skipping circle \(circleId) — behind on its key")
            return
        }
        if !keyChangesMayBuild(circle) {
            // After this account's password reset, nothing is built until
            // its own admission is served (`publishSelfAdmissionsIfDue`).
            print("[Track] rotateCircleKey: \(circleId) waits for this account's own admission")
            return
        }
        if circle.readableName == nil {
            // A name that doesn't open holds nothing back while the key in use
            // is held: the change goes without one.
            print("[Track] rotateCircleKey: circle \(circleId): the name doesn't open here; the stored one stays")
        }

        guard let senderUserId = AuthManager.shared.userId else {
            print("[Track] rotateCircleKey: missing self userId — skipping")
            return
        }

        // Who gets the new key and who is left pending — hidden members,
        // unapproved newcomers and blocked key changes. The TOFU send-side
        // gate runs inside: a member whose server-supplied key does not match
        // our pin is never wrapped to (and raises the key-change alert), but
        // does not hold up the rotation for everyone else.
        let (plan, keysById, blocked) = try await planRotation(for: circle, rotatorUserId: senderUserId)
        // The rotation step has its own reason to rotate: a keyless join's
        // "nobody to deliver to" never cancels it, and neither does a
        // rotation the circle's records are owed.
        if plan.skip && !rotationStepPending(circleId) && !recordedRotationDue(circle) {
            print("[Track] rotateCircleKey: skipping \(circleId) — a keyless join is its only reason and nobody owed the key is approved yet")
            return
        }
        // A plain member's device runs the refresh only if it confirms EVERYONE
        // listed — it must not leave anyone out on its own reckoning; that stays
        // with an owner or admin. A receive-only member's device never runs it.
        if !Self.mayRunRefresh(pending: plan.pending.count, iAmOwnerOrAdmin: isOwnerOrAdmin(circle),
                               selfIsReceiveOnly: selfIsReceiveOnly(circleId)) {
            print("[Track] rotateCircleKey: leaving \(circleId) to an owner or admin — \(plan.pending.count) member(s) this device would leave out")
            return
        }
        // With refresh records, or an owner's or admin's first rotation of
        // a circle without records, the change carries its record; its
        // records not imported in this process yet, or forked: not now.
        var mode = rotationMode(for: circle, due: due)
        if mode == .transition, transitionRefused(circleId) { mode = .legacy }
        switch mode {
        case .wait:
            print("[Track] rotateCircleKey: \(circleId) waits for its records")
            return
        case .transition, .recorded:
            let change: RecordedChange
            do {
                change = try prepareRecordedChange(circle, me: senderUserId, mode: mode, due: due, decision: plan,
                                                   blocked: blocked)
            } catch let refusal where RecordedRotation.notYet(refusal) {
                // "Import this circle's records first": no failure and no
                // back-off; it is tried again after the next import of its
                // records.
                changesAwaitingImport.wait(circleId)
                Self.keyLog.info("circle \(circleId, privacy: .public): its change waits for the next import of its records")
                return
            } catch let refusal as MobileError where mode == .transition {
                // The SDK refused this list's first record (e.g. a listed owner
                // with no keys): the circle stays without records until its
                // list changes, and is never tried again on the same list. A
                // refresh the server's flag asks for goes the legacy way, with
                // no record; nothing else happens.
                noteTransitionRefused(circleId, refusal)
                guard circle.keyRotationNeeded || rotationStepPending(circleId) else { return }
                break
            }
            try await sendRecordedRotation(circle, me: senderUserId, change: change)
            try await loadCircles()
            return
        case .legacy:
            break
        }
        let wrapTo = plan.wrap.compactMap { keysById[$0] }

        // Rotation signs each per-member wrap with the rotator's
        // Ed25519 key, so the SDK also needs every member's verifying
        // key. Members without a published signing key get empty
        // strings — the SDK leaves the signature empty for them
        // during the grace period.
        // The name only from the key in use, else none: the server keeps it.
        let sealable = sealableName(circle)
        let bundle = try cryptoManager.prepareKeyRotation(
            circleId: circleId,
            senderUserId: senderUserId,
            memberUserIds: wrapTo.map(\.userId),
            memberPublicKeysHex: wrapTo.map(\.sharingPublicKey),
            memberSigningPubkeysHex: wrapTo.map { $0.signingPublicKey ?? "" },
            currentCircleNamePlaintext: sealable ?? ""
        )

        // Best-effort key chain link — failing here just means historical
        // ciphertext stays sealed under the old key; rotation itself
        // still proceeds.
        let chainLink: KeyChainLinkRequest? = (try? cryptoManager.createKeyChainLink(circleId: circleId))
            .map { link in
                KeyChainLinkRequest(
                    fromVersion: Int(link.fromVersion),
                    toVersion: Int(link.toVersion),
                    encryptedKey: link.encryptedKey,
                    nonce: link.nonce
                )
            }

        let request = RotateKeysRequest(
            encryptedName: Self.legacyEncryptedName(sealable: sealable, sealed: bundle.encryptedName),
            memberKeys: bundle.memberKeys.map { entry in
                MemberKeyUpdateRequest(
                    userId: entry.userId,
                    encryptedCircleKey: EncryptedBlobRequest(
                        nonce: entry.bundle.encryptedCircleKey.nonce,
                        ciphertext: entry.bundle.encryptedCircleKey.ciphertext
                    ),
                    ephemeralPublicKey: entry.bundle.ephemeralPublicKey,
                    wrapSignature: entry.bundle.wrapSignature.isEmpty ? nil : entry.bundle.wrapSignature
                )
            },
            expectedKeyVersion: circle.keyVersion,
            keyChainLink: chainLink,
            pendingMembers: plan.pending.isEmpty ? nil : plan.pending.sorted()
        )

        let response: RotateKeysResponse
        do {
            response = try await api.rotateKeys(circleId: circleId, request: request)
        } catch {
            // Same as the eject path: an unconfirmed key of ours must not stay
            // active.
            _ = cryptoManager.discardUnconfirmedRotation(circleId: circleId)
            throw error
        }
        if response.alreadyRotated == true {
            print("[Track] rotateCircleKey: another client rotated first for \(circleId); refreshing")
        }
        try await loadCircles()
    }

    // MARK: - Errors

    enum CircleError: LocalizedError {
        case noCircleKey
        case notOwner
        case memberNotFound
        /// Removal could not be completed. Carries its own text because every
        /// reason is different and the person needs to know the member is still
        /// in the circle.
        case ejectFailed(String)
        /// The circle moved to a key this device has not received; nothing new
        /// may be sealed for it (see `holdsCurrentKey(for:)`).
        case keyNotCurrent
        /// Nothing may be SIGNED for the circle either — an invitation or an
        /// admission carries this device's version.
        case waitingToSync
        /// The invited account's identity changed since this device last saw
        /// it; nothing was sent. The invite sheet asks "Is this really…?".
        case inviteeChanged(InviteeChange)
        /// A promotion to admin whose member shows other details than the ones
        /// this device holds for them, or than the question showed: nothing was
        /// signed and the role did not change.
        case promotionDetailsChanged
        /// The admission a promotion needs was not stored: the role did not change.
        case promotionNotDone
        /// What a role change owes the circle's records couldn't be kept on
        /// this device, so nothing was sent (`RoleRecord`).
        case roleChangeNotKept
        /// A hand-over this device couldn't build or keep now: nothing was
        /// sent.
        case handOverNotNow
        /// The member's details changed since the person decided, or they left:
        /// nothing was handed over.
        case handOverDetailsChanged
        /// A waiting "Let them in" whose member shows other keys than the
        /// question did, or whom this device pins with others: nothing was
        /// pinned or signed, and the person is asked again once.
        case letInDetailsChanged
        /// After "It's them" about one account, the address shows another
        /// account, other keys or none now: nothing was pinned, signed or sent,
        /// and nobody is asked again: item 30
        /// (`PendingChangeCopy.detailsKeepChangingInvite`), live or waiting.
        case inviteeDetailsChanged(email: String)
        /// A waiting invitation whose account the circle's records show removed
        /// after the person decided: nothing was signed; item 23
        /// (`PendingChangeCopy.memberLeft`).
        case removedSinceDecided(line: String)

        /// A write this device refused because it is behind: only what is true,
        /// in the words every Track client uses. The circle's own "waiting to
        /// sync" description stays where it describes the circle and its
        /// locations; it is not the answer to something a person just tried.
        static let notDoneWhileWaitingToSync =
            "Not done: this iPhone is still waiting to sync this circle's settings from another member."

        var errorDescription: String? {
            switch self {
            case .noCircleKey:
                return "This circle isn't open on this phone yet."
            case .notOwner:
                return "Only circle owner can perform this action"
            case .memberNotFound:
                return "Member not found"
            case .ejectFailed(let reason):
                return reason
            case .keyNotCurrent, .waitingToSync:
                return Self.notDoneWhileWaitingToSync
            case .inviteeChanged(let change):
                return InviteeChange.body(email: change.email, number: change.number)
            case .promotionDetailsChanged:
                return "Their details changed, so they weren't made an admin."
            case .promotionNotDone, .roleChangeNotKept:
                return "Nothing was changed. Please try again."
            case .handOverNotNow:
                return "Couldn't hand the circle over just now."
            case .handOverDetailsChanged:
                return "Their details changed, so the circle wasn't handed over."
            case .letInDetailsChanged:
                return "Their details changed, so they weren't let in."
            case .inviteeDetailsChanged(let email):
                // Item 30, word for word, as the web says it.
                return PendingChangeCopy.detailsKeepChangingInvite(email: email)
            case .removedSinceDecided(let line):
                return line
            }
        }
    }
}

/// An invited account whose identity changed since this device last saw it
/// (`CircleManager.inviteMember`): what the question shows, and what "It's
/// them" accepts.
struct InviteeChange: Equatable {
    let circleId: String
    let email: String
    let userId: String
    let sharingKeyHex: String
    let signingKeyHex: String
    /// Their security code with the new details; nil when it can't be worked out.
    let number: String?

    /// Words shared with the Android app (`invitee_changed_*`). Static so a
    /// test can pin them.
    static func title(email: String) -> String { "Is this really \(email)?" }

    static func body(email: String, number: String?) -> String {
        "\(email) reset their password, so Pingolin can't tell on its own that it's still them. If you're not sure, check with them another way first."
            + (number.map { "\n\nTheir number: \($0)" } ?? "")
    }
}
