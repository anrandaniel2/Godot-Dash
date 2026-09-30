// Self-test for tools/web_relay_worker.js — run with: node tools/web_relay_worker_selftest.mjs
//
// The Worker is the only piece of the Web build that cannot be exercised by the
// Godot export itself, so its request translation is checked here: preflight,
// GET relay, RobTop POST (form body kept, User-Agent cleared), path-style
// targets, the 400/403 refusals, and the 502 on an unreachable host. Upstream
// fetch is stubbed; no network access is needed.
import assert from "node:assert";
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const workerSource = join(here, "web_relay_worker.js");
const tempModule = join(process.env.TMPDIR ?? "/tmp", "web_relay_worker_under_test.mjs");
// Copy with an .mjs name so Node parses the Worker's `export default`.
writeFileSync(tempModule, readFileSync(workerSource));

const calls = [];
globalThis.fetch = async (input, init = {}) => {
  calls.push({
    url: String(input),
    method: init.method,
    headers: Object.fromEntries(new Headers(init.headers ?? {}).entries()),
    body: init.body ? Buffer.from(init.body).toString() : null,
  });
  return new Response("LEVELDATA#hash #a #b", { status: 200, headers: { "Content-Type": "text/plain" } });
};

const { default: worker } = await import(`file://${tempModule}`);
const base = "https://relay.example.com";
const target = "https://history.geometrydash.eu/api/v1/level/128/";
const encoded = encodeURIComponent(target);

// 1. Preflight.
let response = await worker.fetch(new Request(`${base}/?url=${encoded}`, { method: "OPTIONS" }));
assert.strictEqual(response.status, 204);
assert.strictEqual(response.headers.get("Access-Control-Allow-Origin"), "*");

// 2. GET relay keeps the body and the status, and adds CORS headers.
response = await worker.fetch(new Request(`${base}/?url=${encoded}`));
assert.strictEqual(response.status, 200);
assert.strictEqual(await response.text(), "LEVELDATA#hash #a #b");
assert.strictEqual(response.headers.get("Access-Control-Allow-Origin"), "*");
assert.strictEqual(response.headers.get("Content-Type"), "text/plain");
assert.strictEqual(calls.at(-1).url, target);
assert.strictEqual(calls.at(-1).method, "GET");
assert.strictEqual(calls.at(-1).headers["user-agent"], "Godot-Dash-Web/1.0");

// 3. RobTop POST: form body preserved, User-Agent cleared (RobTop rejects
//    requests that look like a browser).
const postTarget = "https://www.boomlings.com/database/downloadGJLevel22.php";
response = await worker.fetch(new Request(`${base}/?url=${encodeURIComponent(postTarget)}`, {
  method: "POST",
  headers: { "Content-Type": "application/x-www-form-urlencoded" },
  body: "levelID=128&secret=Wmfd2893gb7",
}));
assert.strictEqual(response.status, 200);
assert.strictEqual(calls.at(-1).url, postTarget);
assert.strictEqual(calls.at(-1).method, "POST");
assert.strictEqual(calls.at(-1).headers["user-agent"], "");
assert.strictEqual(calls.at(-1).headers["content-type"], "application/x-www-form-urlencoded");
assert.strictEqual(calls.at(-1).body, "levelID=128&secret=Wmfd2893gb7");

// 4. Path-style target (serve_web.py compatibility).
response = await worker.fetch(new Request(`${base}/cors-proxy/${target}`));
assert.strictEqual(response.status, 200);
assert.strictEqual(calls.at(-1).url, target);

// 5. Refusals.
assert.strictEqual((await worker.fetch(new Request(`${base}/`))).status, 400);
assert.strictEqual((await worker.fetch(new Request(`${base}/?url=not-a-url`))).status, 400);
assert.strictEqual(
  (await worker.fetch(new Request(`${base}/?url=${encodeURIComponent("https://example.com/")}`))).status,
  403,
);
assert.strictEqual(
  (await worker.fetch(new Request(`${base}/?url=${encodeURIComponent("ftp://www.boomlings.com/")}`))).status,
  400,
);

// 6. An unreachable upstream surfaces as 502 instead of an exception.
const workingFetch = globalThis.fetch;
globalThis.fetch = async () => {
  throw new Error("boom");
};
response = await worker.fetch(new Request(`${base}/?url=${encoded}`));
assert.strictEqual(response.status, 502);
globalThis.fetch = workingFetch;

console.log("web_relay_worker self-test: all checks passed");
