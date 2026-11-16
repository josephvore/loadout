// loadout-settings — one native settings window for every Loadout app,
// driven by per-app schemas in <repo>/settings/<app>.schema.json.
// Backends: "json" writes a settings overlay (merged by settings_overlay.lua
// at app start) — "shell" rewrites KEY=VALUE lines in a conf file.
//
//   loadout-settings <app>                     open the settings window
//   loadout-settings <app> --dump              print resolved values
//   loadout-settings <app> --set k=v [...]     write without a GUI
//     (--no-post-save skips the schema's postSave command)
//
// Build: build.sh. No dependencies beyond AppKit.
import AppKit

let home = FileManager.default.homeDirectoryForCurrentUser.path

func expand(_ path: String) -> String {
    path.hasPrefix("~") ? home + path.dropFirst() : path
}

// MARK: - Schema

struct Field: Decodable {
    let key: String
    let label: String
    let type: String            // string | folder | bool | int | enum
    let options: [String]?
    let help: String?
    let rawDef: String          // default, always a string; coerced by type
    var def: String { expand(rawDef) }   // "~/…" defaults resolve to $HOME
    enum CodingKeys: String, CodingKey {
        case key, label, type, options, help, rawDef = "default"
    }
}

struct Schema: Decodable {
    let app: String
    let title: String
    let format: String          // json | shell
    let target: String
    let postSave: [String]?
    let recentsDir: String?
    let fields: [Field]
}

// Schemas live in <repo>/settings; this binary is built into <repo>/lib/settings,
// so the checkout can be anywhere. LOADOUT_ROOT overrides for unusual layouts.
func repoRoot() -> String {
    if let r = ProcessInfo.processInfo.environment["LOADOUT_ROOT"], !r.isEmpty { return expand(r) }
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    return exe.deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().path
}

func loadSchema(_ app: String) -> Schema {
    let url = URL(fileURLWithPath: repoRoot() + "/settings/\(app).schema.json")
    guard let data = try? Data(contentsOf: url),
          let schema = try? JSONDecoder().decode(Schema.self, from: data) else {
        FileHandle.standardError.write("no schema for '\(app)' at \(url.path)\n".data(using: .utf8)!)
        exit(1)
    }
    return schema
}

// MARK: - Value store (read/write current values as strings)

func readValues(_ schema: Schema) -> [String: String] {
    var vals: [String: String] = [:]
    for f in schema.fields { vals[f.key] = f.def }
    let target = expand(schema.target)
    if schema.format == "json" {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: target)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return vals }
        for f in schema.fields {
            guard let v = obj[f.key] else { continue }
            switch v {
            case let b as Bool:   vals[f.key] = b ? "true" : "false"
            case let n as NSNumber: vals[f.key] = "\(n)"
            case let s as String: vals[f.key] = s
            default: break
            }
        }
    } else {
        guard let text = try? String(contentsOfFile: target, encoding: .utf8) else { return vals }
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("#") { continue }
            guard let eq = t.firstIndex(of: "=") else { continue }
            let key = String(t[..<eq])
            guard schema.fields.contains(where: { $0.key == key }) else { continue }
            var val = shellUnquote(String(t[t.index(after: eq)...]))
            if let f = schema.fields.first(where: { $0.key == key }), f.type == "bool" {
                val = (val == "1" || val == "true") ? "true" : "false"
            }
            vals[key] = val
        }
    }
    return vals
}

