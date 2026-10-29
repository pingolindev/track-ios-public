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
import PingolinTrackSDK

/// Lists every active **session** for the current account so the user
/// can rename their devices or sign one out. This screen sources from
/// auth's `/api/v1/auth/sessions` (the trust lifecycle owner). Each row
/// IS the device from the user's perspective: name, ip, last-used,
/// current marker.
///
/// Rename + Revoke both target the session by id; push tokens hang off
/// the session and follow its lifecycle (the server deactivates a
/// session's push registration when the session is revoked).
///
/// Layout mirrors the Android app: a filled tonal "this device"
/// hero card on top, then Active (≤7d) and Older (>7d) sections with
/// per-row overflow + a toolbar "Sign out all other devices" action.
@MainActor
final class DeviceManagementViewModel: ObservableObject {
    @Published private(set) var items: [DeviceListItem] = []
    @Published var error: String?
    @Published var isLoading = false
    @Published var bulkInFlight = false
    /// One-shot toast text; the View clears it after rendering.
    @Published var toast: String?
    /// True when the server has recently been unable to confirm that sessions
    /// have ended, so a sign-out made here may not take effect immediately.
    @Published private(set) var signOutsUnenforced = false

    private var rawSessions: [SessionInfo] = []
    /// `nil` while the /tracking-devices fetch is in flight or after a
    /// failure — in either case we fall back to the unfiltered
    /// session list (matches the Android app's "older backend /
    /// network blip — blank screen is worse than a bit of noise"
    /// behaviour).
    private var trackingDeviceSessionIds: Set<String>?
    /// `sessionId` → `lastSeenDayBucket` map. Ingest updates this
    /// bucket on every upload, so it's a fresher signal than
    /// `sessions.last_used_at` (which only ticks on token refresh).
    private var lastSeenDayBucketBySid: [String: Int] = [:]

    private let api = APIService.shared

    var hasOtherDevices: Bool {
        items.contains {
            if case .other = $0 { return true } else { return false }
        }
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        async let sessionsCall: SessionsListResponse? = (try? await api.listSessions())
        async let trackingCall: [TrackingDevice]? = (try? await api.listTrackingDevices())
        // Best-effort, and never allowed to fail the screen: a warning that
        // breaks the page it warns on is worse than no warning. An older
        // backend has no such route and simply reads as enforcing.
        async let revocationCall: RevocationStatus? = (try? await api.revocationStatus())
        let (sessionsRes, tracking, revocation) = await (sessionsCall, trackingCall, revocationCall)
        self.signOutsUnenforced = revocation.map { !$0.enforcing } ?? false

        if let r = sessionsRes {
            self.rawSessions = r.sessions
            self.error = nil
        } else {
            self.error = "Couldn't load devices"
        }
        if let tds = tracking {
            self.trackingDeviceSessionIds = Set(tds.compactMap { $0.sessionId })
            self.lastSeenDayBucketBySid = Dictionary(
                uniqueKeysWithValues: tds.compactMap { td -> (String, Int)? in
                    guard let sid = td.sessionId,
                          let bucket = td.lastSeenDayBucket else { return nil }
                    return (sid, bucket)
                }
            )
        } else {
            self.trackingDeviceSessionIds = nil
            self.lastSeenDayBucketBySid = [:]
        }
        // Locally-recorded real send time for THIS device — used so the
        // current row reads "Active now" instead of the day-bucket's
        // midnight (which renders as "21h ago" mid-evening). Mirrors
        // the Android app. Zero = no send yet this process; treat
        // as missing so the server fields take over.
        let localSendMs = SDKLocationStreamer.lastSuccessfulSendMs
        let localSendDate: Date? = localSendMs > 0
            ? Date(timeIntervalSince1970: TimeInterval(localSendMs) / 1000)
            : nil
        self.items = Self.buildItems(
            sessions: rawSessions,
            allowedSessionIds: trackingDeviceSessionIds,
            lastSeenBySid: lastSeenDayBucketBySid,
            currentDeviceLastSend: localSendDate,
            now: Date()
        )
    }

    func revoke(_ session: SessionInfo) async {
        do {
            _ = try await api.revokeSession(sessionId: session.id)
            await refresh()
            toast = "Signed out"
        } catch let api as APIError {
            self.error = api.plainLine
            toast = "Sign-out failed"
        } catch {
            self.error = error.plainText
            toast = "Sign-out failed"
        }
    }

