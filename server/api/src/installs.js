// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
// Installs that share how games run, from the app's daily note (POST /v1/installs): a random id made for this
// alone, hashed with a secret salt, and when it was first and last heard from. (Every new install is also counted
// once without any id: the "install" counts.) An install silent for 30 days counts as uninstalled; when it
// is heard from again, it's back, and counted as a return. New installs and returns are also counted per day.
import { count, today } from "./stats.js";

export const GONE_AFTER_DAYS = 30;
const dayNumber = (day) => Math.floor(Date.parse(day + "T00:00:00Z") / 86_400_000);

/** Notes an install heard from today: "new", "back" (after 30 silent days or more) or "seen". */
export async function heard(db, id, version, country, now) {
  const day = today(now);
  const row = await db.prepare("SELECT last_day FROM installs WHERE id = ?").bind(id).first();
  if (!row) {
    await db.prepare("INSERT INTO installs (id, first_day, last_day, version, country) VALUES (?, ?, ?, ?, ?)").bind(id, day, day, version, country).run();
    return "new";
  }
  await db.prepare("UPDATE installs SET last_day = ?, version = ? WHERE id = ?").bind(day, version, id).run();
  if (dayNumber(day) - dayNumber(row.last_day) > GONE_AFTER_DAYS) {
    await count(db, now, "return", version, "app", country);
    return "back";
  }
  return "seen";
}

/** For the owner's page: installed now, uninstalled (silent 30 days), and how many came back in the period. */
export async function installsSummary(db, since, now) {
  const cutoff = today(now - GONE_AFTER_DAYS * 86_400_000);
  const row = await db.prepare(`SELECT COUNT(*) AS tracked, SUM(last_day >= ?) AS now, SUM(last_day < ?) AS gone FROM installs`)
    .bind(cutoff, cutoff).first();
  const all = await db.prepare(`SELECT COALESCE(SUM(count), 0) AS n FROM counts WHERE kind = 'install'`).first();
  const back = await db.prepare(`SELECT COALESCE(SUM(count), 0) AS n FROM counts WHERE kind = 'return' AND day >= ?`).bind(since).first();
  const gone = (await db.prepare(`SELECT last_day AS day, COUNT(*) AS count FROM installs WHERE last_day < ? AND last_day >= ? GROUP BY last_day ORDER BY last_day`)
    .bind(cutoff, today(Date.parse(since + "T00:00:00Z") - GONE_AFTER_DAYS * 86_400_000)).all()).results;
  return { allTime: all?.n ?? 0, tracked: row?.tracked ?? 0, installedNow: row?.now ?? 0, uninstalled: row?.gone ?? 0, returned: back?.n ?? 0,
           // Uninstalls by the day the install was last heard from (it counts as gone 30 days after).
           goneByLastDay: gone };
}
