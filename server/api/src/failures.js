// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
// Launch failures players send (with their say-so, after a preview), and the fixes list the app reads.
//
// fixes.json is the online half of the app's one-click fixes (Sources/SommelierKit/Fixes/FixRules.swift): rules whose
// patterns match a failed launch's logs and whose action is one of a closed list the app knows. The list can only
// choose among those actions, never run anything else; rules with an action this app version doesn't know are
// skipped by the app. Remote rules come first and replace built-in ones with the same id.
import { STORES } from "./reports.js";

const ID = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/;
const RULE_ID = /^[a-z0-9][a-z0-9-]{0,63}$/;
const VERSION = /^[0-9A-Za-z.+ (),-]{1,64}$/;

export const MAX_FAILURE_BYTES = 256 * 1024;
export const RETENTION_DAYS = 180;

const text = (v, max) => (typeof v === "string" ? v.slice(0, max) : null);

/** Checks a failure report; returns `{ failure }` flattened for storage, or `{ error }`. */
export function validateFailure(body) {
  if (!body || typeof body !== "object") return { error: "not a report" };
  const { client, game, diagnostics, matched, sommelier } = body;
  if (typeof client !== "string" || !/^[0-9a-fA-F-]{16,64}$/.test(client)) return { error: "client" };
  if (!game || !STORES.includes(game.store) || typeof game.id !== "string" || !ID.test(game.id)) return { error: "game" };
  if (game.steamAppID != null && !/^\d{1,10}$/.test(String(game.steamAppID))) return { error: "game.steamAppID" };
  if (!diagnostics || typeof diagnostics !== "object" || typeof diagnostics.logTail !== "string") return { error: "diagnostics" };
  if (!Array.isArray(matched) || matched.length > 20 || !matched.every((m) => typeof m === "string" && RULE_ID.test(m))) return { error: "matched" };
  const exit = Number.isInteger(diagnostics.exitCode) ? diagnostics.exitCode : null;
  const seconds = Number.isInteger(diagnostics.secondsRunning) && diagnostics.secondsRunning >= 0 ? diagnostics.secondsRunning : null;
  return {
    failure: {
      client, store: game.store, gameId: game.id,
      steamId: game.store === "steam" ? game.id : (game.steamAppID != null ? String(game.steamAppID) : null),
      title: text(game.title, 200),
      signature: matched[0] ?? "unknown",
      matched: JSON.stringify(matched),
      app: sommelier?.app && VERSION.test(sommelier.app) ? sommelier.app : null,
      engine: diagnostics.engineVersion && VERSION.test(diagnostics.engineVersion) ? diagnostics.engineVersion : null,
      backend: text(diagnostics.backend, 20),
      chip: text(diagnostics.chip, 80),
      macos: text(diagnostics.macOS, 80),
      exitCode: exit, secondsRunning: seconds,
      diagnostics: JSON.stringify(diagnostics),
    },
  };
}

export async function saveFailure(db, player, f, now) {
  const row = await db.prepare(
    `INSERT INTO failures (created_at, client, store, game_id, steam_id, title, signature, matched, app_version, engine, backend, chip, macos,
       exit_code, seconds_running, diagnostics) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) RETURNING id`)
    .bind(now, player, f.store, f.gameId, f.steamId, f.title, f.signature, f.matched, f.app, f.engine, f.backend, f.chip, f.macos,
      f.exitCode, f.secondsRunning, f.diagnostics).first();
  return row?.id;
}

/** What to look at first: by problem, the games failing most, and the failures nothing recognised yet. */
export async function failureSummary(db, now, days) {
  const since = now - days * 86_400_000;
  const all = async (sql, ...args) => (await db.prepare(sql).bind(...args).all()).results;
  return {
    days,
    total: (await db.prepare("SELECT COUNT(*) AS n FROM failures WHERE created_at >= ?").bind(since).first())?.n ?? 0,
    bySignature: await all(`SELECT signature, COUNT(*) AS count, COUNT(DISTINCT store || ':' || game_id) AS games
      FROM failures WHERE created_at >= ? GROUP BY signature ORDER BY count DESC LIMIT 50`, since),
    topGames: await all(`SELECT store, game_id AS id, MAX(title) AS title, COUNT(*) AS count, COUNT(DISTINCT client) AS players,
      GROUP_CONCAT(DISTINCT signature) AS signatures FROM failures WHERE created_at >= ? GROUP BY store, game_id ORDER BY players DESC, count DESC LIMIT 50`, since),
    unrecognised: await all(`SELECT id, created_at, store, game_id, title, backend, engine, exit_code, seconds_running
      FROM failures WHERE created_at >= ? AND signature = 'unknown' ORDER BY created_at DESC LIMIT 50`, since),
  };
}

export async function failureDetail(db, id) {
  const row = await db.prepare("SELECT * FROM failures WHERE id = ?").bind(id).first();
  if (!row) return null;
  const { client, ...rest } = row;
  return { ...rest, matched: JSON.parse(row.matched), diagnostics: JSON.parse(row.diagnostics) };
}

export async function pruneFailures(db, now) {
  await db.prepare("DELETE FROM failures WHERE created_at < ?").bind(now - RETENTION_DAYS * 86_400_000).run();
}

