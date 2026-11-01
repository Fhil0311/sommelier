// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { checkMods, modioProxy, modioPath, isModPath, safePath } from "../src/mods.js";
import { validateReport } from "../src/reports.js";
import { communityVerdicts } from "../src/rating.js";
import { testDB } from "./d1.js";

const HASH = "a".repeat(64);
/** The five games (server/mods/mods.json), with a hash on every download as the owner fills them in before publishing. */
function published() {
  const list = JSON.parse(readFileSync(new URL("../../mods/mods.json", import.meta.url), "utf8"));
  for (const g of list.games) for (const f of g.frameworks ?? []) f.download.sha256 = HASH;
  return list;
}
const withGame = (patch) => ({ version: 1, games: [{ ...published().games[0], ...patch }] });
const withFramework = (patch) => { const g = published().games[0]; g.frameworks[0] = { ...g.frameworks[0], ...patch }; return { version: 1, games: [g] }; };
const withKind = (patch) => { const g = published().games[0]; g.kinds[0] = { ...g.kinds[0], ...patch }; return { version: 1, games: [g] }; };

function bucket() {
  const store = new Map();
  return {
    store,
    async get(key) { const v = store.get(key); return v ? { body: v.value, text: async () => v.value, customMetadata: v.meta, httpEtag: '"e"' } : null; },
    async head(key) { return store.has(key) ? { httpEtag: '"e"' } : null; },
    async put(key, value, options = {}) { store.set(key, { value: typeof value === "string" ? value : new TextDecoder().decode(value), meta: options.customMetadata ?? {} }); },
    async list({ prefix }) { return { objects: [...store.keys()].filter((k) => k.startsWith(prefix)).map((key) => ({ key })) }; },
    async delete(keys) { for (const k of [].concat(keys)) store.delete(k); },
  };
}

test("the five games pass once every download has its hash; without them the list waits", () => {
  const list = published();
  assert.deepEqual(checkMods(list), []);
  assert.equal(list.games.length, 5);
  const raw = JSON.parse(readFileSync(new URL("../../mods/mods.json", import.meta.url), "utf8"));
  const problems = checkMods(raw);
  assert.ok(problems.length);
  assert.ok(problems.every((p) => /sha256 missing/.test(p)), problems.join("\n"));
  assert.ok(problems.some((p) => /frameworks\[0\]/.test(p) && /games\[3\]/.test(p)));      // RDR2's loaders come through the browser: a hash all the same
});

