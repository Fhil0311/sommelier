-- What a game's page on the site shows (developer, year, genres, download size) and its address there (slug).
ALTER TABLE games ADD COLUMN developer TEXT;
ALTER TABLE games ADD COLUMN year INTEGER;
ALTER TABLE games ADD COLUMN genres TEXT;          -- JSON array of Steam's genre names
ALTER TABLE games ADD COLUMN size_gb REAL;         -- the minimum requirements' "Storage"
ALTER TABLE games ADD COLUMN slug TEXT;
CREATE INDEX games_slug ON games(slug);
