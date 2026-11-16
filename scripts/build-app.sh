#!/usr/bin/env bash
# Builds a universal Switchbar.app and a matching standalone binary into dist/.
#
#   scripts/build-app.sh
#
# Environment (all optional):
#   VERSION           CFBundleShortVersionString. Default: latest git tag without
#                     the leading "v", or 0.0.0 when there are no tags.
#   BUILD_NUMBER      CFBundleVersion. Default: commit count of HEAD.
#   SIGNING_IDENTITY  codesign identity (name or SHA-1). Default "-" (ad-hoc).
#                     A real Developer ID identity enables the hardened runtime
#                     and secure timestamp that notarization requires.
#   SOURCE_DIR        Swift package to build. Default: this repository. CI sets it
#                     to rebuild an older tag with the current packaging scripts.
#   ARCHS             Architectures to build. Default: "arm64 x86_64".
#   DIST_DIR          Output directory. Default: <repo>/dist (recreated).
#
# Outputs:
#   dist/Switchbar.app   the app bundle (LSUIElement menu bar app)
#   dist/Switchbar       the same universal binary, signed standalone, for the
#                        Homebrew formula. It has the Info.plist embedded in its
#                        __TEXT,__info_plist section so it reports its version too.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_DIR="${SOURCE_DIR:-$ROOT}"
DIST_DIR="${DIST_DIR:-$ROOT/dist}"
ARCHS="${ARCHS:-arm64 x86_64}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
BUNDLE_IDENTIFIER="com.yukaii.Switchbar"

if [[ -z "${VERSION:-}" ]]; then
  latest_tag="$(git -C "$SOURCE_DIR" describe --tags --abbrev=0 2>/dev/null || true)"
  VERSION="${latest_tag#v}"
  VERSION="${VERSION:-0.0.0}"
fi
VERSION="${VERSION#v}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git -C "$SOURCE_DIR" rev-list --count HEAD 2>/dev/null || echo 1)}"
GIT_COMMIT="$(git -C "$SOURCE_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"

if [[ ! "$VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
  echo "error: VERSION must look like 1.2.3 (got '$VERSION')" >&2
  exit 1
fi

echo "==> Building Switchbar $VERSION ($BUILD_NUMBER) from $SOURCE_DIR"
echo "    commit:   $GIT_COMMIT"
echo "    archs:    $ARCHS"
echo "    identity: $SIGNING_IDENTITY"

rm -rf "$DIST_DIR"
work="$DIST_DIR/.work"
mkdir -p "$work"

# --- Info.plist --------------------------------------------------------------
plist="$work/Info.plist"
sed \
  -e "s/__BUNDLE_IDENTIFIER__/$BUNDLE_IDENTIFIER/" \
  -e "s/__VERSION__/$VERSION/" \
  -e "s/__BUILD_NUMBER__/$BUILD_NUMBER/" \
  -e "s/__GIT_COMMIT__/$GIT_COMMIT/" \
  "$ROOT/Resources/Info.plist" > "$plist"
plutil -lint "$plist" >/dev/null

# --- Compile each architecture, then merge -----------------------------------
binaries=()
for arch in $ARCHS; do
  # A scratch path per arch: newer SwiftPM build systems put every single-arch
  # build in the same products directory, so builds would overwrite each other.
  build_args=(--package-path "$SOURCE_DIR" --scratch-path "$SOURCE_DIR/.build/dist-$arch" -c release --arch "$arch")
  bin_path="$(swift build "${build_args[@]}" --show-bin-path)"
  # The embedded plist is not a tracked build input, so force a relink to pick
  # up a changed version number.
  rm -f "$bin_path/Switchbar"
  echo "==> swift build ($arch)"
  swift build "${build_args[@]}" \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$plist"
  binaries+=("$bin_path/Switchbar")
done
lipo -create -output "$work/Switchbar" "${binaries[@]}"
lipo -info "$work/Switchbar"

# --- Icon --------------------------------------------------------------------
echo "==> Rendering icon"
swift "$ROOT/scripts/generate-icon.swift" "$work/AppIcon.iconset" >/dev/null
iconutil -c icns "$work/AppIcon.iconset" -o "$work/AppIcon.icns"

# --- Assemble the bundle -----------------------------------------------------
app="$DIST_DIR/Switchbar.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$plist" "$app/Contents/Info.plist"
printf 'APPL????' > "$app/Contents/PkgInfo"
cp "$work/Switchbar" "$app/Contents/MacOS/Switchbar"
cp "$work/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
cp "$work/Switchbar" "$DIST_DIR/Switchbar"

# --- Sign --------------------------------------------------------------------
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
  echo "==> Signing ad-hoc (not distributable; set SIGNING_IDENTITY for Developer ID)"
  sign_args=(--force --sign -)
else
  echo "==> Signing with Developer ID"
  sign_args=(--force --options runtime --timestamp --sign "$SIGNING_IDENTITY")
fi
codesign "${sign_args[@]}" --identifier "$BUNDLE_IDENTIFIER" "$DIST_DIR/Switchbar"
codesign "${sign_args[@]}" "$app"

codesign --verify --strict --verbose=2 "$app"
codesign --verify --strict --verbose=2 "$DIST_DIR/Switchbar"

rm -rf "$work"
echo "==> Done: $app"
