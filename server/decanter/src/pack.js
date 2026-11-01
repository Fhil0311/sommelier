// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
// The shader pack format, shared with SommelierKit's ShaderPack.swift:
// "SMLR", format version (u8), kind (u8: 1 shaders, 2 pipelines), Metal version (u32), table version (u32),
// entry count (u32), then raw-deflate of entries: key length (u16), key, value length (u32), value. Little endian.
import { deflateRawSync, inflateRawSync } from "node:zlib";

export const MAGIC = "SMLR";
export const FORMAT_VERSION = 2;
export const HEADER_SIZE = 18;
export const KINDS = { 1: "shaders", 2: "pipelines" };
export const MAX_RECORD_SIZE = 8192;
export const VALUE_MAGIC = "MTLB";
export const MAX_VALUE_SIZE = 4 * 1024 * 1024;
export const MAX_KEY_SIZE = 64;

export function isValidEntry(kind, key, value) {
  if (kind === 2) {
    if (key.length !== 20 || value.length < 8 || value.length > MAX_RECORD_SIZE) return false;
    const recordKind = value.readUInt32LE(0);
    return recordKind === 1 || recordKind === 2;
  }
  return key.length > 0 && key.length <= MAX_KEY_SIZE && value.length <= MAX_VALUE_SIZE
    && value.length >= 4 && value.subarray(0, 4).toString("latin1") === VALUE_MAGIC;
}

/** @returns {{metalVersion:number, tableVersion:number, entries: Map<string, Buffer>}|null} entries keyed by hex */
export function decode(buffer) {
  const data = Buffer.from(buffer);
  if (data.length < HEADER_SIZE || data.subarray(0, 4).toString("latin1") !== MAGIC || data[4] !== FORMAT_VERSION) return null;
  const kind = data[5];
  if (!KINDS[kind]) return null;
  const metalVersion = data.readUInt32LE(6);
  const tableVersion = data.readUInt32LE(10);
  const count = data.readUInt32LE(14);
  let body;
  try { body = count === 0 ? Buffer.alloc(0) : inflateRawSync(data.subarray(HEADER_SIZE)); } catch { return null; }
  const entries = new Map();
  let p = 0;
  for (let i = 0; i < count; i++) {
    if (p + 2 > body.length) return null;
    const keyLength = body.readUInt16LE(p); p += 2;
    if (p + keyLength + 4 > body.length) return null;
    const key = body.subarray(p, p + keyLength); p += keyLength;
    const valueLength = body.readUInt32LE(p); p += 4;
    if (p + valueLength > body.length) return null;
    const value = body.subarray(p, p + valueLength); p += valueLength;
    if (isValidEntry(kind, key, value)) entries.set(key.toString("hex"), Buffer.from(value));
  }
  return { kind, metalVersion, tableVersion, entries };
}

export function encode({ kind, metalVersion, tableVersion, entries }) {
  const parts = [];
  for (const hex of [...entries.keys()].sort()) {
    const key = Buffer.from(hex, "hex"), value = entries.get(hex);
    const keyLength = Buffer.alloc(2); keyLength.writeUInt16LE(key.length);
    const valueLength = Buffer.alloc(4); valueLength.writeUInt32LE(value.length);
    parts.push(keyLength, key, valueLength, value);
  }
  const header = Buffer.alloc(HEADER_SIZE);
  header.write(MAGIC, 0, "latin1");
  header[4] = FORMAT_VERSION;
  header[5] = kind;
  header.writeUInt32LE(metalVersion, 6);
  header.writeUInt32LE(tableVersion, 10);
  header.writeUInt32LE(entries.size, 14);
  const body = Buffer.concat(parts);
  return Buffer.concat([header, body.length ? deflateRawSync(body) : Buffer.alloc(0)]);
}

/** Everything in both; where they differ, what the service already has wins. */
export function merge(existing, incoming) {
  const entries = new Map(existing.entries);
  for (const [key, value] of incoming.entries) if (!entries.has(key)) entries.set(key, value);
  return { kind: existing.kind, metalVersion: existing.metalVersion, tableVersion: existing.tableVersion, entries };
}
