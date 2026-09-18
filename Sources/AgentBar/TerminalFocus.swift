import Cocoa

/// Tab-precision jump-back: land on the exact terminal tab or split pane the
/// session runs in, not just its app. The session's pid (the agent process) has a
/// controlling tty; iTerm2, Terminal.app, and Ghostty expose each tab's tty to
/// AppleScript, WezTerm to its own CLI — matching the two is the whole trick.
/// A session inside a Herdr pane is the exception: its tty is a pty the Herdr
/// server owns, which no terminal lists, so the tab to select is the one hosting
/// the Herdr *attach* (`herdr`, or `herdr --remote <host>`) that renders the pane.
/// Everything here is best effort on a background queue: any miss (no tty,
/// scripting denied, app too old) leaves the plain app-level focus that always
/// runs as the floor.
enum TerminalFocus {
    /// One attempt at a time: a stuck attempt (the Automation consent prompt
    /// can hold osascript for a minute) must queue later clicks, not stack one
    /// blocked thread per click.
    private static let queue = DispatchQueue(label: "agentbar.terminalfocus", qos: .userInitiated)

    /// Whether this terminal can be asked to bring a specific tab forward. A
    /// caller about to TYPE into the session has to know: posting a keystroke
    /// at a terminal we can't aim would hit whatever tab happened to be open.
    static func canTargetTab(termProgram: String) -> Bool {
        ["iTerm.app", "Apple_Terminal", "WezTerm", "Ghostty"].contains(termProgram)
    }

    /// `done` runs on the main queue once the tab select has finished (or
    /// immediately, when there is nothing to select). It reports whether the
    /// session's own tab is now the front one — and, for a session in a Herdr
    /// pane, whether that pane is too — only then is it safe to type.
    static func focus(session: Session, done: ((Bool) -> Void)? = nil) {
        let term = session.termProgram
        let pid = session.pid
        // The floor first and instantly: the user clicked, so the app comes
        // forward now. The precise tab select runs behind it and may land
        // seconds later — first use waits on the Automation consent prompt.
        AgentActions.focusTerminal(named: term)
        queue.async {
            // Herdr first: if the session lives in a Herdr pane, selecting it
            // settles while the (much slower) AppleScript tab select runs — and
            // it names the tty of the tab to select.
            let herdr = focusHerdrPane(session: session)
            var hit = false
            // "" deliberately doesn't match: an unknown terminal must not
            // trigger a Terminal.app Automation prompt for nothing.
            // A remote row's pid belongs to the poller, not the agent. Once
            // Herdr owns the route, a missing attach must not target that pid.
            let targetTTY = herdr == nil ? tty(of: pid) : herdr?.attachTTY
            if canTargetTab(termProgram: term), let tty = targetTTY {
                switch term {
                case "iTerm.app":      hit = selectITermSession(tty: tty)
                case "Apple_Terminal": hit = selectTerminalTab(tty: tty)
                case "WezTerm":        hit = activateWezTermPane(tty: tty)
                case "Ghostty":        hit = focusGhosttyTerminal(tty: tty)
                default:               break // Warp, kitty, …: no per-tab targeting to offer
                }
            }
            // A Herdr-hosted session is targeted only when its tab AND its pane
            // came forward — a tab hit with the wrong pane still types blind.
            let targeted = hit && (herdr?.paneFocused ?? true)
            if let done { DispatchQueue.main.async { done(targeted) } }
        }
    }

    // MARK: - Herdr

    /// What the Herdr step found. `attachTTY` is the tty of the local process
    /// RENDERING the pane — the bare `herdr` attach, or `herdr --remote <host>` —
    /// which is the terminal tab to select; the agent's own tty is a server-owned
    /// pty no terminal app lists. nil `attachTTY` = no attach to aim at.
    struct HerdrFocus {
        var attachTTY: String?
        var paneFocused: Bool
    }

    /// One Herdr attach process from `ps`: `herdr [--session x]` (local) or
    /// `herdr --remote <target> [--session x] [--remote-keybindings …]`.
    struct HerdrAttach: Equatable {
        let pid: Int32
        let tty: String        // "/dev/ttys019"
        let remote: String?    // --remote target as typed; nil for a local attach
        let session: String?   // --session name; nil = the default session
    }

