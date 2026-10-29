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

/// The just-in-time notice, shown before this circle's first location upload.
///
/// It states, before collection, what leaves the device, the recipients (circle
/// members and vendors), purposes, history/retention and controls, and records
/// any consent the applicable state/EU law requires.
///
/// Why here and not at signup: at signup no location is collected and no
/// recipient exists. Sharing begins when a circle is created or joined, and
/// that is the first moment any of the five things above can be stated
/// truthfully — the recipients are this circle's members, and the retention is
/// decided by this circle's tier. A consent taken at signup could name none of
/// them, which is the defect in a bundled Terms + Privacy checkbox restated one
/// box over.
///
/// Two properties this screen has to keep:
///
///   * The text comes from the server. It is what the server digests into the
///     consent record, so rendering a local paraphrase would file a record
///     naming a text the user never read. `fallbackText` exists only for a
///     failed fetch, and a consent given against it is still stamped with the
///     server's own digest, with the fallback's own version named beside it.
///   * It is not dismissible by tapping away. An opt-in statute wants an
///     unambiguous affirmative act, and a sheet that closes on a swipe cannot
///     tell "yes" from "go away". Hence `.interactiveDismissDisabled`, and a
///     "Not now" button that is a real answer rather than an escape.
struct LocationConsentView: View {
    let circleName: String

    /// What agreeing does: if you don't consent, you can't be in the circle.
    /// This screen records nothing itself: the caller sends the yes WITH the
    /// join or the create, one request and one transaction, so there is never
    /// a membership without it.
    enum Purpose: Equatable {
        /// Before accepting an invitation. Agreeing is joining; anything else
        /// leaves the invitation pending.
        case join
        /// Before creating a circle. No circle without it.
        case create
    }

    let purpose: Purpose

    /// Called when the person answers, with (agreed, the notice that was on
    /// screen), so the consent names the text the person actually read rather
    /// than whatever is current by then: the fetched one, or the bundled one
    /// when the fetch failed (`shown(fetched:loadFailed:)`).
    var onFinish: (Bool, ShownNotice?) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var notice: LocationConsentNoticeResponse?
    @State private var loadFailed = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header

