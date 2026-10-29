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
import CoreLocation
import struct PingolinTrackSDK.EncryptedData
import struct PingolinTrackSDK.Location

/// History range picker + count display. Mirrors the Android app's
/// `cardHistory` with a Live / 1h / 24h / Today /
/// 7d / Custom chip group. Live draws no history, so only the
/// freshest member markers render; the other ranges call
/// `getLocationHistory` for the active circle (one member's, when the
/// sheet was opened from that member) and hand the trails to MapView,
/// which draws one line per member.
enum HistoryRange: String, Identifiable, CaseIterable {
    case live, hour, day, today, week, custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .live: return "Live"
        case .hour: return "1h"
        case .day: return "24h"
        case .today: return "Today"
        case .week: return "7d"
        case .custom: return "Custom"
        }
    }

    /// Translate the chip into a concrete (start, end) window. `.live`
    /// returns nil so the caller knows not to fetch history at all, and so
    /// does `.custom` without a usable `custom` window (its two pickers).
    func window(now: Date = Date(), custom: (start: Date, end: Date)? = nil) -> (start: Date, end: Date)? {
        switch self {
        case .live:
            return nil
        case .hour:
            return (now.addingTimeInterval(-3_600), now)
        case .day:
            return (now.addingTimeInterval(-86_400), now)
        case .today:
            let start = Calendar.current.startOfDay(for: now)
            return (start, now)
        case .week:
            return (now.addingTimeInterval(-7 * 86_400), now)
        case .custom:
            guard let custom else { return nil }
            return HistoryTrails.customWindow(start: custom.start, end: custom.end, now: now)
        }
    }
}

@MainActor
final class HistoryViewModel: ObservableObject {
    @Published var range: HistoryRange = .live {
        didSet { Task { await refreshIfNeeded() } }
    }
    /// "Custom": the window its two pickers set, the last 24 hours to start
    /// with.
    @Published var customStart = Date().addingTimeInterval(-86_400) {
        didSet { if range == .custom { Task { await refreshIfNeeded() } } }
    }
    @Published var customEnd = Date() {
        didSet { if range == .custom { Task { await refreshIfNeeded() } } }
    }
    /// Whose history: one member's (the sheet was opened from their card), or
    /// everyone's in the circle when nil.
    @Published private(set) var memberId: String?
    @Published private(set) var memberName: String?
    /// One line per member, inside the range, in time order (`HistoryTrails`):
    /// what the map draws while the sheet is up.
    @Published private(set) var trails: [HistoryTrail] = []
    @Published var pointCount: Int = 0
    @Published var isLoading = false
    @Published var error: String?
    /// Set when the server shortened the range we asked for because of the
    /// plan's history entitlement. Distinct from `error`: nothing failed, the
    /// timeline really is complete for what this account may read. Without it
    /// a free-tier "7d" that returns two days is indistinguishable from a bug.
    /// The web client shows a dismissible note, the Android app a snackbar;
    /// this is the same notice in the one place iOS has to put it.
    @Published var clampNotice: String?

    private let api = APIService.shared
    private let crypto = SDKCrypto.cryptoManager
    private var inFlight: Task<Void, Never>?

    /// The circle whose history this is (`open`): the personal one when there
    /// is no circle.
    private(set) var circleId: String?

    /// Shows a circle's history, one member's or everyone's. Another circle
    /// starts again from Live, as a new sheet would.
    func open(circleId: String, memberId: String?, memberName: String?) {
        if circleId != self.circleId {
            inFlight?.cancel()
            self.circleId = circleId
            trails = []
            pointCount = 0
            clampNotice = nil
            error = nil
            range = .live
        }
        // A Custom range kept from before stays; otherwise its pickers start
        // at the last 24 hours.
        if range != .custom {
            customEnd = Date()
            customStart = customEnd.addingTimeInterval(-86_400)
        }
        self.memberId = memberId
        self.memberName = memberName
        let opened = Self.rangeOnOpen(range, memberId: memberId)
        if opened != range {
            range = opened      // its didSet refreshes
        } else {
            Task { await refreshIfNeeded() }
        }
    }

    /// The range a sheet opens on: from a member's card on Live, their last 24
    /// hours, as on the web, rather than nothing drawn until a range is
    /// picked. Otherwise the range as it was.
    nonisolated static func rangeOnOpen(_ current: HistoryRange, memberId: String?) -> HistoryRange {
        memberId != nil && current == .live ? .day : current
    }

