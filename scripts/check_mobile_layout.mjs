#!/usr/bin/env node
// Mobile layout check: loads every staged HTML page in headless Chrome at phone widths and fails if
// a page scrolls sideways or the home hero's text is drawn over the logo.
//
//   python3 scripts/stage_pages.py            # build _site/
//   python3 -m http.server 8000 -d _site &     # serve it
//   node scripts/check_mobile_layout.mjs _site http://127.0.0.1:8000
//
// No npm packages: it talks to Chrome over the DevTools Protocol with Node's built-in WebSocket.
import { spawn } from "node:child_process";
import { existsSync, mkdtempSync, readdirSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, relative, sep } from "node:path";

const [siteDir = "_site", base = "http://127.0.0.1:8000"] = process.argv.slice(2);
const WIDTHS = (process.env.WIDTHS || "320,375,430").split(",").map(Number);
const PORT = 9300 + Math.floor(Math.random() * 500);
const CHROME = process.env.CHROME || [
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
  "/usr/bin/google-chrome", "/usr/bin/google-chrome-stable", "/usr/bin/chromium", "/usr/bin/chromium-browser",
].find((path) => existsSync(path));
if (!CHROME) { console.error("Chrome was not found; set CHROME=/path/to/chrome"); process.exit(2); }

function htmlPages(dir) {
  const out = [];
  for (const name of readdirSync(dir)) {
    const path = join(dir, name);
    if (statSync(path).isDirectory()) out.push(...htmlPages(path));
    else if (name.endsWith(".html")) out.push(relative(siteDir, path).split(sep).join("/"));
  }
  return out.sort();
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const chrome = spawn(CHROME, ["--headless=new", `--remote-debugging-port=${PORT}`, "--no-first-run", "--no-default-browser-check",
  "--disable-gpu", "--hide-scrollbars", `--user-data-dir=${mkdtempSync(join(tmpdir(), "hc-layout-"))}`, "about:blank"], { stdio: "ignore" });

let socket; let nextId = 0; const waiting = new Map(); const events = [];
async function connect() {
  for (let attempt = 0; attempt < 100; attempt++) {
    try {
      const targets = await (await fetch(`http://127.0.0.1:${PORT}/json`)).json();
      const page = targets.find((target) => target.type === "page");
      if (page) { socket = new WebSocket(page.webSocketDebuggerUrl); break; }
    } catch { /* Chrome is still starting */ }
    await sleep(100);
  }
  if (!socket) throw new Error("Could not connect to Chrome");
  await new Promise((resolve, reject) => { socket.onopen = resolve; socket.onerror = reject; });
  socket.onmessage = (message) => {
    const data = JSON.parse(message.data);
    if (data.id && waiting.has(data.id)) { waiting.get(data.id)(data); waiting.delete(data.id); }
    else if (data.method) events.push(data.method);
  };
}
const send = (method, params = {}) => new Promise((resolve) => {
  const id = ++nextId; waiting.set(id, resolve); socket.send(JSON.stringify({ id, method, params }));
});
async function evaluate(expression) {
  const { result } = await send("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true });
  return result?.result?.value;
}
async function load(url) {
  events.length = 0;
  await send("Page.navigate", { url });
  for (let i = 0; i < 100 && !events.includes("Page.loadEventFired"); i++) await sleep(50);
  await evaluate("document.fonts ? document.fonts.ready.then(() => true) : true");
  await sleep(150);
}

const MEASURE = `(() => {
  const width = document.documentElement.clientWidth;
  const overflow = document.documentElement.scrollWidth - width;
  const culprits = [];
  if (overflow > 0) {
    for (const el of document.body.querySelectorAll("*")) {
      const r = el.getBoundingClientRect();
      if (r.width && r.right > width + 1) culprits.push(el.id ? "#" + el.id : el.tagName.toLowerCase() + (el.className && typeof el.className === "string" ? "." + el.className.trim().split(/\\s+/).join(".") : ""));
      if (culprits.length >= 5) break;
    }
  }
  let heroOverlap = [];
  const art = document.querySelector(".hero-art");
  if (art) {
    const a = art.getBoundingClientRect();
    for (const el of document.querySelectorAll(".hero-copy *")) {
      if (![...el.childNodes].some((n) => n.nodeType === 3 && n.textContent.trim())) continue;
      const range = document.createRange(); range.selectNodeContents(el);
      for (const r of range.getClientRects()) {
        if (r.right > a.left + 8 && r.left < a.right - 8 && r.bottom > a.top + 8 && r.top < a.bottom - 8) heroOverlap.push(el.tagName.toLowerCase());
      }
    }
  }
  return { overflow, culprits, heroOverlap: [...new Set(heroOverlap)],
           viewport: (document.querySelector('meta[name="viewport"]') || {}).content || "" };
})()`;

const failures = [];
try {
  await connect();
  await send("Page.enable");
  const pages = htmlPages(siteDir);
  for (const width of WIDTHS) {
    await send("Emulation.setDeviceMetricsOverride", { width, height: 900, deviceScaleFactor: 1, mobile: true });
    for (const page of pages) {
      await load(`${base}/${page}`);
      const result = await evaluate(MEASURE);
      if (!result) { failures.push(`${width}px ${page}: page did not load`); continue; }
      if (!/width=device-width/.test(result.viewport)) failures.push(`${width}px ${page}: missing viewport meta tag`);
      if (result.overflow > 0) failures.push(`${width}px ${page}: scrolls sideways by ${result.overflow}px (${result.culprits.join(", ")})`);
      if (result.heroOverlap.length) failures.push(`${width}px ${page}: hero text overlaps the logo (${result.heroOverlap.join(", ")})`);
    }
  }
  console.log(`Checked ${pages.length} pages at ${WIDTHS.join(", ")}px.`);
} catch (error) {
  failures.push(`Layout check crashed: ${error.message}`);
} finally {
  chrome.kill();
}
if (failures.length) {
  console.error(`Mobile layout problems:\n  ${failures.join("\n  ")}`);
  process.exit(1);
}
console.log("No horizontal overflow and no hero overlap.");
