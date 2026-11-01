-- Games the API knows: Steam's catalogue as people search it, the most-played games, and games players report.
CREATE TABLE games (
  store TEXT NOT NULL,
  id TEXT NOT NULL,
  title TEXT NOT NULL DEFAULT '',
  search TEXT NOT NULL DEFAULT '',          -- normalized title for search
  type TEXT,                                -- Steam's type ("game", "dlc", ...); null until details are fetched
  cover TEXT,
  header TEXT,
  mac INTEGER,                              -- Steam lists a Mac version
  single INTEGER,                           -- has single-player (Steam category 2)
  dx_min INTEGER,                           -- DirectX version in the minimum requirements, 0 unknown
  deck_category INTEGER,                    -- Valve's Steam Deck result: 0 unknown, 1 unsupported, 2 playable, 3 verified
  deck_tokens TEXT,                         -- JSON array of Valve's test notes
  popularity INTEGER,                       -- rank among Steam's most played, when it is there
  details_at INTEGER,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (store, id)
);
CREATE INDEX games_search ON games(search);
CREATE INDEX games_popularity ON games(popularity);

-- "Are We Anti-Cheat Yet?" (MIT License): games with anti-cheat and whether it runs under Wine.
CREATE TABLE anticheat (
  key TEXT PRIMARY KEY,                     -- "steam:<appid>" or "name:<normalized name>"
  name TEXT NOT NULL,
  status TEXT NOT NULL,
  anticheats TEXT NOT NULL                  -- JSON array
);

-- What players saw. One row per player and game: a new report replaces the player's previous one.
-- Nothing identifies a person: the player id is a random install id, hashed with a secret salt.
CREATE TABLE reports (
  client TEXT NOT NULL,
  store TEXT NOT NULL,
  game_id TEXT NOT NULL,
  steam_id TEXT,                            -- the game's Steam app, when the app knows it (for games from other stores)
  title TEXT,
  outcome TEXT NOT NULL,                    -- "ran", "crashed", "didNotStart"
  minutes INTEGER,
  fps_avg REAL,
  fps_low REAL,                             -- 1% low
  resolution TEXT,                          -- "2560x1440"
  chip TEXT,                                -- "Apple M2 Pro", "Intel Core i7"
  gpu_cores INTEGER,
  ram_gb INTEGER,
  macos TEXT,
  app_version TEXT,
  engine TEXT,
  backend TEXT,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (client, store, game_id)
);
CREATE INDEX reports_game ON reports(store, game_id);
CREATE INDEX reports_steam ON reports(steam_id);

-- Daily counters against floods (hashed keys only).
CREATE TABLE limits (
  key TEXT PRIMARY KEY,
  day INTEGER NOT NULL,
  count INTEGER NOT NULL
);

CREATE TABLE meta (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
