// Devin sessions -> normalized runs.
// API: https://docs.devin.ai/api-reference/v1/sessions/list-sessions (Bearer key
// from Settings -> API Keys). v1 is in deprecation toward v3 but still served;
// the adapter is the only file that would change in a migration.

const { epoch } = require("../lib/policy");

const vendor = "devin";
const agentId = "devin";
const prefix = "cloud-devin-";

const STATES = {
  working: "thinking",
  resumed: "thinking",
  resume_requested: "thinking",
  resume_requested_frontend: "thinking",
  blocked: "question", // waiting on its user — question, never permission (protocol.md)
  finished: "done",
  expired: null,
  suspend_requested: "suspended",          // resolved against cfg.showSuspended below
  suspend_requested_frontend: "suspended",
  suspended: "suspended",
};

const fetchRaw = async (cfg) => {
  const res = await fetch("https://api.devin.ai/v1/sessions?limit=50", {
    headers: { Authorization: `Bearer ${cfg.apiKey}` },
  });
  if (!res.ok) throw new Error(`devin /v1/sessions: HTTP ${res.status}`);
  return res.json();
};

const LABELS = { thinking: "Working", question: "Needs your input", done: "Finished", idle: "Suspended" };

const normalize = (raw, cfg, now) => {
  const rows = [];
  const warnings = [];
  for (const s of raw.sessions || raw.items || []) {
    const key = String(s.status_enum || s.status || "").toLowerCase();
    let state = STATES[key];
    if (state === undefined) {
      warnings.push(`unknown devin status "${key}"`);
      state = "idle";
    }
    if (state === "suspended") state = cfg.showSuspended ? "idle" : null;
    const id = String(s.session_id || s.id || "");
    if (!id) continue;
    rows.push({
      id,
      state,
      label: LABELS[state] || "",
      project: s.title || "Devin session",
      prompt: s.title || "",
      recap: state === "done" ? s.pull_request?.url || "" : "",
      // "app" focuses Devin Desktop, which syncs cloud sessions into its Agent
      // Command Center — but exposes no per-session deep link (its own "copy
      // link" yields the web URL), so thread-precision needs openIn: "web".
      url: cfg.openIn === "web"
        ? s.url || `https://app.devin.ai/sessions/${encodeURIComponent(id)}`
        : "devin://",
      started_at: epoch(s.created_at) || 0,
      updated_at: epoch(s.updated_at) || now,
      recentHours: cfg.recentHours,
    });
  }
  return { rows, warnings };
};

module.exports = { vendor, agentId, prefix, fetchRaw, normalize };
