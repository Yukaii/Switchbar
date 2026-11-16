#!/usr/bin/env bash
# Notarizes dist/Switchbar.app and dist/Switchbar in one submission, then
# staples the ticket to the app. Run scripts/build-app.sh with a Developer ID
# SIGNING_IDENTITY first.
#
# Authenticate with ONE of:
#   App Store Connect API key (CI):
#     NOTARY_KEY_PATH   path to AuthKey_XXXXXXXXXX.p8
#     NOTARY_KEY_ID     key ID
#     NOTARY_ISSUER_ID  issuer UUID
#   Stored keychain profile (local, see `xcrun notarytool store-credentials`):
#     NOTARY_KEYCHAIN_PROFILE
#
# The standalone binary cannot be stapled (only bundles, disk images and
# packages can), but once notarized Gatekeeper finds its ticket online.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${DIST_DIR:-$ROOT/dist}"
app="$DIST_DIR/Switchbar.app"
binary="$DIST_DIR/Switchbar"

[[ -d "$app" && -f "$binary" ]] || { echo "error: run scripts/build-app.sh first" >&2; exit 1; }

if [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
  auth=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
elif [[ -n "${NOTARY_KEY_PATH:-}" && -n "${NOTARY_KEY_ID:-}" && -n "${NOTARY_ISSUER_ID:-}" ]]; then
  auth=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
else
  echo "error: set NOTARY_KEYCHAIN_PROFILE, or NOTARY_KEY_PATH + NOTARY_KEY_ID + NOTARY_ISSUER_ID" >&2
  exit 1
fi

if codesign -dv "$app" 2>&1 | grep -q "Signature=adhoc"; then
  echo "error: $app is ad-hoc signed; rebuild with a Developer ID SIGNING_IDENTITY" >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

mkdir "$work/payload"
ditto "$app" "$work/payload/Switchbar.app"
cp "$binary" "$work/payload/Switchbar"
ditto -c -k --sequesterRsrc "$work/payload" "$work/submission.zip"

echo "==> Submitting to Apple notary service (this usually takes a few minutes)"
xcrun notarytool submit "$work/submission.zip" "${auth[@]}" \
  --wait --timeout 30m --output-format json | tee "$work/result.json"
echo

status="$(plutil -extract status raw -o - "$work/result.json")"
submission_id="$(plutil -extract id raw -o - "$work/result.json")"

if [[ "$status" != "Accepted" ]]; then
  echo "error: notarization finished with status '$status'; log follows" >&2
  xcrun notarytool log "$submission_id" "${auth[@]}" >&2 || true
  exit 1
fi

echo "==> Stapling"
xcrun stapler staple "$app"
xcrun stapler validate "$app"

echo "==> Gatekeeper assessment"
spctl --assess --type execute --verbose=2 "$app"

echo "==> Notarized: $app (submission $submission_id)"
