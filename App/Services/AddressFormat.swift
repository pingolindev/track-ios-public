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
import struct PingolinTrackSDK.GeocodingResult

/// Row formatting for geocoder results — the iOS counterpart of the Android
/// app's `AddressFormat`.
///
/// WHY THIS IS A SEPARATE, UI-FREE FILE
///   These are pure string/number functions with awkward edges (a Swiss user must
///   not read "CHN" as domestic; 0.09 mi must not render as "0.1 mi"), and they are
///   the exact places the two platforms drift apart. Keeping them out of the View
///   makes them testable without a running app, which is how the Android original is
///   pinned too.
enum AddressFormat {

    // MARK: - Locality line

    /// `isHomeCountryCode`, below: true when `country` is the user's own, in either
    /// alpha-2 ("US") or alpha-3 ("USA") form. The tiles carry whichever the source
    /// data had, so both must resolve. Mirrors the Android app's
    /// `isHomeCountryCode`.
    ///
    /// NOT prefix-matched: "CHN".hasPrefix("CH") is true, and a Swiss user would
    /// otherwise read every Chinese row as domestic, as the Android version also
    /// notes.
    ///
    /// Android normalises via `Locale.Builder().setRegion(h).build().isO3Country`.
    /// Foundation has NO alpha-2 → alpha-3 API: `Locale.Region` has no
    /// `isoCodeAlpha3`, and neither `Locale.region` nor the legacy
    /// `NSLocale.countryCode` returns anything but alpha-2. What ICU DOES do is
    /// resolve both forms to the same region name, so comparing resolved names
    /// normalises without shipping a 249-row table.
    ///
    /// `namedRegion`: a town's region as people read it, or nil. The cities index
    /// holds GeoNames' admin1 CODE, which reads as a state only in the US:
    /// elsewhere it is a number ("04" for Hamburg, "16" for Berlin), and "Hamburg,
    /// 04, DE" says nothing. So a code of digits is left out, everywhere a town is
    /// named (the web and Android alike).
    static func namedRegion(_ admin1: String) -> String? {
        admin1.isEmpty || admin1.allSatisfy(\.isNumber) ? nil : admin1
    }

    static func isHomeCountryCode(_ country: String?, home: String? = nil) -> Bool {
        guard let cc = country?.trimmingCharacters(in: .whitespaces), !cc.isEmpty
        else { return false }
        guard let region = (home ?? Locale.current.region?.identifier), !region.isEmpty
        else { return false }
        if cc.caseInsensitiveCompare(region) == .orderedSame { return true }
        // Only alpha-3 needs the slower route; anything else has already been
        // decided by the exact match above.
        guard cc.count == 3, let a = regionName(cc), let b = regionName(region)
        else { return false }
        return a == b
    }

    /// ISO region code (alpha-2 or alpha-3) → canonical region name, or nil when ICU
    /// does not recognise it. Fixed to en_US_POSIX on purpose: these strings are only
    /// ever compared to each other, never shown, so they must not move with the UI
    /// language. Unrecognised codes return nil rather than collapsing to a shared
    /// placeholder — "QQ"/"ZZZ"/"AAA" are all nil and only the literal "ZZ"
    /// resolves ("Unknown Region"), which can only ever collide with itself.
    private static let namingLocale = Locale(identifier: "en_US_POSIX")
    private static func regionName(_ code: String) -> String? {
        namingLocale.localizedString(forRegionCode: code)
    }

