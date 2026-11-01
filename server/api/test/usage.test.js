// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import { test } from "node:test";
import assert from "node:assert/strict";
import { testDB } from "./d1.js";
import { validateUsage, saveUsage, usageSummary } from "../src/usage.js";
import { forget } from "../src/privacy.js";

const good = { client: "0f3c9a2e-1111-2222-3333-444455556666", app: "0.3.0", stores: ["steam", "epic"], controllerMode: true,
               clips: false, counter: true, pads: ["playStation"], firstGameMinutes: 12 };

test("usage is checked before it is kept", () => {
  assert.ok(validateUsage(good).usage);
  assert.equal(validateUsage({ ...good, stores: ["myspace"] }).error, "bad stores");
  assert.equal(validateUsage({ ...good, pads: ["wii"] }).error, "bad pads");
  assert.equal(validateUsage({ ...good, clips: "yes" }).error, "bad flag");
  assert.equal(validateUsage({ ...good, client: "Robert'); DROP" }).error, "bad client");
  assert.equal(validateUsage({ ...good, firstGameMinutes: -1 }).error, "bad firstGameMinutes");
  assert.equal(validateUsage({ ...good, firstGameMinutes: undefined }).usage.firstGameMinutes, null);
});

test("the owner sees what players use, how long to the first game, and who comes back", async () => {
  const db = testDB();
  const u = validateUsage(good).usage;
  await saveUsage(db, "a", u, "2026-09-01");
  await saveUsage(db, "a", { ...u, firstGameMinutes: null, controllerMode: false }, "2026-10-20");     // back after 7 and 30 days
  await saveUsage(db, "b", { ...u, stores: [], pads: [], counter: false, firstGameMinutes: 90 }, "2026-10-01");   // never back
  const s = await usageSummary(db, "2026-08-01", "2026-10-28");
  assert.equal(s.players, 2);
  assert.deepEqual(s.stores, { epic: 1, steam: 1 });
  assert.equal(s.noStore, 1);
  assert.deepEqual(s.features, { controllerMode: 2, clips: 0, counter: 1 });
  assert.deepEqual(s.pads, { playStation: 1 });
  assert.deepEqual(s.firstGame, { players: 2, median: 90, withinHour: 1 });
  assert.deepEqual(s.retention, { week: { players: 2, back: 1 }, month: { players: 1, back: 1 } });
});

test("\"Delete my data\" deletes usage too", async () => {
  const db = testDB();
  const { hash } = await import("../src/reports.js");
  await saveUsage(db, await hash("s", `player:${good.client}`), validateUsage(good).usage, "2026-10-28");
  await forget(db, "s", good.client);
  assert.equal(db.sqlite.prepare("SELECT COUNT(*) AS n FROM usage").get().n, 0);
});

test("usage comes in only from the app, a few times a day at most", async () => {
  const { default: worker } = await import("../src/index.js");
  const env = { DB: testDB(), SALT: "s", ADMIN_TOKEN: "t" };
  const post = (headers) => worker.fetch(new Request("http://x/v1/usage", { method: "POST", headers, body: JSON.stringify(good) }), env, {});
  assert.equal((await post({})).status, 400);
  for (let i = 0; i < 3; i++) assert.equal((await post({ "X-Sommelier-Client": "Sommelier/0.3.0" })).status, 201);
  assert.equal((await post({ "X-Sommelier-Client": "Sommelier/0.3.0" })).status, 429);
});