    /// Herdr (terminal multiplexer for coding agents): when the session runs in
    /// a Herdr pane, ask Herdr to select that pane — workspace, tab, and pane —
    /// and say which local attach renders it, so the tab select can aim at that
    /// attach's tab. Best effort like everything here: no binary, no server, or
    /// no match leaves the app-level focus. Routes, most direct first:
    /// 1. a saved connected machine in a combined Ghostty/Herdr client: click
    ///    the machine's row in that client's sidebar while the pane is focused
    ///    on the remote over ssh — the two don't depend on each other;
    /// 2. the row names a local pane (`herdr_pane`: the session's own, or a live
    ///    herdr-mirror pane the cloud poller mapped) — select it;
    /// 3. the row names a remote pane (`herdr_host` / `herdr_remote_pane`):
    ///    a. a `herdr --remote <host>` attach is running — focus the pane on the
    ///       remote server over ssh, project its tab to the client, and aim at
    ///       that attach's terminal tab;
    ///    b. the herdr-mirror plugin knows the host — restore exactly that
    ///       mirror (`herdr-mirror restore <host> <pane>`) and select it once
    ///       the plugin's map file names the fresh local pane;
    ///    c. neither — focus the pane over ssh anyway, so the next attach lands
    ///       on it; the app-level focus is all the tab select gets;
    /// 4. a local session with no fields: Herdr tracks each pane's native agent
    ///    session identity. ID identities match the row directly; path
    ///    identities (Pi) match the session file's basename.
    /// nil = the session isn't Herdr-hosted (or Herdr isn't installed).
    private static func focusHerdrPane(session: Session) -> HerdrFocus? {
        guard let herdr = herdrBinary() else {
            return session.herdrPane.isEmpty && session.herdrHost.isEmpty
                ? nil : HerdrFocus(attachTTY: nil, paneFocused: false)
        }
        if !session.herdrHost.isEmpty && !session.herdrRemotePane.isEmpty,
           let connected = focusConnectedMachine(session: session, herdr: herdr) {
            return connected
        }
        if !session.herdrPane.isEmpty {
            return focusLocalPane(session.herdrPane, termProgram: session.termProgram, herdr: herdr)
        }
        if !session.herdrHost.isEmpty && !session.herdrRemotePane.isEmpty {
            return focusRemotePane(host: session.herdrHost, pane: session.herdrRemotePane, herdr: herdr)
        }
        guard let json = run(herdr, ["agent", "list"]),
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let agents = ((obj["result"] as? [String: Any])?["agents"]
                            ?? obj["agents"]) as? [[String: Any]],
              let match = agents.first(where: { herdrSessionMatches($0, session: session) }),
              let pane = match["pane_id"] as? String
        else { return nil }
        return focusLocalPane(pane, termProgram: session.termProgram, herdr: herdr)
    }

    private static func focusLocalPane(_ pane: String, termProgram: String, herdr: String) -> HerdrFocus {
        let attach = runningHerdrAttach(host: nil)
        // A local row must switch a combined client back to Local too. Clients
        // without saved machines retain the ordinary API-only focus path.
        if let attach, termProgram == "Ghostty",
           let json = run(herdr, ["machine", "list", "--json"]),
           let machines = HerdrMachineNavigation.machines(json: json),
           machines.contains(where: \.enabled) {
            guard focusGhosttyTerminal(tty: attach.tty),
                  HerdrMachineNavigation.select(machine: .local, among: machines, attach: attach, run: { run($0, $1) }) else {
                NSLog("AgentBar: could not select Local in the connected Herdr client")
                DispatchQueue.main.async { NSSound.beep() }
                return HerdrFocus(attachTTY: attach.tty, paneFocused: false)
            }
        }
        return HerdrFocus(attachTTY: attach?.tty, paneFocused: focusPane(pane, herdr: herdr))
    }

    /// Saved machines are rendered by a plain local `herdr`, with an SSH
    /// bridge child per connected host. Switch the machine in that client and
    /// select the pane and its tab on the remote server at the same time: the
    /// ssh round trip is the slow part and the switch doesn't wait for it.
    private static func focusConnectedMachine(session: Session, herdr: String) -> HerdrFocus? {
        guard let json = run(herdr, ["machine", "list", "--json"]),
              let machines = HerdrMachineNavigation.machines(json: json),
              let machine = HerdrMachineNavigation.machine(host: session.herdrHost, in: machines),
              let ps = run("/bin/ps", ["-axo", "pid=,ppid=,tty=,command="]),
              let attach = HerdrMachineNavigation.attach(host: machine.target, ps: ps)
        else { return nil }
        let result = HerdrFocus(attachTTY: attach.tty, paneFocused: false)
        let remote = DispatchGroup()
        var paneFocused = true
        if safeRemoteArg(machine.target), safeRemoteArg(session.herdrRemotePane) {
            DispatchQueue.global(qos: .userInitiated).async(group: remote) {
                paneFocused = focusHerdrTarget(session.herdrRemotePane) { args in
                    guard args.allSatisfy(safeRemoteArg) else { return nil }
                    return sshHerdr(machine.target, args.joined(separator: " "))
                }
            }
        }
        let switched = session.termProgram == "Ghostty" && focusGhosttyTerminal(tty: attach.tty)
            && HerdrMachineNavigation.select(machine: machine, among: machines, attach: attach, run: { run($0, $1) })
        if !switched {
            NSLog("AgentBar: could not select connected Herdr machine %@", machine.label)
        }
        remote.wait()
        if !paneFocused {
            NSLog("AgentBar: could not focus remote Herdr pane %@ on %@", session.herdrRemotePane, machine.target)
        }
        if !switched || !paneFocused { DispatchQueue.main.async { NSSound.beep() } }
        // Remote rows are observation-only. Do not authorize approval typing.
        return result
    }