    /// From one member's history back to everyone's.
    func showEveryone() {
        memberId = nil
        memberName = nil
        Task { await refreshIfNeeded() }
    }

    func refreshIfNeeded() async {
        inFlight?.cancel()
        guard let circleId, let window = range.window(custom: (start: customStart, end: customEnd)) else {
            trails = []
            pointCount = 0
            clampNotice = nil
            error = range == .custom && circleId != nil ? "Choose a start before the end." : nil
            return
        }
        let memberId = self.memberId
        let personal = circleId == SelfKeyManager.selfCircleUuid
        let me = AuthManager.shared.userId
        inFlight = Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.isLoading = true
            defer { self.isLoading = false }
            do {
                // One member's rows only, when it is a circle's history: the
                // server spends its point budget on them alone.
                let wrapper = try await self.api.getLocationHistory(
                    circleId: circleId,
                    startTime: window.start,
                    endTime: window.end,
                    userId: personal ? nil : memberId
                )
                if Task.isCancelled { return }
                let responses = wrapper.locations
                // PERF: an unbounded history range decrypts every row
                // (envelope unwrap or direct circle-key decrypt) — doing that on
                // the main actor janks the UI on large ranges. Decrypt off the
                // main actor and assign the coordinates back here on MainActor.
                let crypto = self.crypto
                // Pre-import peer session keys for any session-key history rows
                // (key_id "s:{uuid}") so the off-main decrypt below stays
                // synchronous — same shape as the latest-location path. Without
                // this a range that includes a session-key row (the Android
                // app's manual "send now") silently omits those points from the
                // polyline. Fetch each distinct missing key once; a failed fetch
                // leaves the key absent so the row drops below (fail closed).
                let sessionKeyIds = Set(responses.compactMap { row -> String? in
                    guard let keyId = row.encryptedPayload.keyId, keyId.hasPrefix("s:") else { return nil }
                    return keyId
                })
                // Fetch each missing peer session key concurrently. The fetches
                // are independent (distinct key ids), their results are
                // discarded, and both APIService (an actor) and the SDK
                // CryptoManager import are internally synchronized, so the
                // fan-out is race-safe. Naturally bounded by the distinct
                // session-key count. Same shape as the latest-location path.
                let api = self.api
                await withTaskGroup(of: Void.self) { group in
                    for keyId in sessionKeyIds where !crypto.hasPeerSessionKeyFor(circleId: circleId, sessionKeyId: keyId) {
                        group.addTask {
                            _ = await api.fetchSessionKey(circleId: circleId, sessionKeyId: keyId)
                        }
                    }
                }
                let points: [HistoryPoint] = await Task.detached {
                    responses.compactMap { row -> HistoryPoint? in
                        // Whose fix it is: the server's mapping, else the sealed
                        // id. A trail is one member's, so a circle row that
                        // names nobody is left out; the personal history is the
                        // account's own.
                        var rowUserId: String? = row.userId
                        if rowUserId == nil, let blob = row.encryptedUserId {
                            rowUserId = try? crypto.decryptDataV2(
                                circleId: circleId,
                                encryptedData: EncryptedData(nonce: blob.nonce, ciphertext: blob.ciphertext),
                                fieldTag: "user_id"
                            )
                        }
                        // Envelope-encrypted rows (sendEnvelopeLocation path) carry
                        // wrappedMsgKey alongside the ciphertext — decrypt via the
                        // unwrap-then-decrypt helper. Direct-encrypted rows
                        // (legacy or sendLocation path) decrypt with the circle
                        // key directly. The Send-Location FAB writes envelope, so
                        // for the self-circle this branch is always taken.
                        let loc: Location?
                        let payload = row.encryptedPayload
                        if payload.wrappedMsgKey != nil {
                            // With the row's attributed
                            // user (resolved above), read
                            // via the sender-bound reader
                            // so v3 rows verify AND legacy
                            // v2/v1 rows still fall back
                            // (cross-rotation-safe
                            // _for_user variant). The
                            // unbound reader would
                            // silently drop every v3 row
                            // from the polyline. Mirrors
                            // CircleManager's
                            // latest-location resolution.
                            if let uid = rowUserId {
                                loc = EnvelopeDecoding.decryptLocationBound(
                                    circleId: circleId,
                                    payload: payload,
                                    userId: uid,
                                    crypto: crypto
                                )?.location
                            } else {
                                // No attribution (e.g. self-circle legacy rows) →
                                // unbound reader handles v2/v1.
                                loc = EnvelopeDecoding.decryptLocation(
                                    circleId: circleId,
                                    payload: payload,
                                    crypto: crypto
                                )
                            }
                        } else if let keyId = payload.keyId, keyId.hasPrefix("s:") {
                            // Session-key row (the Android app's manual "send now"):
                            // with the attributed user (resolved above), read via the
                            // session-key bound reader (peer key imported above;
                            // absent ⇒ drop). Session rows are always attributed
                            // circle rows — SELF never uses session keys — so a
                            // missing user id here means fail closed (drop), never
                            // plaintext.
                            if let uid = rowUserId, crypto.hasPeerSessionKeyFor(circleId: circleId, sessionKeyId: keyId) {
                                loc = EnvelopeDecoding.decryptSessionLocationBound(
                                    circleId: circleId,
                                    payload: payload,
                                    keyId: keyId,
                                    userId: uid,
                                    crypto: crypto
                                )?.location
                            } else {
                                loc = nil
                            }
                        } else {
                            let blob = EncryptedData(
                                nonce: payload.nonce,
                                ciphertext: payload.ciphertext
                            )
                            loc = try? crypto.decryptLocation(
                                circleId: circleId,
                                encryptedLocation: blob
                            )
                        }
                        guard let loc = loc, let owner = rowUserId ?? (personal ? me : nil) else { return nil }
                        return HistoryPoint(userId: owner, latitude: loc.latitude, longitude: loc.longitude,
                                            at: Date(timeIntervalSince1970: TimeInterval(loc.timestamp) / 1000))
                    }
                }.value
                if Task.isCancelled { return }
                let trails = HistoryTrails.trails(from: points, window: window, memberId: memberId)
                self.trails = trails
                self.pointCount = trails.reduce(0) { $0 + $1.points.count }
                // Assigned with the results, not before the decrypt: a notice
                // about a range the user has already moved off would outlive
                // the points it describes.
                self.clampNotice = Self.clampNotice(
                    requestedDays: Self.requestedDays(window),
                    allowedDays: wrapper.historyDaysAllowed
                )
                self.error = nil
            } catch let api as APIError where Self.isNoHistory(api) {
                // Nobody in the request shares their history with this account:
                // nothing to draw, and no "permission" error. For one member,
                // why: paused, or their history isn't shown here.
                if Task.isCancelled { return }
                self.trails = []
                self.pointCount = 0
                self.clampNotice = nil
                let member = memberId.flatMap { id in
                    CircleManager.shared.members[circleId]?.first { CanonicalId.same($0.userId, id) }
                }
                self.error = Self.noHistoryLine(status: member?.sharing(), name: self.memberName)
            } catch let api as APIError {
                self.error = api.plainLine
            } catch {
                self.error = error.plainText
            }
        }
    }

    /// The history route's one refusal for "nobody here shares their history
    /// with you" (a 403): no history kept, paused, or not a member, all alike,
    /// so that it can't be used to probe who shares.
    nonisolated static func isNoHistory(_ error: APIError) -> Bool {
        error.code == "http_403"
    }

    /// What the card says for that refusal: nothing for everyone's history (no
    /// trail is drawn); for one member, their pause, else that their history
    /// isn't shown in this circle.
    nonisolated static func noHistoryLine(status: MemberSharingStatus?, name: String?) -> String? {
        guard let name else { return nil }
        if case .paused = status, let line = SharingStatusCopy.detailSentence(name: name, status ?? .on) {
            return line
        }
        return SharingStatusCopy.historyOffSentence(name: name)
    }

    /// The span this chip ASKED for, measured in the server's own unit so the
    /// two numbers are comparable. `.live` never reaches here.
    nonisolated static func requestedDays(_ window: (start: Date, end: Date)) -> Int {
        APIService.dayBucket(window.end) - APIService.dayBucket(window.start)
    }

    /// Copy for a server-side range clamp, or nil when nothing was clamped.
    ///
    /// The `> 2` tolerance is the Android app's, and it is not slack for its
    /// own sake: both ends are floored to day buckets, so a range measured in
    /// whole days can read one short at either boundary. Anything inside that
    /// is rounding, not a plan limit — and a notice that fires on rounding
    /// would be worse than none, because it would appear for premium members
    /// too.
    nonisolated static func clampNotice(requestedDays: Int, allowedDays: Int?) -> String? {
        guard let allowedDays, allowedDays > 0 else { return nil }
        guard requestedDays - allowedDays > 2 else { return nil }
        let allowed = allowedDays == 1 ? "1 day" : "\(allowedDays) days"
        return "Showing \(allowed) of history — your plan's limit. "
            + "You asked for \(requestedDays) days."
    }
}