test("fields the app doesn't know are ignored; a value outside a closed list is a problem", () => {
  assert.deepEqual(checkMods(withGame({ somethingNew: { a: 1 } })), []);
  assert.ok(checkMods({ version: 2, games: [] }).length);
  assert.ok(checkMods({ version: 1, games: {} }).length);
  assert.ok(checkMods({ version: 1, games: [published().games[0], published().games[0]] }).some((p) => /repeats steam:990080/.test(p)));
  assert.ok(checkMods({ version: 1, games: [{ ...published().games[0], aliases: ["steam:2050650"] }, published().games[1]] }).some((p) => /repeats/.test(p)));
  assert.ok(checkMods(withGame({ game: "rm -rf /" })).length);
  assert.ok(checkMods(withGame({ status: "beta" })).length);
  assert.ok(checkMods(withGame({ runtime: "linux" })).length);
  assert.ok(checkMods(withGame({ sources: { nexus: { domain: "Hogwarts Legacy" } } })).length);
  assert.ok(checkMods(withGame({ sources: { other: ["http://plain.example"] } })).length);
  assert.ok(checkMods(withGame({ loadOrder: { format: "alphabetical" } })).length);
  assert.ok(checkMods(withGame({ loadOrder: { format: "lml" } })).some((p) => /loadOrder\.file/.test(p)));
  assert.ok(checkMods(withGame({ conflicts: { samePath: "ignore" } })).length);
  assert.ok(checkMods(withGame({ conflicts: { rules: [{ match: "**/a", field: "manifest.A", max: 1, reason: "x" }] } })).length);
  assert.ok(checkMods(withGame({ saves: [{ root: "desktop", path: "x" }] })).length);
  assert.ok(checkMods(withGame({ saves: [{ root: "local", path: "../x" }] })).length);
  assert.ok(checkMods(withGame({ online: { policy: "always" } })).length);
  assert.ok(checkMods(withGame({ online: { policy: "offlineOnly", antiCheat: "eac", moddedLaunch: "same" } })).length);
  assert.ok(checkMods(withGame({ online: { moddedLaunch: "loader" } })).length);                 // Hogwarts has no loader
  assert.ok(checkMods(withGame({ online: { noticeKey: "<b>hi</b>" } })).length);
  assert.ok(checkMods(withGame({ notes: { untouched: ["C:/Windows/**"] } })).length);
  assert.ok(checkMods(withGame({ logs: [{ file: "game:UE4SS.log", rules: [{ pattern: "x", action: "disableMod" }] }] })).some((p) => /modFrom/.test(p)));
  assert.ok(checkMods(withGame({ logs: [{ file: "game:UE4SS.log", rules: [{ pattern: "x", action: "disableFramework", framework: "nope" }] }] })).length);
  assert.ok(checkMods(withGame({ logs: [{ file: "game:UE4SS.log", exists: { action: "disableMod" } }] })).length);
  assert.ok(checkMods(withGame({ logs: [{ file: "game:UE4SS.log", summary: "ue4ss" }] })).length);
});

test("frameworks: where they come from, what they may ask of Wine, how they change the launch", () => {
  assert.ok(checkMods(withFramework({ download: { kind: "github", repo: "UE4SS-RE/RE-UE4SS", asset: "UE4SS.zip", sha256: "abc" } })).some((p) => /sha256/.test(p)));
  assert.ok(checkMods(withFramework({ download: { kind: "github", repo: "UE4SS-RE/RE-UE4SS", asset: "UE4SS.zip" } })).some((p) => /sha256 missing/.test(p)));
  assert.ok(checkMods(withFramework({ download: { kind: "url", url: "https://example.com/page", file: "*.zip", viaBrowser: true } })).some((p) => /sha256 missing/.test(p)));
  assert.ok(checkMods(withFramework({ download: { kind: "torrent", url: "https://x", sha256: HASH } })).length);
  assert.ok(checkMods(withFramework({ download: { kind: "github", repo: "../x", asset: "a.zip", sha256: HASH } })).length);
  assert.ok(checkMods(withFramework({ download: { kind: "url", url: "ftp://x/y", file: "*.zip", sha256: HASH } })).length);
  assert.ok(checkMods(withFramework({ download: { kind: "inner", of: "ue4ss", path: "a/b", sha256: HASH } })).length);         // itself
  assert.deepEqual(checkMods(withFramework({ download: { kind: "inner", of: "asiloader", path: "a/b", sha256: HASH } })), []);
  assert.deepEqual(checkMods(withFramework({ download: { kind: "nexus", domain: "hogwartslegacy", mod: 12, sha256: HASH } })), []);
  assert.ok(checkMods(withFramework({ pick: [{ match: "*.dll", to: "game:../../Windows/" }] })).length);
  assert.ok(checkMods(withFramework({ pick: [{ match: "*.dll", to: "C:/Games/" }] })).length);
  assert.ok(checkMods(withFramework({ pick: [{ match: "*.dll", to: "system:x/" }] })).length);
  assert.ok(checkMods(withFramework({ remove: ["/etc/passwd"] })).length);
  assert.ok(checkMods(withFramework({ dllOverrides: { dwmapi: "builtin" } })).length);
  assert.ok(checkMods(withFramework({ dllOverrides: { "../x": "n,b" } })).length);
  assert.ok(checkMods(withFramework({ components: ["installWine"] })).length);
  assert.deepEqual(checkMods(withFramework({ components: ["installVCRuntime", "physx"] })), []);
  assert.ok(checkMods(withFramework({ requires: ["nope"] })).length);
  assert.ok(checkMods(withFramework({ requires: ["ue4ss"] })).length);                                                  // itself
  assert.ok(checkMods(withFramework({ settings: [{ file: "game:a.ini", format: "xml", set: { A: "1" } }] })).length);
  assert.ok(checkMods(withFramework({ settings: [{ file: "game:a.ini", format: "ini", set: {} }] })).length);
  assert.ok(checkMods(withFramework({ launch: { loader: { exe: "game:../me3.exe", args: [] } } })).length);
  assert.ok(checkMods(withFramework({ launch: { loader: { exe: "tools:me3/me3.exe", config: "modengine2" } } })).length);
  assert.deepEqual(checkMods(withFramework({ launch: { loader: { exe: "tools:me3/me3.exe", args: ["launch", "-p", "{config}"], config: "me3" } } })), []);
  assert.ok(checkMods(withFramework({ launch: { redirect: { instead: "a/b", run: "c" } } })).length);
  assert.ok(checkMods(withFramework({ disableArgument: "rm -rf" })).length);
  assert.ok(checkMods(withFramework({ id: "UE4SS" })).length);
  const twice = published().games[0]; twice.frameworks.push({ ...twice.frameworks[0] });
  assert.ok(checkMods({ version: 1, games: [twice] }).some((p) => /repeats ue4ss/.test(p)));
});

