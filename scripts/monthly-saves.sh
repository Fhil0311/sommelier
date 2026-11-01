#!/usr/bin/env bash
# Copyright 2026 the Sommelier project.
# SPDX-License-Identifier: GPL-3.0-or-later
# Run by launchd once a month (scripts/install-monthly-saves.sh): refreshes the save locations list on the production
# API with scripts/publish-saves.sh. Signing needs the update key in this Mac's keychain, so it runs here, not on the
# server. The admin token is read from ~/.sommelier/secrets-production.env and never printed. Log:
# ~/Library/Logs/Sommelier/saves-monthly.log.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="$HOME/Library/Logs/Sommelier"
mkdir -p "$LOG_DIR"
exec >>"$LOG_DIR/saves-monthly.log" 2>&1
echo "== $(date '+%Y-%m-%d %H:%M')"
VENV="$HOME/.sommelier/venv"
if [[ ! -x "$VENV/bin/python" ]]; then python3 -m venv "$VENV" && "$VENV/bin/pip" -q install pyyaml; fi
ADMIN_TOKEN="$(sed -n 's/^ADMIN_TOKEN=//p' "$HOME/.sommelier/secrets-production.env")"
[[ -n "$ADMIN_TOKEN" ]] || { echo "no ADMIN_TOKEN in secrets-production.env"; exit 1; }
API_URL=https://api.playsommelier.com ADMIN_TOKEN="$ADMIN_TOKEN" PYTHON="$VENV/bin/python" "$ROOT/scripts/publish-saves.sh"
