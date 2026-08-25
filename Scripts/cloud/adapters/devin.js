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

// cog_ keys (service users / PATs) authorize only the v3 org-scoped API and
// need `orgId` from Settings -> Service Users; legacy apk_ keys use v1.
const fetchRaw = async (cfg) => {
  const path = cfg.orgId
    ? `/v3/organizations/${encodeURIComponent(cfg.orgId)}/sessions?limit=50`
    : "/v1/sessions?limit=50";
  const res = await fetch(`https://api.devin.ai${path}`, {
    headers: { Authorization: `Bearer ${cfg.apiKey}` },
  });
  if (!res.ok) throw new Error(`devin ${path.split("?")[0]}: HTTP ${res.status}`);
  return res.json();
};

const LABELS = { thinking: "Working", question: "Needs your input", done: "Finished", idle: "Suspended" };

const normalize = (raw, cfg, now) => {
  const rows = [];
  const warnings = [];
  for (const s of raw.sessions || raw.items || raw.data || []) {
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
      // "app" opens the exact thread in Devin Desktop via its ACP URL handler
      // (undocumented; recovered from the IDE bundle): a session synced into the
      // Agent Command Center activates in-app, and the handler itself falls back
      // to the web thread URL when it isn't. "web" skips the app entirely.
      url: cfg.openIn === "web"
        ? s.url || `https://app.devin.ai/sessions/${encodeURIComponent(id)}`
        : `devin://acp/session?sessionId=${encodeURIComponent(id)}&connectorId=devin-cloud`,
      started_at: epoch(s.created_at) || 0,
      updated_at: epoch(s.updated_at) || now,
      recentHours: cfg.recentHours,
    });
  }
  return { rows, warnings };
};

module.exports = { vendor, agentId, prefix, fetchRaw, normalize };
