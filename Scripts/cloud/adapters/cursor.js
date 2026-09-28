// Cursor cloud agents -> normalized runs.
// API: https://cursor.com/docs/cloud-agent/api/endpoints — GET /v1/agents lists
// the account's agents (lifecycle status only); the live status of the work is
// on the latest *run*. v0 (legacy) carries the run status on the agent itself;
// `apiVersion: "v0"` in cloud.json switches to it if v1 listing proves lacking.
//
// Projects: a Cursor Project is a coordinator cloud agent that delegates to
// worker agents — ordinary cloud agents in /v1/agents, with nothing there that
// ties them to their Project. Cursor's own backend does (a worker's
// manager_agent_id; project_metadata on the coordinator), and the Agents Window
// reads it with the desktop app's login. This adapter borrows that login
// read-only from Cursor's state DB and folds each Project into one row: working
// while the coordinator or any of its agents is, and a click opens the Project
// (the coordinator's own thread). Best-effort: without the login (Cursor.app
// not signed in, another OS) rows stay one per agent, as before.

const { execFile } = require("child_process");
const os = require("os");
const path = require("path");

const { epoch } = require("../lib/policy");

const vendor = "cursor";
const agentId = "cursor";
const prefix = "cloud-cursor-";

const RUN_STATES = {
  CREATING: "thinking", PENDING: "thinking", QUEUED: "thinking", RUNNING: "thinking",
  FINISHED: "done", COMPLETED: "done",
  ERROR: "error", FAILED: "error",
  CANCELLED: null, EXPIRED: null, ARCHIVED: null,
};
const terminalStatus = (s) => ["done", "error", null].includes(RUN_STATES[String(s || "").toUpperCase()]);

const get = async (url, apiKey) => {
  const res = await fetch(url, { headers: { Authorization: `Bearer ${apiKey}` } });
  if (!res.ok) throw new Error(`cursor ${new URL(url).pathname}: HTTP ${res.status}`);
  return res.json();
};

// --- Projects overlay (Cursor.app's login, internal API) ---------------------

const STATE_DB = path.join(os.homedir(), "Library", "Application Support", "Cursor", "User",
                           "globalStorage", "state.vscdb");

// The desktop app's access token, read-only (the app owns and refreshes it).
// Never logged; an empty string means "no login", not an error.
const sessionToken = () => new Promise((resolve) => {
  execFile("sqlite3", ["-readonly", STATE_DB, "SELECT value FROM ItemTable WHERE key='cursorAuth/accessToken'"],
    { timeout: 5_000 }, (err, out) => resolve(err ? "" : String(out).trim()));
});

// The Agents Window's own listing (Connect JSON). includeWorkers is what makes
// Project workers — and their managerAgentId — show up at all.
const listComposers = async (token) => {
  const res = await fetch("https://api2.cursor.sh/aiserver.v1.BackgroundComposerService/ListBackgroundComposers", {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify({ n: 100, includeStatus: true, includeWorkers: true }),
    signal: AbortSignal.timeout(10_000),
  });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  return (await res.json()).composers || [];
};

// A blip in the lookup must not unfold every Project for one poll (worker rows
// flickering in and out): the last good membership stands in for a while.
const LAST_GOOD_TTL = 600;
const lastGood = { composers: null, at: 0 };

// Only what grouping needs: id -> { manager, isProject, archived, name, status, times }.
const fetchProjects = async (io, cache = lastGood) => {
  const token = await io.sessionToken();
  if (!token) return { composers: null, error: "no Cursor.app login — Projects show as separate agents" };
  const now = Date.now() / 1000;
  try {
    const composers = (await io.listComposers(token)).map((c) => ({
      id: c.bcId, name: c.name || "", manager: c.managerAgentId || "",
      isProject: !!c.projectMetadata, archived: !!c.isArchived, status: c.status || "",
      createdAt: c.createdAtMs, updatedAt: c.updatedAtMs,
    }));
    Object.assign(cache, { composers, at: now });
    return { composers, error: "" };
  } catch (e) {
    const error = `Projects lookup failed (${e.message}) — showing agents ungrouped`;
    return now - cache.at < LAST_GOOD_TTL ? { composers: cache.composers, error: "" } : { composers: null, error };
  }
};

