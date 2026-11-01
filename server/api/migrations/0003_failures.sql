-- Launch failures players chose to send from the app's "didn't start" sheet, after seeing exactly what goes.
-- The diagnostics are scrubbed by the app (home folder names, Steam ids, account names, tokens). Kept 180 days.
CREATE TABLE failures (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  created_at INTEGER NOT NULL,
  client TEXT NOT NULL,             -- salted hash of the install's random id
  store TEXT NOT NULL,
  game_id TEXT NOT NULL,
  steam_id TEXT,
  title TEXT,
  signature TEXT NOT NULL,          -- the first rule the app matched, or "unknown": what to look at first
  matched TEXT NOT NULL,            -- JSON array of the rule ids the app matched
  app_version TEXT,
  engine TEXT,
  backend TEXT,
  chip TEXT,
  macos TEXT,
  exit_code INTEGER,
  seconds_running INTEGER,
  diagnostics TEXT NOT NULL         -- the app's LaunchDiagnostics, as JSON
);
CREATE INDEX failures_signature ON failures(signature, created_at);
CREATE INDEX failures_game ON failures(store, game_id);
CREATE INDEX failures_created ON failures(created_at);
