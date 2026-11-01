#!/usr/bin/env bash
# Copyright 2026 the Sommelier project.
# SPDX-License-Identifier: GPL-3.0-or-later
# Publishes the mods list (server/mods/mods.json, or the file given) to the API, which checks it before storing.
# Every Sommelier picks it up within a day: it says how each game's mods are installed, which loaders they need and
# how the game may be started with them. A loader's archive is only ever unpacked when its SHA-256 matches the
# list, so every download needs its hash (taken by hand from the release) before the list can go out, one that
# comes through the embedded browser (viaBrowser) too: the app installs nothing without it.
#
#   API_URL=https://api.playsommelier.com ADMIN_TOKEN=… scripts/publish-mods.sh [file]
# Defaults: the local API (`wrangler dev --port 8788`) and its development token.
set -euo pipefail
cd "$(dirname "$0")/.."
FILE="${1:-server/mods/mods.json}"
API_URL="${API_URL:-http://127.0.0.1:8788}"
ADMIN_TOKEN="${ADMIN_TOKEN:-dev-only-admin}"
python3 -I - "$FILE" <<'PY' || exit 1
import json, re, sys
try:
    data = json.load(open(sys.argv[1]))
except ValueError as e:
    sys.exit(f"{sys.argv[1]} isn't valid JSON: {e}")
missing = []
for game in data.get("games", []):
    for framework in game.get("frameworks", []):
        download = framework.get("download") or {}
        if not re.fullmatch(r"[0-9a-f]{64}", str(download.get("sha256", "")).lower()):
            missing.append(f"{game.get('game')}: {framework.get('id')}")
if missing:
    sys.exit("every download needs its sha256 before the list is published; missing for:\n  " + "\n  ".join(missing))
PY
# Signed with the update key: apps take only a list the owner signed (the service checks it too).
SIGNATURE="$(scripts/sign.sh "$FILE")"
curl -sS -X PUT "$API_URL/v1/mods.json" -H "Authorization: Bearer $ADMIN_TOKEN" -H "X-Sommelier-Staging-Key: ${STAGING_KEY:-}" -H "X-Sommelier-Signature: $SIGNATURE" -H "Content-Type: application/json" --data-binary @"$FILE"
echo
