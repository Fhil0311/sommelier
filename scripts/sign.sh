#!/usr/bin/env bash
# Copyright 2026 the Sommelier project.
# SPDX-License-Identifier: GPL-3.0-or-later
# Prints the base64 signature of FILE with the update signing key (see update-signing-key.swift): what the service
# and the app check on the lists, engine list, shader packs and archives. Builds the signing tool once, into build/.
#
#   scripts/sign.sh FILE
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOL="$ROOT/build/sign-tool"
SOURCE="$ROOT/scripts/update-signing-key.swift"
if [[ ! -x "$TOOL" || "$SOURCE" -nt "$TOOL" ]]; then
  mkdir -p "$ROOT/build"
  DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" swiftc -O "$SOURCE" -o "$TOOL" >/dev/null
fi
"$TOOL" sign "$1"
