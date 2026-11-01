// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
// The same cases as the app's CompatibilityTests, plus players' reports.
import { test } from "node:test";
import assert from "node:assert/strict";
import { rate, antiCheatBlocks, communityVerdict, communityVerdicts } from "../src/rating.js";

const deck = (category, ...tokens) => ({ category, tokens: tokens.map((t) => `#SteamDeckVerified_TestResult_${t}`) });
const r = (input) => { const x = rate(input); return [x.verdict, x.reason, x.notes]; };

test("Steam Deck results give an answer", () => {
  assert.deepEqual(r({ deck: deck(3) }), ["likely", "deckVerified", []]);
  assert.deepEqual(r({ deck: deck(2, "TextInputDoesNotAutomaticallyInvokesKeyboard") }), ["likely", "deckPlayable", []]);
  assert.deepEqual(r({ deck: deck(1, "UnsupportedGraphicsPerformance") }), ["unknown", "deckTooDemanding", ["demanding"]]);
  assert.deepEqual(r({ deck: deck(1, "SteamOSDoesNotSupport") }), ["wontRun", "deckFails", []]);
  assert.deepEqual(r({ deck: deck(0) }), ["unknown", "noData", []]);
  assert.deepEqual(r({}), ["unknown", "noData", []]);
});

test("anti-cheat separates online-only games", () => {
  assert.deepEqual(r({ deck: deck(1, "UnsupportedAntiCheat_Other"), singlePlayer: false }), ["wontRun", "onlineOnlyBlocked", []]);
  assert.deepEqual(r({ antiCheatBlocks: true, singlePlayer: false }), ["wontRun", "onlineOnlyBlocked", []]);
  assert.deepEqual(r({ deck: deck(1, "UnsupportedAntiCheatConfiguration"), singlePlayer: true }), ["unknown", "offlineUnknown", ["noOnline"]]);
  assert.deepEqual(r({ antiCheatBlocks: true }), ["unknown", "offlineUnknown", ["noOnline"]]);
  assert.deepEqual(r({ deck: deck(3), antiCheatBlocks: true, singlePlayer: true }), ["likely", "deckVerified", ["noOnline"]]);
  assert.deepEqual(r({ deck: deck(1, "UnsupportedAntiCheat_Other"), singlePlayer: true }), r({ antiCheatBlocks: true, singlePlayer: true }));
});

test("players decide once there are enough reports", () => {
  assert.deepEqual(r({ deck: deck(1, "SteamOSDoesNotSupport"), players: { ran: 3, failed: 1 } }), ["works", "players", []]);
  assert.deepEqual(r({ antiCheatBlocks: true, singlePlayer: false, players: { ran: 5, failed: 0 } }), ["works", "players", ["noOnline"]]);
  assert.deepEqual(r({ deck: deck(3), players: { ran: 0, failed: 4 } }), ["wontRun", "playersFail", []]);
  assert.deepEqual(r({ deck: deck(3), players: { ran: 1, failed: 1 } }), ["likely", "deckVerified", []]);        // too few
  assert.deepEqual(r({ deck: deck(3), players: { ran: 2, failed: 2 } }), ["likely", "deckVerified", []]);        // split: the guess stays
});

test("a store's Mac version is a note: only the app can tell it still runs", () => {
  assert.deepEqual(r({ deck: deck(3), macVersion: true }), ["works", "macVersion", ["macVersion"]]);
  assert.equal(rate({ deck: deck(1), macVersion: true, verdict: "wontRun" }).verdict, "wontRun");        // the project's answer wins
  assert.equal(rate({ deck: deck(1, "UnsupportedAntiCheat_Other", "UnsupportedGraphicsPerformance"), macVersion: true }).notes.length, 2);
});

test("anti-cheat that blocks a Mac", () => {
  const e = (status, a) => ({ status, anticheats: [a] });
  assert.ok(antiCheatBlocks(e("Denied", "BattlEye")));
  assert.ok(antiCheatBlocks(e("Broken", "XIGNCODE3")));
  assert.ok(antiCheatBlocks(e("Running", "Easy Anti-Cheat")));
  assert.ok(!antiCheatBlocks(e("Supported", "VAC")));
  assert.ok(!antiCheatBlocks(null));
});

