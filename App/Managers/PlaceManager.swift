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
import CoreLocation
import Combine
import os
import UIKit
import PingolinTrackSDK

/// Manages places and geofencing
@MainActor
final class PlaceManager: ObservableObject {
    static let shared = PlaceManager()

    // MARK: - Published State

    @Published private(set) var places: [Place] = []
    /// UNION of the user's places across ALL their circles, used only for
    /// geofencing + region-event lookup — independent of `places`, which is
    /// filtered to the active circle for the map/list UI. A place shared only
    /// to a NON-active circle must still be monitored so its crossing fans out;
    /// tearing geofences down to just the active-circle survivors leaves those
    /// shared places unmonitored. Not @Published — no view observes it.
    private(set) var monitoredPlaces: [Place] = []
    @Published private(set) var placeAlerts: [String: [PlaceAlert]] = [:]
    private var loadedAlertList = false // placeId -> alerts
    @Published private(set) var isLoading = false

    /// When the last LIVE `/places` fetch succeeded. Gates `backgroundRefresh`
    /// loads only — a user-initiated load (Places visit, pull-to-refresh, map
    /// navigation, circle switch, deleteAlert) always goes to the network.
    private var lastSuccessfulPlacesFetch: Date?

    /// The ids of the places the server listed in the last live fetch (every
    /// page). Nil after a fetch that failed or served the saved copy: a place
    /// missing from those proves nothing. What a waiting change is checked
    /// against before a place counts as deleted.
    private(set) var listedPlaceIds: Set<String>?
    /// Debounce window for `backgroundRefresh` loads. Sized like its neighbour
    /// `SDKLocationStreamer.sendNow`'s rate limit: long enough to collapse the
    /// `.inactive` → `.active` churn from Control Centre / app-switcher /
    /// permission prompts, short enough that a real return to the app still
    /// re-reads the alert flag promptly.
    private static let backgroundRefreshMinInterval: TimeInterval = 30

    // MARK: - Dependencies

    private let api = APIService.shared
    private let cryptoManager = SDKCrypto.cryptoManager
    private let locationService = LocationService.shared
    private let circleManager = CircleManager.shared

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Region-monitoring caps + cold-launch replay

    /// Core Location hard-caps an app at 20 simultaneously-monitored regions;
    /// the 21st+ `startMonitoring` silently fails (see
    /// LocationService.monitoringDidFailFor). A premium user can have more than
    /// 20 alerted places across their circles, so we register only the nearest
    /// `maxMonitoredRegions` and re-prioritize as the user moves. SLC + Visit
    /// monitoring are separate subsystems that don't count against this cap.
    /// One non-place region can exist: the battery-saver sleep trial's exit
    /// region (`LocationService.saverSleepRegionIdentifier`, dev builds), so
    /// one slot of the 20 is reserved for it and places get 19.
    /// `LocationService` hides that region from `monitoredCircularRegions`, so
    /// the reconcile below never sees it and never removes it.
    static let maxMonitoredRegions = 19
    /// Minimum distance (m) the user must move before the nearest-N monitored
    /// set is re-evaluated. Damps region-registration churn from a jittery fix
    /// stream while staying well under typical geofence radii so a newly-near
    /// place is promoted before it's reached.
    private static let regionReprioritizeDistanceMeters: CLLocationDistance = 150
    /// Where the user was at the last nearest-N re-evaluation (churn gate).
    private var lastRegionPriorityLocation: CLLocation?
    /// Region crossings that arrived before the async cold-launch hydrate
    /// populated `monitoredPlaces`; replayed by `finishMonitoredLoad`. A
    /// CLRegion is a reference type, so holding it for replay is cheap.
    private var pendingRegionEvents: [(region: CLRegion, isEnter: Bool)] = []
    /// False until the first monitored-set load (hydrate or loadPlaces)
    /// completes. While false, an unresolved region crossing is BUFFERED rather
    /// than dropped, so the crossing that relaunched a killed app isn't lost to
    /// the hydrate race.
    private var monitoredSetReady = false

    private init() {
        setupGeofenceNotifications()
        observeLocationForRegionPriority()
        // Cold background-launch (a geofence enter/exit relaunched a killed app)
        // hits `init` with no UI-driven `loadPlaces` yet, so `monitoredPlaces`
        // is empty and the region event can't resolve to a place → the crossing
        // is dropped. Hydrate the monitored set from the ciphertext cache so the
        // relaunch handler finds the place. Keys are restored by
        // `SDKCrypto.loadPersistedKeys()` on first `cryptoManager` access
        // (already triggered above via the stored `cryptoManager` property).
        Task { await self.hydrateMonitoredFromCache() }
    }

    /// Decrypt the cached all-circles places snapshot into `monitoredPlaces`
    /// and register geofences, for the background-launch path where no UI
    /// `loadPlaces` has run. No-op once `monitoredPlaces` is populated (a live
    /// `loadPlaces` always wins). Best-effort: undecryptable rows (missing key)
    /// are dropped, exactly like `loadPlaces`.
    func hydrateMonitoredFromCache() async {
        // A concurrent loadPlaces already populated the set — it (or this) marks
        // the set ready and replays any buffered crossings, then we bail.
        guard monitoredPlaces.isEmpty else {
            await finishMonitoredLoad()
            return
        }
        guard let cached: [PlaceResponse] = await CacheStore.shared.load(
            [PlaceResponse].self, forKey: Self.allPlacesCacheKey
        ) else {
            // No ciphertext cache to hydrate from (fresh install / never loaded).
            // Nothing to resolve a buffered crossing against, so finish the load
            // (stop buffering) and let the eventual UI-driven loadPlaces catch up.
            await finishMonitoredLoad()
            return
        }
        let selfCircle = SelfKeyManager.selfCircleUuid
        let decoded = await Task.detached { [cryptoManager, selfCircle] in
            Self.decodePlaces(cached, cryptoManager: cryptoManager, selfCircleUuid: selfCircle)
        }.value
        // A concurrent loadPlaces may have populated the set while we awaited.
        guard monitoredPlaces.isEmpty, !decoded.isEmpty else {
            await finishMonitoredLoad()
            return
        }
        monitoredPlaces = Self.withoutDuplicateIds(decoded)
        setupGeofences()
        await finishMonitoredLoad()
    }

