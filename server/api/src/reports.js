// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
// Reports players send from the app (only when they turn it on): did the game run, for how long, how fast, on what
// Mac and with which Sommelier setup. They decide a game's answer once there are enough of them, and they are the
// start of a frame-rate database by Mac model.
//
// Nothing in a report identifies a person: the player id is a random install id that the server keeps only as a
// salted hash, and addresses are never stored (the flood counters keep salted hashes for a day).

export const STORES = ["steam", "epic", "gog", "ea", "ubisoft", "battlenet"];
export const OUTCOMES = ["ran", "crashed", "didNotStart"];
export const BACKENDS = ["auto", "dxmt", "dxvk", "wined3d", "d3dMetal", "native"];

import { checkAction } from "./failures.js";

const ID = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/;
const CLIENT = /^[0-9a-fA-F-]{16,64}$/;
const VERSION = /^[0-9A-Za-z.+-]{1,24}$/;
const CHIP = /^(Apple M\d{1,2}( (Pro|Max|Ultra))?|Intel [\w ()®-]{1,48})$/;
const RESOLUTION = /^\d{3,5}x\d{3,5}$/;
const MACOS = /^\d{2}(\.\d{1,2}){0,2}$/;

/**
 * Checks a report and returns it flattened for storage, or `{ error }`.
 * Shape: { client, game: {store, id, title?, steamAppID?}, outcome, minutes?, fps?: {average, low?, resolution?},
 *          system?: {chip, gpuCores?, ramGB?, macOS?}, sommelier?: {app?, engine?, backend?}, hdr?, mods? }
 */
export function validateReport(body) {
  if (!body || typeof body !== "object") return { error: "not a report" };
  const { client, game, outcome, minutes, fps, system, sommelier } = body;
  if (typeof client !== "string" || !CLIENT.test(client)) return { error: "client" };
  if (!game || !STORES.includes(game.store) || typeof game.id !== "string" || !ID.test(game.id)) return { error: "game" };
  if (game.steamAppID != null && !/^\d{1,10}$/.test(String(game.steamAppID))) return { error: "game.steamAppID" };
  if (game.title != null && (typeof game.title !== "string" || game.title.length > 200)) return { error: "game.title" };
  if (!OUTCOMES.includes(outcome)) return { error: "outcome" };
  if (minutes != null && !(Number.isInteger(minutes) && minutes >= 0 && minutes <= 100_000)) return { error: "minutes" };
  if (outcome === "ran" && !(minutes >= 1)) return { error: "a game that ran was played for at least a minute" };

  let fpsAvg = null, fpsLow = null, resolution = null;
  if (fps != null) {
    if (outcome !== "ran") return { error: "fps without a run" };
    if (!(typeof fps.average === "number" && fps.average > 0 && fps.average <= 1000)) return { error: "fps.average" };
    if (fps.low != null && !(typeof fps.low === "number" && fps.low > 0 && fps.low <= fps.average)) return { error: "fps.low" };
    if (fps.resolution != null && !RESOLUTION.test(fps.resolution)) return { error: "fps.resolution" };
    fpsAvg = round(fps.average); fpsLow = fps.low != null ? round(fps.low) : null; resolution = fps.resolution ?? null;
  }
  if (system != null) {
    if (typeof system.chip !== "string" || !CHIP.test(system.chip)) return { error: "system.chip" };
    if (system.gpuCores != null && !(Number.isInteger(system.gpuCores) && system.gpuCores > 0 && system.gpuCores <= 256)) return { error: "system.gpuCores" };
    if (system.ramGB != null && !(Number.isInteger(system.ramGB) && system.ramGB >= 4 && system.ramGB <= 1024)) return { error: "system.ramGB" };
    if (system.macOS != null && !MACOS.test(system.macOS)) return { error: "system.macOS" };
  }
  if (sommelier != null) {
    if (sommelier.app != null && !VERSION.test(sommelier.app)) return { error: "sommelier.app" };
    if (sommelier.engine != null && !VERSION.test(sommelier.engine)) return { error: "sommelier.engine" };
    if (sommelier.backend != null && !BACKENDS.includes(sommelier.backend)) return { error: "sommelier.backend" };
  }
  if (body.hdr != null && typeof body.hdr !== "boolean") return { error: "hdr" };
  // Mods were in play (a mod on, or a loader's files in the game): only the flag, never which mods. Such a session
  // says nothing about the game itself and stays out of its verdict and numbers.
  if (body.mods != null && typeof body.mods !== "boolean") return { error: "mods" };
  let settingsJSON = null, backendChoice = null;
  if (body.settings != null) {
    const { settings, error } = validateSettings(body.settings);
    if (error) return { error: `settings.${error}` };
    settingsJSON = JSON.stringify(settings); backendChoice = settings.backendChoice;
  }
  return {
    report: {
      client, store: game.store, gameId: game.id,
      steamId: game.store === "steam" ? game.id : (game.steamAppID != null ? String(game.steamAppID) : null),
      title: game.title ?? null, outcome, minutes: minutes ?? null,
      fpsAvg, fpsLow, resolution,
      chip: system?.chip ?? null, gpuCores: system?.gpuCores ?? null, ramGB: system?.ramGB ?? null, macOS: system?.macOS ?? null,
      app: sommelier?.app ?? null, engine: sommelier?.engine ?? null, backend: sommelier?.backend ?? null,
      backendChoice, settings: settingsJSON, hdr: body.hdr == null ? null : (body.hdr ? 1 : 0),
      mods: body.mods == null ? null : (body.mods ? 1 : 0),
    },
  };
}

