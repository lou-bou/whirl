// Records what the real server answers, so the phone app's fake server can be held to it.
//
//   cd mobile/whirl/tool && npm ci && node record_server.mjs
//
// Runs server/index.js unchanged, with the real `pg` driver, against a throwaway Postgres
// (PGlite: Postgres compiled to WebAssembly, reached over a local socket) made from Schema.sql.
// It then sends a scripted sequence of requests (creates, edits, replays, late edits, refusals,
// deletes, categories) and writes every request and answer to test/server_recording.json.
// test/fake_server_test.dart replays the same requests against the Dart fake server and
// expects identical answers. The release workflow re-records and stops if the file changed.
//
// Ids the server makes up (categories) become {cat:<name>}, timestamps <time> and serverTime
// <now>, so the file is the same on every run. Edit times are written relative to the moment
// of the request ({"$ago": ms} / {"$ahead": ms}).
import { spawn } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { createServer } from "node:net";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { PGlite } from "@electric-sql/pglite";
import { PGLiteSocketServer } from "@electric-sql/pglite-socket";

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, "../../..");
const out = path.join(here, "../test/server_recording.json");

async function freePort() {
  return new Promise((resolve) => {
    const s = createServer().listen(0, "127.0.0.1", () => {
      const { port } = s.address();
      s.close(() => resolve(port));
    });
  });
}

// ── A throwaway database from Schema.sql ─────────────────────────────────────
const db = await PGlite.create();
await db.exec(readFileSync(path.join(repo, "Schema.sql"), "utf8"));
const dbPort = await freePort();
const pgServer = new PGLiteSocketServer({ db, port: dbPort, host: "127.0.0.1", maxConnections: 10 });
await pgServer.start();

// ── The real server ─────────────────────────────────────────────────────────
const apiPort = await freePort();
const server = spawn(process.execPath, ["server/index.js"], {
  cwd: repo,
  env: {
    ...process.env,
    DATABASE_URL: `postgres://postgres@127.0.0.1:${dbPort}/postgres?sslmode=disable`,
    PORT: String(apiPort),
    HOST: "127.0.0.1",
  },
  stdio: ["ignore", "pipe", "inherit"],
});
await new Promise((resolve, reject) => {
  server.stdout.on("data", (d) => { if (String(d).includes("Whirl on")) resolve(); });
  server.on("exit", (code) => reject(new Error(`server exited with ${code}`)));
});

// ── The script ──────────────────────────────────────────────────────────────
const P1 = "11111111-1111-4111-8111-111111111111";
const P2 = "22222222-2222-4222-8222-222222222222";
const P3 = "33333333-3333-4333-8333-333333333333";
const P4 = "44444444-4444-4444-8444-444444444444";
const MISSING = "99999999-9999-4999-8999-999999999999";
const min = 60_000;
const ago = (ms) => ({ $ago: ms });
const ahead = (ms) => ({ $ahead: ms });