    /// Steps 3a–3c above. `paneFocused` stays false on purpose: the ssh round
    /// trip runs detached (so the tab switch isn't held ~2 s behind it), and a
    /// remote session can't have a local approval to type into anyway.
    private static func focusRemotePane(host: String, pane: String, herdr: String) -> HerdrFocus {
        if let attach = runningHerdrAttach(host: host) {
            sshFocusPaneDetached(host: host, pane: pane)
            return HerdrFocus(attachTTY: attach.tty, paneFocused: false)
        }
        let mirror = NSHomeDirectory() + "/.local/bin/herdr-mirror"
        if FileManager.default.isExecutableFile(atPath: mirror),
           FileManager.default.fileExists(atPath: mirrorMapPath(host: host)) {
            _ = run(mirror, ["restore", host, pane])
            // The daemon re-mirrors on SIGUSR1; give the map a few seconds to
            // name the recreated pane. A miss leaves the app-level focus.
            for _ in 0..<10 {
                if let local = mirrorLocalPane(host: host, remotePane: pane) {
                    return HerdrFocus(attachTTY: runningHerdrAttach(host: nil)?.tty,
                                      paneFocused: focusPane(local, herdr: herdr))
                }
                usleep(500_000)
            }
            return HerdrFocus(attachTTY: nil, paneFocused: false)
        }
        sshFocusPaneDetached(host: host, pane: pane)
        return HerdrFocus(attachTTY: nil, paneFocused: false)
    }

    /// Herdr reports most native session identities as IDs. Pi reports the full
    /// JSONL session path instead, while AgentBar's row id is that file's basename.
    static func herdrSessionMatches(_ agent: [String: Any], session: Session) -> Bool {
        guard let identity = agent["agent_session"] as? [String: Any],
              let value = identity["value"] as? String
        else { return false }
        if value == session.id { return true }
        guard identity["kind"] as? String == "path",
              (identity["agent"] as? String ?? agent["agent"] as? String) == session.agentID
        else { return false }
        return URL(fileURLWithPath: value).deletingPathExtension().lastPathComponent == session.id
    }

    /// `agent focus` needs Herdr to have recognized an agent on the pane, which
    /// lags a freshly restored mirror — fall back to focusing the pane's tab.
    private static func focusPane(_ pane: String, herdr: String) -> Bool {
        focusHerdrTarget(pane) { run(herdr, $0) }
    }

    /// Herdr 0.9 keeps a separate tab selection for each attached client.
    /// `agent focus` selects the server's pane but does not update those client
    /// views; an explicit `tab focus` projects the selection to them as well.
    /// The runner is injectable so tests exercise the actual command sequence.
    static func focusHerdrTarget(_ pane: String, execute: ([String]) -> String?) -> Bool {
        let focused = execute(["agent", "focus", pane])
        let tab = focused.flatMap { tabID(inHerdrJSON: $0, key: "agent") }
            ?? execute(["pane", "get", pane]).flatMap { tabID(inHerdrJSON: $0, key: "pane") }
        guard let tab else { return false }
        return execute(["tab", "focus", tab]) != nil
    }

