#!/usr/bin/env bash
# Copyright 2026 the Sommelier project.
# SPDX-License-Identifier: GPL-3.0-or-later
# Saves the production database (players' reports, the catalogue, verdicts) as SQL into backups/, dated.
# D1 also keeps its own 30-day Time Travel; this is the copy that outlives it. Run weekly.
#
#   scripts/backup-db.sh [production|staging]
set -euo pipefail
cd "$(dirname "$0")/../server/api"
ENVIRONMENT="${1:-production}"
DB="sommelier"; [[ "$ENVIRONMENT" == staging ]] && DB="sommelier-staging"
mkdir -p ../../backups
OUT="../../backups/$DB-$(date +%Y-%m-%d).sql"
CI=true npx --yes wrangler@4 d1 export "$DB" --remote --env "$ENVIRONMENT" --output "$OUT" </dev/null
gzip -f "$OUT"
echo "saved $OUT.gz"
