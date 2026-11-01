// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
// What players' Sommelier uses, sent once a day by installs that share how games run (POST /v1/usage): the stores
// signed in, whether Controller Mode, clips and the in-game counter are used, the kinds of controllers, and once,
// how long it took from the first start to the first game. Under the same hashed player id as reports, deleted
// with them ("Delete my data") and after a year.
import { STORES } from "./reports.js";

const PADS = ["xbox", "playStation", "other"];
const CLIENT = /^[0-9a-f-]{8,64}$/;
const VERSION = /^[0-9A-Za-z.+-]{1,24}$/;

/** The body checked; `{ usage }` or `{ error }`. */
export function validateUsage(body) {
  if (!body || typeof body !== "object") return { error: "not an object" };
  const { client, app, stores, controllerMode, clips, counter, pads, firstGameMinutes } = body;
  if (typeof client !== "string" || !CLIENT.test(client)) return { error: "bad client" };
  if (app != null && (typeof app !== "string" || !VERSION.test(app))) return { error: "bad app" };
  if (!Array.isArray(stores) || stores.length > STORES.length || !stores.every((s) => STORES.includes(s))) return { error: "bad stores" };
  if (!Array.isArray(pads) || pads.length > PADS.length || !pads.every((p) => PADS.includes(p))) return { error: "bad pads" };
  for (const flag of [controllerMode, clips, counter]) if (typeof flag !== "boolean") return { error: "bad flag" };
  if (firstGameMinutes != null && (!Number.isInteger(firstGameMinutes) || firstGameMinutes < 0 || firstGameMinutes > 525_600)) {
    return { error: "bad firstGameMinutes" };
  }
  return { usage: { client, app: app ?? null, stores: [...new Set(stores)].sort(), pads: [...new Set(pads)].sort(),
                    controllerMode, clips, counter, firstGameMinutes: firstGameMinutes ?? null } };
}

/** One row per player and day; sent again the same day, it replaces the earlier one. */
export async function saveUsage(db, player, usage, day) {
  await db.prepare(
    `INSERT INTO usage (client, day, app_version, stores, controller_mode, clips, counter, pads, first_game_minutes)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
     ON CONFLICT (client, day) DO UPDATE SET app_version = excluded.app_version, stores = excluded.stores,
       controller_mode = excluded.controller_mode, clips = excluded.clips, counter = excluded.counter, pads = excluded.pads,
       first_game_minutes = COALESCE(excluded.first_game_minutes, usage.first_game_minutes)`)
    .bind(player, day, usage.app, JSON.stringify(usage.stores), usage.controllerMode ? 1 : 0, usage.clips ? 1 : 0,
          usage.counter ? 1 : 0, JSON.stringify(usage.pads), usage.firstGameMinutes).run();
}

const dayNumber = (day) => Math.floor(Date.parse(day + "T00:00:00Z") / 86_400_000);

/** For the owner's page: of the players seen in the period, what they use; time to the first game; how many come back. */
export async function usageSummary(db, since, today) {
  const rows = (await db.prepare(`SELECT client, day, stores, controller_mode, clips, counter, pads FROM usage WHERE day >= ? ORDER BY day`)
    .bind(since).all()).results;
  // Each player's latest day in the period stands for them; Controller Mode counts if opened on any day.
  const players = new Map();
  for (const r of rows) {
    const p = players.get(r.client) ?? { controllerMode: false, pads: new Set() };
    p.stores = JSON.parse(r.stores); p.clips = !!r.clips; p.counter = !!r.counter;
    p.controllerMode ||= !!r.controller_mode;
    for (const pad of JSON.parse(r.pads)) p.pads.add(pad);
    players.set(r.client, p);
  }
  const count = (pick) => {
    const out = {};
    for (const p of players.values()) for (const k of pick(p)) out[k] = (out[k] ?? 0) + 1;
    return Object.fromEntries(Object.entries(out).sort((a, b) => b[1] - a[1]));
  };
  const all = [...players.values()];
  const minutes = (await db.prepare(`SELECT first_game_minutes AS m FROM usage WHERE first_game_minutes IS NOT NULL AND day >= ? ORDER BY m`)
    .bind(since).all()).results.map((r) => r.m);
  return {
    players: players.size,
    stores: count((p) => p.stores),
    noStore: all.filter((p) => !p.stores.length).length,
    features: { controllerMode: all.filter((p) => p.controllerMode).length, clips: all.filter((p) => p.clips).length,
                counter: all.filter((p) => p.counter).length },
    pads: count((p) => [...p.pads]),
    firstGame: { players: minutes.length, median: minutes.length ? minutes[Math.floor(minutes.length / 2)] : null,
                 withinHour: minutes.filter((m) => m <= 60).length },
    retention: await retention(db, today),
  };
}

/** Of the players first seen 7 and 30 days or more ago, how many were seen again that long after. */
async function retention(db, today) {
  const rows = (await db.prepare(`SELECT client, MIN(day) AS first, MAX(day) AS last FROM usage GROUP BY client`).all()).results;
  const now = dayNumber(today);
  const after = (days) => {
    const cohort = rows.filter((r) => now - dayNumber(r.first) >= days);
    return { players: cohort.length, back: cohort.filter((r) => dayNumber(r.last) - dayNumber(r.first) >= days).length };
  };
  return { week: after(7), month: after(30) };
}
