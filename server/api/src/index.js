// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
// Sommelier's public API (api.playsommelier.com): the compatibility database the site and the app read, and the reports
// players send from the app. The routes and their answers are described in ../README.md.
import { stagingGate, withStagingCookie } from "./staging.js";
import { SIGNATURE_HEADER, signedByOwner } from "./signature.js";
import { gamesExport, verdictFor, search, top, getGame, enrich, antiCheatFor, reportsFor, gameView, refreshAntiCheat, refreshMostPlayed, refreshStale } from "./catalog.js";
import { validateReport, hash, STORES } from "./reports.js";
import { validateUsage, saveUsage } from "./usage.js";
import { heard } from "./installs.js";
import { appVersion, source, archiveVersion, country, count, latestRelease, summary, sameToken, today } from "./stats.js";
import { validateFailure, saveFailure, failureSummary, failureDetail, pruneFailures, checkFixes, MAX_FAILURE_BYTES } from "./failures.js";
import { ADMIN_PAGE, ADMIN_CSP } from "./admin.js";
import { status as ownerStatus, shaders as ownerShaders } from "./owner.js";
import { checkRecipes, recipeCandidates, fixCandidates, recipeResults } from "./recipes.js";
import { checkAnnouncements } from "./announcements.js";
import { checkMods, modioProxy } from "./mods.js";
import { DEFAULT_TOOLKIT, checkToolkit, normalizeLink, watchToolkit } from "./toolkit.js";
import { communityVerdicts } from "./rating.js";
import { validateForget, forget, prune, allow, over, steamGate, OWNER_FAILURES } from "./privacy.js";

const LIMITS = { address: 200, player: 100 };          // reports a day
const FAILURE_LIMITS = { address: 50, player: 20 };    // failure reports a day (they're large)
const MODIO_LIMIT = 600;                               // mod.io catalogue requests a day per address (one key for everyone)
const ID = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/;

