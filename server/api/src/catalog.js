// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
// The game catalogue in D1: filled from Steam as people search, from Steam's most-played chart, and from reports.
import { rate, antiCheatBlocks } from "./rating.js";
import { summarize } from "./reports.js";
import { normalize, slugify, STEAM_ART, steam as steamSource, fetchAntiCheat } from "./sources.js";

const DAY = 86_400_000;
const STALE = 14 * DAY;

export async function getGame(db, store, id) {
  return db.prepare("SELECT * FROM games WHERE store = ? AND id = ?").bind(store, id).first();
}

/** Adds games Steam's search found, without details yet. */
export async function addSearchResults(db, items, now) {
  if (!items.length) return;
  await db.batch(items.map((item) =>
    db.prepare("INSERT OR IGNORE INTO games (store, id, title, search, created_at) VALUES ('steam', ?, ?, ?, ?)")
      .bind(item.id, item.title, normalize(item.title), now)));
}

/** Fetches a Steam game's details and Valve's Steam Deck result into the catalogue. */
export async function enrich(db, appid, now, steam = steamSource) {
  const [details, deck] = await Promise.all([steam.details(appid).catch(() => undefined), steam.deck(appid).catch(() => null)]);
  if (details === undefined) return false;                          // Steam didn't answer: try again later
  if (details === null) {                                           // no store page (removed, region-locked)
    await db.prepare("INSERT INTO games (store, id, type, details_at, created_at) VALUES ('steam', ?, 'missing', ?, ?) " +
      "ON CONFLICT (store, id) DO UPDATE SET type = 'missing', details_at = excluded.details_at").bind(appid, now, now).run();
    return true;
  }
  await db.prepare(
    `INSERT INTO games (store, id, title, search, type, cover, header, mac, single, dx_min, deck_category, deck_tokens, details_at, created_at, reviews,
                        developer, year, genres, size_gb, slug)
     VALUES ('steam', ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?12, ?13, ?14, ?15, ?16, ?17, ?18)
     ON CONFLICT (store, id) DO UPDATE SET title = ?2, search = ?3, type = ?4, cover = ?5, header = ?6, mac = ?7, single = ?8,
       dx_min = ?9, deck_category = ?10, deck_tokens = ?11, details_at = ?12, reviews = ?13,
       developer = ?14, year = ?15, genres = ?16, size_gb = ?17, slug = coalesce(slug, ?18)`)
    .bind(appid, details.title, normalize(details.title), details.type, STEAM_ART(appid, "library_600x900.jpg"), details.header,
      details.mac ? 1 : 0, details.single == null ? null : (details.single ? 1 : 0), details.dxMin,
      deck?.category ?? null, deck ? JSON.stringify(deck.tokens) : null, now, details.reviews ?? null,
      details.developer ?? null, details.year ?? null, JSON.stringify(details.genres ?? []), details.sizeGB ?? null,
      await freeSlug(db, slugify(details.title), appid))
    .run();
  return true;
}

/** A game's page address: its title's slug; when another game already has it (a remake, a bundle), `<slug>-<appid>`.
 *  Kept once given (coalesce above), so addresses don't change under links and search results. */
async function freeSlug(db, slug, appid) {
  if (!slug) return null;
  const taken = await db.prepare("SELECT 1 AS n FROM games WHERE slug = ? AND NOT (store = 'steam' AND id = ?) LIMIT 1").bind(slug, appid).first();
  return taken ? `${slug}-${appid}` : slug;
}

export async function antiCheatFor(db, game) {
  const keys = [];
  if (game.store === "steam") keys.push(`steam:${game.id}`);
  if (game.title) keys.push(`name:${normalize(game.title)}`);
  for (const key of keys) {
    const row = await db.prepare("SELECT name, status, anticheats FROM anticheat WHERE key = ?").bind(key).first();
    if (row) return { name: row.name, status: row.status, anticheats: JSON.parse(row.anticheats) };
  }
  return null;
}

