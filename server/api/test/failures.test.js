// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import { test } from "node:test";
import assert from "node:assert/strict";
import { validateFailure, checkFixes } from "../src/failures.js";

const diagnostics = { gameID: "epic:Sage", title: "Overcooked", store: "epic", native: false, engineVersion: "2.2.1",
  wineVersion: "11.0, from CrossOver 26.3.0 source", backend: "dxmt", macOS: "Version 26.0", chip: "Apple M4 Pro",
  exitCode: 1, secondsRunning: 4, logTail: "err:module:import_dll Library mfc140u.dll not found", collected: 0 };
const good = { client: "3f2a9c1e-5b7d-4e8f-9a0b-1c2d3e4f5a6b", game: { store: "epic", id: "Sage", title: "Overcooked" },
  diagnostics, matched: ["vcruntime", "missing-dll"], sommelier: { app: "0.1.0" } };

test("a failure report", () => {
  const { failure, error } = validateFailure(good);
  assert.equal(error, undefined);
  assert.equal(failure.signature, "vcruntime");
  assert.equal(failure.engine, "2.2.1");
  assert.equal(failure.secondsRunning, 4);
  assert.equal(JSON.parse(failure.diagnostics).logTail, diagnostics.logTail);
  assert.equal(validateFailure({ ...good, matched: [] }).failure.signature, "unknown");
});

test("bad failure reports", () => {
  assert.ok(validateFailure({ ...good, client: "x" }).error);
  assert.ok(validateFailure({ ...good, game: { store: "itch", id: "1" } }).error);
  assert.ok(validateFailure({ ...good, diagnostics: {} }).error);
  assert.ok(validateFailure({ ...good, matched: ["Not An Id!"] }).error);
  assert.ok(validateFailure(null).error);
});

test("the fixes list", () => {
  const ok = { version: 1, rules: [
    { id: "unity-gl-fallback", cause: "Unity fell back to OpenGL.", causes: { ru: "Unity перешла на OpenGL." },
      patterns: ["OpenGL core profile"], conditions: [{ backendIs: { _0: "d3dMetal" } }, { notNative: {} }, { game: { _0: "epic:Sage" } }],
      action: { switchGraphics: { _0: "dxmt" } } },
    { id: "needs-env", cause: "Needs a variable.", patterns: ["x"], action: { setEnvironment: { _0: { DXMT_CONFIG: "d3d11.metalSpatialUpscaleFactor=1" } } } },
    { id: "known-issue", cause: "Nothing to do.", patterns: ["y"] },
  ] };
  assert.deepEqual(checkFixes(ok), []);
  assert.ok(checkFixes({ version: 2, rules: [] }).length);
  assert.ok(checkFixes({ version: 1, rules: [{ ...ok.rules[0], action: { runShell: { _0: "rm -rf /" } } }] }).length);
  assert.ok(checkFixes({ version: 1, rules: [{ ...ok.rules[0], conditions: [{ backendIs: { _0: "vulkan" } }] }] }).length);
  assert.ok(checkFixes({ version: 1, rules: [ok.rules[2], ok.rules[2]] }).length);         // the same id twice
  assert.ok(checkFixes({ version: 1, rules: [{ ...ok.rules[1], action: { setEnvironment: { _0: { "bad key": "1" } } } }] }).length);
});
