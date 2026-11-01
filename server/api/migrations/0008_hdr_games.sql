-- Our own answers about HDR, from research (server/hdr/hdr-games.json, published with scripts/publish-hdr.sh). They
-- decide a game's place in GET /v1/hdr.json; players' reports fill in the games not listed here.
CREATE TABLE hdr_games (
  game TEXT PRIMARY KEY,          -- "steam:292030"
  hdr INTEGER NOT NULL,           -- 1 has HDR, 0 doesn't
  source TEXT,                    -- where it was checked
  updated_at INTEGER NOT NULL
);