// A session with mods in play says nothing about the game itself: it is left out of a game's numbers.
const VANILLA = "COALESCE(mods, 0) = 0";

/** Every report about a game, from its own store or (for Steam games) from other stores' copies of it. */
export async function reportsFor(db, store, id) {
  const { results } = store === "steam"
    ? await db.prepare(`SELECT outcome, chip, fps_avg, backend, backend_choice FROM reports WHERE (steam_id = ? OR (store = 'steam' AND game_id = ?)) AND ${VANILLA}`).bind(id, id).all()
    : await db.prepare(`SELECT outcome, chip, fps_avg, backend, backend_choice FROM reports WHERE store = ? AND game_id = ? AND ${VANILLA}`).bind(store, id).all();
  return results;
}

/** Outcome counts for several Steam games at once (search results). */
export async function reportCounts(db, appids) {
  const counts = new Map(appids.map((id) => [id, { ran: 0, failed: 0 }]));
  if (!appids.length) return counts;
  const marks = appids.map(() => "?").join(",");
  const { results } = await db.prepare(
    `SELECT steam_id AS id, SUM(outcome = 'ran') AS ran, SUM(outcome != 'ran') AS failed FROM reports WHERE steam_id IN (${marks}) AND ${VANILLA} GROUP BY steam_id`)
    .bind(...appids).all();
  for (const row of results) counts.set(row.id, { ran: row.ran ?? 0, failed: row.failed ?? 0 });
  return counts;
}

/** The project's answer for a game: its own row, or for a Steam game a row of a copy tied to it. */
export async function verdictFor(db, store, id) {
  const row = store === "steam"
    ? await db.prepare("SELECT verdict FROM verdicts WHERE (store = 'steam' AND id = ?) OR steam_id = ? ORDER BY store = 'steam' DESC LIMIT 1").bind(id, id).first()
    : await db.prepare("SELECT verdict FROM verdicts WHERE store = ? AND id = ?").bind(store, id).first();
  return row?.verdict ?? null;
}

/** The project's answers for several Steam games (search results). */
async function verdictsForSteam(db, appids) {
  const out = new Map();
  if (!appids.length) return out;
  const marks = appids.map(() => "?").join(",");
  const { results } = await db.prepare(`SELECT COALESCE(CASE WHEN store = 'steam' THEN id END, steam_id) AS app, verdict FROM verdicts
    WHERE (store = 'steam' AND id IN (${marks})) OR steam_id IN (${marks})`).bind(...appids, ...appids).all();
  for (const r of results) out.set(r.app, r.verdict);
  return out;
}

function compatibilityOf(game, antiCheat, players, verdict = null) {
  return rate({
    verdict,
    deck: game.deck_category == null ? null : { category: game.deck_category, tokens: JSON.parse(game.deck_tokens ?? "[]") },
    antiCheatBlocks: antiCheatBlocks(antiCheat),
    singlePlayer: game.single == null ? null : game.single === 1,
    macVersion: game.mac === 1,
    players,
  });
}

/** A game in a list: enough for a search result or a card. */
export function cardView(game, antiCheat, counts, verdict = null) {
  const compatibility = compatibilityOf(game, antiCheat, counts, verdict);
  return { store: game.store, id: game.id, title: game.title, cover: game.cover, header: game.header, slug: game.slug ?? null,
    compatibility: { verdict: compatibility.verdict, notes: compatibility.notes } };
}

/** Everything about a game, for its page. */
export function gameView(game, antiCheat, rows, verdict = null) {
  const players = summarize(rows);
  return {
    store: game.store, id: game.id, title: game.title, cover: game.cover, header: game.header,
    compatibility: compatibilityOf(game, antiCheat, players, verdict),
    steam: game.store === "steam" ? {
      appid: game.id, macVersion: game.mac === 1, singlePlayer: game.single == null ? null : game.single === 1,
      directX: game.dx_min || null, deck: game.deck_category == null ? null : { category: game.deck_category },
    } : null,
    antiCheat: antiCheat ? { status: antiCheat.status, anticheats: antiCheat.anticheats } : null,
    players,
    updated: game.details_at ? new Date(game.details_at).toISOString() : null,
  };
}

