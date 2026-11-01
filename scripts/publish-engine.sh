#!/usr/bin/env bash
# Copyright 2026 the Sommelier project.
# SPDX-License-Identifier: GPL-3.0-or-later
# Puts an engine where apps download it: the archive from engine/dist, and a list of the published engines with
# addresses on the service, signed with the update key (apps take only a signed list). Every app installs the newest
# engine quietly at its next start.
#
#   scripts/publish-engine.sh 2.2.4                          the local service (`wrangler dev` in server/api)
#   scripts/publish-engine.sh 2.2.4 production|staging       Cloudflare (needs `npx wrangler login`)
#
# The list keeps the engines already published (so players can roll back) and adds or replaces this one.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?version, e.g. 2.2.4}"
TARGET="${2:-local}"
ARCHIVE="engine/dist/sommelier-engine-$VERSION.tar.xz"
[[ -f "$ARCHIVE" ]] || { echo "no $ARCHIVE: build it with engine/build-engine-d3dmetal.sh $VERSION" >&2; exit 1; }
case "$TARGET" in
  local)      BASE="http://127.0.0.1:8788/v1/engines"; BUCKET="sommelier-releases"; WHERE=(--local) ;;
  production) BASE="https://api.playsommelier.com/v1/engines"; BUCKET="sommelier-releases"; WHERE=(--remote) ;;
  staging)    BASE="${STAGING_API_URL:?the staging API address}/v1/engines"; BUCKET="sommelier-releases-staging"; WHERE=(--remote) ;;
  *) echo "local, production or staging" >&2; exit 1 ;;
esac
WORK="build/engines"; mkdir -p "$WORK"
W=(npx --yes wrangler@4)
export CI=true

# The list published now (none yet: an empty one), with this engine's entry from engine/dist's list.
(cd server/api && "${W[@]}" r2 object get "$BUCKET/engines/engine-manifest.json" --file "../../$WORK/current.json" "${WHERE[@]}" </dev/null >/dev/null 2>&1) \
  || echo '{"engines": [], "steamArgs": ["-no-cef-sandbox", "-noverifyfiles"], "knownIssues": {}}' > "$WORK/current.json"
python3 -I - "$WORK/current.json" engine/dist/engine-manifest.json "$VERSION" "$BASE" "$WORK/engine-manifest.json" <<'PY'
import json, sys
current, built, version, base, out = sys.argv[1:]
published = json.load(open(current))
entry = next(e for e in json.load(open(built))["engines"] if e["version"] == version)
entry = dict(entry, url=f"{base}/sommelier-engine-{version}.tar.xz")
published["engines"] = sorted([e for e in published["engines"] if e["version"] != version] + [entry],
                              key=lambda e: [int(p) if p.isdigit() else 0 for p in e["version"].split(".")])
json.dump(published, open(out, "w"), indent=2)
open(out, "a").write("\n")
print("list:", ", ".join(e["version"] for e in published["engines"]))
PY
scripts/sign.sh "$WORK/engine-manifest.json" > "$WORK/engine-manifest.json.sig"

put() { (cd server/api && "${W[@]}" r2 object put "$BUCKET/engines/$1" --file "../../$2" --content-type "$3" "${WHERE[@]}" </dev/null >/dev/null); }
SIZE="$(du -h "$ARCHIVE" | cut -f1)"
echo "uploading the archive, $SIZE"
if [[ "$TARGET" == local ]]; then
  put "sommelier-engine-$VERSION.tar.xz" "$ARCHIVE" application/x-xz
else
  # Over wrangler's 300 MB: in parts through R2's S3 API (key in ~/.sommelier/r2.env).
  node scripts/r2-upload.mjs "$BUCKET" "engines/sommelier-engine-$VERSION.tar.xz" "$ARCHIVE" application/x-xz
fi
put engine-manifest.json.sig "$WORK/engine-manifest.json.sig" text/plain        # signature first, then the list it signs
put engine-manifest.json "$WORK/engine-manifest.json" application/json
echo "published $VERSION: $BASE/engine-manifest.json"
