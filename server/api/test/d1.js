// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
// A small stand-in for Cloudflare D1 on Node's built-in SQLite, with the real migrations, for tests that need tables.
import { DatabaseSync } from "node:sqlite";
import { readdirSync, readFileSync } from "node:fs";

export function testDB() {
  const sqlite = new DatabaseSync(":memory:");
  const dir = new URL("../migrations/", import.meta.url);
  for (const file of readdirSync(dir).filter((f) => f.endsWith(".sql")).sort()) sqlite.exec(readFileSync(new URL(file, dir), "utf8"));
  const plain = (row) => (row ? { ...row } : row);           // D1 rows are ordinary objects
  const statement = (sql, args = []) => ({
    bind: (...values) => statement(sql, values),
    first: async () => plain(sqlite.prepare(sql).get(...args)) ?? null,
    all: async () => ({ results: sqlite.prepare(sql).all(...args).map(plain) }),
    run: async () => { const r = sqlite.prepare(sql).run(...args); return { meta: { changes: Number(r.changes) } }; },
    _run() { return /^\s*(SELECT|INSERT[\s\S]*RETURNING)/i.test(sql) ? { results: sqlite.prepare(sql).all(...args).map(plain) } : { meta: { changes: Number(sqlite.prepare(sql).run(...args).changes) } }; },
  });
  return {
    sqlite,
    prepare: (sql) => statement(sql),
    batch: async (statements) => statements.map((s) => s._run()),
  };
}