const steps = [
  ["GET", "/api/data"],
  ["GET", "/api/nothing-here"],

  // Categories
  ["POST", "/api/categories", { name: "games" }],
  ["POST", "/api/categories", { name: "web" }],
  ["POST", "/api/categories", { name: "tools" }],
  ["POST", "/api/categories", { name: "web" }],
  ["POST", "/api/categories", {}],
  ["PATCH", "/api/categories/{cat:tools}", { name: "tooling" }],
  ["PATCH", "/api/categories/{cat:tools}", { name: "games" }],
  ["PATCH", "/api/categories/{cat:tools}", { name: null }],
  ["PATCH", `/api/categories/${MISSING}`, { name: "ghost" }],
  ["PATCH", "/api/categories/not-a-uuid", { name: "ghost" }],

  // Creates: the web app's (no edit time), a phone's, a replay, refusals
  ["POST", "/api/projects", { id: P1, name: "alpha", difficulty: "Easy", status: "idea", categoryIds: ["{cat:web}"] }],
  ["POST", "/api/projects", { id: P1, name: "alpha", difficulty: "Easy", status: "idea", categoryIds: ["{cat:web}"] }],
  ["POST", "/api/projects", { id: P2, name: "bravo", description: "**Big** idea", dev_type: "Manual", link: "https://example.com", has_content: true, notes: "n", categoryIds: ["{cat:games}", MISSING], editedAt: ago(20 * min) }],
  ["POST", "/api/projects", { id: P3, name: "charlie", difficulty: "Impossible", editedAt: ago(1 * min) }],
  ["POST", "/api/projects", { id: P3, description: "no name", editedAt: ago(1 * min) }],
  ["POST", "/api/projects", { id: P3, name: null, difficulty: "Impossible" }],
  ["POST", "/api/projects", { id: "not-a-uuid", name: "x" }],
  ["POST", "/api/projects", { id: P3, name: "charlie", has_content: "maybe" }],
  ["POST", "/api/projects", { id: P3, name: "charlie", editedAt: "soon" }],
  ["POST", "/api/projects", { id: P3, name: "charlie", categoryIds: "web" }],
  ["POST", "/api/projects", { id: P3, name: "charlie", categoryIds: ["not-a-uuid"] }],
  ["POST", "/api/projects", { id: P2, name: "bravo again", difficulty: "Impossible" }],
  ["POST", "/api/projects", { id: P3, name: "charlie", has_content: "yes", status: "doing", editedAt: ahead(60 * min) }],

  // Edits: newer applies, older is ignored per field, the future counts as now
  ["PATCH", `/api/projects/${P1}`, { name: "alpha two" }],
  ["PATCH", `/api/projects/${P1}`, { name: "alpha old", editedAt: ago(10 * min) }],
  ["PATCH", `/api/projects/${P2}`, { status: "doing", editedAt: ago(10 * min) }],
  ["PATCH", `/api/projects/${P2}`, { status: "completed", difficulty: "Hard", editedAt: ago(15 * min) }],
  ["PATCH", `/api/projects/${P2}`, { status: "doing", editedAt: ago(10 * min) }],
  ["PATCH", `/api/projects/${P2}`, { notes: "from the future", editedAt: ahead(60 * min) }],
  ["PATCH", `/api/projects/${P2}`, { notes: "later, from the web" }],
  ["PATCH", `/api/projects/${P2}`, { name: "bravo", description: null, link: null }],
  ["PATCH", `/api/projects/${P2}`, {}],
  ["PATCH", `/api/projects/${P2}`, { name: "too old", editedAt: ago(30 * min) }],
  ["GET", "/api/data"],

  // Categories one by one: two phones adding different ones both win, a late removal loses
  ["PATCH", `/api/projects/${P2}`, { addCategoryIds: ["{cat:web}"], removeCategoryIds: [], categoryIds: ["{cat:games}", "{cat:web}"], editedAt: ago(5 * min) }],
  ["PATCH", `/api/projects/${P2}`, { addCategoryIds: ["{cat:tools}"], removeCategoryIds: ["{cat:games}"], categoryIds: ["{cat:tools}"], editedAt: ago(4 * min) }],
  ["PATCH", `/api/projects/${P2}`, { addCategoryIds: [], removeCategoryIds: ["{cat:web}"], editedAt: ago(6 * min) }],
  ["PATCH", `/api/projects/${P2}`, { addCategoryIds: ["{cat:games}", MISSING], editedAt: ago(5 * min) }],
  ["GET", "/api/data"],
  ["PATCH", `/api/projects/${P2}`, { categoryIds: ["{cat:games}", MISSING] }],
  ["PATCH", `/api/projects/${P1}`, { categoryIds: [] }],
  ["GET", "/api/data"],

  // Refused edits
  ["PATCH", `/api/projects/${MISSING}`, { name: "nobody" }],
  ["PATCH", "/api/projects/not-a-uuid", { name: "nobody" }],
  ["PATCH", `/api/projects/${P1}`, { difficulty: "Nope" }],
  ["PATCH", `/api/projects/${P1}`, { has_content: "maybe" }],
  ["PATCH", `/api/projects/${P1}`, { name: null }],
  ["PATCH", `/api/projects/${P1}`, { editedAt: "soon", name: "x" }],
  ["PATCH", `/api/projects/${P1}`, { addCategoryIds: "web" }],
  ["PATCH", `/api/projects/${P1}`, { addCategoryIds: ["not-a-uuid"] }],
  ["PATCH", `/api/projects/${P1}`, { name: "never", difficulty: "Nope" }],
  ["PATCH", `/api/projects/${P1}`, { difficulty: "Nope", editedAt: ago(60 * min) }],

  // Deletes, replays and a create sent again after the delete
  ["DELETE", `/api/projects/${P4}`],
  ["POST", "/api/projects", { id: P4, name: "delta", editedAt: ago(2 * min) }],
  ["DELETE", `/api/projects/${P1}`],
  ["DELETE", `/api/projects/${P1}`],
  ["PATCH", `/api/projects/${P1}`, { name: "edited after the delete", editedAt: ago(1 * min) }],
  ["POST", "/api/projects", { id: P1, name: "alpha", difficulty: "Easy" }],
  ["DELETE", "/api/projects/not-a-uuid"],

  // A category deleted while projects use it
  ["DELETE", "/api/categories/{cat:games}"],
  ["DELETE", "/api/categories/{cat:games}"],
  ["DELETE", "/api/categories/not-a-uuid"],
  ["POST", "/api/projects", { id: "55555555-5555-4555-8555-555555555555", name: "echo", categoryIds: ["{cat:games}", "{cat:web}"], editedAt: ago(1 * min) }],
  ["GET", "/api/data"],
];

