#!/usr/bin/env bash
# Copyright 2026 the Sommelier project.
# SPDX-License-Identifier: GPL-3.0-or-later
# Publishes the recipes list (server/fixes/recipes.json, or the file given) to the API, which checks it before storing.
# Every Sommelier picks it up within a day and applies a game's recipe before its first launch there (graphics, Turbo).
#
#   API_URL=https://api.playsommelier.com ADMIN_TOKEN=… scripts/publish-recipes.sh [file]
# Defaults: the local API (`wrangler dev --port 8788`) and its development token.
set -euo pipefail
cd "$(dirname "$0")/.."
FILE="${1:-server/fixes/recipes.json}"
API_URL="${API_URL:-http://127.0.0.1:8788}"
ADMIN_TOKEN="${ADMIN_TOKEN:-dev-only-admin}"
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$FILE" || { echo "$FILE isn't valid JSON" >&2; exit 1; }
# Signed with the update key: apps take only a list the owner signed (the service checks it too).
SIGNATURE="$(scripts/sign.sh "$FILE")"
curl -sS -X PUT "$API_URL/v1/recipes.json" -H "Authorization: Bearer $ADMIN_TOKEN" -H "X-Sommelier-Staging-Key: ${STAGING_KEY:-}" -H "X-Sommelier-Signature: $SIGNATURE" -H "Content-Type: application/json" --data-binary @"$FILE"
echo
