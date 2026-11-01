// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import { test } from "node:test";
import assert from "node:assert/strict";
import { validateReport, summarize, median, hash } from "../src/reports.js";

const good = {
  client: "3f2a9c1e-5b7d-4e8f-9a0b-1c2d3e4f5a6b",
  game: { store: "epic", id: "9d2d0eb64d5c44529cece33fe2a46482", title: "Grand Theft Auto V", steamAppID: "271590" },
  outcome: "ran", minutes: 42,
  fps: { average: 58.37, low: 31, resolution: "2560x1440" },
  system: { chip: "Apple M2 Pro", gpuCores: 19, ramGB: 32, macOS: "15.6" },
  sommelier: { app: "0.1", engine: "2.2.1", backend: "dxmt" },
};

test("a full report", () => {
  const { report, error } = validateReport(good);
  assert.equal(error, undefined);
  assert.equal(report.steamId, "271590");
  assert.equal(report.fpsAvg, 58.4);
  assert.equal(report.chip, "Apple M2 Pro");
});

test("the smallest report: it didn't start", () => {
  const { report } = validateReport({ client: good.client, game: { store: "steam", id: "1172470" }, outcome: "didNotStart" });
  assert.equal(report.steamId, "1172470");
  assert.equal(report.fpsAvg, null);
});

test("bad reports are refused", () => {
  const bad = (patch) => validateReport({ ...good, ...patch }).error;
  assert.ok(bad({ client: "x" }));
  assert.ok(bad({ game: { store: "itch", id: "1" } }));
  assert.ok(bad({ game: { store: "steam", id: "../etc" } }));
  assert.ok(bad({ outcome: "great" }));
  assert.ok(bad({ minutes: 0 }));                                    // "ran" for less than a minute
  assert.ok(bad({ outcome: "crashed" }));                            // frame rates only for a run
  assert.ok(bad({ fps: { average: 5000 } }));
  assert.ok(bad({ fps: { average: 30, low: 60 } }));
  assert.ok(bad({ fps: { average: 30, resolution: "big" } }));
  assert.ok(bad({ system: { chip: "Totally Real GPU" } }));
  assert.ok(bad({ system: { chip: "Apple M3", ramGB: 2 } }));
  assert.ok(bad({ sommelier: { backend: "vulkan" } }));
  assert.ok(validateReport(null).error);
  assert.ok(validateReport({ ...good, system: { chip: "Intel Core i7-9750H" } }).report);
});

test("summary by Mac chip, with median frame rates", () => {
  const rows = [
    { outcome: "ran", chip: "Apple M2 Pro", fps_avg: 60 },
    { outcome: "ran", chip: "Apple M2 Pro", fps_avg: 50 },
    { outcome: "ran", chip: "Apple M2 Pro", fps_avg: null },
    { outcome: "crashed", chip: "Apple M1", fps_avg: null },
    { outcome: "ran", chip: null, fps_avg: 40 },
  ];
  const s = summarize(rows);
  assert.deepEqual([s.reports, s.ran, s.failed], [5, 4, 1]);
  assert.deepEqual(s.systems[0], { chip: "Apple M2 Pro", reports: 3, ran: 3, fpsMedian: 55, fpsReports: 2 });
  assert.deepEqual(s.systems[1], { chip: "Apple M1", reports: 1, ran: 0, fpsMedian: null, fpsReports: 0 });
  assert.equal(median([3, 1, 2]), 2);
  assert.equal(median([]), null);
});

test("hashes are salted", async () => {
  assert.notEqual(await hash("a", "x"), await hash("b", "x"));
  assert.equal((await hash("a", "x")).length, 64);
});

test("how the game was run", async () => {
  const { validateSettings } = await import("../src/reports.js");
  const settings = { backendChoice: "manual", retina: false, metalFX: false, rayTracing: true, commandAsControl: false,
    environment: { DXMT_CONFIG: "d3d11.metalSpatialUpscaleFactor=1.5", WINEDEBUG: "-all" }, arguments: ["-dx11"],
    otherCustom: 2, fixes: ["overcooked-gl"], shadersFromOthers: true, extra: "dropped" };
  const ok = validateSettings(settings);
  assert.equal(ok.error, undefined);
  assert.equal(ok.settings.extra, undefined);
  assert.equal(ok.settings.backendChoice, "manual");

  assert.ok(validateSettings({ ...settings, backendChoice: "maybe" }).error);
  assert.equal(validateSettings({ ...settings, backendChoice: "retry" }).settings.backendChoice, "retry");
  assert.ok(validateSettings({ ...settings, environment: { DXVK_LOG_PATH: "x" } }).error);       // a path by its name
  assert.ok(validateSettings({ ...settings, environment: { HOME: "x" } }).error);              // not a graphics variable
  assert.ok(validateSettings({ ...settings, environment: { WINEPREFIX: "/Users/anna" } }).error);
  assert.ok(validateSettings({ ...settings, arguments: ["/Users/anna/save"] }).error);
  assert.ok(validateSettings({ ...settings, fixes: ["Bad Id!"] }).error);

  const { report } = validateReport({ ...good, settings });
  assert.equal(report.backendChoice, "manual");
  assert.equal(validateReport({ ...good, hdr: true }).report.hdr, 1);
  assert.equal(validateReport({ ...good, hdr: false }).report.hdr, 0);
  assert.equal(validateReport(good).report.hdr, null);
  assert.equal(validateReport({ ...good, hdr: "yes" }).error, "hdr");
  assert.equal(JSON.parse(report.settings).fixes[0], "overcooked-gl");
  assert.equal(validateReport({ ...good, settings: { backendChoice: "x" } }).error, "settings.backendChoice");
  assert.equal(validateReport(good).report.settings, null);                                     // older apps
});

test("a game's results by graphics", () => {
  const rows = [
    { outcome: "ran", backend: "dxmt", backend_choice: "manual", fps_avg: 60 },
    { outcome: "ran", backend: "dxmt", backend_choice: "auto", fps_avg: 40 },
    { outcome: "crashed", backend: "d3dMetal", backend_choice: "auto" },
  ];
  assert.deepEqual(summarize(rows).backends, [
    { backend: "dxmt", reports: 2, ran: 2, manual: 1, fpsMedian: 50 },
    { backend: "d3dMetal", reports: 1, ran: 0, manual: 0, fpsMedian: null },
  ]);
});
