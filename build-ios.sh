#!/bin/bash
# Copyright (c) 2026 Pingolin LLC
#
# This file is part of Pingolin Track.
#
# Pingolin Track is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Pingolin Track is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Pingolin Track. If not, see <https://www.gnu.org/licenses/>.

# Builds the Pingolin Mobile SDK for iOS (device + simulator)
# and packages it as an XCFramework inside lib/.
#
# Requires:
#   - Xcode installed (full Xcode, not just CLT)
#   - rustup with aarch64-apple-ios, aarch64-apple-ios-sim, x86_64-apple-ios targets
#   - protoc on PATH (brew install protobuf)
#   - $MOBILE_SDK_SRC pointing at the track mobile-sdk Rust crate

set -euo pipefail

if [[ -z "${MOBILE_SDK_SRC:-}" ]]; then
  echo "error: MOBILE_SDK_SRC is required — set it to the path of the track mobile-sdk Rust crate." >&2
  exit 64
fi
if [[ ! -d "$MOBILE_SDK_SRC" ]]; then
  echo "error: MOBILE_SDK_SRC=$MOBILE_SDK_SRC not found." >&2
  exit 66
fi

# The SDK's inventory of the third-party crates linked into the framework. It is
# copied next to the bindings at the end, because the app shows it under
# Settings → About → Open Source Licenses: most of those licences require their
# notices to ship with the binary. Resolved before any cd, since MOBILE_SDK_SRC
# may be a relative path.
SDK_LICENSES="$(cd "$MOBILE_SDK_SRC/../.." && pwd)/THIRD_PARTY_LICENSES.md"
if [[ ! -f "$SDK_LICENSES" ]]; then
  echo "error: $SDK_LICENSES not found — MOBILE_SDK_SRC must be the crate inside a mobile-sdk checkout." >&2
  exit 66
fi

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
STAGING="${STAGING:-$HOME/staging}"
DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-15.0}"

export IPHONEOS_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
export PATH="/opt/homebrew/bin:$HOME/.cargo/bin:$PATH"

echo "=> Building mobile-sdk for iOS (deployment target: $DEPLOYMENT_TARGET)"
echo "   Source: $MOBILE_SDK_SRC"
echo "   Staging: $STAGING"

cd "$MOBILE_SDK_SRC"

for TARGET in aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios; do
  echo "==> cargo build --release --target $TARGET"
  cargo build --release --target "$TARGET"
done

echo "==> Building uniffi-bindgen"
cargo build --release --features bindgen --bin uniffi-bindgen

mkdir -p "$STAGING/ios-bindings" "$STAGING/ios-simulator" "$STAGING/xcframework-headers"

echo "==> Lipo simulator slices (arm64 + x86_64)"
lipo -create \
  target/aarch64-apple-ios-sim/release/libpingolin_mobile.a \
  target/x86_64-apple-ios/release/libpingolin_mobile.a \
  -output "$STAGING/ios-simulator/libpingolin_mobile.a"

echo "==> Generating Swift bindings via uniffi-bindgen"
./target/release/uniffi-bindgen generate \
  --library target/aarch64-apple-ios/release/libpingolin_mobile.dylib \
  --language swift \
  --out-dir "$STAGING/ios-bindings"

cp "$STAGING/ios-bindings/pingolin_mobileFFI.h" "$STAGING/xcframework-headers/"

echo "==> Assembling PingolinMobile.xcframework"
rm -rf "$STAGING/PingolinMobile.xcframework"
xcodebuild -create-xcframework \
  -library target/aarch64-apple-ios/release/libpingolin_mobile.a \
  -headers "$STAGING/xcframework-headers" \
  -library "$STAGING/ios-simulator/libpingolin_mobile.a" \
  -headers "$STAGING/xcframework-headers" \
  -output "$STAGING/PingolinMobile.xcframework"

echo "==> Installing into track-ios"
cd "$SCRIPT_DIR"
rm -rf lib/PingolinMobile.xcframework lib/libpingolin_mobile.a
mkdir -p lib
cp -r "$STAGING/PingolinMobile.xcframework" lib/

# Overwrite xcodebuild's default 'framework module PingolinMobileFFI' modulemap
# with uniffi-bindgen's 'module pingolin_mobileFFI' so generated Swift bindings
# resolve the checksum symbols.
for slice in lib/PingolinMobile.xcframework/*/Headers; do
  cp "$STAGING/ios-bindings/pingolin_mobileFFI.modulemap" "$slice/module.modulemap"
done
cp "$STAGING/ios-bindings/pingolin_mobile.swift" Sources/PingolinTrackSDK/pingolin_mobile.swift
cp "$STAGING/ios-bindings/pingolin_mobileFFI.h" Sources/PingolinTrackSDK/pingolin_mobileFFI.h
cp "$STAGING/ios-bindings/pingolin_mobileFFI.modulemap" Sources/PingolinTrackSDK/module.modulemap
cp "$SDK_LICENSES" Sources/PingolinTrackSDK/THIRD_PARTY_LICENSES-mobile-sdk.md

echo "=> Done. XCFramework at lib/PingolinMobile.xcframework"
