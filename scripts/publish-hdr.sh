#!/usr/bin/env bash
# Copyright 2026 the Sommelier project.
# SPDX-License-Identifier: GPL-3.0-or-later
# Publishes our researched list of games with and without HDR (server/hdr/hdr-games.json, or the file given) to the
# API. Unknown answers (null) are left out. Every Sommelier reads GET /v1/hdr.json once a day.
#
#   API_URL=https://api.playsommelier.com ADMIN_TOKEN=… scripts/publish-hdr.sh [file]
# Defaults: the local API (`wrangler dev --port 8788`) and its development token.
set -euo pipefail
cd "$(dirname "$0")/.."
FILE="${1:-server/hdr/hdr-games.json}"
API_URL="${API_URL:-http://127.0.0.1:8788}"
ADMIN_TOKEN="${ADMIN_TOKEN:-dev-only-admin}"
python3 -I -c '
import json, sys
d = json.load(open(sys.argv[1]))
games = [{"game": "steam:" + g["steam"], "hdr": g["hdr"], "source": g.get("source")} for g in d["games"] if g.get("hdr") is not None]
print(json.dumps({"version": 1, "games": games}))' "$FILE" \
  | curl -sS -X PUT "$API_URL/v1/hdr.json" -H "Authorization: Bearer $ADMIN_TOKEN" -H "X-Sommelier-Staging-Key: ${STAGING_KEY:-}" -H "Content-Type: application/json" --data-binary @-
echo
