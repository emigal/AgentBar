// Pure-function tests for the cloud poller: adapter normalization, retention
// policy, and protocol-row assembly. Run: node --test Scripts/cloud/test/*.test.js
const { test } = require("node:test");
const assert = require("node:assert");

const cursor = require("../adapters/cursor");
const devin = require("../adapters/devin");
const codex = require("../adapters/codex");
const herdr = require("../adapters/herdr");
const omnigent = require("../adapters/omnigent");
const { keepRow, toProtocolRow, epoch } = require("../lib/policy");
const { safeId } = require("../lib/state");
const { DEFAULTS } = require("../lib/config");

const NOW = 1_787_600_000;
const iso = (secondsAgo) => new Date((NOW - secondsAgo) * 1000).toISOString();

// --- codex: fixture captured from a real `codex cloud list --json` (2026-08-24)

const codexFixture = {
  tasks: [
    {
      id: "task_e_69dd92b48e5c83249b2cf0fcf2eaafbe",
      url: "https://chatgpt.com/codex/tasks/task_e_69dd92b48e5c83249b2cf0fcf2eaafbe",
      title: "Fix ModelHTTPError 500 in production",
      status: "ready",
      updated_at: iso(600),
      environment_id: null,
      environment_label: "mtwr-two",
      summary: { files_changed: 2, lines_added: 150, lines_removed: 73 },
      is_review: false,
      attempt_total: 1,
    },
    { id: "task_x", url: "https://chatgpt.com/codex/tasks/task_x", title: "Weird",
      status: "somenewstatus", updated_at: iso(60), environment_label: "env", summary: null },
  ],
};

