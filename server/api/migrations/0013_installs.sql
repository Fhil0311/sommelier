-- Each install, under a random id the app makes for this alone (not the reports' id), hashed with a secret salt:
-- when it was first and last heard from. Silent for 30 days, it counts as uninstalled; heard from again, it's back.
CREATE TABLE installs (
  id TEXT PRIMARY KEY,
  first_day TEXT NOT NULL,                  -- "2026-10-28" (UTC)
  last_day TEXT NOT NULL,
  version TEXT,
  country TEXT NOT NULL
);
CREATE INDEX installs_last ON installs(last_day);
