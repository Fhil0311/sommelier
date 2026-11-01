// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
// Decanter: Sommelier's shader sharing service. Players who opt in send the Direct3D-to-Metal shader translations
// DXMT made while they played; the service merges them per game and hands the merged pack to the next player
// before the game's first run. Nothing personal is in a pack: shader hashes and compiled Metal libraries only.
//
// Routes (all under /v1):
//   GET  /v1/pack/{store}/{game}                                   → manifest: the packs held for the game
//   GET  /v1/pack/{store}/{game}/{exe}/{kind}/{metal}/{table}      → the merged pack (binary, see pack.js)
//   PUT  /v1/pack/{store}/{game}/{exe}/{kind}/{metal}/{table}      → merge a player's pack in; body is a pack
// {kind} is "shaders" (DXMT's translated shaders) or "pipelines" (the pipelines it built, for the warm-up).
//   GET  /v1/cellar/{store}/{game}                                 → manifest: the archives held for the game
//   GET  /v1/cellar/{store}/{game}/{exe}/{os}/{arch}               → a binary archive (see cellar.js)
//   PUT  /v1/cellar/{store}/{game}/{exe}/{os}/{arch}               → the builder stores one (bearer token)
// Storage: one R2 object per pack or archive at the same path; a manifest object per game for each.
import { stagingGate, withStagingCookie } from "./staging.js";
import { SIGNATURE_HEADER, signedByOwner } from "./signature.js";
import { createHash } from "node:crypto";
import { decode, KINDS, HEADER_SIZE } from "./pack.js";
import { OS, ARCH, MAX_ARCHIVE, archiveKey, manifestKey, withArchive, mayUpload } from "./cellar.js";

const MAX_UPLOAD = 32 * 1024 * 1024;
const MAX_ENTRIES = 50_000;
// Players' uploads wait in `incoming/<pack>/<address>` (one per address, the latest). The owner's merge script
// (scripts/merge-shaders.sh, on a Mac: the work doesn't fit a free Worker's CPU time) puts an entry in the pack
// everyone downloads only when that same entry (same key, same bytes) came from 2 different addresses, so one
// address alone can't put a bad shader in front of every player of a game. Waiting uploads go after 60 days.
const UPLOADS_PER_DAY = 30;          // per address
const SEGMENT = /^[A-Za-z0-9][A-Za-z0-9._ -]{0,127}$/;

const app = {
  async fetch(request, env, ctx) {
    const closed = stagingGate(request, env);
    if (closed) return closed;
    return withStagingCookie(request, env, await app.handle(request, env, ctx));
  },

  async handle(request, env) {
    const url = new URL(request.url);
    const parts = url.pathname.split("/").filter(Boolean);
    if (env.ENVIRONMENT && [env.SALT, env.ADMIN_TOKEN].some((v) => !v || String(v).startsWith("dev-only") || String(v).length < 24)) {
      return json({ error: "service not configured" }, 503);       // deployed with the development secrets
    }
    // For the merge script: the uploads waiting, GET /v1/incoming[?cursor=…] (keys), GET /v1/incoming/<key> (one).
    if (parts[0] === "v1" && parts[1] === "incoming") {
      if (!isAdmin(request, env)) return json({ error: "not allowed" }, 401);
      if (parts.length === 2) {
        const page = await env.PACKS.list({ prefix: "incoming/", cursor: url.searchParams.get("cursor") ?? undefined });
        return json({ keys: page.objects.map((o) => o.key), cursor: page.truncated ? page.cursor : null });
      }
      const object = await env.PACKS.get(parts.slice(1).join("/"));
      return object ? new Response(object.body, { headers: { "Content-Type": "application/octet-stream" } }) : json({ error: "gone" }, 404);
    }
    // For the admin page: the published packs per game, and how many uploads wait for agreement.
    if (parts[0] === "v1" && parts[1] === "packs" && parts.length === 2 && request.method === "GET") {
      if (!isAdmin(request, env)) return json({ error: "not allowed" }, 401);
      return json(await packsSummary(env));
    }
    if (parts[0] !== "v1" || (parts[1] !== "pack" && parts[1] !== "cellar")) return json({ error: "not found" }, 404);
    if (request.headers.get("X-Sommelier-Client") == null) return json({ error: "client header required" }, 400);
    if (parts[1] === "cellar") return cellar(request, env, parts.slice(2));
    const [store, game, exe, kindName, metal, table] = parts.slice(2);
    if (!SEGMENT.test(store ?? "") || !SEGMENT.test(game ?? "")) return json({ error: "bad path" }, 400);

    if (parts.length === 4 && request.method === "GET") return manifest(env, store, game);
    // The owner clears a game's packs (a bad shader got through): DELETE /v1/pack/{store}/{game} with the admin token.
    if (parts.length === 4 && request.method === "DELETE") {
      if (!isAdmin(request, env)) return json({ error: "not allowed" }, 401);
      return json({ deleted: await purge(env, store, game) });
    }
    const kind = Number(Object.keys(KINDS).find((k) => KINDS[k] === kindName));
    if (parts.length !== 8 || !SEGMENT.test(exe) || !kind || !/^\d{1,6}$/.test(metal) || !/^\d{1,6}$/.test(table)) return json({ error: "bad path" }, 400);
    const key = `pack/${store}/${game}/${exe}/${kindName}/${metal}/${table}`;

    if (request.method === "GET") {
      const object = await env.PACKS.get(key);
      if (!object) return json({ error: "no pack yet" }, 404);
      return new Response(object.body, { headers: { "Content-Type": "application/octet-stream", "Cache-Control": "public, max-age=3600", ETag: object.httpEtag,
        ...signatureHeaders(object) } });
    }
    if (request.method === "PUT") {
      // The owner's merge script publishes the agreed pack (scripts/merge-shaders.sh).
      if (isAdmin(request, env)) return publishPack(request, env, key, { store, game, exe, kindName, metal, table });
      // A player's upload only waits here, one per address (the latest); nothing reaches other players until the
      // merge script finds the same entries from QUORUM different addresses. Kept cheap: no unpacking here.
      const length = Number(request.headers.get("Content-Length") ?? 0);
      if (!length || length > MAX_UPLOAD) return json({ error: "too large" }, 413);
      const address = await addressOf(request, env);
      if (!(await allowUpload(env, address))) return json({ error: "too many uploads today" }, 429);
      const body = await request.arrayBuffer();
      if (body.byteLength > MAX_UPLOAD || !looksLikePack(body, kind, metal, table)) return json({ error: "not a pack" }, 400);
      await env.PACKS.put(`incoming/${key}/${address}`, body, { httpMetadata: { contentType: "application/octet-stream" } });
      return json({ received: true, added: 0 });        // 200 with "added": what the app expects
    }
    return json({ error: "method not allowed" }, 405);
  },
};

