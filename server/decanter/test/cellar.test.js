// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import { test } from "node:test";
import assert from "node:assert/strict";
import { OS, ARCH, archiveKey, withArchive, mayUpload } from "../src/cellar.js";

test("paths name the macOS major and the GPU architecture", () => {
  assert.ok(OS.test("26") && ARCH.test("applegpu_g16s"));
  assert.ok(!OS.test("26.6") && !ARCH.test("g16s") && !ARCH.test("applegpu_g16s/.."));
  assert.equal(archiveKey("steam", "1538550", "Raft.exe", "26", "applegpu_g16s"), "cellar/steam/1538550/Raft.exe/26/applegpu_g16s");
});

test("the manifest keeps one entry per exe, os and arch", () => {
  let m = withArchive(null, { exe: "Raft.exe", os: "26", arch: "applegpu_g16s", pipelines: 167, bytes: 10 });
  m = withArchive(m, { exe: "Raft.exe", os: "26", arch: "applegpu_g13g", pipelines: 167, bytes: 11 });
  m = withArchive(m, { exe: "Raft.exe", os: "26", arch: "applegpu_g16s", pipelines: 200, bytes: 12 });
  assert.deepEqual(m.archives.map((a) => [a.arch, a.pipelines]), [["applegpu_g13g", 167], ["applegpu_g16s", 200]]);
  assert.ok(m.archives.every((a) => a.updated));
});

test("only the builder uploads", () => {
  const env = { CELLAR_TOKEN: "secret" };
  assert.ok(mayUpload(new Request("https://x/", { headers: { Authorization: "Bearer secret" } }), env));
  assert.ok(!mayUpload(new Request("https://x/", { headers: { Authorization: "Bearer other" } }), env));
  assert.ok(!mayUpload(new Request("https://x/", { headers: { Authorization: "Bearer secret" } }), {}));
});