/// Sheet wrapper for the History picker — same content as the
/// inline `HistoryCard`, presented as a modal so the FAB tap has a
/// visible result and the user can pick a range without competing
/// with the map underneath.
struct HistorySheet: View {
    @ObservedObject var viewModel: HistoryViewModel
    @Environment(\.dismiss) private var dismiss
    /// Dragged up to the large detent; otherwise the sheet is as tall as what
    /// it holds, and follows it.
    @State private var expanded = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                HistoryCard(viewModel: viewModel)
                    .padding(.horizontal)
                Spacer()
            }
            .padding(.top, 16)
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        // Sized to what it holds. The sheet is one card — a range chip row
        // and a point count — and `.medium` would give it half the screen,
        // all of it empty below the chips, covering the map the range
        // filters. `.large` stays available for anyone who drags it up;
        // the small detent is what opens.
        .presentationDetents([.height(historySheetHeight), .large], selection: Binding(
            get: { expanded ? .large : .height(historySheetHeight) },
            set: { expanded = $0 == .large }
        ))
        .presentationBackgroundInteraction(.enabled(upThrough: .height(historySheetHeight)))
    }

    /// Chip row + the point-count line, plus the navigation bar and the home
    /// indicator, and room for the Custom range's two pickers and the member's
    /// line when they show. Set by what is shown rather than measured: a
    /// measured height that changes as the count text appears would resize the
    /// sheet under the user's finger. The card has no "History" heading of its
    /// own: the screen's title says it.
    private var historySheetHeight: CGFloat {
        238 + (viewModel.range == .custom ? 100 : 0) + (viewModel.memberName == nil ? 0 : 28)
    }
}