const app = {
  async fetch(request, env, ctx) {
    const closed = stagingGate(request, env);
    if (closed) return closed;
    return withStagingCookie(request, env, await app.handle(request, env, ctx));
  },

  async handle(request, env, ctx) {
    if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: cors() });
    // A deployed service with the development secrets would hash players with a public salt and let anyone in as
    // the owner: it answers nothing until the real ones are set.
    if (unsafeSecrets(env)) return json({ error: "service not configured" }, 503);
    const url = new URL(request.url);
    const parts = url.pathname.split("/").filter(Boolean);
    const now = Date.now();
    try {
      // The owner's stats page (admin.js); its data needs the owner's token.
      if (request.method === "GET" && parts.length === 1 && parts[0] === "admin") {
        return new Response(ADMIN_PAGE, { headers: { "Content-Type": "text/html; charset=utf-8", "Content-Security-Policy": ADMIN_CSP,
          "X-Content-Type-Options": "nosniff", "Referrer-Policy": "no-referrer", "Cache-Control": "no-store", "X-Robots-Tag": "noindex" } });
      }
      if (parts[0] !== "v1") return json({ error: "not found" }, 404);
      const route = parts.slice(1);

      // The owner puts back the version of a list before the last publish: POST /v1/{fixes|recipes|announcements|saves|mods}.json/rollback.
      if (request.method === "POST" && route.length === 2 && route[1] === "rollback" && LISTS.includes(route[0])) {
        if (!(await isOwner(request, env, now))) return json({ error: "not allowed" }, 401);
        const restored = await rollbackList(env, route[0]);
        return restored ? json({ restored }) : json({ error: "no earlier version" }, 404);
      }

      // The admin page's service state and shader packs (owner.js).
      // The owner adds games to the catalogue by Steam id (scripts/seed-games.py): a few at a time, as a Worker may
      // only make so many requests at once (each game asks Steam twice).
      if (route[0] === "admin" && route[1] === "games" && route[2] === "seed" && route.length === 3 && request.method === "POST") {
        if (!(await isOwner(request, env, now))) return json({ error: "not allowed" }, 401);
        const body = parseJSON(await request.text());
        const ids = Array.isArray(body?.appids) ? body.appids.map(String).filter((id) => /^\d{1,10}$/.test(id)).slice(0, 15) : [];
        const done = [], failed = [];
        for (const id of ids) {
          const row = await getGame(env.DB, "steam", id);
          if (row?.details_at && row.slug && row.reviews != null && now - row.details_at < 7 * 86_400_000) { done.push(id); continue; }
          await env.DB.prepare("INSERT OR IGNORE INTO games (store, id, created_at) VALUES ('steam', ?, ?)").bind(id, now).run();
          (await enrich(env.DB, id, now)) ? done.push(id) : failed.push(id);
        }
        return json({ done, failed });
      }
      if (route[0] === "admin" && route[1] === "games" && route.length === 2 && request.method === "GET") {
        if (!(await isOwner(request, env, now))) return json({ error: "not allowed" }, 401);
        return json(await gamesExport(env.DB, url.searchParams.get("after"), clamp(Number(url.searchParams.get("limit") ?? 100), 1, 200)));
      }
      if (route[0] === "admin" && (route[1] === "status" || route[1] === "shaders")) {
        if (!(await isOwner(request, env, now))) return json({ error: "not allowed" }, 401);
        if (route[1] === "status" && route.length === 2 && request.method === "GET") return json(await ownerStatus(env, LISTS));
        if (route[1] === "shaders") return ownerShaders(request, env, route.slice(2));
        return json({ error: "not found" }, 404);
      }

      if (request.method === "GET" && route[0] === "health") return json({ ok: true });

      // App updates (Sparkle): the appcast and the archives it points to, as scripts/release-app.sh uploaded them.
      // Each GET is counted (stats.js): appcast requests from the app approximate active installs by version,
      // archive downloads are counted by version and source.
      if ((request.method === "GET" || request.method === "HEAD") && route[0] === "appcast.xml" && route.length === 1) {
        const version = appVersion(request.headers.get("User-Agent"));
        if (request.method === "GET" && version) ctx.waitUntil(count(env.DB, now, "check", version, "update", country(request)).catch(() => {}));
        return release(env, "appcast.xml", "application/xml; charset=utf-8", 300);
      }
      // Engines (scripts/publish-engine.sh puts them in the bucket's engines/): the signed list the app checks
      // (engine-manifest.json and its .sig) and the archives it names. A new engine reaches every app at its next start.
      if ((request.method === "GET" || request.method === "HEAD") && route[0] === "engines" && route.length === 2
          && /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(route[1])) {
        const name = route[1];
        if (name.endsWith(".tar.xz")) return release(env, `engines/${name}`, "application/x-xz", 31536000);
        if (name === "engine-manifest.json") return release(env, "engines/engine-manifest.json", "application/json; charset=utf-8", 300);
        if (name === "engine-manifest.json.sig") return release(env, "engines/engine-manifest.json.sig", "text/plain; charset=utf-8", 300);
        return json({ error: "not found" }, 404);
      }
      if ((request.method === "GET" || request.method === "HEAD") && route[0] === "releases" && route.length === 2) {
        const version = archiveVersion(route[1]);
        if (!version) return json({ error: "bad path" }, 400);
        // The zip is what the app's updater takes; the disk image is what the site's button gives.
        const response = await release(env, route[1], route[1].endsWith(".dmg") ? "application/x-apple-diskimage" : "application/zip", 31536000);
        if (request.method === "GET" && response.status === 200 && !request.headers.get("Range") && !isInternal(request)) {
          ctx.waitUntil(count(env.DB, now, "download", version, source(request.headers.get("User-Agent")), country(request)).catch(() => {}));
        }
        return response;
      }
      // The owner's own downloads aren't counted: open /v1/internal once in a browser (or /v1/internal?off=1 to stop).
      if (request.method === "GET" && route[0] === "internal" && route.length === 1) {
        const off = url.searchParams.has("off");
        return new Response(off ? "counted again" : "this browser's downloads aren't counted", { headers: { "Content-Type": "text/plain; charset=utf-8",
          "Set-Cookie": `internal=${off ? "" : "1"}; Path=/; Max-Age=${off ? 0 : 31536000}; HttpOnly; SameSite=Lax${url.protocol === "https:" ? "; Secure" : ""}`,
          "Cache-Control": "no-store", "X-Robots-Tag": "noindex" } });
      }
      // The site's download button: the newest archive.
      if (request.method === "GET" && route[0] === "download" && route[1] === "latest" && route.length === 2) {
        const appcast = await env.RELEASES.get("appcast.xml");
        const latest = appcast ? latestRelease(await appcast.text()) : null;
        if (!latest) return json({ error: "no release yet" }, 404);
        // People get the disk image (drag to Applications); a release from before there was one, its zip.
        const image = latest.file.replace(/\.zip$/, ".dmg");
        const file = (await env.RELEASES.head(image)) ? image : latest.file;
        return new Response(null, { status: 302, headers: { Location: `${url.origin}/v1/releases/${file}`, "Cache-Control": "no-store", ...cors() } });
      }
      // The fixes list the app reads (failures.js). Published by the owner with PUT.
      if (request.method === "GET" && route[0] === "fixes.json" && route.length === 1) {
        const object = await env.RELEASES.get("fixes.json");
        if (!object) return json({ version: 1, rules: [] }, 200, 3600);
        return new Response(object.body, { headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "public, max-age=3600", ETag: object.httpEtag,
          ...signatureHeaders(object), ...cors() } });
      }
      if (request.method === "PUT" && route[0] === "fixes.json" && route.length === 1) {
        if (!(await isOwner(request, env, now))) return json({ error: "not allowed" }, 401);
        // Stored as sent, byte for byte: the owner's signature is of these bytes.
        const bytes = new Uint8Array(await request.arrayBuffer());
        const list = parseJSON(new TextDecoder().decode(bytes));
        const problems = checkFixes(list);
        if (problems.length) return json({ error: "fixes list has problems", problems }, 400);
        const signature = request.headers.get(SIGNATURE_HEADER);
        if (!(await signedByOwner(env, bytes, signature))) return json({ error: "needs the owner's signature (scripts/publish-fixes.sh signs it)" }, 400);
        await publishList(env, "fixes.json", bytes, signature);
        return json({ published: list.rules.length });
      }

      // The games that have HDR, from players' sessions (a game asked for HDR at least once): read by every app,
      // so the HDR switch shows before a game's first launch there. A copy from another store counts by its Steam id.
      // Our own researched answers (hdr_games) decide where they exist; players' reports fill in the rest.
      if (request.method === "GET" && route[0] === "hdr.json" && route.length === 1) {
        const { results } = await env.DB.prepare(
          "SELECT DISTINCT store, game_id, steam_id FROM reports WHERE hdr = 1").all();
        const ours = (await env.DB.prepare("SELECT game, hdr FROM hdr_games").all()).results;
        const decided = new Map(ours.map((r) => [r.game, r.hdr === 1]));
        const games = new Set(ours.filter((r) => r.hdr === 1).map((r) => r.game));
        for (const r of results) {
          for (const id of [`${r.store}:${r.game_id}`, r.steam_id ? `steam:${r.steam_id}` : null]) {
            if (id && !decided.has(id)) games.add(id);
          }
        }
        return json({ version: 1, games: [...games].sort() }, 200, 3600);
      }
      // Players' word on games, for the app to rate its whole library at once (rating.js communityVerdicts):
      // { version: 1, games: { "steam:292030": "works", … } }, only the games it decides.
      if (request.method === "GET" && route[0] === "verdicts.json" && route.length === 1) {
        const reports = (await env.DB.prepare("SELECT store, game_id, steam_id, outcome, address, created_at, mods FROM reports ORDER BY created_at").all()).results;
        const owners = (await env.DB.prepare("SELECT store, id, steam_id, verdict FROM verdicts").all()).results;
        return json({ version: 1, games: communityVerdicts(reports, owners) }, 200, 3600);
      }
      // The owner publishes the researched list: { version: 1, games: [ { game, hdr, source } ] } replaces it whole.
      if (request.method === "PUT" && route[0] === "hdr.json" && route.length === 1) {
        if (!(await isOwner(request, env, now))) return json({ error: "not allowed" }, 401);
        const list = parseJSON(await request.text());
        const ok = list?.version === 1 && Array.isArray(list.games) && list.games.length <= 20000 && list.games.every((g) =>
          g && typeof g.game === "string" && /^[a-z]+:[A-Za-z0-9._:-]{1,128}$/.test(g.game) && typeof g.hdr === "boolean"
          && (g.source == null || (typeof g.source === "string" && g.source.length <= 500)));
        if (!ok) return json({ error: "needs { version: 1, games: [ { game, hdr, source? } ] }" }, 400);
        await env.DB.batch([env.DB.prepare("DELETE FROM hdr_games"),
          ...list.games.map((g) => env.DB.prepare("INSERT OR REPLACE INTO hdr_games (game, hdr, source, updated_at) VALUES (?, ?, ?, ?)")
            .bind(g.game, g.hdr ? 1 : 0, g.source ?? null, now))]);
        return json({ published: list.games.length });
      }

      // Recipes: how games are known to start (recipes.js). Read by every app; published by the owner with PUT,
      // who sees the candidates from players' reports first.
      if (request.method === "GET" && route[0] === "recipes.json" && route.length === 1) {
        const object = await env.RELEASES.get("recipes.json");
        if (!object) return json({ version: 1, recipes: [] }, 200, 3600);
        return new Response(object.body, { headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "public, max-age=3600", ETag: object.httpEtag,
          ...signatureHeaders(object), ...cors() } });
      }
      if (request.method === "PUT" && route[0] === "recipes.json" && route.length === 1) {
        if (!(await isOwner(request, env, now))) return json({ error: "not allowed" }, 401);
        // Stored as sent, byte for byte: the owner's signature is of these bytes.
        const bytes = new Uint8Array(await request.arrayBuffer());
        const list = parseJSON(new TextDecoder().decode(bytes));
        const problems = checkRecipes(list);
        if (problems.length) return json({ error: "recipes list has problems", problems }, 400);
        const signature = request.headers.get(SIGNATURE_HEADER);
        if (!(await signedByOwner(env, bytes, signature))) return json({ error: "needs the owner's signature (scripts/publish-recipes.sh signs it)" }, 400);
        await publishList(env, "recipes.json", bytes, signature);
        return json({ published: list.recipes.length });
      }
      if (request.method === "GET" && route[0] === "recipes" && route[1] === "candidates" && route.length === 2) {
        if (!(await isOwner(request, env, now))) return json({ error: "not allowed" }, 401);
        return json({ candidates: await recipeCandidates(env.DB) });
      }
      // Fixes that worked for several players, and how the published recipes do (for the owner's page).
      if (request.method === "GET" && route[0] === "recipes" && (route[1] === "fix-candidates" || route[1] === "results") && route.length === 2) {
        if (!(await isOwner(request, env, now))) return json({ error: "not allowed" }, 401);
        const object = await env.RELEASES.get("recipes.json");
        const recipes = object ? (parseJSON(await object.text())?.recipes ?? []) : [];
        return route[1] === "results"
          ? json({ recipes: await recipeResults(env.DB, recipes) })
          : json({ candidates: await fixCandidates(env.DB, recipes) });
      }

      // Where games keep their saves (server/saves/from-ludusavi.py), signed by the owner like the recipes.
      if (request.method === "GET" && route[0] === "saves.json" && route.length === 1) {
        const object = await env.RELEASES.get("saves.json");
        if (!object) return json({ version: 1, games: {} }, 200, 3600);
        return new Response(object.body, { headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "public, max-age=3600", ETag: object.httpEtag,
          ...signatureHeaders(object), ...cors() } });
      }
      if (request.method === "PUT" && route[0] === "saves.json" && route.length === 1) {
        if (!(await isOwner(request, env, now))) return json({ error: "not allowed" }, 401);
        const bytes = new Uint8Array(await request.arrayBuffer());
        const list = parseJSON(new TextDecoder().decode(bytes));
        if (!list || list.version !== 1 || typeof list.games !== "object" || Array.isArray(list.games)) return json({ error: "version must be 1, with games" }, 400);
        const signature = request.headers.get(SIGNATURE_HEADER);
        if (!(await signedByOwner(env, bytes, signature))) return json({ error: "needs the owner's signature (scripts/publish-saves.sh signs it)" }, 400);
        await publishList(env, "saves.json", bytes, signature);
        return json({ published: Object.keys(list.games).length });
      }

      // Mods: how each game's mods are installed (mods.js), signed by the owner like the recipes. Read by every app;
      // published with PUT after the service has checked it field by field.
      if (request.method === "GET" && route[0] === "mods.json" && route.length === 1) {
        const object = await env.RELEASES.get("mods.json");
        if (!object) return json({ version: 1, games: [] }, 200, 3600);
        return new Response(object.body, { headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "public, max-age=3600", ETag: object.httpEtag,
          ...signatureHeaders(object), ...cors() } });
      }
      if (request.method === "PUT" && route[0] === "mods.json" && route.length === 1) {
        if (!(await isOwner(request, env, now))) return json({ error: "not allowed" }, 401);
        // Stored as sent, byte for byte: the owner's signature is of these bytes.
        const bytes = new Uint8Array(await request.arrayBuffer());
        const list = parseJSON(new TextDecoder().decode(bytes));
        const problems = checkMods(list);
        if (problems.length) return json({ error: "mods list has problems", problems }, 400);
        const signature = request.headers.get(SIGNATURE_HEADER);
        if (!(await signedByOwner(env, bytes, signature))) return json({ error: "needs the owner's signature (scripts/publish-mods.sh signs it)" }, 400);
        await publishList(env, "mods.json", bytes, signature);
        return json({ published: list.games.length });
      }
      // The mod.io catalogue of a game, read for the app with Sommelier's own key (mods.js): GET /v1/mods/modio/{gameID}/mods…
      if (request.method === "GET" && route[0] === "mods" && route[1] === "modio" && route.length >= 4) {
        if (!(await allow(env.DB, `mo:${await addressOf(request, env)}`, MODIO_LIMIT, now))) return json({ error: "too many requests today" }, 429);
        const answer = await modioProxy(env, route[2], route.slice(3), url.searchParams, now);
        return json(answer.body, answer.status, answer.status === 200 ? 600 : 0);
      }

      // Where the app sends players for Apple's Game Porting Toolkit (toolkit.js). Changed by the owner with PUT.
      if (route[0] === "toolkit.json" && route.length === 1) {
        if (request.method === "GET") {
          const object = await env.RELEASES.get("toolkit.json");
          const stored = object ? await object.json().catch(() => null) : null;
          return json({ ...DEFAULT_TOOLKIT, ...(stored ?? {}) }, 200, 3600);
        }
        if (request.method === "PUT") {
          if (!(await isOwner(request, env, Date.now()))) return json({ error: "unauthorized" }, 401);
          const body = await request.json().catch(() => null);
          if (body) for (const key of ["download", "legacy"]) if (body[key] != null) body[key] = normalizeLink(body[key]);
          if (!body || body.version !== 1) return json({ error: "toolkit link has problems", problems: ["version must be 1"] }, 400);
          // A link left out stays as it was (the owner changes one at a time): the result is what gets checked.
          const current = await (await env.RELEASES.get("toolkit.json"))?.json().catch(() => null);
          const saved = { ...DEFAULT_TOOLKIT, ...(current ?? {}), version: 1 };
          for (const key of ["download", "legacy"]) if (body[key] != null) saved[key] = body[key];
          const problems = checkToolkit(saved);
          if (problems.length) return json({ error: "toolkit link has problems", problems }, 400);
          await env.RELEASES.put("toolkit.json", JSON.stringify(saved));
          const watch = await (await env.RELEASES.get("watch/toolkit.json"))?.json().catch(() => null);
          if (watch?.changedAt) await env.RELEASES.put("watch/toolkit.json", JSON.stringify({ ...watch, changedAt: null }));
          return json({ saved: true, download: saved.download, legacy: saved.legacy });
        }
      }

      // Announcements to players (announcements.js). Read by every app; published by the owner with PUT.
      if (request.method === "GET" && route[0] === "announcements.json" && route.length === 1) {
        const object = await env.RELEASES.get("announcements.json");
        if (!object) return json({ version: 1, announcements: [] }, 200, 300);
        return new Response(object.body, { headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "public, max-age=300", ETag: object.httpEtag, ...cors() } });
      }
      if (request.method === "PUT" && route[0] === "announcements.json" && route.length === 1) {
        if (!(await isOwner(request, env, now))) return json({ error: "not allowed" }, 401);
        const list = await request.json().catch(() => null);
        const problems = checkAnnouncements(list);
        if (problems.length) return json({ error: "announcements have problems", problems }, 400);
        // The admin page says which version it edited; a newer one (another tab, a script) isn't overwritten.
        const base = request.headers.get("X-Sommelier-Base");
        if (base != null && base !== ((await env.RELEASES.head("announcements.json"))?.httpEtag ?? "")) {
          return json({ error: "changed since you opened it" }, 409);
        }
        await publishList(env, "announcements.json", JSON.stringify(list));
        return json({ published: list.announcements.length });       // the page reloads the list for its new version
      }

      // Installs (src/installs.js). From every new install once, only the version: counted, nothing kept. From
      // installs that share how games run, once a day with the install's own random id: installed now, gone, back.
      if (request.method === "POST" && route[0] === "installs" && route.length === 1) {
        const version = appVersion(request.headers.get("User-Agent"));
        if (!version) return json({ error: "not Sommelier" }, 400);
        const text = await request.text();
        if (text.length > 256) return json({ error: "too large" }, 413);
        const id = parseJSON(text)?.id;
        if (id == null) {
          if (!(await allow(env.DB, `in:${await addressOf(request, env)}`, 5, now))) return json({ error: "too many" }, 429);
          await count(env.DB, now, "install", version, "app", country(request));
          return json({ result: "counted" }, 201);
        }
        if (typeof id !== "string" || !/^[0-9a-f-]{8,64}$/.test(id)) return json({ error: "bad id" }, 400);
        const key = await hash(env.SALT, `install:${id}`);
        // Sharing turned off, or "Delete my data": the install leaves the count instead of turning up as uninstalled.
        if (parseJSON(text)?.leave === true) {
          await env.DB.prepare("DELETE FROM installs WHERE id = ?").bind(key).run();
          return json({ result: "left" });
        }
        if (!(await allow(env.DB, `in:${key}`, 3, now))) return json({ error: "too many" }, 429);
        const result = await heard(env.DB, key, version, country(request), now);
        return json({ result }, 201);
      }
      // What the player's Sommelier uses, once a day, from installs that share how games run (src/usage.js).
      if (request.method === "POST" && route[0] === "usage" && route.length === 1) {
        if (!request.headers.get("X-Sommelier-Client")) return json({ error: "client header required" }, 400);
        const text = await request.text();
        if (text.length > 2048) return json({ error: "too large" }, 413);
        const { usage, error } = validateUsage(parseJSON(text));
        if (error) return json({ error }, 400);
        const player = await hash(env.SALT, `player:${usage.client}`);
        if (!(await allow(env.DB, `us:${player}`, 3, now))) return json({ error: "too many today" }, 429);
        await saveUsage(env.DB, player, usage, today(now));
        return json({ saved: true }, 201);
      }
      // A launch failure the player chose to send, with its scrubbed diagnostics.
      if (request.method === "POST" && route[0] === "failures" && route.length === 1) {
        if (!request.headers.get("X-Sommelier-Client")) return json({ error: "client header required" }, 400);
        const body = await request.text();
        if (body.length > MAX_FAILURE_BYTES) return json({ error: "too large" }, 413);
        const { failure, error } = validateFailure(parseJSON(body));
        if (error) return json({ error }, 400);
        const player = await hash(env.SALT, `player:${failure.client}`);
        const address = await addressOf(request, env);
        if (!(await allow(env.DB, `fa:${address}`, FAILURE_LIMITS.address, now)) || !(await allow(env.DB, `fp:${player}`, FAILURE_LIMITS.player, now))) {
          return json({ error: "too many reports today" }, 429);
        }
        const id = await saveFailure(env.DB, player, failure, now);
        return json({ saved: true, id }, 201);
      }
      // The owner's view of them.
      if (request.method === "GET" && route[0] === "failures" && route.length <= 2) {
        if (!(await isOwner(request, env, now))) return json({ error: "not allowed" }, 401);
        if (route.length === 2) {
          const detail = /^\d{1,12}$/.test(route[1]) ? await failureDetail(env.DB, Number(route[1])) : null;
          return detail ? json(detail) : json({ error: "not found" }, 404);
        }
        return json(await failureSummary(env.DB, now, clamp(Number(url.searchParams.get("days") ?? 30), 1, 180)));
      }

      // The owner's own answers for games tested on our Macs (bearer ADMIN_TOKEN).
      if (route[0] === "verdicts" && (route.length === 1 || route.length === 3)) {
        if (!(await isOwner(request, env, now))) return json({ error: "not allowed" }, 401);
        if (request.method === "GET" && route.length === 1) {
          return json({ verdicts: (await env.DB.prepare("SELECT store, id, steam_id AS steamAppID, verdict, updated_at AS updated FROM verdicts ORDER BY updated_at DESC").all()).results });
        }
        const [, store, id] = route;
        if (route.length !== 3 || !STORES.includes(store) || !ID.test(id)) return json({ error: "bad path" }, 400);
        if (request.method === "DELETE") {
          await env.DB.prepare("DELETE FROM verdicts WHERE store = ? AND id = ?").bind(store, id).run();
          return json({ deleted: true });
        }
        if (request.method === "PUT") {
          const body = parseJSON(await request.text());
          const verdict = body?.verdict;
          const steamAppID = body?.steamAppID == null ? null : String(body.steamAppID);
          if (!["works", "wontRun"].includes(verdict)) return json({ error: "verdict: works or wontRun" }, 400);
          if (steamAppID != null && !/^\d{1,10}$/.test(steamAppID)) return json({ error: "steamAppID" }, 400);
          await env.DB.prepare("INSERT OR REPLACE INTO verdicts (store, id, steam_id, verdict, updated_at) VALUES (?, ?, ?, ?, ?)")
            .bind(store, id, store === "steam" ? null : steamAppID, verdict, now).run();
          return json({ saved: true });
        }
      }

      // The owner's numbers: Authorization: Bearer <ADMIN_TOKEN>.
      if (request.method === "GET" && route[0] === "stats" && route.length === 1) {
        if (!(await isOwner(request, env, now))) return json({ error: "not allowed" }, 401);
        const days = clamp(Number(url.searchParams.get("days") ?? 30), 1, 365);
        return json(await summary(env.DB, now, days));
      }

      if (request.method === "GET" && route[0] === "games" && route[1] === "search" && route.length === 2) {
        const q = (url.searchParams.get("q") ?? "").slice(0, 100);
        const limit = clamp(Number(url.searchParams.get("limit") ?? 20), 1, 50);
        const gate = steamGate(env.DB, await addressOf(request, env), now);
        return json({ games: await search(env.DB, q, limit, now, ctx, undefined, gate) }, 200, 300);
      }

      if (request.method === "GET" && route[0] === "games" && route[1] === "top" && route.length === 2) {
        const limit = clamp(Number(url.searchParams.get("limit") ?? 50), 1, 100);
        return json({ games: await top(env.DB, limit) }, 200, 3600);
      }

      if (request.method === "GET" && route[0] === "games" && route.length === 3) {
        const [, store, id] = route;
        if (!STORES.includes(store) || !ID.test(id)) return json({ error: "bad path" }, 400);
        let game = await getGame(env.DB, store, id);
        if (store === "steam" && /^\d{1,10}$/.test(id) && !game?.details_at && (await steamGate(env.DB, await addressOf(request, env), now)())) {
          await enrich(env.DB, id, now);
          game = await getGame(env.DB, store, id);
        }
        const rows = await reportsFor(env.DB, store, id);
        if (!game || game.type === "missing") {
          if (!rows.length) return json({ error: "unknown game" }, 404);
          game = { store, id, title: "", cover: null, header: null };             // known only from reports
        }
        return json(gameView(game, await antiCheatFor(env.DB, game), rows, await verdictFor(env.DB, store, id)), 200, 300);
      }

      // "Delete my data" from the app's settings: everything sent from this install.
      if (request.method === "POST" && route[0] === "forget" && route.length === 1) {
        const text = await request.text();
        if (text.length > 1024) return json({ error: "too large" }, 413);
        const { client, error } = validateForget(parseJSON(text));
        if (error) return json({ error }, 400);
        if (!(await allow(env.DB, `fg:${await addressOf(request, env)}`, 20, now))) return json({ error: "too many requests today" }, 429);
        return json({ deleted: await forget(env.DB, env.SALT, client) });
      }

      if (request.method === "POST" && route[0] === "reports" && route.length === 1) {
        if (!request.headers.get("X-Sommelier-Client")) return json({ error: "client header required" }, 400);
        const text = await request.text();
        if (text.length > 16384) return json({ error: "too large" }, 413);
        const { report, error } = validateReport(parseJSON(text));
        if (error) return json({ error }, 400);
        const player = await hash(env.SALT, `player:${report.client}`);
        const address = await addressOf(request, env);
        if (!(await allow(env.DB, `a:${address}`, LIMITS.address, now)) || !(await allow(env.DB, `p:${player}`, LIMITS.player, now))) {
          return json({ error: "too many reports today" }, 429);
        }
        await saveReport(env.DB, player, report, now, address);
        return json({ saved: true }, 201);
      }

      return json({ error: "not found" }, 404);
    } catch (e) {
      console.error(e);
      return json({ error: "server error" }, 500);
    }
  },

  /** Daily: the anti-cheat list, Steam's most played, and details that are missing or old. */
  async scheduled(event, env, ctx) {
    const now = Date.now();
    if (event.cron === BACKUP_CRON) { ctx.waitUntil(backupDatabase(env, now).catch((e) => console.error("backup", e))); return; }
    ctx.waitUntil((async () => {
      await refreshAntiCheat(env.DB, now).catch((e) => console.error("anti-cheat", e));
      await refreshMostPlayed(env.DB, now).catch((e) => console.error("most played", e));
      await refreshStale(env.DB, now).catch((e) => console.error("details", e));
      await pruneFailures(env.DB, now).catch((e) => console.error("failures", e));
      await prune(env.DB, now).catch((e) => console.error("prune", e));
      await watchToolkit(env, now).catch((e) => console.error("toolkit watch", e));
      // Session reports are kept a year (stated in the privacy policy); a player's newer report replaces the old.
      await env.DB.prepare("DELETE FROM reports WHERE created_at < ?").bind(now - 365 * 86_400_000).run()
        .catch((e) => console.error("reports", e));
    })());
  },
};

