#!/usr/bin/env python3
# Copyright 2026 the Sommelier project.
# SPDX-License-Identifier: GPL-3.0-or-later
"""Fills the catalogue with the games the site's pages are made for: Steam's most-played chart first, then the games
with the most Steam reviews (SteamSpy's list), until there are COUNT real games (not DLC, soundtracks, tools).

    API_URL=https://api.playsommelier.com ADMIN_TOKEN=… scripts/seed-games.py [COUNT]     (default 500)
Defaults: the local API and its development token. Safe to run again: games already read are skipped. Steam answers a
few hundred details an hour, so a full run takes a while; it prints its progress and can be stopped and started again.
"""
import json, os, sys, time, urllib.request

API = os.environ.get("API_URL", "http://127.0.0.1:8788")
TOKEN = os.environ.get("ADMIN_TOKEN", "dev-only-admin")
STAGING = os.environ.get("STAGING_KEY", "")
COUNT = int(sys.argv[1]) if len(sys.argv) > 1 else 500

def get(url, headers=None):
    return json.load(urllib.request.urlopen(urllib.request.Request(url, headers=headers or {"User-Agent": "Sommelier-seed/1"}), timeout=90))

def owner(path, body=None):
    req = urllib.request.Request(API + path, method="POST" if body is not None else "GET", data=json.dumps(body).encode() if body is not None else None,
        headers={"Authorization": f"Bearer {TOKEN}", "X-Sommelier-Staging-Key": STAGING, "Content-Type": "application/json",
                 "User-Agent": "Sommelier-seed/1"})          # Cloudflare turns away Python's own
    return json.load(urllib.request.urlopen(req, timeout=120))

chart = [str(r["appid"]) for r in get("https://api.steampowered.com/ISteamChartsService/GetMostPlayedGames/v1/")["response"]["ranks"]]
spy = get("https://steamspy.com/api.php?request=all&page=0")
by_reviews = [str(g["appid"]) for g in sorted(spy.values(), key=lambda g: -(g.get("positive", 0) + g.get("negative", 0)))]
order = list(dict.fromkeys(chart + by_reviews))[: COUNT * 2]                    # room for what turns out not to be a game
print(f"{len(chart)} from the chart, {len(order)} candidates", flush=True)

def games_so_far():
    ids, after = set(), None
    while True:
        page = owner(f"/v1/admin/games?limit=200" + (f"&after={after}" if after else ""))
        ids |= {g["steam"]["appid"] for g in page["games"]}
        after = page["next"]
        if not after: return ids

have, pending, rounds = games_so_far(), list(order), 0
while pending and len(have & set(order)) < COUNT and rounds < 6:
    rounds += 1
    retry = []
    for i in range(0, len(pending), 15):
        batch = pending[i:i + 15]
        try: result = owner("/v1/admin/games/seed", {"appids": batch})
        except Exception as e: print("batch failed:", e, flush=True); retry += batch; time.sleep(30); continue
        retry += result["failed"]
        print(f"round {rounds}: {i + len(batch)}/{len(pending)} read, {len(retry)} to try again", flush=True)
        time.sleep(4)
    have = games_so_far()
    print(f"{len(have & set(order))} games in the catalogue", flush=True)
    pending = retry
    if pending: time.sleep(60)
print("done:", len(have & set(order)), "games of the", COUNT, "wanted")
