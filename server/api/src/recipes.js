// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
// Recipes: how a game is known to start, read by every app before a game's first launch (recipes.json), and the
// candidates for them from players' reports, and how the published ones do. A recipe can only choose among what the app already does (a graphics
// backend, a DLL override, Turbo off…); the owner publishes the list by hand after looking at the candidates.
import { checkAction } from "./failures.js";

const GAME = /^[a-z]+:[A-Za-z0-9._:-]{1,128}$/;
const SOURCE = /^[a-z0-9-]{1,32}$/;

/** Problems with a recipes list, or [] when it can be published. */
export function checkRecipes(list) {
  const problems = [];
  if (!list || typeof list !== "object" || list.version !== 1 || !Array.isArray(list.recipes)) return ["needs { version: 1, recipes: [...] }"];
  if (list.recipes.length > 5000) problems.push("more than 5000 recipes");
  const seen = new Set();
  list.recipes.forEach((r, i) => {
    const at = `recipes[${i}]`;
    if (!r || typeof r !== "object") { problems.push(`${at}: not an object`); return; }
    if (typeof r.game !== "string" || !GAME.test(r.game)) problems.push(`${at}.game`);
    else if (seen.has(r.game)) problems.push(`${at}.game repeats ${r.game}`);
    else seen.add(r.game);
    if (!Array.isArray(r.actions) || !r.actions.length || r.actions.length > 40) problems.push(`${at}.actions`);
    else r.actions.forEach((a, j) => problems.push(...checkAction(a, `${at}.actions[${j}]`)));
    if (r.source != null && !(typeof r.source === "string" && SOURCE.test(r.source))) problems.push(`${at}.source`);
    if (r.players != null && !(Number.isInteger(r.players) && r.players >= 0 && r.players <= 1_000_000)) problems.push(`${at}.players`);
    if (r.note != null && !(typeof r.note === "string" && r.note.length <= 300)) problems.push(`${at}.note`);
  });
  return problems;
}

/**
 * Games whose reports say one backend fails and another works: for each, what players saw by backend. A candidate
 * needs `minPlayers` different players running it on the working backend, at least `minRan` of them ran, and the
 * failing backend to have failed for at least half of its reports.
 */
export async function recipeCandidates(db, { minPlayers = 3, minRan = 0.8 } = {}) {
  const { results } = await db.prepare(
    `SELECT store, game_id AS id, MAX(title) AS title, backend, backend_choice AS choice,
       COUNT(*) AS reports, SUM(outcome = 'ran') AS ran, COUNT(DISTINCT client) AS players
     FROM reports WHERE backend IS NOT NULL GROUP BY store, game_id, backend, backend_choice`).all();
  const games = new Map();
  for (const r of results) {
    const key = `${r.store}:${r.id}`;
    const game = games.get(key) ?? { game: key, title: r.title ?? "", backends: new Map() };
    game.title ||= r.title ?? "";
    const b = game.backends.get(r.backend) ?? { backend: r.backend, reports: 0, ran: 0, players: 0, retries: 0, recipes: 0 };
    b.reports += r.reports; b.ran += r.ran ?? 0; b.players += r.players;
    if (r.choice === "retry") b.retries += r.reports;
    if (r.choice === "recipe") b.recipes += r.reports;
    game.backends.set(r.backend, b);
    games.set(key, game);
  }
  const out = [];
  for (const g of games.values()) {
    const backends = [...g.backends.values()];
    const works = backends.filter((b) => b.players >= minPlayers && b.ran / b.reports >= minRan).sort((a, b) => b.players - a.players)[0];
    const fails = backends.filter((b) => b !== works && (b.reports - b.ran) / b.reports >= 0.5).sort((a, b) => b.reports - a.reports)[0];
    if (!works || !fails) continue;
    out.push({ game: g.game, title: g.title, backend: works.backend, players: works.players, insteadOf: fails.backend,
      failed: fails.reports - fails.ran, of: fails.reports, backends });
  }
  return out.sort((a, b) => b.players - a.players || a.game.localeCompare(b.game));
}

/** The same action written the same way whatever the key order, to count it across reports. */
export function actionKey(action) {
  const sorted = (v) => Array.isArray(v) ? v.map(sorted)
    : v && typeof v === "object" ? Object.fromEntries(Object.keys(v).sort().map((k) => [k, sorted(v[k])])) : v;
  return JSON.stringify(sorted(action));
}

