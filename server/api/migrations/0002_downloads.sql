-- Download and update-check counts per day. Nothing about the person: the version, where the request came from
-- (the site's download button or the app's updater) and the country Cloudflare reports for the request.
CREATE TABLE counts (
  day TEXT NOT NULL,              -- "2026-10-21" (UTC)
  kind TEXT NOT NULL,             -- "download": an app archive; "check": the updater asked for the appcast
  version TEXT NOT NULL,          -- the archive's version, or the checking app's version
  source TEXT NOT NULL,           -- "site", "update" or "other"
  country TEXT NOT NULL,          -- two letters, "XX" when unknown
  count INTEGER NOT NULL,
  PRIMARY KEY (day, kind, version, source, country)
);
