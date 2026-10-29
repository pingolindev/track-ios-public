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

import SafariServices
import SwiftUI
import UIKit

/// Account pages open inside the app, in Safari's own view controller, instead
/// of switching to the Safari app.
///
/// App Review Guideline 4 does not accept an app where "the user is taken to
/// the default web browser to sign in or register for an account". Every
/// account page the app links to (Sign Up, Forgot password, the recovery email,
/// two-factor, the pre-reset data) is one where people register or sign in.
/// SFSafariViewController is the presentation Apple names for this: it shows
/// the page's address and lets people check its certificate, keeps Safari's
/// password AutoFill and passkeys, and gives the page no access to the app.
///
/// Only account pages, and each one marked `in_app=1`. The app cannot steer
/// this browser, and a signed-in account page links to Subscription (Paddle)
/// and Payment (crypto top-up): ways to pay that are not Apple's, which must
/// not be reachable inside the app. The account site hides both in a tab that
/// arrived with the marker. Any other page, the legal ones included, still
/// opens in the Safari app: the website's pages link to the account site
/// without the marker, so they must not open in here.
///
/// Installed once at the root as the `openURL` action, so every `Link` in the
/// app comes here, sheets included.
@MainActor
enum InAppSafari {
    /// The query item the account site reads to hide billing.
    nonisolated static let marker = URLQueryItem(name: "in_app", value: "1")

    /// Whether `url` is an account page of this build's environment, the only
    /// pages this opens.
    nonisolated static func opensInApp(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host?.lowercased(),
              let account = URL(string: AppConfiguration.shared.accountBaseURL),
              let accountHost = account.host?.lowercased()
        else { return false }
        return host == accountHost && url.port == account.port
    }

    /// `url` with the marker added, everything else in it kept (path, other
    /// query items as they were encoded, the fragment); unchanged if it
    /// already carries it. `percentEncoded…`: `queryItems` would decode and
    /// re-encode the rest of the query, and `%2F` would come back as `/`.
    nonisolated static func marked(_ url: URL) -> URL {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = parts.percentEncodedQueryItems ?? []
        if items.contains(where: { $0.name == marker.name }) { return url }
        items.append(marker)
        parts.percentEncodedQueryItems = items
        return parts.url ?? url
    }

    /// Present `url`, marked, over whatever is on screen. False when it isn't
    /// an account page or there is nothing to present from; the caller then
    /// hands the URL to the system.
    @discardableResult
    static func present(_ url: URL) -> Bool {
        guard opensInApp(url), let top = topViewController() else { return false }
        // A second tap while the first page is still sliding in would stack
        // another browser on top of it.
        if top is SFSafariViewController { return true }
        let page = SFSafariViewController(url: marked(url))
        // Over the app, never in its place: a full-screen
        // presentation takes the root view out of the window, a
        // view out of the window hears no scene phase, and App Lock
        // would then not lock while a page is open, nor after it
        // closes.
        page.modalPresentationStyle = .overFullScreen
        top.present(page, animated: true)
        return true
    }

    /// The controller everything else is under: the key window's root, then
    /// down through whatever it presents (a sheet, an alert's host).
    private static func topViewController() -> UIViewController? {
        let window = UIApplication.shared
            .connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
        var top = window?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }

    /// App Lock: an open page sits above every screen, the lock
    /// included (it is presented over the root, not by a view the lock
    /// replaces), so it closes as Track locks, with anything over it. Any
    /// window: going to the background, none is key.
    static func closeForLock() {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        for window in windows {
            var controller = window.rootViewController
            while let presented = controller?.presentedViewController {
                if presented is SFSafariViewController {
                    presented.presentingViewController?.dismiss(animated: false)
                    break
                }
                controller = presented
            }
        }
    }
}

extension View {
    /// Open this view's account-page links with `InAppSafari`; any other link
    /// goes to the system.
    func opensWebLinksInApp() -> some View {
        environment(\.openURL, OpenURLAction { url in
            InAppSafari.present(url) ? .handled : .systemAction
        })
    }
}