// Shell-format targets are sourced by sh, so quote anything beyond a plain
// word; plain values stay bare so simple `sed`/grep readers keep working.
func shellQuote(_ s: String) -> String {
    let safe = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-./:@%+,")
    if s.unicodeScalars.allSatisfy({ safe.contains($0) }) { return s }
    return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

func shellUnquote(_ s: String) -> String {
    guard s.count >= 2, s.hasPrefix("'"), s.hasSuffix("'") else { return s }
    return String(s.dropFirst().dropLast()).replacingOccurrences(of: "'\\''", with: "'")
}

func writeValues(_ schema: Schema, _ vals: [String: String]) throws {
    let target = expand(schema.target)
    try FileManager.default.createDirectory(
        atPath: (target as NSString).deletingLastPathComponent,
        withIntermediateDirectories: true)
    if schema.format == "json" {
        var obj: [String: Any] = [:]
        // Store only values that differ from the schema default, so untouched
        // fields keep following the app's own config (and loadout.local.lua).
        for f in schema.fields {
            let s = vals[f.key] ?? f.def
            if s == f.def { continue }
            switch f.type {
            case "bool": obj[f.key] = (s == "true")
            case "int":  obj[f.key] = Int(s) ?? 0
            default:     obj[f.key] = s
            }
        }
        let data = try JSONSerialization.data(withJSONObject: obj,
            options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: target))
    } else {
        var lines = (try? String(contentsOfFile: target, encoding: .utf8))?
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init) ?? []
        for f in schema.fields {
            var s = vals[f.key] ?? f.def
            if f.type == "bool" { s = (s == "true") ? "1" : "0" }
            let newLine = "\(f.key)=\(shellQuote(s))"
            if let i = lines.firstIndex(where: { $0.hasPrefix("\(f.key)=") }) {
                lines[i] = newLine
            } else {
                lines.append(newLine)
            }
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        try (lines.joined(separator: "\n") + "\n")
            .write(toFile: target, atomically: true, encoding: .utf8)
    }
}

func runPostSave(_ schema: Schema) {
    guard let argv = schema.postSave, !argv.isEmpty else { return }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: argv[0])
    p.arguments = Array(argv.dropFirst())
    try? p.run()
}

// MARK: - Recents (optional section)

struct Recent { let path: String; let label: String }

