// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
// Download statistics and active installs, without identifying anyone.
//
// Downloads: every full GET of an app archive (/v1/releases/Sommelier-<version>.zip), by version, day, source and
// country. "site" is a browser (the download button), "update" is the app's updater (Sparkle).
// Active installs: Sommelier asks for the appcast once a day and names its version in the User-Agent
// ("Sommelier/0.2.0 Sparkle/2.9.6"); the checks per day approximate how many installs are in use, by version.
// Countries come from Cloudflare's CF-IPCountry header; addresses are never stored.
import { usageSummary } from "./usage.js";
import { installsSummary } from "./installs.js";

/** "Sommelier/0.2.0 Sparkle/2.9.6" → "0.2.0"; null for anything else. */
export function appVersion(userAgent) {
  const match = /(?:^|\s)Sommelier\/([0-9][0-9A-Za-z.+-]{0,23})(?:\s|$)/.exec(String(userAgent ?? ""));
  return match ? match[1] : null;
}

/** Who fetched an archive: the app's updater, a browser, or something else (scripts, crawlers). */
export function source(userAgent) {
  const ua = String(userAgent ?? "");
  if (/Sparkle\//.test(ua)) return "update";
  if (/Mozilla\/5\.0/.test(ua)) return "site";
  return "other";
}

/** "Sommelier-0.2.0.zip" → "0.2.0" */
export function archiveVersion(name) {
  const match = /^Sommelier-([0-9A-Za-z.+-]{1,40})\.(zip|dmg)$/.exec(name);
  return match ? match[1] : null;
}

export function country(request) {
  const value = request.headers.get("CF-IPCountry") ?? "";
  return /^[A-Z]{2}$/.test(value) && value !== "T1" ? value : "XX";      // T1 is Tor
}

export const today = (now) => new Date(now).toISOString().slice(0, 10);

export async function count(db, now, kind, version, from, where) {
  await db.prepare(
    `INSERT INTO counts (day, kind, version, source, country, count) VALUES (?, ?, ?, ?, ?, 1)
     ON CONFLICT (day, kind, version, source, country) DO UPDATE SET count = count + 1`)
    .bind(today(now), kind, version, from, where).run();
}

/** The newest release in the appcast: its version and archive name. */
export function latestRelease(appcastXML) {
  const item = /<item>([\s\S]*?)<\/item>/.exec(appcastXML)?.[1];
  if (!item) return null;
  const version = /<sparkle:shortVersionString>([^<]+)<\/sparkle:shortVersionString>/.exec(item)?.[1];
  const url = /<enclosure[^>]*\burl="([^"]+)"/.exec(item)?.[1];
  const file = url?.split("/").pop();
  return version && file && archiveVersion(file) ? { version, file } : null;
}