/**
 * Search across stores, most popular first. Steam's catalogue is the base: a game sold on Steam is shown as its
 * Steam copy (its compatibility data is there). GOG's catalogue adds games Steam doesn't sell, and players' reports
 * add the Epic, Ubisoft and EA games they played (those stores have no public search). Popularity: Steam's
 * most-played chart, then the number of Steam reviews; games only on other stores follow, GOG's bestselling first.
 * The same words ask Steam and GOG at most once a day, and only while `mayAskSteam` (privacy.js steamGate) allows.
 */
export async function search(db, query, limit, now, ctx, steam = steamSource, mayAskSteam = async () => true) {
  const words = normalize(query).split(" ").filter(Boolean).slice(0, 6);
  if (!words.length) return [];
  const where = words.map(() => "search LIKE ?").join(" AND ");
  const like = words.map((w) => `%${w}%`);
  const pool = Math.max(limit * 3, 30);
  const find = async () => (await db.prepare(
    `SELECT * FROM games WHERE store = 'steam' AND type = 'game' AND ${where}
     ORDER BY popularity IS NULL, popularity, reviews IS NULL, reviews DESC, length(title) LIMIT ?`)
    .bind(...like, pool).all()).results;
  const findGOG = async () => (await db.prepare(
    `SELECT * FROM games WHERE store = 'gog' AND ${where} ORDER BY store_rank IS NULL, store_rank, length(title) LIMIT ?`)
    .bind(...like, pool).all()).results;
  let games = await find();
  const key = words.join(" ");
  if (games.length < limit && key.length >= 2 && !(await askedRecently(db, key, now)) && (await mayAskSteam())) {
    await db.prepare("INSERT OR REPLACE INTO steam_queries (query, at) VALUES (?, ?)").bind(key, now).run();
    const [found, gog] = await Promise.all([
      steam.search(query).catch(() => []).then((list) => list.slice(0, 10)),
      steam.gogSearch ? steam.gogSearch(query).catch(() => []) : Promise.resolve([]),
    ]);
    await addSearchResults(db, found, now);
    await addGOGResults(db, gog, now);
    const pending = [];
    for (const item of found) {
      const row = await getGame(db, "steam", item.id);
      if (row && !row.details_at) pending.push(item.id);
    }
    // The first few now, so the answer has them; the rest after the response.
    await Promise.all(pending.slice(0, 4).map((id) => enrich(db, id, now, steam)));
    if (pending.length > 4) ctx?.waitUntil?.(Promise.all(pending.slice(4).map((id) => enrich(db, id, now, steam))));
    games = await find();
  }
  // Steam games read before reviews were kept rank by title alone: a few of them are read again (within the limits).
  const unranked = games.filter((g) => g.reviews == null && g.popularity == null).slice(0, 4).map((g) => g.id);
  if (unranked.length && (await mayAskSteam())) {
    await Promise.all(unranked.map((id) => enrich(db, id, now, steam)));
    games = await find();
  }
  // Steam's popular ones first, then games found only on other stores (a title Steam has is shown once, as Steam's).
  const seen = games.map((g) => baseTitle(g.title));
  const others = [];
  for (const g of [...(await findGOG()), ...(await reportedElsewhere(db, like, pool))]) {
    const base = baseTitle(g.title);
    if (seen.some((s) => sameGame(s, base))) continue;
    seen.push(base);
    others.push(g);
  }
  const picked = [...games, ...others].slice(0, limit);
  const steamIDs = picked.filter((g) => g.store === "steam").map((g) => g.id);
  const counts = await reportCounts(db, steamIDs);
  const verdicts = await verdictsForSteam(db, steamIDs);
  return Promise.all(picked.map(async (g) => g.store === "steam"
    ? cardView(g, await antiCheatFor(db, g), counts.get(g.id), verdicts.get(g.id))
    : cardView(g, await antiCheatFor(db, g), await storeCounts(db, g.store, g.id), await verdictFor(db, g.store, g.id))));
}