/// The History sheet's card; pass in the shared `HistoryViewModel` so the
/// map's trails and this picker stay in sync. No heading and no close of its
/// own: the sheet's title is "History" and its Done closes it.
struct HistoryCard: View {
    @ObservedObject var viewModel: HistoryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    if viewModel.range != .live {
                        Text("\(viewModel.pointCount) point\(viewModel.pointCount == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let name = viewModel.memberName {
                        HStack(spacing: 8) {
                            Text("Only \(name)'s history")
                                .font(.caption)
                            Button("Show all members") { viewModel.showEveryone() }
                                .font(.caption)
                        }
                    }
                }
                Spacer()
                if viewModel.isLoading {
                    ProgressView().controlSize(.small)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(HistoryRange.allCases) { range in
                        Button {
                            viewModel.range = range
                        } label: {
                            Text(range.label)
                                .font(.footnote)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(viewModel.range == range ? Color.blue : Color.clear)
                                .foregroundStyle(viewModel.range == range ? .white : .primary)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14)
                                        .stroke(viewModel.range == range ? Color.blue : Color.secondary.opacity(0.4), lineWidth: 1)
                                )
                                .cornerRadius(14)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if viewModel.range == .custom {
                DatePicker("From", selection: $viewModel.customStart, in: ...Date(),
                           displayedComponents: [.date, .hourAndMinute])
                    .font(.footnote)
                DatePicker("To", selection: $viewModel.customEnd, in: ...Date(),
                           displayedComponents: [.date, .hourAndMinute])
                    .font(.footnote)
            }

            if let error = viewModel.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            // Orange, not red, and shown alongside a full result set: this is a
            // plan boundary the user can act on, not a failure.
            if let clamp = viewModel.clampNotice {
                Label {
                    Text(clamp).font(.caption)
                } icon: {
                    Image(systemName: "clock.badge.exclamationmark")
                }
                .foregroundStyle(.orange)
                .accessibilityIdentifier("history-clamp-notice")
            }
        }
        .padding(12)
        .background(.ultraThinMaterial)
        .cornerRadius(12)
        .shadow(radius: 4)
    }
}
