// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import { test } from "node:test";
import assert from "node:assert/strict";
import worker from "../src/index.js";
import { encode } from "../src/pack.js";

/** An R2 stand-in in memory: get, put, list by prefix, delete. */
function bucket() {
  const store = new Map();
  let clock = 0;
  return {
    store,
    async get(key) {
      const v = store.get(key); if (!v) return null;
      const bytes = Buffer.from(v.bytes);
      return { body: bytes, httpEtag: "x", arrayBuffer: async () => bytes, text: async () => bytes.toString(), json: async () => JSON.parse(bytes.toString()) };
    },
    async put(key, value) { store.set(key, { bytes: Buffer.from(typeof value === "string" ? value : value), uploaded: ++clock }); },
    async list({ prefix }) {
      return { objects: [...store.entries()].filter(([k]) => k.startsWith(prefix)).map(([key, v]) => ({ key, uploaded: v.uploaded })), truncated: false };
    },
    async delete(keys) { for (const k of [].concat(keys)) store.delete(k); },
  };
}

const lib = (seed) => Buffer.concat([Buffer.from("MTLB"), Buffer.alloc(300, seed)]);
const hex = (n) => Buffer.alloc(40, n).toString("hex");
const pack = (entries) => encode({ kind: 1, metalVersion: 320, tableVersion: 18, entries: new Map(entries) });
const path = "https://d.test/v1/pack/steam/1/game.exe/shaders/320/18";

function put(env, body, ip) {
  return worker.fetch(new Request(path, { method: "PUT", body, headers: { "X-Sommelier-Client": "a", "CF-Connecting-IP": ip, "Content-Length": String(body.length) } }), env);
}

test("players' uploads only wait; the merge keeps what two addresses agree on", async () => {
  const env = { PACKS: bucket(), SALT: "s", ADMIN_TOKEN: "t" };
  const r = await (await put(env, pack([[hex(1), lib(1)]]), "1.1.1.1")).json();
  assert.equal(r.added, 0);
  assert.equal((await worker.fetch(new Request(path, { headers: { "X-Sommelier-Client": "a" } }), env)).status, 404);   // nothing shared yet
  const { agreed } = await import("../merge.mjs");
  const { decode } = await import("../src/pack.js");
  const uploads = new Map([["a", decode(pack([[hex(1), lib(1)], [hex(2), lib(2)]]))], ["b", decode(pack([[hex(1), lib(1)], [hex(2), lib(9)]]))]]);
  const yes = agreed(uploads);
  assert.deepEqual([...yes.entries.keys()], [hex(1)]);                    // hex(2) differs in bytes
  assert.equal(agreed(new Map([["a", uploads.get("a")]])).entries.size, 0);
});

test("uploads are limited per address, and the owner can clear a game", async () => {
  const env = { PACKS: bucket(), SALT: "s", ADMIN_TOKEN: "t" };
  for (let i = 0; i < 30; i++) assert.equal((await put(env, pack([[hex(1), lib(1)]]), "3.3.3.3")).status, 200);
  assert.equal((await put(env, pack([[hex(1), lib(1)]]), "3.3.3.3")).status, 429);
  const del = (token) => worker.fetch(new Request("https://d.test/v1/pack/steam/1", { method: "DELETE", headers: { "X-Sommelier-Client": "a", Authorization: `Bearer ${token}` } }), env);
  assert.equal((await del("wrong")).status, 401);
  assert.equal((await del("t")).status, 200);
  assert.equal([...env.PACKS.store.keys()].filter((k) => k.startsWith("incoming/")).length, 0);
});
