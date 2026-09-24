import Cocoa

/// Live status for Claude Cowork sessions — the agent mode inside the Claude
/// desktop app.
///
/// Hooks can't reach these. Cowork spawns Claude Code with `CLAUDE_CONFIG_DIR`
/// pointing at a directory it creates *per session*
/// (`…/local-agent-mode-sessions/<account>/<org>/<session>/.claude`) and loads
/// only the `user` setting source from it, under the name `cowork_settings.json`
/// — so there is no stable file AgentBar could install hooks into, and a session
/// running in VM mode executes the CLI inside a sandbox that can't write to
/// `~/.agentbar` anyway.
///
/// Two on-host signals, both upserted onto the same `~/.agentbar/state.d`
/// protocol the hooks use:
///
/// 1. **Older local mode.** `<session>/audit.jsonl`: one JSON line per turn
///    event, including `permission_request` / `permission_response` pairs.
/// 2. **Cowork tab.** The conversation lives in the cloud / VM (`cse_01*` in
///    the UI, `session_01*` / `rcw-*` on the host). Chat-only turns never
///    touch `audit.jsonl` or even `remote-session-spaces.json` (that's only
///    granted folders). Live identity is a tool call (`[remote-bash]` /
///    `vmOneShot`) or a renderer `chat-draft:cse_01*` write — not every
///    `cse_01*` in `claude.ai-web.log`. Those logs are mostly reconnect
///    failures (`sign_for_session_header_failed`, MCP 400s); treating them
///    as activity marked dead tabs "thinking" and a click then asked Claude
///    to reconnect a VM that was already gone. Permission prompts stay
///    inside the sandbox. Tab rows only exist while the turn is live.
final class CoworkWatcher {
    private static let home = FileManager.default.homeDirectoryForCurrentUser
    private static let root = home
        .appendingPathComponent("Library/Application Support/Claude/local-agent-mode-sessions",
                                isDirectory: true)
    private static let mainLog = home
        .appendingPathComponent("Library/Logs/Claude/main.log")
    private static let vmLog = home
        .appendingPathComponent("Library/Logs/Claude/cowork_vm_node.log")
    /// Renderer WAL: UTF-16 `chat-draft:cse_01…` writes while the composer
    /// is live. Follow-only (no historical seed) so old drafts don't resurrect.
    private static let indexedDB = home
        .appendingPathComponent("Library/Application Support/Claude/IndexedDB/https_claude.ai_0.indexeddb.leveldb",
                                isDirectory: true)

    private static let claudeBundleID = "com.anthropic.claudefordesktop"

    /// Session directories (and their sibling metadata JSON) are named `local_<uuid>`.
    private static let sessionPrefix = "local_"

    /// A working turn appends to the audit log constantly — measured on real
    /// transcripts the median gap is ~1s and p95 ~5s; the only longer gaps are the
    /// app waiting on the human, which we detect explicitly. 90s of silence
    /// therefore means the turn is over, even when it ended without a `result`
    /// (app quit, crash, cancelled turn). The same window applies to Cowork-tab
    /// rows: tool-call log lines and renderer writes arrive per tool / per
    /// stream chunk, not per token.
    private static let workingWindow: TimeInterval = 90

    /// An unanswered `permission_request` stays pending until the user answers it
    /// in the app — there is no timeout on their side. Past this the session is
    /// treated as abandoned rather than waiting, so a prompt left open yesterday
    /// doesn't come back as "needs approval" when AgentBar restarts. Cowork-tab
    /// rows do not use this window — they vanish after `workingWindow` of no
    /// tool call / composer write, so a dead remote session can't linger.
    private static let pendingWindow: TimeInterval = 6 * 3600

    /// A request and its response land within ~3 KB of each other, so a tail this
    /// size always holds the pair when one exists. Audit logs reach tens of MB —
    /// they are never read whole. The same budget seeds the desktop app's logs
    /// on first scan (then we follow from the last offset).
    private static let tailBytes: UInt64 = 1024 * 1024
    private static let tailLines = 200

    /// One audit line can be megabytes on its own (a tool result carrying a
    /// base64 image — 6.6 MB observed). Those are `user`/`assistant` payloads,
    /// never a permission or result event, so they are counted but not decoded.
    private static let maxParsableLine = 512 * 1024