    /// `nil` clears the override (server falls back to auto-detected
    /// User-Agent). Empty / whitespace-only is also treated as a clear
    /// by the server.
    func rename(_ session: SessionInfo, to newName: String?) async {
        let trimmed = newName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = (trimmed?.isEmpty ?? true) ? nil : trimmed
        do {
            _ = try await api.renameSession(sessionId: session.id, deviceName: body)
            await refresh()
            toast = "Renamed"
            self.error = nil
        } catch let api as APIError {
            self.error = api.plainLine
            toast = "Rename failed"
        } catch {
            self.error = error.plainText
            toast = "Rename failed"
        }
    }

    /// Revoke every session except the caller's current one. No backend
    /// "revoke others" endpoint is exposed, so we iterate. Errors per row
    /// are swallowed; we surface a single summary toast at the end. Mirrors
    /// the Android app's `revokeAllOthers`.
    func revokeAllOthers() async {
        let targets: [String] = items.compactMap {
            if case let .other(session, _, _) = $0 { return session.id }
            return nil
        }
        guard !targets.isEmpty else {
            toast = "No other devices to sign out"
            return
        }
        bulkInFlight = true
        defer { bulkInFlight = false }
        var ok = 0
        var failed = 0
        for id in targets {
            do {
                _ = try await api.revokeSession(sessionId: id)
                ok += 1
            } catch {
                failed += 1
            }
        }
        await refresh()
        toast = Self.bulkRevokeToast(ok: ok, failed: failed)
    }

    private static func bulkRevokeToast(ok: Int, failed: Int) -> String {
        switch (ok, failed) {
        case (_, 0):  return "Signed out \(ok) device\(ok == 1 ? "" : "s")"
        case (0, _):  return "Sign-out failed for all \(failed)"
        default:      return "Signed out \(ok); \(failed) failed"
        }
    }

    // MARK: - Item building

    /// Group sessions into three buckets — current device hero card,
    /// then "Active" (≤7 days), then "Older" (>7 days). Sort by
    /// last_used_at descending within each bucket.
    fileprivate static func buildItems(
        sessions: [SessionInfo],
        allowedSessionIds: Set<String>?,
        lastSeenBySid: [String: Int],
        currentDeviceLastSend: Date?,
        now: Date
    ) -> [DeviceListItem] {
        let sevenDays: TimeInterval = 7 * 24 * 60 * 60

        let filtered: [SessionInfo]
        if let allow = allowedSessionIds {
            filtered = sessions.filter { allow.contains($0.id) }
        } else {
            filtered = sessions
        }

        let parsed: [(SessionInfo, Date?)] = filtered.map { s in
            let authDate = parseISO(s.lastUsedAt)
            let pushDate = lastSeenBySid[s.id].map { Date(timeIntervalSince1970: TimeInterval($0) * 86_400) }
            // Prefer the higher of the two — ingest's
            // last_seen_day_bucket is fresher when the device is
            // actively uploading; auth's last_used_at is fresher
            // right after a token refresh.
            let ts: Date? = [authDate, pushDate].compactMap { $0 }.max()
            return (s, ts)
        }

        let current = parsed.first { $0.0.isCurrent }
        let others = parsed
            .filter { !$0.0.isCurrent }
            .sorted { ($0.1 ?? .distantPast) > ($1.1 ?? .distantPast) }

        let recent = others.filter { (_, ts) in
            guard let ts = ts else { return false }
            return now.timeIntervalSince(ts) <= sevenDays
        }
        let older = others.filter { (_, ts) in
            guard let ts = ts else { return true }
            return now.timeIntervalSince(ts) > sevenDays
        }

        var out: [DeviceListItem] = []
        if let (s, ts) = current {
            // The current device is THIS phone, so prefer its
            // locally-recorded last successful location send — the
            // real "location received" time, in minutes — over the
            // day-bucketed / session proxy the server only retains
            // for remote devices. Mirrors the Android app.
            let currentTs = currentDeviceLastSend ?? ts
            out.append(.current(session: s, subtitle: relativeTime(now: now, ts: currentTs)))
        }
        if !recent.isEmpty {
            out.append(.sectionHeader(title: "Active", actionLabel: nil))
            for (s, ts) in recent {
                out.append(.other(session: s, subtitle: relativeTime(now: now, ts: ts), dimmed: false))
            }
        }
        if !older.isEmpty {
            out.append(.sectionHeader(title: "Older (\(older.count))", actionLabel: "Sign out all"))
            for (s, ts) in older {
                out.append(.other(session: s, subtitle: relativeTime(now: now, ts: ts), dimmed: true))
            }
        }
        return out
    }

    fileprivate static func parseISO(_ s: String) -> Date? {
        // Auth emits ISO-8601 with fractional seconds and a "Z" suffix.
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFractional.date(from: s) { return d }
        let basic = ISO8601DateFormatter()
        basic.formatOptions = [.withInternetDateTime]
        return basic.date(from: s)
    }

