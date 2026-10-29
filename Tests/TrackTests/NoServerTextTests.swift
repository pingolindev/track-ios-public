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
import PingolinTrackSDK
@testable import Track

/// No server `error`/`message` text ever reaches the screen. It can carry key
/// talk ("at_version is not this circle's current key version"), or whatever a
/// hacked server wants a person to read. Nor does the SDK's own error text
/// (`MobileError.KeyNotFound(message: …)`): key talk, and for a network
/// failure it can carry the server's words.
final class NoServerTextTests: XCTestCase {

    private let raw = "Invalid membership statement: at_version is not this circle's current key version"

    /// Every code gets a plain line by what kind of failure it is, and none
    /// carries the server's text or a code suffix.
    func testAnAPIErrorDescribesItselfInTheAppsWords() {
        let cases: [(code: String, errorCode: String?, line: String)] = [
            ("weird_thing", nil, APIError.failedText),
            ("invite_invalid_statement", "invite_invalid_statement", APIError.failedText),
            ("http_400", nil, APIError.failedText),
            ("http_404", nil, APIError.goneText),
            ("circle_not_found", "circle_not_found", APIError.goneText),
            ("http_403", nil, APIError.notAllowedText),
            ("auth_not_circle_admin", "auth_not_circle_admin", APIError.notAllowedText),
            ("http_429", nil, APIError.tooManyText),
            ("rate_limited", nil, APIError.tooManyText),
            ("http_500", nil, APIError.troubleText),
            ("http_503", nil, APIError.troubleText),
            ("server_unavailable", "server_unavailable", APIError.troubleText),
            ("network_error", nil, APIError.unreachableText),
            ("missing_circle_key", nil, "This circle isn't open on this phone yet."),
            ("no_members_to_watch", nil, "There's nobody else in this circle to watch yet."),
        ]
        for c in cases {
            let error = APIError(code: c.code, message: raw, errorCode: c.errorCode)
            XCTAssertEqual(error.plainLine, c.line, c.code)
            XCTAssertEqual(error.localizedDescription, c.line, c.code)
            XCTAssertEqual((error as Error).plainText, c.line, c.code)
            XCTAssertFalse(error.localizedDescription.contains("["), "no code suffix: \(c.code)")
        }
        let gate = APIError(code: "quota_places_exceeded", message: raw, errorCode: "quota_places_exceeded")
        XCTAssertEqual(gate.plainLine, APIError.planLimitText)
        // The message is kept, for logs.
        XCTAssertEqual(APIError(code: "x", message: raw).message, raw)
    }

