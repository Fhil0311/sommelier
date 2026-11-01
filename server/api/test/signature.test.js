// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import { test } from "node:test";
import assert from "node:assert/strict";
import { signedByOwner } from "../src/signature.js";
import { publishList, rollbackList } from "../src/index.js";

const b64 = (bytes) => Buffer.from(bytes).toString("base64");

async function owner() {
  const keys = await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"]);
  const raw = new Uint8Array(await crypto.subtle.exportKey("raw", keys.publicKey));
  return { publicKey: b64(raw), sign: async (bytes) => b64(new Uint8Array(await crypto.subtle.sign({ name: "Ed25519" }, keys.privateKey, bytes))) };
}

test("only the owner's signature of exactly these bytes", async () => {
  const me = await owner(), other = await owner();
  const env = { ENVIRONMENT: "production", LIST_PUBLIC_KEY: me.publicKey };
  const bytes = new TextEncoder().encode('{"version":1,"rules":[]}');
  assert.equal(await signedByOwner(env, bytes, await me.sign(bytes)), true);
  assert.equal(await signedByOwner(env, bytes, await other.sign(bytes)), false);
  assert.equal(await signedByOwner(env, new TextEncoder().encode('{"version":1,"rules":[1]}'), await me.sign(bytes)), false);
  assert.equal(await signedByOwner(env, bytes, null), false);
  assert.equal(await signedByOwner(env, bytes, "not base64!"), false);
});

test("deployed without a key takes nothing; local development takes anything", async () => {
  const bytes = new Uint8Array([1, 2, 3]);
  assert.equal(await signedByOwner({ ENVIRONMENT: "staging" }, bytes, "x"), false);
  assert.equal(await signedByOwner({}, bytes, null), true);
});

test("a rollback puts the earlier list back with its own signature", async () => {
  const store = new Map();
  const bucket = {
    async get(key) { const v = store.get(key); return v ? { text: async () => v.value, customMetadata: v.meta } : null; },
    async put(key, value, options = {}) { store.set(key, { value: typeof value === "string" ? value : new TextDecoder().decode(value), meta: options.customMetadata ?? {} }); },
    async list({ prefix }) { return { objects: [...store.keys()].filter((k) => k.startsWith(prefix)).map((key) => ({ key })) }; },
    async delete(keys) { for (const k of [].concat(keys)) store.delete(k); },
  };
  const env = { RELEASES: bucket };
  await publishList(env, "recipes.json", "v1", "sig-1");
  await new Promise((r) => setTimeout(r, 5));
  await publishList(env, "recipes.json", "v2", "sig-2");
  assert.equal(store.get("recipes.json").meta.signature, "sig-2");
  await rollbackList(env, "recipes.json");
  assert.deepEqual([store.get("recipes.json").value, store.get("recipes.json").meta.signature], ["v1", "sig-1"]);
});
