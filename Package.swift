// swift-tools-version: 5.9
// Copyright (c) 2025 Pingolin LLC
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

import PackageDescription

let package = Package(
    name: "PingolinTrackSDK",
    platforms: [
        .iOS(.v17),
        .macOS(.v12)
    ],
    products: [
        .library(
            name: "PingolinTrackSDK",
            targets: ["PingolinTrackSDK"]),
    ],
    targets: [
        .target(
            name: "PingolinTrackSDK",
            dependencies: ["PingolinMobile"],
            path: "Sources/PingolinTrackSDK",
            // Shipped by the app as a resource (Open Source Licenses), not by
            // this package.
            exclude: ["THIRD_PARTY_LICENSES-mobile-sdk.md"]
        ),
        .binaryTarget(
            name: "PingolinMobile",
            path: "lib/PingolinMobile.xcframework"
        )
    ]
)
