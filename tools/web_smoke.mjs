// Opens the exported web game in headless Chrome, lets it run, and reports
// every page error and console error. Run from a directory where puppeteer-core
// is installed (the workflow copies this file there).
// usage: node web_smoke.mjs <url> [seconds]
import puppeteer from "puppeteer-core";

const url = process.argv[2];
const seconds = Number(process.argv[3] ?? 90);
const problems = new Map();
const note = (kind, text) => {
  const key = `${kind}: ${String(text).replace(/\s+/g, " ")}`.slice(0, 1500);
  problems.set(key, (problems.get(key) ?? 0) + 1);
};

const browser = await puppeteer.launch({
  executablePath: process.env.CHROME_BIN || "/usr/bin/google-chrome",
  headless: true,
  args: [
    "--no-sandbox",
    "--use-angle=swiftshader",
    "--enable-unsafe-swiftshader",
    "--ignore-gpu-blocklist",
    "--enable-unsafe-webgpu",
    "--autoplay-policy=no-user-gesture-required",
  ],
});
try {
  const page = await browser.newPage();
  await page.setViewport({ width: 1280, height: 720 });
  page.on("pageerror", (e) => note("pageerror", `${e.message} | ${(e.stack ?? "").split("\n").slice(1, 4).join(" / ")}`));
  // Error objects arrive as handles; read their stacks, not just "JSHandle@error".
  page.on("console", async (m) => {
    if (m.type() !== "error") return;
    const parts = await Promise.all(
      m.args().map((arg) =>
        arg.evaluate((v) => (v instanceof Error ? v.stack || String(v) : typeof v === "string" ? v : JSON.stringify(v))).catch(() => "?"),
      ),
    );
    note("console.error", parts.join(" ") || m.text());
  });
  await page.evaluateOnNewDocument(() => {
    window.__smokeErrors = [];
    window.addEventListener("error", (e) => window.__smokeErrors.push("error: " + (e.error?.stack ?? e.message)));
    window.addEventListener("unhandledrejection", (e) => window.__smokeErrors.push("rejection: " + (e.reason?.stack ?? e.reason)));
  });
  page.on("requestfailed", (r) => note("requestfailed", r.url()));
  await page.goto(url, { waitUntil: "load", timeout: 180000 }).catch((e) => note("goto", e.message));
  await new Promise((resolve) => setTimeout(resolve, seconds * 1000));
  const info = await page.evaluate(() => ({
    canvas: document.querySelectorAll("canvas").length,
    notice: document.querySelector("#status-notice")?.textContent ?? "",
    status: document.querySelector("#status")?.textContent ?? "",
  }));
  console.log(`SMOKE canvases=${info.canvas} notice=${JSON.stringify(info.notice).slice(0, 300)} status=${JSON.stringify(info.status).slice(0, 120)}`);
  if (info.notice.trim()) note("page-notice", info.notice);
  for (const entry of await page.evaluate(() => window.__smokeErrors ?? [])) note("hooked", entry);
} finally {
  await browser.close();
}
for (const [key, count] of problems) console.log(`SMOKE x${count} ${key}`);
console.log(`SMOKE problems=${problems.size}`);