async function cellar(request, env, [store, game, exe, os, arch]) {
  if (!SEGMENT.test(store ?? "") || !SEGMENT.test(game ?? "")) return json({ error: "bad path" }, 400);
  if (exe === undefined) {
    if (request.method !== "GET") return json({ error: "method not allowed" }, 405);
    const object = await env.PACKS.get(manifestKey(store, game));
    if (!object) return json({ archives: [] }, 200, { "Cache-Control": "public, max-age=300" });
    return new Response(object.body, { headers: { "Content-Type": "application/json", "Cache-Control": "public, max-age=300" } });
  }
  if (!SEGMENT.test(exe) || !OS.test(os ?? "") || !ARCH.test(arch ?? "")) return json({ error: "bad path" }, 400);
  const key = archiveKey(store, game, exe, os, arch);
  if (request.method === "GET") {
    const object = await env.PACKS.get(key);
    if (!object) return json({ error: "no archive yet" }, 404);
    return new Response(object.body, { headers: { "Content-Type": "application/octet-stream", "Cache-Control": "public, max-age=3600", ETag: object.httpEtag,
      ...signatureHeaders(object) } });
  }
  if (request.method === "PUT") {
    if (!mayUpload(request, env)) return json({ error: "builder only" }, 403);
    const length = Number(request.headers.get("Content-Length") ?? 0);
    if (length > MAX_ARCHIVE) return json({ error: "too large" }, 413);
    const pipelines = Number(request.headers.get("X-Sommelier-Pipelines") ?? 0);
    const body = await request.arrayBuffer();
    if (body.byteLength < 64) return json({ error: "not an archive" }, 400);
    const signature = request.headers.get(SIGNATURE_HEADER);
    if (!(await signedByOwner(env, new Uint8Array(body), signature))) return json({ error: "needs the owner's signature" }, 400);
    await env.PACKS.put(key, body, { httpMetadata: { contentType: "application/octet-stream" }, customMetadata: signature ? { signature } : {} });
    const current = await env.PACKS.get(manifestKey(store, game));
    const manifest = withArchive(current ? await current.json() : null, { exe, os, arch, pipelines, bytes: body.byteLength });
    await env.PACKS.put(manifestKey(store, game), JSON.stringify(manifest), { httpMetadata: { contentType: "application/json" } });
    return json({ stored: body.byteLength });
  }
  return json({ error: "method not allowed" }, 405);
}

/** The header of a pack of this kind and versions (the rest is checked by the merge script). */
function looksLikePack(body, kind, metal, table) {
  const data = Buffer.from(body);
  return data.length >= HEADER_SIZE && data.subarray(0, 4).toString("latin1") === "SMLR" && data[5] === kind
    && String(data.readUInt32LE(6)) === metal && String(data.readUInt32LE(10)) === table && data.readUInt32LE(14) > 0
    && data.readUInt32LE(14) <= MAX_ENTRIES;
}

