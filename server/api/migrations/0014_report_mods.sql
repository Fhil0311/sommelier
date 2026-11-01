-- Whether mods were in play in the session (a mod on, or a loader's files in the game): only the flag, never which
-- mods. A modded session says nothing about the game itself, so the community verdict, a game's numbers and the
-- owner's compatibility stats leave these reports out. Null from apps that don't say.
ALTER TABLE reports ADD COLUMN mods INTEGER;
