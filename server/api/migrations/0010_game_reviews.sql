-- How many Steam reviews a game has: how search ranks games outside the most-played chart. For GOG games, their
-- place in GOG's bestselling order for the words searched (lower is more popular).
ALTER TABLE games ADD COLUMN reviews INTEGER;
ALTER TABLE games ADD COLUMN store_rank INTEGER;