/** Stores the pack the merge script agreed on, and its manifest line. */
async function publishPack(request, env, key, { store, game, exe, kindName, metal, table }) {
  const body = await request.arrayBuffer();
  const pack = decode(body);
  if (!pack || pack.entries.size === 0) return json({ error: "not a pack" }, 400);
  const signature = request.headers.get(SIGNATURE_HEADER);
  if (!(await signedByOwner(env, new Uint8Array(body), signature))) return json({ error: "needs the owner's signature (scripts/merge-shaders.sh signs it)" }, 400);
  await env.PACKS.put(key, body, { httpMetadata: { contentType: "application/octet-stream" }, customMetadata: signature ? { signature } : {} });
  await updateManifest(env, store, game, { exe, kind: kindName, metal: Number(metal), table: Number(table), count: pack.entries.size });
  return json({ stored: pack.entries.size });
}

/** A salted hash of the uploader's address (the raw address is never stored). */
async function addressOf(request, env) {
  const ip = request.headers.get("CF-Connecting-IP") ?? "local";
  return createHash("sha256").update(`${env.SALT ?? "dev-only-salt"}:address:${ip}`).digest("hex").slice(0, 32);
}

/** At most UPLOADS_PER_DAY uploads a day from one address (a counter object per day, deleted by R2's lifecycle). */
async function allowUpload(env, address) {
  const key = `limits/${new Date().toISOString().slice(0, 10)}/${address}`;
  const current = await env.PACKS.get(key);
  const count = current ? Number(await current.text()) || 0 : 0;
  if (count >= UPLOADS_PER_DAY) return false;
  await env.PACKS.put(key, String(count + 1));
  return true;
}

function isAdmin(request, env) {
  const token = env.ADMIN_TOKEN;
  return Boolean(token) && request.headers.get("Authorization") === `Bearer ${token}`;
}

/** Deletes a game's packs, the uploads waiting for agreement, and its manifest. */
async function purge(env, store, game) {
  let deleted = 0;
  for (const prefix of [`pack/${store}/${game}/`, `incoming/pack/${store}/${game}/`]) {
    let cursor;
    do {
      const page = await env.PACKS.list({ prefix, cursor });
      if (page.objects.length) { await env.PACKS.delete(page.objects.map((o) => o.key)); deleted += page.objects.length; }
      cursor = page.truncated ? page.cursor : undefined;
    } while (cursor);
  }
  await env.PACKS.delete(`manifest/${store}/${game}`);
  return deleted;
}

async function manifest(env, store, game) {
  const object = await env.PACKS.get(`manifest/${store}/${game}`);
  if (!object) return json({ packs: [] }, 200, { "Cache-Control": "public, max-age=300" });
  return new Response(object.body, { headers: { "Content-Type": "application/json", "Cache-Control": "public, max-age=300" } });
}

async function updateManifest(env, store, game, entry) {
  const key = `manifest/${store}/${game}`;
  const current = await env.PACKS.get(key);
  const data = current ? await current.json() : { packs: [] };
  const packs = data.packs.filter((p) => !(p.exe === entry.exe && p.kind === entry.kind && p.metal === entry.metal && p.table === entry.table));
  packs.push({ ...entry, updated: new Date().toISOString() });
  await env.PACKS.put(key, JSON.stringify({ packs }), { httpMetadata: { contentType: "application/json" } });
}

function json(body, status = 200, headers = {}) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json", ...headers } });
}

/** Per game (store/game): packs published, their bytes, the newest; and uploads waiting, from how many addresses. */
export async function packsSummary(env) {
  const games = new Map();
  const at = (store, game) => games.get(`${store}/${game}`) ?? games.set(`${store}/${game}`,
    { store, game, packs: 0, bytes: 0, updated: null, waiting: 0, addresses: new Set() }).get(`${store}/${game}`);
  for (const prefix of ["pack/", "incoming/pack/"]) {
    let cursor;
    do {
      const page = await env.PACKS.list({ prefix, cursor });
      for (const o of page.objects) {
        const p = o.key.split("/");
        if (prefix === "pack/") {
          if (p.length !== 7) continue;
          const g = at(p[1], p[2]); g.packs += 1; g.bytes += o.size;
          const when = new Date(o.uploaded).toISOString();
          if (!g.updated || when > g.updated) g.updated = when;
        } else {
          if (p.length !== 9) continue;
          const g = at(p[2], p[3]); g.waiting += 1; g.addresses.add(p[8]);
        }
      }
      cursor = page.truncated ? page.cursor : undefined;
    } while (cursor);
  }
  return { games: [...games.values()].map(({ addresses, ...g }) => ({ ...g, addresses: addresses.size }))
    .sort((a, b) => b.packs - a.packs || b.waiting - a.waiting) };
}

/** The signature a stored pack or archive carries, as the response header apps read. */
function signatureHeaders(object) {
  const signature = object?.customMetadata?.signature;
  return signature ? { [SIGNATURE_HEADER]: signature } : {};
}

export default app;