    /// Logout teardown for `AuthManager.logout()`: drop every decrypted,
    /// account-scoped store so account A's places (decrypted names +
    /// COORDINATES) and place alerts can't linger in memory — or as
    /// OS-registered geofences — for account B on the same device. Mirrors
    /// `CircleManager.reset()`. The on-disk cache is ciphertext-only and is
    /// wiped separately by `CacheStore.shared.clearAll()` in logout.
    func reset() {
        places = []
        monitoredPlaces = []
        takenShares = []
        placeAlerts = [:]
        loadedAlertList = false
        // Account B must not inherit A's debounce window, or B's first
        // foreground after a fast account switch would skip its places fetch.
        lastSuccessfulPlacesFetch = nil
        listedPlaceIds = nil
        // Monitored CLCircularRegions carry the decrypted place coordinates +
        // ids; tear them down so those don't survive the account switch. The
        // next login re-registers them via loadPlaces → setupGeofences.
        locationService.stopMonitoringAll()
        // Drop the cold-launch replay + region-priority state so a buffered
        // crossing (a region id) from account A can't be replayed against account
        // B, and B's first load re-arms the hydrate-race buffer from scratch.
        pendingRegionEvents = []
        monitoredSetReady = false
        lastRegionPriorityLocation = nil
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

    // MARK: - Place Operations

    /// `backgroundRefresh` marks a best-effort load the user did not ask for
    /// (the app-foreground re-read). Two things differ from a user-initiated
    /// load, and they travel together on purpose so any FUTURE background
    /// caller inherits both instead of re-discovering them:
    ///  - It is DEBOUNCED (`backgroundRefreshMinInterval`). `.onChange(of:
    ///    scenePhase)` fires on every transition into `.active`, and iOS emits
    ///    `.inactive` for Control Centre pulls, app-switcher peeks, call
    ///    banners and permission prompts — so an untimed foreground hook runs a
    ///    full paginated `/places` fetch plus a full re-decrypt of every place
    ///    several times a minute. Mirrors the staleness/rate limits its
    ///    neighbour `nudgeOwnLocationIfStale` already applies.
    ///  - It is SILENT on failure. The cache-fallback path posts to
    ///    `ErrorBanner`, which renders for 5s over RootView; an offline device
    ///    would show that banner on every single foreground for a refresh the
    ///    user never requested. User-initiated loads still report.
    func loadPlaces(for circleId: String, backgroundRefresh: Bool = false) async throws {
        if backgroundRefresh, let last = lastSuccessfulPlacesFetch,
           Date().timeIntervalSince(last) < Self.backgroundRefreshMinInterval {
            return
        }
        isLoading = true
        defer { isLoading = false }

        let cacheKey = Self.allPlacesCacheKey
        let responses: [PlaceResponse]
        do {
            // Fetch the UNION across ALL the user's circles (unfiltered). The
            // active-circle UI list is derived locally below; the union drives
            // geofencing so a place shared to a NON-active circle is still
            // monitored.
            responses = try await api.getAllPlaces()
            listedPlaceIds = Set(responses.map(\.id))
            await CacheStore.shared.save(responses, forKey: cacheKey)
            // Stamp only the LIVE fetch. A cache-fallback load must not start
            // the debounce window, or an offline foreground would suppress the
            // retry that lands once connectivity returns.
            lastSuccessfulPlacesFetch = Date()
            #if DEBUG
            Self.diag("places-fetch", "all responses=\(responses.count) active=\(circleId)")
            #endif
        } catch {
            listedPlaceIds = nil
            #if DEBUG
            Self.diag("places-fetch", "all FETCH_THREW active=\(circleId): \(error)")
            #endif
            if let cached: [PlaceResponse] = await CacheStore.shared.load([PlaceResponse].self, forKey: cacheKey) {
                print("[Track] loadPlaces: serving \(cached.count) place(s) from cache after \(error)")
                if !backgroundRefresh { ErrorBanner.shared.post(error) }
                responses = cached
            } else {
                throw error
            }
        }
        // Decrypt every place off the Main actor — unwrapPlaceKey + up to 4×
        // decryptWithPlaceKeyV2 per place; premium users have unlimited places,
        // so this loop can be long. `decodePlaces` is `nonisolated` + pure (only
        // the Sendable cryptoManager + value-type responses), so Task.detached is
        // race-safe (enforced by Swift strict concurrency); results are assigned
        // back on the Main actor after the await.
        let selfCircle = SelfKeyManager.selfCircleUuid
        let decoded = await Task.detached { [cryptoManager, responses, selfCircle] () -> [Place] in
            Self.decodePlaces(responses, cryptoManager: cryptoManager, selfCircleUuid: selfCircle)
        }.value
        // The full union drives geofencing + region lookup; the active-circle
        // subset drives the UI. A share taken here that this list doesn't show
        // yet stands over it: the list can come from a lagging replica, or the
        // cache.
        let listed = Self.keepingTakenShares(Self.withoutDuplicateIds(decoded), takenShares, now: Date())
        takenShares = listed.stillTaken
        let unique = listed.places
        monitoredPlaces = unique
        places = Self.visibleInUI(unique, activeCircleId: circleId, selfCircleUuid: selfCircle)

        // Reconcile geofences from the union (NOT just the active-circle
        // survivors) DIFFERENTIALLY: add newly-selected regions, drop ones that
        // fell out, re-register only those whose geometry changed, and leave an
        // unchanged region untouched. Deliberately NOT the full-teardown
        // `setupGeofences()` (stopMonitoringAll + re-add the nearest N) that the
        // cold-launch hydrate uses: on EVERY foreground / Places-visit /
        // circle-switch load a teardown briefly UNMONITORS every region (a
        // crossing in that gap is missed) and re-registers all of them even when
        // identical (CoreLocation churn) — and loadPlaces runs on every app
        // foreground (TrackApp scenePhase), so it would fire constantly. The
        // final monitored SET is identical: syncMonitoredRegions computes the
        // SAME nearest-N geofenced selection setupGeofences does (both share
        // `monitoredPlaces.filter(isGeofenced)` → nearestRegions(currentLocation,
        // maxMonitoredRegions)), and geometry is still refreshed for any place a
        // peer/web edit moved or resized. Cold-launch hydrate still uses
        // setupGeofences, so the OS set is established with fresh geometry before
        // the first loadPlaces diffs against it.
        syncMonitoredRegions()
        // Mark the monitored set ready + replay any crossing buffered during a
        // cold-launch hydrate race. Harmless on a warm foreground load (no
        // events buffered).
        await finishMonitoredLoad()

        for place in places {
            try await loadAlerts(for: place.id)
        }
        // Re-apply the local live-alert proof AFTER the decode above reinstalled
        // the server's place-scoped `alerts_enabled` (the `response.alertsEnabled
        // ?? false` constructions). This has to live here, at the choke point,
        // rather than at one caller: `loadAlerts` short-circuits on the
        // `loadedAlertList` session latch, so from the SECOND load of a session
        // onward `refreshAllAlerts` — the only other caller of the arm — never
        // runs, while the disarm half runs on EVERY load. Under read-replica lag
        // a just-created alert reads back FALSE, disarms the geofence, and
        // nothing would re-arm it until the app is relaunched.
        //
        // Safe by construction: `armAlertsEnabledFromFetch` is arm-only (it only
        // ever assigns `true`, and only where an own live alert exists), so it
        // can never disarm peer / circle-wide alert places, as a subscriber-scoped
        // list would. The sole disarm authority remains this function's re-decode
        // of the server flag. `syncMonitoredRegions` is differential — a no-op
        // when nothing armed.
        armAlertsEnabledFromFetch()
        syncMonitoredRegions()
    }

    /// Single cache key for the all-circles places snapshot. One key rather than
    /// one per circle, because the fetch is a union — which also lets the
    /// background-launch `hydrateMonitoredFromCache` restore the monitored set
    /// without knowing which circles exist.
    static let allPlacesCacheKey = "places.list.all"

    /// Every place whose id the list serves more than once, in any spelling,
    /// goes: none of them is used (the web does the same). The unfiltered
    /// `/places` returns one row per place. Keeping the FIRST row would let a
    /// server choose which of two contents a place id stands for, and so which
    /// geofence it registers and which alert fires. Fail closed.
    nonisolated static func withoutDuplicateIds(_ input: [Place]) -> [Place] {
        var counts: [String: Int] = [:]
        for place in input { counts[CanonicalId.key(place.id), default: 0] += 1 }
        let kept = input.filter { counts[CanonicalId.key($0.id)] == 1 }
        if kept.count != input.count {
            // A count only: never an id, a name or a position.
            print("[Track] places: \(input.count - kept.count) row(s) share an id; none of them is used")
        }
        return kept
    }

    /// The subset of the decoded union that the Places tab renders while
    /// `activeCircleId` is the active context. Two rules:
    ///
    ///   1. A place with no shares shows everywhere; a place WITH shares shows
    ///      in the circles it was shared to (`PlaceResponse.isVisible`).
    ///   2. The requester's OWN personal place is ALWAYS visible to them, no
    ///      matter who it has been shared to. Sharing grants a circle
    ///      ADDITIONAL visibility; it never hands the owner's own away.
    ///
    /// WHY RULE 2 EXISTS: without it, rule 1 alone would delete the owner's
    /// place from their own Places tab the moment it was shared: share a place
    /// to circle A, then look at circle B or the self view, and
    /// `shared.contains` is false. Deleting circle A would make that permanent,
    /// because deleting a circle does not remove a place's share to it, so
    /// `shared_circles` can keep naming a circle that cannot be switched to.
    /// The place stays on the server the whole time; and because
    /// `sharePlaceWithCircle` looks the place up in `places`, the owner could
    /// not even un-share it back into view.
    ///
    /// The web client and the Android app follow the same rule: the web's
    /// circle filter ORs in `!p.circleId`, and the Android app's Room query
    /// `observeByCircleIncludingShared` ORs in `circleId = 'self'`, so a
    /// personal place stays visible whichever circle is being viewed.
    ///
    /// `place.circleId == selfCircleUuid` IS the requester's own personal
    /// place, exactly. `decodePlaces` sets it to `wrapViaCircle ??
    /// response.circleId ?? selfCircleUuid`, and the server only sets
    /// `wrap_via_circle` for a place the requester does not own — so the
    /// fallback is reached only when the row came back with a NULL `circle_id`
    /// AND the owner-side wrap, which is the requester's own personal place
    /// and nothing else. (A share RECEIVED from someone else keeps its sharing
    /// circle here, so it still shows only in that circle.)
    nonisolated static func visibleInUI(
        _ decoded: [Place],
        activeCircleId: String,
        selfCircleUuid: String
    ) -> [Place] {
        decoded.filter { place in
            place.circleId == selfCircleUuid
                || PlaceResponse.isVisible(sharedCircles: place.sharedCircles, in: activeCircleId)
        }
    }

    /// Decrypt a `/places` response array into `Place` models. Pure +
    /// `nonisolated` so it runs off the Main actor (only the Sendable
    /// cryptoManager + value-type responses are captured). Shared by the live
    /// fetch and the cache-hydrate path so the two decode identically.
    /// `selfCircleUuid` is passed in (read on the caller's MainActor) because
    /// `SelfKeyManager` is @MainActor-isolated and this function is nonisolated.
    nonisolated static func decodePlaces(_ responses: [PlaceResponse], cryptoManager: CryptoManager, selfCircleUuid: String) -> [Place] {
        responses.compactMap { response -> Place? in
            // Places with a per-place key: every field is encrypted under
            // that key. The wrap pair on the response (wrappedKey +
            // wrappedKeyNonce) is under the receiving party's key
            // (owner side via self-key, or via `wrap_via_circle` for
            // shared recipients). Unwrap once, then decryptWithPlaceKey
            // each field. This matches the Android app's read in
            // `PlaceRepository`.
            //
            // targetCircle resolution: wrap_via_circle for share
            // recipients, circle_id for legacy circle-owned places,
            // self-circle UUID otherwise. The last fallback must NOT be
            // the *requesting* circle's id — that breaks owner reads of
            // personal per-place-key places, whose wrap is under self and
            // not under the active circle.
            //
            // Legacy fallback: rows written by older versions of the app
            // carry no wrappedKey. Those use direct circle-key
            // decryption of name + location, with the place-shares
            // envelope skipped entirely.
            let targetCircle = response.wrapViaCircle
                ?? response.circleId
                ?? selfCircleUuid
            let icon = Place.PlaceIcon(rawValue: response.icon ?? "custom") ?? .custom

            if let wrappedKey = response.wrappedKey,
               let wrappedKeyNonce = response.wrappedKeyNonce {
                let placeKeyHex: String
                do {
                    placeKeyHex = try cryptoManager.unwrapPlaceKey(
                        targetId: targetCircle,
                        wrappedKey: wrappedKey,
                        wrappedKeyNonce: wrappedKeyNonce
                    )
                } catch {
                    #if DEBUG
                    Self.diag("place-decrypt", "id=\(response.id) UNWRAP_THREW circle=\(targetCircle): \(error)")
                    #endif
                    return nil
                }
                let decryptedName: String = (try? cryptoManager.decryptWithPlaceKeyV2(
                    placeKeyHex: placeKeyHex,
                    encryptedData: EncryptedData(
                        nonce: response.encryptedName.nonce,
                        ciphertext: response.encryptedName.ciphertext
                    ),
                    fieldTag: "name"
                )) ?? Place.unopenedName
                let decryptedAddress: String? = response.encryptedAddress.flatMap { blob in
                    try? cryptoManager.decryptWithPlaceKeyV2(
                        placeKeyHex: placeKeyHex,
                        encryptedData: EncryptedData(nonce: blob.nonce, ciphertext: blob.ciphertext),
                        fieldTag: "address"
                    )
                }
                let decryptedNotes: String? = response.encryptedNotes.flatMap { blob in
                    try? cryptoManager.decryptWithPlaceKeyV2(
                        placeKeyHex: placeKeyHex,
                        encryptedData: EncryptedData(nonce: blob.nonce, ciphertext: blob.ciphertext),
                        fieldTag: "notes"
                    )
                }
                let locationJSON: String
                do {
                    locationJSON = try cryptoManager.decryptWithPlaceKeyV2(
                        placeKeyHex: placeKeyHex,
                        encryptedData: EncryptedData(
                            nonce: response.encryptedLocation.nonce,
                            ciphertext: response.encryptedLocation.ciphertext
                        ),
                        fieldTag: "location"
                    )
                } catch {
                    #if DEBUG
                    Self.diag("place-decrypt", "id=\(response.id) LOC_DECRYPT_THREW: \(error)")
                    #endif
                    return nil
                }
                guard let loc = LocationJSON.parse(locationJSON) else {
                    #if DEBUG
                    Self.diag("place-decrypt", "id=\(response.id) PARSE_FAILED json_prefix=\(locationJSON.prefix(200))")
                    #endif
                    return nil
                }
                return Place(
                    id: response.id,
                    circleId: targetCircle,
                    name: decryptedName,
                    latitude: loc.latitude,
                    longitude: loc.longitude,
                    radius: Double(response.boundaryRadius ?? Int(response.radiusMeters)),
                    placeType: response.placeType ?? "place",
                    boundaryRadius: response.boundaryRadius.map(Double.init),
                    alertsEnabled: response.alertsEnabled ?? false,
                    icon: icon,
                    color: response.color ?? "#3B82F6",
                    createdAt: Date(timeIntervalSince1970: TimeInterval(response.createdDayBucket) * 86_400),
                    address: decryptedAddress,
                    notes: decryptedNotes,
                    wrappedKey: wrappedKey,
                    wrappedKeyNonce: wrappedKeyNonce,
                    wrapTargetId: targetCircle,
                    sharedCircles: response.sharedCircles
                )
            }

            // Legacy path: name + location encrypted directly under
            // the targetCircle's key. No place key, no shares.
            let decryptedName: String = {
                let blob = EncryptedData(
                    nonce: response.encryptedName.nonce,
                    ciphertext: response.encryptedName.ciphertext
                )
                return (try? cryptoManager.decryptDataV2(circleId: targetCircle, encryptedData: blob, fieldTag: "name"))
                    ?? Place.unopenedName
            }()
            guard let legacyLoc = try? cryptoManager.decryptLocation(
                circleId: targetCircle,
                encryptedLocation: EncryptedData(
                    nonce: response.encryptedLocation.nonce,
                    ciphertext: response.encryptedLocation.ciphertext
                )
            ) else {
                #if DEBUG
                Self.diag("place-decrypt", "id=\(response.id) legacy decrypt failed circle=\(targetCircle)")
                #endif
                return nil
            }
            return Place(
                id: response.id,
                circleId: targetCircle,
                name: decryptedName,
                latitude: legacyLoc.latitude,
                longitude: legacyLoc.longitude,
                radius: Double(response.boundaryRadius ?? Int(response.radiusMeters)),
                placeType: response.placeType ?? "place",
                boundaryRadius: response.boundaryRadius.map(Double.init),
                alertsEnabled: response.alertsEnabled ?? false,
                icon: icon,
                color: response.color ?? "#3B82F6",
                createdAt: Date(timeIntervalSince1970: TimeInterval(response.createdDayBucket) * 86_400),
                address: nil,
                notes: nil,
                wrappedKey: nil,
                wrappedKeyNonce: nil,
                wrapTargetId: nil,
                sharedCircles: response.sharedCircles
            )
        }
    }

    /// Create a personal place. The place is owned by the
    /// current user and encrypted under a per-place key wrapped to
    /// the self-circle. Cross-circle visibility is added via the
    /// separate `sharePlaceWithCircle(_:_:)` call so multi-circle
    /// share lists land as multiple wraps rather than a single
    /// circle-direct encryption. Matches the Android app.
    ///
    /// `radius` is the place's ONE geofence radius, in metres, and it goes
    /// straight out as `radius_meters` — it is also the alert ring, so it is
    /// the user's choice and nothing else. `wireRadius(for:)` handles a 0
    /// ("no alert area chosen") and the server's accepted 50-25000 band.
    func createPlace(
        name: String,
        coordinate: CLLocationCoordinate2D,
        radius: Double,
        icon: Place.PlaceIcon,
        color: String,
        notes: String? = nil,
        address: String? = nil
    ) async throws -> Place {
        isLoading = true
        defer { isLoading = false }

        let place = try await createPlaceOverWire(
            name: name,
            coordinate: coordinate,
            radius: radius,
            icon: icon,
            color: color,
            notes: notes,
            address: address
        )

        // Keep the geofencing union in sync so a region event resolves to this
        // place even when the active circle later changes. An answer naming an
        // id already listed makes it one served twice: none of them is used,
        // as at a load.
        places = Self.withoutDuplicateIds(places + [place])
        monitoredPlaces = Self.withoutDuplicateIds(monitoredPlaces + [place])
        // Reconcile the registered set through the nearest-N cap rather than
        // an unconditional addGeofence. A brand-new place is alerts-disabled so
        // it isn't geofenced yet (no region added); routing through the cap keeps
        // create cap-safe if that ever changes.
        syncMonitoredRegions()

        return place
    }

    /// A place's fields as a waiting edit keeps them.
    nonisolated static func fields(of place: Place) -> PendingChange.PlaceFields {
        PendingChange.PlaceFields(name: place.name, latitude: place.latitude, longitude: place.longitude,
                                  radius: place.radius, icon: place.icon.rawValue, color: place.color)
    }

    /// Whether this device holds a key IN USE for `circleId`: what a seal or a
    /// wrap needs. `hasCircleKey` is also true for a personal slot that holds
    /// only the retired key from before a password reset, which seals nothing;
    /// for a circle the two agree. The SDK's write gate.
    private func holdsKeyInUse(_ circleId: String) -> Bool {
        cryptoManager.hasCircleKeyInUse(circleId: circleId)
    }

    /// Wrap the existing place key for `circleId` and post the wrap
    /// to `/api/v1/places/:id/share`. The place becomes visible to
    /// the circle's members on their next /places fetch. Requires
    /// that the place was created via `createPlace` above (legacy
    /// places have no place key to re-wrap).
    ///
    /// While this iPhone is behind in the circle the share waits.
    /// `waiting`: the waiting change being run now; a refusal while behind is
    /// then thrown, not queued again.
    func sharePlaceWithCircle(placeId: String, circleId: String, waiting: PendingChange? = nil) async throws {
        guard let userId = AuthManager.shared.userId else {
            throw APIError(code: "unauthorized", message: "No user id available")
        }
        // Every loaded place, not only the active circle's: a waiting share
        // runs whatever circle the screens show then.
        guard let place = monitoredPlace(for: placeId) else {
            throw APIError(code: "missing_place", message: "sharePlaceWithCircle: \(placeId) not loaded")
        }
        guard holdsKeyInUse(circleId) else {
            throw APIError(code: "missing_circle_key", message: "That circle isn't open on this phone yet")
        }
        // The place key is wrapped only under the circle's CURRENT key.
        do {
            try CircleManager.shared.requireCurrentKey(for: circleId)
        } catch CircleManager.CircleError.keyNotCurrent where waiting == nil {
            try PendingChanges.queue(.sharePlace, circleId: circleId, inputs: .sharePlace(placeId: placeId),
                                     subject: place.name)
            return
        }
        // We need the unwrapped place key to re-wrap for the new
        // recipient. Re-derive it from the persisted owner-side
        // wrap we keep on the Place model via the read path.
        let placeKey = try unwrapPlaceKeyForOwner(place)
        let wrap = try cryptoManager.wrapPlaceKey(
            targetId: circleId,
            placeKeyHex: placeKey,
            senderUserId: userId,
            placeId: placeId
        )
        _ = try await api.sharePlace(
            placeId: placeId,
            request: SharePlaceRequest(
                circleId: circleId,
                wrappedKey: wrap.wrappedKey,
                wrappedKeyNonce: wrap.wrappedKeyNonce
            )
        )
        recordShare(placeId: placeId, circleId: circleId, shared: true)
    }

    /// Remove a per-circle wrap. The place row stays on the owner;
    /// the targeted circle's members lose visibility on the next
    /// /places fetch.
    func unsharePlaceFromCircle(placeId: String, circleId: String) async throws {
        _ = try await api.unsharePlace(placeId: placeId, circleId: circleId)
        recordShare(placeId: placeId, circleId: circleId, shared: false)
    }

    /// A share or unshare the server has taken, recorded on this phone's copies
    /// of the place at once. The place list is read from a replica that can lag
    /// just after a change, and the Share Place switches, the circles a
    /// crossing fans out to and a waiting share's check all read these copies.
    /// Kept over the lists that follow until one shows it (`keepingTakenShares`).
    func recordShare(placeId: String, circleId: String, shared: Bool) {
        takenShares.removeAll { $0.placeId == placeId && CanonicalId.sameKey($0.circleId, circleId) }
        takenShares.append(TakenShare(placeId: placeId, circleId: circleId, shared: shared, at: Date()))
        places = places.map { Self.recordingShare($0, placeId: placeId, circleId: circleId, shared: shared) }
        monitoredPlaces = monitoredPlaces.map {
            Self.recordingShare($0, placeId: placeId, circleId: circleId, shared: shared)
        }
    }

    /// A share or unshare taken here, and when.
    struct TakenShare: Equatable {
        let placeId: String
        let circleId: String
        let shared: Bool
        let at: Date
    }

    /// The shares taken here that no list has shown yet (`keepingTakenShares`).
    private var takenShares: [TakenShare] = []

    /// How long a share taken here stands over lists that don't show it: far
    /// longer than the replica's lag, short enough that a change made later on
    /// another device shows here soon.
    nonisolated static let takenShareHold: TimeInterval = 60

    /// Pure: a list's places, with each share taken here that the list doesn't
    /// show yet kept as taken, and the ones still to keep. A share the list
    /// shows, one older than `takenShareHold`, or one of a place no longer
    /// listed is left to the list from then on.
    nonisolated static func keepingTakenShares(_ listed: [Place], _ taken: [TakenShare],
                                               now: Date) -> (places: [Place], stillTaken: [TakenShare]) {
        var places = listed
        var stillTaken: [TakenShare] = []
        for share in taken where now.timeIntervalSince(share.at) < takenShareHold {
            guard let index = places.firstIndex(where: { $0.id == share.placeId }) else { continue }
            let shown = (places[index].sharedCircles ?? []).contains { CanonicalId.sameKey($0, share.circleId) }
            guard shown != share.shared else { continue }
            places[index] = recordingShare(places[index], placeId: share.placeId, circleId: share.circleId,
                                           shared: share.shared)
            stillTaken.append(share)
        }
        return (places, stillTaken)
    }

    /// Pure: `place` with a share taken recorded, when it is the place meant.
    /// Ids compare in their one form, as a removal's subject does
    /// (`CanonicalId.sameKey`); an empty list is nil, as the server omits it.
    nonisolated static func recordingShare(_ place: Place, placeId: String, circleId: String,
                                           shared: Bool) -> Place {
        guard place.id == placeId else { return place }
        var circles = (place.sharedCircles ?? []).filter { !CanonicalId.sameKey($0, circleId) }
        if shared { circles.append(circleId) }
        var recorded = place
        recorded.sharedCircles = circles.isEmpty ? nil : circles
        return recorded
    }

    /// Per-place-key creation. Generates a per-place key, encrypts
    /// every field under that key, then wraps the place key for the
    /// owner via the self-circle. Server stores `circle_id = null`
    /// (personal place); cross-circle visibility is added separately
    /// via `sharePlaceWithCircle`. Mirrors the Android app's
    /// `PlaceRepository.createPersonalPlace`.
    private func createPlaceOverWire(
        name: String,
        coordinate: CLLocationCoordinate2D,
        radius: Double,
        icon: Place.PlaceIcon,
        color: String,
        notes: String? = nil,
        address: String? = nil
    ) async throws -> Place {
        guard let userId = AuthManager.shared.userId else {
            throw APIError(code: "unauthorized", message: "No user id available")
        }
        let selfCircle = SelfKeyManager.selfCircleUuid
        guard SelfKeyManager.personalKeyInUse(cryptoManager) else {
            // The self-circle key is required to wrap the place key
            // for the owner. SelfKeyManager.ensure should have run at
            // login; surface a clean error if it didn't. A key IN USE: a
            // slot holding only the retired key from before a password
            // reset wraps nothing new.
            throw APIError(code: "missing_self_key", message: "Your personal places aren't open on this phone yet")
        }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)

        // Step 1: fresh per-place key (hex-encoded 32-byte symmetric).
        let placeKey = cryptoManager.generatePlaceKey()

        // Step 2: encrypt every field under the place key — same
        // XChaCha20-Poly1305 primitive as direct circle-key paths
        // but the key is now per-place so future per-circle shares
        // just re-wrap the SAME key for new recipients.
        let encName = try cryptoManager.encryptWithPlaceKeyV2(placeKeyHex: placeKey, plaintext: name, fieldTag: "name")
        // Encrypt user_id with the self-circle key (NOT the place
        // key) — the user_id ties the row to its owner across
        // members reads and matches android's wire shape.
        let encUser = try cryptoManager.encryptData(circleId: selfCircle, plaintext: userId)
        // Location is JSON-encoded so cross-platform clients
        // (android / web) decode the same shape via decryptWithPlaceKey.
        let locationJSON = Self.makeLocationJSON(coordinate: coordinate, timestamp: nowMs)
        let encLoc = try cryptoManager.encryptWithPlaceKeyV2(placeKeyHex: placeKey, plaintext: locationJSON, fieldTag: "location")
        let encNotes: EncryptedBlobRequest? = try {
            guard let n = notes, !n.isEmpty else { return nil }
            let blob = try cryptoManager.encryptWithPlaceKeyV2(placeKeyHex: placeKey, plaintext: n, fieldTag: "notes")
            return EncryptedBlobRequest(nonce: blob.nonce, ciphertext: blob.ciphertext)
        }()
        let encAddress: EncryptedBlobRequest? = try {
            guard let a = address, !a.isEmpty else { return nil }
            let blob = try cryptoManager.encryptWithPlaceKeyV2(placeKeyHex: placeKey, plaintext: a, fieldTag: "address")
            return EncryptedBlobRequest(nonce: blob.nonce, ciphertext: blob.ciphertext)
        }()

        // Step 3: wrap the place key for the owner via the self-key.
        // placeId is unknown until the server creates the row; the
        // SDK is fine with "" here (the Android app passes `""` too).
        let ownerWrap = try cryptoManager.wrapPlaceKey(
            targetId: selfCircle,
            placeKeyHex: placeKey,
            senderUserId: userId,
            placeId: ""
        )

        // A place has ONE geofence radius, which IS its alert ring — so
        // this is the user's choice and the server stores exactly what
        // arrives here. See wireRadius for what it does with a zero and
        // for the clamp.
        let wireRadius = Self.wireRadius(for: radius)

        let request = CreatePlaceRequest(
            circleId: nil,
            encryptedName: EncryptedBlobRequest(nonce: encName.nonce, ciphertext: encName.ciphertext),
            encryptedAddress: encAddress,
            encryptedLocation: EncryptedBlobRequest(nonce: encLoc.nonce, ciphertext: encLoc.ciphertext),
            radiusMeters: wireRadius,
            icon: icon.rawValue,
            color: color,
            encryptedUserId: EncryptedBlobRequest(nonce: encUser.nonce, ciphertext: encUser.ciphertext),
            encryptedNotes: encNotes,
            wrappedKey: ownerWrap.wrappedKey,
            wrappedKeyNonce: ownerWrap.wrappedKeyNonce
        )

        let newId = try await api.createPlace(circleId: selfCircle, request: request)

        // Server returned just the new id — we already have every
        // other field locally from the cleartext we encrypted, so
        // build the Place model directly. createdAt is "now" on the
        // client; the server's authoritative timestamp will land on
        // the next loadPlaces refresh.
        return Place(
            id: newId,
            circleId: selfCircle,
            name: name,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            // What the SERVER now holds, not what was asked for: if the two
            // differed, the list would show a ring the backend had never
            // heard of until the next refresh quietly replaced it.
            radius: Double(wireRadius),
            placeType: "place",
            boundaryRadius: nil,
            // A brand-new place has no alert subscription yet (alerts are
            // configured separately), so it isn't monitored until the server
            // reports alerts_enabled on the next loadPlaces.
            alertsEnabled: false,
            icon: icon,
            color: color,
            createdAt: Date(),
            address: address,
            notes: notes,
            wrappedKey: ownerWrap.wrappedKey,
            wrappedKeyNonce: ownerWrap.wrappedKeyNonce,
            wrapTargetId: selfCircle
        )
    }

