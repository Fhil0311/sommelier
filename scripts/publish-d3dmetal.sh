#!/usr/bin/env bash
# Copyright 2026 the Sommelier project.
# SPDX-License-Identifier: GPL-3.0-or-later
# Puts Apple's D3DMetal (DirectX 12) where apps download it, from a Game Porting Toolkit disk image downloaded from
# Apple: the toolkit's redistributable files (`redist`, the D3DMetal framework whole) and Apple's license and
# acknowledgements, unchanged, packed as an archive, plus an entry in the signed engine list. Apple's license allows
# passing them on for non-commercial use only: Sommelier is free. If that ever changes, D3DMetal comes off the list.
#
#   scripts/publish-d3dmetal.sh ~/Downloads/Game_Porting_Toolkit_3.0.dmg                     the local service
#   scripts/publish-d3dmetal.sh ~/Downloads/Game_Porting_Toolkit_4.0_beta_3.dmg 27 production
#
# The second argument is the oldest macOS major version the copy is for (none: any); a Mac gets the copy meant for the
# newest macOS it runs. The list keeps the other copies and replaces one of the same version.
set -euo pipefail
cd "$(dirname "$0")/.."
IMAGE="${1:?the Game Porting Toolkit disk image}"
MIN_MACOS="${2:-}"
TARGET="${3:-local}"
[[ -z "$MIN_MACOS" || "$MIN_MACOS" =~ ^[0-9]+$ ]] || { echo "the macOS version is a number, e.g. 27" >&2; exit 1; }
case "$TARGET" in
  local)      BASE="http://127.0.0.1:8788/v1/engines"; BUCKET="sommelier-releases"; WHERE=(--local) ;;
  production) BASE="https://api.playsommelier.com/v1/engines"; BUCKET="sommelier-releases"; WHERE=(--remote) ;;
  staging)    BASE="${STAGING_API_URL:?the staging API address}/v1/engines"; BUCKET="sommelier-releases-staging"; WHERE=(--remote) ;;
  *) echo "local, production or staging" >&2; exit 1 ;;
esac
WORK="build/d3dmetal"; rm -rf "$WORK"; mkdir -p "$WORK"
W=(npx --yes wrangler@4)
export CI=true

# Apple's image holds a second one ("Evaluation environment for Windows games") with D3DMetal in it.
OUTER="$(mktemp -d)"; INNER="$(mktemp -d)"
cleanup() { hdiutil detach "$INNER" >/dev/null 2>&1 || true; hdiutil detach "$OUTER" >/dev/null 2>&1 || true; rmdir "$INNER" "$OUTER" 2>/dev/null || true; }
trap cleanup EXIT
hdiutil attach "$IMAGE" -readonly -nobrowse -noautoopen -mountpoint "$OUTER" >/dev/null
EVALUATION="$(find "$OUTER" -maxdepth 1 -iname '*evaluation*.dmg' | head -1)"
if [[ -n "$EVALUATION" ]]; then
  hdiutil attach "$EVALUATION" -readonly -nobrowse -noautoopen -mountpoint "$INNER" >/dev/null
  SOURCE="$INNER"
else
  SOURCE="$OUTER"
fi
[[ -d "$SOURCE/redist/lib/external/D3DMetal.framework" && -f "$SOURCE/License.rtf" ]] || { echo "no D3DMetal or license in $IMAGE" >&2; exit 1; }
for item in D3DMetal.framework libd3dshared.dylib; do
  codesign --verify --strict --deep -R="anchor apple" "$SOURCE/redist/lib/external/$item" || { echo "$item isn't signed by Apple" >&2; exit 1; }
done
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$SOURCE/redist/lib/external/D3DMetal.framework/Versions/A/Resources/Info.plist")"
[[ "$VERSION" =~ ^[0-9A-Za-z.]+$ ]] || { echo "unexpected version $VERSION" >&2; exit 1; }

mkdir "$WORK/tree"
cp -R "$SOURCE/redist" "$WORK/tree/"
for file in License.rtf Acknowledgements.rtf "Read Me.rtf"; do
  if [[ -f "$SOURCE/$file" ]]; then cp "$SOURCE/$file" "$WORK/tree/"; fi
done
NAME="d3dmetal-$VERSION.tar.xz"
ARCHIVE="$WORK/$NAME"
COPYFILE_DISABLE=1 tar --no-mac-metadata -cJf "$ARCHIVE" -C "$WORK/tree" .
SHA="$(shasum -a 256 "$ARCHIVE" | cut -d' ' -f1)"
SIZE="$(stat -f %z "$ARCHIVE")"

# The engine list published now, with this copy added (or replacing one of the same version).
(cd server/api && "${W[@]}" r2 object get "$BUCKET/engines/engine-manifest.json" --file "../../$WORK/current.json" "${WHERE[@]}" </dev/null >/dev/null 2>&1) \
  || { echo "no engine list on $TARGET yet: publish an engine first" >&2; exit 1; }
python3 -I - "$WORK/current.json" "$VERSION" "$BASE/$NAME" "$SHA" "$SIZE" "$MIN_MACOS" "$WORK/engine-manifest.json" <<'PY'
import json, sys
current, version, url, sha, size, min_macos, out = sys.argv[1:]
published = json.load(open(current))
entry = {"version": version, "url": url, "sha256": sha, "size": int(size)}
if min_macos: entry["minMacOS"] = int(min_macos)
published["d3dMetal"] = [e for e in published.get("d3dMetal", []) if e["version"] != version] + [entry]
json.dump(published, open(out, "w"), indent=2)
open(out, "a").write("\n")
print("D3DMetal:", ", ".join(f'{e["version"]} (macOS {e["minMacOS"]}+)' if "minMacOS" in e else f'{e["version"]} (any macOS)'
                             for e in published["d3dMetal"]))
PY
scripts/sign.sh "$WORK/engine-manifest.json" > "$WORK/engine-manifest.json.sig"

put() { (cd server/api && "${W[@]}" r2 object put "$BUCKET/engines/$1" --file "../../$2" --content-type "$3" "${WHERE[@]}" </dev/null >/dev/null); }
echo "uploading $NAME, $(du -h "$ARCHIVE" | cut -f1)"
put "$NAME" "$ARCHIVE" application/x-xz
put engine-manifest.json.sig "$WORK/engine-manifest.json.sig" text/plain        # signature first, then the list it signs
put engine-manifest.json "$WORK/engine-manifest.json" application/json
echo "published D3DMetal $VERSION: $BASE/engine-manifest.json"
