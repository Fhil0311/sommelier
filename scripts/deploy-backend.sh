#!/usr/bin/env bash
# Copyright 2026 the Sommelier project.
# SPDX-License-Identifier: GPL-3.0-or-later
# Puts Sommelier's backend on Cloudflare: the API (server/api, api.playsommelier.com) and the shader service
# (server/decanter, decanter.playsommelier.com). Safe to run again: what exists is left as it is.
#
#   scripts/deploy-backend.sh [production|staging]
#
# Needs wrangler logged in with Workers, D1 and R2 rights (`npx wrangler login`). The first run makes:
#   - the D1 database (sommelier or sommelier-staging) and writes its id into server/api/wrangler.toml;
#   - the R2 buckets, with lifecycle rules: a decanter's daily upload counters go after 2 days, players' uploads
#     waiting for agreement after 60;
#   - the secrets SALT, ADMIN_TOKEN (both services) and CELLAR_TOKEN (the shader builder's), random, saved to
#     plus STAGING_KEY for staging (the password every request there must carry),
#     ~/.sommelier/secrets-<env>.env (outside the repository; keep it, the salt can't change later);
# then it applies the database migrations and deploys both Workers.
set -euo pipefail
ENVIRONMENT="${1:-production}"
[[ "$ENVIRONMENT" == production || "$ENVIRONMENT" == staging ]] || { echo "production or staging" >&2; exit 1; }
cd "$(dirname "$0")/../server"
export CI=true
W=(npx --yes wrangler@4)
suffix=""; [[ "$ENVIRONMENT" == staging ]] && suffix="-staging"
DB="sommelier$suffix"

# --- D1 -----------------------------------------------------------------------------------------------------------
id="$("${W[@]}" d1 list --json </dev/null | python3 -c "import json,sys; print(next((d['uuid'] for d in json.load(sys.stdin) if d['name']=='$DB'), ''))")"
if [[ -z "$id" ]]; then
  "${W[@]}" d1 create "$DB" </dev/null
  id="$("${W[@]}" d1 list --json </dev/null | python3 -c "import json,sys; print(next(d['uuid'] for d in json.load(sys.stdin) if d['name']=='$DB'))")"
fi
python3 - "$ENVIRONMENT" "$DB" "$id" <<'PY'
import re, sys
env, db, uuid = sys.argv[1:]
path = "api/wrangler.toml"
text = open(path).read()
section = text.split(f"[env.{env}]", 1)
head, tail = section
tail = re.sub(r'(database_name = "' + re.escape(db) + r'", database_id = ")[0-9a-f-]+(")', r"\g<1>" + uuid + r"\g<2>", tail, count=1)
open(path, "w").write(head + f"[env.{env}]" + tail)
PY

# --- R2 -----------------------------------------------------------------------------------------------------------
for bucket in "sommelier-releases$suffix" "sommelier-decanter$suffix"; do
  "${W[@]}" r2 bucket list </dev/null | grep -q "name: *$bucket\$" || "${W[@]}" r2 bucket create "$bucket" </dev/null
done
"${W[@]}" r2 bucket lifecycle add "sommelier-decanter$suffix" daily-limits "limits/" --expire-days 2 --force </dev/null || true
"${W[@]}" r2 bucket lifecycle add "sommelier-decanter$suffix" waiting-uploads "incoming/" --expire-days 60 --force </dev/null || true

# --- Secrets ------------------------------------------------------------------------------------------------------
SECRETS="$HOME/.sommelier/secrets-$ENVIRONMENT.env"
mkdir -p "$(dirname "$SECRETS")"
if [[ ! -f "$SECRETS" ]]; then
  umask 077
  { echo "SALT=$(openssl rand -hex 32)"; echo "ADMIN_TOKEN=$(openssl rand -hex 32)"; echo "CELLAR_TOKEN=$(openssl rand -hex 32)"; [[ "$ENVIRONMENT" == staging ]] && echo "STAGING_KEY=$(openssl rand -hex 32)"; } > "$SECRETS"
  echo "new secrets saved to $SECRETS"
fi
# shellcheck disable=SC1090
source "$SECRETS"
put_secret() { printf '%s' "$3" | (cd "$1" && "${W[@]}" secret put "$2" --env "$ENVIRONMENT"); }
put_secret api SALT "$SALT"
put_secret api ADMIN_TOKEN "$ADMIN_TOKEN"
put_secret decanter SALT "$SALT"
put_secret decanter ADMIN_TOKEN "$ADMIN_TOKEN"
put_secret decanter CELLAR_TOKEN "$CELLAR_TOKEN"
if [[ "$ENVIRONMENT" == staging ]]; then              # staging answers only those who know this key
  [[ -n "${STAGING_KEY:-}" ]] || { STAGING_KEY="$(openssl rand -hex 32)"; echo "STAGING_KEY=$STAGING_KEY" >> "$SECRETS"; }
  put_secret api STAGING_KEY "$STAGING_KEY"
  put_secret decanter STAGING_KEY "$STAGING_KEY"
fi

# --- Database and Workers -----------------------------------------------------------------------------------------
(cd api && "${W[@]}" d1 migrations apply "$DB" --remote --env "$ENVIRONMENT" </dev/null)
(cd decanter && "${W[@]}" deploy --env "$ENVIRONMENT" </dev/null)     # first: the API is bound to it
(cd api && "${W[@]}" deploy --env "$ENVIRONMENT" </dev/null)
echo "deployed $ENVIRONMENT"