    /// An invitation the server refused because it already stands is said in
    /// the Android app's words, not as "That didn't work. Please try again."
    /// From the server's own answer, as the invite sheet shows it
    /// (`errorMessage = error.plainText`), and as the request path labels it
    /// (`http_400` with the code).
    func testAnInvitationThatAlreadyStandsIsSaidAsOnAndroid() throws {
        let cases = [
            ("invite_already_exists", "This email already has a pending invite",
             "They already have an invitation to this circle."),
            ("circle_already_member", "This user is already a member of this circle",
             "They're already in this circle."),
        ]
        for (code, said, line) in cases {
            let body = Data(#"{"success":false,"error":"\#(said)","error_code":"\#(code)"}"#.utf8)
            XCTAssertThrowsError(try APIService.decodeResponseBody(body) as EmptyResponse) { error in
                XCTAssertEqual(error.plainText, line, code)
                XCTAssertFalse(error.plainText.contains(said), "never the server's words: \(code)")
            }
            XCTAssertEqual(APIError(code: "http_400", message: said, errorCode: code).plainLine, line, code)
        }
    }

    /// The server's cap on invitation e-mails (a 429 that names it,
    /// `invite_limit_reached`) is said in its own words on both paths, and is
    /// never waited out as throttling: online at once, queued dropped.
    @MainActor
    func testAnInvitationCapIsSaidAndNeverWaitedOut() throws {
        let line = "Too many invitations in the last 24 hours. Try again later."
        XCTAssertEqual(APIError.inviteLimitText, line)
        for calendar in ["today", "tomorrow", "midnight"] {
            XCTAssertFalse(line.localizedCaseInsensitiveContains(calendar), calendar)
        }
        let body = Data(#"{"success":false,"error":"Too many invitations","error_code":"invite_limit_reached"}"#.utf8)
        XCTAssertThrowsError(try APIService.decodeResponseBody(body) as EmptyResponse) { error in
            XCTAssertEqual(error.plainText, line)
        }
        let capped = APIError(code: "http_429", message: raw, errorCode: "invite_limit_reached")
        XCTAssertEqual(capped.plainLine, line, "online, as the 429 path throws it")

        let invite = PendingChanges.make(.invite, account: "e0000000-0000-4000-8000-000000000001",
                                         circleId: "e0000000-0000-4000-8000-0000000000c1",
                                         inputs: .invite(.init(email: "sam@example.com")))
        XCTAssertEqual(PendingChangeRunner.classify(capped, change: invite),
                       .drop(line: "sam@example.com's invitation wasn't done. " + line), "queued: dropped, saying why")
        XCTAssertEqual(PendingChangeRunner.classify(APIError(code: "rate_limited", message: ""), change: invite),
                       .transient(sent: false), "plain throttling still waits")

        let api = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App/Services/APIService.swift"), encoding: .utf8)
        let limited = try XCTUnwrap(api.range(of: "            if httpResponse.statusCode == 429 {\n"))
        let named = try XCTUnwrap(api.range(of: "                   APIError.capsNotWaitedOut.contains(named) {\n"
                                            + "                    throw APIError(code: \"http_429\", message: \"Limit reached\", errorCode: named)\n"))
        let waited = try XCTUnwrap(api.range(of: "                let header = httpResponse.value(forHTTPHeaderField: \"Retry-After\")"))
        XCTAssertLessThan(limited.lowerBound, named.lowerBound)
        XCTAssertLessThan(named.lowerBound, waited.lowerBound, "named before anything is waited out")
    }

    /// The SDK's errors describe themselves with their case and message; what
    /// a person reads is a plain line. This app's own errors keep their words.
    func testTheSDKsErrorTextIsNeverShown() {
        let network = MobileError.NetworkError(message: "gRPC call failed: status: InvalidArgument, message: \"\(raw)\"")
        let key = MobileError.KeyNotFound(message: "no circle key for circle c1 at version 3")
        XCTAssertTrue(network.localizedDescription.contains("at_version"), "the trap: what it would have shown")
        XCTAssertEqual((network as Error).plainText, APIError.unreachableText)
        XCTAssertEqual((key as Error).plainText, APIError.failedText)
        XCTAssertEqual((CircleManager.CircleError.waitingToSync as Error).plainText,
                       CircleManager.CircleError.notDoneWhileWaitingToSync)
        XCTAssertEqual((MemberKeyApprovalError.notSaved("KeyNotFound(message: \"x\")") as Error).plainText,
                       "This phone couldn't save that. Please try again.")
        let offline = URLError(.notConnectedToInternet)
        XCTAssertEqual((offline as Error).plainText, offline.localizedDescription, "the system's words stay")
    }

    /// The App Store refusals, the credit question and the SOS close, in the
    /// app's words.
    func testRefusalsAreSaidInTheAppsWords() {
        let codes = ["apple_family_shared", "apple_transaction_revoked", "apple_wrong_account",
                     "apple_unattributable", "apple_already_expired", "apple_something_new"]
        for code in codes {
            let text = StoreKitManager.refusalText(APIError(code: code, message: raw, errorCode: code))
            XCTAssertFalse(text.contains("at_version"), code)
            XCTAssertFalse(text.isEmpty, code)
        }
        XCTAssertEqual(StoreKitManager.refusalText(APIError(code: "apple_wrong_account", message: raw,
                                                            errorCode: "apple_wrong_account")),
                       "This purchase belongs to a different account.")
        XCTAssertTrue(DeleteAccountSheet.unspentCreditText.hasPrefix("Deleting your account destroys the credit on it"))
        XCTAssertEqual(ActiveSOSCard.closeFailure(APIError(code: "http_500", message: raw)),
                       "Still active — couldn't update your circle. " + APIError.troubleText)
        XCTAssertEqual(InvitesManager.cannotBeUsedText, "This invitation can't be used any more.")
    }

    /// The sweep: nothing on screen reads an APIError's `message` or any
    /// error's `localizedDescription`; what is shown goes through `plainText`
    /// (or `plainLine`). What is left is logs, and two uses that decide or
    /// re-wrap without showing anything.
    func testNoServerTextReachesTheScreen() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let app = root.appendingPathComponent("App")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 50)
        let messageRead = try NSRegularExpression(pattern: #"\b(api|apiError|error|err|e)\.message\b"#)
        let logs = ["print(", "Diag(", "setDiagnostic(", "privacy: .public", "let logged =",
                    "+ \"one that is protecting data"]
        // Read, never shown: compared with the server's own words for "no privacy row yet"
        // (CircleManager.isServersNoPrivacyRow, OnlyTheServersNoRowIsADefaultTests).
        let notShown = ["let message = error.message.lowercased()", "message: error.message,",
                        "&& api.message == noPrivacyRow"]
        var offending: [String] = []
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (i, line) in lines.enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                if code.hasPrefix("//") { continue }
                let reads = messageRead.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
                guard reads || line.contains(".localizedDescription") else { continue }
                let context = (i > 0 ? lines[i - 1] : "") + line
                if logs.contains(where: { context.contains($0) }) || notShown.contains(where: { line.contains($0) }) { continue }
                offending.append("\(file.lastPathComponent):\(i + 1): \(code)")
            }
        }
        XCTAssertEqual(offending, [], "server or SDK text on screen")
    }
}
