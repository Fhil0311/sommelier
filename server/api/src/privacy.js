// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
// Players' data: deleting it on request, how long it is kept, and limits that keep the API (and Steam's patience)
// from being run down by a script.
import { hash } from "./reports.js";

const DAY = 86_400_000;

/** How long things are kept. Download and install counts hold nothing about anyone and stay. */
export const RETENTION = {
  reportsDays: 365,          // session reports: a year (the privacy policy says so)
  failuresDays: 180,         // launch failures (failures.js prunes them)
  limitsDays: 2,             // daily flood counters
  steamQueriesDays: 1,       // searches already passed on to Steam
};

/** Daily limits on what makes the API ask Steam: per address, and for everyone together. */
export const STEAM_LIMITS = { address: 100, all: 4000 };

/** Failed owner logins a day per address before the owner routes stop answering it. */
export const OWNER_FAILURES = 20;

const CLIENT = /^[0-9a-fA-F-]{16,64}$/;

/** The body of a delete request: `{ "client": "<the install's random id>" }`. */
export function validateForget(body) {
  const client = body?.client;
  if (typeof client !== "string" || !CLIENT.test(client)) return { error: "client" };
  return { client: client.toLowerCase() };
}

/** Deletes everything sent from one install: its session reports, launch failures and flood counters. */
export async function forget(db, salt, client) {
  const player = await hash(salt, `player:${client}`);
  const results = await db.batch([
    db.prepare("DELETE FROM reports WHERE client = ?").bind(player),
    db.prepare("DELETE FROM failures WHERE client = ?").bind(player),
    db.prepare("DELETE FROM usage WHERE client = ?").bind(player),
    db.prepare("DELETE FROM limits WHERE key IN (?, ?, ?)").bind(`p:${player}`, `fp:${player}`, `us:${player}`),
  ]);
  return { reports: results[0].meta?.changes ?? 0, failures: results[1].meta?.changes ?? 0 };
}

/** The daily clean-up: old reports, old counters, old search memory. */
export async function prune(db, now) {
  const day = Math.floor(now / DAY);
  await db.batch([
    db.prepare("DELETE FROM reports WHERE created_at < ?").bind(now - RETENTION.reportsDays * DAY),
    db.prepare("DELETE FROM usage WHERE day < ?").bind(new Date(now - RETENTION.reportsDays * DAY).toISOString().slice(0, 10)),
    db.prepare("DELETE FROM limits WHERE day < ?").bind(day - RETENTION.limitsDays),
    db.prepare("DELETE FROM steam_queries WHERE at < ?").bind(now - RETENTION.steamQueriesDays * DAY),
  ]);
}

/** Counts a request against a daily limit; false once the limit is reached. */
export async function allow(db, key, limit, now) {
  const day = Math.floor(now / DAY);
  const row = await db.prepare(
    `INSERT INTO limits (key, day, count) VALUES (?, ?, 1)
     ON CONFLICT (key) DO UPDATE SET count = CASE WHEN day = excluded.day THEN count + 1 ELSE 1 END, day = excluded.day
     RETURNING count`).bind(key, day).first();
  return (row?.count ?? 1) <= limit;
}

/** Whether a key is already over its limit today, without counting this request. */
export async function over(db, key, limit, now) {
  const row = await db.prepare("SELECT day, count FROM limits WHERE key = ?").bind(key).first();
  return !!row && row.day === Math.floor(now / DAY) && row.count >= limit;
}

/**
 * A gate the catalogue calls just before asking Steam: true while this address and everyone together are under
 * today's limits. Only real Steam requests count, so ordinary searches of the catalogue are never limited.
 */
export function steamGate(db, address, now, limits = STEAM_LIMITS) {
  let open = null;
  return async () => {
    if (open === null) open = (await allow(db, `ss:${address}`, limits.address, now)) && (await allow(db, "ss:all", limits.all, now));
    return open;
  };
}