const gameOf = (r) => `${r.store}:${r.game_id}`;
const settingsOf = (r) => { try { return JSON.parse(r.settings ?? "null") ?? {}; } catch { return {}; } };

/**
 * Fixes players applied that work: for each game and action, the players whose report with it says the game ran.
 * A candidate needs `minPlayers` of them, at least `minRan` of its reports ran, and the game's published recipe
 * not to have it already. `recipe` is what the game's recipe would be with it (the published one plus this action).
 */
export async function fixCandidates(db, recipes = [], { minPlayers = 3, minRan = 0.8 } = {}) {
  const { results } = await db.prepare(
    `SELECT store, game_id, title, client, outcome, settings FROM reports
     WHERE settings IS NOT NULL AND json_array_length(settings, '$.actions') > 0`).all();
  const published = new Map(recipes.map((r) => [r.game, r]));
  const groups = new Map();
  for (const r of results) {
    for (const action of settingsOf(r).actions ?? []) {
      if (checkAction(action, "a").length) continue;
      const key = `${gameOf(r)}|${actionKey(action)}`;
      const g = groups.get(key) ?? { game: gameOf(r), title: r.title ?? "", action, reports: 0, ran: 0, players: new Set() };
      g.title ||= r.title ?? "";
      g.reports += 1;
      if (r.outcome === "ran") { g.ran += 1; g.players.add(r.client); }
      groups.set(key, g);
    }
  }
  const out = [];
  for (const g of groups.values()) {
    const recipe = published.get(g.game);
    if (recipe?.actions?.some((a) => actionKey(a) === actionKey(g.action))) continue;
    if (g.players.size < minPlayers || g.ran / g.reports < minRan) continue;
    out.push({ game: g.game, title: g.title, action: g.action, players: g.players.size, ran: g.ran, of: g.reports,
      recipe: { game: g.game, actions: [...(recipe?.actions ?? []), g.action], source: "reports" } });
  }
  return out.sort((a, b) => b.players - a.players || a.game.localeCompare(b.game));
}

/**
 * How the published recipes do: for each game with reports, the launches with its recipe in effect and those
 * without (the player took it back, or it came after). A recipe `hurts` when most launches with it failed and
 * launches without it did better; it `helps` when launches with it ran and those without mostly failed.
 */
export async function recipeResults(db, recipes = [], { minReports = 3 } = {}) {
  const { results } = await db.prepare(
    `SELECT store, game_id, MAX(title) AS title, outcome,
       EXISTS (SELECT 1 FROM json_each(settings, '$.fixes') WHERE value = 'recipe') AS with_recipe,
       COUNT(*) AS reports, COUNT(DISTINCT client) AS players
     FROM reports WHERE settings IS NOT NULL GROUP BY store, game_id, outcome, with_recipe`).all();
  const games = new Map(recipes.map((r) => [r.game, { game: r.game, title: "", source: r.source ?? null,
    with: { reports: 0, ran: 0, players: 0 }, without: { reports: 0, ran: 0, players: 0 } }]));
  for (const r of results) {
    const g = games.get(gameOf(r));
    if (!g) continue;
    g.title ||= r.title ?? "";
    const side = r.with_recipe ? g.with : g.without;
    side.reports += r.reports; side.players += r.players;
    if (r.outcome === "ran") side.ran += r.reports;
  }
  const failing = (s) => (s.reports - s.ran) / s.reports;
  const out = [];
  for (const g of games.values()) {
    if (!g.with.reports && !g.without.reports) continue;
    let verdict = "unknown";
    if (g.with.reports >= minReports && failing(g.with) >= 0.5 && (!g.without.reports || failing(g.without) < failing(g.with))) verdict = "hurts";
    else if (g.with.reports >= minReports && failing(g.with) <= 0.2 && g.without.reports >= minReports && failing(g.without) >= 0.5) verdict = "helps";
    else if (g.with.reports >= minReports && failing(g.with) <= 0.2) verdict = "works";
    out.push({ ...g, verdict });
  }
  const order = { hurts: 0, helps: 1, works: 2, unknown: 3 };
  return out.sort((a, b) => order[a.verdict] - order[b.verdict] || b.with.reports - a.with.reports || a.game.localeCompare(b.game));
}
