#!/usr/bin/env python3 -I
# Copyright 2026 the Sommelier project.
# SPDX-License-Identifier: GPL-3.0-or-later
# Imports the graphics layer each game runs best with from highball-db's curated entries (CC0-1.0, public domain:
# https://github.com/gauthierpiarrette/highball-db, served at https://gethighball.com/data/games.json) into
# server/recipes/highball.json, which review.py turns into switchGraphics actions.
# Only the CC0 part is used: not db/derived (ProtonDB-based predictions, ODbL) nor anything else.
# Entries blocked by anti-cheat or the publisher, and renderers Sommelier doesn't have (vkd3d), are left out.
#   python3 -I server/recipes/from-highball.py [out]
import json, sys, urllib.request

BACKEND = {"dxmt": "dxmt", "d3dmetal": "d3dMetal", "dxvk": "dxvk", "wined3d": "wined3d"}
src = "https://gethighball.com/data/games.json"
data = json.load(urllib.request.urlopen(urllib.request.Request(src, headers={"User-Agent": "Sommelier-recipes/1"}), timeout=60))
entries = data if isinstance(data, list) else data.get("games", data)
entries = list(entries.values()) if isinstance(entries, dict) else entries
games = {}
for e in entries:
    backend = BACKEND.get(e.get("renderer") or "")
    if not backend or not e.get("steam_appid") or str(e.get("status", "")).startswith("blocked"): continue
    games["steam:%d" % int(e["steam_appid"])] = {"backend": backend, "title": e.get("title"), "status": e.get("status"),
                                                 "lastVerified": e.get("lastVerified")}
out = sys.argv[1] if len(sys.argv) > 1 else "server/recipes/highball.json"
json.dump({"source": src, "license": "CC0-1.0", "games": dict(sorted(games.items()))}, open(out, "w"), ensure_ascii=False, indent=1)
open(out, "a").write("\n")
print(len(games), "games with a graphics layer, of", len(entries), "entries")
