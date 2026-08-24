// Which normalized runs become rows, and how they map onto the state.d schema.
// Pure functions: the poller loop feeds them the clock and its pid.

const { safeId, oneLine } = require("./state");

// A run's protocol lifetime, by state:
// - thinking: always shown — an actively working run is never too old;
// - done/error: retentionMinutes since the vendor's last update, then gone;
// - question/idle (blocked, suspended): recentHours — needs-you rows matter,
//   but a session ignored for days is clutter, not a prompt.
const keepRow = (run, cfg, now) => {
  if (!run.state) return false;
  const age = now - (run.updated_at || now);
  switch (run.state) {
    case "thinking": return true;
    case "done":     return age < (cfg.retentionMinutes.done || 60) * 60;
    case "error":    return age < (cfg.retentionMinutes.error || 240) * 60;
    default:         return age < (run.recentHours || 48) * 3600;
  }
};

const isTerminal = (state) => state === "done" || state === "error";

// Assemble the state.d row. cwd stays empty (no local checkout — a non-empty cwd
// would advertise the wrong git branch) and pid is the poller's own, so the rows
// die with the poller. ts freezes at the vendor's last update once a run is
// terminal — a done row must age out, not stay eternally fresh.
const toProtocolRow = (run, { agentId, prefix }, now, pid) => ({
  agent: agentId,
  state: run.state,
  label: oneLine(run.label, 80),
  project: oneLine(run.project, 40),
  cwd: "",
  sessionId: safeId(prefix + run.id),
  entrypoint: "cloud",
  term_program: "",
  pid,
  started: true,
  ts: isTerminal(run.state) ? Math.min(run.updated_at || now, now) : now,
  ...(run.started_at ? { started_at: run.started_at } : {}),
  ...(run.prompt ? { prompt: oneLine(run.prompt, 120) } : {}),
  ...(run.recap ? { recap: oneLine(run.recap, 160) } : {}),
  url: String(run.url || ""),
});

// ISO timestamp -> unix seconds; 0 when unparseable (callers treat 0 as unknown).
const epoch = (iso) => {
  const ms = Date.parse(iso || "");
  return Number.isFinite(ms) ? Math.floor(ms / 1000) : 0;
};

module.exports = { keepRow, toProtocolRow, isTerminal, epoch };
