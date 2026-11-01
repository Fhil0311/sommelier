-- Whether the game asked for HDR in the session (Sommelier's DXMT notes it): the games with HDR, known to every app
-- before its first launch there (GET /v1/hdr.json). Null when the session couldn't tell (not on DXMT).
ALTER TABLE reports ADD COLUMN hdr INTEGER;
