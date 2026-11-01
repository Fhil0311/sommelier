#!/usr/bin/env bash
# Copyright 2026 the Sommelier project.
# SPDX-License-Identifier: GPL-3.0-or-later
# Publishes an app update: builds Sommelier, zips it, signs the zip with the update key (scripts/update-signing-key.swift),
# adds it to the appcast and uploads both to the API's release storage (R2 bucket "sommelier-releases").
#
#   scripts/release-app.sh VERSION BUILD [NOTES.html]
#
# VERSION is what people see ("0.2.0"); BUILD is a whole number that grows with every release (Sparkle compares it).
# Env:
#   TARGET=local|remote   where to upload (default local: the bucket `wrangler dev` uses on this Mac)
#   CONFIG=Release|Debug  build configuration (default Release)
#   FEED_URL              appcast URL baked into the build (default: the configuration's SOMMELIER_UPDATE_FEED_URL)
#   CRITICAL=1            the update can't be put off (security fixes, broken compatibility): no "Later" in the app
#   DOWNLOAD_BASE         where archives are served (default https://api.playsommelier.com/v1/releases;
#                         http://127.0.0.1:8788/v1/releases when TARGET=local)
#   SIGN_IDENTITY         the Developer ID certificate (default: the one "Developer ID Application" in the keychain)
#   NOTARY_PROFILE        notarytool's saved credentials (default sommeliery; `xcrun notarytool store-credentials`)
#   ALLOW_UNSIGNED=1      publish remotely without a Developer ID (macOS warns everyone who opens it)
#   NOTARY_SUBMISSION=ID  carry on with an app that is already built, signed and sent to Apple (a first submission
#                         can take many hours, and a run that waited for it may have been cut off): no new build, no
#                         new submission, it waits for that one, staples the ticket and goes on
# With a Developer ID the app is signed with it (hardened runtime, App/Sommelier/Sommelier.entitlements), sent to
# Apple's notary service and stapled, and so is the disk image: macOS opens both without a warning.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?VERSION}"; BUILD="${2:?BUILD}"; NOTES="${3:-}"
[[ "$BUILD" =~ ^[0-9]+$ ]] || { echo "BUILD must be a whole number" >&2; exit 1; }
TARGET="${TARGET:-local}"; CONFIG="${CONFIG:-Release}"
if [ "$TARGET" = local ]; then DOWNLOAD_BASE="${DOWNLOAD_BASE:-http://127.0.0.1:8788/v1/releases}"; else DOWNLOAD_BASE="${DOWNLOAD_BASE:-https://api.playsommelier.com/v1/releases}"; fi
# Each target keeps its own release list: a local test release must never reach the real appcast.
OUT="dist/app/$TARGET"; mkdir -p "$OUT"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

# 1. Build (not when carrying on with a submission already sent: the ticket belongs to exactly that build)
EXTRA=()
[ -n "${FEED_URL:-}" ] && EXTRA+=("SOMMELIER_UPDATE_FEED_URL=$FEED_URL")
if [ -z "${NOTARY_SUBMISSION:-}" ]; then
  xcodegen generate -q
  xcodebuild -project Sommelier.xcodeproj -scheme Sommelier -configuration "$CONFIG" -derivedDataPath build/release \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" ${EXTRA[@]+"${EXTRA[@]}"} build > "$OUT/build-$VERSION.log" 2>&1 \
    || { echo "build failed: $OUT/build-$VERSION.log" >&2; exit 1; }
fi
APP="build/release/Build/Products/$CONFIG/Sommelier.app"

# 1b. Developer ID: sign from the inside out (Sparkle's helpers, then the framework, then the app), notarize, staple
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-sommeliery}"
notarize() {   # notarize FILE: waits for Apple's answer; on a refusal prints why
  local out id
  out="$(xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)" || true
  echo "$out" | tail -3
  if ! echo "$out" | grep -q "status: Accepted"; then
    id="$(echo "$out" | sed -n 's/^ *id: \([0-9a-f-]*\).*/\1/p' | head -1)"
    [ -n "$id" ] && xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2
    echo "notarization refused: $1" >&2; exit 1
  fi
}
if [ -n "$IDENTITY" ] && [ -n "${NOTARY_SUBMISSION:-}" ]; then
  echo "waiting for Apple's answer on submission $NOTARY_SUBMISSION…"
  codesign --verify --deep --strict "$APP"
  out="$(xcrun notarytool wait "$NOTARY_SUBMISSION" --keychain-profile "$NOTARY_PROFILE" 2>&1)" || true
  echo "$out" | tail -2
  if ! echo "$out" | grep -q "status: Accepted"; then
    xcrun notarytool log "$NOTARY_SUBMISSION" --keychain-profile "$NOTARY_PROFILE" >&2 || true
    echo "not accepted (yet): run again with the same NOTARY_SUBMISSION to keep waiting" >&2; exit 1
  fi
  xcrun stapler staple "$APP" >/dev/null
