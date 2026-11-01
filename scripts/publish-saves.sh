#!/usr/bin/env bash
# Copyright 2026 the Sommelier project.
# SPDX-License-Identifier: GPL-3.0-or-later
# Publishes where games keep their saves: downloads the current Ludusavi manifest (MIT, server/saves/LICENSE-ludusavi-manifest),
# turns it into server/saves/saves.json (server/saves/from-ludusavi.py, needs PyYAML), signs it and sends it to the API.
# Every Sommelier picks it up within a day and backs up exactly those folders. Run it now and then (monthly is plenty).
#
#   API_URL=https://api.playsommelier.com ADMIN_TOKEN=… scripts/publish-saves.sh
# Defaults: the local API (`wrangler dev --port 8788`) and its development token.
set -euo pipefail
cd "$(dirname "$0")/.."
API_URL="${API_URL:-http://127.0.0.1:8788}"
ADMIN_TOKEN="${ADMIN_TOKEN:-dev-only-admin}"
PYTHON="${PYTHON:-python3}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
curl -sSfL -o "$WORK/manifest.yaml" https://raw.githubusercontent.com/mtkennerly/ludusavi-manifest/master/data/manifest.yaml
"$PYTHON" -I server/saves/from-ludusavi.py "$WORK/manifest.yaml" server/saves/saves.json
SIGNATURE="$(scripts/sign.sh server/saves/saves.json)"
curl -sS -X PUT "$API_URL/v1/saves.json" -H "Authorization: Bearer $ADMIN_TOKEN" -H "X-Sommelier-Staging-Key: ${STAGING_KEY:-}" -H "X-Sommelier-Signature: $SIGNATURE" -H "Content-Type: application/json" --data-binary @server/saves/saves.json
echo
