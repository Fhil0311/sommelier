#!/usr/bin/env python3 -I
# Copyright 2026 the Sommelier project.
# SPDX-License-Identifier: GPL-3.0-or-later
# Turns highball-db's curated statuses (CC0-1.0, public domain: https://github.com/gauthierpiarrette/highball-db, served
# at https://gethighball.com/data/games.json) into answers for server/verdicts/highball.json, published with
# scripts/publish-verdicts.sh. Only the CC0 part is used: not db/derived (ProtonDB-based predictions, ODbL).
#   verified-local (tested by Highball on Apple Silicon)            -> works
#   community, a player's report rated 4 or 5 of 5                  -> works
#   blocked-anticheat / blocked-publisher                           -> wontRun
# Left out: unrated or low-rated reports, "reported-upstream" (a fix in a changelog says nothing about the whole game),
# games without a Steam id, and games our own lists (works.json: tested on our Macs; pixelport-works.json) already
# answer, so our own word and earlier lists stay as they are.
#   python3 -I server/verdicts/from-highball.py [out]
import json, os, re, sys, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
src = "https://gethighball.com/data/games.json"
data = json.load(urllib.request.urlopen(urllib.request.Request(src, headers={"User-Agent": "Sommelier-verdicts/1"}), timeout=60))
ours = set()
for name in ("works.json", "pixelport-works.json"):
    path = os.path.join(HERE, name)
    if os.path.exists(path):
        ours |= {(v["store"], v["id"]) for v in json.load(open(path))["verdicts"]}

out, kept = [], {"works": 0, "wontRun": 0}
for e in data["games"]:
    status, appid = e.get("status") or "", e.get("steam_appid")
    if not appid: continue
    rating = re.search(r"rated (\d) of 5", e.get("provenance") or "")
    if status == "verified-local":
        verdict, why = "works", "Highball tested it on Apple Silicon"
    elif status == "community" and rating and int(rating.group(1)) >= 4:
        verdict, why = "works", "a Highball player rated it %s of 5; NOT tested by Highball or us" % rating.group(1)
    elif status.startswith("blocked"):
        verdict, why = "wontRun", "Highball marks it %s" % status
    else:
        continue
    if ("steam", str(appid)) in ours: continue
    out.append({"store": "steam", "id": str(appid), "title": e.get("title"), "verdict": verdict,
                "source": "%s (%s)" % (why, e.get("url") or "gethighball.com")})
    kept[verdict] += 1

out.sort(key=lambda v: (v["title"] or "").lower())
dest = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "highball.json")
json.dump({"version": 1, "source": src, "license": "CC0-1.0", "verdicts": out}, open(dest, "w"), ensure_ascii=False, indent=1)
open(dest, "a").write("\n")
print(len(out), "answers:", kept, "of", len(data["games"]), "entries")