elif [ -n "$IDENTITY" ]; then
  echo "signing with $IDENTITY"
  SIGN=(codesign --force --timestamp --options runtime --sign "$IDENTITY")
  SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
  "${SIGN[@]}" "$SPARKLE/XPCServices/Installer.xpc"
  "${SIGN[@]}" --preserve-metadata=entitlements "$SPARKLE/XPCServices/Downloader.xpc"
  "${SIGN[@]}" "$SPARKLE/Autoupdate"
  "${SIGN[@]}" "$SPARKLE/Updater.app"
  "${SIGN[@]}" "$APP/Contents/Frameworks/Sparkle.framework"
  "${SIGN[@]}" --entitlements App/Sommelier/Sommelier.entitlements "$APP"
  codesign --verify --deep --strict "$APP"
  echo "notarizing the app (a few minutes)…"
  NZIP="$(mktemp -d)/Sommelier.zip"
  ditto -c -k --keepParent "$APP" "$NZIP"
  notarize "$NZIP"
  xcrun stapler staple "$APP" >/dev/null
elif [ "$TARGET" != local ] && [ "${ALLOW_UNSIGNED:-0}" != 1 ]; then
  echo "no Developer ID certificate in the keychain (set ALLOW_UNSIGNED=1 to publish unsigned anyway)" >&2; exit 1
fi

# 2. Zip (ditto keeps the bundle's symlinks and extended attributes as Sparkle expects)
ZIP="$OUT/Sommelier-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

# 3. Sign and add to the release list, then write the appcast from the whole list
SIGNATURE="$(swift scripts/update-signing-key.swift sign "$ZIP")"
LENGTH="$(stat -f%z "$ZIP")"
MINOS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")"
python3 - "$OUT/releases.json" "$OUT/appcast.xml" "$VERSION" "$BUILD" "$DOWNLOAD_BASE/Sommelier-$VERSION.zip" "$LENGTH" "$SIGNATURE" "$MINOS" "$NOTES" "${CRITICAL:-0}" <<'PY'
import json, os, sys, html
from email.utils import formatdate
releases_file, appcast_file, version, build, url, length, signature, minos, notes_file, critical = sys.argv[1:]
releases = json.load(open(releases_file)) if os.path.exists(releases_file) else []
releases = [r for r in releases if r["version"] != version and r["build"] != int(build)]
notes = open(notes_file, encoding="utf-8").read() if notes_file else f"<p>Sommelier {html.escape(version)}</p>"
releases.append({"version": version, "build": int(build), "date": formatdate(usegmt=True), "url": url, "length": int(length),
                 "signature": signature, "minimumSystemVersion": minos, "notes": notes, "critical": critical == "1"})
releases.sort(key=lambda r: r["build"], reverse=True)
json.dump(releases, open(releases_file, "w"), indent=2)
items = "".join(f"""
    <item>
      <title>Version {html.escape(r["version"])}</title>
      <pubDate>{r["date"]}</pubDate>
      <sparkle:version>{r["build"]}</sparkle:version>
      <sparkle:shortVersionString>{html.escape(r["version"])}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{html.escape(r["minimumSystemVersion"])}</sparkle:minimumSystemVersion>{"<sparkle:criticalUpdate/>" if r.get("critical") else ""}
      <description><![CDATA[{r["notes"]}]]></description>
      <enclosure url="{html.escape(r["url"])}" length="{r["length"]}" type="application/octet-stream" sparkle:edSignature="{r["signature"]}"/>
    </item>""" for r in releases)
open(appcast_file, "w", encoding="utf-8").write(f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Sommelier</title>
    <link>https://playsommelier.com</link>
    <description>Sommelier updates</description>{items}
  </channel>
</rss>
""")
PY

# 3b. The disk image the site's Download button gives: the app and a link to Applications to drag it onto.
# (Updates keep using the zip: Sparkle takes it, and its signature in the appcast is the zip's.)
DMG="$OUT/Sommelier-$VERSION.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Sommelier.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Sommelier" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
if [ -n "$IDENTITY" ]; then
  codesign --force --timestamp --sign "$IDENTITY" "$DMG"
  echo "notarizing the disk image…"
  notarize "$DMG"
  xcrun stapler staple "$DMG" >/dev/null
fi

# 4. Upload the archive and the disk image first, then the appcast that points to them
WHERE=(--local); [ "$TARGET" = remote ] && WHERE=(--remote)
( cd server/api
  npx --yes wrangler@4 r2 object put "sommelier-releases/Sommelier-$VERSION.zip" --file "../../$ZIP" --content-type application/zip "${WHERE[@]}" >/dev/null
  npx --yes wrangler@4 r2 object put "sommelier-releases/Sommelier-$VERSION.dmg" --file "../../$DMG" --content-type application/x-apple-diskimage "${WHERE[@]}" >/dev/null
  npx --yes wrangler@4 r2 object put "sommelier-releases/appcast.xml" --file "../../$OUT/appcast.xml" --content-type "application/xml" "${WHERE[@]}" >/dev/null )
echo "published Sommelier $VERSION (build $BUILD, $LENGTH bytes) to $TARGET"