test("kinds: a unit the app knows, a safe destination, a framework the entry has", () => {
  assert.ok(checkMods(withKind({ unit: "zip" })).length);
  assert.ok(checkMods(withKind({ to: "game:../Paks/{slot}/" })).length);
  assert.ok(checkMods(withKind({ to: "game:Paks/{wat}/" })).length);
  assert.ok(checkMods(withKind({ to: "Paks/" })).length);
  assert.deepEqual(checkMods(withKind({ to: "store:{name}/" })), []);
  assert.ok(checkMods(withKind({ framework: "smapi" })).length);
  assert.ok(checkMods(withKind({ order: "random" })).length);
  assert.ok(checkMods(withKind({ pinned: "middle" })).length);
  assert.ok(checkMods(withKind({ enable: { format: "ue4ssModsTxt" } })).length);                 // needs its file
  assert.ok(checkMods(withKind({ enable: { format: "registry" } })).length);
  assert.ok(checkMods(withKind({ codeIf: "EntryDll" })).length);
  assert.ok(checkMods(withKind({ merge: "xml" })).length);
  assert.ok(checkMods(withKind({ importer: "vortex" })).length);
  assert.ok(checkMods(withKind({ unit: "folder" })).some((p) => /marker/.test(p)));
  assert.ok(checkMods(withKind({ id: "pak" })).some((p) => /repeats pak/.test(p)));
  assert.ok(checkMods(withGame({ archive: { reject: [{ match: "**/*.exe", reason: "no way!" }] } })).length);
  assert.ok(checkMods(withGame({ archive: { deny: ["../x"] } })).length);
  assert.ok(safePath("a/b.dll") && !safePath("../a") && !safePath("/a") && !safePath("a:b") && !safePath("a/./b"));
  assert.ok(isModPath("game:") && isModPath("tools:me3/bin/me3.exe") && !isModPath("game:*.asi") && isModPath("game:*.asi", { wildcard: true }));
  assert.ok(!isModPath("appdata:a\\..\\b"));
});

