// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import test from "node:test";
import assert from "node:assert/strict";
import { checkToolkit, normalizeLink, versionsOn, watchToolkit, DEFAULT_TOOLKIT } from "../src/toolkit.js";

test("the built-in link passes, others don't", () => {
  assert.deepEqual(checkToolkit(DEFAULT_TOOLKIT), []);
  assert.notDeepEqual(checkToolkit({ version: 1, download: "https://evil.example/Game_Porting_Toolkit.dmg" }), []);
  assert.notDeepEqual(checkToolkit({ version: 1, download: "https://developer.apple.com/services-account/download?path=/Developer_Tools/x/y.pkg" }), []);
});

test("the older-macOS link is checked too, and optional", () => {
  assert.deepEqual(checkToolkit({ version: 1, download: DEFAULT_TOOLKIT.download }), []);
  assert.deepEqual(checkToolkit({ version: 1, download: DEFAULT_TOOLKIT.download, legacy: DEFAULT_TOOLKIT.legacy }), []);
  assert.deepEqual(checkToolkit({ version: 1, legacy: DEFAULT_TOOLKIT.legacy }).length, 1);   // download is required
  assert.notDeepEqual(checkToolkit({ version: 1, download: DEFAULT_TOOLKIT.download, legacy: "https://evil.example/x.dmg" }), []);
  assert.match(DEFAULT_TOOLKIT.legacy, /Game_Porting_Toolkit_3\.0\.dmg$/);
});

test("a copied download link becomes the signing-in form", () => {
  assert.equal(normalizeLink("https://download.developer.apple.com/Developer_Tools/A_1/B_2.dmg"),
    "https://developer.apple.com/services-account/download?path=/Developer_Tools/A_1/B_2.dmg");
});

test("versions on Apple's page", () => {
  assert.deepEqual(versionsOn("Game Porting Toolkit 4 is here. Game Porting Toolkit 4.0 beta 3"), ["4", "4.0 beta 3"]);
});

test("the first look is a baseline; a change is flagged", async () => {
  const store = new Map();
  const env = { RELEASES: {
    get: async (k) => store.has(k) ? { json: async () => JSON.parse(store.get(k)) } : null,
    put: async (k, v) => { store.set(k, v); },
  } };
  const page = (html) => async () => new Response(html);
  await watchToolkit(env, 0, page("Game Porting Toolkit 4"));
  assert.equal(JSON.parse(store.get("watch/toolkit.json")).changedAt, null);
  await watchToolkit(env, 1000, page("Game Porting Toolkit 4"));
  assert.equal(JSON.parse(store.get("watch/toolkit.json")).changedAt, null);
  await watchToolkit(env, 2000, page("Game Porting Toolkit 5"));
  assert.ok(JSON.parse(store.get("watch/toolkit.json")).changedAt);
});
