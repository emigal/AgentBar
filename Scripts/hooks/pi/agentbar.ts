// AgentBar bridge for Pi. Loaded as a Pi extension
// (~/.pi/agent/extensions/agentbar.ts), it maps Pi's event bus to a
// per-session state file in ~/.agentbar/state.d/. Observe-only: writes state,
// decides nothing, never returns { block: true } — a status bridge must never
// take a Pi session down with it.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn, execSync } from "node:child_process";

const AGENT = "pi";
const BUNDLE_ID = "com.michalstrnadel.agentbar";
const base = path.join(os.homedir(), ".agentbar");
const stateDir = path.join(base, "state.d");

const TOOL_LABELS = {
  bash: "Running command",
  read: "Reading",
  write: "Writing",
  edit: "Editing",
};

const safeId = (s) => String(s || "").replace(/[^A-Za-z0-9_.-]/g, "").slice(0, 64) || "unknown";
const sliceSafe = (s, n) => {
  const cut = s.slice(0, n);
  const last = cut.charCodeAt(cut.length - 1);
  return last >= 0xd800 && last <= 0xdbff ? cut.slice(0, -1) : cut;
};
const oneLine = (s, n = 120) => sliceSafe(String(s).replace(/\s+/g, " ").trim(), n);
const writeAtomic = (file, obj) => {
  const tmp = file + "." + process.pid + ".tmp";
  fs.writeFileSync(tmp, JSON.stringify(obj));
  fs.renameSync(tmp, file);
};
const running = () => {
  if (process.platform === "darwin") {
    try { execSync("pgrep -x AgentBar", { stdio: "ignore" }); return true; } catch {}
  }
  try {
    const w = JSON.parse(fs.readFileSync(path.join(base, "watcher.json"), "utf8"));
    return Date.now() / 1000 - w.ts < 60;
  } catch { return false; }
};

const cleanRecap = (text) => {
  const cleaned = String(text || "")
    .replace(/```[^]*?```/g, " ")
    .replace(/^#{1,6}\s+/gm, "")
    .replace(/^\s*[-*+]\s+/gm, "")
    .replace(/^\s*\d+[.)]\s+/gm, "")
    .replace(/[`*_]/g, "")
    .replace(/\s+/g, " ")
    .trim();
  return sliceSafe(cleaned, 160);
};

const recapFromMessages = (messages) => {
  if (!Array.isArray(messages)) return "";
  for (let i = messages.length - 1; i >= 0; i--) {
    const m = messages[i];
    if (!m || m.role !== "assistant") continue;
    let text = "";
    if (typeof m.content === "string") text = m.content;
    else if (Array.isArray(m.content)) {
      text = m.content.map((b) =>
        (b && b.type === "text" && b.text) ? b.text : "").join(" ");
    }
    const recap = cleanRecap(text);
    if (recap) return recap;
  }
  return "";
};

const modelName = (ctx) => {
  const m = ctx && ctx.model;
  if (!m) return "";
  if (typeof m === "string") return m;
  return m.id || m.name || "";
};

const sessionId = (ctx) => {
  const file = ctx && ctx.sessionManager && ctx.sessionManager.getSessionFile
    && ctx.sessionManager.getSessionFile();
  if (typeof file === "string" && file) return path.basename(file, path.extname(file));
  return "pi-" + process.pid;
};

export default function (pi) {
  let id = "";
  let cwd = process.cwd();
  let launched = false;

  const launchOnce = () => {
    if (launched || process.platform !== "darwin") return;
    launched = true;
    if (running()) return;
    try { spawn("open", ["-g", "-b", BUNDLE_ID], { stdio: "ignore", detached: true }).unref(); }
    catch {}
  };

  const write = (patch) => {
    if (!id) return;
    try {
      fs.mkdirSync(stateDir, { recursive: true });
      const statePath = path.join(stateDir, safeId(id) + ".json");
      let prev = {};
      try { prev = JSON.parse(fs.readFileSync(statePath, "utf8")); } catch {}
      const working = patch.state === "thinking" || patch.state === "tool";
      const started = patch.started === false ? false
        : (working || patch.state === "done" || patch.state === "error") ? true
        : (prev.started || false);
      const out = {
        agent: AGENT,
        project: path.basename(cwd),
        cwd,
        sessionId: id,
        entrypoint: "cli",
        term_program: process.env.TERM_PROGRAM || "",
        // The extension runs inside the pi process, so this pid is the
        // session's own liveness handle.
        pid: process.pid,
        started,
        started_at: prev.started_at || Math.floor(Date.now() / 1000),
        ...(prev.prompt ? { prompt: prev.prompt } : {}),
        ...(prev.model ? { model: prev.model } : {}),
        ...(!working && prev.recap ? { recap: prev.recap } : {}),
        ...patch,
        ts: Math.floor(Date.now() / 1000),
      };
      out.started = started;
      writeAtomic(statePath, out);
    } catch {}
  };

  const remove = () => {
    if (!id) return;
    try { fs.rmSync(path.join(stateDir, safeId(id) + ".json"), { force: true }); } catch {}
  };

  pi.on("session_start", (_event, ctx) => {
    try {
      id = sessionId(ctx);
      cwd = (ctx && ctx.cwd) || process.cwd();
      launchOnce();
      const model = modelName(ctx);
      write({
        state: "idle", label: "", started: false,
        ...(model ? { model } : {}),
      });
    } catch {}
  });

  pi.on("session_shutdown", () => { try { remove(); } catch {} });

  pi.on("before_agent_start", (event, ctx) => {
    try {
      if (!id) { id = sessionId(ctx); cwd = (ctx && ctx.cwd) || cwd; }
      const prompt = typeof event.prompt === "string" ? oneLine(event.prompt) : "";
      const model = modelName(ctx);
      write({
        state: "thinking", label: "Thinking…",
        ...(prompt && !prompt.startsWith("/") ? { prompt } : {}),
        ...(model ? { model } : {}),
      });
    } catch {}
  });

  pi.on("agent_start", (_event, ctx) => {
    try {
      if (!id) { id = sessionId(ctx); cwd = (ctx && ctx.cwd) || cwd; }
      write({ state: "thinking", label: "Thinking…" });
    } catch {}
  });

  pi.on("tool_execution_start", (event) => {
    try {
      const tool = String((event && event.toolName) || "");
      const label = TOOL_LABELS[tool] || oneLine(tool || "Using tool");
      write({ state: "tool", label });
    } catch {}
  });

  pi.on("tool_execution_end", () => {
    try { write({ state: "thinking", label: "Thinking…" }); } catch {}
  });

  pi.on("agent_end", (event) => {
    try {
      const recap = recapFromMessages(event && event.messages);
      write({ state: "done", label: "", ...(recap ? { recap } : {}) });
    } catch {}
  });

  pi.on("model_select", (event, ctx) => {
    try {
      const model = (event && event.model && (event.model.id || event.model.name)) || modelName(ctx);
      if (model) write({ model: String(model) });
    } catch {}
  });

  pi.on("after_provider_response", (event) => {
    try {
      const status = Number(event && event.status) || 0;
      if (status >= 400) write({ state: "error", label: oneLine("provider returned " + status) });
    } catch {}
  });
}