    /// "Active now" / "5 minutes ago" / "3 days ago" / absolute date
    /// for old rows. Mirrors the Android app's `relativeTime`.
    fileprivate static func relativeTime(now: Date, ts: Date?) -> String {
        guard let ts = ts else { return "Unknown last activity" }
        let delta = max(0, now.timeIntervalSince(ts))
        let minutes = Int(delta / 60)
        let hours = Int(delta / 3_600)
        let days = Int(delta / 86_400)
        switch (minutes, hours, days) {
        case (0..<1, _, _):
            return "Active now"
        case (1, _, _):
            return "1 minute ago"
        case (2..<60, _, _):
            return "\(minutes) minutes ago"
        case (_, 1, _):
            return "1 hour ago"
        case (_, 2..<24, _):
            return "\(hours) hours ago"
        case (_, _, 1):
            return "Yesterday"
        case (_, _, 2..<7):
            return "\(days) days ago"
        case (_, _, 7..<30):
            return "\(days / 7) week\(days / 7 == 1 ? "" : "s") ago"
        default:
            let fmt = DateFormatter()
            fmt.dateStyle = .medium
            return fmt.string(from: ts)
        }
    }
}

/// One row in the device list. Three cases mirror the Android app's
/// sealed class — `current` renders as a filled hero card, `other`
/// as an outlined row, and `sectionHeader` as the inline "Active" /
/// "Older (N)" label with an optional trailing action button.
enum DeviceListItem: Identifiable {
    case current(session: SessionInfo, subtitle: String)
    case sectionHeader(title: String, actionLabel: String?)
    case other(session: SessionInfo, subtitle: String, dimmed: Bool)

    var id: String {
        switch self {
        case .current(let s, _):       return "current.\(s.id)"
        case .sectionHeader(let t, _): return "header.\(t)"
        case .other(let s, _, _):      return "other.\(s.id)"
        }
    }
}

struct DeviceManagementView: View {
    @StateObject private var viewModel = DeviceManagementViewModel()
    @State private var renameTarget: SessionInfo?
    @State private var renameDraft: String = ""
    @State private var revokeTarget: SessionInfo?
    @State private var showBulkRevokeConfirm = false