/** Totals for the last `days` days (including today), for the owner's stats page. */
export async function summary(db, now, days) {
  const since = today(now - (days - 1) * 86_400_000);
  const rows = async (sql, ...args) => (await db.prepare(sql).bind(...args).all()).results;
  const downloads = await rows(`SELECT day, version, source, country, count FROM counts WHERE kind = 'download' AND day >= ?`, since);
  const installs = await rows(`SELECT day, version, country, count FROM counts WHERE kind = 'install' AND day >= ?`, since);
  const checks = await rows(`SELECT day, version, SUM(count) AS count FROM counts WHERE kind = 'check' AND day >= ? GROUP BY day, version`, since);
  const sum = (list, key) => {
    const out = {};
    for (const r of list) out[r[key]] = (out[r[key]] ?? 0) + r.count;
    return Object.fromEntries(Object.entries(out).sort((a, b) => b[1] - a[1]));
  };
  const byDay = (list) => Object.entries(sum(list, "day")).sort((a, b) => a[0].localeCompare(b[0])).map(([day, count]) => ({ day, count }));
  const lastDay = checks.reduce((d, r) => (r.day > d ? r.day : d), "");
  const from = now - days * 86_400_000;
  const reports = await db.prepare(`SELECT COUNT(*) AS n, SUM(created_at >= ?) AS recent, SUM(created_at >= ? AND mods = 1) AS with_mods FROM reports`).bind(from, from).first();
  // Sessions with mods in play are counted, but say nothing about how games run: the outcomes, the games' numbers
  // and the graphics choices are from sessions without them.
  const vanilla = "COALESCE(mods, 0) = 0";
  const outcomes = await rows(`SELECT outcome, COUNT(*) AS count FROM reports WHERE created_at >= ? AND ${vanilla} GROUP BY outcome`, from);
  const reportDays = await rows(`SELECT date(created_at / 1000, 'unixepoch') AS day, COUNT(*) AS count FROM reports WHERE created_at >= ? GROUP BY day`, from);
  const topGames = await rows(`SELECT COALESCE(steam_id, store || ':' || game_id) AS game, MAX(title) AS title, COUNT(*) AS reports,
      SUM(outcome = 'ran') AS ran, CAST(ROUND(AVG(fps_avg)) AS INTEGER) AS fps
    FROM reports WHERE created_at >= ? AND ${vanilla} GROUP BY game ORDER BY reports DESC LIMIT 20`, from);
  const backends = await rows(`SELECT COALESCE(steam_id, store || ':' || game_id) AS game, MAX(title) AS title, backend, COUNT(*) AS reports,
      SUM(outcome = 'ran') AS ran, SUM(backend_choice = 'manual') AS manual, CAST(ROUND(AVG(fps_avg)) AS INTEGER) AS fps
    FROM reports WHERE created_at >= ? AND backend IS NOT NULL AND ${vanilla} GROUP BY game, backend ORDER BY game, reports DESC LIMIT 200`, from);
  const choice = await db.prepare(`SELECT SUM(backend_choice = 'manual') AS manual, COUNT(backend_choice) AS known FROM reports WHERE created_at >= ? AND ${vanilla}`).bind(from).first();
  const chips = await rows(`SELECT chip, COUNT(*) AS count FROM reports WHERE created_at >= ? AND chip IS NOT NULL GROUP BY chip`, from);
  const games = await db.prepare(`SELECT COUNT(*) AS n FROM games WHERE type = 'game'`).first();
  const macos = await rows(`SELECT macos, COUNT(DISTINCT client) AS count FROM reports WHERE created_at >= ? AND macos IS NOT NULL GROUP BY macos`, from);
  return {
    since,
    downloads: {
      total: downloads.reduce((n, r) => n + r.count, 0),
      bySource: sum(downloads, "source"),
      byVersion: sum(downloads, "version"),
      byCountry: sum(downloads, "country"),
      byDay: byDay(downloads),
    },
    // New installs: Sommelier's first start on a Mac (POST /v1/installs).
    installs: {
      ...(await installsSummary(db, since, now)),
      total: installs.reduce((n, r) => n + r.count, 0),
      byDay: byDay(installs),
      byCountry: sum(installs, "country"),
    },
    activeInstalls: {
      byDay: byDay(checks),
      latestDay: lastDay || null,
      byVersion: sum(checks.filter((r) => r.day === lastDay), "version"),
    },
    reports: {
      total: reports?.n ?? 0, recent: reports?.recent ?? 0, withMods: reports?.with_mods ?? 0,
      byOutcome: sum(outcomes, "outcome"), byDay: byDay(reportDays), byChip: sum(chips, "chip"), byMacOS: sum(macos, "macos"), topGames,
    },
    settings: {
      // Per game and graphics: how many ran, how many players picked it by hand, average frame rate.
      byGameBackend: backends,
      // Of the reports that say how the graphics were chosen, how many were picked by hand.
      manual: choice?.manual ?? 0, withChoice: choice?.known ?? 0,
    },
    catalogue: { games: games?.n ?? 0 },
    usage: await usageSummary(db, since, today(now)),
  };
}

/** Constant-time comparison for the owner's token. */
export function sameToken(given, expected) {
  if (typeof given !== "string" || typeof expected !== "string" || !expected) return false;
  const a = new TextEncoder().encode(given), b = new TextEncoder().encode(expected);
  let diff = a.length ^ b.length;
  for (let i = 0; i < Math.max(a.length, b.length); i++) diff |= (a[i] ?? 0) ^ (b[i] ?? 0);
  return diff === 0;
}
