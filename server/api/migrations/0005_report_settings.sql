-- How Sommelier ran the game in a report: whether the player picked the graphics ("manual") or Sommelier did ("auto"),
-- and the rest of the settings block as JSON (switches, known variables, plain arguments, fixes, shared shaders).
ALTER TABLE reports ADD COLUMN backend_choice TEXT;
ALTER TABLE reports ADD COLUMN settings TEXT;
