// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
/** Staging answers only those who know its key (header X-Sommelier-Staging-Key, or a browser that opened a page once
 *  with ?staging_key=… and got the cookie); production and local development don't ask. */
export function stagingGate(request, env) {
  if (env.ENVIRONMENT !== "staging") return null;
  const key = String(env.STAGING_KEY ?? "");
  if (key.length < 24) return new Response("staging not configured", { status: 503 });
  const url = new URL(request.url);
  const cookie = /(?:^|;\s*)sommelier_staging=([^;]+)/.exec(request.headers.get("Cookie") ?? "")?.[1];
  const given = request.headers.get("X-Sommelier-Staging-Key") ?? url.searchParams.get("staging_key") ?? cookie ?? "";
  if (!sameString(given, key)) return new Response("not allowed", { status: 403 });
  return null;
}

/** Sets the staging cookie on a response to a request that came with ?staging_key=…. */
export function withStagingCookie(request, env, response) {
  if (env.ENVIRONMENT !== "staging" || !new URL(request.url).searchParams.has("staging_key")) return response;
  const copy = new Response(response.body, response);
  copy.headers.append("Set-Cookie", `sommelier_staging=${env.STAGING_KEY}; Path=/; Secure; HttpOnly; SameSite=Strict; Max-Age=2592000`);
  return copy;
}

function sameString(a, b) {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}
