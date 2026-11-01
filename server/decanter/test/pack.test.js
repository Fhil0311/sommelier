import { test } from "node:test";
import assert from "node:assert/strict";
import { decode, encode, merge } from "../src/pack.js";

const lib = (seed) => Buffer.concat([Buffer.from("MTLB"), Buffer.alloc(300, seed)]);
const key = (n) => Buffer.alloc(40, n).toString("hex");

test("round trip", () => {
  const pack = { kind: 1, metalVersion: 320, tableVersion: 18, entries: new Map([[key(1), lib(1)], [key(2), lib(2)]]) };
  const bytes = encode(pack);
  assert.equal(bytes.subarray(0, 4).toString(), "SMLR");
  const back = decode(bytes);
  assert.equal(back.kind, 1);
  assert.equal(back.metalVersion, 320);
  assert.equal(back.tableVersion, 18);
  assert.deepEqual([...back.entries.keys()].sort(), [key(1), key(2)]);
  assert.ok(back.entries.get(key(2)).equals(lib(2)));
  assert.equal(decode(Buffer.from("nope")), null);
  assert.equal(decode(bytes.subarray(0, 30)), null);
});

test("drops what DXMT would not write", () => {
  const pack = { kind: 1, metalVersion: 320, tableVersion: 18, entries: new Map([[key(1), Buffer.from("not metal")]]) };
  assert.equal(decode(encode(pack)).entries.size, 0);
  const record = Buffer.concat([Buffer.from([1, 0, 0, 0]), Buffer.alloc(300, 5)]);
  const records = { kind: 2, metalVersion: 320, tableVersion: 1, entries: new Map([[Buffer.alloc(20, 9).toString("hex"), record], [key(1), record]]) };
  const back = decode(encode(records));
  assert.equal(back.kind, 2);
  assert.equal(back.entries.size, 1);                                      // a 40-byte key is no record key
});

test("merge keeps what the service has", () => {
  const a = { kind: 1, metalVersion: 320, tableVersion: 18, entries: new Map([[key(1), lib(1)]]) };
  const b = { kind: 1, metalVersion: 320, tableVersion: 18, entries: new Map([[key(1), lib(9)], [key(2), lib(2)]]) };
  const m = merge(a, b);
  assert.equal(m.entries.size, 2);
  assert.ok(m.entries.get(key(1)).equals(lib(1)));
});