func recentCaptures(root: String, limit: Int = 5) -> [Recent] {
    let fm = FileManager.default
    guard let names = try? fm.contentsOfDirectory(atPath: root) else { return [] }
    return names
        .filter { $0.range(of: #"^\d{8}-\d{6}$"#, options: .regularExpression) != nil }
        .sorted(by: >)
        .prefix(limit)
        .map { stamp in
            let dir = root + "/" + stamp
            let report = dir + "/report.md"
            if fm.fileExists(atPath: report) {
                return Recent(path: report, label: "\(stamp) — report")
            }
            let done = fm.fileExists(atPath: dir + "/result.json")
            return Recent(path: dir, label: "\(stamp) — \(done ? "done" : "processing…")")
        }
}

// MARK: - CLI modes

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: loadout-settings <app> [--dump | --set k=v ... [--no-post-save]]")
    exit(1)
}
let schema = loadSchema(args[1])

if args.contains("--dump") {
    let vals = readValues(schema)
    for f in schema.fields { print("\(f.key)=\(vals[f.key] ?? "")") }
    exit(0)
}

if args.contains("--set") {
    var vals = readValues(schema)
    for a in args.dropFirst(2) where a.contains("=") {
        guard let eq = a.firstIndex(of: "=") else { continue }
        let key = String(a[..<eq])
        guard schema.fields.contains(where: { $0.key == key }) else {
            FileHandle.standardError.write("unknown key: \(key)\n".data(using: .utf8)!)
            exit(1)
        }
        vals[key] = String(a[a.index(after: eq)...])
    }
    do { try writeValues(schema, vals) } catch {
        FileHandle.standardError.write("write failed: \(error)\n".data(using: .utf8)!)
        exit(1)
    }
    if !args.contains("--no-post-save") { runPostSave(schema) }
    exit(0)
}

// MARK: - GUI

final class SettingsApp: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var controls: [String: NSControl] = [:]
    var recents: [Recent] = []

    func control(for f: Field, value: String) -> NSView {
        switch f.type {
        case "bool":
            let b = NSButton(checkboxWithTitle: "", target: nil, action: nil)
            b.state = (value == "true") ? .on : .off
            b.toolTip = f.help
            controls[f.key] = b
            return b
        case "enum":
            let p = NSPopUpButton(frame: .zero, pullsDown: false)
            p.addItems(withTitles: f.options ?? [])
            p.selectItem(withTitle: value)
            p.toolTip = f.help
            controls[f.key] = p
            return p
        case "folder":
            let t = NSTextField(string: value)
            t.placeholderString = f.help ?? ""
            t.widthAnchor.constraint(equalToConstant: 300).isActive = true
            t.toolTip = f.help
            controls[f.key] = t
            let browse = NSButton(title: "Browse…", target: self, action: #selector(browseFolder(_:)))
            browse.identifier = NSUserInterfaceItemIdentifier(f.key)
            let row = NSStackView(views: [t, browse])
            row.orientation = .horizontal
            return row
        default: // string, int
            let t = NSTextField(string: value)
            t.widthAnchor.constraint(equalToConstant: f.type == "int" ? 80 : 220).isActive = true
            t.toolTip = f.help
            controls[f.key] = t
            return t
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let vals = readValues(schema)
        var rows: [[NSView]] = []
        for f in schema.fields {
            rows.append([NSTextField(labelWithString: f.label + ":"),
                         control(for: f, value: vals[f.key] ?? f.def)])
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 10
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.addArrangedSubview(grid)

        if let rd = schema.recentsDir {
            recents = recentCaptures(root: expand(rd))
            let label = NSTextField(labelWithString: "Recent outputs")
            label.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
            stack.addArrangedSubview(label)
            if recents.isEmpty {
                stack.addArrangedSubview(NSTextField(labelWithString: "none yet"))
            } else {
                for (i, r) in recents.enumerated() {
                    let b = NSButton(title: r.label, target: self, action: #selector(openRecent(_:)))
                    b.bezelStyle = .inline
                    b.tag = i
                    stack.addArrangedSubview(b)
                }
            }
        }

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        let save = NSButton(title: "Save", target: self, action: #selector(saveClicked))
        save.keyEquivalent = "\r"
        let buttons = NSStackView(views: [cancel, save])
        buttons.orientation = .horizontal
        stack.addArrangedSubview(buttons)

        window = NSWindow(contentRect: .zero,
                          styleMask: [.titled, .closable],
                          backing: .buffered, defer: false)
        window.title = schema.title
        window.contentView = stack
        window.setContentSize(stack.fittingSize)
        window.center()
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func browseFolder(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue,
              let field = controls[key] as? NSTextField else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use folder"
        if panel.runModal() == .OK, let url = panel.url {
            field.stringValue = url.path
        }
    }

    @objc func openRecent(_ sender: NSButton) {
        guard sender.tag < recents.count else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: recents[sender.tag].path))
    }

    @objc func cancelClicked() { NSApp.terminate(nil) }

    @objc func saveClicked() {
        var vals: [String: String] = [:]
        for f in schema.fields {
            guard let c = controls[f.key] else { continue }
            switch f.type {
            case "bool": vals[f.key] = ((c as! NSButton).state == .on) ? "true" : "false"
            case "enum": vals[f.key] = (c as! NSPopUpButton).titleOfSelectedItem ?? f.def
            default:     vals[f.key] = (c as! NSTextField).stringValue
                             .trimmingCharacters(in: .whitespaces)
            }
        }
        do { try writeValues(schema, vals) } catch {
            let alert = NSAlert()
            alert.messageText = "Could not save settings"
            alert.informativeText = "\(error)"
            alert.runModal()
            return
        }
        runPostSave(schema)
        NSApp.terminate(nil)
    }

    func windowWillClose(_ notification: Notification) { NSApp.terminate(nil) }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = SettingsApp()
app.delegate = delegate
app.run()