    private static let logDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.timeZone = .current
        return f
    }()

    private var timer: Timer?
    /// Session dir path (local) or session id (VM) -> what we last published, so
    /// an untouched signal isn't re-parsed. "thinking" is exempt: it ages out.
    private var published: [String: (ts: TimeInterval, state: String)] = [:]
    /// Session dir path -> (metadata mtime, title).
    private var titles: [String: (stamp: Date, title: String)] = [:]
    /// Log path -> byte offset already consumed. Shrinks on rotation.
    private var logOffset: [String: UInt64] = [:]
    /// Lowercased `session_01*` -> last activity timestamp from host logs / renderer stores.
    private var remoteActivity: [String: TimeInterval] = [:]
    /// Same key -> original id as seen (prefer mixed-case `cse_01*` for the deep link).
    private var remoteRaw: [String: String] = [:]

    func start() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: Self.root.path)
                || fm.fileExists(atPath: Self.mainLog.path)
                || fm.fileExists(atPath: Self.vmLog.path)
                || fm.fileExists(atPath: Self.indexedDB.path) else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.scan()
        }
    }

    private func scan() {
        // No app, no Cowork. Its pid also anchors every row we write: SessionStore
        // prunes on a dead pid, so quitting Claude clears the sessions by itself.
        guard let claude = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == Self.claudeBundleID
        }) else { return }
        let pid = claude.processIdentifier
        let now = Date().timeIntervalSince1970

        for dir in Self.sessionDirs() {
            let audit = dir.appendingPathComponent("audit.jsonl")
            guard let mtime = (try? FileManager.default.attributesOfItem(atPath: audit.path))?[.modificationDate]
                    as? Date else { continue }
            let ts = mtime.timeIntervalSince1970
            let age = now - ts
            guard age < Self.pendingWindow else { continue }
            // Settled state on an untouched log: nothing can have changed.
            if let prev = published[dir.path], prev.ts == ts, prev.state != "thinking" { continue }
            guard let read = Self.inspect(audit) else { continue }

            var state = "done"
            var label = ""
            if let pending = read.pending {
                let tool = pending["tool_name"] as? String ?? "tool"
                if tool == "AskUserQuestion" {
                    // Claude asking the human, not asking for permission — same
                    // distinction the Claude hook makes.
                    let q = ((pending["tool_input"] as? [String: Any])?["questions"] as? [[String: Any]])?
                        .first?["question"] as? String
                    state = "question"
                    label = "❓ " + Self.oneLine(q ?? "Waiting for your answer")
                } else {
                    state = "permission"
                    label = Self.prettyTool(tool)
                }
            } else if !read.finished, age < Self.workingWindow {
                state = "thinking"
            }

            let id = String(dir.lastPathComponent.filter { $0.isLetter || $0.isNumber || "-_.".contains($0) }
                .prefix(64))
            upsert(id: id, project: title(for: dir), cwd: "",
                   state: state, label: label, ts: ts, pid: pid,
                   recap: state == "done" ? read.recap : "",
                   link: "claude://claude.ai/local_sessions/\(id)")
            published[dir.path] = (ts, state)
        }

        scanRemote(now: now, pid: pid)
    }

    // MARK: - Layout

    /// `<root>/<accountId>/<orgId>/local_*` plus the `agent/` subtree the app uses
    /// for its own background agent sessions. Both hold the same session layout.
    private static func sessionDirs() -> [URL] {
        var out: [URL] = []
        for account in directories(in: root) {
            for org in directories(in: account) {
                out += sessions(in: org)
                out += sessions(in: org.appendingPathComponent("agent", isDirectory: true))
            }
        }
        return out
    }

    private static func sessions(in dir: URL) -> [URL] {
        directories(in: dir).filter { $0.lastPathComponent.hasPrefix(sessionPrefix) }
    }

    private static func directories(in dir: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        return items.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
    }

    /// The session's display name lives in the metadata file sitting next to its
    /// directory (`local_<uuid>.json`): `title` once the app has named the
    /// conversation, otherwise the generated process name.
    private func title(for dir: URL) -> String {
        let meta = dir.deletingLastPathComponent()
            .appendingPathComponent(dir.lastPathComponent + ".json")
        let stamp = (try? FileManager.default.attributesOfItem(atPath: meta.path))?[.modificationDate] as? Date
        if let cached = titles[dir.path], cached.stamp == stamp { return cached.title }
        var name = "Cowork session"
        if let data = try? Data(contentsOf: meta),
           let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let title = (o["title"] as? String) ?? ""
            let process = (o["processName"] as? String) ?? ""
            if !title.isEmpty { name = Self.oneLine(title) } else if !process.isEmpty { name = process }
        }
        if let stamp { titles[dir.path] = (stamp, name) }
        return name
    }

    // MARK: - Audit log

    /// Reads the tail of an audit log and answers the two questions the state
    /// machine needs: has the turn ended, and is a permission prompt open.
    ///
    /// nil means the log couldn't be read at all. An *empty* tail is not nil: a
    /// single line longer than the whole window leaves no complete line to parse,
    /// and the session must still be reported (it is plainly active — something
    /// just wrote megabytes into it) rather than dropped from the menu.
    private static func inspect(_ url: URL) -> (finished: Bool, pending: [String: Any]?, recap: String)? {
        guard let lines = tail(url) else { return nil }

        // One slot per line, so `events.last` really is the last line: an unparsed
        // blob is an event we know isn't a `result` and isn't a permission event.
        var events: [[String: Any]] = []
        events.reserveCapacity(lines.count)
        for line in lines {
            guard line.utf8.count <= maxParsableLine,
                  let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
            else { events.append([:]); continue }
            events.append(o)
        }

        var pending: [String: Any]?
        if let i = events.lastIndex(where: { $0["subtype"] as? String == "permission_request" }) {
            let uuid = events[i]["uuid"] as? String ?? ""
            let answered = events[(i + 1)...].contains {
                $0["subtype"] as? String == "permission_response" && $0["uuid"] as? String == uuid
            }
            if !answered { pending = events[i] }
        }
        let finished = events.last?["type"] as? String == "result"
        // The result event carries the turn's closing words — the same recap the
        // Claude hook reads from its transcript, from the only signal Cowork has.
        let recap = finished ? cleanRecap(events.last?["result"] as? String ?? "") : ""
        return (finished, pending, recap)
    }

    /// One quiet line out of a markdown result: fences and list furniture out,
    /// link text kept (Cowork results end with a `computer://` link whose text is
    /// the deliverable's name), whitespace collapsed, capped at 160.
    private static func cleanRecap(_ s: String) -> String {
        var t = s
        t = t.replacingOccurrences(of: "```[\\s\\S]*?```", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\[([^\\]]*)\\]\\([^)]*\\)", with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: "(?m)^#{1,6}\\s+", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "(?m)^\\s*[-*+]\\s+", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "(?m)^\\s*\\d+[.)]\\s+", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "[`*_]", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return String(t.prefix(160))
    }

    /// Complete lines at the end of the file, oldest first. Walks backwards in
    /// blocks until it has seen enough newlines or read `tailBytes`, then decodes
    /// from there and drops the leading fragment.
    private static func tail(_ url: URL) -> [Substring]? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        guard size > 0 else { return nil }
        let block: UInt64 = 64 * 1024
        var from = size
        var newlines = 0
        while from > 0, size - from < tailBytes, newlines <= tailLines {
            let chunk = min(block, from)
            from -= chunk
            try? fh.seek(toOffset: from)
            guard let d = try? fh.read(upToCount: Int(chunk)) else { break }
            newlines += d.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
        }
        try? fh.seek(toOffset: from)
        guard let data = try? fh.readToEnd() else { return nil }
        // Lossy on purpose: the window can start mid-codepoint, and the damage is
        // confined to the partial first line, which is dropped anyway.
        var lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        if from > 0, !lines.isEmpty { lines.removeFirst() }
        return lines
    }

    /// `mcp__cowork__request_cowork_directory` → `request_cowork_directory`;
    /// `webfetch:github.com` → `webfetch: github.com`. Remote MCP servers are
    /// namespaced by uuid, which is worth nothing in a menu row.
    private static func prettyTool(_ raw: String) -> String {
        var tool = raw
        if tool.hasPrefix("mcp__") {
            tool = tool.components(separatedBy: "__").last ?? tool
        }
        if let colon = tool.firstIndex(of: ":"), tool.index(after: colon) < tool.endIndex,
           tool[tool.index(after: colon)] != " " {
            tool.replaceSubrange(colon...colon, with: ": ")
        }
        return oneLine(tool)
    }

    private static func oneLine(_ s: String) -> String {
        let flat = s.split(whereSeparator: { $0.isNewline || $0 == "\t" })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return flat.count > 80 ? String(flat.prefix(79)) + "…" : flat
    }

    // MARK: - Cowork tab

    /// Host-side liveness for Cowork-tab sessions. Folder grants in
    /// `remote-session-spaces.json` are optional (a chat-only tab never writes
    /// one). Identity is `cse_01*` / `session_01*` / `rcw-01*` collapsed to
    /// `session_01*`. Only a tool call or a live `chat-draft:` counts — reconnect
    /// errors in the web log are not activity. Quiet tabs are dropped, not
    /// kept as "done", so a click can't reopen a VM that's already gone.
    private func scanRemote(now: TimeInterval, pid: Int32) {
        consumeText(Self.mainLog)
        consumeText(Self.vmLog)
        consumeBinaryLogs(in: Self.indexedDB)
        collapseRemotePrefixes()
        remoteActivity = remoteActivity.filter { now - $0.value < Self.workingWindow }
        remoteRaw = remoteRaw.filter { remoteActivity[$0.key] != nil }
        let spaces = remoteSpaces()
        var keeping: Set<String> = []
        for (key, ts) in remoteActivity {
            let age = now - ts
            guard age < Self.workingWindow else { continue }
            let folders = spaces[key]?.folders ?? []
            let display = spaces[key]?.id ?? key
            if let prev = published[display], prev.ts == ts, prev.state != "thinking" { continue }
            let project = folders.first.map { URL(fileURLWithPath: $0).lastPathComponent }
                ?? "Cowork session"
            let cwd = folders.first ?? ""
            let id = String(display.filter { $0.isLetter || $0.isNumber || "-_.".contains($0) }
                .prefix(64))
            upsert(id: id, project: Self.oneLine(project), cwd: cwd,
                   state: "thinking", label: "", ts: ts, pid: pid,
                   link: Self.coworkLink(from: remoteRaw[key] ?? display))
            published[display] = (ts, "thinking")
            keeping.insert(id)
        }
        dropStaleRemote(keeping: keeping)
    }

    /// Cowork-tab rows we wrote that have gone quiet (or were only ever a
    /// reconnect error) — delete so they can't sit in the menu as live work.
    private func dropStaleRemote(keeping: Set<String>) {
        let dir = SessionStore.stateDir
        let items = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for url in items where url.pathExtension == "json" {
            let id = url.deletingPathExtension().lastPathComponent
            guard id.hasPrefix("session_01"), !keeping.contains(id) else { continue }
            guard let data = try? Data(contentsOf: url),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (o["agent"] as? String ?? "claude") == "claude",
                  (o["entrypoint"] as? String) == "claude-desktop" else { continue }
            try? FileManager.default.removeItem(at: url)
        }
        for (display, _) in published where !display.contains("/") {
            let id = String(display.filter { $0.isLetter || $0.isNumber || "-_.".contains($0) }
                .prefix(64))
            if !keeping.contains(id) { published.removeValue(forKey: display) }
        }
    }

    /// `<root>/<accountId>/<orgId>/remote-session-spaces.json` → lowercased
    /// session id -> (canonical id, granted folders).
    private func remoteSpaces() -> [String: (id: String, folders: [String])] {
        var out: [String: (id: String, folders: [String])] = [:]
        for account in Self.directories(in: Self.root) {
            for org in Self.directories(in: account) {
                let url = org.appendingPathComponent("remote-session-spaces.json")
                guard let data = try? Data(contentsOf: url),
                      let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let entries = o["entries"] as? [[String: Any]] else { continue }
                for e in entries {
                    guard let sid = e["sessionId"] as? String, sid.hasPrefix("session_") else { continue }
                    out[sid.lowercased()] = (sid, e["folders"] as? [String] ?? [])
                }
            }
        }
        return out
    }

    /// Follow a text log from the last offset (or the last `tailBytes` on first
    /// sight / after rotation). Only `[remote-bash] user=rcw-…` and
    /// `[vmOneShot] … as rcw-…` count — scraping every `cse_01*` picked up
    /// reconnect failures and marked dead tabs as thinking.
    private func consumeText(_ url: URL) {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        guard size > 0 else { return }
        var from = logOffset[url.path] ?? 0
        if size < from { from = 0 } // rotated
        // First sight (or post-rotation) of a large log: seed from the tail.
        // That cut is mid-line, so the leading fragment has to go. A follow
        // from a previous EOF is already on a line boundary — dropping there
        // would eat the first new event.
        var dropFirst = false
        if from == 0, size > Self.tailBytes {
            from = size - Self.tailBytes
            dropFirst = true
        }
        try? fh.seek(toOffset: from)
        guard let data = try? fh.readToEnd(), !data.isEmpty else {
            logOffset[url.path] = size
            return
        }
        var text = String(decoding: data, as: UTF8.self)
        if dropFirst, let nl = text.firstIndex(of: "\n") {
            text.removeSubrange(...nl)
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let ts = Self.logTimestamp(in: line) ?? Date().timeIntervalSince1970
            if let rcw = Self.remoteUser(in: line) { noteRemote(rcw, ts: ts) }
        }
        logOffset[url.path] = size
    }

    /// Chromium numbered WAL (`000130.log`). Follow-only: a seed would pick up
    /// every historical `chat-draft:cse_01*` still sitting in the file. New
    /// bytes stamp `now`, and only `chat-draft:` keys count — a dump of the
    /// shown-sessions set would otherwise resurrect yesterday's tabs.
    private func consumeBinaryLogs(in dir: URL) {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for url in items {
            guard url.pathExtension == "log" else { continue }
            let stem = url.deletingPathExtension().lastPathComponent
            guard !stem.isEmpty, stem.allSatisfy(\.isNumber) else { continue }
            consumeBinary(url)
        }
    }

    private func consumeBinary(_ url: URL) {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        guard size > 0 else { return }
        if logOffset[url.path] == nil {
            logOffset[url.path] = size
            return
        }
        var from = logOffset[url.path] ?? 0
        if size < from { from = 0 } // rotated
        guard size > from else { return }
        try? fh.seek(toOffset: from)
        guard let data = try? fh.readToEnd(), !data.isEmpty else {
            logOffset[url.path] = size
            return
        }
        let ts = Date().timeIntervalSince1970
        for id in Self.draftIds(in: data) { noteRemote(id, ts: ts) }
        logOffset[url.path] = size
    }

    /// UTF-16LE truncation can emit `…why8` next to `…why8h`. Keep the longer.
    private func collapseRemotePrefixes() {
        let keys = remoteActivity.keys.sorted { $0.count > $1.count }
        var winners: [String] = []
        for k in keys {
            if winners.contains(where: { $0.hasPrefix(k) }) {
                remoteActivity.removeValue(forKey: k)
                remoteRaw.removeValue(forKey: k)
            } else {
                winners.append(k)
            }
        }
    }

    private func noteRemote(_ raw: String, ts: TimeInterval) {
        let key = Self.canonicalKey(raw)
        guard key.hasPrefix("session_01"), key.count >= 16 else { return }
        if ts >= remoteActivity[key] ?? 0 { remoteActivity[key] = ts }
        rememberRaw(raw, key: key)
    }

    /// Prefer a mixed-case `cse_01*` over a lowercased `session_01*` / `rcw-*`
    /// so the deep link matches the route Claude's UI actually uses.
    private func rememberRaw(_ raw: String, key: String) {
        guard let cur = remoteRaw[key] else { remoteRaw[key] = raw; return }
        let newCse = raw.lowercased().hasPrefix("cse_")
        let oldCse = cur.lowercased().hasPrefix("cse_")
        if newCse, !oldCse { remoteRaw[key] = raw; return }
        if newCse, oldCse, raw != raw.lowercased(), cur == cur.lowercased() {
            remoteRaw[key] = raw
        }
    }

    /// `claude://claude.ai/cowork/cse_01…` — Claude.app's open-url handler
    /// (`fBt`) loads `/cowork/<id>` into the webview. `claude://cowork/…`
    /// without the `claude.ai` host only accepts `/new`.
    private static func coworkLink(from raw: String) -> String {
        var id = raw
        let low = id.lowercased()
        if low.hasPrefix("rcw-") { id = "cse_" + id.dropFirst(4) }
        else if low.hasPrefix("session_") { id = "cse_" + id.dropFirst("session_".count) }
        return "claude://claude.ai/cowork/\(id)"
    }

    /// `rcw-01abc` / `cse_01abc` / `session_01abc` → `session_01abc`.
    private static func canonicalKey(_ raw: String) -> String {
        let s = raw.lowercased()
        if s.hasPrefix("rcw-") { return "session_" + s.dropFirst(4) }
        if s.hasPrefix("cse_") { return "session_" + s.dropFirst(4) }
        return s
    }

    /// `cse_01…` immediately after `chat-draft:` (ASCII or UTF-16LE).
    private static func draftIds(in data: Data) -> [String] {
        let marker = Array("chat-draft:".utf8)
        var out: [String] = []
        var i = 0
        while i < data.count {
            if let n = matchId(data, at: i, prefix: marker + Array("cse_01".utf8), stride: 1) {
                out.append(n.id.replacingOccurrences(of: "chat-draft:", with: ""))
                i = n.next; continue
            }
            if let n = matchId(data, at: i, prefix: marker + Array("cse_01".utf8), stride: 2) {
                out.append(n.id.replacingOccurrences(of: "chat-draft:", with: ""))
                i = n.next; continue
            }
            i += 1
        }
        return out
    }

    private static func matchId(_ data: Data, at i: Int, prefix: [UInt8], stride: Int)
            -> (id: String, next: Int)? {
        var j = i
        for b in prefix {
            guard j < data.count, data[j] == b else { return nil }
            if stride == 2 {
                guard j + 1 < data.count, data[j + 1] == 0 else { return nil }
            }
            j += stride
        }
        var chars: [UInt8] = prefix
        while j < data.count {
            let b = data[j]
            let alnum = (b >= 48 && b <= 57) || (b >= 65 && b <= 90) || (b >= 97 && b <= 122)
            guard alnum else { break }
            if stride == 2 {
                guard j + 1 < data.count, data[j + 1] == 0 else { break }
            }
            chars.append(b)
            j += stride
        }
        guard chars.count - prefix.count >= 8,
              let s = String(bytes: chars, encoding: .utf8) else { return nil }
        return (s, j)
    }

    /// `rcw-<id>` from a remote-bash or vmOneShot line; nil for everything else
    /// (process-memory noise, old local-mode guest names like `pensive-upbeat-euler`).
    private static func remoteUser(in line: Substring) -> String? {
        if let r = rangeAfter(line, marker: "[remote-bash] user="),
           let user = token(in: line, from: r), user.hasPrefix("rcw-") {
            return user
        }
        if line.contains("[vmOneShot]"),
           let r = rangeAfter(line, marker: " as rcw-") {
            let rest = token(in: line, from: r) ?? ""
            return rest.isEmpty ? nil : "rcw-" + rest
        }
        return nil
    }

    private static func rangeAfter(_ line: Substring, marker: String) -> String.Index? {
        guard let r = line.range(of: marker) else { return nil }
        return r.upperBound
    }

    private static func token(in line: Substring, from i: String.Index) -> String? {
        let rest = line[i...]
        let end = rest.firstIndex(where: { $0.isWhitespace || $0 == "]" }) ?? rest.endIndex
        let s = String(rest[..<end])
        return s.isEmpty ? nil : s
    }

    private static func logTimestamp(in line: Substring) -> TimeInterval? {
        guard line.count >= 19 else { return nil }
        let stamp = String(line.prefix(19))
        return logDate.date(from: stamp)?.timeIntervalSince1970
    }

    // MARK: - State file

    private func upsert(id: String, project: String, cwd: String,
                        state: String, label: String, ts: TimeInterval, pid: Int32,
                        recap: String = "", link: String = "") {
        guard !id.isEmpty else { return }
        let url = SessionStore.stateDir.appendingPathComponent(id + ".json")
        var o = ((try? Data(contentsOf: url))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any] ?? [:]
        guard (o["agent"] as? String ?? "claude") == "claude" else { return }
        // Nothing visible changed and the row already points at this app instance.
        if o["state"] as? String == state, o["label"] as? String == label,
           o["pid"] as? Int == Int(pid), (o["ts"] as? Double ?? 0) >= ts,
           (link.isEmpty || o["url"] as? String == link) { return }
        o["agent"] = "claude"
        o["state"] = state
        o["label"] = label
        o["project"] = project
        o["entrypoint"] = "claude-desktop" // row clicks focus the app, not a terminal
        o["term_program"] = ""
        o["cwd"] = cwd
        o["pid"] = Int(pid)
        o["started"] = true
        o["sessionId"] = id
        if !link.isEmpty { o["url"] = link }
        // Set once; elapsed in the frontends depends on it never moving.
        if o["started_at"] == nil { o["started_at"] = Int(ts) }
        // Protocol rule: recap is the LATEST turn's result — a working state must
        // drop the previous turn's line, never carry it forward.
        if state == "done", !recap.isEmpty { o["recap"] = recap } else { o.removeValue(forKey: "recap") }
        o["ts"] = Int(ts)
        guard let data = try? JSONSerialization.data(withJSONObject: o) else { return }
        try? FileManager.default.createDirectory(at: SessionStore.stateDir,
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
