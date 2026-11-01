// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import { test } from "node:test";
import assert from "node:assert/strict";
import { appVersion, source, archiveVersion, latestRelease, sameToken, today } from "../src/stats.js";

test("the updater names the app's version", () => {
  assert.equal(appVersion("Sommelier/0.2.0 Sparkle/2.9.6"), "0.2.0");
  assert.equal(appVersion("Mozilla/5.0 (Macintosh)"), null);
  assert.equal(appVersion("NotSommelier/1.0"), null);
});

test("who downloads", () => {
  assert.equal(source("Sommelier/0.2.0 Sparkle/2.9.6"), "update");
  assert.equal(source("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15"), "site");
  assert.equal(source("curl/8.7.1"), "other");
  assert.equal(source(null), "other");
});

test("archive names and the newest release", () => {
  assert.equal(archiveVersion("Sommelier-0.2.0.zip"), "0.2.0");
  assert.equal(archiveVersion("../etc/passwd"), null);
  const appcast = `<rss><channel>
    <item><sparkle:shortVersionString>0.2.0</sparkle:shortVersionString><enclosure url="https://api.playsommelier.com/v1/releases/Sommelier-0.2.0.zip" length="1"/></item>
    <item><sparkle:shortVersionString>0.1.0</sparkle:shortVersionString><enclosure url="https://api.playsommelier.com/v1/releases/Sommelier-0.1.0.zip" length="1"/></item>
  </channel></rss>`;
  assert.deepEqual(latestRelease(appcast), { version: "0.2.0", file: "Sommelier-0.2.0.zip" });
  assert.equal(latestRelease("<rss></rss>"), null);
});

test("the owner's token", () => {
  assert.ok(sameToken("secret", "secret"));
  assert.ok(!sameToken("secreT", "secret"));
  assert.ok(!sameToken("", ""));
  assert.ok(!sameToken("x", undefined));
  assert.equal(today(Date.UTC(2026, 9, 21, 23, 59)), "2026-10-21");
});

test("the owner's summary of players' reports", async () => {
  const { testDB } = await import("./d1.js");
  const { summary } = await import("../src/stats.js");
  const db = testDB();
  const now = Date.UTC(2026, 9, 21, 12);
  const add = (client, outcome, fps, chip) => db.prepare("INSERT INTO reports (client, store, game_id, steam_id, title, outcome, fps_avg, chip, created_at) VALUES (?, 'steam', '1', '1', 'Raft', ?, ?, ?, ?)").bind(client, outcome, fps, chip, now).run();
  await add("a", "ran", 60, "Apple M1"); await add("b", "ran", 40, "Apple M1"); await add("c", "crashed", null, null);
  const s = await summary(db, now, 30);
  assert.deepEqual(s.reports.byOutcome, { ran: 2, crashed: 1 });
  assert.deepEqual(s.reports.byChip, { "Apple M1": 2 });
  assert.deepEqual(s.reports.topGames, [{ game: "1", title: "Raft", reports: 3, ran: 2, fps: 50 }]);
  assert.deepEqual(s.reports.byDay, [{ day: "2026-10-21", count: 3 }]);
});

test("the stats page is served with a strict policy", async () => {
  const { default: worker } = await import("../src/index.js");
  const response = await worker.fetch(new Request("http://x/admin"), {}, {});
  assert.equal(response.status, 200);
  assert.match(response.headers.get("Content-Security-Policy"), /frame-ancestors 'none'/);
  assert.match(await response.text(), /<title>Sommelier · статистика<\/title>/);
});

test("which graphics work, per game", async () => {
  const { testDB } = await import("./d1.js");
  const { summary } = await import("../src/stats.js");
  const db = testDB();
  const now = Date.UTC(2026, 9, 21, 12);
  const add = (client, outcome, backend, choice) => db.prepare("INSERT INTO reports (client, store, game_id, steam_id, title, outcome, backend, backend_choice, created_at) VALUES (?, 'steam', '1', '1', 'Raft', ?, ?, ?, ?)").bind(client, outcome, backend, choice, now).run();
  await add("a", "ran", "dxmt", "manual"); await add("b", "crashed", "d3dMetal", "auto"); await add("c", "ran", "dxmt", null);
  const s = await summary(db, now, 30);
  assert.deepEqual(s.settings.byGameBackend.map((r) => [r.backend, r.reports, r.ran, r.manual]), [["dxmt", 2, 2, 1], ["d3dMetal", 1, 0, 0]]);
  assert.equal(s.settings.manual, 1);
  assert.equal(s.settings.withChoice, 2);
});

