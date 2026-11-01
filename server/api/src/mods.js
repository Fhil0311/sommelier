// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
// Mods: how each game's mods are installed (mods.json, read by every app and published by the owner like the
// recipes), and the mod.io catalogue proxied for the app with Sommelier's own key. The list says which loaders a
// game's mods need, where each kind of mod goes, how the load order is written and whether the game may go online
// with mods; the app does nothing a profile doesn't describe, so the list is checked here before it is stored,
// field by field, the way the app's decoder reads it (Sources/SommelierKit/Mods/ModSupport.swift).
import { COMPONENTS, OVERRIDE_MODES } from "./failures.js";

const GAME = /^[a-z]+:[A-Za-z0-9._:-]{1,128}$/;
const ID = /^[a-z0-9][a-z0-9-]{0,63}$/;
const KEY = /^[A-Za-z][A-Za-z0-9]{0,40}$/;                                   // a reason, hint or notice: a key for the app's texts
const SHA256 = /^[0-9a-f]{64}$/;
const DLL = /^[A-Za-z0-9_.-]{1,64}$/;
const REPO = /^[A-Za-z0-9][A-Za-z0-9_-]{0,99}\/[A-Za-z0-9][A-Za-z0-9_.-]{0,99}$/;
const FILE_NAME = /^[^\\/:*?"<>|\0\r\n]{1,200}$/;
const TEXT = /^[^\0\r\n]{1,200}$/;
const NEXUS_DOMAIN = /^[a-z0-9-]{1,64}$/;
const MANIFEST_FIELD = /^manifest(\.[A-Za-z0-9_]{1,64}){1,4}$/;

export const ROOTS = ["game", "store", "tools", "home", "appdata", "roaming", "documents"];
export const SAVE_ROOTS = ["documents", "roaming", "local", "localLow", "savedGames", "steamUserdata", "install", "home"];
const STATUSES = ["ready", "experimental"], RUNTIMES = ["wine", "native", "any"];
const DOWNLOADS = ["github", "url", "nexus", "inner"];
const SETTINGS_FORMATS = ["ini", "json", "keyValue"];
const UNITS = ["triple", "folder", "file", "tree"], ORDERS = ["prefix", "orderFile", "deploy", "config", "none"], PINS = ["first", "last"];
const ENABLES = ["ue4ssModsTxt", "dotPrefix"], MERGES = ["ini"], IMPORTERS = ["modengine2"];
const LOAD_ORDERS = ["prefixFolder", "ue4ssModsTxt", "deployOrder", "dependencies", "lml", "loaderConfig", "none"];
const SAME_PATH = ["warn", "block"];
const LOG_ACTIONS = ["disableMod", "disableFramework", "disableNewestMod"], SUMMARIES = ["smapi"];
const POLICIES = ["allowed", "storyOnly", "offlineOnly"], MODDED_LAUNCHES = ["same", "loader"], NOTICES = ["offline", "storyOnly"];
const LOADER_CONFIGS = ["me3"];
// The fix actions a framework may ask for: runtime installs and the components, never anything that changes the
// engine or the graphics (the app's ModFramework.componentAction).
const COMPONENT_ACTIONS = ["installVCRuntime", "installDotNet", "setUpDirectX12", ...COMPONENTS];

const isObject = (v) => v && typeof v === "object" && !Array.isArray(v);
const isBool = (v) => v == null || typeof v === "boolean";
const isText = (v, max = 200) => typeof v === "string" && v.length > 0 && v.length <= max && !/[\0\r\n]/.test(v);
const isHTTPS = (v) => { try { return isText(v, 500) && new URL(v).protocol === "https:"; } catch { return false; } };

/** A relative path inside an archive or a root: real names only, nothing that could leave it. */
export function safePath(path, { allowEmpty = false } = {}) {
  if (typeof path !== "string" || path.length > 300 || /[:\0]/.test(path) || /^[\\/]/.test(path)) return false;
  if (!path) return allowEmpty;
  return path.split(/[\\/]/).every((part) => part !== ".." && part !== ".");
}

/** A glob over an archive's paths (`*`, `?`, `**`, `{a,b}`, `a|b`): a safe path with the wildcards allowed. */
const isGlob = (v) => isText(v, 300) && safePath(v.replace(/[{}|,]/g, "x"));

/** A `root:relative/path` place a profile names (`ModPath` in the app); `{slot}`, `{name}` and `{next}` stand for
 *  parts the deployer fills in, and `*` is allowed in a name where the caller says so. */
export function isModPath(spec, { placeholders = false, wildcard = false } = {}) {
  if (typeof spec !== "string" || spec.length > 320) return false;
  const colon = spec.indexOf(":");
  if (colon < 0 || !ROOTS.includes(spec.slice(0, colon))) return false;
  let path = spec.slice(colon + 1);
  if (placeholders) path = path.replace(/\{(slot|name|next)\}/g, "x");
  if (wildcard) path = path.replace(/\*/g, "x");
  return !/[{}*?]/.test(path) && safePath(path, { allowEmpty: true });
}

/** Problems with a mods list, or [] when it can be published. Fields the app doesn't know are ignored, as the app
 *  ignores them; a value outside a closed list is a problem, as it would drop the entry in the app. */
export function checkMods(list) {
  if (!isObject(list) || list.version !== 1 || !Array.isArray(list.games)) return ["needs { version: 1, games: [...] }"];
  const problems = [];
  if (list.games.length > 500) problems.push("more than 500 games");
  const seen = new Set();
  list.games.forEach((g, i) => {
    const at = `games[${i}]`;
    if (!isObject(g)) { problems.push(`${at}: not an object`); return; }
    for (const id of [g.game, ...(Array.isArray(g.aliases) ? g.aliases : [])]) {
      if (typeof id !== "string" || !GAME.test(id)) problems.push(`${at}.game`);
      else if (seen.has(id)) problems.push(`${at}.game repeats ${id}`);
      else seen.add(id);
    }
    if (g.aliases != null && !Array.isArray(g.aliases)) problems.push(`${at}.aliases`);
    problems.push(...checkEntry(g, at));
  });
  return problems;
}

function checkEntry(g, at) {
  const p = [];
  const bad = (field) => p.push(`${at}.${field}`);
  const oneOf = (field, values) => { if (g[field] != null && !values.includes(g[field])) bad(field); };
  oneOf("status", STATUSES); oneOf("runtime", RUNTIMES);

  if (g.sources != null) {
    const s = g.sources;
    if (!isObject(s)) bad("sources");
    else {
      if (s.nexus != null && !(isObject(s.nexus) && NEXUS_DOMAIN.test(s.nexus.domain ?? ""))) bad("sources.nexus");
      if (s.modio != null && !(isObject(s.modio) && Number.isInteger(s.modio.gameID) && s.modio.gameID > 0)) bad("sources.modio");
      if (s.other != null && !(Array.isArray(s.other) && s.other.length <= 20 && s.other.every(isHTTPS))) bad("sources.other");
    }
  }

  const frameworks = Array.isArray(g.frameworks) ? g.frameworks : [];
  if (g.frameworks != null && (!Array.isArray(g.frameworks) || g.frameworks.length > 20)) bad("frameworks");
  const frameworkIDs = new Set(frameworks.filter((f) => isObject(f) && typeof f.id === "string").map((f) => f.id));
  const seenFrameworks = new Set();
  frameworks.forEach((f, j) => {
    const here = `${at}.frameworks[${j}]`;
    if (isObject(f) && typeof f.id === "string") { if (seenFrameworks.has(f.id)) p.push(`${here}.id repeats ${f.id}`); seenFrameworks.add(f.id); }
    p.push(...checkFramework(f, here, frameworkIDs));
  });

  const kinds = Array.isArray(g.kinds) ? g.kinds : [];
  if (g.kinds != null && (!Array.isArray(g.kinds) || g.kinds.length > 30)) bad("kinds");
  const kindIDs = new Set();
  kinds.forEach((k, j) => p.push(...checkKind(k, `${at}.kinds[${j}]`, frameworkIDs, kindIDs)));

  if (g.archive != null) p.push(...checkArchive(g.archive, `${at}.archive`));
  if (g.loadOrder != null) p.push(...checkLoadOrder(g.loadOrder, `${at}.loadOrder`, kindIDs));
  if (g.conflicts != null) p.push(...checkConflicts(g.conflicts, `${at}.conflicts`));
  if (g.logs != null) {
    if (!Array.isArray(g.logs) || g.logs.length > 20) bad("logs");
    else g.logs.forEach((l, j) => p.push(...checkLog(l, `${at}.logs[${j}]`, frameworkIDs)));
  }
  if (g.saves != null) {
    const ok = Array.isArray(g.saves) && g.saves.length <= 20
      && g.saves.every((s) => isObject(s) && SAVE_ROOTS.includes(s.root) && safePath(s.path) && !/\*/.test(s.path));
    if (!ok) bad("saves");
  }
  if (g.online != null) p.push(...checkOnline(g.online, `${at}.online`, frameworks));
  if (g.notes != null) {
    const n = g.notes;
    if (!isObject(n)) bad("notes");
    else {
      if (n.gameVersionFile != null && !isModPath(n.gameVersionFile)) bad("notes.gameVersionFile");
      if (n.untouched != null && !(Array.isArray(n.untouched) && n.untouched.every((u) => isModPath(u, { wildcard: true })))) bad("notes.untouched");
      if (!isBool(n.cleanupOnLastCodeMod)) bad("notes.cleanupOnLastCodeMod");
    }
  }
  return p;
}

function checkFramework(f, at, ids) {
  const p = [];
  const bad = (field) => p.push(`${at}.${field}`);
  if (!isObject(f)) return [`${at}: not an object`];
  if (typeof f.id !== "string" || !ID.test(f.id)) bad("id");
  if (!isText(f.name, 80)) bad("name");
  if (f.license != null && !isText(f.license, 80)) bad("license");
  if (!isBool(f.code) || !isBool(f.optional)) bad("code");
  p.push(...checkDownload(f.download, `${at}.download`, ids, f.id));
  if (f.pick != null) {
    const ok = Array.isArray(f.pick) && f.pick.length <= 40 && f.pick.every((k) => isObject(k) && isGlob(k.match) && isModPath(k.to)
      && (k.stripTo == null || safePath(k.stripTo)) && isBool(k.unpack));
    if (!ok) bad("pick");
  }
  if (f.remove != null && !(Array.isArray(f.remove) && f.remove.every((r) => isModPath(r)))) bad("remove");
  if (f.skip != null && !(Array.isArray(f.skip) && f.skip.every((s) => safePath(s)))) bad("skip");
  if (f.copyAs != null && !(Array.isArray(f.copyAs) && f.copyAs.every((c) => isObject(c) && isModPath(c.from) && isModPath(c.to)))) bad("copyAs");
  if (f.settings != null) {
    const ok = Array.isArray(f.settings) && f.settings.length <= 20 && f.settings.every((s) => isObject(s) && isModPath(s.file)
      && SETTINGS_FORMATS.includes(s.format) && isObject(s.set) && Object.keys(s.set).length > 0 && Object.keys(s.set).length <= 50
      && Object.entries(s.set).every(([k, v]) => isText(k, 120) && isSettingValue(v, 1)));
    if (!ok) bad("settings");
  }
  if (f.dllOverrides != null) {
    const ok = isObject(f.dllOverrides) && Object.keys(f.dllOverrides).length <= 10
      && Object.entries(f.dllOverrides).every(([dll, mode]) => DLL.test(dll) && OVERRIDE_MODES.includes(mode));
    if (!ok) bad("dllOverrides");
  }
  if (f.components != null && !(Array.isArray(f.components) && f.components.every((c) => COMPONENT_ACTIONS.includes(c)))) bad("components");
  if (f.launch != null) p.push(...checkLaunch(f.launch, `${at}.launch`));
  if (f.disableArgument != null && !(isText(f.disableArgument, 200) && /^-{1,2}[A-Za-z]/.test(f.disableArgument))) bad("disableArgument");
  if (f.requires != null && !(Array.isArray(f.requires) && f.requires.every((r) => ids.has(r) && r !== f.id))) bad("requires");
  return p;
}

/** A download's source, complete for its kind, with the hash the app checks before unpacking. A download that
 *  comes through the embedded browser needs one too: the app installs nothing without it, so a list
 *  without it would offer a loader that can never go in. */
function checkDownload(d, at, ids, own) {
  if (!isObject(d) || !DOWNLOADS.includes(d.kind)) return [`${at}.kind`];
  const p = [];
  switch (d.kind) {
    case "github":
      if (!(typeof d.repo === "string" && REPO.test(d.repo) && FILE_NAME.test(d.asset ?? "") && (d.tag == null || isText(d.tag, 80)))) p.push(`${at}: github needs repo and asset`);
      break;
    case "url":
      if (!(isHTTPS(d.url) && isGlob(d.file ?? ""))) p.push(`${at}: url needs an https url and a file`);
      break;
    case "nexus":
      if (!(NEXUS_DOMAIN.test(d.domain ?? "") && Number.isInteger(d.mod) && d.mod > 0)) p.push(`${at}: nexus needs domain and mod`);
      break;
    case "inner":
      if (!(typeof d.of === "string" && ids.has(d.of) && d.of !== own && safePath(d.path))) p.push(`${at}: inner needs another framework (of) and a path`);
      break;
  }
  if (!isBool(d.viaBrowser)) p.push(`${at}.viaBrowser`);
  if (d.sha256 != null && !(typeof d.sha256 === "string" && SHA256.test(d.sha256))) p.push(`${at}.sha256`);
  else if (d.sha256 == null) p.push(`${at}.sha256 missing (every download is checked against it)`);
  return p;
}

function isSettingValue(v, depth) {
  if (typeof v === "string") return v.length <= 500 && !/[\0\r\n]/.test(v);
  if (typeof v === "boolean" || (typeof v === "number" && Number.isFinite(v))) return true;
  return depth > 0 && isObject(v) && Object.keys(v).length <= 50 && Object.entries(v).every(([k, x]) => isText(k, 120) && isSettingValue(x, depth - 1));
}

function checkLaunch(l, at) {
  if (!isObject(l)) return [`${at}: redirect, loader or arguments`];
  const p = [];
  if (l.redirect != null && !(isObject(l.redirect) && FILE_NAME.test(l.redirect.instead ?? "") && FILE_NAME.test(l.redirect.run ?? ""))) p.push(`${at}.redirect`);
  if (l.loader != null) {
    const ok = isObject(l.loader) && isModPath(l.loader.exe) && !l.loader.exe.endsWith("/")
      && (l.loader.args == null || (Array.isArray(l.loader.args) && l.loader.args.length <= 40 && l.loader.args.every((a) => isText(a, 300))))
      && (l.loader.config == null || LOADER_CONFIGS.includes(l.loader.config)) && isBool(l.loader.steamInBottle);
    if (!ok) p.push(`${at}.loader`);
  }
  if (l.arguments != null && !(Array.isArray(l.arguments) && l.arguments.length <= 20 && l.arguments.every((a) => isText(a, 200)))) p.push(`${at}.arguments`);
  return p;
}

function checkKind(k, at, frameworkIDs, kindIDs) {
  const p = [];
  const bad = (field) => p.push(`${at}.${field}`);
  if (!isObject(k)) return [`${at}: not an object`];
  if (typeof k.id !== "string" || !ID.test(k.id)) bad("id");
  else if (kindIDs.has(k.id)) p.push(`${at}.id repeats ${k.id}`);
  else kindIDs.add(k.id);
  if (!isBool(k.code)) bad("code");
  if (k.codeIf != null && !(typeof k.codeIf === "string" && MANIFEST_FIELD.test(k.codeIf))) bad("codeIf");
  if (k.framework != null && !frameworkIDs.has(k.framework)) bad("framework");
  if (!UNITS.includes(k.unit)) bad("unit");
  if (!isGlob(k.match)) bad("match");
  if (k.marker != null && !safePath(k.marker)) bad("marker");
  if (k.stripTo != null && !safePath(k.stripTo)) bad("stripTo");
  if (k.stripToParentOf != null && !isGlob(k.stripToParentOf)) bad("stripToParentOf");
  if (!isModPath(k.to, { placeholders: true })) bad("to");
  if (!isBool(k.siblings) || !isBool(k.backupOriginal) || !isBool(k.ask)) bad("flags");
  if (k.order != null && !ORDERS.includes(k.order)) bad("order");
  if (k.pinned != null && !PINS.includes(k.pinned)) bad("pinned");
  if (k.enable != null) {
    const ok = isObject(k.enable) && ENABLES.includes(k.enable.format)
      && (k.enable.format === "ue4ssModsTxt" ? isModPath(k.enable.file) && !k.enable.file.endsWith("/") : k.enable.file == null || isModPath(k.enable.file));
    if (!ok) bad("enable");
  }
  if (k.keepOnUpdate != null && !(Array.isArray(k.keepOnUpdate) && k.keepOnUpdate.every((f) => safePath(f)))) bad("keepOnUpdate");
  if (k.merge != null && !MERGES.includes(k.merge)) bad("merge");
  if (k.importer != null && !IMPORTERS.includes(k.importer)) bad("importer");
  if (k.unit === "folder" && k.marker == null) bad("marker (a folder is found by one)");
  if (k.unit === "tree" && k.stripTo == null && k.stripToParentOf == null) bad("stripTo (a tree starts at one)");
  return p;
}

function checkArchive(a, at) {
  if (!isObject(a)) return [at];
  const p = [];
  const bad = (field) => p.push(`${at}.${field}`);
  if (a.variants != null && !FILE_NAME.test(a.variants)) bad("variants");
  if (!isBool(a.wrappers)) bad("wrappers");
  if (a.ignore != null && !(Array.isArray(a.ignore) && a.ignore.every(isGlob))) bad("ignore");
  if (a.deny != null && !(Array.isArray(a.deny) && a.deny.every(isGlob))) bad("deny");
  if (a.reject != null) {
    const ok = Array.isArray(a.reject) && a.reject.every((r) => isObject(r) && isGlob(r.match) && KEY.test(r.reason ?? "")
      && (r.unlessNearby == null || FILE_NAME.test(r.unlessNearby)) && isBool(r.onlyFile));
    if (!ok) bad("reject");
  }
  return p;
}

function checkLoadOrder(o, at, kindIDs) {
  if (!isObject(o)) return [at];
  const p = [];
  const bad = (field) => p.push(`${at}.${field}`);
  if (o.format != null && !LOAD_ORDERS.includes(o.format)) bad("format");
  if (!isBool(o.reverse)) bad("reverse");
  for (const field of ["pinFirst", "pinLast"]) {
    if (o[field] != null && !(Array.isArray(o[field]) && o[field].every((n) => isText(n, 120)))) bad(field);
  }
  if (o.pinLastGroups != null && !(Array.isArray(o.pinLastGroups) && o.pinLastGroups.every((k) => kindIDs.has(k)))) bad("pinLastGroups");
  if (o.file != null && !(isModPath(o.file) && !o.file.endsWith("/"))) bad("file");
  if (o.config != null && !LOADER_CONFIGS.includes(o.config)) bad("config");
  if ((o.format === "lml" || o.format === "loaderConfig") && o.file == null) bad("file (this format writes one)");
  return p;
}

function checkConflicts(c, at) {
  if (!isObject(c)) return [at];
  const p = [];
  const bad = (field) => p.push(`${at}.${field}`);
  if (c.samePath != null && !SAME_PATH.includes(c.samePath)) bad("samePath");
  if (c.rules != null) {
    const ok = Array.isArray(c.rules) && c.rules.length <= 20 && c.rules.every((r) => isObject(r)
      && ((r.match != null) !== (r.field != null))                                  // by file name or by manifest field, not both
      && (r.match == null || isGlob(r.match)) && (r.field == null || MANIFEST_FIELD.test(r.field))
      && (r.max == null || (Number.isInteger(r.max) && r.max >= 1)) && isBool(r.sameStem) && (r.max != null || r.sameStem === true)
      && KEY.test(r.reason ?? "") && (r.hint == null || KEY.test(r.hint)));
    if (!ok) bad("rules");
  }
  if (c.needs != null && !(isObject(c.needs) && MANIFEST_FIELD.test(c.needs.field ?? "") && KEY.test(c.needs.label ?? ""))) bad("needs");
  return p;
}

function checkLog(l, at, frameworkIDs) {
  if (!isObject(l)) return [at];
  const p = [];
  const bad = (field) => p.push(`${at}.${field}`);
  if (!isModPath(l.file, { wildcard: true }) || l.file.endsWith("/")) bad("file");
  if (l.altFile != null && !isModPath(l.altFile, { wildcard: true })) bad("altFile");
  if (l.rules != null) {
    if (!Array.isArray(l.rules) || l.rules.length > 20) bad("rules");
    else l.rules.forEach((r, j) => {
      const here = `${at}.rules[${j}]`;
      if (!isObject(r) || !isText(r.pattern, 500)) { p.push(`${here}.pattern`); return; }
      if (!LOG_ACTIONS.includes(r.action)) p.push(`${here}.action`);
      if (r.action === "disableMod" && !(Number.isInteger(r.modFrom) && r.modFrom >= 1 && r.modFrom <= 9)) p.push(`${here}.modFrom`);
      if (r.action === "disableFramework" && !frameworkIDs.has(r.framework)) p.push(`${here}.framework`);
      if (!isBool(r.byUniqueID)) p.push(`${here}.byUniqueID`);
    });
  }
  if (l.exists != null && !(isObject(l.exists) && LOG_ACTIONS.includes(l.exists.action) && l.exists.action !== "disableMod")) bad("exists");
  if (l.summary != null && !SUMMARIES.includes(l.summary)) bad("summary");
  return p;
}

function checkOnline(o, at, frameworks) {
  if (!isObject(o)) return [at];
  const p = [];
  const bad = (field) => p.push(`${at}.${field}`);
  if (o.policy != null && !POLICIES.includes(o.policy)) bad("policy");
  if (o.antiCheat != null && !isText(o.antiCheat, 20)) bad("antiCheat");
  if (o.moddedLaunch != null && !MODDED_LAUNCHES.includes(o.moddedLaunch)) bad("moddedLaunch");
  const hasLoader = frameworks.some((f) => isObject(f) && isObject(f.launch) && f.launch.loader != null);
  if (o.moddedLaunch === "loader" && !hasLoader) bad("moddedLaunch: no framework has a loader");
  if (o.policy === "offlineOnly" && o.antiCheat != null && o.moddedLaunch !== "loader") bad("moddedLaunch: offline-only play with an anti-cheat goes through a loader");
  if (o.separateSave != null) {
    const s = o.separateSave;
    if (!(isObject(s) && isBool(s.default) && (s.via == null || LOAD_ORDERS.includes(s.via)) && (s.file == null || FILE_NAME.test(s.file)))) bad("separateSave");
  }
  for (const field of ["cleanBeforeVanilla", "playWithoutModsRemoves"]) {
    if (o[field] != null && !(Array.isArray(o[field]) && o[field].length <= 40 && o[field].every((s) => isModPath(s, { wildcard: true })))) bad(field);
  }
  if (o.noticeKey != null && !NOTICES.includes(o.noticeKey)) bad("noticeKey");
  return p;
}

// MARK: mod.io

// The app reads a game's mod.io catalogue through here (GET /v1/mods/modio/{gameID}/mods…), so the key stays on
// the server: mod.io gives one key per account with a shared minute limit, enough for the first thousands of
// players with answers kept ten minutes. Only the games whose published profile names a mod.io id are served,
// so the key can't be used to read anything else. The app downloads a file itself from the link mod.io gives
// (`binary_url`, signed and short-lived); nothing is re-uploaded.
export const MODIO_API = "https://api.mod.io/v1";
const MODIO_TTL = 600_000;
const MODIO_CACHE_ENTRIES = 1000;
const MODIO_PARAM = /^[a-z_][a-z0-9_-]{0,40}$/;
const NUMBER = /^\d{1,12}$/;

/** What may be asked of mod.io, as the path after `/v1/mods/modio/{gameID}/`: the catalogue, one mod, its files
 *  and one file (whose answer carries the download link). Anything else is not found. */
export function modioPath(gameID, rest) {
  if (!NUMBER.test(gameID)) return null;
  const base = `/games/${gameID}/mods`;
  if (rest.length === 1 && rest[0] === "mods") return base;
  if (rest[0] !== "mods" || !NUMBER.test(rest[1] ?? "")) return null;
  if (rest.length === 2) return `${base}/${rest[1]}`;
  if (rest[2] !== "files") return null;
  if (rest.length === 3) return `${base}/${rest[1]}/files`;
  if (rest.length === 4 && NUMBER.test(rest[3])) return `${base}/${rest[1]}/files/${rest[3]}`;
  return null;
}

/** The mod.io game ids the published list names. */
export async function modioGames(env) {
  const object = await env.RELEASES.get("mods.json");
  if (!object) return new Set();
  let list;
  try { list = JSON.parse(await object.text()); } catch { return new Set(); }
  return new Set((list?.games ?? []).map((g) => g?.sources?.modio?.gameID).filter((id) => Number.isInteger(id)).map(String));
}

const cache = new Map();

/**
 * Answers one catalogue request from the cache or from mod.io. `params` are the app's query parameters, passed on
 * when they look like mod.io's own (`_q`, `_limit`, `_sort`, `tags-in`…); the key is never one of them. The answer
 * is mod.io's JSON as it came, with its status; a failure upstream is a 502 without its body.
 */
export async function modioProxy(env, gameID, rest, params, now, { fetchImpl = fetch, store = cache, games = modioGames } = {}) {
  if (!env.MODIO_API_KEY) return { status: 503, body: { error: "mod.io not configured" } };
  const path = modioPath(gameID, rest);
  if (!path) return { status: 404, body: { error: "not found" } };
  if (!(await games(env)).has(gameID)) return { status: 404, body: { error: "no mod.io catalogue for this game" } };
  const query = new URLSearchParams();
  for (const [key, value] of [...params.entries()].slice(0, 12)) {
    if (MODIO_PARAM.test(key) && key !== "api_key" && typeof value === "string" && value.length <= 200) query.set(key, value);
  }
  query.sort();
  const key = `${path}?${query}`;
  const hit = store.get(key);
  if (hit && hit.expires > now) return { status: hit.status, body: hit.body, cached: true };
  query.set("api_key", env.MODIO_API_KEY);
  let response;
  try {
    response = await fetchImpl(`${MODIO_API}${path}?${query}`, { headers: { Accept: "application/json", "User-Agent": "Sommelier (api.playsommelier.com)" } });
  } catch {
    return { status: 502, body: { error: "mod.io didn't answer" } };
  }
  if (response.status === 404) return { status: 404, body: { error: "not found" } };
  if (response.status !== 200) return { status: 502, body: { error: `mod.io answered ${response.status}` } };
  let body;
  try { body = await response.json(); } catch { return { status: 502, body: { error: "mod.io answered with no JSON" } }; }
  if (store.size >= MODIO_CACHE_ENTRIES) store.delete(store.keys().next().value);
  store.set(key, { status: 200, body, expires: now + MODIO_TTL });
  return { status: 200, body, cached: false };
}
