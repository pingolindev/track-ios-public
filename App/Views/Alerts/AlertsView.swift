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

/// Unified Alerts screen — low-battery rules + inactivity alerts in one
/// list, with a Battery/Inactivity chooser on create and tap-to-edit.
/// Mirrors the Android app's merged AlertsFragment +
/// UnifiedAlertAdapter. History stays separate (the inactivity "Recent
/// Triggers" section here is the iOS analog of the events inbox).
struct AlertsView: View {
    @StateObject private var ruleManager = AlertRulesManager.shared
    @StateObject private var inactivityManager = InactivityAlertsManager.shared
    @StateObject private var circleManager = CircleManager.shared
    @StateObject private var localStore = LocalInactivityStore.shared
    @StateObject private var localBatteryStore = LocalBatteryStore.shared
    /// Alerts and alert changes waiting for this iPhone to catch up.
    @ObservedObject private var pendingChanges = PendingChangeStore.shared
    private static let waitingKinds: Set<PendingChange.Kind> = [.batteryAlert, .alertChange, .inactivityAlert]
    private var anyWaiting: Bool {
        pendingChanges.changes.contains { $0.isPending && Self.waitingKinds.contains($0.kind) }
    }

    @State private var showingChooser = false
    @State private var editorMode: AlertEditorMode?

    /// One row model over both alert kinds so they sort/render together.
    private enum Row: Identifiable {
        case battery(AlertRuleResponse)
        case inactivity(InactivityAlertResponse)
        var id: String {
            switch self {
            case .battery(let r): return "b-\(r.id)"
            case .inactivity(let a): return "i-\(a.id)"
            }
        }
    }

    private var rows: [Row] {
        ruleManager.batteryRules.map(Row.battery)
            + inactivityManager.alerts.map(Row.inactivity)
    }

    private var isEmpty: Bool {
        rows.isEmpty && localStore.events.isEmpty && localBatteryStore.events.isEmpty
    }

