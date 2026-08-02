#!/usr/bin/env bash
#
# Build, Developer ID-sign, notarize and package TickerBar.app into
# dist/tickerbar.zip. The release workflow runs this same script, so a local
# run and a CI run produce the same artifact.
#
# Signing is delegated to xcodebuild rather than a hand-rolled
# `codesign --deep`. TickerBar is sandboxed and its entitlements reference
# $(PRODUCT_BUNDLE_IDENTIFIER) for Sparkle's installer XPC mach-lookup
# exceptions. codesign does not expand build settings, so signing the raw
# .entitlements file by hand bakes in a literal
# "$(PRODUCT_BUNDLE_IDENTIFIER)-spks" and the sandboxed updater cannot reach
# its XPC services. xcodebuild expands it, and signs nested code
# (Sparkle.framework, Updater.app, Installer.xpc, Downloader.xpc) inside-out
# with each target's own entitlements.
#
# Configuration, all via environment:
#   VERSION          release version, e.g. 1.5.0 (default: read from Info.plist)
#   APP_IDENTITY     "Developer ID Application: NAME (TEAMID)"
#   TEAM_ID          Apple Developer team id (default: parsed from APP_IDENTITY)
#   NOTARY_PROFILE   notarytool keychain profile (default: tickerbar-notary)
#   SKIP_NOTARIZE=1  build and sign, but do not notarize (local testing)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

INFO_PLIST="$ROOT/TickerBar/Info.plist"
VERSION="${VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")}"
APP_IDENTITY="${APP_IDENTITY:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-tickerbar-notary}"

BUILD="$ROOT/build"
DIST="$ROOT/dist"
ARCHIVE="$BUILD/TickerBar.xcarchive"
APP="$DIST/TickerBar.app"
ZIP="$DIST/tickerbar.zip"

step() { printf '\n\033[1;34m==>\033[0m %s\n' "$1"; }

if [[ -z "$APP_IDENTITY" ]]; then
  echo "APP_IDENTITY is unset." >&2
  echo "Set it to your Developer ID Application identity, e.g.:" >&2
  echo '  APP_IDENTITY="Developer ID Application: Your Name (TEAMID)"' >&2
  echo "List what you have with: security find-identity -v -p codesigning" >&2
  exit 1
fi

# "Developer ID Application: Name (TEAMID)" -> TEAMID
TEAM_ID="${TEAM_ID:-$(sed -n 's/.*(\([A-Z0-9]*\))$/\1/p' <<<"$APP_IDENTITY")}"
if [[ -z "$TEAM_ID" ]]; then
  echo "TEAM_ID is unset and could not be parsed from APP_IDENTITY." >&2
  exit 1
fi

step "Stamping version $VERSION"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$INFO_PLIST"

step "Archiving (Developer ID, hardened runtime)"
rm -rf "$ARCHIVE" "$DIST"
xcodebuild archive \
  -project TickerBar.xcodeproj \
  -scheme TickerBar \
  -configuration Release \
  -derivedDataPath "$BUILD" \
  -archivePath "$ARCHIVE" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$APP_IDENTITY" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  PROVISIONING_PROFILE_SPECIFIER= \
  OTHER_CODE_SIGN_FLAGS=--timestamp

step "Exporting app"
EXPORT_OPTIONS="$(mktemp -t tickerbar-export).plist"
cat > "$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>manual</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
</dict>
</plist>
PLIST
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$DIST" \
  -exportOptionsPlist "$EXPORT_OPTIONS"
rm -f "$EXPORT_OPTIONS"
codesign --verify --deep --strict --verbose=2 "$APP"

if [[ "${SKIP_NOTARIZE:-}" == "1" ]]; then
  step "Skipping notarization (SKIP_NOTARIZE=1)"
  echo "WARNING: not notarized, local testing only. Gatekeeper will complain." >&2
else
  step "Notarizing"
  ditto -c -k --keepParent "$APP" "$DIST/notarize.zip"
  xcrun notarytool submit "$DIST/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
  rm -f "$DIST/notarize.zip"

  step "Stapling"
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  # Must report "source=Notarized Developer ID". Anything else means users get
  # a Gatekeeper prompt, so fail here rather than ship it.
  spctl --assess --type exec --verbose=4 "$APP"
fi

step "Packaging"
ditto -c -k --keepParent "$APP" "$ZIP"

step "Done"
echo "App: $APP"
echo "Zip: $ZIP"
echo "SHA256: $(shasum -a 256 "$ZIP" | awk '{print $1}')"
