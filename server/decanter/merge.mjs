// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
// The shader merge, run on the owner's Mac (scripts/merge-shaders.sh): the work of unpacking and comparing players'
// uploads doesn't fit a free Worker's CPU time, so the service only stores them and this does the rest.
//
// For every pack with uploads waiting: an entry joins the pack everyone downloads when the same entry (same key,
// same bytes) came from QUORUM different addresses; what the pack already has stays. Then the pack goes back up.
//
//   DECANTER_URL=https://decanter.playsommelier.com ADMIN_TOKEN=… node merge.mjs
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

/** The update key's signature of a pack (scripts/sign.sh): apps take only packs the owner signed. */
function sign(body) {
  const dir = mkdtempSync(join(tmpdir(), "sommelier-pack-"));
  try {
    const file = join(dir, "pack.bin");
    writeFileSync(file, body);
    return execFileSync(new URL("../../scripts/sign.sh", import.meta.url).pathname, [file], { encoding: "utf8" }).trim();
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}
import { decode, encode, merge } from "./src/pack.js";

export const QUORUM = 2;

/** The entries of the uploads (Map address → pack) that QUORUM addresses sent with the same bytes. */
export function agreed(uploads, quorum = QUORUM) {
  const votes = new Map();                       // "<key>:<sha>" → { value, addresses }
  let sample = null;
  for (const [address, pack] of uploads) {
    sample ??= pack;
    for (const [hex, value] of pack.entries) {
      const vote = `${hex}:${createHash("sha256").update(value).digest("hex")}`;
      const entry = votes.get(vote) ?? votes.set(vote, { hex, value, addresses: new Set() }).get(vote);
      entry.addresses.add(address);
    }
  }
  const entries = new Map();
  for (const { hex, value, addresses } of votes.values()) if (addresses.size >= quorum) entries.set(hex, value);
  return sample ? { kind: sample.kind, metalVersion: sample.metalVersion, tableVersion: sample.tableVersion, entries } : null;
}

async function main() {
  const base = process.env.DECANTER_URL ?? "http://127.0.0.1:8789";
  const token = process.env.ADMIN_TOKEN ?? "dev-only-admin";
  const headers = { Authorization: `Bearer ${token}`, "X-Sommelier-Client": "merge",
                    ...(process.env.STAGING_KEY ? { "X-Sommelier-Staging-Key": process.env.STAGING_KEY } : {}) };
  const get = async (path) => {
    const r = await fetch(`${base}${path}`, { headers });
    if (!r.ok) throw new Error(`${path}: ${r.status}`);
    return r;
  };

  // Every waiting upload, grouped by the pack it is for: incoming/pack/<store>/<game>/<exe>/<kind>/<metal>/<table>/<address>.
  const groups = new Map();
  let cursor = null;
  do {
    const page = await (await get(`/v1/incoming${cursor ? `?cursor=${encodeURIComponent(cursor)}` : ""}`)).json();
    for (const key of page.keys) {
      const cut = key.lastIndexOf("/");
      const pack = key.slice("incoming/".length, cut);
      (groups.get(pack) ?? groups.set(pack, []).get(pack)).push(key);
    }
    cursor = page.cursor;
  } while (cursor);

  let added = 0, packs = 0;
  for (const [pack, keys] of groups) {
    if (new Set(keys.map((k) => k.slice(k.lastIndexOf("/") + 1))).size < QUORUM) continue;   // one address: nothing can agree
    const uploads = new Map();
    for (const key of keys) {
      const decoded = decode(Buffer.from(await (await get(`/v1/${key}`)).arrayBuffer()));
      if (decoded) uploads.set(key.slice(key.lastIndexOf("/") + 1), decoded);
    }
    const yes = agreed(uploads);
    if (!yes || yes.entries.size === 0) continue;
    const current = await fetch(`${base}/v1/${pack}`, { headers });
    const existing = current.ok ? decode(Buffer.from(await current.arrayBuffer())) : null;
    const merged = existing ? merge(existing, yes) : yes;
    const grown = merged.entries.size - (existing?.entries.size ?? 0);
    if (grown <= 0) continue;
    const body = encode(merged);
    const put = await fetch(`${base}/v1/${pack}`, { method: "PUT", headers: { ...headers, "Content-Length": String(body.length),
      "X-Sommelier-Signature": sign(body) }, body });
    if (!put.ok) { console.error(`${pack}: ${put.status}`); continue; }
    added += grown; packs += 1;
    console.log(`${pack}: +${grown} (now ${merged.entries.size})`);
  }
  console.log(`${groups.size} packs with uploads waiting, ${packs} grew, ${added} shaders added`);
}

if (import.meta.url === `file://${process.argv[1]}`) main().catch((e) => { console.error(e.message); process.exit(1); });
