// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import { test } from "node:test";
import assert from "node:assert/strict";
import { testDB } from "./d1.js";
import { validateForget, forget, prune, allow, over, steamGate, RETENTION } from "../src/privacy.js";
import { hash } from "../src/reports.js";
import { search } from "../src/catalog.js";
import worker from "../src/index.js";

const DAY = 86_400_000;
const NOW = Date.UTC(2026, 9, 21, 12);
const CLIENT = "3f2a9c1e-5b7d-4e8f-9a0b-1c2d3e4f5a6b";

async function seed(db, player, other) {
  for (const [client, game] of [[player, "1"], [player, "2"], [other, "1"]]) {
    await db.prepare("INSERT INTO reports (client, store, game_id, outcome, created_at) VALUES (?, 'steam', ?, 'ran', ?)").bind(client, game, NOW).run();
  }
  await db.prepare("INSERT INTO failures (created_at, client, store, game_id, signature, matched, diagnostics) VALUES (?, ?, 'epic', 'Sage', 'unknown', '[]', '{}')").bind(NOW, player).run();
  await db.prepare("INSERT INTO limits (key, day, count) VALUES (?, ?, 3)").bind(`p:${player}`, Math.floor(NOW / DAY)).run();
}

test("a delete request names the install", () => {
  assert.deepEqual(validateForget({ client: CLIENT.toUpperCase() }), { client: CLIENT });
  assert.ok(validateForget({ client: "me" }).error);
  assert.ok(validateForget(null).error);
});

test("forgetting deletes one install's reports, failures and counters, and nothing else", async () => {
  const db = testDB();
  const player = await hash("salt", `player:${CLIENT}`);
  await seed(db, player, "someone-else");
  assert.deepEqual(await forget(db, "salt", CLIENT), { reports: 2, failures: 1 });
  assert.equal((await db.prepare("SELECT COUNT(*) AS n FROM reports").first()).n, 1);
  assert.equal((await db.prepare("SELECT COUNT(*) AS n FROM failures").first()).n, 0);
  assert.equal((await db.prepare("SELECT COUNT(*) AS n FROM limits").first()).n, 0);
});

test("the daily clean-up drops old reports and counters", async () => {
  const db = testDB();
  await db.prepare("INSERT INTO reports (client, store, game_id, outcome, created_at) VALUES ('a', 'steam', '1', 'ran', ?)").bind(NOW - (RETENTION.reportsDays + 1) * DAY).run();
  await db.prepare("INSERT INTO reports (client, store, game_id, outcome, created_at) VALUES ('b', 'steam', '1', 'ran', ?)").bind(NOW - DAY).run();
  await db.prepare("INSERT INTO limits (key, day, count) VALUES ('old', ?, 1), ('new', ?, 1)").bind(Math.floor(NOW / DAY) - 5, Math.floor(NOW / DAY)).run();
  await prune(db, NOW);
  assert.equal((await db.prepare("SELECT COUNT(*) AS n FROM reports").first()).n, 1);
  assert.deepEqual((await db.prepare("SELECT key FROM limits").all()).results.map((r) => r.key), ["new"]);
});

test("daily limits", async () => {
  const db = testDB();
  assert.equal(await allow(db, "k", 2, NOW), true);
  assert.equal(await over(db, "k", 2, NOW), false);
  assert.equal(await allow(db, "k", 2, NOW), true);
  assert.equal(await over(db, "k", 2, NOW), true);
  assert.equal(await allow(db, "k", 2, NOW), false);
  assert.equal(await allow(db, "k", 2, NOW + DAY), true);        // a new day starts again
});

test("search asks Steam once per words a day, and stops at the address limit", async () => {
  const db = testDB();
  let asked = 0;
  const steam = { search: async () => { asked += 1; return []; }, details: async () => null, deck: async () => null };
  const gate = () => steamGate(db, "addr", NOW, { address: 2, all: 100 });
  await search(db, "Hollow Knight", 20, NOW, null, steam, gate());
  await search(db, "hollow  knight", 20, NOW, null, steam, gate());     // same words: remembered
  assert.equal(asked, 1);
  await search(db, "Celeste", 20, NOW, null, steam, gate());
  await search(db, "Hades", 20, NOW, null, steam, gate());               // third Steam search from this address
  assert.equal(asked, 2);
  await search(db, "Hollow Knight", 20, NOW + 2 * DAY, null, steam, steamGate(db, "addr", NOW + 2 * DAY, { address: 2, all: 100 }));
  assert.equal(asked, 3);
});

test("the delete route and the owner's lock-out", async () => {
  const db = testDB();
  const env = { DB: db, SALT: "salt", ADMIN_TOKEN: "secret-token" };
  const player = await hash("salt", `player:${CLIENT}`);
  await seed(db, player, "someone-else");
  const post = (body) => worker.fetch(new Request("http://x/v1/forget", { method: "POST", body: JSON.stringify(body) }), env, {});
  const ok = await post({ client: CLIENT });
  assert.equal(ok.status, 200);
  assert.deepEqual(await ok.json(), { deleted: { reports: 2, failures: 1 } });
  assert.equal((await post({ client: "nope" })).status, 400);

  const stats = (token) => worker.fetch(new Request("http://x/v1/stats", { headers: { Authorization: `Bearer ${token}` } }), env, {});
  for (let i = 0; i < 20; i++) assert.equal((await stats("guess")).status, 401);
  assert.equal((await stats("secret-token")).status, 401);                 // locked out for the day, even with the right token
  const other = await worker.fetch(new Request("http://x/v1/stats", { headers: { Authorization: "Bearer secret-token", "CF-Connecting-IP": "1.2.3.4" } }), env, {});
  assert.equal(other.status, 200);
});