const IO = { sessionToken, listComposers };

// agentId -> { latestRunId, run }: a run that reached a terminal status never
// changes again, so it is fetched once. Keeps the poll at 1 list call + one
// call per still-moving run.
const runCache = new Map();

const fetchRaw = async (cfg, io = IO, cache = lastGood) => {
  const projects = cfg.projects === false ? { composers: null, error: "" } : await fetchProjects(io, cache);
  const raw = await fetchAgents(cfg);
  return { ...raw, composers: projects.composers, projectsError: projects.error };
};

const fetchAgents = async (cfg) => {
  const base = "https://api.cursor.com";
  if (cfg.apiVersion === "v0") {
    const r = await get(`${base}/v0/agents?limit=40`, cfg.apiKey);
    return { agents: r.agents || r.items || [], runs: {} };
  }
  const agents = [];
  let cursor = "";
  for (let page = 0; page < 2; page++) {
    const u = new URL(`${base}/v1/agents`);
    u.searchParams.set("limit", "40");
    if (cursor) u.searchParams.set("cursor", cursor);
    const r = await get(u.toString(), cfg.apiKey);
    agents.push(...(r.agents || r.items || []));
    cursor = r.nextCursor || "";
    if (!cursor) break;
  }
  const runs = {};
  for (const a of agents) {
    if (String(a.status || "").toUpperCase() === "ARCHIVED" || !a.latestRunId) continue;
    const cached = runCache.get(a.id);
    if (cached && cached.latestRunId === a.latestRunId && terminalStatus(cached.run.status)) {
      runs[a.id] = cached.run;
      continue;
    }
    // The runs LIST is the working endpoint (newest first); run-by-id 404s in
    // practice despite being documented. Best-effort per agent: one broken
    // agent must not blank the whole vendor's rows.
    try {
      const r = await get(`${base}/v1/agents/${a.id}/runs`, cfg.apiKey);
      const items = r.items || r.runs || [];
      const run = items.find((x) => x.id === a.latestRunId) || items[0];
      if (run) {
        runs[a.id] = run;
        runCache.set(a.id, { latestRunId: a.latestRunId, run });
      }
    } catch (e) {
      if (!warnedAgents.has(a.id)) {
        warnedAgents.add(a.id);
        console.error(`[cursor] runs fetch failed for ${a.id}: ${e.message}`);
      }
    }
  }
  return { agents, runs };
};
const warnedAgents = new Set();

const LABELS = { thinking: "Working", done: "Ready for review", error: "Failed" };

const repoName = (a) => {
  const repo = (a.repos && a.repos[0]) || a.source?.repository || "";
  const s = typeof repo === "string" ? repo : repo.repository || repo.name || "";
  return s.replace(/\.git$/, "").split("/").filter(Boolean).pop() || "";
};

const linkFor = (id, webUrl, cfg) => cfg.openIn === "app"
  ? `cursor://anysphere.cursor-deeplink/background-agent?bcId=${encodeURIComponent(id)}`
  : webUrl || `https://cursor.com/agents/${encodeURIComponent(id)}`;

// Internal status of a coordinator the public listing didn't return.
const COMPOSER_STATES = { RUNNING: "thinking", CREATING: "thinking", FINISHED: "done", ERROR: "error" };

const plural = (n) => `${n} agent${n === 1 ? "" : "s"}`;