test("the project's answer comes first, as players' word", async () => {
  const { rate } = await import("../src/rating.js");
  assert.deepEqual(rate({ deck: { category: 1, tokens: [] }, verdict: "works" }), { verdict: "works", reason: "players", notes: [] });
  assert.equal(rate({ deck: { category: 3, tokens: [] }, verdict: "wontRun" }).verdict, "wontRun");
  assert.equal(rate({ deck: { category: 3, tokens: [] } }).verdict, "likely");
});

test("owner answers through the API", async () => {
  const { default: worker } = await import("../src/index.js");
  const { testDB } = await import("./d1.js");
  const env = { DB: testDB(), SALT: "s", ADMIN_TOKEN: "t" };
  const call = (method, path, body, token = "t") => worker.fetch(new Request("http://x" + path, { method, headers: { Authorization: `Bearer ${token}` }, body: body && JSON.stringify(body) }), env, {});
  assert.equal((await call("PUT", "/v1/verdicts/epic/Sage", { verdict: "works", steamAppID: "448510" }, "no")).status, 401);
  assert.equal((await call("PUT", "/v1/verdicts/epic/Sage", { verdict: "maybe" })).status, 400);
  assert.equal((await call("PUT", "/v1/verdicts/epic/Sage", { verdict: "works", steamAppID: "448510" })).status, 200);
  const { verdictFor } = await import("../src/catalog.js");
  assert.equal(await verdictFor(env.DB, "steam", "448510"), "works");          // the Steam copy of an Epic game we tested
  assert.equal(await verdictFor(env.DB, "epic", "Sage"), "works");
  assert.equal((await (await call("GET", "/v1/verdicts")).json()).verdicts.length, 1);
  assert.equal((await call("DELETE", "/v1/verdicts/epic/Sage")).status, 200);
  assert.equal(await verdictFor(env.DB, "epic", "Sage"), null);
});

test("community verdicts: owner answers win, three agreeing players decide, copies count for their Steam game", () => {
  const reports = [
    ...["a", "b", "c"].map((c) => ({ store: "steam", game_id: "1", steam_id: "1", outcome: "ran", client: c })),
    { store: "steam", game_id: "2", steam_id: "2", outcome: "ran" }, { store: "steam", game_id: "2", steam_id: "2", outcome: "crashed" },
    { store: "steam", game_id: "2", steam_id: "2", outcome: "didNotStart" },
    { store: "epic", game_id: "Quail", steam_id: "3", outcome: "crashed" }, { store: "steam", game_id: "3", steam_id: "3", outcome: "crashed" },
    { store: "steam", game_id: "3", steam_id: "3", outcome: "didNotStart" },
    { store: "steam", game_id: "4", steam_id: "4", outcome: "ran" },                              // one report: no word yet
  ];
  const owners = [{ store: "steam", id: "1", steam_id: null, verdict: "wontRun" }, { store: "gog", id: "9", steam_id: "8", verdict: "works" }];
  assert.deepEqual(communityVerdicts(reports, owners), {
    "gog:9": "works", "steam:1": "wontRun", "steam:3": "wontRun", "steam:8": "works",   // steam:2, 1 of 3 ran (33 %): undecided
  });
  assert.equal(communityVerdict({ players: { ran: 2, failed: 1 } }), null);                      // 67 %: undecided
  assert.equal(communityVerdict({ players: { ran: 7, failed: 3 } }), "works");
});

test("one computer posing as many players counts once", async () => {
  const { communityVerdicts } = await import("../src/rating.js");
  const fake = Array.from({ length: 5 }, () => ({ store: "steam", game_id: "1", steam_id: null, outcome: "ran", address: "same" }));
  assert.deepEqual(communityVerdicts(fake, []), {});                         // one address: one vote, not enough
  const real = ["a", "b", "c"].map((address) => ({ store: "steam", game_id: "1", steam_id: null, outcome: "ran", address }));
  assert.equal(communityVerdicts(real, [])["steam:1"], "works");
});
