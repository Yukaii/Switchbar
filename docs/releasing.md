# Releasing

Releases are built by [`.github/workflows/release.yml`](../.github/workflows/release.yml).
Each release publishes:

| Asset | Contents |
| --- | --- |
| `Switchbar-vX.Y.Z.zip` | Universal `Switchbar.app`, Developer ID–signed, notarized and stapled |
| `Switchbar-vX.Y.Z-universal.tar.gz` | The standalone `Switchbar` binary (signed and notarized), used by the Homebrew formula |
| `checksums.txt` | SHA-256 of both archives |

## Cutting a release

```sh
git tag v1.2.0
git push origin v1.2.0
```

The tag (minus the `v`) becomes `CFBundleShortVersionString`. The commit count
becomes `CFBundleVersion`. The About tab shows both, along with the commit hash.

Then update the Homebrew formula in `Yukaii/homebrew-tap` to the new
`-universal.tar.gz` URL and its checksum from `checksums.txt`.

## Rebuilding an existing version

Run the **Release** workflow manually (Actions → Release → Run workflow) and
enter an existing tag. It builds that tag's sources with the current packaging
scripts and replaces the release's assets. Use this, for example, to re-publish
an older version once signing is set up.

## Signing and notarization secrets

Add these as repository secrets. Without them the workflow still releases, but
the build is ad-hoc signed and the run shows a warning.

| Secret | How to get it |
| --- | --- |
| `DEVELOPER_ID_CERTIFICATE_P12_BASE64` | Export your *Developer ID Application* certificate and private key from Keychain Access as a `.p12`, then `base64 -i cert.p12 \| pbcopy` |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | The password you set when exporting the `.p12` |
| `NOTARY_API_KEY_P8_BASE64` | App Store Connect → Users and Access → Integrations → Team Keys. Create a key with the *Developer* role, download `AuthKey_XXXX.p8`, then `base64 -i AuthKey_XXXX.p8 \| pbcopy` |
| `NOTARY_API_KEY_ID` | The key ID shown next to the key |
| `NOTARY_API_ISSUER_ID` | The issuer ID shown above the key list |

## Building locally

```sh
# Ad-hoc signed, for testing
scripts/build-app.sh
open dist/Switchbar.app

# Signed and notarized
SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" VERSION=1.2.0 scripts/build-app.sh
xcrun notarytool store-credentials switchbar-notary   # one time
NOTARY_KEYCHAIN_PROFILE=switchbar-notary scripts/notarize.sh
```

## Notes

- The executable embeds its Info.plist (`-sectcreate __TEXT __info_plist`), so
  the bare Homebrew binary also reports a bundle identifier and version.
- The bundle identifier is `com.yukaii.Switchbar`. 1.0.x ran without one and
  stored its preferences in the `Switchbar` defaults domain. On first launch,
  Switchbar copies those preferences into the new domain.
- *Launch at login* uses `SMAppService.mainApp`, which needs the `.app` bundle.
  Homebrew users use `brew services` instead.

## Landing page

`site/` is a static page deployed to GitHub Pages by
[`.github/workflows/pages.yml`](../.github/workflows/pages.yml) whenever it
changes on `main`. Set Settings → Pages → Source to **GitHub Actions** once.

To refresh the screenshots, build the app and launch it with
`-showMenu YES` or `-showSettings general|browsers|about`. For example:

```sh
open -n dist/Switchbar.app --args -showSettings browsers -launchAtLogin NO
```
