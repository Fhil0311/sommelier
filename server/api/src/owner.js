// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
// What the admin page needs beyond the numbers: the service's state, and the shader service's packs (reached
// through a service binding, so the page stays on one origin and the shader service needs no CORS for the owner).

import { DEFAULT_TOOLKIT } from "./toolkit.js";

/** The lists, the last backup, which secrets are set: GET /v1/admin/status. */
export async function status(env, lists) {
  const out = { environment: env.ENVIRONMENT ?? "development", lists: [], backup: null, secrets: {}, rows: {} };
  for (const name of lists) {
    const head = await env.RELEASES.head(name);
    const history = (await env.RELEASES.list({ prefix: `history/${name}/` })).objects.length;
    out.lists.push({ name, published: head ? head.uploaded.toISOString?.() ?? String(head.uploaded) : null, bytes: head?.size ?? 0, history });
  }
  const days = [...new Set((await env.RELEASES.list({ prefix: "backups/" })).objects.map((o) => o.key.split("/")[1]))].sort();
  out.backup = days.at(-1) ?? null;
  out.backups = days.length;
  const real = (v) => Boolean(v) && !String(v).startsWith("dev-only") && String(v).length >= 24;
  out.secrets = { SALT: real(env.SALT), ADMIN_TOKEN: real(env.ADMIN_TOKEN) };
  if (env.ENVIRONMENT === "staging") out.secrets.STAGING_KEY = real(env.STAGING_KEY);
  out.decanter = Boolean(env.DECANTER);
  out.toolkit = {
    ...{ ...DEFAULT_TOOLKIT, ...((await (await env.RELEASES.get("toolkit.json"))?.json().catch(() => null)) ?? {}) },
    watch: await (await env.RELEASES.get("watch/toolkit.json"))?.json().catch(() => null),
  };
  for (const table of ["reports", "failures", "verdicts", "games"]) {
    out.rows[table] = (await env.DB.prepare(`SELECT COUNT(*) AS n FROM ${table}`).first())?.n ?? 0;
  }
  return out;
}

/** /v1/admin/shaders[/…] → the shader service's owner routes, with the owner's token and staging key passed on. */
export async function shaders(request, env, rest) {
  if (!env.DECANTER) return new Response(JSON.stringify({ error: "shader service not connected" }), { status: 503, headers: { "Content-Type": "application/json" } });
  let path;
  if (request.method === "GET" && rest.length === 0) path = "/v1/packs";
  else if (request.method === "DELETE" && rest.length === 2) path = `/v1/pack/${encodeURIComponent(rest[0])}/${encodeURIComponent(rest[1])}`;
  else return new Response(JSON.stringify({ error: "not found" }), { status: 404, headers: { "Content-Type": "application/json" } });
  const headers = { Authorization: request.headers.get("Authorization") ?? "", "X-Sommelier-Client": "admin" };
  if (env.STAGING_KEY) headers["X-Sommelier-Staging-Key"] = env.STAGING_KEY;
  return env.DECANTER.fetch(new Request(`https://decanter${path}`, { method: request.method, headers }));
}
