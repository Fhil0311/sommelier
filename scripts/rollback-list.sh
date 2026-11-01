#!/usr/bin/env bash
# Copyright 2026 the Sommelier project.
# SPDX-License-Identifier: GPL-3.0-or-later
# Puts back the version of a published list from before its last publish (the service keeps 20 earlier versions).
#
#   API_URL=https://api.playsommelier.com ADMIN_TOKEN=… scripts/rollback-list.sh recipes|fixes|announcements
set -euo pipefail
NAME="${1:?which list: recipes, fixes or announcements}"
API_URL="${API_URL:-http://127.0.0.1:8788}"
ADMIN_TOKEN="${ADMIN_TOKEN:-dev-only-admin}"
curl -sS -X POST "$API_URL/v1/$NAME.json/rollback" -H "Authorization: Bearer $ADMIN_TOKEN" -H "X-Sommelier-Staging-Key: ${STAGING_KEY:-}"
echo
