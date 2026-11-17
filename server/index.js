// Whirl API + static file server.
// Auth is handled in front of this by Cloudflare Access, so it binds to localhost only.
import express from "express";
import pg from "pg";
import path from "node:path";
import { fileURLToPath } from "node:url";

const PORT = process.env.PORT || 3000;
const HOST = process.env.HOST || "127.0.0.1";
const DIST = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "dist");

const pool = new pg.Pool({ connectionString: process.env.DATABASE_URL });
const app = express();
app.use(express.json());
app.use("/api", (_req, res, next) => {
  res.set("Cache-Control", "no-store");
  next();
});

const PROJECT_FIELDS = ["name", "description", "difficulty", "dev_type", "status", "link", "has_content", "notes"];

function pickFields(body, allowed = PROJECT_FIELDS) {
  return allowed.filter((k) => k in body).map((k) => [k, body[k]]);
}

async function withTransaction(fn) {
  const client = await pool.connect();
  try {
    await client.query("begin");
    const result = await fn(client);
    await client.query("commit");
    return result;
  } catch (err) {
    await client.query("rollback");
    throw err;
  } finally {
    client.release();
  }
}

async function setProjectCategories(client, projectId, categoryIds) {
  await client.query("delete from project_categories where project_id = $1", [projectId]);
  if (categoryIds.length) {
    await client.query(
      "insert into project_categories (project_id, category_id) select $1, unnest($2::uuid[])",
      [projectId, categoryIds],
    );
  }
}

// ── Conflicts between devices ───────────────────────────────────────────────
// A device that was offline sends its changes late. So that a late change can't undo a newer
// one, every field remembers when it was last edited (field_times), and a change only applies to
// fields it is newer than. Phones send when the edit was made as `editedAt` (ms since epoch, on
// this server's clock: they learn the offset from `serverTime`). Requests without it, like the
// web app's, count as made when they arrive. Category links are timed one by one ("cat:<id>"),
// so adding different categories on two devices keeps both. Deleted projects leave a marker in
// deleted_projects, so a create sent again later can't bring one back.

function invalid() {
  return Object.assign(new Error("invalid value"), { code: "22P02" });
}

// Never later than now, so a device with a fast clock can't block later edits
function editTime(body, now) {
  if (body.editedAt === undefined || body.editedAt === null) return now;
  const t = Number(body.editedAt);
  if (!Number.isFinite(t)) throw invalid();
  return Math.min(t, now);
}

function idList(value) {
  if (value === undefined || value === null) return [];
  if (!Array.isArray(value)) throw invalid();
  return [...new Set(value)];
}

// Links to a category that no longer exists are dropped rather than failing the whole change
async function knownCategories(client, ids) {
  if (!ids.length) return [];
  const { rows } = await client.query("select id from categories where id = any($1::uuid[])", [ids]);
  const known = new Set(rows.map((r) => r.id));
  return ids.filter((id) => known.has(id));
}

async function wasDeleted(client, id) {
  const { rowCount } = await client.query("select 1 from deleted_projects where id = $1", [id]);
  return rowCount > 0;
}

function withoutTimes(project) {
  const { field_times: _, ...rest } = project; // eslint-disable-line no-unused-vars
  return rest;
}
const newer = (times, key, at) => !(times[key] > at);

// ── Read everything in one go ───────────────────────────────────────────────
app.get("/api/data", async (_req, res) => {
  const [projects, categories] = await Promise.all([
    pool.query(`
      select p.*, coalesce(array_agg(pc.category_id) filter (where pc.category_id is not null), '{}') as "categoryIds"
      from projects p left join project_categories pc on pc.project_id = p.id
      group by p.id order by p.name`),
    pool.query("select * from categories order by name"),
  ]);
  res.json({ projects: projects.rows.map(withoutTimes), categories: categories.rows, serverTime: Date.now() });
});

// ── Projects ────────────────────────────────────────────────────────────────
app.post("/api/projects", async (req, res) => {
  // The app picks the id, so replaying a queued create can't make a duplicate
  const at = editTime(req.body, Date.now());
  const fields = pickFields(req.body, ["id", ...PROJECT_FIELDS]);
  const result = await withTransaction(async (client) => {
    if (req.body.id && await wasDeleted(client, req.body.id)) return { gone: true };
    const categoryIds = await knownCategories(client, idList(req.body.categoryIds));
    const times = Object.fromEntries([
      ...PROJECT_FIELDS.map((k) => [k, at]),
      ...categoryIds.map((id) => [`cat:${id}`, at]),
    ]);
    const columns = [...fields.map(([k]) => k), "field_times"];
    const { rows } = await client.query(
      `insert into projects (${columns.join(", ")})
       values (${columns.map((_, i) => `$${i + 1}`).join(", ")})
       on conflict (id) do nothing returning *`,
      [...fields.map(([, v]) => v), JSON.stringify(times)],
    );
    if (rows[0]) await setProjectCategories(client, rows[0].id, categoryIds);
    return { project: rows[0] && { ...withoutTimes(rows[0]), categoryIds } };
  });
  if (result.gone) return res.status(410).json({ error: "this project was deleted on another device" });
  res.status(result.project ? 201 : 200).json(result.project ?? { id: req.body.id });
});