    var body: some View {
        Group {
            if isEmpty && !anyWaiting && !ruleManager.isRefreshing && !inactivityManager.isRefreshing {
                emptyState
            } else {
                list
            }
        }
        .navigationTitle("Alerts")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingChooser = true } label: { Image(systemName: "plus.circle") }
                    .disabled(circleManager.activeCircle == nil)
            }
        }
        .task { await refreshAll() }
        .refreshable { await refreshAll() }
        .confirmationDialog("Create an alert", isPresented: $showingChooser, titleVisibility: .visible) {
            Button("Low battery") { editorMode = .createBattery }
            Button("Inactivity") { editorMode = .createInactivity }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Alert your circle when a member's battery is low, or when they stop sending locations.")
        }
        .sheet(item: $editorMode) { mode in
            NavigationStack { AlertEditorView(mode: mode) }
        }
    }

    private func refreshAll() async {
        await localStore.loadIfNeeded()
        await localBatteryStore.loadIfNeeded()
        await ruleManager.refresh()
        await inactivityManager.refresh()
    }

    private var list: some View {
        List {
            if !localStore.events.isEmpty || !localBatteryStore.events.isEmpty {
                Section("Recent Triggers") {
                    // Device-local firings, with their exact
                    // local time. There is no server-sourced
                    // list to merge in: the server serves no
                    // inactivity events, and battery firings
                    // are local by construction — the level
                    // is sealed in the payload, so the server
                    // has no row to serve.
                    ForEach(localStore.events) { event in
                        localEventRow(event)
                    }
                    ForEach(localBatteryStore.events) { event in
                        localBatteryRow(event)
                    }
                }
            }
            if anyWaiting {
                Section(PendingChangeCopy.tag) {
                    PendingChangesInPlace(kinds: Self.waitingKinds)
                }
            }
            if !rows.isEmpty {
                Section("Configured Alerts") {
                    ForEach(rows) { row in
                        switch row {
                        case .battery(let rule): batteryRow(rule)
                        case .inactivity(let alert): inactivityRow(alert)
                        }
                    }
                }
            }
        }
    }

    private func circleName(_ circleId: String?) -> String? {
        guard let circleId else { return nil }
        return circleManager.circles.first(where: { $0.id == circleId })?.name
    }

    @ViewBuilder
    private func batteryRow(_ rule: AlertRuleResponse) -> some View {
        alertRowShell(
            icon: "battery.25",
            tint: .orange,
            active: rule.isActive,
            title: "Low battery",
            circle: circleName(rule.circleId),
            // No cooldown fragment: a battery rule's cooldown_minutes is stored
            // and read by nothing, so printing it would describe behaviour that
            // does not exist.
            subtitle: subtitle(
                detail: "below \(ruleManager.threshold(for: rule))%",
                cooldown: nil
            ),
            disabled: !rule.isActive
        )
        .contentShape(Rectangle())
        .onTapGesture { editorMode = .editBattery(rule) }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                Task { try? await ruleManager.deleteRule(rule) }
            } label: { Label("Delete", systemImage: "trash") }
        }
    }

    @ViewBuilder
    private func inactivityRow(_ alert: InactivityAlertResponse) -> some View {
        alertRowShell(
            icon: alert.isSelfAlert ? "person.crop.circle.badge.exclamationmark" : "eye",
            tint: .blue,
            active: alert.isActive,
            title: inactivityTitle(alert),
            circle: circleName(alert.circleId),
            subtitle: subtitle(
                detail: "\(alert.timeoutHours)h timeout",
                cooldown: alert.cooldownMinutes
            ),
            disabled: !alert.isActive
        )
        .contentShape(Rectangle())
        .onTapGesture { editorMode = .editInactivity(alert) }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                Task { try? await inactivityManager.deleteAlert(alert) }
            } label: { Label("Delete", systemImage: "trash") }
        }
    }

    private func inactivityTitle(_ alert: InactivityAlertResponse) -> String {
        if alert.isSelfAlert { return "If I'm inactive" }
        // Client-only watch rule: encrypted_conditions holds the set.
        if alert.encryptedConditions != nil {
            guard let spec = inactivityManager.watchSpec(for: alert) else { return "Watch members" }
            if spec == "all" || spec.isEmpty { return "Watch everyone" }
            let count = spec.split(separator: ",").count
            return count == 1 ? "Watch 1 member" : "Watch \(count) members"
        }
        return "Watch member"
    }

    private func subtitle(detail: String, cooldown: Int?) -> String {
        var parts = [detail]
        if let cooldown { parts.append("\(cooldown)m cooldown") }
        return parts.joined(separator: " • ")
    }

    @ViewBuilder
    private func alertRowShell(icon: String, tint: Color, active: Bool, title: String, circle: String?, subtitle: String, disabled: Bool) -> some View {
        HStack(spacing: 12) {
            ZStack {
                SwiftUI.Circle()
                    .fill((active ? tint : .gray).opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: icon).foregroundStyle(active ? tint : .gray)
            }
            VStack(alignment: .leading, spacing: 2) {
                // Circle name is the primary disambiguator across same-type
                // rules, so it rides the title line as a de-emphasized suffix,
                // not buried in the description.
                (
                    Text(title).font(.subheadline).fontWeight(.medium)
                    + Text(circle.map { "  ·  \($0)" } ?? "")
                        .font(.caption).foregroundColor(.secondary)
                )
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
                if disabled {
                    Text("Disabled").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }

    // Device-local client-only firing — carries the exact trigger time
    // (unlike the day-bucket-only server rows), so show "Today · 2:14 PM".
    @ViewBuilder
    private func localEventRow(_ event: LocalInactivityEvent) -> some View {
        let resolved = event.isResolved
        HStack(spacing: 12) {
            ZStack {
                SwiftUI.Circle()
                    .fill((resolved ? Color.green : Color.orange).opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: resolved ? "checkmark" : "exclamationmark.triangle")
                    .foregroundStyle(resolved ? .green : .orange)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("\(event.memberName) \(resolved ? "active again" : "inactive")")
                    .font(.subheadline).fontWeight(.medium)
                Text(localTriggerLabel(event.triggeredAt))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                localStore.delete(id: event.id)
            } label: { Label("Delete", systemImage: "trash") }
        }
    }

    /// A device-local low-battery firing. Resolved means they charged back
    /// above the threshold, which is the battery equivalent of "active again".
    @ViewBuilder
    private func localBatteryRow(_ event: LocalBatteryEvent) -> some View {
        let resolved = event.isResolved
        HStack(spacing: 12) {
            ZStack {
                SwiftUI.Circle()
                    .fill((resolved ? Color.green : Color.orange).opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: resolved ? "battery.100.bolt" : "battery.25")
                    .foregroundStyle(resolved ? .green : .orange)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(resolved
                     ? "\(event.memberName) charged up"
                     : "\(event.memberName) at \(event.batteryLevel)%")
                    .font(.subheadline).fontWeight(.medium)
                Text(localTriggerLabel(event.triggeredAt))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                localBatteryStore.delete(id: event.id)
            } label: { Label("Delete", systemImage: "trash") }
        }
    }

    /// "Today · 2:14 PM" / "Yesterday · 9:03 AM" / "Jun 21 · 2:14 PM" — exact
    /// local time, day relative to today. Matches android.
    private func localTriggerLabel(_ date: Date) -> String {
        let cal = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if cal.isDateInToday(date) { return "Today · \(time)" }
        if cal.isDateInYesterday(date) { return "Yesterday · \(time)" }
        return "\(date.formatted(date: .abbreviated, time: .omitted)) · \(time)"
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bell.badge")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No alerts yet")
                .font(.headline)
            Text("Get notified when a circle member's battery runs low or they stop sending locations.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }
}

/// Create or edit, for either alert kind. On edit the circle + target are
/// immutable (changing them re-targets a different member and needs
/// re-encryption — Android requires delete-and-recreate), so only the
/// threshold/timeout, notify prefs, cooldown, and active state are editable.
enum AlertEditorMode: Identifiable {
    case createBattery
    case createInactivity
    case editBattery(AlertRuleResponse)
    case editInactivity(InactivityAlertResponse)

    var id: String {
        switch self {
        case .createBattery: return "create-battery"
        case .createInactivity: return "create-inactivity"
        case .editBattery(let r): return "edit-battery-\(r.id)"
        case .editInactivity(let a): return "edit-inactivity-\(a.id)"
        }
    }

    var isBattery: Bool {
        switch self {
        case .createBattery, .editBattery: return true
        case .createInactivity, .editInactivity: return false
        }
    }

    var isEditing: Bool {
        switch self {
        case .editBattery, .editInactivity: return true
        case .createBattery, .createInactivity: return false
        }
    }
}

struct AlertEditorView: View {
    /// An inactivity rule about others says what keeps it quiet: nothing
    /// goes off about someone who paused, or turned real-time sharing off,
    /// in the circle.
    static let notWhileNotSharing = "Doesn't go off while they've paused or turned off location sharing in this circle."

    let mode: AlertEditorMode
    @Environment(\.dismiss) private var dismiss
    @StateObject private var circleManager = CircleManager.shared
    @StateObject private var ruleManager = AlertRulesManager.shared
    @StateObject private var inactivityManager = InactivityAlertsManager.shared

    // Target (create only)
    @State private var watchSelf = false
    @State private var selectedMemberId: String?        // battery (single)
    @State private var selectedMemberIds: Set<String> = []  // inactivity (multi)
    // Battery
    @State private var threshold: Double = Double(AlertRulesManager.defaultThreshold)
    // Inactivity
    @State private var timeoutHours: Double = 6
    // Common
    @State private var cooldownMinutes: Double = 60
    @State private var notifyPush = true
    @State private var notifyOnReturn = false
    @State private var isActive = true
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var didPrefill = false

    /// An inactivity rule about other members: one being made with "Alert
    /// about me" off, or one already made about others.
    private var watchesOthers: Bool {
        if case .editInactivity(let rule) = mode { return !rule.isSelfAlert }
        return !watchSelf
    }

    var body: some View {
        Form {
            if mode.isEditing {
                Section {
                    Toggle("Active", isOn: $isActive)
                }
            } else if !mode.isBattery {
                Section {
                    Toggle("Alert about me", isOn: $watchSelf)
                } footer: {
                    Text("When on, fires if your own device stops sending locations. Otherwise choose who to watch below.")
                }
            }

            // Target picker — create mode only (immutable after creation).
            if !mode.isEditing {
                if mode.isBattery {
                    Section("Watch") { memberPickerSingle }
                } else if !watchSelf {
                    Section {
                        memberPickerMulti
                    } header: {
                        Text("Watch")
                    } footer: {
                        Text("Select members to watch, or leave all unchecked to watch everyone. Watched-member inactivity is evaluated on this device, so it fires while the app is running.")
                    }
                }
            }

            if mode.isBattery {
                Section {
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Battery threshold")
                            Spacer()
                            Text("\(Int(threshold))%").foregroundStyle(.secondary)
                        }
                        Slider(value: $threshold, in: 5...50, step: 5)
                    }
                } footer: {
                    Text("Fires when the watched member's battery drops to this level.")
                }
            } else {
                Section {
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Timeout")
                            Spacer()
                            Text("\(Int(timeoutHours)) hours").foregroundStyle(.secondary)
                        }
                        Slider(value: $timeoutHours, in: 1...24, step: 1)
                    }
                } footer: {
                    if watchesOthers {
                        Text(Self.notWhileNotSharing)
                    }
                }
            }

            // Inactivity-only, because it is inactivity-only in fact: the worker
            // reads the inactivity rule's cooldown_minutes to space its
            // wake-ups, whereas nothing reads the battery rule's copy — both
            // evaluators fire once per drain against a persisted marker. Shown
            // for a battery rule it would be a dial whose value is stored and
            // never consulted.
            if !mode.isBattery {
                Section {
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Cooldown")
                            Spacer()
                            Text("\(Int(cooldownMinutes)) min").foregroundStyle(.secondary)
                        }
                        Slider(value: $cooldownMinutes, in: 15...1440, step: 15)
                    }
                } footer: {
                    Text("How long to wait before telling you again about the same member.")
                }
            }

            // No "Email": these rules are judged on this phone, so the
            // server never learns who watches whom and could not send one.
            Section("Notifications") {
                Toggle("Push", isOn: $notifyPush)
                // Inactivity-only: also announce when the member resumes sharing.
                if !mode.isBattery {
                    Toggle("Notify when back online", isOn: $notifyOnReturn)
                }
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(navTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await submit() }
                } label: {
                    if isSubmitting { ProgressView() } else { Text(mode.isEditing ? "Save" : "Create") }
                }
                .disabled(!canSubmit)
            }
        }
        .onAppear(perform: prefill)
    }

    private var otherMembers: [CircleMember] {
        guard let circle = circleManager.activeCircle,
              let members = circleManager.members[circle.id] else { return [] }
        let me = AuthManager.shared.userId
        return members.filter { $0.userId != me }
    }

    @ViewBuilder
    private var memberPickerSingle: some View {
        if let circle = circleManager.activeCircle,
           let members = circleManager.members[circle.id] {
            Picker("Member", selection: $selectedMemberId) {
                Text("Pick someone").tag(nil as String?)
                ForEach(members, id: \.userId) { member in
                    Text(member.displayName).tag(Optional(member.userId))
                }
            }
        } else {
            Text("No active circle.").font(.footnote).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var memberPickerMulti: some View {
        if otherMembers.isEmpty {
            Text("No other members in this circle.").font(.footnote).foregroundStyle(.secondary)
        } else {
            ForEach(otherMembers, id: \.userId) { member in
                Toggle(member.displayName, isOn: Binding(
                    get: { selectedMemberIds.contains(member.userId) },
                    set: { on in
                        if on { selectedMemberIds.insert(member.userId) }
                        else { selectedMemberIds.remove(member.userId) }
                    }
                ))
            }
        }
    }

    private var navTitle: String {
        switch mode {
        case .createBattery: return "Low Battery Alert"
        case .createInactivity: return "Inactivity Alert"
        case .editBattery: return "Edit Battery Alert"
        case .editInactivity: return "Edit Inactivity Alert"
        }
    }

    private var canSubmit: Bool {
        guard !isSubmitting else { return false }
        if mode.isEditing { return true }
        guard circleManager.activeCircle != nil else { return false }
        if mode.isBattery { return selectedMemberId != nil }
        // Inactivity: self, everyone (none selected), or any subset are all valid.
        return true
    }

    private func prefill() {
        guard !didPrefill else { return }
        didPrefill = true
        switch mode {
        case .editBattery(let r):
            isActive = r.isActive
            threshold = Double(ruleManager.threshold(for: r))
            notifyPush = Self.initialPush(notifyPush: r.notifyPush, notifyEmail: r.notifyEmail)
            // No cooldown priming: the slider is not shown for a battery rule
            // and its stored value is read by nothing.
        case .editInactivity(let a):
            isActive = a.isActive
            timeoutHours = Double(a.timeoutHours)
            notifyPush = Self.initialPush(notifyPush: a.notifyPush, notifyEmail: a.notifyEmail)
            notifyOnReturn = a.notifyOnReturn ?? false
            cooldownMinutes = Double(a.cooldownMinutes)
        case .createBattery, .createInactivity:
            break
        }
    }

    /// The Push switch for a rule opened for editing. A rule stored with e-mail
    /// only (written by an older version) notifies through the phones all the
    /// same — the server wakes them for push OR e-mail — so it opens with Push
    /// on, and saving it keeps it notifying. The server's own migration makes
    /// the same conversion.
    static func initialPush(notifyPush: Bool, notifyEmail: Bool) -> Bool {
        notifyPush || notifyEmail
    }

    /// What a save sends: Push as the editor shows it, and never an e-mail
    /// choice — `notify_email: false`, which a battery-rule CREATE must still
    /// carry (the server reads it as a required field).
    static func savedChannels(push: Bool) -> (notifyPush: Bool, notifyEmail: Bool) {
        (push, false)
    }

    private func submit() async {
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            // A save clears a stored e-mail choice nobody can see any more.
            let channels = Self.savedChannels(push: notifyPush)
            switch mode {
            case .editBattery(let r):
                try await ruleManager.updateRule(
                    r, isActive: isActive, threshold: Int(threshold),
                    notifyPush: channels.notifyPush, notifyEmail: channels.notifyEmail
                )
            case .editInactivity(let a):
                try await inactivityManager.updateAlert(
                    a, isActive: isActive, timeoutMinutes: Int(timeoutHours * 60),
                    notifyPush: channels.notifyPush, notifyEmail: channels.notifyEmail,
                    cooldownMinutes: Int(cooldownMinutes), notifyOnReturn: notifyOnReturn
                )
            case .createBattery:
                guard let circle = circleManager.activeCircle, let target = selectedMemberId else { return }
                try await ruleManager.createBatteryRule(
                    circleId: circle.id, targetUserId: target, threshold: Int(threshold),
                    notifyPush: channels.notifyPush, notifyEmail: channels.notifyEmail
                )
            case .createInactivity:
                guard let circle = circleManager.activeCircle else { return }
                let target: InactivityAlertsManager.Target
                if watchSelf {
                    target = .selfUser
                } else if selectedMemberIds.isEmpty {
                    target = .everyone
                } else {
                    target = .members(Array(selectedMemberIds))
                }
                try await inactivityManager.createAlert(
                    circleId: circle.id, target: target, timeoutMinutes: Int(timeoutHours * 60),
                    notifyPush: channels.notifyPush, notifyEmail: channels.notifyEmail,
                    cooldownMinutes: Int(cooldownMinutes), notifyOnReturn: notifyOnReturn
                )
            }
            dismiss()
        } catch let apiError as APIError {
            errorMessage = apiError.plainLine
        } catch {
            errorMessage = error.plainText
        }
    }
}