test("the list through the API: checked, signed, served, rolled back", async () => {
  const { default: worker } = await import("../src/index.js");
  const env = { DB: testDB(), RELEASES: bucket(), SALT: "s", ADMIN_TOKEN: "t" };
  const call = (method, path, body, headers = {}) => worker.fetch(new Request("http://x" + path, { method, headers: { Authorization: "Bearer t", ...headers }, body }), env, {});
  const list = JSON.stringify(published());
  assert.equal((await call("PUT", "/v1/mods.json", list, { Authorization: "Bearer no" })).status, 401);
  const bad = await call("PUT", "/v1/mods.json", JSON.stringify(withGame({ runtime: "linux" })));
  assert.equal(bad.status, 400);
  assert.match((await bad.json()).problems[0], /runtime/);
  const first = await call("PUT", "/v1/mods.json", list, { "X-Sommelier-Signature": "sig-1" });
  assert.deepEqual(await first.json(), { published: 5 });
  const served = await worker.fetch(new Request("http://x/v1/mods.json"), env, {});
  assert.equal(served.status, 200);
  assert.equal(served.headers.get("X-Sommelier-Signature"), "sig-1");
  assert.equal((await served.json()).games.length, 5);
  await new Promise((r) => setTimeout(r, 5));
  await call("PUT", "/v1/mods.json", JSON.stringify({ version: 1, games: [] }), { "X-Sommelier-Signature": "sig-2" });
  assert.equal((await call("POST", "/v1/mods.json/rollback")).status, 200);
  assert.equal(env.RELEASES.store.get("mods.json").meta.signature, "sig-1");
  const empty = { DB: testDB(), RELEASES: bucket(), SALT: "s", ADMIN_TOKEN: "t" };
  assert.deepEqual(await (await worker.fetch(new Request("http://x/v1/mods.json"), empty, {})).json(), { version: 1, games: [] });
});

test("a report with mods is kept with the flag and casts no vote", async () => {
  const good = { client: "3f2a9c1e-5b7d-4e8f-9a0b-1c2d3e4f5a6b", game: { store: "steam", id: "990080" }, outcome: "crashed" };
  assert.equal(validateReport({ ...good, mods: true }).report.mods, 1);
  assert.equal(validateReport({ ...good, mods: false }).report.mods, 0);
  assert.equal(validateReport(good).report.mods, null);
  assert.equal(validateReport({ ...good, mods: "yes" }).error, "mods");

  const { default: worker } = await import("../src/index.js");
  const env = { DB: testDB(), RELEASES: bucket(), SALT: "s", ADMIN_TOKEN: "t" };
  const send = (client, outcome, mods, ip) => worker.fetch(new Request("http://x/v1/reports", { method: "POST",
    headers: { "X-Sommelier-Client": client, "CF-Connecting-IP": ip }, body: JSON.stringify({ ...good, client, outcome, mods, minutes: outcome === "ran" ? 5 : undefined }) }), env, {});
  for (const [i, ip] of ["1.1.1.1", "2.2.2.2", "3.3.3.3"].entries()) assert.equal((await send(`aaaaaaaa-0000-0000-0000-00000000000${i}`, "crashed", true, ip)).status, 201);
  assert.equal((await send("bbbbbbbb-0000-0000-0000-000000000000", "ran", undefined, "4.4.4.4")).status, 201);
  const rows = (await env.DB.prepare("SELECT mods FROM reports").all()).results.map((r) => r.mods).sort();
  assert.deepEqual(rows, [1, 1, 1, null]);
  // Three crashes with mods would make the game "wontRun"; they say nothing about it, so no word yet.
  const verdicts = await (await worker.fetch(new Request("http://x/v1/verdicts.json"), env, {})).json();
  assert.deepEqual(verdicts.games, {});
  const reports = (await env.DB.prepare("SELECT store, game_id, steam_id, outcome, address, mods FROM reports").all()).results;
  assert.deepEqual(communityVerdicts(reports.map((r) => ({ ...r, mods: null })), []), { "steam:990080": "wontRun" });   // the same rows without the flag would
  const { reportsFor, reportCounts } = await import("../src/catalog.js");
  assert.equal((await reportsFor(env.DB, "steam", "990080")).length, 1);
  assert.deepEqual((await reportCounts(env.DB, ["990080"])).get("990080"), { ran: 1, failed: 0 });
  const { summary } = await import("../src/stats.js");
  const s = await summary(env.DB, Date.now(), 30);
  assert.deepEqual([s.reports.total, s.reports.withMods, s.reports.byOutcome], [4, 3, { ran: 1 }]);
});