/** The owner's token; an address that keeps guessing wrong is shut out for the day. */
async function isOwner(request, env, now) {
  const address = await addressOf(request, env);
  if (await over(env.DB, `ow:${address}`, OWNER_FAILURES, now)) return false;
  if (sameToken((request.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, ""), env.ADMIN_TOKEN)) return true;
  await allow(env.DB, `ow:${address}`, OWNER_FAILURES, now);
  return false;
}

const addressOf = (request, env) => hash(env.SALT, `address:${request.headers.get("CF-Connecting-IP") ?? "local"}`);

async function release(env, key, contentType, maxAge) {
  const object = await env.RELEASES.get(key);
  if (!object) return json({ error: "not found" }, 404);
  return new Response(object.body, {
    headers: { "Content-Type": contentType, "Content-Length": String(object.size), "Cache-Control": `public, max-age=${maxAge}`, ETag: object.httpEtag, ...cors() },
  });
}

async function saveReport(db, player, r, now, address) {
  await db.prepare(
    `INSERT OR REPLACE INTO reports (client, store, game_id, steam_id, title, outcome, minutes, fps_avg, fps_low, resolution,
       chip, gpu_cores, ram_gb, macos, app_version, engine, backend, created_at, backend_choice, settings, hdr, address, mods)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`)
    .bind(player, r.store, r.gameId, r.steamId, r.title, r.outcome, r.minutes, r.fpsAvg, r.fpsLow, r.resolution,
      r.chip, r.gpuCores, r.ramGB, r.macOS, r.app, r.engine, r.backend, now, r.backendChoice, r.settings, r.hdr, address ?? null, r.mods)
    .run();
}