test("the owner's marked browser isn't counted as a download", async () => {
  const { testDB } = await import("./d1.js");
  const { default: worker } = await import("../src/index.js");
  const files = new Map([["Sommelier-9.9.9.zip", "zip"]]);
  const env = { DB: testDB(), SALT: "s", ADMIN_TOKEN: "t",
    RELEASES: { async get(k) { return files.has(k) ? { body: "zip", size: 3, httpEtag: '"x"' } : null } } };
  const ctx = { waitUntil: (p) => p };
  const downloads = () => env.DB.sqlite.prepare("SELECT COALESCE(SUM(count), 0) AS n FROM counts WHERE kind = 'download'").get().n;
  await worker.fetch(new Request("http://x/v1/releases/Sommelier-9.9.9.zip"), env, ctx);
  await new Promise((r) => setTimeout(r, 20));
  assert.equal(downloads(), 1);
  const marked = await worker.fetch(new Request("http://x/v1/internal"), env, ctx);
  assert.match(marked.headers.get("Set-Cookie"), /internal=1/);
  await worker.fetch(new Request("http://x/v1/releases/Sommelier-9.9.9.zip", { headers: { Cookie: "internal=1" } }), env, ctx);
  await new Promise((r) => setTimeout(r, 20));
  assert.equal(downloads(), 1);                                        // still one
});

test("installs: new, seen, gone after 30 silent days, and back", async () => {
  const { testDB } = await import("./d1.js");
  const { default: worker } = await import("../src/index.js");
  const { heard, installsSummary } = await import("../src/installs.js");
  const db = testDB();
  const day = (d) => Date.UTC(2026, 8, d, 12);
  assert.equal(await heard(db, "a", "0.3.0", "DE", day(1)), "new");
  assert.equal(await heard(db, "a", "0.3.0", "DE", day(2)), "seen");
  assert.equal(await heard(db, "b", "0.3.0", "PL", day(1)), "new");
  let s = await installsSummary(db, "2026-09-01", Date.UTC(2026, 9, 10));      // 38 days after: both gone
  assert.deepEqual([s.tracked, s.installedNow, s.uninstalled, s.returned], [2, 0, 2, 0]);
  assert.equal(await heard(db, "a", "0.3.1", "DE", Date.UTC(2026, 9, 10)), "back");
  s = await installsSummary(db, "2026-09-01", Date.UTC(2026, 9, 10));
  assert.deepEqual([s.tracked, s.installedNow, s.uninstalled, s.returned], [2, 1, 1, 1]);
  // From the app: only Sommelier; without an id it's only counted, with one it's tracked.
  const env = { DB: testDB(), SALT: "s", ADMIN_TOKEN: "t" };
  const post = (ua, id) => worker.fetch(new Request("http://x/v1/installs", { method: "POST", headers: { "User-Agent": ua }, body: JSON.stringify({ id }) }), env, {});
  assert.equal((await post("Mozilla/5.0", "0f3c9a2e-1111")).status, 400);
  assert.equal((await post("Sommelier/0.3.0", "not an id!")).status, 400);
  assert.equal((await (await post("Sommelier/0.3.0", undefined)).json()).result, "counted");
  assert.equal((await installsSummary(env.DB, "2026-01-01", Date.now())).allTime, 1);
  assert.equal((await (await post("Sommelier/0.3.0", "0f3c9a2e-1111")).json()).result, "new");
  assert.equal((await (await post("Sommelier/0.3.0", "0f3c9a2e-1111")).json()).result, "seen");
  const leave = await worker.fetch(new Request("http://x/v1/installs", { method: "POST", headers: { "User-Agent": "Sommelier/0.3.0" }, body: JSON.stringify({ id: "0f3c9a2e-1111", leave: true }) }), env, {});
  assert.equal((await leave.json()).result, "left");
  assert.equal((await installsSummary(env.DB, "2026-01-01", Date.now())).tracked, 0);
});
