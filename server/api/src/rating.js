// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
// Will a game run in Sommelier: one answer, up to two notes, and the reason (which also says where the answer comes
// from). The same rules as the app's `Compatibility.rate` (Sources/SommelierKit/Library/Compatibility.swift), plus what
// players report, which the app doesn't know on its own and which beats every guess.
//
// Answers, best first: "works", "likely" (should work), "unknown", "wontRun".
// Notes: "noOnline" (anti-cheat closes online play; single-player can run), "macVersion", "demanding" (resource-heavy).

export const VERDICTS = ["works", "likely", "unknown", "wontRun"];

/** Reports needed before players' word decides the answer. */
export const MIN_REPORTS = 3;

/**
 * @param {object} input
 * @param {{category:number, tokens:string[]}|null} input.deck  Valve's Steam Deck result
 * @param {boolean} [input.antiCheatBlocks]  the game's anti-cheat keeps Wine out on a Mac
 * @param {boolean|null} [input.singlePlayer]  has single-player; null when unknown
 * @param {boolean} [input.macVersion]  the store lists a Mac version
 * @param {{ran:number, failed:number}|null} [input.players]  distinct players by outcome
 */
export function rate({ deck = null, antiCheatBlocks = false, singlePlayer = null, macVersion = false, players = null, verdict = null }) {
  const tokens = (deck?.tokens ?? []).join(" ");
  const antiCheat = tokens.includes("UnsupportedAntiCheat") || antiCheatBlocks;
  const demanding = deck?.category === 1 && tokens.includes("UnsupportedGraphicsPerformance");
  const notes = [];
  if (antiCheat) notes.push("noOnline");
  if (demanding) notes.push("demanding");
  // A game with a Mac version works. A store's Mac version can be a 32-bit build that no
  // longer runs; the app checks that after installing and installs the Windows version instead (which then runs
  // here like any other), so the answer stays "works", with the note.
  if (macVersion) notes.push("macVersion");
  const result = (verdict, reason, keep = notes) => ({ verdict, reason, notes: keep.slice(0, 2) });

  const word = communityVerdict({ verdict, players });
  if (word === "works") return result("works", "players");
  if (word === "wontRun") return result("wontRun", "playersFail", notes.filter((n) => n !== "noOnline"));
  if (macVersion) return result("works", "macVersion");
  if (antiCheat) {
    if (singlePlayer === false) return result("wontRun", "onlineOnlyBlocked", notes.filter((n) => n === "macVersion"));
    if (deck?.category === 3) return result("likely", "deckVerified");
    if (deck?.category === 2) return result("likely", "deckPlayable");
    return result("unknown", "offlineUnknown");
  }
  switch (deck?.category) {
    case 3: return result("likely", "deckVerified");
    case 2: return result("likely", "deckPlayable");
    case 1: return demanding ? result("unknown", "deckTooDemanding") : result("wontRun", "deckFails");
    default: return result("unknown", "noData");
  }
}

/**
 * What players' word says, when it decides: the owner's own answer (tested on our Macs) first, then players' reports
 * once there are enough of them and they agree. "works", "wontRun", or null when it doesn't decide.
 * @param {{verdict?: string|null, players?: {ran:number, failed:number}|null}} input
 */
export function communityVerdict({ verdict = null, players = null }) {
  if (verdict === "works" || verdict === "wontRun") return verdict;
  const total = (players?.ran ?? 0) + (players?.failed ?? 0);
  if (total < MIN_REPORTS) return null;
  const share = players.ran / total;
  if (share >= 0.7) return "works";
  if (share <= 0.3) return "wontRun";
  return null;
}

/**
 * The games players' word decides, for the app to rate its library with (`GET /v1/verdicts.json`). Reports are one
 * per player and game; a copy from another store also counts for its Steam game. The project's answers win. A session
 * with mods in play (`mods = 1`) says nothing about the game and casts no vote.
 * @param {{store:string, game_id:string, steam_id:string|null, outcome:string, mods?:number|null}[]} reports
 * @param {{store:string, id:string, steam_id:string|null, verdict:string}[]} owners
 * @returns {Record<string, "works"|"wontRun">}
 */
export function communityVerdicts(reports, owners) {
  // One vote per address and game, the latest (reports come oldest first): installs on one computer, or one
  // computer posing as many players, count once. Reports from before addresses were kept count each.
  const votes = new Map();
  reports.forEach((r, i) => {
    if (r.mods === 1) return;
    const keys = [`${r.store}:${r.game_id}`];
    if (r.steam_id && r.store !== "steam") keys.push(`steam:${r.steam_id}`);
    for (const key of keys) votes.set(`${key}\u0001${r.address ?? `#${i}`}`, { key, ran: r.outcome === "ran" });
  });
  const players = new Map();
  for (const { key, ran } of votes.values()) {
    const entry = players.get(key) ?? { ran: 0, failed: 0 };
    if (ran) entry.ran += 1; else entry.failed += 1;
    players.set(key, entry);
  }
  const verdicts = new Map();
  for (const o of owners) {
    verdicts.set(`${o.store}:${o.id}`, o.verdict);
    if (o.steam_id && o.store !== "steam" && !verdicts.has(`steam:${o.steam_id}`)) verdicts.set(`steam:${o.steam_id}`, o.verdict);
  }
  const games = {};
  for (const key of new Set([...players.keys(), ...verdicts.keys()])) {
    const word = communityVerdict({ verdict: verdicts.get(key) ?? null, players: players.get(key) ?? null });
    if (word) games[key] = word;
  }
  return Object.fromEntries(Object.entries(games).sort(([a], [b]) => a.localeCompare(b)));
}

/** Anti-cheat that keeps a game's online play closed on a Mac (same rule as the app's `AntiCheat.Entry`). */
export function antiCheatBlocks(entry) {
  if (!entry) return false;
  if (["Broken", "Denied", "Planned"].includes(entry.status)) return true;
  return entry.anticheats.some((a) => a === "Easy Anti-Cheat" || a === "BattlEye");
}
