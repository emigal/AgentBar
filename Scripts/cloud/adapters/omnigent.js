// Omnigent sessions -> normalized runs. Omnigent is a self-hosted agent server
// (`omnigent server` on a box, reached over e.g. Tailscale); every coding agent
// it runs — Claude Code, Codex, Pi… — is a session in its REST API. Rows carry
// the underlying agent's id and `via: "Omnigent"`, and a click opens the exact
// session: Omnigent.app's `omnigent://<host>/c/<id>` deep link, or the same
// `/c/<id>` route of the web UI when the app can't take the link (see linkFor).
//
// Auth rides the Omnigent CLI's login: its bearer token in
// ~/.omnigent/auth_tokens.json, renewed through the CLI's own refresh (its file
// lock and refresh-token rotation) — this adapter never writes that file.

const { execFile } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");

const { epoch } = require("../lib/policy");

const vendor = "omnigent";
const agentId = "omnigent"; // harnesses AgentBar has no mascot for (goose, hermes, kimi…) + the error row
const prefix = "omnigent-";

const home = (p) => p.replace(/^~(?=\/|$)/, os.homedir());
const OMNIGENT_DIR = path.join(os.homedir(), ".omnigent");
const APP_SETTINGS = path.join(os.homedir(), "Library", "Application Support", "Omnigent", "settings.json");

// Harness / agent names are compounds ("claude-native-ui", "native-codex",
// "claude_code:explore-…"): the first token AgentBar knows decides the mascot.
const AGENTS = {
  claude: "claude", codex: "codex", pi: "pi", agy: "antigravity", antigravity: "antigravity",
  opencode: "opencode", qwen: "qwen", gemini: "gemini", copilot: "copilot", cursor: "cursor",
  devin: "devin",
};
const agentFor = (name) => {
  for (const t of String(name || "").toLowerCase().split(/[^a-z0-9]+/)) if (AGENTS[t]) return AGENTS[t];
  return null;
};

// --- auth -------------------------------------------------------------------

