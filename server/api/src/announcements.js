// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
// Announcements: short messages the owner sends to every Sommelier (or to some: older versions, owners of a game).
// The app reads the list when it starts and every few hours, and shows what is new as a banner (and, for the ones
// marked so, a macOS notification). The list lives in R2 as announcements.json; the owner publishes it with PUT.

export const LEVELS = ["info", "important"];
const ID = /^[a-z0-9][a-z0-9-]{0,63}$/;
const LANG = /^[a-z]{2}(-[A-Za-z]{2,4})?$/;
const VERSION = /^\d{1,4}(\.\d{1,4}){0,3}$/;
const GAME = /^(steam|epic|gog|ea|ubisoft|battlenet):[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/;

/** Problems in an announcements list (empty when it can be published). */
export function checkAnnouncements(list) {
  const problems = [];
  if (!list || typeof list !== "object" || list.version !== 1 || !Array.isArray(list.announcements)) return ["version must be 1, with an announcements list"];
  if (list.announcements.length > 50) problems.push("at most 50 announcements");
  const ids = new Set();
  list.announcements.forEach((a, i) => {
    const at = `announcements[${i}]`;
    if (!a || typeof a !== "object") { problems.push(at); return; }
    if (!ID.test(a.id ?? "")) problems.push(`${at}.id`);
    else if (ids.has(a.id)) problems.push(`${at}.id: used twice`);
    ids.add(a.id);
    if (!LEVELS.includes(a.level)) problems.push(`${at}.level`);
    if (!texts(a.title, 120)) problems.push(`${at}.title: an English text and other languages, up to 120 characters`);
    if (a.body != null && !texts(a.body, 1000)) problems.push(`${at}.body`);
    if (a.link != null) {
      if (typeof a.link !== "object" || !/^https:\/\/[^\s]{3,500}$/.test(a.link.url ?? "")) problems.push(`${at}.link.url: https only`);
      else if (a.link.label != null && !texts(a.link.label, 40)) problems.push(`${at}.link.label`);
    }
    for (const key of ["from", "until"]) if (a[key] != null && Number.isNaN(Date.parse(a[key]))) problems.push(`${at}.${key}: a date`);
    if (a.from != null && a.until != null && Date.parse(a.from) >= Date.parse(a.until)) problems.push(`${at}: from is after until`);
    for (const key of ["minApp", "belowApp"]) if (a[key] != null && !VERSION.test(a[key])) problems.push(`${at}.${key}: a version like 0.3.0`);
    if (a.games != null && (!Array.isArray(a.games) || a.games.length > 50 || !a.games.every((g) => GAME.test(g)))) problems.push(`${at}.games: like steam:271590`);
    if (a.notify != null && typeof a.notify !== "boolean") problems.push(`${at}.notify`);
  });
  return problems;
}

/** `{ "en": "…", "ru": "…" }`: English is required (the fallback), each text non-empty and short enough. */
function texts(value, max) {
  if (!value || typeof value !== "object" || Array.isArray(value) || typeof value.en !== "string") return false;
  return Object.entries(value).every(([lang, text]) => LANG.test(lang) && typeof text === "string" && text.trim() && text.length <= max);
}