/** Mondays 03:30 UTC: the database's tables as JSON in `backups/<date>/` of the releases bucket. */
const BACKUP_CRON = "30 3 * * 1";
// What is worth a copy: players' reports and failures, the owner's verdicts, the HDR list and the catalogue. The
// flood counters (limits) and caches (steam_queries) aren't.
const BACKUP_TABLES = ["reports", "failures", "verdicts", "hdr_games", "games", "anticheat", "counts", "meta"];
const BACKUPS_KEPT = 8;
const BACKUP_PAGE = 2000;

/** Copies every table, a page of rows at a time (a free Worker's time per run is short), then drops old copies. */
export async function backupDatabase(env, now) {
  const day = new Date(now).toISOString().slice(0, 10);
  for (const table of BACKUP_TABLES) {
    for (let offset = 0, page = 0; ; offset += BACKUP_PAGE, page += 1) {
      const { results } = await env.DB.prepare(`SELECT * FROM ${table} LIMIT ? OFFSET ?`).bind(BACKUP_PAGE, offset).all();
      if (!results.length && page > 0) break;
      await env.RELEASES.put(`backups/${day}/${table}-${String(page).padStart(4, "0")}.json`, JSON.stringify(results),
        { httpMetadata: { contentType: "application/json" } });
      if (results.length < BACKUP_PAGE) break;
    }
  }
  const days = [...new Set((await env.RELEASES.list({ prefix: "backups/" })).objects.map((o) => o.key.split("/")[1]))].sort();
  for (const old of days.slice(0, Math.max(0, days.length - BACKUPS_KEPT))) {
    const keys = (await env.RELEASES.list({ prefix: `backups/${old}/` })).objects.map((o) => o.key);
    if (keys.length) await env.RELEASES.delete(keys);
  }
  return day;
}