// The same rules as the app's CompatibilityReport.Settings: only settings, never paths or names.
const ENV_PREFIXES = ["DXMT_", "DXVK_", "D3DM_", "MTL_", "MVK_", "WINE", "VKD3D_", "DXGI_", "METAL_"];
const ENV_KEY = /^[A-Z][A-Z0-9_]{0,63}$/;
const ENV_VALUE = /^[A-Za-z0-9._,=:;+-]{0,120}$/;
const ARGUMENT = /^-{1,2}[A-Za-z][A-Za-z0-9_.+-]{0,39}$/;
const FIX_ID = /^[a-z0-9][a-z0-9.-]{0,63}$/;
const SWITCHES = ["retina", "metalFX", "rayTracing", "commandAsControl", "shadersFromOthers"];

/** Checks a report's settings block and returns it with only the known fields, or `{ error }` naming the field. */
export function validateSettings(s) {
  if (!s || typeof s !== "object" || Array.isArray(s)) return { error: "shape" };
  if (!["auto", "manual", "retry", "recipe"].includes(s.backendChoice)) return { error: "backendChoice" };
  const out = { backendChoice: s.backendChoice };
  for (const key of SWITCHES) {
    if (s[key] == null) continue;
    if (typeof s[key] !== "boolean") return { error: key };
    out[key] = s[key];
  }
  const env = s.environment ?? {};
  if (typeof env !== "object" || Array.isArray(env) || Object.keys(env).length > 20) return { error: "environment" };
  for (const [key, value] of Object.entries(env)) {
    const known = ENV_KEY.test(key) && ENV_PREFIXES.some((p) => key.startsWith(p)) && !/PATH|FILE|DIR|LOG/.test(key);
    if (!known || typeof value !== "string" || !ENV_VALUE.test(value)) return { error: `environment.${ENV_KEY.test(key) ? key : "key"}` };
  }
  out.environment = env;
  const args = s.arguments ?? [];
  if (!Array.isArray(args) || args.length > 20 || !args.every((a) => typeof a === "string" && ARGUMENT.test(a))) return { error: "arguments" };
  out.arguments = args;
  const other = s.otherCustom ?? 0;
  if (!(Number.isInteger(other) && other >= 0 && other <= 1000)) return { error: "otherCustom" };
  out.otherCustom = other;
  const fixes = s.fixes ?? [];
  if (!Array.isArray(fixes) || fixes.length > 10 || !fixes.every((f) => typeof f === "string" && FIX_ID.test(f))) return { error: "fixes" };
  out.fixes = fixes;
  // What the player's fixes did (installed a component, set a variable…), in the recipes' own form: a fix that
  // works for several players is a recipe in waiting. One this server can't read is left out, not the report.
  const actions = s.actions ?? [];
  if (!Array.isArray(actions) || actions.length > 10) return { error: "actions" };
  out.actions = actions.filter((a) => a && typeof a === "object" && !Array.isArray(a) && Object.keys(a).length === 1
    && JSON.stringify(a).length <= 2000 && !checkAction(a, "a").length);
  return { settings: out };
}

const round = (n) => Math.round(n * 10) / 10;

/**
 * What players reported about one game: counts by outcome, and by Mac chip how many ran it and the median frame
 * rate they saw. `rows` are stored reports ({outcome, chip, fps_avg, ...}).
 */
export function summarize(rows) {
  const ran = rows.filter((r) => r.outcome === "ran").length;
  const failed = rows.length - ran;
  const byChip = new Map();
  for (const r of rows) {
    if (!r.chip) continue;
    const entry = byChip.get(r.chip) ?? { chip: r.chip, reports: 0, ran: 0, fps: [] };
    entry.reports += 1;
    if (r.outcome === "ran") entry.ran += 1;
    if (r.fps_avg != null) entry.fps.push(r.fps_avg);
    byChip.set(r.chip, entry);
  }
  const systems = [...byChip.values()]
    .sort((a, b) => b.reports - a.reports || a.chip.localeCompare(b.chip))
    .slice(0, 12)
    .map(({ fps, ...rest }) => ({ ...rest, fpsMedian: median(fps), fpsReports: fps.length }));
  const byBackend = new Map();
  for (const r of rows) {
    if (!r.backend) continue;
    const entry = byBackend.get(r.backend) ?? { backend: r.backend, reports: 0, ran: 0, manual: 0, fps: [] };
    entry.reports += 1;
    if (r.outcome === "ran") entry.ran += 1;
    if (r.backend_choice === "manual") entry.manual += 1;
    if (r.fps_avg != null) entry.fps.push(r.fps_avg);
    byBackend.set(r.backend, entry);
  }
  const backends = [...byBackend.values()]
    .sort((a, b) => b.reports - a.reports || a.backend.localeCompare(b.backend))
    .map(({ fps, ...rest }) => ({ ...rest, fpsMedian: median(fps) }));
  return { reports: rows.length, ran, failed, systems, backends };
}

export function median(values) {
  if (!values.length) return null;
  const sorted = [...values].sort((a, b) => a - b);
  const mid = sorted.length >> 1;
  return sorted.length % 2 ? sorted[mid] : round((sorted[mid - 1] + sorted[mid]) / 2);
}

/** Salted SHA-256, hex: how player ids and addresses are kept. */
export async function hash(salt, value) {
  const bytes = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(`${salt}:${value}`));
  return [...new Uint8Array(bytes)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
