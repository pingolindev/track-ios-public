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

/// Where the map's vector tiles come from, and the one lever that can move them.
///
/// Tiles are served `Cache-Control: immutable, max-age=31536000`, so a tile a
/// device has cached can outlive a rebuild by a YEAR, and no CDN purge reaches a
/// device's own HTTP cache. A version segment hardcoded in the app would leave a
/// bad tile build stuck until an app-store release shipped a new literal.
///
/// So the backend serves the whole template at `GET /api/config`
/// (`map.pmtiles.tileTemplate`), and bumping the prefix server-side hands every
/// client a fresh cache namespace on its next launch. The tile server accepts
/// any `/tiles/v<N>/` and serves the same archive, so a device that never picks
/// up a new template keeps rendering correctly — it just does not get the bust.
/// Nothing breaks on a stale client; that is what makes the lever safe to pull
/// while old builds are still in use.
enum MapTileConfig {

    /// Shipped fallback: the prefix the server serves, so a device that has
    /// never reached `/api/config` still renders the current tiles.
    static let defaultTileTemplate = "https://pmtiles.pingolin.com/tiles/v4/{z}/{x}/{y}.mvt"

    private static let storageKey = "map.pmtiles.tileTemplate"

    /// The template to render with: server value if one has ever been stored,
    /// otherwise the shipped literal.
    static var tileTemplate: String {
        UserDefaults.standard.string(forKey: storageKey) ?? defaultTileTemplate
    }

    /// Fetch `/api/config` and persist the template if it carries one.
    ///
    /// Deliberately forgiving — this must never be able to break the map:
    ///   * a nil/absent `tileTemplate` (an older backend) leaves the stored value
    ///     ALONE rather than clearing it, so a bump that already landed is not
    ///     silently rolled back to the compiled-in v4 literal;
    ///   * any network or decode failure is ignored, and `tileTemplate` keeps
    ///     returning the last good value or the fallback.
    ///
    /// `/api/config` is a public route, so this needs no session and can run
    /// before sign-in.
    static func refresh(apiBaseURL: String) async {
        guard let url = URL(string: apiBaseURL + "/api/config") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        guard let (data, response) = try? await TrustBlocklist.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let decoded = try? JSONDecoder().decode(AppConfigResponse.self, from: data),
              let template = decoded.map?.pmtiles?.tileTemplate,
              !template.isEmpty
        else { return }

        UserDefaults.standard.set(template, forKey: storageKey)
    }
}

// MARK: - Wire format

/// Mirrors the response of `GET /api/config`.
///
/// Every field is optional: this is a public, evolving config document, and a
/// decode failure here must not cost the app its map.
private struct AppConfigResponse: Decodable {
    let map: MapSection?

    struct MapSection: Decodable {
        let pmtiles: PMTilesSection?
    }

    struct PMTilesSection: Decodable {
        let tilesUrl: String?
        let lightStyle: String?
        let darkStyle: String?
        /// Absent on an older backend — hence the fallback above.
        let tileTemplate: String?
    }
}
