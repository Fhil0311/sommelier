// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import { test } from "node:test";
import assert from "node:assert/strict";
import { checkAnnouncements } from "../src/announcements.js";

const good = { version: 1, announcements: [
  { id: "steam-outage", level: "important", title: { en: "Steam sign-in is down", ru: "Вход в Steam не работает" },
    body: { en: "Valve is fixing it.", ru: "Valve уже чинит." }, link: { url: "https://playsommelier.com/status", label: { en: "Details", ru: "Подробнее" } },
    from: "2026-10-21T00:00:00Z", until: "2026-10-23T00:00:00Z", belowApp: "0.3", games: ["steam:271590"], notify: true },
  { id: "hello", level: "info", title: { en: "Welcome to the beta" } },
] };

test("an announcements list", () => {
  assert.deepEqual(checkAnnouncements(good), []);
  assert.deepEqual(checkAnnouncements({ version: 1, announcements: [] }), []);
});

test("bad announcements are refused", () => {
  const one = (change) => checkAnnouncements({ version: 1, announcements: [{ ...good.announcements[1], ...change }] });
  assert.ok(one({ id: "Bad Id" }).length);
  assert.ok(one({ level: "urgent" }).length);
  assert.ok(one({ title: { ru: "Только по-русски" } }).length);            // English is the fallback
  assert.ok(one({ title: { en: "x".repeat(200) } }).length);
  assert.ok(one({ link: { url: "http://insecure.example" } }).length);
  assert.ok(one({ link: { url: "javascript:alert(1)" } }).length);
  assert.ok(one({ until: "soon" }).length);
  assert.ok(one({ from: "2026-10-23T00:00:00Z", until: "2026-10-21T00:00:00Z" }).length);
  assert.ok(one({ belowApp: "latest" }).length);
  assert.ok(one({ games: ["itch:1"] }).length);
  assert.ok(checkAnnouncements({ version: 1, announcements: [good.announcements[1], good.announcements[1]] }).length);   // the same id twice
  assert.ok(checkAnnouncements({ version: 2, announcements: [] }).length);
});

test("publishing needs the owner", async () => {
  const { default: worker } = await import("../src/index.js");
  const { testDB } = await import("./d1.js");
  const stored = {};
  const env = { DB: testDB(), SALT: "s", ADMIN_TOKEN: "secret",
    RELEASES: { get: async (k) => (stored[k] ? { body: stored[k], httpEtag: "e" } : null), put: async (k, v) => { stored[k] = v; } } };
  const put = (token, body) => worker.fetch(new Request("http://x/v1/announcements.json", { method: "PUT", headers: { Authorization: `Bearer ${token}` }, body: JSON.stringify(body) }), env, {});
  assert.equal((await put("guess", good)).status, 401);
  assert.equal((await put("secret", { version: 1, announcements: [{ id: "x" }] })).status, 400);
  assert.equal((await put("secret", good)).status, 200);
  const read = await worker.fetch(new Request("http://x/v1/announcements.json"), env, {});
  assert.equal((await read.json()).announcements.length, 2);
});
