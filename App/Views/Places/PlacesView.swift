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
import MapKit
import CoreLocation
import struct PingolinTrackSDK.GeocodingResult

struct PlacesView: View {
    @StateObject private var placeManager = PlaceManager.shared
    @StateObject private var circleManager = CircleManager.shared
    @State private var showingAddPlace = false
    @State private var editingPlace: Place?
    @State private var sharingPlace: Place?
    @State private var pendingDelete: Place?
    @State private var alertEditorPlace: Place?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if placeManager.places.isEmpty {
                    Spacer()
                    EmptyPlacesView(onAddPlace: { showingAddPlace = true })
                    Spacer()
                } else {
                    List {
                        ForEach(placeManager.places) { place in
                            PlaceRow(
                                place: place,
                                onEdit: { editingPlace = place },
                                onShare: { sharingPlace = place },
                                onDelete: { pendingDelete = place },
                                onTapRow: {
                                    // Cross-tab handoff: stash the
                                    // target place, then switch to
                                    // the Map tab (index 0). MapView
                                    // .onChange watches mapTapState
                                    // for pendingFocusPlace.
                                    MapTapState.shared.pendingFocusPlace = place
                                    TabSelectionState.shared.selected = 0
                                },
                                onBell: { alertEditorPlace = place }
                            )
                            // On the place: a share, an edit or
                            // an alert that waits for this
                            // iPhone to catch up.
                            PendingChangesInPlace(kinds: [.sharePlace, .editPlace, .memberPlaceAlert]) { change in
                                switch change.inputs {
                                case .sharePlace(let placeId): return placeId == place.id
                                case .editPlace(let placeId, _): return placeId == place.id
                                case .memberPlaceAlert(let inputs): return inputs.placeId == place.id
                                default: return false
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Places")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: { showingAddPlace = true }) {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAddPlace) {
                AddPlaceSheet()
            }
            .sheet(item: $editingPlace) { place in
                EditPlaceSheet(place: place)
            }
            .sheet(item: $sharingPlace) { place in
                SharePlaceSheet(place: place)
            }
            .sheet(item: $alertEditorPlace) { place in
                PlaceAlertEditorSheet(place: place)
            }
            .alert(
                "Delete \(pendingDelete?.name ?? "Place")?",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
            ) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    if let target = pendingDelete {
                        Task { try? await placeManager.deletePlace(target) }
                    }
                    pendingDelete = nil
                }
            } message: {
                Text("This permanently removes the place. Shared circles will lose access.")
            }
            .refreshable {
                let id = circleManager.activeCircle?.id ?? SelfKeyManager.selfCircleUuid
                try? await placeManager.loadPlaces(for: id)
            }
            .task {
                // Re-read places FIRST so `alertsEnabled` is re-installed from the
                // authoritative, place-scoped server flag (alerts_enabled = ANY
                // member's active subscription): this disarms a geofence a peer
                // deleted/paused/expired and RE-arms one they added, in BOTH
                // directions — which the subscriber-scoped alert list alone cannot
                // do. Runs every visit (not only when empty) because that flag is
                // the sole disarm authority: the alert-list reconcile is
                // arm-only. Then refreshAllAlerts hydrates the per-place bell map
                // (badges + editor pre-fill, android's refreshPlaceAlertsMap
                // parity) and arms (only) any place with an own live alert on top.
                // Cost is one getAllPlaces per visit — the same work the
                // pull-to-refresh above already does; loadPlaces skips its own alert
                // refresh once the list is loaded, so this isn't a double fetch.
                let id = circleManager.activeCircle?.id ?? SelfKeyManager.selfCircleUuid
                try? await placeManager.loadPlaces(for: id)
                try? await placeManager.refreshAllAlerts()
            }
        }
    }

}

struct EmptyPlacesView: View {
    let onAddPlace: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "mappin.circle.fill")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                Text("No Places Yet")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Add places like Home, Work, or School to get arrival and departure notifications")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }

            Button(action: onAddPlace) {
                Label("Add a Place", systemImage: "plus.circle.fill")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}

struct PlaceRow: View {
    let place: Place
    let onEdit: () -> Void
    let onShare: () -> Void
    let onDelete: () -> Void
    let onTapRow: () -> Void
    let onBell: () -> Void

    @StateObject private var circleManager = CircleManager.shared
    @StateObject private var placeManager = PlaceManager.shared

    private var bellHasAlert: Bool {
        !(placeManager.placeAlerts[place.id]?.isEmpty ?? true)
    }
    /// Every alert on this place is DORMANT because the person it watches has
    /// switched off `allow_alerts_on_me` in the alert's consent circle.
    ///
    /// Distinct from "no alerts": the alerts exist and are configured, they
    /// simply cannot fire. Saying so is the point — an alert that silently stops
    /// working is indistinguishable from a broken feature.
    private var bellSuppressed: Bool {
        guard let alerts = placeManager.placeAlerts[place.id], !alerts.isEmpty else { return false }
        return alerts.allSatisfy(\.suppressedByTarget)
    }
    /// Lazy reverse-geocoded fallback. Populated in .task when
    /// `place.address` is nil so existing rows saved without an
    /// address still show a human-readable line
    /// instead of a blank space. Later loadPlaces calls won't
    /// overwrite this — it stays local to the row.
    @State private var resolvedAddress: String?

