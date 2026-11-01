#!/usr/bin/env python3
# Copyright 2026 the Sommelier project.
# SPDX-License-Identifier: GPL-3.0-or-later
"""Builds server/saves/saves.json, where Windows games keep their saves, from the Ludusavi manifest
(github.com/mtkennerly/ludusavi-manifest, MIT; see server/saves/LICENSE-ludusavi-manifest).

Only save files (tag "save") on Windows, anchored to the folders Sommelier backs up (Documents, AppData, Saved Games,
the game's own folder). Registry saves and anything else are left out. Paths may hold "*" (any name in that step);
the app expands them. Needs PyYAML.

  python3 server/saves/from-ludusavi.py path/to/manifest.yaml [out.json]
"""
import json
import sys

import yaml

ROOTS = [
    ("<winDocuments>/", "documents"), ("<winAppData>/", "roaming"), ("<winLocalAppData>/", "local"),
    ("<winLocalAppDataLow>/", "localLow"), ("<home>/Documents/", "documents"), ("<home>/AppData/Roaming/", "roaming"),
    ("<home>/AppData/Local/", "local"), ("<home>/AppData/LocalLow/", "localLow"), ("<home>/Saved Games/", "savedGames"),
    ("<base>/", "install"),
]
STORES = {"steam", "gog", "epic", "ea", "uplay", "origin"}


def windows(entry):
    """Whether a file entry applies on Windows; with the stores it is limited to (empty: any)."""
    conditions = entry.get("when") or []
    if not conditions:
        return True, []
    stores, fits = set(), False
    for c in conditions:
        if c.get("os") not in (None, "windows"):
            continue
        fits = True
        if c.get("store"):
            stores.add(c["store"])
        else:
            return True, []
    return fits, sorted(stores)


def convert(path, game):
    for prefix, root in ROOTS:
        if path.startswith(prefix):
            rest = path[len(prefix):]
            break
    else:
        return None
    rest = rest.replace("<storeUserId>", "*")
    if "<game>" in rest:
        dirs = list((game.get("installDir") or {}).keys())
        if not dirs:
            return None
        rest = rest.replace("<game>", dirs[0])
    if "<" in rest or "\\" in rest:
        return None
    parts = [p for p in rest.split("/") if p]
    if not parts or any(p in (".", "..") for p in parts):
        return None
    # "**" and the like: one step of "*" is as far as the app goes.
    parts = ["*" if "**" in p else p for p in parts]
    return {"root": root, "path": "/".join(parts)}


def main():
    manifest = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
    out_path = sys.argv[2] if len(sys.argv) > 2 else "server/saves/saves.json"
    games = {}
    for title, game in manifest.items():
        if not isinstance(game, dict):
            continue
        places = []
        for path, entry in (game.get("files") or {}).items():
            entry = entry or {}
            if "save" not in (entry.get("tags") or []):
                continue
            fits, stores = windows(entry)
            if not fits:
                continue
            place = convert(path, game)
            if not place:
                continue
            if stores and not set(stores) & STORES:
                continue
            if stores:
                place["stores"] = stores
            if place not in places:
                places.append(place)
        if not places:
            continue
        ids = []
        if (game.get("steam") or {}).get("id"):
            ids.append(f"steam:{game['steam']['id']}")
        if (game.get("gog") or {}).get("id"):
            ids.append(f"gog:{game['gog']['id']}")
        # Letters and digits of any script, as the app's SaveLocator.normalize keeps them.
        ids.append("title:" + "".join(ch for ch in title.lower() if ch.isalnum()))
        for i in ids:
            games.setdefault(i, places)
    json.dump({"version": 1, "source": "ludusavi-manifest (MIT)", "games": games}, open(out_path, "w"),
              separators=(",", ":"), ensure_ascii=False, sort_keys=True)
    print(f"{len(games)} ids, {sum(1 for k in games if k.startswith('title:'))} titles -> {out_path}")


if __name__ == "__main__":
    main()
