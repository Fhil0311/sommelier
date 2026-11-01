-- Searches already passed on to Steam's own search, so the same words don't ask Steam again for a day.
CREATE TABLE steam_queries (
  query TEXT PRIMARY KEY,                   -- normalized search words
  at INTEGER NOT NULL
);
CREATE INDEX failures_client ON failures(client);