    /// The same two steps as `focusPane`, on the remote server, fire-and-forget:
    /// the caller doesn't wait, and a hung ssh (ConnectTimeout plus the run
    /// timeout) can't stall the focus queue. Both arguments land in a remote
    /// shell line, so only plain host/pane characters are let through.
    private static func sshFocusPaneDetached(host: String, pane: String) {
        guard safeRemoteArg(host), safeRemoteArg(pane) else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            _ = focusHerdrTarget(pane) { args in
                guard args.allSatisfy(safeRemoteArg) else { return nil }
                return sshHerdr(host, args.joined(separator: " "))
            }
        }
    }

    /// Non-interactive ssh skips the remote's rc files, so ~/.local/bin (where
    /// Herdr installs) goes on PATH by hand. The remote command is one argv
    /// element: no local shell, nothing to quote here.
    private static func sshHerdr(_ host: String, _ args: String) -> String? {
        run("/usr/bin/ssh",
            ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-o", "LogLevel=ERROR", host,
             "PATH=\"$HOME/.local/bin:$PATH\" herdr \(args)"],
            timeout: 10)
    }

    /// A host, pane, or tab id safe to interpolate into a remote shell line:
    /// letters, digits, `. _ @ : -`, and never option-shaped.
    static func safeRemoteArg(_ s: String) -> Bool {
        !s.isEmpty && !s.hasPrefix("-") && s.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || "._@:-".contains($0))
        }
    }

    /// `herdr agent focus` / `herdr pane get` → the target's tab id.
    private static func tabID(inHerdrJSON json: String, key: String) -> String? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tab = ((obj["result"] as? [String: Any])?[key]
                          as? [String: Any])?["tab_id"] as? String
        else { return nil }
        return tab
    }

    private static func herdrBinary() -> String? {
        [NSHomeDirectory() + "/.local/bin/herdr", "/opt/homebrew/bin/herdr", "/usr/local/bin/herdr"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    /// The attach to aim at, straight from `ps`; nil host = the local session.
    private static func runningHerdrAttach(host: String?) -> HerdrAttach? {
        guard let ps = run("/bin/ps", ["-axo", "pid=,tty=,command="]) else { return nil }
        return herdrAttach(host: host, in: herdrAttaches(ps: ps))
    }

    /// Every Herdr attach on this machine, from `ps -axo pid=,tty=,command=`.
    /// An attach is the `herdr` binary with flags only — a bare word after it is
    /// a subcommand (`server`, `client`, …), not an attach — on a real tty (`??`
    /// is a daemon). `login … herdr-launcher.sh`, `ssh … herdr
    /// remote-client-bridge`, and `herdr-mirror` don't have `herdr` as the
    /// binary's basename and fall out the same way.
    static func herdrAttaches(ps: String) -> [HerdrAttach] {
        var out: [HerdrAttach] = []
        for line in ps.split(separator: "\n") {
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard tokens.count >= 3, let pid = Int32(tokens[0]), tokens[1].hasPrefix("tty"),
                  tokens[2] == "herdr" || tokens[2].hasSuffix("/herdr")
            else { continue }
            var remote: String?
            var session: String?
            var flagsOnly = true
            var i = 3
            while i < tokens.count, flagsOnly {
                let t = tokens[i]
                var flag = t
                var value: String? = i + 1 < tokens.count ? tokens[i + 1] : nil
                var width = 2
                if t.hasPrefix("--"), let eq = t.firstIndex(of: "=") { // --remote=host
                    flag = String(t[..<eq]); value = String(t[t.index(after: eq)...]); width = 1
                }
                switch flag {
                case "--remote":             remote = value; i += width
                case "--session":            session = value; i += width
                case "--remote-keybindings": i += width
                default:                     flagsOnly = t.hasPrefix("-"); i += 1
                }
            }
            guard flagsOnly else { continue }
            out.append(HerdrAttach(pid: pid, tty: "/dev/" + tokens[1], remote: remote, session: session))
        }
        return out
    }

    /// These rows come from the default server. A named session is a different
    /// namespace even when the host and pane id happen to match.
    /// Of matching attaches, prefer the oldest (lowest pid).
    /// `user@host` and `host` name the same machine on either side.
    static func herdrAttach(host: String?, in attaches: [HerdrAttach]) -> HerdrAttach? {
        let bare = { (s: String) -> String in s.split(separator: "@", maxSplits: 1).last.map(String.init) ?? s }
        return attaches
            .filter { a in
                guard a.session == nil || a.session == "default" else { return false }
                guard let host else { return a.remote == nil }
                guard let remote = a.remote else { return false }
                return bare(remote) == bare(host)
            }
            .min { $0.pid < $1.pid }
    }

    private static func mirrorMapPath(host: String) -> String {
        NSHomeDirectory() + "/.local/state/herdr-mirror/\(host)-map.json"
    }

    /// herdr-mirror's map file: the live local pane mirroring `remotePane` on
    /// `host`, nil while none exists (closed mirror, daemon still syncing).
    private static func mirrorLocalPane(host: String, remotePane: String) -> String? {
        guard let data = FileManager.default.contents(atPath: mirrorMapPath(host: host)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = (obj["panes"] as? [String: Any])?[remotePane] as? [String: Any],
              (entry["tombstone"] as? Bool) != true,
              let local = entry["localId"] as? String
        else { return nil }
        return local
    }

    /// "/dev/ttys003" for a live process, nil for daemons ("??") or a dead pid.
    private static func tty(of pid: Int32) -> String? {
        guard pid > 0,
              let out = run("/bin/ps", ["-o", "tty=", "-p", "\(pid)"])?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !out.isEmpty, out != "??"
        else { return nil }
        return "/dev/" + out
    }

    // MARK: - Per-terminal targeting

    /// iTerm2: windows ▸ tabs ▸ sessions, each with a `tty` — select all three.
    /// Prints "hit" when the tty was found, so the caller can tell a real
    /// selection from a silent miss.
    private static func selectITermSession(tty: String) -> Bool {
        let script = """
        on run argv
            set target to item 1 of argv
            tell application "iTerm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is target then
                                select s
                                select t
                                select w
                                return "hit"
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            return "miss"
        end run
        """
        return run("/usr/bin/osascript", ["-e", script, tty], timeout: 60)?
            .contains("hit") == true
    }

    /// Terminal.app: tabs carry the tty directly.
    private static func selectTerminalTab(tty: String) -> Bool {
        let script = """
        on run argv
            set target to item 1 of argv
            tell application "Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is target then
                            set selected of t to true
                            set frontmost of w to true
                            return "hit"
                        end if
                    end repeat
                end repeat
            end tell
            return "miss"
        end run
        """
        return run("/usr/bin/osascript", ["-e", script, tty], timeout: 60)?
            .contains("hit") == true
    }

    /// Ghostty: windows ▸ tabs ▸ terminals (surfaces), each with a `tty` —
    /// select the tab, raise the window, focus the surface. Needs a Ghostty
    /// with the scripting dictionary; an older one errors out into a miss.
    private static func focusGhosttyTerminal(tty: String) -> Bool {
        let script = """
        on run argv
            set target to item 1 of argv
            tell application "Ghostty"
                repeat with w in windows
                    repeat with tb in tabs of w
                        repeat with t in terminals of tb
                            if tty of t is target then
                                select tab tb
                                activate window w
                                focus t
                                return "hit"
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            return "miss"
        end run
        """
        return run("/usr/bin/osascript", ["-e", script, tty], timeout: 60)?
            .contains("hit") == true
    }

    /// WezTerm: its own CLI lists panes with tty_name and can activate by id.
    private static func activateWezTermPane(tty: String) -> Bool {
        guard let wezterm = ["/opt/homebrew/bin/wezterm", "/usr/local/bin/wezterm",
                             "/Applications/WezTerm.app/Contents/MacOS/wezterm"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else { return false }
        guard let json = run(wezterm, ["cli", "list", "--format", "json"]),
              let data = json.data(using: .utf8),
              let panes = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let pane = panes.first(where: { $0["tty_name"] as? String == tty }),
              let id = pane["pane_id"] as? Int
        else { return false }
        return run(wezterm, ["cli", "activate-pane", "--pane-id", "\(id)"]) != nil
    }

    // MARK: - Plumbing

    /// Run a tool, give it a moment, and hand back stdout. Nil on any failure —
    /// callers treat every miss the same way: the app-level focus already ran.
    /// osascript gets a generous window because its first run blocks on the
    /// Automation consent prompt; killing it under the user would eat the dialog.
    /// Stdout drains as it arrives — waiting for exit before reading deadlocks
    /// the moment output outgrows the pipe buffer (a long `wezterm cli list`).
    private static func run(_ path: String, _ args: [String],
                            timeout: TimeInterval = 8) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        var buffer = Data()
        let lock = NSLock()
        pipe.fileHandleForReading.readabilityHandler = { h in
            let chunk = h.availableData
            guard !chunk.isEmpty else { return }
            lock.lock(); buffer.append(chunk); lock.unlock()
        }
        defer { pipe.fileHandleForReading.readabilityHandler = nil }
        do { try p.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline {
            usleep(50_000)
        }
        if p.isRunning { p.terminate(); return nil }
        // A last drain — with the handler off first, so the two readers never
        // pull from the descriptor at the same time.
        pipe.fileHandleForReading.readabilityHandler = nil
        if let rest = try? pipe.fileHandleForReading.readToEnd(), !rest.isEmpty {
            lock.lock(); buffer.append(rest); lock.unlock()
        }
        guard p.terminationStatus == 0 else { return nil }
        lock.lock(); defer { lock.unlock() }
        return String(decoding: buffer, as: UTF8.self)
    }
}