// Edition words stores add to the same game ("The Witcher: Enhanced Edition Director's Cut", "… Final Cut Bundle").
const EDITION = /\b(game of the year|goty|complete|definitive|enhanced|remastered|deluxe|ultimate|gold|standard|digital|edition|bundle|pack|director s cut|the final cut|final cut|collection)\b/g;

/** A title without its edition words, for telling whether two stores sell the same game. */
export function baseTitle(title) {
  return normalize(title).replace(EDITION, " ").replace(/\s+/g, " ").trim();
}

/** The same game: equal titles once edition words are gone ("Control" and "Control Old" are not). */
export function sameGame(a, b) {
  return Boolean(a) && a === b;
}

/** GOG search results into the catalogue, with their place in GOG's bestselling order. */
async function addGOGResults(db, items, now) {
  const statements = items.map((item, rank) => db.prepare(
    `INSERT INTO games (store, id, title, search, type, cover, header, store_rank, details_at, created_at)
     VALUES ('gog', ?1, ?2, ?3, 'game', ?4, ?5, ?6, ?7, ?7)
     ON CONFLICT (store, id) DO UPDATE SET title = ?2, search = ?3, cover = ?4, header = ?5,
       store_rank = min(coalesce(store_rank, ?6), ?6), details_at = ?7`)
    .bind(item.id, item.title, normalize(item.title), item.cover, item.header, rank, now));
  if (statements.length) await db.batch(statements);
}

/** Epic, Ubisoft and EA (and GOG) games players have reported, matching the words: the most reported first. */
async function reportedElsewhere(db, like, limit) {
  const { results } = await db.prepare(
    `SELECT store, game_id AS id, max(title) AS title, count(*) AS n FROM reports
     WHERE store IN ('epic', 'ubisoft', 'ea', 'gog') AND title IS NOT NULL AND title != ''
     GROUP BY store, game_id ORDER BY n DESC LIMIT 400`).all();
  const words = like.map((w) => w.slice(1, -1));
  return results
    .map((r) => ({ store: r.store, id: r.id, title: r.title, search: normalize(r.title), cover: null, header: null }))
    .filter((r) => words.every((w) => r.search.includes(w)))
    .slice(0, limit);
}

/** Outcome counts of one game of another store, as `reportCounts` gives them for Steam games. */
async function storeCounts(db, store, id) {
  const row = await db.prepare(
    `SELECT sum(outcome = 'ran') AS ran, sum(outcome != 'ran') AS failed FROM reports WHERE store = ? AND game_id = ? AND ${VANILLA}`)
    .bind(store, id).first();
  return { ran: row?.ran ?? 0, failed: row?.failed ?? 0 };
}

async function askedRecently(db, key, now) {
  const row = await db.prepare("SELECT at FROM steam_queries WHERE query = ?").bind(key).first();
  return !!row && row.at > now - DAY;
}

/**
 * The owner's export for the site's game pages: Steam games with their details, a page at a time (`after` = the last
 * appid of the page before), each with everything its page shows. `stores`: Steam, and GOG/Epic/Ubisoft/EA where the
 * same title is known there (the GOG catalogue, players' reports). Only games with a slug, a title and details.
 */
