// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import { test } from "node:test";
import assert from "node:assert/strict";
import { publishList, rollbackList, unsafeSecrets } from "../src/index.js";

function bucket() {
  const store = new Map();
  return {
    store,
    async get(key) { const v = store.get(key); return v == null ? null : { text: async () => v }; },
    async put(key, value) { store.set(key, String(value)); },
    async list({ prefix }) { return { objects: [...store.keys()].filter((k) => k.startsWith(prefix)).map((key) => ({ key })) }; },
    async delete(keys) { for (const k of [].concat(keys)) store.delete(k); },
  };
}

test("a published list can be rolled back to the one before", async () => {
  const env = { RELEASES: bucket() };
  await publishList(env, "recipes.json", "v1");
  await new Promise((r) => setTimeout(r, 5));
  await publishList(env, "recipes.json", "v2");
  assert.equal(env.RELEASES.store.get("recipes.json"), "v2");
  assert.ok(await rollbackList(env, "recipes.json"));
  assert.equal(env.RELEASES.store.get("recipes.json"), "v1");
  assert.equal(await rollbackList(env, "recipes.json"), null);              // nothing earlier than the first
});

test("a deployed service refuses the development secrets", () => {
  assert.equal(unsafeSecrets({ SALT: "dev-only-salt", ADMIN_TOKEN: "dev-only-admin" }), false);   // local
  assert.equal(unsafeSecrets({ ENVIRONMENT: "production", SALT: "dev-only-salt", ADMIN_TOKEN: "x".repeat(40) }), true);
  assert.equal(unsafeSecrets({ ENVIRONMENT: "production" }), true);
  assert.equal(unsafeSecrets({ ENVIRONMENT: "production", SALT: "s".repeat(40), ADMIN_TOKEN: "t".repeat(40) }), false);
});

test("the weekly backup copies the tables and keeps eight weeks", async () => {
  const { backupDatabase } = await import("../src/index.js");
  const { testDB } = await import("./d1.js");
  const db = testDB();
  db.sqlite.prepare("INSERT INTO meta (key, value) VALUES ('a', 'b')").run();
  const env = { DB: db, RELEASES: bucket() };
  for (let week = 0; week < 10; week++) await backupDatabase(env, Date.UTC(2026, 0, 5 + week * 7));
  const days = new Set([...env.RELEASES.store.keys()].map((k) => k.split("/")[1]));
  assert.equal(days.size, 8);
  assert.ok(env.RELEASES.store.get("backups/2026-03-09/meta-0000.json").includes('"value":"b"'));
});
