// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import test from "node:test";
import assert from "node:assert/strict";
import { checkRecipes, recipeCandidates } from "../src/recipes.js";

test("the recipes list", () => {
  const ok = { version: 1, recipes: [
    { game: "steam:1903340", actions: [{ switchGraphics: { _0: "d3dMetal" } }], players: 4, note: "Crashes in DXMT's swap chain", source: "reports" },
    { game: "epic:Sage", actions: [{ turnOffTurbo: {} }] },
    { game: "steam:49520", actions: [{ runExecutable: { instead: "Launcher.exe", run: "Borderlands2.exe" } }, { overrideDLL: { _0: "ddraw", _1: "n,b" } },
      { setWindowsVersion: { version: "win7", exe: "Borderlands2.exe" } }, { addArguments: { _0: ["-nosplash"] } },
      { installComponent: { _0: "physx" } }], source: "protonfixes" },
  ] };
  assert.ok(checkRecipes({ version: 1, recipes: [{ game: "steam:1", actions: [{ installComponent: { _0: "winetricks" } }] }] }).length);
  const save = { editSave: { file: "appdata:Sandfall/Saved/SaveGames/*/SharedGameUserSettings.sav", structName: "EngineSettingsData", values: { OverallScalabilityLevel: "${level}", ShadowQuality: "2" } } };
  assert.deepEqual(checkRecipes({ version: 1, recipes: [{ game: "steam:1903340", actions: [save] }] }), []);
  for (const bad of [{ ...save.editSave, file: "appdata:G/*/*/x.sav" }, { ...save.editSave, file: "appdata:G/x.ini" }, { ...save.editSave, file: "unreal:x.sav" },
                     { ...save.editSave, values: {} }, { ...save.editSave, values: { A: "two" } }, { ...save.editSave, structName: "a b" }]) {
    assert.ok(checkRecipes({ version: 1, recipes: [{ game: "steam:1", actions: [{ editSave: bad }] }] }).length, JSON.stringify(bad));
  }
  const edit = { editConfig: { file: "unreal:GameUserSettings.ini", section: "/Script/SandFall.ConfigurableGameUserSettings", key: "SettingsData", field: "ConsoleGraphicPreset", value: "${level}" } };
  assert.deepEqual(checkRecipes({ version: 1, recipes: [{ game: "steam:1903340", actions: [edit] }] }), []);
  assert.deepEqual(checkRecipes({ version: 1, recipes: [{ game: "steam:2", actions: [{ editConfig: { file: "appdata:G/x.ini", section: "Video", key: "Quality", value: "3" } }] }] }), []);
  for (const bad of [{ ...edit.editConfig, file: "game:../../x.ini" }, { ...edit.editConfig, file: "game:x.exe" }, { ...edit.editConfig, file: "system:x.ini" },
                     { ...edit.editConfig, field: "a b" }, { ...edit.editConfig, key: "a=b" }, { ...edit.editConfig, section: "[x]" }]) {
    assert.ok(checkRecipes({ version: 1, recipes: [{ game: "steam:1", actions: [{ editConfig: bad }] }] }).length, JSON.stringify(bad));
  }
  assert.deepEqual(checkRecipes(ok), []);
  assert.ok(checkRecipes({ version: 2, recipes: [] }).length);
  assert.ok(checkRecipes({ version: 1, recipes: [{ game: "steam:1", actions: [{ switchGraphics: { _0: "vulkan" } }] }] }).length);
  assert.ok(checkRecipes({ version: 1, recipes: [{ game: "steam:1" }] }).length);                       // says nothing
  assert.ok(checkRecipes({ version: 1, recipes: [{ game: "steam:1", actions: [{ runShell: { _0: "rm -rf /" } }] }] }).length);
  assert.ok(checkRecipes({ version: 1, recipes: [{ game: "steam:1", actions: [{ runExecutable: { instead: "a.exe", run: "C:\\Windows\\x.exe" } }] }] }).length);
  assert.ok(checkRecipes({ version: 1, recipes: [{ game: "steam:1", actions: [{ overrideDLL: { _0: "ddraw", _1: "x" } }] }] }).length);
  assert.ok(checkRecipes({ version: 1, recipes: [{ game: "steam:1", actions: [{ setWindowsVersion: { version: "win95", exe: "a.exe" } }] }] }).length);
  assert.ok(checkRecipes({ version: 1, recipes: [ok.recipes[0], ok.recipes[0]] }).length);              // the same game twice
  assert.ok(checkRecipes({ version: 1, recipes: [{ game: "rm -rf", actions: [{ turnOffTurbo: {} }] }] }).length);
});

/** A D1-like stub over rows of the reports table. */
function db(rows) {
  return { prepare: () => ({ all: async () => {
    const groups = new Map();
    for (const r of rows) {
      const key = [r.store, r.game_id, r.backend, r.backend_choice].join("|");
      const g = groups.get(key) ?? { store: r.store, id: r.game_id, title: r.title, backend: r.backend, choice: r.backend_choice, reports: 0, ran: 0, clients: new Set() };
      g.reports += 1; if (r.outcome === "ran") g.ran += 1; g.clients.add(r.client);
      groups.set(key, g);
    }
    return { results: [...groups.values()].map(({ clients, ...g }) => ({ ...g, players: clients.size })) };
  } }) };
}

