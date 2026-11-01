// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
// Apple's Game Porting Toolkit: the app opens a direct link to its disk image in the player's browser (Apple's
// license keeps it off our servers). The link lives in R2 as toolkit.json so it can change without an app update,
// and a daily look at Apple's page tells the owner (admin page) when a new toolkit may have replaced it.
// Two links: `download` is the newest toolkit (GPTK 4, built for macOS 27: Metal 4), `legacy` the stable one for
// older macOS, where the GPTK 4 beta hangs games (ray tracing pipelines) and has no Metal 4. The app takes
// `legacy` below macOS 27.

export const DEFAULT_TOOLKIT = {
  version: 1,
  download: "https://developer.apple.com/services-account/download?path=/Developer_Tools/Game_Porting_Toolkit_4.0_beta_1/Game_Porting_Toolkit_4.0_beta_3.dmg",
  legacy: "https://developer.apple.com/services-account/download?path=/Developer_Tools/Game_Porting_Toolkit_3.0/Game_Porting_Toolkit_3.0.dmg",
};
const LINK = /^https:\/\/(developer\.apple\.com\/services-account\/download\?path=|download\.developer\.apple\.com)\/Developer_Tools\/[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+\.dmg$/;
const PAGE = "https://developer.apple.com/games/game-porting-toolkit/";

/** Problems in a toolkit.json (empty when it can be published). */
export function checkToolkit(body) {
  if (!body || typeof body !== "object" || body.version !== 1) return ["version must be 1"];
  const problems = [];
  for (const key of ["download", "legacy"]) {
    if (body[key] == null && key === "legacy") continue;
    if (!LINK.test(body[key] ?? "")) problems.push(`${key}: a link to a .dmg in Apple's Developer_Tools`);
  }
  return problems;
}

/** A download.developer.apple.com link (what the downloads page copies) as the form that signs in first. */
export function normalizeLink(url) {
  const m = /^https:\/\/download\.developer\.apple\.com(\/Developer_Tools\/.+\.dmg)$/.exec(url ?? "");
  return m ? `https://developer.apple.com/services-account/download?path=${m[1]}` : url;
}

/** Toolkit versions Apple's page names ("Game Porting Toolkit 4", "… 4.0 beta 3"), sorted. */
export function versionsOn(html) {
  const found = new Set();
  for (const m of String(html).matchAll(/Game Porting Toolkit (\d+(?:\.\d+)*(?: beta \d+)?)/gi)) found.add(m[1].toLowerCase());
  return [...found].sort();
}

/** Daily: remembers what Apple's page names; a change is kept for the admin page until the owner sets a link. */
export async function watchToolkit(env, now, fetcher = fetch) {
  const response = await fetcher(PAGE, { headers: { "User-Agent": "Sommelier toolkit watch" } });
  if (!response.ok) return;
  const versions = versionsOn(await response.text());
  if (!versions.length) return;
  const old = await (await env.RELEASES.get("watch/toolkit.json"))?.json().catch(() => null);
  if (old && old.versions.join("|") === versions.join("|")) return;
  const changedAt = old ? new Date(now).toISOString() : old?.changedAt ?? null;   // the first look is the baseline
  await env.RELEASES.put("watch/toolkit.json", JSON.stringify({ versions, previous: old?.versions ?? null, changedAt }));
}
