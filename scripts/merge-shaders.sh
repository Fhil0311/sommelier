#!/usr/bin/env bash
# Copyright 2026 the Sommelier project.
# SPDX-License-Identifier: GPL-3.0-or-later
# Puts players' agreed shaders into the packs everyone downloads (server/decanter/merge.mjs). Run every few days.
#
#   scripts/merge-shaders.sh            # production, with the token from ~/.sommelier/secrets-production.env
#   scripts/merge-shaders.sh local      # the local service (wrangler dev on 127.0.0.1:8789)
set -euo pipefail
cd "$(dirname "$0")/../server/decanter"
if [[ "${1:-production}" == local ]]; then
  DECANTER_URL="http://127.0.0.1:8789" ADMIN_TOKEN="dev-only-admin" node merge.mjs
else
  # shellcheck disable=SC1090
  source "$HOME/.sommelier/secrets-${1:-production}.env"
  url="https://decanter.playsommelier.com"; [[ "${1:-production}" == staging ]] && url="https://sommelier-decanter-staging.workers.dev"
  DECANTER_URL="$url" ADMIN_TOKEN="$ADMIN_TOKEN" node merge.mjs
fi