                    if let notice {
                        NoticeBody(markdown: notice.text)
                    } else if loadFailed {
                        NoticeBody(markdown: Self.fallbackText)
                    } else {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                    }

                }
                .padding(20)
            }
            .safeAreaInset(edge: .bottom) { actions }
            .navigationTitle("Location sharing")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(true)
        }
        .task { await load() }
    }

    // MARK: - Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Before you share with")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(circleName)
                .font(.title2.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Button {
                onFinish(true, shown)
                dismiss()
            } label: {
                Text(Self.agreeLabel(purpose))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(notice == nil && !loadFailed)

            // "Not now" on both paths: declining means the join or the creation
            // never happens, so an invitation is untouched and still there —
            // there IS a later, and "Decline invite" would overstate it.
            Button("Not now") {
                onFinish(false, shown)
                dismiss()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.bar)
    }

    // MARK: - Work

    private func load() async {
        do {
            notice = try await APIService.shared.locationConsentNotice()
        } catch {
            // Not fatal. The fallback says the same things, and a consent given
            // against it is still stamped server-side with whatever text the
            // server is actually serving, with the fallback's own version named
            // beside it — so the record stays accurate even when this fetch did
            // not.
            loadFailed = true
        }
    }

    /// The main button: what agreeing does, in the person's words.
    static func agreeLabel(_ purpose: Purpose) -> String {
        switch purpose {
        case .join: return "Join and share my location"
        case .create: return "Create and share my location"
        }
    }

    /// The notice on screen, as the request that records the answer names it.
    private var shown: ShownNotice? {
        Self.shown(fetched: notice, loadFailed: loadFailed)
    }

    /// What a yes names: the fetched notice's version, or, when the fetch
    /// failed and the bundled text was shown, that text's own. The server
    /// stamps its current notice and keeps this beside it
    /// (`client_notice_version`), warning when they differ, so a consent given
    /// against the fallback still says which text was read, and an older build's
    /// fallback shows as older. nil only while loading, when the yes is disabled.
    static func shown(fetched: LocationConsentNoticeResponse?, loadFailed: Bool) -> ShownNotice? {
        if let fetched { return ShownNotice(version: fetched.version) }
        return loadFailed ? fallbackShown : nil
    }

    /// The bundled notice, by the `version:` of its own front matter, so a new
    /// `fallbackText` brings its version with it.
    static let fallbackShown: ShownNotice? = frontMatterVersion(of: fallbackText).map { ShownNotice(version: $0) }

    /// The `version:` line of a notice's front matter (the lines before its
    /// first blank line), or nil when it has none.
    static func frontMatterVersion(of text: String) -> String? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty { return nil }
            if line.hasPrefix("version:") {
                let value = line.dropFirst("version:".count).trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    /// Used only when the notice fetch fails: byte for byte the text the
    /// server serves as v1.5 (1518 bytes), front matter and question
    /// included — the renderer drops what is not shown. Pinned by its
    /// SHA-256 in ConsentMembershipTests.
    static let fallbackText = """
    version: 1.5
    effective: 2026-10-20

    # Before you share with this circle

    ## What leaves your phone

    Your position is encrypted on your phone before it goes anywhere.
    Travelling alongside, unencrypted: which device and which circle, a
    pseudonym for you, and which day it was.

    ## Who can read it

    Everyone in this circle. Including anyone who joins later — they can read back
    through the history too, not just from the day they arrive.

    ## Who handles it on the way

    Cloudflare carries the traffic and sees your IP address. Netcup hosts the
    servers, in Nuremberg. Apple and Google deliver the alerts and can see which
    circle one is about, never what it says.

    ## How long we keep it

    Your history: two days on a free circle, a year on premium. Then it's deleted.
    The last location you shared is kept for up to 13 months.

    ## Stopping

    Pause sharing whenever you like. Turn real-time sharing off and Track stops
    sending the circle your location: they see your history up to then, and may
    still see the last location you shared. Turn location history off and they see
    where you are now but not where you've been. Your history is still kept, and
    turning it back on shows them all of it, including the time it was off. We
    enforce both on our servers, not just in the app.

    Sharing your location is part of being in a circle. You can pause it any time; to stop
    sharing for good, you leave the circle.
    As its owner, you delete it, or transfer ownership and then leave.

    ## The question

    Share my location with this circle.

    """
}

/// The notice a person answered, as the request that records the answer names
/// it (the server stamps its own version and digest beside it).
struct ShownNotice: Equatable {
    let version: String
}

/// The notice text, rendered.
///
/// A deliberately small Markdown subset — `##` headings and paragraphs — because
/// that is all the notice text uses and a general renderer would be more
/// surface than the job needs. Anything it does not recognise renders as a
/// paragraph, so an unsupported construct degrades to readable text rather than
/// disappearing.
struct NoticeBody: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(Array(Self.blocks(from: markdown).enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let text):
                    Text(text)
                        .font(.subheadline.weight(.semibold))
                        .textCase(.uppercase)
                        .kerning(0.6)
                        .foregroundStyle(.tint)
                        .fixedSize(horizontal: false, vertical: true)
                case .paragraph(let text):
                    Text(text)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    enum Block: Equatable {
        case heading(String)
        case paragraph(String)
    }

    /// Split into blocks on blank lines.
    ///
    /// The front matter (`version:` / `effective:`) and the `#` title are
    /// dropped: the version is recorded, not read, and the title is already the
    /// screen's header. Under "## The question" only the question itself — its
    /// first paragraph — is dropped, because its text is the button. Anything
    /// after it is notice text and is shown (some versions end with "Sharing
    /// your location is part of being in a circle…" there), and a sentence the
    /// consent is recorded against must be one the person read.
    static func blocks(from markdown: String) -> [Block] {
        var out: [Block] = []
        var questionPending = false
        for raw in markdown.components(separatedBy: "\n\n") {
            let chunk = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !chunk.isEmpty else { continue }
            if chunk.hasPrefix("version:") || chunk.hasPrefix("effective:") { continue }
            if chunk.hasPrefix("## ") {
                let title = String(chunk.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                if title.caseInsensitiveCompare("The question") == .orderedSame {
                    // The question is the affirmative control, which this screen
                    // renders as a button rather than as prose.
                    questionPending = true
                    continue
                }
                out.append(.heading(title))
                continue
            }
            if questionPending {
                questionPending = false
                continue
            }
            if chunk.hasPrefix("# ") { continue }
            // Soft-wrapped source lines join into one paragraph.
            let joined = chunk
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .joined(separator: " ")
            out.append(.paragraph(joined))
        }
        return out
    }
}
