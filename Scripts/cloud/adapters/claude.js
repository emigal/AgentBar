// Claude Code cloud sessions (claude.ai/code) -> normalized runs, including the
// ones started from the Claude Code app's cloud environments.
// No public API: this is the session list the Claude Code CLI itself uses for
// `--cloud` / teleport (GET /v1/sessions, beta ccr-byoc-2025-07-29), read with
// the CLI's own login — the OAuth access token in the macOS Keychain item
// "Claude Code-credentials", read-only, never logged, never refreshed here (the
// app and CLI own the refresh token; rotating it from a second process would
// sign them out). An expired token is a failed poll until the app renews it.
// Rows open in Claude.app (`claude://code/<session>` — the app's own handler
// resolves the id and routes to the thread); openIn "web" opens claude.ai/code.
// Sessions with environment_kind "bridge" are Remote Control mirrors of local
// CLI sessions the hooks already report — skipped, or they'd show twice.

const { execFile } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");

const { epoch } = require("../lib/policy");

const vendor = "claude";
const agentId = "claude";
const prefix = "cloud-claude-";

const STATES = {
  running: "thinking", working: "thinking",
  waiting: "question",
  idle: "done", completed: "done",
  archived: null, cancelled: null, rejected: null,
};

const LABELS = { thinking: "Working", question: "Needs your input", done: "Ready for review", error: "Failed" };

const keychainCreds = () => new Promise((resolve, reject) => {
  execFile("security", ["find-generic-password", "-s", "Claude Code-credentials", "-w"],
    { timeout: 10_000 }, (err, out) => {
      if (err) return reject(new Error("claude: no Claude Code login in the Keychain (run `claude`, then /login)"));
      try { resolve(JSON.parse(String(out)).claudeAiOauth || {}); }
      catch { reject(new Error("claude: unreadable Keychain credentials")); }
    });
});

const orgUuid = (cfg) => {
  if (cfg.orgId) return cfg.orgId;
  try {
    const file = path.join(os.homedir(), ".claude.json");
    return JSON.parse(fs.readFileSync(file, "utf8")).oauthAccount?.organizationUuid || "";
  } catch { return ""; }
};

const fetchRaw = async (cfg) => {
  const creds = await keychainCreds();
  const org = orgUuid(cfg);
  if (!creds.accessToken || !org) throw new Error("claude: Claude Code login has no token or organization");
  if (creds.expiresAt && creds.expiresAt < Date.now()) {
    throw new Error("claude: Claude Code token expired (open the Claude app or run `claude`)");
  }
  const res = await fetch(`https://api.anthropic.com/v1/sessions?limit=${cfg.limit || 50}`, {
    headers: {
      Authorization: `Bearer ${creds.accessToken}`,
      "anthropic-version": "2023-06-01",
      "anthropic-beta": "ccr-byoc-2025-07-29",
      "x-organization-uuid": org,
    },
    signal: AbortSignal.timeout(15_000),
  });
  if (!res.ok) throw new Error(`claude /v1/sessions: HTTP ${res.status}`);
  return res.json();
};

// "owner/repo" from the session's first git source or outcome; "" when it has none.
const repoOf = (s) => {
  const ctx = s.session_context || {};
  const url = (ctx.sources || []).map((x) => x.url).find(Boolean);
  if (url) return String(url).replace(/\.git$/, "").split("/").filter(Boolean).pop() || "";
  const repo = (ctx.outcomes || []).map((o) => o.git_info?.repo).find(Boolean);
  return repo ? String(repo).split("/").pop() : "";
};

const normalize = (raw, cfg, now) => {
  const rows = [];
  const warnings = [];
  for (const s of raw.data || []) {
    if (!s.id || s.environment_kind === "bridge") continue;
    const key = String(s.session_status || "").toLowerCase();
    let state = STATES[key];
    if (state === undefined) {
      warnings.push(`unknown claude session status "${key}"`);
      state = "idle";
    }
    rows.push({
      id: String(s.id),
      state,
      label: LABELS[state] || "",
      project: repoOf(s) || "Claude Code",
      prompt: s.title || "",
      url: cfg.openIn === "web" ? `https://claude.ai/code/${s.id}` : `claude://code/${s.id}`,
      started_at: epoch(s.created_at),
      updated_at: epoch(s.updated_at) || now,
      recentHours: cfg.recentHours,
    });
  }
  return { rows, warnings };
};

module.exports = { vendor, agentId, prefix, fetchRaw, normalize };
