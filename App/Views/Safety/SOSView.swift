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

struct SOSView: View {
    @StateObject private var sosManager = SOSManager.shared
    @StateObject private var circleManager = CircleManager.shared
    @State private var showingSOSConfirm = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Active SOS Alert
                    if let myAlert = sosManager.myActiveAlert {
                        ActiveSOSCard(alert: myAlert)
                    }

                    // Circle Alerts. A dismissed alert is NOT dropped straight
                    // away — it lingers here, greyed and counting down, for its
                    // 24h grace window so a mistaken dismissal can be undone.
                    // The map hides it immediately; this row is the way back.
                    if !sosManager.visibleAlerts.isEmpty {
                        CircleAlertsSection(alerts: sosManager.visibleAlerts)
                    }

                    // SOS button (matches the Android SOS screen —
                    // single big red action with a tap subtitle; no
                    // check-in affordance here). The button is a tap →
                    // confirm dialog, not a long-press, so the subtitle
                    // says "Tap", matching Android.
                    VStack(spacing: 8) {
                        Button(action: { showingSOSConfirm = true }) {
                            HStack {
                                // Warning triangle, not the "sos" SF Symbol.
                                // Track does not summon anyone, and the distress
                                // signal would claim that it might.
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.title)
                                // The disclaimer is IN the
                                // label, not beside it: the
                                // button is the last thing
                                // read before the tap, and
                                // "not emergency services"
                                // is the one fact a person
                                // in trouble must not learn
                                // later. Hence the wrapping
                                // allowances below — a fixed
                                // 80pt frame would clip this
                                // string, and clipped text
                                // is exactly where the
                                // caveat gets lost.
                                Text("Notify my circle - not emergency services")
                                    .font(.title2)
                                    .fontWeight(.semibold)
                                    .multilineTextAlignment(.center)
                                    .minimumScaleFactor(0.7)
                            }
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 80)
                            .background(Self.notifyGreen)
                            .cornerRadius(16)
                        }
                        .disabled(sosManager.raiseIsOff)

                        Text("Tap to notify the active members of this circle and show them where you are — you'll confirm before it sends")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal)

                    // Alerts entry (mirrors Android's SOS card +
                    // its unified Alerts list). Tap navigates to
                    // the merged battery + inactivity alerts screen.
                    NavigationLink(destination: AlertsView()) {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Alerts")
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                Text("Get notified about low battery or inactivity")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.secondary)
                        }
                        .padding()
                        .background(Color(.systemGray6))
                        .cornerRadius(12)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal)
                }
                .padding(.vertical)
            }
            .navigationTitle("Notify my circle")
            // The circle's privacy row is read again as the dialog appears,
            // so the raise judges a held position on a record read after it
            // was taken. Never awaited: the raise doesn't wait for it.
            .onChange(of: showingSOSConfirm) { _, showing in
                guard showing, let circleId = circleManager.activeCircle?.id else { return }
                Task { try? await circleManager.loadPrivacySettings(for: circleId) }
            }
            .alert("Notify your circle?", isPresented: $showingSOSConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Notify", role: .destructive) {
                    triggerSOS()
                }
            } message: {
                if let notice = privacyOverrideNotice {
                    Text("\(notice)\n\n\(Self.reachExplanation)")
                } else {
                    Text(Self.reachExplanation)
                }
            }
            // Surface a failed send. Without this the button appears to work and
            // the notification simply never arrives.
            .alert(
                "Not Sent",
                isPresented: Binding(
                    get: { sosManager.lastTriggerError != nil },
                    set: { if !$0 { sosManager.lastTriggerError = nil } }
                )
            ) {
                Button("OK", role: .cancel) { sosManager.lastTriggerError = nil }
            } message: {
                Text(sosManager.lastTriggerError ?? "")
            }
            // What actually happened to it is on the active card, "Did it
            // get through?", as the answer comes in: never an alert, whose
            // text is fixed when it shows.
            .task {
                // No circle argument: alerts are loaded across every circle
                // the user belongs to, so an emergency outside the currently
                // selected circle still appears here.
                try? await sosManager.loadActiveAlerts()
            }
        }
    }

    /// The notify button's green.
    ///
    /// NOT `Color.green`. systemGreen is #34C759, and white on it is 2.22:1 —
    /// under WCAG AA's 4.5:1, which would make the most important button in
    /// the app hard to read. This is Material Green 800 (#2E7D32), which
    /// carries white at 5.13:1 and still reads unmistakably green. Matches
    /// the Android app's `sos_notify_green`.
    private static let notifyGreen = Color(red: 46 / 255, green: 125 / 255, blue: 50 / 255)

    /// What this actually does, shown in the confirm dialog before "Notify".
    ///
    /// Three facts, in the order that matters to someone deciding whether this
    /// is the thing to tap:
    ///   1. WHO gets it — active members of this circle, nobody else. Not a
    ///      dispatcher, not a contact list, not everyone who was ever a member.
    ///   2. That delivery is BEST-EFFORT. A push can be dropped, a phone can be
    ///      off, and `SOSDeliveryCopy` exists precisely because "this reached
    ///      nobody" is a real outcome. Promising arrival here and reporting a
    ///      failure afterwards would be the wrong order.
    ///   3. What to do INSTEAD when it is an emergency. Stating the limitation
    ///      ("Pingolin does not contact emergency services") without naming the
    ///      alternative leaves out the half that is useful to someone in
    ///      immediate danger.
    ///
    /// One constant, used by both branches of the dialog, so the override
    /// wording and the ordinary wording cannot drift apart on any of the three.
    private static let reachExplanation =
        "This sends your location only to active members of this circle. "
        + "Delivery is not guaranteed. If you are in immediate danger, "
        + "contact your local emergency services."

    /// Replaces the confirm dialog's usual sentence when the active circle is one
    /// the user has hidden their location from.
    ///
    /// Notifying seals the location with the CIRCLE key, so every member decrypts
    /// the same ciphertext and there is no per-member withholding available to
    /// implement. Stripping the location instead is not an option: pausing is
    /// circle-WIDE and the circle is chosen here, so a silent downgrade would gut
    /// a safety feature at the moment it matters most. Saying plainly what is
    /// about to happen, and then doing exactly what is asked, is the honest
    /// middle — and this dialog already exists, so it costs the user no extra tap.
    ///
    /// Reads the cached posture rather than fetching: this runs when someone
    /// needs help, so it must not depend on a round trip.
    ///
    /// FAILS CLOSED on a cache miss. Treating an unknown posture as the server
    /// default ("exact") is exactly backwards for the person this protects:
    /// someone who paused is BY DEFINITION not on the default, and a miss is a
    /// real state rather than a theoretical one — privacySettings is filled only
    /// by the loadCircles fan-out, whose per-circle GETs are best-effort and
    /// swallowed, so a cold launch has none of it. Paused, cold app, real
    /// emergency, generic confirm: the exact location would go to the person she
    /// was hiding from, while the Terms promise she is told first. Warning
    /// unnecessarily costs a sentence; not warning costs the thing the feature
    /// exists to prevent.
    private var privacyOverrideNotice: String? {
        guard let circleId = circleManager.activeCircle?.id else { return nil }
        guard let settings = circleManager.privacySettings[circleId] else {
            return "We could not check your sharing settings for this circle just now. "
                + "If you have paused sharing or set an approximate location for it, "
                + "sending will override that and show everyone in it your exact location."
        }
        if settings.isPaused {
            return "You have paused sharing with this circle. Sending will show everyone in it your exact location."
        }
        if settings.sharesApproximately {
            return "You are sharing only an approximate location with this circle. Sending will show everyone in it your exact location."
        }
        // shareRealtime is a SEPARATE flag from the pause and the blur, and it
        // is the control the Terms call the strongest on the screen — it does
        // not expire and it is applied server-side — so it gets its own warning
        // here, as on the web and Android: the most deliberate choice a user
        // can make must not be the one this dialog stays quiet about.
        if settings.shareRealtime == false {
            return "You have turned real-time sharing off for this circle. Sending will show everyone in it your exact location anyway."
        }
        return nil
    }

    private func triggerSOS() {
        Task {
            await sosManager.quickTriggerSOS()
        }
    }

}