    /// Unwrap the place key for the owner. Used by
    /// `sharePlaceWithCircle` to re-wrap for a new recipient.
    private func unwrapPlaceKeyForOwner(_ place: Place) throws -> String {
        guard let wrappedKey = place.wrappedKey,
              let wrappedKeyNonce = place.wrappedKeyNonce,
              let target = place.wrapTargetId else {
            throw APIError(code: "legacy_place", message: "Legacy place — share unsupported")
        }
        return try cryptoManager.unwrapPlaceKey(
            targetId: target,
            wrappedKey: wrappedKey,
            wrappedKeyNonce: wrappedKeyNonce
        )
    }

    /// The unwrapped per-place key for a loaded place, or nil for a
    /// legacy circle-keyed place with no wrap. Works for the owner AND
    /// for share recipients — their wrap arrived via `wrap_via_circle`
    /// and is persisted on the model in `loadPlaces`, so the recipient
    /// can set/read alerts on a shared personal place without falling
    /// back to a circle key they don't hold. Mirrors the Android app's
    /// `placeDao.getById(placeId)?.placeKey`.
    private func placeKeyHex(for place: Place) -> String? {
        guard let wrappedKey = place.wrappedKey,
              let wrappedKeyNonce = place.wrappedKeyNonce,
              let target = place.wrapTargetId else { return nil }
        return try? cryptoManager.unwrapPlaceKey(
            targetId: target,
            wrappedKey: wrappedKey,
            wrappedKeyNonce: wrappedKeyNonce
        )
    }

