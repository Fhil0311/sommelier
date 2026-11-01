// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
// Public sources the compatibility database is built from. No keys, nothing about the people asking:
//   Steam store search, game details and Valve's Steam Deck report (store.steampowered.com),
//   Steam's most-played chart (api.steampowered.com),
//   GOG's catalogue search (catalog.gog.com),
//   "Are We Anti-Cheat Yet?" (github.com/AreWeAntiCheatYet, MIT License).

export const STEAM_ART = (appid, file) => `https://shared.cloudflare.steamstatic.com/store_item_assets/steam/apps/${appid}/${file}`;
export const ANTICHEAT_URL = "https://raw.githubusercontent.com/AreWeAntiCheatYet/AreWeAntiCheatYet/master/games.json";

/** Lowercase letters and digits only, words separated by single spaces: "The Witcher® 3" → "the witcher 3". */
export function normalize(title) {
  return String(title ?? "")
    .replace(/[\u2122\u00ae\u00a9]/g, "")         // trademark signs, before NFKD spells "\u2122" out as "TM"
    .toLowerCase()
    .normalize("NFKD")
    .replace(/[\u0300-\u036f]/g, "")              // accents
    .replace(/[^\p{L}\p{N}]+/gu, " ")
    .trim();
}

/** `storesearch`: `{"total":n,"items":[{"type":"app","name":"…","id":292030,…}]}` → [{id, title}] */
export function parseSearch(json) {
  return (json?.items ?? [])
    .filter((item) => item && item.type === "app" && Number.isInteger(item.id) && item.name)
    .map((item) => ({ id: String(item.id), title: item.name }));
}

/** `appdetails?appids=X`: the fields the rating and the site use, or null when Steam has no page for it. */
export function parseDetails(json, appid) {
  const entry = json?.[appid];
  if (!entry?.success || !entry.data) return null;
  const d = entry.data;
  const categories = new Set((d.categories ?? []).map((c) => Number(c.id)));
  const minimum = typeof d.pc_requirements === "object" && !Array.isArray(d.pc_requirements) ? d.pc_requirements.minimum : null;
  return {
    type: d.type ?? null,
    title: d.name ?? "",
    header: d.header_image ?? null,
    mac: d.platforms?.mac === true,
    single: categories.size ? categories.has(2) : null,
    dxMin: directXVersion(minimum),
    reviews: Number.isInteger(d.recommendations?.total) ? d.recommendations.total : null,
    developer: (d.developers ?? []).filter((n) => typeof n === "string")[0]?.replace(/,?\s*(Inc|LLC|Ltd|Co)\.?$/i, "").trim() || null,
    year: releaseYear(d.release_date?.date),
    genres: (d.genres ?? []).map((g) => g?.description).filter((n) => typeof n === "string" && n).slice(0, 6),
    sizeGB: storageGB(minimum),
  };
}

/** The year in Steam's release date ("Feb 24, 2022", "2022", "Q4 2026"); null when there isn't one yet. */
export function releaseYear(text) {
  const year = Number(/\b(19[89]\d|20[0-4]\d)\b/.exec(String(text ?? ""))?.[1]);
  return year || null;
}

/** The disk space a requirements block asks for ("Storage: 60 GB available space", "500 MB"), in GB; null when none. */
export function storageGB(html) {
  const text = String(html ?? "").replace(/<[^>]+>/g, " ");
  const match = /(?:Storage|Hard Drive|Hard Disk|Disk Space)\s*[:：]?\s*([\d.,]+)\s*(GB|MB|TB)/i.exec(text);
  if (!match) return null;
  const n = Number(match[1].replace(",", "."));
  if (!Number.isFinite(n) || n <= 0) return null;
  const gb = match[2].toUpperCase() === "TB" ? n * 1024 : match[2].toUpperCase() === "MB" ? n / 1024 : n;
  return gb > 1000 ? null : Math.round(gb * 10) / 10;
}