/// What the raiser is told about how far their notification got, on the
/// active card, as `SOSManager.delivery` changes.
enum SOSDeliveryCopy {
    static let checking = "Checking whether your circle received it…"
    /// The title of the one notice, in the app or as a notification, when a
    /// circle notification settled as reaching nobody. True in both settled
    /// states: nothing went anywhere, e-mail included.
    static let reachedNobodyTitle = "Your circle notification didn't reach anyone"

    /// The one notice when the checks ended with no answer at all (the card's
    /// `noAnswer`): unknown, not nobody, so never the reached-nobody words; and
    /// not "confirm", which on the card means a device reported arrival.
    static let noAnswerTitle = "Your circle notification may not have arrived"
    static let noAnswerBody = "We couldn't find out whether it reached anyone. If you need help now, contact someone directly."

    /// The settled answers that reached someone, or were sent and are waiting
    /// on a device: no notice.
    static let answeredStates: Set<String> = ["confirmed", "partial", "no_confirmation"]

    /// That notice's body, per settled state: shorter than the card's line,
    /// which stays as it is. Never "try again": the same circle gives the
    /// same answer.
    static func reachedNobodyBody(_ state: String) -> String? {
        switch state {
        case "alone":
            return "Nobody else is in this circle, so there was no one to notify. "
                + "If you need help now, contact someone directly, or notify a different circle."
        case "undeliverable":
            return "Nobody in this circle has a device we can notify. Contact them another way."
        default:
            return nil
        }
    }
    /// The checks ended with no answer at all: said, never "Checking…" forever.
    static let noAnswer = "We couldn't find out whether it arrived. If this matters right now, reach someone another way."