app.patch("/api/projects/:id", async (req, res) => {
  const at = editTime(req.body, Date.now());
  const outcome = await withTransaction(async (client) => {
    const { rows } = await client.query("select field_times from projects where id = $1 for update", [req.params.id]);
    if (!rows[0]) return (await wasDeleted(client, req.params.id)) ? "gone" : "missing";
    const times = rows[0].field_times || {};
    const fields = pickFields(req.body).filter(([k]) => newer(times, k, at));

    // Phones send what changed (addCategoryIds, removeCategoryIds); the web app sends the whole set
    let add = [], remove = [];
    if ("addCategoryIds" in req.body || "removeCategoryIds" in req.body) {
      add = idList(req.body.addCategoryIds);
      remove = idList(req.body.removeCategoryIds);
    } else if (req.body.categoryIds !== undefined) {
      const wanted = idList(req.body.categoryIds);
      const linked = await client.query("select category_id from project_categories where project_id = $1", [req.params.id]);
      const current = linked.rows.map((r) => r.category_id);
      add = wanted.filter((id) => !current.includes(id));
      remove = current.filter((id) => !wanted.includes(id));
    }
    add = (await knownCategories(client, add)).filter((id) => newer(times, `cat:${id}`, at));
    remove = remove.filter((id) => newer(times, `cat:${id}`, at));

    if (!fields.length && !add.length && !remove.length) return "ok";
    const stamped = { ...times };
    for (const [k] of fields) stamped[k] = at;
    for (const id of [...add, ...remove]) stamped[`cat:${id}`] = at;
    await client.query(
      `update projects set ${[...fields.map(([k], i) => `${k} = $${i + 3}`), "field_times = $2"].join(", ")} where id = $1`,
      [req.params.id, JSON.stringify(stamped), ...fields.map(([, v]) => v)],
    );
    if (add.length) {
      await client.query(
        "insert into project_categories (project_id, category_id) select $1, unnest($2::uuid[]) on conflict do nothing",
        [req.params.id, add],
      );
    }
    if (remove.length) {
      await client.query(
        "delete from project_categories where project_id = $1 and category_id = any($2::uuid[])",
        [req.params.id, remove],
      );
    }
    return "ok";
  });
  if (outcome === "gone") return res.status(410).json({ error: "this project was deleted on another device" });
  if (outcome === "missing") return res.status(404).json({ error: "this project no longer exists" });
  res.status(204).end();
});

app.delete("/api/projects/:id", async (req, res) => {
  await withTransaction(async (client) => {
    await client.query("delete from projects where id = $1", [req.params.id]);
    await client.query("insert into deleted_projects (id) values ($1) on conflict do nothing", [req.params.id]);
  });
  res.status(204).end();
});

// ── Categories ──────────────────────────────────────────────────────────────
app.post("/api/categories", async (req, res) => {
  const { rows } = await pool.query("insert into categories (name) values ($1) returning *", [req.body.name]);
  res.status(201).json(rows[0]);
});

app.patch("/api/categories/:id", async (req, res) => {
  await pool.query("update categories set name = $2 where id = $1", [req.params.id, req.body.name]);
  res.status(204).end();
});

app.delete("/api/categories/:id", async (req, res) => {
  await pool.query("delete from categories where id = $1", [req.params.id]);
  res.status(204).end();
});

app.use("/api", (_req, res) => res.status(404).json({ error: "not found" }));

// Permanent failures get a 4xx so the app's device queue doesn't keep retrying them
const REJECTED = {
  23505: [409, "that name is already taken"],
  23503: [409, "a category it uses no longer exists"],
  23502: [400, "a required field is missing"],
  23514: [400, "a field has an invalid value"],
  "22P02": [400, "a field has an invalid value"],
};

// Express needs all four args to treat this as an error handler
// eslint-disable-next-line no-unused-vars
app.use("/api", (err, _req, res, _next) => {
  const rejected = REJECTED[err.code];
  if (rejected) return res.status(rejected[0]).json({ error: rejected[1] });
  console.error(err);
  res.status(500).json({ error: err.message });
});

// ── Frontend (built by `npm run build`) ─────────────────────────────────────
app.use(express.static(DIST));
// Only page routes get the app; a missing file must 404, or the service worker saves index.html as that file
app.get("/{*path}", (req, res) => {
  if (path.extname(req.path)) return res.status(404).end();
  res.sendFile(path.join(DIST, "index.html"));
});

// Databases made before these existed get them on the next start
await pool.query("alter table projects add column if not exists notes text");
await pool.query("alter table projects add column if not exists field_times jsonb not null default '{}'");
await pool.query("create table if not exists deleted_projects (id uuid primary key, deleted_at timestamptz not null default now())");

app.listen(PORT, HOST, () => console.log(`Whirl on http://${HOST}:${PORT}`));