export async function gamesExport(db, after, limit) {
  const { results } = await db.prepare(
    `SELECT * FROM games WHERE store = 'steam' AND type = 'game' AND details_at IS NOT NULL AND slug IS NOT NULL AND title != ''
     AND CAST(id AS INTEGER) > ? ORDER BY CAST(id AS INTEGER) LIMIT ?`).bind(Number(after) || 0, limit).all();
  const sold = new Map();                                              // normalized title → stores that have it
  const note = (title, store) => { const k = normalize(title); (sold.get(k) ?? sold.set(k, new Set()).get(k)).add(store); };
  for (const r of (await db.prepare("SELECT title, store FROM games WHERE store != 'steam' AND title != ''").all()).results) note(r.title, r.store);
  for (const r of (await db.prepare("SELECT DISTINCT title, store FROM reports WHERE title IS NOT NULL AND title != ''").all()).results) note(r.title, r.store);
  const games = [];
  for (const g of results) {
    const view = gameView(g, await antiCheatFor(db, g), await reportsFor(db, "steam", g.id), await verdictFor(db, "steam", g.id));
    const elsewhere = [...(sold.get(normalize(g.title)) ?? [])].filter((s) => s !== "steam").sort();
    games.push({ ...view, slug: g.slug, developer: g.developer, year: g.year, genres: g.genres ? JSON.parse(g.genres) : [], sizeGB: g.size_gb,
      popularity: g.popularity, reviews: g.reviews, stores: ["steam", ...elsewhere] });
  }
  return { games, next: results.length === limit ? results.at(-1).id : null };
}

export async function top(db, limit) {
  const { results } = await db.prepare(
    "SELECT * FROM games WHERE store = 'steam' AND type = 'game' AND popularity IS NOT NULL ORDER BY popularity LIMIT ?").bind(limit).all();
  const counts = await reportCounts(db, results.map((g) => g.id));
  const verdicts = await verdictsForSteam(db, results.map((g) => g.id));
  return Promise.all(results.map(async (g) => cardView(g, await antiCheatFor(db, g), counts.get(g.id), verdicts.get(g.id))));
}

// MARK: Daily upkeep

export async function refreshAntiCheat(db, now, load = fetchAntiCheat) {
  const entries = await load();
  if (entries.length < 100) throw new Error(`anti-cheat list looks wrong (${entries.length} entries)`);
  const statements = [db.prepare("DELETE FROM anticheat")];
  for (const e of entries) {
    const row = [e.name, e.status, JSON.stringify(e.anticheats)];
    if (e.steamId) statements.push(db.prepare("INSERT OR REPLACE INTO anticheat (key, name, status, anticheats) VALUES (?, ?, ?, ?)").bind(`steam:${e.steamId}`, ...row));
    statements.push(db.prepare("INSERT OR REPLACE INTO anticheat (key, name, status, anticheats) VALUES (?, ?, ?, ?)").bind(`name:${normalize(e.name)}`, ...row));
  }
  for (let i = 0; i < statements.length; i += 100) await db.batch(statements.slice(i, i + 100));
  await setMeta(db, "anticheat_at", String(now));
  return entries.length;
}

export async function refreshMostPlayed(db, now, steam = steamSource) {
  const ranks = await steam.mostPlayed();
  if (!ranks.length) return 0;
  const statements = [db.prepare("UPDATE games SET popularity = NULL WHERE popularity IS NOT NULL")];
  for (const r of ranks) {
    statements.push(db.prepare("INSERT OR IGNORE INTO games (store, id, created_at) VALUES ('steam', ?, ?)").bind(r.id, now));
    statements.push(db.prepare("UPDATE games SET popularity = ? WHERE store = 'steam' AND id = ?").bind(r.rank, r.id));
  }
  for (let i = 0; i < statements.length; i += 100) await db.batch(statements.slice(i, i + 100));
  return ranks.length;
}

/** Details for games that have none or old ones, most popular first; a few per run to stay gentle with Steam. */
export async function refreshStale(db, now, count = 40, steam = steamSource) {
  const { results } = await db.prepare(
    `SELECT id FROM games WHERE store = 'steam' AND (details_at IS NULL OR details_at < ? OR (type = 'game' AND reviews IS NULL))
     ORDER BY details_at IS NOT NULL, popularity IS NULL, popularity LIMIT ?`).bind(now - STALE, count).all();   // reviews: read before 0010
  let done = 0;
  for (const { id } of results) if (await enrich(db, id, now, steam)) done += 1;
  return done;
}

export async function getMeta(db, key) {
  return (await db.prepare("SELECT value FROM meta WHERE key = ?").bind(key).first())?.value ?? null;
}

async function setMeta(db, key, value) {
  await db.prepare("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)").bind(key, value).run();
}