    /// "New York, NY 10118" / "Kreuzberg, Berlin, DEU" — the parts below the street
    /// line. Mirrors the Android app's `GeocodingResult.localityLine()`: the
    /// region and postcode join with a SPACE (they are one postal unit), everything
    /// else with ", ".
    ///
    /// The user's OWN country is omitted: "USA" on every row of a domestic search is
    /// noise, and it costs ~5 characters on a line that also has to hold a city, a
    /// region, a postcode and possibly a distance. Foreign results keep it, because
    /// there it is the most important word on the line.
    ///
    /// `home` exists so tests can pin the device's country; production always passes
    /// nil and gets `Locale.current`.
    static func localityLine(_ r: GeocodingResult, home: String? = nil) -> String {
        let regionAndPostcode = [r.state, r.postcode]
            .compactMap { nonBlank($0) }
            .joined(separator: " ")
        return [
            nonBlank(r.city),
            nonBlank(regionAndPostcode),
            nonBlank(r.country).flatMap { isHomeCountryCode($0, home: home) ? nil : $0 },
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
    }

    /// The whole secondary line for a result row, minus the distance:
    /// `"630 Ventura Blvd Ste 1215 · Camarillo, CA 93010"`.
    ///
    /// TWO RULES, both ported from the Android app's `bindCached`:
    ///
    ///   * **POI rows lead with the street.** Without it several "Pink's Hot
    ///     Dogs" — or several "Togo's" — are indistinguishable at a glance.
    ///     `address` is the POI's own street where known and the nearest address
    ///     in the cell otherwise, so this is exact for most rows and approximate
    ///     for the rest. ADDRESS rows are excluded on purpose: their primary line
    ///     already IS the street.
    ///   * **Drop any locality part that merely repeats the primary line** —
    ///     "Modesto" under "Modesto" is a wasted line.
    static func secondaryLine(
        _ r: GeocodingResult, primary: String, home: String? = nil
    ) -> String {
        let locality = localityLine(r, home: home)
            .components(separatedBy: ", ")
            .filter { part in
                guard let p = nonBlank(part) else { return false }
                return p.caseInsensitiveCompare(primary.trimmingCharacters(in: .whitespaces))
                    != .orderedSame
            }
            .joined(separator: ", ")
        guard r.resultType == "poi", let street = nonBlank(r.address) else { return locality }
        return [street, locality].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private static func nonBlank(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
        return t
    }

    // MARK: - Placard line

    /// The single address line for a map placard — the member callout, the SOS
    /// card, the place sheet — or nil when the row cannot express one.
    ///
    /// Rendering `GeocodingResult.text` raw would make the city and state a
    /// property of WHICH GEOCODER ANSWERED rather than of the address. The SDK's
    /// tile geocoder appends ", City, State" to `text` on a reverse lookup;
    /// ``ServerGeocoder`` deliberately does not — `text` there is the street
    /// alone, so consumers reading the structured fields don't print the
    /// locality twice.
    ///
    /// Differs from ``localityLine(_:home:)`` in two ways, both forced by the
    /// placard:
    ///   * **No postcode.** The callout already carries coordinates, and the
    ///     tiles store the zip float-formatted ("94102.0"), which reads as an
    ///     error.
    ///   * **It will not repeat a locality the head already ends with**, so the
    ///     tile geocoder's baked-in ", City, State" doesn't come out twice.
    ///     Matched segment-wise, not by substring: the tile geocoder's own guard
    ///     is `text.contains(state)`, which silently eats "CA" from a street
    ///     named "Canal Street".
    ///
    /// `withPOIName` is for the one-line placards, where a POI's name is the most
    /// useful thing on the row and has nowhere else to go. The dropped-pin sheet
    /// leaves it false — it renders the name in its own title line, so repeating
    /// it here would print it twice. Mirrors the Android app's `placardAddress()`.
    static func placardAddress(
        _ r: GeocodingResult, withPOIName: Bool = false, home: String? = nil
    ) -> String? {
        let isPOI = r.resultType == "poi"
        // POI rows keep their street in `address`; on an address row `text` IS
        // the street (plus, from the tile geocoder, the locality the dedupe eats).
        let street = nonBlank(isPOI ? r.address : r.text)
        let head = [
            withPOIName && isPOI ? nonBlank(r.name) : nil,
            street,
        ].compactMap { $0 }

        let carried = Set(
            head.flatMap { $0.components(separatedBy: ",") }
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        )
        let locality = [
            nonBlank(r.city),
            nonBlank(r.state),
            nonBlank(r.country).flatMap { isHomeCountryCode($0, home: home) ? nil : $0 },
        ]
        .compactMap { $0 }
        .filter { !carried.contains($0.trimmingCharacters(in: .whitespaces).lowercased()) }

        let line = (head + locality).joined(separator: ", ")
        if !line.isEmpty { return line }
        // Fall back to the raw field rather than to nothing, so a row from a tile
        // too old to carry structured columns still renders. Withheld from a POI
        // when the caller shows the name separately: `text` on a POI row leads
        // with that name, which the title already has.
        return (withPOIName || !isPOI) ? nonBlank(r.text) : nil
    }

    // MARK: - Distance

    private static let kmPerMile = 1.609344

    /// True when this device's locale wants miles.
    ///
    /// Android reads a stored user preference (`sessionManager.useMiles()`); iOS has
    /// no distance-unit setting to read — every other surface uses metric ("100 m",
    /// "5 km" in MapView). Locale is the honest stand-in, and it gives a US device
    /// the same "mi" Android shows there.
    static var useMiles: Bool {
        Locale.current.measurementSystem == .us
    }

    /// "412 ft" / "1.6 mi" / "5385 mi" — matching the Android app's
    /// `formatDistance` tier for tier. Sub-tier values switch UNIT rather than
    /// gaining decimals, because "0.1 mi" reads as a rounding artefact where
    /// "412 ft" reads as a measurement.
    static func distance(km: Double, useMiles: Bool = AddressFormat.useMiles) -> String {
        if useMiles {
            let miles = km / kmPerMile
            if miles < 0.1 { return "\(Int((miles * 5280).rounded())) ft" }
            if miles < 10.0 { return String(format: "%.1f mi", miles) }
            return "\(Int(miles.rounded())) mi"
        }
        if km < 1.0 { return "\(Int((km * 1000).rounded())) m" }
        if km < 10.0 { return String(format: "%.1f km", km) }
        return "\(Int(km.rounded())) km"
    }
}
