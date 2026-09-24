#!/usr/bin/env node
// Drive Scripts/hooks/pi/agentbar.ts against a mock Pi event bus and assert
// the state.d writes. HOME must already be a throwaway (the suite sets it).
import { pathToFileURL } from "node:url";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";

const handlers = {};
const pi = { on: (e, h) => { handlers[e] = h; } };
const mod = await import(pathToFileURL(process.argv[2]).href);
mod.default(pi);

const sid = "2026-08-27T00-00-00Z_abc";
const ctx = {
  cwd: "/tmp/proj",
  sessionManager: { getSessionFile: () => "/tmp/" + sid + ".jsonl" },
  model: { id: "claude-fable-5" },
};
const f = path.join(os.homedir(), ".agentbar/state.d", sid + ".json");
const fail = (n, msg) => { console.error(msg); process.exit(n); };

handlers.session_start({}, ctx);
const idle = JSON.parse(fs.readFileSync(f, "utf8"));
if (idle.agent !== "pi" || idle.started !== false)
  fail(2, "session_start: " + JSON.stringify(idle));
if (idle.model !== "claude-fable-5") fail(2, "model not recorded");

handlers.before_agent_start({ prompt: "fix the auth bug" }, ctx);
handlers.tool_execution_start({ toolName: "bash" }, ctx);
const tool = JSON.parse(fs.readFileSync(f, "utf8"));
if (tool.state !== "tool" || tool.label !== "Running command" || tool.started !== true)
  fail(3, "tool: " + JSON.stringify(tool));
if (tool.prompt !== "fix the auth bug") fail(4, "prompt: " + tool.prompt);
if (tool.recap) fail(4, "working row kept recap");

handlers.agent_end({ messages: [{ role: "assistant", content: [{ type: "text", text: "Fixed it." }] }] }, ctx);
const done = JSON.parse(fs.readFileSync(f, "utf8"));
if (done.state !== "done" || done.recap !== "Fixed it.")
  fail(5, "done: " + JSON.stringify(done));

handlers.after_provider_response({ status: 429 }, ctx);
const err = JSON.parse(fs.readFileSync(f, "utf8"));
if (err.state !== "error") fail(6, "error: " + JSON.stringify(err));

handlers.session_shutdown({}, ctx);
if (fs.existsSync(f)) fail(7, "session_shutdown left " + f);
