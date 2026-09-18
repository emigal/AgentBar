import Foundation

// Minimal collaborators let this test compile the production TerminalFocus.swift
// directly without launching AgentBar or a Herdr UI.
struct Session {
    let id: String
    let agentID: String
    let termProgram = ""
    let pid: Int32 = 0
    let herdrPane = ""
    let herdrHost = ""
    let herdrRemotePane = ""
}

enum AgentActions {
    static func focusTerminal(named: String) {}
}

enum KeystrokeApprover {
    static func requestAccess() {}
}

@main
struct TerminalFocusTest {
    static func main() {
        sessionMatching()
        attachDiscovery()
        clientTabFocus()
        connectedMachines()
        sidebarClick()
        navigatorConfiguration()
        machineNavigation()
        remoteArgs()
    }

    static func sessionMatching() {
        let pi = Session(
            id: "2026-08-27T20-11-00-449Z_01a044d8-e5e1-7c2b-b6ef-5d1da4913949",
            agentID: "pi"
        )
        let piAgent: [String: Any] = [
            "agent": "pi",
            "agent_session": [
                "agent": "pi",
                "kind": "path",
                "value": "/Users/test/.pi/agent/sessions/project/\(pi.id).jsonl",
            ],
        ]
        check(TerminalFocus.herdrSessionMatches(piAgent, session: pi),
              "Pi path identity should match the AgentBar session id")

        let claude = Session(id: "abc-123", agentID: "claude")
        let claudeAgent: [String: Any] = [
            "agent": "claude",
            "agent_session": ["agent": "claude", "kind": "id", "value": "abc-123"],
        ]
        check(TerminalFocus.herdrSessionMatches(claudeAgent, session: claude),
              "existing id identity matching should remain supported")

        var wrongAgent = piAgent
        wrongAgent["agent_session"] = [
            "agent": "claude",
            "kind": "path",
            "value": "/tmp/\(pi.id).jsonl",
        ]
        check(!TerminalFocus.herdrSessionMatches(wrongAgent, session: pi),
              "path identities from another agent should not match")

        var wrongFile = piAgent
        wrongFile["agent_session"] = [
            "agent": "pi",
            "kind": "path",
            "value": "/tmp/different-session.jsonl",
        ]
        check(!TerminalFocus.herdrSessionMatches(wrongFile, session: pi),
              "a different Pi session file should not match")
    }

    // `ps -axo pid=,tty=,command=` as it really looks with a local Herdr, a
    // `herdr --remote egdev` attach, and their helpers (captured 2026-09-05),
    // plus a few synthetic attaches for the selection rules.
    static func attachDiscovery() {
        let ps = """
        62485 ??       /Users/emigal/.local/bin/herdr server
        62482 ttys000  /usr/bin/login -flp emigal /bin/bash --noprofile --norc -c exec -l /Users/emigal/.local/bin/herdr-launcher.sh
        62484 ttys000  /Users/emigal/.local/bin/herdr
        12126 ttys019  herdr --remote egdev --remote-keybindings server
        12218 ttys019  /Users/emigal/.local/bin/herdr client
        12231 ttys019  ssh -F /var/folders/x/T/herdr-ssh-12126-0/config -S /var/folders/x/T/herdr-ssh-12126-0/ctl -o ControlMaster=auto -T egdev exec /home/ubuntu/.local/bin/herdr remote-client-bridge
        78588 ??       /Users/emigal/.config/herdr/plugins/github/mirror-00154761637c/target/release/herdr-mirror daemon
        40001 ttys021  herdr --remote ubuntu@egdev --session scratch
        40002 ttys022  herdr --session other
        40003 ttys023  herdr --remote=dexter --handoff
        """
        let attaches = TerminalFocus.herdrAttaches(ps: ps)
        check(attaches.count == 5,
              "server, client, login, ssh bridge, and herdr-mirror are not attaches (got \(attaches.count))")
        check(!attaches.contains { $0.tty.hasSuffix("??") }, "a daemon is never an attach")
        check(TerminalFocus.herdrAttach(host: "egdev", in: attaches)?.tty == "/dev/ttys019",
              "the egdev attach is the default-session one, not the named session")
        check(TerminalFocus.herdrAttach(host: "ubuntu@egdev", in: attaches)?.tty == "/dev/ttys019",
              "user@host in the config names the same machine")
        check(TerminalFocus.herdrAttach(host: nil, in: attaches)?.tty == "/dev/ttys000",
              "the local attach is the default session even when a named one has a lower pid")
        check(TerminalFocus.herdrAttach(host: "dexter", in: attaches)?.tty == "/dev/ttys023",
              "--remote=host is the same flag")
        check(TerminalFocus.herdrAttach(host: "nope", in: attaches) == nil,
              "a host nobody is attached to has no tab")

        let twoLocal = """
        300 ttys005  herdr
        200 ttys004  /opt/homebrew/bin/herdr
        """
        check(TerminalFocus.herdrAttach(host: nil, in: TerminalFocus.herdrAttaches(ps: twoLocal))?.pid == 200,
              "two attaches to the same session: the oldest wins")

        let namedOnly = TerminalFocus.herdrAttaches(ps: "40001 ttys021 herdr --remote egdev --session scratch")
        check(TerminalFocus.herdrAttach(host: "egdev", in: namedOnly) == nil,
              "a named session must not receive default-session pane ids")
        let explicitDefault = TerminalFocus.herdrAttaches(ps: "40001 ttys021 herdr --remote egdev --session default")
        check(TerminalFocus.herdrAttach(host: "egdev", in: explicitDefault)?.tty == "/dev/ttys021",
              "an explicit default session is a valid attach")
    }

