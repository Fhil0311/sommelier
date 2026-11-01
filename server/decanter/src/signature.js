// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
// Lists and shader packs that change what runs on players' Macs are signed on the owner's Mac with the key that
// signs app updates (Ed25519; scripts/update-signing-key.swift sign). The service keeps the signature with what it
// stores and hands it on in X-Sommelier-Signature; the app checks it. The service checks it too before storing,
// so a stolen owner's token alone can't publish anything apps would take.

export const SIGNATURE_HEADER = "X-Sommelier-Signature";

/** Whether `signature` (base64) is the owner's key's signature of `bytes`. Local development (no ENVIRONMENT and no
 *  key) takes anything; a deployed service without its LIST_PUBLIC_KEY takes nothing. */
export async function signedByOwner(env, bytes, signature) {
  const key = env.LIST_PUBLIC_KEY;
  if (!key) return !env.ENVIRONMENT;
  if (!signature) return false;
  try {
    const publicKey = await crypto.subtle.importKey("raw", fromBase64(key), { name: "Ed25519" }, false, ["verify"]);
    return await crypto.subtle.verify({ name: "Ed25519" }, publicKey, fromBase64(signature), bytes);
  } catch {
    return false;
  }
}

function fromBase64(text) {
  return Uint8Array.from(atob(String(text).trim()), (c) => c.charCodeAt(0));
}