    /// One sentence per state, plus the caveats that apply to it.
    ///
    /// "Confirmed" throughout means a recipient's DEVICE reported the
    /// notification arrived — not acknowledgement, and not anyone having read
    /// it. Keeping those apart is the whole point of this text.
    static func verdict(_ status: SOSManager.DeliveryStatus) -> String {
        guard let d = status.response else {
            return status.stillChecking ? checking : noAnswer
        }

        let head: String
        switch d.state {
        case "alone":
            head = "Nobody else is in this circle, so there was no one to notify. Add someone, or pick a different circle."
        case "confirmed":
            head = "All \(d.recipients) confirmed their device received it."
        case "partial":
            head = "\(d.confirmed) of \(d.recipients) confirmed their device received it. The rest have not yet — a phone that is off or has no signal cannot confirm."
        case "no_confirmation":
            head = "Nobody's device has confirmed yet. We sent it, but we cannot tell whether it arrived. If this matters right now, reach someone another way."
        case "undeliverable":
            head = "This did not reach anyone. Nobody in this circle has a device we can notify. Contact them another way."
        default:
            head = status.stillChecking ? checking : noAnswer
        }

        var parts = [head]
        if d.emailed > 0 {
            parts.append("We also emailed \(d.emailed).")
        }
        if d.confirmed > 0 {
            parts.append("Confirmed means the notification reached their device — not that anyone has read it or is on their way.")
        }
        return parts.joined(separator: "\n\n")
    }
}

/// WHERE an SOS was raised, as a street address.
///
/// Resolved on device: the server stores the alert's location encrypted and
/// cannot answer this. Renders nothing at all until the lookup succeeds — an
/// alert with no decryptable coordinates, or a device with no geocoding data,
/// gets no line rather than a placeholder that never fills in.
private struct SOSAddressLine: View {
    let alert: SOSAlert
    /// White-on-red inside `ActiveSOSCard`, secondary on a plain card
    /// elsewhere — the card behind this decides, not the line.
    var style: AnyShapeStyle = AnyShapeStyle(.secondary)

    @State private var address: String?

