# agentbar-cloud

External poller that mirrors **non-local** coding-agent runs into the AgentBar
menu bar: Cursor cloud agents, Devin sessions, and Codex cloud tasks become
protocol rows in `~/.agentbar/state.d/` (`entrypoint: "cloud"`, a `url`, this
poller's pid). Clicking a row opens the run where it lives — cursor.com /
app.devin.ai / chatgpt.com. No changes to the app beyond the protocol's
optional `url` field.

A fourth adapter covers **remote Herdr machines**: `ssh <host> herdr agent
list` surfaces every agent Herdr recognizes there (no AgentBar hooks needed on
the remote). Those rows aren't cloud rows — they name the remote pane, and a
click goes wherever you view that machine from: a connected machine in an
existing combined Herdr window, a `herdr --remote <host>` tab
(the pane is focused over ssh and that tab comes forward), or a herdr-mirror
pane (`herdr_pane`) — if that mirror was closed, the click restores exactly it
(`herdr-mirror restore <host> <pane>`) and then focuses it. With neither open,
the pane is still focused on the remote so the next attach lands on it.

For **Herdr 0.9 connected machines in Ghostty**, AgentBar finds the local client
from its SSH bridge and clicks the machine's row in the client's sidebar —
Ghostty's scripting dictionary sends the mouse event to that exact surface, and
AgentBar reads the surface's accessibility text to locate the row first and to
confirm the switch afterwards. Nothing opens and nothing is typed; the remote
tab and pane are focused over ssh in parallel. This keeps the existing combined
window; no separate remote terminal is opened. Local rows switch back to Local.
Only when the sidebar is collapsed, hidden, or scrolled past the machine does
AgentBar fall back to Herdr's native navigator, honoring the configured
`keys.prefix` and `keys.goto` shortcuts. Allow AgentBar in macOS **Privacy &
Security → Accessibility** and allow its Ghostty Automation request; Ghostty
must have AppleScript enabled, and Herdr's `ui.mouse_capture` must stay on
(the default). Ghostty's `window-padding-*` settings are read from its config
files so the click lands on the right cell. An unverifiable target stops the
jump with a beep. Profile targets must match `herdr.hosts` and use the default
remote session, since that is the session the poller observes.

A fifth adapter covers a **self-hosted Omnigent server** (`omnigent server` on
a box you reach over e.g. Tailscale). Every session it runs — Claude Code,
Codex, Pi, Goose… — becomes a row under that agent's own mascot (a ring for
agents AgentBar has no mascot for), with an "Omnigent" chip and
`folder@host`. It polls `GET /v1/sessions` with the Omnigent CLI's login: the
bearer token in `~/.omnigent/auth_tokens.json`, renewed through the CLI's own
Python (`omnigent.cli_auth.refresh_stored_token`, under the CLI's file lock)
when it is about to expire. If that renewal fails, run `omnigent login`.

A click opens the exact session in Omnigent.app through its deep link,
`omnigent://<host>/c/<session>`. The link names only a host, and the app
assumes http for localhost and https for everything else. So links are used
only when the app's own server (read from its `settings.json`) is https or
loopback. An app pinned to plain http on a LAN or Tailscale address would
otherwise ask to trust an https server that isn't there. Those clicks open the
same session in the browser instead (`<server>/c/<session>`). To get app links,
put the server behind HTTPS, e.g. on the server box:

```bash
sudo tailscale serve --bg --https=6443 http://<tailscale-ip>:6767
```

then point Omnigent.app at `https://<box>.<tailnet>.ts.net:6443`. Rows switch
to app links on the next poll.

## Setup

```bash
./Scripts/cloud/install.sh        # writes a starter ~/.agentbar/cloud.json + launchd agent
./Scripts/cloud/install.sh uninstall
```

Config `~/.agentbar/cloud.json` (chmod 600 — it holds API keys):

```jsonc
{
  "pollSeconds": 30,
  "retentionMinutes": { "done": 60, "error": 240 }, // how long finished/failed rows linger
  "syntheticErrorRow": true,   // one clickable "<vendor>: auth failed" row on persistent failure
  "cursor": { "enabled": true, "apiKey": "…",  // cursor.com/dashboard -> API Keys
              "openIn": "app",                 // cursor:// run deep link; "web" = cursor.com/agents/<id>
              "apiVersion": "v1" },            // "v0" = legacy status-on-agent endpoint
  "devin":  { "enabled": true, "apiKey": "…",  // app.devin.ai Settings -> API Keys
              "openIn": "app",                 // focuses Devin Desktop (no per-session deep link
                                               // exists); "web" = app.devin.ai/sessions/<id>, thread-precise
              "recentHours": 48, "showSuspended": false },
  "codex":  { "enabled": true },               // rides `codex login`, no key needed
  "herdr":  { "enabled": true,
              "hosts": ["dexter", "egdev"],    // ssh targets — the same string you pass
                                               // to `herdr --remote <host>` (or the
                                               // herdr-mirror host name in hosts.toml)
              "termProgram": "Ghostty" },      // terminal hosting your Herdr tabs
  "omnigent": { "enabled": true,               // rides `omnigent login`, no key needed
                "server": "",                  // "" = `server:` in ~/.omnigent/config.yaml
                "appServer": "",               // "" = Omnigent.app's server (where links open)
                "openIn": "app",               // "web" = always the browser
                "recentHours": 24 }            // how long idle sessions stay listed
}
```

Keys may also come from `CURSOR_API_KEY` / `DEVIN_API_KEY` in the launchd
environment instead of the file.

## Behavior

- Poll every 30 s (codex 60 s — it shells out to `codex cloud list --json`;
  herdr 20 s — one `ssh <host> herdr agent list` per host, key auth required:
  `ssh -o BatchMode=yes <host> true` must succeed — a row click uses the same
  ssh to focus the pane). Hosts fail independently: a host that stops
  answering keeps its last rows for three polls, then drops them; the vendor
  only fails (error row below) when every host does. omnigent 15 s: one
  session list, plus a one-time detail lookup for sessions whose agent name
  doesn't say which harness runs them.
- After each **successful** vendor poll the vendor's rows are reconciled to the
  fresh set; a vendor that keeps failing (~5 min) gets its rows replaced by one
  clickable error row. Vendors never affect each other's rows.
- Actively working runs always show; finished/failed runs age out per
  `retentionMinutes`; blocked/suspended ones per `recentHours`.
- Rows carry the poller's pid: stop the poller and the app prunes them.

## Dev

```bash
node Scripts/cloud/index.js --once   # single poll, then exit
node --test Scripts/cloud/test/*.test.js      # pure-function tests, no network
```
