// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import { test } from "node:test";
import assert from "node:assert/strict";
import { testDB } from "./d1.js";
import { search } from "../src/catalog.js";
import { parseGOGSearch } from "../src/sources.js";

const NOW = 1_800_000_000_000;

function steamGame(db, id, title, { popularity = null, reviews = null } = {}) {
  db.sqlite.prepare(`INSERT INTO games (store, id, title, search, type, popularity, reviews, details_at, created_at)
    VALUES ('steam', ?, ?, lower(?), 'game', ?, ?, ?, ?)`).run(id, title, title, popularity, reviews, NOW, NOW);
}

test("most played first, then by reviews; GOG-only games after, a title Steam sells shown once as Steam's", async () => {
  const db = testDB();
  steamGame(db, "1", "control ultimate", { reviews: 90_000 });
  steamGame(db, "2", "control machine", { reviews: 12 });
  steamGame(db, "3", "control chart", { popularity: 40, reviews: 5 });
  const sources = {
    search: async () => [], details: async () => null, deck: async () => null,
    gogSearch: async () => [{ id: "10", title: "Control Ultimate", cover: "c", header: "h" }, { id: "11", title: "Control Old", cover: null, header: null }],
  };
  const games = await search(db, "control", 10, NOW, null, sources);
  assert.deepEqual(games.map((g) => `${g.store}:${g.id}`), ["steam:3", "steam:1", "steam:2", "gog:11"]);
});

test("Epic, Ubisoft and EA games come from players' reports", async () => {
  const db = testDB();
  db.sqlite.prepare(`INSERT INTO reports (client, store, game_id, title, outcome, created_at) VALUES ('p', 'epic', 'Sage', 'Alan Wake 2', 'ran', ?)`).run(NOW);
  const games = await search(db, "alan wake", 10, NOW, null, { search: async () => [], details: async () => null, deck: async () => null });
  assert.deepEqual(games.map((g) => [g.store, g.id, g.title]), [["epic", "Sage", "Alan Wake 2"]]);
  assert.equal(games[0].compatibility.verdict === undefined, false);
});

test("GOG's catalogue answer", () => {
  assert.deepEqual(parseGOGSearch({ products: [{ id: "1207658924", title: "The Witcher", coverVertical: "v", coverHorizontal: "h" }, { id: "x" }] }),
    [{ id: "1207658924", title: "The Witcher", cover: "v", header: "h" }]);
});

test("editions of one game are one game", async () => {
  const { baseTitle, sameGame } = await import("../src/catalog.js");
  assert.ok(sameGame(baseTitle("The Witcher: Enhanced Edition"), baseTitle("The Witcher: Enhanced Edition Director's Cut")));
  assert.ok(sameGame(baseTitle("Disco Elysium - The Final Cut Bundle"), baseTitle("Disco Elysium - The Final Cut")));
  assert.ok(!sameGame(baseTitle("The Witcher 2"), baseTitle("The Witcher 3")));
  assert.ok(!sameGame(baseTitle("Star Control III"), baseTitle("CONTROL Ultimate Edition")));
});

test("a longer title is another game", async () => {
  const { baseTitle, sameGame } = await import("../src/catalog.js");
  assert.ok(!sameGame(baseTitle("Control Old"), baseTitle("CONTROL Ultimate Edition")));
  assert.ok(!sameGame(baseTitle("The Witcher"), baseTitle("The Witcher 3: Wild Hunt")));
});

test("the export gives each game's page data, stores where the title is known, and pages by appid", async () => {
  const { gamesExport } = await import("../src/catalog.js");
  const db = testDB();
  for (const [id, title, slug] of [["10", "Alpha Quest", "alpha-quest"], ["20", "Beta Run", "beta-run"], ["30", "Gamma Rush", "gamma-rush"]]) {
    db.sqlite.prepare(`INSERT INTO games (store, id, title, search, type, slug, developer, year, genres, size_gb, details_at, created_at)
      VALUES ('steam', ?, ?, lower(?), 'game', ?, 'Dev', 2020, '["Action"]', 12.5, ?, ?)`).run(id, title, title, slug, NOW, NOW);
  }
  db.sqlite.prepare(`INSERT INTO games (store, id, title, search, type, created_at) VALUES ('gog', '900', 'Beta Run', 'beta run', 'game', ?)`).run(NOW);
  db.sqlite.prepare(`INSERT INTO reports (client, store, game_id, title, outcome, created_at) VALUES ('p', 'epic', 'E1', 'Beta Run', 'ran', ?)`).run(NOW);
  const first = await gamesExport(db, null, 2);
  assert.deepEqual(first.games.map((g) => g.slug), ["alpha-quest", "beta-run"]);
  assert.equal(first.next, "20");
  assert.deepEqual(first.games[1].stores, ["steam", "epic", "gog"]);
  assert.deepEqual([first.games[0].developer, first.games[0].year, first.games[0].genres, first.games[0].sizeGB], ["Dev", 2020, ["Action"], 12.5]);
  const rest = await gamesExport(db, first.next, 2);
  assert.deepEqual(rest.games.map((g) => g.slug), ["gamma-rush"]);
  assert.equal(rest.next, null);
});
