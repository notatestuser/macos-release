#!/usr/bin/env bash
# sign-notarize-dmg.sh — stack-agnostic macOS release packager.
# Takes an already-built .app and: signs (Developer ID + hardened runtime),
# notarizes, staples, builds a .dmg, signs/notarizes/staples the dmg, verifies.
# Runs identically in CI and locally. With no Developer ID identity present it
# falls back to ad-hoc signing and skips notarization (local dev builds).
#
# Required env:
#   APP_PATH        path to the built .app (e.g. "My App.app")
#   APP_NAME        display/volume name   (e.g. "My App")
#   DMG_BASENAME    dmg file stem         (e.g. "My-App" -> My-App-v1.0.0.dmg)
#   VERSION         semver, no leading v  (e.g. "1.0.0")
# Optional env:
#   ENTITLEMENTS    path to a .entitlements plist applied to the main app
#   TEAM_ID         Apple team id — picks the Developer ID identity when several exist
#                   (empty = first "Developer ID Application" found in the keychain)
#   DEVID_IDENTITY  explicit codesign identity string (overrides discovery)
#   OUT_DIR         where the .dmg is written                                  [cwd]
#   NOTARY_PROFILE  a stored `notarytool store-credentials` keychain profile name
#                   (preferred locally; overrides the NOTARY_KEY trio below)
#   NOTARY_KEY      path to App Store Connect API key .p8
#   NOTARY_KEY_ID   API key id
#   NOTARY_ISSUER_ID  API issuer id
set -euo pipefail

APP_PATH="${APP_PATH:?set APP_PATH}"
APP_NAME="${APP_NAME:?set APP_NAME}"
DMG_BASENAME="${DMG_BASENAME:?set DMG_BASENAME}"
VERSION="${VERSION:?set VERSION}"
ENTITLEMENTS="${ENTITLEMENTS:-}"
TEAM_ID="${TEAM_ID:-}"
OUT_DIR="${OUT_DIR:-$PWD}"
DMG_PATH="$OUT_DIR/${DMG_BASENAME}-v${VERSION}.dmg"