/** The address of a game's page on the site: lowercase title, no ®/™, anything else becomes a dash. */
export function slugify(title) {
  return normalize(String(title ?? "").replace(/['\u2019\u2018`]/g, "")).replace(/ /g, "-").slice(0, 80).replace(/-+$/g, "");   // "Baldur's" → "baldurs"
}

/** GOG's catalogue search, bestselling first: [{id, title, cover, header}] (games and packs, not DLC). */
export function parseGOGSearch(json) {
  return (json?.products ?? [])
    .filter((p) => p && /^\d+$/.test(String(p.id)) && p.title)
    .map((p) => ({ id: String(p.id), title: p.title, cover: p.coverVertical ?? null, header: p.coverHorizontal ?? null }));
}

/** The DirectX version a requirements block names ("DirectX: Version 12"); 0 when none. */
export function directXVersion(html) {
  const match = /DirectX\s*[:：]?\s*[^0-9\n<]{0,24}?(\d{1,2})/i.exec(String(html ?? "").replace(/<[^>]+>/g, " "));
  return match ? Number(match[1]) : 0;
}

/** `ajaxgetdeckappcompatibilityreport`: `{"results":{"resolved_category":3,"resolved_items":[{"loc_token":"#…"}]}}` */
export function parseDeck(json) {
  const results = json?.results;
  return {
    category: Number(results?.resolved_category ?? 0),
    tokens: (results?.resolved_items ?? []).map((item) => item?.loc_token).filter((t) => typeof t === "string"),
  };
}

/** `GetMostPlayedGames`: app ids by rank. */
export function parseMostPlayed(json) {
  return (json?.response?.ranks ?? []).filter((r) => Number.isInteger(r.appid)).map((r) => ({ id: String(r.appid), rank: r.rank }));
}

/** The anti-cheat list; native Linux games are left out, as the app does. */
export function parseAntiCheat(json) {
  return (Array.isArray(json) ? json : [])
    .filter((g) => g && g.native !== true && typeof g.name === "string" && typeof g.status === "string")
    .map((g) => ({ name: g.name, status: g.status, anticheats: Array.isArray(g.anticheats) ? g.anticheats : [], steamId: g.storeIds?.steam ? String(g.storeIds.steam) : null }));
}

// Steam refuses some free-form agents (403); the usual "compatible" form passes.
const STEAM_HEADERS = { "User-Agent": "Mozilla/5.0 (compatible; Sommelier/1.0; +https://playsommelier.com)" };

async function getJSON(url) {
  const response = await fetch(url, { headers: STEAM_HEADERS });
  if (!response.ok) throw new Error(`${url} → ${response.status}`);
  return response.json();
}

export const steam = {
  search: async (term) => parseSearch(await getJSON(`https://store.steampowered.com/api/storesearch/?term=${encodeURIComponent(term)}&l=english&cc=us`)),
  details: async (appid) => parseDetails(await getJSON(`https://store.steampowered.com/api/appdetails?appids=${appid}&l=english&cc=us`), appid),
  deck: async (appid) => parseDeck(await getJSON(`https://store.steampowered.com/saleaction/ajaxgetdeckappcompatibilityreport?nAppID=${appid}`)),
  mostPlayed: async () => parseMostPlayed(await getJSON("https://api.steampowered.com/ISteamChartsService/GetMostPlayedGames/v1/")),
  // GOG's public catalogue: what search adds for games Steam doesn't sell.
  gogSearch: async (term) => parseGOGSearch(await getJSON(`https://catalog.gog.com/v1/catalog?limit=10&query=like:${encodeURIComponent(term)}` +
    "&order=desc:bestselling&productType=in:game,pack&countryCode=US&locale=en-US&currencyCode=USD")),
};

export async function fetchAntiCheat() {
  return parseAntiCheat(await getJSON(ANTICHEAT_URL));
}
