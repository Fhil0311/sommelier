# Sommelier API

The public API at `https://api.playsommelier.com` (once deployed): the compatibility database the site and the app read,
and the reports players send from the app. A Cloudflare Worker with a D1 (SQLite) database; free tier.

## Where the answers come from

| Source | What it gives |
| --- | --- |
| Valve's Steam Deck results | the first guess: Deck runs Windows games through Wine, as Sommelier does |
| [Are We Anti-Cheat Yet?](https://areweanticheatyet.com) (MIT) | which games' anti-cheat keeps Wine out |
| Steam store details | single-player or online-only, Mac version, DirectX version, artwork |
| Steam's most-played chart | which games the catalogue fills in first |
| Players' reports | what really happened on Macs; once there are 3, they decide the answer |

The catalogue grows as people search: a search with few matches asks Steam's own search and adds what it finds.
Once a day the Worker refreshes the anti-cheat list and the most-played chart and fetches details for games that
have none or old ones (40 per run, to stay gentle with Steam).

## Compatibility

The same model as the app (`Compatibility` in `Sources/SommelierKit/Library/Compatibility.swift`):

```json
{ "verdict": "likely", "reason": "deckVerified", "notes": ["noOnline"] }
```

- `verdict`, best first: `works`, `likely` (should work), `unknown`, `wontRun`.
- `notes`, at most two: `noOnline` (anti-cheat closes online play; single-player can run), `demanding`
  (resource-heavy), `macVersion` (the store lists a Mac version).
- `reason`: `players`, `playersFail`, `deckVerified`, `deckPlayable`, `deckTooDemanding`, `deckFails`,
  `onlineOnlyBlocked`, `offlineUnknown`, `noData`.

One difference from the app: a store's Mac version is only a note here, because it may be a 32-bit build that no
longer runs, which only the app can check after installing.

## Routes

All answers are JSON. Reads are public, cached for a few minutes, and allow any origin (CORS).

### `GET /v1/games/search?q=witcher&limit=20`

```json
{ "games": [
  { "store": "steam", "id": "292030", "title": "The Witcher 3: Wild Hunt — Remastered",
    "cover": "https://shared.cloudflare.steamstatic.com/store_item_assets/steam/apps/292030/library_600x900.jpg",
    "header": "https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/292030/header.jpg?t=…",
    "compatibility": { "verdict": "likely", "notes": [] } }
] }
```

`limit` 1–50 (default 20). The first search for something new can take a second or two while Steam is asked.
`cover` (2:3) can be missing on Steam's side for old games: fall back to `header` (wide).

### `GET /v1/games/top?limit=50`

The most-played Steam games the catalogue has details for, in the chart's order. Same item shape as search.

### `GET /v1/games/{store}/{id}`

A game's page. `store` is `steam`, `epic`, `gog`, `ea`, `ubisoft` or `battlenet`; Steam games are filled in on
first request. Games from other stores are known from players' reports (and count toward their Steam game).

```json
{
  "store": "steam", "id": "271590", "title": "Grand Theft Auto V Legacy", "cover": "…", "header": "…",
  "compatibility": { "verdict": "works", "reason": "players", "notes": ["noOnline"] },
  "steam": { "appid": "271590", "macVersion": false, "singlePlayer": true, "directX": 10, "deck": { "category": 1 } },
  "antiCheat": { "status": "Denied", "anticheats": ["BattlEye"] },
  "players": {
    "reports": 4, "ran": 4, "failed": 0,
    "systems": [
      { "chip": "Apple M2 Pro", "reports": 3, "ran": 3, "fpsMedian": 58, "fpsReports": 3 },
      { "chip": "Apple M1", "reports": 1, "ran": 1, "fpsMedian": 31, "fpsReports": 1 }
    ]
  },
  "updated": "2026-10-20T21:40:12.000Z"
}
```

`players.systems` is the start of the frame-rate database: by Mac chip, how many players ran the game and the
median frame rate they saw.

### `POST /v1/reports`

Sent by the app after a session, only when the player has turned reports on. Needs the `X-Sommelier-Client`
header. One report per player and game: a new one replaces the old.

```json
{
  "client": "3f2a9c1e-5b7d-4e8f-9a0b-1c2d3e4f5a6b",
  "game": { "store": "epic", "id": "9d2d0eb64d5c44529cece33fe2a46482", "title": "Grand Theft Auto V", "steamAppID": "271590" },
  "outcome": "ran",
  "minutes": 42,
  "fps": { "average": 58.4, "low": 31, "resolution": "2560x1440" },
  "system": { "chip": "Apple M2 Pro", "gpuCores": 19, "ramGB": 32, "macOS": "15.6" },
  "sommelier": { "app": "0.1", "engine": "2.2.1", "backend": "dxmt" },
  "settings": { "backendChoice": "manual", "retina": true, "metalFX": false, "rayTracing": true, "commandAsControl": false,
                "environment": { "DXMT_CONFIG": "d3d11.metalSpatialUpscaleFactor=1.5" }, "arguments": ["-dx11"],
                "otherCustom": 1, "fixes": ["overcooked-gl"], "shadersFromOthers": true }
}
```

- `outcome`: `ran` (needs `minutes` ≥ 1), `crashed`, `didNotStart`. `fps` only with `ran`.
- `mods: true` (optional) says mods were in play in the session: a mod on, or a loader's files in the game. Only the
  flag, never which mods. Such a session says nothing about the game itself, so it casts no vote in the community
  verdict and stays out of the game's numbers and the owner's compatibility stats.
- `settings` (optional, newer apps): how Sommelier ran the game. `backendChoice` is `manual` when the player picked the
  graphics. Only variables of the graphics layers and Wine with plain values (no paths, nothing named `PATH`, `FILE`,
  `DIR`, `LOG`) and plain `-flags` are allowed; the app counts the player's other variables and arguments in
  `otherCustom` without sending them. A game's page sums reports by graphics in `players.backends`.
- `client` is a random id the app makes once per install. The server keeps only a salted hash of it; addresses are
  never stored (daily flood counters keep salted hashes).
- Limits: 100 reports a day per player, 200 per address. Answers `201 {"saved": true}`, `400 {"error": "…"}`
  naming the bad field, or `429`.

### App releases: `GET /v1/appcast.xml`, `GET /v1/releases/Sommelier-<version>.zip`, `GET /v1/download/latest`

The appcast Sparkle reads and the archives it points to, from the R2 bucket `sommelier-releases`
(`scripts/release-app.sh` puts them there). `/v1/download/latest` redirects to the newest archive: the site's download
button.

Counted, without identifying anyone (`src/stats.js`, table `counts`): each full archive download by version, day,
source (`site` for browsers, `update` for the app's updater, `other`) and country (Cloudflare's `CF-IPCountry`); and
each appcast request from the app by its version (the User-Agent says `Sommelier/<version> Sparkle/<version>`).
Sommelier checks once a day, so checks per day approximate active installs.

### Launch failures: `POST /v1/failures`

Sent from the app's "didn't start" sheet when the player presses "Send Report" after seeing a preview of exactly what
goes: the scrubbed diagnostics (end of the launch log, Steam's content log, macOS's crash report; home folder names,
Steam ids, account names and tokens taken out by the app), the rule ids the app matched, the app's version.
Needs the `X-Sommelier-Client` header; at most 256 KB; 20 a day per player, 50 per address. Kept 180 days.

```json
{ "client": "3f2a9c1e-…", "game": { "store": "epic", "id": "Sage", "title": "Overcooked", "steamAppID": "448510" },
  "diagnostics": { "gameID": "epic:Sage", "logTail": "…", "exitCode": 1, "secondsRunning": 4, "engineVersion": "2.2.1", "backend": "dxmt", "chip": "Apple M4 Pro", "macOS": "…" },
  "matched": ["overcooked-gl"], "sommelier": { "app": "0.1.0" } }
```

The owner reads them (bearer `ADMIN_TOKEN`): `GET /v1/failures?days=30` gives counts by problem (`signature`: the
first matched rule, or `unknown`), the games failing for most players, and the latest failures nothing recognised;
`GET /v1/failures/{id}` gives one with its diagnostics.

### The fixes list: `GET /v1/fixes.json`, `PUT /v1/fixes.json`

The online half of the app's one-click fixes. Every Sommelier reads it once a day; its rules come before the built-in
ones and replace them by id. A rule can only pick one of the app's own actions (`switchGraphics`, `installDotNet`,
`installVCRuntime`, `disableEAOverlay`, `setEnvironment`, `setUpDirectX12`, `setUpEAApp`, `turnOffTurbo`,
`overrideDLL`, `runExecutable`, `setWindowsVersion`, `addArguments`), never run anything else.
The list lives in `server/fixes/fixes.json`; `scripts/publish-fixes.sh` checks and publishes it (PUT, bearer
`ADMIN_TOKEN`). Format (the app's Codable form):

```json
{ "version": 1, "rules": [
  { "id": "overcooked-gl", "cause": "Overcooked fell back to OpenGL, which is slow. DXMT runs it on Metal.",
    "causes": { "ru": "Overcooked перешла на OpenGL, а он медленный. DXMT запустит её через Metal." },
    "patterns": ["OpenGL core profile"],
    "conditions": [ { "game": { "_0": "epic:Sage" } }, { "notNative": {} } ],
    "action": { "switchGraphics": { "_0": "dxmt" } } }
] }
```

Conditions: `backendIs`, `backendIsNot`, `store`, `notNative`, `noD3DMetal`, `game`. Patterns are regular expressions
matched against the launch's logs. A rule the app can't read (an action added in a later version) is skipped by older
apps instead of breaking the list.

### Recipes: `GET /v1/recipes.json`, `PUT /v1/recipes.json`, `GET /v1/recipes/candidates`

How games are known to start. Every Sommelier reads the list once a day and, before a game's first launch there,
applies its recipe when the player left the graphics on Automatic: a list of the app's own fix actions (the same
closed list as `fixes.json`, plus `overrideDLL`, `runExecutable`, `setWindowsVersion`, `addArguments`). The app
records them as applied fixes (undoable from the game's menu) and reports the session with
`backendChoice: "recipe"`. The list lives in `server/fixes/recipes.json`; `scripts/publish-recipes.sh` checks and
publishes it (PUT, bearer `ADMIN_TOKEN`). Candidates from the protonfixes database come from
`server/recipes/from-protonfixes.py` (BSD-2-Clause; facts re-expressed, no code).

```json
{ "version": 1, "recipes": [
  { "game": "steam:1903340", "actions": [ { "switchGraphics": { "_0": "d3dMetal" } } ], "players": 4, "note": "Crashes in DXMT", "source": "reports" },
  { "game": "steam:49520", "actions": [ { "runExecutable": { "instead": "Launcher.exe", "run": "Borderlands2.exe" } },
                                        { "addArguments": { "_0": ["-NoSplash"] } } ], "source": "protonfixes" },
  { "game": "gog:1207658924", "actions": [ { "overrideDLL": { "_0": "ddraw", "_1": "n,b" } }, { "setWindowsVersion": { "version": "win7", "exe": "game.exe" } } ] }
] }
```

`editConfig`: a value in the game's own settings file. `file` is `<root>:<relative path>` with root `game` (the
install folder), `appdata`, `roaming`, `documents` or `unreal` (`unreal:GameUserSettings.ini`, found by the Unreal
adapter); only ini-style files, never a path out of those folders. `section` and `key` name the entry; with `field`
the key holds a struct (`SettingsData=(…,ConsoleGraphicPreset=0)`) and that field is set. `${level}` in the value is
the Mac's tuning level (0 low … 3 epic). Applied after the tuning, so a game's own preset can follow it. Every file
is copied first and the edit is undone from the game's menu.