test("codex: ready maps to done with a diffstat recap", () => {
  const { rows, warnings } = codex.normalize(codexFixture, DEFAULTS.codex, NOW);
  assert.equal(rows[0].state, "done");
  assert.equal(rows[0].recap, "2 files · +150 −73");
  assert.equal(rows[0].project, "mtwr-two");
  assert.match(rows[0].url, /^https:\/\/chatgpt\.com\/codex\/tasks\//);
  assert.equal(rows[1].state, "idle"); // unknown status degrades, never hides silently
  assert.deepEqual(warnings, ['unknown codex status "somenewstatus"']);
});

// --- devin

const devinFixture = {
  sessions: [
    { session_id: "devin-abc123", status_enum: "working", title: "Migrate billing to v2",
      created_at: iso(7200), updated_at: iso(30) },
    { session_id: "devin-blocked1", status_enum: "blocked", title: "Refactor auth",
      created_at: iso(7200), updated_at: iso(300) },
    { session_id: "devin-fin", status_enum: "finished", title: "Done thing",
      created_at: iso(9000), updated_at: iso(120), pull_request: { url: "https://github.com/x/y/pull/7" } },
    { session_id: "devin-susp", status_enum: "suspend_requested", title: "Paused thing",
      created_at: iso(9000), updated_at: iso(120) },
    { session_id: "devin-old", status_enum: "expired", title: "Gone", updated_at: iso(900000) },
  ],
};

test("devin: status_enum mapping — blocked is question, never permission", () => {
  const { rows, warnings } = devin.normalize(devinFixture, DEFAULTS.devin, NOW);
  const byId = Object.fromEntries(rows.map((r) => [r.id, r]));
  assert.equal(byId["devin-abc123"].state, "thinking");
  assert.equal(byId["devin-blocked1"].state, "question");
  assert.equal(byId["devin-fin"].state, "done");
  assert.equal(byId["devin-fin"].recap, "https://github.com/x/y/pull/7");
  assert.equal(byId["devin-susp"].state, "idle"); // suspended = Devin's resting state, shown
  assert.equal(byId["devin-susp"].recentHours, DEFAULTS.devin.suspendedHours);
  assert.equal(byId["devin-old"].state, null);    // expired: dropped
  assert.equal(byId["devin-abc123"].url, // default: exact thread in Devin Desktop
    "devin://acp/session?sessionId=devin-abc123&connectorId=devin-cloud");
  assert.deepEqual(warnings, []);
});

test("devin: v3 shape — numeric timestamps, unprefixed ids, bare status", () => {
  const v3 = { items: [
    { session_id: "082c8b0459464c6c9ce3ea47da31a0d2", status: "suspended",
      title: "Sentry errors 24 hours", created_at: String(NOW - 7200), updated_at: String(NOW - 600) },
    { session_id: "f9b766226d0000000000000000000000", status: "running", // v3 for v1's "working"
      title: "Validate backfill plan", created_at: String(NOW - 120), updated_at: String(NOW - 60) },
  ] };
  const { rows, warnings } = devin.normalize(v3, DEFAULTS.devin, NOW);
  assert.equal(rows[0].state, "idle");
  assert.equal(rows[0].updated_at, NOW - 600); // numeric-string epoch parsed, not defaulted to now
  assert.equal(rows[0].url, // ACP store keys sessions WITH the devin- prefix
    "devin://acp/session?sessionId=devin-082c8b0459464c6c9ce3ea47da31a0d2&connectorId=devin-cloud");
  assert.equal(rows[1].state, "thinking"); // a running session is active, never idle-filed
  assert.deepEqual(warnings, []);
});

test("devin: openIn web yields the thread-precise browser URL, prefix stripped", () => {
  const { rows } = devin.normalize(devinFixture, { ...DEFAULTS.devin, openIn: "web" }, NOW);
  assert.equal(rows.find((r) => r.id === "devin-abc123").url,
    "https://app.devin.ai/sessions/abc123");
});

test("devin: showSuspended false hides suspended sessions", () => {
  const { rows } = devin.normalize(devinFixture, { ...DEFAULTS.devin, showSuspended: false }, NOW);
  assert.equal(rows.find((r) => r.id === "devin-susp").state, null);
});

// --- cursor (v1 doc shape: lifecycle on the agent, live status on the run)

const cursorFixture = {
  agents: [
    { id: "bc-11111111-2222-3333-4444-555555555555", name: "Fix login bug", status: "ACTIVE",
      latestRunId: "run-1", url: "https://cursor.com/agents/bc-11111111-2222-3333-4444-555555555555",
      repos: ["github.com/acme/webapp.git"], createdAt: iso(3600) },
    { id: "bc-archived", name: "Old", status: "ARCHIVED", latestRunId: "run-9" },
    { id: "bc-errored", name: "Broken run", status: "ACTIVE", latestRunId: "run-2", createdAt: iso(3600) },
  ],
  runs: {
    "bc-11111111-2222-3333-4444-555555555555":
      { id: "run-1", status: "RUNNING", createdAt: iso(3600), updatedAt: iso(10) },
    "bc-errored":
      { id: "run-2", status: "ERROR", createdAt: iso(3600), updatedAt: iso(60),
        git: { branches: [{ prUrl: "https://github.com/x/y/pull/9" }] } },
  },
};

test("cursor: run status wins; archived agents are dropped", () => {
  const { rows, warnings } = cursor.normalize(cursorFixture, DEFAULTS.cursor, NOW);
  assert.equal(rows.length, 2);
  assert.equal(rows[0].state, "thinking");
  assert.equal(rows[0].project, "Fix login bug");
  assert.match(rows[0].url, /^cursor:\/\/anysphere\.cursor-deeplink\/background-agent\?bcId=/);
  assert.equal(rows[1].state, "error");
  assert.deepEqual(warnings, []);
});

test("cursor: openIn web switches the url to the browser link", () => {
  const { rows } = cursor.normalize(cursorFixture, { ...DEFAULTS.cursor, openIn: "web" }, NOW);
  assert.match(rows[0].url, /^https:\/\/cursor\.com\/agents\//);
});

test("cursor: v0 shape (status on the agent, no runs) still normalizes", () => {
  const v0 = { agents: [{ id: "bc-v0", name: "Old style", status: "FINISHED", createdAt: iso(120) }], runs: {} };
  const { rows } = cursor.normalize(v0, DEFAULTS.cursor, NOW);
  assert.equal(rows[0].state, "done");
});

// --- herdr: fixture captured from a real `ssh dexter herdr agent list` (2026-08-27)

const herdrFixture = {
  hosts: [{
    host: "dexter",
    agents: [
      { agent: "claude", agent_status: "working", cwd: "/home/emi/code/frontierfi",
        pane_id: "w1:pC", state_change_seq: 69, terminal_id: "term_6598124a35ac4c",
        terminal_title_stripped: "Fix auth flow" },
      { agent: "prime-agent", agent_status: "blocked", cwd: "/home/emi/code/frontierfi",
        pane_id: "w1:p9", state_change_seq: 8, terminal_id: "term_658f0e39411ae9",
        terminal_title_stripped: "prime-agent - frontierfi" },
      { agent: "claude", agent_status: "idle", cwd: "/home/emi/.local/state/herdr-mirror/.mirror-pane",
        pane_id: "w1:pF", state_change_seq: 2, terminal_id: "term_reverse" },
      { agent: "claude", agent_status: "someday", cwd: "/home/emi/x",
        pane_id: "w1:pG", state_change_seq: 1, terminal_id: "term_weird" },
    ],
    panes: {
      "w1:pC": { localId: "w13:pE", seq: 4636 },
      "w1:p9": { localId: "w13:pA", tombstone: true, seq: 6 },
    },
  }],
};

test("herdr: states map, mirror panes resolve, remote mirrors and unknowns drop", () => {
  const cache = new Map();
  const { rows, warnings } = herdr.normalize(herdrFixture, DEFAULTS.herdr, NOW, cache);
  assert.equal(rows.length, 2); // reverse mirror pane and unknown status are out
  assert.equal(rows[0].state, "thinking");
  assert.equal(rows[0].agent, "claude");
  assert.equal(rows[0].project, "frontierfi@dexter");
  assert.equal(rows[0].prompt, "Fix auth flow");
  assert.equal(rows[0].herdr_pane, "w13:pE"); // live mirror: click focuses it
  assert.equal(rows[0].herdr_remote_pane, "w1:pC");
  assert.equal(rows[1].state, "permission"); // blocked = waiting on a human
  assert.equal(rows[1].agent, "prime-agent");
  assert.equal(rows[1].herdr_pane, ""); // tombstoned mirror: click restores it
  assert.equal(rows[1].herdr_host, "dexter");
  assert.deepEqual(warnings, ['unknown herdr status "someday"']);
});

test("herdr: state_change_seq is the clock — unchanged keeps updated_at, moved resets it", () => {
  const cache = new Map();
  const first = herdr.normalize(herdrFixture, DEFAULTS.herdr, NOW, cache);
  assert.equal(first.rows[0].updated_at, NOW);
  const later = herdr.normalize(herdrFixture, DEFAULTS.herdr, NOW + 300, cache);
  assert.equal(later.rows[0].updated_at, NOW);       // same seq: still the old change time
  assert.equal(later.rows[0].started_at, NOW);       // first sight sticks
  const moved = JSON.parse(JSON.stringify(herdrFixture));
  moved.hosts[0].agents[0].state_change_seq = 70;
  const changed = herdr.normalize(moved, DEFAULTS.herdr, NOW + 600, cache);
  assert.equal(changed.rows[0].updated_at, NOW + 600);
});

test("herdr: rows land in a local pane, not at a url — entrypoint stays overridden", () => {
  const cache = new Map();
  const { rows } = herdr.normalize(herdrFixture, DEFAULTS.herdr, NOW, cache);
  const row = toProtocolRow(rows[0], herdr, NOW, 4242);
  assert.equal(row.entrypoint, ""); // "" must survive the "cloud" default
  assert.equal(row.agent, "claude"); // per-row agent wins over the adapter's
  assert.equal(row.term_program, "Ghostty");
  assert.equal(row.herdr_pane, "w13:pE");
  assert.equal(row.herdr_host, "dexter");
  assert.equal(row.sessionId, "herdr-dexter-term_6598124a35ac4c");
});

// --- herdr: a host attached natively (`herdr --remote egdev`), no mirror plugin (2026-09-05)

const egdevFixture = {
  hosts: [{
    host: "egdev",
    agents: [
      { agent: "pi", agent_status: "working", cwd: "/home/ubuntu/.herdr/worktrees/mtwr-two/mtwr-two-8c5a98e8e8",
        pane_id: "w8:p8", tab_id: "w8:t4", state_change_seq: 84, terminal_id: "term_65ab7aa1185d34b",
        terminal_title_stripped: "π - mtwr-two-8c5a98e8e8" },
      { agent: "claude", agent_status: "idle", cwd: "/home/ubuntu/.herdr/worktrees/mtwr-two/mtwr-two-8c5a98e8e8",
        pane_id: "w8:p9", tab_id: "w8:t5", state_change_seq: 86, terminal_id: "term_65ab7aa11a6894c",
        terminal_title_stripped: "Claude Code" },
    ],
    panes: {},
  }],
};

test("herdr: a natively attached host has no mirror — rows name the remote pane only", () => {
  const { rows, warnings } = herdr.normalize(egdevFixture, DEFAULTS.herdr, NOW, new Map());
  assert.equal(rows.length, 2);
  assert.deepEqual(warnings, []);
  assert.equal(rows[0].agent, "pi");
  assert.equal(rows[0].state, "thinking");
  assert.equal(rows[0].project, "mtwr-two-8c5a98e8e8@egdev");
  assert.equal(rows[0].herdr_pane, "");
  assert.equal(rows[0].herdr_host, "egdev");
  assert.equal(rows[0].herdr_remote_pane, "w8:p8");
  const row = toProtocolRow(rows[0], herdr, NOW, 4242);
  assert.equal(row.sessionId, "herdr-egdev-term_65ab7aa1185d34b");
  assert.equal(row.agent, "pi");
  assert.equal(row.entrypoint, "");
  assert.equal("herdr_pane" in row, false); // no local pane: the frontend picks the transport
  assert.equal(row.herdr_host, "egdev");
  assert.equal(row.herdr_remote_pane, "w8:p8");
});

test("herdr: hosts fail independently — a dead host keeps last-good rows for a few polls, then drops", async () => {
  const memory = new Map();
  const cfg = { hosts: ["dexter", "egdev"] };
  let egdevUp = true;
  const list = async (host) => {
    if (host === "egdev" && !egdevUp) throw new Error(`${host}: ssh: connect timed out`);
    return [{ agent: "claude", agent_status: "idle", cwd: `/home/${host}`, pane_id: "w1:p1",
              state_change_seq: 1, terminal_id: `term_${host}` }];
  };
  let raw = await herdr.fetchRaw(cfg, list, memory);
  assert.deepEqual(raw.hosts.map((h) => h.host), ["dexter", "egdev"]);
  assert.deepEqual(raw.failed, []);

  egdevUp = false;
  for (let i = 0; i < herdr.STALE_POLLS; i++) {
    raw = await herdr.fetchRaw(cfg, list, memory);
    assert.deepEqual(raw.hosts.map((h) => h.host), ["dexter", "egdev"]); // still served from last-good
    assert.equal(raw.hosts[1].stale, "egdev: ssh: connect timed out");
    assert.deepEqual(raw.failed, []);
  }
  raw = await herdr.fetchRaw(cfg, list, memory);
  assert.deepEqual(raw.hosts.map((h) => h.host), ["dexter"]); // budget spent: egdev is out
  assert.equal(raw.failed.length, 1);
  assert.equal(raw.failed[0].host, "egdev");
  const { rows, warnings } = herdr.normalize(raw, DEFAULTS.herdr, NOW, new Map());
  assert.equal(rows.length, 1);
  assert.equal(rows[0].herdr_host, "dexter");
  assert.match(warnings[0], /^egdev: unreachable/);

  egdevUp = true; // back: rows return on the very next poll
  raw = await herdr.fetchRaw(cfg, list, memory);
  assert.deepEqual(raw.hosts.map((h) => h.host), ["dexter", "egdev"]);

  // No host answering and nothing left to serve: the vendor poll itself fails.
  egdevUp = false;
  await assert.rejects(herdr.fetchRaw({ hosts: ["egdev"] }, list, new Map()), /egdev/);
});

// --- omnigent: shapes captured from a live `GET /v1/sessions` + `/v1/hosts` (2026-09-24)

const omniSession = (over) => ({
  id: "8a4bc9efff0248529f17d1277502afb7", agent_id: "ag_1", agent_name: "claude-native-ui",
  status: "idle", created_at: NOW - 3000, updated_at: NOW - 600, title: "System operational check",
  host_id: "94d35f487e8143aea400abb354884d62", workspace: "/home/ubuntu/projects/automation-testing",
  viewer_unread: false, pending_elicitations_count: 0, parent_session_id: null, archived: false, ...over,
});
const omniRaw = (sessions, over) => ({
  server: "http://egdev.tail33789d.ts.net:6767",
  appServer: "https://egdev.tail33789d.ts.net:6443/",
  sessions,
  hosts: { "94d35f487e8143aea400abb354884d62": "egdev" },
  harness: {},
  ...over,
});

test("omnigent: states — a pending approval beats running; unread idle is done for an hour", () => {
  const raw = omniRaw([
    omniSession({ id: "run", status: "running" }),
    omniSession({ id: "ask", status: "running", pending_elicitations_count: 1 }),
    omniSession({ id: "wait", status: "waiting" }),
    omniSession({ id: "fail", status: "failed" }),
    omniSession({ id: "fresh", status: "idle", viewer_unread: true, updated_at: NOW - 600 }),
    omniSession({ id: "stale", status: "idle", viewer_unread: true, updated_at: NOW - 7200 }),
    omniSession({ id: "read", status: "idle" }),
    omniSession({ id: "new", status: "hibernating" }),
  ]);
  const { rows, warnings } = omnigent.normalize(raw, DEFAULTS.omnigent, NOW);
  assert.deepEqual(rows.map((r) => r.state),
    ["thinking", "question", "question", "error", "done", "idle", "idle", "idle"]);
  assert.deepEqual(warnings, ['unknown omnigent status "hibernating"']);
});

test("omnigent: rows carry the harness's agent, folder@host, and via Omnigent", () => {
  const raw = omniRaw([
    omniSession({ id: "a" }),
    omniSession({ id: "b", agent_name: "native-codex", workspace: null }),
    omniSession({ id: "c", agent_name: "polly" }),     // harness from the detail lookup
    omniSession({ id: "d", agent_name: "goose-native" }), // no AgentBar mascot
  ], { harness: { c: "claude-native" } });
  const { rows } = omnigent.normalize(raw, DEFAULTS.omnigent, NOW);
  assert.deepEqual(rows.map((r) => r.agent), ["claude", "codex", "claude", "omnigent"]);
  assert.equal(rows[0].project, "automation-testing@egdev");
  assert.equal(rows[1].project, "egdev");
  assert.equal(rows[0].prompt, "System operational check");
  const row = toProtocolRow(rows[0], omnigent, NOW, 4242);
  assert.equal(row.via, "Omnigent");
  assert.equal(row.entrypoint, "cloud"); // a click opens url; no approval affordances
  assert.equal(row.sessionId, "omnigent-a");
  assert.equal(omnigent.agentFor("claude_code:explore-supabase"), "claude");
  assert.equal(omnigent.agentFor("agy"), "antigravity");
  assert.equal(omnigent.agentFor("pineapple"), null); // whole tokens only
});

test("omnigent: app links only where the app infers the right scheme; else the web route", () => {
  const url = (over, cfg = DEFAULTS.omnigent) =>
    omnigent.normalize(omniRaw([omniSession({ id: "s1" })], over), cfg, NOW).rows[0].url;
  assert.equal(url({}), "omnigent://egdev.tail33789d.ts.net:6443/c/s1");
  assert.equal(url({ appServer: "http://127.0.0.1:6767/" }), "omnigent://127.0.0.1:6767/c/s1");
  // Plain http off-loopback: the app would try https — open the session in the browser.
  assert.equal(url({ appServer: "http://100.109.180.102:6767/" }), "http://100.109.180.102:6767/c/s1");
  assert.equal(url({ appServer: "" }), "http://egdev.tail33789d.ts.net:6767/c/s1");
  assert.equal(url({}, { ...DEFAULTS.omnigent, openIn: "web" }), "https://egdev.tail33789d.ts.net:6443/c/s1");
});

test("omnigent: expired token renews before polling; a 401 renews once; no login fails", async () => {
  const server = "http://egdev.tail33789d.ts.net:6767";
  const nowS = Date.now() / 1000;
  const mkIO = ({ expires, statuses, refreshOK = true }) => {
    const calls = { refresh: 0, gets: [] };
    let tokens = { [server]: { token: "old", expires_at: expires, refresh_token: "r" } };
    const io = {
      configServer: () => `${server}/`,
      readTokens: () => tokens,
      refresh: async () => {
        calls.refresh += 1;
        if (refreshOK) tokens = { [server]: { token: "new", expires_at: nowS + 3600, refresh_token: "r2" } };
        return refreshOK;
      },
      get: async (url, token) => {
        calls.gets.push([url.replace(server, ""), token]);
        const status = statuses.length ? statuses.shift() : 200;
        const body = url.includes("/v1/hosts") ? { hosts: [{ host_id: "h", name: "egdev" }] }
          : url.includes("/v1/sessions?") ? { data: [omniSession({ agent_name: "polly" }),
                                                     omniSession({ id: "child", parent_session_id: "x" })] }
          : { harness: "codex-native" };
        return { status, body: status === 200 ? body : null };
      },
      appServer: () => "",
    };
    return { io, calls };
  };
  const fresh = () => ({ hosts: null, hostsAt: 0, harness: new Map() });

  let { io, calls } = mkIO({ expires: nowS - 100, statuses: [] });
  const raw = await omnigent.fetchRaw(DEFAULTS.omnigent, io, fresh());
  assert.equal(calls.refresh, 1);
  assert.ok(calls.gets.every(([, t]) => t === "new"));
  assert.equal(raw.sessions.length, 1); // sub-agent child dropped
  assert.deepEqual(raw.hosts, { h: "egdev" });
  assert.deepEqual(raw.harness, { [raw.sessions[0].id]: "codex-native" });

  ({ io, calls } = mkIO({ expires: nowS + 3600, statuses: [401] }));
  await omnigent.fetchRaw(DEFAULTS.omnigent, io, fresh());
  assert.equal(calls.refresh, 1);
  assert.deepEqual(calls.gets.slice(0, 2).map(([, t]) => t), ["old", "new"]);

  ({ io, calls } = mkIO({ expires: nowS - 100, statuses: [], refreshOK: false }));
  await assert.rejects(omnigent.fetchRaw(DEFAULTS.omnigent, io, fresh()), /omnigent login/);

  ({ io, calls } = mkIO({ expires: nowS + 3600, statuses: [503] }));
  await assert.rejects(omnigent.fetchRaw(DEFAULTS.omnigent, io, fresh()), /HTTP 503/);
});

// --- retention / policy

test("keepRow: thinking always kept; done/error age out by retention", () => {
  const cfg = { retentionMinutes: { done: 60, error: 240 }, syntheticErrorRow: true };
  assert.ok(keepRow({ state: "thinking", updated_at: NOW - 900000 }, cfg, NOW));
  assert.ok(keepRow({ state: "done", updated_at: NOW - 59 * 60 }, cfg, NOW));
  assert.ok(!keepRow({ state: "done", updated_at: NOW - 61 * 60 }, cfg, NOW));
  assert.ok(!keepRow({ state: "error", updated_at: NOW - 241 * 60 }, cfg, NOW));
  assert.ok(!keepRow({ state: null, updated_at: NOW }, cfg, NOW));
  assert.ok(keepRow({ state: "question", updated_at: NOW - 3600, recentHours: 48 }, cfg, NOW));
  assert.ok(!keepRow({ state: "question", updated_at: NOW - 49 * 3600, recentHours: 48 }, cfg, NOW));
});

test("toProtocolRow: cloud invariants — cwd empty, entrypoint cloud, ts frozen when terminal", () => {
  const meta = { agentId: "devin", prefix: "cloud-devin-" };
  const active = toProtocolRow({ id: "s1", state: "thinking", label: "Working", project: "P",
    url: "https://x", updated_at: NOW - 500 }, meta, NOW, 4242);
  assert.equal(active.cwd, "");
  assert.equal(active.entrypoint, "cloud");
  assert.equal(active.pid, 4242);
  assert.equal(active.started, true);
  assert.equal(active.ts, NOW);
  assert.equal(active.sessionId, "cloud-devin-s1");
  const finished = toProtocolRow({ id: "s2", state: "done", label: "", project: "P",
    url: "https://x", updated_at: NOW - 500 }, meta, NOW, 4242);
  assert.equal(finished.ts, NOW - 500); // frozen: the row must age out, not stay fresh
  const suspended = toProtocolRow({ id: "s3", state: "idle", label: "", project: "P",
    url: "https://x", updated_at: NOW - 900 }, meta, NOW, 4242);
  assert.equal(suspended.ts, NOW - 900); // frozen too: ts = when it last worked (sort key)
});

test("safeId: sanitizes and stays unique past 64 chars", () => {
  assert.equal(safeId("cloud-codex-task_e_69dd"), "cloud-codex-task_e_69dd");
  assert.equal(safeId("we/ird id!"), "we-ird-id-");
  const long = "cloud-cursor-" + "x".repeat(100);
  const a = safeId(long);
  const b = safeId(long + "y");
  assert.equal(a.length, 64);
  assert.notEqual(a, b); // head-only truncation would collide
});

test("epoch: ISO, numeric seconds, numeric ms; garbage in, 0 out", () => {
  assert.equal(epoch("2026-08-24T10:00:00.000Z"), 1787565600);
  assert.equal(epoch("1787641783"), 1787641783);      // Devin v3: seconds as string
  assert.equal(epoch(1787641783), 1787641783);
  assert.equal(epoch(1787641783199), 1787641783);     // milliseconds collapse to seconds
  assert.equal(epoch("nope"), 0);
  assert.equal(epoch(undefined), 0);
});
