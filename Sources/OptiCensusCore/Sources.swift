import Foundation

/// One place AI can be found. `reads` is shown to the owner word for word
/// by `opticensus reads`, so it must stay true.
public protocol Source {
    var id: String { get }
    var reads: String { get }
    func collect(_ env: Env, _ sig: Signatures) -> [Found]
}

public enum Sources {
    public static let all: [Source] = [
        AppsSource(), ProcessSource(), AutostartSource(), MCPSource(),
        PortSource(), CLISource(), KeyNameSource(), ExtensionSource(),
        PluginSource(), ApprovalSource(), HookSource(),
    ]
}

// MARK: - Installed apps

struct AppsSource: Source {
    let id = "apps"
    let reads = "Installed apps: the Info.plist of each app in /Applications and ~/Applications (bundle id, version)."

    func collect(_ env: Env, _ sig: Signatures) -> [Found] {
        var out: [Found] = []
        func inspect(_ path: String) {
            guard let d = env.data(path + "/Contents/Info.plist"),
                  let p = (try? PropertyListSerialization.propertyList(from: d, format: nil)) as? [String: Any]
            else { return }
            let bundleId = p["CFBundleIdentifier"] as? String ?? ""
            let appName = String((path as NSString).lastPathComponent.dropLast(4))
            guard let tool = sig.tool(bundleId: bundleId, appName: appName) else { return }
            let version = [p["CFBundleShortVersionString"] as? String, p["CFBundleVersion"] as? String]
                .compactMap { $0 }
            out.append(Found(
                kind: .app, key: "app:" + (bundleId.isEmpty ? appName : bundleId),
                name: appName, tool: tool.id,
                detail: ["path": env.tilde(path), "bundle id": bundleId,
                         "version": version.first ?? "unknown"],
                fingerprint: fingerprint([bundleId, appName]),
                version: version.joined(separator: " ")))
        }
        for dir in ["/Applications", env.home + "/Applications"] {
            for name in env.list(dir) {
                let path = dir + "/" + name
                if name.hasSuffix(".app") {
                    inspect(path)
                } else if env.isDir(path) {
                    for inner in env.list(path) where inner.hasSuffix(".app") { inspect(path + "/" + inner) }
                }
            }
        }
        return out
    }
}

// MARK: - Running processes

struct ProcessSource: Source {
    let id = "processes"
    let reads = "Running processes: the list from ps. Command lines are matched against known names and then discarded; only the program's name and path are kept."

    func collect(_ env: Env, _ sig: Signatures) -> [Found] {
        var paths: [String: Set<String>] = [:]   // tool id -> executable paths
        var names: [String: String] = [:]
        func rows(_ command: Command) -> [Substring] {
            (env.run(command) ?? "").split(separator: "\n").compactMap { line in
                let t = line.drop(while: { $0 == " " })
                guard let space = t.firstIndex(of: " ") else { return nil }
                return t[t.index(after: space)...]
            }
        }
        for exe in rows(.psComm) {
            let path = String(exe).trimmingCharacters(in: .whitespaces)
            guard let tool = sig.tool(process: (path as NSString).lastPathComponent) else { continue }
            paths[tool.id, default: []].insert(env.tilde(path))
            names[tool.id] = tool.name
        }
        for args in rows(.psArgs) {
            guard let tool = sig.tool(argKeywordIn: String(args)) else { continue }
            if paths[tool.id] == nil { paths[tool.id] = [] }
            names[tool.id] = tool.name
        }
        return paths.keys.sorted().map { toolId in
            let list = paths[toolId]!.sorted()
            return Found(
                kind: .process, key: "process:" + toolId, name: names[toolId] ?? toolId, tool: toolId,
                detail: ["program": list.isEmpty ? "found in a command line" : list.joined(separator: ", ")],
                // Which copy is running (a bare name or a full path, a debug
                // build) varies from scan to scan, so it is shown, not tracked.
                fingerprint: fingerprint([toolId]))
        }
    }
}

// MARK: - Launch agents, launch daemons, crontab

struct AutostartSource: Source {
    let id = "autostart"
    let reads = "Things that start by themselves: the launch agents and daemons in ~/Library/LaunchAgents, /Library/LaunchAgents and /Library/LaunchDaemons, and your crontab. The program is recorded; its arguments and any script it runs are kept only as a hash."

    static let systemPrefixes = ["/bin/", "/sbin/", "/usr/bin/", "/usr/sbin/", "/System/"]