    /// The value that goes in `radius_meters` on a create.
    ///
    /// WHY IT GOES THERE AND NOWHERE ELSE
    ///   The server's create request has no `boundary_radius` or `place_type`
    ///   field, and a field the server does not know is silently dropped with
    ///   a 200. Neither side reports it, so a radius sent under any other name
    ///   would simply be replaced by a default, and the only way that surfaces
    ///   is somebody noticing the value is wrong.
    ///
    /// WHAT IT DOES
    ///   Carries the radius through, with two guards:
    ///     - 0 means "no alert area chosen" (MapView passes `addBoundary ?
    ///       radiusMeters : 0`). The server's floor is 50, so a literal 0 would
    ///       400 the whole create. Falls back to the range floor — the place is
    ///       unmonitored until an alert subscription flips `alerts_enabled`
    ///       server-side regardless.
    ///     - Anything outside the server's accepted band is clamped rather than
    ///       sent to be refused. The sliders cannot produce such a value, but this
    ///       is a public entry point and a 400 here reads to the user as "saving
    ///       failed" with no mention of a radius.
    nonisolated static func wireRadius(for radius: Double) -> Int {
        /// The server's accepted radius band, applied on both create and
        /// update: 50 to 25000 metres.
        let serverMin = 50
        let serverMax = 25_000
        guard radius.isFinite, radius > 0 else { return Int(PlaceRadius.range.lowerBound) }
        return Swift.min(Swift.max(Int(radius.rounded()), serverMin), serverMax)
    }

    /// JSON shape compatible with the Android app + web. Keeps the SDK
    /// `decryptWithPlaceKey` → `LocationJSON.parse` decode round-trip
    /// portable across platforms.
    private static func makeLocationJSON(coordinate: CLLocationCoordinate2D, timestamp: Int64) -> String {
        let dict: [String: Any] = [
            "latitude":  coordinate.latitude,
            "longitude": coordinate.longitude,
            "altitude":     NSNull(),
            "speed":        NSNull(),
            "heading":      NSNull(),
            "accuracy":     NSNull(),
            "timestamp":    timestamp,
            "batteryLevel": NSNull(),
            "isCharging":   false,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: dict)) ?? Data("{}".utf8)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// While this iPhone is behind in an older circle-owned place's circle, the
    /// edit waits, against the place as it was shown. `waiting`: the waiting
    /// change being run now.
    func updatePlace(_ place: Place, waiting: PendingChange? = nil) async throws {
        // Re-encrypt the (possibly renamed) name and (possibly moved)
        // coordinate with the place's circle key, then PUT the request.
        // Backend route: PUT /api/v1/places/:id.
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)

        // Re-encrypt name + location with the SAME key the place was
        // created under: the per-place key for places that have one
        // (wrapped to the owner + every shared circle), the circle key
        // only for legacy circle-keyed places. Re-encrypting a per-place-key
        // place with the circle key corrupts its place-key encryption on
        // edit, so the branch below is not optional. Its location must be
        // the JSON shape loadPlaces decodes via decryptWithPlaceKey +
        // LocationJSON.parse, so it mirrors createPlaceOverWire exactly.
        let encNameBlob: EncryptedBlobRequest
        let encLocBlob: EncryptedBlobRequest
        if let placeKey = placeKeyHex(for: place) {
            let n = try cryptoManager.encryptWithPlaceKeyV2(placeKeyHex: placeKey, plaintext: place.name, fieldTag: "name")
            let locationJSON = Self.makeLocationJSON(coordinate: place.coordinate, timestamp: nowMs)
            let l = try cryptoManager.encryptWithPlaceKeyV2(placeKeyHex: placeKey, plaintext: locationJSON, fieldTag: "location")
            encNameBlob = EncryptedBlobRequest(nonce: n.nonce, ciphertext: n.ciphertext)
            encLocBlob = EncryptedBlobRequest(nonce: l.nonce, ciphertext: l.ciphertext)
        } else {
            // A legacy circle-keyed place is re-sealed only under the
            // circle's current key.
            do {
                try CircleManager.shared.requireCurrentKey(for: place.circleId)
            } catch CircleManager.CircleError.keyNotCurrent where waiting == nil {
                let shown = places.first(where: { $0.id == place.id }) ?? place
                try PendingChanges.queue(
                    .editPlace, circleId: place.circleId,
                    inputs: .editPlace(placeId: place.id, fields: Self.fields(of: place)),
                    seen: .init(place: Self.fields(of: shown)), subject: shown.name)
                return
            }
            let n = try cryptoManager.encryptDataV2(circleId: place.circleId, plaintext: place.name, fieldTag: "name")
            let sdkLocation = PingolinTrackSDK.Location(
                latitude: place.latitude,
                longitude: place.longitude,
                altitude: nil,
                speed: nil,
                heading: nil,
                accuracy: nil,
                timestamp: nowMs,
                batteryLevel: nil,
                isCharging: nil as Bool?
            )
            let l = try cryptoManager.encryptLocation(circleId: place.circleId, location: sdkLocation)
            encNameBlob = EncryptedBlobRequest(nonce: n.nonce, ciphertext: n.ciphertext)
            encLocBlob = EncryptedBlobRequest(nonce: l.nonce, ciphertext: l.ciphertext)
        }

        // Same guard the create path uses, and for the same reason: the server
        // applies the identical (50, 25000) check here, so a value outside it
        // is a 400 that reaches the user as "saving failed" with no mention of
        // a radius. `Int(_:)` also traps on a non-finite Double, which the guard
        // keeps from it.
        let wireRadius = Self.wireRadius(for: place.radius)

        let request = UpdatePlaceRequest(
            encryptedName: encNameBlob,
            encryptedAddress: nil,
            encryptedLocation: encLocBlob,
            radiusMeters: wireRadius,
            icon: place.icon.rawValue,
            color: place.color,
            encryptedNotes: nil
        )

        _ = try await api.updatePlace(placeId: place.id, request: request)

        // Mirror what the SERVER now holds, not what was asked for. If the
        // radius was clamped above, keeping the requested value locally would
        // show a ring the backend never stored, until the next refresh
        // silently replaced it.
        var saved = place
        saved.radius = Double(wireRadius)