/** The lists the owner publishes whole, each kept with its earlier versions in `history/<name>/`. */
const LISTS = ["fixes.json", "recipes.json", "announcements.json", "saves.json", "mods.json"];
const HISTORY_KEPT = 20;

/** A browser the owner marked with /v1/internal: what it downloads isn't counted. */
function isInternal(request) {
  return /(?:^|;\s*)internal=1(?:;|$)/.test(request.headers.get("Cookie") ?? "");
}

/** Publishes a list, first copying the one it replaces into its history (the newest HISTORY_KEPT are kept).
 *  A signed list keeps its signature with it, in its history too, so a rollback hands apps a list they take. */
export async function publishList(env, name, text, signature = null) {
  const current = await env.RELEASES.get(name);
  if (current) {
    const stamp = new Date().toISOString().replace(/[:.]/g, "-");
    await env.RELEASES.put(`history/${name}/${stamp}.json`, await current.arrayBuffer?.() ?? await current.text(),
      { httpMetadata: { contentType: "application/json" }, customMetadata: current.customMetadata ?? {} });
    const kept = (await env.RELEASES.list({ prefix: `history/${name}/` })).objects.map((o) => o.key).sort();
    if (kept.length > HISTORY_KEPT) await env.RELEASES.delete(kept.slice(0, kept.length - HISTORY_KEPT));
  }
  await env.RELEASES.put(name, text, { httpMetadata: { contentType: "application/json" }, customMetadata: signature ? { signature } : {} });
}

