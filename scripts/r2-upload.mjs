// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
// Uploads a file to Cloudflare R2 in parts, through R2's S3 API: for files wrangler won't take (over 300 MB, an
// engine archive). The key comes from ~/.sommelier/r2.env (R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, R2_ENDPOINT):
// an "Account API token" with Object Read & Write, made in Cloudflare's R2 settings. Never in the repository.
//
//   node scripts/r2-upload.mjs <bucket> <key> <file> [content-type]
import { createHash, createHmac } from "node:crypto";
import { openSync, readSync, fstatSync, readFileSync, closeSync } from "node:fs";
import { homedir } from "node:os";

const [bucket, key, file, type = "application/octet-stream"] = process.argv.slice(2);
if (!bucket || !key || !file) { console.error("r2-upload.mjs <bucket> <key> <file> [content-type]"); process.exit(1); }
const env = Object.fromEntries(readFileSync(`${homedir()}/.sommelier/r2.env`, "utf8").split("\n")
  .map((l) => l.trim()).filter((l) => l && !l.startsWith("#") && l.includes("=")).map((l) => [l.slice(0, l.indexOf("=")), l.slice(l.indexOf("=") + 1)]));
const { R2_ACCESS_KEY_ID: id, R2_SECRET_ACCESS_KEY: secret, R2_ENDPOINT: endpoint } = env;
if (!id || !secret || !/^https:\/\/[a-z0-9]+\.r2\.cloudflarestorage\.com\/?$/.test(endpoint ?? "")) {
  console.error("~/.sommelier/r2.env needs R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY and R2_ENDPOINT (https://<account>.r2.cloudflarestorage.com)");
  process.exit(1);
}
const host = new URL(endpoint).host;
const sha = (data) => createHash("sha256").update(data).digest("hex");
const hmac = (k, data) => createHmac("sha256", k).update(data).digest();
const path = `/${bucket}/${key.split("/").map(encodeURIComponent).join("/")}`;

/** One S3 request signed with AWS Signature V4 (R2's region is "auto"). */
async function s3(method, query, body = null, headers = {}) {
  const now = new Date().toISOString().replace(/[:-]|\.\d{3}/g, "");
  const day = now.slice(0, 8);
  const payload = body ? sha(body) : sha("");
  const all = { host, "x-amz-content-sha256": payload, "x-amz-date": now, ...headers };
  const names = Object.keys(all).map((n) => n.toLowerCase()).sort();
  const canonicalHeaders = names.map((n) => `${n}:${String(all[Object.keys(all).find((k) => k.toLowerCase() === n)]).trim()}\n`).join("");
  const canonical = [method, path, query, canonicalHeaders, names.join(";"), payload].join("\n");
  const scope = `${day}/auto/s3/aws4_request`;
  const toSign = ["AWS4-HMAC-SHA256", now, scope, sha(canonical)].join("\n");
  const signingKey = hmac(hmac(hmac(hmac(`AWS4${secret}`, day), "auto"), "s3"), "aws4_request");
  const signature = createHmac("sha256", signingKey).update(toSign).digest("hex");
  const response = await fetch(`https://${host}${path}${query ? `?${query}` : ""}`, {
    method, body, headers: { ...all, Authorization: `AWS4-HMAC-SHA256 Credential=${id}/${scope}, SignedHeaders=${names.join(";")}, Signature=${signature}` },
  });
  const text = await response.text();
  if (!response.ok) throw new Error(`${method} ${response.status}: ${text.slice(0, 300)}`);
  return { text, etag: response.headers.get("etag") };
}

const PART = 50 * 1024 * 1024;
const fd = openSync(file, "r");
const size = fstatSync(fd).size;
const upload = /<UploadId>([^<]+)<\/UploadId>/.exec((await s3("POST", "uploads=", null, { "content-type": type })).text)?.[1];
if (!upload) throw new Error("no upload id");
const parts = [];
try {
  for (let offset = 0, n = 1; offset < size; offset += PART, n += 1) {
    const chunk = Buffer.alloc(Math.min(PART, size - offset));
    readSync(fd, chunk, 0, chunk.length, offset);
    const { etag } = await s3("PUT", `partNumber=${n}&uploadId=${encodeURIComponent(upload)}`, chunk);
    parts.push(`<Part><PartNumber>${n}</PartNumber><ETag>${etag}</ETag></Part>`);
    process.stdout.write(`\r  ${Math.round(((offset + chunk.length) / size) * 100)}%`);
  }
  await s3("POST", `uploadId=${encodeURIComponent(upload)}`, `<CompleteMultipartUpload>${parts.join("")}</CompleteMultipartUpload>`);
  console.log(`\n  ${key}: ${size} bytes`);
} catch (error) {
  await s3("DELETE", `uploadId=${encodeURIComponent(upload)}`).catch(() => {});
  throw error;
} finally {
  closeSync(fd);
}