    static func clientTabFocus() {
        var calls: [[String]] = []
        let focused = TerminalFocus.focusHerdrTarget("wY:p8") { args in
            calls.append(args)
            if args == ["agent", "focus", "wY:p8"] {
                return #"{"result":{"agent":{"pane_id":"wY:p8","tab_id":"wY:t3"}}}"#
            }
            if args == ["tab", "focus", "wY:t3"] { return #"{"result":{"type":"ok"}}"# }
            return nil
        }
        check(focused, "focusing an agent also selects the attached client tab")
        check(calls == [["agent", "focus", "wY:p8"], ["tab", "focus", "wY:t3"]],
              "a successful agent focus still needs an explicit client tab focus on Herdr 0.9")

        calls = []
        let mirrorFocused = TerminalFocus.focusHerdrTarget("w13:pE") { args in
            calls.append(args)
            if args == ["pane", "get", "w13:pE"] {
                return #"{"result":{"pane":{"tab_id":"w13:t4"}}}"#
            }
            if args == ["tab", "focus", "w13:t4"] { return "{}" }
            return nil
        }
        check(mirrorFocused && calls.last == ["tab", "focus", "w13:t4"],
              "a freshly restored mirror without agent detection still selects its tab")

        check(!TerminalFocus.focusHerdrTarget("wY:p8") { args in
            args == ["agent", "focus", "wY:p8"]
                ? #"{"result":{"agent":{"tab_id":"wY:t3"}}}"# : nil
        }, "agent focus alone must not report success when the client tab switch fails")
        check(!TerminalFocus.focusHerdrTarget("wY:p8") { _ in "{}" },
              "missing tab identity must not guess from the pane id")
    }

    static func remoteArgs() {
        for ok in ["egdev", "ubuntu@egdev", "w8:p9", "w8:t5", "dev-box.local"] {
            check(TerminalFocus.safeRemoteArg(ok), "\(ok) is a plain remote argument")
        }
        for bad in ["", "-oProxyCommand=x", "w8:p9;rm", "a b", "host`x`", "$HOME"] {
            check(!TerminalFocus.safeRemoteArg(bad), "\(bad) must never reach a remote shell line")
        }
    }

    static func connectedMachines() {
        let machines = #"[{"id":"egdev-id","label":"Build box","target":"egdev","session":"default","enabled":true},{"id":"other-id","label":"egdev","target":"other-host","session":"default","enabled":true},{"id":"named-id","label":"Scratch","target":"egdev","session":"scratch","enabled":true}]"#
        check(HerdrMachineNavigation.machine(host: "egdev", json: machines)?.id == "egdev-id",
              "SSH target and session identify the saved machine, not its label")
        check(HerdrMachineNavigation.machine(host: "egdev", json: machines.replacingOccurrences(of: "true", with: "false")) == nil,
              "disabled saved machines must not be selected")
        check(HerdrMachineNavigation.machine(host: "egdev", json: machines.replacingOccurrences(of: "Scratch", with: "Build box")) == nil,
              "ambiguous labels cannot be selected through the navigator")
        check(HerdrMachineNavigation.machine(host: "egdev", json: "{}") == nil,
              "older CLIs without machine list leave legacy routing available")

        let ps = """
        95239 1 ?? /Users/emigal/.local/bin/herdr server
        35093 34655 ttys004 herdr
        32303 35093 ttys004 ssh -o BatchMode=yes -T egdev exec /home/ubuntu/.local/bin/herdr remote-client-bridge
        28345 35093 ttys004 ssh -o BatchMode=yes -T dexter exec /home/emi/.local/bin/herdr remote-client-bridge
        200 1 ttys001 herdr
        400 1 ttys005 herdr --session scratch
        401 400 ttys005 ssh -T egdev exec /home/ubuntu/.local/bin/herdr remote-client-bridge
        500 1 ttys006 herdr --remote egdev
        501 500 ttys006 ssh -T egdev exec /home/ubuntu/.local/bin/herdr remote-client-bridge
        """
        check(HerdrMachineNavigation.attach(host: "egdev", ps: ps)?.tty == "/dev/ttys004",
              "a connected machine belongs to its bridge's parent client, not the oldest or last terminal")
        check(HerdrMachineNavigation.attach(host: "missing", ps: ps) == nil,
              "a plain Herdr client without a matching SSH bridge must not be guessed")
    }

    /// Herdr 0.9 expanded sidebar as Ghostty's accessibility text shows it
    /// (captured 2026-09-18), next to pane content that repeats the same words.
    static func sidebarScreen(active: String = "Local", footer: String? = nil, egdev: String = " ▾ egdev                ●") -> String {
        let footer = footer ?? (" new · \(active)" + String(repeating: " ", count: 12 - active.count) + "● menu")
        return [" machines                ", "                         ", " ▾ Local                 ",
                "   ● AgentBar            ", "     emi                 ", egdev,
                "   ○ ~                   ", "   ○ egdev               ", " ▾ menubox              ●",
                " ▾ dexter  ◐ reconnecting", "   · ~                   ", "                         ", footer]
            .map { $0 + "│ ▾ egdev ● new · egdev ● menu " }.joined(separator: "\n")
    }

    static func sidebarClick() {
        let labels = ["egdev", "dexter", "menubox"]
        let sidebar = HerdrMachineNavigation.sidebar(screen: sidebarScreen(), labels: labels)
        check(sidebar?.active == "Local", "the footer's new-workspace button names the machine on screen")
        check(sidebar?.machineRow(label: "egdev") == 5, "an online machine row is the click target")
        check(sidebar?.machineRow(label: "Local", local: true) == 2, "Local has no connection glyph")
        check(sidebar?.machineRow(label: "dexter") == nil, "a reconnecting machine is not a live target")
        check(sidebar?.machineRow(label: "menubox") == 8, "a label containing the launcher's word is a plain label")
        check(sidebar?.machineRow(label: "eg") == nil, "a label must match whole, not as a prefix")
        check(HerdrMachineNavigation.sidebar(screen: sidebarScreen(active: "menubox"), labels: labels)?.active == "menubox"
              && HerdrMachineNavigation.sidebar(screen: sidebarScreen(active: "menubox"), labels: labels)?.machineRow(label: "egdev") == 5,
              "the sidebar is cut at the launcher even when the active label contains its word")
        check(HerdrMachineNavigation.sidebar(screen: sidebarScreen(footer: " new · Local           menu"), labels: labels)?.active == "Local",
              "the launcher without an attention dot still marks the sidebar's edge")
        check(HerdrMachineNavigation.sidebar(screen: sidebarScreen(egdev: " ▾ egdev               ●▕"), labels: labels)?.machineRow(label: "egdev") == 5,
              "a scrollbar beside the glyph does not hide the row")
        check(HerdrMachineNavigation.sidebar(screen: sidebarScreen(footer: "                         "), labels: labels) == nil,
              "no footer (hidden or collapsed sidebar, mouse capture off) means no click target")
        check(HerdrMachineNavigation.sidebar(screen: sidebarScreen(active: "egdev"), labels: ["dexter"]) == nil,
              "an unknown active label fails closed rather than guessing the sidebar's width")

        var padding = HerdrMachineNavigation.Padding()
        padding.apply(ghosttyConfig: "window-padding-x = 2,4\nwindow-padding-y = 8\n# window-padding-x = 30\nwindow-padding-balance = true\nwindow-padding-x = 8")
        check(padding == HerdrMachineNavigation.Padding(left: 8, right: 8, top: 8, bottom: 8, balance: true),
              "Ghostty padding: left,right pairs, later lines override, comments ignored")
        padding.apply(ghosttyConfig: "window-padding-balance = false\nwindow-padding-y = 2,x")
        check(padding == HerdrMachineNavigation.Padding(left: 8, right: 8, top: 8, bottom: 8, balance: false),
              "a later file overrides; an unparsable value keeps the previous one")

        // The surface the live client was measured in: 2304×1189 pt, 286×75
        // cells at 2x — the click at these points switched machines.
        let size = CGSize(width: 2304, height: 1189)
        let eight = HerdrMachineNavigation.Padding(left: 8, right: 8, top: 8, bottom: 8)
        check(HerdrMachineNavigation.cellCenter(row: 5, column: 6, size: size, rows: 75, columns: 286, padding: eight, scale: 2) == CGPoint(x: 60, y: 93.25),
              "cell centres come from whole-pixel cells anchored at the top-left padding")
        check(HerdrMachineNavigation.cellCenter(row: 2, column: 6, size: size, rows: 75, columns: 286, padding: eight, scale: 2) == CGPoint(x: 60, y: 46.75),
              "rows are cell height apart")
        var balanced = eight
        balanced.balance = true
        check(HerdrMachineNavigation.cellCenter(row: 5, column: 6, size: size, rows: 75, columns: 286, padding: balanced, scale: 2) == CGPoint(x: 60, y: 98.5),
              "balanced padding moves the grid down by half the leftover")
        check(HerdrMachineNavigation.cellCenter(row: 0, column: 0, size: size, rows: 0, columns: 286, padding: eight, scale: 2) == nil,
              "an empty grid has no cells")

        var active = "Local"
        var clicks: [CGPoint] = []
        let screen = { HerdrMachineNavigation.Surface(text: sidebarScreen(active: active), size: size, scale: 2) }
        let clicked = HerdrMachineNavigation.click(label: "egdev", labels: labels, padding: eight, surface: screen,
                                                   clickAt: { clicks.append($0); active = "egdev"; return true }, waitFor: { $0() })
        let rows = sidebarScreen().components(separatedBy: "\n").count
        check(clicked == .selected && clicks == [HerdrMachineNavigation.cellCenter(row: 5, column: 5, size: size, rows: rows, columns: 56, padding: eight, scale: 2)!],
              "the click lands inside the machine's label on its sidebar row")

        clicks = []
        check(HerdrMachineNavigation.click(label: "egdev", labels: labels, padding: eight, surface: screen,
                                           clickAt: { clicks.append($0); return true }, waitFor: { $0() }) == .alreadyActive && clicks.isEmpty,
              "the machine already on screen is not clicked — on the active row a click folds the group")
        check(HerdrMachineNavigation.click(label: "dexter", labels: labels, padding: eight, surface: screen,
                                           clickAt: { clicks.append($0); return true }, waitFor: { $0() }) == .rowHidden && clicks.isEmpty,
              "a machine without a live row is left to the navigator")
        check(HerdrMachineNavigation.click(label: "Local", local: true, labels: labels, padding: eight,
                                           surface: { HerdrMachineNavigation.Surface(text: "agent output", size: size, scale: 2) },
                                           clickAt: { clicks.append($0); return true }, waitFor: { $0() }) == .rowHidden && clicks.isEmpty,
              "no sidebar on screen means nothing is clicked")
        check(HerdrMachineNavigation.click(label: "Local", local: true, labels: labels, padding: eight, surface: screen,
                                           clickAt: { clicks.append($0); return true }, waitFor: { $0() }) == .failed && clicks.count == 1,
              "a click the footer never confirms is a failure, not a success")
    }

    static func navigatorConfiguration() {
        typealias Key = HerdrMachineNavigation.Key
        check(HerdrMachineNavigation.navigatorKeys(config: "") == [Key(name: "b", modifiers: "control"), Key(name: "g", modifiers: "")],
              "Herdr's default native navigator shortcut")
        check(HerdrMachineNavigation.navigatorKeys(config: """
        [keys]
        prefix = "ctrl+space"
        [[keys.command]]
        key = "prefix+t"
        type = "plugin_action"
        command = "herdr-navigator.open"
        """) == [Key(name: "space", modifiers: "control"), Key(name: "g", modifiers: "")],
              "the user's custom prefix and separate navigator plugin preserve the native shortcut")
        check(HerdrMachineNavigation.navigatorKeys(config: "[keys]\ngoto = ['alt+g', 'prefix+g'] # alternate") == [Key(name: "g", modifiers: "option")],
              "a custom native navigator binding is honored")
        check(HerdrMachineNavigation.navigatorKeys(config: "[keys]\nprefix = 'ctrl+]'\ngoto = 'prefix+G'") == [Key(name: "bracketRight", modifiers: "control"), Key(name: "g", modifiers: "shift")],
              "punctuation and uppercase chords use Ghostty's key names and modifiers")
        for config in ["[keys]\ngoto = []", "[keys]\nprefix = unsupported", "[keys]\ngoto = 'prefix+g'\nsettings = 'prefix+g'", "[[keys.command]]\nkey = 'prefix+g'"] {
            check(HerdrMachineNavigation.navigatorKeys(config: config) == nil,
                  "unsupported, disabled, or conflicting bindings must fail closed: \(config)")
        }
    }

    /// Source-derived native Herdr 0.9 navigator fixture, including another
    /// machine whose workspace happens to match the egdev search text.
    static func navigatorScreen(query: String, searching: Bool, selected: String, online: Bool = true) -> String {
        let width = 100
        func pad(_ value: String) -> String { value + String(repeating: " ", count: max(0, width - value.count)) }
        let rows = [" ▾ Local", "   ▾ egdev-work", pad(" ▾ egdev").dropLast(online ? 1 : 14) + (online ? "●" : "◐ reconnecting"), "   ▾ remote-project"]
        let header = " / \(query.isEmpty && !searching ? "search panes" : query)"
        let heading = header + String(repeating: " ", count: width - header.count - 7) + "8 panes"
        let footer = searching
            ? " search type · move ↑↓/ctrl+n/p · open enter · back esc"
            : " move j/k · expand space · filter a/b/w/i/d · search / · open enter · close esc"
        // Extra vertical borders outside the navigator must not be mistaken
        // for its right edge.
        return (["╭" + String(repeating: "─", count: width) + "╮"]
            + ([heading, String(repeating: "─", count: width)] + rows + [" \(selected) · ", footer]).map { "│" + pad(String($0)) + "│" }
            + ["╰" + String(repeating: "─", count: width) + "╯"])
            .map { "│sidebar " + $0 + " outside│" }.joined(separator: "\n")
    }

    static func machineNavigation() {
        typealias Key = HerdrMachineNavigation.Key
        let fixture = navigatorScreen(query: "egdev", searching: true, selected: "Local")
        check(HerdrMachineNavigation.navigator(screen: fixture)?.machineRow(label: "egdev") == 2,
              "machine navigation distinguishes egdev from local workspaces matching its name")
        check(HerdrMachineNavigation.navigator(screen: fixture)?.machineRow(label: "Local", local: true) == 0,
              "Local has no connection indicator and remains reachable from a remote machine")
        check(HerdrMachineNavigation.navigator(screen: navigatorScreen(query: "egdev", searching: true, selected: "Local", online: false))?.machineRow(label: "egdev") == nil,
              "a reconnecting machine is not a selectable live target")
        check(HerdrMachineNavigation.navigator(screen: "search panes\n▾ egdev\nopen enter") == nil,
              "ordinary terminal output is not a native navigator")

        var opened = false
        var searching = false
        var query = ""
        var selectedRow = 0
        var events: [String] = []
        let selected = HerdrMachineNavigation.select(label: "egdev", keys: [Key(name: "b", modifiers: "control"), Key(name: "g", modifiers: "")], screen: {
            opened ? navigatorScreen(query: query, searching: searching, selected: selectedRow == 2 ? "egdev" : "Local") : "Herdr terminal"
        }, sendKey: { key in
            events.append(key.name)
            switch key.name {
            case "g": opened = true
            case "slash": searching = true
            case "u": query = ""
            case "escape": searching = false
            case "home": selectedRow = 0
            case "arrowDown": selectedRow += 1
            case "enter": opened = false
            default: break
            }
            return true
        }, inputText: { value in
            check(opened && searching, "search text must only enter the native navigator")
            events.append("text"); query = value; return true
        }, waitFor: { $0() })
        check(selected && selectedRow == 2 && events.last == "enter",
              "the existing combined window selects egdev through its machine row")
        check(events.filter { $0 == "arrowDown" }.count == 2,
              "matching workspace text on another machine must not receive the click")

        opened = true
        searching = true
        query = "egdev"
        events = []
        let local = HerdrMachineNavigation.select(label: "Local", local: true, keys: [], screen: {
            opened ? navigatorScreen(query: query, searching: searching, selected: "Local") : "Herdr local terminal"
        }, sendKey: {
            events.append($0.name)
            if $0.name == "escape" { searching = false }
            if $0.name == "enter" { opened = false }
            return true
        }, inputText: { query = $0; return true }, waitFor: { $0() })
        check(local && events.last == "enter" && !events.contains("arrowDown"),
              "clicking a local agent returns the existing client to Local")

        events = []
        let missing = HerdrMachineNavigation.select(label: "egdev", keys: [Key(name: "g", modifiers: "")], screen: { "agent prompt" }, sendKey: {
            events.append($0.name); return true
        }, inputText: { _ in events.append("text"); return true }, waitFor: { $0() })
        check(!missing && events == ["g"], "a navigator that does not open receives no search text or Enter")

        events = []
        let unreadable = HerdrMachineNavigation.select(label: "egdev", keys: [Key(name: "g", modifiers: "")], screen: { nil }, sendKey: {
            events.append($0.name); return true
        }, inputText: { _ in events.append("text"); return true }, waitFor: { $0() })
        check(!unreadable && events.isEmpty, "unreadable or unfocused terminals receive no input")

        events = []
        var readable = true
        let lostFocus = HerdrMachineNavigation.select(label: "egdev", keys: [], screen: {
            readable ? navigatorScreen(query: "egdev", searching: true, selected: "egdev") : nil
        }, sendKey: { events.append($0.name); return true }, inputText: { _ in readable = false; return true }, waitFor: { $0() })
        check(!lostFocus && !events.contains("enter"), "losing terminal focus during a search aborts navigation")

        events = []
        let disconnected = HerdrMachineNavigation.select(label: "egdev", keys: [], screen: {
            navigatorScreen(query: "egdev", searching: true, selected: "egdev", online: false)
        }, sendKey: { events.append($0.name); return true }, inputText: { _ in true }, waitFor: { $0() })
        check(!disconnected && !events.contains("enter"), "a disconnected machine must never be accepted")

        events = []
        let wrongSelection = HerdrMachineNavigation.select(label: "egdev", keys: [], screen: {
            navigatorScreen(query: "egdev", searching: searching, selected: "Local")
        }, sendKey: {
            events.append($0.name)
            if $0.name == "slash" { searching = true }
            if $0.name == "escape" { searching = false }
            return true
        }, inputText: { _ in true }, waitFor: { $0() })
        check(!wrongSelection && !events.contains("enter"),
              "Enter must not be sent when the selected row is still on the wrong machine")
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8))
            exit(1)
        }
    }
}