/** The signature a stored list or pack carries, as the response header apps read. */
function signatureHeaders(object) {
  const signature = object?.customMetadata?.signature;
  return signature ? { [SIGNATURE_HEADER]: signature } : {};
}

/** Puts the newest earlier version back (and drops it from the history); its key, or null when there is none. */
export async function rollbackList(env, name) {
  const kept = (await env.RELEASES.list({ prefix: `history/${name}/` })).objects.map((o) => o.key).sort();
  const last = kept.at(-1);
  if (!last) return null;
  const object = await env.RELEASES.get(last);
  await env.RELEASES.put(name, await object.arrayBuffer?.() ?? await object.text(),
    { httpMetadata: { contentType: "application/json" }, customMetadata: object.customMetadata ?? {} });
  await env.RELEASES.delete(last);
  return last;
}

/** Deployed (production or staging) with a missing or development SALT or ADMIN_TOKEN. */
export function unsafeSecrets(env) {
  if (!env.ENVIRONMENT) return false;                                   // local development
  return [env.SALT, env.ADMIN_TOKEN].some((v) => !v || String(v).startsWith("dev-only") || String(v).length < 24);
}

// Other sites may only read and send reports; publishing (PUT) and deleting are for the owner's scripts and the
// admin page, which is served from this same origin.
function cors() {
  return { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Methods": "GET, POST, OPTIONS", "Access-Control-Allow-Headers": "Content-Type, X-Sommelier-Client",
    "Access-Control-Expose-Headers": SIGNATURE_HEADER };
}

function json(body, status = 200, maxAge = 0) {
  const headers = { "Content-Type": "application/json; charset=utf-8", "X-Content-Type-Options": "nosniff", ...cors() };
  if (maxAge && status === 200) headers["Cache-Control"] = `public, max-age=${maxAge}`;
  return new Response(JSON.stringify(body), { status, headers });
}

function parseJSON(text) {
  try { return JSON.parse(text || "null"); } catch { return null; }
}

const clamp = (n, lo, hi) => (Number.isFinite(n) ? Math.min(Math.max(Math.trunc(n), lo), hi) : lo);

export default app;