    private var addressForDisplay: String? {
        if let stored = place.address, !stored.isEmpty { return stored }
        return resolvedAddress
    }

    /// `wrapTargetId` is the self-circle for owned places; for shares
    /// received from another circle it's that circle's id.
    private var isReceivedShare: Bool {
        guard let target = place.wrapTargetId else { return false }
        return target != SelfKeyManager.selfCircleUuid
    }

    private var fillColor: Color {
        if place.color.hasPrefix("#") { return Color(hex: place.color) }
        return Color(place.color)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                SwiftUI.Circle()
                    .fill(fillColor)
                    .frame(width: 44, height: 44)
                Image(systemName: place.icon.systemImage)
                    .font(.title3)
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(place.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    // BOUNDARY badge intentionally absent: the Android
                    // app gates it on `placeType == "boundary"`,
                    // a distinct row type, not on whether a boundary
                    // radius is set. iOS doesn't surface "boundary
                    // places" as a separate creation path, so the
                    // badge would mean nothing concrete. SHARED stays
                    // because it reflects a real wire distinction
                    // (this row arrived via wrap_via_circle from
                    // another circle).
                    if isReceivedShare {
                        Text("SHARED")
                            .font(.caption2.bold())
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.orange.opacity(0.15), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                }
                // Address: persisted on the row when stored on the
                // server, otherwise we lazy-reverse-geocode in .task
                // below so older rows still show a real line.
                if let address = addressForDisplay {
                    Text(address)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 0)

            // Alert bell — opens the unified place-alert editor. Shown on
            // own places AND received shares: the per-place key lets a
            // recipient set alerts too. A filled badge means an alert
            // already exists.
            Button(action: onBell) {
                // THREE states, not two. A suppressed place keeps the filled bell
                // (the alerts exist and are still editable) but takes the muted
                // tint, because rendering it as "alerts on" would promise
                // notifications that will never arrive. The slash is the
                // accessible signal: colour alone is not one.
                Image(systemName: bellSuppressed
                      ? "bell.slash.fill"
                      : (bellHasAlert ? "bell.badge.fill" : "bell"))
                    .foregroundStyle(bellHasAlert && !bellSuppressed ? .blue : .secondary)
                    .accessibilityLabel(bellSuppressed
                        ? "Alert paused: this person has turned off alerts about themselves in this circle"
                        : (bellHasAlert ? "Edit alert" : "Create alert"))
            }
            .buttonStyle(.plain)

            // Edit + Share + Delete icon buttons. Hidden for received
            // shares — owner-only operations on the underlying row.
            // Matches Android's right-aligned button
            // stack (btnEdit + btnShare + btnDelete).
            if !isReceivedShare {
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                Button(action: onShare) {
                    Image(systemName: "square.and.arrow.up")
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        // Tapping anywhere except the action icons jumps to the Map
        // tab and focuses on this place's marker — same affordance
        // as the Android app's onPlaceClick on the row body.
        .onTapGesture { onTapRow() }
        .task(id: place.id) {
            // Lazy reverse-geocode for older rows whose
            // encryptedAddress wasn't populated on create. Cheap
            // single fetch; GeocodingService caches across calls.
            guard place.address?.isEmpty ?? true, resolvedAddress == nil else { return }
            let result = await GeocodingService.shared.reverse(
                latitude: place.latitude,
                longitude: place.longitude
            )
            resolvedAddress = result?.text
        }
    }
}

/// Multi-circle share picker. Lets the owner toggle their place's
/// visibility to each circle they're a member of. Mirrors
/// the Android app's chip-group share flow but with
/// a checked-row layout. Calls into PlaceManager.sharePlaceWithCircle /
/// unsharePlaceFromCircle, which (via the SDK) wraps the per-place
/// key for the target circle's symmetric key — server-blind end-to-end.
struct SharePlaceSheet: View {
    let place: Place
    @Environment(\.dismiss) private var dismiss
    @StateObject private var circleManager = CircleManager.shared
    @StateObject private var placeManager = PlaceManager.shared
    @State private var pendingChanges: Set<String> = []
    @State private var error: String?
    /// Shares waiting for this iPhone to catch up.
    @ObservedObject private var waiting = PendingChangeStore.shared

    var body: some View {
        NavigationStack {
            Form {
                // In the place's circle list: a share that waits, with Cancel.
                if waiting.changes.contains(where: { isWaitingShare($0) }) {
                    Section(PendingChangeCopy.tag) {
                        PendingChangesInPlace(kinds: [.sharePlace]) { isWaitingShare($0) }
                    }
                }
                if circleManager.circles.isEmpty {
                    Section {
                        Text("Join or create a circle first — places are shared with a circle.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        ForEach(circleManager.circles, id: \.id) { circle in
                            ShareCircleRow(
                                circle: circle,
                                isShared: Self.isShared(current, with: circle.id),
                                isOwnCircle: Self.belongs(current, to: circle.id),
                                isPending: pendingChanges.contains(circle.id),
                                isWaiting: Self.shareWaits(waiting.changes, place: place.id, circle: circle.id)
                            ) { newValue in
                                Task { await toggle(circleId: circle.id, share: newValue) }
                            }
                        }
                    } footer: {
                        Text("Members of each selected circle will see this place on their map.")
                    }
                }
                if let error = error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Share Place")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    /// The place as this phone holds it now: its shares as the server listed
    /// them, with each share or unshare taken since (`PlaceManager.recordShare`).
    private var current: Place { placeManager.monitoredPlace(for: place.id) ?? place }

    /// Whether the circle can see the place, which its switch shows. A
    /// circle it is shared with (`sharedCircles`; the server omits an empty
    /// list), or the circle a place made in a circle belongs to. Ids compare
    /// in their one form; `sameKey`, because a share shown off that is on is
    /// the harmful mistake here.
    static func isShared(_ place: Place, with circleId: String) -> Bool {
        belongs(place, to: circleId) || (place.sharedCircles ?? []).contains { CanonicalId.sameKey($0, circleId) }
    }

    /// A place made in a circle, not a personal one, is that circle's: its
    /// members see it with no share to stop, so its switch is on and locked.
    static func belongs(_ place: Place, to circleId: String) -> Bool {
        place.circleId != SelfKeyManager.selfCircleUuid && CanonicalId.sameKey(place.circleId, circleId)
    }

    /// Whether a share of the place with the circle waits for this iPhone to
    /// catch up: neither on nor off yet, so its row says so.
    static func shareWaits(_ changes: [PendingChange], place placeId: String, circle circleId: String) -> Bool {
        changes.contains { change in
            guard change.isPending, case .sharePlace(let id) = change.inputs else { return false }
            return id == placeId && CanonicalId.sameKey(change.circleId, circleId)
        }
    }

    private func isWaitingShare(_ change: PendingChange) -> Bool {
        guard change.isPending, case .sharePlace(let placeId) = change.inputs else { return false }
        return placeId == place.id
    }

    @MainActor
    private func toggle(circleId: String, share: Bool) async {
        error = nil
        pendingChanges.insert(circleId)
        defer { pendingChanges.remove(circleId) }
        do {
            if share {
                try await placeManager.sharePlaceWithCircle(placeId: place.id, circleId: circleId)
            } else {
                try await placeManager.unsharePlaceFromCircle(placeId: place.id, circleId: circleId)
            }
        } catch {
            self.error = error.plainText
        }
    }
}

/// One circle's switch in Share Place. It shows whether the circle can see the
/// place (`SharePlaceSheet.isShared`), never a tap the server hasn't taken: a
/// tap asks, the row waits, and the switch then shows what was taken. A share
/// kept waiting shows as waiting, neither on nor off (it is listed above, with
/// Cancel). Named with the circle, so VoiceOver says which circle it is for.
struct ShareCircleRow: View {
    let circle: Circle
    let isShared: Bool
    let isOwnCircle: Bool
    let isPending: Bool
    var isWaiting = false
    let onToggle: (Bool) -> Void

    var body: some View {
        if isPending {
            HStack {
                Text(circle.name)
                Spacer()
                ProgressView().controlSize(.small)
            }
        } else if isWaiting {
            HStack {
                Text(circle.name)
                Spacer()
                Label(PendingChangeCopy.tag, systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        } else {
            Toggle(circle.name, isOn: Binding(get: { isShared }, set: onToggle))
                .disabled(isOwnCircle)
        }
    }
}

private extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { self = .gray; return }
        let r = Double((v & 0xFF0000) >> 16) / 255
        let g = Double((v & 0x00FF00) >> 8) / 255
        let b = Double(v & 0x0000FF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

/// Unified place-alert editor opened from a place row's bell — the
/// single create/edit alert UI. Arrives/
/// Leaves triggers, Everyone vs a specific person, an optional schedule,
/// notification channels, and Remove. Pre-fills from the place's existing
/// alert when one is present.
struct PlaceAlertEditorSheet: View {
    let place: Place
    @Environment(\.dismiss) private var dismiss
    @StateObject private var placeManager = PlaceManager.shared
    @StateObject private var circleManager = CircleManager.shared

    @State private var alertOnArrival = true
    @State private var alertOnDeparture = false
    @State private var targetEveryone = true
    @State private var selectedUserIds: Set<String> = []
    @State private var limitDays = false
    @State private var selectedDays: Set<String> = []
    @State private var limitTime = false
    @State private var startTime = Date()
    @State private var endTime = Date()
    @State private var notifyPush = true
    @State private var notifyEmail = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    /// A free-tier place-alert limit (402) is an offer, not a failure. Same
    /// state the place-create path in this file already carries.
    @State private var premiumPrompt: PremiumPrompt?
    @State private var didPrefill = false

    private let weekdays = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]

    private var existingAlerts: [PlaceAlert] { placeManager.placeAlerts[place.id] ?? [] }
    /// Config is shared across a place's alerts (only the target differs),
    /// so trigger/schedule/notify pre-fill from the first one.
    private var configAlert: PlaceAlert? { existingAlerts.first }

    /// Members of the circle this place lives in (else the active
    /// circle's). Empty when this device holds no roster to target from —
    /// which is about CIRCLE MEMBERSHIP, never about whether the place is
    /// shared. A personal place is targetable without being shared;
    /// subscriber-side evaluation runs the alert on this device against
    /// members' locations it already receives.
    private var members: [CircleMember] {
        if let m = circleManager.members[place.circleId], !m.isEmpty { return m }
        if let active = circleManager.activeCircle?.id { return circleManager.members[active] ?? [] }
        return []
    }

    private var canSave: Bool {
        (alertOnArrival || alertOnDeparture)
            && (targetEveryone || !selectedUserIds.isEmpty)
            && !isSaving
    }

    /// A place alert exists to tell a CIRCLE that one of its members arrived or
    /// left. With no circle there is nobody to watch and nobody to tell, so the
    /// editor has nothing to offer. Gated HERE rather than at the bell: this sheet
    /// has two entry points (the Places row and the map's place sheet) and gating
    /// each one separately is how the two drift apart. Matches the Android app's
    /// gate in PlaceAlertEditor.
    private var hasAnyCircle: Bool { !circleManager.circles.isEmpty }

    var body: some View {
        NavigationStack {
            if !hasAnyCircle {
                ContentUnavailableView(
                    "Place alerts need a circle",
                    systemImage: "person.2.slash",
                    description: Text("Place alerts tell a circle when one of its members arrives at or leaves a place. Join or create a circle to set one.")
                )
                .navigationTitle(place.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                }
            } else {
            Form {
                Section("Notify me when someone") {
                    Toggle("Arrives", isOn: $alertOnArrival)
                    Toggle("Leaves", isOn: $alertOnDeparture)
                }

                Section {
                    Picker("Target", selection: $targetEveryone) {
                        Text("Everyone").tag(true)
                        Text("Specific people").tag(false)
                    }
                    .pickerStyle(.segmented)
                    if !targetEveryone {
                        if members.isEmpty {
                            // NOT "share this place first".
                            // Targeting a person needs a
                            // circle you share with THEM —
                            // that is where their locations
                            // come from at all — but not
                            // this PLACE shared: with
                            // subscriber-side evaluation it
                            // needs no share of any kind.
                            // Telling users to share would
                            // send them to expose a private
                            // place's coordinates to solve
                            // a roster problem.
                            Text("Join a circle with other members to alert about specific people.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            // Advanced per-member targeting:
                            // one alert is saved per selected member.
                            ForEach(members, id: \.userId) { member in
                                Toggle(member.displayName, isOn: Binding(
                                    get: { selectedUserIds.contains(member.userId) },
                                    set: { on in
                                        if on { selectedUserIds.insert(member.userId) }
                                        else { selectedUserIds.remove(member.userId) }
                                    }
                                ))
                            }
                        }
                    }
                } header: {
                    Text("Who")
                } footer: {
                    if !targetEveryone && !members.isEmpty {
                        Text("Each selected person gets their own alert with these settings.")
                    }
                }

                Section("Schedule") {
                    Toggle("Only on certain days", isOn: $limitDays)
                    if limitDays {
                        ForEach(weekdays, id: \.self) { day in
                            Toggle(day.capitalized, isOn: Binding(
                                get: { selectedDays.contains(day) },
                                set: { on in
                                    if on { selectedDays.insert(day) } else { selectedDays.remove(day) }
                                }
                            ))
                        }
                    }
                    Toggle("Only during a time window", isOn: $limitTime)
                    if limitTime {
                        DatePicker("From", selection: $startTime, displayedComponents: .hourAndMinute)
                        DatePicker("To", selection: $endTime, displayedComponents: .hourAndMinute)
                    }
                }

                // No SMS toggle: there is no SMS provider, so it would do
                // nothing. On save we PRESERVE the existing alert's notifySms
                // rather than force-false it; a fresh create still defaults
                // to false.
                Section("Notify via") {
                    Toggle("Push", isOn: $notifyPush)
                    Toggle("Email", isOn: $notifyEmail)
                }

                if !existingAlerts.isEmpty {
                    Section {
                        Button(role: .destructive) {
                            Task { await remove() }
                        } label: {
                            Label(existingAlerts.count > 1 ? "Remove all alerts" : "Remove alert", systemImage: "trash")
                        }
                    }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(place.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") { Task { await save() } }
                        .disabled(!canSave)
                }
            }
            .onAppear(perform: prefill)
            // Free place-alert limit 402 -> upgrade explainer; other failures
            // stay in the inline error Section above. Mirrors AddPlaceSheet.
            .sheet(item: $premiumPrompt) { PremiumPromptSheet(prompt: $0) }
            }
        }
    }

    private func prefill() {
        guard !didPrefill else { return }
        didPrefill = true
        guard let alert = configAlert else { return }
        alertOnArrival = alert.alertType == .arrival || alert.alertType == .both
        alertOnDeparture = alert.alertType == .departure || alert.alertType == .both
        // Specific-people mode when any existing alert names a target;
        // pre-select all of them. Otherwise everyone.
        let targets = existingAlerts.compactMap { $0.targetUserId }.filter { !$0.isEmpty }
        if targets.isEmpty {
            targetEveryone = true
        } else {
            targetEveryone = false
            selectedUserIds = Set(targets)
        }
        if let days = alert.activeDays, !days.isEmpty {
            limitDays = true
            selectedDays = Set(days)
        }
        if let start = alert.activeStartTime, let end = alert.activeEndTime,
           let s = Self.parseHHmm(start), let e = Self.parseHHmm(end) {
            limitTime = true
            startTime = s
            endTime = e
        }
        notifyPush = alert.notifyPush
        notifyEmail = alert.notifyEmail
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let type: PlaceAlert.AlertType = (alertOnArrival && alertOnDeparture)
            ? .both : (alertOnDeparture ? .departure : .arrival)
        let days: [String]? = (limitDays && !selectedDays.isEmpty)
            ? weekdays.filter { selectedDays.contains($0) } : nil
        do {
            _ = try await placeManager.savePlaceAlerts(
                placeId: place.id,
                targetUserIds: targetEveryone ? nil : Array(selectedUserIds),
                alertType: type,
                activeDays: days,
                activeStartTime: limitTime ? Self.hhmm(startTime) : nil,
                activeEndTime: limitTime ? Self.hhmm(endTime) : nil,
                notifyPush: notifyPush,
                notifyEmail: notifyEmail,
                // The editor exposes no SMS toggle, so preserve whatever the
                // existing alert had (possibly set true on web/Android) rather
                // than clobbering it to false on every iOS edit.
                // A fresh create (no existing alert) still defaults to false.
                notifySms: configAlert?.notifySms ?? false
            )
            dismiss()
        } catch let apiError as APIError {
            switch Self.outcome(for: apiError) {
            case .upgrade(let prompt): premiumPrompt = prompt
            case .message(let text): errorMessage = text
            }
        } catch {
            errorMessage = error.plainText
        }
    }

    /// Where a failed alert save goes: the upgrade sheet, or the inline red row.
    ///
    /// Not Equatable on purpose — `PremiumPrompt` carries a fresh `UUID` id
    /// (it is Identifiable so `.sheet(item:)` can drive it), so a synthesized
    /// `==` would compare those and report two identical prompts unequal.
    /// Tests pattern-match instead.
    enum SaveOutcome {
        case upgrade(PremiumPrompt)
        case message(String)
    }

    /// Route a failed save.
    ///
    /// A 402 opens the upgrade sheet (`PremiumPrompt.forGate`, as
    /// `AddPlaceSheet.create()` does): a free user hitting the place-alert
    /// limit must not get the raw server sentence in the red inline row, as
    /// if a quota were a fault rather than an offer.
    ///
    /// Order matters. ALERT_RECIPIENT_OPTED_OUT is checked first because it is
    /// a 403 about somebody else's privacy choice and no subscription changes
    /// it; presenting an upgrade sheet for it would be selling a fix that does
    /// not exist. It cannot collide with a gate (a 403 carries no quota), but
    /// the precedence is the part worth being explicit about.
    ///
    /// Pure + non-private so the routing is testable without driving the sheet.
    static func outcome(for error: APIError) -> SaveOutcome {
        // The target opted out of being alerted on in this circle (per-circle
        // "Allow alerts on me") — say why, rather than echoing the server code.
        if error.code == "ALERT_RECIPIENT_OPTED_OUT" {
            return .message(
                "That person turned off \u{201C}Allow alerts on me\u{201D} for this circle, "
                + "so you can't set an alert targeting them."
            )
        }
        if let prompt = PremiumPrompt.forGate(error) {
            return .upgrade(prompt)
        }
        return .message(error.plainLine)
    }

    private func remove() async {
        isSaving = true
        defer { isSaving = false }
        do {
            for alert in existingAlerts {
                try await placeManager.deleteAlert(alert)
            }
            dismiss()
        } catch {
            errorMessage = error.plainText
        }
    }

    private static func hhmm(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
    private static func parseHHmm(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f.date(from: s)
    }
}

struct AddPlaceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var placeManager = PlaceManager.shared
    @StateObject private var circleManager = CircleManager.shared
    @StateObject private var locationService = LocationService.shared

    @State private var name = ""
    /// The name came from an address pick, not from the person. A later pick
    /// may replace it; a keystroke makes it theirs.
    @State private var nameFromPick = false
    @State private var selectedIcon: Place.PlaceIcon = .custom
    @State private var selectedColor = "#2196F3"
    // 150 m default alert area, as in the Android app.
    @State private var radius: Double = PlaceRadius.defaultMeters
    @State private var coordinate: CLLocationCoordinate2D?
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var premiumPrompt: PremiumPrompt?
    /// The address field over the map, and the map's own search behind it: the
    /// same pause, the same once-per-query spend, the same whole-city step.
    @State private var addressQuery = ""
    @StateObject private var search = PlaceSearchModel()

    let colors = PlaceColorPalette.swatches

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // Keystrokes come through this binding and a pick does not, so
                    // typing is what makes the name the person's own.
                    TextField("Place Name", text: Binding(
                        get: { name },
                        set: { typed in
                            if typed != name {
                                name = typed
                                nameFromPick = false
                            }
                        }
                    ))
                }

                Section("Icon") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 12) {
                        ForEach(Place.PlaceIcon.allCases, id: \.self) { icon in
                            Button(action: { selectedIcon = icon }) {
                                Image(systemName: icon.systemImage)
                                    .font(.title2)
                                    .foregroundStyle(selectedIcon == icon ? .white : .primary)
                                    .frame(width: 44, height: 44)
                                    .background(selectedIcon == icon ? Color(placeColor: selectedColor) : Color(.systemGray5))
                                    .clipShape(SwiftUI.Circle())
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }

                Section("Color") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                        ForEach(colors, id: \.self) { color in
                            Button(action: { selectedColor = color }) {
                                SwiftUI.Circle()
                                    .fill(Color(placeColor: color))
                                    .frame(width: 36, height: 36)
                                    .overlay {
                                        if PlaceColorPalette.canonical(selectedColor) == color {
                                            Image(systemName: "checkmark")
                                                .foregroundStyle(.white)
                                        }
                                    }
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }

                Section("Alert area") {
                    VStack {
                        Text(PlaceRadius.formatted(radius))
                            .font(.headline)
                        Slider(value: $radius, in: PlaceRadius.range, step: PlaceRadius.step)
                    }
                }

                Section("Location") {
                    // A place is mostly somewhere the user knows
                    // the address of. Without this, Add Place
                    // would mean dragging a 250-point map across
                    // town, and the only way to a typed address
                    // would be the Map tab's search and its pin
                    // card.
                    TextField("Address, place or city", text: $addressQuery)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .accessibilityIdentifier("add-place-address-field")
                    if SearchSchedule.isSearchable(addressQuery) {
                        addressAnswers
                    }

                    Map(position: $cameraPosition, interactionModes: .all) {
                        if let coord = coordinate {
                            Annotation("", coordinate: coord) {
                                Image(systemName: selectedIcon.systemImage)
                                    .foregroundStyle(.white)
                                    .frame(width: 36, height: 36)
                                    .background(Color(selectedColor))
                                    .clipShape(SwiftUI.Circle())
                            }

                            MapCircle(center: coord, radius: radius)
                                .foregroundStyle(Color(selectedColor).opacity(0.2))
                                .stroke(Color(selectedColor), lineWidth: 2)
                        }
                    }
                    .frame(height: 250)
                    .listRowInsets(EdgeInsets())
                    .onMapCameraChange { context in
                        coordinate = context.camera.centerCoordinate
                        // Searched around what the map shows, as the Map tab's search is.
                        search.focus = (context.camera.centerCoordinate.latitude,
                                        context.camera.centerCoordinate.longitude)
                    }

                    Button("Use Current Location") {
                        if let location = locationService.currentLocation {
                            coordinate = location.coordinate
                            cameraPosition = .camera(MapCamera(
                                centerCoordinate: location.coordinate,
                                distance: 1000
                            ))
                        }
                    }
                }
            }
            .onChange(of: addressQuery) { _, query in
                search.queryChanged(query)
            }
            .onAppear { search.watchNetwork() }
            .onDisappear { search.stopWatchingNetwork() }
            .navigationTitle("Add Place")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        savePlace()
                    }
                    // Same decision `savePlace` acts on, so an
                    // enabled Save always does something. See
                    // `plan`: a second, disagreeing predicate
                    // here would leave Save enabled but doing
                    // nothing.
                    .disabled(savePlan == nil)
                }
            }
            .onAppear {
                if let location = locationService.currentLocation {
                    coordinate = location.coordinate
                    cameraPosition = .camera(MapCamera(
                        centerCoordinate: location.coordinate,
                        distance: 1000
                    ))
                }
            }
            // A quota/premium 402 opens the upgrade explainer; anything else
            // shows a plain error. This failure must surface somewhere: merely
            // print()ing it makes a hit place limit look like a silently broken
            // Save button.
            .sheet(item: $premiumPrompt) { PremiumPromptSheet(prompt: $0) }
            .alert("Couldn't add place", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    /// What the address field found: up to five rows, then the map search's own
    /// progress line, empty-list sentence and metered row. A city row is left
    /// out: a place at a city's centroid is nobody's place.
    @ViewBuilder private var addressAnswers: some View {
        ForEach(Array(search.places.prefix(5).enumerated()), id: \.offset) { _, result in
            Button {
                let (pin, camera) = Self.mapAt(result)
                coordinate = pin
                cameraPosition = camera
                (name, nameFromPick) = Self.nameAfterPick(current: name, fromPick: nameFromPick, picked: result)
                addressQuery = ""
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    let primary = result.name ?? result.text
                    Text(primary)
                        .foregroundStyle(.primary)
                    let secondary = AddressFormat.secondaryLine(result, primary: primary)
                    if !secondary.isEmpty {
                        Text(secondary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        if search.isSearching {
            HStack(spacing: 8) {
                ProgressView()
                Text(AddressSearchView.progressText(for: search.loadingPhase, cityWide: search.widening))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } else if search.places.isEmpty {
            Text(AddressSearchView.emptyText(timedOut: search.timedOut, scopedTo: search.scopedTo,
                                             moreToDownload: search.moreToDownload))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        if AddressSearchView.offersMoreData(moreToDownload: search.moreToDownload,
                                            isSearching: search.isSearching, query: addressQuery) {
            Button("Search beyond the map view (uses more data) →") {
                search.searchMore(addressQuery)
            }
            .font(.footnote)
        }
    }

    /// The Place Name after an address pick: the pick's own name, as its row
    /// shows it, when the field is empty or still holds an earlier pick's;
    /// whatever the person typed, untouched. They can edit it.
    static func nameAfterPick(
        current: String, fromPick: Bool, picked: GeocodingResult
    ) -> (name: String, fromPick: Bool) {
        guard fromPick || current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (current, false)
        }
        return (picked.name ?? picked.text, true)
    }

    /// Where a picked address puts the place, and the map over it: the address
    /// itself, at the same 1 km camera "Use Current Location" uses.
    static func mapAt(_ result: GeocodingResult) -> (CLLocationCoordinate2D, MapCameraPosition) {
        let pin = CLLocationCoordinate2D(latitude: result.lat, longitude: result.lng)
        return (pin, .camera(MapCamera(centerCoordinate: pin, distance: 1000)))
    }

    /// What tapping Save does, given the state of the form.
    ///
    /// ONE DECISION FOR THE BUTTON AND THE ACTION
    ///   `.disabled` and `savePlace` consume the SAME decision, so they cannot
    ///   disagree about when a save is possible: `nil` means "Save does
    ///   nothing", and that is precisely when the button is greyed out. Two
    ///   predicates that disagree leave Save enabled and hittable while
    ///   tapping it does nothing — no request, no error, no spinner, no
    ///   dismissal — discarding the user's name, icon, colour and radius.
    ///
    ///   No circle is needed to create a place. `createPlace` posts
    ///   `CreatePlaceRequest(circleId: nil, ...)` for every caller — places are
    ///   personal and owned by the user — and the server accepts a place with
    ///   no circle, checking membership only when one is given. An active
    ///   circle is a *visibility* grant layered on afterwards by
    ///   `sharePlaceWithCircle`, so having none is an ordinary state and not a
    ///   failure. Refusing is what this codebase does where a circle genuinely
    ///   is required — see `ShareDestinationSheet`, where a destination is a
    ///   broadcast to members and solo users get a clear error.
    ///
    ///   Pure + non-private so the outcome is testable without driving the
    ///   sheet, matching `PlaceAlertEditorSheet.outcome(for:)` above.
    enum SavePlan: Equatable {
        /// Create the personal place and stop. Either there is no circle, or
        /// the "active circle" IS the self-circle, which `sharePlaceWithCircle`
        /// would reject as a share target anyway.
        case createPersonal
        /// Create the personal place, then wrap its key for `circleId` too so
        /// that circle's members can see it.
        case createAndShare(circleId: String)
    }

    /// The Map twin — `CreatePlaceFromMapSheet.create()` — has no
    /// `activeCircle` guard at all: its visibility picker defaults to
    /// `SelfKeyManager.selfCircleUuid` ("Just me") and it shares only when the
    /// user picked a real circle. This resolves to the same two outcomes, so
    /// both entry points agree about what a solo user gets.
    ///
    /// `name` is checked with `isEmpty`, not trimmed, matching what the
    /// button does; the pairing is the claim here, not a rule about
    /// whitespace.
    static func plan(
        name: String,
        hasCoordinate: Bool,
        isLoading: Bool,
        activeCircleId: String?
    ) -> SavePlan? {
        guard !name.isEmpty, hasCoordinate, !isLoading else { return nil }
        guard let circleId = activeCircleId,
              circleId != SelfKeyManager.selfCircleUuid else { return .createPersonal }
        return .createAndShare(circleId: circleId)
    }

    /// The live plan for the form as it stands. Drives both the button's
    /// enabled state and what the tap does.
    private var savePlan: SavePlan? {
        Self.plan(
            name: name,
            hasCoordinate: coordinate != nil,
            isLoading: isLoading,
            activeCircleId: circleManager.activeCircle?.id
        )
    }

    private func savePlace() {
        // Unreachable: the button is disabled in exactly the states where
        // `savePlan` is nil. It is a `guard` rather than a `!` so a future
        // caller cannot crash the app, and it is the ONLY silent return.
        guard let plan = savePlan, let coord = coordinate else { return }

        isLoading = true
        Task {
            do {
                let place = try await placeManager.createPlace(
                    name: name,
                    coordinate: coord,
                    radius: radius,
                    icon: selectedIcon,
                    color: selectedColor
                )
                // Places are personal by default. An active circle is
                // an extra visibility grant on top, so post-create wrap the
                // place key for it too.
                if case .createAndShare(let circleId) = plan {
                    try? await placeManager.sharePlaceWithCircle(placeId: place.id, circleId: circleId)
                }
                dismiss()
            } catch {
                if let apiError = error as? APIError, let prompt = PremiumPrompt.forGate(apiError) {
                    premiumPrompt = prompt
                } else {
                    errorMessage = error.plainText
                }
            }
            isLoading = false
        }
    }
}

struct EditPlaceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var placeManager = PlaceManager.shared
    @State var place: Place
    @State private var isLoading = false
    @State private var errorMessage: String?
    /// Seeded ONCE from the radius as loaded, in `.onAppear`. Recomputing it
    /// from the live `place.radius` on every body pass would make the range
    /// follow the value: dragging a 6 km place downwards would shrink the
    /// ceiling with it and pin the thumb to the right edge.
    @State private var radiusRange: ClosedRange<Double> = PlaceRadius.range

    let colors = PlaceColorPalette.swatches

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Place Name", text: $place.name)
                }

                Section("Icon") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 12) {
                        ForEach(Place.PlaceIcon.allCases, id: \.self) { icon in
                            Button(action: { place.icon = icon }) {
                                Image(systemName: icon.systemImage)
                                    .font(.title2)
                                    .foregroundStyle(place.icon == icon ? .white : .primary)
                                    .frame(width: 44, height: 44)
                                    .background(place.icon == icon ? Color(placeColor: place.color) : Color(.systemGray5))
                                    .clipShape(SwiftUI.Circle())
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }

                Section("Color") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                        ForEach(colors, id: \.self) { color in
                            Button(action: { place.color = color }) {
                                SwiftUI.Circle()
                                    .fill(Color(placeColor: color))
                                    .frame(width: 36, height: 36)
                                    .overlay {
                                        if PlaceColorPalette.canonical(place.color) == color {
                                            Image(systemName: "checkmark")
                                                .foregroundStyle(.white)
                                        }
                                    }
                            }
                            // Borderless so each swatch fires on its own — in a
                            // Form cell, default-styled buttons ALL fire on any
                            // tap, so tapping one color would apply the last one
                            // (pink).
                            .buttonStyle(.borderless)
                        }
                    }
                }

                Section("Alert area") {
                    VStack {
                        Text(PlaceRadius.formatted(place.radius))
                            .font(.headline)
                        // radiusRange, not PlaceRadius.range: this binds the
                        // LIVE place.radius, and a Slider clamps a bound value
                        // that falls outside its bounds. A place set outside
                        // the range on web or Android would be rewritten just
                        // by opening this sheet, and saveChanges() would
                        // persist it and re-register the geofence — with
                        // nobody having touched the slider.
                        Slider(value: $place.radius, in: radiusRange, step: PlaceRadius.step)
                    }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Edit Place")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveChanges()
                    }
                    .disabled(place.name.isEmpty || isLoading)
                }
            }
            .onAppear { radiusRange = PlaceRadius.editableRange(for: place.radius) }
        }
    }

    private func saveChanges() {
        isLoading = true
        errorMessage = nil
        Task {
            defer { isLoading = false }
            do {
                // Not `try?`: updatePlace also re-registers the geofence for
                // the edited geometry. Swallowing a failure here would dismiss
                // the sheet over an edit that never reached the server, while
                // the OS keeps watching the old ring — the user sees their new
                // radius in a list that is only local, and crossings keep
                // firing on the old one. Keep the sheet open so Save can be
                // retried.
                try await placeManager.updatePlace(place)
                dismiss()
            } catch let apiError as APIError {
                errorMessage = apiError.plainLine
            } catch {
                errorMessage = error.plainText
            }
        }
    }
}

#Preview {
    PlacesView()
}

/// Place colors are stored as HEX ("#3B82F6") — the form the map renders via
/// `UIColor(hex:)`. The picker swatches + selection check must therefore be hex
/// too: a named list ("blue"…) would render clear (there are no "blue"/"red"
/// color *assets*, so `Color("blue")` is invisible) and never match a place's
/// hex color. `canonical` also maps the few legacy named rows to hex so their
/// swatch still highlights.
enum PlaceColorPalette {
    /// The Android app's exact place palette (Material Design):
    /// red, pink, purple, blue, teal, green, orange. Place colors come from
    /// android/web as Material hex (e.g. #4CAF50/#9C27B0), so the swatches
    /// must be the same values for one to highlight.
    static let swatches = ["#F44336", "#E91E63", "#9C27B0", "#2196F3", "#009688", "#4CAF50", "#FF9800"]

    static func canonical(_ s: String) -> String {
        if s.hasPrefix("#") { return s.uppercased() }
        switch s.lowercased() {
        case "blue": return "#2196F3"
        case "red": return "#F44336"
        case "green": return "#4CAF50"
        case "orange": return "#FF9800"
        case "purple": return "#9C27B0"
        case "pink": return "#E91E63"
        case "teal": return "#009688"
        default: return s.uppercased()
        }
    }
}

extension Color {
    /// Resolve a stored place color (hex, or a legacy named value) to a Color.
    /// `UIColor(hex:)` is the same resolver the map markers use, so the picker
    /// and the map agree.
    init(placeColor s: String) {
        self = Color(UIColor(hex: PlaceColorPalette.canonical(s)) ?? .systemBlue)
    }
}