// MARK: fixes.json

/** The closed lists the app knows (FixAction, FixCondition, GraphicsBackend, StoreKind). */
export const ACTIONS = ["playStationPrompts", "switchGraphics", "installDotNet", "installVCRuntime", "disableEAOverlay", "setEnvironment", "setUpDirectX12", "setUpEAApp", "turnOffTurbo",
  "overrideDLL", "runExecutable", "setWindowsVersion", "addArguments", "installComponent", "editConfig", "editSave"];
const SAVE_FILE = /^(game|appdata|roaming|documents)(?!.*(^|[\\/])\.\.([\\/]|$))(?!.*\*[^\\/])(?!.*[^\\/:]\*)(?!(.*\*){2}):[^:?"<>|\0]{1,300}\.sav$/i;
// Any text file the game keeps its settings in (user.settings, config.NFS13Save), never a program, library, script,
// archive or save.
const CONFIG_FILE = /^(game|appdata|roaming|documents|unreal):(?!.*(^|[\\/])\.\.([\\/]|$))(?!.*\.(exe|dll|sys|com|bat|cmd|ps1|vbs|js|msi|scr|lnk|sav|pak|bin|dat|zip|7z|rar|cab|so|dylib)$)[^:*?"<>|\0]{1,300}\.[A-Za-z0-9_]{1,20}$/i;
const CONFIG_TEXT = /^[^\r\n\0]{1,200}$/;
export const COMPONENTS = ["directx", "d3dcompiler47", "physx", "directplay", "dsound", "directmusic", "corefonts"];
export const WINDOWS_VERSIONS = ["winxp", "winxp64", "vista", "win7", "win8", "win81", "win10", "win11"];
export const OVERRIDE_MODES = ["", "n", "b", "n,b", "b,n", "d"];
const DLL = /^[A-Za-z0-9_.-]{1,64}$/;
const RELATIVE = /^(?!.*\.\.[\\/]\.\.[\\/]\.\.)[^:*?"<>|\0]{1,200}$/;        // inside the game's folder: no drive, at most two "..".
const ARGUMENT = /^[^\0\r\n]{1,200}$/;

/** Problems with one action of a rule or recipe (Swift's Codable form), as strings; [] when it's fine. */
/** The variables a rule or recipe may set (the app keeps to the same list, FixAction.allowsEnvironment). */
export function allowsEnvironment(key) {
  const names = new Set(["SOMMELIER_HIDE_WINE", "SOMMELIER_FORCE_SDR", "SOMMELIER_NO_MIC", "WINE_LARGE_ADDRESS_AWARE", "WINEESYNC", "WINEMSYNC", "WINEDEBUG",
    "SOMMELIER_VIDEO_SYSMEM", "WINE_ROSETTA_CPUID7_OR"]);
  return names.has(key) || /^(DXMT|D3DM|MTL|DXVK|VKD3D|MVK)_[A-Z0-9_]{1,60}$/.test(key);
}

export function checkAction(action, at) {
  const keys = action && typeof action === "object" ? Object.keys(action) : [];
  if (keys.length !== 1 || !ACTIONS.includes(keys[0])) return [`${at}.action`];
  const kind = keys[0], value = action[kind];
  switch (kind) {
    case "switchGraphics":
      return BACKENDS.includes(value?._0) ? [] : [`${at}.action: backend`];
    case "setEnvironment": {
      const env = value?._0;
      return env && typeof env === "object" && Object.entries(env).every(([k, v]) => allowsEnvironment(k) && typeof v === "string" && v.length <= 300)
        ? [] : [`${at}.action: environment (only graphics and Wine tuning variables)`];
    }
    case "overrideDLL":
      return typeof value?._0 === "string" && DLL.test(value._0) && OVERRIDE_MODES.includes(value?._1) ? [] : [`${at}.action: override`];
    case "runExecutable":
      return typeof value?.instead === "string" && RELATIVE.test(value.instead) && /\.exe$/i.test(value.instead)
        && typeof value?.run === "string" && RELATIVE.test(value.run) && /\.exe$/i.test(value.run) ? [] : [`${at}.action: executable`];
    case "setWindowsVersion":
      return WINDOWS_VERSIONS.includes(value?.version) && typeof value?.exe === "string" && /^[^\\/:*?"<>|\0]{1,120}\.exe$/i.test(value.exe)
        ? [] : [`${at}.action: windows version`];
    case "editConfig":
      return typeof value?.file === "string" && CONFIG_FILE.test(value.file) && !/^(game|appdata|roaming|documents|unreal):[\\/]/.test(value.file)
        && typeof value?.section === "string" && CONFIG_TEXT.test(value.section) && !/[\[\]]/.test(value.section)
        && typeof value?.key === "string" && CONFIG_TEXT.test(value.key) && !value.key.includes("=")
        && (value.field == null || (typeof value.field === "string" && /^[A-Za-z0-9_.]{1,100}$/.test(value.field)))
        && typeof value?.value === "string" && CONFIG_TEXT.test(value.value) ? [] : [`${at}.action: config edit`];
    case "playStationPrompts": {
      const values = value?.values;
      return typeof value?.file === "string" && CONFIG_FILE.test(value.file) && !/^(game|appdata|roaming|documents|unreal):[\\/]/.test(value.file)
        && typeof value?.section === "string" && CONFIG_TEXT.test(value.section) && !/[\[\]]/.test(value.section)
        && values && typeof values === "object" && Object.keys(values).length >= 1 && Object.keys(values).length <= 8
        && Object.entries(values).every(([k, v]) => /^[A-Za-z0-9_.]{1,100}$/.test(k) && typeof v === "string" && CONFIG_TEXT.test(v))
        ? [] : [`${at}.action: PlayStation prompts`];
    }
    case "editSave": {
      const values = value?.values;
      return typeof value?.file === "string" && SAVE_FILE.test(value.file) && !/^[a-z]+:[\\/]/.test(value.file)
        && typeof value?.structName === "string" && /^[A-Za-z0-9_]{1,100}$/.test(value.structName)
        && values && typeof values === "object" && Object.keys(values).length >= 1 && Object.keys(values).length <= 32
        && Object.entries(values).every(([k, v]) => /^[A-Za-z0-9_]{1,100}$/.test(k) && typeof v === "string" && (/^-?\d{1,9}$/.test(v) || v === "${level}"))
        ? [] : [`${at}.action: save edit`];
    }
    case "installComponent":
      return COMPONENTS.includes(value?._0) ? [] : [`${at}.action: component`];
    case "addArguments":
      return Array.isArray(value?._0) && value._0.length > 0 && value._0.length <= 20 && value._0.every((a) => typeof a === "string" && ARGUMENT.test(a))
        ? [] : [`${at}.action: arguments`];
    default:
      return [];
  }
}
export const CONDITIONS = ["backendIs", "backendIsNot", "store", "notNative", "noD3DMetal", "game", "launcherIs", "hasAntiCheat", "engineIs", "usesEpicOnlineServices"];
export const BACKENDS = ["auto", "d3dMetal", "dxmt", "dxvk", "wined3d"];

/**
 * Checks a fixes list before it is published. Shape (Swift's Codable form of the app's types):
 *   { "version": 1, "rules": [ { "id": "unity-dx12", "cause": "…", "causes": { "ru": "…" },
 *       "patterns": ["regex"], "conditions": [ { "backendIs": { "_0": "dxmt" } }, { "notNative": {} } ],
 *       "action": { "switchGraphics": { "_0": "wined3d" } } } ] }
 * Returns a list of problems (empty when it's fine).
 */
export function checkFixes(list) {
  const problems = [];
  if (!list || typeof list !== "object" || list.version !== 1 || !Array.isArray(list.rules)) return ["needs { version: 1, rules: [...] }"];
  if (list.rules.length > 500) problems.push("more than 500 rules");
  const seen = new Set();
  list.rules.forEach((r, i) => {
    const at = `rules[${i}]`;
    if (!r || typeof r !== "object") { problems.push(`${at}: not an object`); return; }
    if (typeof r.id !== "string" || !RULE_ID.test(r.id)) problems.push(`${at}.id`);
    else if (seen.has(r.id)) problems.push(`${at}.id repeats ${r.id}`);
    else seen.add(r.id);
    if (typeof r.cause !== "string" || !r.cause.trim() || r.cause.length > 600) problems.push(`${at}.cause`);
    if (r.causes != null && (typeof r.causes !== "object" || !Object.entries(r.causes).every(([k, v]) => /^[a-z]{2}(-[A-Za-z]{2,4})?$/.test(k) && typeof v === "string" && v.length <= 600))) problems.push(`${at}.causes`);
    if (!Array.isArray(r.patterns) || !r.patterns.length || r.patterns.length > 20 || !r.patterns.every((p) => typeof p === "string" && p.length > 0 && p.length <= 500)) problems.push(`${at}.patterns`);
    for (const c of r.conditions ?? []) {
      const keys = c && typeof c === "object" ? Object.keys(c) : [];
      if (keys.length !== 1 || !CONDITIONS.includes(keys[0])) { problems.push(`${at}.conditions: ${JSON.stringify(c)}`); continue; }
      const value = c[keys[0]]?._0;
      if ((keys[0] === "backendIs" || keys[0] === "backendIsNot") && !BACKENDS.includes(value)) problems.push(`${at}.conditions: backend ${value}`);
      if (keys[0] === "store" && !STORES.includes(value)) problems.push(`${at}.conditions: store ${value}`);
      if (keys[0] === "game" && !(typeof value === "string" && /^[a-z]+:[A-Za-z0-9._:-]{1,128}$/.test(value))) problems.push(`${at}.conditions: game ${value}`);
      if (keys[0] === "launcherIs" && !["ea", "ubisoft", "rockstar"].includes(value)) problems.push(`${at}.conditions: launcher ${value}`);
      if (keys[0] === "engineIs" && !["unreal", "unity"].includes(value)) problems.push(`${at}.conditions: engine ${value}`);
    }
    if (r.action != null) problems.push(...checkAction(r.action, at));
  });
  return problems;
}