log() { printf '\033[1;34m→ %s\033[0m\n' "$*"; }
die() { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

[ -d "$APP_PATH" ] || die "APP_PATH not found: $APP_PATH"

# ── Resolve signing identity ────────────────────────────────────────────────
IDENTITY="${DEVID_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' -v team="($TEAM_ID)" '/Developer ID Application/ && index($0, team){print $2; exit}')"
fi
if [ -z "$IDENTITY" ]; then
  # any Developer ID Application identity, regardless of team
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Developer ID Application/{print $2; exit}')"
fi

NOTARIZE=1
if [ -z "$IDENTITY" ]; then
  log "No Developer ID Application identity found — AD-HOC signing, skipping notarization (local dev build)."
  IDENTITY="-"
  NOTARIZE=0
fi
# Notary auth: a stored keychain profile (NOTARY_PROFILE) OR an App Store Connect
# API key trio (NOTARY_KEY + NOTARY_KEY_ID + NOTARY_ISSUER_ID).
NOTARY_AUTH=()
if [ -n "${NOTARY_PROFILE:-}" ]; then
  NOTARY_AUTH=(--keychain-profile "$NOTARY_PROFILE")
elif [ -n "${NOTARY_KEY:-}" ] && [ -n "${NOTARY_KEY_ID:-}" ] && [ -n "${NOTARY_ISSUER_ID:-}" ]; then
  NOTARY_AUTH=(--key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
fi
if [ "${#NOTARY_AUTH[@]}" -eq 0 ]; then
  [ "$NOTARIZE" = 1 ] && log "Notary credentials not set — signing only, skipping notarization."
  NOTARIZE=0
fi
log "Identity: $IDENTITY  | notarize: $NOTARIZE  | version: $VERSION"

CODESIGN_OPTS=(--force --timestamp --options runtime)
[ "$IDENTITY" = "-" ] && CODESIGN_OPTS=(--force)   # ad-hoc: no timestamp/runtime

# ── 1. Sign nested code inside-out, then the app ────────────────────────────
# Sign every nested Mach-O (helper executables, dylibs, .so, embedded plugin
# binaries) and every nested code bundle (.framework/.app/.xpc/.bundle),
# deepest path first, so the main bundle is sealed last. Apps that embed helper
# binaries (e.g. embedded plugins) FAIL notarization if any nested
# executable is unsigned — a blanket "sign frameworks only" pass is not enough.
log "Signing nested code (all Mach-O, deepest first)…"
sign_one() { codesign "${CODESIGN_OPTS[@]}" --sign "$IDENTITY" "$1"; }

# 1a. loose Mach-O files (executables, dylibs, plugins) — deepest first
while IFS= read -r f; do
  [ -n "$f" ] && sign_one "$f"
done < <(
  find "$APP_PATH/Contents" -type f -print0 \
  | while IFS= read -r -d '' f; do
      if file -b "$f" 2>/dev/null | grep -q "Mach-O"; then
        depth="$(printf '%s' "$f" | tr -cd '/' | wc -c | tr -d ' ')"
        printf '%s\t%s\n' "$depth" "$f"
      fi
    done | sort -rn | cut -f2-
)

# 1b. nested code bundles — deepest first (skip the top-level app itself)
while IFS= read -r -d '' b; do
  [ "$b" = "$APP_PATH" ] && continue
  sign_one "$b"
done < <(find "$APP_PATH/Contents" -depth -type d \
           \( -name "*.framework" -o -name "*.app" -o -name "*.xpc" -o -name "*.bundle" \) -print0 2>/dev/null)

log "Signing main bundle…"
ENT_ARGS=()
[ -n "$ENTITLEMENTS" ] && { [ -f "$ENTITLEMENTS" ] || die "entitlements not found: $ENTITLEMENTS"; ENT_ARGS=(--entitlements "$ENTITLEMENTS"); }
codesign "${CODESIGN_OPTS[@]}" ${ENT_ARGS[@]+"${ENT_ARGS[@]}"} --sign "$IDENTITY" "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

# ── 2. Notarize + staple the app ────────────────────────────────────────────
if [ "$NOTARIZE" = 1 ]; then
  WORK="$(mktemp -d)"
  log "Zipping app for notarization…"
  ditto -c -k --keepParent "$APP_PATH" "$WORK/app.zip"
  log "Submitting app to notary service (waits for result)…"
  xcrun notarytool submit "$WORK/app.zip" ${NOTARY_AUTH[@]+"${NOTARY_AUTH[@]}"} --wait \
    || die "App notarization failed (see log above; 'notarytool log <id>' for detail)."
  log "Stapling app…"
  xcrun stapler staple "$APP_PATH"
  rm -rf "$WORK"
fi

# ── 3. Build the DMG ────────────────────────────────────────────────────────
log "Building DMG: $DMG_PATH"
mkdir -p "$OUT_DIR"
rm -f "$DMG_PATH"
STAGING="$(mktemp -d)"
cp -R "$APP_PATH" "$STAGING/"
if command -v create-dmg >/dev/null 2>&1; then
  # create-dmg (Homebrew, create-dmg/create-dmg). Exit 2 = made dmg but couldn't
  # set every cosmetic; treat as success if the file exists.
  create-dmg \
    --volname "$APP_NAME" \
    --window-size 600 400 \
    --icon-size 110 \
    --icon "$(basename "$APP_PATH")" 150 190 \
    --app-drop-link 450 190 \
    --no-internet-enable \
    "$DMG_PATH" "$STAGING" || true
  [ -f "$DMG_PATH" ] || die "create-dmg did not produce $DMG_PATH"
else
  log "create-dmg not installed; using hdiutil."
  ln -s /Applications "$STAGING/Applications"
  hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG_PATH"
fi
rm -rf "$STAGING"

# ── 4. Sign + notarize + staple the DMG ─────────────────────────────────────
if [ "$IDENTITY" != "-" ]; then
  log "Signing DMG…"
  codesign --force --timestamp --sign "$IDENTITY" "$DMG_PATH"
fi
if [ "$NOTARIZE" = 1 ]; then
  log "Submitting DMG to notary service…"
  xcrun notarytool submit "$DMG_PATH" ${NOTARY_AUTH[@]+"${NOTARY_AUTH[@]}"} --wait \
    || die "DMG notarization failed."
  log "Stapling DMG…"
  xcrun stapler staple "$DMG_PATH"
fi

# ── 5. Verify ───────────────────────────────────────────────────────────────
log "Verifying…"
if [ "$NOTARIZE" = 1 ]; then
  xcrun stapler validate "$DMG_PATH" || die "stapler validate failed."
  spctl -a -t open --context context:primary-signature -vv "$DMG_PATH" \
    || die "spctl assessment failed — Gatekeeper would reject this dmg."
  log "PASS — notarized, stapled, Gatekeeper-clean: $DMG_PATH"
else
  log "DONE (unsigned/ad-hoc, NOT notarized): $DMG_PATH"
fi

# Emit path for CI consumption
[ -n "${GITHUB_OUTPUT:-}" ] && echo "dmg=$DMG_PATH" >> "$GITHUB_OUTPUT"
echo "$DMG_PATH"