// Fold each Project's workers into its coordinator's row. A worker whose
// manager is archived or unknown stays a row of its own.
const foldProjects = (rows, composers, cfg, now) => {
  const info = new Map(composers.map((c) => [c.id, c]));
  const byId = new Map(rows.map((r) => [r.id, r]));
  const live = (id) => (info.has(id) ? !info.get(id).archived : byId.has(id));
  const groups = new Map();
  const out = [];
  for (const r of rows) {
    const manager = info.get(r.id)?.manager;
    if (manager && manager !== r.id && live(manager)) {
      if (!groups.has(manager)) groups.set(manager, []);
      groups.get(manager).push(r);
    } else {
      out.push(r);
    }
  }
  for (const [id, workers] of groups) {
    let coord = byId.get(id);
    if (!coord) {
      const c = info.get(id);
      const state = COMPOSER_STATES[String(c.status).replace("BACKGROUND_COMPOSER_STATUS_", "")] ?? null;
      coord = { id, state, label: LABELS[state] || "", project: c.name || "Cursor project", prompt: c.name || "",
                recap: "", url: linkFor(id, "", cfg), started_at: epoch(c.createdAt), updated_at: epoch(c.updatedAt) || now,
                recentHours: cfg.recentHours };
      out.push(coord);
    }
    const active = workers.filter((w) => w.state === "thinking");
    const coordBusy = coord.state === "thinking";
    const busy = [...(coordBusy ? [coord] : []), ...active];
    const latest = workers.reduce((a, w) => (!a || w.updated_at > a.updated_at ? w : a), null);
    coord.updated_at = Math.max(coord.updated_at || 0, ...workers.map((w) => w.updated_at || 0));
    if (busy.length) {
      coord.state = "thinking";
      coord.label = !active.length ? "Coordinating"
        : coordBusy ? `Coordinating · ${plural(active.length)}`
        : `${plural(active.length)} working`;
      if (active.length) coord.prompt = active[0].prompt + (active.length > 1 ? ` +${active.length - 1}` : "");
      // Elapsed counts from the oldest piece of work in flight, not from the
      // day the Project was created.
      coord.started_at = Math.min(...busy.map((b) => b.started_at || now));
    } else if (!coord.state && latest) {
      coord.state = latest.state;
      coord.label = LABELS[latest.state] || "";
    }
    if (!coord.recap && latest?.state === "done") coord.recap = latest.recap || "";
  }
  for (const r of out) if (groups.has(r.id) || info.get(r.id)?.isProject) r.via = "Project";
  return out;
};

const normalize = (raw, cfg, now) => {
  const rows = [];
  const warnings = raw.projectsError ? [raw.projectsError] : [];
  for (const a of raw.agents || []) {
    if (String(a.status || "").toUpperCase() === "ARCHIVED") continue;
    const run = raw.runs?.[a.id];
    const rawStatus = String((run || a).status || "").toUpperCase();
    if (!(rawStatus in RUN_STATES)) {
      if (rawStatus && rawStatus !== "ACTIVE") warnings.push(`unknown cursor status "${rawStatus}"`);
      if (rawStatus !== "ACTIVE" || !run) continue; // ACTIVE with no run detail: nothing to show
    }
    const state = RUN_STATES[rawStatus] ?? null;
    const prUrl = run?.git?.branches?.find((b) => b.prUrl)?.prUrl || "";
    rows.push({
      id: a.id,
      state,
      label: LABELS[state] || "",
      project: a.name || repoName(a) || "Cursor agent",
      prompt: a.name || "",
      recap: state === "done" && prUrl ? prUrl : "",
      url: linkFor(a.id, a.url, cfg),
      started_at: epoch(run?.createdAt || a.createdAt) || 0,
      updated_at: epoch(run?.updatedAt || run?.finishedAt || run?.createdAt || a.createdAt) || now,
      recentHours: cfg.recentHours,
    });
  }
  return { rows: raw.composers ? foldProjects(rows, raw.composers, cfg, now) : rows, warnings };
};

module.exports = { vendor, agentId, prefix, fetchRaw, fetchProjects, normalize };
