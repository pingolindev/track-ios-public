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
@testable import Track

/// The sentence under the export passphrase field.
///
/// WHAT IT MUST NOT PROMISE
///   Track for iPhone has no import path at all — no `CFBundleDocumentTypes` in
///   project.yml, no `onOpenURL`, no file picker, nothing in DataExportService
///   that parses the format back. A sentence like "A sealed file opens on any
///   Pingolin app or the website." would be most wrong in the app making it: a
///   user could seal a backup, keep it for a year, and discover on the day they
///   needed it that the app that wrote it cannot read it.
///
///   The other platforms are not equivalent either. The website has a full
///   restore; the Android app restores CONFIGURATION only — not history, and
///   not check-ins (a record of something that happened, not a setting). Only
///   the website is named here, because only the website does the whole job.
///
/// WHAT THIS PINS
///   Not the phrasing. The two claims a user makes a decision on: that this app
///   cannot restore, and that there is somewhere that can.
final class ExportFooterCopyTests: XCTestCase {

    private var notice: String { DataExportView.sealedFileNotice }

    /// The false claim, in the shapes it would come back in.
    func testItDoesNotPromiseThatAnyPingolinAppCanOpenIt() {
        XCTAssertFalse(
            notice.localizedCaseInsensitiveContains("any Pingolin app"),
            "iOS cannot open one at all; got: \(notice)"
        )
        XCTAssertFalse(
            notice.localizedCaseInsensitiveContains("every Pingolin app"),
            "same claim, different word; got: \(notice)"
        )
    }

    /// The fact that replaces it. A user planning a restore has to know this
    /// BEFORE they need the file, not when they try to open it.
    func testItSaysThisAppCannotRestore() {
        XCTAssertTrue(
            notice.localizedCaseInsensitiveContains("cannot read one back in")
                || notice.localizedCaseInsensitiveContains("can't read one back in"),
            "must state that this app has no import path; got: \(notice)"
        )
    }

    /// A limitation with no alternative is a dead end. Name the surface that
    /// does have a full restore.
    func testItNamesWhereARestoreIsPossible() {
        XCTAssertTrue(
            notice.localizedCaseInsensitiveContains("website"),
            "must point at the surface that can restore; got: \(notice)"
        )
    }

    /// The parts that must stay true whatever the wording: the seal is
    /// real, and losing the passphrase is final. This is the only warning the
    /// user gets before choosing an unrecoverable secret.
    func testItKeepsTheUnrecoverableWarning() {
        XCTAssertTrue(
            notice.localizedCaseInsensitiveContains("cannot recover"),
            "the passphrase is unrecoverable and that must keep being said; got: \(notice)"
        )
        XCTAssertTrue(
            notice.localizedCaseInsensitiveContains("sealed"),
            "got: \(notice)"
        )
    }
}