        if let index = places.firstIndex(where: { $0.id == place.id }) {
            places[index] = saved
        }
        // Mirror the edit into the geofencing union so the monitored region
        // uses the new coordinate/radius even when this place isn't in the
        // active-circle UI list.
        if let mIndex = monitoredPlaces.firstIndex(where: { $0.id == place.id }) {
            monitoredPlaces[mIndex] = saved
        }
        // Drop the stale-geometry region, then reconcile through the nearest-N
        // cap: the edited place is re-registered with its new coordinate/radius
        // if it still ranks in the nearest set, and any slot it frees is
        // refilled. An unconditional re-add here would instead push past the
        // region cap when editing a geofenced place beyond the cap.
        removeGeofence(for: place.id)
        syncMonitoredRegions()
    }

    func deletePlace(_ place: Place) async throws {
        _ = try await api.deletePlace(placeId: place.id)
        places.removeAll { $0.id == place.id }
        monitoredPlaces.removeAll { $0.id == place.id }
        removeGeofence(for: place.id)
        // A freed monitoring slot can now hold the next-nearest geofenced place
        // that was over the cap — reconcile so it gets registered instead of
        // leaving the slot empty.
        syncMonitoredRegions()
    }

    // MARK: - Alerts

    func loadAlerts(for placeId: String) async throws {
        // Backend returns the full list of alerts the current user owns —
        // there's no per-place filter on the server. Fetch once, group
        // locally. For multi-place callers (loadPlaces), this means the
        // first invocation does the network round-trip and the rest hit
        // the in-memory cache.
        if loadedAlertList == false {
            try await refreshAllAlerts()
        }
        // Touch the dictionary so callers that expected a key always get one.
        if placeAlerts[placeId] == nil {
            placeAlerts[placeId] = []
        }
    }

    /// Refresh every alert the current user owns and group by placeId. The
    /// alert's encrypted_target_user_id is decrypted opportunistically —
    /// the PlaceAlert model only carries the resolved user_id, so failures
    /// fall through to the alert creator's id.
    func refreshAllAlerts() async throws {
        // `listPlaceAlerts` returns a SINGLE cursor page (at most `alertPageLimit`
        // rows), not a full drain. That's fine for grouping, but it means "this
        // place is absent from the page" is NOT proof the server has no alert for
        // it — so nothing below disarms a place because it is absent.
        let alertPageLimit = 100
        let responses = try await api.listPlaceAlerts(limit: alertPageLimit)
        var grouped: [String: [PlaceAlert]] = [:]
        for response in responses {
            // Look up in the geofencing union, not just the active-circle list,
            // so an alert on a place shared to a NON-active circle still resolves
            // its place (for target decrypt + routing circle).
            let owningPlace = monitoredPlace(for: response.placeId)
            let targetUserId: String = {
                guard let place = owningPlace else { return response.userId }
                let blob = EncryptedData(
                    nonce: response.encryptedTargetUserId.nonce,
                    ciphertext: response.encryptedTargetUserId.ciphertext
                )
                // Per-place key where the place has one; circle key for legacy.
                if let placeKey = placeKeyHex(for: place) {
                    return (try? cryptoManager.decryptWithPlaceKeyV2(placeKeyHex: placeKey, encryptedData: blob, fieldTag: "target_user_id"))
                        ?? response.userId
                }
                return (try? cryptoManager.decryptDataV2(circleId: place.circleId, encryptedData: blob, fieldTag: "target_user_id"))
                    ?? response.userId
            }()
            let alertType: PlaceAlert.AlertType
            switch (response.alertOnArrival, response.alertOnDeparture) {
            case (true, true): alertType = .both
            case (false, true): alertType = .departure
            default: alertType = .arrival
            }
            // A circle-wide alert decrypts to the "all" sentinel — surface
            // nil to the editor so "Everyone" pre-selects.
            let editorTarget: String? = (targetUserId == "all" || targetUserId.isEmpty) ? nil : targetUserId
            let alert = PlaceAlert(
                id: response.id,
                placeId: response.placeId,
                userId: targetUserId,
                alertType: alertType,
                isEnabled: response.isActive,
                targetUserId: editorTarget,
                activeDays: response.activeDays,
                activeStartTime: response.activeStartTime,
                activeEndTime: response.activeEndTime,
                notifyPush: response.notifyPush,
                notifyEmail: response.notifyEmail,
                notifySms: response.notifySms,
                // Carry the server-owned lifecycle flags so a later iOS edit can
                // round-trip them unchanged.
                isRecurring: response.isRecurring,
                expiresAt: response.expiresAt,
                // Prefer the alert's own routing circle (its `circle_id`);
                // the place circle is the self sentinel for a personal place.
                circleId: response.circleId ?? owningPlace?.circleId,
                suppressedByTarget: response.suppressedByTarget ?? false
            )
            grouped[response.placeId, default: []].append(alert)
        }
        placeAlerts = grouped
        loadedAlertList = true

        // Arm (only) each loaded place that has an OWN live alert in this fresh
        // list — a live own row is PROOF the server's place-scoped `alerts_enabled`
        // is TRUE (creating an alert flips it server-side), so it is safe to arm
        // here without a places round-trip. This does NOT disarm: `placeAlerts` is
        // SUBSCRIBER-scoped (listPlaceAlerts returns only the caller's own
        // subscriptions), so its emptiness for a place can't tell TRUE from FALSE
        // for the PLACE — a peer's or circle-wide alert that names this user as
        // TARGET is subscribed by someone else and never appears here.
        // Disarm authority is the server flag, re-installed by loadPlaces at the
        // call sites (PlacesView .task / pull-refresh, deleteAlert), correct in
        // BOTH directions. Then reconcile the OS region set — an arm adds a region,
        // and syncMonitoredRegions is a differential no-op when nothing changed.
        armAlertsEnabledFromFetch()
        syncMonitoredRegions()

        // Circle-key-rotation recovery: a rotation leaves the server match
        // hashes derived from the OLD key, so a mover's new-key crossing no
        // longer matches and the alert silently stops firing. Re-derive with
        // the current circle key and refresh server-side. Best-effort — a
        // failure just leaves needs_hash_update set for the next load.
        for response in responses where response.needsHashUpdate == true {
            // Re-derive under the ALERT'S routing circle (its `circle_id`),
            // falling back to the place's own circle. For a PERSONAL place the
            // place circle is the self sentinel — an alert is NEVER homed there,
            // and hashing under self yields a value that can't match the alert
            // (keyed to a REAL circle), so a personal place's alert would stop
            // firing after a rotation. Skip the self sentinel and any alert
            // whose routing circle we can't resolve.
            let routingCircleId = response.circleId ?? monitoredPlace(for: response.placeId)?.circleId
            guard let circleId = routingCircleId,
                  circleId != SelfKeyManager.selfCircleUuid else { continue }
            let arrivalHash: String? = response.alertOnArrival
                ? (try? cryptoManager.computeEventTypeHash(circleId: circleId, eventType: "arrival"))
                : nil
            let departureHash: String? = response.alertOnDeparture
                ? (try? cryptoManager.computeEventTypeHash(circleId: circleId, eventType: "departure"))
                : nil
            // The enter/exit hashes are the ones the worker matches a crossing
            // against — without them the alert never fires and the backend won't
            // clear needs_hash_update. enter ↔ arrival trigger, exit ↔ departure.
            let enterHash: String? = response.alertOnArrival
                ? (try? cryptoManager.computeEventTypeHash(circleId: circleId, eventType: "enter"))
                : nil
            let exitHash: String? = response.alertOnDeparture
                ? (try? cryptoManager.computeEventTypeHash(circleId: circleId, eventType: "exit"))
                : nil
            guard arrivalHash != nil || departureHash != nil || enterHash != nil || exitHash != nil else {
                // Nothing derivable for this alert's routing circle (no key for it).
                // Logged, and deliberately not silent: a skip here is otherwise
                // indistinguishable from a successful heal, which makes an alert
                // that has quietly stopped firing near-impossible to spot on device.
                NSLog("[place-alerts] skipped stale alert %@: no hash derivable for circle %@",
                      response.id, routingCircleId ?? "nil")
                continue
            }
            try? await api.refreshPlaceAlertHashes(
                alertId: response.id,
                arrivalHash: arrivalHash,
                departureHash: departureHash,
                enterHash: enterHash,
                exitHash: exitHash
            )
        }
    }

    /// ARM (only) every loaded place that has an OWN live alert in the list just
    /// fetched into `placeAlerts`. `alertsEnabled` is the only monitoring +
    /// crossing-report switch (`Place.isGeofenced`); this sets it TRUE where a live
    /// own alert proves it must be, and NEVER sets it FALSE. Flips the flag on BOTH
    /// the active-circle `places` copy and the monitored-union copy, matching
    /// `savePlaceAlert`; the caller reconciles the OS region set.
    ///
    /// "Live" = at least one alert that is enabled AND not past its `expiresAt`. A
    /// live own alert is PROOF the server's place-scoped `alerts_enabled` is TRUE —
    /// creating an alert flips it server-side — so we can arm without a places
    /// round-trip.
    ///
    /// Why arm-ONLY (no disarm here): `placeAlerts` is grouped from
    /// `listPlaceAlerts`, which the server scopes to the CURRENT USER as
    /// SUBSCRIBER. The server flag it must mirror is PLACE-scoped (TRUE iff >=1
    /// active subscription from ANY member targets the place). So a place being
    /// absent / all-dead in THIS user's list does NOT prove the flag is FALSE: a
    /// peer's or circle-wide alert that names this user as the TARGET is
    /// subscribed by someone else and never appears here. Disarming on that
    /// emptiness would darken a target device on every Places visit, stopping its
    /// `reportOwnCrossing` POSTs until the next loadPlaces re-armed it — a flap.
    /// Disarm authority is therefore the server flag, re-installed by loadPlaces at
    /// the call sites (PlacesView .task / pull-refresh, deleteAlert), correct in
    /// BOTH directions.
    private func armAlertsEnabledFromFetch() {
        let now = Date()
        func hasLiveAlert(_ placeId: String) -> Bool {
            guard let rows = placeAlerts[placeId] else { return false }
            return rows.contains { $0.isEnabled && !Self.isAlertExpired($0.expiresAt, now: now) }
        }
        func arm(_ place: inout Place) {
            if hasLiveAlert(place.id) { place.alertsEnabled = true }
        }
        for idx in places.indices { arm(&places[idx]) }
        for idx in monitoredPlaces.indices { arm(&monitoredPlaces[idx]) }
    }

    /// Whether an alert's optional RFC3339 `expiresAt` is in the past. Missing or
    /// unparseable ⇒ treated as NOT expired (fail toward keeping monitoring; never
    /// drop an alert on a parse miss). Tolerates the presence or absence of
    /// fractional seconds, mirroring NotificationsView.parseTimestamp.
    nonisolated static func isAlertExpired(_ expiresAt: String?, now: Date) -> Bool {
        guard let expiresAt, !expiresAt.isEmpty else { return false }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: expiresAt) { return d <= now }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let d = plain.date(from: expiresAt) { return d <= now }
        return false
    }

    /// Delete one alert row: server delete + drop it from the local per-place bell
    /// map. Does NOT touch monitoring — the caller owns how `alertsEnabled`
    /// reconciles (the pruning loop in `savePlaceAlerts` keeps the place armed via
    /// the alert it just created; the public `deleteAlert` re-reads the
    /// authoritative server flag). Split out so pruning doesn't fire a places
    /// round-trip per removed row.
    private func deleteAlertRow(_ alert: PlaceAlert) async throws {
        _ = try await api.deletePlaceAlert(alertId: alert.id)
        placeAlerts[alert.placeId]?.removeAll { $0.id == alert.id }
    }

    func deleteAlert(_ alert: PlaceAlert) async throws {
        try await deleteAlertRow(alert)
        // Disarm authority is the server's place-scoped `alerts_enabled`, not this
        // device's SUBSCRIBER-scoped `placeAlerts` list. The server recomputes the
        // flag on THIS delete: FALSE iff NO active subscription (from ANY member)
        // still targets the place, TRUE if a PEER's alert remains. Re-read it via
        // loadPlaces so the geofence disarms only when the place truly lost its
        // last alert, and STAYS armed when a peer still alerts it. Do NOT shortcut
        // this to a subscriber-scoped "my list is now empty ⇒ disarm": that
        // wrongly darkens the place (stopping `reportOwnCrossing`) whenever a peer
        // alert remains, then flaps back on the next loadPlaces. Going through the
        // authoritative path still disarms this device immediately when you delete
        // your last alert, with no relaunch needed.
        // loadPlaces re-installs alertsEnabled + rebuilds regions via
        // setupGeofences. Best-effort: the delete already succeeded, so a refresh
        // failure must not surface as a delete failure — the disarm then lands on
        // the next load.
        let circleId = circleManager.activeCircle?.id ?? SelfKeyManager.selfCircleUuid
        try? await loadPlaces(for: circleId)
    }

    /// Encrypt an alert's target with the per-place key, or the circle
    /// key for a legacy place, matching `createPlaceAlert`. A nil target
    /// encrypts the "all" sentinel (circle-wide).
    private func encryptAlertTarget(for place: Place, targetUserId: String?) throws -> EncryptedBlobRequest {
        let plaintext = (targetUserId?.isEmpty ?? true) ? "all" : targetUserId!
        if let placeKey = placeKeyHex(for: place) {
            let e = try cryptoManager.encryptWithPlaceKeyV2(placeKeyHex: placeKey, plaintext: plaintext, fieldTag: "target_user_id")
            return EncryptedBlobRequest(nonce: e.nonce, ciphertext: e.ciphertext)
        }
        guard holdsKeyInUse(place.circleId) else {
            throw APIError(code: "missing_circle_key", message: "This circle isn't open on this phone yet")
        }
        try CircleManager.shared.requireCurrentKey(for: place.circleId)
        let e = try cryptoManager.encryptDataV2(circleId: place.circleId, plaintext: plaintext, fieldTag: "target_user_id")
        return EncryptedBlobRequest(nonce: e.nonce, ciphertext: e.ciphertext)
    }

    /// The circle an alert on `place` should be homed + hashed to, or `nil` when
    /// the alert needs no circle at all and is evaluated entirely on this device.
    ///
    /// A circle-owned place uses its own circle. A PERSONAL place's circle is the
    /// self sentinel (nil-UUID), which the backend rejects for an alert (403) and
    /// which can never match a crossing's hash.
    ///
    /// Returning nil for an unshared personal place — rather than refusing with
    /// a "share it first" error — is deliberate and must stay that way.
    /// Subscriber-side evaluation removes the need for a circle entirely: this
    /// device already receives and decrypts every member's location and
    /// evaluates it against its own private place locally (PlaceAlertEvaluator),
    /// so there is nothing to route. Demanding a share instead asks the user to
    /// do the one thing the privacy model exists to prevent — sharing wraps the
    /// place's content key for the circle, making its name AND coordinates
    /// readable by every member.
    ///
    /// A SHARED personal place still prefers its shared circle, so the
    /// server-routed path keeps working and covers the case where this device is
    /// asleep. The two paths de-duplicate through the ledger in
    /// `PlaceAlertEvaluator`, in either arrival order.
    ///
    /// NOTE: when a personal place is shared to MORE than one circle this picks
    /// the first deterministically. The crossing itself still fans out to every
    /// shared circle (see reportOwnCrossing), so a same-circle subscriber is
    /// always reached.
    private func routingCircle(for place: Place, targetUserId: String?) -> String? {
        if place.circleId != SelfKeyManager.selfCircleUuid { return place.circleId }
        var candidates = place.sharedCircles ?? []
        if let wrap = place.wrapTargetId { candidates.append(wrap) }
        if let real = candidates
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty && $0 != SelfKeyManager.selfCircleUuid }) {
            return real
        }
        // Unshared personal place — local evaluation covers it.
        //
        // Self-targeted and circle-wide alerts need no circle: the backend leaves
        // `circle_id` NULL and derives no match hashes, exactly as the Android
        // app's "Just me" does.
        guard let target = targetUserId, target != AuthManager.shared.userId else { return nil }
        // A NON-SELF target still needs one, and not as a formality: the server
        // requires the target to be an active member of the chosen circle, and the
        // target's opt-out (`allow_alerts_on_me`) is anchored to that circle —
        // with no circle, the consent check would have nothing to look up. Pick a
        // circle the target actually belongs to. Nil when the roster is unknown,
        // which surfaces as the backend's own error rather than a silent miss.
        return CircleManager.shared.members
            .first { _, roster in roster.contains { $0.userId == target } }?
            .key
    }

    /// The zone the alert's active window is written in, as an IANA identifier.
    ///
    /// This is the ONE piece of a place alert's schedule the server cannot
    /// infer. `activeStartTime`/`activeEndTime` are wall-clock strings with no
    /// zone attached, so the server-side worker reads them in the
    /// subscription's stored timezone — which is 'UTC' unless a client sends
    /// one. Meanwhile this device's own evaluator uses `Calendar.current`.
    /// Sending the zone is what makes the two detectors agree.
    ///
    /// Read at save time rather than cached: the phone that edits an alert may
    /// not be in the zone the phone that created it was.
    ///
    /// `nonisolated` because the class is `@MainActor` and reading the device
    /// zone needs no actor — it also lets the wire test check it without
    /// hopping to the main actor.
    nonisolated static var currentTimezoneIdentifier: String { TimeZone.current.identifier }

    /// Unified create-or-update for the place-alert bell editor, mirroring
    /// the Android app's `savePlaceAlerts`. Encrypts the target with the
    /// per-place key, computes the privacy-preserving arrival/departure match
    /// hashes, then POSTs a new alert or PUTs an existing one. A nil target
    /// means everyone in the circle.
    ///
    /// Nil when the new alert waits for this iPhone to catch up.
    /// `waiting`: the waiting change being run now.
    @discardableResult
    func savePlaceAlert(
        placeId: String,
        existingAlertId: String?,
        targetUserId: String?,
        alertType: PlaceAlert.AlertType,
        activeDays: [String]?,
        activeStartTime: String?,
        activeEndTime: String?,
        notifyPush: Bool,
        notifyEmail: Bool,
        notifySms: Bool,
        waiting: PendingChange? = nil
    ) async throws -> PlaceAlert? {
        guard let place = monitoredPlace(for: placeId) else {
            throw APIError(code: "missing_place", message: "savePlaceAlert: place \(placeId) not loaded")
        }
        // Home the alert to a REAL circle. A PERSONAL place's own circle is the
        // self sentinel (nil-UUID), which the backend rejects (403); route to a
        // circle the place is shared to and derive the match hashes under that
        // same circle so a crossing (reported per shared circle) can match.
        // Circle-owned places pass through.
        let circleId = routingCircle(for: place, targetUserId: targetUserId)
        let wantsArrival = alertType == .arrival || alertType == .both
        let wantsDeparture = alertType == .departure || alertType == .both

        // Match hashes exist only for the SERVER-ROUTED path: they are derived
        // under a circle key so the blind server can match a reported crossing
        // against this subscription. A personal place with no routing circle is
        // evaluated entirely on this device (PlaceAlertEvaluator), so there is
        // nothing to match and no key to derive under — the alert is stored with
        // NULL hashes and fires locally.
        func eventHash(_ eventType: String, wanted: Bool) -> String? {
            guard wanted, let circleId else { return nil }
            return try? cryptoManager.computeEventTypeHash(circleId: circleId, eventType: eventType)
        }
        let arrivalHash = eventHash("arrival", wanted: wantsArrival)
        let departureHash = eventHash("departure", wanted: wantsDeparture)
        // Enter/exit are the hashes the place-alert worker actually matches a
        // crossing against (a crossing is reported under eventType "enter"/"exit").
        // Without them the alert's enter_type_hash/exit_type_hash stay NULL and it
        // NEVER fires — the arrival/departure names are legacy. Parity with
        // the Android app: enter ↔ arrival trigger, exit ↔ departure, keyed under
        // the SAME routing circle.
        let enterHash = eventHash("enter", wanted: wantsArrival)
        let exitHash = eventHash("exit", wanted: wantsDeparture)

        // Preserve the server-owned lifecycle flags the bell editor doesn't
        // expose (isRecurring / isActive / expiresAt). On UPDATE,
        // read them off the in-memory alert being edited so an iOS edit that only
        // changes trigger/schedule/notify doesn't reset columns the backend
        // full-replaces; on CREATE (existing == nil) they fall back to the prior
        // defaults (recurring, active, no expiry). Threaded into BOTH the update
        // request AND the returned/stored alert below, so a second same-session
        // edit re-sends the preserved values rather than the clobbered defaults.
        let existing = existingAlertId.flatMap { id in placeAlerts[placeId]?.first { $0.id == id } }
        let preservedIsRecurring = existing?.isRecurring ?? true
        let preservedIsActive = existing?.isEnabled ?? true
        let preservedExpiresAt = existing?.expiresAt

        let alertId: String
        if let existingAlertId {
            // UpdatePlaceAlertRequest can't change the target (no
            // encrypted_target_user_id field) — to retarget, delete +
            // recreate. Editing changes trigger / schedule / notify.
            let request = UpdatePlaceAlertRequest(
                alertOnArrival: wantsArrival,
                alertOnDeparture: wantsDeparture,
                activeDays: activeDays,
                activeStartTime: activeStartTime,
                activeEndTime: activeEndTime,
                encryptedConditions: nil,
                notifyPush: notifyPush,
                notifyEmail: notifyEmail,
                notifySms: notifySms,
                isRecurring: preservedIsRecurring,
                isActive: preservedIsActive,
                expiresAt: preservedExpiresAt,
                arrivalHash: arrivalHash,
                departureHash: departureHash,
                enterTypeHash: enterHash,
                exitTypeHash: exitHash,
                encryptedSchedule: nil,
                encryptedCooldown: nil,
                timezone: Self.currentTimezoneIdentifier
            )
            _ = try await api.updatePlaceAlert(alertId: existingAlertId, request: request)
            alertId = existingAlertId
        } else {
            let encTargetBlob: EncryptedBlobRequest
            do {
                encTargetBlob = try encryptAlertTarget(for: place, targetUserId: targetUserId)
            } catch CircleManager.CircleError.keyNotCurrent where waiting == nil {
                // An alert on an older circle-owned place, while this iPhone is
                // behind in its circle: it waits.
                try PendingChanges.queue(
                    .memberPlaceAlert, circleId: place.circleId,
                    inputs: .memberPlaceAlert(.init(
                        placeId: placeId, targetUserId: targetUserId, alertType: alertType.rawValue,
                        activeDays: activeDays, activeStartTime: activeStartTime, activeEndTime: activeEndTime,
                        notifyPush: notifyPush, notifyEmail: notifyEmail, notifySms: notifySms)),
                    subject: place.name,
                    member: targetUserId.flatMap { id in
                        CircleManager.shared.members[place.circleId]?.first { $0.userId == id }?.displayName
                    })
                return nil
            }
            let dayBucket = Int(Date().timeIntervalSince1970 / 86_400)
            let request = CreatePlaceAlertRequest(
                placeId: placeId,
                circleId: circleId,
                targetUserId: targetUserId,
                encryptedTargetUserId: encTargetBlob,
                alertOnArrival: wantsArrival,
                alertOnDeparture: wantsDeparture,
                activeDays: activeDays,
                activeStartTime: activeStartTime,
                activeEndTime: activeEndTime,
                encryptedConditions: nil,
                clientOnly: false,
                notifyPush: notifyPush,
                notifyEmail: notifyEmail,
                notifySms: notifySms,
                isRecurring: true,
                expiresAt: nil,
                dayBucket: dayBucket,
                arrivalHash: arrivalHash,
                departureHash: departureHash,
                enterTypeHash: enterHash,
                exitTypeHash: exitHash,
                encryptedSchedule: nil,
                encryptedCooldown: nil,
                timezone: Self.currentTimezoneIdentifier,
                clientRequestId: waiting?.requestId()
            )
            // POST answers with the bare new id ("data": "<uuid>"), not a row.
            alertId = try await api.createPlaceAlert(request: request)
        }

        let alert = PlaceAlert(
            id: alertId,
            placeId: placeId,
            userId: targetUserId ?? "all",
            alertType: alertType,
            isEnabled: preservedIsActive,
            targetUserId: targetUserId,
            activeDays: activeDays,
            activeStartTime: activeStartTime,
            activeEndTime: activeEndTime,
            notifyPush: notifyPush,
            notifyEmail: notifyEmail,
            notifySms: notifySms,
            isRecurring: preservedIsRecurring,
            expiresAt: preservedExpiresAt,
            circleId: circleId
        )
        var list = placeAlerts[placeId] ?? []
        if let idx = list.firstIndex(where: { $0.id == alertId }) {
            list[idx] = alert
        } else {
            list.append(alert)
        }
        placeAlerts[placeId] = list
        // Arm the geofence on THIS (creator) device immediately.
        // `isGeofenced` derives from the server-set `alertsEnabled`, which only
        // flips on the next pull — so without this the creator misses their OWN
        // first crossing after enabling an alert (e.g. "alert me when I leave
        // work", set and acted on at once). Flip alertsEnabled locally on the
        // place + its monitored-union copy, then reconcile the OS region set now
        // (syncMonitoredRegions still honors the nearest-N cap). monitoredPlaces
        // is a superset of `places`, so the union copy is what actually arms.
        if let idx = places.firstIndex(where: { $0.id == placeId }) {
            places[idx].alertsEnabled = true
        }
        if let mIdx = monitoredPlaces.firstIndex(where: { $0.id == placeId }) {
            monitoredPlaces[mIdx].alertsEnabled = true
        }
        syncMonitoredRegions()
        return alert
    }

    /// Reconcile the full set of alerts for a place from the bell editor.
    /// `targetUserIds` nil/empty → a single circle-wide alert (target
    /// nil); otherwise one alert per user id, matching android's advanced
    /// targeting. All saved alerts share the same trigger / schedule /
    /// notify config — only the target differs. Alerts for any other
    /// target (including a stale circle-wide one) are deleted.
    @discardableResult
    func savePlaceAlerts(
        placeId: String,
        targetUserIds: [String]?,
        alertType: PlaceAlert.AlertType,
        activeDays: [String]?,
        activeStartTime: String?,
        activeEndTime: String?,
        notifyPush: Bool,
        notifyEmail: Bool,
        notifySms: Bool
    ) async throws -> [PlaceAlert] {
        let existing = placeAlerts[placeId] ?? []
        var saved: [PlaceAlert] = []

        // A NEW alert on an older circle-owned place waits while this iPhone is
        // behind in its circle. Only a save that is that one new alert and
        // nothing else may wait; anything more (another alert, an update,
        // removing what it replaces) is refused WHOLE: kept in part, a save
        // would remove the live alerts while their replacement only waited.
        if let place = monitoredPlace(for: placeId), newAlertWouldWait(on: place),
           Self.refusedWholeWhileNewAlertsWait(existingTargets: existing.map(\.targetUserId),
                                               targets: targetUserIds) {
            throw CircleManager.CircleError.keyNotCurrent
        }

        if let targetUserIds, !targetUserIds.isEmpty {
            let desired = Set(targetUserIds)
            for uid in targetUserIds {
                let existingForUid = existing.first { $0.targetUserId == uid }
                let alert = try await savePlaceAlert(
                    placeId: placeId,
                    existingAlertId: existingForUid?.id,
                    targetUserId: uid,
                    alertType: alertType,
                    activeDays: activeDays,
                    activeStartTime: activeStartTime,
                    activeEndTime: activeEndTime,
                    notifyPush: notifyPush,
                    notifyEmail: notifyEmail,
                    notifySms: notifySms
                )
                if let alert { saved.append(alert) }
            }
            // Drop any alert whose target isn't in the desired set —
            // including the circle-wide alert (nil target). Row-only delete: the
            // alert(s) just saved above keep the place armed, so pruning must not
            // fire deleteAlert's authoritative places refresh per removed row.
            for alert in existing where !(alert.targetUserId.map { desired.contains($0) } ?? false) {
                try? await deleteAlertRow(alert)
            }
        } else {
            let existingEveryone = existing.first { $0.targetUserId == nil }
            let alert = try await savePlaceAlert(
                placeId: placeId,
                existingAlertId: existingEveryone?.id,
                targetUserId: nil,
                alertType: alertType,
                activeDays: activeDays,
                activeStartTime: activeStartTime,
                activeEndTime: activeEndTime,
                notifyPush: notifyPush,
                notifyEmail: notifyEmail,
                notifySms: notifySms
            )
            if let alert { saved.append(alert) }
            // Drop every other alert (specific-person + any duplicate). Row-only
            // delete — the "everyone" alert just saved keeps the place armed (see
            // the multi-target branch's note).
            for other in existing where other.id != alert?.id {
                try? await deleteAlertRow(other)
            }
        }
        return saved
    }

    /// Whether a NEW alert on `place` would wait instead of going out now: its
    /// target is sealed with the circle's key (an older circle-owned place)
    /// and this iPhone is behind in that circle, as `encryptAlertTarget` finds.
    private func newAlertWouldWait(on place: Place) -> Bool {
        placeKeyHex(for: place) == nil && holdsKeyInUse(place.circleId)
            && !CircleManager.shared.holdsCurrentKey(for: place.circleId)
    }

    /// A place-alert save while a new alert on its place would wait: refused
    /// whole unless it is exactly one new alert on a place with none. A save
    /// that makes no new alert has nothing that waits.
    nonisolated static func refusedWholeWhileNewAlertsWait(existingTargets: [String?], targets: [String]?) -> Bool {
        let wanted: [String?] = targets.flatMap { $0.isEmpty ? nil : $0.map { Optional($0) } } ?? [nil]
        guard wanted.contains(where: { !existingTargets.contains($0) }) else { return false }
        return !(existingTargets.isEmpty && wanted.count == 1)
    }

    // MARK: - Geofencing

    private func setupGeofences() {
        // Full rebuild: drop every currently-monitored region (including stale
        // ones persisted across a relaunch) and register the current selection.
        locationService.stopMonitoringAll()

        // Monitor the ALL-circles union, not just the active-circle `places`
        // list: a place shared to a non-active circle must still fire its
        // crossing so the fan-out routes to that circle's subscribers.
        // Only geofenced places (an alert subscription targets them — see
        // Place.isGeofenced) get a monitored region.
        //
        // Core Location HARD-caps an app at 20 simultaneously-monitored regions;
        // past 20, startMonitoring silently fails (see
        // LocationService.monitoringDidFailFor). A premium user can have more
        // than 20 alerted places across their circles, so register only the
        // nearest `maxMonitoredRegions` to the user — the ones most likely to be
        // crossed next — and re-prioritize as they move
        // (reprioritizeMonitoredRegionsOnMovement). The FULL union stays in
        // `monitoredPlaces` for region-event lookup, so a replayed/late crossing
        // on an un-registered place still resolves. Mirrors the Android app.
        let geofenced = monitoredPlaces.filter { $0.isGeofenced }
        for place in Self.nearestRegions(
            from: geofenced,
            to: locationService.currentLocation,
            limit: Self.maxMonitoredRegions
        ) {
            addGeofence(for: place)
        }
    }

    /// The ≤`limit` geofenced places nearest to `reference`, keeping the
    /// OS-registered region set under Core Location's 20-region cap. When the
    /// set already fits under the cap, EVERY place is returned
    /// (ordering irrelevant — all get monitored). With no `reference` fix yet
    /// (cold launch before the first GPS fix) a stable prefix is returned so we
    /// still monitor SOMETHING; the location subscription re-prioritizes with
    /// real distances the moment a fix lands. Pure + `nonisolated` so it's
    /// unit-testable off the Main actor.
    nonisolated static func nearestRegions(from places: [Place], to reference: CLLocation?, limit: Int) -> [Place] {
        guard places.count > limit else { return places }
        guard let reference else { return Array(places.prefix(limit)) }
        return places
            .map { place -> (Place, CLLocationDistance) in
                let placeLocation = CLLocation(latitude: place.latitude, longitude: place.longitude)
                return (place, reference.distance(from: placeLocation))
            }
            .sorted { $0.1 < $1.1 }
            .prefix(limit)
            .map { $0.0 }
    }

    /// Reconcile the OS's monitored-region set to the nearest-N geofenced
    /// places: add newly-nearest regions, remove ones that dropped out, and
    /// re-register any that stayed selected but whose geometry changed
    /// server-side (a peer/web edit moved or resized the place). A DIFFERENTIAL
    /// update (not stop-all/re-add) so a region that stays selected AND unchanged
    /// is never briefly torn down — which could miss a crossing during the gap —
    /// and identical re-registration is skipped entirely (no CoreLocation churn).
    /// Used after the union mutates (create/update/delete), as the user moves,
    /// and on every loadPlaces (foreground / Places-visit / circle-switch).
    /// A just-crossed region is inherently retained: the user is at/near it, so
    /// it ranks nearest and stays selected, and churn never leaves it
    /// unmonitored.
    private func syncMonitoredRegions() {
        let geofenced = monitoredPlaces.filter { $0.isGeofenced }
        let desired = Self.nearestRegions(
            from: geofenced,
            to: locationService.currentLocation,
            limit: Self.maxMonitoredRegions
        )
        let desiredById = Dictionary(desired.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let desiredIds = Set(desiredById.keys)
        // Index the LIVE OS regions WITH their geometry (not just ids) so an
        // already-monitored region can be told apart as IDENTICAL (skip — a true
        // CoreLocation no-op) vs geometry-CHANGED (a peer/web edit moved or
        // resized the place → re-register with the new center/radius). The
        // full-teardown `setupGeofences()` refreshes geometry for free by
        // re-adding everything; this differential path must do it explicitly or
        // a moved place keeps firing at its stale ring.
        let monitoredById = Dictionary(
            locationService.monitoredCircularRegions.map { ($0.identifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let monitoredIds = Set(monitoredById.keys)
        // Drop regions that fell out of the nearest-N selection.
        for staleId in monitoredIds.subtracting(desiredIds) {
            removeGeofence(for: staleId)
        }
        // Add newly-selected regions; re-register an already-monitored one only
        // when its geometry drifted. startMonitoring replaces a same-identifier
        // region atomically, so a changed region is refreshed without an
        // unmonitored gap, and an unchanged region is left entirely alone.
        for id in desiredIds {
            guard let place = desiredById[id] else { continue }
            if let existing = monitoredById[id], Self.regionMatches(existing, place) {
                continue
            }
            addGeofence(for: place)
        }
    }

    /// Whether a live monitored region already carries `place`'s geometry, within
    /// a 1-metre tolerance on both center and radius. Lets `syncMonitoredRegions`
    /// skip re-registering an unchanged region (a CoreLocation no-op) while still
    /// refreshing one a peer/web edit moved or resized. Geofence radii are ≥100 m
    /// and any real move shifts the center by many metres, so a 1 m epsilon can
    /// never mask a meaningful change yet absorbs any float noise from the OS
    /// round-trip.
    private static func regionMatches(_ region: CLCircularRegion, _ place: Place) -> Bool {
        guard abs(region.radius - place.radius) < 1.0 else { return false }
        let regionCenter = CLLocation(latitude: region.center.latitude, longitude: region.center.longitude)
        let placeCenter = CLLocation(latitude: place.latitude, longitude: place.longitude)
        return regionCenter.distance(from: placeCenter) < 1.0
    }

    /// Subscribe to the location stream so the nearest-N monitored set tracks
    /// the places the user is actually near as they move. Only
    /// meaningful when the union exceeds the cap; gated on a minimum movement so
    /// a stationary/jittering fix stream doesn't thrash region registration.
    private func observeLocationForRegionPriority() {
        locationService.locationUpdates
            .sink { [weak self] location in
                Task { @MainActor in
                    self?.reprioritizeMonitoredRegionsOnMovement(location)
                }
            }
            .store(in: &cancellables)
    }

    private func reprioritizeMonitoredRegionsOnMovement(_ location: CLLocation) {
        // Nothing to prioritize unless the union exceeds what we can monitor —
        // under the cap every geofenced place is already registered.
        let geofencedCount = monitoredPlaces.reduce(into: 0) { count, place in
            if place.isGeofenced { count += 1 }
        }
        guard geofencedCount > Self.maxMonitoredRegions else { return }
        // Damp churn: re-evaluate only after a meaningful move since the last one.
        if let last = lastRegionPriorityLocation,
           location.distance(from: last) < Self.regionReprioritizeDistanceMeters {
            return
        }
        lastRegionPriorityLocation = location
        syncMonitoredRegions()
    }

    /// Called once the initial monitored-set load (cold-launch hydrate or the
    /// first loadPlaces) finishes. Marks the set ready and REPLAYS any region
    /// crossings buffered because they arrived before `monitoredPlaces` was
    /// populated — the cold-launch race where the very crossing that relaunched
    /// the killed app would otherwise be dropped. After this, an
    /// unresolved region id is a genuinely-unknown (stale) region and is dropped,
    /// not buffered. `monitoredSetReady` is set BEFORE the replay awaits, so a
    /// crossing arriving mid-replay resolves directly instead of re-buffering.
    private func finishMonitoredLoad() async {
        monitoredSetReady = true
        let events = pendingRegionEvents
        pendingRegionEvents = []
        for event in events {
            if event.isEnter {
                await handleRegionEntry(event.region)
            } else {
                await handleRegionExit(event.region)
            }
        }
        // Now the durable queues, which is the point at which a crossing that
        // survived a suspension can finally be resolved to a place. Deliberately
        // AFTER the in-memory replay so a crossing held in both is handled by the
        // faster path first; the durable record is then a no-op, because
        // `PlaceAlertEventLedger` claims a crossing by its own identity.
        await drainDeferredCrossings()
    }

    /// Replay what the three silent-drop paths deferred: a region crossing that
    /// arrived before the place cache resolved, and a report that reached nobody
    /// because the POST failed or a circle's privacy posture could not be
    /// established.
    ///
    /// Safe to call repeatedly and from any of the wake paths — both stores
    /// take-and-clear, and the local surfacing half is idempotent through the event
    /// ledger.
    func drainDeferredCrossings() async {
        await PendingRegionEventStore.shared.loadIfNeeded()
        await PendingCrossingStore.shared.loadIfNeeded()

        // Unresolved region events first: they owe BOTH halves of the work (no
        // local notification has been shown for them), so they are the ones a user
        // would notice missing.
        for record in PendingRegionEventStore.shared.take() {
            guard let place = monitoredPlace(for: record.placeId) else {
                // Still unresolvable after a full load: the place is gone, or was
                // never ours. Dropping is right — there is nothing to alert about —
                // and it is not a silent drop, because the store logged the buffer.
                continue
            }
            await processOwnRegionCrossing(place: place, isEnter: record.isEnter, at: record.detectedAt)
        }

        // Then reports owed. These have already been surfaced locally; only the
        // server half is outstanding, so they go through `reportOwnCrossing` rather
        // than the full path — sending them through `processOwnRegionCrossing`
        // would re-run the local surfacing.
        for record in PendingCrossingStore.shared.take() {
            guard let place = monitoredPlace(for: record.placeId) else { continue }
            let before = PendingCrossingStore.shared.count
            await reportOwnCrossing(place: place, eventType: record.eventType, occurredAt: record.occurredAt)
            // `reportOwnCrossing` re-queues on its own when the replay also fails,
            // via the same gate the live path uses. Carry the attempt count across
            // so a wedged crossing is visible as a rising number rather than a
            // permanently fresh one.
            if PendingCrossingStore.shared.count > before {
                PendingCrossingStore.shared.requeue(record)
            }
        }
    }

    /// Resolve a region id to a monitored place, preferring the geofencing
    /// union and falling back to the active-circle `places` list.
    func monitoredPlace(for identifier: String) -> Place? {
        monitoredPlaces.first(where: { $0.id == identifier })
            ?? places.first(where: { $0.id == identifier })
    }

    private func addGeofence(for place: Place) {
        let region = CLCircularRegion(
            center: place.coordinate,
            radius: place.radius,
            identifier: place.id
        )
        locationService.startMonitoring(region: region)
    }

    private func removeGeofence(for placeId: String) {
        let region = CLCircularRegion(
            center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            radius: 100,
            identifier: placeId
        )
        locationService.stopMonitoring(region: region)
    }

    private func setupGeofenceNotifications() {
        NotificationCenter.default.publisher(for: .didEnterRegion)
            .compactMap { $0.userInfo?["region"] as? CLRegion }
            .sink { [weak self] region in
                Task { @MainActor in
                    await self?.handleRegionEntry(region)
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .didExitRegion)
            .compactMap { $0.userInfo?["region"] as? CLRegion }
            .sink { [weak self] region in
                Task { @MainActor in
                    await self?.handleRegionExit(region)
                }
            }
            .store(in: &cancellables)
    }

    /// Buffer a region crossing that can't yet resolve to a place because the
    /// async cold-launch hydrate hasn't populated `monitoredPlaces` — but ONLY
    /// while that first load is still in flight (`monitoredSetReady == false`).
    /// Replayed by `finishMonitoredLoad`. Once the set is ready an unresolved id
    /// is a stale region (e.g. one registered by an earlier version of the app)
    /// and is dropped, since there's nothing to resolve it against.
    private func bufferPendingRegionEvent(_ region: CLRegion, isEnter: Bool) {
        guard !monitoredSetReady else { return }
        pendingRegionEvents.append((region: region, isEnter: isEnter))
        // AND durably. The in-memory array is the fast path — it is replayed by
        // `finishMonitoredLoad` moments later in the healthy case — but the hydrate
        // it waits on is `unwrapPlaceKey` plus up to 4x `decryptWithPlaceKeyV2` per
        // place, and a premium account has unlimited places. If suspension wins
        // that race the array goes with the process, and the crossing that
        // relaunched the app is gone with no trace. Persisting the identifier is
        // enough: it IS the place id (see `addGeofence`), which is the only field
        // the handler reads from the region.
        PendingRegionEventStore.shared.enqueue(
            placeId: region.identifier,
            isEnter: isEnter,
            detectedAt: Date()
        )
    }

    private func handleRegionEntry(_ region: CLRegion) async {
        guard let place = monitoredPlace(for: region.identifier) else {
            bufferPendingRegionEvent(region, isEnter: true)
            return
        }
        await processOwnRegionCrossing(place: place, isEnter: true, at: Date())
    }

    /// The two halves of an own-region crossing, in one place so a REPLAYED event
    /// gets both. The durable buffer stores a place id rather than a `CLRegion`, so
    /// the replay needs an entry point that takes a resolved place and the ORIGINAL
    /// detection time.
    private func processOwnRegionCrossing(place: Place, isEnter: Bool, at when: Date) async {
        // Report the crossing regardless of local alert config — whether anyone
        // cares is decided server-side by boundary subscriptions. This exists for
        // OTHER people: it is how a remote subscriber watching a SHARED place
        // learns we moved. It no-ops for an unshared personal place, which has no
        // real circle to report under.
        await reportOwnCrossing(place: place, eventType: isEnter ? "enter" : "exit", occurredAt: when)

        // ...and this is how WE learn, with no server involved at all. The OS
        // evaluated the geofence on-device, so nothing about this crossing reaches
        // the blind server or APNs. This must NOT be deferred to the server
        // pipeline: for a personal place that path never fires unless the place is
        // shared.
        //
        // `when` rather than Date(): a REPLAYED event must carry the time it was
        // detected, or a crossing surfaced after a relaunch is stamped with the
        // relaunch.
        await PlaceAlertEvaluator.shared.surfaceOwnRegionCrossing(
            place: place,
            isEnter: isEnter,
            at: when
        )
    }

    private func handleRegionExit(_ region: CLRegion) async {
        guard let place = monitoredPlace(for: region.identifier) else {
            bufferPendingRegionEvent(region, isEnter: false)
            return
        }
        await processOwnRegionCrossing(place: place, isEnter: false, at: Date())
    }

    /// Report an own-location boundary crossing so the server can notify
    /// any circle members whose subscriptions match. E2EE: the event type
    /// and device id ride as circle-key ciphertexts; routing uses the
    /// BLAKE3 event-type hash, so the server never learns whether this
    /// was an enter or an exit. Mirrors the Android app's
    /// `checkOwnLocationAgainstBoundaries` → `reportCrossingFromMonitor` —
    /// iOS detection rides Core Location region monitoring instead of
    /// per-fix ring checks, so transitions arrive pre-deduplicated.
    private func reportOwnCrossing(place: Place, eventType: String, occurredAt: Date = Date()) async {
        // Stale regions registered by an earlier version of the app may
        // still fire before loadPlaces re-registers the filtered set.
        guard place.isGeofenced else { return }
        guard let userId = AuthManager.shared.userId else { return }

        // Resolve the circle(s) to hash + encrypt this crossing under.
        //
        // A CIRCLE-owned place reports under its own circle. A PERSONAL place has
        // circleId == the self-tracking pseudo-circle (SelfKeyManager.selfCircleUuid)
        // — the device-local, per-user self key that no OTHER member can reproduce.
        // A crossing hashed under self can therefore NEVER equal an alert's stored
        // hash (an alert is always keyed to a REAL circle — the bell dialog has no
        // "self" option), so reporting a personal crossing under self alone makes
        // every personal-place alert silently fail to fire. Instead, mirroring
        // the Android app's BoundaryRepository fan-out, route the crossing to the
        // UNION of every real circle this place touches —
        //   • the place's own circle (when it's a real circle, not self),
        //   • every circle a personal place is SHARED to (`sharedCircles`),
        //   • the via-circle it was RECEIVED through (`wrapTargetId`).
        // This makes both an OWNED-and-shared place AND a RECEIVED share fan out
        // to every sharing circle we hold a key for, so a watcher in a DIFFERENT
        // sharing circle also gets alerted; narrowing a recipient to
        // `[place.circleId]` alone misses them. The self sentinel is dropped, and
        // circles we can't encrypt for (no key held — e.g. a circle the mover
        // isn't a member of) are skipped so we don't spam un-encryptable reports.
        var candidates: [String] = []
        if place.circleId != SelfKeyManager.selfCircleUuid {
            candidates.append(place.circleId)
        }
        candidates.append(contentsOf: place.sharedCircles ?? [])
        if let wrapVia = place.wrapTargetId {
            candidates.append(wrapVia)
        }
        var seen = Set<String>()
        let targetCircles: [String] = candidates.compactMap { raw -> String? in
            let c = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !c.isEmpty,
                  c != SelfKeyManager.selfCircleUuid,
                  cryptoManager.hasCircleKey(circleId: c),
                  seen.insert(c).inserted else { return nil }
            return c
        }

        guard !targetCircles.isEmpty else {
            // A personal place shared to no circle we hold a key for has no
            // subscriber we can route to.
            return
        }

        let deviceId = KeychainService.shared.getString(for: .deviceId) ?? "unknown"
        // Stamp the crossing ONCE, here, before any per-circle encryption or
        // network work. Everything below happens after the crossing, and the
        // server can only ever see when the report landed, so a late-reported
        // crossing would announce itself as if it had just happened.
        // One value for every circle, so the same crossing reads identically to
        // every subscriber.
        let detectedAt = occurredAt
        // Whether anything actually reached the server, and whether any circle's
        // posture could not be ESTABLISHED. The two together decide whether this
        // crossing is queued: see the `if` after the loop.
        var anySent = false
        var postureUnknown = false
        var sawReportFailure = false
        var awaitingRead = false
        // A crossing replayed later is judged at its OWN time: the server can
        // only judge it by NOW(). One that happened while this account was not
        // sharing with a circle never goes there, even when it shares again by
        // the time it is sent; one that waited goes only once a row read since
        // it happened says whether it was sharing then (a pause set and ended
        // on another device while this phone was offline is in the server's
        // spans alone).
        let late = Date().timeIntervalSince(detectedAt) > CirclePauseRecord.skewMargin
        for circleId in targetCircles {
            let waiting = late
                && CirclePauseRecord.shared.awaitsRead(circleId: circleId, capturedAt: detectedAt, owner: userId)
            if CirclePauseRecord.shared.withholds(circleId: circleId, capturedAt: detectedAt, owner: userId,
                                                  waiting: waiting) {
                continue
            }
            if waiting {
                awaitingRead = true
                continue
            }
            // Privacy posture (per circle): don't self-report a boundary crossing
            // while that circle is paused or realtime-off (posture-unknown fails
            // closed). A crossing carries no coordinates, but it discloses presence
            // + timing at a member-known place during the exact window the user
            // chose to hide. The self pseudo-circle is never a target here (filtered
            // out above), so each iteration gates a real circle. Prime-on-miss so a
            // cold-wake crossing before this circle's privacy GET landed isn't
            // fail-closed and lost.
            switch await CircleManager.shared.presencePosture(for: circleId) {
            case .denied:
                // The user's decision. Never send, and never retry — queueing this
                // would resend the crossing the moment they unpaused, disclosing
                // presence from the window they chose to hide.
                continue
            case .unknown:
                // A failed privacy GET, not an opt-out. Suppress the send (being
                // unsure is not a licence) but remember that this was a FAILURE, so
                // the crossing can be retried instead of silently lost.
                postureUnknown = true
                continue
            case .allowed:
                if await reportCrossing(
                    place: place,
                    circleId: circleId,
                    userId: userId,
                    deviceId: deviceId,
                    eventType: eventType,
                    occurredAt: detectedAt
                ) {
                    anySent = true
                } else {
                    sawReportFailure = true
                }
            }
        }

        // Queue only when the crossing reached NOBODY, mirroring the Android app's
        // `!anySucceeded` gate: re-sending to circles that already have it would
        // duplicate their notifications. That leaves a partial failure still losing
        // the failed circle's report — accepted, because a per-circle queue has two
        // replay modes, which is more likely to be wrong than this case is to
        // happen. Most personal places are shared to one circle or none.
        if !anySent && (postureUnknown || sawReportFailure || awaitingRead) {
            PendingCrossingStore.shared.enqueue(
                placeId: place.id,
                userId: userId,
                deviceId: deviceId,
                eventType: eventType,
                occurredAt: detectedAt,
                reason: postureUnknown ? "privacy posture unknown"
                    : awaitingRead ? "waiting for a privacy read since it happened" : "report failed"
            )
        }
    }

    /// Encrypt + hash a single boundary crossing under `circleId` and POST it.
    /// Split out from `reportOwnCrossing` so a personal place can fan the same
    /// crossing out over every circle it is shared to, each under that circle's
    /// key. Mirrors the Android app's `BoundaryRepository.reportCrossing`.
    /// Returns whether the report reached the server, so the caller can queue a
    /// crossing that reached nobody: a failed report must never look like a
    /// successful one.
    @discardableResult
    private func reportCrossing(
        place: Place,
        circleId: String,
        userId: String,
        deviceId: String,
        eventType: String,
        /// When the crossing was DETECTED, captured by the caller before any of
        /// the encryption or network work below. The server can only observe when
        /// the report arrived, which is why this has to travel with it.
        occurredAt: Date
    ) async -> Bool {
        // Hold a background-task assertion across the encryption + POST. The app's
        // only other one is `TokenRefreshAssertion`, whose doc names the same
        // hazard: iOS may suspend the app mid-request. This request arrives on a
        // region wake, which is precisely when the app has no other reason to be
        // running, so without the assertion a crossing could be cut off in flight
        // with nothing recording that it had been.
        let assertion = CrossingReportAssertion.begin()
        defer { CrossingReportAssertion.end(assertion) }

        // A crossing is not sealed under a key the circle has moved past.
        // Reported as not delivered, so the caller queues it and it goes out
        // once the circle's new key has reached this device. Primed: a region
        // wake can arrive before this process has listed the circles.
        guard await CircleManager.shared.holdsCurrentKeyPrimed(for: circleId) else {
            Self.crossingLog.error(
                "crossing report held: circle \(circleId, privacy: .public) has a newer key this device has not received"
            )
            return false
        }

        do {
            let encEventType = try cryptoManager.encryptDataV2(
                circleId: circleId,
                plaintext: eventType,
                fieldTag: "event_type"
            )
            let encDeviceId = try cryptoManager.encryptDataV2(
                circleId: circleId,
                plaintext: deviceId,
                fieldTag: "device_id"
            )
            let eventTypeHash = try cryptoManager.computeEventTypeHash(
                circleId: circleId,
                eventType: eventType
            )
            let request = BoundaryCrossingRequest(
                placeId: place.id,
                crossingUserId: userId,
                encryptedEventType: EncryptedBlobRequest(
                    nonce: encEventType.nonce,
                    ciphertext: encEventType.ciphertext
                ),
                encryptedDeviceId: EncryptedBlobRequest(
                    nonce: encDeviceId.nonce,
                    ciphertext: encDeviceId.ciphertext
                ),
                eventTypeHash: eventTypeHash,
                encryptedLocation: nil,
                // Sealed as a decimal string of epoch millis, matching what the
                // Android reporter sends and what the recipients parse.
                encryptedOccurredAt: (try? cryptoManager.encryptDataV2(
                    circleId: circleId,
                    plaintext: String(Int64(occurredAt.timeIntervalSince1970 * 1000)),
                    fieldTag: "occurred_at"
                )).map { EncryptedBlobRequest(nonce: $0.nonce, ciphertext: $0.ciphertext) }
            )
            _ = try await api.reportBoundaryCrossing(request: request)
            return true
        } catch {
            // `Logger`, not `print`: this has to be diagnosable from a shipped
            // build, and it never surfaces a banner — a background geofence event
            // must not put UI on screen. The caller queues the crossing.
            Self.crossingLog.error(
                "boundary crossing report failed: place=\(place.id, privacy: .public) circle=\(circleId, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    private static let crossingLog = Logger(subsystem: "com.pingolin.track", category: "PlaceAlerts")

    /// Keeps the app alive across a crossing report. Mirrors
    /// `TokenRefreshAssertion`; separate type for the same reason, so the call site
    /// reaches it in one hop.
    @MainActor
    private enum CrossingReportAssertion {
        static func begin() -> UIBackgroundTaskIdentifier {
            UIApplication.shared.beginBackgroundTask(withName: "crossing-report")
        }
        static func end(_ id: UIBackgroundTaskIdentifier) {
            guard id != .invalid else { return }
            UIApplication.shared.endBackgroundTask(id)
        }
    }

    // MARK: - Location Helpers

    func nearbyPlaces(to coordinate: CLLocationCoordinate2D, radius: Double = 1000) -> [Place] {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)

        return places.filter { place in
            let placeLocation = CLLocation(latitude: place.latitude, longitude: place.longitude)
            return location.distance(from: placeLocation) <= radius
        }
    }

    func place(at coordinate: CLLocationCoordinate2D) -> Place? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)

        return places.first { place in
            let placeLocation = CLLocation(latitude: place.latitude, longitude: place.longitude)
            return location.distance(from: placeLocation) <= place.radius
        }
    }

    /// The place a check-in in `circleId` may name: one at `coordinate` that is
    /// shared into that circle, and none other. Its id goes in clear beside the
    /// check-in, so a personal place, or another circle's, would tie this
    /// circle's check-in to a place it was never shown. Everything a check-in
    /// carries comes from the circle it opened for.
    func checkInPlace(at coordinate: CLLocationCoordinate2D, in circleId: String) -> Place? {
        Self.checkInPlace(at: coordinate, in: circleId, among: places, selfCircleUuid: SelfKeyManager.selfCircleUuid)
    }

    /// Pure, for tests: `checkInPlace(at:in:)` against `places`.
    nonisolated static func checkInPlace(at coordinate: CLLocationCoordinate2D, in circleId: String,
                                         among places: [Place], selfCircleUuid: String) -> Place? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return places.first { place in
            isShared(place, into: circleId, selfCircleUuid: selfCircleUuid)
                && location.distance(from: CLLocation(latitude: place.latitude, longitude: place.longitude))
                    <= place.radius
        }
    }

    /// Whether `place` is shared into `circleId`: one of this account's own
    /// (filed under the personal slot) shared to it, or one filed under that
    /// circle (the circle's own, or a share received through it).
    nonisolated static func isShared(_ place: Place, into circleId: String, selfCircleUuid: String) -> Bool {
        if CanonicalId.sameKey(place.circleId, selfCircleUuid) {
            return place.sharedCircles?.contains { CanonicalId.sameKey($0, circleId) } ?? false
        }
        return CanonicalId.sameKey(place.circleId, circleId)
    }

    func distanceToPlace(_ place: Place, from location: CLLocation) -> Double {
        let placeLocation = CLLocation(latitude: place.latitude, longitude: place.longitude)
        return location.distance(from: placeLocation)
    }
}