// The server the CLI is logged in to: cfg.server, else the top-level `server:`
// key of ~/.omnigent/config.yaml (one scalar — no YAML parser needed).
const configServer = () => {
  try {
    const m = fs.readFileSync(path.join(OMNIGENT_DIR, "config.yaml"), "utf8").match(/^server:\s*["']?([^\s"']+)/m);
    return m ? m[1] : "";
  } catch {
    return "";
  }
};

const readTokens = () => {
  try {
    return JSON.parse(fs.readFileSync(path.join(OMNIGENT_DIR, "auth_tokens.json"), "utf8"));
  } catch {
    return {};
  }
};

const tokenEntry = (tokens, server) =>
  tokens[server] || tokens[server.replace(/\/+$/, "")] || tokens[`${server.replace(/\/+$/, "")}/`] || null;

// Renew via the CLI's own Python (the interpreter on the omnigent launcher's
// shebang), so refresh-token rotation and the token-file lock stay the CLI's.
// Exit status only — the token never crosses stdout.
const REFRESH = "import sys\nfrom omnigent.cli_auth import refresh_stored_token as r\nsys.exit(0 if r(sys.argv[1]) else 1)";
const cliRefresh = (cfg, server) => new Promise((resolve) => {
  let python = "";
  try {
    const first = fs.readFileSync(home(cfg.bin), "utf8").split("\n", 1)[0];
    if (first.startsWith("#!") && !/\benv\b/.test(first)) python = first.slice(2).trim();
  } catch { /* no CLI -> cannot refresh */ }
  if (!python) return resolve(false);
  execFile(python, ["-c", REFRESH, server], { timeout: 20_000 }, (err) => resolve(!err));
});

// --- http -------------------------------------------------------------------

const httpGet = async (url, token) => {
  const res = await fetch(url, {
    headers: { Authorization: `Bearer ${token}`, Accept: "application/json" },
    signal: AbortSignal.timeout(10_000),
  });
  return { status: res.status, body: res.ok ? await res.json() : null };
};

// Omnigent.app's current server (its own settings file): where links point.
const appServer = () => {
  try {
    return String(JSON.parse(fs.readFileSync(APP_SETTINGS, "utf8")).server_url || "");
  } catch {
    return "";
  }
};

const IO = { configServer, readTokens, refresh: cliRefresh, get: httpGet, appServer };

// --- poll -------------------------------------------------------------------

const REFRESH_MARGIN = 120; // seconds of validity below which the token is renewed first
const HOSTS_TTL = 600;
const DETAIL_BUDGET = 10; // per poll: harness lookups for names that don't say which agent

const memo = { hosts: null, hostsAt: 0, harness: new Map() };

// Throws (-> the framework's failure budget and error row) when the server is
// unreachable or the CLI's login can't be renewed. `io` and `cache` are
// injectable for tests.
const fetchRaw = async (cfg, io = IO, cache = memo) => {
  const server = (cfg.server || io.configServer()).replace(/\/+$/, "");
  if (!server) throw new Error("omnigent: no server (run `omnigent login`, or set omnigent.server)");
  const now = Date.now() / 1000;

  let entry = tokenEntry(io.readTokens(), server);
  const renew = async () => {
    if (!(await io.refresh(cfg, server))) {
      throw new Error("omnigent: login expired and could not be renewed — run `omnigent login`");
    }
    entry = tokenEntry(io.readTokens(), server);
    if (!entry || !entry.token) throw new Error("omnigent: token missing after renewal — run `omnigent login`");
  };
  if (!entry || !entry.token) throw new Error(`omnigent: not logged in to ${server} — run \`omnigent login\``);
  if (typeof entry.expires_at === "number" && entry.expires_at - now < REFRESH_MARGIN) await renew();

  // A 401 despite a fresh-looking token (revoked, clock skew): renew once.
  let retried = false;
  const get = async (p) => {
    const r = await io.get(server + p, entry.token);
    if (r.status === 401 && !retried) {
      retried = true;
      await renew();
      return get(p);
    }
    if (r.status < 200 || r.status >= 300) throw new Error(`omnigent ${p.split("?")[0]}: HTTP ${r.status}`);
    return r.body;
  };

  const list = await get(`/v1/sessions?visibility=mine&sort_by=updated_at&limit=${cfg.limit || 50}`);
  const sessions = (list?.data || []).filter((s) => !s.archived && !s.parent_session_id);

  // Host names only label rows: a failed lookup keeps the last map (or none).
  if (!cache.hosts || now - cache.hostsAt > HOSTS_TTL) {
    try {
      const h = await get("/v1/hosts");
      cache.hosts = Object.fromEntries((h?.hosts || []).map((x) => [x.host_id, x.name]));
      cache.hostsAt = now;
    } catch { /* keep previous */ }
  }

  // agent_name usually names the harness ("claude-native-ui"); custom agents
  // (polly, a YAML agent) don't, and the session detail's `harness` does.
  let budget = DETAIL_BUDGET;
  for (const s of sessions) {
    if (agentFor(s.agent_name) || cache.harness.has(s.id) || budget <= 0) continue;
    budget -= 1;
    try {
      const d = await get(`/v1/sessions/${encodeURIComponent(s.id)}?include_items=false&include_liveness=false`);
      cache.harness.set(s.id, String(d?.harness || ""));
    } catch { /* try again next poll */ }
  }

  return {
    server,
    appServer: cfg.appServer || io.appServer(),
    sessions,
    hosts: cache.hosts || {},
    harness: Object.fromEntries(sessions.filter((s) => cache.harness.has(s.id)).map((s) => [s.id, cache.harness.get(s.id)])),
  };
};

// --- normalize ----------------------------------------------------------------

const LOOPBACK = new Set(["localhost", "127.0.0.1", "[::1]", "::1"]);

// Omnigent.app's deep link names a server by host only and infers the scheme:
// http for loopback, https for anything else (the app's src/deepLink.js). So
// the app can only be linked to a server it reaches at such an origin — an
// app pinned to plain http on a LAN/Tailscale address would get a consent
// prompt for an https server that doesn't exist. Those clicks go to the same
// session in the browser instead; moving the server behind HTTPS (e.g.
// `tailscale serve --https=…`) switches them to the app on the next poll.
const linkFor = (id, raw, cfg) => {
  const route = `/c/${encodeURIComponent(id)}`;
  let app = null;
  try { app = raw.appServer ? new URL(raw.appServer) : null; } catch { /* unparseable */ }
  if (cfg.openIn !== "web" && app && (app.protocol === "https:" || LOOPBACK.has(app.hostname))) {
    return `omnigent://${app.host}${route}`;
  }
  const base = (app ? app.origin + app.pathname : raw.server).replace(/\/+$/, "");
  return base + route;
};

const LABELS = { thinking: "Working", question: "Needs your input", done: "Finished", error: "Failed", idle: "" };
const DONE_WINDOW = 3600; // an unread finish reads as done this long, then rests as idle

const normalize = (raw, cfg, now) => {
  const rows = [];
  const warnings = [];
  for (const s of raw.sessions || []) {
    const id = String(s.id || "");
    if (!id) continue;
    const updated = epoch(s.updated_at) || now;
    // A pending approval leaves status "running" (observed live): the
    // elicitation count is what says the session waits on its user.
    let state;
    if (s.pending_elicitations_count > 0 || s.status === "waiting") state = "question";
    else if (s.status === "running") state = "thinking";
    else if (s.status === "failed") state = "error";
    else if (s.status === "idle") state = s.viewer_unread && now - updated < DONE_WINDOW ? "done" : "idle";
    else {
      warnings.push(`unknown omnigent status "${s.status}"`);
      state = "idle";
    }
    const host = raw.hosts[s.host_id] || "";
    const folder = s.workspace ? path.basename(s.workspace) : "";
    rows.push({
      id,
      agent: agentFor(s.agent_name) || agentFor(raw.harness[id]) || agentId,
      state,
      label: LABELS[state],
      project: [folder, host].filter(Boolean).join("@") || "Omnigent",
      prompt: s.title || "",
      url: linkFor(id, raw, cfg),
      via: "Omnigent",
      started_at: epoch(s.created_at) || 0,
      updated_at: updated,
    });
  }
  return { rows, warnings };
};

module.exports = { vendor, agentId, prefix, fetchRaw, normalize, agentFor };