    func collect(_ env: Env, _ sig: Signatures) -> [Found] {
        var out: [Found] = []
        for dir in [env.home + "/Library/LaunchAgents", "/Library/LaunchAgents", "/Library/LaunchDaemons"] {
            for file in env.list(dir) where file.hasSuffix(".plist") {
                let path = dir + "/" + file
                guard let d = env.data(path),
                      let p = (try? PropertyListSerialization.propertyList(from: d, format: nil)) as? [String: Any]
                else { continue }
                let label = p["Label"] as? String ?? String(file.dropLast(6))
                let args = (p["ProgramArguments"] as? [String]) ?? (p["Program"] as? String).map { [$0] } ?? []
                // A path counts by its last component only: a script kept in
                // ~/.claude/ is not, for that reason, something that starts AI.
                let words = [label] + args.map { $0.hasPrefix("/") || $0.hasPrefix("~") ? ($0 as NSString).lastPathComponent : $0 }
                guard let tool = sig.tool(keywordIn: words.joined(separator: " ")) else { continue }

                var schedule: [String] = []
                if let n = p["StartInterval"] as? Int { schedule.append("every \(n) s") }
                if p["StartCalendarInterval"] != nil { schedule.append("at set times") }
                if p["RunAtLoad"] as? Bool == true { schedule.append("at login") }
                if p["KeepAlive"] != nil, p["KeepAlive"] as? Bool != false { schedule.append("kept running") }
                if p["WatchPaths"] != nil || p["QueueDirectories"] != nil { schedule.append("when a watched path changes") }

                // A script the job runs is part of what it does: hash it.
                var scripts: [String] = []
                for a in args where a.hasPrefix("/") && !Self.systemPrefixes.contains(where: a.hasPrefix) {
                    if env.isFile(a), let size = env.size(a), size <= 1_000_000, let body = env.data(a) {
                        scripts.append(fingerprint(body))
                    }
                }
                let program = args.first.map(env.tilde) ?? "none"
                out.append(Found(
                    kind: .autostart, key: "autostart:launchd:" + label, name: label, tool: tool.id,
                    detail: ["file": env.tilde(path), "program": program,
                             "arguments": "\(max(args.count - 1, 0)) (hash \(fingerprint(args)))",
                             "schedule": schedule.isEmpty ? "on demand" : schedule.joined(separator: ", "),
                             "scripts": scripts.isEmpty ? "none hashed" : scripts.joined(separator: ", ")],
                    fingerprint: fingerprint(args + ["|"] + schedule + ["|"] + scripts)))
            }
        }

        for line in (env.run(.crontab) ?? "").split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, !t.hasPrefix("#"), let tool = sig.tool(keywordIn: t) else { continue }
            let fields = t.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            let scheduleCount = t.hasPrefix("@") ? 1 : 5
            guard fields.count > scheduleCount else { continue }
            let hash = fingerprint([t])
            out.append(Found(
                kind: .autostart, key: "autostart:cron:" + hash, name: "cron line (\(tool.name))", tool: tool.id,
                detail: ["schedule": fields.prefix(scheduleCount).joined(separator: " "),
                         "program": fields[scheduleCount].contains("=") ? "not shown" : env.tilde(fields[scheduleCount]),
                         "line": "hash \(hash)"],
                fingerprint: hash))
        }
        return out
    }
}

// MARK: - MCP configuration

struct MCPSource: Source {
    let id = "mcp"
    let reads = "MCP configuration: the tool lists of Claude Code (including servers that come with a plugin), Claude desktop, Cursor, VS Code, Windsurf, Gemini and Codex. Server name, command and the names of its environment variables are recorded; arguments are kept as a hash, values and URLs beyond the host name are not kept."

    static let launchers: Set<String> = ["npx", "uvx", "node", "python", "python3", "bunx", "bun", "deno", "pnpm", "uv"]

