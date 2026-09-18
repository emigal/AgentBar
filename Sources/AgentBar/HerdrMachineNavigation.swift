import Cocoa

/// Herdr 0.9's machine selection belongs to its client, not the server API.
/// Until Herdr exposes client navigation, the client is driven through its
/// exact Ghostty surface. The direct route is a left click on the machine's
/// sidebar row — Herdr's own mouse handling turns that into the switch, nothing
/// opens and nothing is typed. Ghostty's scripting dictionary aims mouse events
/// at one terminal surface; the row is located in that surface's accessibility
/// text first and the switch verified in it afterwards. The native navigator is
/// only the fallback for a sidebar that is collapsed, hidden, or scrolled past
/// the machine. Both read before sending anything; no shell commands are typed.
enum HerdrMachineNavigation {
    struct Machine: Decodable, Equatable {
        let id: String
        let label: String
        let target: String
        let session: String
        let enabled: Bool

        static let local = Machine(id: "", label: "Local", target: "", session: "default", enabled: true)
    }

    struct Key: Equatable {
        let name: String
        let modifiers: String
    }

    /// `herdr machine list --json`; nil for an older CLI without the command.
    static func machines(json: String) -> [Machine]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([Machine].self, from: data)
    }

    static func machine(host: String, json: String) -> Machine? {
        machines(json: json).flatMap { machine(host: host, in: $0) }
    }

    /// The poller queries the default session at an SSH target, not a profile
    /// label. Identical pane IDs in other sessions must never be substituted.
    static func machine(host: String, in machines: [Machine]) -> Machine? {
        let matches = machines.filter {
            $0.enabled && $0.target == host && $0.session == "default"
                && !$0.label.isEmpty && !$0.label.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        }
        guard matches.count == 1 else { return nil }
        // The sidebar and the navigator show labels. Duplicate labels cannot
        // identify a machine, even when the profiles have different IDs.
        guard machines.filter({ $0.enabled && $0.label.lowercased() == matches[0].label.lowercased() }).count == 1
        else { return nil }
        return matches[0]
    }

    /// Only a client with an actual SSH bridge to this host can render it.
    /// A bare `herdr` process alone does not prove that the machine is connected.
    static func attach(host: String, ps: String) -> TerminalFocus.HerdrAttach? {
        let rows = ps.split(separator: "\n").map {
            $0.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        }.filter { $0.count >= 4 }
        let attaches = TerminalFocus.herdrAttaches(ps: rows.map {
            ([$0[0]] + Array($0.dropFirst(2))).joined(separator: " ")
        }.joined(separator: "\n"))
        let parents = Set(rows.compactMap { tokens -> Int32? in
            guard tokens[3] == "ssh" || tokens[3].hasSuffix("/ssh"),
                  tokens.last == "remote-client-bridge",
                  let execIndex = tokens.lastIndex(of: "exec"), execIndex > 4,
                  tokens[execIndex - 1] == host
            else { return nil }
            return Int32(tokens[1])
        })
        return TerminalFocus.herdrAttach(host: nil, in: attaches.filter { parents.contains($0.pid) })
    }

    /// Conservative parsing of the two client bindings we need. Unsupported
    /// TOML or a conflicting binding disables automation instead of guessing.
    static func navigatorKeys(config: String) -> [Key]? {
        var section = ""
        var prefix = "ctrl+b"
        var shortcut = "prefix+g"
        var otherBindings: [String] = []
        for raw in config.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") {
                section = line.components(separatedBy: "#")[0].trimmingCharacters(in: .whitespaces)
                if section.hasPrefix("[keys.") && section != "[keys.indexed]" { return nil }
                continue
            }
            guard section == "[keys]" || section == "[[keys.command]]" else { continue }
            guard let equal = line.firstIndex(of: "=") else { return nil }
            let field = line[..<equal].trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: equal)...])
            if section == "[[keys.command]]", field != "key" { continue }
            guard let values = bindingStrings(value) else { return nil }
            if section == "[keys]", field == "prefix" {
                guard values.count == 1 else { return nil }
                prefix = values[0]
            } else if section == "[keys]", field == "goto" {
                guard let first = values.first else { return nil }
                shortcut = first
            } else {
                otherBindings += values
            }
        }
        func sequence(_ binding: String) -> [Key]? {
            let prefixed = binding.lowercased().hasPrefix("prefix+")
            let chords = prefixed ? [prefix, String(binding.dropFirst(7))] : [binding]
            let keys = chords.compactMap(key)
            return keys.count == chords.count ? keys : nil
        }
        guard let keys = sequence(shortcut), !otherBindings.contains(where: { sequence($0) == keys }) else { return nil }
        return keys
    }

    private static func bindingStrings(_ value: String) -> [String]? {
        // Match complete quoted strings, then permit only array punctuation,
        // whitespace and a trailing comment outside them.
        let pattern = #"\"(?:[^\"\\]|\\.)*\"|'[^']*'"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = value as NSString
        let matches = regex.matches(in: value, range: NSRange(location: 0, length: ns.length))
        var strings: [String] = []
        var end = 0
        for match in matches {
            let gap = ns.substring(with: NSRange(location: end, length: match.range.location - end))
            if gap.contains("#") { break }
            guard gap.allSatisfy({ $0.isWhitespace || "[,".contains($0) }) else { return nil }
            let literal = ns.substring(with: match.range)
            if literal.hasPrefix("'") {
                strings.append(String(literal.dropFirst().dropLast()))
            } else {
                guard let data = literal.data(using: .utf8),
                      let decoded = try? JSONDecoder().decode(String.self, from: data) else { return nil }
                strings.append(decoded)
            }
            end = match.range.location + match.range.length
        }
        let tail = ns.substring(from: end).components(separatedBy: "#")[0]
        guard tail.allSatisfy({ $0.isWhitespace || "[],".contains($0) }) else { return nil }
        return strings
    }

    private static func key(_ chord: String) -> Key? {
        var parts = chord.split(separator: "+").map(String.init)
        guard let rawName = parts.popLast(), !rawName.isEmpty else { return nil }
        let name = rawName.lowercased()
        let names = ["ctrl": "control", "control": "control", "alt": "option", "option": "option", "shift": "shift", "super": "command", "cmd": "command"]
        var modifiers = parts.compactMap { names[$0.lowercased()] }
        guard modifiers.count == parts.count else { return nil }
        if rawName.count == 1 && rawName != name { modifiers.append("shift") }
        let punctuation = ["/": "slash", ".": "period", ",": "comma", "-": "minus", "=": "equal", "[": "bracketLeft", "]": "bracketRight", ";": "semicolon", "'": "quote", "`": "backquote", "\\": "backslash", "esc": "escape"]
        let ghosttyName: String
        if let mapped = punctuation[name] { ghosttyName = mapped }
        else if name.count == 1 && name.first!.isASCII && name.first!.isNumber { ghosttyName = "digit" + name }
        else if name == "space" || name == "escape" || (name.count == 1 && name.first!.isASCII && name.first!.isLetter)
                    || (1...24).contains(where: { name == "f\($0)" }) { ghosttyName = name }
        else { return nil }
        return Key(name: ghosttyName, modifiers: Set(modifiers).sorted().joined(separator: ","))
    }

    // MARK: - Sidebar click

    /// The Ghostty surface rendering the Herdr client: its screen text, its
    /// size in points, and the backing scale of the display it is on.
    struct Surface {
        let text: String
        let size: CGSize
        let scale: CGFloat
    }

    /// Ghostty's `window-padding-*`, in points. The grid is anchored at the
    /// top-left padding; leftover space goes to the bottom and right unless
    /// `window-padding-balance` splits it.
    struct Padding: Equatable {
        var left = 2.0, right = 2.0, top = 2.0, bottom = 2.0
        var balance = false

        /// Later lines and later files override earlier ones, like Ghostty.
        /// `window-padding-x = 2,4` is left,right; `-y` is top,bottom.
        mutating func apply(ghosttyConfig: String) {
            for raw in ghosttyConfig.components(separatedBy: .newlines) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard !line.hasPrefix("#"), let equal = line.firstIndex(of: "=") else { continue }
                let key = line[..<equal].trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: equal)...].trimmingCharacters(in: .whitespaces)
                switch key {
                case "window-padding-x", "window-padding-y":
                    let parts = value.split(separator: ",")
                    let numbers = parts.compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                    guard (1...2).contains(parts.count), numbers.count == parts.count else { continue }
                    let (first, second) = (numbers[0], numbers.count == 2 ? numbers[1] : numbers[0])
                    if key == "window-padding-x" { (left, right) = (first, second) } else { (top, bottom) = (first, second) }
                case "window-padding-balance":
                    balance = value != "false"
                default:
                    continue
                }
            }
        }
    }

    /// Ghostty's config files in load order: XDG, then the macOS-specific
    /// Application Support file on top.
    static func ghosttyPadding() -> Padding {
        var padding = Padding()
        let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"] ?? NSHomeDirectory() + "/.config"
        for path in [xdg + "/ghostty/config", NSHomeDirectory() + "/Library/Application Support/com.mitchellh.ghostty/config"] {
            if let config = try? String(contentsOfFile: path, encoding: .utf8) { padding.apply(ghosttyConfig: config) }
        }
        return padding
    }

    /// The centre of a grid cell in the surface's own points, origin top-left,
    /// which is what Ghostty's scripted mouse position takes. Cells are whole
    /// device pixels, so the size the grid divides into is floored to one.
    static func cellCenter(row: Int, column: Int, size: CGSize, rows: Int, columns: Int,
                           padding: Padding, scale: CGFloat) -> CGPoint? {
        guard rows > 0, columns > 0, scale > 0 else { return nil }
        let width = size.width - padding.left - padding.right
        let height = size.height - padding.top - padding.bottom
        let cellWidth = floor(width / CGFloat(columns) * scale) / scale
        let cellHeight = floor(height / CGFloat(rows) * scale) / scale
        guard cellWidth > 0, cellHeight > 0 else { return nil }
        let balanceX = padding.balance ? (width - cellWidth * CGFloat(columns)) / 2 : 0
        let balanceY = padding.balance ? (height - cellHeight * CGFloat(rows)) / 2 : 0
        return CGPoint(x: padding.left + balanceX + (CGFloat(column) + 0.5) * cellWidth,
                       y: padding.top + balanceY + (CGFloat(row) + 0.5) * cellHeight)
    }

    /// Herdr's expanded sidebar column, one string per screen row, cut at the
    /// footer's `menu` button, which Herdr right-aligns to the sidebar's edge.
    struct Sidebar: Equatable {
        let rows: [String]
        /// The machine on screen, from the footer's ` new · <label>` button.
        let active: String

        /// A machine row is ` ▾ label` (`▸` collapsed) with the online glyph
        /// `●` right-aligned — Local has none — and at most the list's
        /// scrollbar after it. Any other status adds a word (`◐ reconnecting`)
        /// and is not a live target; workspaces are indented further.
        func machineRow(label: String, local: Bool = false) -> Int? {
            let matches = rows.enumerated().filter { _, row in
                guard row.hasPrefix(" ▾ \(label)") || row.hasPrefix(" ▸ \(label)") else { return false }
                let rest = row.dropFirst(label.count + 3)
                guard rest.first?.isWhitespace ?? true else { return false } // a longer label
                let marks = rest.filter { !$0.isWhitespace }
                return local ? marks == "" || marks == "▕" : marks == "●" || marks == "●▕"
            }
            return matches.count == 1 ? matches[0].offset : nil
        }
    }

    /// `labels` are the saved machines: the footer names one of them or Local,
    /// and a label is matched whole so one containing "menu" cannot move the
    /// cut. No footer (sidebar hidden or collapsed, mouse capture off) = nil.
    static func sidebar(screen: String, labels: [String]) -> Sidebar? {
        let lines = screen.components(separatedBy: .newlines)
        for line in lines where line.hasPrefix(" new · ") {
            let rest = line.dropFirst(7)
            guard let label = (labels + ["Local"]).first(where: {
                rest.hasPrefix($0) && (rest.dropFirst($0.count).first?.isWhitespace ?? true)
            }) else { return nil }
            let after = rest.dropFirst(label.count)
            // The launcher: spaces, an attention dot when Herdr shows one, "menu".
            guard let menu = after.range(of: "menu"),
                  after[..<menu.lowerBound].allSatisfy({ $0.isWhitespace || $0 == "●" })
            else { return nil }
            let width = line.distance(from: line.startIndex, to: menu.upperBound)
            return Sidebar(rows: lines.map { String($0.prefix(width)) }, active: label)
        }
        return nil
    }

    enum Click: Equatable {
        case selected, alreadyActive, rowHidden, failed
    }

    /// Click the machine's sidebar row and wait for the footer to name it.
    /// Injectable so tests prove where the click lands and that nothing is
    /// clicked when the machine is already on screen or its row is not.
    static func click(label: String, local: Bool = false, labels: [String], padding: Padding,
                      surface: @escaping () -> Surface?, clickAt: (CGPoint) -> Bool,
                      waitFor: ((() -> Bool)) -> Bool) -> Click {
        guard let current = surface(), let bar = sidebar(screen: current.text, labels: labels) else { return .rowHidden }
        if bar.active == label { return .alreadyActive }
        guard let row = bar.machineRow(label: label, local: local) else { return .rowHidden }
        let lines = current.text.components(separatedBy: .newlines)
        // Inside the label, well past the collapse arrow at column 1: on the
        // active machine that arrow folds the group instead of switching.
        guard let point = cellCenter(row: row, column: 3 + label.count / 2, size: current.size,
                                     rows: lines.count, columns: lines.map(\.count).max() ?? 0,
                                     padding: padding, scale: current.scale),
              clickAt(point)
        else { return .failed }
        return waitFor({ surface().flatMap { sidebar(screen: $0.text, labels: labels) }?.active == label })
            ? .selected : .failed
    }

    // MARK: - Navigator fallback

    struct Navigator {
        let query: String
        let searching: Bool
        let rows: [String]
        let selected: String

        func machineRow(label: String, local: Bool = false) -> Int? {
            let matches = rows.enumerated().filter {
                var row = $0.element
                while row.last?.isWhitespace == true { row.removeLast() }
                // One leading space is a machine; three is a workspace.
                if local { return row == " ▾ Local" }
                return row.hasPrefix(" ▾ \(label) ") && row.hasSuffix("●")
                    && row.dropFirst(label.count + 3).dropLast().allSatisfy(\.isWhitespace)
            }
            return matches.count == 1 ? matches[0].offset : nil
        }
    }

    /// Parse only a boxed native navigator, with its header and footer in the
    /// same columns. Normal agent output mentioning a machine is insufficient.
    static func navigator(screen: String) -> Navigator? {
        let lines = screen.components(separatedBy: .newlines).map(Array.init)
        for (index, chars) in lines.enumerated() where index > 0 && index + 4 < lines.count {
            let line = String(chars)
            guard let header = line.range(of: "│ / ") else { continue }
            let left = line.distance(from: line.startIndex, to: header.lowerBound)
            guard lines[index - 1].count > left, "╭┌".contains(lines[index - 1][left]),
                  let right = lines[index - 1].indices.first(where: { $0 > left && "╮┐".contains(lines[index - 1][$0]) }),
                  chars.count > right, chars[right] == "│"
            else { continue }
            let inside: (Int) -> String? = { row in
                guard lines[row].count > right, lines[row][left] == "│", lines[row][right] == "│" else { return nil }
                return String(lines[row][(left + 1)..<right])
            }
            guard let heading = inside(index), let separator = inside(index + 1),
                  separator.trimmingCharacters(in: .whitespaces).allSatisfy({ $0 == "─" })
            else { continue }
            for bottom in (index + 4)..<lines.count {
                guard let footer = inside(bottom),
                      footer.contains("open enter"), footer.contains("search")
                else { continue }
                let searching = footer.contains("search type")
                guard searching || footer.contains("expand space"),
                      let selected = inside(bottom - 1),
                      bottom + 1 < lines.count, lines[bottom + 1].count > right,
                      "╰└".contains(lines[bottom + 1][left]), "╯┘".contains(lines[bottom + 1][right]),
                      heading.hasSuffix("panes ") || heading.trimmingCharacters(in: .whitespaces).hasSuffix("panes")
                else { continue }
                let headerText = String(heading.dropFirst(3))
                // Count is right-aligned after at least two spaces.
                let query = headerText.components(separatedBy: "  ")[0].trimmingCharacters(in: .whitespaces)
                let rows = ((index + 2)..<(bottom - 1)).compactMap(inside)
                return Navigator(query: query, searching: searching, rows: rows,
                                 selected: selected.trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    /// Injectable UI operations keep regression tests independent of a running
    /// terminal and prove that no text/Enter is sent after a failed guard.
    static func select(label: String, local: Bool = false, keys: [Key], screen: @escaping () -> String?,
                       sendKey: (Key) -> Bool, inputText: (String) -> Bool,
                       waitFor: ((() -> Bool)) -> Bool) -> Bool {
        func view() -> Navigator? { screen().flatMap(navigator) }
        guard let initialScreen = screen() else { return false }
        if navigator(screen: initialScreen) == nil {
            for key in keys { guard sendKey(key) else { return false } }
        }
        guard waitFor({ view() != nil }), let initial = view() else { return false }
        if !initial.searching {
            guard sendKey(Key(name: "slash", modifiers: "")) else { return false }
        }
        guard waitFor({ view()?.searching == true }),
              sendKey(Key(name: "u", modifiers: "control")), view()?.searching == true, inputText(label),
              waitFor({ view()?.query == label }), let filtered = view(),
              let row = filtered.machineRow(label: label, local: local)
        else { return false }
        guard sendKey(Key(name: "escape", modifiers: "")),
              waitFor({ view()?.searching == false }),
              sendKey(Key(name: "home", modifiers: "")) else { return false }
        for _ in 0..<row {
            guard view() != nil, sendKey(Key(name: "arrowDown", modifiers: "")) else { return false }
        }
        guard waitFor({
            guard let current = view() else { return false }
            return current.query == label && current.machineRow(label: label, local: local) != nil
                && current.selected == "\(label) ·"
        }) else { return false }
        return sendKey(Key(name: "enter", modifiers: ""))
            && waitFor({ screen().map { navigator(screen: $0) == nil } == true })
    }

    /// Switch the combined client at `attach` to `machine`, then confirm the
    /// client persisted that choice. `machines` is the whole catalog: the
    /// sidebar footer is read against every label.
    static func select(machine: Machine, among machines: [Machine], attach: TerminalFocus.HerdrAttach,
                       run: @escaping (String, [String]) -> String?) -> Bool {
        guard AXIsProcessTrusted() else {
            DispatchQueue.main.async { KeystrokeApprover.requestAccess() }
            return false
        }
        let env = ProcessInfo.processInfo.environment
        func command(_ operation: String, _ first: String = "", _ second: String = "") -> Bool {
            run("/usr/bin/osascript", ["-e", ghosttyScript, attach.tty, String(attach.pid), operation, first, second])?
                .trimmingCharacters(in: .whitespacesAndNewlines) == "hit"
        }
        func surface() -> Surface? {
            guard command("check"),
                  let app = NSWorkspace.shared.frontmostApplication,
                  app.bundleIdentifier == "com.mitchellh.ghostty" else { return nil }
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            var focused: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
                  let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
            let element = focused as! AXUIElement
            func attribute(_ name: String) -> CFTypeRef? {
                var value: CFTypeRef?
                return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
            }
            var origin = CGPoint.zero
            var size = CGSize.zero
            guard attribute(kAXRoleAttribute) as? String == kAXTextAreaRole,
                  let text = attribute(kAXValueAttribute) as? String,
                  let position = attribute(kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
                  AXValueGetValue(position as! AXValue, .cgPoint, &origin),
                  let extent = attribute(kAXSizeAttribute), CFGetTypeID(extent) == AXValueGetTypeID(),
                  AXValueGetValue(extent as! AXValue, .cgSize, &size),
                  command("check") else { return nil }
            // Accessibility positions hang from the top-left of the main
            // display; NSScreen frames rise from its bottom-left.
            let mainHeight = NSScreen.screens.first?.frame.height ?? 0
            let center = CGPoint(x: origin.x + size.width / 2, y: mainHeight - origin.y - size.height / 2)
            let scale = NSScreen.screens.first(where: { $0.frame.contains(center) })?.backingScaleFactor ?? 2
            return Surface(text: text, size: size, scale: scale)
        }
        func waitFor(_ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(3)
            repeat {
                if condition() { return true }
                usleep(100_000)
            } while Date() < deadline
            return false
        }
        let local = machine.id.isEmpty
        switch click(label: machine.label, local: local, labels: machines.map(\.label), padding: ghosttyPadding(),
                     surface: surface, clickAt: { point in
                         // Whole points: AppleScript parses the numbers in the user's locale.
                         command("click", String(Int(point.x.rounded())), String(Int(point.y.rounded())))
                     }, waitFor: waitFor) {
        case .selected, .alreadyActive:
            break
        case .failed:
            return false
        case .rowHidden:
            NSLog("AgentBar: Herdr sidebar row for %@ is not on screen; using the navigator", machine.label)
            let configPath = env["HERDR_CONFIG_PATH"]
                ?? (env["XDG_CONFIG_HOME"] ?? NSHomeDirectory() + "/.config") + "/herdr/config.toml"
            let config: String
            if FileManager.default.fileExists(atPath: configPath) {
                guard let contents = try? String(contentsOfFile: configPath, encoding: .utf8) else { return false }
                config = contents
            } else { config = "" }
            guard let keys = navigatorKeys(config: config),
                  select(label: machine.label, local: local, keys: keys, screen: { surface()?.text },
                         sendKey: { command("key", $0.name, $0.modifiers) },
                         inputText: { command("text", $0) }, waitFor: waitFor)
            else { return false }
        }
        let stateDir = (env["XDG_STATE_HOME"] ?? NSHomeDirectory() + "/.local/state") + "/herdr/client"
        guard let data = FileManager.default.contents(atPath: stateDir + "/endpoint-selection.json"),
              let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return local ? state["selected_profile"] is NSNull : state["selected_profile"] as? String == machine.id
    }

    // Target the selected surface AND its live foreground Herdr process on
    // every operation. Switching apps, tabs, or closing Herdr aborts input.
    private static let ghosttyScript = """
    on run argv
        tell application "Ghostty"
            if not frontmost then return "miss"
            set tb to selected tab of front window
            set t to focused terminal of tb
            if tty of t is not item 1 of argv then return "miss"
            if pid of t is not (item 2 of argv as integer) then return "miss"
            set operation to item 3 of argv
            if operation is "key" then
                send key (item 4 of argv) modifiers (item 5 of argv) to t
            else if operation is "text" then
                input text (item 4 of argv) to t
            else if operation is "click" then
                send mouse position x (item 4 of argv as integer) y (item 5 of argv as integer) to t
                send mouse button left button action press to t
                send mouse button left button action release to t
            end if
            return "hit"
        end tell
    end run
    """
}
