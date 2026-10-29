# Third-party licences

Pingolin Track for iOS is licensed under the GNU General Public License,
version 3 or later (see [LICENSE](LICENSE)). It links the third-party components
below, each under its own licence. Nothing here is vendored into the
repository — Swift Package Manager fetches every entry at the exact revision
pinned in [`project.yml`](project.yml).

| Component | Pinned revision | Licence | Project |
|---|---|---|---|
| Swift-Sodium | `cfd195c7` | ISC | <https://github.com/jedisct1/swift-sodium> |
| MapLibre Native for iOS | `be069600` | BSD-2-Clause | <https://github.com/maplibre/maplibre-gl-native-distribution> |

Swift-Sodium bundles [libsodium](https://github.com/jedisct1/libsodium), which
is ISC-licensed by the same author; its notice is reproduced below alongside the
wrapper's.

## The Pingolin Mobile SDK XCFramework

`lib/PingolinMobile.xcframework` is **not** third-party code and is **not**
committed here — it is Pingolin's own Rust `mobile-sdk`, compiled locally by
[`build-ios.sh`](build-ios.sh) (see the README for how). It does carry its own
tree of transitive Rust dependencies, and those are inventoried in the
`mobile-sdk` repository rather than duplicated here:

- <https://github.com/pingolindev/mobile-sdk-public> — see its `THIRD_PARTY_LICENSES.md`

## How this list was verified

Each licence was taken from the dependency's own repository, not from a
third-party licence database:

- **Swift-Sodium** — `LICENSE` on the `master` branch reads "ISC License /
  Copyright (c) 2014-2026, Frank Denis". GitHub's repository metadata reports
  `spdx_id: ISC`.
- **MapLibre Native for iOS** — `LICENSE.md` on the `main` branch of the
  distribution repository reads "BSD 2-Clause License". GitHub's repository
  metadata reports `spdx_id: BSD-2-Clause`.
- **libsodium** — `LICENSE` on the `master` branch reads "ISC License /
  Copyright (c) 2013-2026 / Frank Denis".

There is currently no in-app licences screen in Settings; this file is the
canonical notice.

---

## Swift-Sodium — ISC

<https://github.com/jedisct1/swift-sodium>

```
ISC License

Copyright (c) 2014-2026, Frank Denis <j at pureftpd dot org>

Permission to use, copy, modify, and/or distribute this software for any
purpose with or without fee is hereby granted, provided that the above
copyright notice and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
```

## libsodium — ISC

<https://github.com/jedisct1/libsodium>

```
ISC License

Copyright (c) 2013-2026
Frank Denis <j at pureftpd dot org>

Permission to use, copy, modify, and/or distribute this software for any
purpose with or without fee is hereby granted, provided that the above
copyright notice and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
```

## MapLibre Native for iOS — BSD-2-Clause

<https://github.com/maplibre/maplibre-gl-native-distribution>

```
BSD 2-Clause License

Copyright (c) 2021 MapLibre contributors

Copyright (c) 2018-2021 MapTiler.com

Copyright (c) 2014-2020 Mapbox

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

* Redistributions of source code must retain the above copyright
  notice, this list of conditions and the following disclaimer.
* Redistributions in binary form must reproduce the above copyright
  notice, this list of conditions and the following disclaimer in
  the documentation and/or other materials provided with the
  distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS
IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR
CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

## Map data and basemap style

The app renders the [Protomaps Basemaps](https://github.com/protomaps/basemaps)
style over map tiles derived from [OpenStreetMap](https://www.openstreetmap.org)
data. OpenStreetMap data is © OpenStreetMap contributors, available under the
[Open Database License](https://www.openstreetmap.org/copyright).

**Attribution is not currently displayed in-app.** `MapLibreMapView` hides both
of MapLibre's built-in credit controls when it creates the map view:

```swift
mapView.logoView.isHidden = true
mapView.attributionButton.isHidden = true
```

and no replacement credit view is drawn elsewhere. Restoring an attribution
surface — either by un-hiding `attributionButton` or by rendering the credit in
the app's own map chrome — is a known follow-up.