    var body: some View {
        List {
            if let error = viewModel.error {
                Section {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            // Above the rows, because it changes what the Sign out button on
            // each of them means. Wording is deliberately about the recent past
            // ("have not been able to confirm"), not a live claim that a service
            // is down — the server only knows it failed open recently, and auth
            // may already have recovered.
            if viewModel.signOutsUnenforced {
                Section {
                    Text("Sign-outs may not be taking effect. In the last few minutes we have not been able to confirm that sessions have ended, so a device you sign out here may keep receiving locations for a short time — up to 15 minutes for a phone, or until the session ends for a browser. To stop sharing immediately, leave the circle instead.")
                        .font(.footnote)
                        .accessibilityIdentifier("signouts-unenforced-warning")
                }
            }

            ForEach(viewModel.items) { item in
                row(for: item)
            }

            if !viewModel.isLoading && viewModel.items.isEmpty && viewModel.error == nil {
                Section {
                    Text("No tracking devices yet — grant location permission and start tracking on a phone to see it here.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            // Footer — clarifies this list shows location-sharing
            // devices only. There is no Open Account / Security
            // deep-link, as on the Android app: the account
            // shell hosts the Paddle upgrade flow, and steering users
            // there from inside the app trips App Store anti-steering
            // rules (same shape as Play's external-purchase rule).
            // Native session management lives in this screen,
            // so no functionality is missing.
            Section {
                Text("Only devices that share location appear here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Devices")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await viewModel.refresh() }
        .task { await viewModel.refresh() }
        .overlay {
            if viewModel.isLoading && viewModel.items.isEmpty {
                ProgressView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button(role: .destructive) {
                        showBulkRevokeConfirm = true
                    } label: {
                        Label("Sign out all other devices", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    .disabled(!viewModel.hasOtherDevices || viewModel.bulkInFlight)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .alert("Rename device", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        ), presenting: renameTarget) { session in
            TextField("Pixel 7, Asha's iPhone, …", text: $renameDraft)
                .textInputAutocapitalization(.words)
            Button("Save") {
                let draft = renameDraft
                Task { await viewModel.rename(session, to: draft) }
                renameTarget = nil
            }
            Button("Reset to auto-detected") {
                Task { await viewModel.rename(session, to: nil) }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) {
                renameTarget = nil
            }
        } message: { _ in
            Text("Shows up here and in the Devices section on the account site.")
        }
        .alert("Sign out device?", isPresented: Binding(
            get: { revokeTarget != nil },
            set: { if !$0 { revokeTarget = nil } }
        ), presenting: revokeTarget) { session in
            Button("Sign out", role: .destructive) {
                Task { await viewModel.revoke(session) }
                revokeTarget = nil
            }
            Button("Cancel", role: .cancel) {
                revokeTarget = nil
            }
        } message: { session in
            Text("Signs out \(session.deviceName?.isEmpty == false ? session.deviceName! : "this device") and stops push notifications to it.")
        }
        .alert("Sign out other devices?",
               isPresented: $showBulkRevokeConfirm) {
            Button("Sign out all", role: .destructive) {
                Task { await viewModel.revokeAllOthers() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            let count = otherDeviceCount()
            Text("Signs out \(count) device\(count == 1 ? "" : "s"). You'll stay signed in here.")
        }
        .overlay(alignment: .bottom) {
            if let toast = viewModel.toast {
                Text(toast)
                    .font(.subheadline)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task {
                        try? await Task.sleep(nanoseconds: 1_800_000_000)
                        viewModel.toast = nil
                    }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.toast)
    }

    private func otherDeviceCount() -> Int {
        viewModel.items.reduce(into: 0) { acc, item in
            if case .other = item { acc += 1 }
        }
    }

    @ViewBuilder
    private func row(for item: DeviceListItem) -> some View {
        switch item {
        case let .current(session, subtitle):
            CurrentDeviceCard(session: session, subtitle: subtitle) {
                renameTarget = session
                renameDraft = session.deviceName ?? ""
            }
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 12, trailing: 16))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

        case let .sectionHeader(title, actionLabel):
            HStack {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Spacer()
                if let label = actionLabel {
                    Button(label) {
                        showBulkRevokeConfirm = true
                    }
                    .font(.subheadline)
                    .buttonStyle(.borderless)
                }
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

        case let .other(session, subtitle, dimmed):
            OtherDeviceRow(
                session: session,
                subtitle: subtitle,
                dimmed: dimmed,
                onRename: {
                    renameTarget = session
                    renameDraft = session.deviceName ?? ""
                },
                onRevoke: { revokeTarget = session }
            )
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }
}

/// Hero card for the current device — filled tonal background,
/// large icon, inline rename pencil. Mirrors the Android app's
/// current-device layout.
private struct CurrentDeviceCard: View {
    let session: SessionInfo
    let subtitle: String
    let onRename: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName(for: session))
                .font(.system(size: 32, weight: .regular))
                .foregroundStyle(.tint)
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(displayName(for: session))
                        .font(.headline)
                    Text("This device")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                        .foregroundStyle(.tint)
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onRename) {
                Image(systemName: "pencil")
                    .padding(8)
                    .background(Color(.systemBackground).opacity(0.5), in: SwiftUI.Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// Standard per-device row — outlined card with overflow menu. Dimmed
/// when the row sits in the "Older" section so users can scan at a
/// glance which sessions deserve attention.
private struct OtherDeviceRow: View {
    let session: SessionInfo
    let subtitle: String
    let dimmed: Bool
    let onRename: () -> Void
    let onRevoke: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName(for: session))
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName(for: session))
                    .font(.body)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button {
                    onRename()
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    onRevoke()
                } label: {
                    Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .padding(8)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .opacity(dimmed ? 0.6 : 1.0)
    }
}

// MARK: - Shared helpers

/// Show the user-set device name, falling back to a friendly
/// placeholder rather than a literal "Unknown Device" for
/// unparseable rows.
private func displayName(for session: SessionInfo) -> String {
    let raw = session.deviceName?.trimmingCharacters(in: .whitespaces) ?? ""
    return raw.isEmpty ? "Unnamed device" : raw
}

/// Best-effort icon picker. The server gives us a free-form
/// device_name with a User-Agent-parsed prefix; we sniff the string
/// for the platform marker. No match → generic devices SF Symbol.
/// Mirrors the Android app's `iconFor` heuristic.
private func iconName(for session: SessionInfo) -> String {
    let name = (session.deviceName ?? "").lowercased()
    if name.contains("iphone") { return "iphone" }
    if name.contains("ipad") { return "ipad" }
    if name.contains("ios") { return "iphone" }
    if name.contains("android") { return "candybarphone" }
    let desktopMarkers = ["windows", "macos", "mac os", "linux",
                          "chrome", "firefox", "edge", "safari"]
    if desktopMarkers.contains(where: { name.contains($0) }) {
        return "laptopcomputer"
    }
    return "display"
}
