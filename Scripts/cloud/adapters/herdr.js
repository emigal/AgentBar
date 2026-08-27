// Remote Herdr sessions -> normalized runs. One `ssh <host> herdr agent list`
// per poll surfaces every agent Herdr recognizes on that machine (Claude Code,
// Codex, anything with a Herdr integration — no AgentBar hooks needed there).
// The herdr-mirror plugin's map file translates each remote pane to its local
// mirror pane, so a row click lands on the live mirror inside the local Herdr
// (TerminalFocus reads the herdr_* fields this adapter writes).

const { execFile } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");

const vendor = "herdr";
const agentId = "claude"; // synthetic rows only (poll failure); real rows carry their own agent
const prefix = "herdr-";

// Herdr agent lifecycle -> protocol states. "blocked" is Herdr's word for an
// approval or question UI; "unknown" (agent present, unclassifiable) degrades
// to idle rather than hiding a live session.
const STATES = { working: "thinking", blocked: "permission", idle: "idle", done: "done", unknown: "idle" };
const LABELS = { thinking: "Working", permission: "Needs approval", done: "Done", idle: "" };

const sshList = (host) => new Promise((resolve, reject) => {
  // Non-interactive ssh skips the remote's rc files, so ~/.local/bin (where
  // `herdr plugin install` links binaries) is put on PATH by hand.
  execFile("ssh",
    ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8", host,
     'PATH="$HOME/.local/bin:$PATH" herdr agent list'],
    { timeout: 20_000, maxBuffer: 4 * 1024 * 1024 },
    (err, stdout) => {
      if (err) return reject(new Error(`herdr ${host}: ${err.message.split("\n")[0]}`));
      try {
        const o = JSON.parse(stdout);
        resolve(o.result?.agents || o.agents || []);
      } catch {
        reject(new Error(`herdr ${host}: unparseable agent list`));
      }
    });
});

// herdr-mirror's state file for a host: remote pane id -> { localId, tombstone }.
// Best effort — no plugin or no map just means rows without a local pane.
const readMap = (host) => {
  try {
    const m = JSON.parse(fs.readFileSync(path.join(
      os.homedir(), ".local", "state", "herdr-mirror", `${host}-map.json`), "utf8"));
    return m.panes || {};
  } catch {
    return {};
  }
};

const fetchRaw = async (cfg) => {
  const hosts = [];
  // Sequential and all-or-nothing: one unreachable host fails the vendor poll,
  // which keeps the last-good rows (then the framework's failure budget takes
  // over) instead of silently dropping that host's sessions.
  for (const host of cfg.hosts) {
    hosts.push({ host, agents: await sshList(host), panes: readMap(host) });
  }
  return { hosts };
};

// `herdr agent list` carries no timestamps, only state_change_seq (a counter
// that moves on every lifecycle change). The poller's own memory is the clock:
// seq moved -> updated_at becomes "now"; first sight -> started_at. Times reset
// on poller restart, so rows age from the restart, never backwards.
const seen = new Map(); // row id -> { seq, since, firstSeen }
const track = (id, seq, cache, now) => {
  const c = cache.get(id);
  const e = { seq, since: c && c.seq === seq ? c.since : now, firstSeen: c ? c.firstSeen : now };
  cache.set(id, e);
  return e;
};

const normalize = (raw, cfg, now, cache = seen) => {
  const rows = [];
  const warnings = [];
  const fresh = new Set();
  for (const { host, agents, panes } of raw.hosts || []) {
    for (const a of agents || []) {
      // A mirror pane on the remote is a view of a session living elsewhere
      // (possibly this very machine) — mirroring it back would double-count.
      if (String(a.cwd || "").includes("/herdr-mirror/")) continue;
      const state = STATES[a.agent_status];
      if (!state) {
        warnings.push(`unknown herdr status "${a.agent_status}"`);
        continue;
      }
      const id = `${host}-${a.terminal_id || a.pane_id}`;
      fresh.add(id);
      const t = track(id, a.state_change_seq || 0, cache, now);
      const pane = panes[a.pane_id];
      rows.push({
        id,
        agent: a.agent || "claude",
        state,
        label: LABELS[state] || "",
        project: `${path.posix.basename(a.cwd || "") || host}@${host}`,
        prompt: a.terminal_title_stripped || a.title || "",
        entrypoint: "", // lives in a local (mirror) pane, not at a URL
        term_program: cfg.termProgram,
        herdr_pane: pane && pane.tombstone !== true ? pane.localId : "",
        herdr_host: host,
        herdr_remote_pane: a.pane_id,
        started_at: t.firstSeen,
        updated_at: t.since,
        recentHours: cfg.recentHours,
      });
    }
  }
  for (const k of cache.keys()) if (!fresh.has(k)) cache.delete(k);
  return { rows, warnings };
};

module.exports = { vendor, agentId, prefix, fetchRaw, normalize };
