// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import { test } from "node:test";
import assert from "node:assert/strict";
import { normalize, parseSearch, parseDetails, directXVersion, parseDeck, parseMostPlayed, parseAntiCheat } from "../src/sources.js";

test("titles normalize for search", () => {
  assert.equal(normalize("The Witcher® 3: Wild Hunt — Remastered"), "the witcher 3 wild hunt remastered");
  assert.equal(normalize("Battlefield™ 6"), "battlefield 6");
  assert.equal(normalize("Pokémon"), "pokemon");
  assert.equal(normalize("  "), "");
});

test("Steam search keeps apps", () => {
  const json = { total: 3, items: [{ type: "app", name: "The Witcher 3", id: 292030 }, { type: "sub", name: "Bundle", id: 1 }, { type: "app", id: 5 }] };
  assert.deepEqual(parseSearch(json), [{ id: "292030", title: "The Witcher 3" }]);
  assert.deepEqual(parseSearch(null), []);
});

test("Steam details", () => {
  const json = { 271590: { success: true, data: { type: "game", name: "Grand Theft Auto V Legacy", header_image: "https://x/h.jpg",
    platforms: { windows: true, mac: false }, categories: [{ id: 2 }, { id: 1 }, { id: 36 }],
    pc_requirements: { minimum: "<strong>DirectX:</strong> Version 10<br>" } } } };
  assert.deepEqual(parseDetails(json, "271590"), { type: "game", title: "Grand Theft Auto V Legacy", header: "https://x/h.jpg", mac: false, single: true, dxMin: 10, reviews: null, developer: null, year: null, genres: [], sizeGB: null });
  const online = { 1: { success: true, data: { type: "game", name: "Online", categories: [{ id: 1 }], pc_requirements: [] } } };
  assert.equal(parseDetails(online, "1").single, false);
  assert.equal(parseDetails(online, "1").dxMin, 0);
  assert.equal(parseDetails({ 2: { success: true, data: { type: "game", name: "No categories" } } }, "2").single, null);
  assert.equal(parseDetails({ 3: { success: false } }, "3"), null);
});

test("DirectX in any store language", () => {
  assert.equal(directXVersion("DirectX: Version 12"), 12);
  assert.equal(directXVersion("DirectX: версии 11"), 11);
  assert.equal(directXVersion("DirectX 版本： 12"), 12);
  assert.equal(directXVersion("OS: Windows 10"), 0);
});

test("Deck report, most played, anti-cheat list", () => {
  assert.deepEqual(parseDeck({ success: 1, results: { resolved_category: 3, resolved_items: [{ loc_token: "#A" }, {}] } }), { category: 3, tokens: ["#A"] });
  assert.deepEqual(parseDeck({}), { category: 0, tokens: [] });
  assert.deepEqual(parseMostPlayed({ response: { ranks: [{ rank: 1, appid: 730 }, { rank: 2 }] } }), [{ id: "730", rank: 1 }]);
  const list = [{ name: "Fall Guys", status: "Running", anticheats: ["Easy Anti-Cheat"], storeIds: { steam: "1097150" } },
    { name: "Native", status: "Supported", anticheats: [], native: true, storeIds: {} },
    { name: "Fortnite", status: "Denied", anticheats: ["Easy Anti-Cheat"], storeIds: {} }];
  assert.deepEqual(parseAntiCheat(list).map((e) => [e.name, e.steamId]), [["Fall Guys", "1097150"], ["Fortnite", null]]);
});

test("what a game's page shows comes from Steam's details", async () => {
  const { releaseYear, storageGB, slugify } = await import("../src/sources.js");
  const full = parseDetails({ 1245620: { success: true, data: { type: "game", name: "ELDEN RING", developers: ["FromSoftware, Inc."],
    release_date: { date: "Feb 24, 2022" }, genres: [{ description: "Action" }, { description: "RPG" }], recommendations: { total: 834665 },
    pc_requirements: { minimum: "<li><strong>Storage:</strong> 60 GB available space</li>" } } } }, "1245620");
  assert.deepEqual([full.developer, full.year, full.genres, full.sizeGB, full.reviews], ["FromSoftware", 2022, ["Action", "RPG"], 60, 834665]);
  assert.equal(releaseYear("Coming soon"), null);
  assert.equal(releaseYear("Q4 2026"), 2026);
  assert.equal(storageGB("Storage: 500 MB available space"), 0.5);
  assert.equal(storageGB("Hard Drive: 2 TB"), null);              // not a game's real figure
  assert.equal(storageGB("no figure here"), null);
  assert.equal(slugify("Tom Clancy’s Rainbow Six® Siege"), "tom-clancys-rainbow-six-siege");
  assert.equal(slugify("Baldur’s Gate 3"), "baldurs-gate-3");
});
