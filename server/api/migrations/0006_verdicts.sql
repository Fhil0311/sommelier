-- The owner's own answers for games tested on our Macs: they decide a game's answer as players' reports would
-- (same reason, "players"). `steam_id` ties a copy from another store to its Steam game.
CREATE TABLE verdicts (
  store TEXT NOT NULL,
  id TEXT NOT NULL,
  steam_id TEXT,
  verdict TEXT NOT NULL,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (store, id)
);
CREATE INDEX verdicts_steam ON verdicts(steam_id);