// ── Run and record ──────────────────────────────────────────────────────────
const catIds = new Map(); // name → id
const catNames = new Map(); // id → token

function resolve(value) {
  if (typeof value === "string") {
    return value.replace(/\{cat:([^}]+)\}/g, (_, name) => catIds.get(name) ?? MISSING);
  }
  if (Array.isArray(value)) return value.map(resolve);
  if (value && typeof value === "object") {
    if ("$ago" in value) return Date.now() - value.$ago;
    if ("$ahead" in value) return Date.now() + value.$ahead;
    return Object.fromEntries(Object.entries(value).map(([k, v]) => [k, resolve(v)]));
  }
  return value;
}

const ISO = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:?\d{2})$/;

function normalize(value, key) {
  if (key === "serverTime" && typeof value === "number") return "<now>";
  if (typeof value === "string") {
    if (ISO.test(value)) return "<time>";
    return catNames.get(value) ?? value;
  }
  // Category links have no order (array_agg without ORDER BY), so they are compared sorted
  if (Array.isArray(value)) {
    const list = value.map((v) => normalize(v));
    return key === "categoryIds" ? list.sort() : list;
  }
  if (value && typeof value === "object") {
    return Object.fromEntries(Object.keys(value).sort().map((k) => [k, normalize(value[k], k)]));
  }
  return value;
}

const recorded = [];
try {
  for (const [method, url, body] of steps) {
    const res = await fetch(`http://127.0.0.1:${apiPort}${resolve(url)}`, {
      method,
      headers: body ? { "Content-Type": "application/json" } : undefined,
      body: body ? JSON.stringify(resolve(body)) : undefined,
    });
    const text = await res.text();
    const json = text ? JSON.parse(text) : null;
    if (method === "POST" && url === "/api/categories" && res.status === 201) {
      catIds.set(json.name, json.id);
      catNames.set(json.id, `{cat:${json.name}}`);
    }
    recorded.push({ request: { method, path: url, ...(body ? { body } : {}) }, response: { status: res.status, body: normalize(json) } });
  }
} finally {
  server.kill();
  await pgServer.stop();
  await db.close();
}

writeFileSync(out, `${JSON.stringify({ steps: recorded }, null, 1)}\n`);
console.log(`Recorded ${recorded.length} requests to ${path.relative(repo, out)}`);