`editSave`: whole-number values inside one struct of the game's Unreal save file (`GVAS`, Unreal 5.5 tags), for
games that keep their options in a save and apply them over the ini. `file` as for `editConfig` but `.sav`, and
one `*` may stand for the folder named after the player (`appdata:Sandfall/Saved/SaveGames/*/SharedGameUserSettings.sav`);
`structName` the top-level struct, `values` the ints by name (`${level}` allowed). A value already there is replaced,
a missing one added; nothing is touched when the struct can't be read through.

`runExecutable`: `instead` is the end of the launcher's path under the game's folder, `run` is relative to the
launcher's folder. For Steam games the engine's ntdll does the swap (`SOMMELIER_EXE_REDIRECTS`); Epic and GOG games
are started by Sommelier itself. `setWindowsVersion` needs the program's file name (Wine's per-program setting).

`GET /v1/recipes/candidates` (owner) lists the games whose reports disagree by backend: one backend ran for at least
three different players (80 % of its reports), another failed for at least half of its. `backendChoice: "retry"` in
a report means the player took the backend from the "didn't start" sheet's offer, so those rows show where the offer
pays off. Recipes are published by hand from this list.

### `GET /v1/hdr.json`

The games that have HDR: a report's `hdr: true` says the game asked for an HDR colour space in that session
(Sommelier's DXMT notes it; reports from other graphics leave it out). Every app reads the list once a day and
offers the HDR switch for these games before their first launch. `{ "version": 1, "games": ["steam:292030",
"ubisoft:2688", …] }`; a copy from another store adds its Steam id too. Cached an hour.

Our own researched answers (`server/hdr/hdr-games.json`, published by `scripts/publish-hdr.sh` with
`PUT /v1/hdr.json`, bearer `ADMIN_TOKEN`, body `{ "version": 1, "games": [ { "game": "steam:292030", "hdr": true,
"source": "https://…" } ] }`, replaces the list whole) decide for the games they name, yes or no; players' reports
add the rest.

### Mods: `GET /v1/mods.json`, `PUT /v1/mods.json`, `GET /v1/mods/modio/{gameID}/…`

How each game's mods are installed, one entry per game: the loaders (frameworks) its mods need and where their
files come from (a GitHub release asset, an author's page through the app's embedded browser, a Nexus mod), the
kinds of mods and where each goes, how the load order is written, what conflicts, which logs give away a broken
mod, and whether the game may go online with mods. Data the app follows, never code: the service checks every
field the app reads (ids, globs, `root:relative/path` places with no way out of their root, closed lists of
values, DLL overrides and components from the app's own lists, a SHA-256 for every download). The list lives in
`server/mods/mods.json`; `scripts/publish-mods.sh` refuses it until every download has its hash (a download
through the browser may wait for its), signs it with the update key and publishes it (PUT, bearer
`ADMIN_TOKEN`). Signed like the recipes, kept with its earlier versions for `POST /v1/mods.json/rollback`.

`GET /v1/mods/modio/{gameID}/mods`, `…/mods/{id}`, `…/mods/{id}/files`, `…/mods/{id}/files/{fileID}`: the mod.io
catalogue of a game, read with Sommelier's own key (the `MODIO_API_KEY` secret), which never leaves the service.
mod.io's own query parameters (`_q`, `_limit`, `_offset`, `_sort`, `tags-in`…) pass through; answers are mod.io's
JSON, kept ten minutes. Only games whose published entry names a mod.io `gameID` are served; 600 requests a day
per address. The app downloads a file itself from the link in a file's answer (`binary_url`); nothing is
re-uploaded.

### `POST /v1/forget`

"Delete my data" in the app's Privacy settings. Body `{ "client": "<the install's random id>" }`. Deletes every session
report and launch failure sent from that install, and its flood counters; the app then starts over under a new id.
Answers `{"deleted": {"reports": 2, "failures": 1}}`. 20 requests a day per address.

### Privacy and limits

| What | Kept |
| --- | --- |
| Session reports | 2 years, or until the player deletes them |
| Launch failures | 180 days, or until the player deletes them |
| Download and install counts | always: they hold nothing about anyone |
| Daily flood counters | 2 days |
| Searches passed on to Steam | 1 day |

Nothing stores an address or a player's id in the clear: both are hashed with the secret `SALT`. The daily upkeep
deletes what is past its time.

Limits that keep a script from running the API (and our standing with Steam) down, in `src/privacy.js`:

- Steam is asked (a search the catalogue can't answer, or a game page without details) at most 100 times a day per
  address and 4000 times a day for everyone. Past that, answers come from the catalogue alone. The same search words
  ask Steam once a day at most.
- Reports: 100 a day per player, 200 per address. Launch failures: 20 and 50.
- Owner routes: after 20 wrong tokens in a day, an address is refused even with the right one until the next day.

There is no app key or request signing: anything built into the app can be pulled out of it, so the limits above
are what protects the API.

### Announcements: `GET /v1/announcements.json`, `PUT /v1/announcements.json`

Messages from the team to players. The app reads the list when it starts and every three hours, and shows what
applies as a banner over the library until the player closes it; with `notify`, also once as a macOS notification.
The owner publishes from the stats page (`/admin`, "Объявления игрокам") or with PUT (bearer `ADMIN_TOKEN`).

```json
{ "version": 1, "announcements": [
  { "id": "steam-outage", "level": "important",
    "title": { "en": "Steam sign-in is down", "ru": "Вход в Steam не работает" },
    "body": { "en": "Valve is fixing it." }, "link": { "url": "https://…", "label": { "en": "Details" } },
    "from": "2026-10-21T00:00:00Z", "until": "2026-10-23T00:00:00Z",
    "minApp": "0.2", "belowApp": "0.3", "games": ["steam:271590"], "notify": true }
] }
```

- `level`: `info` or `important` (shown first, with an orange frame). Texts by language; English is required.
- Optional: `from`/`until` (when), `minApp`/`belowApp` (which versions), `games` (only players who have one),
  `link` (https only), `notify`. At most 50 announcements.
- Not instant: a player sees a new one within three hours, or when Sommelier starts.

### The owner's answers: `PUT /v1/verdicts/{store}/{id}`, `DELETE …`, `GET /v1/verdicts`

For games tested on our Macs (bearer `ADMIN_TOKEN`). Body `{ "verdict": "works" | "wontRun", "steamAppID": "448510" }`
(`steamAppID` ties a copy from another store to its Steam game). An answer decides the game's verdict before anything
else, shown as players' word (reason `players` / `playersFail`): no label of its own.

```sh
curl -X PUT -H "Authorization: Bearer $ADMIN_TOKEN" -d '{"verdict":"works"}' https://api.playsommelier.com/v1/verdicts/steam/648800
```

### `GET /v1/stats?days=30`

The owner's numbers. Needs `Authorization: Bearer <ADMIN_TOKEN>` (a Worker secret).

```json
{
  "since": "2026-09-22",
  "downloads": { "total": 4, "bySource": { "site": 3, "update": 1 }, "byVersion": { "0.2.0": 4 },
                 "byCountry": { "AM": 3, "LT": 1 }, "byDay": [{ "day": "2026-10-20", "count": 4 }] },
  "activeInstalls": { "byDay": [{ "day": "2026-10-20", "count": 3 }], "latestDay": "2026-10-20",
                      "byVersion": { "0.1.0": 2, "0.2.0": 1 } },
  "reports": { "total": 6, "recent": 6, "byOutcome": { "ran": 5, "crashed": 1 }, "byDay": [{ "day": "2026-10-20", "count": 6 }],
               "byChip": { "Apple M2 Pro": 4 }, "topGames": [{ "game": "271590", "title": "GTA V", "reports": 4, "ran": 4, "fps": 58 }] },
  "catalogue": { "games": 48 }
}
```

### `GET /admin`

The owner's stats page: downloads and active installs by day, sources, countries, versions, players' reports, and
launch failures (a click on an unrecognised one opens its logs). The page holds no data; it asks for `ADMIN_TOKEN`,
keeps it in that browser only, and reads `/v1/stats` and `/v1/failures` with it. Served with a strict
Content-Security-Policy and `noindex`.

### `GET /v1/health`

`{"ok": true}`.

## Running it

```sh
npm test                                    # unit tests (Node 20+)
npx wrangler@4 d1 migrations apply sommelier --local
npx wrangler@4 dev --port 8788 --test-scheduled
curl "http://127.0.0.1:8788/__scheduled?cron=17+4+*+*+*"     # run the daily upkeep now
```

Deploying needs the Cloudflare account: create the D1 database (`wrangler d1 create sommelier`) and the R2 bucket
(`wrangler r2 bucket create sommelier-releases`), put the database id in `wrangler.toml`, set the secrets
(`wrangler secret put SALT`, `wrangler secret put ADMIN_TOKEN`, and `wrangler secret put MODIO_API_KEY` for the mod.io
catalogue), then `npm run deploy` and route `api.playsommelier.com` to it.
