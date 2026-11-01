#!/usr/bin/env bash
# Copyright 2026 the Sommelier project.
# SPDX-License-Identifier: GPL-3.0-or-later
# Puts the project's answers for games tested on our Macs (server/verdicts/works.json, or the file given) into the
# database: each game's "works" or "wontRun", which outranks players' reports. Safe to run again.
#
#   API_URL=https://api.playsommelier.com ADMIN_TOKEN=… scripts/publish-verdicts.sh [file]
# Defaults: the local API (`wrangler dev --port 8788`) and its development token. Staging: also STAGING_KEY.
set -euo pipefail
cd "$(dirname "$0")/.."
FILE="${1:-server/verdicts/works.json}"
API_URL="${API_URL:-http://127.0.0.1:8788}"
ADMIN_TOKEN="${ADMIN_TOKEN:-dev-only-admin}"
python3 -I - "$FILE" "$API_URL" "$ADMIN_TOKEN" "${STAGING_KEY:-}" <<'PY'
import json, sys, urllib.parse, urllib.request
file, api, token, staging = sys.argv[1:]
items = json.load(open(file))["verdicts"]
bad = 0
for v in items:
    body = {"verdict": v["verdict"]}
    if v.get("steamAppID"): body["steamAppID"] = v["steamAppID"]
    url = f"{api}/v1/verdicts/{urllib.parse.quote(v['store'])}/{urllib.parse.quote(v['id'], safe='')}"
    req = urllib.request.Request(url, data=json.dumps(body).encode(), method="PUT",
        headers={"Authorization": f"Bearer {token}", "X-Sommelier-Staging-Key": staging, "Content-Type": "application/json",
                 "User-Agent": "Sommelier-Publisher/1"})   # Cloudflare's edge refuses Python-urllib's default agent (error 1010)
    try:
        urllib.request.urlopen(req)
        print("ok  ", v["store"], v["id"], v.get("title", ""))
    except Exception as e:
        bad += 1; print("FAIL", v["store"], v["id"], e)
sys.exit(1 if bad else 0)
PY