test("the mod.io proxy serves the cache and never shows the key", async () => {
  const calls = [];
  const fetchImpl = async (url) => { calls.push(url); return new Response(JSON.stringify({ data: [{ id: 1, name: "Mod" }], result_total: 1 }), { status: 200 }); };
  const games = async () => new Set(["8254"]);
  const store = new Map();
  const env = { MODIO_API_KEY: "secret-key-123" };
  const params = new URLSearchParams("_q=lighting&_limit=20&api_key=mine");
  const first = await modioProxy(env, "8254", ["mods"], params, 1000, { fetchImpl, store, games });
  assert.equal(first.status, 200);
  assert.equal(first.cached, false);
  assert.equal(calls.length, 1);
  assert.match(calls[0], /^https:\/\/api\.mod\.io\/v1\/games\/8254\/mods\?/);
  assert.match(calls[0], /api_key=secret-key-123/);
  assert.ok(!/mine/.test(calls[0]));                                               // the app's own key parameter is dropped
  const second = await modioProxy(env, "8254", ["mods"], new URLSearchParams("_limit=20&_q=lighting"), 2000, { fetchImpl, store, games });
  assert.equal(second.cached, true);
  assert.equal(calls.length, 1);
  assert.ok(!JSON.stringify(second).includes("secret"));
  assert.equal([...store.keys()].some((k) => k.includes("secret")), false);
  const later = await modioProxy(env, "8254", ["mods"], params, 1000 + 601_000, { fetchImpl, store, games });
  assert.equal(later.cached, false);
  assert.equal(calls.length, 2);
  assert.equal((await modioProxy(env, "8254", ["mods", "7", "files", "9"], new URLSearchParams(), 1, { fetchImpl, store, games })).status, 200);
  assert.match(calls.at(-1), /\/games\/8254\/mods\/7\/files\/9\?/);
  assert.equal((await modioProxy(env, "1", ["mods"], params, 1, { fetchImpl, store, games })).status, 404);      // not one of our games
  assert.equal((await modioProxy(env, "8254", ["users"], params, 1, { fetchImpl, store, games })).status, 404);
  assert.equal((await modioProxy({}, "8254", ["mods"], params, 1, { fetchImpl, store, games })).status, 503);
  assert.equal(calls.length, 3);
  const down = await modioProxy(env, "8254", ["mods", "2"], params, 1, { fetchImpl: async () => new Response("key=secret-key-123", { status: 500 }), store, games });
  assert.equal(down.status, 502);
  assert.ok(!JSON.stringify(down).includes("secret"));
  assert.equal(modioPath("8254", ["mods", "x"]), null);
  assert.equal(modioPath("../8254", ["mods"]), null);
});

test("the mod.io proxy through the API answers only for games the published list names", async () => {
  const { default: worker } = await import("../src/index.js");
  const env = { DB: testDB(), RELEASES: bucket(), SALT: "s", ADMIN_TOKEN: "t", MODIO_API_KEY: "secret-key-123" };
  const list = published();
  list.games[0].sources.modio = { gameID: 8254 };
  await env.RELEASES.put("mods.json", JSON.stringify(list));
  const original = globalThis.fetch;
  globalThis.fetch = async (url) => new Response(JSON.stringify({ data: [], echo: String(url).includes("secret") ? "asked with the key" : "no key" }), { status: 200 });
  try {
    const response = await worker.fetch(new Request("http://x/v1/mods/modio/8254/mods?_q=x"), env, {});
    assert.equal(response.status, 200);
    assert.equal(response.headers.get("Cache-Control"), "public, max-age=600");
    assert.equal((await response.json()).echo, "asked with the key");
    assert.equal((await worker.fetch(new Request("http://x/v1/mods/modio/9999/mods"), env, {})).status, 404);
  } finally {
    globalThis.fetch = original;
  }
});
