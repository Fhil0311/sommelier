-- What a player's Sommelier uses, once a day, only when "Share how games run" is on. No names, no paths, nothing
-- about the person: the player id is the install's random id hashed with a secret salt (as in reports).
CREATE TABLE usage (
  client TEXT NOT NULL,
  day TEXT NOT NULL,                        -- "2026-10-28" (UTC)
  app_version TEXT,
  stores TEXT NOT NULL,                     -- JSON array of the stores signed in: ["steam","epic"]
  controller_mode INTEGER NOT NULL,         -- Controller Mode opened since the last day sent
  clips INTEGER NOT NULL,                   -- clips turned on
  counter INTEGER NOT NULL,                 -- in-game counter turned on
  pads TEXT NOT NULL,                       -- JSON array of controller kinds seen: ["xbox","playStation","other"]
  first_game_minutes INTEGER,               -- minutes from the first start of Sommelier to the first game, sent once
  PRIMARY KEY (client, day)
);
CREATE INDEX usage_day ON usage(day);