test("recipe candidates come from reports that disagree by backend", async () => {
  const rows = [];
  for (let i = 0; i < 4; i++) rows.push({ store: "steam", game_id: "1", title: "Crashy", backend: "dxmt", backend_choice: "auto", outcome: "crashed", client: `c${i}` });
  for (let i = 0; i < 3; i++) rows.push({ store: "steam", game_id: "1", title: "Crashy", backend: "d3dMetal", backend_choice: "retry", outcome: "ran", client: `c${i}` });
  rows.push({ store: "steam", game_id: "1", title: "Crashy", backend: "d3dMetal", backend_choice: "manual", outcome: "ran", client: "c9" });
  // Two players is not enough, and a game that runs everywhere is no candidate.
  for (let i = 0; i < 2; i++) rows.push({ store: "steam", game_id: "2", title: "Few", backend: "d3dMetal", backend_choice: "retry", outcome: "ran", client: `d${i}` });
  for (let i = 0; i < 3; i++) rows.push({ store: "steam", game_id: "2", title: "Few", backend: "dxmt", backend_choice: "auto", outcome: "crashed", client: `d${i}` });
  for (let i = 0; i < 5; i++) rows.push({ store: "epic", game_id: "Sage", title: "Fine", backend: "dxmt", backend_choice: "auto", outcome: "ran", client: `e${i}` });
  const candidates = await recipeCandidates(db(rows));
  assert.equal(candidates.length, 1);
  assert.equal(candidates[0].game, "steam:1");
  assert.equal(candidates[0].backend, "d3dMetal");
  assert.equal(candidates[0].players, 4);
  assert.equal(candidates[0].insteadOf, "dxmt");
  assert.equal(candidates[0].failed, 4);
});

import { testDB } from "./d1.js";
import { fixCandidates, recipeResults, actionKey } from "../src/recipes.js";
import { validateSettings } from "../src/reports.js";

function addReport(db, { client, game = "1", outcome = "ran", fixes = [], actions = [] }) {
  db.sqlite.prepare(`INSERT INTO reports (client, store, game_id, title, outcome, created_at, backend_choice, settings)
    VALUES (?, 'steam', ?, 'Game', ?, 0, 'auto', ?)`).run(client, game, outcome, JSON.stringify({ backendChoice: "auto", fixes, actions }));
}

test("reports keep the actions of players' fixes that the server can read", () => {
  const { settings } = validateSettings({ backendChoice: "auto", actions: [{ installComponent: { _0: "physx" } }, { runShell: { _0: "rm" } }] });
  assert.deepEqual(settings.actions, [{ installComponent: { _0: "physx" } }]);
  assert.ok(validateSettings({ backendChoice: "auto", actions: "x" }).error);
  assert.equal(actionKey({ b: 1, a: { d: 2, c: 3 } }), actionKey({ a: { c: 3, d: 2 }, b: 1 }));
});

test("a fix that worked for three players is a recipe candidate", async () => {
  const db = testDB();
  const vc = { installVCRuntime: {} }, physx = { installComponent: { _0: "physx" } };
  for (let i = 0; i < 3; i++) addReport(db, { client: `a${i}`, fixes: ["manual"], actions: [physx] });
  addReport(db, { client: "b0", actions: [vc] });                                              // one player: not yet
  for (let i = 0; i < 3; i++) addReport(db, { client: `c${i}`, game: "2", actions: [physx] });    // already in its recipe
  const recipes = [{ game: "steam:2", actions: [physx] }, { game: "steam:1", actions: [{ turnOffTurbo: {} }] }];
  const list = await fixCandidates(db, recipes);
  assert.equal(list.length, 1);
  assert.equal(list[0].game, "steam:1");
  assert.equal(list[0].players, 3);
  assert.deepEqual(list[0].recipe.actions, [{ turnOffTurbo: {} }, physx]);
});

test("recipes that hurt come first", async () => {
  const db = testDB();
  for (let i = 0; i < 3; i++) addReport(db, { client: `a${i}`, game: "1", outcome: "crashed", fixes: ["recipe"] });
  for (let i = 0; i < 2; i++) addReport(db, { client: `b${i}`, game: "1", outcome: "ran" });
  for (let i = 0; i < 3; i++) addReport(db, { client: `c${i}`, game: "2", outcome: "ran", fixes: ["recipe"] });
  for (let i = 0; i < 3; i++) addReport(db, { client: `d${i}`, game: "2", outcome: "didNotStart" });
  addReport(db, { client: "e0", game: "9", outcome: "ran" });                                        // no recipe: not listed
  const list = await recipeResults(db, [{ game: "steam:2", actions: [{ turnOffTurbo: {} }] }, { game: "steam:1", actions: [{ turnOffTurbo: {} }], source: "protonfixes" }, { game: "steam:3", actions: [{ turnOffTurbo: {} }] }]);
  assert.deepEqual(list.map((g) => [g.game, g.verdict]), [["steam:1", "hurts"], ["steam:2", "helps"]]);
  assert.deepEqual(list[0].with, { reports: 3, ran: 0, players: 3 });
  assert.equal(list[0].source, "protonfixes");
});
