// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
// The cellar: Metal binary archives of a game's pipelines, built ahead of time by Sommelier's builder for each
// macOS major version and Apple GPU architecture. Sommelier downloads the one for the player's Mac before the
// game's first run; DXMT takes pipelines from it instead of compiling them. Only the builder may upload.
export const OS = /^\d{2}$/;                       // macOS major version: "15", "26"
export const ARCH = /^applegpu_g\d{2}[a-z]$/;      // Metal's architecture name: "applegpu_g16s" (M4 Pro)
export const MAX_ARCHIVE = 100 * 1024 * 1024;       // a Worker request body; bigger archives come in parts later

export function archiveKey(store, game, exe, os, arch) { return `cellar/${store}/${game}/${exe}/${os}/${arch}`; }
export function manifestKey(store, game) { return `cellar-manifest/${store}/${game}`; }

/** The manifest with one archive's entry replaced or added. */
export function withArchive(manifest, entry) {
  const archives = (manifest?.archives ?? []).filter((a) => !(a.exe === entry.exe && a.os === entry.os && a.arch === entry.arch));
  archives.push({ ...entry, updated: new Date().toISOString() });
  archives.sort((a, b) => a.exe.localeCompare(b.exe) || a.os.localeCompare(b.os) || a.arch.localeCompare(b.arch));
  return { archives };
}

/** Whether a request may upload: the builder's bearer token, set as the Worker secret CELLAR_TOKEN. */
export function mayUpload(request, env) {
  const token = env.CELLAR_TOKEN;
  return Boolean(token) && request.headers.get("Authorization") === `Bearer ${token}`;
}