    var body: some View {
        Group {
            if let address, !alert.hasApproximatePosition {
                Label(address, systemImage: "mappin.and.ellipse")
                    .font(.caption)
                    .foregroundStyle(style)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // Keyed on the alert AND its position, not on view identity.
        // `ActiveSOSCard` is reached through a plain `if let`, so raising a
        // second SOS after resolving the first reuses the same view — an
        // unkeyed .task would not re-run and the card would show the OLD
        // emergency's address next to the new one. And a raiser's phone can
        // update the position: the address follows. None for a position
        // known only as an area.
        .task(id: alert.positionKey) {
            address = nil
            guard let coordinate = alert.coordinate, !alert.hasApproximatePosition else { return }
            // placardAddress, not `text`: with the server geocoder on, `text` is
            // the street alone, and a street with no city is not an address you
            // can relay to anyone.
            guard let r = await GeocodingService.shared.reverse(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude
            ) else { return }
            address = AddressFormat.placardAddress(r, withPOIName: true)
        }
    }
}

struct ActiveSOSCard: View {
    let alert: SOSAlert
    @StateObject private var sosManager = SOSManager.shared
    /// Watched so the responders are named once their names open.
    @StateObject private var circleManager = CircleManager.shared
    @State private var showingCancelConfirm = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.white)

                VStack(alignment: .leading) {
                    // No claim about delivery: it would be
                    // false when nobody was reached. "Did it
                    // get through?" below is the one place
                    // that speaks of delivery.
                    Text("Your circle notification")
                        .font(.headline)
                        .foregroundStyle(.white)

                    Text("Sent \(alert.createdAt.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.8))
                }

                Spacer()

                // acknowledgmentCount, NOT acknowledgedBy.count: the server
                // sends a count (who, only to the raiser and only on GET
                // /sos/{id}: `SOSManager.responders`), so `acknowledgedBy` is
                // built as [] everywhere and a block keyed on it would never
                // render — the one person who most needs to know somebody is
                // coming would be the one person never told. SOSMapOverlays
                // reads the count the same way.
                if alert.acknowledgmentCount > 0 {
                    VStack(alignment: .trailing) {
                        Text("\(alert.acknowledgmentCount)")
                            .font(.title)
                            .fontWeight(.bold)
                            .foregroundStyle(.white)

                        Text("Acknowledged")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
            }

            // Who is responding: served to the raiser alone.
            if let responding = sosManager.respondingLine(for: alert) {
                Text(responding)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            SOSAddressLine(alert: alert, style: AnyShapeStyle(.white.opacity(0.85)))

            // Did it get through? Bound to the delivery state, so each
            // answer replaces the last as it comes in, and kept here once
            // the checks end. This alert's alone.
            if let delivery = sosManager.delivery, CanonicalId.same(delivery.alertId, alert.id) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Did it get through?")
                        .font(.subheadline.weight(.semibold))
                    HStack(alignment: .top, spacing: 8) {
                        if delivery.stillChecking {
                            ProgressView()
                                .tint(.white)
                        }
                        Text(SOSDeliveryCopy.verdict(delivery))
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }

            // What went out as the position.
            if let line = SOSManager.raiserLine(sosManager.myPosition, raisedAt: alert.createdAt) {
                Text(line)
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if sosManager.myPosition?.locationOff == true, sosManager.myPosition?.marker == .unavail {
                VStack(alignment: .leading, spacing: 6) {
                    // The app's own location-off guidance (MapView's banner).
                    Text(LocationService.shared.authorizationStatus == .restricted
                         ? LocationOffCopy.restricted : LocationOffCopy.denied)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.9))
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Cancel buttons.
            //
            // Styled by hand rather than with .bordered/.borderedProminent +
            // .tint(.white): those derive the label colour from the tint, so on
            // this red card a white tint would produce a white label on a white
            // fill. Spelling out fill and foreground keeps both readable.
            HStack(spacing: 12) {
                Button(action: { showingCancelConfirm = true }) {
                    Text("False Alarm")
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(.white.opacity(0.7), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)

                Button(action: resolveSOS) {
                    Text("I'm Safe")
                        .fontWeight(.semibold)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(.white, in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
        .padding()
        .background(.red)
        .cornerRadius(16)
        .padding(.horizontal)
        .alert("Cancel this notification?", isPresented: $showingCancelConfirm) {
            Button("Keep Active", role: .cancel) {}
            Button("Mark as False Alarm", role: .destructive) {
                cancelSOS()
            }
        }
    }

    // Not `try?`: while the alert stays active the whole circle is still being
    // told there is an emergency. A silently-failed "I'm Safe" leaves the card
    // on screen with no indication anything went wrong, so the raiser believes
    // they have stood everybody down when they have not.
    private func cancelSOS() {
        Task {
            errorMessage = nil
            do {
                try await sosManager.cancelSOS(alert, reason: .falseAlarm)
            } catch {
                errorMessage = Self.closeFailure(error)
            }
        }
    }

    private func resolveSOS() {
        Task {
            errorMessage = nil
            do {
                try await sosManager.resolveSOS(alert)
            } catch {
                errorMessage = Self.closeFailure(error)
            }
        }
    }

    nonisolated static func closeFailure(_ error: Error) -> String {
        // An APIError describes itself in the app's words, never the server's.
        "Still active — couldn't update your circle. \(error.plainText)"
    }
}

struct CircleAlertsSection: View {
    let alerts: [SOSAlert]
    @StateObject private var circleManager = CircleManager.shared

    var otherAlerts: [SOSAlert] {
        SOSManager.othersLive(alerts, me: AuthManager.shared.userId)
    }

    var body: some View {
        if !otherAlerts.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Active Alerts")
                    .font(.headline)
                    .padding(.horizontal)

                ForEach(otherAlerts) { alert in
                    AlertCard(alert: alert)
                }
            }
        }
    }
}

struct AlertCard: View {
    let alert: SOSAlert
    // The "removed in Xh Ym" countdown re-renders once a minute through a
    // `TimelineView(.everyMinute)` around that one line (below), not a
    // `Timer.publish` per card, which would keep firing every minute for as
    // long as the Safety tab had been visited — all night, in a process the
    // location request never lets iOS suspend — whether or not the card was
    // on screen or even showing a countdown. SwiftUI pauses a timeline that
    // is not visible.
    @StateObject private var sosManager = SOSManager.shared
    @StateObject private var circleManager = CircleManager.shared
    @State private var cameraPosition: MapCameraPosition = .automatic

    var member: CircleMember? {
        guard let circleId = circleManager.activeCircle?.id,
              let members = circleManager.members[circleId] else { return nil }
        return members.first { $0.userId == alert.userId }
    }

    /// Per-viewer, from the server. Acknowledging does not flip the shared
    /// status, so `alert.status` cannot answer this.
    var hasAcknowledged: Bool {
        alert.acknowledgedByMe || alert.acknowledgedBy.contains(AuthManager.shared.userId ?? "")
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                // Tapping the entry opens this alert's marker on the map. Only
                // the leading region is the tap target, so it can't fight with
                // the Acknowledge / Dismiss controls on the trailing edge.
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)

                    VStack(alignment: .leading) {
                        Text(member?.displayName ?? "Unknown")
                            .fontWeight(.medium)

                        Text(alert.createdAt.formatted(.relative(presentation: .named)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture { showOnMap() }

                if alert.dismissedByMe {
                    // Already off the map. This row is the only route back, so
                    // Undo replaces the actions that assume you're engaging.
                    Button("Undo") { undismissAlert() }
                        .buttonStyle(.bordered)
                } else if !hasAcknowledged {
                    Button("Acknowledge") {
                        acknowledgeAlert()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                } else {
                    Label("Acknowledged", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }

                // Side dismiss. Hides the alert for this user only; it stays
                // active for everyone else. Kept visually subordinate to
                // Acknowledge — that one changes what the circle sees, this
                // one only changes what you see.
                Button {
                    dismissAlert()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(6)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss for me")
            }

            // WHERE it was raised. A responder reading this list should not have
            // to open the map — or read off coordinates — to find out where to go.
            SOSAddressLine(alert: alert)

            // How old that position is, or that one is still on its
            // way, and how precise when it is an area.
            if alert.coordinate != nil, let line = SOSPositionText.line(alert.positionReading()) {
                Text(line)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if alert.coordinate != nil, let area = alert.positionAreaMeters {
                Text(SOSPositionText.within(area))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Grace-period notice: when it goes, and that it can be brought back.
            if alert.dismissedByMe, let expiry = alert.dismissExpiry {
                TimelineView(.everyMinute) { context in
                    let now = context.date
                    Text(expiry > now
                         ? "Dismissed · removed in \(Self.remainingText(from: now, to: expiry)) · Undo restores it to the map"
                         : "Dismissed · removing now")
                        .font(.caption)
                        .italic()
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            // Mini map + directions, only when the location actually decrypted.
            // Never fall back to (0, 0) on a decrypt failure: that draws the
            // preview — and offers directions — to the Gulf of Guinea.
            if let coordinate = alert.coordinate {
                Map(position: $cameraPosition) {
                    // An area with the alert's label, never a
                    // pin, when the position is that rough: a
                    // coarse fix, or a held one under a bubble.
                    if let area = alert.positionAreaMeters {
                        MapPolygon(coordinates: ApproximateArea.outline(center: coordinate, radiusMeters: area))
                            .foregroundStyle(.red.opacity(0.18))
                            .stroke(.red.opacity(0.7), lineWidth: 1)
                        Annotation("", coordinate: coordinate, anchor: .center) {
                            Text(SOSPositionText.areaLabel(alert.positionReading(), areaMeters: area))
                                .font(.caption2.weight(.semibold))
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(.red, in: RoundedRectangle(cornerRadius: 6))
                        }
                    } else {
                        Annotation(SOSPositionText.mapLabel(alert.positionReading()), coordinate: coordinate) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.title)
                                .foregroundStyle(.red)
                        }
                    }
                }
                .frame(height: 120)
                .cornerRadius(8)
                .onAppear { frame(coordinate) }
                // The raiser's phone can update the position: the map follows.
                .onChange(of: alert.positionKey) { frame(coordinate) }

                // Directions go to a point: an area has none to give.
                if !alert.hasApproximatePosition {
                    Button(action: openDirections) {
                        Label("Get Directions", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                // "Sending current location" while the raiser's phone gets one,
                // "Location unavailable" when it can't; `noPosition` when nothing
                // opened.
                Text(SOSPositionText.line(alert.positionReading()) ?? SOSPositionText.noPosition)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.1), radius: 4)
        .padding(.horizontal)
        // Greyed so a dismissed row reads as on its way out, not live.
        .opacity(alert.dismissedByMe ? 0.55 : 1.0)
    }

    /// The mini map on `coordinate`, wide enough for its area when it has one.
    private func frame(_ coordinate: CLLocationCoordinate2D) {
        cameraPosition = .camera(MapCamera(
            centerCoordinate: coordinate,
            distance: max(2000, (alert.positionAreaMeters ?? 0) * 3)
        ))
    }

    /// "23h 58m" / "45m" / "30s" — coarse enough to read at a glance, fine
    /// enough near the end that it visibly counts down.
    static func remainingText(from now: Date, to expiry: Date) -> String {
        let seconds = max(0, Int(expiry.timeIntervalSince(now)))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "\(seconds)s"
    }

    private func acknowledgeAlert() {
        Task {
            try? await sosManager.acknowledgeSOS(alert)
        }
    }

    /// Private per-viewer hide. Not acknowledge (an outward signal to the
    /// circle) and not resolve (closes it for everyone, raiser/admin only).
    /// Undo a dismissal inside the grace window — restores this row and the
    /// map marker together.
    private func undismissAlert() {
        Task { try? await sosManager.undismissSOS(alert) }
    }

    private func dismissAlert() {
        Task {
            try? await sosManager.dismissSOS(alert)
        }
    }

    /// Jump to this alert's marker on the map. Routed through the same
    /// MapTapState singleton PlacesView uses, so it survives the tab switch.
    private func showOnMap() {
        guard alert.coordinate != nil else { return }
        MapTapState.shared.pendingFocusSOS = alert
        TabSelectionState.shared.selected = 0
    }

    private func openDirections() {
        guard let coordinate = alert.coordinate, !alert.hasApproximatePosition else { return }
        let mapItem = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        mapItem.name = "\(member?.displayName ?? "Circle member") Location"
        mapItem.openInMaps(launchOptions: [
            MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving
        ])
    }
}

struct RecentCheckInsSection: View {
    @StateObject private var checkInManager = CheckInManager.shared
    @StateObject private var circleManager = CircleManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recent Check-ins")
                    .font(.headline)

                Spacer()

                NavigationLink(destination: CheckInHistoryView()) {
                    Text("See All")
                        .font(.subheadline)
                }
            }
            .padding(.horizontal)

            // Check-ins waiting for this iPhone to catch up, at the top.
            PendingChangesInPlace(kinds: [.checkIn])
                .padding(.horizontal)

            if checkInManager.recentCheckIns.isEmpty {
                Text("No recent check-ins")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            } else {
                ForEach(checkInManager.recentCheckIns.prefix(5)) { checkIn in
                    CheckInRow(checkIn: checkIn)
                }
            }
        }
    }
}

struct CheckInRow: View {
    let checkIn: CheckIn
    @StateObject private var circleManager = CircleManager.shared

    var member: CircleMember? {
        guard let circleId = circleManager.activeCircle?.id,
              let members = circleManager.members[circleId] else { return nil }
        return members.first { $0.userId == checkIn.userId }
    }

    var isCurrentUser: Bool {
        checkIn.userId == AuthManager.shared.userId
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: checkIn.type.icon)
                .foregroundStyle(.blue)
                .frame(width: 32, height: 32)
                .background(.blue.opacity(0.1))
                .clipShape(SwiftUI.Circle())

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(isCurrentUser ? "You" : member?.displayName ?? "Unknown")
                        .fontWeight(.medium)

                    Text(checkIn.type.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let message = checkIn.message {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Text(checkIn.timestamp.formatted(.relative(presentation: .named)))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}



#Preview {
    SOSView()
}
