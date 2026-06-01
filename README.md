# macos-release

Shared, reusable release pipeline for signing, notarizing, and publishing macOS apps
to GitHub Releases. Each app repo adds a small caller workflow and **declares its own
Apple team id + secrets**; this repo owns the build-agnostic half:
**sign → notarize → staple → build dmg → sign/notarize/staple dmg → publish**.

## Use it from an app repo

`.github/workflows/release.yml` in the app:

```yaml
on: { push: { tags: ['v*.*.*'] } }
permissions: { contents: write }
jobs:
  release:
    uses: notatestuser/macos-release/.github/workflows/release.yml@v1
    with:
      app-name: "My App"
      team-id: "ABCDE12345"            # this repo's Apple Developer team id
      build-command: "bash build.sh"   # must emit ${app-path}; reads $APP_VERSION/$APP_BUILD/$BUNDLE_ID
      app-path: "My App.app"
      bundle-id: "com.example.myapp"
      dmg-name: "My-App"
      # entitlements: "path/to/App.entitlements"   # optional (sandboxed apps)
      # prerelease: true                            # for v1.0.0-rc.1 etc.
    secrets: inherit
```

Tag and push to release:

```bash
git tag -a v1.0.0 -m "v1.0.0"
git push origin v1.0.0
```

## Inputs

| input | required | meaning |
|---|---|---|
| `app-name` | yes | Display / dmg volume name |
| `team-id` | yes | Apple Developer team id whose Developer ID cert is loaded in this repo's secrets |
| `build-command` | yes | Shell that builds `${app-path}`; gets `$APP_VERSION`, `$APP_BUILD`, `$BUNDLE_ID` |
| `app-path` | yes | Path to the built `.app` after `build-command` |
| `bundle-id` | yes | The app's bundle identifier |
| `dmg-name` | yes | Dmg file stem → `<dmg-name>-v<version>.dmg` |
| `entitlements` | no | Entitlements plist for re-signing (sandboxed apps) |
| `runner` | no | macOS runner label (default `macos-26`) |
| `prerelease` | no | Force pre-release; `-rc`/`-beta` tags are auto-detected anyway |

## Required secrets (per app repo — see docs/RELEASING.md)

`DEVID_CERT_P12_BASE64`, `DEVID_CERT_PASSWORD`, `NOTARY_API_KEY_P8_BASE64`,
`NOTARY_API_KEY_ID`, `NOTARY_API_ISSUER_ID`. Each app repo holds its own copy
(replicate with `gh secret set`, or use org-level secrets if the repos are in an org).

## Local release / dry-run

`scripts/sign-notarize-dmg.sh` runs the same pipeline on a Mac. With no Developer ID
identity it ad-hoc signs and skips notarization (dev build). With the cert installed
and notary env set, it produces a fully notarized dmg — identical to CI.

```bash
APP_PATH="My App.app" APP_NAME="My App" DMG_BASENAME="My-App" VERSION="1.0.0" \
TEAM_ID="ABCDE12345" \
NOTARY_KEY=/path/to/AuthKey_XXXX.p8 NOTARY_KEY_ID=XXXX NOTARY_ISSUER_ID=yyyy-… \
bash scripts/sign-notarize-dmg.sh
```

## Versioning convention

- Git tag `vMAJOR.MINOR.PATCH` is the single source of truth.
- `CFBundleShortVersionString` = semver (tag minus `v`); `CFBundleVersion` = `git rev-list --count HEAD` (monotonic).
- Pre-releases: `v1.0.0-rc.1` → auto-marked pre-release on GitHub.

> The reusable workflow pins its own helper script to `ref: v1`. When changing the
> script, move the `v1` tag (or cut `v2` and bump callers).
