// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import { test } from "node:test";
import assert from "node:assert/strict";
import { stagingGate, withStagingCookie } from "../src/staging.js";

const KEY = "k".repeat(32);
const env = { ENVIRONMENT: "staging", STAGING_KEY: KEY };

test("production and development aren't gated", () => {
  assert.equal(stagingGate(new Request("https://x/v1/a"), { ENVIRONMENT: "production" }), null);
  assert.equal(stagingGate(new Request("https://x/v1/a"), {}), null);
});

test("staging wants the key", () => {
  assert.equal(stagingGate(new Request("https://x/v1/a"), env).status, 403);
  assert.equal(stagingGate(new Request("https://x/v1/a", { headers: { "X-Sommelier-Staging-Key": "wrong" } }), env).status, 403);
  assert.equal(stagingGate(new Request("https://x/v1/a", { headers: { "X-Sommelier-Staging-Key": KEY } }), env), null);
  assert.equal(stagingGate(new Request(`https://x/admin?staging_key=${KEY}`), env), null);
  assert.equal(stagingGate(new Request("https://x/admin", { headers: { Cookie: `a=b; sommelier_staging=${KEY}` } }), env), null);
  assert.equal(stagingGate(new Request("https://x/v1/a"), { ENVIRONMENT: "staging", STAGING_KEY: "short" }).status, 503);
});

test("the key in the address leaves a cookie", () => {
  const r = withStagingCookie(new Request(`https://x/admin?staging_key=${KEY}`), env, new Response("ok"));
  assert.match(r.headers.get("Set-Cookie"), /sommelier_staging=/);
});