    func collect(_ env: Env, _ sig: Signatures) -> [Found] {
        var out: [Found] = []
        let h = env.home

        func add(client: String, scope: String, file: String, name: String,
                 command: String?, args: [String], url: String?, secretNames: [String]) {
            var detail = ["client": client, "scope": scope, "file": env.tilde(file)]
            if let command {
                detail["command"] = env.tilde(command)
                if Self.launchers.contains((command as NSString).lastPathComponent),
                   let target = args.first(where: { !$0.hasPrefix("-") }), target.count <= 100,
                   !target.contains("://"), !target.contains("=") {
                    detail["runs"] = env.tilde(target)
                }
                detail["arguments"] = "\(args.count) (hash \(fingerprint(args)))"
            }
            if let url { detail["host"] = URLComponents(string: url)?.host ?? "not readable" }
            let names = secretNames.sorted()
            if !names.isEmpty { detail["variables"] = names.joined(separator: ", ") }
            out.append(Found(
                kind: .mcp, key: "mcp:\(client):\(scope):\(name)", name: name, tool: nil, detail: detail,
                fingerprint: fingerprint([command ?? ""] + args + ["|", url ?? "", "|"] + names)))
        }

        func addJSON(client: String, scope: String, file: String, servers: Any?) {
            guard let servers = servers as? [String: Any] else { return }
            for name in servers.keys.sorted() {
                guard let s = servers[name] as? [String: Any] else { continue }
                let secrets = ((s["env"] as? [String: Any])?.keys.map { $0 } ?? [])
                    + ((s["headers"] as? [String: Any])?.keys.map { $0 } ?? [])
                add(client: client, scope: scope, file: file, name: name,
                    command: s["command"] as? String,
                    args: (s["args"] as? [Any])?.map { "\($0)" } ?? [],
                    url: (s["url"] as? String) ?? (s["serverUrl"] as? String) ?? (s["httpUrl"] as? String),
                    secretNames: secrets)
            }
        }

        // Claude Code: servers at the top level and under each project.
        let claudeCode = h + "/.claude.json"
        if let j = env.json(claudeCode) {
            addJSON(client: "claude-code", scope: "user", file: claudeCode, servers: j["mcpServers"])
            for (project, value) in (j["projects"] as? [String: Any] ?? [:]).sorted(by: { $0.key < $1.key }) {
                let scope = env.tilde(project)
                addJSON(client: "claude-code", scope: scope, file: claudeCode,
                        servers: (value as? [String: Any])?["mcpServers"])
                let shared = project + "/.mcp.json"
                if let pj = env.json(shared) {
                    addJSON(client: "claude-code", scope: scope + " (.mcp.json)", file: shared, servers: pj["mcpServers"])
                }
            }
        }
        for p in ClaudeCode.plugins(env) {
            if let s = ClaudeCode.pluginServers(env, p) {
                addJSON(client: "claude-code", scope: "plugin \(p.id)", file: s.file, servers: s.servers)
            }
        }
        let simple: [(String, String, String)] = [
            ("claude-desktop", h + "/Library/Application Support/Claude/claude_desktop_config.json", "mcpServers"),
            ("cursor", h + "/.cursor/mcp.json", "mcpServers"),
            ("vscode", h + "/Library/Application Support/Code/User/mcp.json", "servers"),
            ("windsurf", h + "/.codeium/windsurf/mcp_config.json", "mcpServers"),
            ("gemini", h + "/.gemini/settings.json", "mcpServers"),
        ]
        for (client, file, key) in simple {
            if let j = env.json(file) { addJSON(client: client, scope: "user", file: file, servers: j[key]) }
        }

        // Codex keeps its servers in TOML: [mcp_servers.<name>] and [mcp_servers.<name>.env].
        let codex = h + "/.codex/config.toml"
        if let text = env.text(codex) {
            struct Entry { var fields: [String: String] = [:]; var names: [String] = [] }
            var entries: [String: Entry] = [:]
            var current: String?, sub: String?
            func unquote(_ s: String) -> String { s.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")) }
            for raw in text.split(separator: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("[") && line.hasSuffix("]") {
                    let section = line.dropFirst().dropLast()
                    current = nil; sub = nil
                    if section.hasPrefix("mcp_servers.") {
                        let parts = section.dropFirst("mcp_servers.".count).split(separator: ".", maxSplits: 1)
                        if let first = parts.first {
                            current = unquote(String(first))
                            sub = parts.count > 1 ? String(parts[1]) : nil
                            if entries[current!] == nil { entries[current!] = Entry() }
                        }
                    }
                    continue
                }
                guard let cur = current, !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
                let k = unquote(String(line[..<eq]))
                let v = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                if sub != nil {
                    entries[cur]!.names.append(k)               // a table of secrets: names only
                } else if k == "env" || k == "http_headers" {
                    let inner = v.trimmingCharacters(in: CharacterSet(charactersIn: "{} "))
                    for pair in inner.split(separator: ",") {
                        if let e = pair.firstIndex(of: "=") { entries[cur]!.names.append(unquote(String(pair[..<e]))) }
                    }
                } else {
                    entries[cur]!.fields[k] = v
                }
            }
            for name in entries.keys.sorted() {
                let e = entries[name]!
                let args = (e.fields["args"] ?? "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
                    .split(separator: ",").map { unquote(String($0)) }.filter { !$0.isEmpty }
                add(client: "codex", scope: "user", file: codex, name: name,
                    command: e.fields["command"].map(unquote), args: args,
                    url: e.fields["url"].map(unquote), secretNames: e.names)
            }
        }
        return out
    }
}

// MARK: - Listening ports

struct PortSource: Source {
    let id = "ports"
    let reads = "Listening ports: the list from lsof, for your own processes. Program name, port and whether it listens beyond this Mac."

    static let loopback: Set<String> = ["127.0.0.1", "[::1]", "localhost"]

    func collect(_ env: Env, _ sig: Signatures) -> [Found] {
        struct Listener { var command: String; var port: Int; var hosts: Set<String> }
        var seen: [String: Listener] = [:]
        for line in (env.run(.lsof) ?? "").split(separator: "\n").dropFirst() {
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 9, let colon = f[8].lastIndex(of: ":"),
                  let port = Int(f[8][f[8].index(after: colon)...]) else { continue }
            let command = f[0].replacingOccurrences(of: "\\x20", with: " ")
            let key = "\(port):\(command)"
            seen[key, default: Listener(command: command, port: port, hosts: [])].hosts.insert(String(f[8][..<colon]))
        }
        var out: [Found] = []
        for key in seen.keys.sorted() {
            let l = seen[key]!
            let exposed = !l.hosts.isSubset(of: Self.loopback)
            let known = sig.ports.first { $0.port == l.port }
            let tool = sig.tool(process: l.command)
            // A known model port always counts. An AI program on any other
            // port counts only when it is open to the network.
            guard known != nil || (tool != nil && exposed) else { continue }
            out.append(Found(
                kind: .port, key: "port:" + key,
                name: known?.name ?? "\(tool!.name) listener", tool: tool?.id,
                detail: ["port": "\(l.port)", "program": l.command,
                         "listens on": l.hosts.sorted().joined(separator: ", "),
                         "reach": exposed ? "the network" : "this Mac only"],
                fingerprint: fingerprint([l.command, "\(l.port)", exposed ? "exposed" : "local"]),
                exposed: exposed))
        }
        return out
    }
}

// MARK: - Command-line tools

struct CLISource: Source {
    let id = "cli"
    let reads = "Command-line assistants: whether a file with a known name exists in the folders on your PATH. Nothing is run."

    func collect(_ env: Env, _ sig: Signatures) -> [Found] {
        let h = env.home
        var dirs = env.path + [h + "/.local/bin", "/usr/local/bin", "/opt/homebrew/bin", h + "/bin",
                               h + "/.npm-global/bin", h + "/.cargo/bin", h + "/.bun/bin",
                               h + "/.claude/local", h + "/.lmstudio/bin"]
        let nvm = h + "/.nvm/versions/node"
        dirs += env.list(nvm).map { "\(nvm)/\($0)/bin" }
        var unique: [String] = []
        for d in dirs where !d.isEmpty && !unique.contains(d) { unique.append(d) }

        var out: [Found] = []
        for tool in sig.tools {
            for command in tool.commands ?? [] {
                let hits = unique.map { $0 + "/" + command }.filter {
                    env.isFile($0) && FileManager.default.isExecutableFile(atPath: env.url($0).path)
                }
                guard let first = hits.first else { continue }
                let resolved = env.logical(env.url(first).resolvingSymlinksInPath().path)
                var detail = ["path": env.tilde(first)]
                if resolved != first { detail["points to"] = env.tilde(resolved) }
                if hits.count > 1 { detail["copies"] = hits.dropFirst().map(env.tilde).joined(separator: ", ") }
                out.append(Found(
                    kind: .cli, key: "cli:" + command, name: command, tool: tool.id, detail: detail,
                    fingerprint: fingerprint(hits),
                    version: "\(resolved) \(env.size(resolved) ?? 0)"))
            }
        }
        return out
    }
}

// MARK: - Names of AI keys in shell start-up files

struct KeyNameSource: Source {
    let id = "keys"
    let reads = "Shell start-up files (.zshrc, .zshenv, .zprofile, .bashrc, .bash_profile, .profile, fish config): the NAMES of variables that look like AI keys. The value is never kept, hashed or shown."

    func collect(_ env: Env, _ sig: Signatures) -> [Found] {
        let files = [".zshrc", ".zshenv", ".zprofile", ".bashrc", ".bash_profile", ".profile",
                     ".config/fish/config.fish"].map { env.home + "/" + $0 }
        var out: [Found] = []
        var seen: Set<String> = []
        for file in files {
            guard let text = env.text(file) else { continue }
            for raw in text.split(separator: "\n") {
                guard let name = Self.variableName(in: String(raw)), sig.isKeyName(name) else { continue }
                let key = "key:\(name):\(env.tilde(file))"
                guard seen.insert(key).inserted else { continue }
                out.append(Found(kind: .key, key: key, name: name, tool: nil,
                                 detail: ["file": env.tilde(file)], fingerprint: fingerprint([key])))
            }
        }
        return out
    }

    /// The variable a line sets, and nothing else from the line.
    static func variableName(in line: String) -> String? {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("#") { return nil }
        func valid(_ s: Substring) -> String? {
            guard let first = s.first, first.isLetter || first == "_",
                  s.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else { return nil }
            return String(s)
        }
        let words = t.split(separator: " ", omittingEmptySubsequences: true)
        if words.first == "set", let name = words.dropFirst().first(where: { !$0.hasPrefix("-") }) {
            return valid(name)                                   // fish: set -gx NAME value
        }
        if words.first == "setenv", words.count > 1 { return valid(words[1]) }
        for prefix in ["export ", "typeset -x ", "declare -x "] where t.hasPrefix(prefix) {
            t = String(t.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        guard let eq = t.firstIndex(of: "=") else { return nil }
        return valid(t[..<eq])
    }
}

// MARK: - Chromium browser extensions

struct ExtensionSource: Source {
    let id = "extensions"
    let reads = "Browser extensions in Chrome, Edge, Brave, Arc, Vivaldi, Chromium and Opera: each extension's manifest (name, id, version; its permission list is kept as a hash). Safari is not read."

    static let browsers: [(String, String)] = [
        ("chrome", "Google/Chrome"), ("edge", "Microsoft Edge"), ("brave", "BraveSoftware/Brave-Browser"),
        ("arc", "Arc/User Data"), ("vivaldi", "Vivaldi"), ("chromium", "Chromium"),
        ("opera", "com.operasoftware.Opera"),
    ]

    func collect(_ env: Env, _ sig: Signatures) -> [Found] {
        var out: [Found] = []
        for (browser, folder) in Self.browsers {
            let base = env.home + "/Library/Application Support/" + folder
            var profiles = env.list(base).filter { $0 == "Default" || $0.hasPrefix("Profile ") }.map { ($0, base + "/" + $0) }
            if env.isDir(base + "/Extensions") { profiles.append(("Default", base)) }
            for (profile, dir) in profiles {
                for extId in env.list(dir + "/Extensions") {
                    let versions = env.list(dir + "/Extensions/" + extId)
                    guard let version = versions.last else { continue }
                    let folder = "\(dir)/Extensions/\(extId)/\(version)"
                    guard let m = env.json(folder + "/manifest.json") else { continue }
                    var name = m["name"] as? String ?? extId
                    if name.hasPrefix("__MSG_"), name.hasSuffix("__") {
                        let wanted = name.dropFirst(6).dropLast(2).lowercased()
                        let locale = m["default_locale"] as? String ?? "en"
                        if let messages = env.json("\(folder)/_locales/\(locale)/messages.json"),
                           let hit = messages.first(where: { $0.key.lowercased() == wanted }),
                           let text = (hit.value as? [String: Any])?["message"] as? String {
                            name = text
                        }
                    }
                    guard sig.isAIExtension(id: extId, name: name) else { continue }
                    let permissions = ((m["permissions"] as? [Any] ?? []) + (m["host_permissions"] as? [Any] ?? []))
                        .map { "\($0)" }.sorted()
                    out.append(Found(
                        kind: .extension, key: "extension:\(browser):\(profile):\(extId)", name: name, tool: nil,
                        detail: ["browser": browser, "profile": profile, "id": extId,
                                 "version": m["version"] as? String ?? version,
                                 "permissions": "\(permissions.count) (hash \(fingerprint(permissions)))"],
                        fingerprint: fingerprint(permissions),
                        version: m["version"] as? String ?? version))
                }
            }
        }
        return out
    }
}
