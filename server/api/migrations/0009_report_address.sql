-- The sender's address as a salted hash (as the flood counters keep it): a game's community verdict counts one vote
-- per address, so one computer posing as many players can't flip a game to "works".
ALTER TABLE reports ADD COLUMN address TEXT;
